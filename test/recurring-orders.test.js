'use strict';
/**
 * A standing order is one rule, not two.
 *
 * `renderer/clients.js` created recurring jobs from two functions that both ran
 * at every boot: `checkRecurringOrders` on the due day, and
 * `patchRecurringOrdersWithLeadDays` up to `leadDays` early. They guarded
 * against each other and they did not agree about what the job looked like.
 * The lift to `lib/recurring-orders.js` is proven the way every lift here is:
 * BOTH originals are copied below verbatim — the clock frozen, the globals they
 * read supplied — run in the order boot ran them over generated books, and
 * compared field by field with the rule.
 *
 * The comparison normalises exactly the fields the lift changed ON PURPOSE,
 * and a separate test shows the two originals disagreeing on them, because a
 * fix for a divergence that cannot be demonstrated is not a fix.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const RealDate = globalThis.Date;
require('../lib/pricing.js');
require('../lib/working-week.js');
require('../lib/subscriptions.js');
require('../lib/order-new.js');
const R = require('../lib/recurring-orders.js');

/* ── The clock, and the globals the originals read ─────────────────────────
   `Date` is shadowed for this module so `new Date()` in the copied code is the
   frozen instant; a dated construction still works. */
const FROZEN = new RealDate('2026-09-16T10:30:00'); // local time, a Wednesday
class Date extends RealDate {
  constructor(...args) { super(...(args.length ? args : [FROZEN.getTime()])); }
}
const TODAY = '2026-09-16';

let clients, printLog, settings;
let sideEffects;
const saveAll = () => sideEffects.push('save');
const renderKanban = () => sideEffects.push('kanban');
const renderLogs = () => sideEffects.push('logs');
const renderDashboard = () => sideEffects.push('dashboard');
const toast = (msg) => sideEffects.push('toast:' + msg);
const t = (key, vars) => key + (vars ? JSON.stringify(vars) : '');

// renderer/util.js
function localDateStr(d = new Date()) {
  const y = d.getFullYear(), m = String(d.getMonth() + 1).padStart(2, '0'), day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}
// renderer/invoicing.js, minus its saveAll()
function nextInvoiceNumber() {
  const currentYear = new Date().getFullYear();
  if ((settings.invNumYear || currentYear) !== currentYear) {
    settings.invNumYear = currentYear;
    settings.invNumNext = 1;
  }
  const prefix = settings.invNumPrefix || 'INV';
  const seq4 = String(settings.invNumNext || 1).padStart(4, '0');
  const fmt = settings.invNumFormat || '{prefix}-{year}-{seq4}';
  const result = fmt.replace('{prefix}', prefix).replace('{year}', currentYear).replace('{seq4}', seq4);
  settings.invNumNext = (settings.invNumNext || 1) + 1;
  settings.invNumYear = currentYear;
  return result;
}

/* ── ORIGINAL 1: renderer/clients.js, checkRecurringOrders, copied verbatim ── */
/** Advance a recurring nextDue by one cycle. Never throws — KhaytSubscriptions
 *  rejects unknown intervals, so we validate first and fall back to day math. */
function advanceRecurringDate(nextDue, interval, intervalDays) {
  const VALID = ['daily', 'weekly', 'biweekly', 'monthly', 'quarterly', 'yearly'];
  if (typeof KhaytSubscriptions !== 'undefined' && VALID.includes(interval)) {
    try { return KhaytSubscriptions.nextRunDate(nextDue, interval); } catch (e) { /* fall through */ }
  }
  const next = new Date(nextDue + 'T00:00:00');
  next.setDate(next.getDate() + ((intervalDays && intervalDays[interval]) || 30));
  return localDateStr(next);
}

function checkRecurringOrders() {
  const today = localDateStr();
  const INTERVAL_DAYS = { weekly: 7, biweekly: 14, monthly: 30, quarterly: 91 };
  let created = 0;

  clients.forEach(client => {
    const rec = client.recurring;
    if (!rec?.enabled || rec.paused || !rec.nextDue || rec.nextDue > today) return;
    // Stop after the end date (if set): disable so it no longer recurs.
    if (rec.endDate && rec.nextDue > rec.endDate) { rec.enabled = false; return; }

    // Use most recent completed order for this client as a template
    const template = printLog.find(o => o.clientId === client.id && o.status === 'completed');
    if (!template) return;

    // Check if an order was already created for this cycle — prevents duplicates
    // when patchRecurringOrdersWithLeadDays also runs on boot
    // Must happen BEFORE consuming the invoice number to avoid wasting sequence numbers
    const alreadyCreated = printLog.some(o =>
      o.clientId === client.id && o.recurringCycle === rec.nextDue);
    if (alreadyCreated) return;

    const now = new Date();
    const invoiceNum = nextInvoiceNumber();
    const seq = String(settings.invNumNext - 1).padStart(4, '0');
    const id = `${settings.invPrefix || 'INV'}-${now.getFullYear()}-${seq}`;

    printLog.unshift({
      ...template,
      parts: template.parts ? template.parts.map(p => ({ ...p })) : [],
      id,
      invoiceNum,
      invoiceNumber: invoiceNum,
      date: today,
      timestamp: now.toISOString(),
      status: 'pending',
      paymentStatus: 'unpaid',
      paidAmount: 0,
      paymentMethod: null,
      paidAt: null,
      printPhotos: [],
      notes: '',
      dueDate: null,
      priority: false,
      materialDeducted: false,
      actualPrintTime: null,
      actualWeight: null,
      quoteSentAt: null,
      quoteExpiresAt: null,
      quoteAcceptedAt: null,
      deliveredAt: null,
      attachedFiles: [],
      recurringCycle: rec.nextDue,
    });
    created++;

    // Advance one cycle (calendar-safe; never throws on a bad interval).
    rec.nextDue = advanceRecurringDate(rec.nextDue, rec.interval, INTERVAL_DAYS);
    if (rec.endDate && rec.nextDue > rec.endDate) rec.enabled = false;
  });

  if (created > 0) {
    saveAll();
    renderKanban(); renderLogs(); renderDashboard();
    toast(t('rec.created', { n: created }), 'success', 4500);
  }
}

/* ── ORIGINAL 2: renderer/clients.js, patchRecurringOrdersWithLeadDays, verbatim ── */
function patchRecurringOrdersWithLeadDays() {
  // Wrap the existing checkRecurringOrders to also respect leadDays
  // This runs at startup after loadAll() to check for orders due within leadDays
  const today = localDateStr();
  const INTERVAL_DAYS = { weekly: 7, biweekly: 14, monthly: 30, quarterly: 91 };
  let created = 0;

  clients.forEach(client => {
    const rec = client.recurring;
    if (!rec?.enabled || rec.paused || !rec.nextDue) return;
    if (rec.endDate && rec.nextDue > rec.endDate) { rec.enabled = false; return; }
    // Don't double-create: checkRecurringOrders() runs just before this on boot and
    // may have already created today's recurring order for this client (a different
    // cycle key), so skip any client that already got a recurring order today.
    if (printLog.some(o => o.clientId === client.id && o.recurringCycle && o.date === today)) return;
    const leadDays = rec.leadDays || 0;
    const triggerDate = new Date(rec.nextDue + 'T00:00:00');
    triggerDate.setDate(triggerDate.getDate() - leadDays);
    const triggerStr = localDateStr(triggerDate);
    if (triggerStr > today) return;

    // Check if an order was already created for this cycle (any status — prevents duplicate on re-completion)
    const alreadyCreated = printLog.some(o =>
      o.clientId === client.id && o.recurringCycle === rec.nextDue);
    if (alreadyCreated) return;

    // Find template: use specific templateOrderId or last completed order
    const template = rec.templateOrderId
      ? printLog.find(o => o.id === rec.templateOrderId)
      : printLog.find(o => o.clientId === client.id && o.status === 'completed');
    if (!template) return;

    const now = new Date();
    const invoiceNum = nextInvoiceNumber();
    const seq = String(settings.invNumNext - 1).padStart(4, '0');
    const id = `${settings.invPrefix || 'INV'}-${now.getFullYear()}-${seq}`;
    printLog.unshift({
      ...template,
      parts: template.parts ? template.parts.map(p => ({ ...p })) : [],
      id,
      invoiceNum,
      invoiceNumber: invoiceNum,
      date: today,
      timestamp: now.toISOString(),
      status: rec.cloneStatus || 'pending',
      paymentStatus: 'unpaid',
      paidAmount: 0,
      paymentMethod: null,
      paidAt: null,
      printPhotos: [],
      notes: '',
      dueDate: rec.nextDue,
      priority: false,
      materialDeducted: false,
      actualPrintTime: null,
      actualWeight: null,
      quoteSentAt: null,
      quoteExpiresAt: null,
      quoteAcceptedAt: null,
      deliveredAt: null,
      attachedFiles: [],
      comments: [],
      recurringCycle: rec.nextDue,
    });
    created++;

    // Advance one cycle (calendar-safe; never throws on a bad interval).
    rec.nextDue = advanceRecurringDate(rec.nextDue, rec.interval, INTERVAL_DAYS);
    if (rec.endDate && rec.nextDue > rec.endDate) rec.enabled = false;
  });

  if (created > 0) {
    saveAll(); renderKanban(); renderLogs(); renderDashboard();
    toast(t('rec.created', { n: created }), 'success', 4500);
  }
}

/* ── Generated books ──────────────────────────────────────────────────────── */

function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];
const dayOffset = (days) => {
  const d = new RealDate(FROZEN.getTime()); d.setDate(d.getDate() + days); return localDateStr(d);
};

/** A book: a few customers, some with schedules, and jobs newest first. */
function book(seed, { chosenTemplates = false, recurringToday = false } = {}) {
  const r = rng(seed);
  const cl = [];
  const orders = [];
  let n = 0;
  const count = 1 + Math.floor(r() * 4);
  for (let i = 0; i < count; i++) {
    const id = 'CLI-' + i;
    const done = [];
    for (let j = 0, jobs = Math.floor(r() * 4); j < jobs; j++) {
      const status = pick(r, ['completed', 'completed', 'pending', 'delivered', 'cancelled']);
      const o = {
        id: 'ORD-' + (n++), clientId: id, status, date: dayOffset(-10 - j),
        project: 'Job ' + n, price: 100 + j, parts: [{ name: 'part', qty: 1 }],
        paidAmount: 50, paymentStatus: 'partial', printPhotos: ['x'], notes: 'old',
        dueDate: dayOffset(-3), priority: true, materialDeducted: true, actualPrintTime: 3,
        actualWeight: 40, quoteSentAt: 'q', quoteExpiresAt: 'e', quoteAcceptedAt: 'a',
        deliveredAt: 'd', attachedFiles: ['f'], comments: [{ text: 'hi' }],
      };
      orders.push(o);
      if (status === 'completed') done.push(o.id);
    }
    const client = { id, nameEn: 'Customer ' + i };
    if (r() < 0.8) {
      const nextDue = dayOffset(Math.floor(r() * 9) - 4);            // -4 .. +4 days
      client.recurring = {
        enabled: r() < 0.85, interval: pick(r, ['weekly', 'biweekly', 'monthly', 'quarterly', 'daily', 'odd']),
        nextDue: r() < 0.9 ? nextDue : '',
        paused: r() < 0.15,
        endDate: r() < 0.3 ? dayOffset(Math.floor(r() * 9) - 4) : null,
      };
      if (r() < 0.5) client.recurring.leadDays = Math.floor(r() * 5);
      if (r() < 0.3) client.recurring.cloneStatus = pick(r, ['pending', 'printing']);
      if (chosenTemplates && done.length && r() < 0.5) client.recurring.templateOrderId = pick(r, done);
      // A cycle that already has its job.
      if (r() < 0.2 && client.recurring.nextDue) {
        orders.push({ id: 'ORD-' + (n++), clientId: id, status: 'cancelled', date: dayOffset(-1),
                      recurringCycle: client.recurring.nextDue });
      }
      if (recurringToday && r() < 0.5) {
        orders.push({ id: 'ORD-' + (n++), clientId: id, status: 'pending', date: TODAY,
                      recurringCycle: dayOffset(-30) });
      }
    }
    cl.push(client);
  }
  orders.sort((a, b) => b.date.localeCompare(a.date));
  return { clients: cl, orders, settings: { invNumNext: 1 + Math.floor(r() * 50), invNumYear: 2026, invPrefix: pick(r, ['INV', 'F']) } };
}

const deep = (v) => JSON.parse(JSON.stringify(v));

/** The originals as boot ran them: the due-day pass, then the early pass. */
function original(b) {
  clients = deep(b.clients); printLog = deep(b.orders); settings = deep(b.settings); sideEffects = [];
  checkRecurringOrders();
  patchRecurringOrdersWithLeadDays();
  return { clients, printLog, settings, sideEffects };
}

function lifted(b) {
  const cl = deep(b.clients), orders = deep(b.orders), st = deep(b.settings);
  const out = R.run(cl, orders, { settings: st, now: new Date() });
  return { clients: cl, printLog: orders, settings: st, created: out.created };
}

/**
 * The fields the lift changed on purpose, taken off the ORIGINAL's due-day
 * jobs so the rest can be compared exactly. The early pass already wrote all
 * three; the due-day pass wrote none of them, and that is the divergence.
 */
function normalise(orders, clientsBefore) {
  for (const o of orders) {
    if (!o.recurringCycle || o.date !== TODAY) continue;
    if (o.comments !== undefined && o.dueDate === o.recurringCycle) continue;   // the early pass's shape
    const rec = (clientsBefore.find(c => c.id === o.clientId) || {}).recurring || {};
    o.dueDate = o.recurringCycle;
    o.comments = [];
    o.status = rec.cloneStatus || 'pending';
  }
  return orders;
}

test('the rule creates what the two originals created, over generated books', () => {
  let created = 0, checked = 0;
  for (let seed = 1; seed <= 600; seed++) {
    const b = book(seed);
    const was = original(b);
    const now = lifted(b);
    assert.deepEqual(now.clients, was.clients, `seed ${seed}: the schedules moved differently`);
    assert.deepEqual(now.settings, was.settings, `seed ${seed}: the invoice counter differs`);
    assert.deepEqual(now.printLog, normalise(was.printLog, b.clients), `seed ${seed}: the jobs differ`);
    created += now.created.length; checked++;
  }
  assert.ok(created > 100, `only ${created} jobs created across ${checked} books — the generator is not reaching the rule`);
});

test('a chosen template is honoured on the due day too — where the originals disagreed', () => {
  // ONE schedule, two days. The shop chose ORD-A as the template; the last
  // completed job is ORD-B.
  const a = { id: 'ORD-A', clientId: 'C', status: 'completed', date: '2026-08-01', project: 'the standing order', parts: [] };
  const b = { id: 'ORD-B', clientId: 'C', status: 'completed', date: '2026-09-01', project: 'something else', parts: [] };
  const mk = (nextDue) => ({
    clients: [{ id: 'C', recurring: { enabled: true, interval: 'monthly', nextDue, leadDays: 3, templateOrderId: 'ORD-A', cloneStatus: 'printing' } }],
    orders: [b, a], settings: { invNumNext: 7, invNumYear: 2026 },
  });

  // Opened the day OF: the original's first pass fired.
  const onTheDay = original(mk(TODAY));
  // Opened the day BEFORE: only the early pass could fire.
  const dayBefore = original(mk(dayOffset(1)));
  const jobOnTheDay = onTheDay.printLog[0], jobDayBefore = dayBefore.printLog[0];
  assert.equal(jobOnTheDay.project, 'something else', 'the due-day original ignored the chosen template');
  assert.equal(jobDayBefore.project, 'the standing order');
  assert.equal(jobOnTheDay.dueDate, null, 'the due-day original gave the job no due date');
  assert.equal(jobDayBefore.dueDate, dayOffset(1));
  assert.equal(jobOnTheDay.status, 'pending', 'the due-day original ignored cloneStatus');
  assert.equal(jobDayBefore.status, 'printing');
  assert.equal(jobOnTheDay.comments, undefined);
  assert.deepEqual(jobDayBefore.comments, []);

  // The rule: the same job either day.
  for (const nextDue of [TODAY, dayOffset(1)]) {
    const out = lifted(mk(nextDue));
    const job = out.printLog[0];
    assert.equal(job.project, 'the standing order');
    assert.equal(job.dueDate, nextDue);
    assert.equal(job.recurringCycle, nextDue);
    assert.equal(job.status, 'printing');
    assert.deepEqual(job.comments, []);
  }
});

test('a customer whose earlier cycle was created today still gets a cycle that is due', () => {
  // The original early pass skipped ANY customer with a recurring job dated
  // today — a guard against its twin, not a rule. With one rule the guard is
  // the cycle itself.
  const done = { id: 'ORD-1', clientId: 'C', status: 'completed', date: '2026-08-01', parts: [] };
  const earlier = { id: 'ORD-2', clientId: 'C', status: 'pending', date: TODAY, recurringCycle: '2026-08-16' };
  const b = { clients: [{ id: 'C', recurring: { enabled: true, interval: 'monthly', nextDue: TODAY } }],
              orders: [earlier, done], settings: { invNumNext: 1, invNumYear: 2026 } };
  const out = lifted(b);
  assert.equal(out.created.length, 1);
  assert.equal(out.created[0].recurringCycle, TODAY);
  // And not twice.
  const again = R.run(out.clients, out.printLog, { settings: out.settings, now: new Date() });
  assert.equal(again.created.length, 0);
});

test('the job is the template with the last run taken off it', () => {
  const template = {
    id: 'ORD-9', clientId: 'C', status: 'completed', date: '2026-08-01', project: 'Monthly brackets',
    parts: [{ name: 'bracket', qty: 12, unitCost: 3 }], price: 240, machineId: 'M1', currency: 'SAR',
    paidAmount: 240, paymentStatus: 'paid', paymentMethod: 'cash', paidAt: 'x', printPhotos: ['p'],
    notes: 'left at the desk', dueDate: '2026-08-03', priority: true, materialDeducted: true,
    actualPrintTime: 9, actualWeight: 300, quoteSentAt: 'q', quoteExpiresAt: 'e', quoteAcceptedAt: 'a',
    deliveredAt: 'd', attachedFiles: ['f'], comments: [{ text: 'thanks' }], invoiceNum: 'INV-2026-0003',
  };
  const settings = { invNumNext: 12, invNumYear: 2026, invPrefix: 'INV' };
  const job = R.clone(template, { settings, now: new Date(), recurring: { nextDue: TODAY }, cycle: TODAY });
  assert.equal(job.id, 'INV-2026-0012');
  assert.equal(job.invoiceNum, 'INV-2026-0012');
  assert.equal(job.invoiceNumber, 'INV-2026-0012');
  assert.equal(settings.invNumNext, 13, 'the counter moved, and the caller must save it');
  assert.equal(job.date, TODAY);
  assert.equal(job.timestamp, FROZEN.toISOString());
  // Kept: the standing order itself.
  assert.equal(job.project, 'Monthly brackets');
  assert.deepEqual(job.parts, template.parts);
  assert.notEqual(job.parts, template.parts, 'the parts are copied, not shared');
  assert.notEqual(job.parts[0], template.parts[0]);
  assert.equal(job.price, 240);
  assert.equal(job.machineId, 'M1');
  assert.equal(job.clientId, 'C');
  // Reset: everything the last run wrote.
  assert.equal(job.status, 'pending');
  assert.equal(job.paymentStatus, 'unpaid');
  assert.equal(job.paidAmount, 0);
  assert.equal(job.paymentMethod, null);
  assert.equal(job.paidAt, null);
  assert.deepEqual(job.printPhotos, []);
  assert.equal(job.notes, '');
  assert.equal(job.dueDate, TODAY);
  assert.equal(job.priority, false);
  assert.equal(job.materialDeducted, false);
  assert.equal(job.actualPrintTime, null);
  assert.equal(job.actualWeight, null);
  assert.equal(job.quoteSentAt, null);
  assert.equal(job.deliveredAt, null);
  assert.deepEqual(job.attachedFiles, []);
  assert.deepEqual(job.comments, []);
  assert.equal(job.recurringCycle, TODAY);
  assert.equal(template.status, 'completed', 'the template is untouched');
});

test('the year rolls the counter, as the invoice rule says it does', () => {
  const settings = { invNumNext: 40, invNumYear: 2025 };
  const job = R.clone({ id: 'x', parts: [] }, { settings, now: new Date(), cycle: TODAY });
  assert.equal(job.id, 'INV-2026-0001');
  assert.equal(settings.invNumYear, 2026);
});

test('what is due, and what is not', () => {
  const done = (id, clientId) => ({ id, clientId, status: 'completed', date: '2026-08-01', parts: [] });
  const orders = [done('D1', 'A'), done('D2', 'B'), done('D3', 'C'), done('D4', 'D'), done('D5', 'E'),
                  { id: 'X', clientId: 'F', status: 'cancelled', date: '2026-09-10', recurringCycle: TODAY }, done('D6', 'F')];
  const clients = [
    { id: 'A', recurring: { enabled: true, interval: 'weekly', nextDue: TODAY } },                 // due
    { id: 'B', recurring: { enabled: true, interval: 'weekly', nextDue: dayOffset(1) } },          // tomorrow
    { id: 'C', recurring: { enabled: true, interval: 'weekly', nextDue: dayOffset(2), leadDays: 2 } }, // early, due
    { id: 'D', recurring: { enabled: true, interval: 'weekly', nextDue: TODAY, paused: true } },   // paused
    { id: 'E', recurring: { enabled: true, interval: 'weekly', nextDue: TODAY, endDate: '2026-09-01' } }, // over
    { id: 'F', recurring: { enabled: true, interval: 'weekly', nextDue: TODAY } },                 // cycle exists, cancelled
    { id: 'G', recurring: { enabled: true, interval: 'weekly', nextDue: TODAY } },                 // nothing to copy
    { id: 'H', recurring: { enabled: false, interval: 'weekly', nextDue: TODAY } },
    { id: 'I' },
  ];
  const { effects } = R.due(clients, orders, { now: new Date() });
  assert.deepEqual(effects.map(e => e.kind + ':' + e.client.id), ['create:A', 'create:C', 'stop:E']);
  assert.equal(effects[0].template.id, 'D1');
  assert.equal(effects[1].cycle, dayOffset(2));
  // Read-only.
  assert.equal(orders.length, 7);
  assert.equal(clients[4].recurring.enabled, true);
});

test('run moves each schedule on one cycle and stops one past its end', () => {
  const done = { id: 'D', clientId: 'A', status: 'completed', date: '2026-08-01', parts: [] };
  const clients = [
    { id: 'A', recurring: { enabled: true, interval: 'monthly', nextDue: TODAY, endDate: '2026-10-01' } },
  ];
  const orders = [done];
  const settings = { invNumNext: 1, invNumYear: 2026 };
  const out = R.run(clients, orders, { settings, now: new Date() });
  assert.equal(out.created.length, 1);
  assert.equal(orders[0], out.created[0], 'the new job is at the FRONT of the caller\'s own array');
  assert.equal(clients[0].recurring.nextDue, '2026-10-16');
  assert.equal(clients[0].recurring.enabled, false, 'the next cycle is past the end date, so it stops');
  assert.deepEqual(out.notices, [{ code: 'rec.created', n: 1 }]);
  // Three months behind: one now, the next at the next run.
  const behind = [{ id: 'B', recurring: { enabled: true, interval: 'monthly', nextDue: '2026-06-16' } }];
  const bOrders = [{ id: 'E', clientId: 'B', status: 'completed', date: '2026-05-01', parts: [] }];
  assert.equal(R.run(behind, bOrders, { settings, now: new Date() }).created.length, 1);
  assert.equal(behind[0].recurring.nextDue, '2026-07-16');
  assert.equal(R.run(behind, bOrders, { settings, now: new Date() }).created.length, 1);
  assert.equal(behind[0].recurring.nextDue, '2026-08-16');
});

test('advancing is calendar-safe, and an interval the calendar does not know still moves', () => {
  assert.equal(R.advance('2026-01-31', 'monthly'), '2026-02-28');
  assert.equal(R.advance('2026-01-01', 'biweekly'), '2026-01-15');
  assert.equal(R.advance('2026-01-01', 'quarterly'), '2026-04-01');
  assert.equal(R.advance('2026-01-01', 'odd'), '2026-01-31', 'thirty days, the fallback the renderer used');
  assert.equal(R.advance('2026-01-01', 'weekly'), '2026-01-08');
});

test('the trigger day is leadDays before the cycle, never after', () => {
  assert.equal(R.triggerDay({ nextDue: '2026-09-20', leadDays: 4 }), '2026-09-16');
  assert.equal(R.triggerDay({ nextDue: '2026-09-20' }), '2026-09-20');
  assert.equal(R.triggerDay({ nextDue: '2026-09-20', leadDays: -3 }), '2026-09-20');
  assert.equal(R.triggerDay({ nextDue: '2026-09-20', leadDays: 'x' }), '2026-09-20');
});
