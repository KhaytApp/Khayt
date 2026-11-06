'use strict';
(function (global) {

/**
 * The test-print log: temperature towers, retraction tests and the rest, run
 * on a spool and kept in the book's top-level `testPrints` collection.
 *
 * The rules were inside `renderer/inventory.js openTestPrintLog`'s save and
 * delete handlers. The Mac logs test prints too, so what a row holds, and what
 * logging one does to the spool, are here — in the desktop's own field names:
 *
 *   { id, spoolId, date, machineId, testType, result,
 *     printTemp, bedTemp, speed, notes, weightUsed }
 *
 * A test print that used filament takes it off the spool and writes a usage
 * line (`orderId` = the test print's id, with the spool's lot stamped on, so a
 * recall finds it). Deleting one puts the grams back on the spool; the usage
 * line stays, as it always has on the desktop.
 *
 * PURE: the caller supplies the id and today's date.
 */

const TEST_TYPES = ['temp_tower', 'retraction', 'first_layer', 'stringing', 'overhang', 'dimensional', 'other'];
const TEST_RESULTS = ['excellent', 'good', 'fair', 'poor'];
const USAGE_CAP = 200;

function lotStampOf(item, opts) {
  if (opts && typeof opts.lotStamp === 'function') return opts.lotStamp(item);
  const D = (typeof global !== 'undefined' && global.KhaytOrderDeduction) || (() => {
    try { return require('./order-deduction.js'); } catch (e) { return null; }
  })();
  return D && typeof D.lotStamp === 'function' ? D.lotStamp(item) : {};
}

/**
 * A form's raw values as the row stores them: a blank or unreadable figure
 * is null (weight 0), an unknown type `other`, an unknown result `good`.
 */
function normalize(raw, today) {
  const r = raw || {};
  const n = (v) => parseFloat(v) || null;
  return {
    date: String(r.date || '') || String(today || ''),
    machineId: r.machineId || null,
    testType: r.testType || 'other',
    result: r.result || 'good',
    printTemp: n(r.printTemp),
    bedTemp: n(r.bedTemp),
    speed: n(r.speed),
    notes: String(r.notes || '').trim(),
    weightUsed: parseFloat(r.weightUsed) || 0,
  };
}

/**
 * Log a test print. Returns the new collection (newest first) and the spool
 * as it now stands; neither input is changed.
 *
 * @param {object[]} testPrints
 * @param {object} item  the spool
 * @param {object} input normalised fields (see `normalize`)
 * @param {{id: string, lotStamp?: function}} opts
 */
function addTestPrint(testPrints, item, input, opts) {
  const o = opts || {};
  const f = input || {};
  const newTp = {
    id: o.id, spoolId: item.id, date: f.date, machineId: f.machineId, testType: f.testType,
    result: f.result, printTemp: f.printTemp, bedTemp: f.bedTemp, speed: f.speed,
    notes: f.notes, weightUsed: f.weightUsed,
  };
  const list = [newTp].concat(Array.isArray(testPrints) ? testPrints : []);
  const spool = Object.assign({}, item);
  if (f.weightUsed > 0) {
    spool.weight = Math.max(0, spool.weight - f.weightUsed);
    const history = Array.isArray(spool.usageHistory) ? spool.usageHistory.slice() : [];
    history.unshift(Object.assign({ orderId: newTp.id, project: `Test print (${f.testType})`,
      weightUsed: f.weightUsed, date: f.date }, lotStampOf(item, o)));
    if (history.length > USAGE_CAP) history.length = USAGE_CAP;
    spool.usageHistory = history;
  }
  return { testPrints: list, item: spool, entry: newTp };
}

/**
 * Take a test print off the log, putting its grams back on the spool.
 * `item` may be null when the spool is gone; then only the log changes.
 */
function removeTestPrint(testPrints, item, id) {
  const list = Array.isArray(testPrints) ? testPrints : [];
  const tp = list.find((x) => x && x.id === id);
  const kept = list.filter((x) => !(x && x.id === id));
  let spool = item;
  if (item && tp && tp.weightUsed > 0) {
    spool = Object.assign({}, item, { weight: (item.weight || 0) + tp.weightUsed });
  }
  return { testPrints: kept, item: spool, removed: tp || null };
}

/** One spool's test prints, newest first. */
function forSpool(testPrints, spoolId) {
  return (Array.isArray(testPrints) ? testPrints : [])
    .filter((tp) => tp && tp.spoolId === spoolId)
    .sort((a, b) => (b.date || '').localeCompare(a.date || ''));
}

/** How a result reads: good news, bad news, or in between. */
function resultTone(result) {
  return result === 'excellent' || result === 'good' ? 'good' : result === 'poor' ? 'bad' : 'fair';
}

const api = { TEST_TYPES, TEST_RESULTS, normalize, addTestPrint, removeTestPrint, forSpool, resultTone };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytTestPrints = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
