const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../renderer/app-helpers.js'); // defines prioritySortValue as a global, as in the app
const K = require('../renderer/kanban.js');
const { kanbanUrgencyScore } = K;

test('kanbanUrgencyScore ranks overdue before future due dates', () => {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const yesterday = new Date(today);
  yesterday.setDate(yesterday.getDate() - 1);
  const tomorrow = new Date(today);
  tomorrow.setDate(tomorrow.getDate() + 1);
  const fmt = (d) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

  const overdue = kanbanUrgencyScore({ dueDate: fmt(yesterday), printTime: 1 });
  const soon = kanbanUrgencyScore({ dueDate: fmt(tomorrow), printTime: 1 });
  const noDue = kanbanUrgencyScore({ printTime: 5 });

  assert.ok(overdue < soon);
  assert.ok(soon < noDue);
});

test('kanbanUrgencyScore treats due-today as most urgent among future dates', () => {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const fmt = (d) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const tomorrow = new Date(today);
  tomorrow.setDate(tomorrow.getDate() + 1);

  const dueToday = kanbanUrgencyScore({ dueDate: fmt(today), printTime: 1 });
  const dueTomorrow = kanbanUrgencyScore({ dueDate: fmt(tomorrow), printTime: 1 });
  assert.ok(dueToday < dueTomorrow);
});

test('M6: kanbanQueuePos is column-scoped (stale position ignored after a column move)', () => {
  const { kanbanQueuePos } = require('../renderer/kanban.js');
  // Order dragged to position 0 while in 'post'.
  const o = { queuePos: 0, queueCol: 'post' };
  assert.equal(kanbanQueuePos(o, 'post'), 0);        // honored in its own column
  assert.equal(kanbanQueuePos(o, 'pending'), 9999);  // ignored elsewhere → end of queue
  // No manual position → end.
  assert.equal(kanbanQueuePos({}, 'pending'), 9999);
});

/* ── manual drag order must survive in every column ─────────────────────── */

test('a manual reorder is honoured in every column, not just pending', () => {
  // The drop handler writes queuePos/queueCol for whichever column the card was
  // dropped in. The render sort used to read it back only for `pending`, so a drag
  // in the other five columns was written to disk and then visually reverted.
  for (const col of ['pending', 'on_hold', 'printing', 'post', 'qc', 'completed']) {
    const items = [
      { id: 'A', status: col, queueCol: col, queuePos: 2 },
      { id: 'B', status: col, queueCol: col, queuePos: 0 },
      { id: 'C', status: col, queueCol: col, queuePos: 1 },
    ];
    const order = K.sortColumnOrders(items, col).map(o => o.id);
    assert.deepEqual(order, ['B', 'C', 'A'], `drag order ignored in column: ${col}`);
  }
});

test('priority still outranks manual order', () => {
  const items = [
    { id: 'normal-first', status: 'qc', queueCol: 'qc', queuePos: 0, priorityLevel: 'normal' },
    { id: 'urgent-last', status: 'qc', queueCol: 'qc', queuePos: 9, priorityLevel: 'urgent' },
  ];
  assert.deepEqual(K.sortColumnOrders(items, 'qc').map(o => o.id), ['urgent-last', 'normal-first']);
});

test('a card dragged in a different column does not affect this one', () => {
  const items = [
    { id: 'A', status: 'qc', queueCol: 'printing', queuePos: 0 }, // stale: belongs to another column
    { id: 'B', status: 'qc', queueCol: 'qc', queuePos: 5 },
  ];
  // B has an explicit position in THIS column; A's position is for another column and
  // must fall back to the unpositioned sentinel rather than jumping to the front.
  assert.deepEqual(K.sortColumnOrders(items, 'qc').map(o => o.id), ['B', 'A']);
});
