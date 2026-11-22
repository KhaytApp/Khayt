/**
 * AI reply-drafting core (lib/ai-reply.js) — pure prompt building + extraction.
 * No network, no key (the model call is injected via aiExtract in the app).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/ai-reply.js');

test('schema + intents are well-formed', () => {
  assert.equal(R.REPLY_SCHEMA.required[0], 'message');
  assert.ok(R.REPLY_INTENTS.some((i) => i.id === 'quote_followup'));
  assert.ok(R.REPLY_INTENTS.every((i) => i.id && i.label));
});

test('system prompt sets language + forbids inventing facts', () => {
  const en = R.buildReplySystem({ shopName: 'Acme 3D', lang: 'en' });
  assert.match(en, /Acme 3D/);
  assert.match(en, /English/);
  assert.match(en, /Never invent/i);
  const ar = R.buildReplySystem({ lang: 'ar' });
  assert.match(ar, /Arabic/);
});

test('request includes provided facts, omits missing, and applies intent', () => {
  const req = R.buildReplyRequest({
    intent: 'quote_followup',
    order: { id: 'A-9', project: 'Vase', status: 'quote', price: 120 },
    client: { name: 'Sara' },
    currency: 'SAR',
  });
  assert.match(req, /Sara/);
  assert.match(req, /A-9/);
  assert.match(req, /120 SAR/);
  assert.match(req, /follow up on the quote/i);
  assert.doesNotMatch(req, /Due \/ ready date/); // not provided → omitted
});

test('request computes outstanding balance when partially paid', () => {
  const req = R.buildReplyRequest({
    intent: 'payment_reminder',
    order: { id: 'B-1', price: 200, paidAmount: 50 },
    currency: 'SAR',
  });
  assert.match(req, /Outstanding balance: 150 SAR/);
});

test('unknown intent falls back to status_update; owner note is included', () => {
  const req = R.buildReplyRequest({ intent: 'nonsense', order: { id: 'X' }, extra: 'mention free delivery' });
  assert.match(req, /reassuring update/i);
  assert.match(req, /free delivery/);
});

test('pickMessage handles object, raw string, trims, and empties', () => {
  assert.equal(R.pickMessage({ message: '  hi there  ' }), 'hi there');
  assert.equal(R.pickMessage('raw text'), 'raw text');
  assert.equal(R.pickMessage(null), '');
  assert.equal(R.pickMessage({}), '');
});
