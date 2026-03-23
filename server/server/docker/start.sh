#!/bin/bash
set -e

# ── Detect public IP (for coturn only) ───────────────────────────────────────
# Node.js has its own IP detection + watcher (ip.ts), so we don't set
# MEDIASOUP_ANNOUNCED_IP here unless the user explicitly configured it.
if [ -n "$MEDIASOUP_ANNOUNCED_IP" ]; then
  PUBLIC_IP="$MEDIASOUP_ANNOUNCED_IP"
  echo "[start] Using configured MEDIASOUP_ANNOUNCED_IP: $PUBLIC_IP"
else
  echo "[start] Detecting public IP for coturn..."
  PUBLIC_IP=""
  for URL in "https://api.ipify.org" "https://api64.ipify.org" "https://ifconfig.me"; do
    IP=$(curl -s --max-time 5 "$URL" 2>/dev/null | tr -d '[:space:]')
    if echo "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      PUBLIC_IP="$IP"
      echo "[start] Public IP: $PUBLIC_IP (via $URL)"
      break
    fi
  done
  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="127.0.0.1"
    echo "[start] WARNING: Could not detect public IP, using $PUBLIC_IP"
  fi
  # Do NOT export MEDIASOUP_ANNOUNCED_IP — let Node.js auto-detect + watch
fi

# ── Write coturn config ───────────────────────────────────────────────────────
TURN_USER="${TURN_USER:-rayspeaki}"
TURN_CREDENTIAL="${TURN_CREDENTIAL:-rayspeakiturn}"
TURN_REALM="${TURN_REALM:-rayspeaki}"

cat > /tmp/turnserver.conf <<EOF
listening-port=3478
external-ip=${PUBLIC_IP}
realm=${TURN_REALM}
lt-cred-mech
user=${TURN_USER}:${TURN_CREDENTIAL}
min-port=50000
max-port=50100
no-tls
no-dtls
log-file=/dev/stdout
simple-log
EOF

echo "[start] coturn configured (external-ip=$PUBLIC_IP)"

# ── Init PostgreSQL ──────────────────────────────────────────────────────────
PG_DATA="/var/lib/postgresql/data"
PG_USER="${PG_USER:-rayspeaki}"
PG_PASSWORD="${PG_PASSWORD:-rayspeaki}"
PG_DB="${PG_DB:-rayspeaki}"
# Ensure socket dir exists
mkdir -p /run/postgresql
chown postgres:postgres /run/postgresql

if [ ! -f "$PG_DATA/PG_VERSION" ]; then
  echo "[start] Initializing PostgreSQL..."
  mkdir -p "$PG_DATA"
  chown -R postgres:postgres /var/lib/postgresql
  su -s /bin/bash postgres -c "initdb -D $PG_DATA --auth=trust --encoding=UTF8 --locale=C"
  # Allow password auth from localhost
  cat > "$PG_DATA/pg_hba.conf" <<PGHBA
local   all   all                trust
host    all   all   127.0.0.1/32 md5
host    all   all   ::1/128      md5
PGHBA
  # Start temporarily to create user/db
  su -s /bin/bash postgres -c "pg_ctl -D $PG_DATA -l /tmp/pg_init.log start -w"
  su -s /bin/bash postgres -c "psql -c \"CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD';\""
  su -s /bin/bash postgres -c "psql -c \"CREATE DATABASE $PG_DB OWNER $PG_USER;\""
  su -s /bin/bash postgres -c "pg_ctl -D $PG_DATA stop -m fast"
  echo "[start] PostgreSQL initialized"
else
  chown -R postgres:postgres /var/lib/postgresql
fi

# ── Init Redis dir ────────────────────────────────────────────────────────────
mkdir -p /var/lib/redis
chown redis:redis /var/lib/redis

# ── Start supervisor ──────────────────────────────────────────────────────────
echo "[start] Starting all services via supervisord..."
exec /usr/bin/supervisord -n -c /app/supervisord.conf
