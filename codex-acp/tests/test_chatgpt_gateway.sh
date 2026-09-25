#!/usr/bin/env bash
# Exercise the recipe-built LiteLLM image without contacting ChatGPT.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${RECIPE_SOURCE}/docker-compose.yaml"
CONFIG_FILE="${RECIPE_SOURCE}/auth-profiles/chatgpt/litellm.config.yaml"
TEST_FILE="${RECIPE_SOURCE}/tests/test_chatgpt_gateway.py"

# Build exactly the gateway selected by this recipe, using its isolated context.
docker compose -f "${COMPOSE_FILE}" build litellm
litellm_image="$(docker compose -f "${COMPOSE_FILE}" config --format json \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["litellm"]["image"])')"

docker run --rm --network none --entrypoint python \
  -e LITELLM_LOCAL_MODEL_COST_MAP=True \
  -e OTEL_SDK_DISABLED=true \
  --mount "type=bind,src=${CONFIG_FILE},dst=/test/config.yaml,readonly" \
  --mount "type=bind,src=${TEST_FILE},dst=/test/test_chatgpt_gateway.py,readonly" \
  --mount "type=bind,src=${RECIPE_SOURCE}/litellm/patch_chatgpt.py,dst=/test/patch_chatgpt.py,readonly" \
  "${litellm_image}" /test/test_chatgpt_gateway.py /test/config.yaml
