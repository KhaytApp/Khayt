'use strict';
(function (global) {

/**
 * Kits: several printed jobs that are one physical object.
 *
 * A figure printed as Head, Hand, Body and Legs is four jobs and four print-log
 * entries, and Khayt has no idea they are the same thing. "What did that figure
 * cost me" is arithmetic across four rows, done by hand, and nobody does it.
 *
 * NOT the BOM assembly in lib/assembly.js. That is one ORDER holding several
 * parts plus non-printed components, gated on QC — a thing you sell. This is a
 * grouping ACROSS orders, over work already done. The two can coexist on the
 * same shop and mean different things, which is why this does not reuse the word.
 *
 * Why across orders rather than merging them into one multi-part order: actuals
 * (`actualPrintTime`, `actualWeight`) live on the ORDER and nowhere else — no
 * part in this codebase carries its own measurement. Folding four jobs into one
 * order would replace four measured numbers with one, which is exactly the data
 * the estimator calibrates from. Grouping keeps every measurement intact.
 *
 * Pure: no DOM, no fs, no clock.
 */

// `+null` is 0 and `+''` is 0, so the obvious one-liner turns "never measured"
// into "measured, and it was zero" — which is the single bug this whole module
// exists to avoid. Absent must stay absent all the way to the caller.
const num = (v) => {
  if (v === null || v === undefined || v === '' || typeof v === 'boolean') return null;
  const n = +v;
  return Number.isFinite(n) ? n : null;
};
const str = (v) => String(v == null ? '' : v).trim();

/** Statuses whose numbers are real. A cancelled job's figures are not the kit's. */
const COUNTED = new Set(['completed', 'delivered']);

/**
 * Total a kit's jobs.
 *
 * The trap this exists to avoid: summing `actualPrintTime` across entries where
 * some are null yields a number that LOOKS like the kit's total and silently
 * omits whatever was never measured. So the count of what went into each total
 * is returned beside it, and a caller that shows the total without the count is
 * the bug. `measuredOf` is not decoration.
 *
 * Cost is only summed within one currency. Two currencies in a kit is a shop
 * mid-migration, and 12 SAR + 3 EUR = 15 of nothing.
 */
function rollup(entries) {
  const list = (Array.isArray(entries) ? entries : []).filter((e) => e && COUNTED.has(str(e.status)));
  const out = {
    jobs: list.length,
    estHours: 0, estGrams: 0,
    actualHours: 0, actualGrams: 0,
    cost: 0, currency: null, mixedCurrency: false,
    measuredTime: 0, measuredWeight: 0, costed: 0,
  };
  const currencies = new Set();
  for (const e of list) {
    const est = num(e.printTime); if (est !== null) out.estHours += est;
    const at = num(e.actualPrintTime);
    if (at !== null) { out.actualHours += at; out.measuredTime += 1; }
    const aw = num(e.actualWeight);
    if (aw !== null) { out.actualGrams += aw; out.measuredWeight += 1; }
    // The slicer's own weight, summed only where a job carries one, so estGrams
    // and actualGrams are comparable over the same jobs.
    for (const p of (Array.isArray(e.parts) ? e.parts : [])) {
      const pw = num(p && p.printWeight); if (pw !== null) out.estGrams += pw;
    }
    const c = num(e.costBasis);
    if (c !== null) {
      const cur = str(e.currency) || null;
      if (cur) currencies.add(cur);
      out.cost += c; out.costed += 1;
    }
  }
  out.mixedCurrency = currencies.size > 1;
  out.currency = currencies.size === 1 ? [...currencies][0] : null;
  if (out.mixedCurrency) out.cost = null;      // refuse rather than add nonsense
  // Round only at the edges; the sums above stay exact.
  out.estHours = +out.estHours.toFixed(2);
  out.actualHours = +out.actualHours.toFixed(2);
  out.estGrams = +out.estGrams.toFixed(2);
  out.actualGrams = +out.actualGrams.toFixed(2);
  if (out.cost !== null) out.cost = +out.cost.toFixed(2);
  return out;
}

/**
 * How far the estimate was off across the kit, or null when there is nothing
 * honest to compare.
 *
 * Returns null unless EVERY counted job was measured. A kit where three of
 * four are measured has a real per-job story but no kit-level delta — the
 * estimate covers four jobs and the actual covers three, and dividing one by the
 * other invents a number.
 */
function accuracy(r) {
  if (!r || !r.jobs || r.measuredTime !== r.jobs) return null;
  const out = { time: null, weight: null };
  if (r.estHours > 0) out.time = +(((r.actualHours - r.estHours) / r.estHours) * 100).toFixed(1);
  if (r.estGrams > 0 && r.measuredWeight === r.jobs) {
    out.weight = +(((r.actualGrams - r.estGrams) / r.estGrams) * 100).toFixed(2);
  }
  return out;
}

/**
 * Group print-log entries into kits.
 *
 * A kitId with no definition still produces a kit rather than vanishing —
 * a deleted definition must not take the shop's history off the screen with it.
 *
 * @param {Array} entries      printLog, newest-first (order is preserved within a kit)
 * @param {Array} defs         store.kits — [{id, name}]
 * @returns {{kits: Array, ungrouped: Array}}
 */
function groupByKit(entries, defs) {
  const byId = new Map();
  for (const d of (Array.isArray(defs) ? defs : [])) {
    const id = str(d && d.id); if (id) byId.set(id, str(d.name));
  }
  const order = [];
  const groups = new Map();
  const ungrouped = [];
  for (const e of (Array.isArray(entries) ? entries : [])) {
    const id = str(e && e.kitId);
    if (!id) { if (e) ungrouped.push(e); continue; }
    if (!groups.has(id)) { groups.set(id, []); order.push(id); }
    groups.get(id).push(e);
  }
  const kits = order.map((id) => {
    const list = groups.get(id);
    const r = rollup(list);
    return {
      id,
      // An orphaned kit keeps a name derived from its work rather than showing
      // a raw id, which reads as corruption to anyone looking at it.
      name: byId.get(id) || str(list[0] && list[0].project) || id,
      orphaned: !byId.has(id),
      entries: list,
      rollup: r,
      accuracy: accuracy(r),
    };
  });
  return { kits, ungrouped };
}

/** Is this kit finished — every job in it counted and measured? */
function isComplete(kit) {
  const r = kit && kit.rollup;
  return !!(r && r.jobs > 0 && r.measuredTime === r.jobs && r.measuredWeight === r.jobs);
}

/* ── Filing work into a kit, after the fact ──────────────────────────────────
 *
 * Kits were always meant to be retroactive — the module header says so — but
 * both places that made one asked the shop to TYPE the name, including when the
 * kit already existed. That is exactly backwards for the case this is for: you
 * print three parts, file them as "Dragon", print the fourth next week, and now
 * have to reproduce a string from memory. Get it right and it works; get it
 * slightly wrong and you silently own two kits called almost the same thing,
 * with the rollup split between them — which is the one failure both call sites'
 * comments say they exist to prevent, defeated by a typo.
 *
 * So the rule lives here once, and the callers pick from what already exists.
 */

/** Fold a name to what two people typing the same kit would agree on. */
function nameKey(v) { return str(v).toLowerCase().replace(/\s+/g, ' '); }

/**
 * Edit distance, capped — enough to tell "Dragn" from "Dragon" and no more.
 *
 * Bounded because it exists to ask a question, not to decide anything: past a
 * couple of edits two names are simply different, and the work of measuring how
 * different is wasted.
 */
function editDistance(a, b, cap) {
  const s = nameKey(a); const t = nameKey(b);
  if (s === t) return 0;
  if (Math.abs(s.length - t.length) > cap) return cap + 1;
  let prev = Array.from({ length: t.length + 1 }, (_, i) => i);
  for (let i = 1; i <= s.length; i++) {
    const cur = [i];
    let best = i;
    for (let j = 1; j <= t.length; j++) {
      cur[j] = Math.min(
        prev[j] + 1, cur[j - 1] + 1,
        prev[j - 1] + (s[i - 1] === t[j - 1] ? 0 : 1),
      );
      if (cur[j] < best) best = cur[j];
    }
    if (best > cap) return cap + 1;      // no row below can come back under it
    prev = cur;
  }
  return prev[t.length];
}

/**
 * Which kit does this typed name mean?
 *
 * An exact match (ignoring case and repeated spaces) IS that kit — reusing it
 * rather than minting a second one is the whole point. Anything else is a new
 * kit, and the caller gets `created: true` so it can say so.
 *
 * @returns {{id: string, name: string, created: boolean}|null} null for an empty name
 */
function resolveKitName(name, defs, newId) {
  const clean = str(name);
  if (!clean) return null;
  const list = Array.isArray(defs) ? defs : [];
  const key = nameKey(clean);
  const hit = list.find((k) => k && nameKey(k.name) === key);
  if (hit) return { id: str(hit.id), name: str(hit.name), created: false };
  const mint = typeof newId === 'function' ? newId : null;
  return {
    id: mint ? str(mint()) : 'KIT-' + str(clean).replace(/[^a-z0-9]+/gi, '-').toLowerCase(),
    name: clean,
    created: true,
  };
}

/**
 * Existing kits whose names are one or two edits from this one.
 *
 * Offered so a near-miss can be caught BEFORE it becomes a second kit. It never
 * decides: two genuinely different kits can be one character apart ("Leg L" and
 * "Leg R"), and silently merging those would move somebody's jobs on a guess.
 *
 * Short names get a tighter budget, because at three characters two edits is a
 * different word rather than a slip.
 */
function similarKitNames(name, defs) {
  const clean = str(name);
  if (!clean) return [];
  const cap = nameKey(clean).length <= 4 ? 1 : 2;
  const out = [];
  for (const k of (Array.isArray(defs) ? defs : [])) {
    const other = str(k && k.name);
    if (!other || nameKey(other) === nameKey(clean)) continue;   // exact is a match, not a near-miss
    const d = editDistance(clean, other, cap);
    if (d <= cap) out.push({ id: str(k.id), name: other, distance: d });
  }
  return out.sort((a, b) => a.distance - b.distance || a.name.localeCompare(b.name));
}

/**
 * Kit definitions no job points at any more.
 *
 * Pulling the last job out of a kit leaves a name attached to nothing, and a
 * list of those is clutter the shop has to read past every time it files
 * something. Reported rather than deleted here — this module does not own the
 * store — and deliberately NOT the mirror of `orphaned`: that is a job whose
 * definition is gone, this is a definition whose jobs are.
 */
function emptyKitIds(entries, defs) {
  const used = new Set();
  for (const e of (Array.isArray(entries) ? entries : [])) {
    const id = str(e && e.kitId);
    if (id) used.add(id);
  }
  return (Array.isArray(defs) ? defs : [])
    .map((k) => str(k && k.id))
    .filter((id) => id && !used.has(id));
}

const api = {
  groupByKit, rollup, accuracy, isComplete, COUNTED,
  resolveKitName, similarKitNames, emptyKitIds, nameKey, editDistance,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytPrintKits = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
