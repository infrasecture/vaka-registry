#!/usr/bin/env python3
"""Exercise the real launcher dispatch without containers or provider calls."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


launcher = Path(__file__).resolve().parent.parent / "bin/myCodex"
with tempfile.TemporaryDirectory(prefix="vaka-launcher-build-") as directory:
    workdir = Path(directory)
    capture = workdir / "calls.jsonl"
    docker = workdir / "docker"
    docker.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["TEST_DOCKER_CALLS"], "a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1] == "inspect":
    print("running")
elif sys.argv[1] == "exec":
    print("ready")
''')
    docker.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{workdir}:{os.environ['PATH']}",
        "MYCODEX_COMPOSE": "docker compose",
        "MYCODEX_IMAGE_NAME": "registry.invalid/launcher-test",
        "MYCODEX_IMAGE_TAG": "1.2.3-r1",
        "TEST_DOCKER_CALLS": str(capture),
    }
    cases = (
        ([], ["up", "-d", "--build"]),
        (["up"], ["up", "--build"]),
        (["create"], ["create", "--build"]),
        (["up", "--wait"], ["up", "--build", "-d"]),
        (["up", "--no-build"], ["up", "--no-build"]),
        (["create", "--no-build"], ["create", "--no-build"]),
        (["up", "--wait", "--no-build"], ["up", "-d", "--no-build"]),
        (["up", "--build", "litellm"], ["up", "--build", "litellm"]),
        (["pull", "--quiet", "codex"], ["pull", "--ignore-buildable", "--quiet", "codex"]),
    )
    for args, expected in cases:
        capture.write_text("")
        subprocess.run(["bash", str(launcher), *args], cwd=workdir, env=env, check=True,
                       capture_output=True, text=True)
        calls = [json.loads(line) for line in capture.read_text().splitlines()]
        # Compose prefix is: compose -p <project> -f <recipe file>.
        dispatch = [call[5:] for call in calls if call[0] == "compose"
                    and call[5] in {"up", "create", "pull"}]
        if dispatch != [expected]:
            raise SystemExit(f"FAIL: launcher {args!r} dispatched {dispatch!r}, expected {expected!r}")

print("PASS: launcher builds by default, honors explicit overrides, and skips builds on pull")
