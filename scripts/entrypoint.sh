#!/bin/bash
# Pod entrypoint: make the IDE available immediately, run the heavy panel
# bootstrap in the background (tail -f /workspace/bootstrap.log to watch it).
set -u

mkdir -p /workspace/.code-server/extensions /workspace/.claude /workspace/.cargo

# Seed staged extensions (Claude Code) into the persistent extensions dir.
# -n never clobbers, so user-managed extension state survives.
cp -rn /home/coder/.staged-extensions/. /workspace/.code-server/extensions/ 2>/dev/null || true

# The devtools extension is installed properly (not just copied) so the
# extensions registry gets updated even on volumes that predate it.
code-server --user-data-dir /workspace/.code-server \
    --extensions-dir /workspace/.code-server/extensions \
    --install-extension /home/coder/calaforge-devtools.vsix >/dev/null 2>&1 || true

bootstrap.sh >> /workspace/bootstrap.log 2>&1 &

exec code-server \
    --bind-addr 0.0.0.0:8080 \
    --auth none \
    --disable-telemetry \
    --user-data-dir /workspace/.code-server \
    --extensions-dir /workspace/.code-server/extensions \
    /workspace/panel
