const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

/**
 * The IPC channel list is maintained by hand in two places: preload.js names
 * the channels the renderer may reach, and main.js (plus the lib/ modules it
 * delegates to) registers the handlers. A typo on either side fails SILENTLY —
 * `ipcRenderer.invoke` on an unhandled channel rejects at runtime, in a code
 * path that may only run for one shop with one feature enabled.
 *
 * Honest note: when this test was written the surface was already fully
 * consistent — 170 invoke channels, 151 handlers in main.js and the rest in
 * lib/ modules, with zero mismatches in either direction. It found nothing.
 * It exists because every OTHER hand-maintained list in this codebase had
 * drifted by the time anyone checked (the 153-file lint chain, settings.js's
 * export literal, the per-flavor CSS tokens), and this one is only consistent
 * until the next channel is added.
 */

function readMainSide() {
  let src = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  // RECURSIVE, because handlers no longer live only at the top of lib/.
  //
  // This read `lib/*.js` one level deep. When the printer-discovery, webcam and
  // payment-link handlers moved into `lib/main/`, seven registered channels
  // became invisible to this guard and it reported them as unregistered — the
  // handlers were fine, the guard had simply stopped looking where they were.
  //
  // A checker scoped to a path is a checker that expires the first time code
  // moves, which is the whole reason extractions are risky. Walking is what
  // makes the next extraction cost nothing here.
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else if (e.name.endsWith('.js')) src += '\n' + fs.readFileSync(full, 'utf8');
    }
  };
  walk(path.join(ROOT, 'lib'));
  return src;
}

const PRELOAD = fs.readFileSync(path.join(ROOT, 'preload.js'), 'utf8');
const MAIN = readMainSide();

const all = (re, src) => new Set([...src.matchAll(re)].map((m) => m[1]));

// Renderer side
const invoked = all(/ipcRenderer\.invoke\(\s*['"]([^'"]+)/g, PRELOAD);
const sent = all(/ipcRenderer\.send\(\s*['"]([^'"]+)/g, PRELOAD);
const listened = all(/ipcRenderer\.on\(\s*['"]([^'"]+)/g, PRELOAD);
// Main side
const handled = all(/ipcMain\.(?:handle|handleOnce)\(\s*['"]([^'"]+)/g, MAIN);
const received = all(/ipcMain\.(?:on|once)\(\s*['"]([^'"]+)/g, MAIN);
const pushed = all(/\.send\(\s*['"]([^'"]+)/g, MAIN);
// The LAN REST rules name the channel a write is announced on, and lib/lan-server.js
// sends it (`restWrite` → `webContents.send(out.emit.channel, …)`): a pushed
// channel all the same, so it counts as one.
for (const c of all(/\bchannel:\s*['"]([^'"]+)/g, fs.readFileSync(path.join(ROOT, 'lib', 'lan-rest.js'), 'utf8'))) pushed.add(c);

test('every channel the renderer invokes has a handler', () => {
  // The dangerous direction: this rejects at runtime, often in a rarely-hit path.
  const missing = [...invoked].filter((c) => !handled.has(c)).sort();
  assert.deepEqual(missing, [], `preload invokes channels nothing handles:\n  ${missing.join('\n  ')}`);
});

test('every channel the renderer sends has a listener', () => {
  // Worse than invoke: `send` is fire-and-forget, so an unlistened channel is
  // lost with no rejection at all. hub:flush-save-done is one of these — losing
  // it would strand the quit handshake until its 10s timeout.
  const missing = [...sent].filter((c) => !received.has(c)).sort();
  assert.deepEqual(missing, [], `preload sends channels nothing listens for:\n  ${missing.join('\n  ')}`);
});

test('every channel the renderer listens on is actually pushed', () => {
  // A dead listener is a feature that silently never fires — LAN events,
  // updater progress, tunnel status.
  const missing = [...listened].filter((c) => !pushed.has(c)).sort();
  assert.deepEqual(missing, [], `preload listens on channels main never sends:\n  ${missing.join('\n  ')}`);
});

test('no handler is unreachable from the preload bridge', () => {
  // The reverse drift: a handler kept alive after its caller was deleted is
  // dead main-process surface, and dead surface is where stale assumptions live.
  const orphans = [...handled].filter((c) => !invoked.has(c)).sort();
  assert.deepEqual(orphans, [], `handlers no preload method can reach:\n  ${orphans.join('\n  ')}`);
});

test('the audit is actually looking at something', () => {
  // A regex that silently stops matching would make every test above pass
  // vacuously — the exact failure mode these guards exist to prevent.
  assert.ok(invoked.size > 100, `expected a large invoke surface, found ${invoked.size}`);
  assert.ok(handled.size > 100, `expected a large handler surface, found ${handled.size}`);
  assert.ok(listened.size > 5, `expected renderer listeners, found ${listened.size}`);
  assert.ok(sent.size >= 1, `expected at least one fire-and-forget channel, found ${sent.size}`);
});
