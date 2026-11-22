'use strict';
/**
 * Pure helpers for the archived-order prune tool (Settings → Data).
 *
 * Purging is user-initiated maintenance: keep the store fast as history grows
 * into the thousands by exporting archived orders to a file and removing them
 * from the live store. These helpers are dependency-free + Node-testable so the
 * destructive path (what gets kept vs removed, and what the export contains) has
 * unit coverage. The renderer handles the file write + confirmation + save.
 */

/** Split an order list into { archived, active } by the `archived` flag. */
function partitionArchived(orders) {
  const archived = [];
  const active = [];
  const list = Array.isArray(orders) ? orders : [];
  for (const o of list) {
    if (o && typeof o === 'object' && o.archived) archived.push(o);
    else active.push(o);
  }
  return { archived, active };
}

/**
 * Build the export payload written to disk BEFORE any records are removed.
 * The download becomes the user's only copy of these orders afterwards, so it
 * carries the full records plus provenance (version + timestamp + count).
 */
function buildArchiveExport(orders, opts = {}) {
  const { archived } = partitionArchived(orders);
  return {
    type: 'khayt-archived-orders',
    version: opts.version || null,
    exportedAt: opts.exportedAt || null,
    count: archived.length,
    orders: archived,
  };
}

const api = { partitionArchived, buildArchiveExport };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytOrderArchive = api;
