FROM node:lts-trixie-slim AS base
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git \
  && rm -rf /var/lib/apt/lists/*
RUN corepack enable

FROM base AS deps
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
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
WORKDIR /app
COPY --chown=node:node --from=build /app /app
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai \
  && mkdir -p /paperclip/instances/default \
  && chown -R node:node /paperclip

# Create config file so Paperclip uses external Postgres (not embedded)
RUN echo '{"$meta":{"version":1,"updatedAt":"2026-03-27T00:00:00Z","source":"configure"},"database":{"mode":"postgres"},"logging":{"mode":"file","logDir":"/paperclip/instances/default/logs"},"server":{"deploymentMode":"authenticated","exposure":"private","host":"0.0.0.0","port":10000,"allowedHostnames":["os.kai-it.pro","paperclip-5xqa.onrender.com"],"serveUi":true},"auth":{"baseUrlMode":"auto","disableSignUp":false},"storage":{"provider":"local_disk","localDisk":{"baseDir":"/paperclip/instances/default/data/storage"},"s3":{"bucket":"paperclip","region":"us-east-1","prefix":"","forcePathStyle":false}},"secrets":{"provider":"local_encrypted","strictMode":false,"localEncrypted":{"keyFilePath":"/paperclip/instances/default/secrets/master.key"}}}' > /paperclip/instances/default/config.json \
  && chown node:node /paperclip/instances/default/config.json

ENV NODE_ENV=production \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=10000 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private

EXPOSE 10000

USER node
CMD ["sh", "-c", "node /app/bootstrap.mjs 2>&1 || true; exec node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js"]
