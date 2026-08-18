#!/usr/bin/env bash
# Public command-surface regression checks. These do not require Docker.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vaka-codex-acp-control.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

RECIPE="${TMP}/recipe"
cp -a "${RECIPE_SOURCE}" "${RECIPE}"
rm -rf -- "${RECIPE}/.secrets" "${RECIPE}/.workspaces"

[[ -x "${RECIPE}/myCodexACP" ]] \
  || fail "the public myCodexACP launcher is missing or not executable"
[[ -x "${RECIPE}/bin/myCodexACP" ]] \
  || fail "the internal myCodexACP launcher is missing or not executable"
[[ ! -e "${RECIPE}/myCodex" && ! -e "${RECIPE}/bin/myCodex" ]] \
  || fail "the obsolete myCodex command is still distributed"

help_output="$(cd "${RECIPE}" && ./myCodexACP)"
for command in start login status stdio stop down; do
  grep -Eq "^[[:space:]]+myCodexACP .*${command}" <<<"${help_output}" \
    || fail "no-command help does not advertise '${command}'"
done
[[ ! -e "${RECIPE}/.workspaces" ]] \
  || fail "no-command help created a workspace"
[[ ! -e "${RECIPE}/.secrets" ]] \
  || fail "no-command help created credential state"

explicit_help="$(cd "${RECIPE}" && ./myCodexACP help)"
grep -Fq 'Additional authentication commands:' <<<"${explicit_help}" \
  || fail "explicit help omitted the additional authentication commands"
[[ ! -e "${RECIPE}/.workspaces" ]] \
  || fail "explicit help created a workspace"
[[ ! -e "${RECIPE}/.secrets" ]] \
  || fail "explicit help created credential state"

echo "PASS: myCodexACP exposes the six-command lifecycle without setup side effects"
