'use strict';
/**
 * Bringing a shop's spools across from Spoolman.
 *
 * Spoolman (github.com/Donkie/Spoolman) is where a great many Klipper shops
 * already keep every roll they own: vendor, material, colour, what it cost,
 * what is left on it. A shop moving to Khayt had to type all of that again,
 * roll by roll, which is the kind of first hour that ends with a shop not
 * moving at all.
 *
 * This reads what Spoolman's `GET /api/v1/spool` returns — the shapes are
 * Spoolman's own `spoolman/api/v1/models.py` (`Spool`, `Filament`, `Vendor`) —
 * and says what each becomes on Khayt's shelf. It never writes to Spoolman.
 *
 * ── AN IMPORT RUN TWICE IS ONE IMPORT ─────────────────────────────────────
 *
 * Every spool brought across carries `spoolmanId`, and a spool already on the
 * shelf with that id is skipped. So a shop can import, look, and import again
 * after adding rolls to Spoolman, and get only the new ones. Weights are NOT
 * refreshed on a second run: from the moment a spool is on Khayt's shelf,
 * Khayt deducts from it itself, and overwriting that with Spoolman's figure
 * would put back every gram Khayt has already counted as used.
 *
 * Pure: the ids and the day are the caller's.
 */
(function (global) {
  const str = (v) => (v == null ? '' : String(v)).trim();
  const num = (v) => { const n = typeof v === 'number' ? v : parseFloat(v); return Number.isFinite(n) ? n : null; };

  /** `#RRGGBB` from Spoolman's `color_hex` (no `#`), or the first of a multi-colour. */
  function colourOf(filament) {
    const f = filament || {};
    const one = str(f.color_hex) || str(f.multi_color_hexes).split(',')[0].trim();
    const hex = one.replace(/^#/, '');
    return /^[0-9a-f]{6}([0-9a-f]{2})?$/i.test(hex) ? `#${hex.slice(0, 6).toUpperCase()}` : null;
  }

  /** `YYYY-MM-DD` from a Spoolman datetime (UTC), or null. */
  function dayOf(when) {
    const m = /^(\d{4}-\d{2}-\d{2})/.exec(str(when));
    return m ? m[1] : null;
  }

  /**
   * One Spoolman spool, as a Khayt spool — or null when there is nothing to
   * match a job against (no material and no name).
   *
   * `material` is what Khayt matches jobs by and what the shelf lists, so it
   * carries the vendor, the way shops type it ("Sunlu PETG"). The filament's
   * own name — in Spoolman usually the colour, "Galaxy Black" — becomes the
   * colour variant rather than being lost.
   */
  function toSpool(sm, ctx) {
    const s = sm || {};
    const f = s.filament || {};
    const vendor = str(f.vendor && f.vendor.name);
    const kind = str(f.material);
    const name = str(f.name);
    const material = [vendor, kind].filter(Boolean).join(' ') || name;
    if (!material) return null;

    // What the roll held new: the spool's own figure, else the filament's.
    const initial = num(s.initial_weight) ?? num(f.weight);
    // What is left: Spoolman works it out and sends it whenever it can.
    let left = num(s.remaining_weight);
    if (left == null && initial != null) left = initial - (num(s.used_weight) || 0);

    const spool = {
      id: ctx.id,
      material,
      cost: Math.max(0, num(s.price) ?? num(f.price) ?? 0),
      weight: Math.max(0, Math.round((left ?? initial ?? 1000) * 10) / 10),
      spoolWeight: Math.max(1, Math.round((initial ?? left ?? 1000) * 10) / 10),
      color: colourOf(f) || '#888888',
      materialType: 'fdm',
      purchasedAt: dayOf(s.registered) || ctx.today,
      spoolmanId: s.id,
    };
    if (name && name !== material) spool.colourVariant = name;
    const lot = str(s.lot_nr); if (lot) spool.lot = lot;
    const where = str(s.location); if (where) spool.storage = where;
    const opened = dayOf(s.first_used); if (opened) spool.openedAt = opened;
    return spool;
  }

  /**
   * What an import would do to this shelf: `{ add, skipped }`, where `add` is
   * the Khayt spools to append and `skipped` counts why the rest were left:
   * `archived` (Spoolman says it is used up), `already` (imported before),
   * `unnamed` (no material or name to match a job by).
   *
   * `ctx.mintId()` is called once per spool added, in order.
   */
  function plan(spoolmanSpools, inventory, ctx) {
    const have = new Set();
    for (const row of inventory || []) {
      if (row && row.spoolmanId != null) have.add(String(row.spoolmanId));
    }
    const out = { add: [], skipped: { archived: 0, already: 0, unnamed: 0 } };
    for (const sm of Array.isArray(spoolmanSpools) ? spoolmanSpools : []) {
      if (!sm || sm.id == null) { out.skipped.unnamed += 1; continue; }
      if (sm.archived) { out.skipped.archived += 1; continue; }
      if (have.has(String(sm.id))) { out.skipped.already += 1; continue; }
      const spool = toSpool(sm, { id: ctx.mintId(), today: ctx.today });
      if (!spool) { out.skipped.unnamed += 1; continue; }
      have.add(String(sm.id));
      out.add.push(spool);
    }
    return out;
  }

  /** The page of spools to ask for next: `/api/v1/spool?…`. */
  function listPath(offset, limit) {
    return `/api/v1/spool?allow_archived=false&limit=${limit}&offset=${offset}`;
  }

  const PAGE = 500;
  /** Spoolman's own default port. */
  const DEFAULT_PORT = 7912;

  const api = { toSpool, plan, colourOf, listPath, PAGE, DEFAULT_PORT };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSpoolmanImport = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
