'use strict';
/**
 * The WhatsApp Business send: the Cloud API template request, byte for byte,
 * and what each of Meta's answers means to the shop.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const WS = require('../lib/whatsapp-send.js');

const TOKEN = 'EAAG' + 'a'.repeat(40);
const msg = (over) => Object.assign({
  phoneNumberId: '106540352242922',
  token: TOKEN,
  to: '966551234567',
  template: { name: 'order_ready', language: 'ar' },
  params: ['Sara', 'J-101', 'Athar'],
}, over || {});

test('the request is a template message to the Cloud API, never free text', () => {
  const r = WS.buildRequest(msg());
  assert.equal(r.ok, true);
  assert.equal(r.method, 'POST');
  assert.equal(r.url, 'https://graph.facebook.com/v21.0/106540352242922/messages');
  assert.deepEqual(r.headers, { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json' });
  assert.deepEqual(JSON.parse(r.body), {
    messaging_product: 'whatsapp',
    recipient_type: 'individual',
    to: '966551234567',
    type: 'template',
    template: {
      name: 'order_ready',
      language: { code: 'ar' },
      components: [{ type: 'body', parameters: [
        { type: 'text', text: 'Sara' }, { type: 'text', text: 'J-101' }, { type: 'text', text: 'Athar' },
      ] }],
    },
  });
  assert.equal(JSON.parse(r.body).text, undefined);
});

test('the token is in the header only — not the URL, not the body', () => {
  const r = WS.buildRequest(msg());
  assert.equal(r.url.includes(TOKEN), false);
  assert.equal(r.body.includes(TOKEN), false);
});

test('a template with no parameters sends no components', () => {
  const r = WS.buildRequest(msg({ params: [] }));
  assert.equal(JSON.parse(r.body).template.components, undefined);
});

test('parameters are made one line, never empty, and capped', () => {
  assert.equal(WS.cleanParam('Sara\nAhmed'), 'Sara Ahmed');
  assert.equal(WS.cleanParam('a\t\tb'), 'a b');
  assert.equal(WS.cleanParam('a      b'), 'a b');
  assert.equal(WS.cleanParam(''), '-');
  assert.equal(WS.cleanParam(null), '-');
  assert.equal(WS.cleanParam('   '), '-');
  assert.equal(WS.cleanParam('x'.repeat(500)).length, WS.PARAM_MAX);
});

test('a malformed field is refused before it reaches a request', () => {
  assert.deepEqual(WS.buildRequest(msg({ phoneNumberId: '12ab' })), { ok: false, reason: 'bad_phone_number_id' });
  assert.deepEqual(WS.buildRequest(msg({ token: '' })), { ok: false, reason: 'bad_token' });
  // A newline in the token would be a second header.
  assert.deepEqual(WS.buildRequest(msg({ token: TOKEN + '\nX-Evil: 1' })), { ok: false, reason: 'bad_token' });
  assert.deepEqual(WS.buildRequest(msg({ token: 'Bearer ' + TOKEN })), { ok: false, reason: 'bad_token' });
  assert.deepEqual(WS.buildRequest(msg({ to: '+966551234567' })), { ok: false, reason: 'bad_recipient' });
  assert.deepEqual(WS.buildRequest(msg({ to: '0551234567x' })), { ok: false, reason: 'bad_recipient' });
  assert.deepEqual(WS.buildRequest(msg({ template: { name: 'Order Ready', language: 'ar' } })), { ok: false, reason: 'bad_template' });
  assert.deepEqual(WS.buildRequest(msg({ template: { name: 'order_ready', language: 'arabic' } })), { ok: false, reason: 'bad_language' });
  // The phone number id is a path segment: nothing but digits gets there.
  assert.deepEqual(WS.buildRequest(msg({ phoneNumberId: '123456/../me' })), { ok: false, reason: 'bad_phone_number_id' });
});

test('en_US is a language code', () => {
  assert.equal(WS.buildRequest(msg({ template: { name: 'order_ready', language: 'en_US' } })).ok, true);
});

test('a sent message comes back with the wamid the delivery reports name', () => {
  const r = WS.readResponse(200, {
    messaging_product: 'whatsapp',
    contacts: [{ input: '966551234567', wa_id: '966551234567' }],
    messages: [{ id: 'wamid.HBgMOTY2NTUxMjM0NTY3FQIAERgSQ0Y=', message_status: 'accepted' }],
  });
  assert.deepEqual(r, { ok: true, messageId: 'wamid.HBgMOTY2NTUxMjM0NTY3FQIAERgSQ0Y=', waId: '966551234567' });
});

test('a 200 with no message id is not a send', () => {
  const r = WS.readResponse(200, { messaging_product: 'whatsapp', messages: [] });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'no_message_id');
});

const metaError = (code, message, extra) => ({ error: Object.assign({ message, type: 'OAuthException', code, fbtrace_id: 'A1' }, extra || {}) });

test('template paused, missing or disabled each say so', () => {
  assert.equal(WS.readResponse(400, metaError(132015, 'Template is Paused')).reason, 'template_paused');
  assert.equal(WS.readResponse(404, metaError(132001, "Template name does not exist in the translation")).reason, 'template_missing');
  assert.equal(WS.readResponse(400, metaError(132016, 'Template is disabled')).reason, 'template_disabled');
  assert.equal(WS.readResponse(400, metaError(132000, 'Number of parameters does not match')).reason, 'template_params');
});

test('a bad or expired token says so, by code or by HTTP 401', () => {
  assert.equal(WS.readResponse(401, metaError(190, 'Error validating access token: Session has expired')).reason, 'bad_token');
  assert.equal(WS.readResponse(401, {}).reason, 'bad_token');
});

test('a number not on WhatsApp says so', () => {
  const r = WS.readResponse(400, metaError(131026, 'Message undeliverable', { error_user_title: 'Message Undeliverable.' }));
  assert.equal(r.reason, 'not_on_whatsapp');
  assert.equal(r.code, 131026);
  assert.equal(r.title, 'Message Undeliverable.');
  assert.equal(r.retryable, false);
});

test('rate limits and outages are retryable; nothing else is', () => {
  assert.equal(WS.readResponse(429, metaError(130429, 'Rate limit hit')).retryable, true);
  assert.equal(WS.readResponse(503, {}).reason, 'unavailable');
  assert.equal(WS.readResponse(503, {}).retryable, true);
  assert.equal(WS.readResponse(400, metaError(131047, 'Re-engagement message')).reason, 'outside_window');
  assert.equal(WS.readResponse(400, metaError(131047, 'x')).retryable, false);
  assert.equal(WS.readResponse(403, metaError(200, 'Permissions error')).reason, 'no_permission');
  assert.equal(WS.readResponse(400, metaError(999999, 'Something new')).reason, 'failed');
});

test('an error title is one short line', () => {
  const r = WS.readResponse(400, metaError(100, 'line one\n\nline two ' + 'x'.repeat(400)));
  assert.equal(r.title.includes('\n'), false);
  assert.ok(r.title.length <= 200);
});

test('a body that is not JSON is still an answer', () => {
  assert.equal(WS.readResponse(502, null).reason, 'unavailable');
  assert.equal(WS.readResponse(200, null).reason, 'no_message_id');
});

test('the check request asks Graph about the number and writes to nobody', () => {
  const r = WS.buildCheckRequest({ phoneNumberId: '106540352242922', token: TOKEN });
  assert.equal(r.method, 'GET');
  assert.equal(r.url, 'https://graph.facebook.com/v21.0/106540352242922?fields=display_phone_number,verified_name');
  assert.equal(r.url.includes('messages'), false);
  assert.deepEqual(WS.buildCheckRequest({ phoneNumberId: '1', token: TOKEN }), { ok: false, reason: 'bad_phone_number_id' });
  assert.deepEqual(WS.readCheck(200, { display_phone_number: '+966 55 123 4567', verified_name: 'Athar', id: '1065' }),
    { ok: true, number: '+966 55 123 4567', name: 'Athar' });
  assert.equal(WS.readCheck(401, metaError(190, 'expired')).reason, 'bad_token');
  assert.equal(WS.readCheck(200, {}).ok, false);
});

test('the sent line is what the delivery reports then move forward', () => {
  const WM = require('../lib/whatsapp-message.js');
  const WSt = require('../lib/whatsapp-status.js');
  const sent = WS.readResponse(200, { messages: [{ id: 'wamid.X1' }] });
  const line = WM.commEntry({ id: 'L', at: '2026-10-23T10:00:00Z', text: 't', orderId: 'J', milestone: 'ready', messageId: sent.messageId });
  const out = WSt.apply([{ id: 'C1', commLog: [line] }], [{ messageId: 'wamid.X1', status: 'delivered', at: '2026-10-23T10:01:00Z' }]);
  assert.equal(out.changed, 1);
  assert.equal(out.clients[0].commLog[0].status, 'delivered');
});
