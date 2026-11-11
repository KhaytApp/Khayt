'use strict';
/**
 * A cancelled job is never late.
 *
 * Turki, Nov 11 2026: "canceled print still showing on dashboard as overdue".
 * His job INV-2026-0003 was cancelled on Nov 8 and due on Nov 9. A cancelled
 * job keeps its due date, and the rules that decide what is overdue left
 * 'cancelled' out of what is not live work: lib/attention.js `isOpenOrder` (the
 * attention list, and through it the dashboard's late count) and the desktop's
 * own filters, which excluded only finished jobs.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { selectAttention } = require('../lib/attention.js');
const KhaytAttention = require('../lib/attention.js');
const { dashboardFacts } = require('../lib/dashboard-facts.js');
const { buildShopContext } = require('../lib/ai-assistant.js');
const Reminder = require('../lib/payment-reminder.js');

const NOW = Date.parse('2026-11-11T09:00:00');
// The shape of Turki's job, with sample names.
const cancelled = { id: 'J-c', jobNumber: 'INV-2026-0003', project: 'Sample bracket', status: 'cancelled',
  cancelledAt: '2026-11-08T10:00:00.000Z', dueDate: '2026-11-09', price: 120, paidAmount: 0 };
const late = { id: 'J-l', project: 'Still late', status: 'pending', dueDate: '2026-11-09', price: 80, paidAmount: 0 };

test('a cancelled job past its due date is not in the attention list', () => {
  const got = selectAttention({ orders: [cancelled, late], now: NOW });
  assert.deepEqual(got.items.filter((i) => i.kind === 'order').map((i) => i.id), ['J-l']);
  assert.equal(selectAttention({ orders: [cancelled], now: NOW }).count, 0);
});

test('and not in the dashboard\'s late count', () => {
  const f = dashboardFacts({ orders: [cancelled, late], machines: [], statusCache: {}, now: NOW,
    attention: KhaytAttention, settings: { mode: 'business' } });
  assert.equal(f.lateCount, 1);
  assert.equal(f.isLate(cancelled), false);
  assert.equal(f.isLate(late), true);
});

test('nor in what the assistant is told is overdue or owed', () => {
  const ctx = buildShopContext({ printLog: [cancelled, late] }, { now: NOW });
  assert.deepEqual(ctx.overdue.map((o) => o.id), ['J-l']);
  assert.equal(ctx.overdueCount, 1);
});

test('nor is it chased for payment', () => {
  assert.equal(Reminder.isReminderEligible(cancelled, 120), false, 'whatever owed the caller passes');
  const withMilestone = { ...cancelled, milestoneInvoices: [{ id: 'M1', amount: 60, dueDate: '2026-11-01' }] };
  assert.deepEqual(Reminder.milestonesDue(withMilestone, NOW), []);
});

test('the desktop never treats "not finished" alone as "can be late"', () => {
  // A ratchet: every renderer line that pairs a due date with
  // `!KhaytOrderStatus.isFinished(…)` must also leave cancelled jobs out
  // (or use isOpen, which does). The dashboard's overdue list, the Logs
  // badge and tab count, the board's due chip and the desktop notifications
  // all read "not finished" as "live" and showed a cancelled job as overdue.
  const dir = path.join(__dirname, '../renderer');
  const files = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p); else if (e.name.endsWith('.js')) files.push(p);
  } };
  walk(dir);
  const holes = [];
  for (const f of files) {
    fs.readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
      if (/dueDate/.test(line) && /!KhaytOrderStatus\.isFinished\(/.test(line) && !/cancelled/.test(line)) {
        holes.push(`${path.relative(dir, f)}:${i + 1}`);
      }
    });
  }
  assert.deepEqual(holes, []);
});
