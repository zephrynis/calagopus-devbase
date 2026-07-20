#!/bin/bash
# Pod entrypoint: make the IDE available immediately, run the heavy panel
# bootstrap in the background (tail -f /workspace/bootstrap.log to watch it).
set -u

mkdir -p /workspace/.code-server/extensions /workspace/.claude /workspace/.cargo

# Seed the staged extensions (Claude Code) into the persistent extensions dir
# once; after that the user owns it and can add/remove extensions freely.
if [ ! -e /workspace/.code-server/.extensions-seeded ]; then
    cp -rn /home/coder/.staged-extensions/. /workspace/.code-server/extensions/ || true
    touch /workspace/.code-server/.extensions-seeded
fi

bootstrap.sh >> /workspace/bootstrap.log 2>&1 &

exec code-server \
    --bind-addr 0.0.0.0:8080 \
    --auth none \
    --disable-telemetry \
    --user-data-dir /workspace/.code-server \
    --extensions-dir /workspace/.code-server/extensions \
    /workspace/panel
