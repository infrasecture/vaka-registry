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

# The vendored launcher is not under test here. It acknowledges `up -d` and
# follows logs until the wrapper terminates it, recording cleanup for assertion.
cat > "${RECIPE}/bin/myCodex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MYCODEX_TEST_LAUNCHER_CALLS:?}"
for arg in "$@"; do
  if [[ "${arg}" == "logs" ]]; then
    cleanup() {
      : > "${MYCODEX_TEST_LOG_CLEANED:?}"
      exit 0
    }
    trap cleanup INT TERM
    echo "litellm: simulated device-login output" >&2
    while :; do sleep 1; done
  fi
done
STUB
chmod 755 "${RECIPE}/bin/myCodex"

# Fake only the two `docker exec` calls owned by the login flow: readiness and
# the provider request. Each mode makes the process lifecycle deterministic.
cat > "${FAKE_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "exec" ]] || exit 1
shift
[[ $# -gt 0 ]] || exit 1
shift # container name

case " $* " in
  *" http://litellm:4000/health/liveliness "*)
    [[ "${MYCODEX_TEST_MODE:?}" != "not-ready" ]]
    exit $?
    ;;
esac

printf 'request\n' >> "${MYCODEX_TEST_REQUESTS:?}"
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
LAUNCHER_CALLS="${TMP}/launcher-calls"
LOG_CLEANED="${TMP}/log-cleaned"
PROBE_CLEANED="${TMP}/probe-cleaned"

reset_case() {
  rm -f -- "${TOKEN_FILE}" "${REQUESTS}" "${LAUNCHER_CALLS}" \
    "${LOG_CLEANED}" "${PROBE_CLEANED}"
}

run_login() {
  local mode="$1"
  local ready_timeout="$2"
  local login_timeout="$3"
  (
    cd "${WORKSPACE}"
    env \
      PATH="${FAKE_BIN}:${PATH}" \
      MYCODEX_AUTH=chatgpt \
      MYCODEX_CHATGPT_READY_TIMEOUT="${ready_timeout}" \
      MYCODEX_CHATGPT_LOGIN_TIMEOUT="${login_timeout}" \
      MYCODEX_TEST_MODE="${mode}" \
      MYCODEX_TEST_TOKEN_FILE="${TOKEN_FILE}" \
      MYCODEX_TEST_REQUESTS="${REQUESTS}" \
      MYCODEX_TEST_LAUNCHER_CALLS="${LAUNCHER_CALLS}" \
      MYCODEX_TEST_LOG_CLEANED="${LOG_CLEANED}" \
      MYCODEX_TEST_PROBE_CLEANED="${PROBE_CLEANED}" \
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
[[ "$(request_count)" == "0" ]] || fail "OAuth started before LiteLLM was ready"
echo "ok: readiness timeout is bounded and does not start device login"

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
[[ -f "${LOG_CLEANED}" ]] || fail "log follower survived successful login"
[[ -f "${PROBE_CLEANED}" ]] || fail "provider request survived successful login"
echo "ok: successful login uses one request and cleans up child processes"

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
