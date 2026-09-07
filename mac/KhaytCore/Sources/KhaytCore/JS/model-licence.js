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

const api = { LICENCES, list, sellable, needsAttribution, allowsDerivatives, standing, notForSale };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytModelLicence = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
