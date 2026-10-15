/**
 * POST /api/quote — costing a part from the phone.
 *
 * A customer walks in holding a part. Today that means walking back to the
 * desktop, which is why quoting was the strongest of the phone-feature
 * candidates: it is revenue, and it happens standing up.
 *
 * The design constraint that shapes everything here: the phone must never
 * produce a different number from the desktop it is paired to. So the endpoint
 * calls the desktop's own `lib/calculator-cost.js` against the live store
 * rather than reimplementing the maths server-side. Two implementations means
 * two costs for one part, and the wrong one is whichever the shop happens to be
 * looking at.
 *
 * The tests boot the real server and speak HTTP to it. Asserting against the
 * calculator directly would prove the calculator works — which is already known
 * — and nothing about the endpoint, its auth, or its handling of a hostile body.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 3991;
const PIN = '4321';
const BASE = `http://127.0.0.1:${PORT}`;

const handlers = new Map();
const noop = () => {};

// A store with real pricing inputs: a resin spool to exercise the per-kg branch,
// and a packaging cost that must reach the maths through the injected context.
let store = {
  inventory: [
    { id: 'f-pla', material: 'PLA', materialType: 'filament', cost: 100, weight: 1000 },
    { id: 'f-resin', material: 'Resin', materialType: 'resin', cost: 200, weight: 1000 },
  ],
  settings: { defaultPackagingCost: 2, currency: 'SAR' },
  printLog: [], machines: [], clients: [], waitingList: [], tombstones: [],
};

before(async () => {
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
    persistLanStoreUpdate: async () => {},
    updateStoreOnDisk: async (fn) => { store = fn(store); return store; },
    getLanServerStore: () => store,
    setLanServerStore: (s) => { store = s; },
    getMainWindow: () => null,
    statusPagesDir: path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
  });
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, `server did not start: ${JSON.stringify(r)}`);
});

after(async () => {
  const stop = handlers.get('hub:stop-lan-server');
  if (stop) await stop(null, {});
});

const quote = (part, opts = {}) => fetch(`${BASE}/api/quote`, {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    ...(opts.noPin ? {} : { 'x-khayt-pin': PIN }),
  },
  body: opts.raw !== undefined ? opts.raw : JSON.stringify(part),
});

/** A part with every cost input populated, so nothing is silently zero. */
const FULL_PART = {
  spoolCost: 100, spoolWeight: 1000, printWeight: 50,
  printTime: 2, wearRate: 1, powerDraw: 200, elecRate: 0.5,
  prepTime: 0.25, postTime: 0.5, laborRate: 20,
  failureRate: 5, qty: 2,
};

test('a part is costed with the desktop\'s own maths', async () => {
  const r = await quote(FULL_PART);
  assert.equal(r.status, 200);
  const body = await r.json();

  // The authority check: the endpoint must agree with the calculator the
  // desktop uses, run against the same store. Not a hardcoded number — a
  // hardcoded number would still pass if both sides drifted together.
  const cost = require('../lib/calculator-cost.js');
  const ctx = { inventory: store.inventory, settings: store.settings };
  const expected = cost.computePartBaseCost({ ...FULL_PART, qty: 2 }, ctx);

  assert.ok(Math.abs(body.unitCost - expected) < 0.0001,
    `endpoint said ${body.unitCost}, the desktop's calculator says ${expected}`);
  assert.ok(Math.abs(body.totalCost - expected * 2) < 0.0001, 'total is per-unit times qty');
  assert.equal(body.currency, 'SAR', 'the shop\'s currency comes back so the phone need not guess');
});

test('the breakdown sums to the cost — the phone can show where the money goes', async () => {
  const body = await (await quote(FULL_PART)).json();
  const { material, machine, labor, buffer } = body.breakdown;
  const sum = material + machine + labor + buffer;
  assert.ok(Math.abs(sum - body.unitCost) < 0.0001,
    `breakdown sums to ${sum} but unit cost is ${body.unitCost}`);
  assert.ok(material > 0 && machine > 0 && labor > 0 && buffer > 0,
    'every bucket should be populated by a fully-specified part');
});

test('store settings reach the maths — packaging is not silently dropped', async () => {
  // The endpoint injects the store as context rather than relying on renderer
  // globals that do not exist in the main process. If that injection broke, the
  // cost would quietly come back lower, which is the worst way for it to fail.
  const withPackaging = await (await quote(FULL_PART)).json();

  const previous = store.settings;
  store.settings = { ...previous, defaultPackagingCost: 0 };
  const without = await (await quote(FULL_PART)).json();
  store.settings = previous;

  assert.ok(withPackaging.unitCost > without.unitCost,
    'a configured packaging cost must raise the quoted cost');
});

test('inventory reaches the maths — a resin spool is costed per kg, not per spool', async () => {
  // The resin branch reads materialType off the store's inventory. It is the
  // clearest proof the live inventory is being consulted and not an empty array.
  const base = { spoolCost: 200, spoolWeight: 500, printWeight: 100, qty: 1 };
  const asResin = await (await quote({ ...base, filamentId: 'f-resin' })).json();
  const asFilament = await (await quote({ ...base, filamentId: 'f-pla' })).json();
  assert.notEqual(asResin.unitCost, asFilament.unitCost,
    'resin costs per kg and filament per spool — identical numbers mean inventory was not read');
});

test('a price tier is reported when the quantity reaches it, and not before', async () => {
  const tiered = { ...FULL_PART, priceTiers: [{ minQty: 10, pricePerUnit: 25 }] };

  const below = await (await quote({ ...tiered, qty: 5 })).json();
  assert.equal(below.priceTier, null, 'below the tier the caller shows its own price');

  const at = await (await quote({ ...tiered, qty: 10 })).json();
  assert.deepEqual(at.priceTier, { minQty: 10, pricePerUnit: 25 });
});

test('costs need the owner PIN — they are not customer-facing', async () => {
  const r = await quote(FULL_PART, { noPin: true });
  assert.equal(r.status, 401, 'what a job costs the shop is not public');
});

test('a hostile or empty body is refused, not costed', async () => {
  for (const raw of ['', 'not json', '[]', 'null', '"a string"', '123']) {
    const r = await quote(null, { raw });
    assert.equal(r.status, 400, `body ${JSON.stringify(raw)} should be rejected`);
  }
});

test('a part with no numbers costs the packaging, not NaN', async () => {
  // An empty draft is what the phone sends before the user types anything.
  //
  // The first version of this test expected zero and was wrong: the desktop
  // charges `defaultPackagingCost` per order regardless of what is in it, so a
  // blank part legitimately costs the packaging. Asserting zero would have been
  // asserting a bug into place. What actually matters is that nothing is NaN —
  // NaN rendered into a field a customer is looking at is the real failure.
  const body = await (await quote({})).json();
  assert.ok(Number.isFinite(body.unitCost), `unitCost is ${body.unitCost}`);
  assert.ok(Number.isFinite(body.totalCost), `totalCost is ${body.totalCost}`);
  assert.equal(body.unitCost, store.settings.defaultPackagingCost,
    'an empty part costs exactly the packaging');
  for (const [k, v] of Object.entries(body.breakdown)) {
    assert.ok(Number.isFinite(v), `${k} is not a finite number: ${v}`);
  }
});

test('an absurd quantity is clamped instead of overflowing the total', async () => {
  const body = await (await quote({ ...FULL_PART, qty: 1e12 })).json();
  assert.ok(body.qty <= 100000, `qty should be clamped, got ${body.qty}`);
  assert.ok(Number.isFinite(body.totalCost));
});

/**
 * Pricing, now that lib/pricing.js is extracted out of build.js.
 *
 * The endpoint runs the SAME function the calculator screen runs, so a quote
 * given standing next to a customer matches the one on the desk. Before the
 * extraction this was impossible without a second implementation, which is why
 * the endpoint originally shipped costs only.
 */
test('a margin turns cost into a price', async () => {
  const body = await (await quote({ ...FULL_PART, margin: 50 })).json();
  const expected = body.totalCost * 1.5;
  assert.ok(Math.abs(body.price.total - expected) < 0.001,
    `margin not applied: total ${body.price.total}, cost ${body.totalCost}`);
});

test('with no margin the price equals the cost — honest, not a guess', async () => {
  const body = await (await quote(FULL_PART)).json();
  assert.ok(Math.abs(body.price.total - body.totalCost) < 0.001,
    'quoting a shop\'s own markup it never supplied would be inventing a number');
});

test('the price matches lib/pricing.js exactly — one implementation, not two', async () => {
  // The authority check. Comparing against a hardcoded figure would still pass
  // if the endpoint and the calculator drifted together.
  const pricing = require('../lib/pricing.js');
  const part = { ...FULL_PART, margin: 35, discountPct: 10, rush: true, shippingCost: 25,
    extraLines: [{ amount: 12.5 }] };
  const body = await (await quote(part)).json();

  const expected = pricing.quoteTotal({
    baseCost: body.totalCost, qty: body.qty, margin: 35,
    priceTier: null, discountPct: 10, rushEnabled: true,
    rushPct: store.settings.rushFeePct ?? 25,
    shippingCost: 25, extraLines: [{ amount: 12.5 }],
  });
  assert.ok(Math.abs(body.price.total - expected.total) < 0.001,
    `endpoint ${body.price.total} vs pricing module ${expected.total}`);
  assert.ok(Math.abs(body.price.rushFee - expected.rushFee) < 0.001, 'rush fee must agree too');
});

test('rush uses the shop\'s configured percentage, not a hardcoded one', async () => {
  const previous = store.settings;
  store.settings = { ...previous, rushFeePct: 50 };
  const high = await (await quote({ ...FULL_PART, margin: 100, rush: true })).json();
  store.settings = { ...previous, rushFeePct: 10 };
  const low = await (await quote({ ...FULL_PART, margin: 100, rush: true })).json();
  store.settings = previous;

  assert.ok(high.price.rushFee > low.price.rushFee,
    'a shop that charges 50% for rush must not be quoted at 10%');
});

test('a price tier overrides the margin here exactly as it does on the desktop', async () => {
  const part = { ...FULL_PART, qty: 10, margin: 500, priceTiers: [{ minQty: 10, pricePerUnit: 25 }] };
  const body = await (await quote(part)).json();
  assert.equal(body.price.beforeDiscount, 250, 'tier price x qty, margin ignored');
});

test('the shop\'s overhead per print hour is in the phone\'s price when it is on, and only then', async () => {
  const previous = store.settings;
  const costs = [{ id: 'r', name: 'Rent', amount: 2100 }];
  store.settings = { ...previous, fixedCosts: costs };
  const off = await (await quote({ ...FULL_PART, margin: 50 })).json();
  store.settings = { ...previous, fixedCosts: costs, overheadPerHour: { enabled: true, monthlyHours: 500 } };
  const on = await (await quote({ ...FULL_PART, margin: 50 })).json();
  const tiered = await (await quote({ ...FULL_PART, qty: 10, margin: 50,
    priceTiers: [{ minQty: 10, pricePerUnit: 25 }] })).json();
  store.settings = previous;

  assert.equal(off.price.overhead, 0, 'off: the price it always was');
  // 2 h × 2 pieces × 4.20 an hour, marked up 50% with the rest of the cost.
  assert.equal(on.price.overhead, 16.8);
  const expectedTotal = Math.round((on.totalCost + 16.8) * 1.5 * 10000) / 10000;
  assert.ok(Math.abs(on.price.total - expectedTotal) < 0.001, `${on.price.total} vs ${expectedTotal}`);
  assert.equal(on.totalCost, off.totalCost, 'the part\'s cost is the cost; the overhead is its own line');
  assert.equal(tiered.price.overhead, 0, 'a price tier replaces cost-plus, overhead and all');
  assert.equal(tiered.price.total, 250);
});
