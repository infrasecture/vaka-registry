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
- Credentials for one supported authentication profile: an OpenAI API key, a
  ChatGPT subscription, or the external credentials required by an experimental
  profile.

## How To Run It

Run `myCodex` from the project directory you want the agent to work on — **not** from this recipe directory (that would mount the recipe's own `.secrets` into the container).

```sh
cd /path/to/your/project
/path/to/codex/myCodex
```

With no selected profile, normal startup keeps the compatible `openai` default:
`myCodex` asks for your `OPENAI_API_KEY`, stores the entered value under the
recipe's `.secrets/`, creates an internal LiteLLM key, starts the stack, and
attaches you to the Codex session. Use `myCodex login` to choose another profile.

### Secret sources

Each secret is resolved in this order:

1. A direct environment value (`OPENAI_API_KEY` or `LITELLM_MASTER_KEY`).
2. The file named by `OPENAI_API_KEY_FILE` or `LITELLM_MASTER_KEY_FILE`.
3. Its managed file under the recipe's `.secrets/` directory.
4. An interactive prompt for the provider key, or random generation for the
   embedded LiteLLM key.

Set either the direct value or its `_FILE` alternative, not both. Explicit file
sources may be symlinks and are never copied, rewritten, or chmodded by
`myCodex`; this supports files materialized by a secret manager.

Managed storage is different: `.secrets` and the managed files beneath it must
not be symlinks. This guards against a persistent accidental or planted link
redirecting a managed secret read or write outside the recipe; it is not a
privilege boundary against another process running as the same user. The
directory is not shipped in the recipe archive; `myCodex` creates it with mode
`0700` when needed and creates managed files with mode `0600`. Existing files
and directories are not silently chmodded.

The generated key is stored in `.secrets/litellm_master_key` and reused.
Keeping it stable prevents an unchanged `myCodex` invocation from recreating
both containers. The `.secrets` directory is untracked recipe state, so
`vaka get` updates preserve it.

Your project directory is mounted inside the container **at its own host path** (path parity), and that is the working directory. Only that directory is bind-mounted; files outside it are not shared with the container.

The container runs as your host user (same UID/GID), so files the agent creates under your project stay owned by you rather than by root. `myCodex` collects your host identity and passes it to the stack — this is why you run through it and not bare `docker compose`.

Common commands:

```sh
/path/to/codex/myCodex            # start (if needed) and attach
/path/to/codex/myCodex ps
/path/to/codex/myCodex stop
/path/to/codex/myCodex restart
/path/to/codex/myCodex exec bash
/path/to/codex/myCodex auth status
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

## Authentication Profiles

Authentication is selected once through `myCodex login` and then remembered:

```sh
/path/to/codex/myCodex login chatgpt
/path/to/codex/myCodex                 # uses chatgpt from now on
```

Run `myCodex login` without a profile to use the stored selection or, when none
exists, choose interactively. The selected profile is written atomically to
`.secrets/auth_profile` only after credential acquisition succeeds. Failed or
cancelled login therefore leaves the previous selection intact.

The agent container is unaffected by the choice: it always reaches the model
only through the sidecar with the internal proxy key, so switching profiles does
not widen the agent's egress policy.

| Profile | Upstream auth | How you provide it |
| --- | --- | --- |
| `openai` (compatibility default) | OpenAI API key | `myCodex login openai` (prompt / env / `_FILE`) |
| `chatgpt` | ChatGPT subscription (OAuth) | `myCodex login chatgpt` — one-time device login |
| `vertex` (scaffold) | Google Vertex AI service account | `MYCODEX_VERTEX_CREDENTIALS=/path/to/sa.json` + `VERTEXAI_PROJECT` |

Each non-default profile lives under `auth-profiles/<id>/` as data — a compose
overlay, a LiteLLM config, and its own egress policy whose agent block is
identical to the default (only the sidecar's upstream hosts change). Adding a new
API-key provider (e.g. Anthropic) is a new profile directory with no wrapper
dispatch changes. `PROFILE_DISPLAY_NAME` in `profile.env` supplies its label in
the interactive selector and `auth list`.

Profile management commands are local and do not contact a provider unless they
perform `login`:

```sh
/path/to/codex/myCodex auth list
/path/to/codex/myCodex auth status
/path/to/codex/myCodex logout chatgpt
```

`logout` removes only credentials managed under this recipe's `.secrets/` and
clears a matching stored selection. It never deletes an external credential
file or changes the caller's environment. Existing containers are not stopped;
bring a running project down when it must no longer retain its current session.

For automation or a temporary exception, put `--auth <profile>` first on the
command line, or set `MYCODEX_AUTH`. These override the stored selection for one
invocation and are not persisted:

```sh
/path/to/codex/myCodex --auth openai info
MYCODEX_AUTH=vertex /path/to/codex/myCodex up
```

Runtime precedence is `--auth`, `MYCODEX_AUTH`, the stored profile, then the
`openai` compatibility default. A profile argument to `login` is the explicit
login target and becomes the stored profile only on success.

Switching an existing project between profiles requires recreating the stack.
The Codex container is labeled with the profile that created it. `login`,
`start`, `restart`, and implicit attach refuse to replace a container created for
another profile; run `myCodex down` first. An explicit `myCodex up` remains the
operation that may apply a changed profile by recreating the stack.

### ChatGPT subscription

```sh
/path/to/codex/myCodex login chatgpt   # one-time device login and selection
/path/to/codex/myCodex                 # then run normally, with no environment flag
```

`login` surfaces LiteLLM's own OAuth device flow: it prints a URL and a code —
open the URL, sign in, enter the code. LiteLLM stores the token under the recipe's
`.secrets/chatgpt-token/` (mounted only into the sidecar, never the agent) and
refreshes it automatically thereafter. If you already have a Codex
`~/.codex/auth.json`, import it instead with
`MYCODEX_CHATGPT_AUTH=~/.codex/auth.json ./myCodex login chatgpt`.

Login starts only the LiteLLM service; it does not create or replace the Codex
container. Output is followed from the beginning of the current attempt before
readiness is checked, so a device URL/code or startup failure cannot be hidden
behind the readiness wait. The readiness probe runs over localhost inside the
sidecar, reports its current failure while retrying, and has a 60-second ceiling.

Once ready, the wrapper makes exactly one device-flow request and allows up to 15
minutes for browser login and MFA. A status line is printed every 30 seconds
while authorization is pending. Press Ctrl-C to cancel. Configuration, network,
or provider failures terminate that request and are reported directly; the
wrapper never creates device codes in a retry loop. A sidecar started solely for
login is removed afterwards, while an already-running sidecar is left running.
If local startup or provider policy requires a different limit, set
`MYCODEX_CHATGPT_READY_TIMEOUT` or `MYCODEX_CHATGPT_LOGIN_TIMEOUT` to a positive
number of seconds.

> The `chatgpt` and `vertex` profiles are new and depend on provider-side
> behavior (LiteLLM's `chatgpt/` provider and a chatgpt-capable image; a real
> Vertex project). Verify them in your environment before relying on them; the
> default `openai` profile is unchanged.

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

The Codex workstation image uses the bundled Codex version tag (currently
`0.146.0`) instead of a manifest-list digest. This lets Docker select the
native platform image consistently on Linux and VM-backed macOS engines such
as Colima. The tag can advance to a newer workstation image revision that
still bundles the same Codex version; it does not track a different Codex
version. The LiteLLM image remains digest-pinned.

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

### Shared LiteLLM gateways

The LiteLLM service in this recipe is an embedded sidecar owned by this Compose
project. Its master key is an internal credential for that one gateway. Other
recipes should not join its private network or reuse that master key: bringing
this stack down would also remove their gateway, and sharing an administrative
credential would couple their security boundaries.

A future shared gateway should be a separate recipe with an independent
lifecycle, a stable external Docker network and alias, and a separate client
credential for each consumer. LiteLLM supports centralized gateway operation
and virtual keys, but that topology is not implemented by this recipe. See the
[LiteLLM proxy documentation](https://docs.litellm.ai/).

## Stopping The Stack

From your project directory, run:

```sh
/path/to/codex/myCodex stop
```

Starting it again reuses the existing LiteLLM proxy key. To rotate that internal
key, bring the stack down, remove `.secrets/litellm_master_key` from the recipe
directory, and start it again. A non-empty `LITELLM_MASTER_KEY` or
`LITELLM_MASTER_KEY_FILE` overrides the stored key for that invocation and is
never persisted. Changing the selected key intentionally changes the Compose
configuration and recreates both services on the next `up`.

## How It's Assembled

The launcher (`bin/myCodex` and `bin/lib/`) is vendored verbatim from the upstream
[myCodex](https://github.com/emsi/myCodex) project. The top-level `myCodex`
wrapper manages provider selection and credentials and points the launcher at
vaka (via `MYCODEX_COMPOSE`) for egress enforcement. `docker-compose.yaml`
defines the two services, using a portable SemVer workstation image and a
digest-pinned LiteLLM image; `vaka.yaml` defines the egress policy.

> Upgrading from an older version of this recipe? It previously shipped a `compose.yaml`; the current layout uses `docker-compose.yaml`. `vaka get` removes the old file automatically unless you edited it, in which case it is kept and you can delete the leftover `compose.yaml` yourself.

> The first `up` after upgrading from 0.2.2 or older establishes the persistent
> LiteLLM key and may recreate both services once. Later invocations leave
> unchanged containers in place.

## Recipe Tests

Codex-specific regressions live with the recipe rather than in registry-global
validation. Maintainers can run them from the registry checkout with:

```sh
codex/tests/run.sh
```

The wrapper and profile tests are self-contained. `test_wrapper.sh` covers secret
resolution; `test_profiles.sh` covers profile state and precedence, dispatch,
the identical-agent-egress invariant, and credential handlers; `test_login.sh`
covers sidecar scope, early log visibility, readiness diagnostics, timeouts, and
process/service cleanup. The Compose rendering test (`test_compose.py`, which
also renders the profile overlays) additionally requires Docker Compose.
