#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vaka-codex-wrapper.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

RECIPE="${TMP}/recipe"
WORKSPACE="${TMP}/workspace"
mkdir -p "${RECIPE}/bin" "${WORKSPACE}"
cp "${ROOT}/codex/myCodex" "${RECIPE}/myCodex"
chmod 755 "${RECIPE}/myCodex"

cat > "${RECIPE}/bin/myCodex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${MYCODEX_TEST_CAPTURE:?}"
: "${LITELLM_MASTER_KEY:?}"
printf '%s\n' "${LITELLM_MASTER_KEY}" > "${MYCODEX_TEST_CAPTURE}"
STUB
chmod 755 "${RECIPE}/bin/myCodex"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

run_wrapper() {
  local capture="$1"
  shift
  (
    cd "${WORKSPACE}"
    env OPENAI_API_KEY=test-provider-key MYCODEX_TEST_CAPTURE="${capture}" "$@" \
      "${RECIPE}/myCodex" up
  )
}

capture_one="${TMP}/capture-one"
capture_two="${TMP}/capture-two"
run_wrapper "${capture_one}"

secret_dir="${RECIPE}/.secrets"
secret_file="${secret_dir}/litellm_master_key"
[[ -f "${secret_file}" && ! -L "${secret_file}" ]] || fail "generated key is not a regular file"
[[ "$(mode_of "${secret_dir}")" == "700" ]] || fail "secret directory mode is not 0700"
[[ "$(mode_of "${secret_file}")" == "600" ]] || fail "generated key mode is not 0600"
grep -Eq '^[0-9a-f]{64}$' "${secret_file}" || fail "generated key is not 32-byte hexadecimal data"
cmp -s "${capture_one}" "${secret_file}" || fail "launcher did not receive the persisted key"

run_wrapper "${capture_two}"
cmp -s "${capture_one}" "${capture_two}" || fail "successive launches received different keys"

persisted_before="$(<"${secret_file}")"
override_capture="${TMP}/capture-override"
run_wrapper "${override_capture}" LITELLM_MASTER_KEY=explicit-test-override
[[ "$(<"${override_capture}")" == "explicit-test-override" ]] || fail "environment override was not honored"
[[ "$(<"${secret_file}")" == "${persisted_before}" ]] || fail "environment override modified persisted state"

rm -f -- "${secret_file}"
concurrent_one="${TMP}/capture-concurrent-one"
concurrent_two="${TMP}/capture-concurrent-two"
run_wrapper "${concurrent_one}" &
pid_one=$!
run_wrapper "${concurrent_two}" &
pid_two=$!
wait "${pid_one}"
wait "${pid_two}"
cmp -s "${concurrent_one}" "${concurrent_two}" || fail "concurrent launches selected different keys"
cmp -s "${concurrent_one}" "${secret_file}" || fail "concurrent winner was not persisted"

echo "PASS: codex wrapper reuses one private LiteLLM key"
