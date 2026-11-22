'use strict';
/**
 * Taking the cloud's copy down.
 *
 * `pullMerge` in renderer/cloud-sync.js did this with a constant from
 * renderer/settings.js, so a second host could not merge without writing the
 * rule a second time. This is that rule, lifted — and the load-bearing test is
 * `theLiftChangedNothing`, which runs the ORIGINAL body verbatim beside the new
 * one over generated books and requires the same store and the same report.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const sync = require('../lib/sync.js');
const inbox = require('../lib/cloud-inbox.js');

const clone = (o) => JSON.parse(JSON.stringify(o));

/** The renderer's own body, copied here verbatim rather than described. */
function originalMerge(local, server, appendOnly) {
  const payload = sync.extractDeltas(server, { rev: 0, ts: '' });
  const merged = sync.applyDeltas(local, payload, { appendOnly: appendOnly || [] });
  return merged;
}

test('the append-only list is the one the renderer has always used', () => {
  // The eight the renderer carried before the lift, written out here so the
  // move is checkable against what was actually there rather than against
  // itself. A ledger dropped from this list is entries that happened being
  // overwritten by a merge, on both apps at once.
  assert.deepEqual([...inbox.APPEND_ONLY].sort(), [
    '_auditLog', 'auditLog', 'envLogs', 'loyaltyLedger',
    'machMaintLog', 'shiftLogs', 'timeEntries', 'wasteLog',
  ]);
});

test('nothing keeps a second copy of the list', () => {
  // The whole point of the lift. A `CLOUD_APPEND_ONLY` anywhere is a list that
  // can drift from this one, and the drift would be silent.
  for (const file of ['renderer/settings.js', 'renderer/cloud-sync.js']) {
    const text = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
    assert.ok(!/const CLOUD_APPEND_ONLY\s*=\s*\[/.test(text),
      `${file} declares the list again`);
  }
});

test('a ledger is added to and never overwritten', () => {
  for (const ledger of inbox.APPEND_ONLY) {
    const local = { [ledger]: [{ id: 'e1', rev: 1, what: 'ours' }] };
    const server = { [ledger]: [{ id: 'e1', rev: 9, what: 'theirs' }, { id: 'e2', rev: 1 }] };
    const out = inbox.merge(local, server);
    assert.equal(out.store[ledger].find((r) => r.id === 'e1').what, 'ours',
      `${ledger}: an entry that happened was overwritten`);
    assert.ok(out.store[ledger].some((r) => r.id === 'e2'), `${ledger}: a new entry was dropped`);
  }
});

test('an ordinary collection takes the higher revision', () => {
  const out = inbox.merge(
    { orders: [{ id: 'o1', rev: 2, title: 'mine' }] },
    { orders: [{ id: 'o1', rev: 7, title: 'theirs' }] });
  assert.equal(out.store.orders[0].title, 'theirs');
  assert.equal(out.applied, 1);
});

test('a local record the cloud has not seen is left alone', () => {
  const out = inbox.merge({ orders: [{ id: 'mine', rev: 3 }] }, { orders: [] });
  assert.equal(out.store.orders.length, 1);
  assert.equal(out.applied, 0);
});

/**
 * The line that keeps a shop's own machine its own. A merge that replaced the
 * cloud address, the tax registration or a printer's IP would be the worst kind
 * of surprise, and `extractDeltas` walking only array collections is what stops
 * it. Asserted, because it is a property somebody could remove by "fixing"
 * extractDeltas.
 */
test('settings never come down', () => {
  const local = { settings: { currency: 'SAR', cloud: { url: 'https://mine' } }, orders: [] };
  const out = inbox.merge(local, {
    settings: { currency: 'USD', cloud: { url: 'https://theirs' } },
    orders: [{ id: 'o1', rev: 1 }],
  });
  assert.deepEqual(out.store.settings, { currency: 'SAR', cloud: { url: 'https://mine' } });
  assert.equal(out.store.orders.length, 1, 'and the records still merged');
});

test('a deletion elsewhere removes it here, and says it did', () => {
  const out = inbox.merge(
    { orders: [{ id: 'o1', rev: 1 }], tombstones: [] },
    { orders: [], tombstones: [{ collection: 'orders', id: 'o1', rev: 2, deletedAt: '2026-09-01' }] });
  assert.equal(out.store.orders.length, 0);
  assert.equal(out.removed, 1);
});

/**
 * Delete wins over a local edit — and the caller is told, so it can say so.
 * A merge that discarded somebody's work in silence is the failure the
 * conflicts list exists to prevent.
 */
test('a local edit lost to a remote delete is reported', () => {
  const out = inbox.merge(
    { orders: [{ id: 'o1', rev: 9, title: 'my new title' }], tombstones: [] },
    { orders: [], tombstones: [{ collection: 'orders', id: 'o1', rev: 2, deletedAt: '2026-09-01' }] });
  assert.equal(out.store.orders.length, 0);
  assert.ok(out.conflicts.length >= 1, 'the discarded edit was not reported');
});

test('the store is returned, not only mutated', () => {
  // A caller across a JavaScriptCore bridge holds a COPY of what it passed in,
  // so a merge it cannot see is a merge that did not happen.
  const local = { orders: [] };
  const out = inbox.merge(local, { orders: [{ id: 'o1', rev: 1 }] });
  assert.ok(out.store, 'no store came back');
  assert.equal(out.store.orders.length, 1);
});

test('a merge with no engine refuses rather than doing nothing', () => {
  const saved = globalThis.KhaytSync;
  try {
    globalThis.KhaytSync = undefined;
    assert.throws(() => inbox.merge({}, {}), /merge engine is not loaded/);
  } finally { globalThis.KhaytSync = saved; }
});

/** ── The lift ────────────────────────────────────────────────────────────── */

function withRevs(b) {
  for (const k of Object.keys(b)) {
    if (k !== 'tombstones' && Array.isArray(b[k])) b[k] = b[k].filter((r) => r.rev > 0);
  }
  return b;
}

test('a record the cloud holds without a rev comes down where this book has none, and overwrites nothing', () => {
  sync._resetIndex();
  const local = {
    inventory: [{ id: 'a', rev: 3, weight: 5 }],
    tombstones: [{ collection: 'inventory', id: 'gone', deletedAt: '2026-10-01T00:00:00Z' }],
  };
  const server = {
    inventory: [{ id: 'a', weight: 999 }, { id: 'n', weight: 7 }, { id: 'gone', weight: 1 }],
    giftCards: [{ id: 'g', balance: 50 }],
    loyaltyLedger: [{ id: 'L1', clientId: 'c', points: -100 }],
    settings: { currency: 'SAR' },
    tombstones: [],
  };
  const r = inbox.merge(local, server);
  assert.deepEqual(local.inventory.find((x) => x.id === 'a'), { id: 'a', rev: 3, weight: 5 }, 'overwrote a record here');
  assert.equal(local.inventory.find((x) => x.id === 'n').rev, 1);
  assert.ok(!local.inventory.some((x) => x.id === 'gone'), 'a deleted record came back');
  assert.equal(local.giftCards[0].id, 'g');
  assert.equal(local.loyaltyLedger[0].id, 'L1', 'a ledger row is added like any other');
  assert.equal(local.settings, undefined, 'settings never come down');
  assert.ok(r.applied >= 3);
});

function book(seed) {
  let n = seed;
  const rnd = () => (n = (n * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const collections = ['orders', 'printLog', 'inventory', 'wasteLog', 'timeEntries', 'clients'];
  const out = {};
  for (const c of collections) {
    if (rnd() < 0.2) continue;
    out[c] = [];
    for (let i = 0; i < Math.floor(rnd() * 6); i++) {
      out[c].push({ id: 'r' + Math.floor(rnd() * 8), rev: Math.floor(rnd() * 9), v: Math.floor(rnd() * 100) });
    }
  }
  out.tombstones = [];
  for (let i = 0; i < Math.floor(rnd() * 3); i++) {
    out.tombstones.push({ collection: pick(collections), id: 'r' + Math.floor(rnd() * 8),
                          rev: Math.floor(rnd() * 9), deletedAt: '2026-09-0' + (1 + Math.floor(rnd() * 8)) });
  }
  out.settings = { currency: pick(['SAR', 'USD']) };
  return out;
}

/**
 * `applyDeltas` IS NOT PURE, and this test found it out.
 *
 * It calls `noteSynced`, which writes into sync.js's module-level index — so
 * running the two implementations one after another in the same process is not
 * a fair comparison: the second one sees what the first left behind. Without
 * the reset below, seed 12 reported a conflict from one and not the other, and
 * the rule was identical the whole time.
 *
 * (`lib/cloud-client.js` states the opposite — "only applyDeltas is used, and
 * that touches no module-level index". Its conclusion holds anyway, because
 * Electron's main process is a different realm from the renderer, but the
 * reason given is wrong and the comment now says so.)
 */
test('the lift changed nothing, over two thousand books', () => {
  for (let seed = 1; seed <= 1000; seed++) {
    const local = book(seed);
    // Rev-less server records are the one deliberate change since the lift
    // (see the test below), so the comparison is of everything else.
    const server = withRevs(book(seed + 5000));

    const mineLocal = clone(local);
    const theirsLocal = clone(local);

    sync._resetIndex();
    const mine = inbox.merge(mineLocal, clone(server));
    sync._resetIndex();
    const theirs = originalMerge(theirsLocal, clone(server), [...inbox.APPEND_ONLY]);

    assert.deepEqual(mineLocal, theirsLocal, `seed ${seed}: the merged store differs`);
    assert.equal(mine.applied, theirs.applied, `seed ${seed}: applied differs`);
    assert.equal(mine.skipped, theirs.skipped, `seed ${seed}: skipped differs`);
    assert.equal(mine.removed, theirs.removed, `seed ${seed}: removed differs`);
    assert.deepEqual(mine.conflicts, theirs.conflicts, `seed ${seed}: conflicts differ`);
  }
});
