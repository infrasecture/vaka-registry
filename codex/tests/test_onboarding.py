#!/usr/bin/env python3
"""Regression checks for first-run authentication onboarding."""

from __future__ import annotations

import errno
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time


SOURCE = Path(__file__).resolve().parent.parent


def fail(message: str, output: bytes = b"") -> None:
    detail = output.decode("utf-8", "replace")
    raise AssertionError(f"{message}\n--- output ---\n{detail}")


def clean_env(fake_bin: Path, capture: Path) -> dict[str, str]:
    env = os.environ.copy()
    for name in (
        "MYCODEX_AUTH",
        "MYCODEX_CHATGPT_AUTH",
        "MYCODEX_VERTEX_CREDENTIALS",
        "OPENAI_API_KEY",
        "OPENAI_API_KEY_FILE",
        "LITELLM_MASTER_KEY",
        "LITELLM_MASTER_KEY_FILE",
    ):
        env.pop(name, None)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["MYCODEX_TEST_CAPTURE"] = str(capture)
    return env


def run_in_pty(
    command: list[str], cwd: Path, env: dict[str, str], exchanges: list[tuple[bytes, bytes]]
) -> tuple[int, bytes]:
    pid, master = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execve(command[0], command, env)

    output = bytearray()
    exchange = 0
    status: int | None = None
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(master, 4096)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    chunk = b""
                output.extend(chunk)

            if exchange < len(exchanges) and exchanges[exchange][0] in output:
                os.write(master, exchanges[exchange][1])
                exchange += 1

            waited, status = os.waitpid(pid, os.WNOHANG)
            if waited == pid:
                break
        else:
            os.kill(pid, signal.SIGTERM)
            _, status = os.waitpid(pid, 0)
            fail("interactive onboarding timed out", bytes(output))
    finally:
        os.close(master)

    if status is None:
        _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status), bytes(output)


with tempfile.TemporaryDirectory(prefix="vaka-codex-onboarding.") as temp:
    root = Path(temp)
    recipe = root / "recipe"
    workspace = root / "workspace"
    fake_bin = root / "fake-bin"
    capture = root / "launcher-argv"
    (recipe / "bin").mkdir(parents=True)
    workspace.mkdir()
    fake_bin.mkdir()

    shutil.copy2(SOURCE / "myCodex", recipe / "myCodex")
    shutil.copy2(SOURCE / "vaka.yaml", recipe / "vaka.yaml")
    shutil.copytree(SOURCE / "auth-profiles", recipe / "auth-profiles")

    launcher = recipe / "bin" / "myCodex"
    launcher.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        ": \"${MYCODEX_TEST_CAPTURE:?}\"\n"
        "printf '%s\\n' \"$@\" > \"${MYCODEX_TEST_CAPTURE}\"\n"
        "printf '%s\\n' \"${LITELLM_MASTER_KEY-}\" > \"${MYCODEX_TEST_CAPTURE}.gateway-admin\"\n",
        encoding="utf-8",
    )
    launcher.chmod(0o755)

    docker = fake_bin / "docker"
    docker.write_text(
        "#!/usr/bin/env bash\n"
        "[[ \"${1:-}\" == ps ]] && exit 0\n"
        "exit 1\n",
        encoding="utf-8",
    )
    docker.chmod(0o755)

    env = clean_env(fake_bin, capture)
    command = [str(recipe / "myCodex"), "up"]
    code, output = run_in_pty(
        command,
        workspace,
        env,
        [
            (b"Profile [1]:", b"2\n"),
            (b"Enter OPENAI_API_KEY:", b"\n"),
        ],
    )
    if code == 0:
        fail("first-run setup accepted an empty provider credential", output)
    if (recipe / ".secrets" / "auth_profile").exists():
        fail("failed first-run setup persisted its profile", output)
    print("ok: failed first-run authentication leaves no selected profile")

    code, output = run_in_pty(
        command,
        workspace,
        env,
        [
            (b"Profile [1]:", b"2\n"),
            (b"Enter OPENAI_API_KEY:", b"test-provider-key\n"),
        ],
    )
    if code != 0:
        fail(f"interactive onboarding exited {code}", output)
    menu = output.find(b"Choose how myCodex should authenticate:")
    key_prompt = output.find(b"Enter OPENAI_API_KEY:")
    if menu < 0 or key_prompt < 0 or menu > key_prompt:
        fail("authentication choice was not shown before the API-key prompt", output)
    if b"1) chatgpt" not in output or b"2) openai" not in output:
        fail("onboarding did not put ChatGPT before the API-key option", output)
    if (recipe / ".secrets" / "auth_profile").read_text().strip() != "openai":
        fail("successful onboarding did not persist the chosen profile", output)
    print("ok: first interactive startup chooses authentication before prompting for a key")

    # ChatGPT device login runs in a cleanup-scoped subshell. A complete token
    # makes this deterministic while proving the parent reacquires the managed
    # LiteLLM administrator key before it launches the requested stack.
    (recipe / ".secrets" / "auth_profile").unlink()
    (recipe / ".secrets" / "openai_api_key").unlink()
    token_dir = recipe / ".secrets" / "chatgpt-token"
    token_dir.mkdir(mode=0o700)
    (token_dir / "auth.json").write_text(
        '{"access_token":"existing-chatgpt-token"}\n', encoding="utf-8"
    )
    capture.unlink()
    (Path(f"{capture}.gateway-admin")).unlink(missing_ok=True)
    code, output = run_in_pty(
        command,
        workspace,
        clean_env(fake_bin, capture),
        [(b"Profile [1]:", b"1\n")],
    )
    if code != 0:
        fail(f"ChatGPT first startup exited {code}", output)
    gateway_key = Path(f"{capture}.gateway-admin").read_text().strip()
    managed_key = recipe / ".secrets" / "litellm_admin_key_restricted_v1"
    if not gateway_key or gateway_key != managed_key.read_text().strip():
        fail("ChatGPT first startup lost the sidecar administrator key after device login", output)
    if (recipe / ".secrets" / "auth_profile").read_text().strip() != "chatgpt":
        fail("ChatGPT first startup did not persist its selected profile", output)
    print("ok: ChatGPT first startup reacquires sidecar credentials after device login")

    (recipe / ".secrets" / "auth_profile").unlink()
    capture.unlink()

    result = subprocess.run(
        command,
        cwd=workspace,
        env=clean_env(fake_bin, capture),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        start_new_session=True,
        check=False,
    )
    if result.returncode == 0:
        fail("headless startup accepted an unselected profile", result.stderr.encode())
    if "no authentication profile is selected and input is not a terminal" not in result.stderr:
        fail("headless startup error was not actionable", result.stderr.encode())
    if capture.exists():
        fail("headless startup reached the launcher without authentication")
    print("ok: unconfigured headless startup fails with explicit setup guidance")

    env = clean_env(fake_bin, capture)
    env["OPENAI_API_KEY"] = "automation-provider-key"
    result = subprocess.run(
        command,
        cwd=workspace,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        start_new_session=True,
        check=False,
    )
    if result.returncode != 0:
        fail("headless OpenAI compatibility path failed", result.stderr.encode())
    if (recipe / ".secrets" / "auth_profile").exists():
        fail("an implicit headless compatibility choice was persisted")
    if capture.read_text().splitlines()[-1] != "up":
        fail("headless compatibility path did not reach the requested command")
    print("ok: explicit headless OpenAI credentials retain non-persistent compatibility")

print("PASS: first-run authentication onboarding")
