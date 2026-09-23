'use strict';
(function (global) {

/**
 * Where a model came from, and what its licence lets a shop do with it.
 *
 * ── WHY A SHOP NEEDS THIS ─────────────────────────────────────────────────
 *
 * A print shop's library holds two very different things: work it made or was
 * commissioned for, and models it downloaded. They look identical in a grid,
 * and the difference decides whether a print can be SOLD. Most of what is on
 * the model sites is Creative Commons, and a large share of that is
 * NonCommercial — which is exactly the licence that makes selling a print of it
 * a breach rather than a favour.
 *
 * Khayt recorded neither. A model arrived with a filename and nothing else.
 *
 * ── UNKNOWN IS NOT NO ─────────────────────────────────────────────────────
 *
 * The important design decision here, and the easy one to get wrong. A shop
 * that has not filled this in yet must not be told it may not sell its own
 * work, and must not be told it may either. `sellable` answers `true`, `false`,
 * or `null` — and `null` means nobody has said, which is a different sentence
 * on screen and a different colour beside it.
 *
 * PURE: no store, no DOM, no clock.
 */

const str = (v) => (typeof v === 'string' ? v.trim() : '');

/**
 * The licences a downloaded model actually carries, and what each permits.
 *
 * `commercial` is the shop's question — may a print of this be sold. `share`
 * is whether a modified version must carry the same licence, which matters the
 * moment a shop remixes something. `derivatives` is whether it may be modified
 * at all: an ND model may be printed and sold under some readings and may not
 * be altered, so it is kept separate rather than folded into `commercial`.
 */
const LICENCES = [
  { id: 'own',       commercial: true,  attribution: false, derivatives: true,  share: false },
  { id: 'cc0',       commercial: true,  attribution: false, derivatives: true,  share: false },
  { id: 'cc-by',     commercial: true,  attribution: true,  derivatives: true,  share: false },
  { id: 'cc-by-sa',  commercial: true,  attribution: true,  derivatives: true,  share: true  },
  { id: 'cc-by-nd',  commercial: true,  attribution: true,  derivatives: false, share: false },
  { id: 'cc-by-nc',  commercial: false, attribution: true,  derivatives: true,  share: false },
  { id: 'cc-by-nc-sa', commercial: false, attribution: true, derivatives: true, share: true  },
  { id: 'cc-by-nc-nd', commercial: false, attribution: true, derivatives: false, share: false },
  // Bought from the designer, which overrides whatever the free licence said.
  { id: 'commercial', commercial: true, attribution: false, derivatives: true,  share: false },
];

const byId = (id) => LICENCES.find((l) => l.id === str(id).toLowerCase()) || null;

/** Every licence, for a menu. Order is the order above: permissive first. */
function list() { return LICENCES.map((l) => ({ ...l })); }

/**
 * May a shop sell a print of this?
 *
 * @returns {boolean|null} `null` when nobody has recorded a licence — which is
 *   not the same as "no", and must not be shown as one.
 */
function sellable(licence) {
  const found = byId(licence);
  return found ? found.commercial : null;
}

/** Must the designer be credited when it is shown or sold? */
function needsAttribution(licence) {
  const found = byId(licence);
  return found ? found.attribution : false;
}

/** May it be modified — rescaled, remixed, cut up? */
function allowsDerivatives(licence) {
  const found = byId(licence);
  return found ? found.derivatives : null;
}

/**
 * What a shop should be told about one model, in facts rather than a sentence.
 *
 * `known` false means the record says nothing, and every other field is a
 * `null` the caller must not render as a refusal.
 */
function standing(record) {
  const r = record || {};
  const licence = str(r.licence).toLowerCase();
  const found = byId(licence);
  return {
    known: !!found,
    licence: found ? found.id : '',
    source: str(r.source),
    sellable: found ? found.commercial : null,
    attribution: found ? found.attribution : false,
    derivatives: found ? found.derivatives : null,
    share: found ? found.share : false,
  };
}

/**
 * The models a shop may NOT sell a print of.
 *
 * Only the ones actually recorded as non-commercial. A library where nothing
 * has been filled in returns an empty list rather than all of it — a warning
 * about every model is a warning nobody reads.
 */
function notForSale(records) {
  return (Array.isArray(records) ? records : []).filter((r) => sellable(r && r.licence) === false);
}

/**
 * Whether a BOUGHT licence has run out on `today` (`YYYY-MM-DD`).
 *
 * A designer's commercial licence is usually a subscription — a Patreon
 * merchant tier, a shop plan — and it covers sales only while it is paid. So a
 * `commercial` record may carry `licenceExpires`, the last day it covers, and
 * the day after it the model is no longer for sale. A Creative Commons licence
 * does not expire, and a record with no date, or one this cannot read, is
 * taken at its word rather than guessed at.
 */
function expired(record, today) {
  const r = record || {};
  if (str(r.licence).toLowerCase() !== 'commercial') return false;
  const until = str(r.licenceExpires);
  const day = str(today);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(until) || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return false;
  return until < day;
}

/**
 * May a print of this be sold TODAY — `sellable`, and a bought licence that
 * has lapsed is a no. Still three-valued: `null` when nobody has said.
 */
function sellableOn(record, today) {
  const yes = sellable(record && record.licence);
  return yes === true && expired(record, today) ? false : yes;
}

/**
 * The models behind a sale that may not be sold today, in the order asked.
 *
 * `ids` are the library ids a job's parts or a product's parts point at;
 * `records` is the library. Only models recorded as not for sale come back —
 * `not-commercial`, or `expired` for a bought licence past its date. A model
 * nobody has filled in is NOT a problem here, for the reason this module
 * exists: unknown is not no, and a warning on every sale is one nobody reads.
 */
function saleProblems(ids, records, today) {
  const list = Array.isArray(records) ? records : [];
  const seen = new Set();
  const out = [];
  for (const id of Array.isArray(ids) ? ids : []) {
    const key = str(id);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    const r = list.find((x) => x && str(x.id) === key);
    if (!r) continue;
    const plain = sellable(r.licence);
    if (plain === false) out.push({ id: key, name: str(r.name) || str(r.originalName), licence: str(r.licence).toLowerCase(), reason: 'not-commercial' });
    else if (plain === true && expired(r, today)) out.push({ id: key, name: str(r.name) || str(r.originalName), licence: 'commercial', reason: 'expired', until: str(r.licenceExpires) });
  }
  return out;
}

const api = { LICENCES, list, sellable, needsAttribution, allowsDerivatives, standing, notForSale,
              expired, sellableOn, saleProblems };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytModelLicence = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
