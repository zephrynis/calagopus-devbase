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

echo "$PANEL_VERSION" > .devenv-version
log "=== bootstrap done. Run 'panel-backend' and 'panel-frontend' in terminals. ==="
