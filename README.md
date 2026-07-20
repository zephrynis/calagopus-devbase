# calagopus-devbase

Workspace image for [Calaforge](https://github.com/zephrynis/calaforge) Calagopus
extension dev environments (`gitops/devenvs/*`). Contains:

- **code-server** (VS Code in the browser) on `:8080`, `--auth none` — auth is
  handled upstream by oauth2-proxy on the ingress
- **Rust** (rustup stable), **Node 24 + pnpm**, panel build deps, `postgresql-client`
- **Claude Code** CLI + VS Code extension (Open VSX), seeded on first boot;
  log in with a claude.ai subscription, credentials persist via
  `CLAUDE_CONFIG_DIR=/workspace/.claude`
- `bootstrap.sh` — idempotent clone/checkout of `calagopus/panel` at
  `$PANEL_VERSION`, pnpm installs, frontend build, DB migrations; doubles as the
  update mechanism (the pod rolls when the gitops `PANEL_VERSION` changes)
- Helpers on PATH: `panel-backend`, `panel-frontend`, `panel-rs`

Everything stateful lives on the `/workspace` PVC; the image is replaceable.

Expected env (set by the devenv manifests): `PANEL_VERSION`, `POSTGRES_PASSWORD`,
`APP_ENCRYPTION_KEY`, `CARGO_HOME=/workspace/.cargo`,
`CLAUDE_CONFIG_DIR=/workspace/.claude`, `CARGO_BUILD_JOBS`.

Built by GitHub Actions to `ghcr.io/zephrynis/calagopus-devbase` (`:latest` +
`:sha-<commit>`). The GHCR package must be **public** so devenv namespaces can
pull without a secret.
