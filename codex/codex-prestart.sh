#!/usr/bin/env bash
# Runs as the container command (as the runtime user, after the image entrypoint
# has provisioned the user, written the base codex config, and created the tmux
# session). It idempotently adds the LiteLLM provider to codex's config and then
# keeps the container alive.
#
# It deliberately does NOT manage `[projects."<workdir>"]`: the image entrypoint
# already writes that for the real, path-parity workdir. This script only owns
# the top-level `model_provider` line and the `[model_providers.litellm]` table,
# stripping any prior copy before re-adding — so repeated boots against a
# persistent state volume never duplicate the block, and everything else the
# entrypoint wrote is preserved.
set -euo pipefail

codex_home="${CODEX_HOME:-${MYCODEX_CODEX_HOME:-/home/codex/.codex}}"
config_file="${codex_home}/config.toml"
tmp_file="${config_file}.tmp.$$"
# Optional model pin. Auth profiles that enumerate specific models set this so
# Codex requests a model the gateway serves; the default profile leaves it empty
# and relies on LiteLLM's wildcard.
model="${MYCODEX_MODEL:-}"

mkdir -p "${codex_home}"
touch "${config_file}"

awk -v model="${model}" '
  function is_table(line) {
    return line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*([#].*)?$/
  }
  function toml_escape(value) {
    gsub(/\\/, "\\\\", value)
    gsub(/"/, "\\\"", value)
    return value
  }

  # Drop our managed provider table (until the next table header or EOF).
  /^[[:space:]]*\[model_providers\.litellm\][[:space:]]*([#].*)?$/ {
    skip_managed_block = 1
    next
  }
  skip_managed_block && is_table($0) { skip_managed_block = 0 }
  skip_managed_block { next }

  # Drop any prior top-level model_provider line (before the first table).
  is_table($0) { in_table = 1 }
  !in_table && /^[[:space:]]*model_provider[[:space:]]*=/ { next }
  # Only drop a prior top-level model line when we are going to re-add a pin.
  # With no pin (default openai profile) the user model choice is preserved.
  !in_table && model != "" && /^[[:space:]]*model[[:space:]]*=/ { next }

  # Buffer everything else so the output can be reassembled deterministically.
  { buf[n++] = $0 }

  END {
    # Trim trailing blank lines so re-runs produce byte-identical output.
    while (n > 0 && buf[n - 1] ~ /^[[:space:]]*$/) { n-- }

    print "model_provider = \"litellm\""
    if (model != "") { print "model = \"" toml_escape(model) "\"" }
    for (i = 0; i < n; i++) { print buf[i] }
    print ""
    print "[model_providers.litellm]"
    print "name = \"LiteLLM local proxy\""
    print "base_url = \"http://litellm:4000/v1\""
    print "wire_api = \"responses\""
    print "env_key = \"OPENAI_API_KEY\""
    print "requires_openai_auth = false"
    print "supports_websockets = false"
  }
' "${config_file}" > "${tmp_file}"

mv "${tmp_file}" "${config_file}"

# Keep the container alive. The image entrypoint already created the tmux session
# used by `./myCodex attach`; this replaces the entrypoint's own keep-alive.
exec sleep infinity
