/**
 * The integration rules the Mac app now shares with the desktop: the SMS
 * request (no Node in it), the accounting push, the KPI email digest, the
 * webhook subscriptions editor, and the settings save that carries them.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const R = require('../lib/sms-request.js');
const Sms = require('../lib/sms.js');
const Push = require('../lib/accounting-push.js');
require('../lib/order-status.js');
require('../lib/order-money.js');
require('../lib/order-payment.js');
require('../lib/currencies.js');
const Digest = require('../lib/email-digest.js');
const Bus = require('../lib/webhook-bus.js');
const Edit = require('../lib/settings-edit.js');
const D = require('../lib/secret-destination.js');

// ── SMS ─────────────────────────────────────────────────────────────────────

test('the form encoding is URLSearchParams\', byte for byte', () => {
  const samples = ['Hi', 'a b+c&d=e', 'طلبك جاهز ✓', "!'()*~-._", '100% done\nnext line', '', 'é/ü?#'];
  for (const v of samples) {
    assert.equal(R.formEncode({ Body: v, To: '+966500000000' }),
      new URLSearchParams({ Body: v, To: '+966500000000' }).toString(), v);
  }
});

test('the Basic header is Buffer\'s base64, including non-ASCII', () => {
  for (const v of ['AC1:tok', 'a', 'ab', 'abc', 'حساب:رمز', '']) {
    assert.equal(R.base64(v), Buffer.from(v).toString('base64'), v);
  }
});

test('lib/sms.js re-exports the shared builder unchanged', () => {
  assert.equal(Sms.buildSmsRequest, R.buildSmsRequest);
  assert.equal(Sms.normalizePhone, R.normalizePhone);
  const r = R.buildSmsRequest('twilio', { accountSid: 'AC1', authToken: 'tok', from: '+1555' },
    { to: '+966 50 000 0000', message: 'طلبك جاهز', channel: 'sms' });
  assert.equal(r.headers.Authorization, 'Basic ' + Buffer.from('AC1:tok').toString('base64'));
  assert.equal(new URLSearchParams(r.body).get('Body'), 'طلبك جاهز');
});

test('a text account: which providers can send free text, and what is missing', () => {
  const acc = (c) => R.textAccount({ smsConfig: c });
  assert.equal(acc({ provider: 'none' }).reason, 'not_set_up');
  assert.equal(acc({ provider: 'whatsapp_cloud', token: 'x' }).reason, 'not_set_up');
  assert.equal(acc({ provider: 'twilio', accountSid: 'AC' }).reason, 'no_auth_token');
  assert.equal(acc({ provider: 'twilio', authToken: 'x' }).reason, 'no_account_sid');
  assert.equal(acc({ provider: 'unifonic' }).reason, 'no_app_sid');
  assert.equal(acc({ provider: 'webhook', url: 'ftp://x' }).reason, 'no_url');
  const ok = acc({ provider: 'twilio', accountSid: 'AC', authToken: '__enc__x', channel: 'sms' });
  assert.equal(ok.ok, true);
  assert.equal(ok.channel, 'sms');
  assert.equal(acc({ provider: 'unifonic', appSid: 'A' }).channel, 'whatsapp', 'the desktop default');
});

test('a provider\'s answer: 2xx is sent, anything else says what came back, cut short', () => {
  assert.deepEqual(R.readSmsResponse(201, ''), { ok: true, status: 201 });
  const bad = R.readSmsResponse(401, 'x'.repeat(500));
  assert.equal(bad.ok, false);
  assert.equal(bad.error.length, 'HTTP 401 — '.length + 200);
});

test('a text writes an sms line to the log, and is found by its job and milestone', () => {
  const e = R.commEntry({ id: 'CMM1', at: '2026-11-05T10:00:00Z', text: 'Ready', orderId: 'J1',
    milestone: 'ready', provider: 'twilio' });
  assert.deepEqual(e, { id: 'CMM1', type: 'sms', note: 'Ready', at: '2026-11-05T10:00:00Z',
    orderId: 'J1', milestone: 'ready', via: 'twilio' });
  assert.equal(R.sentAt([e, { type: 'whatsapp', orderId: 'J1', milestone: 'ready', at: '2027' }], 'J1', 'ready'),
    '2026-11-05T10:00:00Z');
  assert.equal(R.sentAt([e], 'J1', 'shipped'), null);
});

// ── ACCOUNTING PUSH ─────────────────────────────────────────────────────────

const acctOn = { accountingSync: { enabled: true, webhookUrl: 'https://hooks.example/acct', format: 'xero',
  salesAccount: '200', taxCode: 'OUTPUT15' } };

test('a push is owed only when paid, switched on, not pushed, and there is somewhere to send it', () => {
  const paid = { id: 'J1', paymentStatus: 'paid', price: 115 };
  assert.deepEqual(Push.wouldPush(paid, acctOn), { push: true, reason: '' });
  assert.equal(Push.wouldPush(paid, {}).reason, 'off');
  assert.equal(Push.wouldPush(paid, { accountingSync: { ...acctOn.accountingSync, pushOnPaid: false } }).reason, 'not_on_paid');
  assert.equal(Push.wouldPush({ ...paid, paymentStatus: 'partial' }, acctOn).reason, 'not_paid');
  assert.equal(Push.wouldPush({ ...paid, accountingPushedAt: 'x' }, acctOn).reason, 'already_pushed');
  assert.equal(Push.wouldPush(paid, { accountingSync: { enabled: true, webhookUrl: 'ftp://x' } }).reason, 'no_url');
});

test('the retry sweep takes only failed pushes — switching sync on does not push the history', () => {
  const orders = [
    { id: 'A', paymentStatus: 'paid' },
    { id: 'B', paymentStatus: 'paid', accountingPushFailedAt: '2026-11-01' },
    { id: 'C', paymentStatus: 'paid', accountingPushFailedAt: '2026-11-01', accountingPushedAt: '2026-11-02' },
    { id: 'D', paymentStatus: 'unpaid', accountingPushFailedAt: '2026-11-01' },
  ];
  assert.deepEqual(Push.retryable(orders, acctOn).map((o) => o.id), ['B']);
  assert.deepEqual(Push.retryable(orders, {}), []);
});

test('the payload is the shared invoice payload, dated the day it was paid, with the mapping', () => {
  const row = { id: 'INV-1', date: '2026-10-01', clientName: 'Layla', price: 115, currency: 'SAR',
    vatRate: 15, taxMode: 'inclusive', baseCurrency: 'SAR', baseAmount: 115 };
  const p = Push.payloadFor(row, { paidAt: '2026-11-03' }, acctOn);
  assert.equal(p.idempotencyKey, 'inv:INV-1');
  assert.equal(p.date, '2026-11-03');
  assert.equal(p.format, 'xero');
  assert.equal(p.salesAccount, '200');
  assert.equal(p.taxCode, 'OUTPUT15');
  assert.equal(p.total, 115);
  assert.equal(p.vat, 15);
});

test('the request carries the secret and the idempotency key; the outcome clears an old failure', () => {
  const r = Push.request({ idempotencyKey: 'inv:1' }, 's3');
  assert.equal(r.headers['X-Khayt-Secret'], 's3');
  assert.equal(r.headers['Idempotency-Key'], 'inv:1');
  assert.equal(Push.request({}, '').headers['X-Khayt-Secret'], undefined);
  assert.deepEqual(Push.outcome(true, 'T'), { set: { accountingPushedAt: 'T' },
    clear: ['accountingPushFailedAt', 'accountingPushError'] });
  assert.equal(Push.outcome(false, 'T', 'HTTP 500').set.accountingPushError, 'HTTP 500');
  assert.equal(Push.testPayload(acctOn, 5).idempotencyKey, 'test:5');
});

// ── KPI EMAIL DIGEST ────────────────────────────────────────────────────────

const at = (y, m, d, h) => new Date(y, m - 1, d, h, 5, 0);

test('due: on, a recipient, the hour, the day, and not already sent this period', () => {
  const s = (d) => ({ email: 'shop@example.com', emailDigest: { enabled: true, hour: 8, ...d } });
  assert.equal(Digest.due({ emailDigest: {} }, at(2026, 11, 5, 8)).reason, 'off');
  assert.equal(Digest.due({ emailDigest: { enabled: true } }, at(2026, 11, 5, 8)).reason, 'no_recipient');
  assert.equal(Digest.due(s({}), at(2026, 11, 5, 9)).reason, 'not_this_hour');
  const daily = Digest.due(s({}), at(2026, 11, 5, 8));
  assert.deepEqual(daily, { due: true, periodKey: '2026-11-05', reason: '' });
  assert.equal(Digest.due(s({ lastSentDate: '2026-11-05' }), at(2026, 11, 5, 8)).reason, 'already_sent');
  // 2026-11-05 is a Thursday (4).
  assert.equal(Digest.due(s({ frequency: 'weekly', weekday: 1 }), at(2026, 11, 5, 8)).reason, 'not_this_day');
  assert.equal(Digest.due(s({ frequency: 'weekly', weekday: 4 }), at(2026, 11, 5, 8)).due, true);
  // The 31st clamps to a 30-day month.
  assert.equal(Digest.due(s({ frequency: 'monthly', monthday: 31 }), at(2026, 11, 30, 8)).periodKey, '2026-11');
  assert.equal(Digest.due(s({ frequency: 'monthly', monthday: 3 }), at(2026, 11, 5, 8)).reason, 'not_this_day');
  assert.equal(Digest.due(s({ hour: 0 }), at(2026, 11, 5, 0)).due, true, 'midnight is an hour');
});

test('the figures are the period\'s, in the shop\'s base currency', () => {
  const now = at(2026, 11, 5, 8);
  const today = new Date(2026, 10, 5, 7).toISOString();
  const settings = { currency: 'SAR', emailDigest: { frequency: 'daily' }, lowStockThreshold: 200 };
  const f = Digest.figures({
    settings, now, clients: [],
    orders: [
      { id: 'A', status: 'completed', completedAt: today, price: 100, paymentStatus: 'paid', paidAmount: 100 },
      { id: 'B', status: 'completed', completedAt: '2026-01-01T00:00:00Z', price: 50 },
      { id: 'C', status: 'printing', price: 70 },
    ],
    inventory: [{ material: 'PLA', weight: 120 }, { material: 'PETG', weight: 900 }, { brand: 'X', weight: 10, reorderPoint: 5 }],
    waitingList: [{}, {}],
  });
  assert.equal(f.completed, 1);
  assert.equal(f.revenue, 100);
  assert.equal(f.outstanding, 50);
  assert.deepEqual(f.lowStock, [{ name: 'PLA', weight: 120, reorderAt: 200 }]);
  assert.equal(f.waiting, 2);
  const page = Digest.html(f, { shopName: '<Acme>', currency: 'SAR', today: '2026-11-05' });
  assert.match(page, /&lt;Acme&gt;/);
  assert.match(page, /100\.00 SAR/);
  assert.match(page, /Daily Digest · 2026-11-05/);
  assert.match(page, /PLA — 120g remaining \(reorder at 200g\)/);
  assert.equal(Digest.subject('Acme', 'weekly'), 'Acme — Weekly Digest');
  assert.equal(Digest.subject('', 'daily', true), 'Khayt — Test Digest');
});

test('the four choices: local, cloud, both, neither', () => {
  assert.equal(Digest.choiceOf(true, true), 'both');
  assert.equal(Digest.choiceOf(false, true), 'cloud');
  assert.deepEqual(Digest.choiceParts('local'), { local: true, cloud: false });
  assert.deepEqual(Digest.choiceParts('none'), { local: false, cloud: false });
  assert.deepEqual(Digest.sent({ emailDigest: { enabled: true } }, '2026-W45'), { enabled: true, lastSentDate: '2026-W45' });
});

// ── WEBHOOK SUBSCRIPTIONS ───────────────────────────────────────────────────

test('a subscription without a secret signs with the shop\'s one signing secret', () => {
  assert.equal(Bus.subscriptionSecret({ secret: '' }, { secret: 'shared' }), 'shared');
  assert.equal(Bus.subscriptionSecret({ secret: 'own' }, { secret: 'shared' }), 'own');
  assert.equal(Bus.subscriptionSecret({}, {}), '');
});

test('editing keeps the legacy map in step and drops retries for a subscription taken away', () => {
  const a = Bus.editSubscription(null, { url: ' https://a.example/h ', events: ['status_changed', 'nope', 'order_created'] }, 'whs_a', 'T');
  assert.deepEqual(a.events, ['order_created', 'status_changed'], 'catalogue order, no unknown event');
  assert.equal(a.url, 'https://a.example/h');
  assert.equal(a.secret, '');
  const wh = Bus.withSubscriptions({ deliveries: [1], pending: [{ id: 'p1', subscriptionId: 'whs_gone' },
    { id: 'p2', subscriptionId: 'whs_a' }, { id: 'p3', subscriptionId: 'event:status' }] }, [a]);
  assert.deepEqual(wh.events, { order_created: 'https://a.example/h', status_changed: 'https://a.example/h' });
  assert.deepEqual(wh.pending.map((p) => p.id), ['p2', 'p3']);
  assert.deepEqual(wh.deliveries, [1]);
  const off = Bus.editSubscription({ ...a, disabledReason: 'gone', enabled: false }, { enabled: true, events: a.events }, 'x', 'U');
  assert.equal(off.disabledReason, undefined);
  assert.equal(off.id, 'whs_a');
  assert.equal(off.createdAt, 'T');
});

test('the desktop\'s legacy screen keeps the subscriptions when its URLs did not change', () => {
  const subs = [Bus.editSubscription(null, { url: 'https://a.example/h', events: ['status_changed'] }, 'whs_a', 'T'),
    Bus.editSubscription(null, { url: 'https://b.example/h', events: ['status_changed'] }, 'whs_b', 'T')];
  const wh = Bus.withSubscriptions({ enabled: false, deliveries: [{ id: 'd' }], pending: [] }, subs);
  const kept = Bus.fromLegacyForm(wh, { enabled: true, secret: 'x', events: { status_changed: 'https://a.example/h', order_created: '' } });
  assert.equal(kept.subscriptions.length, 2, 'the second URL the legacy screen cannot show survives');
  assert.equal(kept.enabled, true);
  assert.deepEqual(kept.deliveries, [{ id: 'd' }]);
  const moved = Bus.fromLegacyForm(wh, { enabled: true, secret: 'x', events: { status_changed: 'https://c.example/h' } });
  assert.equal(moved.subscriptions, undefined, 'rebuilt from the screen on next use');
  assert.deepEqual(Bus.migrateLegacyWebhooks(moved).map((s) => s.url), ['https://c.example/h']);
});

test('the signing secret is filled in only for an address the shop saved', () => {
  const settings = {
    eventWebhooks: { url: 'https://ev.example/k', secret: 'ev-secret' },
    webhooks: { secret: 'shared', subscriptions: [{ id: 'a', url: 'https://a.example/h', secret: '' },
      { id: 'b', url: 'https://b.example/h', secret: '__KHAYT_MASKED__' }, { id: 'c', url: 'https://c.example/h', secret: 'own' }] },
  };
  const f = (u) => Bus.signingSecretFor(settings, u, D.urlKey, '__KHAYT_MASKED__');
  assert.deepEqual(f('https://ev.example/k/'), { found: true, secret: 'ev-secret' });
  assert.deepEqual(f('https://a.example/h'), { found: true, secret: 'shared' });
  assert.deepEqual(f('https://b.example/h'), { found: true, secret: 'shared' }, 'a mask stored by an old migration');
  assert.deepEqual(f('https://c.example/h'), { found: true, secret: 'own' });
  assert.deepEqual(f('https://evil.example/h'), { found: false, secret: '' });
  // A book with only the legacy map still finds its URLs.
  const legacy = { webhooks: { secret: 'shared', events: { status_changed: 'https://a.example/h' } } };
  assert.deepEqual(Bus.signingSecretFor(legacy, 'https://a.example/h', D.urlKey, 'M'), { found: true, secret: 'shared' });
});

test('a delivery record keeps its payload, so a resend sends what the first attempt did', () => {
  const r = Bus.deliveryRecord({ id: 'd1', subscriptionId: 'a', event: 'status_changed', at: 'T',
    status: 'retrying', httpStatus: 503, attempts: 2, payload: { orderId: 'J1' } });
  assert.deepEqual(r.payload, { orderId: 'J1' });
  assert.equal(r.error, null);
});

// ── SAVING THEM ─────────────────────────────────────────────────────────────

test('settings-edit: the SMS providers\' fields, secrets opaque, WhatsApp Business untouched', () => {
  const s = { smsConfig: { provider: 'whatsapp_cloud', phoneNumberId: '123', token: '__enc__W', from: '+1' } };
  const out = Edit.apply(s, { smsConfig: { provider: 'twilio', channel: 'sms', accountSid: ' AC1 ', authToken: '__enc__T',
    from: ' +1555 ', url: '' } }, { year: 2026 });
  assert.equal(out.smsConfig.provider, 'twilio');
  assert.equal(out.smsConfig.accountSid, 'AC1');
  assert.equal(out.smsConfig.from, '+1555');
  assert.equal(out.smsConfig.authToken, '__enc__T');
  assert.equal(out.smsConfig.token, '__enc__W', 'the Business token kept');
  assert.equal(out.smsConfig.channel, 'sms');
  // The WhatsApp Business pane names none of these: they stay.
  const wab = Edit.apply(out, { smsConfig: { provider: 'whatsapp_cloud', phoneNumberId: '9' } }, { year: 2026 });
  assert.equal(wab.smsConfig.accountSid, 'AC1');
  assert.equal(wab.smsConfig.authToken, '__enc__T');
});

test('settings-edit: webhooks, event webhooks, accounting and the digest', () => {
  const s = { webhooks: { enabled: false, secret: '__enc__S', deliveries: [{ id: 'd' }],
    subscriptions: [{ id: 'whs_a', url: 'https://a.example/h', events: ['order_created'], createdAt: 'T0' }] },
  emailDigest: { lastSentDate: '2026-11-04' }, accountingSync: { salesAccount: '200' } };
  const out = Edit.apply(s, {
    webhooks: { enabled: true, subscriptions: [
      { id: 'whs_a', url: 'https://a.example/h2', events: ['status_changed'] },
      { id: 'whs_b', isNew: true, url: 'https://b.example/h', events: ['payment_received'], createdAt: 'T1' },
      { id: 'whs_x', url: 'https://x.example/h', events: [] },
      { id: 'whs_c', isNew: true, url: 'http://insecure.example', events: [] },
    ] },
    eventWebhooks: { enabled: true, url: ' https://ev.example ', events: { paid: false } },
    accountingSync: { enabled: true, format: 'daftra', webhookUrl: 'https://acc.example', pushOnPaid: false },
    emailDigest: { enabled: true, frequency: 'monthly', monthday: 31, hour: '7', recipientEmail: ' me@x ' },
  }, { year: 2026 });
  assert.equal(out.webhooks.enabled, true);
  assert.equal(out.webhooks.secret, '__enc__S', 'absent keeps the secret');
  assert.deepEqual(out.webhooks.subscriptions.map((x) => [x.id, x.url, x.createdAt]),
    [['whs_a', 'https://a.example/h2', 'T0'], ['whs_b', 'https://b.example/h', 'T1']],
    'an unknown id that is not new, and an http URL, are refused');
  assert.deepEqual(out.webhooks.deliveries, [{ id: 'd' }]);
  assert.deepEqual(out.eventWebhooks, { enabled: true, url: 'https://ev.example', secret: '', events: { paid: false } });
  assert.equal(out.accountingSync.format, 'daftra');
  assert.equal(out.accountingSync.salesAccount, '200', 'the export dialogue\'s mapping kept');
  assert.equal(out.accountingSync.pushOnPaid, false);
  assert.deepEqual(out.emailDigest, { lastSentDate: '2026-11-04', enabled: true, frequency: 'monthly',
    hour: 7, weekday: 1, monthday: 28, recipientEmail: 'me@x' });
  // A form without them changes none of them.
  const same = Edit.apply(out, { bizEn: 'Acme' }, { year: 2026 });
  assert.deepEqual(same.webhooks, out.webhooks);
  assert.deepEqual(same.emailDigest, out.emailDigest);
  assert.deepEqual(same.accountingSync, out.accountingSync);
});
