'use strict';
/**
 * The job intake waiting list, as `lib/intake-queue.js` holds it for both
 * apps — the desktop's list and the Mac's, on the same `waitingList` records
 * the LAN intake form writes.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const Q = require('../lib/intake-queue.js');

const NOW = '2026-11-05T09:00:00.000Z';
const LIST = () => [
  { id: 'W1', project: 'Vase', priority: 'normal', status: 'active', estimatedValue: 100 },
  { id: 'W2', project: 'Bracket', priority: 'urgent', status: 'reminded', estValue: 50 },
  { id: 'W3', project: 'Toy', priority: 'low', status: 'declined', estimatedValue: 999 },
  { id: 'W4', project: 'Sign', priority: 'high', status: 'active', reminderDate: '2026-11-01' },
];

test('the list shows the open ones, most urgent first, declined left out', () => {
  assert.deepEqual(Q.visible(LIST()).map((w) => w.id), ['W2', 'W4', 'W1']);
  assert.equal(Q.openCount(LIST()), 3);
});

test('a reminder is due on its day and after, never on a declined one', () => {
  assert.equal(Q.reminderDue(LIST()[3], '2026-11-05'), true);
  assert.equal(Q.reminderDue(LIST()[3], '2026-10-31'), false);
  assert.equal(Q.reminderDue({ reminderDate: '2026-11-01', status: 'declined' }, '2026-11-05'), false);
});

test('the funnel counts both lists and reads either spelling of the value', () => {
  const f = Q.funnel(LIST(), [{ id: 'H1', status: 'converted' }]);
  assert.deepEqual(f, { total: 5, active: 3, converted: 1, declined: 1, convertedPct: 20, pipeline: 150 });
  assert.deepEqual(Q.funnel([], []), { total: 0, active: 0, converted: 0, declined: 0, convertedPct: 0, pipeline: 0 });
});

test('saving needs a project, adds at the top, and keeps what the editor does not show', () => {
  assert.deepEqual(Q.saveItem(LIST(), { project: '  ' }, {}), { ok: false, error: 'project_required' });
  const added = Q.saveItem(LIST(), { project: ' Lamp ', priority: 'nonsense', estimatedValue: -3 },
    { newId: 'W9', now: NOW });
  assert.equal(added.list[0].id, 'W9');
  assert.equal(added.item.project, 'Lamp');
  assert.equal(added.item.priority, 'normal');
  assert.equal(added.item.estimatedValue, 0);
  assert.equal(added.item.addedAt, NOW);
  assert.equal(added.item.status, 'active');

  const form = [{ id: 'W5', project: 'From the form', phone: '+966500000000', consent: { ok: true }, estValue: 40 }];
  const edited = Q.saveItem(form, { project: 'From the form', estimatedValue: 80, status: 'reminded' }, { id: 'W5' });
  assert.equal(edited.item.phone, '+966500000000');
  assert.deepEqual(edited.item.consent, { ok: true });
  assert.equal(edited.item.estValue, 80, 'the form\'s spelling is read first, so it moves too');
  assert.equal(Q.funnel(edited.list, []).pipeline, 80);
  assert.deepEqual(Q.saveItem(form, { project: 'x' }, { id: 'gone' }), { ok: false, error: 'gone' });
});

test('promoting moves the enquiry into the history as converted', () => {
  const out = Q.promote(LIST(), [], 'W1', NOW);
  assert.deepEqual(out.list.map((w) => w.id), ['W2', 'W3', 'W4']);
  assert.equal(out.history.length, 1);
  assert.equal(out.history[0].status, 'converted');
  assert.equal(out.history[0].convertedAt, NOW);
  assert.equal(out.item.status, 'active', 'the item handed back is as it was');
  assert.equal(Q.promote(LIST(), [], 'nope', NOW), null);
});

test('reminded and declined', () => {
  const r = Q.markReminded(LIST(), 'W1', NOW).find((w) => w.id === 'W1');
  assert.equal(r.status, 'reminded');
  assert.equal(r.reminderSentAt, NOW);
  assert.equal(Q.decline(LIST(), 'W1').find((w) => w.id === 'W1').status, 'declined');
});

test('the customer: named, matched by name or phone, else a new record', () => {
  const clients = [{ id: 'C1', nameEn: 'Sara', phone: '+9665' }, { id: 'C2', nameAr: 'خالد' }];
  assert.deepEqual(Q.resolveClient({ clientId: 'C2' }, clients, 'N'), { clientId: 'C2', created: null });
  assert.deepEqual(Q.resolveClient({ clientName: ' sara ' }, clients, 'N'), { clientId: 'C1', created: null });
  assert.deepEqual(Q.resolveClient({ clientName: 'Someone', phone: '+9665' }, clients, 'N'), { clientId: 'C1', created: null });
  assert.deepEqual(Q.resolveClient({ clientName: 'خالد' }, clients, 'N'), { clientId: 'C2', created: null });
  const made = Q.resolveClient({ clientName: 'Noor', email: 'n@x.test' }, clients, 'CLI-1');
  assert.deepEqual(made, { clientId: 'CLI-1', created: { id: 'CLI-1', nameEn: 'Noor', nameAr: '', phone: '', email: 'n@x.test' } });
  assert.deepEqual(Q.resolveClient({ project: 'x' }, clients, 'N'), { clientId: null, created: null });
});

test('the new job\'s note carries what the enquiry said', () => {
  assert.equal(Q.promotionNote({ project: 'Vase', notes: 'Tall, blue', phone: '+1', material: 'PLA' }),
    'Tall, blue\nPhone: +1\nMaterial: PLA');
  assert.equal(Q.promotionNote({ project: 'Vase', notes: 'Vase' }), '');
});

test('the desktop list runs the shared rules', () => {
  const fs = require('node:fs');
  const src = fs.readFileSync(require.resolve('../renderer/waiting-list.js'), 'utf8');
  for (const call of ['Q().visible(', 'Q().saveItem(', 'Q().promote(', 'Q().funnel(', 'Q().resolveClient(']) {
    assert.ok(src.includes(call), `renderer/waiting-list.js no longer calls ${call}`);
  }
  const html = fs.readFileSync(require.resolve('../renderer/index.html'), 'utf8');
  assert.ok(html.indexOf('../lib/intake-queue.js') > 0 && html.indexOf('../lib/intake-queue.js') < html.indexOf('"waiting-list.js"'),
    'the module must load before the list that uses it');
});
