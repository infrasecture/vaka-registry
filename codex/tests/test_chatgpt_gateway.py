#!/usr/bin/env python3
"""Contract test for the pinned LiteLLM ChatGPT Responses adapter."""

import importlib.metadata
import inspect
from itertools import product
import sys

import litellm
import yaml
from litellm.llms.chatgpt.responses.transformation import ChatGPTResponsesAPIConfig
from litellm.responses.utils import ResponsesAPIRequestUtils
from litellm.types.router import GenericLiteLLMParams
from patch_chatgpt import ALLOWED, INSTRUCTIONS, PRESERVE, WITH_CACHE, patch_source


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


def check_source_patch():
    # Use the installed adapter as the fixture so upstream source drift is visible.
    patched = inspect.getsource(sys.modules[ChatGPTResponsesAPIConfig.__module__])
    if patch_source(patched) != patched:
        fail("source patch is not idempotent on the installed adapter")
    original = patched.replace(PRESERVE, INSTRUCTIONS).replace(WITH_CACHE, ALLOWED)
    if patch_source(original) != patched:
        fail("source patch does not reproduce the installed adapter")
    incompatible = (
        original.replace('get_chatgpt_default_instructions()', 'changed_default()'),
        original.replace('            "truncation",', '            "unknown_field",'),
        original + INSTRUCTIONS,
        original.replace(INSTRUCTIONS, PRESERVE),
        original.replace(ALLOWED, WITH_CACHE),
        patched.replace('            "prompt_cache_key",\n', ''),
    )
    for source in incompatible:
        try:
            patch_source(source)
        except RuntimeError:
            continue
        fail("source patch accepted an incompatible or partial adapter")


def check_instructions_and_cache(adapter):
    absent = object()
    checked = 0
    for model, instructions, cache_key in product(
        EXPECTED_EFFORTS,
        ("Caller instructions.\nPreserve spacing. ", "", absent),
        ("thread-one", "thread-one", "thread-two", "", absent),
    ):
        params = {}
        if instructions is not absent:
            params["instructions"] = instructions
        if cache_key is not absent:
            params["prompt_cache_key"] = cache_key
        requested = ResponsesAPIRequestUtils.get_requested_response_api_optional_param(params)
        mapped = ResponsesAPIRequestUtils.get_optional_params_responses_api(
            f"chatgpt/{model}", adapter, requested
        )
        headers = {"session_id": "generated-fallback", "x-test": "unchanged"}
        outbound = adapter.transform_responses_api_request(
            f"chatgpt/{model}", "contract test", mapped, GenericLiteLLMParams(), headers
        )
        if outbound.get("instructions", absent) != instructions:
            fail(f"{model} instructions changed, including empty/absent semantics")
        if outbound.get("prompt_cache_key", absent) != cache_key:
            fail(f"{model} prompt_cache_key changed or was dropped")
        expected_session = cache_key if isinstance(cache_key, str) and cache_key else "generated-fallback"
        if headers != {"session_id": expected_session, "x-test": "unchanged"}:
            fail(f"{model} cache affinity or unrelated headers changed")
        if outbound.get("store") is not False or outbound.get("stream") is not True:
            fail(f"{model} upstream store/stream requirements changed")
        if "reasoning.encrypted_content" not in outbound.get("include", []):
            fail(f"{model} encrypted reasoning inclusion changed")
        checked += 1
    print(f"PASS: caller instructions and cache affinity ({checked} combinations); patch drift checks")


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
    check_source_patch()
    check_instructions_and_cache(adapter)
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
