'use strict';
(function (global) {

/**
 * The box-form VAT return: the figures a shop transcribes onto the return it
 * files (the Saudi GAZT form's boxes, or a VAT100's equivalents), and the
 * one-page document that shows them.
 *
 * ── WHY IT IS HERE AND NOT IN A SCREEN ───────────────────────────────────
 *
 * `renderer/operations-extras.js exportGaztVatReturn` worked it out inline.
 * The Mac prints the same document, and two copies of "what goes in Box 3" is
 * exactly the disagreement a tax return cannot have. The desktop calls
 * `boxes` and `html` now; its output is unchanged.
 *
 * ── THE RULES IT LEANS ON, NOT REWRITES ──────────────────────────────────
 *
 *   - which orders are invoiced, and on what day: `KhaytPnl.isTaxPoint` and
 *     `taxPointDate` — the invoice is the tax point, so a job still printing
 *     owes its tax in the period it is dated;
 *   - how a price splits into sale and tax: `KhaytTax.computeTax` over the
 *     shop's profile, the arithmetic every invoice uses;
 *   - what a FILED period's later changes do: `KhaytPnl.vatCorrections`, each
 *     counted on its own day, adjustments totalled on their own line;
 *   - what an order earned: the caller's `revenueOf` — the desktop and the Mac
 *     both pass `orderNetRevenueBase` (base currency, credit notes deducted,
 *     personal prints excluded).
 *
 * PURE: no DOM, no clock.
 */

function sibling(name, file) {
  if (typeof global !== 'undefined' && global[name]) return global[name];
  try { return require(file); } catch (e) { return null; }
}

/**
 * The figures for the days `from`..`to` inclusive (`YYYY-MM-DD`).
 *
 * @param {object[]} orders    the print log
 * @param {object[]} expenses  the expense book
 * @param {{settings, clients, currencies, from, to, revenueOf}} opts
 */
function boxes(orders, expenses, opts) {
  const o2 = opts || {};
  const Pnl = sibling('KhaytPnl', './pnl-report.js');
  const Tax = sibling('KhaytTax', './tax.js');
  const settings = o2.settings || {};
  const fromDate = String(o2.from || '');
  const toDate = String(o2.to || '');
  const revenueOf = typeof o2.revenueOf === 'function' ? o2.revenueOf : () => 0;

  const periodOrders = (Array.isArray(orders) ? orders : []).filter((o) => {
    const day = Pnl.taxPointDate(o);
    return Pnl.isTaxPoint(o) && day >= fromDate && day <= toDate;
  });

  const taxProfile = Tax.profileFromSettings(settings);
  const ratePct = taxProfile.rates.reduce((sum, r) => sum + r.percent, 0);
  const vatRegistered = ratePct > 0;
  const taxName = String(taxProfile.name || 'Tax');
  // A shop that predates the country presets has no settings.tax at all, and
  // every one of those was Saudi — including one with VAT switched off, which
  // is a registration state, not a country.
  const isSaudiForm = settings.tax ? (settings.tax.country || '') === 'SA' : true;

  let box1 = 0;   // standard-rated sales, NET of VAT
  let box2 = 0;   // zero-rated sales
  let box3 = 0;   // VAT due on those sales
  for (const o of periodOrders) {
    const gross = revenueOf(o);
    if (!gross) continue;
    if (vatRegistered) {
      const t = Tax.computeTax(gross, taxProfile);
      box1 += t.subtotal;
      box3 += t.taxTotal;
    } else {
      // ONE shop-level rate: no per-order zero-rating. Either the shop charges
      // tax on everything or on nothing.
      box2 += gross;
    }
  }

  // A FILED RETURN IS NOT REWRITTEN (lib/vat-periods.js).
  let adjSales = 0, adjVat = 0;
  if (vatRegistered && typeof Pnl.vatCorrections === 'function') {
    const corrections = Pnl.vatCorrections(orders, {
      settings, clients: o2.clients || [], currencies: o2.currencies,
    });
    for (const c of corrections) {
      if (!(c.day >= fromDate && c.day <= toDate)) continue;
      box1 += c.sales;
      box3 += c.vat;
      if (c.kind === 'adjustment') { adjSales += c.sales; adjVat += c.vat; }
    }
  }

  const periodExp = (Array.isArray(expenses) ? expenses : []).filter((e) => e && e.date >= fromDate && e.date <= toDate);
  const box6 = periodExp.reduce((s, e) => s + (+e.amount || 0), 0);
  // No expense form ever carried a VAT figure until `vatAmount`; a period
  // with none recorded leaves the line for the shop's own figure.
  const box7 = periodExp.reduce((s, e) => s + (+e.vatAmount || 0), 0);
  const box7Known = periodExp.some((e) => +e.vatAmount > 0);
  const netVat = box3 - box7;

  return {
    from: fromDate, to: toDate,
    taxName, ratePct, mode: taxProfile.mode, vatRegistered, isSaudiForm,
    box1, box2, box3, adjSales, adjVat, box6, box7, box7Known, netVat,
    invoices: periodOrders.length,
  };
}

function escapeHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[c]);
}

function fmtMoney(n) {
  return (Math.round((+n || 0) * 100) / 100).toFixed(2);
}

/**
 * The document, as the desktop has always printed it. English, like the
 * desktop's: it is a working paper to transcribe from, with the shop's own
 * tax name and box numbers only where they are the shop's own.
 *
 * @param {object} b  what `boxes` returned
 * @param {{shopName, periodTitle, currencySymbol}} opts
 */
function html(b, opts) {
  const o2 = opts || {};
  const taxName = b.taxName;
  const boxNo = (n) => (b.isSaudiForm ? `Box ${n}` : '');
  const periodTitle = String(o2.periodTitle || '');
  return `<!DOCTYPE html><html><head><meta charset="utf-8">
    <title>${escapeHtml(taxName)} summary — ${escapeHtml(periodTitle)}</title>
    <style>body{font-family:sans-serif;max-width:700px;margin:auto;padding:24px;}
      h1{font-size:18px;} table{width:100%;border-collapse:collapse;margin-top:16px;}
      th{background:#f3f4f6;text-align:left;padding:8px;border:1px solid #ddd;font-size:13px;}
      td{padding:8px;border:1px solid #ddd;font-size:13px;}
      .net{font-weight:700;background:#fef3c7;}
      .warn{margin-top:16px;padding:10px 12px;border:1px solid #f59e0b;background:#fffbeb;font-size:12px;}</style></head>
    <body>
      <h1>${escapeHtml(taxName)} summary — ${escapeHtml(o2.shopName || '')} (${escapeHtml(periodTitle)})</h1>
      <p style="font-size:12px;color:#666;">Period: ${escapeHtml(b.from)} to ${escapeHtml(b.to)}</p>
      <table>
        <thead><tr><th>Box</th><th>Description</th><th>Amount (${escapeHtml(o2.currencySymbol || '')})</th></tr></thead>
        <tbody>
          <tr><td>${boxNo(1)}</td><td>Sales at the standard rate (net of ${escapeHtml(taxName)})</td><td>${fmtMoney(b.box1)}</td></tr>
          <tr><td>${boxNo(2)}</td><td>Sales at zero rate</td><td>${fmtMoney(b.box2)}</td></tr>
          <tr><td>${boxNo(3)}</td><td>${escapeHtml(taxName)} collected on sales</td><td>${fmtMoney(b.box3)}</td></tr>
          ${(b.adjVat || b.adjSales) ? `<tr><td></td><td>of which: adjustment for a filed period (sales ${fmtMoney(b.adjSales)})</td><td>${fmtMoney(b.adjVat)}</td></tr>` : ''}
          <tr><td>${boxNo(6)}</td><td>Total purchases</td><td>${fmtMoney(b.box6)}</td></tr>
          <tr><td>${boxNo(7)}</td><td>${escapeHtml(taxName)} paid on purchases (recoverable)</td><td>${b.box7Known ? fmtMoney(b.box7) : '&mdash;'}</td></tr>
          <tr class="net"><td colspan="2">Net ${escapeHtml(taxName)} payable</td><td>${fmtMoney(b.netVat)}</td></tr>
        </tbody>
      </table>
      ${b.box7Known ? '' : `<p class="warn">Khayt does not record ${escapeHtml(taxName)} on expenses, so the
        recoverable line is blank and the net figure assumes nothing is reclaimable. Add your own
        figure before filing.</p>`}
      <p class="warn">This is a summary to transcribe onto the return you file &mdash; not the return
        itself. Khayt applies one rate to every sale, so a shop with mixed or exempt rating must
        split these figures itself.${b.isSaudiForm ? '' : ' The box numbers on your form will differ.'}</p>
      <p style="font-size:12px;color:#666;margin-top:16px;">${b.mode === 'inclusive'
        ? `Prices in Khayt include ${escapeHtml(taxName)} at ${escapeHtml(String(b.ratePct))}%, and sales are shown with it removed.`
        : `Prices in Khayt exclude ${escapeHtml(taxName)}; it is added at ${escapeHtml(String(b.ratePct))}% and shown separately.`}</p>
    </body></html>`;
}

const api = { boxes, html };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytVatReturn = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
