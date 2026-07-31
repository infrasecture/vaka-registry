# Secure Codex Container With Vaka

This recipe runs Codex inside a Docker container whose outbound network access is restricted by vaka. The goal is to let an agent work on your code while limiting what it can send to the internet.

The setup uses two containers:

- `codex`: the agent harness where Codex runs and where your project is mounted.
- `litellm`: a local LLM gateway that receives Codex model requests and forwards them to the model provider.

Vaka blocks direct egress from the Codex container. Codex can talk to the LiteLLM sidecar, but it cannot directly call arbitrary websites, pastebin services, webhooks, package hosts, or other internet endpoints. LiteLLM is the only path from the agent container to the LLM provider.

## Why This Exists

LLM agents can be tricked by prompts, repository content, test output, or tool results. A malicious instruction might ask the agent to reveal API keys, upload private source code, or send sensitive files to an external server.

This recipe reduces that risk by isolating the agent inside a container with blocked egress. Even if the agent is jailbroken or prompted to exfiltrate data, the Codex container cannot directly connect to the internet. Its blast radius is the code and files in the project directory you run it from.

This does not make unsafe code safe, and it does not hide files that you place inside the mounted project directory. If a secret is present under the project directory you run from, the agent may be able to read it. The protection is that the agent should not have a direct network path to send that secret somewhere else.

## What You Need

- Docker with Compose v2.
- `vaka` installed and on your `PATH` — it is **required**; every Compose call is routed through it for egress enforcement.
- Bash 4.4 or newer. On macOS, install it with Homebrew; the launcher will use
  a compatible Bash from `$SHELL` automatically when `/usr/bin/env bash` finds
  the older system Bash.
- An OpenAI API key, provided when prompted or through `OPENAI_API_KEY`.

## How To Run It

Run `myCodex` from the project directory you want the agent to work on — **not** from this recipe directory (that would mount the recipe's own `.secrets` into the container).

```sh
cd /path/to/your/project
/path/to/codex/myCodex
```

On first run, `myCodex` asks for your `OPENAI_API_KEY` if it is not already set,
stores the entered value under the recipe's `.secrets/`, creates an internal
LiteLLM key, starts the stack, and attaches you to the Codex session. Values
supplied through the environment are used without being copied to disk.

The internal key is stored in `.secrets/litellm_master_key` with mode `0600`
and reused. Keeping it stable prevents an unchanged `myCodex` invocation from
recreating both containers. The `.secrets` directory is untracked recipe state,
so `vaka get` updates preserve it.

Your project directory is mounted inside the container **at its own host path** (path parity), and that is the working directory. Only that directory is bind-mounted; files outside it are not shared with the container.

The container runs as your host user (same UID/GID), so files the agent creates under your project stay owned by you rather than by root. `myCodex` collects your host identity and passes it to the stack — this is why you run through it and not bare `docker compose`.

Common commands:

```sh
/path/to/codex/myCodex            # start (if needed) and attach
/path/to/codex/myCodex ps
/path/to/codex/myCodex stop
/path/to/codex/myCodex restart
/path/to/codex/myCodex exec bash
```

To see the resolved configuration — project name, image, container home/workdir,
host identity, and the **state volume name** (and whether it exists yet) — without
starting anything:

```sh
/path/to/codex/myCodex info
```

### Per-project state (default)

Each project directory gets its **own** Codex state volume (home, config, history), so state never drifts between projects or leaks across them. To share a single state volume across all projects instead, set `MYCODEX_SHARED_STATE=1`:

```sh
MYCODEX_SHARED_STATE=1 /path/to/codex/myCodex
```

## How The Network Boundary Works

The Codex container has a strict vaka egress policy (`vaka.yaml`):

- It can resolve DNS.
- It can connect to the `litellm` sidecar on port `4000`.
- Other outbound connections are rejected.

The LiteLLM sidecar has its own narrower allowlist for LLM-provider traffic. In this recipe it can reach the model-provider endpoints needed to serve as the gateway.

In normal use, Codex sends model requests to:

```text
http://litellm:4000/v1
```

LiteLLM forwards those requests using the real provider API key. Codex receives
only the local proxy key shared with LiteLLM, never the real provider key.

## Practical Security Model

This recipe is meant to limit accidental or prompt-driven data exfiltration from the agent harness.

It helps with:

- A prompt injection that tells the agent to upload files to an external URL.
- A malicious repository instruction that asks the agent to leak environment variables.
- A compromised tool result that tries to make the agent call out to an attacker-controlled service.

It does not solve:

- Secrets that are already committed or stored inside the mounted project directory.
- Commands that change or delete files inside the project directory.
- Trust decisions about code the agent writes for you.
- All possible Docker, host, or kernel escape risks.

Treat the project directory as the allowed blast radius. Put only the project files the agent needs there, and keep unrelated secrets outside it.

## Extending The Setup

You can add more sidecar containers when the agent needs controlled access to a service. Instead of letting Codex reach the internet directly, add a local sidecar for the capability you want and allow Codex to talk only to that sidecar.

Possible extensions include:

- A package cache or internal registry proxy.
- A database container with test data.
- A documentation search service.
- A browser or web-fetch service with its own policy.
- Docker's MCP Gateway: https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/

The pattern is the same: keep Codex blocked by default, give it access to a narrow local service, and put the internet-facing permissions on that service only when needed.

You can also relax `vaka.yaml` to allow Codex to reach specific hosts directly. That is possible but not recommended as the default: each extra allowed destination is another place a jailbroken or misled agent could send sensitive data.

## Stopping The Stack

From your project directory, run:

```sh
/path/to/codex/myCodex stop
```

Starting it again reuses the existing LiteLLM proxy key. To rotate that internal
key, bring the stack down, remove `.secrets/litellm_master_key` from the recipe
directory, and start it again. A non-empty `LITELLM_MASTER_KEY` environment
value overrides the stored key for that invocation and is never persisted.

## How It's Assembled

The launcher (`bin/myCodex` and `bin/lib/`) is vendored verbatim from the upstream [myCodex](https://github.com/emsi/myCodex) project; the top-level `myCodex` is a thin wrapper that adds the secrets and points the launcher at vaka (via `MYCODEX_COMPOSE`) for egress enforcement. `docker-compose.yaml` defines the two services (both images pinned by digest) and `vaka.yaml` is the egress policy.

> Upgrading from an older version of this recipe? It previously shipped a `compose.yaml`; the current layout uses `docker-compose.yaml`. `vaka get` removes the old file automatically unless you edited it, in which case it is kept and you can delete the leftover `compose.yaml` yourself.

> The first `up` after upgrading from 0.2.2 or older establishes the persistent
> LiteLLM key and may recreate both services once. Later invocations leave
> unchanged containers in place.
