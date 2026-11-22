'use strict';
(function (global) {

/**
 * Will this model go on that bed?
 *
 * ── WHY IT IS ITS OWN MODULE ──────────────────────────────────────────────
 *
 * The decision lived inside `mf-convert.js`, which is 1500 lines built on
 * Node's zlib and cannot be loaded anywhere but the main process. So the one
 * question a maker asks about a model before anything else — will it even fit
 * on my printer — could only be answered *during a conversion*, by the app that
 * can run a converter. The Mac app has every number it needs (a model's bounds
 * live in its `geometryKey`, a machine's bed in its record) and no way to ask.
 *
 * ── IT ANSWERS IN FACTS, NOT SENTENCES ────────────────────────────────────
 *
 * `fitWarnings` returned English prose — "Model footprint 555×529 mm is larger
 * than …" — which an Arabic shop would have been shown verbatim. A rule that
 * answers in one language is a rule only one app can use. This returns the
 * numbers and lets each app say them; `mf-convert` builds its own sentences
 * from these facts, so the converter's wording has not changed.
 *
 * PURE: numbers in, numbers out.
 */

/**
 * A millimetre of slack.
 *
 * Bed sizes are nominal and meshes carry floating-point bounds, so a model
 * measured at 270.0001 mm on a 270 mm bed is a rounding artefact rather than a
 * part that will not print. Inherited from `mf-convert.fitWarnings`, where it
 * has always been ±1, and kept identical so the converter's answers do not move.
 */
const SLACK = 1;

const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };

/**
 * @param {{x:number,y:number,z:number}} bounds  the model, in mm
 * @param {{x:number,y:number,z:number}} bed     the printer, in mm
 * @returns {{known: boolean, ok: boolean, footprint: boolean, height: boolean,
 *            rotated: boolean, over: {x:number,y:number,z:number}}}
 *   `known` false when either side did not say — an unmeasured model or a
 *   machine with no bed recorded is NOT a model that does not fit, and must
 *   never be shown as one.
 */
function check(bounds, bed) {
  const none = { known: false, ok: true, footprint: false, height: false,
                 rotated: false, over: { x: 0, y: 0, z: 0 } };
  if (!bounds || !bed) return none;
  const mx = num(bounds.x), my = num(bounds.y), mz = num(bounds.z);
  const bx = num(bed.x), by = num(bed.y), bz = num(bed.z);
  if (mx <= 0 || my <= 0 || bx <= 0 || by <= 0) return none;

  const footprint = mx > bx + SLACK || my > by + SLACK;
  // A bed with no height recorded cannot refuse one, which is `fitWarnings`'
  // own rule: `if (b.z && …)`.
  const height = bz > 0 && mz > bz + SLACK;

  // TURNED A QUARTER TURN. A 300×200 model on a 250×250 bed does not fit as it
  // lies and fits perfectly rotated, and the converter's own advice has always
  // been "rotate or rescale in your slicer" — so saying WHICH is more use than
  // refusing. Only meaningful when it does not already fit.
  const rotated = footprint && !(my > bx + SLACK || mx > by + SLACK);

  return {
    known: true,
    ok: !footprint && !height,
    footprint,
    height,
    rotated,
    over: {
      x: Math.max(0, mx - bx),
      y: Math.max(0, my - by),
      z: bz > 0 ? Math.max(0, mz - bz) : 0,
    },
  };
}

/**
 * The best a shop can do with the machines it owns.
 *
 * Returns the first machine it fits outright, else the first it fits rotated,
 * else nothing — which is the order a maker would try them in.
 *
 * @param {object} bounds
 * @param {Array<{id?:string, name?:string, bed?:object}>} machines
 * @returns {{machine: object|null, verdict: 'fits'|'rotate'|'none', checked: number}}
 */
function bestFit(bounds, machines) {
  const list = Array.isArray(machines) ? machines : [];
  let rotate = null, checked = 0;
  for (const m of list) {
    const r = check(bounds, m && m.bed);
    if (!r.known) continue;
    checked += 1;
    if (r.ok) return { machine: m, verdict: 'fits', checked };
    if (r.rotated && !r.height && !rotate) rotate = m;
  }
  if (rotate) return { machine: rotate, verdict: 'rotate', checked };
  return { machine: null, verdict: 'none', checked };
}

const api = { SLACK, check, bestFit };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytPrintFit = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
