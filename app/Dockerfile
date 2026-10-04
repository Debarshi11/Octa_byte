# ---- build stage: install only production dependencies -------------------
FROM node:20-slim AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund

# ---- runtime stage: smallest possible attack surface ---------------------
FROM node:20-slim AS runtime

ENV NODE_ENV=production \
    PORT=3000

# Pull in any Debian security updates published since this base image was cut.
# Without this the rootfs carries fixable HIGH/CRITICAL CVEs (gnutls, pcre2,
# libcap) that the image scan gates on, even though patched packages exist.
RUN apt-get update \
 && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The process is started as `node src/server.js` and never invokes npm at
# runtime, so drop npm and npx along with npm's bundled dependency tree. That
# tree is pure attack surface here, and it is where most of the image's
# Node.js CVEs (tar, pacote, sigstore, brace-expansion, minimatch) actually
# live -- none of which are application dependencies.
RUN rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/bin/npm \
           /usr/local/bin/npx \
 && node --version

# Run as the built-in non-root `node` user (uid 1000) rather than root.
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src
COPY --chown=node:node public ./public

USER node
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/server.js"]
