/**
 * Taking the cloud's copy down, and merging it into this device's book.
 *
 * The other direction from `lib/cloud-outbox.js`, and the dangerous one: the
 * outbox appends to a chain nobody has to obey, while this REPLACES records in
 * a shop's own book. Everything here was `pullMerge` in
 * `renderer/cloud-sync.js` plus a constant in `renderer/settings.js`, which
 * between them meant a second host could not merge without writing the rule a
 * second time — and a second opinion about which of two edits wins is the one
 * thing sync must never have.
 *
 * WHAT IT DOES NOT TOUCH. `extractDeltas` walks array collections and
 * tombstones and nothing else, so **settings never come down**. That is not an
 * oversight to be fixed later: a shop's cloud address, its tax registration and
 * its printer addresses belong to the machine in front of you, and a merge that
 * quietly replaced them would be the worst kind of surprise. The desktop has
 * always behaved this way; saying so here is the point.
 */
(function (global) {
  'use strict';

  /**
   * Collections a merge may add to and never overwrite.
   *
   * These are LEDGERS: an entry is written once and read for ever after. Two
   * devices that both logged waste on Tuesday have two entries, not one that
   * won — and a merge that let a later rev replace an earlier entry would erase
   * a record of something that actually happened. `applyDeltas` skips an
   * incoming record whose id is already present in one of these.
   *
   * `_auditLog` is here beside `auditLog` because both names have been used.
   */
  const APPEND_ONLY = Object.freeze([
    'loyaltyLedger', 'wasteLog', 'machMaintLog', 'envLogs',
    'shiftLogs', 'timeEntries', 'auditLog', '_auditLog',
  ]);

  /**
   * Merge the cloud's store into this device's, in place.
   *
   * `local` IS MUTATED and is also returned — returned because a caller across
   * a JavaScriptCore bridge gets a copy of what it passed in, so a mutation it
   * cannot see is a merge that never happened.
   *
   * The payload is every revisioned record the server holds, expressed as a
   * delta chain of one: `extractDeltas(server, {rev: 0, ts: ''})`. A cursor of
   * zero selects everything with a rev, which is the whole store, and the
   * tombstones with it. `applyDeltas` then decides record by record, by the
   * same higher-rev rule every device uses.
   *
   * @returns {{store: object, applied: number, skipped: number,
   *            removed: number, conflicts: Array}}
   */
  function merge(local, server) {
    const sync = global.KhaytSync;
    if (!sync || typeof sync.applyDeltas !== 'function') {
      throw new Error('cloud-inbox: the merge engine is not loaded');
    }
    const payload = sync.extractDeltas(server || {}, { rev: 0, ts: '' });
    // ── AND WHAT ARRIVED WITHOUT A REV ─────────────────────────────────────
    //
    // `extractDeltas` takes only records with a rev, and a record created on
    // a Mac before it stamped new records (alpha.81 and earlier) reached the
    // cloud with none — so it never came down to any other device, until its
    // first edit. Such a record is taken only where this book has no record
    // of that id at all, as rev 1: it adds what is missing and can never
    // overwrite anything here. A tombstone still removes it.
    const have = new Set();
    for (const [coll, rows] of Object.entries(local || {})) {
      if (!Array.isArray(rows)) continue;
      for (const r of rows) if (r && typeof r === 'object' && r.id != null) have.add(coll + ':' + r.id);
    }
    const colls = typeof sync.arrayCollections === 'function'
      ? sync.arrayCollections(server || {}) : [];
    for (const coll of colls) {
      const rows = server[coll];
      if (!Array.isArray((local || {})[coll]) && local && local[coll] !== undefined) continue;
      for (const r of rows) {
        if (!r || typeof r !== 'object' || r.id == null) continue;
        if (typeof r.rev === 'number' && r.rev > 0) continue;
        if (have.has(coll + ':' + r.id)) continue;
        payload.deltas.push({ collection: coll, record: Object.assign({}, r, { rev: 1 }) });
      }
    }
    const report = sync.applyDeltas(local || {}, payload, { appendOnly: APPEND_ONLY.slice() }) || {};
    return {
      store: local,
      applied: report.applied || 0,
      skipped: report.skipped || 0,
      removed: report.removed || 0,
      // A local edit thrown away because the record was deleted elsewhere.
      // Delete wins — but not silently, which is what this list is for.
      conflicts: report.conflicts || [],
    };
  }

  const api = { APPEND_ONLY, merge };
  Object.assign(global, { KhaytCloudInbox: api });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
