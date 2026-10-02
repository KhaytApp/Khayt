/**
 * The seam between the sync engine and the app's own state.
 *
 * Every cloud merge ends with `applySnapshot(local)` → `applyStoreFromSnapshot`,
 * which runs the merged store through `normalizeStoreSnapshot` before assigning
 * it back into the renderer's module-level arrays. That path is where merged data
 * can quietly fail to land, and it depends on THREE separate lists agreeing:
 *
 *   collectStoreCollections()   what gets snapshotted, synced and pushed
 *   ARRAY_COLLECTIONS           what survives normalizeStoreSnapshot
 *   applyStoreFromSnapshot      what is assigned back into app state
 *
 * They agree today — checked by running, not by reading. Nothing enforces it. Add
 * a collection to the first and forget the second, and normalize drops the key,
 * `if (store.X)` is false, and every pull silently discards that collection's
 * merged data while sync reports success. Exactly the shape of the tombstone bug
 * this suite was written after: correct-looking, permanent, and unannounced.
 *
 * The per-record half is the same failure one level down: a record that arrives
 * from another device but fails its collection's filter is dropped here, kept
 * there, and the two never converge. `isValidOrder` is the only filter that asks
 * for more than an id — date, status AND project — so orders are where that can
 * actually happen.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const src = (f) => fs.readFileSync(path.join(ROOT, 'renderer', f), 'utf8');

require(path.join(ROOT, 'lib/store-validate.js'));
const V = global.KhaytStoreValidate;

/**
 * These lists are read out of source, so a regex that quietly stops matching
 * would turn this file into a test that passes by finding nothing. Every
 * extraction is floor-checked against a count that only ever grows.
 */
const FLOOR = 25;

function collectedCollections() {
  const body = src('app-state.js').match(/function collectStoreCollections\(\)\s*\{[\s\S]*?\n\}/);
  assert.ok(body, 'could not find collectStoreCollections — this test is blind, fix the extraction');
  const names = [...body[0].matchAll(/\b([a-zA-Z_]\w*)\b(?=\s*[,\n])/g)]
    .map((m) => m[1])
    .filter((n) => !['function', 'collectStoreCollections', 'return'].includes(n));
  const out = [...new Set(names)].filter((n) => n !== 'settings').sort();
  assert.ok(out.length >= FLOOR, `only found ${out.length} collections — the extraction broke`);
  return out;
}

function restoredCollections() {
  const body = src('app-state.js').match(/function applyStoreFromSnapshot\([\s\S]*?\n\}/);
  assert.ok(body, 'could not find applyStoreFromSnapshot — this test is blind, fix the extraction');
  const names = [...body[0].matchAll(/if \(store\.(\w+)\)/g)].map((m) => m[1]);
  const out = [...new Set(names)].filter((n) => n !== 'settings' && n !== '__corrupt').sort();
  assert.ok(out.length >= FLOOR, `only found ${out.length} restores — the extraction broke`);
  return out;
}

test('everything that is synced also survives normalization', () => {
  const collected = collectedCollections();
  const known = [...V.ARRAY_COLLECTIONS].sort();
  const missing = collected.filter((c) => !known.includes(c));
  assert.deepEqual(missing, [],
    'these are pushed to the cloud but dropped by normalizeStoreSnapshot, so merged data never lands');
});

test('everything that survives normalization is assigned back into app state', () => {
  const known = [...V.ARRAY_COLLECTIONS].sort();
  const restored = restoredCollections();
  const missing = known.filter((c) => !restored.includes(c));
  assert.deepEqual(missing, [],
    'these survive normalization but applyStoreFromSnapshot never assigns them, so a merge is a no-op for them');
});

test('nothing is normalized or restored that is never snapshotted', () => {
  // The reverse drift: dead entries are harmless but they mean the lists have
  // stopped being maintained together, which is how the live gap arrives.
  const collected = collectedCollections();
  const known = [...V.ARRAY_COLLECTIONS].sort();
  assert.deepEqual(known.filter((c) => !collected.includes(c)), [],
    'normalize knows collections that are never built into a snapshot');
  assert.deepEqual(restoredCollections().filter((c) => !known.includes(c)), [],
    'applyStoreFromSnapshot restores collections normalize has already dropped — a dead branch');
});

test('sync metadata survives normalization', () => {
  // rev, updatedAt and tombstones are what the engine reasons with. If normalize
  // rebuilt records field-by-field instead of keeping them whole, every merge
  // would strip them, every save would re-stamp everything, and this device would
  // win every conflict against the shop's other machines.
  const store = {
    printLog: [{ id: 'o1', date: '2026-07-01', status: 'pending', project: 'bracket', rev: 7, updatedAt: '2026-07-01T00:00:00.000Z' }],
    clients: [{ id: 'c1', name: 'سارة', rev: 3, updatedAt: '2026-07-02T00:00:00.000Z' }],
    tombstones: [{ id: 'o2', collection: 'printLog', rev: 4, deletedAt: '2026-07-03T00:00:00.000Z' }],
  };
  const { normalized } = V.normalizeStoreSnapshot(store);

  assert.equal(normalized.printLog[0].rev, 7);
  assert.equal(normalized.printLog[0].updatedAt, '2026-07-01T00:00:00.000Z');
  assert.equal(normalized.clients[0].rev, 3);
  assert.deepEqual(normalized.tombstones, store.tombstones, 'tombstones are a synced collection like any other');
  assert.deepEqual(normalized.printLog[0], store.printLog[0], 'records are kept whole, not rebuilt');
});

test('an order missing a field is KEPT, read as "", so every device converges', () => {
  // This was the hazard: the strictest filter in the app dropped such an order
  // on the device that merged it and kept it on the one that made it, so the
  // two never converged, and the desktop's next save erased it. Since the
  // Mac's data-loss audit (2026-10-02) an order only needs an id, like every
  // other collection; a missing text field reads as "", as the Mac decodes it.
  const cases = {
    'no date': [{ id: 'o1', status: 'pending', project: 'p' }, { date: '' }],
    'no status': [{ id: 'o1', date: '2026-07-01', project: 'p' }, { status: '' }],
    'no project': [{ id: 'o1', date: '2026-07-01', status: 'pending' }, { project: '' }],
    'project not a string': [{ id: 'o1', date: '2026-07-01', status: 'pending', project: 12 }, { project: '12' }],
  };
  for (const [label, [order, filled]] of Object.entries(cases)) {
    const { normalized } = V.normalizeStoreSnapshot({ printLog: [order] });
    assert.equal(normalized.printLog.length, 1, `${label}: must be kept`);
    assert.deepEqual(normalized.printLog[0], { ...order, ...filled }, label);
  }
  const good = { id: 'o1', date: '2026-07-01', status: 'pending', project: 'p' };
  assert.equal(V.normalizeStoreSnapshot({ printLog: [good] }).normalized.printLog.length, 1);
});

test('an order built from a hostile outside body still survives normalization', async () => {
  // The live risk: an order built from a body the shop did not write — the phone,
  // or a Salla/Zid webhook — where `project` arrives as a number or an object. If
  // it reached the record uncoerced, the order would be created, persisted, pushed
  // to the cloud, and then silently dropped by every device that merged it,
  // including this one at next launch. A shop would see an order on the tablet
  // that no other machine has.
  //
  // Driven through the real endpoint rather than scanned for `String(...)` in the
  // source: a first attempt at the source scan reported a site with "no project"
  // because the literal uses shorthand, which is exactly how a syntax check lies.
  // What matters is the record that comes out, so that is what is asserted.
  const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

  const PORT = 3988;
  const PIN = '4321';
  const handlers = new Map();
  const noop = () => {};
  let store = {
    inventory: [], settings: { currency: 'SAR' },
    printLog: [], machines: [], clients: [], waitingList: [], tombstones: [],
  };

  registerLanServer({
    fs,
    ipcMain: { handle: (n, f) => handlers.set(n, f) },
    BrowserWindow: class { static getAllWindows() { return []; } },
    safeJsonParse: (s, f) => { try { return JSON.parse(s); } catch { return f; } },
    syncLanServerStoreFromDisk: noop,
    resolveStoreSecret: (v) => v,
    isStoreSecretMasked: () => false,
    migrateLanApiSecrets: noop,
    ensureLanIntakeToken: () => ({ token: 'tok', generated: false }),
    ensureLanIntakePin: () => ({ pin: '1234', generated: false }),
    ensureLanCalendarToken: () => ({ token: 'cal', generated: false }),
    writeStoreToDisk: async () => {},
    persistLanStoreUpdate: async (s) => { store = s; },
    updateStoreOnDisk: async (fn) => { store = fn(store); return store; },
    getLanServerStore: () => store,
    setLanServerStore: (s) => { store = s; },
    getMainWindow: () => null,
    statusPagesDir: path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
  });

  const started = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(started && started.ok, `server did not start: ${JSON.stringify(started)}`);

  try {
    const post = (body) => fetch(`http://127.0.0.1:${PORT}/api/orders`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-khayt-pin': PIN },
      body: JSON.stringify(body),
    });

    const hostile = [
      ['a number', { project: 12345, client: 'Sara', price: 100 }],
      ['an object', { project: { a: 1 }, client: 'Sara', price: 100 }],
      ['an array', { project: ['x', 'y'], client: 'Sara', price: 100 }],
      ['a hostile status', { project: 'p', status: { evil: 1 } }],
    ];

    for (const [label, body] of hostile) {
      store.printLog = [];
      const res = await post(body);
      assert.equal(res.status, 201, `${label}: expected the order to be accepted`);
      const created = store.printLog[0];
      assert.ok(created, `${label}: no order was created`);

      const { normalized } = V.normalizeStoreSnapshot({ printLog: [created] });
      assert.equal(normalized.printLog.length, 1,
        `${label}: the created order does not survive normalization — it would exist on this device and nowhere else`);
      assert.equal(typeof created.project, 'string', `${label}: project reached the record uncoerced`);
      assert.equal(typeof created.status, 'string', `${label}: status reached the record uncoerced`);
    }

    // An order with no project at all is refused outright rather than stored as
    // something that cannot survive a merge — the right end to fail at.
    for (const body of [{ client: 'Sara' }, { project: '', client: 'Sara' }]) {
      store.printLog = [];
      assert.equal((await post(body)).status, 400);
      assert.equal(store.printLog.length, 0, 'refused, and nothing was written');
    }
  } finally {
    const stop = handlers.get('hub:stop-lan-server');
    if (stop) await stop(null, {});
  }
});

/* ============================================================
   The same failure one level further down: per-RECORD fields
   ============================================================ */

test('every field v3.6.0 added survives normalization', () => {
  // The checks above prove the three COLLECTION lists agree. Nothing proves that
  // the fields on a record survive — and that is the same bug one level down.
  // `subscriptions` and `auditLog` were once stripped here and reset on every
  // restart; a field can go the same way, and more quietly, because the
  // collection still arrives and only part of each record is missing.
  //
  // Everything the estimate→actual chain writes is a NEW field on an EXISTING
  // collection, so all of it is exposed to exactly that. If any of these is
  // dropped, the shop keeps its orders and print files but silently loses which
  // settings worked, what a job really cost, and what a customer was quoted.
  const store = {
    version: 3,
    printLog: [{
      id: 'O1', date: '2026-07-31', status: 'completed', project: 'Bracket run',
      actualPrintTime: 3.21, actualWeight: 41.8,
      actualsSource: { time: 'moonraker', weight: 'moonraker', at: '2026-07-31T00:00:00Z' },
      parts: [{ id: 'p1', printFileId: 'F1', setupId: 'S1', printTime: 3, printWeight: 40, qty: 1 }],
    }],
    printFiles: [{
      id: 'F1', name: 'Bracket', createdAt: 1,
      contentHash: 'abc123', geometryKey: '12:8000:20x20x20',
      setups: [{ id: 'S1', name: 'Draft', ok: 3, failed: 0, layerHeightMm: 0.28 }],
    }],
    waitingList: [{
      id: 'W1', clientName: 'A', project: 'x', status: 'active', estValue: 113.77,
      modelQuote: { price: 113.77, currency: 'SAR', grams: 43.1, hours: 3.22, exact: true, binding: false },
    }],
    settings: {
      currency: 'SAR',
      estimator: { densityGPerCm3: 1.27, infillPct: 0.6, shellFactor: 0.35, wastePct: 0.03, throughputMm3PerS: 2.7 },
      lanApi: { enabled: true, intakeQuote: { enabled: true, presetId: 'P1', spoolCost: 90, marginPct: 40 } },
    },
  };

  const { normalized } = V.normalizeStoreSnapshot(store);
  const order = normalized.printLog?.[0];
  const file = normalized.printFiles?.[0];
  const wait = normalized.waitingList?.[0];
  const set = normalized.settings;

  assert.ok(order, 'the order itself was dropped');
  // R3 — what the job really cost, and whether a printer or a person said so.
  assert.equal(order.actualPrintTime, 3.21);
  assert.equal(order.actualWeight, 41.8);
  assert.equal(order.actualsSource?.time, 'moonraker',
    'without provenance a measured figure and a typed one become indistinguishable');
  // The order→file link, which is what makes any of it answerable per setup.
  assert.equal(order.parts?.[0]?.printFileId, 'F1');
  assert.equal(order.parts?.[0]?.setupId, 'S1');

  assert.ok(file, 'the print file itself was dropped');
  assert.equal(file.contentHash, 'abc123', 'without this a returning customer\'s file is a stranger again');
  assert.equal(file.geometryKey, '12:8000:20x20x20');
  assert.equal(file.setups?.[0]?.ok, 3, 'the record of which settings worked');

  assert.ok(wait, 'the request itself was dropped');
  assert.equal(wait.modelQuote?.price, 113.77, 'what the customer was actually shown');
  assert.equal(wait.modelQuote?.exact, true, 'and whether that came off a slicer');

  // Settings go through sanitisePlainObject, which walks keys rather than an
  // allowlist — so these survive today. Pinned because that is a choice, not a
  // law, and switching it to an allowlist would silently reset a shop's pricing.
  assert.equal(set?.estimator?.densityGPerCm3, 1.27);
  assert.equal(set?.estimator?.infillPct, 0.6);
  assert.equal(set?.lanApi?.intakeQuote?.enabled, true);
  assert.equal(set?.lanApi?.intakeQuote?.marginPct, 40);
});
