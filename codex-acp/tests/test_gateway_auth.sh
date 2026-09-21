#!/usr/bin/env bash
# Exercise the auth policy with the exact pinned LiteLLM image.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${RECIPE_SOURCE}/docker-compose.yaml"
AUTH_FILE="${RECIPE_SOURCE}/litellm_agent_auth.py"
TEST_FILE="${RECIPE_SOURCE}/tests/test_gateway_auth.py"

litellm_image="$(
  sed -n 's/^[[:space:]]*image: \(docker\.litellm[^[:space:]]*\)$/\1/p' \
    "${COMPOSE_FILE}"
)"
[[ -n "${litellm_image}" ]] \
  || { echo "FAIL: could not resolve the pinned LiteLLM image" >&2; exit 1; }

docker_args=(
  run --rm --entrypoint python
  -e MYCODEX_GATEWAY_TOKEN=mycodex-agent-v1
  -e LITELLM_MASTER_KEY=test-gateway-master
  --mount "type=bind,src=${AUTH_FILE},dst=/test/litellm_agent_auth.py,readonly"
  --mount "type=bind,src=${TEST_FILE},dst=/test/test_gateway_auth.py,readonly"
)
config_args=()
index=0
for config in \
  "${RECIPE_SOURCE}/litellm.config.yaml" \
  "${RECIPE_SOURCE}/auth-profiles/chatgpt/litellm.config.yaml" \
  "${RECIPE_SOURCE}/auth-profiles/vertex/litellm.config.yaml"; do
  index=$((index + 1))
  target="/test/config-${index}.yaml"
  docker_args+=(--mount "type=bind,src=${config},dst=${target},readonly")
  config_args+=("${target}")
done

docker "${docker_args[@]}" "${litellm_image}" \
  /test/test_gateway_auth.py /test/litellm_agent_auth.py "${config_args[@]}"

container="vaka-gateway-auth-test-$$"
cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --rm --name "${container}" \
  -e LITELLM_MASTER_KEY=test-gateway-master \
  -e MYCODEX_GATEWAY_TOKEN=mycodex-agent-v1 \
  -e OPENAI_API_KEY=test-provider-key \
  --mount "type=bind,src=${RECIPE_SOURCE}/litellm.config.yaml,dst=/app/config.yaml,readonly" \
  --mount "type=bind,src=${AUTH_FILE},dst=/app/litellm_agent_auth.py,readonly" \
  "${litellm_image}" --config /app/config.yaml --telemetry False >/dev/null

ready=0
for ((attempt = 1; attempt <= 30; attempt++)); do
  if docker exec "${container}" python -c '
import urllib.request
urllib.request.urlopen("http://127.0.0.1:4000/health/liveliness", timeout=2)
' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if (( ! ready )); then
  docker logs "${container}" >&2
  echo "FAIL: pinned LiteLLM did not become ready with the auth policy" >&2
  exit 1
fi

docker exec "${container}" python -c '
import urllib.request
request = urllib.request.Request(
    "http://127.0.0.1:4000/v1/models",
    headers={"Authorization": "Bearer mycodex-agent-v1"},
)
response = urllib.request.urlopen(request, timeout=5)
assert response.status == 200, response.status
'

docker exec "${container}" python -c '
import urllib.error
import urllib.request
request = urllib.request.Request(
    "http://127.0.0.1:4000/key/list",
    headers={"Authorization": "Bearer mycodex-agent-v1"},
)
try:
    urllib.request.urlopen(request, timeout=5)
except urllib.error.HTTPError as exc:
    assert exc.code == 403, exc.code
else:
    raise SystemExit("agent credential reached a LiteLLM management route")
'

echo "PASS: pinned LiteLLM enforces the agent route boundary at runtime"
