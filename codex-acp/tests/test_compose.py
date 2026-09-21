#!/usr/bin/env python3
"""Regression checks for rendered Codex orchestration invariants."""

import json
import os
from pathlib import Path
import subprocess

recipe_dir = Path(__file__).resolve().parent.parent


def render(overlays=None, extra_env=None, image_contract=True):
    env = os.environ.copy()
    env.setdefault("OPENAI_API_KEY", "test-provider-key")
    env.setdefault("LITELLM_MASTER_KEY", "test-proxy-key")
    if image_contract:
        env["MYCODEX_IMAGE_NAME"] = "registry.invalid/mycodex-contract-test"
        env["MYCODEX_IMAGE_TAG"] = "9.8.7-r6"
    else:
        env.pop("MYCODEX_IMAGE_NAME", None)
        env.pop("MYCODEX_IMAGE_TAG", None)
    env["CODEX_BYOBU_SESSION"] = "recipe-test-session"
    if extra_env:
        env.update(extra_env)
    args = ["docker", "compose", "-f", "docker-compose.yaml"]
    for overlay in overlays or []:
        args += ["-f", overlay]
    args += ["config", "--format", "json"]
    proc = subprocess.run(
        args, cwd=recipe_dir, env=env, check=True, capture_output=True, text=True
    )
    return json.loads(proc.stdout)


def litellm_config_mount(compose):
    for vol in compose["services"]["litellm"].get("volumes", []):
        if vol.get("target") == "/app/config.yaml":
            return vol
    raise SystemExit("FAIL: litellm has no /app/config.yaml mount")


def has_mount(svc, target):
    return any(v.get("target") == target for v in svc.get("volumes", []))


def codex_label(compose, key):
    return compose["services"]["codex"].get("labels", {}).get(key)


def assert_credential_boundary(compose, profile):
    codex_env = compose["services"]["codex"].get("environment", {})
    litellm_env = compose["services"]["litellm"].get("environment", {})
    forbidden = {
        "LITELLM_MASTER_KEY",
        "OPENAI_API_KEY",
        "GOOGLE_APPLICATION_CREDENTIALS",
    }
    leaked = sorted(forbidden.intersection(codex_env))
    if leaked:
        raise SystemExit(
            f"FAIL: {profile} Codex environment contains privileged credential(s): {leaked}"
        )
    if codex_env.get("MYCODEX_GATEWAY_TOKEN") != "mycodex-agent-v1":
        raise SystemExit(f"FAIL: {profile} Codex does not use the restricted gateway token")
    if litellm_env.get("LITELLM_MASTER_KEY") != "test-proxy-key":
        raise SystemExit(f"FAIL: {profile} LiteLLM did not receive its administrator key")
    if codex_label(compose, "agent.vaka.codex.gateway-auth") != "restricted-v1":
        raise SystemExit(f"FAIL: {profile} Codex lacks the restricted-auth contract label")
    litellm_label = compose["services"]["litellm"].get("labels", {}).get(
        "agent.vaka.codex.gateway-auth"
    )
    if litellm_label != "restricted-v1":
        raise SystemExit(f"FAIL: {profile} LiteLLM lacks the restricted-auth contract label")
    if not has_mount(compose["services"]["litellm"], "/app/litellm_agent_auth.py"):
        raise SystemExit(f"FAIL: {profile} LiteLLM does not mount the agent auth policy")


# --- default (openai) profile: the CI-audited artifact --------------------
compose = render()
assert_credential_boundary(compose, "openai")

codex_image = compose.get("services", {}).get("codex", {}).get("image")
expected_codex_image = "registry.invalid/mycodex-contract-test:9.8.7-r6"
if codex_image != expected_codex_image:
    raise SystemExit(
        f"FAIL: codex image is {codex_image!r}, want SemVer reference "
        f"{expected_codex_image!r} supplied by the launcher contract"
    )

codex_service = compose["services"]["codex"]
build = codex_service.get("build") or {}
if not str(build.get("context", "")).endswith("/codex-acp"):
    raise SystemExit("FAIL: codex-acp service does not build from the recipe context")
if build.get("dockerfile") != "Dockerfile":
    raise SystemExit("FAIL: codex-acp service does not use the distributed Dockerfile")
if "NET_ADMIN" not in (codex_service.get("cap_drop") or []):
    raise SystemExit("FAIL: codex-acp service does not explicitly drop NET_ADMIN")
if "no-new-privileges:true" not in (codex_service.get("security_opt") or []):
    raise SystemExit("FAIL: codex-acp service does not enable no-new-privileges")
socket_path = (codex_service.get("environment") or {}).get("CODEX_ACP_SOCKET", "")
if not socket_path.endswith("/.codex/run/codex-acp.sock"):
    raise SystemExit(f"FAIL: unexpected ACP broker socket path: {socket_path!r}")
if (codex_service.get("environment") or {}).get("NO_BROWSER") != "1":
    raise SystemExit("FAIL: ACP adapter can initiate an in-container browser flow")

unwrapped = render(image_contract=False)
unwrapped_image = unwrapped["services"]["codex"].get("image")
expected_unwrapped_image = (
    "invalid.invalid/mycodex-wrapper-required:wrapper-required"
)
if unwrapped_image != expected_unwrapped_image:
    raise SystemExit(
        f"FAIL: unwrapped codex image is {unwrapped_image!r}, want fail-closed "
        f"placeholder {expected_unwrapped_image!r}"
    )

codex_session = compose["services"]["codex"].get("environment", {}).get(
    "CODEX_BYOBU_SESSION"
)
if codex_session != "recipe-test-session":
    raise SystemExit(
        f"FAIL: codex session is {codex_session!r}, want launcher-selected "
        "'recipe-test-session'"
    )

if codex_label(compose, "agent.vaka.codex.auth-profile") != "openai":
    raise SystemExit("FAIL: default codex container is not labeled with the openai profile")

try:
    condition = compose["services"]["codex"]["depends_on"]["litellm"]["condition"]
except (KeyError, TypeError) as exc:
    raise SystemExit("FAIL: codex must declare a long-form dependency on litellm") from exc

if condition != "service_started":
    raise SystemExit(
        f"FAIL: codex -> litellm dependency is {condition!r}, want 'service_started'"
    )

default_cfg = litellm_config_mount(compose)["source"]
if not default_cfg.endswith("/litellm.config.yaml") or "auth-profiles" in default_cfg:
    raise SystemExit(
        f"FAIL: default litellm config source is {default_cfg!r}, want the root config"
    )

# --- chatgpt profile: overlay adds the rw token mount + swaps config -------
chatgpt = render(
    overlays=["auth-profiles/chatgpt/overlay.yaml"],
    extra_env={
        "MYCODEX_AUTH": "chatgpt",
        "MYCODEX_LITELLM_CONFIG": "./auth-profiles/chatgpt/litellm.config.yaml",
    },
)
assert_credential_boundary(chatgpt, "chatgpt")
if codex_label(chatgpt, "agent.vaka.codex.auth-profile") != "chatgpt":
    raise SystemExit("FAIL: chatgpt render did not stamp the chatgpt profile label")
if not has_mount(chatgpt["services"]["litellm"], "/var/lib/litellm/chatgpt-token"):
    raise SystemExit("FAIL: chatgpt overlay does not mount the token dir into litellm")
cg_cfg = litellm_config_mount(chatgpt)["source"]
if not cg_cfg.endswith("/auth-profiles/chatgpt/litellm.config.yaml"):
    raise SystemExit(f"FAIL: chatgpt litellm config source is {cg_cfg!r}")
cg_env = chatgpt["services"]["litellm"].get("environment", {})
if cg_env.get("CHATGPT_TOKEN_DIR") != "/var/lib/litellm/chatgpt-token":
    raise SystemExit("FAIL: chatgpt overlay does not set CHATGPT_TOKEN_DIR")
# The agent must be untouched by the overlay.
if chatgpt["services"]["codex"].get("image") != expected_codex_image:
    raise SystemExit("FAIL: chatgpt overlay altered the codex image")

# --- vertex profile (scaffold): credential-file mount + env ----------------
vertex = render(
    overlays=["auth-profiles/vertex/overlay.yaml"],
    extra_env={
        "MYCODEX_LITELLM_CONFIG": "./auth-profiles/vertex/litellm.config.yaml",
        "MYCODEX_CREDENTIAL_FILE": "/tmp/vertex-sa.json",
        "VERTEXAI_PROJECT": "demo-project",
    },
)
assert_credential_boundary(vertex, "vertex")
if not has_mount(vertex["services"]["litellm"], "/etc/vaka/credentials/vertex.json"):
    raise SystemExit("FAIL: vertex overlay does not mount the credential file into litellm")
vx_env = vertex["services"]["litellm"].get("environment", {})
if vx_env.get("GOOGLE_APPLICATION_CREDENTIALS") != "/etc/vaka/credentials/vertex.json":
    raise SystemExit("FAIL: vertex overlay does not set GOOGLE_APPLICATION_CREDENTIALS")
if vx_env.get("VERTEXAI_PROJECT") != "demo-project":
    raise SystemExit("FAIL: vertex overlay did not pass VERTEXAI_PROJECT through")

print("PASS: default artifact intact; chatgpt and vertex overlays render correctly")
