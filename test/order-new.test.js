'use strict';
/**
 * What a new job IS.
 *
 * Forty-five fields, an id allocated from a counter the shop owns, an invoice
 * number, a due date estimated from the queue, and a deposit that decides the
 * payment status. All of it was written inline in `logPrint`, reading twenty
 * form controls — which is why only the Electron window could create a job.
 *
 * A wrong field here does not crash. It produces a record that looks like every
 * other record and is quietly missing the one thing some later screen reads —
 * so the first test builds the SAME order both ways, the original expression
 * copied out of order-flows.js beside the module, and compares all forty-five.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/pricing.js');
require('../lib/working-week.js');
const N = require('../lib/order-new.js');

const NOW = new Date('2026-09-04T09:15:00.000Z');
const TOKENS = {
  tracking: new Uint8Array(16).fill(0xab),
  quoteApproval: new Uint8Array(16).fill(0xcd),
};

/* ── The original, copied from renderer/order-flows.js before the move ────────
   The form reads become plain inputs and the clock is frozen; nothing else is
   changed. `nextInvoiceNumber` and `nextQuoteSeq` are inlined from
   renderer/invoicing.js, minus their saveAll(). */
function originalRecord(form, g) {
  const { settings, printLog } = g;
  const currentBuild = form.parts;
  const currentExtraLines = form.extraLines || [];
  const now = NOW;
  const asQuote = !!form.asQuote;

  const totalBaseCost = currentBuild.reduce((s, p) => s + p.baseCost, 0);
  const totalPrintTime = currentBuild.reduce((s, p) => s + p.printTime, 0);
  const margin = Math.max(0, form.margin || 0);
  const discountPct = Math.min(100, Math.max(0, form.discountPct || 0));
  const shippingCost = Math.max(0, form.shippingCost || 0);
  const logRushEnabled = !!form.rushEnabled;
  const logRushPct = logRushEnabled ? (settings.rushFeePct ?? 25) : 0;
  const _lq = KhaytPricing.quoteTotal({
    baseCost: totalBaseCost, qty: 1, margin, priceTier: null, discountPct,
    rushEnabled: logRushEnabled, rushPct: logRushPct, shippingCost,
    extraLines: currentExtraLines, business: true,
  });
  const priceBeforeDiscount = _lq.priceBeforeDiscount;
  const logRushFeeAmt = _lq.rushFee;
  const finalPrice = _lq.total;

  const project = form.project || '';
  const clientRef = form.clientRef || null;
  const materials = [...new Set(currentBuild.map(p => p.material))].join(', ');

  const localDateStr = (d) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

  const nextInvoiceNumber = () => {
    const currentYear = now.getFullYear();
    if ((settings.invNumYear || currentYear) !== currentYear) {
      settings.invNumYear = currentYear;
      settings.invNumNext = 1;
    }
    const prefix = settings.invNumPrefix || 'INV';
    const seq4 = String(settings.invNumNext || 1).padStart(4, '0');
    const fmt = settings.invNumFormat || '{prefix}-{year}-{seq4}';
    const result = fmt.replace('{prefix}', prefix).replace('{year}', currentYear).replace('{seq4}', seq4);
    settings.invNumNext = (settings.invNumNext || 1) + 1;
    settings.invNumYear = currentYear;
    return result;
  };
  const nextQuoteSeq = () => {
    const currentYear = now.getFullYear();
    if ((settings.quoteNumYear || currentYear) !== currentYear) {
      settings.quoteNumYear = currentYear;
      settings.quoteNumNext = 1;
    }
    const seq4 = String(settings.quoteNumNext || 1).padStart(4, '0');
    settings.quoteNumNext = (settings.quoteNumNext || 1) + 1;
    settings.quoteNumYear = currentYear;
    return seq4;
  };
  const avgDailyWorkingHours = () => {
    const wh = KhaytWorkingWeek.workingHours(settings);
    const totalWeeklyHours = Object.values(wh).reduce((s, h) => s + (h > 0 ? h : 0), 0);
    return totalWeeklyHours > 0 ? totalWeeklyHours / 7 : 8;
  };

  const prefix = asQuote ? (settings.quotePrefix || 'QUO') : (settings.invPrefix || 'INV');
  const invoiceNum = asQuote ? null : nextInvoiceNumber();
  const seq = asQuote ? nextQuoteSeq() : String(settings.invNumNext - 1).padStart(4, '0');
  const id = `${prefix}-${now.getFullYear()}-${seq}`;

  return {
    id,
    invoiceNum,
    invoiceNumber: invoiceNum,
    date: localDateStr(now),
    timestamp: now.toISOString(),
    project,
    clientId: form.clientId || null,
    productId: form.productId || null,
    currency: form.currency || undefined,
    material: materials,
    printTime: +totalPrintTime.toFixed(1),
    price: +finalPrice.toFixed(2),
    discountPct: discountPct || 0,
    priceBeforeDiscount: discountPct > 0 ? +priceBeforeDiscount.toFixed(2) : null,
    shippingCost: shippingCost > 0 ? +shippingCost.toFixed(2) : 0,
    deliveredAt: null,
    carrier: null,
    trackingNumber: null,
    labelUrl: null,
    shippedAt: null,
    shippingStatus: null,
    shippingHistory: [],
    shippingService: null,
    shipmentMeta: null,
    attachedFiles: [],
    extraLines: currentExtraLines.length > 0
      ? KhaytPricing.resolveExtraLines(currentExtraLines, _lq.extrasBase)
        .map((r, i) => ({ ...currentExtraLines[i], label: r.label, amount: r.amount }))
      : undefined,
    status: asQuote ? 'quote' : 'pending',
    statusHistory: [{ status: asQuote ? 'quote' : 'pending', at: now.toISOString() }],
    queuePos: printLog.filter(o => o.status === 'pending').length + 1,
    machineId: form.machineId || null,
    materialDeducted: false,
    depositAmount: Math.max(0, form.depositAmount || 0),
    paymentStatus: (() => {
      const dep = Math.max(0, form.depositAmount || 0);
      if (dep <= 0) return 'unpaid';
      return dep >= finalPrice ? 'paid' : 'partial';
    })(),
    paidAmount: Math.max(0, form.depositAmount || 0),
    paymentMethod: null,
    paidAt: null,
    notes: '',
    internalNotes: '',
    invoiceNotes: '',
    clientRef,
    tags: [],
    dueDate: (() => {
      if (!asQuote) {
        const queueHrs = printLog
          .filter(o => o.status !== 'completed' && o.status !== 'quote' && o.status !== 'on_hold')
          .reduce((s, o) => s + (+o.printTime || 0), 0);
        const totalHrs = queueHrs + totalPrintTime;
        const dailyHrs = avgDailyWorkingHours();
        if (dailyHrs > 0 && totalHrs > 0) {
          const daysNeeded = Math.ceil(totalHrs / dailyHrs);
          const d = new Date(now);
          d.setDate(d.getDate() + daysNeeded);
          return localDateStr(d);
        }
      }
      return null;
    })(),
    priority: false,
    printPhotos: [],
    parts: currentBuild.map(p => ({ ...p, partStatus: p.partStatus || 'pending' })),
    components: Array.isArray(form.components)
      ? form.components.filter(c => c && c.consumableId).map(c => ({ ...c }))
      : [],
    assemblyQty: (form.assemblyQty > 0) ? form.assemblyQty : 1,
    actualPrintTime: null,
    actualWeight: null,
    quoteSentAt: asQuote ? localDateStr(now) : null,
    rushFee: logRushFeeAmt > 0 ? +logRushFeeAmt.toFixed(2) : undefined,
    rushFeeAmount: logRushFeeAmt > 0 ? +logRushFeeAmt.toFixed(2) : 0,
    quoteExpiresAt: asQuote
      ? localDateStr(new Date(now.getTime() + (settings.quoteValidityDays || 7) * 86400000))
      : null,
    quoteApprovalToken: asQuote
      ? Array.from(TOKENS.quoteApproval, (x) => x.toString(16).padStart(2, '0')).join('')
      : undefined,
    quoteAcceptedAt: null,
    quoteVersion: asQuote ? 1 : undefined,
    quoteRevisions: asQuote ? [] : undefined,
    trackingToken: Array.from(TOKENS.tracking, (b) => b.toString(16).padStart(2, '0')).join(''),
  };
}

/* ── Generated carts and shops ─────────────────────────────────────────────── */
function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeForm(rnd) {
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const maybe = (p) => rnd() < p;
  const parts = Array.from({ length: 1 + Math.floor(rnd() * 3) }, (_, k) => ({
    name: `part ${k}`,
    material: pick(['PLA', 'PETG', 'Resin', '']),
    baseCost: Math.round(rnd() * 30000) / 100,
    printTime: Math.round(rnd() * 2000) / 100,
    qty: 1 + Math.floor(rnd() * 4),
    printWeight: Math.round(rnd() * 500),
    partStatus: maybe(0.2) ? 'printed' : undefined,
  }));
  return {
    parts,
    project: maybe(0.8) ? 'Bracket set' : '',
    clientId: maybe(0.6) ? 'C1' : null,
    clientRef: maybe(0.3) ? 'PO-88' : null,
    productId: maybe(0.2) ? 'P1' : null,
    machineId: maybe(0.5) ? 'M1' : null,
    currency: maybe(0.3) ? 'USD' : undefined,
    margin: Math.round(rnd() * 80),
    discountPct: maybe(0.4) ? Math.round(rnd() * 100) : 0,
    shippingCost: maybe(0.4) ? Math.round(rnd() * 200) : 0,
    depositAmount: maybe(0.5) ? Math.round(rnd() * 2000) : 0,
    rushEnabled: maybe(0.3),
    extraLines: maybe(0.4)
      ? [{ label: 'Design', amount: Math.round(rnd() * 300) },
         { label: 'Card fee', pct: Math.round(rnd() * 10) }]
      : [],
    components: maybe(0.25)
      ? [{ consumableId: 'c1', qtyPerUnit: 2 }, { qtyPerUnit: 4 }]
      : [],
    assemblyQty: maybe(0.3) ? 1 + Math.floor(rnd() * 5) : 0,
    asQuote: maybe(0.35),
  };
}

function makeShop(rnd) {
  const maybe = (p) => rnd() < p;
  return {
    settings: {
      invPrefix: maybe(0.2) ? 'ORD' : undefined,
      quotePrefix: maybe(0.2) ? 'Q' : undefined,
      invNumPrefix: maybe(0.2) ? 'BILL' : undefined,
      invNumFormat: maybe(0.15) ? '{prefix}/{year}/{seq4}' : undefined,
      invNumNext: 1 + Math.floor(rnd() * 40),
      invNumYear: maybe(0.2) ? 2025 : 2026,
      quoteNumNext: 1 + Math.floor(rnd() * 40),
      quoteNumYear: maybe(0.2) ? 2025 : 2026,
      rushFeePct: maybe(0.3) ? Math.round(rnd() * 50) : undefined,
      quoteValidityDays: maybe(0.3) ? 1 + Math.floor(rnd() * 30) : undefined,
      workingHours: maybe(0.5)
        ? { mon: 8, tue: 8, wed: 8, thu: 8, fri: 0, sat: 4, sun: 0 }
        : undefined,
    },
    printLog: Array.from({ length: Math.floor(rnd() * 8) }, (_, k) => ({
      id: `o${k}`,
      status: ['pending', 'printing', 'completed', 'quote', 'on_hold'][Math.floor(rnd() * 5)],
      printTime: Math.round(rnd() * 1000) / 100,
    })),
  };
}

test('the lifted record and the original agree, all forty-five fields', () => {
  const rnd = mulberry32(20260904);
  for (let i = 0; i < 2000; i++) {
    const form = makeForm(rnd);
    const shop = makeShop(rnd);

    const a = JSON.parse(JSON.stringify(shop));
    const recordA = originalRecord(form, a);

    const b = JSON.parse(JSON.stringify(shop));
    const recordB = N.newOrder(form, {
      settings: b.settings, orders: b.printLog, now: NOW, tokens: TOKENS,
    });

    assert.deepEqual(recordB, recordA, `the record diverged: ${JSON.stringify({ form, shop })}`);
    // And the counters it advanced, which are the shop's and which a caller
    // must save with the order.
    assert.deepEqual(b.settings, a.settings, 'the settings counters diverged');
  }
});

/* ── The rules that are easy to break and hard to notice ───────────────────── */

const CART = [{ name: 'a', material: 'PLA', baseCost: 100, printTime: 4, qty: 1 }];
const base = (over) => Object.assign({ parts: CART, project: 'Job', margin: 0 }, over || {});
const ctx = (settings, orders) => ({
  settings: settings || {}, orders: orders || [], now: NOW, tokens: TOKENS,
});

test('a quote does not consume an invoice number', () => {
  // The tax authority asks about invoice numbers. A quote is not an invoice, and
  // a gap in the sequence is a question nobody can answer.
  const settings = { invNumNext: 5, quoteNumNext: 2 };
  const quote = N.newOrder(base({ asQuote: true }), ctx(settings));
  assert.equal(quote.invoiceNumber, null);
  assert.equal(settings.invNumNext, 5, 'untouched');
  assert.equal(settings.quoteNumNext, 3, 'its own counter moved');
  assert.equal(quote.id, 'QUO-2026-0002');
});

test('an order takes the next invoice number and advances it', () => {
  const settings = { invNumNext: 5 };
  const order = N.newOrder(base(), ctx(settings));
  assert.equal(order.invoiceNumber, 'INV-2026-0005');
  assert.equal(order.id, 'INV-2026-0005');
  assert.equal(settings.invNumNext, 6, 'or the next job takes the same number');
});

test('the counter resets in January, which is what {year}-0001 promises', () => {
  const settings = { invNumNext: 340, invNumYear: 2025 };
  const order = N.newOrder(base(), ctx(settings));
  assert.equal(order.invoiceNumber, 'INV-2026-0001');
  assert.equal(settings.invNumYear, 2026);
  assert.equal(settings.invNumNext, 2);
});

test('two jobs in a row never share an id', () => {
  const settings = { invNumNext: 1, quoteNumNext: 1 };
  const seen = new Set();
  for (let i = 0; i < 50; i++) {
    seen.add(N.newOrder(base({ asQuote: i % 2 === 0 }), ctx(settings)).id);
  }
  assert.equal(seen.size, 50, 'the id is the primary key — a collision overwrites a job');
});

test('a due date is estimated from the work already queued', () => {
  // Eight hours a day, seven days a week: 56 a week.
  const settings = { workingHours: { mon: 8, tue: 8, wed: 8, thu: 8, fri: 8, sat: 8, sun: 8 } };
  const queue = [{ status: 'printing', printTime: 20 }, { status: 'pending', printTime: 20 }];
  const order = N.newOrder(base(), ctx(settings, queue));
  // 40 queued + 4 this job = 44 hours ÷ 8 a day = 6 days.
  assert.equal(order.dueDate, '2026-09-10');
});

test('a held job is not consuming machine time', () => {
  const settings = { workingHours: { mon: 8, tue: 8, wed: 8, thu: 8, fri: 8, sat: 8, sun: 8 } };
  const held = [{ status: 'on_hold', printTime: 400 }];
  const order = N.newOrder(base(), ctx(settings, held));
  assert.equal(order.dueDate, '2026-09-05',
    'counting it would push every new due date out by work nobody is doing');
});

test('a quote gets no due date, because nothing is queued until it is accepted', () => {
  const settings = { workingHours: { mon: 8, tue: 8, wed: 8, thu: 8, fri: 8, sat: 8, sun: 8 } };
  assert.equal(N.newOrder(base({ asQuote: true }), ctx(settings)).dueDate, null);
});

test('a deposit decides the payment status, and it is derived not taken', () => {
  const priced = N.newOrder(base({ margin: 0 }), ctx());   // 100
  assert.equal(priced.price, 100);

  assert.equal(N.newOrder(base(), ctx()).paymentStatus, 'unpaid');
  assert.equal(N.newOrder(base({ depositAmount: 40 }), ctx()).paymentStatus, 'partial');
  assert.equal(N.newOrder(base({ depositAmount: 100 }), ctx()).paymentStatus, 'paid');
  assert.equal(N.newOrder(base({ depositAmount: 500 }), ctx()).paymentStatus, 'paid');

  const deposited = N.newOrder(base({ depositAmount: 40 }), ctx());
  assert.equal(deposited.paidAmount, 40, 'the deposit is money received, not just a promise');
  assert.equal(deposited.depositAmount, 40);
});

test('a new job is at the back of the pending queue', () => {
  const queue = [{ status: 'pending' }, { status: 'pending' }, { status: 'printing' }];
  assert.equal(N.newOrder(base(), ctx({}, queue)).queuePos, 3);
});

test('a percentage line is frozen at the money it resolved to', () => {
  // An invoice reports what was charged. Recomputing a percentage months later
  // against a base that has since changed is a different number on a document
  // the customer already has.
  const order = N.newOrder(base({ margin: 0, extraLines: [{ label: 'Card fee', pct: 10 }] }), ctx());
  assert.equal(order.extraLines.length, 1);
  assert.equal(order.extraLines[0].pct, 10, 'the row still reads as 10%');
  assert.ok(order.extraLines[0].amount > 0, 'and carries the money it came to');
});

test('a job with no extra lines carries none rather than an empty list', () => {
  assert.equal(N.newOrder(base(), ctx()).extraLines, undefined);
});

test('a component with no consumable is not a component', () => {
  const order = N.newOrder(base({ components: [{ consumableId: 'c1' }, { qtyPerUnit: 3 }] }), ctx());
  assert.equal(order.components.length, 1);
});

test('every part starts pending unless it says otherwise', () => {
  const order = N.newOrder(base({
    parts: [{ name: 'a', baseCost: 1, printTime: 1 }, { name: 'b', baseCost: 1, printTime: 1, partStatus: 'printed' }],
  }), ctx());
  assert.deepEqual(order.parts.map(p => p.partStatus), ['pending', 'printed']);
});

test('the tokens come from the caller, and a quote gets both', () => {
  const order = N.newOrder(base(), ctx());
  assert.equal(order.trackingToken.length, 32, '16 bytes in hex');
  assert.equal(order.quoteApprovalToken, undefined, 'an order has nothing to approve');

  const quote = N.newOrder(base({ asQuote: true }), ctx());
  assert.equal(quote.quoteApprovalToken.length, 32);
  assert.equal(quote.quoteVersion, 1);
  assert.deepEqual(quote.quoteRevisions, []);
});

test('a quote expires, by default in a week', () => {
  assert.equal(N.newOrder(base({ asQuote: true }), ctx()).quoteExpiresAt, '2026-09-11');
  assert.equal(N.newOrder(base({ asQuote: true }), ctx({ quoteValidityDays: 30 })).quoteExpiresAt,
    '2026-10-04');
});

test('the materials are the distinct ones, named once', () => {
  const order = N.newOrder(base({
    parts: [{ material: 'PLA', baseCost: 1, printTime: 1 },
            { material: 'PLA', baseCost: 1, printTime: 1 },
            { material: 'PETG', baseCost: 1, printTime: 1 }],
  }), ctx());
  assert.equal(order.material, 'PLA, PETG');
});

/* ── Agreed parts, rounding and a typed price on the record (2026-09-16) ──── */

test('an agreed part is charged its agreed price, not cost plus margin — and its cost stays its cost', () => {
  const settings = { invNumNext: 1, invNumYear: NOW.getFullYear() };
  const order = N.newOrder({
    parts: [
      { name: 'Wall bracket', qty: 4, unitCost: 3, baseCost: 12, agreedPrice: 50, printTime: 1 },
      { name: 'Lid', qty: 1, unitCost: 2, baseCost: 2, printTime: 1 },
    ],
    margin: 30, discountPct: 10,
  }, { settings, orders: [], now: NOW, tokens: TOKENS });
  // Lid: 2 × 1.3 = 2.6, less 10% = 2.34. Bracket: 4 × 50 = 200, not discounted.
  assert.equal(order.price, 202.34);
  assert.equal(order.parts.reduce((t, p) => t + p.baseCost, 0), 14, 'the true cost of every part, agreed or not');
  assert.equal(order.agreedAmount, 200);
  assert.equal(order.parts[0].unitCost, 3, 'the part still knows what it cost');
  assert.equal(order.parts[0].agreedPrice, 50);
  assert.equal(order.computedPrice, undefined, 'nothing rounded, nothing typed: no provenance fields');
  assert.equal(order.priceSource, undefined);
});

test('a rounded or typed total says so on the record; a plain one carries nothing new', () => {
  const settings = { invNumNext: 1, invNumYear: NOW.getFullYear() };
  const base = { parts: [{ name: 'x', qty: 1, unitCost: 100, baseCost: 100, printTime: 1 }], margin: 30 };
  const plain = N.newOrder(base, { settings, orders: [], now: NOW, tokens: TOKENS });
  for (const key of ['agreedAmount', 'computedPrice', 'priceSource', 'priceRound', 'priceOverride']) {
    assert.equal(key in plain, false, `${key} on a record nothing touched`);
  }
  const rounded = N.newOrder({ ...base, priceRound: { step: 5, mode: 'up' } }, { settings, orders: [], now: NOW, tokens: TOKENS });
  assert.equal(rounded.price, 130, 'already a multiple of 5');
  assert.equal(rounded.priceSource, 'rounded');
  assert.equal(rounded.computedPrice, 130);
  assert.deepEqual(rounded.priceRound, { step: 5, mode: 'up' });
  const rounded2 = N.newOrder({ ...base, margin: 31, priceRound: { step: 5, mode: 'up' } }, { settings, orders: [], now: NOW, tokens: TOKENS });
  assert.equal(rounded2.price, 135);
  assert.equal(rounded2.computedPrice, 131);
  const typed = N.newOrder({ ...base, priceOverride: 120 }, { settings, orders: [], now: NOW, tokens: TOKENS });
  assert.equal(typed.price, 120);
  assert.equal(typed.priceSource, 'override');
  assert.equal(typed.priceOverride, 120);
  assert.equal(typed.computedPrice, 130);
  assert.equal(typed.paymentStatus, 'unpaid');
  // The deposit is judged against the price the customer is asked for.
  const paid = N.newOrder({ ...base, priceOverride: 120, depositAmount: 120 }, { settings, orders: [], now: NOW, tokens: TOKENS });
  assert.equal(paid.paymentStatus, 'paid');
});

test('a legacy `delivered` row is not queued work', () => {
  // It pushed every new due date out by work handed over months ago.
  const settings = { workingHours: { mon: 8, tue: 8, wed: 8, thu: 8, fri: 8, sat: 8, sun: 8 } };
  const queue = [{ status: 'delivered', printTime: 400 }, { status: 'printing', printTime: 20 }];
  const order = N.newOrder(base(), ctx(settings, queue));
  // 20 queued + 4 this job = 24 hours ÷ 8 a day = 3 days.
  assert.equal(order.dueDate, '2026-09-07');
});
