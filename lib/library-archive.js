'use strict';
(function () {

/**
 * Archived library records, the Mac's rule.
 *
 * A record is archived when `archivedAt` is a non-empty string. The Mac sets
 * it when the shop archives a model, and also when the model's Khayt Vault
 * file is trashed elsewhere (`vaultArchived: true` says which; a vault restore
 * clears only that one). An archived record stays in the book — a job or a
 * product that already names it keeps working — but it is out of the library:
 * not in the grid, its counts, its chips or its pickers, only under Archived
 * (mac Shop+LibraryQuery.swift: `f.isArchived != q.archived`).
 *
 * The desktop never sets or clears `archivedAt`; it only honours it, so a
 * model the Mac took out of the library does not come back here.
 *
 * PURE: no DOM, no clock.
 */

function isArchived(r) {
  return !!r && typeof r.archivedAt === 'string' && r.archivedAt.trim() !== '';
}

/** The records one side of the line: the live library, or only the archived. */
function pool(list, archived) {
  const rows = Array.isArray(list) ? list : [];
  const want = !!archived;
  return rows.filter((r) => r && isArchived(r) === want);
}

function archivedCount(list) {
  let n = 0;
  for (const r of Array.isArray(list) ? list : []) if (isArchived(r)) n++;
  return n;
}

const api = { isArchived, pool, archivedCount };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytLibraryArchive = api;

})();
