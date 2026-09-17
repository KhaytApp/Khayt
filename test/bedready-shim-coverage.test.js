/**
 * Does every control Bed Ready renders actually do something?
 *
 * bedready-shim.js declares ~150 business functions as `function () { return ''; }` so the
 * shared framework can boot without the modules Bed Ready drops. That is necessary and it
 * is also a trap: a stub is a FUNCTION, so `typeof fn === 'function'` is true, `fn?.()` is
 * safe, and `${fn()}` interpolates cleanly. A control wired to one renders, accepts the
 * click, runs its handler and returns the empty string. Nothing errors. Nothing says why.
 *
 * That is how "Add to print queue" — the calculator's primary button, and the only path in
 * the whole renderer that creates an order — spent the entire beta doing nothing, alongside
 * QC pass, QC fail, hold, mark-delivered, timeline, print-label and capture-failure-photo,
 * every one of them rendered on every card in the production queue.
 *
 * A test that boots the app and clicks things would catch this, and the e2e suite does some
 * of that. This is the cheap half: it checks the WIRING statically, so a name that goes back
 * to being a no-op fails in `npm test` rather than in a user's queue.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

const SHIM = 'renderer/bedready-shim.js';
const shimNames = new Set(JSON.parse(read(SHIM).match(/const FNS = (\[[^\]]*\])/s)[1]));

/** Scripts bedready.html loads, as repo-relative paths. */
const BR = [...read('renderer/bedready.html').matchAll(/<script src="([^"]+\.js)"/g)]
  .map((m) => m[1].replace(/^\.\.\//, '').replace(/^(?!lib\/)/, 'renderer/'));

/**
 * Names a Bed Ready module puts on the global object — i.e. really implements.
 *
 * The shim itself is excluded, which is the whole point: it assigns the same names.
 * It also assigns only `if (typeof g[n] === 'undefined')` and loads first, so a real
 * implementation must assign unconditionally to win.
 */
function implementedNames() {
  const out = new Map();
  for (const rel of BR) {
    if (rel === SHIM) continue;
    const p = path.join(ROOT, rel);
    if (!fs.existsSync(p)) continue;
    const src = fs.readFileSync(p, 'utf8');
    for (const m of src.matchAll(/(?:^|[\s;{])(?:global|window|globalThis|g)\.([A-Za-z_$][\w$]*)\s*=[^=]/g)) {
      if (!out.has(m[1])) out.set(m[1], rel);
    }
  }
  return out;
}

/**
 * Controls Bed Ready renders whose handler MUST be real, and where each is.
 *
 * Every one of these was a live button wired to a no-op. Listed by name rather than
 * derived, because the derivation is what failed to notice for a whole beta.
 */
const MUST_BE_REAL = {
  logPrint: 'Calculator → "Add to print queue" (wire-events.js). The only path that creates an order.',
  updateStatus: 'Queue card → the column buttons (Start print, Move to post, …).',
  holdOrder: 'Queue card → Hold ⏸.',
  qcPassOrder: 'Queue card → QC pass ✅.',
  qcFailOrder: 'Queue card → QC fail ❌.',
  markDelivered: 'Queue card → Mark delivered.',
  openOrderTimeline: 'Queue card → Timeline 🕐.',
  generateOrderLabel: 'Queue card → Print label 🏷.',
  captureFailurePhoto: 'Queue card (on hold) → Capture failure photo 📷.',
  dispatchPrinterAlerts: 'Printer polling → the offline/error alert.',
};

test('every shimmed name behind a live Bed Ready control is really implemented', () => {
  const impl = implementedNames();
  const dead = [];
  for (const [name, where] of Object.entries(MUST_BE_REAL)) {
    if (!impl.has(name)) dead.push(`${name} is still only bedready-shim.js's no-op — ${where}`);
  }
  assert.deepEqual(dead, [], 'controls Bed Ready renders that would silently do nothing:\n  ' + dead.join('\n  '));
});

test('a real implementation loads after the shim, or the shim would not be replaced', () => {
  const html = read('renderer/bedready.html');
  const shimAt = html.indexOf('bedready-shim.js');
  const impl = implementedNames();
  for (const name of Object.keys(MUST_BE_REAL)) {
    const rel = impl.get(name);
    if (!rel) continue; // the test above already reports this
    const tag = rel.replace(/^renderer\//, '').replace(/^lib\//, '../lib/');
    assert.ok(html.indexOf(tag) > shimAt,
      `${rel} implements ${name} but loads before bedready-shim.js, which would overwrite nothing`);
  }
});

/**
 * The forcing function: a NEW button on a queue card has to be classified.
 *
 * kanban.js is shared, so a card action added for Khayt lands in Bed Ready's queue too.
 * If it is `biz`-gated it never renders here; if it is not, its handler had better exist.
 * Anything unclassified fails, which is the conversation that did not happen the first
 * eight times.
 */
const KANBAN_ACTS = {
  // Rendered in Bed Ready — handler must be real.
  'status': 'live', 'hold-order': 'live', 'qc-pass': 'live', 'qc-fail': 'live',
  'mark-delivered': 'live', 'order-timeline': 'live', 'print-label': 'live',
  'order-label': 'live', 'capture-failure-photo': 'live', 'log-waste-card': 'live',
  'q-up': 'live', 'q-down': 'live', 'toggle-part-status': 'live',
  'kanban-slice-print': 'live', 'wo-kanban': 'live', 'assembly': 'live',
  // `biz`-gated in kanban.js — never rendered in enthusiast mode, so a stub is fine.
  'invoice': 'biz', 'pay': 'biz', 'bnpl-pay': 'biz', 'ship-order': 'biz', 'wa-quick': 'biz',
  // In the post: a business posts parcels, and it sits beside ship-order.
  'mark-shipped': 'biz',
  'approve-quote': 'biz', 'reject-quote': 'biz', 'share-quote': 'biz',
  'quote-approval-link': 'biz', 'share-tracking-link': 'biz',
  // Resin post-processing: rendered only for resin jobs, and still on the shim. Recorded
  // so it is a known gap rather than a surprise — see the review notes.
  'resin-log-wash': 'known-gap', 'resin-log-cure': 'known-gap', 'resin-complete': 'known-gap',
};

test('every queue-card action is classified as live, business-only or a known gap', () => {
  const acts = [...new Set([...read('renderer/kanban.js').matchAll(/data-act="([a-z-]+)"/g)].map((m) => m[1]))];
  const unclassified = acts.filter((a) => !(a in KANBAN_ACTS));
  assert.deepEqual(unclassified, [],
    'new queue-card action(s) with no decision recorded — does Bed Ready render them, and does the handler exist?\n  '
    + unclassified.join('\n  '));
});

test('nothing classified "live" is left to the shim', () => {
  const impl = implementedNames();
  // act → the global its handler calls (wire-events.js), for the ones the shim covers.
  const HANDLER = {
    'status': 'updateStatus', 'hold-order': 'holdOrder', 'qc-pass': 'qcPassOrder',
    'qc-fail': 'qcFailOrder', 'mark-delivered': 'markDelivered',
    'order-timeline': 'openOrderTimeline', 'print-label': 'generateOrderLabel',
    'capture-failure-photo': 'captureFailurePhoto',
  };
  const dead = [];
  for (const [act, kind] of Object.entries(KANBAN_ACTS)) {
    if (kind !== 'live') continue;
    const fn = HANDLER[act];
    if (!fn || !shimNames.has(fn)) continue;  // handler isn't one the shim stubs
    if (!impl.has(fn)) dead.push(`data-act="${act}" renders in Bed Ready but ${fn} is still the shim no-op`);
  }
  assert.deepEqual(dead, [], dead.join('\n  '));
});
