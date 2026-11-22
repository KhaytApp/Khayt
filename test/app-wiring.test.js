const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

/**
 * Structural guards on the app's wiring. Every rule here corresponds to a defect that
 * actually shipped, and that no other test could catch — because the wiring only fails at
 * runtime, in boot code or on a timer.
 *
 *  - lib/printer-alerts.js was never <script>-loaded, so computePrinterAlerts was undefined
 *    and its caller silently gave up. The feature had 22 passing unit tests and had never
 *    once run in the shipped app.
 *  - buildDigestEmailHtml / globalSearchOpen and five others were IIFE-private but
 *    referenced across files (see renderer-cross-file-scope.test.js).
 */
const root = path.join(__dirname, '..');
const readRoot = (f) => fs.readFileSync(path.join(root, f), 'utf8');

const IPC_REGISTER_RE = /ipcMain\.(handle|handleOnce|on|once)\(\s*['"]([^'"]+)['"]/g;
const IPC_INVOKE_RE = /ipcRenderer\.(?:invoke|send)\(\s*['"]([^'"]+)['"]/g;

function registeredChannels() {
  // Recursive: handlers live in lib/main/ as well as at the top of lib/. A
  // one-level listing stopped seeing seven registered channels the day the
  // printer-discovery, webcam and payment-link sections moved, and reported them
  // as unregistered — the handlers were fine, the guard had stopped looking.
  const libFiles = [];
  const walk = (rel) => {
    for (const e of fs.readdirSync(path.join(root, rel), { withFileTypes: true })) {
      if (e.isDirectory()) walk(path.posix.join(rel, e.name));
      else if (e.name.endsWith('.js')) libFiles.push(path.posix.join(rel, e.name));
    }
  };
  walk('lib');
  const files = ['main.js', ...libFiles];
  const map = new Map();
  for (const f of files) {
    const src = readRoot(f);
    for (const m of src.matchAll(IPC_REGISTER_RE)) {
      const line = src.slice(0, m.index).split('\n').length;
      if (!map.has(m[2])) map.set(m[2], []);
      map.get(m[2]).push({ where: `${f}:${line}`, kind: m[1] });
    }
  }
  return map;
}

test('every IPC channel the preload bridge invokes is registered', () => {
  const registered = registeredChannels();
  const pre = readRoot('preload.js');
  const invoked = [...new Set([...pre.matchAll(IPC_INVOKE_RE)].map((m) => m[1]))];
  assert.ok(invoked.length > 100, `expected the full bridge, found ${invoked.length}`);
  const missing = invoked.filter((c) => !registered.has(c));
  assert.deepEqual(missing, [],
    `preload invokes these channels but nothing registers them — the call rejects at runtime: ${missing.join(', ')}`);
});

test('no IPC channel is registered twice', () => {
  // ipcMain.handle throws on a duplicate; a duplicate `on` silently double-fires.
  const dupes = [...registeredChannels()]
    .filter(([, w]) => w.filter((x) => x.kind === 'handle').length > 1)
    .map(([c, w]) => `${c} (${w.map((x) => x.where).join(', ')})`);
  assert.deepEqual(dupes, [], `duplicate IPC handlers: ${dupes.join('; ')}`);
});

test('every lib module the renderer depends on is actually script-loaded', () => {
  // The printer-alerts defect: lib/printer-alerts.js registered computePrinterAlerts,
  // integrations.js reached for it, and NO shell ever loaded the file — so the feature was
  // dead in the shipped app despite 22 passing unit tests.
  //
  // The rule is deliberately narrow: flag a module that NO shell loads. Khayt and Bed
  // Ready load different script sets, and a module present in one and absent from the
  // other is an intentional flavor difference — Bed Ready omits webcam, privacy and
  // telemetry on purpose, and every reference to them is typeof-guarded. Widening this to
  // per-shell produced exactly those false positives.
  const shells = ['renderer/index.html', 'renderer/bedready.html'];
  const loadedAnywhere = new Set();
  for (const shell of shells) {
    for (const m of readRoot(shell).matchAll(/<script src="([^"]+)"/g)) {
      loadedAnywhere.add(path.basename(m[1]));
    }
  }
  const rendererSrc = fs.readdirSync(path.join(root, 'renderer'))
    .filter((f) => f.endsWith('.js'))
    .map((f) => readRoot('renderer/' + f)).join('\n');

  const dead = [];
  for (const f of fs.readdirSync(path.join(root, 'lib')).filter((x) => x.endsWith('.js'))) {
    if (loadedAnywhere.has(f)) continue;
    const src = readRoot('lib/' + f);
    const globals = [...new Set([...src.matchAll(/(?:globalThis|window|global)\.([A-Za-z_$][\w$]*)\s*=/g)]
      .map((m) => m[1]))].filter((g) => g !== 'exports');
    for (const g of globals) {
      // A real reference: called, typeof-tested, or read off the global object. NOT `g:`
      // as an object key — `fullSpectrum: fsOn` in an options literal is not a use.
      const used = new RegExp(`(?<![.\\w$])${g}\\s*\\(|typeof\\s+${g}\\b|(?:window|globalThis)\\.${g}\\b`);
      if (used.test(rendererSrc)) {
        dead.push(`lib/${f} provides ${g} and the renderer uses it, but no shell loads the file`);
      }
    }
  }
  assert.deepEqual(dead, [], dead.join('; '));
});
