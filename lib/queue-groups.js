'use strict';
(function () {

/**
 * Grouping for the production queue's list view — pure selector.
 *
 * The queue's job is scanning: "what needs me, what's running, what's next".
 * A kanban answers a different question — "what do I move along" — and makes
 * you sweep seven columns to answer the first one. So the list groups by the
 * state of the work rather than by the column it lives in, and pulls anything
 * blocked out to the top regardless of which status it holds.
 *
 * Kanban is not replaced; it stays a toggle. This module only decides what the
 * list shows, so both views read the same orders through tested logic.
 *
 * Side-effect free and clock-injected, like lib/attention.js, whose machine
 * state it reuses so "blocked" means the same thing on both screens.
 */

/** Statuses the queue treats as live work, in the order the list shows them. */
const GROUPS = [
  { key: 'attention', statuses: null },                 // cross-cutting, see below
  { key: 'running', statuses: ['printing'] },
  { key: 'finishing', statuses: ['post', 'qc'] },
  { key: 'queued', statuses: ['pending', 'on_hold'] },
  { key: 'done', statuses: ['completed', 'delivered'], collapsed: true },
];

const DAY_MS = 86400000;

function startOfDay(now) {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

function parseDay(s) {
  if (!s || typeof s !== 'string') return null;
  const ms = new Date(s + 'T00:00:00').getTime();
  return Number.isFinite(ms) ? ms : null;
}

function num(v) {
  const n = +v;
  return Number.isFinite(n) ? n : 0;
}

/**
 * Is this order blocked — overdue, or sitting on a machine that has stopped?
 * "Stopped" is machineState's definition, so a printer that merely missed a
 * poll never drags its job into the attention group.
 */
function blockedReason(order, ctx) {
  if (!order) return null;
  const due = parseDay(order.dueDate);
  if (due !== null && due < ctx.today) {
    return { kind: 'overdue', daysLate: Math.round((ctx.today - due) / DAY_MS) };
  }
  if (order.machineId && ctx.downMachines.has(order.machineId)) {
    return { kind: 'machine_down', machineId: order.machineId };
  }
  return null;
}

/**
 * @param {object} input
 * @param {object[]} [input.orders]        already location-scoped
 * @param {object[]} [input.machines]      already location-scoped
 * @param {object}   [input.statusCache]   machineStatusCache
 * @param {number}   [input.now]           injected clock
 * @param {boolean}  [input.money]         include money aggregates (business modes only)
 * @param {function} [input.revenueOf]     order -> base revenue; defaults to `price`
 * @returns {{groups: Array, footer: object}}
 */
function groupQueue(input) {
  const inp = input || {};
  const orders = Array.isArray(inp.orders) ? inp.orders : [];
  const machines = Array.isArray(inp.machines) ? inp.machines : [];
  const cache = inp.statusCache || {};
  const now = Number.isFinite(inp.now) ? inp.now : Date.now();
  const wantMoney = inp.money !== false;
  const revenueOf = typeof inp.revenueOf === 'function' ? inp.revenueOf : (o) => num(o && o.price);

  // Machines that have genuinely stopped, via the shared resolver.
  const machineState = (typeof globalThis !== 'undefined' && globalThis.KhaytAttention)
    ? globalThis.KhaytAttention.machineState
    : (typeof require === 'function' ? require('./attention.js').machineState : null);
  const downMachines = new Set();
  if (machineState) {
    for (const m of machines) {
      if (!m) continue;
      const st = machineState(m, cache[m.id]);
      if (st === 'offline' || st === 'error') downMachines.add(m.id);
    }
  }

  const ctx = { today: startOfDay(now), downMachines };
  const byKey = new Map(GROUPS.map((g) => [g.key, []]));
  const statusGroup = new Map();
  for (const g of GROUPS) {
    for (const s of (g.statuses || [])) statusGroup.set(s, g.key);
  }

  for (const o of orders) {
    if (!o || o.voidedAt) continue;
    if (o.status === 'quote') continue;          // quotes have their own section
    const home = statusGroup.get(o.status);
    if (!home) continue;                          // unknown status: not this view's problem
    // Blocked work leaves its status group and leads the list — but finished
    // work cannot be "blocked", so `done` is never pulled forward.
    const reason = home === 'done' ? null : blockedReason(o, ctx);
    if (reason) {
      byKey.get('attention').push({ order: o, reason });
    } else {
      byKey.get(home).push({ order: o, reason: null });
    }
  }

  // Longest-overdue first inside attention; everything else keeps due-date order.
  byKey.get('attention').sort((a, b) => {
    const al = a.reason.kind === 'overdue' ? a.reason.daysLate : Infinity;
    const bl = b.reason.kind === 'overdue' ? b.reason.daysLate : Infinity;
    if (al !== bl) return bl - al;
    return String(a.order.id).localeCompare(String(b.order.id));
  });
  for (const g of GROUPS) {
    if (g.key === 'attention') continue;
    byKey.get(g.key).sort((a, b) =>
      (a.order.dueDate || '~').localeCompare(b.order.dueDate || '~')
      || String(a.order.id).localeCompare(String(b.order.id)));
  }

  const aggregate = (rows) => {
    const agg = { count: rows.length, hours: 0 };
    for (const r of rows) agg.hours += num(r.order.printTime);
    agg.hours = Math.round(agg.hours * 10) / 10;
    if (wantMoney) {
      let money = 0;
      for (const r of rows) money += revenueOf(r.order);
      agg.money = Math.round(money * 100) / 100;
    }
    return agg;
  };

  const groups = GROUPS.map((g) => ({
    key: g.key,
    collapsed: !!g.collapsed,
    items: byKey.get(g.key),
    aggregate: aggregate(byKey.get(g.key)),
  }));

  // Footer answers the question a shop actually gets asked: how much work is
  // outstanding, what is it worth, and when can I promise the next slot.
  const openRows = groups
    .filter((g) => g.key !== 'done')
    .flatMap((g) => g.items);
  const footer = aggregate(openRows);
  footer.nextFreeAt = nextMachineFree(machines, cache, orders, now);
  return { groups, footer };
}

/**
 * When does a machine next come free? Prefers live telemetry (timeRemaining),
 * falling back to the order's estimate. Null when nothing is printing — i.e.
 * something is free right now, which the UI should say rather than showing a time.
 */
function nextMachineFree(machines, cache, orders, now) {
  if (!Array.isArray(machines) || !machines.length) return null;
  const busy = [];
  for (const m of machines) {
    if (!m) continue;
    const entry = cache[m.id];
    const job = (orders || []).find((o) => o && o.status === 'printing' && o.machineId === m.id);
    if (!entry && !job) return null;                       // this machine is free now
    let remainingMs = null;
    if (entry && !entry.error && Number.isFinite(+entry.timeRemaining)) {
      remainingMs = Math.max(0, +entry.timeRemaining * 1000);
    } else if (job && num(job.printTime) > 0) {
      const started = new Date(job.printingStartedAt || job.timerStart || now).getTime();
      const total = num(job.printTime) * 3600000;
      remainingMs = Math.max(0, started + total - now);
    }
    if (remainingMs === null) return null;                 // idle machine
    busy.push(remainingMs);
  }
  if (!busy.length) return null;
  return now + Math.min(...busy);
}

const api = { GROUPS, groupQueue, nextMachineFree, blockedReason };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytQueueGroups = api;

})();
