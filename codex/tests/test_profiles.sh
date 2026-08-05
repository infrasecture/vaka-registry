#!/usr/bin/env bash
# Regression checks for the auth-profile layer in the thin ./myCodex wrapper.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vaka-codex-profiles.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

RECIPE="${TMP}/recipe"
# Unique basename so the derived container name (<project>-codex) cannot collide
# with a real running stack when the profile-switch guard runs `docker inspect`.
WORKSPACE="${TMP}/proj-${RANDOM}${RANDOM}"
mkdir -p "${RECIPE}/bin" "${WORKSPACE}"
cp "${RECIPE_SOURCE}/myCodex" "${RECIPE}/myCodex"
chmod 755 "${RECIPE}/myCodex"
cp "${RECIPE_SOURCE}/vaka.yaml" "${RECIPE}/vaka.yaml"
cp -R "${RECIPE_SOURCE}/auth-profiles" "${RECIPE}/auth-profiles"

# Capturing launcher stub: record argv and the profile-relevant environment.
# Tolerant of a missing OPENAI_API_KEY (non-openai profiles never set it).
cat > "${RECIPE}/bin/myCodex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${MYCODEX_TEST_CAPTURE:?}"
: "${LITELLM_MASTER_KEY:?}"
printf '%s\n' "$@" > "${MYCODEX_TEST_CAPTURE}.argv"
{
  printf 'MYCODEX_COMPOSE=%s\n' "${MYCODEX_COMPOSE:-}"
  printf 'MYCODEX_LITELLM_CONFIG=%s\n' "${MYCODEX_LITELLM_CONFIG:-}"
  printf 'MYCODEX_MODEL=%s\n' "${MYCODEX_MODEL:-}"
  printf 'MYCODEX_CREDENTIAL_FILE=%s\n' "${MYCODEX_CREDENTIAL_FILE:-}"
  printf 'OPENAI_API_KEY_SET=%s\n' "${OPENAI_API_KEY:+yes}"
  printf 'LITELLM_MASTER_KEY_SET=%s\n' "${LITELLM_MASTER_KEY:+yes}"
} > "${MYCODEX_TEST_CAPTURE}.env"
STUB
chmod 755 "${RECIPE}/bin/myCodex"

fail() { echo "FAIL: $*" >&2; exit 1; }

run_wrapper() {
  local capture="$1"; shift
  ( cd "${WORKSPACE}" && env MYCODEX_TEST_CAPTURE="${capture}" "$@" "${RECIPE}/myCodex" up )
}

# --- egress invariant: codex block byte-identical across every policy -------
extract_codex_block() {
  awk '
    /^  codex:/ { grab = 1; print; next }
    grab && /^  [a-z]/ { grab = 0 }
    grab { print }
  ' "$1"
}
root_codex="$(extract_codex_block "${RECIPE}/vaka.yaml")"
[[ -n "${root_codex}" ]] || fail "root vaka.yaml has no codex service block"
for policy in "${RECIPE}"/auth-profiles/*/vaka.yaml; do
  if [[ "$(extract_codex_block "${policy}")" != "${root_codex}" ]]; then
    fail "codex egress block in ${policy} differs from root vaka.yaml (agent egress must be identical)"
  fi
done
echo "ok: agent egress block identical across all profile policies"

# --- default (openai) profile: no overlay, root policy ---------------------
default_capture="${TMP}/capture-default"
run_wrapper "${default_capture}" OPENAI_API_KEY=test-provider-key
grep -Fq -- '-f' "${default_capture}.argv" && fail "openai profile must not inject a compose overlay"
grep -Fq 'up' "${default_capture}.argv" || fail "openai launcher did not receive the subcommand"
grep -Fq "vaka.yaml compose" "${default_capture}.env" || fail "openai did not use the root vaka policy"
grep -Fxq 'OPENAI_API_KEY_SET=yes' "${default_capture}.env" || fail "openai did not resolve the provider key"
echo "ok: openai profile injects no overlay and uses the root policy"

# --- chatgpt profile: overlay injected, config/model/policy switched --------
chatgpt_capture="${TMP}/capture-chatgpt"
run_wrapper "${chatgpt_capture}" MYCODEX_AUTH=chatgpt
grep -Fq "auth-profiles/chatgpt/overlay.yaml" "${chatgpt_capture}.argv" \
  || fail "chatgpt profile did not inject its compose overlay"
grep -Fq "auth-profiles/chatgpt/vaka.yaml compose" "${chatgpt_capture}.env" \
  || fail "chatgpt profile did not select its egress policy"
grep -Fq "auth-profiles/chatgpt/litellm.config.yaml" "${chatgpt_capture}.env" \
  || fail "chatgpt profile did not select its litellm config"
grep -Fxq 'MYCODEX_MODEL=gpt-5.3-codex' "${chatgpt_capture}.env" \
  || fail "chatgpt profile did not pin the default model"
grep -Fxq 'OPENAI_API_KEY_SET=' "${chatgpt_capture}.env" \
  || fail "chatgpt profile must not require OPENAI_API_KEY"
grep -Fxq 'LITELLM_MASTER_KEY_SET=yes' "${chatgpt_capture}.env" \
  || fail "chatgpt profile did not mint the internal proxy key"
[[ -d "${RECIPE}/.secrets/chatgpt-token" ]] || fail "chatgpt profile did not create the token dir"
echo "ok: chatgpt profile switches overlay/config/policy/model without a provider key"

# --- profile-switch guard: no-op when no stack is running ------------------
start_capture="${TMP}/capture-start"
( cd "${WORKSPACE}" && env MYCODEX_TEST_CAPTURE="${start_capture}" MYCODEX_AUTH=chatgpt \
    "${RECIPE}/myCodex" start )
grep -Fxq 'start' "${start_capture}.argv" || fail "start did not reach the launcher when nothing is running"
echo "ok: profile-switch guard is a no-op when no stack is running"

# --- vertex scaffold: credential-file handler ------------------------------
vertex_err="${TMP}/vertex-missing.err"
if run_wrapper "${TMP}/capture-vertex-missing" MYCODEX_AUTH=vertex \
    > /dev/null 2> "${vertex_err}"; then
  fail "vertex profile accepted a missing credential file"
fi
grep -Fq 'set MYCODEX_VERTEX_CREDENTIALS' "${vertex_err}" \
  || fail "vertex missing-credential error was not actionable"

sa="${TMP}/service-account.json"
printf '{}\n' > "${sa}"
vertex_capture="${TMP}/capture-vertex"
run_wrapper "${vertex_capture}" MYCODEX_AUTH=vertex MYCODEX_VERTEX_CREDENTIALS="${sa}"
grep -Fq "auth-profiles/vertex/overlay.yaml" "${vertex_capture}.argv" \
  || fail "vertex profile did not inject its compose overlay"
grep -Fxq "MYCODEX_CREDENTIAL_FILE=${sa}" "${vertex_capture}.env" \
  || fail "vertex profile did not export the resolved credential path"
echo "ok: vertex credential-file profile resolves and mounts the credential"

# --- unknown profile rejected ----------------------------------------------
unknown_err="${TMP}/unknown.err"
if run_wrapper "${TMP}/capture-unknown" MYCODEX_AUTH=nope > /dev/null 2> "${unknown_err}"; then
  fail "unknown profile was accepted"
fi
grep -Fq "unknown auth profile 'nope'" "${unknown_err}" || fail "unknown-profile error was not actionable"
echo "ok: unknown profile rejected"

echo "PASS: auth-profile dispatch, egress invariant, and credential handlers"
