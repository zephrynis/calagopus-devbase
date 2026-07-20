#!/bin/bash
# Idempotent workspace bootstrap + panel updater. Runs on every pod start.
# Driven by env: PANEL_VERSION (git tag), POSTGRES_PASSWORD, APP_ENCRYPTION_KEY.
# The user's extension code lives INSIDE the clone (backend-extensions/,
# frontend/extensions/, database/extension-migrations/) — never hard-reset.
set -u

log() { echo "[bootstrap $(date -u +%H:%M:%S)] $*"; }

PANEL_DIR=/workspace/panel
PANEL_REPO=${PANEL_REPO:-https://github.com/calagopus/panel.git}

log "=== bootstrap start (PANEL_VERSION=${PANEL_VERSION:-unset}) ==="

if [ ! -d "$PANEL_DIR/.git" ]; then
    log "cloning calagopus/panel..."
    git clone "$PANEL_REPO" "$PANEL_DIR" || { log "clone FAILED"; exit 1; }
fi
cd "$PANEL_DIR"

current=$(cat .devenv-version 2>/dev/null || echo "none")
if [ "$current" != "$PANEL_VERSION" ]; then
    log "switching panel $current -> $PANEL_VERSION"
    git fetch --tags origin || log "WARN: git fetch failed, trying local tags"
    # Refuse to switch if tracked files outside the extension dirs are dirty —
    # the user probably has uncommitted panel-core changes; don't clobber them.
    dirty=$(git status --porcelain -- . \
        ':(exclude)backend-extensions' \
        ':(exclude)frontend/extensions' \
        ':(exclude)database/extension-migrations' | grep -v '^??' || true)
    if [ -n "$dirty" ]; then
        log "WARN: working tree has modified core files; NOT switching version:"
        echo "$dirty"
    else
        git checkout -q "$PANEL_VERSION" || { log "checkout $PANEL_VERSION FAILED"; exit 1; }
    fi
fi

if [ ! -f .env ]; then
    log "creating .env"
    cp .env.example .env
    sed -i "s#^DATABASE_URL=.*#DATABASE_URL=postgresql://panel:${POSTGRES_PASSWORD}@postgres:5432/panel#" .env
    sed -i "s#^REDIS_URL=.*#REDIS_URL=redis://redis:6379#" .env
    sed -i "s#^APP_ENCRYPTION_KEY=.*#APP_ENCRYPTION_KEY=${APP_ENCRYPTION_KEY}#" .env
fi

log "installing frontend deps..."
( cd frontend && pnpm install ) || { log "frontend pnpm install FAILED"; exit 1; }
log "installing database deps..."
( cd database && pnpm install ) || { log "database pnpm install FAILED"; exit 1; }

# The backend embeds frontend assets, so the frontend must be built before the
# first cargo build succeeds.
log "building frontend (needed before backend compiles)..."
( cd frontend && pnpm build ) || { log "frontend build FAILED"; exit 1; }

log "waiting for postgres..."
until pg_isready -h postgres -U panel -d panel >/dev/null 2>&1; do sleep 2; done

log "running database migrations (compiles database-migrator, slow on first run)..."
SQLX_OFFLINE=true cargo run -p database-migrator -- migrate \
    || { log "migrations FAILED"; exit 1; }

log "building panel binary (the long step on first run; incremental afterwards)..."
SQLX_OFFLINE=true cargo build -p panel-rs || { log "panel build FAILED"; exit 1; }

seed() {
    local PSQL="psql -h postgres -U panel -d panel -qtA -c"
    export PGPASSWORD="$POSTGRES_PASSWORD"
    local RS=./target/debug/panel-rs

    # Admin user (skip if any user exists — e.g. created via the panel's OOBE)
    if [ "$($PSQL 'SELECT count(*) FROM users')" = "0" ]; then
        log "seeding admin user '${SEED_ADMIN_USERNAME:-admin}'..."
        $RS users create \
            --username "${SEED_ADMIN_USERNAME:-admin}" \
            --email "${SEED_ADMIN_EMAIL:-admin@zephmc.dev}" \
            --name-first Dev --name-last Admin \
            --password "$SEED_ADMIN_PASSWORD" \
            --admin true --json 2>&1 | tail -1 \
            && log "admin user ready (password is SEED_ADMIN_PASSWORD in the devenv-secrets Secret)"
    else
        log "users already exist, skipping admin seed"
    fi

    # Location (no CLI for this — one row, schema-stable columns only)
    local LOC
    LOC=$($PSQL 'SELECT uuid FROM locations LIMIT 1')
    if [ -z "$LOC" ]; then
        LOC=$($PSQL "INSERT INTO locations (name, description) VALUES ('Local', 'Seeded by Calaforge') RETURNING uuid")
        log "seeded location $LOC"
    fi

    # Wings node (panel connects to the in-namespace wings service; enable the
    # wings deployment via the project's kustomization replicas toggle)
    if [ "$($PSQL 'SELECT count(*) FROM nodes')" = "0" ]; then
        log "seeding wings node..."
        $RS nodes create --location-uuid "$LOC" --name wings \
            --url http://wings:8443 --sftp-port 2022 \
            --memory 8192 --disk 51200 --deployment-enabled true --json 2>&1 | tail -1
    fi

    # Wings credentials -> config file for the wings pod (it waits for this
    # file). Only on first seed: resetting the token later would cut off a
    # running wings. The CLI prints pretty multiline JSON to stderr.
    if [ -f /workspace/wings/config.yml ]; then
        return 0
    fi
    local TOK
    TOK=$($RS nodes reset-token --node wings --json 2>&1 | sed -n '/^{/,/^}/p')
    if [ -n "$TOK" ]; then
        mkdir -p /workspace/wings
        cat > /workspace/wings/config.yml <<WINGSEOF
uuid: $(echo "$TOK" | jq -r .uuid)
token_id: $(echo "$TOK" | jq -r .token_id)
token: $(echo "$TOK" | jq -r .token)
remote: http://workspace:8000
api:
  host: 0.0.0.0
  port: 8443
  upload_limit: 10240
system:
  sftp:
    bind_port: 2022
docker:
  socket: tcp://127.0.0.1:2375
WINGSEOF
        log "wrote wings config (node URL http://wings:8443)"
    else
        log "WARN: could not obtain wings node token; wings config not written"
    fi
}

if [ -n "${SEED_ADMIN_PASSWORD:-}" ]; then
    seed || log "WARN: seeding failed (panel still usable, set up via OOBE)"
else
    log "SEED_ADMIN_PASSWORD not set, skipping seeding"
fi

echo "$PANEL_VERSION" > .devenv-version
log "=== bootstrap done. Run 'panel-backend' and 'panel-frontend' in terminals. ==="
