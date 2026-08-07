#!/usr/bin/env bash
# Regression checks for the ChatGPT device-login process lifecycle.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vaka-codex-login.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

RECIPE="${TMP}/recipe"
WORKSPACE="${TMP}/workspace"
FAKE_BIN="${TMP}/fake-bin"
mkdir -p "${RECIPE}/bin" "${WORKSPACE}" "${FAKE_BIN}"
cp "${RECIPE_SOURCE}/myCodex" "${RECIPE}/myCodex"
chmod 755 "${RECIPE}/myCodex"
cp "${RECIPE_SOURCE}/vaka.yaml" "${RECIPE}/vaka.yaml"
cp -R "${RECIPE_SOURCE}/auth-profiles" "${RECIPE}/auth-profiles"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The vendored launcher is not under test here. This stub models one Compose
# service closely enough to verify service scope, attempt-bounded logs, and
# restoration when login created the sidecar.
cat > "${RECIPE}/bin/myCodex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MYCODEX_TEST_LAUNCHER_CALLS:?}"

args=" $* "
case "${args}" in
  *" ps --all --quiet litellm "*)
    [[ -e "${MYCODEX_TEST_SERVICE_EXISTS:?}" ]] && printf '%s\n' "${MYCODEX_TEST_CONTAINER_ID:?}"
    exit 0
    ;;
  *" up -d litellm "*)
    if [[ "${MYCODEX_TEST_EXPECT_CLEAN_TOKEN:-0}" == "1" \
        && -e "${MYCODEX_TEST_TOKEN_FILE:?}" ]]; then
      echo "incomplete token state reached sidecar startup" >&2
      exit 97
    fi
    : > "${MYCODEX_TEST_SERVICE_EXISTS:?}"
    exit 0
    ;;
  *" logs --since "*" --follow litellm "*)
    cleanup() {
      : > "${MYCODEX_TEST_LOG_CLEANED:?}"
      exit 0
    }
    trap cleanup INT TERM
    echo "Sign in with ChatGPT using device code:" >&2
    echo "1) Visit https://auth.openai.com/codex/device" >&2
    echo "2) Enter code: TEST-CODE" >&2
    while :; do sleep 1; done
    ;;
  *" rm --stop --force litellm "*)
    rm -f -- "${MYCODEX_TEST_SERVICE_EXISTS:?}"
    exit 0
    ;;
  *" stop litellm "*)
    : > "${MYCODEX_TEST_SERVICE_STOPPED:?}"
    exit 0
    ;;
esac
STUB
chmod 755 "${RECIPE}/bin/myCodex"

# Fake the profile guard, sidecar-state snapshot, and two sidecar-local execs.
cat > "${FAKE_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  ps)
    # No legacy LiteLLM sidecar exists for this test project.
    exit 0
    ;;
  inspect)
    container="${*: -1}"
    if [[ "${container}" == "${MYCODEX_TEST_CONTAINER_ID:?}" ]]; then
      printf '%s\n' "${MYCODEX_TEST_PRIOR_STATE:-running}"
      exit 0
    fi
    # No codex container exists, so the profile-switch guard is a no-op.
    exit 1
    ;;
  exec)
    shift
    [[ "${1:-}" == "${MYCODEX_TEST_CONTAINER_ID:?}" ]] || exit 98
    shift
    ;;
  pause)
    : > "${MYCODEX_TEST_SERVICE_PAUSED:?}"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac

case " $* " in
  *"health/liveliness"*)
    if [[ "${MYCODEX_TEST_MODE:?}" == "not-ready" ]]; then
      echo "ConnectionRefusedError: simulated refusal" >&2
      exit 1
    fi
    exit 0
    ;;
esac

printf 'request\n' >> "${MYCODEX_TEST_REQUESTS:?}"
printf '%s\n' "${@: -2:1}" >> "${MYCODEX_TEST_MODELS:?}"
case "${MYCODEX_TEST_MODE:?}" in
  fail)
    echo "curl: simulated permanent provider failure" >&2
    exit 22
    ;;
  success)
    printf '{"access_token":"test-token"}\n' > "${MYCODEX_TEST_TOKEN_FILE:?}"
    ;;
  wait)
    ;;
  *)
    echo "unexpected test mode: ${MYCODEX_TEST_MODE}" >&2
    exit 99
    ;;
esac

cleanup() {
  : > "${MYCODEX_TEST_PROBE_CLEANED:?}"
  exit 0
}
trap cleanup INT TERM
while :; do sleep 1; done
STUB
chmod 755 "${FAKE_BIN}/docker"

TOKEN_FILE="${RECIPE}/.secrets/chatgpt-token/auth.json"
REQUESTS="${TMP}/requests"
MODELS="${TMP}/models"
LAUNCHER_CALLS="${TMP}/launcher-calls"
LOG_CLEANED="${TMP}/log-cleaned"
PROBE_CLEANED="${TMP}/probe-cleaned"
SERVICE_EXISTS="${TMP}/service-exists"
SERVICE_STOPPED="${TMP}/service-stopped"
SERVICE_PAUSED="${TMP}/service-paused"
CONTAINER_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

reset_case() {
  rm -f -- "${TOKEN_FILE}" "${REQUESTS}" "${MODELS}" "${LAUNCHER_CALLS}" \
    "${LOG_CLEANED}" "${PROBE_CLEANED}" "${SERVICE_EXISTS}" \
    "${SERVICE_STOPPED}" "${SERVICE_PAUSED}"
}

run_login() {
  local mode="$1"
  local ready_timeout="$2"
  local login_timeout="$3"
  local prior_state="${4:-absent}"
  local expect_clean_token="${5:-0}"
  (
    cd "${WORKSPACE}"
    if [[ "${prior_state}" != "absent" ]]; then
      : > "${SERVICE_EXISTS}"
    fi
    env \
      PATH="${FAKE_BIN}:${PATH}" \
      MYCODEX_AUTH=chatgpt \
      MYCODEX_CHATGPT_READY_TIMEOUT="${ready_timeout}" \
      MYCODEX_CHATGPT_LOGIN_TIMEOUT="${login_timeout}" \
      MYCODEX_TEST_MODE="${mode}" \
      MYCODEX_TEST_TOKEN_FILE="${TOKEN_FILE}" \
      MYCODEX_TEST_REQUESTS="${REQUESTS}" \
      MYCODEX_TEST_MODELS="${MODELS}" \
      MYCODEX_TEST_LAUNCHER_CALLS="${LAUNCHER_CALLS}" \
      MYCODEX_TEST_LOG_CLEANED="${LOG_CLEANED}" \
      MYCODEX_TEST_PROBE_CLEANED="${PROBE_CLEANED}" \
      MYCODEX_TEST_SERVICE_EXISTS="${SERVICE_EXISTS}" \
      MYCODEX_TEST_SERVICE_STOPPED="${SERVICE_STOPPED}" \
      MYCODEX_TEST_SERVICE_PAUSED="${SERVICE_PAUSED}" \
      MYCODEX_TEST_CONTAINER_ID="${CONTAINER_ID}" \
      MYCODEX_TEST_PRIOR_STATE="${prior_state}" \
      MYCODEX_TEST_EXPECT_CLEAN_TOKEN="${expect_clean_token}" \
      "${RECIPE}/myCodex" login
  )
}

request_count() {
  [[ -f "${REQUESTS}" ]] || { printf '0'; return; }
  wc -l < "${REQUESTS}" | tr -d ' '
}

# Readiness has its own short, wall-clock timeout and never starts OAuth.
reset_case
if output="$(run_login not-ready 1 30 2>&1)"; then
  fail "login accepted a sidecar that never became ready"
fi
grep -Fq 'did not become ready within 1s' <<< "${output}" \
  || fail "readiness timeout was not actionable"
grep -Fq 'ConnectionRefusedError: simulated refusal' <<< "${output}" \
  || fail "readiness timeout hid the last probe diagnostic"
grep -Fq 'Enter code: TEST-CODE' <<< "${output}" \
  || fail "startup device-code output was hidden behind readiness"
[[ "$(request_count)" == "0" ]] || fail "OAuth started before LiteLLM was ready"
grep -Eq 'up -d litellm$' "${LAUNCHER_CALLS}" \
  || fail "login did not scope startup to the LiteLLM service"
grep -Eq 'logs --since [^ ]+ --follow litellm$' "${LAUNCHER_CALLS}" \
  || fail "login did not follow attempt-bounded startup logs"
grep -Eq 'rm --stop --force litellm$' "${LAUNCHER_CALLS}" \
  || fail "login did not remove a sidecar created only for authentication"
[[ ! -e "${SERVICE_EXISTS}" ]] || fail "temporary login sidecar remained after readiness failure"
echo "ok: readiness is bounded, diagnostic, observable, and sidecar-scoped"

# An interrupted provider flow leaves request metadata but no access token.
# Explicit retry must remove it before starting the sidecar so LiteLLM emits a
# fresh code rather than waiting on an abandoned request.
reset_case
mkdir -p -- "$(dirname -- "${TOKEN_FILE}")"
printf '{"device_code_requested_at":"stale"}\n' > "${TOKEN_FILE}"
output="$(run_login success 5 30 absent 1 2>&1)" \
  || fail "login retry rejected incomplete prior state: ${output}"
grep -Fq 'discarded incomplete ChatGPT login state' <<< "${output}" \
  || fail "login retry did not explain stale-state cleanup"
grep -Eq '"access_token"[[:space:]]*:[[:space:]]*"test-token"' "${TOKEN_FILE}" \
  || fail "login retry did not replace incomplete state with a complete token"
echo "ok: login retry discards incomplete device-flow state before startup"

# A provider/configuration failure is terminal. It must not mint repeated codes
# or remain hidden until the human authorization deadline.
reset_case
if output="$(run_login fail 5 30 2>&1)"; then
  fail "login accepted a provider request that failed"
fi
grep -Fq 'simulated permanent provider failure' <<< "${output}" \
  || fail "provider stderr was hidden"
grep -Fq 'request ended before credentials were issued (exit 22)' <<< "${output}" \
  || fail "provider failure was not explained"
[[ "$(request_count)" == "1" ]] || fail "failed provider request was retried"
[[ -f "${LOG_CLEANED}" ]] || fail "log follower survived provider failure"
echo "ok: permanent provider failure is immediate, visible, and not retried"

# A token may appear while the single provider request is still blocked. The
# wrapper succeeds and terminates both background processes.
reset_case
output="$(run_login success 5 30 2>&1)" \
  || fail "login rejected a completed device flow: ${output}"
grep -Fq 'ChatGPT login complete' <<< "${output}" || fail "success was not reported"
[[ "$(request_count)" == "1" ]] || fail "successful device flow used more than one request"
grep -Fxq 'gpt-5.6-sol' "${MODELS}" \
  || fail "device login did not use the profile's dedicated login model"
[[ -f "${LOG_CLEANED}" ]] || fail "log follower survived successful login"
[[ -f "${PROBE_CLEANED}" ]] || fail "provider request survived successful login"
echo "ok: successful login uses one request and cleans up child processes"

# A sidecar that was already running belongs to the user and remains running.
reset_case
output="$(run_login success 5 30 running 2>&1)" \
  || fail "login rejected an existing running sidecar: ${output}"
if grep -Eq '(rm --stop --force|stop) litellm$' "${LAUNCHER_CALLS}"; then
  fail "login changed the prior running sidecar state"
fi
[[ -e "${SERVICE_EXISTS}" ]] || fail "existing running sidecar was removed"
echo "ok: login preserves a pre-existing running sidecar"

# The browser/MFA phase gets its full configured allowance, then expires with a
# new-code instruction. The pending provider request must be terminated.
reset_case
if output="$(run_login wait 5 1 2>&1)"; then
  fail "login succeeded without a token"
fi
grep -Fq 'waiting up to 1s for browser authorization and MFA' <<< "${output}" \
  || fail "human authorization wait was not announced"
grep -Fq 'device code expired after 1s' <<< "${output}" \
  || fail "authorization timeout did not explain how to retry"
[[ "$(request_count)" == "1" ]] || fail "timed-out device flow was retried"
[[ -f "${LOG_CLEANED}" ]] || fail "log follower survived authorization timeout"
[[ -f "${PROBE_CLEANED}" ]] || fail "provider request survived authorization timeout"
echo "ok: authorization timeout is explicit, single-request, and cleans up"

# Invalid timeout controls fail before starting containers.
reset_case
if output="$(run_login wait invalid 30 2>&1)"; then
  fail "login accepted an invalid readiness timeout"
fi
grep -Fq 'MYCODEX_CHATGPT_READY_TIMEOUT must be a positive whole number' <<< "${output}" \
  || fail "invalid timeout error was not actionable"
[[ ! -e "${LAUNCHER_CALLS}" ]] || fail "invalid timeout started the stack"
echo "ok: timeout controls are validated before stack startup"

echo "PASS: ChatGPT device-login lifecycle"
