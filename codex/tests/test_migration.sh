#!/usr/bin/env bash
# Upgrade checks for the pre-0.3.1 gateway credential boundary.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vaka-codex-migration.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

RECIPE="${TMP}/recipe"
WORKSPACE="${TMP}/workspace"
FAKE_BIN="${TMP}/fake-bin"
CAPTURE="${TMP}/launcher"
mkdir -p "${RECIPE}/bin" "${RECIPE}/.secrets" "${WORKSPACE}" "${FAKE_BIN}"
cp "${RECIPE_SOURCE}/myCodex" "${RECIPE}/myCodex"
chmod 755 "${RECIPE}/myCodex"
cp "${RECIPE_SOURCE}/vaka.yaml" "${RECIPE}/vaka.yaml"
cp -R "${RECIPE_SOURCE}/auth-profiles" "${RECIPE}/auth-profiles"

fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "${RECIPE}/bin/myCodex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MYCODEX_TEST_CAPTURE:?}"
printf '%s\n' "${LITELLM_MASTER_KEY-}" > "${MYCODEX_TEST_CAPTURE}.gateway-admin"
STUB
chmod 755 "${RECIPE}/bin/myCodex"

cat > "${FAKE_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ps" ]]; then
  case "${MYCODEX_TEST_CONTAINER_STATE:-absent}" in
    sidecar-legacy|sidecar-current)
      printf '%s\n' test-litellm-container
      ;;
  esac
  exit 0
fi
[[ "${1:-}" == "inspect" ]] || exit 1
case "${MYCODEX_TEST_CONTAINER_STATE:-absent}" in
  absent)
    exit 1
    ;;
  legacy)
    # A pre-contract container has no gateway-auth label.
    printf '\n'
    ;;
  current)
    printf '%s\n' restricted-v1
    ;;
  sidecar-legacy)
    [[ "${*: -1}" == "test-litellm-container" ]] || exit 1
    printf '\n'
    ;;
  sidecar-current)
    [[ "${*: -1}" == "test-litellm-container" ]] || exit 1
    printf '%s\n' restricted-v1
    ;;
  *)
    exit 99
    ;;
esac
STUB
chmod 755 "${FAKE_BIN}/docker"

run_wrapper() {
  (
    cd "${WORKSPACE}"
    env \
      PATH="${FAKE_BIN}:${PATH}" \
      MYCODEX_AUTH=openai \
      OPENAI_API_KEY=test-provider-key \
      MYCODEX_TEST_CAPTURE="${CAPTURE}" \
      MYCODEX_TEST_CONTAINER_STATE="$1" \
      "${RECIPE}/myCodex" "${@:2}"
  )
}

printf '%s\n' exposed-legacy-admin-key > "${RECIPE}/.secrets/litellm_master_key"
chmod 600 "${RECIPE}/.secrets/litellm_master_key"

legacy_error="${TMP}/legacy.err"
if run_wrapper legacy up > /dev/null 2> "${legacy_error}"; then
  fail "legacy Codex container was allowed to start"
fi
grep -Fq "predates restricted gateway authentication" "${legacy_error}" \
  || fail "legacy-container failure did not explain the security boundary"
grep -Fq "${RECIPE}/myCodex down" "${legacy_error}" \
  || fail "legacy-container failure did not provide the non-destructive migration command"
[[ ! -e "${CAPTURE}" ]] || fail "legacy container reached the launcher"
[[ -e "${RECIPE}/.secrets/litellm_master_key" ]] \
  || fail "legacy key was changed while its container may still be running"
echo "ok: legacy containers fail closed with a non-destructive migration command"

sidecar_error="${TMP}/sidecar.err"
if run_wrapper sidecar-legacy login chatgpt > /dev/null 2> "${sidecar_error}"; then
  fail "legacy LiteLLM-only partial stack was allowed into device login"
fi
grep -Fq "test-litellm-container" "${sidecar_error}" \
  || fail "partial-stack failure did not identify the legacy LiteLLM sidecar"
[[ ! -e "${CAPTURE}" ]] || fail "legacy sidecar reached the login launcher"
echo "ok: a legacy LiteLLM-only partial stack is blocked before device login"

run_wrapper legacy down >/dev/null
grep -Eq '(^| )down($| )' "${CAPTURE}" || fail "migration down command did not reach the launcher"
rm -f -- "${CAPTURE}" "${CAPTURE}.gateway-admin"

rotation_output="${TMP}/rotation.err"
run_wrapper absent up > /dev/null 2> "${rotation_output}"
current_key="${RECIPE}/.secrets/litellm_admin_key_restricted_v1"
[[ -s "${current_key}" && ! -L "${current_key}" ]] \
  || fail "restricted gateway administrator key was not generated"
[[ ! -e "${RECIPE}/.secrets/litellm_master_key" ]] \
  || fail "exposed legacy administrator key was retained"
[[ "$(<"${current_key}")" != "exposed-legacy-admin-key" ]] \
  || fail "legacy administrator key was reused"
cmp -s "${current_key}" "${CAPTURE}.gateway-admin" \
  || fail "launcher did not receive the rotated sidecar administrator key"
grep -Fq 'rotated the legacy LiteLLM administrator key' "${rotation_output}" \
  || fail "automatic key rotation was not reported"
echo "ok: managed gateway administrator key rotates after legacy containers are removed"

external_error="${TMP}/external.err"
if (
  cd "${WORKSPACE}"
  env \
    PATH="${FAKE_BIN}:${PATH}" \
    MYCODEX_AUTH=openai \
    OPENAI_API_KEY=test-provider-key \
    LITELLM_MASTER_KEY=previously-exposed-override \
    MYCODEX_TEST_CAPTURE="${CAPTURE}" \
    MYCODEX_TEST_CONTAINER_STATE=absent \
    "${RECIPE}/myCodex" up
) > /dev/null 2> "${external_error}"; then
  fail "external legacy administrator key override was accepted"
fi
grep -Fq 'are no longer accepted' "${external_error}" \
  || fail "external-key rejection did not explain the compatibility change"
grep -Fq 'unset the override' "${external_error}" \
  || fail "external-key rejection did not provide the safe migration"
echo "ok: formerly exposed external administrator keys cannot be reused"

echo "PASS: gateway credential migration fails closed and rotates legacy state"
