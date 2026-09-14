/**
 * lib/portal-refresh.js is what the customer's tracking link says, lifted.
 *
 * THE PROOF, as in `telegram-message.test.js` and `order-email.test.js`: the
 * original `buildPortalPayload` + `republishPortalIfPublished` are copied below
 * with their transport replaced by a recorder, and run beside the module over
 * thousands of generated jobs. What would have been PUT is compared — the kind,
 * the token, the customer address, and the payload field by field.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/currencies.js');
require('../lib/order-payment.js');
require('../lib/portal-trial.js');
require('../lib/cloud-plans.js');
const Portal = require('../lib/portal-refresh.js');
globalThis.KhaytPortalRefresh = Portal;
require('../lib/order-email.js');
const Status = require('../lib/order-status.js');

const CLOUD_PORTAL_STATUS_LABELS = {
  quote: 'Quote', pending: 'Pending', on_hold: 'On hold',
  printing: 'Printing', post: 'Post-processing', qc: 'Final checks',
  completed: 'Completed', delivered: 'Delivered',
};

/**
 * `buildPortalPayload` and the guards of `republishPortalIfPublished`, verbatim
 * from renderer/integrations.js, with the host's globals passed in and
 * `hubAPI.cloudPublish` replaced by `sent.push`.
 */
function original(order, settings, clients, shopField, payStatusFn, currencySymbol, t, trial, sent) {
  // republishPortalIfPublished
  if (!order || !order.cloudPublished) return;
  const c = settings.cloud || {};
  if (!(c.enabled && c.shopId) || !order.trackingToken) return;
  if (trial && !trial.available) return;

  // buildPortalPayload
  const isQuote = order.status === 'quote';
  const payload = {
    shopName: shopField('biz') || 'Khayt',
    ref: order.id,
    status: order.status,
    statusLabel: isQuote ? 'Quote' : (CLOUD_PORTAL_STATUS_LABELS[order.status] || order.status),
    eta: order.dueDate || '',
    issueDate: order.date || '',
    invoiceNo: order.invoiceNumber || order.invoiceNum || order.id,
    seller: {
      name: shopField('biz') || 'Khayt',
      vat: settings.vat || '',
      address: shopField('addr') || '',
    },
    paid: payStatusFn(order) === 'paid',
  };
  if (+order.price) {
    payload.amount = (+order.price).toFixed(2);
    payload.currency = currencySymbol();
  }
  if (isQuote && +order.cloudDeposit) {
    payload.depositAmount = (+order.cloudDeposit).toFixed(2);
    if (!payload.currency) payload.currency = currencySymbol();
  }
  if (isQuote && order.cloudPayUrl) payload.payUrl = order.cloudPayUrl;
  if (!isQuote && order.status !== 'completed' && order.status !== 'delivered') {
    const bal = (+order.price || 0) - (+order.paidAmount || 0);
    if (bal > 0.005) {
      payload.balanceDue = bal.toFixed(2);
      if (!payload.currency) payload.currency = currencySymbol();
      const payUrl = order.cloudPayUrl || (settings.cloud && settings.cloud.lastPayUrl) || '';
      if (/^https?:\/\//i.test(payUrl)) payload.payUrl = payUrl;
    }
  }
  if (order.status === 'on_hold' && order.holdReason) payload.note = String(order.holdReason);
  if (!isQuote) {
    payload.stages = [
      t('track.received') || 'Received',
      t('track.printing') || 'Printing',
      t('track.finishing') || 'Finishing',
      t('track.done') || 'Done',
      t('track.ready') || 'Ready for pickup',
    ];
    const STAGE_BY_STATUS = { pending: 0, queued: 0, accepted: 0, received: 0, ordered: 0, printing: 1, post: 2, qc: 2, completed: 3, delivered: 4 };
    payload.stage = order.status === 'on_hold' ? 1 : (STAGE_BY_STATUS[order.status] != null ? STAGE_BY_STATUS[order.status] : 0);
  }

  const custEmail = order.clientId ? (clients.find((x) => x.id === order.clientId)?.email || '') : '';
  sent.push({ kind: isQuote ? 'quote' : 'order', pubToken: order.trackingToken, payload, customerEmail: custEmail });
}

// ── Generated shops ────────────────────────────────────────────────────────

function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const STATUSES = ['quote', 'pending', 'printing', 'post', 'qc', 'completed', 'delivered', 'on_hold', 'ordered'];
const CURRENCIES = ['SAR', 'USD', 'EUR', 'ZZZ'];

function shopFor(rnd) {
  const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
  const price = rnd() < 0.9 ? Math.round(rnd() * 4000) : 0;
  return {
    settings: {
      currency: pick(CURRENCIES),
      vat: rnd() < 0.6 ? '300000000000003' : '',
      bizEn: rnd() < 0.9 ? 'Tuwaiq Prints' : '',
      addrEn: rnd() < 0.7 ? 'Riyadh' : '',
      cloud: {
        enabled: rnd() < 0.85,
        shopId: rnd() < 0.9 ? 'shop_1' : '',
        lastPayUrl: rnd() < 0.4 ? 'https://pay.example.test/abc' : '',
      },
    },
    clients: [{ id: 'C1', email: rnd() < 0.8 ? 'buyer@example.com' : '' }],
    order: {
      id: 'ORD-' + Math.floor(rnd() * 9999),
      status: pick(STATUSES),
      clientId: rnd() < 0.85 ? 'C1' : '',
      cloudPublished: rnd() < 0.8,
      trackingToken: rnd() < 0.9 ? 'trk_abc123' : '',
      price,
      paidAmount: rnd() < 0.5 ? Math.round(price * rnd()) : 0,
      dueDate: rnd() < 0.6 ? '2026-10-01' : '',
      date: rnd() < 0.8 ? '2026-09-01' : '',
      invoiceNumber: rnd() < 0.5 ? 'INV-7' : '',
      holdReason: rnd() < 0.5 ? 'waiting on filament' : '',
      cloudDeposit: rnd() < 0.3 ? 250 : 0,
      cloudPayUrl: rnd() < 0.3 ? 'https://pay.example.test/xyz' : '',
      paymentStatus: rnd() < 0.3 ? 'paid' : 'unpaid',
    },
  };
}

const TRACK = {
  'track.received': 'Received', 'track.printing': 'Printing',
  'track.finishing': 'Finishing', 'track.done': 'Done',
  'track.ready': 'Ready for pickup',
};

test('the module publishes exactly what the renderer would have published', () => {
  const rnd = mulberry32(20260914);
  let compared = 0, published = 0;
  for (let i = 0; i < 5000; i++) {
    const s = shopFor(rnd);
    const shopField = (k) => (k === 'biz' ? s.settings.bizEn : s.settings.addrEn);
    const payStatusFn = (o) => globalThis.KhaytOrderPayment.statusOf(o);
    const currencySymbol = () => {
      const table = globalThis.KhaytCurrencies.CURRENCIES;
      return (table[s.settings.currency] || table.SAR).symbol;
    };
    const t = (key) => TRACK[key] || '';

    const sent = [];
    original(s.order, s.settings, s.clients, shopField, payStatusFn, currencySymbol, t, null, sent);

    const req = Portal.requestFor(s.order, {
      settings: s.settings, clients: s.clients,
      shopName: shopField('biz') || 'Khayt',
      shopAddress: shopField('addr') || '',
      stages: ['Received', 'Printing', 'Finishing', 'Done', 'Ready for pickup'],
      now: Date.UTC(2026, 8, 14),
    });

    if (sent.length === 0) {
      assert.equal(req, null, `renderer published nothing; module built one (${s.order.status})`);
    } else {
      assert.ok(req, `renderer published one; module built nothing (${s.order.status})`);
      assert.equal(req.kind, sent[0].kind);
      assert.equal(req.pubToken, sent[0].pubToken);
      assert.equal(req.customerEmail, sent[0].customerEmail);
      assert.deepEqual(req.payload, sent[0].payload);
      published++;
    }
    compared++;
  }
  assert.equal(compared, 5000);
  assert.ok(published > 1500, `only ${published} of 5000 jobs published`);
});

test('an unpublished job, a missing token or a shop without cloud sends nothing', () => {
  const base = {
    id: 'O1', status: 'printing', cloudPublished: true, trackingToken: 'trk', price: 10,
  };
  const settings = { cloud: { enabled: true, shopId: 's1' } };
  const ctx = { settings, clients: [], shopName: 'S', now: Date.now() };
  assert.ok(Portal.requestFor(base, ctx), 'the ordinary case publishes');

  assert.equal(Portal.requestFor({ ...base, cloudPublished: false }, ctx), null);
  assert.equal(Portal.requestFor({ ...base, trackingToken: '' }, ctx), null);
  assert.equal(Portal.requestFor(base, { ...ctx, settings: { cloud: { enabled: false, shopId: 's1' } } }), null);
  assert.equal(Portal.requestFor(base, { ...ctx, settings: { cloud: { enabled: true, shopId: '' } } }), null);
});

test('the path is the one lib/cloud-client.js PUTs to', () => {
  assert.equal(Portal.pathFor('shop_1', 'trk_abc'), '/v1/shops/shop_1/published/trk_abc');
  // A token with a slash in it must not climb out of its own path segment.
  assert.equal(Portal.pathFor('a/b', 'c d'), '/v1/shops/a%2Fb/published/c%20d');
  // `seg`'s null handling, not the string "undefined".
  assert.equal(Portal.pathFor(null, undefined), '/v1/shops//published/');
});

test('outboundFor announces the portal exactly when a request would be built', () => {
  const rnd = mulberry32(4242);
  const now = Date.UTC(2026, 8, 14);
  for (let i = 0; i < 2000; i++) {
    const s = shopFor(rnd);
    const reaches = Status.outboundFor(s.order, s.order.status, {
      settings: s.settings, clients: s.clients, now,
    });
    const announced = reaches.some(r => r.channel === 'portal');
    const req = Portal.requestFor(s.order, {
      settings: s.settings, clients: s.clients, shopName: 'X', now,
    });
    assert.equal(announced, !!req,
      `outboundFor and requestFor disagree for ${s.order.status}`);
  }
});

/**
 * The trial gate was the one thing `outboundFor` never checked, so a shop whose
 * portal trial had lapsed was told a move would reach the customer's link when
 * the renderer would have sent nothing — and on the Mac that is a move refused
 * for a message nobody was going to receive.
 *
 * BETA_FREE makes every trial `available` today, so this pins the gate with the
 * flag forced off rather than pretending the live answer exercises it.
 */
test('a lapsed trial stops the refresh, and outboundFor agrees', () => {
  const order = { id: 'O1', status: 'printing', cloudPublished: true, trackingToken: 'trk', price: 10 };
  const settings = {
    cloud: {
      enabled: true, shopId: 's1', planActive: false,
      portalTrialStartedAt: '2026-01-01T00:00:00Z',
    },
  };
  const now = Date.UTC(2026, 8, 14);   // months past any trial window

  const realIsBetaFree = globalThis.KhaytCloudPlans.isBetaFree;
  globalThis.KhaytCloudPlans.isBetaFree = () => false;
  try {
    const trial = globalThis.KhaytPortalTrial.portalTrialState({
      betaFree: false, subscribed: false,
      startedAt: settings.cloud.portalTrialStartedAt, now,
    });
    assert.equal(trial.available, false, 'the fixture must actually be lapsed');

    assert.equal(Portal.requestFor(order, { settings, clients: [], shopName: 'S', now }), null);
    const reaches = Status.outboundFor(order, 'printing', { settings, clients: [], now });
    assert.equal(reaches.some(r => r.channel === 'portal'), false,
      'a lapsed trial reaches nobody, and must not be announced as reaching anybody');
  } finally {
    globalThis.KhaytCloudPlans.isBetaFree = realIsBetaFree;
  }
});

test('without a clock the answer is the one outboundFor gave before', () => {
  // A host that cannot supply `now` must not under-report: under-reporting
  // makes a move and drops the message, which is the failure that matters.
  const order = { id: 'O1', status: 'printing', cloudPublished: true, trackingToken: 'trk' };
  const settings = {
    cloud: {
      enabled: true, shopId: 's1', planActive: false,
      portalTrialStartedAt: '2026-01-01T00:00:00Z',
    },
  };
  const realIsBetaFree = globalThis.KhaytCloudPlans.isBetaFree;
  globalThis.KhaytCloudPlans.isBetaFree = () => false;
  try {
    assert.equal(Portal.wouldRefresh(order, { settings }), true);
  } finally {
    globalThis.KhaytCloudPlans.isBetaFree = realIsBetaFree;
  }
});
