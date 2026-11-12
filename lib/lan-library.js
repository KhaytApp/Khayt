'use strict';
/**
 * The library as the phone sees it: `GET /api/library` and the figures
 * `POST /api/library/{id}/estimate` prices from (docs/LAN_API.md).
 *
 * The library stays on the computer — at 10,000 models it is a quarter of a real
 * book and is left out of the phone's working set — so the phone asks for one
 * page at a time and the search runs here.
 *
 * Pure: no fs, no network. The routes in lib/lan-server.js read the files.
 */

const Organise = require('./organise.js');
const LibraryArchive = require('./library-archive.js');
const PrintHistory = require('./print-history.js');
const ColourFamily = require('./colour-family.js');
const ModelFileType = require('./model-file-type.js');

const ESTIMABLE = new Set(['stl', 'obj', '3mf', 'gcode', 'gco']);
const MAX_LIMIT = 200;
const DEFAULT_LIMIT = 50;

const str = (v) => (v == null ? '' : String(v));
const fold = (s) => str(s).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
const pos = (v) => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : null);

const nameOf = (rec) => str(rec.name).trim()
  || str(rec.sourceFile && rec.sourceFile.originalName).trim()
  || str(rec.sourceFile && rec.sourceFile.filename).trim()
  || str(rec.id);
const extOf = (rec) => str(rec.sourceFile && rec.sourceFile.ext).toLowerCase();
const tagsOf = (rec) => (Array.isArray(rec.tags) ? rec.tags.map(str).filter(Boolean) : []);
const hasThumb = (rec) => !!(rec.thumbFile || rec.thumb || rec.userPhoto);

function haystack(rec) {
  return fold([
    nameOf(rec), rec.originalName, rec.sourceFile && rec.sourceFile.originalName,
    Organise.groupOf(rec), tagsOf(rec).join(' '), Organise.categoryOf(rec),
  ].map(str).join(' '));
}

/** Is `folder` the record's own folder or one above it? `""` is above everything. */
const isUnder = (recFolder, folder) => !folder || recFolder === folder || recFolder.startsWith(folder + '/');

/** One record as the phone gets it. Anything the book does not have is left out. */
/** The record's figures belong to older bytes (`figuresStaleFor`, the Mac's vault apply). */
const figuresStale = (rec) => !!(rec && rec.figuresStaleFor && String(rec.figuresStaleFor).trim());

function itemOf(rec, history) {
  // Figures from older bytes are not sent as the model's (beta.8 review M1):
  // the phone then asks for an estimate, which says it is one.
  const p = (rec.parsed && typeof rec.parsed === 'object' && !figuresStale(rec)) ? rec.parsed : {};
  const out = { id: str(rec.id), name: nameOf(rec), folder: Organise.groupOf(rec) };
  const category = Organise.categoryOf(rec);
  if (category) out.category = category;
  const tags = tagsOf(rec);
  if (tags.length) out.tags = tags;
  if (rec.material) out.material = str(rec.material);
  const ext = extOf(rec);
  if (ext) out.ext = ext;
  const size = pos(rec.sourceFile && rec.sourceFile.size);
  if (size) out.size = size;
  out.favorite = !!rec.favorite;
  // The record's own counter, or what the jobs say when that is more
  // (lib/print-history.js): a job made from the model is a print of it.
  // Without a job naming it, the record is sent exactly as it stands.
  const entry = history && Object.prototype.hasOwnProperty.call(history, rec.id) ? history[rec.id] : null;
  if (entry) {
    const printed = PrintHistory.merge(rec, entry);
    out.timesPrinted = printed.timesPrinted;
    if (printed.lastPrinted) out.lastPrinted = str(printed.lastPrinted);
  } else {
    if (typeof rec.timesPrinted === 'number') out.timesPrinted = rec.timesPrinted;
    if (rec.lastPrinted) out.lastPrinted = str(rec.lastPrinted);
  }
  out.thumb = hasThumb(rec);
  out.estimable = !!(rec.sourceFile && rec.sourceFile.filename && ESTIMABLE.has(ext));
  // What a slicer recorded, or null — never a made-up 0.
  out.printTimeMins = pos(p.printTimeMins);
  out.grams = pos(p.filamentGrams);
  if (Array.isArray(p.plates) && p.plates.length) {
    out.plates = p.plates.filter(Boolean).map((pl, i) => {
      const o = { index: Number.isInteger(pl.index) ? pl.index : i + 1 };
      if (pl.name) o.name = str(pl.name);
      o.printTimeMins = pos(pl.printTimeMins);
      o.grams = pos(pl.filamentGrams);
      return o;
    });
  }
  if (Array.isArray(rec.colors)) {
    const colors = rec.colors.filter((c) => c && c.hex).map((c) => {
      const o = { hex: str(c.hex) };
      const g = pos(c.grams);
      if (g) o.grams = g;
      return o;
    });
    if (colors.length) out.colors = colors;
  }
  if (rec.testedNotes) out.testedNotes = str(rec.testedNotes);
  return out;
}

/** `colour=blue,black` as the keys it names that exist; anything else is ignored. */
function keysOf(text, known) {
  const want = new Set(str(text).toLowerCase().split(',').map((k) => k.trim()).filter(Boolean));
  return known.filter((k) => want.has(k));
}

/**
 * The two filter menus the phone draws, counted and applied.
 *
 * ── THE MAC'S OWN RULE, OVER THE WIRE ─────────────────────────────────────
 * Several rows of one menu are OR ("red or orange"); the two menus narrow
 * together, and with the search or the folder. Each menu is COUNTED over
 * everything except its own choice — the search, the folder and the OTHER
 * menu — so choosing Blue does not zero every other colour, and a shop can
 * see what adding Black would bring. Every key is always in the counts,
 * zeros included: a menu whose rows come and go is a menu nobody learns.
 *
 * A multicolour model is under each of its families and under `multi`; a
 * model with no colour stored is under `none` (lib/colour-family.js).
 */
function narrow(base, opts) {
  const colours = keysOf(opts.colour, ColourFamily.TOKENS);
  const types = keysOf(opts.type, ModelFileType.TYPES);
  const rows = base.map((r) => ({ r, tokens: ColourFamily.tokensOf(r.colors), type: ModelFileType.typeOf(r) }));
  const colourOk = (x) => !colours.length || x.tokens.some((t) => colours.includes(t));
  const typeOk = (x) => !types.length || types.includes(x.type);
  const colour = {}; const type = {};
  for (const k of ColourFamily.TOKENS) colour[k] = 0;
  for (const k of ModelFileType.TYPES) type[k] = 0;
  for (const x of rows) {
    if (typeOk(x)) for (const t of x.tokens) colour[t] += 1;
    if (colourOk(x)) type[x.type] += 1;
  }
  return { matched: rows.filter((x) => colourOk(x) && typeOk(x)).map((x) => x.r), facets: { colour, type } };
}

function byFavouriteThenName(a, b) {
  if (!!a.favorite !== !!b.favorite) return a.favorite ? -1 : 1;
  return nameOf(a).localeCompare(nameOf(b), undefined, { sensitivity: 'base', numeric: true });
}

/**
 * One page of the library.
 *
 * @param {Array} printFiles  the book's `printFiles`
 * @param {{q?: string, folder?: string, offset?: number|string, limit?: number|string,
 *   colour?: string, type?: string, orders?: Array}} opts  `orders` is the
 *   book's `printLog`: each model's times printed and last printed are read
 *   off its jobs as well (lib/print-history.js). `colour` and `type` are
 *   comma-separated filter keys (`narrow`).
 */
function list(printFiles, opts = {}) {
  // A model archived on the Mac (archivedAt) is out of the phone's library —
  // items, folder counts and paging — as the Mac's own LAN listing does
  // (Shop+PhoneLibrary.swift).
  const recs = (Array.isArray(printFiles) ? printFiles : [])
    .filter((r) => r && typeof r === 'object' && r.id && !LibraryArchive.isArchived(r));
  const words = fold(opts.q).split(/\s+/).filter(Boolean);
  const offset = Math.max(0, parseInt(opts.offset, 10) || 0);
  const asked = parseInt(opts.limit, 10);
  const limit = Number.isFinite(asked) ? Math.min(MAX_LIMIT, Math.max(1, asked)) : DEFAULT_LIMIT;

  let matched;
  const folders = [];
  if (words.length) {
    // A search covers the whole library, whatever folder the phone was in.
    matched = recs.filter((r) => { const h = haystack(r); return words.every((w) => h.includes(w)); });
  } else {
    const folder = Organise.normalise(opts.folder);
    matched = recs.filter((r) => Organise.groupOf(r) === folder);
    const subs = new Map();
    for (const r of recs) {
      const f = Organise.groupOf(r);
      if (!f || f === folder || !isUnder(f, folder)) continue;
      const rest = folder ? f.slice(folder.length + 1) : f;
      const name = rest.split('/')[0];
      if (!name) continue;
      const path = folder ? `${folder}/${name}` : name;
      subs.set(path, (subs.get(path) || 0) + 1);
    }
    for (const [path, count] of subs) folders.push({ path, name: path.split('/').pop(), count });
    folders.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base', numeric: true }));
  }
  // The sub-folders above are the library's own shape and are not narrowed:
  // a folder does not vanish because nothing blue is directly inside it.
  const narrowed = narrow(matched, opts);
  matched = narrowed.matched;
  matched.sort(byFavouriteThenName);
  const history = Array.isArray(opts.orders) ? PrintHistory.byFile(opts.orders) : null;
  return {
    total: matched.length, offset, folders,
    // An older computer sends no `facets`; that is how a phone knows not to
    // draw the two menus.
    facets: narrowed.facets,
    items: matched.slice(offset, offset + limit).map((r) => itemOf(r, history)),
  };
}

/**
 * The slicer's own figures for a model, or for one of its plates, in the shape
 * lib/public-quote.js prices (a lib/model-intake.js result). Null when the book
 * has none, and the file has to be measured instead.
 *
 * @returns {object|null|false}  false when `plate` names no plate on the model
 */
function recordedFigures(rec, plate) {
  const p = (rec && rec.parsed && typeof rec.parsed === 'object') ? rec.parsed : {};
  // Measured from older bytes: none recorded for THESE (beta.8 review M1).
  // A plate that exists is still not refused as unknown.
  if (figuresStale(rec)) {
    if (plate != null && plate !== '') {
      const want = parseInt(plate, 10);
      const plates = Array.isArray(p.plates) ? p.plates.filter(Boolean) : [];
      if (!plates.some((pl, i) => (Number.isInteger(pl.index) ? pl.index : i + 1) === want)) return false;
    }
    return null;
  }
  let mins = p.printTimeMins, grams = p.filamentGrams;
  if (plate != null && plate !== '') {
    const want = parseInt(plate, 10);
    const plates = Array.isArray(p.plates) ? p.plates.filter(Boolean) : [];
    const at = plates.findIndex((pl, i) => (Number.isInteger(pl.index) ? pl.index : i + 1) === want);
    if (at < 0) return false;
    mins = plates[at].printTimeMins; grams = plates[at].filamentGrams;
  }
  if (!pos(mins) || !pos(grams)) return null;
  return {
    kind: extOf(rec) || null, exact: true, source: 'slicer',
    printTimeMins: mins, filamentGrams: grams,
    slicer: p.slicer ? str(p.slicer) : null, geometry: null, risk: null, warnings: [],
  };
}

/**
 * The spool a library model is costed with: the shop's spool of the material
 * the model was sliced for, else its first spool with a cost. The Mac's
 * `Shop.spool(for:file:among:)`, so both computers cost a model alike.
 */
function spoolFor(material, inventory) {
  const costed = (Array.isArray(inventory) ? inventory : []).filter((s) => s && s.id && Number(s.cost) > 0);
  if (!costed.length) return null;
  const w = str(material).trim().toLowerCase();
  if (w) {
    const hit = costed.find((s) => {
      const m = str(s.materialType || s.material).toLowerCase();
      return m === w || m.startsWith(w + ' ') || m.startsWith(w + '+') || str(s.material).toLowerCase().startsWith(w);
    });
    if (hit) return hit;
  }
  return costed[0];
}

/**
 * The owner's price for a library model: what the calculator's "from a model"
 * gives, the way the Mac's "Quote this model…" does — the model's figures
 * (`partPatch`), the shop's rates (`ratesFor`), the spool of its material, the
 * shop's default margin, and its overhead when that is on. Not the customer
 * intake form's settings: the owner prices whether or not that form is set up.
 *
 * @param {object} a
 * @param {object} a.rec       the library record
 * @param {?number} a.plate    one plate, or null for the whole model
 * @param {?{grams:number, hours:number, reliable?:boolean, exact?:boolean}} a.measured
 *   what the file in the vault gave, when the book holds no figures
 * @param {object} a.store
 * @param {number} a.qty
 * @param {object} a.deps      { partPatch, ratesFor, computePartBaseCost, quoteTotal, overheadPerHour }
 */
function ownerQuote({ rec, plate, measured, store, qty, deps }) {
  const settings = (store && store.settings) || {};
  const n = Math.max(1, Math.min(1000, Math.round(Number(qty) || 1)));
  const refuse = (reason) => ({ ok: false, reason });

  // One plate: the record as the shared rule reads it, with that plate's own
  // figures in place of the whole file's.
  let r = rec;
  if (plate != null) {
    const p = recordedFigures(rec, plate);
    if (!p) return refuse('no-numbers');
    r = { ...rec, colors: [], parsed: { ...(rec.parsed || {}), printTimeMins: p.printTimeMins, filamentGrams: p.filamentGrams, plates: undefined } };
  }
  const patch = deps.partPatch(r) || {};
  const part = { ...(patch.fields || {}) };
  let exact = part.printWeight > 0 && part.printTime > 0;
  let reliable = true;
  if (!exact && measured) {
    if (!(part.printWeight > 0) && measured.grams > 0) part.printWeight = measured.grams;
    if (!(part.printTime > 0) && measured.hours > 0) part.printTime = measured.hours;
    // A sliced file read off the disk is as good as figures in the book.
    exact = !!measured.exact;
    reliable = measured.reliable !== false;
  }
  if (!(part.printWeight > 0) || !(part.printTime > 0)) return refuse('no-numbers');

  const spool = spoolFor(part.material, store && store.inventory);
  if (spool) {
    part.filamentId = spool.id;
    part.material = str(spool.material);
    part.spoolCost = Number(spool.cost);
    part.spoolWeight = Math.max(1, Number(spool.spoolWeight) || 1000);
  }
  part.qty = n;
  const costed = { ...deps.ratesFor({ settings }), ...part };
  const ctx = { inventory: (store && store.inventory) || [], settings, consumables: (store && store.consumables) || [] };
  let unit;
  try { unit = deps.computePartBaseCost(costed, ctx); } catch (_) { return refuse('no-price'); }
  if (!Number.isFinite(unit) || unit <= 0) return refuse('no-price');

  const margin = typeof settings.defaultMargin === 'number' && Number.isFinite(settings.defaultMargin) ? settings.defaultMargin : 30;
  const overhead = Math.max(0, Number(deps.overheadPerHour) || 0);
  let total;
  try {
    total = deps.quoteTotal({
      baseCost: unit * n, qty: 1, margin, discountPct: 0, shippingCost: 0,
      rushEnabled: false, business: true, agreedAmount: 0,
      ...(overhead > 0 ? { overheadPerHour: overhead, printHours: part.printTime * n } : {}),
    });
  } catch (_) { return refuse('no-price'); }
  const price = Math.round((Number(total && total.total) || 0) * 100) / 100;
  if (!(price > 0)) return refuse('no-price');
  return {
    ok: true, price, currency: settings.currency || null, qty: n,
    // Per piece, as the intake estimate and the Mac answer.
    grams: Math.round(part.printWeight * 10) / 10,
    hours: Math.round(part.printTime * 100) / 100,
    exact, reliable,
  };
}

module.exports = { list, itemOf, recordedFigures, ownerQuote, spoolFor, isArchived: LibraryArchive.isArchived, ESTIMABLE, MAX_LIMIT, DEFAULT_LIMIT };
