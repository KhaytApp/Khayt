'use strict';
(function () {

/**
 * What is wrong with a library, in groups a shop can work through.
 *
 * A PORT of the Mac's `LibraryHealth` (mac/KhaytCore/Sources/KhaytCore/
 * LibraryHealth.swift). The Mac's rule is Swift-only; this is its JavaScript
 * twin for the desktop and is NOT in the Mac's JS bundle. The groups, their
 * order and the duplicate line are the Mac's; test/library-health.test.js pins
 * them. ONE addition the Mac does not have: `noPicture` — a model on this
 * computer with no preview — because the desktop draws its own previews and
 * can make one again. It is only produced when the caller says `hasPicture`.
 *
 * The app hands it plain facts — where each model's bytes are, what its slicer
 * said, its key and its box — and gets the groups back. Nothing here reads a
 * disk or writes a record; every fix is the app's own existing door.
 *
 * ── DUPLICATES: CERTAIN, OR A LOOK ────────────────────────────────────────
 *
 *   SAME FILE   — the same `contentHash`. Certain.
 *   LOOKS SAME  — the same `geometryKey` with DIFFERENT bytes. A part
 *                 MIRRORED left-to-right has the same key and is not the same
 *                 part (lib/geometry-key.js), so these are shown to be looked
 *                 at, never merged.
 *
 * Model facts: {id, title, presence, contentHash?, geometryKey?, slicedMinutes?,
 * slicedGrams?, tags?, category?, archived?, inArchive?, hasPicture?}.
 * presence: here | online | missing | deletedByPlan | unreachable | unknown | web.
 */

const KINDS = ['deletedByPlan', 'missing', 'unreachable', 'onlineUnmeasured', 'noFigures',
  'noPicture', 'sameFile', 'looksSame', 'tooBig', 'unorganised', 'orphanProducts'];

/** The machines a 3D model can go on. A laser or UV bed says nothing about a model. */
const MODEL_KINDS = new Set(['fdm', 'resin']);

const fit = () => {
  if (typeof globalThis !== 'undefined' && globalThis.KhaytPrintFit) return globalThis.KhaytPrintFit;
  if (typeof module !== 'undefined' && module.exports && typeof require === 'function') {
    try { return require('./print-fit.js'); } catch (_) { return null; }
  }
  return null;
};

/** `triangles:volumeMm3:XxYxZ`, unpacked — null for no key or no triangles. */
function meshOf(key) {
  if (typeof key !== 'string' || !key) return null;
  const parts = key.split(':');
  if (parts.length !== 3) return null;
  const tris = Number(parts[0]);
  if (!/^[+-]?\d+$/.test(parts[0]) || !(tris > 0) || !parts[1] || !Number.isFinite(Number(parts[1]))) return null;
  const dims = parts[2].split('x').filter((s) => s !== '').map(Number).filter((n) => !Number.isNaN(n));
  if (dims.length !== 3) return null;
  return { triangles: tris, x: dims[0], y: dims[1], z: dims[2] };
}

const hasTime = (m) => (Number(m.slicedMinutes) || 0) > 0 || !!meshOf(m.geometryKey);
const hasWeight = (m) => (Number(m.slicedGrams) || 0) > 0 || !!meshOf(m.geometryKey);
const hasFigures = (m) => hasTime(m) && hasWeight(m);

/** Neither a tag nor a category — nothing a filter could find it by. */
function isUnorganised(m) {
  const tagged = (m.tags || []).some((t) => String(t || '').trim() !== '');
  const filed = String(m.category || '').trim() !== '';
  return !tagged && !filed;
}

/** Too big for every 3D printer with a bed recorded. Unknown is not a refusal. */
function tooBigForEveryMachine(m, machines) {
  const mesh = meshOf(m.geometryKey);
  const F = fit();
  if (!mesh || !F) return false;
  const bounds = { x: mesh.x, y: mesh.y, z: mesh.z };
  const states = [];
  for (const mc of Array.isArray(machines) ? machines : []) {
    if (!mc || !MODEL_KINDS.has(String(mc.kind || 'fdm').toLowerCase())) continue;
    const r = F.check(bounds, mc.bed && typeof mc.bed === 'object' ? mc.bed : null);
    if (!r.known) continue;
    // Turned a quarter turn only helps when the height fits too (ModelReadiness).
    const turned = !r.ok && r.rotated && !r.height;
    states.push(!r.ok && !turned);
  }
  return states.length > 0 && states.every(Boolean);
}

/** The two kinds of copy, each as clusters of ids in the order given. */
function duplicates(models) {
  const byHash = new Map(), byKey = new Map();
  for (const m of models) {
    if (m.contentHash) {
      if (!byHash.has(m.contentHash)) byHash.set(m.contentHash, []);
      byHash.get(m.contentHash).push(m);
    }
    if (meshOf(m.geometryKey)) {
      if (!byKey.has(m.geometryKey)) byKey.set(m.geometryKey, []);
      byKey.get(m.geometryKey).push(m);
    }
  }
  const sameFile = [], looksSame = [];
  for (const ms of byHash.values()) {
    const ids = ms.map((m) => m.id);
    if (new Set(ids).size > 1) sameFile.push(ids);
  }
  for (const ms of byKey.values()) {
    if (new Set(ms.map((m) => m.id)).size < 2) continue;
    // Each record without a hash is its own file: nothing proves it is the same bytes.
    const files = new Set(ms.map((m) => (m.contentHash ? m.contentHash : 'id:' + m.id)));
    if (files.size > 1) looksSame.push(ms.map((m) => m.id));
  }
  return { sameFile, looksSame };
}

/**
 * The groups with anything in them, in the order a shop should work through
 * them: what is lost first, what is unpriced next, then tidy-up.
 * @returns {Array<{kind, modelIds, clusters, productIds, archives, count}>}
 */
function groups(models, machines, products) {
  const all = Array.isArray(models) ? models.filter(Boolean) : [];
  const live = all.filter((m) => !m.archived);
  const out = [];
  const add = (kind, ids, extra) => {
    const e = extra || {};
    const productIds = e.productIds || [];
    if (!ids.length && !productIds.length) return null;
    const g = { kind, modelIds: ids, clusters: e.clusters || [], productIds, archives: [] };
    g.count = kind === 'orphanProducts' ? productIds.length : ids.length;
    out.push(g);
    return g;
  };
  const ids = (list) => list.map((m) => m.id);
  add('deletedByPlan', ids(live.filter((m) => m.presence === 'deletedByPlan')));
  const missing = live.filter((m) => m.presence === 'missing');
  const mg = add('missing', ids(missing));
  if (mg) {
    // A missing archive is ONE thing gone, however many models it held.
    const held = new Map();
    for (const m of missing) {
      if (!m.inArchive) continue;
      if (!held.has(m.inArchive)) held.set(m.inArchive, []);
      held.get(m.inArchive).push(m.id);
    }
    mg.archives = [...held].map(([path, modelIds]) => ({ path, modelIds }));
  }
  add('unreachable', ids(live.filter((m) => m.presence === 'unreachable')));
  add('onlineUnmeasured', ids(live.filter((m) => m.presence === 'online' && !hasFigures(m))));
  const notHere = new Set(['online', 'missing', 'deletedByPlan', 'unreachable', 'web']);
  add('noFigures', ids(live.filter((m) => !notHere.has(m.presence) && !hasFigures(m))));
  add('noPicture', ids(live.filter((m) => m.presence === 'here' && m.hasPicture === false)));
  const d = duplicates(live);
  add('sameFile', d.sameFile.flat(), { clusters: d.sameFile });
  add('looksSame', d.looksSame.flat(), { clusters: d.looksSame });
  add('tooBig', ids(live.filter((m) => tooBigForEveryMachine(m, machines))));
  add('unorganised', ids(live.filter(isUnorganised)));
  // EVERY record, archived too: a product whose model was put aside still has it.
  const known = new Set(all.map((m) => m.id));
  add('orphanProducts', [], {
    productIds: (Array.isArray(products) ? products : [])
      .filter((p) => p && (p.printFileIds || []).some((f) => f && !known.has(f)))
      .map((p) => p.id),
  });
  return out;
}

/** The library models a catalogue product's parts print from (`parts[].printFileId`). */
function productFacts(rows) {
  return (Array.isArray(rows) ? rows : []).filter((r) => r && r.id).map((r) => ({
    id: r.id,
    name: String(r.name || r.id),
    printFileIds: (Array.isArray(r.parts) ? r.parts : [])
      .map((p) => p && typeof p.printFileId === 'string' ? p.printFileId : '')
      .filter(Boolean),
  }));
}

const api = { KINDS, MODEL_KINDS, meshOf, hasFigures, isUnorganised, tooBigForEveryMachine, duplicates, groups, productFacts };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytLibraryHealth = api;

})();
