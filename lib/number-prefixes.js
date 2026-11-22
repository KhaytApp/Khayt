'use strict';
(function (global) {

/**
 * The two number prefixes a shop sets, and when to show them as one.
 *
 * ── TWO NUMBERS, NOT ONE ──────────────────────────────────────────────────
 *
 * `settings.invPrefix` starts a JOB's number and id (`lib/order-new.js`
 * `newOrder`, `lib/recurring-orders.js`). `settings.invNumPrefix` starts the
 * formal TAX INVOICE number, off its own counter (`invNumNext`,
 * `invNumFormat`). `lib/invoice-document.js` keeps them apart on purpose: a
 * shop whose job is `ATH-2026-0012` may carry invoice `INV-2026-0012`, and a
 * reprint must show the number that was issued. So both keys stay, and
 * nothing here ever renames, migrates or renumbers anything.
 *
 * ── ONE FIELD WHILE THEY AGREE ────────────────────────────────────────────
 *
 * Both apps showed both, each labelled as THE invoice prefix, in two
 * different places — a shop set one and wondered why its invoices did not
 * change. Nearly every shop has them equal (the default is `INV` for both),
 * so while they are equal the settings show ONE field, "Invoice number
 * prefix", that writes both. When they differ, two fields, honestly named:
 * "Job number prefix" and "Tax invoice prefix". Decided Nov 9 2026 (Turki).
 *
 * Equal means equal as USED: trimmed, and blank read as `INV`, which is what
 * every numbering rule does with a blank. A shop with `invPrefix: "INV"` and
 * no `invNumPrefix` has one prefix, not two.
 *
 * Issued numbers are never touched: a new prefix applies to numbers made
 * after it is saved, which is how both counters already work.
 *
 * PURE: no store, no DOM, no clock. The Mac's `NumberPrefixes` (KhaytCore)
 * is the same rule, checked against this file.
 */

const DEFAULT = 'INV';
/** The longest prefix either app keeps (`invoiceNumbering`'s cap, Nov 2026). */
const MAX = 10;

/** As a numbering rule reads it: a string, trimmed; anything else is blank. */
function used(v) {
  const t = typeof v === 'string' ? v.trim() : '';
  return t || DEFAULT;
}

/**
 * As it is kept: trimmed, cut to `MAX` UTF-16 units (stepping back one when
 * the cut would leave half of a surrogate pair), `INV` when blank.
 */
function clean(v) {
  let t = typeof v === 'string' ? v.trim() : '';
  if (t.length > MAX) {
    t = t.slice(0, MAX);
    const last = t.charCodeAt(t.length - 1);
    if (last >= 0xD800 && last <= 0xDBFF) t = t.slice(0, -1);
  }
  return t || DEFAULT;
}

/**
 * What the settings show: `{ shared }` while the two prefixes are the same
 * as used, else `{ job, taxInvoice }`.
 */
function prefixView(settings) {
  const s = settings && typeof settings === 'object' ? settings : {};
  const job = used(s.invPrefix);
  const taxInvoice = used(s.invNumPrefix);
  return job === taxInvoice ? { shared: job } : { job, taxInvoice };
}

/**
 * The keys to write for what was typed. `{ shared }` writes both prefixes;
 * `{ job, taxInvoice }` writes each one given. Keys not given are left out,
 * so the patch never touches anything else — not the counter, not the format,
 * not a number already issued.
 */
function prefixPatch(input) {
  const f = input && typeof input === 'object' ? input : {};
  const has = (k) => Object.prototype.hasOwnProperty.call(f, k);
  if (has('shared')) {
    const v = clean(f.shared);
    return { invPrefix: v, invNumPrefix: v };
  }
  const out = {};
  if (has('job')) out.invPrefix = clean(f.job);
  if (has('taxInvoice')) out.invNumPrefix = clean(f.taxInvoice);
  return out;
}

const api = { DEFAULT, MAX, prefixView, prefixPatch, clean };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytNumberPrefixes = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
