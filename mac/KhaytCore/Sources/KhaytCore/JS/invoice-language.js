'use strict';
(function () {

/**
 * Decide what language(s) a customer-facing document prints in.
 *
 * Khayt's invoices, quotes, credit notes and delivery notes were unconditionally
 * bilingual: every label rendered twice, the working language above and Arabic
 * below. That is right for the market it was built in and wrong everywhere else —
 * the second language is hardcoded Arabic, not "the user's other language", so a
 * French shop printed French and Arabic, and an English shop in Ohio sent
 * customers a quote captioned عرض سعر.
 *
 * The rule cannot simply be "print one language", because of ZATCA.
 *
 * ZATCA Phase 1 — Saudi Arabia's e-invoicing mandate — REQUIRES Arabic on a tax
 * invoice. For a shop operating under it, bilingual output is a legal obligation
 * and not a preference, so `enableZatca` outranks the setting rather than being
 * one more input to it. A shop cannot switch that off by accident and quietly
 * start issuing non-compliant invoices.
 *
 * Pure (no DOM, no globals) so the decision is unit-testable without rendering a
 * document.
 */

/**
 * - `auto`   — bilingual only where a second language earns its place (default)
 * - `both`   — always bilingual, for a shop serving two language groups
 * - `single` — the working language only
 */
const MODES = Object.freeze(['auto', 'both', 'single']);
const DEFAULT_MODE = 'auto';

/** Every language the app is translated into, and therefore can print. */
const LANGS = Object.freeze(['en', 'ar', 'de', 'es', 'fr', 'zh', 'ja', 'tr', 'pt-BR']);

/**
 * The second language when the shop has not picked one.
 *
 * Arabic pairs with everything else and English pairs with Arabic — the pairing
 * the templates were built around, and the one ZATCA expects. This is only the
 * DEFAULT now: a shop that invoices in English and French says so, and gets it.
 */
function defaultSecondaryFor(primary) {
  return primary === 'ar' ? 'en' : 'ar';
}

/**
 * The second language actually used: the shop's pick when it is a language we
 * can print and is not simply the primary again, otherwise the default pair.
 *
 * A document whose two languages are the same language is not bilingual, it is
 * the same labels printed twice — so that selection is refused here rather than
 * relied upon being unreachable in the UI.
 */
function resolveSecondary(primary, picked) {
  const p = String(picked || '');
  if (!LANGS.includes(p) || p === primary) return defaultSecondaryFor(primary);
  return p;
}

/**
 * @param {object}  opts
 * @param {string}  opts.mode         one of MODES; anything unrecognised reads as 'auto'
 * @param {string}  opts.lang         the working language ('en', 'ar', 'fr', …)
 * @param {string}  opts.secondary    the shop's chosen second language, if any
 * @param {boolean} opts.enableZatca  whether ZATCA e-invoicing fields are on
 * @returns {{bilingual: boolean, primary: string, secondary: string|null, forced: boolean}}
 *   `forced` is true when ZATCA overrode the choice — the caller says so rather
 *   than leaving a control that appears to work and does not.
 */
function resolveDocumentLanguage({ mode = DEFAULT_MODE, lang = 'en', secondary, enableZatca = false } = {}) {
  const primary = String(lang || 'en');
  const picked = resolveSecondary(primary, secondary);
  const both = (sec, f) => ({ bilingual: true, primary, secondary: sec, forced: f });

  // Legal requirement first — it is not one input among several.
  //
  // The requirement is specifically ARABIC, not "a second language", so a shop
  // that picked French while under ZATCA gets Arabic: an Arabic-free tax invoice
  // is non-compliant however many languages are on it. A shop already working IN
  // Arabic satisfies it with the primary, so there its pick is honoured.
  // `forced` means "ZATCA decided this, not the shop". A shop already working IN
  // Arabic satisfies the mandate with its primary language, so nothing is taken
  // away from it and its own choices stand. Everywhere else the outcome is
  // dictated — bilingual, with Arabic as the second language — whatever was
  // picked, and the UI says so rather than leaving two controls that appear to
  // work and do not.
  if (enableZatca) {
    return primary === 'ar' ? both(picked, false) : both('ar', true);
  }

  const m = MODES.includes(mode) ? mode : DEFAULT_MODE;
  if (m === 'both') return both(picked, false);
  if (m === 'single') return { bilingual: false, primary, secondary: null, forced: false };

  // auto: an Arabic shop keeps its second language, because that is the one
  // combination where the second line was already doing real work — Gulf shops
  // invoice international customers, and this is what stops the fix from
  // changing their documents underneath them. Everyone else gets the language
  // they chose, and opts in with 'both' if they want a second.
  return primary === 'ar' ? both(picked, false) : { bilingual: false, primary, secondary: null, forced: false };
}

/**
 * Whether the ZATCA toggle should start on for a shop setting up in `lang`.
 *
 * It shipped defaulting to ON for everyone, so a shop anywhere in the world got
 * Saudi e-invoicing fields, a ZATCA QR code and the line "ZATCA Phase 1 compliant
 * invoice" on documents sent to customers who have never heard of it — and,
 * once this module exists, would also have been forced bilingual by it forever.
 * Regional compliance has to be opted into by the region it applies to.
 */
function zatcaDefaultFor(lang) {
  return String(lang || '') === 'ar';
}

const api = { MODES, DEFAULT_MODE, LANGS, defaultSecondaryFor, resolveSecondary, resolveDocumentLanguage, zatcaDefaultFor };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytInvoiceLanguage = api;

})();
