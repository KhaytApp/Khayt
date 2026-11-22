'use strict';

/**
 * lib/portal-owner.js — the shop's side of the customer portal, lifted out of
 * renderer/integrations.js so the Mac asks the same questions.
 *
 * Each rule is held to the verbatim inline original over the inputs where the
 * original was right, and each defect it had gets a test of its own.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/portal-trial.js');
require('../lib/cloud-plans.js');
const P = require('../lib/portal-owner.js');
const R = require('../lib/portal-refresh.js');

// ── The originals, verbatim from renderer/integrations.js (before the lift) ──

const originalUrl = (url, pubToken) => String(url || '').replace(/\/$/, '') + '/p/' + pubToken;

function originalResponse(items, pubToken, order) {
  const item = (items || []).find(x => x.token === pubToken);
  const act = item && item.action;
  const paid = item && item.payment && item.payment.status === 'paid';
  if (!act || !act.type) return { response: 'none', paid: !!paid, advance: false };
  const approved = act.type === 'approve';
  return { response: approved ? 'approved' : 'declined', paid: !!paid,
           advance: approved && order.status === 'quote' };
}

function originalDeposit(dep, payUrl) {
  dep = String(dep).trim(); payUrl = String(payUrl).trim();
  return { cloudDeposit: dep ? +dep : null, cloudPayUrl: payUrl || null, lastPayUrl: payUrl || null };
}

// ── Parity where the original was right ──

test('the link matches the original for an ordinary address and token', () => {
  for (const [url, tok] of [['https://cloud.khaytapp.com', 'abc123'], ['https://x.example/', 'T0k-en_9']]) {
    assert.equal(P.portalUrl(url, tok), originalUrl(url, tok));
  }
});

test('the customer\'s response matches the original for approve, decline, nothing, and paid', () => {
  const quote = { status: 'quote' };
  const cases = [
    [[{ token: 't1', action: { type: 'approve' } }], 't1', quote],
    [[{ token: 't1', action: { type: 'approve' } }], 't1', { status: 'pending' }],
    [[{ token: 't1', action: { type: 'decline' } }], 't1', quote],
    [[{ token: 't1', action: null, payment: { status: 'paid' } }], 't1', quote],
    [[{ token: 't1', action: { type: 'approve' }, payment: { status: 'paid' } }], 't1', quote],
    [[{ token: 'other', action: { type: 'approve' } }], 't1', quote],
  ];
  for (const [items, tok, order] of cases) {
    const mine = P.responseFor(items, tok, order);
    const theirs = originalResponse(items, tok, order);
    assert.deepEqual({ response: mine.response, paid: mine.paid, advance: mine.advance }, theirs);
  }
});

test('a well-formed deposit and pay link store what the original stored', () => {
  for (const [dep, url] of [['250', 'https://pay.example/x'], ['', ''], ['99.5', '']]) {
    const mine = P.depositForm(dep, url);
    assert.equal(mine.ok, true);
    const theirs = originalDeposit(dep, url);
    assert.deepEqual({ cloudDeposit: mine.cloudDeposit, cloudPayUrl: mine.cloudPayUrl, lastPayUrl: mine.lastPayUrl }, theirs);
  }
});

// ── The defects ──

test('a server address with a trailing slash or two, and a token that needs it, make one clean link', () => {
  assert.equal(P.portalUrl('https://c.example//', 'a b'), 'https://c.example/p/a%20b');
  assert.equal(originalUrl('https://c.example//', 'a b'), 'https://c.example//p/a b', 'the original produced this');
  assert.equal(P.portalUrl('', 't'), '');
  assert.equal(P.portalUrl('https://c.example', ''), '');
});

test('a deposit that is not a positive number is refused, not stored as NaN or a negative', () => {
  assert.ok(Number.isNaN(originalDeposit('abc', '').cloudDeposit), 'the original stored NaN');
  assert.equal(originalDeposit('-50', '').cloudDeposit, -50, 'the original stored a negative');
  assert.deepEqual(P.depositForm('abc', ''), { ok: false, error: 'deposit' });
  assert.deepEqual(P.depositForm('-50', ''), { ok: false, error: 'deposit' });
  assert.equal(P.depositForm('0', '').cloudDeposit, null, 'zero is no deposit');
  assert.equal(P.depositForm('1,250.456', '').cloudDeposit, 1250.46);
});

test('a pay link that is not an http(s) address is refused, and never reaches the public page', () => {
  assert.equal(originalDeposit('', 'javascript:alert(1)').cloudPayUrl, 'javascript:alert(1)', 'the original kept it');
  assert.deepEqual(P.depositForm('', 'javascript:alert(1)'), { ok: false, error: 'pay_url' });
  assert.deepEqual(P.depositForm('', 'pay.example/x'), { ok: false, error: 'pay_url' });
  // And the payload builder no longer publishes one already in a book.
  const quote = { id: 'Q1', status: 'quote', price: 100, cloudDeposit: 50, cloudPayUrl: 'javascript:alert(1)' };
  assert.equal(R.payloadFor(quote, { settings: {} }).payload.payUrl, undefined);
  const good = { ...quote, cloudPayUrl: 'https://pay.example/q1' };
  assert.equal(R.payloadFor(good, { settings: {} }).payload.payUrl, 'https://pay.example/q1');
});

// ── The rest of the module ──

test('the owner routes are the contract\'s, each segment encoded; messages never use the public route', () => {
  assert.equal(P.paths.list('S 1'), '/v1/shops/S%201/published');
  assert.equal(P.paths.item('S1', 'a/b'), '/v1/shops/S1/published/a%2Fb');
  assert.equal(P.paths.messages('S1', 't'), '/v1/shops/S1/published/t/messages');
  assert.equal(P.paths.reply('S1', 't'), '/v1/shops/S1/published/t/message');
  assert.equal(P.paths.item('S1', 't'), R.pathFor('S1', 't'), 'the same path the republish uses');
  for (const p of Object.values(P.paths)) assert.ok(!p('S', 't').startsWith('/v1/p/'));
});

test('the trial gate allows during beta and never starts a clock then', () => {
  const g = P.trialGate({}, Date.parse('2026-10-08T00:00:00Z'));
  assert.equal(g.allowed, true);
  if (g.state && g.state.state === 'beta') assert.equal(g.startAt, null);
});

test('the trial gate starts the clock on first publish and refuses once it has run out', () => {
  const Plans = globalThis.KhaytCloudPlans;
  const was = Plans.isBetaFree;
  Plans.isBetaFree = () => false;
  try {
    const now = Date.parse('2026-10-08T00:00:00Z');
    const first = P.trialGate({}, now);
    assert.equal(first.allowed, true);
    assert.equal(first.startAt, new Date(now).toISOString());
    const later = P.trialGate({ portalTrialStartedAt: '2026-10-01T00:00:00Z' }, now);
    assert.equal(later.allowed, true);
    assert.equal(later.startAt, null, 'a started clock is not restarted');
    const over = P.trialGate({ portalTrialStartedAt: '2026-01-01T00:00:00Z' }, now);
    assert.equal(over.allowed, false);
    const paying = P.trialGate({ portalTrialStartedAt: '2026-01-01T00:00:00Z', planActive: true }, now);
    assert.equal(paying.allowed, true);
  } finally { Plans.isBetaFree = was; }
});

test('a refusal is named for what it means', () => {
  assert.equal(P.errorFor(403, {}).code, 'viewer');
  assert.equal(P.errorFor(409, { error: 'That link belongs to another shop' }).text, 'That link belongs to another shop');
  assert.equal(P.errorFor(409, {}).code, 'other_shop');
  assert.equal(P.errorFor(413, {}).code, 'too_large');
  assert.equal(P.errorFor(404, {}).code, 'not_this_shop');
  assert.equal(P.errorFor(429, {}).code, 'rate');
  assert.equal(P.errorFor(500, null).text, 'HTTP 500');
});

test('a publish that did not link the customer says so; one that did says nothing', () => {
  assert.equal(P.linkNote({ ok: true, customerEmailLinked: false, note: 'cap' }), 'cap');
  assert.equal(P.linkNote({ ok: true, customerEmailLinked: false }), 'link_cap');
  assert.equal(P.linkNote({ ok: true, customerEmailLinked: true }), null);
  assert.equal(P.linkNote({ ok: true }), null);
});

test('a thread comes back oldest first, with nothing the screen cannot draw', () => {
  const t = P.threadFrom({ messages: [
    { from: 'shop', text: 'later', at: 20 }, { from: 'customer', text: 'first', at: 10 },
    { from: 'x', text: '  ', at: 5 }, null, { from: 'evil', text: 'who', at: 30 },
  ] });
  assert.deepEqual(t.map((m) => m.text), ['first', 'later', 'who']);
  assert.equal(t[2].from, 'customer', 'anything not the shop is the customer');
  assert.deepEqual(P.threadFrom(null), []);
});
