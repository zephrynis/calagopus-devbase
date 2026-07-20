#!/bin/bash
# Pod entrypoint: make the IDE available immediately, run the heavy panel
# bootstrap in the background (tail -f /workspace/bootstrap.log to watch it).
set -u

mkdir -p /workspace/.code-server/extensions /workspace/.claude /workspace/.cargo

# Seed staged extensions (Claude Code, Calaforge devtools) into the
# persistent extensions dir. -n never clobbers, so user-managed extension
# state survives while newly staged extensions (or new versions) appear.
cp -rn /home/coder/.staged-extensions/. /workspace/.code-server/extensions/ 2>/dev/null || true

bootstrap.sh >> /workspace/bootstrap.log 2>&1 &

exec code-server \
    --bind-addr 0.0.0.0:8080 \
    --auth none \
    --disable-telemetry \
    --user-data-dir /workspace/.code-server \
    --extensions-dir /workspace/.code-server/extensions \
    /workspace/panel
