#!/usr/bin/env bash
# Exercise the exact pinned LiteLLM image without contacting ChatGPT.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${RECIPE_SOURCE}/docker-compose.yaml"
CONFIG_FILE="${RECIPE_SOURCE}/auth-profiles/chatgpt/litellm.config.yaml"
TEST_FILE="${RECIPE_SOURCE}/tests/test_chatgpt_gateway.py"

litellm_image="$(
  sed -n 's/^[[:space:]]*image: \(docker\.litellm[^[:space:]]*\)$/\1/p' \
    "${COMPOSE_FILE}"
)"
[[ -n "${litellm_image}" ]] \
  || { echo "FAIL: could not resolve the pinned LiteLLM image" >&2; exit 1; }

docker run --rm --entrypoint python \
  --mount "type=bind,src=${CONFIG_FILE},dst=/test/config.yaml,readonly" \
  --mount "type=bind,src=${TEST_FILE},dst=/test/test_chatgpt_gateway.py,readonly" \
  "${litellm_image}" /test/test_chatgpt_gateway.py /test/config.yaml
