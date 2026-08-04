#!/usr/bin/env python3
"""Regression checks for rendered Codex orchestration invariants."""

import json
import os
from pathlib import Path
import subprocess

recipe_dir = Path(__file__).resolve().parent.parent
env = os.environ.copy()
env.setdefault("OPENAI_API_KEY", "test-provider-key")
env.setdefault("LITELLM_MASTER_KEY", "test-proxy-key")
render = subprocess.run(
    ["docker", "compose", "config", "--format", "json"],
    cwd=recipe_dir,
    env=env,
    check=True,
    capture_output=True,
    text=True,
)
compose = json.loads(render.stdout)

codex_image = compose.get("services", {}).get("codex", {}).get("image")
expected_codex_image = "ghcr.io/infrasecture/harness-workstation:0.146.0"
if codex_image != expected_codex_image:
    raise SystemExit(
        f"FAIL: codex image is {codex_image!r}, want SemVer reference "
        f"{expected_codex_image!r} without a digest pin"
    )

try:
    condition = compose["services"]["codex"]["depends_on"]["litellm"]["condition"]
except (KeyError, TypeError) as exc:
    raise SystemExit(
        "FAIL: codex must declare a long-form dependency on litellm"
    ) from exc

if condition != "service_started":
    raise SystemExit(
        f"FAIL: codex -> litellm dependency is {condition!r}, want 'service_started'"
    )

print("PASS: codex uses a SemVer image and waits for LiteLLM to start")
