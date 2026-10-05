#!/usr/bin/env bash
# End-to-end ACP framing and capability-boundary regression test.
set -euo pipefail

RECIPE_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vaka-codex-acp-runtime.XXXXXX")"
RECIPE="${TMP}/recipe"
WORKSPACE="${TMP}/workspace-${RANDOM}"
PROJECT_NAME="$(basename -- "${WORKSPACE}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
CONTAINER="${PROJECT_NAME}-codex-acp"
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
grep -Fq "run 'myCodexACP' interactively" "${stdio_before_start_err}" \
  || fail "stdio failure did not direct the user to interactive startup"
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
    "${RECIPE}/myCodexACP"
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
grep -Fq 'LiteLLM gateway   ready' <<<"${status_output}" \
  || fail "status did not report LiteLLM as ready"
grep -Fq "state volume      ${STATE_VOLUME} [exists]" <<<"${status_output}" \
  || fail "status did not report the per-workspace state volume"
echo "ok: default startup waits for authentication and broker readiness"

python3 - "${RECIPE}/myCodexACP" "${CONTAINER}" "$(id -u)" <<'PY'
import json
import os
import select
import subprocess
import sys
import time

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

pending = b""


def fail(message):
    proc.terminate()
    raise SystemExit(f"FAIL: {message}")


def rpc(request_id, method, params):
    global pending
    request = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
    deadline = time.monotonic() + 30
    while True:
        while b"\n" not in pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([proc.stdout], [], [], remaining)[0]:
                fail(f"timed out waiting for ACP {method} response")
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                fail(f"ACP stdout closed while waiting for {method}")
            pending += chunk
        line, pending = pending.split(b"\n", 1)
        try:
            response = json.loads(line)
        except (ValueError, UnicodeDecodeError) as error:
            fail(f"ACP stdout was not one clean JSON line: {line!r} ({error})")
        if not isinstance(response, dict) or response.get("jsonrpc") != "2.0":
            fail(f"invalid ACP message: {response!r}")
        if response.get("id") == request_id:
            if "error" in response or "result" not in response:
                fail(f"ACP {method} failed: {response!r}")
            return response
        if "id" in response or not isinstance(response.get("method"), str):
            fail(f"unexpected ACP message while waiting for {method}: {response!r}")
        # Session creation may emit notifications before its response. Drain
        # complete lines without losing bytes already read from the pipe.


response = rpc(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}})
if response.get("id") != 1 or response.get("result", {}).get("protocolVersion") != 1:
    proc.terminate()
    raise SystemExit(f"FAIL: unexpected ACP initialize response: {response!r}")
if response.get("result", {}).get("agentInfo", {}).get("name") != (
    "@agentclientprotocol/codex-acp"
):
    proc.terminate()
    raise SystemExit("FAIL: response did not come from codex-acp")
if response.get("result", {}).get("agentInfo", {}).get("version") != "2.1.1":
    proc.terminate()
    raise SystemExit(f"FAIL: unexpected ACP adapter version: {response!r}")
auth_ids = {
    method.get("id") for method in response.get("result", {}).get("authMethods", [])
}
if "chat-gpt" in auth_ids:
    proc.terminate()
    raise SystemExit("FAIL: adapter advertised a second in-container browser flow")

# Exercise the adapter/backend API beyond the initialize handshake, without
# submitting a prompt or making a paid provider request.
session = rpc(2, "session/new", {"cwd": os.getcwd(), "mcpServers": []})["result"]
session_id = session.get("sessionId")
if not isinstance(session_id, str) or not session_id:
    fail(f"session/new did not return a session ID: {session!r}")
modes = {mode.get("id") for mode in session.get("modes", {}).get("availableModes", [])}
if not {"read-only", "workspace-write", "agent-full-access"}.issubset(modes):
    fail(f"session/new did not advertise the expected access presets: {modes!r}")
rpc(3, "session/set_mode", {"sessionId": session_id, "modeId": "read-only"})
print("PASS: ACP v1 session creation and read-only mode selection")

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

# Check the executable of the running app-server, not whichever Codex happens
# to be on PATH (the harness CLI has an independent version).
for app_server in app_servers:
    executable = f"/proc/{app_server['pid']}/exe"
    backend_path = subprocess.check_output(
        ["docker", "exec", "--user", expected_uid, container, "readlink", executable],
        text=True,
    ).strip()
    if not backend_path.startswith("/opt/codex-acp/node_modules/"):
        fail(f"app-server is not the adapter-bundled Codex: {backend_path!r}")
    backend_version = subprocess.check_output(
        ["docker", "exec", "--user", expected_uid, container, executable, "--version"],
        text=True,
    ).strip()
    if backend_version != "codex-cli 0.159.3":
        fail(f"unexpected running ACP backend version: {backend_version!r}")
print("PASS: adapter 2.1.1 runs its locked Codex 0.159.3 backend")

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

rpc(4, "session/close", {"sessionId": session_id})
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
echo "PASS: default startup/status/stdio/stop lifecycle retains state"
