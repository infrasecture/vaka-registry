#!/usr/bin/env bash
# Regression checks for codex-prestart.sh config rewriting.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PRESTART="${RECIPE_SOURCE}/codex-prestart.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vaka-codex-prestart.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

CODEX_HOME="${TMP}/.codex"
CONFIG="${CODEX_HOME}/config.toml"
mkdir -p "${CODEX_HOME}"

seed_config() {
  cat > "${CONFIG}" <<'EOF'
approval_policy = "never"
sandbox_mode = "danger-full-access"
model = "user-choice"

[projects."/w"]
trust_level = "trusted"
EOF
}

run_prestart() {
  # prestart ends with `exec sleep infinity`; the config is fully rewritten
  # before that, so run under a timeout and ignore the expected non-zero exit.
  env CODEX_HOME="${CODEX_HOME}" "$@" timeout 5 bash "${PRESTART}" >/dev/null 2>&1 || true
}

# --- default (openai) profile: MYCODEX_MODEL unset -> user's model preserved ---
seed_config
run_prestart
grep -Fxq 'model = "user-choice"' "${CONFIG}" || fail "default profile deleted the user's model line"
grep -Fxq 'model_provider = "litellm"' "${CONFIG}" || fail "default profile did not set the litellm provider"
grep -Fq '[model_providers.litellm]' "${CONFIG}" || fail "default profile did not add the provider table"
grep -Fxq 'trust_level = "trusted"' "${CONFIG}" || fail "default profile dropped the projects table"

# Idempotent: a second run keeps the user's model and does not duplicate blocks.
run_prestart
[[ "$(grep -c '^model = "user-choice"$' "${CONFIG}")" == "1" ]] || fail "user model line not preserved idempotently"
[[ "$(grep -c '^\[model_providers.litellm\]$' "${CONFIG}")" == "1" ]] || fail "provider table duplicated on re-run"

# --- profile with a pin: MYCODEX_MODEL set -> replaces the user's model --------
seed_config
run_prestart MYCODEX_MODEL=gpt-5.3-codex
grep -Fxq 'model = "gpt-5.3-codex"' "${CONFIG}" || fail "pin was not written"
grep -Fxq 'model = "user-choice"' "${CONFIG}" && fail "pin did not replace the user's model line"
[[ "$(grep -c '^model = ' "${CONFIG}")" == "1" ]] || fail "expected exactly one top-level model line"

echo "PASS: prestart preserves the user's model by default and pins it only when set"
