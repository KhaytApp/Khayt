/**
 * CSV bundle — turn a Khayt store snapshot into a set of CSV files for a
 * one-click "Export all data (CSV)" backup. Pure (no DOM / no I/O) so it is
 * unit-testable and reusable from the main process; the renderer hands the
 * result to hub:export-csv-bundle, which writes each file into a chosen folder.
 *
 * Spreadsheet-friendly and injection-safe: every cell is quoted, embedded
 * quotes are doubled, and a leading =,+,-,@ is neutralized so a CSV opened in
 * Excel/Sheets can't execute a formula.
 */
(function (global) {
  function neutralize(v) {
    const s = v == null ? '' : String(v);
    return /^[=+\-@\t\r]/.test(s) ? "'" + s : s;
  }
  function cell(v) {
    if (Array.isArray(v)) v = v.join(', ');
    return '"' + neutralize(v).replace(/\n/g, ' ').replace(/"/g, '""') + '"';
  }
  function toCsv(headers, rows) {
    const lines = [headers.map(cell).join(',')];
    for (const r of rows) lines.push(r.map(cell).join(','));
    // BOM so Excel reads UTF-8; CRLF line endings.
    return '﻿' + lines.join('\r\n');
  }

  /**
   * The rule that decides which of a record's names to show.
   *
   * `globalThis` first because JavaScriptCore has no `require` and no `global`;
   * the `require` is for Node, where the tests run.
   */
  const contentLanguages = () => {
    if (typeof globalThis !== 'undefined' && globalThis.KhaytContentLanguages) {
      return globalThis.KhaytContentLanguages;
    }
    try { return require('./content-languages.js'); } catch (e) { return null; }
  };

  /**
   * The shop's own name for a record.
   *
   * ── AND WHY THIS IS NOT `nameEn || nameAr` ──────────────────────────────
   *
   * Khayt writes `nameEn` and `nameAr` on a customer and on a product — there
   * is no `name` on either, and reading one produced a Name column blank in
   * every row. The obvious repair is the wrong one: a shop writes in the
   * languages IT chose, and `nameEn || nameAr` is blank for a shop working in
   * German or Turkish. `test/content-languages.test.js` forbids that shape by
   * name, because eight of them were live and two put "Hi ," in front of a
   * customer.
   *
   * So the shop's own rule answers it, through the settings the snapshot
   * already carries: the shop's languages in its own order, then anything
   * filled in at all, then a plain `name` for a record that predates all of
   * this. English is only ASKED for because the column heading is English; a
   * shop that does not write English never gets an English answer.
   */
  function nameOf(r, settings) {
    const langs = contentLanguages();
    // NO TWO-LANGUAGE FALLBACK HERE. The obvious one — `nameEn || nameAr` — is
    // the shape `test/content-languages.test.js` forbids, and writing it as a
    // "just in case" would put the fault back in the file the guard is named
    // after. All three hosts have the module: the renderer loads it, Node
    // requires it, the Mac bundles it. Without it there is no honest answer,
    // and a plain `name` is the only field that means the same in every
    // language.
    if (langs) return langs.read(r, 'name', 'en', settings) || r.name || '';
    return r.name || '';
  }

  /** The first of these fields the record actually carries. */
  function firstOf(r, keys) {
    for (const k of keys) {
      const v = r[k];
      if (v !== undefined && v !== null && v !== '') return v;
    }
    return '';
  }

  /** What a job is printed in, which lives on its parts and not on the job. */
  function materialsOf(o) {
    if (o.material) return o.material;
    const seen = [];
    for (const p of Array.isArray(o.parts) ? o.parts : []) {
      const m = p && p.material;
      if (m && !seen.includes(m)) seen.push(m);
    }
    return seen.join(', ');
  }

  // Each table: a header row + a mapper from one record to a row array.
  // Keyed by the snapshot collection name. Only collections that exist and are
  // non-empty get a file.
  //
  // ── EVERY COLUMN IS READ FROM A FIELD THE APP ACTUALLY WRITES ───────────
  //
  // This file shipped for a year reading `c.name` for a customer, `p.name` and
  // `p.price` for a product, and `s.remaining` / `s.total` for a spool. Khayt
  // writes none of those: customers and products carry `nameEn`/`nameAr`, a
  // product's price is `basePrice`, and a spool's grams are `weight` (what is
  // left) and `spoolWeight` (what it held new). So a shop that pressed "Export
  // all data" got spreadsheets whose Name, Price, Remaining and Total columns
  // were empty in every row — and the file looked perfectly well-formed.
  //
  // The purchase-order row above carried exactly this fault and was fixed on
  // its own; the rest of the file was not looked at. `test/csv-bundle.test.js`
  // could not catch it either, because its fixtures were written to match the
  // mistake.
  //
  // Older spellings stay as fallbacks, behind the ones the app writes, so a
  // snapshot from an importer or an older build still exports.
  const TABLES = {
    printLog: {
      file: 'orders.csv',
      // PROJECT IS ITS OWN COLUMN. The job's own name was being written under
      // the "Client" heading, so every export said the customer was called
      // "Helmet build" — and the customer's name, which the order carries as
      // `client`, appeared nowhere in the file.
      headers: ['ID', 'Date', 'Client', 'Project', 'Material', 'Print Time (hrs)', 'Price', 'Status', 'Payment', 'Paid Amount', 'Due Date', 'Tags', 'Notes'],
      row: (o) => [o.id, o.date, firstOf(o, ['client', 'clientName']), o.project || '',
                   materialsOf(o), o.printTime, o.price, o.status, o.paymentStatus || '',
                   o.paidAmount || 0, o.dueDate || '', o.tags || [], o.notes || ''],
    },
    clients: {
      file: 'clients.csv',
      headers: ['ID', 'Name', 'Phone', 'Email', 'Company', 'Address', 'Notes', 'Tags'],
      row: (c, settings) => [c.id, nameOf(c, settings), c.phone || '', c.email || '', c.company || '', c.address || '', c.notes || '', c.tags || []],
    },
    products: {
      file: 'products.csv',
      headers: ['ID', 'Name', 'Category', 'Price', 'Material', 'Print Time (hrs)', 'Notes'],
      // A product's price is `basePrice`, and `priceOverride` is the figure
      // the shop typed over it — that one wins, because it is what the product
      // actually sells for.
      row: (p, settings) => [p.id, nameOf(p, settings), p.category || '',
                   firstOf(p, ['priceOverride', 'basePrice', 'price']),
                   materialsOf(p), p.printTime ?? '', p.notes || ''],
    },
    inventory: {
      file: 'inventory.csv',
      headers: ['ID', 'Material', 'Color', 'Brand', 'Remaining (g)', 'Total (g)', 'Cost', 'Location', 'Notes'],
      // `weight` is what is LEFT on the spool and `spoolWeight` what it held
      // new. Reading `remaining` and `total` — which nothing writes — emptied
      // both columns, which are the two a shop exports a shelf for.
      row: (s) => [s.id, s.material || s.type || '',
                   firstOf(s, ['colourVariant', 'color', 'colour']), s.brand || '',
                   firstOf(s, ['weight', 'remaining', 'remainingGrams']),
                   firstOf(s, ['spoolWeight', 'total', 'totalGrams']),
                   firstOf(s, ['cost', 'costPerKg']),
                   firstOf(s, ['storage', 'location']), s.notes || ''],
    },
    expenses: {
      file: 'expenses.csv',
      headers: ['ID', 'Date', 'Category', 'Description', 'Amount', 'Vendor'],
      row: (e) => [e.id, e.date || '', e.category || '', e.description || e.note || '', e.amount ?? '', e.vendor || ''],
    },
    machines: {
      file: 'machines.csv',
      headers: ['ID', 'Name', 'Model', 'Status', 'Notes'],
      // A machine's model is `printerModelName`; `model` is the demo data's
      // spelling and stays behind it.
      row: (m) => [m.id, m.name || '', firstOf(m, ['printerModelName', 'model']),
                   m.status || '', m.notes || ''],
    },
    suppliers: {
      file: 'suppliers.csv',
      headers: ['ID', 'Name', 'Phone', 'Email', 'Notes'],
      row: (s) => [s.id, s.name || '', s.phone || '', s.email || '', s.notes || ''],
    },
    purchaseOrders: {
      file: 'purchase-orders.csv',
      headers: ['ID', 'Date', 'Supplier', 'Status', 'Total'],
      // A purchase order records its date as `orderedAt` and its money as
      // `qty` × `unitPrice`; the `date` and `total` this reached for first are
      // written by nothing, so the accountant's copy of every order carried a
      // blank date and a blank total. The old names stay as fallbacks for an
      // externally-shaped snapshot, behind the ones the app actually writes.
      row: (po) => [
        po.id,
        po.orderedAt || po.date || po.createdAt || '',
        po.supplierName || po.supplier || '',
        po.status || '',
        po.total ?? (Math.round((+po.qty || 0) * (+po.unitPrice || 0) * 100) / 100 || ''),
      ],
    },
  };

  /**
   * Build the CSV files for a snapshot.
   * @param {object} snapshot store collections (printLog, clients, …)
   * @returns {Array<{name: string, content: string}>}
   */
  function buildCsvBundle(snapshot) {
    snapshot = snapshot || {};
    const out = [];
    for (const key of Object.keys(TABLES)) {
      const rows = snapshot[key];
      if (!Array.isArray(rows) || rows.length === 0) continue;
      const t = TABLES[key];
      // The settings ride along because the name of a customer or a product is
      // a question about the shop's own content languages, not about the
      // record alone.
      out.push({ name: t.file,
                 content: toCsv(t.headers, rows.map((r) => t.row(r, snapshot.settings))) });
    }
    return out;
  }

  const api = { buildCsvBundle, TABLES };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytCsvBundle = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
