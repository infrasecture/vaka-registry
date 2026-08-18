#!/usr/bin/env python3
"""Contract tests for the embedded LiteLLM gateway credential boundary."""

import asyncio
import importlib.util
import os
import sys
from dataclasses import dataclass

import yaml
from litellm.proxy._types import LitellmUserRoles, ProxyException


AGENT_TOKEN = "mycodex-agent-v1"
MASTER_KEY = "test-gateway-master"


@dataclass
class Route:
    path: str


class Request:
    def __init__(self, method, route, *, path=None, host=None):
        self.method = method
        self.scope = {
            "route": Route(route) if route is not None else None,
            "path": path or route or "/",
            "headers": [(b"host", (host or "litellm").encode())],
        }


def fail(message):
    raise SystemExit(f"FAIL: {message}")


def load_auth(path):
    os.environ["MYCODEX_GATEWAY_TOKEN"] = AGENT_TOKEN
    os.environ["LITELLM_MASTER_KEY"] = MASTER_KEY
    spec = importlib.util.spec_from_file_location("litellm_agent_auth", path)
    if spec is None or spec.loader is None:
        fail(f"cannot load auth module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


async def authorize(module, method, route, key, **kwargs):
    return await module.user_api_key_auth(Request(method, route, **kwargs), key)


async def expect_denied(module, method, route, key, code, **kwargs):
    try:
        await authorize(module, method, route, key, **kwargs)
    except ProxyException as exc:
        if int(exc.code) != code:
            fail(f"{method} {route} returned {exc.code}, expected {code}")
        return
    fail(f"{method} {route} unexpectedly accepted the agent credential")


async def main():
    module = load_auth(sys.argv[1])

    for method, route in module.AGENT_ROUTES:
        identity = await authorize(module, method, route, AGENT_TOKEN)
        if identity.user_role != LitellmUserRoles.INTERNAL_USER:
            fail(f"agent route {method} {route} received role {identity.user_role}")

    identity = await authorize(module, "POST", "/key/generate", MASTER_KEY)
    if identity.user_role != LitellmUserRoles.PROXY_ADMIN:
        fail("gateway master key did not retain administrator access")

    await expect_denied(module, "POST", "/v1/responses", "wrong", 401)
    await expect_denied(module, "GET", "/key/list", AGENT_TOKEN, 403)
    await expect_denied(module, "POST", "/key/generate", AGENT_TOKEN, 403)
    await expect_denied(module, "GET", "/config/yaml", AGENT_TOKEN, 403)
    await expect_denied(module, "GET", "/team/list", AGENT_TOKEN, 403)
    await expect_denied(module, "GET", "/v1/responses", AGENT_TOKEN, 403)
    await expect_denied(module, "POST", None, AGENT_TOKEN, 403)

    # Auth decisions use FastAPI's dispatched route template. A malformed Host
    # or misleading literal path cannot turn a management request into an
    # allowlisted inference route (or vice versa).
    await expect_denied(
        module,
        "POST",
        "/key/generate",
        AGENT_TOKEN,
        403,
        path="/v1/responses",
        host="litellm/?route=/v1/responses",
    )

    for config_path in sys.argv[2:]:
        with open(config_path, encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
        settings = config.get("general_settings", {})
        if settings.get("custom_auth") != "litellm_agent_auth.user_api_key_auth":
            fail(f"{config_path} does not select the recipe auth policy")
        if settings.get("custom_auth_run_common_checks") is not True:
            fail(f"{config_path} does not retain LiteLLM common authorization checks")

    print("PASS: Codex credential is restricted to the explicit inference-route contract")


if __name__ == "__main__":
    asyncio.run(main())
