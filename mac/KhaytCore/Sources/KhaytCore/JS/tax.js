'use strict';
(function () {

/**
 * Sales tax, for shops that are not in Saudi Arabia.
 *
 * Khayt was built around one tax, at one rate, priced one way: VAT, 15%, and the
 * listed price INCLUDES it. That is correct for the Gulf and for most of Europe,
 * and wrong for the two largest English-speaking markets. In the US and Canada a
 * price is quoted WITHOUT tax and the tax is added at the end, which is not a
 * formatting difference — it changes what the customer is asked to pay.
 *
 * The old arithmetic (`price * rate / (100 + rate)`) was written out by hand in
 * ten places across analytics, clients, expenses, invoicing and the exports.
 * Duplicating it once more for exclusive pricing would be eleven, so this module
 * owns the arithmetic and everything else asks it.
 *
 * Three things it has to get right that a single rate never exposed:
 *
 *  - **More than one tax.** Canada charges GST and PST together; India charges
 *    CGST and SGST. Both must appear on the invoice as separate lines, because
 *    they are separate remittances to separate authorities.
 *  - **Compound tax.** A rate that applies to the base PLUS the taxes before it,
 *    rather than to the base alone.
 *  - **Pennies.** On an inclusive total the tax is extracted, not added, so
 *    rounding each line independently can leave subtotal + taxes ≠ total. On a
 *    legal document that discrepancy is not cosmetic, so the remainder is
 *    allocated rather than dropped.
 *
 * Pure: no DOM, no settings, no globals.
 */

/** Prices as entered by the shop already contain the tax, or do not. */
const MODES = Object.freeze(['inclusive', 'exclusive']);
const DEFAULT_MODE = 'inclusive';

const round2 = (n) => Math.round((n + Number.EPSILON) * 100) / 100;

/** Normalise one rate entry, dropping anything unusable. */
function normalizeRate(r, i) {
  if (!r || typeof r !== 'object') return null;
  const percent = Number(r.percent);
  if (!Number.isFinite(percent) || percent < 0) return null;
  return {
    id: String(r.id || `t${i}`),
    label: String(r.label || '').trim() || 'Tax',
    percent,
    // A compound rate is charged on the base plus everything already added.
    compound: !!r.compound,
  };
}

function normalizeRates(rates) {
  return (Array.isArray(rates) ? rates : [])
    .map(normalizeRate)
    .filter(Boolean)
    .filter((r) => r.percent > 0);
}

/**
 * The effective multiplier a set of rates applies to a base of 1.
 *
 * Non-compound rates all sit on the base; a compound rate sits on the base plus
 * everything accumulated before it. Computed in one place because the inclusive
 * case has to invert exactly this to recover the base from a total.
 */
function grossFactor(rates) {
  let factor = 1;
  for (const r of rates) {
    factor += (r.compound ? factor : 1) * (r.percent / 100);
  }
  return factor;
}

/**
 * Break an amount into subtotal, tax lines and total.
 *
 * @param {number} amount   exclusive: the pre-tax price. inclusive: the price the
 *                          customer sees, tax already in it.
 * @param {object} profile  { mode, rates: [{id,label,percent,compound}] }
 * @returns {{subtotal:number, taxes:Array<{id,label,percent,amount}>, taxTotal:number, total:number, mode:string}}
 *
 * The guarantee: `subtotal + taxTotal === total`, exactly, at 2dp — in BOTH
 * modes. Callers put these three numbers on an invoice next to each other, and a
 * penny that does not add up is a support ticket.
 */
function computeTax(amount, profile = {}) {
  const mode = MODES.includes(profile.mode) ? profile.mode : DEFAULT_MODE;
  const rates = normalizeRates(profile.rates);
  const amt = Number(amount);
  const base0 = Number.isFinite(amt) ? amt : 0;

  if (!rates.length) {
    const v = round2(base0);
    return { subtotal: v, taxes: [], taxTotal: 0, total: v, mode };
  }

  // Exclusive: the amount IS the subtotal and tax is added on top.
  // Inclusive: the amount is the total, so recover the subtotal by dividing out
  // the same factor the exclusive case would have multiplied by.
  const subtotalRaw = mode === 'exclusive' ? base0 : base0 / grossFactor(rates);

  let running = subtotalRaw;
  const taxesRaw = rates.map((r) => {
    const on = r.compound ? running : subtotalRaw;
    const t = on * (r.percent / 100);
    running += t;
    return { id: r.id, label: r.label, percent: r.percent, amount: t };
  });

  const subtotal = round2(subtotalRaw);
  const taxes = taxesRaw.map((t) => ({ ...t, amount: round2(t.amount) }));
  const totalRaw = mode === 'exclusive' ? subtotalRaw + taxesRaw.reduce((s, t) => s + t.amount, 0) : base0;
  const total = round2(totalRaw);

  // Reconcile the pennies. Rounding subtotal and each tax independently can
  // leave the parts a cent away from the whole; push the difference onto the
  // LARGEST tax line, where a cent is proportionally least visible and — for the
  // single-tax case that is almost everyone — is simply exact.
  let taxTotal = round2(taxes.reduce((s, t) => s + t.amount, 0));
  const drift = round2(total - subtotal - taxTotal);
  if (drift !== 0 && taxes.length) {
    let big = 0;
    for (let i = 1; i < taxes.length; i++) if (taxes[i].amount > taxes[big].amount) big = i;
    taxes[big] = { ...taxes[big], amount: round2(taxes[big].amount + drift) };
    taxTotal = round2(taxes.reduce((s, t) => s + t.amount, 0));
  }

  return { subtotal, taxes, taxTotal, total, mode };
}

/**
 * Country presets.
 *
 * `mode` is the local CONVENTION for how a shop quotes a price, which is the
 * part that cannot be guessed from a rate. `registration` is what the shop's tax
 * number is called — printing "VAT No." above an Australian ABN is wrong in a way
 * an accountant notices immediately.
 *
 * Rates move, and this is a starting point a shop edits, not an authority. It is
 * deliberately not exhaustive: an unlisted country gets the generic profile and
 * types its own rate, which is better than a confidently wrong default.
 */
const PRESETS = Object.freeze({
  SA: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] },
  AE: { name: 'VAT', mode: 'inclusive', registration: 'TRN', rates: [{ id: 'vat', label: 'VAT', percent: 5 }] },
  KW: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [] },
  QA: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [] },
  BH: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 10 }] },
  OM: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 5 }] },
  EG: { name: 'VAT', mode: 'inclusive', registration: 'Tax No.', rates: [{ id: 'vat', label: 'VAT', percent: 14 }] },
  JO: { name: 'GST', mode: 'inclusive', registration: 'Tax No.', rates: [{ id: 'gst', label: 'GST', percent: 16 }] },
  GB: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 20 }] },
  DE: { name: 'VAT', mode: 'inclusive', registration: 'USt-IdNr.', rates: [{ id: 'vat', label: 'USt.', percent: 19 }] },
  FR: { name: 'VAT', mode: 'inclusive', registration: 'N° TVA', rates: [{ id: 'vat', label: 'TVA', percent: 20 }] },
  ES: { name: 'VAT', mode: 'inclusive', registration: 'NIF-IVA', rates: [{ id: 'vat', label: 'IVA', percent: 21 }] },
  IT: { name: 'VAT', mode: 'inclusive', registration: 'P. IVA', rates: [{ id: 'vat', label: 'IVA', percent: 22 }] },
  NL: { name: 'VAT', mode: 'inclusive', registration: 'BTW-nr.', rates: [{ id: 'vat', label: 'BTW', percent: 21 }] },
  PT: { name: 'VAT', mode: 'inclusive', registration: 'NIF', rates: [{ id: 'vat', label: 'IVA', percent: 23 }] },
  IE: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 23 }] },
  CH: { name: 'VAT', mode: 'inclusive', registration: 'MWST-Nr.', rates: [{ id: 'vat', label: 'MWST', percent: 8.1 }] },
  NO: { name: 'VAT', mode: 'inclusive', registration: 'Org. nr.', rates: [{ id: 'vat', label: 'MVA', percent: 25 }] },
  SE: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'Moms', percent: 25 }] },
  TR: { name: 'VAT', mode: 'inclusive', registration: 'VKN', rates: [{ id: 'vat', label: 'KDV', percent: 20 }] },
  ZA: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] },
  AU: { name: 'GST', mode: 'inclusive', registration: 'ABN', rates: [{ id: 'gst', label: 'GST', percent: 10 }] },
  NZ: { name: 'GST', mode: 'inclusive', registration: 'GST No.', rates: [{ id: 'gst', label: 'GST', percent: 15 }] },
  SG: { name: 'GST', mode: 'inclusive', registration: 'GST Reg. No.', rates: [{ id: 'gst', label: 'GST', percent: 9 }] },
  JP: { name: 'Consumption Tax', mode: 'inclusive', registration: 'Reg. No.', rates: [{ id: 'ct', label: '消費税', percent: 10 }] },
  IN: { name: 'GST', mode: 'exclusive', registration: 'GSTIN', rates: [
    { id: 'cgst', label: 'CGST', percent: 9 },
    { id: 'sgst', label: 'SGST', percent: 9 },
  ] },
  // The two markets the old single-inclusive-rate model got wrong.
  US: { name: 'Sales Tax', mode: 'exclusive', registration: 'EIN', rates: [] },
  CA: { name: 'GST/PST', mode: 'exclusive', registration: 'GST/HST No.', rates: [
    { id: 'gst', label: 'GST', percent: 5 },
  ] },
  MX: { name: 'VAT', mode: 'inclusive', registration: 'RFC', rates: [{ id: 'vat', label: 'IVA', percent: 16 }] },
  BR: { name: 'Tax', mode: 'inclusive', registration: 'CNPJ', rates: [] },
});

/** The fallback for anywhere not listed: name the tax, charge nothing until told. */
const GENERIC = Object.freeze({ name: 'Tax', mode: 'inclusive', registration: 'Tax No.', rates: [] });

function presetFor(country) {
  const key = String(country || '').toUpperCase();
  return PRESETS[key] ? { ...PRESETS[key], rates: PRESETS[key].rates.map((r) => ({ ...r })) } : { ...GENERIC, rates: [] };
}

/**
 * Build a tax profile from settings, including the pre-tax-engine shape.
 *
 * Every existing shop has `enableVat` + `vatRate` and nothing else, and their
 * prices are tax-INCLUSIVE because that is the only thing Khayt ever did. That
 * has to keep computing the identical number, so the legacy path is an explicit
 * branch rather than a default that happens to line up.
 */
function profileFromSettings(settings = {}) {
  const s = settings || {};
  if (s.tax && typeof s.tax === 'object' && Array.isArray(s.tax.rates)) {
    return {
      name: String(s.tax.name || 'Tax'),
      mode: MODES.includes(s.tax.mode) ? s.tax.mode : DEFAULT_MODE,
      registration: String(s.tax.registration || 'Tax No.'),
      rates: normalizeRates(s.tax.rates),
    };
  }
  const on = !!s.enableVat;
  const percent = Number(s.vatRate);
  return {
    name: 'VAT',
    mode: 'inclusive',
    registration: 'VAT No.',
    rates: on && Number.isFinite(percent) && percent > 0
      ? [{ id: 'vat', label: 'VAT', percent, compound: false }]
      : [],
  };
}

/**
 * What a price is worth as REVENUE, with the tax taken out of it.
 *
 * ZATCA and IFRS 15 agree and are not optional about it: tax collected on a sale
 * is money held for the government, not income. It belongs on the balance sheet
 * as a liability until it is remitted, and it must never appear in the profit
 * and loss.
 *
 * MODE-AWARE, AND THAT IS THE WHOLE POINT. Under `inclusive` the price already
 * contains the tax and this returns less than it was given; under `exclusive`
 * the price IS the net figure and this returns it unchanged. A report that
 * subtracts the tax unconditionally is wrong for half the world's shops in the
 * opposite direction to the one it is trying to fix.
 *
 * A shop with no rates — not registered — has no tax to take out, and gets its
 * own number back.
 *
 * @param {number} amount the price as the shop enters it
 * @param {object} profile from `profileFromSettings`
 */
function netOfTax(amount, profile) {
  const n = +amount || 0;
  if (!profile || !Array.isArray(profile.rates) || !profile.rates.length) return n;
  return computeTax(n, profile).subtotal;
}

const api = {
  MODES, DEFAULT_MODE, PRESETS, GENERIC,
  computeTax, grossFactor, normalizeRates, presetFor, profileFromSettings,
  netOfTax,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytTax = api;

})();
