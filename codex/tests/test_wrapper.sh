#!/usr/bin/env bash
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vaka-codex-wrapper.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

RECIPE="${TMP}/recipe"
WORKSPACE="${TMP}/workspace"
mkdir -p "${RECIPE}/bin" "${WORKSPACE}"
cp "${RECIPE_SOURCE}/myCodex" "${RECIPE}/myCodex"
chmod 755 "${RECIPE}/myCodex"

cat > "${RECIPE}/bin/myCodex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${MYCODEX_TEST_CAPTURE:?}"
: "${OPENAI_API_KEY:?}"
: "${LITELLM_MASTER_KEY:?}"
printf '%s\n' "${OPENAI_API_KEY}" > "${MYCODEX_TEST_CAPTURE}.provider"
printf '%s\n' "${LITELLM_MASTER_KEY}" > "${MYCODEX_TEST_CAPTURE}.proxy"
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
    env MYCODEX_TEST_CAPTURE="${capture}" "$@" "${RECIPE}/myCodex" up
  )
}

capture_one="${TMP}/capture-one"
capture_two="${TMP}/capture-two"
run_wrapper "${capture_one}" OPENAI_API_KEY=test-provider-key

secret_dir="${RECIPE}/.secrets"
secret_file="${secret_dir}/litellm_admin_key_restricted_v1"
[[ -f "${secret_file}" && ! -L "${secret_file}" ]] || fail "generated key is not a managed regular file"
[[ "$(mode_of "${secret_dir}")" == "700" ]] || fail "created secret directory mode is not 0700"
[[ "$(mode_of "${secret_file}")" == "600" ]] || fail "created secret file mode is not 0600"
grep -Eq '^[0-9a-f]{64}$' "${secret_file}" || fail "generated key is not 32-byte hexadecimal data"
cmp -s "${capture_one}.proxy" "${secret_file}" || fail "launcher did not receive the persisted key"

run_wrapper "${capture_two}" OPENAI_API_KEY=test-provider-key
cmp -s "${capture_one}.proxy" "${capture_two}.proxy" || fail "successive launches received different keys"

printf '%s\n' 'managed-provider-key' > "${secret_dir}/openai_api_key"
chmod 600 "${secret_dir}/openai_api_key"
managed_provider_capture="${TMP}/capture-managed-provider"
run_wrapper "${managed_provider_capture}"
[[ "$(<"${managed_provider_capture}.provider")" == "managed-provider-key" ]] || \
  fail "managed provider key was not loaded"

# Existing managed paths are read but never silently chmodded.
chmod 750 "${secret_dir}"
chmod 640 "${secret_file}"
run_wrapper "${TMP}/capture-existing-mode" OPENAI_API_KEY=test-provider-key
[[ "$(mode_of "${secret_dir}")" == "750" ]] || fail "existing managed directory mode was changed"
[[ "$(mode_of "${secret_file}")" == "640" ]] || fail "existing managed file mode was changed"

# Explicit provider *_FILE inputs intentionally follow symlinks and are not
# chmodded. The embedded gateway administrator key is deliberately not an input.
external_provider="${TMP}/provider-key"
printf '%s\n' 'provider-from-file' > "${external_provider}"
chmod 644 "${external_provider}"
ln -s "${external_provider}" "${TMP}/provider-link"
file_capture="${TMP}/capture-file"
run_wrapper "${file_capture}" \
  OPENAI_API_KEY_FILE="${TMP}/provider-link"
[[ "$(<"${file_capture}.provider")" == "provider-from-file" ]] || fail "provider *_FILE input was not honored"
[[ "$(mode_of "${external_provider}")" == "644" ]] || fail "provider *_FILE target mode was changed"
cmp -s "${file_capture}.proxy" "${secret_file}" || fail "provider file input changed the gateway key"

ambiguous_error="${TMP}/ambiguous-error"
if run_wrapper "${TMP}/capture-ambiguous" \
  OPENAI_API_KEY=test-provider-key \
  OPENAI_API_KEY_FILE="${external_provider}" > /dev/null 2> "${ambiguous_error}"; then
  fail "ambiguous value and file inputs were accepted"
fi
grep -Fq 'set only one of OPENAI_API_KEY and OPENAI_API_KEY_FILE' "${ambiguous_error}" || \
  fail "ambiguous-source failure was not actionable"

printf '\n' > "${secret_file}"
empty_error="${TMP}/empty-error"
if run_wrapper "${TMP}/capture-empty" OPENAI_API_KEY=test-provider-key > /dev/null 2> "${empty_error}"; then
  fail "empty persisted key was silently accepted or replaced"
fi
grep -Fq 'is empty' "${empty_error}" || fail "empty-key failure was not actionable"

rm -f -- "${secret_file}"
ln -s "${external_provider}" "${secret_file}"
managed_link_error="${TMP}/managed-link-error"
if run_wrapper "${TMP}/capture-managed-link" OPENAI_API_KEY=test-provider-key > /dev/null 2> "${managed_link_error}"; then
  fail "symlinked managed key was accepted"
fi
grep -Fq 'managed secret files must be regular files' "${managed_link_error}" \
  || fail "managed-key symlink failure was not actionable"

rm -rf -- "${secret_dir}"
external_secret_dir="${TMP}/external-secrets"
mkdir "${external_secret_dir}"
ln -s "${external_secret_dir}" "${secret_dir}"
managed_dir_error="${TMP}/managed-dir-error"
if run_wrapper "${TMP}/capture-managed-dir" OPENAI_API_KEY=test-provider-key > /dev/null 2> "${managed_dir_error}"; then
  fail "symlinked managed secret directory was accepted"
fi
grep -Fq 'managed secret storage must be a real directory' "${managed_dir_error}" || \
  fail "managed-directory symlink failure was not actionable"

rm -f -- "${secret_dir}"
mkdir -m 700 "${secret_dir}"
concurrent_one="${TMP}/capture-concurrent-one"
concurrent_two="${TMP}/capture-concurrent-two"
run_wrapper "${concurrent_one}" OPENAI_API_KEY=test-provider-key &
pid_one=$!
run_wrapper "${concurrent_two}" OPENAI_API_KEY=test-provider-key &
pid_two=$!
wait "${pid_one}"
wait "${pid_two}"
cmp -s "${concurrent_one}.proxy" "${concurrent_two}.proxy" || fail "concurrent launches selected different keys"
cmp -s "${concurrent_one}.proxy" "${secret_file}" || fail "concurrent winner was not persisted"
shopt -s nullglob
temporary_keys=("${secret_dir}"/.litellm_admin_key_restricted_v1.*)
shopt -u nullglob
if [[ ${#temporary_keys[@]} -ne 0 ]]; then
  fail "temporary key file remained after concurrent publication"
fi

echo "PASS: codex wrapper resolves and persists secrets consistently"
