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

    # Public app URL (only replaces the untouched default, never a user edit)
    if [ -n "${PROJECT_NAME:-}" ]; then
        local PROJECT="${PROJECT_NAME#devenv-}"
        $PSQL "UPDATE settings SET value = 'https://${PROJECT}-panel.${BASE_DOMAIN:-dev.zephmc.dev}' WHERE key = 'app::url' AND value = 'http://localhost:8000'" >/dev/null \
            && log "app::url set to https://${PROJECT}-panel.${BASE_DOMAIN:-dev.zephmc.dev}"
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

    # Browsers reach wings same-origin through the panel's wings proxy (the
    # ingress routes /wings-proxy on the panel host to the backend).
    if [ -n "${PROJECT_NAME:-}" ]; then
        local PROJECT="${PROJECT_NAME#devenv-}"
        $PSQL "UPDATE nodes SET public_url = 'https://${PROJECT}-panel.${BASE_DOMAIN:-dev.zephmc.dev}/wings-proxy/' || uuid WHERE name = 'wings' AND public_url IS NULL" >/dev/null || true
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
  # /tmp is shadowed inside dind (its entrypoint remounts it), so the install
  # staging dir must live on the shared data volume.
  tmp_directory: /var/lib/pterodactyl/tmp
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

# Second-stage seeding needs the panel's HTTP API (no CLI exists for servers):
# log in with the seeded admin session, create allocations, import the Paper
# egg, and create one test server — only when wings is actually reachable.
seed_server() {
    local PSQL="psql -h postgres -U panel -d panel -qtA -c"
    export PGPASSWORD="$POSTGRES_PASSWORD"
    local RS=./target/debug/panel-rs API=http://localhost:8000 JAR=/tmp/.seed-cookies

    [ "$($PSQL 'SELECT count(*) FROM servers')" != "0" ] && return 0

    # Paper egg via CLI import (Pterodactyl-format egg JSON imports natively)
    mkdir -p /tmp/seed-eggs
    curl -fsSL -o /tmp/seed-eggs/egg-paper.json \
        https://raw.githubusercontent.com/pterodactyl/game-eggs/main/minecraft/java/paper/egg-paper.json \
        || { log "WARN: Paper egg download failed, skipping server seed"; return 0; }
    if [ "$($PSQL 'SELECT count(*) FROM nest_eggs')" = "0" ]; then
        [ "$($PSQL 'SELECT count(*) FROM nests')" = "0" ] \
            && $RS nests create --author calaforge --name Seeded --json >/dev/null 2>&1
        log "importing Paper egg..."
        $RS nests mass-import --nest Seeded /tmp/seed-eggs 2>&1 | tail -1
    fi

    if ! curl -s -o /dev/null --max-time 5 http://wings:8443/; then
        log "wings not reachable — enable wings, then restart the workspace pod to seed the Paper server"
        return 0
    fi

    log "waiting for panel http..."
    local n=0
    until curl -s -o /dev/null --max-time 3 "$API/" 2>/dev/null || [ $n -ge 60 ]; do sleep 2; n=$((n+1)); done

    rm -f "$JAR"
    local LOGIN
    LOGIN=$(jq -n --arg u "${SEED_ADMIN_USERNAME:-admin}" --arg p "$SEED_ADMIN_PASSWORD" '{user:$u,password:$p}' \
        | curl -s -c "$JAR" -H 'content-type: application/json' -d @- "$API/api/auth/login/")
    echo "$LOGIN" | grep -q '"completed"' || { log "WARN: seed login failed: $(echo "$LOGIN" | head -c 200)"; return 0; }

    local NODE
    NODE=$($PSQL "SELECT uuid FROM nodes WHERE name = 'wings' LIMIT 1")
    if [ "$($PSQL 'SELECT count(*) FROM node_allocations')" = "0" ]; then
        curl -s -b "$JAR" -H 'content-type: application/json' \
            -d '{"ip":"0.0.0.0","ip_alias":null,"ports":[25565,25566,25567,25568,25569]}' \
            "$API/api/admin/nodes/$NODE/allocations/" >/dev/null
        log "seeded allocations 25565-25569"
    fi

    local EGG OWNER ALLOC STARTUP IMAGE VARS RESP
    # Explicit variable values: unsent variables are not persisted by the API,
    # which leaves {{PLACEHOLDERS}} unsubstituted in the startup command.
    VARS=$(jq '[.variables[] | {env_variable, value: (.default_value // "" | tostring)}]' /tmp/seed-eggs/egg-paper.json)
    EGG=$($PSQL 'SELECT uuid FROM nest_eggs LIMIT 1')
    OWNER=$($PSQL 'SELECT uuid FROM users WHERE admin = true ORDER BY created LIMIT 1')
    ALLOC=$($PSQL "SELECT uuid FROM node_allocations WHERE node_uuid = '$NODE' ORDER BY port LIMIT 1")
    STARTUP=$(jq -r '.startup' /tmp/seed-eggs/egg-paper.json)
    # First image = newest Java; current Paper requires the newest (26.1 -> Java 25)
    IMAGE=$(jq -r '.docker_images | to_entries[0].value' /tmp/seed-eggs/egg-paper.json)
    [ -z "$EGG" ] || [ -z "$ALLOC" ] && { log "WARN: missing egg/allocation, skipping server seed"; return 0; }

    RESP=$(jq -n --arg node "$NODE" --arg owner "$OWNER" --arg egg "$EGG" --arg alloc "$ALLOC" \
        --arg startup "$STARTUP" --arg image "$IMAGE" '{
        node_uuid:$node, owner_uuid:$owner, egg_uuid:$egg,
        backup_configuration_uuid:null, allocation_uuid:$alloc, allocation_uuids:[],
        start_on_completion:true, skip_installer:false, external_id:null,
        name:"Paper (seeded)", description:"Seeded by Calaforge for extension testing",
        limits:{cpu:200, memory:2048, memory_overhead:0, swap:0, disk:5120, io_weight:null},
        pinned_cpus:[], startup:$startup, image:$image, timezone:null,
        hugepages_passthrough_enabled:false, kvm_passthrough_enabled:false,
        feature_limits:{allocations:5, databases:0, backups:0, schedules:5},
        variables:$vars}' --argjson vars "$VARS" \
        | curl -s -b "$JAR" -H 'content-type: application/json' -d @- "$API/api/admin/servers/")
    if echo "$RESP" | grep -q '"server"'; then
        log "seeded Paper server (installs via wings, port 25565)"
        # Accept the Minecraft EULA so the first start doesn't stop on the
        # prompt (standard for throwaway dev/test servers).
        local SRV n=0
        SRV=$(echo "$RESP" | jq -r '.server.uuid // empty')
        if [ -n "$SRV" ]; then
            until curl -sf -b "$JAR" -X POST --data-binary 'eula=true'                 "$API/api/client/servers/$SRV/files/write?file=eula.txt" >/dev/null 2>&1                 || [ $n -ge 30 ]; do sleep 6; n=$((n+1)); done
            [ $n -lt 30 ] && log "accepted EULA" || log "WARN: could not write eula.txt (accept it in the panel UI)"
        fi
    else
        log "WARN: server seed failed: $(echo "$RESP" | head -c 250)"
    fi
    rm -f "$JAR"
}

if [ -n "${SEED_ADMIN_PASSWORD:-}" ]; then
    seed || log "WARN: seeding failed (panel still usable, set up via OOBE)"
else
    log "SEED_ADMIN_PASSWORD not set, skipping seeding"
fi

echo "$PANEL_VERSION" > .devenv-version

if [ -f /workspace/.no-autostart ]; then
    log "autostart disabled (/workspace/.no-autostart exists)"
else
    log "autostarting panel (opt out: touch /workspace/.no-autostart)"
    panel-start all
fi

if [ -n "${SEED_ADMIN_PASSWORD:-}" ] && [ ! -f /workspace/.no-autostart ]; then
    seed_server || log "WARN: server seeding failed (create one via the panel UI)"
fi

log "=== bootstrap done. Control the panel from the Calaforge IDE tab, or panel-start/panel-stop. ==="
