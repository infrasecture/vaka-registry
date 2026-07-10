#!/usr/bin/env python3
"""Add one released recipe version to the registry index (index.yaml).

The index is the distribution catalog served over HTTPS (GitHub Pages);
format per the registry design:
https://github.com/infrasecture/vaka/blob/main/docs/design/recipes-registry.md

Only the most recent --keep versions per recipe stay in the index; older
versions remain downloadable via their release URLs.
"""

import argparse
import datetime
import re
import sys

import yaml

API_VERSION = "recipes.vaka/v1alpha1"
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def parse_semver(s):
    m = SEMVER_RE.match(s or "")
    if not m:
        raise SystemExit(f"error: {s!r} is not strict SemVer (X.Y.Z)")
    return tuple(int(g) for g in m.groups())


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--index", required=True, help="path to index.yaml (created if missing)")
    ap.add_argument("--name", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--digest", required=True, help="sha256:<hex> of the release tarball")
    ap.add_argument("--url", required=True, help="download URL of the release tarball")
    ap.add_argument("--recipe-yaml", required=True, help="the released recipe's manifest")
    ap.add_argument("--summary-json", help="policy summary emitted by validate_recipe.py")
    ap.add_argument("--keep", type=int, default=5, help="index at most N versions per recipe")
    args = ap.parse_args()

    parse_semver(args.version)
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.digest):
        raise SystemExit(f"error: digest {args.digest!r} must be sha256:<64 hex>")

    with open(args.recipe_yaml, encoding="utf-8") as f:
        manifest = yaml.safe_load(f)
    if manifest.get("name") != args.name or manifest.get("version") != args.version:
        raise SystemExit(
            f"error: manifest says {manifest.get('name')}@{manifest.get('version')}, "
            f"expected {args.name}@{args.version}"
        )

    try:
        with open(args.index, encoding="utf-8") as f:
            index = yaml.safe_load(f) or {}
    except FileNotFoundError:
        index = {}
    index.setdefault("apiVersion", API_VERSION)
    index.setdefault("kind", "RegistryIndex")
    index.setdefault("recipes", {})
    if index["apiVersion"] != API_VERSION or index.get("kind") != "RegistryIndex":
        raise SystemExit(f"error: {args.index} is not a {API_VERSION} RegistryIndex")

    entry = {
        "version": args.version,
        "description": manifest.get("description", ""),
        "tags": manifest.get("tags", []),
        "created": now_utc(),
        "digest": args.digest,
        "urls": [args.url],
    }
    if "minVakaVersion" in manifest:
        entry["minVakaVersion"] = manifest["minVakaVersion"]
    if "env" in manifest:
        entry["env"] = manifest["env"]
    if args.summary_json:
        import json
        with open(args.summary_json, encoding="utf-8") as f:
            entry["policy"] = json.load(f)

    versions = index["recipes"].setdefault(args.name, [])
    if any(v.get("version") == args.version for v in versions):
        raise SystemExit(
            f"error: {args.name}@{args.version} is already indexed; "
            f"published versions are immutable — bump the version instead"
        )
    versions.append(entry)
    versions.sort(key=lambda v: parse_semver(v["version"]), reverse=True)
    del versions[args.keep:]

    index["generated"] = now_utc()
    with open(args.index, "w", encoding="utf-8") as f:
        yaml.safe_dump(index, f, sort_keys=False)
    print(f"indexed {args.name}@{args.version} ({args.digest}); "
          f"{len(versions)} version(s) of {args.name} in index")
    return 0


if __name__ == "__main__":
    sys.exit(main())
