FROM node:lts-trixie-slim AS base
ARG USER_UID=1000
ARG USER_GID=1000
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates gosu curl git wget ripgrep python3 \
  && mkdir -p -m 755 /etc/apt/keyrings \
  && wget -nv -O/etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && echo "20e0125d6f6e077a9ad46f03371bc26d90b04939fb95170f5a1905099cc6bcc0  /etc/apt/keyrings/githubcli-archive-keyring.gpg" | sha256sum -c - \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && mkdir -p -m 755 /etc/apt/sources.list.d \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# Modify the existing node user/group to have the specified UID/GID to match host user
RUN usermod -u $USER_UID --non-unique node \
  && groupmod -g $USER_GID --non-unique node \
  && usermod -g $USER_GID -d /paperclip node

FROM base AS deps
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/mcp-server/package.json packages/mcp-server/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/openclaw-gateway/package.json packages/adapters/openclaw-gateway/
COPY packages/adapters/opencode-local/package.json packages/adapters/opencode-local/
COPY packages/adapters/pi-local/package.json packages/adapters/pi-local/
COPY packages/plugins/sdk/package.json packages/plugins/sdk/
COPY patches/ patches/

RUN pnpm install --frozen-lockfile

FROM base AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)

FROM base AS production
ARG USER_UID=1000
ARG USER_GID=1000
WORKDIR /app
COPY --chown=node:node --from=build /app /app
RUN npm install --global --omit=dev @anthropic-ai/claude-code@2.1.92 \
  && CLAUDE_BIN="$(command -v claude)" \
  && mv "$CLAUDE_BIN" /usr/local/bin/claude-real \
  && printf '%s\n' \
    '#!/bin/sh' \
    'if [ -n "${MINIMAX_API_KEY:-}" ]; then' \
    '  unset ANTHROPIC_API_KEY' \
    '  export ANTHROPIC_BASE_URL="${MINIMAX_BASE_URL:-https://api.minimax.io/anthropic}"' \
    '  export ANTHROPIC_AUTH_TOKEN="${MINIMAX_API_KEY}"' \
    '  export API_TIMEOUT_MS="${API_TIMEOUT_MS:-3000000}"' \
    '  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}"' \
    '  export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-${MINIMAX_MODEL:-MiniMax-M2.7}}"' \
    '  export ANTHROPIC_SMALL_FAST_MODEL="${ANTHROPIC_SMALL_FAST_MODEL:-${MINIMAX_MODEL:-MiniMax-M2.7}}"' \
    '  export ANTHROPIC_DEFAULT_SONNET_MODEL="${ANTHROPIC_DEFAULT_SONNET_MODEL:-${MINIMAX_MODEL:-MiniMax-M2.7}}"' \
    '  export ANTHROPIC_DEFAULT_OPUS_MODEL="${ANTHROPIC_DEFAULT_OPUS_MODEL:-${MINIMAX_MODEL:-MiniMax-M2.7}}"' \
    '  export ANTHROPIC_DEFAULT_HAIKU_MODEL="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-${MINIMAX_MODEL:-MiniMax-M2.7}}"' \
    'fi' \
    'exec /usr/local/bin/claude-real "$@"' > /usr/local/bin/claude \
  && chmod +x /usr/local/bin/claude \
  && ln -sf /usr/local/bin/claude /usr/local/bin/claude-minimax \
  && printf '%s\n' '#!/bin/sh' 'exec npx -y @openai/codex@0.117.0 "$@"' > /usr/local/bin/codex \
  && chmod +x /usr/local/bin/codex \
  && mkdir -p /paperclip/instances/default /paperclip/.claude \
  && chown -R node:node /paperclip

# Create config file so Paperclip uses external Postgres (not embedded)
RUN echo '{"$meta":{"version":1,"updatedAt":"2026-03-27T00:00:00Z","source":"configure"},"database":{"mode":"postgres"},"logging":{"mode":"file","logDir":"/paperclip/instances/default/logs"},"server":{"deploymentMode":"authenticated","exposure":"private","host":"0.0.0.0","port":10000,"allowedHostnames":["os.kai-it.pro","paperclip-5xqa.onrender.com"],"serveUi":true},"auth":{"baseUrlMode":"auto","disableSignUp":false},"storage":{"provider":"local_disk","localDisk":{"baseDir":"/paperclip/instances/default/data/storage"},"s3":{"bucket":"paperclip","region":"us-east-1","prefix":"","forcePathStyle":false}},"secrets":{"provider":"local_encrypted","strictMode":false,"localEncrypted":{"keyFilePath":"/paperclip/instances/default/secrets/master.key"}}}' > /paperclip/instances/default/config.json \
  && chown node:node /paperclip/instances/default/config.json

COPY scripts/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV NODE_ENV=production \
  HOME=/paperclip \
  CLAUDE_HOME=/paperclip/.claude \
  HOST=0.0.0.0 \
  PORT=10000 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  USER_UID=${USER_UID} \
  USER_GID=${USER_GID} \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  OPENCODE_ALLOW_ALL_MODELS=true

RUN printf '%s\n' '#!/bin/sh' 'exec npx -y @openai/codex@0.117.0 "$@"' > /usr/local/bin/codex \
  && chmod +x /usr/local/bin/codex \
  && printf '%s\n' '#!/bin/sh' 'exec npx -y opencode-ai@latest "$@"' > /usr/local/bin/opencode \
  && chmod +x /usr/local/bin/opencode \
  && mkdir -p /paperclip/instances/default \
  && chown -R node:node /paperclip

EXPOSE 10000

USER node
CMD ["sh", "-c", "node --import ./server/node_modules/tsx/dist/loader.mjs packages/db/src/migrate.ts && (node /app/bootstrap.mjs 2>&1 || true); exec node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js"]
