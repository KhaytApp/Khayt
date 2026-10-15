'use strict';
/**
 * The VAT a shop owes for a stretch of time: what it charged on its sales,
 * what it paid on its purchases, and the difference it remits.
 *
 * ── NOT A SECOND TAX ENGINE ───────────────────────────────────────────────
 *
 * Every figure is already worked out, per period, by `lib/pnl-report.js`'s
 * `pnlByPeriod`: `vatCollected` is `computeTax(charged).taxTotal` on each
 * finished, unvoided, business job — which EXTRACTS the tax under inclusive
 * pricing and ADDS it under exclusive, so it is right in either mode — and
 * `vatReclaimable` is each expense's own `vatAmount`, read off the supplier's
 * invoice. This sums those rows, over the span the shop chose, so the summary
 * and the P&L beside it are one answer and cannot drift apart.
 *
 * MODE-AWARE all the same, for what it SAYS: an inclusive shop's revenue had
 * the tax taken out of it; an exclusive shop's revenue is the price it typed,
 * and the tax sat on top. The mode is returned so the screen can say which.
 *
 * A SHOP WITH NO TAX SET — no rates — owes nothing and reclaims nothing, and
 * `applies` is false: the screen hides the summary rather than print three
 * zeros that look like a filed return.
 *
 * INPUT VAT IS ONLY WHAT WAS RECORDED. An expense carries `vatAmount` when the
 * shop typed it (or read it off a ZATCA QR); one entered without it reclaims
 * nothing, and nothing here guesses a rate for it — a receipt can carry two
 * rates, an import none. How many of the span's expenses carry none is
 * counted (`expensesWithoutVat`), so the screen can say why the input figure
 * may be low instead of leaving the shop to wonder.
 *
 * Pure: no DOM, no clock. The tax rule is read through `KhaytTax`.
 */
(function (global) {
  const round2 = (n) => Math.round(((+n || 0) + Number.EPSILON) * 100) / 100;

  function taxModule() {
    if (typeof global !== 'undefined' && global.KhaytTax) return global.KhaytTax;
    if (typeof require === 'function') {
      try { return require('./tax.js'); } catch (_) { return null; }
    }
    return null;
  }

  /** Is this book day inside `{ from, to }` (either end optional)? */
  function inSpan(dateStr, range) {
    if (!range || (!range.from && !range.to)) return true;
    const ds = String(dateStr || '').slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(ds)) return false;
    if (range.from && ds < String(range.from).slice(0, 10)) return false;
    if (range.to && ds > String(range.to).slice(0, 10)) return false;
    return true;
  }

  /**
   * @param {Array} rows  pnlByPeriod's rows for the span (already narrowed)
   * @param {object} [ctx] `{ settings, expenses, range: { from, to } }` —
   *   `expenses` (the book's, unnarrowed) only feed the recorded/unrecorded
   *   count, narrowed here to `range` the same way the P&L narrows them.
   * @returns {{ applies:boolean, name:string, mode:string,
   *   rates:Array<{label:string, percent:number}>, sales:number, output:number,
   *   input:number, net:number, position:'payable'|'refund'|'nil',
   *   expensesWithVat:number, expensesWithoutVat:number }}
   */
  function summarize(rows, ctx) {
    const c = ctx || {};
    const T = taxModule();
    const profile = T ? T.profileFromSettings(c.settings || {}) : { name: 'Tax', mode: 'inclusive', rates: [] };
    const rates = Array.isArray(profile.rates) ? profile.rates : [];
    const empty = {
      applies: false, name: String(profile.name || 'Tax'), mode: profile.mode || 'inclusive',
      rates: [], sales: 0, output: 0, input: 0, net: 0, position: 'nil',
      expensesWithVat: 0, expensesWithoutVat: 0,
    };
    if (!rates.length) return empty;

    let sales = 0, output = 0, input = 0;
    for (const r of Array.isArray(rows) ? rows : []) {
      if (!r) continue;
      sales += +r.revenue || 0;
      output += +r.vatCollected || 0;
      input += +r.vatReclaimable || 0;
    }
    let withVat = 0, without = 0;
    for (const e of Array.isArray(c.expenses) ? c.expenses : []) {
      if (!e || !(+e.amount > 0) || !inSpan(e.date, c.range)) continue;
      if ((+e.vatAmount || 0) > 0) withVat += 1; else without += 1;
    }
    const net = round2(round2(output) - round2(input));
    return {
      applies: true,
      name: String(profile.name || 'Tax'),
      mode: profile.mode || 'inclusive',
      rates: rates.map((r) => ({ label: String(r.label || ''), percent: +r.percent || 0 })),
      // What the shop earned on the sales the tax was charged on — revenue,
      // already net of the tax in both modes.
      sales: round2(sales),
      output: round2(output),
      input: round2(input),
      // Negative is a real position: a span in which the shop bought more
      // than it sold is one in which the authority owes it.
      net,
      position: net > 0 ? 'payable' : net < 0 ? 'refund' : 'nil',
      expensesWithVat: withVat,
      expensesWithoutVat: without,
    };
  }

  const api = { summarize, inSpan };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytVatSummary = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
