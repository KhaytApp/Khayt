'use strict';
/**
 * lib/portal-owner.js responseLine — the "Check response" wording, the same on
 * every app. A decline of an earlier version waits; it is not a refusal.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/portal-owner.js');

const item = (action, extra) => Object.assign({ token: 'T', action }, extra || {});
const lineFor = (items, order, more) => P.responseLine(Object.assign(P.responseFor(items, 'T', order || { status: 'quote' }), more || {}));

test('a decline of the earlier version waits, in steel, with no cross', () => {
  const l = lineFor([item({ type: 'reject' }, { actionStale: true })]);
  assert.deepEqual(l, { key: 'cloud.portal_declined_earlier', tone: 'wait', mark: '', paidNote: false });
});

test('a decline of this version is a refusal (the cloud says reject)', () => {
  const l = lineFor([item({ type: 'reject' })]);
  assert.deepEqual(l, { key: 'cloud.portal_declined', tone: 'late', mark: '✗', paidNote: false });
});

test('approved, approved and moved on, paid, and nothing yet', () => {
  assert.equal(lineFor([item({ type: 'approve' })]).key, 'cloud.portal_approved');
  assert.equal(lineFor([item({ type: 'approve' })], null, { advanced: true }).key, 'cloud.portal_approved_advanced');
  const paidOnly = lineFor([item(null, { payment: { status: 'paid' } })]);
  assert.deepEqual(paidOnly, { key: 'cloud.portal_deposit_paid', tone: 'live', mark: '✓', paidNote: false });
  assert.deepEqual(lineFor([]), { key: 'cloud.portal_no_response', tone: 'muted', mark: '', paidNote: false });
  assert.equal(lineFor([item({ type: 'approve' }, { payment: { status: 'paid' } })]).paidNote, true);
});

test('every key it can return is in every renderer locale', () => {
  const keys = ['cloud.portal_declined_earlier', 'cloud.portal_declined', 'cloud.portal_approved',
    'cloud.portal_approved_advanced', 'cloud.portal_deposit_paid', 'cloud.portal_no_response'];
  const fs = require('fs'); const path = require('path');
  const dir = path.join(__dirname, '..', 'renderer', 'locales');
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const k of keys) assert.ok(src.includes(`"${k}":`), `${f} lacks ${k}`);
  }
});
