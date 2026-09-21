ARG NODE_VERSION=24.19.0
FROM node:${NODE_VERSION}-bookworm-slim AS node-runtime

FROM ghcr.io/infrasecture/harness-workstation:0.147.0-r2

USER root
COPY --from=node-runtime /usr/local/ /usr/local/
WORKDIR /opt/codex-acp

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
    && npm cache clean --force

COPY docker/acp-broker.mjs docker/acp-connect.mjs ./

# Keep the harness image's root entrypoint contract. It provisions the host
# identity, prepares Codex state and tmux, then drops to that identity before
# it executes the Compose command (the ACP broker).
WORKDIR /workspace
