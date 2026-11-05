'use strict';

/**
 * The shop's other papers: the packing slip, the delivery note, the work order
 * and a customer's account statement.
 *
 * Each lived as a template string inside a renderer handler, so only the
 * Electron window could print one. The native Mac app could invoice a job and
 * could not hand anybody the slip that goes in the box with it. The bodies
 * moved here UNCHANGED and their renderer globals became one argument, `ctx`,
 * the way `lib/invoice-document.js` was lifted before them — so the desktop
 * prints exactly what it printed, and the Mac prints the same paper.
 *
 * RETURNS STRINGS. Printing is each app's own business: the desktop writes the
 * packing slip into a window of its own and the other three into
 * `#invoice-print-area`; the Mac draws them in WebKit and saves a PDF.
 *
 * PURE: no globals beyond the sibling modules every host loads first
 * (`KhaytInvoiceLanguage`), no clock beyond what `ctx` hands in.
 *
 * `ctx`:
 *   t(key, vars)             the interface language's words
 *   tIn(lang, key, vars)     another language's words (bilingual documents)
 *   lang                     the interface language, `i18n.current`
 *   escapeHtml(s)
 *   settings, clients, machines, inventory
 *   docs                     this order's product documents (`docsForOrder`)
 *   shopName                 the shop's name in its content language
 *   safeBizLogo              the shop's logo as a `data:image/` URL, or ''
 *   brandMark                the mark printed when there is no logo
 *   safeCssColor(v, fb)
 *   jobRef(order)            the job's readable number
 *   localName(client)
 *   formatPrintDate(iso)
 *   today                    `YYYY-MM-DD`, in the shop's calendar
 *   localeTag                the BCP 47 tag dates are written in
 *   fmtPrice(n)              money in the shop's currency
 *   orderRevenueBase(o), orderOwedBase(o), orderToBase(n, o), payStatus(o)
 */
(function (global) {

  const language = () => (typeof global.KhaytInvoiceLanguage !== 'undefined')
    ? global.KhaytInvoiceLanguage
    : (function () {
        try { return require('./invoice-language.js'); } catch (e) { return null; }
      })();

  function docLanguage(ctx) {
    const settings = ctx.settings || {};
    const L = language();
    if (!L) return { bilingual: false, secondary: null };
    return L.resolveDocumentLanguage({
      mode: settings.invoiceBilingual, lang: ctx.lang,
      secondary: settings.invoiceSecondLang, enableZatca: settings.enableZatca,
    });
  }

  function clientOf(order, ctx) {
    const list = Array.isArray(ctx.clients) ? ctx.clients : [];
    return order && order.clientId ? (list.find((c) => c && c.id === order.clientId) || null) : null;
  }

  // ── PACKING SLIP ───────────────────────────────────────────────────────
  //
  // A whole page of its own, with its own styles: the desktop opens it in a
  // window by itself rather than in the invoice's print area.
  function packingSlipHtml(order, ctx) {
    const { t, escapeHtml, jobRef } = ctx;
    const settings = ctx.settings || {};
    const client = clientOf(order, ctx);
    const clientName = client ? ctx.localName(client) : (order.client || '');
    const clientPhone = client?.phone || '';
    const deliveryAddr = order.deliveryAddress
      || (client?.addresses?.[0]?.address || '');
    const shopName = ctx.shopName || 'Khayt';
    const shopPhone = settings.phone || '';
    const shopEmail = settings.email || '';
    const accentColor = ctx.safeCssColor(settings.invAccentColor, '#5E2E14');
    const tag = ctx.localeTag;
    const dateStr = order.completedAt
      ? new Date(order.completedAt).toLocaleDateString(tag)
      : order.date || ctx.today;

    const parts = order.parts || [];
    const rowsHtml = parts.map(p => {
      const qty = p.qty || 1;
      const wt = Math.round((+p.printWeight || 0) * qty);
      return `<tr>
      <td>${escapeHtml(p.name || order.project || '—')}</td>
      <td>${escapeHtml(p.material || order.material || '—')}</td>
      <td>${escapeHtml(p.color || p.colour || '—')}</td>
      <td style="text-align:center;">${qty}</td>
      <td style="text-align:right;">${wt > 0 ? wt + 'g' : '—'}</td>
    </tr>`;
    }).join('');

    const totalWeight = parts.reduce((s, p) => s + (+p.printWeight || 0) * (p.qty || 1), 0);
    const totalQty = parts.reduce((s, p) => s + (p.qty || 1), 0);

    // Printed output must follow the shop's own language, not default to LTR English.
    const docLang = ctx.lang === 'ar' ? 'ar' : 'en';
    const docDir = docLang === 'ar' ? 'rtl' : 'ltr';
    return `<!DOCTYPE html>
<html lang="${docLang}" dir="${docDir}">
<head>
<meta charset="UTF-8">
<title>Packing Slip — ${escapeHtml(jobRef(order))}</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:-apple-system,'Segoe UI',sans-serif; font-size:11pt; color:#111; background:#fff; padding:20mm; }
  .header { display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:10mm; border-bottom:2px solid ${accentColor}; padding-bottom:6mm; }
  .shop-name { font-size:18pt; font-weight:800; color:${accentColor}; }
  .shop-sub { font-size:9pt; color:#666; margin-top:2mm; }
  .slip-title { font-size:22pt; font-weight:700; color:${accentColor}; text-align:right; text-transform:uppercase; letter-spacing:1pt; }
  .slip-meta { font-size:9.5pt; color:#444; text-align:right; margin-top:2mm; line-height:1.7; }
  .section { margin-bottom:8mm; }
  .section-label { font-size:8pt; text-transform:uppercase; letter-spacing:.5pt; color:#888; margin-bottom:1.5mm; font-weight:700; }
  .bill-to { font-size:11pt; line-height:1.6; }
  table { width:100%; border-collapse:collapse; margin-bottom:6mm; }
  thead tr { background:${accentColor}; color:#fff; }
  thead th { padding:3mm 4mm; text-align:left; font-size:9pt; font-weight:700; letter-spacing:.3pt; }
  thead th:last-child, thead th:nth-child(4) { text-align:right; }
  tbody tr:nth-child(even) { background:#f9fafb; }
  td { padding:2.5mm 4mm; font-size:10pt; border-bottom:0.3mm solid #e5e7eb; }
  td:last-child, td:nth-child(4) { text-align:right; }
  tfoot td { padding:3mm 4mm; font-size:10.5pt; font-weight:700; border-top:1.5px solid #111; }
  .notes { background:#fffbeb; border-inline-start:3mm solid #fbbf24; padding:3mm 4mm; font-size:10pt; border-radius:1mm; margin-bottom:8mm; }
  .footer { text-align:center; font-size:9pt; color:#888; border-top:0.5mm solid #e5e7eb; padding-top:4mm; margin-top:4mm; }
  @media print { body { padding:15mm; } }
</style>
</head>
<body>
  <div class="header">
    <div>
      <div class="shop-name">${escapeHtml(shopName)}</div>
      <div class="shop-sub">${shopPhone ? escapeHtml(shopPhone) : ''}${shopPhone && shopEmail ? ' · ' : ''}${shopEmail ? escapeHtml(shopEmail) : ''}</div>
    </div>
    <div>
      <div class="slip-title">Packing Slip</div>
      <div class="slip-meta">
        <strong>${escapeHtml(t('common.date') || 'Date')}:</strong> ${escapeHtml(dateStr)}<br>
        <strong>${escapeHtml(t('log.order_id') || 'Order') || 'Order'}:</strong> ${escapeHtml(jobRef(order))}
        ${order.invoiceNum ? `<br><strong>${escapeHtml(t('ord.invoice_num') || 'Invoice')}:</strong> ${escapeHtml(String(order.invoiceNum))}` : ''}
      </div>
    </div>
  </div>

  ${(clientName || deliveryAddr || clientPhone) ? `
  <div class="section">
    <div class="section-label">${escapeHtml(t('ps.ship_to') || 'Ship / Bill To')}</div>
    <div class="bill-to">
      ${clientName ? `<strong>${escapeHtml(clientName)}</strong><br>` : ''}
      ${deliveryAddr ? escapeHtml(deliveryAddr).replace(/\\n/g, '<br>') + '<br>' : ''}
      ${clientPhone ? escapeHtml(clientPhone) : ''}
    </div>
  </div>` : ''}

  <table>
    <thead>
      <tr>
        <th>${escapeHtml(t('ps.item') || 'Item')}</th>
        <th>${escapeHtml(t('ps.material') || 'Material')}</th>
        <th>${escapeHtml(t('ps.color') || 'Color')}</th>
        <th style="text-align:right;">${escapeHtml(t('ps.qty') || 'Qty')}</th>
        <th style="text-align:right;">${escapeHtml(t('ps.weight') || 'Weight')}</th>
      </tr>
    </thead>
    <tbody>
      ${rowsHtml || `<tr><td colspan="5" style="color:#888;text-align:center;">${escapeHtml(order.project || jobRef(order))}</td></tr>`}
    </tbody>
    <tfoot>
      <tr>
        <td colspan="3" style="text-align:right;font-weight:600;">${escapeHtml(t('ps.total') || 'Total')}</td>
        <td style="text-align:right;">${totalQty}</td>
        <td style="text-align:right;">${totalWeight > 0 ? Math.round(totalWeight) + 'g' : '—'}</td>
      </tr>
    </tfoot>
  </table>

  ${order.notes ? `<div class="notes"><strong>${escapeHtml(t('common.notes') || 'Notes')}:</strong> ${escapeHtml(order.notes)}</div>` : ''}

  <div class="footer">
    ${escapeHtml(t('ps.thank_you') || 'Thank you for your business!')}
    ${shopName ? ` · ${escapeHtml(shopName)}` : ''}
  </div>
</body>
</html>`;
  }

  // ── DELIVERY NOTE ──────────────────────────────────────────────────────
  //
  // Into the invoice's print area, in the invoice's stylesheet.
  function deliveryNoteHtml(order, ctx) {
    const { t, escapeHtml, jobRef } = ctx;
    const isAr = ctx.lang === 'ar';
    const dir  = isAr ? 'rtl' : 'ltr';
    // Same rule as the invoice — see renderInvoice(). A credit note and a delivery
    // note are customer-facing documents too, and were bilingual unconditionally.
    const _dl = docLanguage(ctx);
    const bi = _dl.bilingual;
    const secondLang = _dl.secondary;
    const bizPrimary = ctx.shopName;
    const linkedClient = clientOf(order, ctx);
    const clientName = (order.project || '').trim() || t('inv.walk_in');
    const clientSub  = linkedClient ? [linkedClient.phone, linkedClient.email].filter(Boolean).join(' · ') : '';
    const lines = (order.parts && order.parts.length > 0) ? order.parts
      : [{ name: t('inv.services_default'), qty: 1 }];
    const logo = ctx.safeBizLogo;

    return `
    <div class="inv-wrap">
    <div class="inv-top-bar" style="background:var(--primary);"></div>
    <div class="inv" dir="${dir}" lang="${ctx.lang}" style="--brand:#1a1a2e; --accent:#4a90e2; --highlight:#eef3fc;">
      <div class="inv-header">
        <div class="biz">
          <div class="mark">${logo ? `<img src="${logo}" style="max-height:60px; max-width:120px; object-fit:contain;" alt="logo">` : ctx.brandMark}</div>
          <div class="biz-name">
            <h1>${escapeHtml(bizPrimary || 'Khayt')}</h1>
          </div>
        </div>
        <div class="doc">
          <div class="title">${escapeHtml(t("doc.delivery_note"))}</div>
          ${bi ? `<div class="title-ar ${isAr ? 'ltr' : 'ar'}">${escapeHtml(ctx.tIn(secondLang, "doc.delivery_note"))}</div>` : ''}
          <div class="meta">
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.ref"))}</span><span class="v">${escapeHtml(jobRef(order))}</span></div>
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.date"))}</span><span class="v">${escapeHtml(ctx.formatPrintDate(order.date))}</span></div>
          </div>
        </div>
      </div>
      <div class="bill-to">
        <div class="label"><span>${escapeHtml(t("doc.deliver_to"))}</span></div>
        <div>
          <div class="name">${escapeHtml(clientName)}</div>
          ${clientSub ? `<div class="name-sub">${escapeHtml(clientSub)}</div>` : ''}
        </div>
      </div>
      ${(order.trackingNumber || order.courierName || order.deliveryAddress) ? `
      <div class="delivery-tracking">
        ${order.courierName ? `<div><strong>${escapeHtml(t("doc.courier"))}:</strong> ${escapeHtml(order.courierName)}</div>` : ''}
        ${order.trackingNumber ? `<div><strong>${escapeHtml(t("doc.tracking"))}:</strong> ${escapeHtml(order.trackingNumber)}</div>` : ''}
        ${order.deliveryAddress ? `<div><strong>${escapeHtml(t("doc.address"))}:</strong> ${escapeHtml(order.deliveryAddress)}</div>` : ''}
      </div>` : ''}
      ${(() => {
        // OUTSIDE the courier/tracking block on purpose. That block only renders
        // when there is shipping information, and a shop handing an order over
        // in person still puts the safety sheet in the box.
        //
        // Only the packable documents: this sheet goes to the customer, and a
        // machine setup sheet is not something to put in the box.
        const docs = (ctx.docs || []).filter((d) => d.packWithOrder);
        if (!docs.length) return "";
        return `<div class="delivery-docs" style="margin-top:8px;"><strong>${escapeHtml(t("pdoc.enclosed") || "Enclosed")}:</strong> ${docs.map((x) => escapeHtml(x.name)).join(", ")}</div>`;
      })()}
      <table class="lines">
        <thead>
          <tr>
            <th>${escapeHtml(t("doc.item"))}</th>
            <th style="text-align:center; width:60px;">${escapeHtml(t("doc.qty"))}</th>
            <th style="width:120px;">${escapeHtml(t("doc.notes"))}</th>
          </tr>
        </thead>
        <tbody>
          ${lines.map(p => `
            <tr>
              <td>${escapeHtml(p.name)}</td>
              <td class="center">${p.qty || 1}</td>
              <td></td>
            </tr>`).join('')}
        </tbody>
      </table>
      <div style="margin-top:32px; display:flex; justify-content:space-between; gap:32px;">
        <div style="flex:1; border-top:1px solid #ccc; padding-top:8px; font-size:12px; color:#888;">${escapeHtml(t("doc.received_by"))}</div>
        <div style="flex:1; border-top:1px solid #ccc; padding-top:8px; font-size:12px; color:#888;">${escapeHtml(t("doc.delivered_by"))}</div>
      </div>
      <div class="footer" style="margin-top:24px;">
        <div class="legal">${escapeHtml(t("doc.generated_by"))}</div>
      </div>
    </div>
    </div>`;
  }

  // ── WORK ORDER ─────────────────────────────────────────────────────────
  //
  // The shop floor's sheet. No prices on it.
  function workOrderHtml(order, ctx) {
    const { t, escapeHtml, jobRef } = ctx;
    const settings = ctx.settings || {};
    const isAr = ctx.lang === 'ar';
    const dir  = isAr ? 'rtl' : 'ltr';
    // The work order is a customer-facing-adjacent document printed for the shop
    // floor, and it was bilingual unconditionally like the rest. Same rule, same
    // resolver — see renderInvoice() in renderer/invoicing.js.
    const _dl = docLanguage(ctx);
    const bi = _dl.bilingual;
    const bizPrimary = ctx.shopName;
    const today = ctx.today;
    const linkedClient = clientOf(order, ctx);
    const clientName = (order.project || '').trim() || (linkedClient ? ctx.localName(linkedClient) : t('inv.walk_in'));
    const lines = (order.parts && order.parts.length > 0) ? order.parts
      : [{ name: order.project || jobRef(order), qty: 1, material: '', weight: '', printTime: order.printTime || 0 }];
    const machines = Array.isArray(ctx.machines) ? ctx.machines : [];
    const inventory = Array.isArray(ctx.inventory) ? ctx.inventory : [];
    const machine = order.machineId ? machines.find(m => m.id === order.machineId) : null;
    const customDataHtml = (settings.customFields || []).length > 0 && order.customData
      ? (settings.customFields || []).map(f => {
          const val = (order.customData || {})[f.id] || '';
          return val ? `<div class="meta-row"><span class="k">${escapeHtml(f.label)}</span><span class="v">${escapeHtml(val)}</span></div>` : '';
        }).join('')
      : '';
    const logo = ctx.safeBizLogo;

    return `
    <div class="inv-wrap wo-wrap">
    <div class="inv-top-bar" style="background:#374151;"></div>
    <div class="inv" dir="${dir}" lang="${ctx.lang}" style="--brand:#1f2937; --accent:#374151; --highlight:#f3f4f6;">
      <div class="inv-header">
        <div class="biz">
          <div class="mark">${logo ? `<img src="${logo}" style="max-height:50px; max-width:100px; object-fit:contain;" alt="logo">` : ctx.brandMark}</div>
          <div class="biz-name"><h1>${escapeHtml(bizPrimary || 'Khayt')}</h1></div>
        </div>
        <div class="doc">
          <div class="title">${escapeHtml(t("doc.work_order"))}</div>
          ${bi ? `<div class="title-ar ${isAr ? 'ltr' : 'ar'}">${escapeHtml(ctx.tIn(_dl.secondary, "doc.work_order"))}</div>` : ''}
          <div class="meta">
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.wo_no"))}</span><span class="v">WO-${escapeHtml(jobRef(order))}</span></div>
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.date"))}</span><span class="v">${escapeHtml(ctx.formatPrintDate(today))}</span></div>
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.due"))}</span><span class="v">${order.dueDate ? escapeHtml(ctx.formatPrintDate(order.dueDate)) : '—'}</span></div>
            ${machine ? `<div class="meta-row"><span class="k">${escapeHtml(t("doc.machine"))}</span><span class="v">${escapeHtml(machine.name)}</span></div>` : ''}
            ${customDataHtml}
          </div>
        </div>
      </div>

      <div class="bill-to">
        <div class="label"><span>${escapeHtml(t("doc.client"))}</span></div>
        <div>
          <div class="name">${escapeHtml(clientName)}</div>
          ${order.notes ? `<div class="name-sub">${escapeHtml(order.notes)}</div>` : ''}
        </div>
      </div>

      <table class="lines">
        <thead>
          <tr>
            <th>${escapeHtml(t("doc.part"))}</th>
            <th style="text-align:center; width:40px;">${escapeHtml(t("doc.qty"))}</th>
            <th style="width:120px;">${escapeHtml(t("doc.material"))}</th>
            <th style="width:80px;">${escapeHtml(t("doc.colour"))}</th>
            <th style="width:80px; text-align:center;">${escapeHtml(t("doc.weight_g"))}</th>
            <th style="width:80px; text-align:center;">${escapeHtml(t("doc.time_h"))}</th>
            <th style="width:100px;">${escapeHtml(t("doc.settings"))}</th>
            <th style="width:100px;">${escapeHtml(t("doc.file"))}</th>
          </tr>
        </thead>
        <tbody>
          ${lines.map(p => {
            const invItem = p.filamentId ? inventory.find(f => f.id === p.filamentId) : null;
            const filamentName = invItem?.material || (p.material || '');
            // Feature 4: Include spool print settings in work order
            const printSettingsStr = invItem && (invItem.printTemp || invItem.bedTemp)
              ? [
                  invItem.printTemp ? `${invItem.printTemp}°C` : '',
                  invItem.bedTemp   ? `Bed: ${invItem.bedTemp}°C` : '',
                  invItem.maxSpeed  ? `${invItem.maxSpeed}mm/s` : '',
                ].filter(Boolean).join(' / ')
              : '';
            const settings_str = [
              p.infill ? `${p.infill}%` : '',
              p.layerHeight ? `${p.layerHeight}mm` : '',
              p.supports ? (t("doc.supports")) : '',
              printSettingsStr
            ].filter(Boolean).join(', ');
            return `<tr>
              <td>${escapeHtml(p.name || order.project || '')}</td>
              <td class="center">${escapeHtml(String(p.qty || 1))}</td>
              <td>${escapeHtml(filamentName)}</td>
              <td style="font-size:11px;">${escapeHtml(p.colour || invItem?.colourVariant || '—')}</td>
              <td class="center">${p.weight ? escapeHtml(String(+p.weight)) : '—'}</td>
              <td class="center">${p.printTime ? escapeHtml((+p.printTime).toFixed(1)) : '—'}</td>
              <td style="font-size:10px;">${escapeHtml(settings_str)}</td>
              <td style="font-size:10px; color:#4a8ee8;">${escapeHtml(p.fileRef || '—')}</td>
            </tr>`;
          }).join('')}
        </tbody>
      </table>

      ${(() => {
        // Everything attached to the product — the person making it should see
        // the setup sheet as well as the customer-facing instructions.
        const docs = ctx.docs || [];
        if (!docs.length) return "";
        return `<div class="wo-docs" style="margin-top:16px;">
          <div style="font-size:12px; font-weight:600; margin-bottom:6px;">${escapeHtml(t("pdoc.title") || "Documents")}</div>
          ${docs.map((d) => `<div style="font-size:12px; margin-bottom:3px;">• ${escapeHtml(d.name)}${d.packWithOrder ? "" : ` <span style="color:#888;">(${escapeHtml(t("pdoc.not_shipped") || "not shipped")})</span>`}</div>`).join("")}
        </div>`;
      })()}

      <div class="wo-checks" style="margin-top:20px;">
        ${(settings.postChecklist || []).length > 0 ? `
          <div style="font-size:12px; font-weight:600; margin-bottom:8px;">${escapeHtml(t("doc.post_checklist"))}</div>
          ${settings.postChecklist.map(ch => `
            <div style="display:flex; align-items:center; gap:8px; margin-bottom:5px;">
              <div style="width:14px;height:14px;border:1.5px solid #666;border-radius:3px;flex-shrink:0;"></div>
              <span style="font-size:12px;">${escapeHtml(ch.label)}</span>
            </div>`).join('')}` : ''}
      </div>

      <div style="margin-top:28px; display:flex; justify-content:space-between; gap:32px;">
        <div style="flex:1; border-top:1px solid #ccc; padding-top:8px; font-size:12px; color:#888;">${escapeHtml(t("doc.operator"))}</div>
        <div style="flex:1; border-top:1px solid #ccc; padding-top:8px; font-size:12px; color:#888;">${escapeHtml(t("doc.reviewed_by"))}</div>
        <div style="flex:1; border-top:1px solid #ccc; padding-top:8px; font-size:12px; color:#888;">${escapeHtml(t("doc.date_time"))}</div>
      </div>
    </div>
    </div>`;
  }

  // ── ACCOUNT STATEMENT ──────────────────────────────────────────────────

  /** A customer's jobs, oldest first — the rows a statement lists. */
  function statementOrders(clientId, orders) {
    return (Array.isArray(orders) ? orders : []).filter(o => o && o.clientId === clientId)
      .sort((a, b) => (a.date || '').localeCompare(b.date || ''));
  }

  /**
   * The statement's figures, every one in the shop's BASE currency so a
   * customer's rows and totals reconcile whatever currency each job was in.
   */
  function statementFigures(clientId, orders, ctx) {
    const list = statementOrders(clientId, orders);
    // Cash actually received (base). Falls back to price ONLY for legacy fully-paid
    // orders with no recorded amount AND no gift settlement — otherwise a gift-card
    // -settled order would be counted as both "paid" (price) and "gift".
    const cashPaidBase = (o) => {
      const recorded = +o.paidAmount || 0;
      if (recorded > 0) return ctx.orderToBase(recorded, o);
      return (ctx.payStatus(o) === 'paid' && !(+o.giftCardDiscount > 0)) ? ctx.orderToBase(+o.price || 0, o) : 0;
    };
    const rows = list.map((o) => ({
      order: o, charge: ctx.orderRevenueBase(o), paid: cashPaidBase(o), balance: ctx.orderOwedBase(o),
    }));
    return {
      rows,
      totalCharges: rows.reduce((s, r) => s + r.charge, 0),
      totalPaid: rows.reduce((s, r) => s + r.paid, 0),
      // Gift-card redemptions settle part of the balance just like a payment.
      totalGift: list.reduce((s, o) => s + ctx.orderToBase(+o.giftCardDiscount || 0, o), 0),
      totalCredit: list.reduce((s, o) =>
        s + ctx.orderToBase((o.creditNotes || []).reduce((a, cn) => a + (+cn.amount || 0), 0), o), 0),
      outstanding: rows.reduce((s, r) => s + r.balance, 0),
    };
  }

  function clientStatementHtml(client, orders, ctx) {
    const { t, escapeHtml, jobRef, fmtPrice } = ctx;
    const c = client;
    const displayName = ctx.localName(c);
    const bizPrimary = ctx.shopName || 'Khayt';
    const f = statementFigures(c.id, orders, ctx);
    const { totalCharges, totalPaid, totalGift, totalCredit, outstanding } = f;
    const logo = ctx.safeBizLogo;

    const rowsHtml = f.rows.map(({ order: o, charge, paid, balance: bal }) => {
      return `<tr style="border-bottom:1px solid #eee;">
      <td style="padding:6px 8px; font-size:12px; white-space:nowrap;">${escapeHtml(o.date || '')}</td>
      <td style="padding:6px 8px; font-size:12px;">${escapeHtml(jobRef(o))}</td>
      <td style="padding:6px 8px; font-size:12px;">${escapeHtml(o.project || '')}</td>
      <td style="padding:6px 8px; font-size:12px; text-align:end;">${fmtPrice(charge)}</td>
      <td style="padding:6px 8px; font-size:12px; text-align:end; color:#2a9d8f;">${fmtPrice(paid)}</td>
      <td style="padding:6px 8px; font-size:12px; text-align:end; color:${bal > 0 ? '#e63946' : '#2a9d8f'};">${fmtPrice(bal)}</td>
    </tr>`;
    }).join('');

    return `
    <div class="inv-wrap">
    <div class="inv-top-bar" style="background:var(--primary);"></div>
    <div class="inv" style="--brand:#1a1a2e; --accent:#4a90e2; --highlight:#eef3fc;">
      <div class="inv-header">
        <div class="biz">
          <div class="mark">${logo ? `<img src="${logo}" style="max-height:60px; max-width:120px; object-fit:contain;" alt="logo">` : ctx.brandMark}</div>
          <div class="biz-name"><h1>${escapeHtml(bizPrimary)}</h1></div>
        </div>
        <div class="doc">
          <div class="title">${escapeHtml(t('cl.statement_title'))}</div>
          <div class="meta">
            <div class="meta-row"><span class="k">${escapeHtml(t('common.date'))}</span><span class="v">${escapeHtml(ctx.today)}</span></div>
          </div>
        </div>
      </div>
      <div class="bill-to">
        <div class="label"><span>${escapeHtml(t('inv.billed_to'))}</span></div>
        <div>
          <div class="name">${escapeHtml(displayName)}</div>
          ${c.phone ? `<div class="name-sub">${escapeHtml(c.phone)}</div>` : ''}
          ${c.email ? `<div class="name-sub">${escapeHtml(c.email)}</div>` : ''}
        </div>
      </div>
      <table style="width:100%; border-collapse:collapse; margin-top:16px; font-size:13px;">
        <thead>
          <tr style="border-bottom:2px solid #333; text-align:start;">
            <th style="padding:6px 8px;">${escapeHtml(t('common.date'))}</th>
            <th style="padding:6px 8px;">${escapeHtml(t('log.id') || 'Order ID')}</th>
            <th style="padding:6px 8px;">${escapeHtml(t('oe.project') || 'Description')}</th>
            <th style="padding:6px 8px; text-align:end;">${escapeHtml(t('log.price'))}</th>
            <th style="padding:6px 8px; text-align:end;">${escapeHtml(t('cl.stmt_paid'))}</th>
            <th style="padding:6px 8px; text-align:end;">${escapeHtml(t('cl.stmt_outstanding'))}</th>
          </tr>
        </thead>
        <tbody>${rowsHtml}</tbody>
        <tfoot>
          <tr style="border-top:2px solid #333; font-weight:700;">
            <td colspan="3" style="padding:8px 8px;">${escapeHtml(t('common.total'))}</td>
            <td style="padding:8px 8px; text-align:end;">${fmtPrice(totalCharges)}</td>
            <td style="padding:8px 8px; text-align:end; color:#2a9d8f;">${fmtPrice(totalPaid)}</td>
            <td style="padding:8px 8px; text-align:end; color:${outstanding > 0 ? '#e63946' : '#2a9d8f'};">${fmtPrice(outstanding)}</td>
          </tr>
        </tfoot>
      </table>
      <div style="margin-top:20px; display:flex; gap:24px; flex-wrap:wrap;">
        <div style="background:#f8f9fa; padding:12px 16px; border-radius:6px; min-width:150px;">
          <div style="font-size:11px; color:#666;">${escapeHtml(t('cl.stmt_charges'))}</div>
          <div style="font-size:18px; font-weight:700;">${fmtPrice(totalCharges)}</div>
        </div>
        <div style="background:#f0fdf4; padding:12px 16px; border-radius:6px; min-width:150px;">
          <div style="font-size:11px; color:#666;">${escapeHtml(t('cl.stmt_paid'))}</div>
          <div style="font-size:18px; font-weight:700; color:#2a9d8f;">${fmtPrice(totalPaid)}</div>
        </div>
        ${totalGift > 0 ? `<div style="background:#f8f9fa; padding:12px 16px; border-radius:6px; min-width:150px;">
          <div style="font-size:11px; color:#666;">${escapeHtml(t('cl.stmt_gift') || 'Gift cards')}</div>
          <div style="font-size:18px; font-weight:700; color:#2a9d8f;">${fmtPrice(totalGift)}</div>
        </div>` : ''}
        ${totalCredit > 0 ? `<div style="background:#f8f9fa; padding:12px 16px; border-radius:6px; min-width:150px;">
          <div style="font-size:11px; color:#666;">${escapeHtml(t('cl.stmt_credit') || 'Credit notes')}</div>
          <div style="font-size:18px; font-weight:700; color:#2a9d8f;">${fmtPrice(totalCredit)}</div>
        </div>` : ''}
        <div style="background:${outstanding > 0 ? '#fff5f5' : '#f0fdf4'}; padding:12px 16px; border-radius:6px; min-width:150px;">
          <div style="font-size:11px; color:#666;">${escapeHtml(t('cl.stmt_outstanding'))}</div>
          <div style="font-size:18px; font-weight:700; color:${outstanding > 0 ? '#e63946' : '#2a9d8f'};">${fmtPrice(outstanding)}</div>
        </div>
      </div>
      <div class="footer" style="margin-top:24px;">
        <div class="legal">${escapeHtml(t('legal') || 'Generated by Khayt')}</div>
      </div>
    </div>
    </div>`;
  }

  /**
   * The jobs whose invoices "Export all invoices" writes: the customer's
   * FINISHED work, oldest first. `isFinished` is `KhaytOrderStatus.isFinished`.
   */
  function invoicesToExport(clientId, orders, isFinished) {
    return (Array.isArray(orders) ? orders : [])
      .filter(o => o && o.clientId === clientId && isFinished(o))
      .sort((a, b) => (a.date || '').localeCompare(b.date || ''));
  }

  const api = {
    packingSlipHtml,
    deliveryNoteHtml,
    workOrderHtml,
    clientStatementHtml,
    statementOrders,
    statementFigures,
    invoicesToExport,
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytShopDocuments = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
