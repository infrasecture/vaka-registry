#!/usr/bin/env bash
# Exercise the published LiteLLM image without contacting ChatGPT.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${RECIPE_SOURCE}/docker-compose.yaml"
CONFIG_FILE="${RECIPE_SOURCE}/auth-profiles/chatgpt/litellm.config.yaml"
TEST_FILE="${RECIPE_SOURCE}/tests/test_chatgpt_gateway.py"

litellm_image="$(docker compose -f "${COMPOSE_FILE}" config --format json \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["litellm"]["image"])')"
docker pull "${litellm_image}"

docker run --rm --network none --entrypoint python \
  -e LITELLM_LOCAL_MODEL_COST_MAP=True \
  -e OTEL_SDK_DISABLED=true \
  -e CHATGPT_DEFAULT_INSTRUCTIONS=must-not-be-injected \
  --mount "type=bind,src=${CONFIG_FILE},dst=/test/config.yaml,readonly" \
  --mount "type=bind,src=${TEST_FILE},dst=/test/test_chatgpt_gateway.py,readonly" \
  "${litellm_image}" /test/test_chatgpt_gateway.py /test/config.yaml
