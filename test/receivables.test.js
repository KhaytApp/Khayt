/**
 * lib/receivables.js is the aged-receivables computation, lifted.
 *
 * THE PROOF: `renderAgedReceivables`'s aggregation — everything down to where
 * it starts writing HTML — is copied below VERBATIM, its clock frozen and its
 * globals supplied, and run beside the module over thousands of generated
 * books. Every amount and every age is compared, bucket by bucket.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/business-scope.js');
require('../lib/content-languages.js');
const money = require('../lib/order-money.js');
const payments = require('../lib/order-payment.js');
const { CURRENCIES } = require('../lib/currencies.js');
const R = require('../lib/receivables.js');

const ORIGINAL = `
function renderAgedReceivables() {
  const el = $('#agedReceivablesSection');
  if (!el) return;
  const today = new Date(); today.setHours(0,0,0,0);

  const unpaid = printLog.filter(o => {
    if (o.voidedAt) return false;
    const ps = payStatus(o);
    return ps === 'unpaid' || ps === 'partial';
  });

  if (unpaid.length === 0) {
    el.innerHTML = \`<p style="color:var(--success);margin:0;">✅ No outstanding receivables.</p>\`;
    return;
  }

  const buckets = { '0–30': [], '31–60': [], '61–90': [], '90+': [] };
  function addToBucket(entry) {
    if      (entry.days <= 30) buckets['0–30'].push(entry);
    else if (entry.days <= 60) buckets['31–60'].push(entry);
    else if (entry.days <= 90) buckets['61–90'].push(entry);
    else                       buckets['90+'].push(entry);
  }
  unpaid.forEach(o => {
    const arClient = o.clientId ? clients.find(c => c.id === o.clientId) : null;
    const arClientName = arClient ? localName(arClient) : (o.client || '');

    if (o.instalments && o.instalments.length > 0) {
      // Age each unpaid instalment separately by its own dueDate
      o.instalments.forEach(ins => {
        if (ins.paid) return;
        const owed = Math.max(0, +ins.amount || 0);
        if (owed <= 0) return;
        const refDate = ins.dueDate || o.date;
        const instDate = new Date(refDate + 'T00:00:00');
        const days = Math.max(0, Math.floor((today - instDate) / 86400000));
        addToBucket({ id: o.id, project: o.project, client: arClientName, owed, days, payStatus: payStatus(o) });
      });
    } else {
      const orderDate = new Date((o.date || o.timestamp || today.toISOString()).split('T')[0] + 'T00:00:00');
      const days = Math.max(0, Math.floor((today - orderDate) / 86400000));
      const owed = orderOwedBase(o);
      if (owed > 0) addToBucket({ id: o.id, project: o.project, client: arClientName, owed, days, payStatus: payStatus(o) });
    }
  });

  const totalOwed = unpaid.reduce((s, o) => {
    if (o.instalments && o.instalments.length > 0) {
      return s + o.instalments.filter(ins => !ins.paid).reduce((si, ins) => si + Math.max(0, +ins.amount || 0), 0);
    }
    return s + orderOwedBase(o);
  }, 0);


  return { buckets, totalOwed };
}
return renderAgedReceivables;`;

function runOriginal(orders, settings, clients, now) {
  const ctx = { settings, clients };
  const RealDate = Date;
  class FrozenDate extends RealDate {
    constructor(...args) { super(...(args.length ? args : [now.getTime()])); }
  }
  const scope = {
    Date: FrozenDate,
    $: () => ({}),
    printLog: orders,
    clients,
    payStatus: (o) => payments.statusOf(o),
    orderOwedBase: (o) => money.orderOwedBase(o, ctx, CURRENCIES),
    // The renderer's own localName, which reads through the shop's content
    // languages — the same path the module now takes.
    localName: (c) => (globalThis.KhaytContentLanguages.read(c, 'name', 'en', settings) || ''),
    escapeHtml: (x) => String(x),
    t: (k) => k,
    fmtPrice: (n) => String(n),
  };
  return new Function(...Object.keys(scope), ORIGINAL)(...Object.values(scope))();
}

function rng(seed) {
  let x = seed >>> 0 || 1;
  return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];
const day = (r) => {
  const y = 2025 + Math.floor(r() * 2), m = 1 + Math.floor(r() * 12), d = 1 + Math.floor(r() * 28);
  return `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
};

function someBook(r) {
  const orders = [];
  for (let i = 0; i < 1 + Math.floor(r() * 10); i++) {
    const o = { id: 'O' + i, date: day(r), project: 'P' + i, price: pick(r, [0, 400, 1200.5]),
                paidAmount: pick(r, [0, 100, 400]) };
    if (r() < 0.2) o.voidedAt = day(r);
    if (r() < 0.3) o.clientId = 'C1';
    if (r() < 0.2) o.client = 'Typed Name';
    if (r() < 0.25) {
      o.instalments = [
        { amount: pick(r, [0, 200, 500]), dueDate: pick(r, [day(r), null]), paid: r() < 0.4 },
        { amount: 300, dueDate: day(r), paid: r() < 0.4 },
      ];
    }
    if (r() < 0.2) o.creditNotes = [{ amount: 100 }];
    if (r() < 0.2) o.currency = pick(r, ['USD', 'SAR']);
    orders.push(o);
  }
  return orders;
}

test('the module and the original agree, bucket for bucket, over 2000 generated books', () => {
  const r = rng(90210);
  const settings = { currency: 'SAR', exchangeRates: { USD: 3.75 } };
  const clients = [{ id: 'C1', nameEn: 'Acme' }];
  // WHERE THE ORIGINAL IS NO LONGER THE RULE, ON PURPOSE: an instalment plan
  // whose unpaid rows add up to more than the order still owes (cash taken
  // outside the plan) is now capped at what is owed, oldest rows settled
  // first; and a plan on a foreign-currency order is converted to the shop's
  // currency like every other row. The original listed both at face value.
  // Those orders are pinned by test/money-review.test.js instead, and left out
  // of this comparison — everything else must still agree to the cent.
  const ctx = { settings, clients };
  const planDiverges = (o) => {
    if (!Array.isArray(o.instalments) || !o.instalments.length) return false;
    if (money.orderCurrency(o, ctx, CURRENCIES) !== settings.currency) return true;
    const listed = o.instalments.filter((x) => !x.paid).reduce((s, x) => s + Math.max(0, +x.amount || 0), 0);
    return listed > money.orderOwedRaw(o, ctx) + 0.005;
  };
  for (let i = 0; i < 2000; i++) {
    const orders = someBook(r).filter((o) => !planDiverges(o));
    const now = new Date(2026, 8, 6);
    const theirs = runOriginal(orders, settings, clients, now);
    const ours = R.aged(orders, { settings, clients, currencies: CURRENCIES, now, language: 'en' });

    // The original returns early with no buckets when nothing is outstanding.
    if (!theirs) {
      assert.equal(ours.rows.length, 0, `case ${i}: the module found rows where the original found none`);
      continue;
    }
    for (const label of R.BUCKETS) {
      // The original's labels use an en dash; the module's are ASCII, because
      // they cross a JSON bridge and end up in a Swift enum.
      const theirLabel = label.replace('-', '\u2013');
      const theirItems = theirs.buckets[theirLabel] || theirs.buckets[label] || [];
      const ourItems = ours.rows.filter((x) => x.bucket === label);
      assert.equal(ourItems.length, theirItems.length, `case ${i} ${label}: row count`);
      const key = (x) => `${x.id}|${Math.round(x.owed * 100)}|${x.days}`;
      assert.deepEqual(ourItems.map(key).sort(), theirItems.map(key).sort(), `case ${i} ${label}`);
    }
    assert.ok(Math.abs(ours.total - theirs.totalOwed) < 0.005, `case ${i}: total`);
  }
});

test('a voided invoice is not a receivable', () => {
  // Dunning a customer for a cancelled invoice is the worst thing this screen
  // could cause.
  const out = R.aged([{ id: 'A', date: '2026-01-01', price: 900, paidAmount: 0, voidedAt: '2026-02-01' }],
                     { settings: {}, now: new Date(2026, 8, 6) });
  assert.deepEqual(out.rows, []);
  assert.equal(out.total, 0);
});

test('an instalment plan is aged by each payment\'s own due date', () => {
  /* A plan agreed in January with a payment due in June is not six months
   * overdue in July; it is one month overdue. Ageing the plan by the order's
   * date would put every instalment of every plan in the oldest bucket and
   * make the screen useless for the shops that offer them. */
  const out = R.aged([{
    id: 'A', date: '2026-01-01', price: 1000, paidAmount: 0,
    instalments: [
      { amount: 400, dueDate: '2026-06-01', paid: true },
      { amount: 300, dueDate: '2026-08-20' },
      { amount: 300, dueDate: '2026-09-06' },
    ],
  }], { settings: {}, now: new Date(2026, 8, 6) });
  assert.equal(out.rows.length, 2, 'the paid one is not owed');
  assert.equal(out.total, 600);
  assert.deepEqual(out.rows.map((x) => x.days), [17, 0]);
  assert.deepEqual(out.rows.map((x) => x.bucket), ['0-30', '0-30']);
});

test('the buckets are the four a shop reads, and the rows come oldest first', () => {
  const now = new Date(2026, 8, 6);
  const orders = [
    { id: 'NEW', date: '2026-09-01', price: 100, paidAmount: 0 },
    { id: 'OLD', date: '2025-01-01', price: 200, paidAmount: 0 },
    { id: 'MID', date: '2026-07-01', price: 300, paidAmount: 0 },
  ];
  const out = R.aged(orders, { settings: {}, now });
  assert.deepEqual(out.rows.map((x) => x.id), ['OLD', 'MID', 'NEW'], 'what a shop chases is at the top');
  assert.deepEqual(out.buckets.map((b) => b.label), ['0-30', '31-60', '61-90', '90+']);
  assert.equal(out.buckets[3].count, 1);
  assert.equal(out.buckets[3].total, 200);
  assert.equal(out.total, 600);
});

test('the bucket edges are where they say they are', () => {
  assert.equal(R.bucketFor(0), '0-30');
  assert.equal(R.bucketFor(30), '0-30');
  assert.equal(R.bucketFor(31), '31-60');
  assert.equal(R.bucketFor(60), '31-60');
  assert.equal(R.bucketFor(61), '61-90');
  assert.equal(R.bucketFor(90), '61-90');
  assert.equal(R.bucketFor(91), '90+');
});

test('a date in the future is not negative days', () => {
  assert.equal(R.daysSince('2027-01-01', new Date(2026, 8, 6)), 0);
  assert.equal(R.daysSince('', new Date(2026, 8, 6)), 0);
  assert.equal(R.daysSince('nonsense', new Date(2026, 8, 6)), 0);
});

test('a customer\'s name comes through the shop\'s own content languages', () => {
  // `nameEn || nameAr` is blank for a shop that writes Turkish, and the name is
  // the only thing on this row a person can act on.
  const settings = { contentLangs: ['tr'] };
  const clients = [{ id: 'C1', name_tr: 'Acme Ltd.', nameEn: '' }];
  const out = R.aged([{ id: 'A', date: '2026-09-01', price: 100, paidAmount: 0, clientId: 'C1' }],
                     { settings, clients, now: new Date(2026, 8, 6), language: 'tr' });
  assert.equal(out.rows[0].client, 'Acme Ltd.');
});
