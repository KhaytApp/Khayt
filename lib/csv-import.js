'use strict';
/**
 * Importing spools, clients and products from a CSV file.
 *
 * The rules were three `onImport` closures in renderer/inventory.js and a
 * mapping modal in renderer/app-helpers.js — which is why only the Electron
 * window could import a spreadsheet. Lifted here unchanged so the Mac's
 * File ▸ Import CSV… builds the same records from the same file:
 *
 *   parse     the text into a header row and data rows (quoted fields, "" as
 *             an escaped quote, CRLF/CR line ends, blank lines dropped, every
 *             cell trimmed) — renderer/util.js parseCsvString, as it was;
 *   autoMap   each field to the column whose header matches its key or its
 *             label, ignoring case, spaces, `_` and `-`;
 *   objects   the mapped rows, numbers as `+raw || 0`, rows missing a
 *             required field dropped;
 *   plan      the records to add, a row matching one already in the book (or
 *             one added earlier in the same file) skipped as a duplicate.
 *
 * PURE: no DOM, no clock, no random ids. The host hands in `today` and either
 * `newId(prefix)` or a list of `ids` to use in order, because both are its own.
 * The desktop's old closures are pinned against this in
 * test/csv-import.test.js — the same file gives the same records.
 */
(function (global) {

  /** The fields each kind maps, in the order the desktop lists them. `label`
   *  is the English fallback; `labelKey` is the shared catalogue's word. */
  const FIELDS = {
    spools: [
      { key: 'material',        labelKey: 'inv.material',      label: 'Material', required: true },
      { key: 'brand',           labelKey: 'inv.brand',         label: 'Brand' },
      { key: 'color',           labelKey: 'inv.color',         label: 'Color' },
      { key: 'lot',             labelKey: 'inv.lot',           label: 'Lot / Batch' },
      { key: 'diameter',        labelKey: 'inv.diameter',      label: 'Diameter (mm)',     type: 'number' },
      { key: 'weightTotal',     labelKey: 'inv.weight_total',  label: 'Total Weight (g)',  type: 'number' },
      { key: 'weightRemaining', labelKey: 'inv.remaining',     label: 'Remaining (g)',     type: 'number' },
      { key: 'costPerKg',       labelKey: 'inv.cost_per_kg',   label: 'Cost/kg',           type: 'number' },
      { key: 'reorderPoint',    labelKey: 'inv.reorder_point', label: 'Reorder Point (g)', type: 'number' },
      { key: 'location',        labelKey: 'inv.location',      label: 'Location' },
      { key: 'notes',           labelKey: 'common.notes',      label: 'Notes' },
    ],
    clients: [
      { key: 'nameEn',    labelKey: 'cl.name_en',   label: 'Name (English)', required: true },
      { key: 'nameAr',    labelKey: 'cl.name_ar',   label: 'Name (Arabic)' },
      { key: 'phone',     labelKey: 'cl.phone',     label: 'Phone' },
      { key: 'email',     labelKey: 'cl.email',     label: 'Email' },
      { key: 'city',      labelKey: 'cl.city',      label: 'City' },
      { key: 'address',   labelKey: 'cl.address',   label: 'Address' },
      { key: 'vatNumber', labelKey: 'cl.vat',       label: 'VAT Number' },
      { key: 'company',   labelKey: 'cl.company',   label: 'Company' },
      { key: 'notes',     labelKey: 'common.notes', label: 'Notes' },
    ],
    products: [
      { key: 'nameEn',        labelKey: 'pe.name_en',        label: 'Name (English)', required: true },
      { key: 'nameAr',        labelKey: 'pe.name_ar',        label: 'Name (Arabic)' },
      { key: 'description',   labelKey: 'pe.description',    label: 'Description' },
      { key: 'defaultMargin', labelKey: 'pe.default_margin', label: 'Default Margin (%)', type: 'number' },
      { key: 'sku',           labelKey: 'cat.sku',           label: 'SKU' },
    ],
  };

  /** The id prefix of each kind's records — the desktop's `uid()` prefixes. */
  const PREFIX = { spools: 'S', clients: 'CL', products: 'PROD' };

  /** Where each kind lives in the book. */
  const COLLECTION = { spools: 'inventory', clients: 'clients', products: 'products' };

  function parse(csv) {
    const lines = String(csv == null ? '' : csv).replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim().split('\n');
    if (!lines.length) return { headers: [], rows: [] };

    function parseLine(line) {
      const cols = [];
      let cur = '';
      let inQ = false;
      for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === '"') {
          if (inQ && line[i + 1] === '"') {
            cur += '"';
            i++;
          } else inQ = !inQ;
        } else if (c === ',' && !inQ) {
          cols.push(cur.trim());
          cur = '';
        } else {
          cur += c;
        }
      }
      cols.push(cur.trim());
      return cols;
    }

    const headers = parseLine(lines[0]);
    const rows = lines.slice(1).filter((l) => l.trim()).map(parseLine);
    return { headers, rows };
  }

  /**
   * The column each field starts on: `{ key: index }`, -1 for none. `labels`
   * is `{ key: label }` in the shop's language (the desktop's `t()`), falling
   * back to the English one here.
   */
  function autoMap(fields, headers, labels) {
    const norm = (s) => String(s == null ? '' : s).toLowerCase().replace(/[\s_-]/g, '');
    const out = {};
    for (const f of fields || []) {
      const label = (labels && labels[f.key]) || f.label || '';
      const targets = [norm(f.key), norm(label)];
      out[f.key] = (headers || []).findIndex((h) => targets.includes(norm(h)));
    }
    return out;
  }

  /** The rows as objects of the mapped fields; a row missing a required one is dropped. */
  function objects(rows, fields, mapping) {
    const m = mapping || {};
    const has = (k) => typeof m[k] === 'number' && m[k] >= 0;
    return (rows || []).map((row) => {
      const obj = {};
      (fields || []).forEach((f) => {
        if (has(f.key)) {
          const cell = row[m[f.key]];
          const raw = (cell == null ? '' : String(cell)).trim() || '';
          obj[f.key] = f.type === 'number' ? (+raw || 0) : raw;
        }
      });
      return obj;
    }).filter((obj) => (fields || []).filter((f) => f.required).every((f) => obj[f.key]));
  }

  const lower = (s) => (s == null ? s : String(s).toLowerCase());

  function spoolRecord(row, id, ctx) {
    const wt = row.weightTotal || 1000;
    const settings = ctx.settings || {};
    return {
      id,
      material: row.material,
      brand: row.brand || '',
      color: row.color || '',
      lot: row.lot || undefined,
      diameter: row.diameter || 1.75,
      weight: row.weightRemaining != null ? row.weightRemaining : wt,
      weightTotal: wt,
      cost: row.costPerKg || 0,
      reorderPoint: row.reorderPoint ?? (settings.lowStockThreshold ?? 200),
      location: row.location || '',
      notes: row.notes || '',
      addedAt: ctx.today,
      usageHistory: [],
    };
  }

  function clientRecord(row, id, ctx) {
    return {
      id,
      nameEn: row.nameEn,
      nameAr: row.nameAr || '',
      phone: row.phone || '',
      email: row.email || '',
      city: row.city || '',
      address: row.address || '',
      vat: row.vatNumber || '',
      company: row.company || '',
      notes: row.notes || '',
      createdAt: ctx.today,
      commLog: [],
      loyaltyTier: 'standard',
    };
  }

  function productRecord(row, id, ctx) {
    return {
      id,
      nameEn: row.nameEn,
      nameAr: row.nameAr || '',
      description: row.description || '',
      defaultMargin: row.defaultMargin || 30,
      sku: row.sku || '',
      thumbnail: null,
      imagePath: null,
      priceTiers: [],
      parts: [],
      createdAt: ctx.today,
    };
  }

  /** Whether `row` names a record already in `pool` — the desktop's own tests. */
  function duplicate(kind, row, pool) {
    if (kind === 'spools') {
      return pool.some((s) => s && lower(s.material) === lower(row.material)
        && lower(s.brand) === (row.brand || '').toLowerCase()
        && lower(s.color) === (row.color || '').toLowerCase());
    }
    if (kind === 'clients') {
      return pool.some((c) => c && ((lower(c.nameEn) === lower(row.nameEn))
        || (row.phone && c.phone === row.phone)
        || (row.email && lower(c.email) === lower(row.email))));
    }
    return pool.some((p) => p && ((lower(p.nameEn) === lower(row.nameEn))
      || (row.sku && p.sku === row.sku)));
  }

  /**
   * What importing `objects` into `existing` does: the records to add, in
   * file order, and each row's verdict for a preview.
   *
   * @param {'spools'|'clients'|'products'} kind
   * @param {object[]} objs     from `objects()`
   * @param {object[]} existing the book's records of that kind
   * @param {{today:string, settings?:object, newId?:Function, ids?:string[]}} ctx
   * @returns {{ add: object[], imported: number, skipped: number,
   *             rows: {verdict:'new'|'duplicate', id?:string}[] }}
   */
  function plan(kind, objs, existing, ctx) {
    const c = ctx || {};
    const build = kind === 'spools' ? spoolRecord : kind === 'clients' ? clientRecord : productRecord;
    if (!PREFIX[kind]) throw new Error('csv-import: unknown kind ' + kind);
    const pool = (Array.isArray(existing) ? existing : []).slice();
    const add = [];
    const rows = [];
    let next = 0;
    const idFor = () => {
      if (Array.isArray(c.ids) && next < c.ids.length) return c.ids[next++];
      if (typeof c.newId === 'function') return c.newId(PREFIX[kind]);
      throw new Error('csv-import: no id for a new record');
    };
    let skipped = 0;
    (objs || []).forEach((row) => {
      if (duplicate(kind, row, pool)) { skipped++; rows.push({ verdict: 'duplicate' }); return; }
      const rec = build(row, idFor(), c);
      pool.push(rec);
      add.push(rec);
      rows.push({ verdict: 'new', id: rec.id });
    });
    return { add, imported: add.length, skipped, rows };
  }

  const api = { FIELDS, PREFIX, COLLECTION, parse, autoMap, objects, plan, duplicate };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytCsvImport = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
