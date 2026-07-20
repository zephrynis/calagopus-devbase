# Workspace image for Calagopus extension dev environments (Calaforge).
# code-server + Rust + Node 24/pnpm + panel build deps + Claude Code.
# The panel clone, cargo caches, code-server state and Claude credentials all
# live under /workspace (a PVC) — this image is stateless and replaceable.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git openssl sudo dumb-init \
        build-essential pkg-config libssl-dev clang cmake \
        postgresql-client zip unzip ripgrep jq \
    && rm -rf /var/lib/apt/lists/*

# Node 24 (panel requires >=24) + pnpm via corepack
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@latest --activate

# code-server (latest at build time; rebuild the image to bump)
RUN curl -fsSL https://code-server.dev/install.sh | sh

# Ubuntu 24.04 ships a default "ubuntu" user on uid 1000 — replace it with
# "coder" so the uid matches the pod's fsGroup and PVC ownership.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash coder \
    && echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder

USER coder
ENV HOME=/home/coder
WORKDIR /home/coder

# Rust stable via rustup (toolchain in the image; caches/target live on the PVC
# via CARGO_HOME=/workspace/.cargo and the in-tree target/ dir)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
ENV PATH="/home/coder/.cargo/bin:/home/coder/.local/bin:${PATH}"

# Claude Code CLI (native installer -> ~/.local/bin/claude). Auth happens at
# runtime with the user's claude.ai subscription; CLAUDE_CONFIG_DIR is pointed
# at /workspace/.claude by the StatefulSet so logins persist.
RUN curl -fsSL https://claude.ai/install.sh | bash

# Claude Code VS Code extension from Open VSX, staged into the image; the
# entrypoint seeds staged extensions into the persistent extensions dir.
RUN mkdir -p /home/coder/.staged-extensions \
    && code-server --extensions-dir /home/coder/.staged-extensions \
         --install-extension anthropic.claude-code

# Calaforge devtools extension (in-IDE panel/wings controls). The vsix is
# kept in the image: the entrypoint installs it at boot, which updates the
# extensions registry on volumes that predate the extension (a bare dir copy
# does not — code-server ignores unregistered dirs).
COPY --chown=coder ide-extension /tmp/ide-extension
RUN cd /tmp/ide-extension \
    && npx --yes @vscode/vsce package --allow-missing-repository -o /opt/calaforge-devtools.vsix \
    && code-server --extensions-dir /home/coder/.staged-extensions \
         --install-extension /opt/calaforge-devtools.vsix \
    && rm -rf /tmp/ide-extension

COPY --chmod=755 scripts/entrypoint.sh scripts/bootstrap.sh scripts/panel-backend scripts/panel-frontend scripts/panel-rs scripts/panel-start scripts/panel-stop scripts/panel-status /usr/local/bin/

EXPOSE 8080 5173 8000
ENTRYPOINT ["dumb-init", "--", "entrypoint.sh"]
