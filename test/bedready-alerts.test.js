/**
 * Bed Ready's printer alerts.
 *
 * lib/printer-alerts.js decides WHAT is worth firing, debounce and all; that is tested
 * elsewhere. What is pinned here is that Bed Ready has somewhere for an alert to go at all.
 *
 * app-boot.js has always called dispatchPrinterAlerts after every poll, in both apps. In
 * Bed Ready it reached bedready-shim.js's no-op, so the app watched printers go offline and
 * said nothing — the same silence as the queue that could not move a job.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const SRC = fs.readFileSync(path.join(ROOT, 'renderer/bedready-alerts.js'), 'utf8');
const LIB = fs.readFileSync(path.join(ROOT, 'lib/printer-alerts.js'), 'utf8');

function boot({ withLib = true } = {}) {
  const toasts = [];
  const ctx = { settings: { notifyOffline: true, notifyError: true }, machines: [{ id: 'M1', name: 'U1' }], document: { hidden: false },
                toast: (msg, kind) => toasts.push({ msg, kind }), module: undefined };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  if (withLib) vm.runInContext(LIB, ctx);
  vm.runInContext(SRC, ctx);
  return { ctx, toasts };
}

// isFailedPoll() keys off `error`, not an `ok` flag, and offlineThreshold is 3 polls.
const cache = (over) => ({ M1: Object.assign({ state: 'idle', failCount: 0 }, over || {}) });
const failing = () => cache({ error: 'ECONNREFUSED', failCount: 5 });

test('it replaces the shim no-op', () => {
  const ctx = { dispatchPrinterAlerts: function () { return ''; }, settings: {}, document: {} };
  ctx.globalThis = ctx; vm.createContext(ctx);
  vm.runInContext(LIB, ctx); vm.runInContext(SRC, ctx);
  assert.ok(!/return\s*''/.test(String(ctx.dispatchPrinterAlerts)), 'the no-op survived');
});

test('a printer going offline reaches the maker', () => {
  const { ctx, toasts } = boot();
  ctx.dispatchPrinterAlerts(cache());                                   // baseline
  // failCount is the module's own counter across polls, and offlineThreshold is 3 —
  // one bad poll is a blip, which is the point of the threshold.
  for (let i = 0; i < 4; i++) ctx.dispatchPrinterAlerts(failing());
  assert.ok(toasts.length >= 1, 'an offline printer should say so');
  assert.ok(toasts.some((x) => /offline/i.test(x.msg)), 'and say what happened: ' + JSON.stringify(toasts));
});

test('a steady printer says nothing at all', () => {
  const { ctx, toasts } = boot();
  for (let i = 0; i < 5; i++) ctx.dispatchPrinterAlerts(cache());
  assert.equal(toasts.length, 0, 'nothing changed, so there is nothing to report');
});

test('without the library it degrades quietly instead of throwing every poll', () => {
  const { ctx, toasts } = boot({ withLib: false });
  assert.doesNotThrow(() => ctx.dispatchPrinterAlerts(cache()));
  assert.equal(toasts.length, 0);
});

test('a failed diff still advances the baseline', () => {
  // Otherwise every later poll re-reports the same transition forever.
  const { ctx, toasts } = boot();
  ctx.KhaytPrinterAlerts.computePrinterAlerts = () => { throw new Error('boom'); };
  assert.doesNotThrow(() => ctx.dispatchPrinterAlerts(failing()));
  ctx.KhaytPrinterAlerts.computePrinterAlerts = () => ({ alerts: [], state: {} });
  assert.doesNotThrow(() => ctx.dispatchPrinterAlerts(failing()));
  assert.equal(toasts.length, 0);
});

test('bedready.html loads the library and the dispatcher, after the shim', () => {
  const html = fs.readFileSync(path.join(ROOT, 'renderer/bedready.html'), 'utf8');
  const shim = html.indexOf('bedready-shim.js');
  const lib = html.indexOf('lib/printer-alerts.js');
  const mod = html.indexOf('bedready-alerts.js');
  assert.ok(lib !== -1 && mod !== -1, 'both must be loaded or the call stays a no-op');
  assert.ok(mod > lib && mod > shim, 'load order: shim -> library -> dispatcher');
});

test('Khayt does not load it — integrations.js owns its own dispatcher', () => {
  const html = fs.readFileSync(path.join(ROOT, 'renderer/index.html'), 'utf8');
  assert.ok(!html.includes('bedready-alerts.js'),
    'this would replace the version that fans out to Telegram and webhooks');
});
