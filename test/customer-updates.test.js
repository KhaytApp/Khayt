'use strict';
/**
 * Automatic customer order updates on the desktop (renderer/customer-updates.js
 * + lib/customer-updates.js), decided by the rule the Mac sends with
 * (lib/whatsapp-message.js cloudMessage) and deduplicated by the same log line.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/content-languages.js');
require('../lib/wa-template.js');
require('../lib/whatsapp-send.js');
const WM = require('../lib/whatsapp-message.js');
require('../lib/whatsapp-status.js');
const CU = require('../lib/customer-updates.js');
const Status = require('../lib/order-status.js');

const TEMPLATES = {
  received: { name: 'order_received', langs: ['ar', 'en'] },
  ready: { name: 'order_ready', langs: ['ar', 'en'] },
  shipped: { name: 'order_shipped', langs: ['ar'] },
  delivered: { name: 'order_delivered', langs: ['en'] },
};
const ACCOUNT = { provider: 'whatsapp_cloud', phoneNumberId: '123456789', token: 'EAA' + 'x'.repeat(30) };
const OPTED = { at: '2026-10-01T09:00:00.000Z', how: 'asked' };

// ── lib/customer-updates.js ─────────────────────────────────────────────────

test('beforeOf reads the stage before the move from the history it just wrote', () => {
  const o = { id: 'J1', status: 'quote', statusHistory: [{ status: 'quote', at: 'a' }] };
  assert.equal(CU.beforeOf(o), null, 'one line: the stage before is unknown');
  Status.apply(o, 'pending', { now: Date.parse('2026-11-01T10:00:00Z') });
  assert.deepEqual(CU.beforeOf(o), { status: 'quote' });
  Status.apply(o, 'completed', { now: Date.parse('2026-11-02T10:00:00Z') });
  assert.equal(WM.milestoneOf(CU.beforeOf(o)), 'received');
  Status.markShipped(o, { now: Date.parse('2026-11-03T10:00:00Z') });
  assert.equal(WM.milestoneOf(CU.beforeOf(o)), 'ready');
  Status.markDelivered(o, { now: Date.parse('2026-11-04T10:00:00Z') });
  assert.equal(WM.milestoneOf(CU.beforeOf(o)), 'shipped');
  assert.equal(CU.beforeOf(null), null);
  assert.equal(CU.beforeOf({ status: 'pending' }), null, 'a legacy job with no history');
});

test('appendComm appends and keeps the NEWEST 200, as the Mac does', () => {
  const log = Array.from({ length: 200 }, (_, i) => ({ id: 'L' + i }));
  const out = CU.appendComm(log, { id: 'new' });
  assert.equal(out.length, 200);
  assert.equal(out[199].id, 'new');
  assert.equal(out[0].id, 'L1');
  assert.equal(log.length, 200, 'the input is left alone');
  assert.deepEqual(CU.appendComm(undefined, { id: 'x' }), [{ id: 'x' }]);
});

test('jobLines lists this job\'s WhatsApp and SMS lines, newest first', () => {
  const client = { commLog: [
    { type: 'whatsapp', orderId: 'J1', milestone: 'received', at: '2026-11-01' },
    { type: 'note', orderId: 'J1', at: '2026-11-05' },
    { type: 'sms', orderId: 'J1', milestone: 'ready', at: '2026-11-03' },
    { type: 'whatsapp', orderId: 'J2', milestone: 'ready', at: '2026-11-04' },
    { channel: 'wa', orderId: 'J1', at: '2026-11-02' },
  ] };
  assert.deepEqual(CU.jobLines(client, 'J1').map((l) => l.at), ['2026-11-03', '2026-11-02', '2026-11-01']);
  assert.deepEqual(CU.jobLines(null, 'J1'), []);
  assert.equal(CU.deliveryOf({ status: 'read' }), 'read');
  assert.equal(CU.deliveryOf({ status: 'weird' }), '');
});

test('keep folds reports: the highest per message, only the fields apply reads', () => {
  const kept = CU.keep([], [
    { messageId: 'm1', status: 'delivered', at: '2026-11-01T10:00:00Z', recipient: '9665…' },
    { messageId: 'm1', status: 'sent', at: '2026-11-01T09:00:00Z' },
    { messageId: 'm2', status: 'failed', at: '2026-11-01T11:00:00Z', errorCode: 131026, errorTitle: 'x'.repeat(300) },
    { messageId: '', status: 'read' },
    { messageId: 'm3', status: 'bogus' },
  ]);
  assert.equal(kept.length, 2);
  const m1 = kept.find((k) => k.messageId === 'm1');
  assert.equal(m1.status, 'delivered');
  assert.equal(m1.recipient, undefined, 'a recipient\'s number is never kept');
  assert.equal(kept.find((k) => k.messageId === 'm2').errorTitle.length, 200);
  const again = CU.keep(kept, [{ messageId: 'm1', status: 'read', at: '2026-11-01T12:00:00Z' }]);
  assert.equal(again.find((k) => k.messageId === 'm1').status, 'read');
  assert.equal(CU.seq(41), 41);
  assert.equal(CU.seq('42'), 42);
  assert.equal(CU.seq(1.5), null);
  assert.equal(CU.seq(1e300), null);
  assert.equal(CU.seq(null), null);
});

// ── renderer/customer-updates.js, with the window's globals stood in ───────

function rig({ client, smsConfig = ACCOUNT, templates = TEMPLATES, answer } = {}) {
  const sent = [];
  const toasts = [];
  let n = 0;
  global.settings = { lang: 'en', smsConfig, whatsappTemplates: templates, bizEn: 'Acme Prints' };
  global.clients = [client || { id: 'C1', nameEn: 'Amal', phone: '0501234567', whatsappOptIn: OPTED }];
  global.printLog = [];
  global.t = (k, p) => k + (p ? ' ' + JSON.stringify(p) : '');
  global.toast = (msg, kind) => toasts.push({ msg, kind });
  global.uid = (p) => p + '-' + (++n);
  global.saveAll = () => {};
  global.localDateStr = (d) => d.toISOString().slice(0, 10);
  global.escapeHtml = (s) => String(s);
  global.hubAPI = {
    sendWhatsappTemplate: async (req) => {
      sent.push(req);
      return answer ? answer(req) : { ok: true, messageId: 'wamid.' + sent.length };
    },
  };
  delete require.cache[require.resolve('../renderer/customer-updates.js')];
  require('../renderer/customer-updates.js');
  return { sent, toasts };
}

/** Move a job as the window does, and run the send runStatusEffects runs. */
async function move(order, to) {
  if (to === 'shipped') Status.markShipped(order, { now: Date.now() });
  else if (to === 'delivered') Status.markDelivered(order, { now: Date.now() });
  else Status.apply(order, to, { now: Date.now() });
  await global.sendOwedCustomerUpdate(order, CU.beforeOf(order));
}

const job = () => ({ id: 'J1', clientId: 'C1', status: 'quote', price: 100,
  statusHistory: [{ status: 'quote', at: '2026-11-01T00:00:00Z' }] });

test('each milestone is sent once, with its template, as a job goes through', async () => {
  const { sent, toasts } = rig();
  const o = job();
  await move(o, 'pending');
  await move(o, 'printing');      // still "received": no second message
  await move(o, 'post');
  await move(o, 'completed');
  await move(o, 'shipped');
  await move(o, 'delivered');
  assert.deepEqual(sent.map((s) => s.template.name),
    ['order_received', 'order_ready', 'order_shipped', 'order_delivered']);
  assert.equal(sent[0].to, '966501234567');
  assert.deepEqual(sent[0].template, { name: 'order_received', language: 'en' });
  assert.deepEqual(sent[2].template, { name: 'order_shipped', language: 'ar' }, 'the first language when the customer\'s is not approved');
  assert.deepEqual(sent[0].params, ['Amal', 'J1', 'Acme Prints']);
  assert.equal(sent[0].smsConfig, global.settings.smsConfig, 'the stored config; main opens the token');
  const log = global.clients[0].commLog;
  assert.equal(log.length, 4);
  assert.deepEqual(log.map((l) => l.milestone), ['received', 'ready', 'shipped', 'delivered']);
  for (const l of log) {
    assert.equal(l.type, 'whatsapp');
    assert.equal(l.orderId, 'J1');
    assert.equal(l.via, 'whatsapp_cloud');
    assert.equal(l.status, 'sent');
    assert.match(l.messageId, /^wamid\./);
  }
  assert.equal(toasts.filter((x) => x.kind === 'success').length, 4);
});

test('a milestone the Mac already sent is not sent again (the shared log line)', async () => {
  const { sent } = rig({ client: { id: 'C1', nameEn: 'Amal', phone: '0501234567', whatsappOptIn: OPTED,
    commLog: [WM.commEntry({ id: 'X', at: '2026-11-01T00:00:00Z', text: 'mac', orderId: 'J1',
      milestone: 'received', lang: 'en', messageId: 'wamid.mac', template: 'order_received' })] } });
  const o = job();
  await move(o, 'pending');
  assert.equal(sent.length, 0);
  await move(o, 'completed');
  assert.equal(sent.length, 1);
});

test('moving back, or reopening, is not a step forward', async () => {
  const { sent } = rig();
  const o = job();
  await move(o, 'pending');
  await move(o, 'completed');
  await move(o, 'shipped');
  await move(o, 'completed');     // "not shipped after all": the stamp comes off
  await move(o, 'printing');      // reopened
  assert.deepEqual(sent.map((s) => s.template.name), ['order_received', 'order_ready', 'order_shipped']);
});

test('nothing goes to a customer who has not agreed, or with no account or template', async () => {
  let r = rig({ client: { id: 'C1', nameEn: 'Amal', phone: '0501234567' } });
  let o = job();
  await move(o, 'pending'); await move(o, 'completed');
  assert.equal(r.sent.length, 0, 'not opted in');
  assert.equal(r.toasts.length, 0, 'and that is quiet');

  r = rig({ smsConfig: { provider: 'twilio', accountSid: 'AC1', authToken: 'x' } });
  o = job();
  await move(o, 'pending'); await move(o, 'completed');
  assert.equal(r.sent.length, 0, 'a text provider is never sent through on its own (the Mac\'s rule)');

  r = rig({ templates: { shipped: TEMPLATES.shipped } });
  o = job();
  await move(o, 'pending'); await move(o, 'completed'); await move(o, 'shipped');
  assert.deepEqual(r.sent.map((s) => s.template.name), ['order_shipped'], 'only the steps with a template');
});

test('a customer who agreed but cannot be reached is SAID, and nothing is sent', async () => {
  const { sent, toasts } = rig({ client: { id: 'C1', nameEn: 'Amal', phone: '4471234567890', whatsappOptIn: OPTED } });
  const o = job();
  await move(o, 'pending');
  assert.equal(sent.length, 0);
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].kind, 'warning');
  assert.match(toasts[0].msg, /cu\.not_sent/);
  assert.match(toasts[0].msg, /cu\.r_no_country_code/);
});

test('a refused send writes nothing, is said, and is tried again on the next chance', async () => {
  let refuse = true;
  const { sent, toasts } = rig({ answer: () => (refuse
    ? { ok: false, reason: 'template_missing', code: 132001, title: 'Template name does not exist' }
    : { ok: true, messageId: 'wamid.ok' }) });
  const o = job();
  await move(o, 'pending');
  assert.equal(sent.length, 1);
  assert.equal((global.clients[0].commLog || []).length, 0, 'no line for a message Meta refused');
  assert.match(toasts[0].msg, /wab\.reason\.template_missing.*#132001/);
  refuse = false;
  await global.sendJobUpdateNow.call(null, 'missing');   // no such job: nothing
  global.printLog.push(o);
  await global.sendJobUpdateNow('J1');
  assert.equal(sent.length, 2);
  assert.equal(global.clients[0].commLog.length, 1);
  assert.equal(global.clients[0].commLog[0].milestone, 'received');
});

test('an unknown stage before (a legacy job with no history) sends nothing on its own', async () => {
  const { sent } = rig();
  const o = { id: 'J9', clientId: 'C1', status: 'completed' };
  await global.sendOwedCustomerUpdate(o, CU.beforeOf(o));
  assert.equal(sent.length, 0);
});

test('two moves racing for one milestone send it once', async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const { sent } = rig({ answer: async () => { await gate; return { ok: true, messageId: 'wamid.1' }; } });
  const o = job();
  Status.apply(o, 'pending', { now: Date.now() });
  const a = global.sendOwedCustomerUpdate(o, { status: 'quote' });
  const b = global.sendOwedCustomerUpdate(o, { status: 'quote' });
  release();
  await Promise.all([a, b]);
  assert.equal(sent.length, 1);
});
