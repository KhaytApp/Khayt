'use strict';
(function () {
/**
 * Plate nesting / batch planner — pack queued jobs onto printer "plates"
 * (build sessions) so the shop can run efficient batches instead of one job at a
 * time. Pure (no DOM): the renderer supplies normalized jobs + capacity limits.
 *
 * Strategy: group by material (you can't mix filaments on one FDM plate), then
 * First-Fit-Decreasing bin-packing by print time, also respecting a max grams
 * per plate. A single job larger than a plate's limits gets its own plate and is
 * flagged `oversize` (so it's surfaced, never silently dropped).
 */

const DEFAULTS = { maxHours: 24, maxGrams: 1000, groupByMaterial: true };

function cfg(opts) {
  const o = opts || {};
  const pick = (v, d) => (Number.isFinite(+v) && +v > 0 ? +v : d);
  return {
    maxHours: pick(o.maxHours, DEFAULTS.maxHours),
    maxGrams: pick(o.maxGrams, DEFAULTS.maxGrams),
    groupByMaterial: o.groupByMaterial !== false,
  };
}

function materialKey(j) {
  return String((j && j.material) || '').trim().toUpperCase() || '—';
}

/**
 * @param {Array<{id,project?,hours?,grams?,material?}>} jobs
 * @param {{maxHours?:number,maxGrams?:number,groupByMaterial?:boolean}} [opts]
 * @returns {{plates:Array, totalJobs:number, totalPlates:number}}
 */
function planPlates(jobs, opts) {
  const c = cfg(opts);
  const list = (Array.isArray(jobs) ? jobs : []).map((j) => ({
    id: j.id,
    project: j.project || j.id,
    hours: Math.max(0, +j.hours || 0),
    grams: Math.max(0, +j.grams || 0),
    material: j.material || '',
  }));

  // Bucket by material (or one shared bucket).
  const buckets = new Map();
  for (const j of list) {
    const key = c.groupByMaterial ? materialKey(j) : '*';
    if (!buckets.has(key)) buckets.set(key, []);
    buckets.get(key).push(j);
  }

  const plates = [];
  for (const [key, group] of buckets) {
    // First-Fit-Decreasing by print time.
    group.sort((a, b) => b.hours - a.hours);
    const open = []; // plates currently being filled for this material
    for (const j of group) {
      const oversize = j.hours > c.maxHours || j.grams > c.maxGrams;
      if (oversize) { plates.push(makePlate(key, [j], true)); continue; }
      let placed = false;
      for (const p of open) {
        if (p.hours + j.hours <= c.maxHours && p.grams + j.grams <= c.maxGrams) {
          p.jobs.push(j); p.hours += j.hours; p.grams += j.grams; placed = true; break;
        }
      }
      if (!placed) { const p = makePlate(key, [j], false); open.push(p); plates.push(p); }
    }
  }
  // Round accumulated totals for display.
  for (const p of plates) { p.hours = Math.round(p.hours * 10) / 10; p.grams = Math.round(p.grams); }
  // Fullest plates first.
  plates.sort((a, b) => (a.material < b.material ? -1 : a.material > b.material ? 1 : b.jobs.length - a.jobs.length));
  return { plates, totalJobs: list.length, totalPlates: plates.length };
}

function makePlate(material, jobs, oversize) {
  return {
    material: material === '*' ? '' : material,
    jobs: jobs.slice(),
    hours: jobs.reduce((s, j) => s + j.hours, 0),
    grams: jobs.reduce((s, j) => s + j.grams, 0),
    oversize: !!oversize,
  };
}

const api = { DEFAULTS, planPlates, materialKey };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPlateNesting = api;
})();
