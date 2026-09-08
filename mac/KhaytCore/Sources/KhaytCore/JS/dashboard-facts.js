'use strict';

(function (global) {
/**
 * The facts every dashboard layout needs, derived once.
 *
 * WHAT THIS IS FOR, AND WHAT IT IS DELIBERATELY NOT
 *
 * Khayt ships eight themes and six of them replace the dashboard with their own
 * screen. That is on purpose and it is worth keeping: Flow is a kanban board,
 * Meridian is a schedule, Foreman is a wallboard, Command and Vivid lead with
 * figures, Workbench leads with the work. They are not arrangements of one
 * dashboard, they are different ways of looking at a shop, and forcing them onto
 * a shared set of blocks would throw away the reason they exist.
 *
 * So this shares no markup at all. What it shares is the layer underneath —
 * "which orders are late", "what is still owed", "how many printers are live",
 * "does this shop show money" — because those questions have exactly one right
 * answer per shop, and six layouts were each working it out for themselves.
 *
 * THE BUG THAT PROVES THE POINT
 *
 * Flow already knew to borrow rather than re-derive; its own comment says so:
 * "Ids the shared attention engine considers overdue — borrowed, not
 * re-derived." It then borrowed it wrongly, twice over:
 *
 *   const attn = KhaytAttention.selectAttention({…}) || [];
 *   for (const a of attn) if (a.orderId) ids.add(a.orderId);
 *
 * `selectAttention` returns `{count, items}`, not an array, so `for…of` threw
 * `TypeError: attn is not iterable` on every render — swallowed by the theme's
 * own defensive catch. And had it been iterable, it read `a.orderId` while the
 * items carry `a.id`. Both wrong, silently: no Flow card has ever shown a "late"
 * chip and the "{n} late" alert has never once appeared.
 *
 * That is what a shared derivation prevents. Not the markup — the markup was
 * fine. The question.
 *
 * PURE, AND INJECTED RATHER THAN GLOBAL
 *
 * The renderer answers these from globals (`printLog`, `machines`, `settings`,
 * `payStatus`, `orderOwedBase`). This module takes them as arguments so it can be
 * tested without a DOM, the same way `printer-status` and `duet` are.
 */

const asArray = (v) => (Array.isArray(v) ? v : []);
const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);

/**
 * Ids of orders the shared attention engine considers overdue.
 *
 * One place, because "late" appearing on a card in one theme and not in another
 * for the same order is the kind of disagreement a shop notices and cannot
 * explain.
 *
 * @param {object} attention  the KhaytAttention module (injected; optional)
 * @param {object} input      {machines, orders, statusCache, now}
 * @returns {Set<string>}
 */
function selectAttentionSafely(attention, input) {
  const select = attention && typeof attention.selectAttention === 'function'
    ? attention.selectAttention : null;
  if (!select) return { count: 0, items: [] };
  let result;
  try {
    result = select(input || {});
  } catch (e) {
    // Attention is advisory: a board still renders without it. Unlike the catch
    // this replaces, nothing here is expected to throw, so a throw is a defect
    // rather than a supported path — but it must not take a screen down.
    return { count: 0, items: [] };
  }
  // `{count, items}` is the documented shape. A bare array is tolerated so a
  // future change to the engine degrades rather than silently emptying every
  // board — which is exactly how the Flow bug stayed invisible.
  const items = Array.isArray(result) ? result : asArray(result && result.items);
  return { count: Number.isFinite(result && result.count) ? result.count : items.length, items };
}

function lateOrderIds(attention, input) {
  const ids = new Set();
  const items = (attention && attention.items && !attention.selectAttention)
    ? asArray(attention.items)                       // already-resolved result
    : selectAttentionSafely(attention, input).items; // a module to call
  for (const a of items) {
    if (!a) continue;
    if (a.kind && a.kind !== 'order') continue;
    const id = a.id != null ? a.id : a.orderId;
    if (id != null) ids.add(id);
  }
  return ids;
}

/** Statuses that mean a job is somewhere on the floor rather than finished. */
const ACTIVE_STATUSES = ['pending', 'printing', 'post', 'qc', 'on_hold'];

/**
 * Everything the layouts ask about the current shop, answered once.
 *
 * @param {object} input
 *   orders       already location-scoped (the caller owns the filter, because
 *                the filter itself is a renderer concern)
 *   machines     likewise
 *   statusCache  machineStatusCache
 *   settings     for the mode
 *   now          epoch ms
 *   attention    the KhaytAttention module
 *   tiers        the KhaytTiers module, for showsBusiness
 *   money        {payStatus(o) -> string, owedFor(o) -> number}
 */
function dashboardFacts(input) {
  const inp = input || {};
  const orders = asArray(inp.orders);
  const machines = asArray(inp.machines);
  const cache = inp.statusCache || {};
  const now = Number.isFinite(inp.now) ? inp.now : Date.now();
  const settings = inp.settings || {};

  // "Does this shop deal in money" gates revenue, receivables and quotes in
  // every layout. Five of six themes asked KhaytTiers and one guessed.
  const showsMoney = (inp.tiers && typeof inp.tiers.showsBusiness === 'function')
    ? !!inp.tiers.showsBusiness(settings.mode)
    : settings.mode !== 'enthusiast';

  const byStatus = {};
  for (const o of orders) {
    const s = (o && o.status) || 'unknown';
    byStatus[s] = (byStatus[s] || 0) + 1;
  }

  const active = orders.filter((o) => o && ACTIVE_STATUSES.includes(o.status));
  const printing = orders.filter((o) => o && o.status === 'printing');

  // ONE call to the attention engine, with the arguments the engine documents,
  // and the result handed to every layout that needs it. Command and Foreman
  // both need the full item list — machines as well as orders — so exposing only
  // the late ids would have left them calling the engine themselves, which is
  // the call site the Flow bug lived at.
  /* Nozzle wear is INJECTED the same way `attention` and `tiers` are: this
   * module is pure and must not reach for a global.
   *
   * It has to come through here rather than through each theme, because the
   * dashboard's own maintenance section — where overdue nozzles used to be
   * listed — is markup no shipped theme renders. Every theme replaces
   * renderDashboard with its own and none of them draws `.dash-section`, so the
   * warning lived on the machine card and nowhere on the screen a shop leaves
   * open. All six themes come through dashboardFacts, so this is the one place
   * that reaches all of them. */
  const wearMod = inp.nozzleWear;
  const nozzleWear = (wearMod && typeof wearMod.nozzleWear === 'function')
    ? (m) => wearMod.nozzleWear(orders, m, inp.settings || {})
    : undefined;
  /* The shelf, injected the same way. `lowStock` decides what "low" means and
   * lives in `order-deduction` so the banner, the badge, the reorder list and
   * the deduction cannot disagree; this hands the engine that one function
   * rather than a threshold, for the same reason. A caller that passes no
   * inventory gets no stock warnings — not an error, just silence. */
  const deduction = inp.deduction;
  const lowStock = (deduction && typeof deduction.isLowStock === 'function')
    ? (item) => deduction.isLowStock(item, settings)
    : undefined;
  /* And what each item is COUNTED IN, so the panel can write the right word
   * after the figure. Injected like the rest; a caller that passes no units
   * module gets grams, which is what every item was before there were any. */
  const unitsMod = inp.units;
  const unitOf = (unitsMod && typeof unitsMod.unitOf === 'function')
    ? (item) => unitsMod.unitOf(item)
    : undefined;
  const attn = selectAttentionSafely(inp.attention, {
    machines, orders, statusCache: cache, now, nozzleWear,
    inventory: asArray(inp.inventory), lowStock, unitOf,
  });
  const late = lateOrderIds(attn);

  // Owed is only meaningful where money is shown, and asking for it in a shop
  // that has none would put a zero on screen that reads like a fact.
  let owed = null;
  const m = inp.money;
  if (showsMoney && m && typeof m.payStatus === 'function' && typeof m.owedFor === 'function') {
    owed = 0;
    for (const o of orders) {
      try { if (m.payStatus(o) !== 'paid') owed += num(m.owedFor(o)); } catch (e) { /* one bad order must not blank the strip */ }
    }
  }

  // Fleet state, read the way the attention engine reads it so a printer cannot
  // be "live" on one screen and "offline" on another.
  let live = 0, offline = 0;
  for (const mach of machines) {
    const st = mach && cache[mach.id];
    const state = String((st && st.state) || '').toLowerCase();
    if (!st) continue;
    if (state === 'offline' || state === 'error') offline += 1;
    else live += 1;
  }

  return {
    orders,
    machines,
    showsMoney,
    byStatus,
    active,
    activeCount: active.length,
    printing,
    printingCount: printing.length,
    attn,
    lateIds: late,
    lateCount: late.size,
    isLate: (o) => !!(o && late.has(o.id)),
    owed,
    fleet: { total: machines.length, live, offline, idle: Math.max(0, machines.length - live - offline) },
    now,
  };
}

const api = { dashboardFacts, lateOrderIds, selectAttentionSafely, ACTIVE_STATUSES };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytDashboardFacts = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
