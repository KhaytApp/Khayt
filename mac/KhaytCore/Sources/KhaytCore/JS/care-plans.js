'use strict';
(function () {

/**
 * Care plans: a ready-made maintenance schedule per printer brand and model,
 * and the parts buy list that follows from it.
 *
 * ── WHERE THE NUMBERS COME FROM ─────────────────────────────────────────────
 *
 * Every plan carries a `source`: the manufacturer's own maintenance page the
 * intervals were read from. A task the maker publishes no interval for is
 * either left out or, where the plan still needs it, takes the generic
 * starter interval from lib/maintenance.js and says so with
 * `source: 'starter'` on the task. A plan with no published guidance at all
 * is `source: 'starter'` as a whole. Nothing here is a guess dressed as a
 * maker's figure.
 *
 * Part lead times (`leadDays`) are NOT manufacturer data: they are a typical
 * shipping wait for a spare, used only to say "order by". A caller may pass
 * its own per-part lead days to `partsBuyList`.
 *
 * ── HOURS COME FROM JOBS ────────────────────────────────────────────────────
 *
 * Projection uses `KhaytMaintenance.hoursMeter` (completed jobs' printTime) and
 * `KhaytMaintenance.hoursPerDay`, never a typed meter reading.
 *
 * Pure: no clock, no I/O. `now` is always passed in.
 */

const MS_PER_DAY = 24 * 60 * 60 * 1000;

function maint() {
  const g = typeof globalThis !== 'undefined' ? globalThis : {};
  if (g.KhaytMaintenance) return g.KhaytMaintenance;
  // eslint-disable-next-line global-require
  return typeof require === 'function' ? require('./maintenance.js') : null;
}

function num(v, fallback = 0) {
  const n = +v;
  return Number.isFinite(n) ? n : fallback;
}

function str(v) { return String(v == null ? '' : v).trim(); }

/**
 * Parts a care task consumes. `leadDays` is a typical wait for a spare to
 * arrive — Khayt's assumption, not a maker's figure — and only sets the
 * order-by date. `unit` is what one `qty` counts.
 */
const PARTS = Object.freeze([
  { id: 'nozzle',        unit: 'pcs',    leadDays: 7 },
  { id: 'ptfe_tube',     unit: 'pcs',    leadDays: 7 },
  { id: 'carbon_filter', unit: 'pcs',    leadDays: 14 },
  { id: 'air_filter',    unit: 'pcs',    leadDays: 14 },
  { id: 'grease',        unit: 'tube',   leadDays: 7 },
  { id: 'oil',           unit: 'bottle', leadDays: 7 },
  { id: 'rail_lube',     unit: 'set',    leadDays: 14 },
  { id: 'fep_film',      unit: 'pcs',    leadDays: 7 },
  { id: 'resin_tank',    unit: 'pcs',    leadDays: 14 },
  { id: 'ipa',           unit: 'l',      leadDays: 3 },
].map(Object.freeze));

// The starter tasks (lib/maintenance.js STARTER_TASKS) a plan falls back on
// where the maker publishes no hours or days for a consumable that still has
// to be bought. Each carries `source: 'starter'`, so the app can say so.
const STARTER_NOZZLE = { id: 'nozzle', intervalHours: 500,  intervalDays: 0,   parts: [{ id: 'nozzle', qty: 1 }],    source: 'starter' };
const STARTER_PTFE   = { id: 'ptfe',   intervalHours: 1000, intervalDays: 180, parts: [{ id: 'ptfe_tube', qty: 1 }], source: 'starter' };

const STARTER_RESIN = [
  { id: 'fep',    intervalHours: 100, intervalDays: 0,   parts: [{ id: 'fep_film', qty: 1 }] },
  { id: 'vat',    intervalHours: 0,   intervalDays: 7,   parts: [] },
  { id: 'ipa',    intervalHours: 0,   intervalDays: 14,  parts: [{ id: 'ipa', qty: 1 }] },
  { id: 'wiring', intervalHours: 0,   intervalDays: 90,  parts: [] },
  { id: 'filter', intervalHours: 0,   intervalDays: 180, parts: [{ id: 'air_filter', qty: 1 }] },
];

/**
 * The catalogue. Intervals are copied from the `source` page (read Nov 2026);
 * the comment beside each says what the maker wrote. Rules used:
 *   - weekly = 7 days, monthly = 30, every three months = 90, six = 180;
 *   - a published RANGE takes its shorter end ("every 3-6 months" -> 90);
 *   - intervals given in spools, rolls, prints or layers are not converted
 *     (that needs an hours-per-spool figure no maker publishes) and are left
 *     out, as are condition-only checks ("when HMS prompts", "before every
 *     print").
 * `match` holds the names a machine record may use for the model.
 */
const PLANS = Object.freeze([
  {
    id: 'bambu-x1', brand: 'Bambu Lab', model: 'X1 series (X1C, X1E)', kind: 'fdm',
    match: ['X1 Carbon', 'X1C', 'X1E', 'X1'],
    source: 'https://wiki.bambulab.com/en/x1/maintenance/basic-maintenance',
    tasks: [
      // "checked once a month for any dust and particle buildup"
      { id: 'carbon_rods', intervalHours: 0, intervalDays: 30, parts: [] },
      // "checked and greased every three months"
      { id: 'leadscrew', intervalHours: 0, intervalDays: 90, parts: [{ id: 'grease', qty: 1 }] },
      // Y/Z linear rods "checked once a month"
      { id: 'rods', intervalHours: 0, intervalDays: 30, parts: [] },
      // Y/Z rods "should be anti-rust every three months"
      { id: 'rust', intervalHours: 0, intervalDays: 90, parts: [{ id: 'oil', qty: 1 }] },
      // "checking and cleaning the extruder gear assembly once a week"
      { id: 'extruder', intervalHours: 0, intervalDays: 7, parts: [] },
      // "checking the fans every week"
      { id: 'fans', intervalHours: 0, intervalDays: 7, parts: [] },
      // "every three months if the printer is used for about 8 hours a day"
      // (monthly for a production machine — tighten it for one)
      { id: 'filter', intervalHours: 0, intervalDays: 90, parts: [{ id: 'carbon_filter', qty: 1 }] },
      STARTER_NOZZLE, STARTER_PTFE,
    ],
  },
  {
    id: 'bambu-p1', brand: 'Bambu Lab', model: 'P1 series (P1P, P1S)', kind: 'fdm',
    match: ['P1S', 'P1P', 'P1'],
    source: 'https://wiki.bambulab.com/en/p1/maintenance/p1p-maintenance',
    tasks: [
      { id: 'carbon_rods', intervalHours: 0, intervalDays: 30, parts: [] },
      { id: 'leadscrew', intervalHours: 0, intervalDays: 90, parts: [{ id: 'grease', qty: 1 }] },
      { id: 'rods', intervalHours: 0, intervalDays: 30, parts: [] },
      // "should also have an anti-rust treatment every three months"
      { id: 'rust', intervalHours: 0, intervalDays: 90, parts: [{ id: 'oil', qty: 1 }] },
      { id: 'fans', intervalHours: 0, intervalDays: 7, parts: [] },
      STARTER_NOZZLE, STARTER_PTFE,
    ],
  },
  {
    id: 'bambu-a1', brand: 'Bambu Lab', model: 'A1', kind: 'fdm',
    match: ['A1'],
    source: 'https://wiki.bambulab.com/en/a1/maintenance/basic-maintenance',
    tasks: [
      // X and Y linear rails: "Every month ... Cleaning, Lubricant oil"
      { id: 'rods', intervalHours: 0, intervalDays: 30, parts: [{ id: 'oil', qty: 1 }] },
      // Z lead screws: "Every 3 months ... Lubricant grease"
      { id: 'leadscrew', intervalHours: 0, intervalDays: 90, parts: [{ id: 'grease', qty: 1 }] },
      // idler pulleys: "Every 3 months ... Lubricant oil"
      { id: 'pulleys', intervalHours: 0, intervalDays: 90, parts: [{ id: 'oil', qty: 1 }] },
      // fans: "Every week"
      { id: 'fans', intervalHours: 0, intervalDays: 7, parts: [] },
      // hotend heating assembly: "Every month"
      { id: 'hotend', intervalHours: 0, intervalDays: 30, parts: [] },
      STARTER_NOZZLE, STARTER_PTFE,
    ],
  },
  {
    id: 'bambu-a1-mini', brand: 'Bambu Lab', model: 'A1 mini', kind: 'fdm',
    match: ['A1 mini', 'A1mini'],
    source: 'https://wiki.bambulab.com/en/a1-mini/maintenance/period-maintenance',
    tasks: [
      // X, Y and Z rails: "Every month ... Lubricant oil"
      { id: 'rods', intervalHours: 0, intervalDays: 30, parts: [{ id: 'oil', qty: 1 }] },
      // Z lead screw: "Every 3 months ... Lubricant grease or oil"
      { id: 'leadscrew', intervalHours: 0, intervalDays: 90, parts: [{ id: 'grease', qty: 1 }] },
      { id: 'pulleys', intervalHours: 0, intervalDays: 90, parts: [{ id: 'oil', qty: 1 }] },
      { id: 'fans', intervalHours: 0, intervalDays: 7, parts: [] },
      { id: 'hotend', intervalHours: 0, intervalDays: 30, parts: [] },
      STARTER_NOZZLE, STARTER_PTFE,
    ],
  },
  {
    id: 'prusa-mk4', brand: 'Prusa', model: 'MK4 / MK4S / MK3.9', kind: 'fdm',
    match: ['MK4S', 'MK4', 'MK3.9S', 'MK3.9'],
    source: 'https://help.prusa3d.com/article/regular-printer-maintenance-mk4-s-mk3-9-s_419000',
    tasks: [
      // "every 200 hours of printing time": rods and bearings cleaned and
      // lubricated, belts checked, Nextruder gear cleaned
      { id: 'rods', intervalHours: 200, intervalDays: 0, parts: [{ id: 'grease', qty: 1 }] },
      { id: 'belts', intervalHours: 200, intervalDays: 0, parts: [] },
      { id: 'extruder', intervalHours: 200, intervalDays: 0, parts: [] },
      // connectors "every 600-800 hours of printing"
      { id: 'wiring', intervalHours: 600, intervalDays: 0, parts: [] },
      STARTER_NOZZLE, STARTER_PTFE,
    ],
  },
  {
    id: 'prusa-core-one', brand: 'Prusa', model: 'Core One', kind: 'fdm',
    match: ['Core One', 'CoreOne'],
    source: 'https://help.prusa3d.com/article/regular-printer-maintenance-core-one_829710',
    tasks: [
      // "every 200 hours of printing time": Y rods cleaned and lubed, X rail
      // cleaned, belts, fans and Nextruder
      { id: 'rods', intervalHours: 200, intervalDays: 0, parts: [{ id: 'grease', qty: 1 }] },
      { id: 'belts', intervalHours: 200, intervalDays: 0, parts: [] },
      { id: 'fans', intervalHours: 200, intervalDays: 0, parts: [] },
      { id: 'extruder', intervalHours: 200, intervalDays: 0, parts: [] },
      // "lubricating the linear rail every 3-6 months, using the dedicated
      // linear rail lubrication set"
      { id: 'rail', intervalHours: 0, intervalDays: 90, parts: [{ id: 'rail_lube', qty: 1 }] },
      { id: 'wiring', intervalHours: 600, intervalDays: 0, parts: [] },
      STARTER_NOZZLE, STARTER_PTFE,
    ],
  },
  {
    id: 'snapmaker-u1', brand: 'Snapmaker', model: 'U1', kind: 'fdm',
    match: ['Snapmaker U1', 'U1'],
    source: 'https://wiki.snapmaker.com/en/snapmaker_u1/troubleshooting/Core_Components_Maintenance_Guide',
    tasks: [
      // "Linear Shaft / Linear Bearing | Monthly | Cleaning, lubrication"
      { id: 'rods', intervalHours: 0, intervalDays: 30, parts: [{ id: 'grease', qty: 1 }] },
      // "X Carbon Rod Assembly | Monthly" (no grease on carbon rods)
      { id: 'carbon_rods', intervalHours: 0, intervalDays: 30, parts: [] },
      // "Lead Screw / Nut | Quarterly | Cleaning, lubrication"
      { id: 'leadscrew', intervalHours: 0, intervalDays: 90, parts: [{ id: 'grease', qty: 1 }] },
      // "Steel Pin / Steel Ball | Quarterly | Cleaning, lubrication"
      { id: 'coupling', intervalHours: 0, intervalDays: 90, parts: [{ id: 'grease', qty: 1 }] },
      // "Timing Belt | Monthly | Tension check, cleaning"
      { id: 'belts', intervalHours: 0, intervalDays: 30, parts: [] },
      // "Pogo pin | Every 4–6 months | Cleaning"
      { id: 'pogo', intervalHours: 0, intervalDays: 120, parts: [] },
      // Four toolheads, four nozzles.
      { ...STARTER_NOZZLE, parts: [{ id: 'nozzle', qty: 4 }] },
      { ...STARTER_PTFE, parts: [{ id: 'ptfe_tube', qty: 4 }] },
    ],
  },
  {
    id: 'creality-k1', brand: 'Creality', model: 'K1 / K1C / K1 Max', kind: 'fdm',
    match: ['K1 Max', 'K1Max', 'K1C', 'K1'],
    source: 'https://wiki.creality.com/en/k1-flagship-series/k1c/maintenance-tips',
    tasks: [
      // X, Y and Z rods "checked every 300 printing hours"
      { id: 'rods', intervalHours: 300, intervalDays: 0, parts: [] },
      // "The Y-axis should undergo rust prevention treatment every six months."
      { id: 'rust', intervalHours: 0, intervalDays: 180, parts: [{ id: 'oil', qty: 1 }] },
      // "Z-axis lead screws should be checked and lubricated every 300 printing hours."
      { id: 'leadscrew', intervalHours: 300, intervalDays: 0, parts: [{ id: 'grease', qty: 1 }] },
      // "checking the fans weekly"
      { id: 'fans', intervalHours: 0, intervalDays: 7, parts: [] },
      // "about 8 hours per day ... every three months" (monthly in production)
      { id: 'filter', intervalHours: 0, intervalDays: 90, parts: [{ id: 'carbon_filter', qty: 1 }] },
      // "vibration pattern optimization and automatic leveling detection every 300 printing hours"
      { id: 'selfcheck', intervalHours: 300, intervalDays: 0, parts: [] },
      STARTER_NOZZLE, STARTER_PTFE,
    ],
  },
  {
    id: 'creality-ender3-v3-ke', brand: 'Creality', model: 'Ender-3 V3 KE', kind: 'fdm',
    match: ['Ender-3 V3 KE', 'Ender3 V3 KE'],
    source: 'https://wiki.creality.com/en/ender-series/ender-3-v3-ke/maintenance',
    tasks: [
      // "replace the nozzle after every cumulative 500 hours of printing"
      { id: 'nozzle', intervalHours: 500, intervalDays: 0, parts: [{ id: 'nozzle', qty: 1 }] },
      // "every 500 cumulative hours ... lubricate the lead screws, optical
      // axes, and guide rail areas"
      { id: 'rods', intervalHours: 500, intervalDays: 0, parts: [{ id: 'grease', qty: 1 }] },
      { id: 'leadscrew', intervalHours: 500, intervalDays: 0, parts: [] },
      // "perform a self-check every 300 cumulative printing hours"
      { id: 'selfcheck', intervalHours: 300, intervalDays: 0, parts: [] },
      STARTER_PTFE,
    ],
  },
  {
    // Creality publishes no intervals for the Ender-3 V3 or V3 SE, so this
    // is the starter list (without the air filter an open frame has none of).
    id: 'creality-ender3-v3', brand: 'Creality', model: 'Ender-3 V3 / V3 SE', kind: 'fdm',
    match: ['Ender-3 V3 SE', 'Ender3 V3 SE', 'Ender-3 V3', 'Ender3 V3'],
    source: 'starter',
    tasks: [
      { id: 'plate', intervalHours: 50, intervalDays: 0, parts: [] },
      { id: 'belts', intervalHours: 200, intervalDays: 30, parts: [] },
      { id: 'rods', intervalHours: 200, intervalDays: 90, parts: [{ id: 'grease', qty: 1 }] },
      { id: 'leadscrew', intervalHours: 300, intervalDays: 90, parts: [{ id: 'grease', qty: 1 }] },
      { id: 'extruder', intervalHours: 200, intervalDays: 0, parts: [] },
      { id: 'nozzle', intervalHours: 500, intervalDays: 0, parts: [{ id: 'nozzle', qty: 1 }] },
      { id: 'ptfe', intervalHours: 1000, intervalDays: 180, parts: [{ id: 'ptfe_tube', qty: 1 }] },
      { id: 'fans', intervalHours: 300, intervalDays: 90, parts: [] },
      { id: 'wiring', intervalHours: 0, intervalDays: 90, parts: [] },
    ],
  },
  {
    id: 'formlabs-form3', brand: 'Formlabs', model: 'Form 3 / 3B', kind: 'resin',
    match: ['Form 3B', 'Form 3', 'Form3'],
    source: 'https://formlabs.com/support/Schedule-of-maintenance-Form-3/',
    tasks: [
      // optical window: "Monthly"
      { id: 'window', intervalHours: 0, intervalDays: 30, parts: [{ id: 'ipa', qty: 1 }] },
      // Resin tank: "Estimated lifetime for most applications: 600–800 hours
      // of printing" (https://formlabs.com/support/Resin-tank-lifetime-Form-3-Form-3B/).
      // Aggressive resins wear one out in 250 h or 75 days — tighten it for those.
      { id: 'tank', intervalHours: 600, intervalDays: 0, parts: [{ id: 'resin_tank', qty: 1 }] },
    ],
  },
  {
    // Elegoo publishes no replacement intervals: the starter resin list.
    id: 'elegoo-resin', brand: 'Elegoo', model: 'Saturn / Mars', kind: 'resin',
    match: ['Saturn', 'Mars'],
    source: 'starter',
    tasks: STARTER_RESIN,
  },
  {
    // Anycubic gives the FEP film as "about 30,000 layers", not hours or
    // days, so the starter resin list stands.
    id: 'anycubic-photon', brand: 'Anycubic', model: 'Photon Mono', kind: 'resin',
    match: ['Photon Mono', 'Photon'],
    source: 'starter',
    tasks: STARTER_RESIN,
  },
].map((p) => Object.freeze({ ...p, tasks: Object.freeze(p.tasks.map((t) => Object.freeze({ ...t }))) })));

const PLAN_BY_ID = Object.create(null);
for (const p of PLANS) PLAN_BY_ID[p.id] = p;
const PART_BY_ID = Object.create(null);
for (const p of PARTS) PART_BY_ID[p.id] = p;

function copyPlan(p) {
  return {
    id: p.id, brand: p.brand, model: p.model, kind: p.kind, source: p.source,
    tasks: p.tasks.map(copyTask),
  };
}

function copyTask(t) {
  return {
    id: t.id,
    intervalHours: num(t.intervalHours, 0),
    intervalDays: num(t.intervalDays, 0),
    parts: (t.parts || []).map((x) => ({ id: x.id, qty: num(x.qty, 1) })),
    source: t.source || null,
  };
}

/** Brands with at least one plan, in catalogue order. */
function brands() {
  const out = [];
  for (const p of PLANS) if (!out.includes(p.brand)) out.push(p.brand);
  return out;
}

/** The plans for one brand (copies). */
function plansFor(brand) {
  const b = str(brand).toLowerCase();
  return PLANS.filter((p) => p.brand.toLowerCase() === b).map(copyPlan);
}

/** Every plan (copies). */
function allPlans() { return PLANS.map(copyPlan); }

/** One plan by id, or null. */
function plan(id) {
  const p = PLAN_BY_ID[str(id)];
  return p ? copyPlan(p) : null;
}

/** One part by id, or null. */
function part(id) {
  const p = PART_BY_ID[str(id)];
  return p ? { ...p } : null;
}

/** Every part (copies). */
function parts() { return PARTS.map((p) => ({ ...p })); }

function squash(s) { return str(s).toLowerCase().replace(/[^a-z0-9]+/g, ''); }

/**
 * The plan a machine most likely is, from what its record says (`vendor`,
 * `printerModelName`, or its name). Null when nothing matches — a guess the
 * shop has to undo is worse than an empty picker.
 *
 * Matching is on each plan's `match` aliases, squashed to letters and digits,
 * longest alias first so "K1 Max" is not read as "K1".
 */
function matchPlan(vendor, model, name) {
  const hay = [vendor, model, name].map(squash).filter(Boolean);
  if (!hay.length) return null;
  const joined = hay.join(' ');
  let best = null;
  let bestLen = 0;
  for (const p of PLANS) {
    for (const alias of p.match || []) {
      const a = squash(alias);
      if (a.length > bestLen && hay.some((h) => h.includes(a) || joined.includes(a))) {
        best = p; bestLen = a.length;
      }
    }
  }
  return best ? best.id : null;
}

/**
 * What applying a plan to a machine would do, given the tasks it already has.
 *
 * An existing task is "the same task" when it carries the plan task's id as
 * `careTaskId`, or when its name equals one of `namesById[id]` (the names a
 * shop's app gives the catalogue ids, so a task added from the starter menu is
 * recognised). Case and surrounding spaces are ignored.
 *
 * @returns {{ add: object[], same: object[], differ: object[] }}
 *   add    — plan tasks the machine does not have;
 *   same   — matched, intervals already equal: { recordId, task };
 *   differ — matched, intervals differ: { recordId, task, hadHours, hadDays }.
 *   The plan's interval replaces the shop's only for `differ` rows the shop
 *   confirms (see `applyPlan`).
 */
function comparePlan(existing, machineId, planId, namesById) {
  const p = plan(planId);
  const out = { add: [], same: [], differ: [] };
  if (!p) return out;
  const mine = (Array.isArray(existing) ? existing : [])
    .filter((t) => t && typeof t === 'object' && str(t.machineId) === str(machineId));
  const names = namesById || {};
  const used = new Set();
  for (const task of p.tasks) {
    const wanted = [].concat(names[task.id] || []).map((n) => str(n).toLowerCase()).filter(Boolean);
    const hit = mine.find((t) => !used.has(t) && str(t.careTaskId) === task.id)
      || mine.find((t) => !used.has(t) && !str(t.careTaskId) && wanted.includes(str(t.name).toLowerCase()));
    if (!hit) { out.add.push(task); continue; }
    used.add(hit);
    const hadHours = num(hit.intervalHours, 0);
    const hadDays = num(hit.intervalDays, 0);
    const row = { recordId: str(hit.id), task };
    if (hadHours === task.intervalHours && hadDays === task.intervalDays) out.same.push(row);
    else out.differ.push({ ...row, hadHours, hadDays });
  }
  return out;
}

/**
 * Apply a plan to `tasks` (the whole machMaintTasks list). Returns a NEW list;
 * the input is not mutated.
 *
 * - Missing tasks are added, counted from now: `lastDoneHours` is the meter
 *   and `lastDoneAt` is `nowIso`, the same as a task typed in by hand.
 *   `newId(planTask)` (or the map `ids`) names each record; `nameOf(id)` (or
 *   the map `names`) gives its label.
 * - Matched tasks gain the link fields (careTaskId, carePlanId, parts) so the
 *   buy list knows their parts. Their intervals change ONLY when the record id
 *   is in `confirm` — and then without touching lastDone*, because a new
 *   interval is not a claim that the work was done.
 *
 * Fields the other app writes are kept as they are; new ones are optional.
 *
 * @returns {{ tasks: object[], added: string[], changed: string[] }}
 */
function applyPlan(tasks, opts) {
  opts = opts || {};
  const list = Array.isArray(tasks) ? tasks.slice() : [];
  const p = plan(opts.planId);
  if (!p) return { tasks: list, added: [], changed: [] };
  const cmp = comparePlan(list, opts.machineId, p.id, opts.namesById);
  const confirm = new Set((opts.confirm || []).map(str));
  // Functions from a JS caller, or plain maps from one that cannot pass a
  // function (the Mac): `names[id]` and `ids[id]`.
  const names = opts.names || {};
  const ids = opts.ids || {};
  const nameOf = typeof opts.nameOf === 'function' ? opts.nameOf
    : (id) => str([].concat(names[id] || [])[0]) || id;
  const newId = typeof opts.newId === 'function' ? opts.newId
    : (t) => str(ids[t.id]) || ('MTASK-' + str(opts.machineId) + '-' + t.id);
  const changed = [];
  const link = (task) => ({ careTaskId: task.id, carePlanId: p.id, parts: task.parts });
  for (const row of [...cmp.same, ...cmp.differ]) {
    const i = list.findIndex((t) => t && str(t.id) === row.recordId);
    if (i < 0) continue;
    const next = { ...list[i], ...link(row.task) };
    if (row.hadHours !== undefined && confirm.has(row.recordId)) {
      next.intervalHours = row.task.intervalHours > 0 ? row.task.intervalHours : null;
      next.intervalDays = row.task.intervalDays > 0 ? row.task.intervalDays : null;
    }
    if (JSON.stringify(next) !== JSON.stringify(list[i])) { list[i] = next; changed.push(row.recordId); }
  }
  const added = [];
  for (const task of cmp.add) {
    const id = String(newId(task));
    list.push({
      id,
      machineId: opts.machineId,
      name: String(nameOf(task.id)),
      intervalHours: task.intervalHours > 0 ? task.intervalHours : null,
      intervalDays: task.intervalDays > 0 ? task.intervalDays : null,
      lastDoneHours: Math.max(0, num(opts.meter, 0)),
      lastDoneAt: opts.nowIso,
      ...link(task),
    });
    added.push(id);
  }
  return { tasks: list, added, changed };
}

/** The parts a task consumes: its own `parts`, else its plan's, else none. */
function partsOf(task) {
  if (Array.isArray(task.parts) && task.parts.length) {
    return task.parts.filter((x) => x && PART_BY_ID[str(x.id)])
      .map((x) => ({ id: str(x.id), qty: Math.max(0, num(x.qty, 1)) || 1 }));
  }
  const p = PLAN_BY_ID[str(task.carePlanId)];
  const t = p && p.tasks.find((x) => x.id === str(task.careTaskId));
  return t ? (t.parts || []).map((x) => ({ id: x.id, qty: num(x.qty, 1) })) : [];
}

function isRetired(m) {
  return !!m && (m.status === 'retired' || !!str(m.retiredAt));
}

/**
 * The parts to buy: one row per part per task, for every task with parts
 * whose projected due date falls inside the horizon.
 *
 * @param {{ machines: object[], tasks: object[], jobs: object[], now: any,
 *           horizonDays?: number, windowDays?: number,
 *           leadDays?: Object<string, number> }} input
 * @returns {Array<{ partId, unit, qty, machineId, machineName, taskId, careTaskId,
 *                   taskName, dueAt, orderBy, leadDays, late, status, clock }>}
 *   sorted by orderBy (earliest first), then machine name, then part id.
 *   `late` is true when the order-by date has already passed.
 */
function partsBuyList(input) {
  input = input || {};
  const M = maint();
  if (!M) return [];
  const nowMs = input.now instanceof Date ? input.now.getTime()
    : (typeof input.now === 'number' ? input.now : Date.parse(input.now));
  if (!Number.isFinite(nowMs)) return [];
  const horizon = num(input.horizonDays, 90) > 0 ? num(input.horizonDays, 90) : 90;
  const win = num(input.windowDays, 30) > 0 ? num(input.windowDays, 30) : 30;
  const lead = input.leadDays || {};
  const machines = Array.isArray(input.machines) ? input.machines : [];
  const byId = new Map(machines.filter((m) => m && m.id != null && !isRetired(m)).map((m) => [String(m.id), m]));
  const jobs = Array.isArray(input.jobs) ? input.jobs : [];
  const meters = new Map();
  const rows = [];
  for (const task of Array.isArray(input.tasks) ? input.tasks : []) {
    if (!task || typeof task !== 'object') continue;
    const machine = byId.get(String(task.machineId));
    if (!machine) continue;
    const used = partsOf(task);
    if (!used.length) continue;
    const mid = String(machine.id);
    if (!meters.has(mid)) {
      meters.set(mid, { meter: M.hoursMeter(jobs, mid), rate: M.hoursPerDay(jobs, mid, nowMs, win) });
    }
    const { meter, rate } = meters.get(mid);
    const due = M.projectDue(task, meter, rate, nowMs);
    if (due.dueMs == null || due.dueMs > nowMs + horizon * MS_PER_DAY) continue;
    for (const u of used) {
      const pt = PART_BY_ID[u.id];
      const leadDays = Math.max(0, num(lead[u.id], pt.leadDays));
      const orderMs = due.dueMs - leadDays * MS_PER_DAY;
      rows.push({
        partId: u.id,
        unit: pt.unit,
        qty: u.qty,
        machineId: mid,
        machineName: str(machine.name),
        taskId: str(task.id),
        careTaskId: str(task.careTaskId) || null,
        taskName: str(task.name),
        dueAt: due.dueAt,
        orderBy: new Date(orderMs).toISOString(),
        orderByMs: orderMs,
        leadDays,
        late: orderMs < nowMs,
        status: due.status,
        clock: due.clock,
      });
    }
  }
  rows.sort((a, b) => (a.orderByMs - b.orderByMs)
    || a.machineName.localeCompare(b.machineName) || a.partId.localeCompare(b.partId));
  return rows.map(({ orderByMs, ...r }) => r);
}

/**
 * The same rows summed per part, for "how many nozzles do I order": total qty
 * and the earliest order-by date among them. Sorted by that date.
 */
function partsTotals(rows) {
  const by = new Map();
  for (const r of Array.isArray(rows) ? rows : []) {
    const had = by.get(r.partId);
    if (!had) by.set(r.partId, { partId: r.partId, unit: r.unit, qty: r.qty, orderBy: r.orderBy, late: r.late });
    else {
      had.qty += r.qty;
      if (r.orderBy < had.orderBy) had.orderBy = r.orderBy;
      had.late = had.late || r.late;
    }
  }
  return [...by.values()].sort((a, b) => (a.orderBy < b.orderBy ? -1 : a.orderBy > b.orderBy ? 1 : 0));
}

const api = {
  PLANS, PARTS,
  brands, plansFor, allPlans, plan, part, parts, matchPlan,
  comparePlan, applyPlan, partsOf, partsBuyList, partsTotals,
};

// Dual export: CommonJS (node tests) + global (renderer <script>, Mac bundle).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytCarePlans = api;

})();
