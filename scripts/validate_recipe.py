#!/usr/bin/env python3
"""Validate a vaka recipe directory against the registry authoring rules.

Rules come from the registry design document:
https://github.com/infrasecture/vaka/blob/main/docs/design/recipes-registry.md

Checks:
  - recipe.yaml schema (apiVersion, kind: Recipe, strict key set; the
    reserved `provides:`/`requires:` fields are rejected until specified)
  - name equals the directory name and matches [a-z0-9-]+
  - version is strict SemVer (X.Y.Z); optional bump check against a base
    manifest (--require-bump-from) and tag check (--expect-version)
  - required files: recipe.yaml, README.md, vaka.yaml, compose file
  - no reserved .vaka-* paths, no committed .env, symlinks stay in-tree
  - risk lint over `docker compose config` + vaka.yaml; every gating flag
    must be acknowledged in riskAcknowledgements or validation fails.
    Advisory flags (ADVISORY_FLAGS, e.g. unpinned-image) are surfaced as
    warnings and never fail CI.
  - optional machine-readable policy summary for the index (--summary-json)

Exit code 0 on success, 1 with per-line `::error::`/`::warning::` output
(GitHub Actions annotations, readable in any terminal) otherwise.
"""

import argparse
import json
import os
import re
import subprocess
import sys

import yaml

API_VERSION = "recipes.vaka/v1alpha1"
NAME_RE = re.compile(r"^[a-z0-9-]+$")
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
ALLOWED_KEYS = {
    "apiVersion", "kind", "name", "version", "description", "homepage",
    "tags", "minVakaVersion", "env", "riskAcknowledgements",
}
RESERVED_KEYS = {"provides", "requires"}
ENV_ENTRY_KEYS = {"name", "required", "default", "description"}
ACK_ENTRY_KEYS = {"flag", "reason"}
# Exactly compose-go's DefaultFileNames / DefaultOverrideFileNames (cli/
# options.go), in precedence order — base and override are selected
# INDEPENDENTLY (the override is not tied to the base's family), and .yml
# precedes .yaml for docker-compose. Keep these identical to the Go lint so
# the risk lint sees the same files `vaka up` loads.
COMPOSE_FILES = ("compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml")
COMPOSE_OVERRIDE_FILES = (
    "compose.override.yml", "compose.override.yaml",
    "docker-compose.override.yml", "docker-compose.override.yaml",
)
BROAD_MOUNT_SOURCES = {"/", "/home", "/root", "/etc", "/usr", "/var", "/proc", "/sys"}
BROAD_CAPS = {"SYS_ADMIN", "ALL"}
VAKA_INIT_LABEL = "agent.vaka.init"
# Advisory flags are surfaced to users but never fail CI (they need no
# riskAcknowledgements), because the pattern they flag is common and not, on
# its own, a gate.
ADVISORY_FLAGS = {"unpinned-image"}

errors = []
warnings = []


def err(msg):
    errors.append(msg)
    print(f"::error::{msg}")


def warn(msg):
    warnings.append(msg)
    print(f"::warning::{msg}")


def parse_semver(s):
    m = SEMVER_RE.match(s or "")
    return tuple(int(g) for g in m.groups()) if m else None


def load_yaml(path):
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def check_manifest(recipe_dir, expect_version, bump_from):
    path = os.path.join(recipe_dir, "recipe.yaml")
    if not os.path.isfile(path):
        err(f"{recipe_dir}: recipe.yaml is missing")
        return None
    try:
        manifest = load_yaml(path)
    except yaml.YAMLError as e:
        err(f"{path}: not valid YAML: {e}")
        return None
    if not isinstance(manifest, dict):
        err(f"{path}: manifest must be a YAML mapping")
        return None

    if manifest.get("apiVersion") != API_VERSION:
        err(f"{path}: apiVersion must be {API_VERSION!r}")
    if manifest.get("kind") != "Recipe":
        err(f"{path}: kind must be 'Recipe'")

    keys = set(manifest)
    for k in sorted(keys & RESERVED_KEYS):
        err(f"{path}: field {k!r} is reserved for future recipe composability and is rejected until specified")
    for k in sorted(keys - ALLOWED_KEYS - RESERVED_KEYS):
        err(f"{path}: unknown field {k!r} (strict schema; allowed: {', '.join(sorted(ALLOWED_KEYS))})")

    dir_name = os.path.basename(os.path.abspath(recipe_dir))
    name = manifest.get("name")
    if name != dir_name:
        err(f"{path}: name {name!r} must equal the directory name {dir_name!r}")
    if not (isinstance(name, str) and NAME_RE.match(name)):
        err(f"{path}: name must match [a-z0-9-]+")

    version = manifest.get("version")
    ver = parse_semver(version if isinstance(version, str) else "")
    if ver is None:
        err(f"{path}: version {version!r} must be strict SemVer (X.Y.Z)")
    if expect_version and version != expect_version:
        err(f"{path}: version {version!r} does not match expected {expect_version!r} (tag/manifest mismatch)")
    if bump_from:
        try:
            old = load_yaml(bump_from) or {}
        except yaml.YAMLError as e:
            err(f"{bump_from}: base manifest unreadable: {e}")
            old = {}
        old_ver = parse_semver(old.get("version", ""))
        if ver is not None and old_ver is not None and ver <= old_ver:
            err(f"{path}: recipe content changed but version {version} does not bump past base {old.get('version')}")

    if not (isinstance(manifest.get("description"), str) and manifest["description"].strip()):
        err(f"{path}: description is required and must be non-empty")
    if "tags" in manifest and not (
        isinstance(manifest["tags"], list) and all(isinstance(t, str) for t in manifest["tags"])
    ):
        err(f"{path}: tags must be a list of strings")
    if "minVakaVersion" in manifest and parse_semver(str(manifest["minVakaVersion"])) is None:
        err(f"{path}: minVakaVersion must be strict SemVer (X.Y.Z)")

    for i, entry in enumerate(manifest.get("env") or []):
        where = f"{path}: env[{i}]"
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
            err(f"{where}: each env entry needs a string 'name'")
            continue
        for k in sorted(set(entry) - ENV_ENTRY_KEYS):
            err(f"{where}: unknown field {k!r}")

    for i, entry in enumerate(manifest.get("riskAcknowledgements") or []):
        where = f"{path}: riskAcknowledgements[{i}]"
        if not isinstance(entry, dict) or not isinstance(entry.get("flag"), str) \
                or not (isinstance(entry.get("reason"), str) and entry["reason"].strip()):
            err(f"{where}: each acknowledgement needs a 'flag' and a non-empty 'reason'")
            continue
        for k in sorted(set(entry) - ACK_ENTRY_KEYS):
            err(f"{where}: unknown field {k!r}")

    return manifest


def check_tree(recipe_dir):
    if not os.path.isfile(os.path.join(recipe_dir, "README.md")):
        err(f"{recipe_dir}: README.md is required")
    if not os.path.isfile(os.path.join(recipe_dir, "vaka.yaml")):
        err(f"{recipe_dir}: vaka.yaml is required")

    root = os.path.realpath(recipe_dir)
    for cur, dirs, files in os.walk(recipe_dir, followlinks=False):
        for entry in dirs + files:
            full = os.path.join(cur, entry)
            rel = os.path.relpath(full, recipe_dir)
            if entry.startswith(".vaka-"):
                err(f"{rel}: the .vaka-* namespace is reserved for vaka's own state; recipes must not ship such paths")
            if entry == ".env":
                err(f"{rel}: committed .env files are forbidden; ship a .env.example instead")
            if os.path.islink(full):
                target = os.readlink(full)
                if os.path.isabs(target):
                    err(f"{rel}: absolute symlink targets are forbidden ({target})")
                elif not os.path.realpath(full).startswith(root + os.sep):
                    err(f"{rel}: symlink escapes the recipe directory ({target})")


def first_existing(recipe_dir, names):
    for name in names:
        if os.path.exists(os.path.join(recipe_dir, name)):
            return name
    return None


def compose_file(recipe_dir):
    base = first_existing(recipe_dir, COMPOSE_FILES)
    if base is None:
        err(f"{recipe_dir}: no compose file found (looked for {', '.join(COMPOSE_FILES)})")
    return base


def compose_files(recipe_dir):
    """Base file plus its override, chosen with compose-go's exact precedence
    (base and override selected independently) — so the risk lint sees exactly
    what `vaka up` runs, including the override."""
    base = first_existing(recipe_dir, COMPOSE_FILES)
    if base is None:
        return []
    files = [base]
    override = first_existing(recipe_dir, COMPOSE_OVERRIDE_FILES)
    if override is not None:
        files.append(override)
    return files


def rendered_compose(recipe_dir):
    files = compose_files(recipe_dir)
    label = "+".join(files) if files else "compose"
    args = ["docker", "compose"]
    for f in files:
        args += ["-f", f]
    args += ["config", "--format", "json"]
    proc = subprocess.run(args, cwd=recipe_dir, capture_output=True, text=True)
    if proc.returncode != 0:
        err(f"{recipe_dir}/{label}: docker compose config failed:\n{proc.stderr.strip()}")
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        err(f"{recipe_dir}/{label}: docker compose config emitted invalid JSON: {e}")
        return None


def labels_of(svc):
    labels = svc.get("labels") or {}
    if isinstance(labels, list):
        return dict(l.split("=", 1) if "=" in l else (l, "") for l in labels)
    return labels


def risk_lint(recipe_dir, config, policy):
    """Return the list of risk flags as 'service:flag' strings."""
    flags = []

    def flag(svc, name):
        flags.append(f"{svc}:{name}")

    services = (config or {}).get("services") or {}
    policy_services = (policy or {}).get("services") or {}

    for svc_name, svc in sorted(services.items()):
        if svc.get("privileged"):
            flag(svc_name, "privileged")
        for cap in svc.get("cap_add") or []:
            if cap.upper().removeprefix("CAP_") in BROAD_CAPS:
                flag(svc_name, "cap-add-broad")
                break
        if svc.get("network_mode") == "host":
            flag(svc_name, "host-network")
        if svc.get("pid") == "host":
            flag(svc_name, "host-pid")
        if svc.get("ipc") == "host":
            flag(svc_name, "host-ipc")
        for vol in svc.get("volumes") or []:
            if not isinstance(vol, dict) or vol.get("type") != "bind":
                continue
            src = os.path.normpath(vol.get("source") or "")
            if src == "/var/run/docker.sock" or (vol.get("target") == "/var/run/docker.sock"):
                flag(svc_name, "docker-socket-mount")
            elif src in BROAD_MOUNT_SOURCES:
                flag(svc_name, "broad-bind-mount")
        if labels_of(svc).get(VAKA_INIT_LABEL) == "present":
            flag(svc_name, "disables-vaka-init")
        image = svc.get("image") or ""
        if image and "@sha256:" not in image:
            flag(svc_name, "unpinned-image")

        pol = policy_services.get(svc_name)
        if pol is None:
            flag(svc_name, "no-policy-for-service")
        else:
            egress = ((pol.get("network") or {}).get("egress") or {})
            if egress.get("defaultAction") == "accept":
                flag(svc_name, "egress-default-accept")

    return sorted(set(flags))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("recipe_dir")
    ap.add_argument("--require-bump-from", metavar="OLD_RECIPE_YAML",
                    help="base manifest; the version must bump past it")
    ap.add_argument("--expect-version", metavar="X.Y.Z",
                    help="require the manifest version to equal this (tag check)")
    ap.add_argument("--summary-json", metavar="OUT",
                    help="write the index policy summary (defaultActions, riskFlags)")
    ap.add_argument("--compose-config", metavar="JSON",
                    help="pre-rendered `docker compose config --format json` output "
                         "(otherwise docker compose is invoked)")
    ap.add_argument("--print-compose-files", action="store_true",
                    help="print the base+override compose files (one per line) and exit; "
                         "the single source of truth for the workflows' vaka validate")
    args = ap.parse_args()

    recipe_dir = args.recipe_dir.rstrip("/")

    if args.print_compose_files:
        for f in compose_files(recipe_dir):
            print(f)
        return 0
    manifest = check_manifest(recipe_dir, args.expect_version, args.require_bump_from)
    check_tree(recipe_dir)

    config = None
    cf = compose_file(recipe_dir)
    if args.compose_config:
        with open(args.compose_config, encoding="utf-8") as f:
            config = json.load(f)
    elif cf:
        config = rendered_compose(recipe_dir)

    policy = None
    vaka_yaml = os.path.join(recipe_dir, "vaka.yaml")
    if os.path.isfile(vaka_yaml):
        try:
            policy = load_yaml(vaka_yaml)
        except yaml.YAMLError as e:
            err(f"{vaka_yaml}: not valid YAML: {e}")

    flags = risk_lint(recipe_dir, config, policy) if config else []
    acked = {a["flag"] for a in (manifest or {}).get("riskAcknowledgements") or []
             if isinstance(a, dict) and isinstance(a.get("flag"), str)}
    for f in flags:
        flag_name = f.split(":", 1)[1]
        if flag_name in ADVISORY_FLAGS:
            warn(f"{recipe_dir}: advisory risk flag {f} (surfaced to users; not a CI failure)")
        elif flag_name in acked:
            warn(f"{recipe_dir}: risk flag {f} is acknowledged in recipe.yaml")
        else:
            err(f"{recipe_dir}: risk flag {f} is not acknowledged in riskAcknowledgements")
    for a in sorted(acked - {f.split(':', 1)[1] for f in flags}):
        warn(f"{recipe_dir}: riskAcknowledgements declares {a!r} but the lint did not find it (stale acknowledgement?)")

    if args.summary_json and config is not None and policy is not None:
        default_actions = {}
        for svc_name in sorted((config.get("services") or {})):
            pol = ((policy.get("services") or {}).get(svc_name) or {})
            egress = ((pol.get("network") or {}).get("egress") or {})
            default_actions[svc_name] = egress.get("defaultAction", "none")
        with open(args.summary_json, "w", encoding="utf-8") as f:
            json.dump({"defaultActions": default_actions, "riskFlags": flags}, f, indent=2)

    if errors:
        print(f"{recipe_dir}: FAILED with {len(errors)} error(s), {len(warnings)} warning(s)")
        return 1
    print(f"{recipe_dir}: OK ({len(warnings)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
