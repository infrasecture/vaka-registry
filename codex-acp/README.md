# Codex ACP recipe

This recipe exposes [codex-acp](https://github.com/agentclientprotocol/codex-acp)
as an ACP agent over stdio while keeping Codex in a Vaka-managed,
egress-restricted container. It is based on the **codex** recipe and retains its
workspace isolation, persistent state, tmux shell, LiteLLM gateway, and OpenAI
API-key, ChatGPT subscription, and Vertex profile flows.

The important implementation property is that **codex-acp is not started by
docker exec**. Every adapter is forked by a broker in the container's original
Vaka-initialized process tree, after Vaka has removed **NET_ADMIN** from that
tree's capability bounding set.

## Quick start

Run setup from the project directory the ACP agent should see:

~~~bash
cd /path/to/project
/path/to/codex-acp/myCodexACP login chatgpt   # or: login openai
/path/to/codex-acp/myCodexACP start
~~~

Then configure an ACP client to run:

~~~text
command: /absolute/path/to/codex-acp/myCodexACP
args:    stdio
cwd:     /path/to/project
~~~

For clients with JSON configuration, the equivalent shape is:

~~~json
{
  "command": "/absolute/path/to/codex-acp/myCodexACP",
  "args": ["stdio"],
  "cwd": "/path/to/project"
}
~~~

The client must leave stdin and stdout connected. **stdio** only attaches to an
already-started broker. It never builds containers, changes authentication, or
launches a browser; missing setup is reported on stderr with an instruction to
run **start**.

If the launcher is run from the recipe directory itself, it safely selects or
creates a child under **.workspaces/** instead of exposing the recipe, managed
credentials, or build files to the agent. With no terminal it uses the announced
**work** workspace.

## Commands

~~~bash
./myCodexACP start           # build/reconcile, start, and wait for the ACP broker
./myCodexACP login           # authenticate and persist a selected profile
./myCodexACP status          # read-only workspace, service, state, and broker status
./myCodexACP stdio           # attach one ACP client; requires start first
./myCodexACP stop            # stop both services and retain containers/state
./myCodexACP down            # remove the stack and retain Codex state
./myCodexACP down -v         # also delete this workspace's Codex state
~~~

With no command, the launcher prints help and performs no startup. Advanced
maintenance operations such as **attach**, **exec**, **ps**, **logs**, and
Compose passthrough remain available but are not part of the ACP client
lifecycle.

The caller's canonical current directory is bind-mounted at the identical path
inside the container. The Compose project, container name, and default private
Codex state volume are derived from the directory basename, matching myCodexACP.
Use distinct basenames when running several workspaces concurrently.

Additional mounts and Compose overrides use the inherited launcher options:

~~~bash
./myCodexACP -v /host/data:/data:ro start
./myCodexACP -f ./local-policy-overlay.yaml start
~~~

Use the same options before **status**, **stdio**, **stop**, or **down** when an
override changes how the Compose project is resolved. Only **start** applies
mount or configuration changes.

## Authentication profiles

The selected profile is remembered under the ignored **.secrets/** directory:

| Profile | Upstream credential | Setup |
|---|---|---|
| chatgpt | ChatGPT subscription OAuth | **./myCodexACP login chatgpt** |
| openai | OpenAI API key | **./myCodexACP login openai** |
| vertex | Google service-account file | See **auth-profiles/vertex/profile.env** |

Run **login** before **start**. If an interactive start has no selected profile,
the launcher can still guide first-time selection; headless setup must select a
profile explicitly with **MYCODEX_AUTH** or **--auth**. API keys can be supplied
with **OPENAI_API_KEY** or **OPENAI_API_KEY_FILE**; managed copies are stored
with restrictive permissions.

The adapter runs with **NO_BROWSER=1**. Authentication belongs to the launcher
phase above; ACP clients are not offered a second browser flow from inside the
restricted agent container.

Provider credentials and the LiteLLM administrator key enter only the gateway
sidecar. The Codex container receives the fixed, route-restricted
**MYCODEX_GATEWAY_TOKEN**, so an agent cannot use administrator routes.

## Why the broker exists

Vaka needs **NET_ADMIN** briefly to install the container's nftables policy. Its
init process then removes that capability—including from the bounding set—and
executes the Compose service's original entrypoint. Descendants of that process
cannot recover NET_ADMIN, even through a setuid helper such as sudo.

A later Docker or Compose exec is a separate process created from the container
configuration; it does not descend from Vaka's already-scrubbed process. The
recipe therefore uses this split:

1. **/usr/local/bin/entrypoint.sh** starts as root because the harness must
   create the host-matching user, fix state ownership, and then use gosu.
2. **codex-prestart.sh** configures LiteLLM and execs **acp-broker.mjs** as that
   user in the original process tree.
3. Each Unix-socket connection makes the broker spawn one pinned **codex-acp**
   child. Codex App Server remains below that child in the same safe tree.
4. **myCodexACP stdio** uses **compose exec -T --user UID:GID** only for the fixed
   **acp-connect.mjs** byte relay. Before connecting, setpriv applies
   **no_new_privs**. The relay cannot execute client-selected commands.

The socket is mode 0600 inside persistent state. It is not bind-mounted to the
host, avoiding Unix-socket sharing differences across Docker Desktop and
Colima. Adapter stderr goes to the Codex container log; protocol stdout remains
newline-delimited JSON only.

Do not replace **stdio** with **myCodexACP exec codex-acp**, **docker exec
codex-acp**, or a Compose exec command. That would put the adapter in the
independent exec process tree and discard the capability invariant.

**attach** is different: the exec-created process is only a tmux client.
Commands entered in the pane are run by the already-existing tmux server, which
is a descendant of the original Vaka process. **exec** is a maintenance
facility and should not be used to start an untrusted agent.

The Compose service also explicitly declares **cap_drop: [NET_ADMIN]** and
**no-new-privileges:true**. Vaka may temporarily add NET_ADMIN for its init
phase, but the original service tree is scrubbed before startup.

## Image and dependency policy

The recipe intentionally distributes a normal Dockerfile:

- it builds on **ghcr.io/infrasecture/harness-workstation:0.147.0-r2**;
- it copies Node **24.19.0** from the official semver-tagged Node image because
  current adapter dependencies require Node 20 or newer;
- package.json pins **@agentclientprotocol/codex-acp** to **1.3.0**;
- package-lock.json locks its graph, including the compatible
  **@openai/codex** package shipped by the adapter;
- **npm ci --omit=dev** runs during image build.

This keeps installation in the standard, cacheable image-build phase. Runtime
does not need npm-registry egress and does not execute mutable **npx -y**
resolution on every client launch.

The app image and both base images use readable release tags rather than image
digest pins. The npm lockfile provides exact JavaScript dependency integrity.
When updating:

1. Change the exact adapter version in package.json.
2. Regenerate package-lock.json with npm.
3. Confirm the bundled Codex compatibility and Node engine.
4. Update the local image tag in myCodexACP and the recipe version.
5. Run tests/run.sh, especially the live capability test.

The allowlist-style **.dockerignore** is separate from **.gitignore** on purpose.
Docker does not consult .gitignore; without .dockerignore, ignored secrets and
workspaces can still enter the build context. Only the Dockerfile, npm
manifests, and two runtime modules are sent to the builder.

## Network policy

The **codex** service can reach DNS and **litellm:4000**; direct Internet egress
is rejected. LiteLLM has profile-specific HTTPS destinations for the selected
provider. Customize a copied vaka.yaml or profile policy when a project needs
additional hosts rather than broadening the shipped default.

Run the stack through **myCodexACP**, not bare Docker Compose: the wrapper supplies
host identity, path parity, state names, auth overlays, secrets, the local image
contract, and routes every Compose operation through Vaka.

## Validation

~~~bash
./tests/run.sh
~~~

The suite retains the inherited launcher, profile, migration, gateway, and
policy checks. Its ACP runtime test builds and starts a real Vaka stack,
initializes the adapter, checks that stdout is clean JSON, and reads **/proc**
for the live broker, adapter, and Codex App Server. It fails if NET_ADMIN is
present in any bounding set or if the exec-side relay lacks no_new_privs.

The internal launcher began from [myCodex](https://github.com/emsi/myCodex) and
the registry's sibling **codex** recipe. **myCodexACP** is the recipe-specific
public control interface around that reused implementation.
