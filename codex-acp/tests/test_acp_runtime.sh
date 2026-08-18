#!/usr/bin/env bash
# End-to-end ACP framing and capability-boundary regression test.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vaka-codex-acp-runtime.XXXXXX")"
RECIPE="${TMP}/recipe"
WORKSPACE="${TMP}/workspace-${RANDOM}"
PROJECT_NAME="$(basename -- "${WORKSPACE}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
CONTAINER="${PROJECT_NAME}-codex"
STATE_VOLUME="${PROJECT_NAME}_codex_state"

cleanup() {
  if [[ -d "${WORKSPACE}" && -x "${RECIPE}/myCodexACP" ]]; then
    (
      cd "${WORKSPACE}"
      MYCODEX_AUTH=openai "${RECIPE}/myCodexACP" down -v
    ) >/dev/null 2>&1 || true
  fi
  rm -rf -- "${TMP}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v vaka >/dev/null 2>&1 || fail "vaka is required"

cp -a "${RECIPE_SOURCE}" "${RECIPE}"
rm -rf -- "${RECIPE}/.secrets" "${RECIPE}/.workspaces"
mkdir -p "${WORKSPACE}"

# stdio is deliberately attach-only. An ACP client's first connection must not
# build images, start services, create state, or initiate authentication.
stdio_before_start_out="${TMP}/stdio-before-start.out"
stdio_before_start_err="${TMP}/stdio-before-start.err"
if (
  cd "${WORKSPACE}"
  MYCODEX_AUTH=openai "${RECIPE}/myCodexACP" stdio
) >"${stdio_before_start_out}" 2>"${stdio_before_start_err}"; then
  fail "stdio succeeded before start"
fi
[[ ! -s "${stdio_before_start_out}" ]] \
  || fail "stdio emitted protocol-unsafe stdout before start"
grep -Fq "run 'myCodexACP start'" "${stdio_before_start_err}" \
  || fail "stdio failure did not direct the user to start"
if docker volume inspect "${STATE_VOLUME}" >/dev/null 2>&1; then
  fail "stdio created the workspace state volume"
fi
if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  fail "stdio created the Codex container"
fi
echo "ok: stdio before start fails on stderr without creating runtime state"

(
  cd "${WORKSPACE}"
  MYCODEX_AUTH=openai OPENAI_API_KEY=test-only-key \
    "${RECIPE}/myCodexACP" start
)

cd "${WORKSPACE}"
status_output="$(MYCODEX_AUTH=openai "${RECIPE}/myCodexACP" status)"
grep -Fq "workspace         ${WORKSPACE}" <<<"${status_output}" \
  || fail "status did not report the workspace"
grep -Fq 'profile           openai' <<<"${status_output}" \
  || fail "status did not report the active profile"
grep -Fq 'codex container   running' <<<"${status_output}" \
  || fail "status did not report the Codex container as running"
grep -Fq 'ACP broker        ready' <<<"${status_output}" \
  || fail "status did not report the ACP broker as ready"
grep -Fq 'LiteLLM gateway   running' <<<"${status_output}" \
  || fail "status did not report LiteLLM as running"
grep -Fq "state volume      ${STATE_VOLUME} [exists]" <<<"${status_output}" \
  || fail "status did not report the per-workspace state volume"
echo "ok: start waits for the broker and status reports the complete stack"

python3 - "${RECIPE}/myCodexACP" "${CONTAINER}" "$(id -u)" <<'PY'
import json
import os
import select
import subprocess
import sys

launcher, container, expected_uid = sys.argv[1:]
env = {
    **os.environ,
    "MYCODEX_AUTH": "openai",
    "OPENAI_API_KEY": "test-only-key",
}
proc = subprocess.Popen(
    [launcher, "stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=env,
)

request = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {"protocolVersion": 1, "clientCapabilities": {}},
}
proc.stdin.write(json.dumps(request) + "\n")
proc.stdin.flush()

ready, _, _ = select.select([proc.stdout], [], [], 20)
if not ready:
    proc.terminate()
    raise SystemExit("FAIL: timed out waiting for ACP initialize response")

line = proc.stdout.readline()
try:
    response = json.loads(line)
except json.JSONDecodeError as error:
    proc.terminate()
    raise SystemExit(
        f"FAIL: ACP stdout was not one clean JSON line: {line!r} ({error})"
    )
if response.get("id") != 1 or response.get("result", {}).get("protocolVersion") != 1:
    proc.terminate()
    raise SystemExit(f"FAIL: unexpected ACP initialize response: {response!r}")
if response.get("result", {}).get("agentInfo", {}).get("name") != (
    "@agentclientprotocol/codex-acp"
):
    proc.terminate()
    raise SystemExit("FAIL: response did not come from codex-acp")
auth_ids = {
    method.get("id") for method in response.get("result", {}).get("authMethods", [])
}
if "chat-gpt" in auth_ids:
    proc.terminate()
    raise SystemExit("FAIL: adapter advertised a second in-container browser flow")

probe = r'''
for p in /proc/[0-9]*; do
  pid=${p##*/}
  [ "${pid}" = "$$" ] && continue
  cmd=$(tr '\0' ' ' < "${p}/cmdline" 2>/dev/null || true)
  case "${cmd}" in
    *"/opt/codex-acp/acp-broker.mjs"*|*"/opt/codex-acp/acp-connect.mjs"*|*"/opt/codex-acp/node_modules/.bin/codex-acp"*|*"codex app-server"*)
      uid=$(awk '/^Uid:/{print $2}' "${p}/status")
      eff=$(awk '/^CapEff:/{print $2}' "${p}/status")
      bnd=$(awk '/^CapBnd:/{print $2}' "${p}/status")
      nnp=$(awk '/^NoNewPrivs:/{print $2}' "${p}/status")
      ppid=$(awk '/^PPid:/{print $2}' "${p}/status")
      printf '%s|%s|%s|%s|%s|%s|%s\n' "${pid}" "${ppid}" "${uid}" "${eff}" "${bnd}" "${nnp}" "${cmd}"
      ;;
  esac
done
'''
rows = subprocess.check_output(
    ["docker", "exec", container, "sh", "-c", probe], text=True
).splitlines()
processes = []
for row in rows:
    pid, ppid, uid, effective, bounding, no_new_privs, command = row.split("|", 6)
    processes.append(
        {
            "pid": int(pid),
            "ppid": int(ppid),
            "uid": uid,
            "effective": int(effective, 16),
            "bounding": int(bounding, 16),
            "no_new_privs": no_new_privs,
            "command": command,
        }
    )

broker = next((p for p in processes if "acp-broker.mjs" in p["command"]), None)
adapter = next(
    (p for p in processes if "node_modules/.bin/codex-acp" in p["command"]), None
)
connector = next((p for p in processes if "acp-connect.mjs" in p["command"]), None)
app_servers = [p for p in processes if "codex app-server" in p["command"]]
if not broker or not adapter or not connector or not app_servers:
    proc.terminate()
    raise SystemExit(f"FAIL: incomplete ACP process tree: {processes!r}")

net_admin = 1 << 12
safe_tree = [broker, adapter, *app_servers]
for process in safe_tree:
    if process["bounding"] & net_admin:
        proc.terminate()
        raise SystemExit(
            f"FAIL: NET_ADMIN remains in capability bounding set: {process!r}"
        )
    if process["uid"] != expected_uid:
        proc.terminate()
        raise SystemExit(f"FAIL: ACP process does not use the host UID: {process!r}")
if adapter["ppid"] != broker["pid"]:
    proc.terminate()
    raise SystemExit(
        f"FAIL: adapter is not a direct child of the original-session broker: {processes!r}"
    )
if connector["effective"] != 0 or connector["no_new_privs"] != "1":
    proc.terminate()
    raise SystemExit(f"FAIL: docker-exec relay is not constrained: {connector!r}")

proc.stdin.close()
try:
    status = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.terminate()
    raise SystemExit("FAIL: ACP relay did not exit after stdin EOF")
if status != 0:
    raise SystemExit(
        f"FAIL: ACP relay exited with {status}: {proc.stderr.read()!r}"
    )

print(
    "PASS: clean ACP stdio; broker-spawned adapter/app-server lack NET_ADMIN; "
    "exec relay has no_new_privs"
)
PY

MYCODEX_AUTH=openai "${RECIPE}/myCodexACP" stop
stopped_status="$(MYCODEX_AUTH=openai "${RECIPE}/myCodexACP" status)"
grep -Fq 'codex container   exited' <<<"${stopped_status}" \
  || fail "stop did not leave the Codex container stopped"
grep -Fq 'ACP broker        not ready' <<<"${stopped_status}" \
  || fail "status reported a broker after stop"
grep -Fq 'LiteLLM gateway   not running' <<<"${stopped_status}" \
  || fail "stop did not stop LiteLLM"
docker volume inspect "${STATE_VOLUME}" >/dev/null 2>&1 \
  || fail "stop deleted the workspace state volume"
echo "PASS: canonical start/status/stdio/stop lifecycle retains state"
