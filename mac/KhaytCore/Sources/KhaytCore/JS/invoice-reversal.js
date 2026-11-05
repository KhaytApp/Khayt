'use strict';
/**
 * Taking an invoice back: voiding it, or crediting some or all of it.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * Both lived in `renderer/invoicing.js` (`voidInvoice`, `generateCreditNote`),
 * so the Mac app read `voidedAt` and `creditNotes[]` — every money figure in
 * lib/ honours them — and had no way to write either. The records are written
 * here now and both apps write them.
 *
 * ── THE RECORDS ───────────────────────────────────────────────────────────
 *
 * A VOID stamps the job: `voidedAt`, `voidedReason`, `paymentStatus: 'voided'`
 * and a `voided` entry in `statusHistory`. The status itself is kept — a void
 * is about the invoice, not about where the work is. Optionally the material
 * the job used is booked as waste (`wasteRow`).
 *
 * A CREDIT NOTE is `{ id, amount, reason, issuedAt }` pushed onto
 * `creditNotes[]`. It reduces what is DUE; `paidAmount` is never touched, so
 * the credit is counted once (lib/order-money.js and lib/order-payment.js
 * subtract it). Credited in full, the job is stamped `creditedAt` and reads
 * as voided for reporting.
 *
 * ── WHAT IS NOT DECIDED HERE ──────────────────────────────────────────────
 *
 * A credit note's printed number is `CN-` + the job's id, as the desktop has
 * always printed it. Whether a credit note needs its own legal sequence (as a
 * ZATCA Phase 2 credit note would) is the owner's decision; until then the
 * number follows the job it reverses.
 *
 * PURE: no clock (`now` is passed), no randomness (ids are passed). Changes
 * the order it is handed IN PLACE, as the desktop's flows always have, and
 * returns it.
 */
(function (global) {
  const HISTORY_CAP = 200;
  const arrayOf = (v) => (Array.isArray(v) ? v : []);
  const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };

  /** What the job's parts weighed and what they were made of, for its waste row. */
  function materialOf(order) {
    const o = order || {};
    const weight = arrayOf(o.parts).reduce((s, p) => s + (num(p && p.weightG) || num(p && p.printWeight)), 0);
    const material = o.material || (arrayOf(o.parts).find((p) => p && p.material) || {}).material || '';
    return { weight, material, loggable: weight > 0 && !!material };
  }

  /**
   * Void the job's invoice. `opts` is `{ reason, now, logWaste, wasteId,
   * today, wasteNote, defaultReason }`. Returns `{ ok, order, waste }` —
   * `waste` the row to put at the TOP of `wasteLog` when `logWaste` asked for
   * one and the job has the weight and material to book — or
   * `{ ok: false, error: 'already_voided' }`.
   */
  function voidInvoice(order, opts) {
    const o = opts || {};
    if (!order) return { ok: false, error: 'gone' };
    if (order.voidedAt) return { ok: false, error: 'already_voided' };
    const at = o.now;
    order.voidedAt = at;
    order.voidedReason = String(o.reason == null ? '' : o.reason).trim() || o.defaultReason || 'Voided';
    order.paymentStatus = 'voided';
    if (!Array.isArray(order.statusHistory)) order.statusHistory = [];
    order.statusHistory.push({ status: 'voided', at });
    if (order.statusHistory.length > HISTORY_CAP) order.statusHistory = order.statusHistory.slice(-HISTORY_CAP);
    let waste = null;
    const m = materialOf(order);
    if (o.logWaste && m.loggable) {
      waste = {
        id: o.wasteId,
        date: o.today,
        orderId: order.id,
        machineId: order.machineId || null,
        material: m.material,
        weight: m.weight,
        failureType: 'operator_error',
        notes: o.wasteNote || '',
        cost: 0,
      };
    }
    return { ok: true, order, waste };
  }

  /** What has been credited on the job so far. */
  function credited(order) {
    return arrayOf(order && order.creditNotes).reduce((s, cn) => s + num(cn && cn.amount), 0);
  }

  /**
   * The most a new credit note can be for: the job's price, less what is
   * already credited. The desktop capped each note at the price alone, so two
   * notes could credit a job twice over; the remainder is the honest ceiling.
   */
  function creditRoom(order) {
    return Math.max(0, Math.round((num(order && order.price) - credited(order)) * 100) / 100);
  }

  /**
   * Issue a credit note. `opts` is `{ amount, reason, now, id }`; the amount
   * is held between 0.01 and `creditRoom`. Returns `{ ok, order, note }`, or
   * `{ ok: false, error: 'nothing_to_credit' }` when the job is credited in
   * full already (or was never priced).
   */
  function creditNote(order, opts) {
    const o = opts || {};
    if (!order) return { ok: false, error: 'gone' };
    const room = creditRoom(order);
    if (room < 0.01) return { ok: false, error: 'nothing_to_credit' };
    const typed = num(o.amount);
    const amount = Math.round(Math.min(Math.max(0.01, typed || room), room) * 100) / 100;
    if (!Array.isArray(order.creditNotes)) order.creditNotes = [];
    const note = { id: o.id, amount, reason: String(o.reason == null ? '' : o.reason).trim(), issuedAt: o.now };
    order.creditNotes.push(note);
    // Credited in full reads as voided for reporting (order-payment statusOf).
    if (credited(order) >= num(order.price)) order.creditedAt = o.now;
    return { ok: true, order, note };
  }

  /** The number a credit note prints under "No.". */
  function creditNoteNumber(order) {
    return 'CN-' + String((order && order.id) || '');
  }

  /**
   * The credit note a customer is handed — the desktop's document, moved here
   * so both apps print the same one. `ctx` carries the host's ways of saying
   * things, as `lib/invoice-document.js` does: `{ t, i18n, escapeHtml,
   * fmtMoney, formatPrintDate, settings, shopName, logo, BRAND_MARK_SVG,
   * currencySymbol, jobRef, invoiceNumber, clientName, clientSub, today }`.
   * Returns `{ html, arabicNumerals, selector }`, the shape the invoice has.
   */
  function creditNoteHtml(order, note, ctx) {
    const c = ctx || {};
    const t = c.t || ((k) => k);
    const esc = c.escapeHtml || ((s) => String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;'));
    const money = c.fmtMoney || ((n) => num(n).toFixed(2));
    const date = c.formatPrintDate || ((d) => String(d || ''));
    const settings = c.settings || {};
    const i18n = c.i18n || { current: 'en' };
    const lang = i18n.current || 'en';
    const isAr = lang === 'ar';
    const L = global.KhaytInvoiceLanguage;
    const dl = L && typeof L.resolveDocumentLanguage === 'function'
      ? L.resolveDocumentLanguage({ mode: settings.invoiceBilingual, lang,
          secondary: settings.invoiceSecondLang, enableZatca: settings.enableZatca })
      : { bilingual: false, secondary: null };
    const second = dl.bilingual && typeof i18n.tIn === 'function' ? i18n.tIn(dl.secondary, 'doc.credit_note') : '';
    const o = order || {};
    const n = note || {};
    const ref = c.jobRef || o.jobNumber || o.id || '';
    const sym = c.currencySymbol || '';
    const amount = money(n.amount);
    const logo = c.logo || '';
    const clientName = c.clientName || String(o.project || '').trim() || t('inv.walk_in');
    const html = `
    <div class="inv-wrap">
    <div class="inv-top-bar" style="background:#b91c1c;"></div>
    <div class="inv" dir="${isAr ? 'rtl' : 'ltr'}" lang="${esc(lang)}" style="--brand:#7f1d1d; --accent:#dc2626; --highlight:#fee2e2;">
      <div class="inv-header">
        <div class="biz">
          <div class="mark">${logo ? `<img src="${esc(logo)}" style="max-height:60px; max-width:120px; object-fit:contain;" alt="logo">` : (c.BRAND_MARK_SVG || '')}</div>
          <div class="biz-name">
            <h1>${esc(c.shopName || 'Khayt')}</h1>
          </div>
        </div>
        <div class="doc">
          <div class="title" style="color:#dc2626;">${esc(t('doc.credit_note'))}</div>
          ${second ? `<div class="title-ar ${isAr ? 'ltr' : 'ar'}">${esc(second)}</div>` : ''}
          <div class="meta">
            <div class="meta-row"><span class="k">${esc(t('doc.no'))}</span><span class="v">${esc(creditNoteNumber(o))}</span></div>
            <div class="meta-row"><span class="k">${esc(t('doc.date'))}</span><span class="v">${esc(date(c.today || n.issuedAt))}</span></div>
            <div class="meta-row"><span class="k">${esc(t('doc.ref'))}</span><span class="v">${esc(ref)}</span></div>
          </div>
        </div>
      </div>

      <div class="cn-ref-line">
        ${esc(t('cn.reversal_of'))}: <strong>#${esc(c.invoiceNumber || ref)}</strong>
        ${o.date ? ` &mdash; ${esc(t('cn.original_date'))}: ${esc(date(o.date))}` : ''}
      </div>

      <div class="bill-to">
        <div class="label"><span>${esc(t('doc.issued_to'))}</span></div>
        <div>
          <div class="name">${esc(clientName)}</div>
          ${c.clientSub ? `<div class="name-sub">${esc(c.clientSub)}</div>` : ''}
        </div>
      </div>

      <table class="lines">
        <thead>
          <tr>
            <th>${esc(t('doc.description'))}</th>
            <th style="text-align:center; width:60px;">${esc(t('doc.qty'))}</th>
            <th class="th-amount" style="width:150px;">${esc(t('doc.amount'))}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <div class="desc-en">${esc(t('doc.credit_note'))} — ${esc(o.project || ref)}</div>
              ${n.reason ? `<div class="meta">${esc(n.reason)}</div>` : ''}
            </td>
            <td class="center">1</td>
            <td class="amount" style="color:#dc2626;">−${esc(amount)} <span style="color:#666; font-weight:500;">${sym}</span></td>
          </tr>
        </tbody>
      </table>

      <div class="totals">
        <div class="summary">
          <div class="row grand">
            <span class="label-en" style="color:#dc2626;">${esc(t('doc.credit_total'))}</span>
            <span class="v" style="color:#dc2626;">−${esc(amount)}<span class="unit">${sym}</span></span>
          </div>
        </div>
      </div>

      <div class="footer">
        <div class="legal">${esc(t('doc.generated_by'))}</div>
      </div>
    </div>
    </div>`;
    return { html, arabicNumerals: !!(isAr && settings.useArabicNumerals), selector: '.v, .amount, .meta-row' };
  }

  const api = { HISTORY_CAP, materialOf, voidInvoice, credited, creditRoom, creditNote, creditNoteNumber, creditNoteHtml };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytInvoiceReversal = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
