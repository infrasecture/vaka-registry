#!/usr/bin/env python3
"""Contract test for the pinned LiteLLM ChatGPT Responses adapter."""

import importlib.metadata
import sys

import litellm
import yaml
from litellm.llms.chatgpt.responses.transformation import ChatGPTResponsesAPIConfig
from litellm.responses.utils import ResponsesAPIRequestUtils
from litellm.types.router import GenericLiteLLMParams


EXPECTED_EFFORTS = {
    "gpt-6-sol": ("low", "medium", "high", "xhigh", "max"),
    "gpt-6-luna": ("low", "medium", "high", "xhigh", "max"),
    "gpt-6-astra": ("low", "medium", "high", "xhigh", "max"),
    "gpt-5.6-sol": ("low", "medium", "high", "xhigh", "max"),
    "gpt-5.6-terra": ("low", "medium", "high", "xhigh", "max"),
    "gpt-5.6-luna": ("low", "medium", "high", "xhigh", "max"),
    "gpt-5.5": ("low", "medium", "high", "xhigh"),
    "gpt-5.2": ("low", "medium", "high", "xhigh"),
}


def fail(message):
    raise SystemExit(f"FAIL: {message}")


def main():
    version = importlib.metadata.version("litellm")
    if version != "1.104.0":
        fail(f"LiteLLM version is {version}, expected audited pre-release 1.104.0")

    for model in ("gpt-6-sol", "gpt-6-luna"):
        info = litellm.get_model_info(model)
        if info.get("key") != model or info.get("litellm_provider") != "openai":
            fail(f"bundled model metadata is missing or invalid for {model}: {info!r}")
        if "/v1/responses" not in info.get("supported_endpoints", []):
            fail(f"bundled model metadata does not advertise Responses for {model}")
        for capability in (
            "supports_none_reasoning_effort",
            "supports_xhigh_reasoning_effort",
            "supports_max_reasoning_effort",
        ):
            if info.get(capability) is not True:
                fail(f"bundled model metadata does not advertise {capability} for {model}")

    with open(sys.argv[1], encoding="utf-8") as stream:
        config = yaml.safe_load(stream)

    routes = config.get("model_list", [])
    by_name = {route.get("model_name"): route for route in routes}
    if set(by_name) != set(EXPECTED_EFFORTS):
        fail(f"ChatGPT routes are {sorted(by_name)}, expected {sorted(EXPECTED_EFFORTS)}")

    for model, route in by_name.items():
        if route.get("model_info", {}).get("mode") != "responses":
            fail(f"{model} is not configured for the Responses API")
        target = route.get("litellm_params", {}).get("model")
        if target != f"chatgpt/{model}":
            fail(f"{model} routes to {target!r}")

    if config.get("litellm_settings", {}).get("drop_params") is not False:
        fail("drop_params must be false so the generic layer cannot silently drop fields")

    tools = [
        {
            "type": "function",
            "name": "shell",
            "description": "Run a command",
            "strict": False,
            "parameters": {"type": "object", "properties": {}},
        },
        {
            "type": "custom",
            "name": "apply_patch",
            "description": "Apply a patch",
            "format": {
                "type": "grammar",
                "syntax": "lark",
                "definition": "start: /.+/",
            },
        },
        {
            "type": "web_search",
            "external_web_access": True,
            "indexed_web_access": True,
            "filters": {"allowed_domains": ["example.com"]},
            "user_location": {"type": "approximate", "country": "PL"},
            "search_context_size": "high",
            "search_content_types": ["text", "image"],
        },
    ]

    litellm.drop_params = False
    adapter = ChatGPTResponsesAPIConfig()
    checked = 0
    for model, efforts in EXPECTED_EFFORTS.items():
        for effort in efforts:
            requested = ResponsesAPIRequestUtils.get_requested_response_api_optional_param(
                {
                    "reasoning": {"effort": effort},
                    "tools": tools,
                    "tool_choice": "auto",
                    "include": ["web_search_call.results"],
                }
            )
            mapped = ResponsesAPIRequestUtils.get_optional_params_responses_api(
                f"chatgpt/{model}", adapter, requested
            )
            outbound = adapter.transform_responses_api_request(
                f"chatgpt/{model}",
                "contract test",
                mapped,
                GenericLiteLLMParams(),
                {},
            )
            if outbound.get("reasoning") != {"effort": effort}:
                fail(f"{model}/{effort} reasoning was changed or dropped")
            if outbound.get("tools") != tools:
                fail(f"{model}/{effort} tools were changed or dropped")
            if outbound.get("tool_choice") != "auto":
                fail(f"{model}/{effort} tool_choice was changed or dropped")
            if "web_search_call.results" not in outbound.get("include", []):
                fail(f"{model}/{effort} web-search result inclusion was dropped")
            checked += 1

    print(
        f"PASS: pinned LiteLLM routes all {len(EXPECTED_EFFORTS)} ChatGPT models and preserves "
        f"reasoning plus function/custom/web-search tools ({checked} combinations)"
    )


if __name__ == "__main__":
    main()
