'use strict';

/**
 * File names that do not destroy the file already there.
 *
 * Two small rules, each of which was missing somewhere a shop's data lives.
 */

/**
 * The shop's calendar day, `YYYY-MM-DD`, in the machine's own time zone.
 *
 * The daily backup was named by `toISOString()` — the UTC day — while the
 * renderer decides whether today's backup has run by comparing that name with
 * the LOCAL day. In Riyadh (UTC+3), from midnight to 03:00 the two disagree:
 * the renderer saw "yesterday's" name, wrote again, and the write landed on
 * yesterday's file, replacing that day's restore point with tonight's state —
 * on every call until 03:00. Naming by the same day the renderer compares
 * against makes one backup per local day, which is what the setting promises.
 */
function localDayName(d = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/**
 * `name` if it is free, otherwise `stem-2.ext`, `stem-3.ext`, … — the first one
 * `taken` says is free. The Mac's ArchiveImport.uniqueName follows the same
 * rule, so the two apps name a second `part.stl` the same way.
 *
 * `taken(name)` answers whether a file of that name already exists; it is
 * injected so this stays pure and testable.
 */
function uniqueName(name, taken) {
  const base = String(name || 'file');
  if (!taken(base)) return base;
  const dot = base.lastIndexOf('.');
  const stem = dot > 0 ? base.slice(0, dot) : base;
  const ext = dot > 0 ? base.slice(dot) : '';
  for (let n = 2; ; n++) {
    const candidate = `${stem}-${n}${ext}`;
    if (!taken(candidate)) return candidate;
  }
}

/** A timestamp safe in a file name on every platform: no `:` and no `.`. */
function fileStamp(d = new Date()) {
  return d.toISOString().replace(/[:.]/g, '-');
}

module.exports = { localDayName, uniqueName, fileStamp };
