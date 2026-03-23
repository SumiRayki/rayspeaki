# ═══════════════════════════════════════════════════════════════════════════════
# RaySpeaki — All-in-one container
# PostgreSQL + Redis + Go API + Node.js MediaSoup + coturn
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Stage 1: Build web client ────────────────────────────────────────────────
FROM node:20-bookworm-slim AS web-builder
ARG HTTP_PROXY
ARG HTTPS_PROXY
WORKDIR /build/web
COPY server/web/package.json server/web/package-lock.json* ./
RUN npm install
COPY server/web/ ./
RUN npm run build

# ─── Stage 2: Build Node.js server ───────────────────────────────────────────
FROM node:20-bookworm-slim AS server-builder
ARG HTTP_PROXY
ARG HTTPS_PROXY
WORKDIR /build/server
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip make g++ && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages invoke
COPY server/package.json server/package-lock.json* ./
RUN npm install
COPY server/tsconfig.json ./
COPY server/src/ ./src/
RUN npm run build

# ─── Stage 3: Build Go API ───────────────────────────────────────────────────
FROM golang:1.24-alpine AS go-builder
ARG HTTP_PROXY
ARG HTTPS_PROXY
WORKDIR /build/goapi
RUN apk add --no-cache git
COPY goapi/go.mod ./
RUN go get github.com/jackc/pgx/v5@v5.7.2 github.com/redis/go-redis/v9@v9.7.3 golang.org/x/crypto@v0.35.0
COPY goapi/ .
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -o /goapi .

# ─── Stage 4: Runtime (all-in-one) ───────────────────────────────────────────
FROM node:20-bookworm-slim AS runtime
WORKDIR /app

# Install all runtime services
RUN apt-get update && apt-get install -y --no-install-recommends \
    coturn supervisor curl \
    postgresql redis-server \
    ca-certificates && rm -rf /var/lib/apt/lists/*

# Symlink PostgreSQL binaries into PATH
RUN PG_BIN=$(find /usr/lib/postgresql -name initdb -type f | head -1 | xargs dirname) \
    && ln -sf "$PG_BIN"/* /usr/local/bin/

# Create data directories
RUN mkdir -p /var/lib/postgresql/data && chown -R postgres:postgres /var/lib/postgresql
RUN mkdir -p /var/lib/redis && chown redis:redis /var/lib/redis
RUN mkdir -p /run/postgresql && chown postgres:postgres /run/postgresql

# Copy compiled Node.js server
COPY --from=server-builder /build/server/dist ./dist
COPY --from=server-builder /build/server/node_modules ./node_modules
COPY --from=server-builder /build/server/package.json ./

# Copy built web client
COPY --from=web-builder /build/web-dist ./web-dist

# Copy Go API binary
COPY --from=go-builder /goapi /app/goapi

# Copy startup scripts and configs
COPY server/docker/supervisord.conf /app/supervisord.conf
COPY server/docker/start.sh /app/start.sh
RUN chmod +x /app/start.sh /app/goapi

# Ports:
#   4000       — HTTP + WebSocket (web client + signaling)
#   3478/udp   — STUN/TURN
#   40000-40100— MediaSoup WebRTC RTP
#   49152-49252— TURN relay
EXPOSE 4000
EXPOSE 3478/udp
EXPOSE 40000-40100/udp
EXPOSE 40000-40100/tcp
EXPOSE 50000-50100/udp

# Persistent data
VOLUME ["/var/lib/postgresql/data", "/var/lib/redis"]

CMD ["/app/start.sh"]
