"""Least-privilege authentication for the embedded myCodex LiteLLM gateway."""

import os
import secrets
from typing import Final

from fastapi import Request
from litellm.proxy._types import (
    LitellmUserRoles,
    ProxyException,
    UserAPIKeyAuth,
)


# The agent receives only the capability it inherently needs: model inference
# through this embedded gateway. Keep this table exact; never grant the agent a
# wildcard path or an administrative LiteLLM role.
AGENT_ROUTES: Final[frozenset[tuple[str, str]]] = frozenset(
    {
        ("GET", "/v1/models"),
        ("POST", "/v1/responses"),
        ("POST", "/v1/responses/compact"),
        ("GET", "/v1/responses/{response_id}"),
        ("DELETE", "/v1/responses/{response_id}"),
        ("GET", "/v1/responses/{response_id}/input_items"),
        ("POST", "/v1/responses/{response_id}/cancel"),
        ("POST", "/v1/alpha/search"),
    }
)


def _required_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name} must be set for LiteLLM gateway authentication")
    return value


AGENT_TOKEN: Final = _required_env("MYCODEX_GATEWAY_TOKEN")
MASTER_KEY: Final = _required_env("LITELLM_MASTER_KEY")
if secrets.compare_digest(AGENT_TOKEN, MASTER_KEY):
    raise RuntimeError("MYCODEX_GATEWAY_TOKEN must differ from LITELLM_MASTER_KEY")


def _reject(message: str, code: int) -> None:
    raise ProxyException(
        message=message,
        type="authentication_error" if code == 401 else "permission_error",
        param="api_key",
        code=code,
    )


def _request_route_template(request: Request) -> str | None:
    """Return FastAPI's dispatched route, never a caller-controlled URL."""
    scope = request.scope
    if not isinstance(scope, dict):
        return None
    route = scope.get("route")
    path = getattr(route, "path", None)
    return path if isinstance(path, str) and path else None


async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    """Authenticate gateway administrators and the route-limited Codex client."""
    if api_key and secrets.compare_digest(api_key, MASTER_KEY):
        return UserAPIKeyAuth(
            api_key=api_key,
            user_id="mycodex-gateway-admin",
            user_role=LitellmUserRoles.PROXY_ADMIN,
        )

    if not api_key or not secrets.compare_digest(api_key, AGENT_TOKEN):
        _reject("Invalid gateway credential", 401)

    route = _request_route_template(request)
    method = request.method.upper()
    if route is None or (method, route) not in AGENT_ROUTES:
        _reject("The Codex client cannot access this gateway route", 403)

    return UserAPIKeyAuth(
        api_key=api_key,
        user_id="mycodex-agent",
        user_role=LitellmUserRoles.INTERNAL_USER,
    )
