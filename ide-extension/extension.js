// Calaforge environment controls, rendered as a webview in the activity bar.
// Runs server-side in the workspace pod: buttons execute the same helper
// scripts available in the terminal; wings toggling goes through the
// cluster-internal Calaforge dashboard API.
const vscode = require('vscode');
const { execFile } = require('child_process');

const PROJECT = (process.env.PROJECT_NAME || '').replace(/^devenv-/, '');
const BASE_DOMAIN = process.env.BASE_DOMAIN || 'dev.zephmc.dev';
const DASHBOARD = process.env.CALAFORGE_API || 'http://calaforge.calaforge';

const sh = (cmd, args = []) =>
  new Promise((resolve) => {
    execFile(cmd, args, { timeout: 30000 }, (err, stdout, stderr) =>
      resolve({ ok: !err, out: `${stdout}${stderr}`.trim() })
    );
  });

async function dashboard(path, opts = {}) {
  const res = await fetch(`${DASHBOARD}${path}`, {
    ...opts,
    headers: {
      'x-auth-request-user': `ide-${PROJECT || 'unknown'}`,
      ...(opts.body ? { 'content-type': 'application/json' } : {}),
    },
  });
  if (!res.ok) throw new Error(`dashboard ${path} -> ${res.status}`);
  return res.json();
}

async function status() {
  const local = await sh('panel-status');
  let parsed = {};
  try { parsed = JSON.parse(local.out); } catch {}
  let wings = null;
  if (PROJECT) {
    try {
      const data = await dashboard('/api/projects');
      const p = data.projects.find((x) => x.name === PROJECT);
      wings = p ? { enabled: p.wingsEnabled, argo: p.argo?.health ?? null } : null;
    } catch {}
  }
  return { ...parsed, wings, project: PROJECT, panelUrl: PROJECT ? `https://${PROJECT}-panel.${BASE_DOMAIN}` : null };
}

function term(name, command) {
  const t = vscode.window.createTerminal(name);
  t.show();
  t.sendText(command);
}

class Controls {
  resolveWebviewView(view) {
    this.view = view;
    view.webview.options = { enableScripts: true };
    view.webview.html = HTML;

    const send = async () => {
      try { view.webview.postMessage({ type: 'status', status: await status() }); } catch {}
    };
    const timer = setInterval(send, 5000);
    view.onDidDispose(() => clearInterval(timer));

    view.webview.onDidReceiveMessage(async (msg) => {
      const done = (text) => { if (text) vscode.window.showInformationMessage(text); send(); };
      try {
        switch (msg.cmd) {
          case 'refresh': return send();
          case 'start': return done((await sh('panel-start', [msg.target])).out);
          case 'stop': return done((await sh('panel-stop', [msg.target])).out);
          case 'restart': {
            await sh('panel-stop', [msg.target]);
            return done((await sh('panel-start', [msg.target])).out);
          }
          case 'wings': {
            await dashboard(`/api/projects/${PROJECT}/wings`, {
              method: 'POST',
              body: JSON.stringify({ enabled: msg.enabled }),
            });
            return done(`wings ${msg.enabled ? 'enabling' : 'disabling'} — ArgoCD syncs in ~1-3 min`);
          }
          case 'migrate':
            return term('migrations', 'cd /workspace/panel && SQLX_OFFLINE=true cargo run -p database-migrator -- migrate');
          case 'log':
            return term(`${msg.target} log`, `tail -n 100 -f /workspace/${msg.target}.log`);
          case 'scaffold': {
            const name = await vscode.window.showInputBox({
              prompt: 'Extension package name (reverse-DNS, e.g. me.zephrynis.myext)',
              validateInput: (v) => (/^[a-z0-9]+(\.[a-z0-9]+)+$/.test(v) ? null : 'use reverse-DNS form'),
            });
            if (name) term('scaffold', `cd /workspace/panel && panel-rs extensions init ${name}`);
            return;
          }
          case 'export': {
            const id = await vscode.window.showInputBox({
              prompt: 'Extension identifier to package (e.g. me_zephrynis_myext)',
            });
            if (id) term('export', `cd /workspace/panel && panel-rs extensions export ${id}`);
            return;
          }
          case 'openPanel': {
            const s = await status();
            if (s.panelUrl) vscode.env.openExternal(vscode.Uri.parse(s.panelUrl));
            return;
          }
          case 'creds': {
            const user = process.env.SEED_ADMIN_USERNAME || 'admin';
            const pass = process.env.SEED_ADMIN_PASSWORD || '(not seeded)';
            const pick = await vscode.window.showInformationMessage(
              `Panel admin login — user: ${user}`, 'Copy password'
            );
            if (pick) await vscode.env.clipboard.writeText(pass);
            return;
          }
        }
      } catch (err) {
        vscode.window.showErrorMessage(String(err.message || err));
        send();
      }
    });

    send();
  }
}

const HTML = /* html */ `<!doctype html><html><head><style>
  body { font-family: var(--vscode-font-family); padding: 8px 12px; }
  h3 { margin: 14px 0 6px; font-size: 12px; text-transform: uppercase; opacity: .7; }
  .row { display: flex; align-items: center; gap: 6px; margin: 4px 0; flex-wrap: wrap; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--vscode-charts-red); }
  .dot.on { background: var(--vscode-charts-green); }
  .dot.warn { background: var(--vscode-charts-yellow); }
  button { background: var(--vscode-button-secondaryBackground); color: var(--vscode-button-secondaryForeground);
           border: none; padding: 3px 9px; border-radius: 3px; cursor: pointer; }
  button:hover { background: var(--vscode-button-secondaryHoverBackground); }
  .wide { width: 100%; text-align: left; margin: 2px 0; }
  .lbl { min-width: 68px; }
  small { opacity: .6; }
</style></head><body>
  <h3>Panel</h3>
  <div class="row"><span id="d-backend" class="dot"></span><span class="lbl">backend</span>
    <button onclick="cmd({cmd:'start',target:'backend'})">Start</button>
    <button onclick="cmd({cmd:'stop',target:'backend'})">Stop</button>
    <button onclick="cmd({cmd:'restart',target:'backend'})">Restart</button>
    <button onclick="cmd({cmd:'log',target:'panel-backend'})">Log</button></div>
  <div class="row"><span id="d-frontend" class="dot"></span><span class="lbl">frontend</span>
    <button onclick="cmd({cmd:'start',target:'frontend'})">Start</button>
    <button onclick="cmd({cmd:'stop',target:'frontend'})">Stop</button>
    <button onclick="cmd({cmd:'restart',target:'frontend'})">Restart</button>
    <button onclick="cmd({cmd:'log',target:'panel-frontend'})">Log</button></div>
  <div class="row"><small id="hint">restart backend = incremental rebuild + run</small></div>

  <h3>Wings</h3>
  <div class="row"><span id="d-wings" class="dot"></span><span class="lbl" id="wings-state">…</span>
    <button id="wings-btn" onclick="toggleWings()">…</button></div>

  <h3>Actions</h3>
  <button class="wide" onclick="cmd({cmd:'openPanel'})">Open panel in browser</button>
  <button class="wide" onclick="cmd({cmd:'creds'})">Show admin login</button>
  <button class="wide" onclick="cmd({cmd:'migrate'})">Run database migrations</button>
  <button class="wide" onclick="cmd({cmd:'log',target:'bootstrap'})">Bootstrap log</button>
  <button class="wide" onclick="cmd({cmd:'scaffold'})">Scaffold new extension…</button>
  <button class="wide" onclick="cmd({cmd:'export'})">Package extension (.c7s.zip)…</button>

<script>
  const vscode = acquireVsCodeApi();
  let wingsEnabled = null;
  function cmd(m) { vscode.postMessage(m); }
  function toggleWings() { cmd({cmd:'wings', enabled: !wingsEnabled}); }
  window.addEventListener('message', (e) => {
    if (e.data.type !== 'status') return;
    const s = e.data.status;
    document.getElementById('d-backend').className = 'dot' + (s.port8000 ? ' on' : (s.backend && s.backend.running ? ' warn' : ''));
    document.getElementById('d-frontend').className = 'dot' + (s.port5173 ? ' on' : (s.frontend && s.frontend.running ? ' warn' : ''));
    document.getElementById('hint').textContent = s.bootstrapped
      ? 'restart backend = incremental rebuild + run'
      : 'bootstrap still running — check the bootstrap log';
    const w = s.wings;
    wingsEnabled = w ? w.enabled : null;
    document.getElementById('d-wings').className = 'dot' + (w && w.enabled ? (w.argo === 'Healthy' ? ' on' : ' warn') : '');
    document.getElementById('wings-state').textContent = w ? (w.enabled ? 'enabled' : 'disabled') : 'unavailable';
    document.getElementById('wings-btn').textContent = w && w.enabled ? 'Disable' : 'Enable';
    document.getElementById('wings-btn').disabled = !w;
  });
  cmd({cmd:'refresh'});
</script></body></html>`;

exports.activate = (context) => {
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('calaforge.controls', new Controls())
  );
};
exports.deactivate = () => {};
