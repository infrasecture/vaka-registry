"""Preserve caller instructions and cache affinity in the pinned ChatGPT adapter."""

import importlib.util
from itertools import product
from pathlib import Path


INSTRUCTIONS = '''        base_instructions: Final = get_chatgpt_default_instructions()
        existing_instructions: Final = request.get("instructions")
        if existing_instructions:
            if base_instructions not in existing_instructions:
                request["instructions"] = f"{base_instructions}\\n\\n{existing_instructions}"
        else:
            request["instructions"] = base_instructions
'''
PRESERVE = '''        # Preserve caller instructions verbatim, including empty or absent values.
        cache_key = request.get("prompt_cache_key")
        if isinstance(cache_key, str) and cache_key:
            headers["session_id"] = cache_key
'''
ALLOWED = '''            "previous_response_id",
            "truncation",
        }
'''
WITH_CACHE = '''            "previous_response_id",
            "truncation",
            "prompt_cache_key",
        }
'''


def patch_source(source: str) -> str:
    """Accept the audited adapter or our complete patch; reject partial changes."""
    originals = (INSTRUCTIONS, ALLOWED)
    replacements = (PRESERVE, WITH_CACHE)
    if all(source.count(block) == 1 for block in replacements) and all(
        block not in source for block in originals
    ):
        return source
    if not all(source.count(block) == 1 for block in originals) or any(
        block in source for block in replacements
    ):
        raise RuntimeError("Unrecognized LiteLLM ChatGPT adapter; review before building")
    for original, replacement in zip(originals, replacements):
        source = source.replace(original, replacement, 1)
    compile(source, "ChatGPT adapter", "exec")
    return source


def main() -> None:
    spec = importlib.util.find_spec("litellm")
    if spec is None or spec.origin is None:
        raise RuntimeError("LiteLLM package not found")
    path = Path(spec.origin).parent / "llms/chatgpt/responses/transformation.py"
    path.write_text(patch_source(path.read_text()))
    # Exercise the installed adapter without authentication or model calls.
    from litellm.llms.chatgpt.responses.transformation import ChatGPTResponsesAPIConfig
    from litellm.types.router import GenericLiteLLMParams

    adapter = ChatGPTResponsesAPIConfig()
    absent = object()
    for instructions, key in product(
        ("Caller instructions.\nKeep whitespace. ", "", absent),
        ("thread-one", "thread-two", "", absent),
    ):
        params = {}
        if instructions is not absent:
            params["instructions"] = instructions
        if key is not absent:
            params["prompt_cache_key"] = key
        headers = {"session_id": "fallback"}
        request = adapter.transform_responses_api_request(
            "gpt-6-sol", "fixture", params, GenericLiteLLMParams(), headers
        )
        if request.get("instructions", absent) != instructions:
            raise RuntimeError("ChatGPT adapter changed caller instructions")
        if request.get("prompt_cache_key", absent) != key:
            raise RuntimeError("ChatGPT adapter dropped the cache key")
        expected_session = key if isinstance(key, str) and key else "fallback"
        if headers.get("session_id") != expected_session:
            raise RuntimeError("ChatGPT adapter changed cache affinity")
    print("Patched ChatGPT caller instructions and prompt cache affinity")


if __name__ == "__main__":
    main()
