/**
 * Invoicing: numbering, ZATCA QR/XML, render/print/export, quotes, credit notes.
 */
(function (global) {

/* Feature 7: Configurable invoice number sequence */
function nextInvoiceNumber() {
  const currentYear = new Date().getFullYear();
  if ((settings.invNumYear || currentYear) !== currentYear) {
    settings.invNumYear = currentYear;
    settings.invNumNext = 1;
  }
  const prefix = settings.invNumPrefix || 'INV';
  const seq4 = String(settings.invNumNext || 1).padStart(4, '0');
  const fmt = settings.invNumFormat || '{prefix}-{year}-{seq4}';
  const result = fmt
    .replace('{prefix}', prefix)
    .replace('{year}', currentYear)
    .replace('{seq4}', seq4);
  settings.invNumNext = (settings.invNumNext || 1) + 1;
  settings.invNumYear = currentYear;
  saveAll();
  return result;
}
/* Separate quote sequence so two quotes never collide on id (Bug A).
   Quotes intentionally do NOT advance the invoice counter, but they still
   need their own monotonic number or back-to-back quotes share an id. */
function nextQuoteSeq() {
  const currentYear = new Date().getFullYear();
  if ((settings.quoteNumYear || currentYear) !== currentYear) {
    settings.quoteNumYear = currentYear;
    settings.quoteNumNext = 1;
  }
  const seq4 = String(settings.quoteNumNext || 1).padStart(4, '0');
  settings.quoteNumNext = (settings.quoteNumNext || 1) + 1;
  settings.quoteNumYear = currentYear;
  saveAll();
  return seq4;
}

/* --- extracted 6543-6682 --- */
function generateClientStatement(clientId) {
  const c = clients.find(x => x.id === clientId);
  if (!c) return;
  const displayName = localName(c);
  const orders = printLog.filter(o => o.clientId === clientId)
    .sort((a, b) => (a.date || '').localeCompare(b.date || ''));

  const bizPrimary = shopName() || 'Khayt';

  // All statement figures are in the shop's BASE currency so multi-currency
  // clients' rows and totals reconcile (orderRevenueBase/orderOwedBase convert).
  const curOf = (o) => (typeof orderCurrency === 'function') ? orderCurrency(o) : (settings.currency || 'SAR');
  // Cash actually received (base). Falls back to price ONLY for legacy fully-paid
  // orders with no recorded amount AND no gift settlement — otherwise a gift-card
  // -settled order would be counted as both "paid" (price) and "gift".
  const cashPaidBase = (o) => {
    const recorded = +o.paidAmount || 0;
    if (recorded > 0) return convertToBase(recorded, curOf(o));
    return (payStatus(o) === 'paid' && !(+o.giftCardDiscount > 0)) ? convertToBase(+o.price || 0, curOf(o)) : 0;
  };
  const totalCharges = orders.reduce((s, o) => s + orderRevenueBase(o), 0);
  const totalPaid    = orders.reduce((s, o) => s + cashPaidBase(o), 0);
  // Gift-card redemptions settle part of the balance just like a payment.
  const totalGift    = orders.reduce((s, o) => s + convertToBase(+o.giftCardDiscount || 0, curOf(o)), 0);
  const totalCredit  = orders.reduce((s, o) =>
    s + convertToBase((o.creditNotes || []).reduce((a, cn) => a + (+cn.amount || 0), 0), curOf(o)), 0);
  const outstanding  = orders.reduce((s, o) => s + orderOwedBase(o), 0);

  const rowsHtml = orders.map(o => {
    const paid  = cashPaidBase(o);
    const bal   = orderOwedBase(o);
    return `<tr style="border-bottom:1px solid #eee;">
      <td style="padding:6px 8px; font-size:12px; white-space:nowrap;">${escapeHtml(o.date || '')}</td>
      <td style="padding:6px 8px; font-size:12px;">${escapeHtml(o.id)}</td>
      <td style="padding:6px 8px; font-size:12px;">${escapeHtml(o.project || '')}</td>
      <td style="padding:6px 8px; font-size:12px; text-align:end;">${fmtPrice(orderRevenueBase(o))}</td>
      <td style="padding:6px 8px; font-size:12px; text-align:end; color:#2a9d8f;">${fmtPrice(paid)}</td>
      <td style="padding:6px 8px; font-size:12px; text-align:end; color:${bal > 0 ? '#e63946' : '#2a9d8f'};">${fmtPrice(bal)}</td>
    </tr>`;
  }).join('');

  const area = $('#invoice-print-area');
  area.innerHTML = `
    <div class="inv-wrap">
    <div class="inv-top-bar" style="background:var(--primary);"></div>
    <div class="inv" style="--brand:#1a1a2e; --accent:#4a90e2; --highlight:#eef3fc;">
      <div class="inv-header">
        <div class="biz">
          <div class="mark">${safeBizLogo() ? `<img src="${safeBizLogo()}" style="max-height:60px; max-width:120px; object-fit:contain;" alt="logo">` : BRAND_MARK_SVG}</div>
          <div class="biz-name"><h1>${escapeHtml(bizPrimary)}</h1></div>
        </div>
        <div class="doc">
          <div class="title">${escapeHtml(t('cl.statement_title'))}</div>
          <div class="meta">
            <div class="meta-row"><span class="k">${escapeHtml(t('common.date'))}</span><span class="v">${escapeHtml(localDateStr())}</span></div>
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
  setTimeout(() => window.print(), 80);
}

/* ============================================================
   Export all invoices for a client — renders each sequentially
   into the print area then triggers the system print dialog once,
   which the user can save as a single multi-page PDF.
   ============================================================ */
async function exportClientInvoices(clientId) {
  const c = clients.find(x => x.id === clientId);
  if (!c) return;
  const orders = printLog
    .filter(o => o.clientId === clientId && o.status === 'completed')
    .sort((a, b) => (a.date || '').localeCompare(b.date || ''));
  if (orders.length === 0) {
    toast(t('cl.no_invoices'), 'info');
    return;
  }
  toast(t('cl.exporting_invoices', { n: orders.length }), 'info', 2000);

  // If hubAPI.exportPDF exists, export each invoice as a separate file
  if (window.hubAPI?.exportPDF) {
    // Track failures instead of swallowing them: "30 invoices exported" when 29 landed
    // sends the owner to their accountant a document short, with no way to tell which.
    const failedIds = [];
    for (let i = 0; i < orders.length; i++) {
      await renderInvoiceForOrder(orders[i]);
      await new Promise(r => setTimeout(r, 60));
      try {
        const r = await window.hubAPI.exportPDF({ filename: `${orders[i].id}.pdf`, askWhere: i === 0, openAfter: false });
        if (r && r.ok === false && !r.canceled) failedIds.push(orders[i].id);
      } catch (e) {
        console.error('exportPDF failed for', orders[i].id, e);
        failedIds.push(orders[i].id);
      }
    }
    if (failedIds.length) {
      toast('⚠ ' + (t('cl.invoices_exported_partial', {
        n: String(orders.length - failedIds.length), total: String(orders.length), ids: failedIds.join(', '),
      }) || `Exported ${orders.length - failedIds.length} of ${orders.length} — failed: ${failedIds.join(', ')}`), 'error', 9000);
    } else {
      toast(t('cl.invoices_exported', { n: orders.length }), 'success', 4000);
    }
    return;
  }

  // Fallback: render all invoices concatenated into print area, print once
  const area = $('#invoice-print-area');
  area.innerHTML = '';
  const pages = [];
  for (const order of orders) {
    await renderInvoiceForOrder(order);
    pages.push(area.innerHTML);
    area.innerHTML = '';
  }
  area.innerHTML = pages.join('<div style="page-break-after:always;"></div>');
  setTimeout(() => window.print(), 100);
}

/* --- extracted 7267-7296 --- */
function approveQuote(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  order.status = 'pending';
  order.quoteAcceptedAt = localDateStr();
  if (!order.invoiceNum) {
    order.invoiceNum = nextInvoiceNumber();
    order.invoiceNumber = order.invoiceNum;
  }
  if (!order.statusHistory) order.statusHistory = [];
  order.statusHistory.push({ status: 'pending', at: new Date().toISOString() });
  if (order.statusHistory.length > 200) order.statusHistory = order.statusHistory.slice(-200);
  saveAll();
  renderKanban(); renderLogs(); renderDashboard();
  toast(t('quote.approved'), 'success');
}

async function rejectQuote(orderId) {
  const ok = await confirmModal(t('quote.reject_q'), { danger: true });
  if (!ok) return;
  const idx = printLog.findIndex(o => o.id === orderId);
  if (idx < 0) return;
  const removed = printLog[idx];
  printLog.splice(idx, 1);
  saveAll();
  renderKanban(); renderLogs();
  toast(t('quote.rejected'), 'success', 5000, {
    undo: () => { printLog.splice(idx, 0, removed); saveAll(); renderKanban(); renderLogs(); }
  });
}

/* --- extracted 9895-10012 --- */
function renderInvoiceNumberingSection() {
  const el = $('#invNumSection');
  if (!el) return;
  el.innerHTML = `
    <div style="display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:10px;">
      <div>
        <label style="margin-top:0;">${escapeHtml(t('set.inv_num_prefix'))}</label>
        <input type="text" id="invNumPrefix" value="${escapeHtml(settings.invNumPrefix || 'INV')}" placeholder="INV" maxlength="10">
      </div>
      <div>
        <label style="margin-top:0;">${escapeHtml(t('set.inv_num_next'))}</label>
        <input type="number" id="invNumNext" value="${settings.invNumNext || 1}" min="1" step="1">
      </div>
    </div>
    <div style="margin-top:10px;">
      <label style="margin-top:0;">Format</label>
      <select id="invNumFormat">
        <option value="{prefix}-{year}-{seq4}" ${(settings.invNumFormat || '') === '{prefix}-{year}-{seq4}' ? 'selected' : ''}>{prefix}-{year}-{seq4} (e.g. INV-2026-0001)</option>
        <option value="{prefix}-{seq4}" ${settings.invNumFormat === '{prefix}-{seq4}' ? 'selected' : ''}>{prefix}-{seq4} (e.g. INV-0001)</option>
      </select>
    </div>
    <div style="display:flex; gap:8px; flex-wrap:wrap; margin-top:10px;">
      <button class="btn small primary" id="btnSaveInvNum">${escapeHtml(t('common.save'))}</button>
      <button class="btn small ghost" id="btnInvNumReset">${escapeHtml(t('set.inv_num_reset'))}</button>
      <button class="btn small ghost" id="btnInvNumDetectGaps">${escapeHtml(t('set.inv_num_detect_gaps'))}</button>
    </div>
    <div id="invNumGapsResult" style="margin-top:8px; font-size:12.5px;"></div>`;

  el.querySelector('#btnSaveInvNum').addEventListener('click', () => {
    settings.invNumPrefix = el.querySelector('#invNumPrefix').value.trim() || 'INV';
    settings.invNumNext   = Math.max(1, parseInt(el.querySelector('#invNumNext').value, 10) || 1);
    settings.invNumFormat = el.querySelector('#invNumFormat').value;
    saveAll();
    toast(t('set.saved'), 'success');
  });
  el.querySelector('#btnInvNumReset').addEventListener('click', () => {
    settings.invNumYear  = new Date().getFullYear();
    settings.invNumNext  = 1;
    saveAll();
    el.querySelector('#invNumNext').value = '1';
    toast(t('set.inv_num_reset'), 'success');
  });
  el.querySelector('#btnInvNumDetectGaps').addEventListener('click', () => {
    const nums = printLog
      .map(o => o.invoiceNum || o.id)
      .map(id => { const m = /(\d+)$/.exec(id); return m ? parseInt(m[1], 10) : null; })
      .filter(n => n !== null)
      .sort((a, b) => a - b);
    const gaps = [];
    for (let i = 1; i < nums.length; i++) {
      for (let g = nums[i - 1] + 1; g < nums[i]; g++) gaps.push(g);
    }
    const res = el.querySelector('#invNumGapsResult');
    if (res) {
      res.textContent = gaps.length === 0
        ? t('set.inv_num_no_gaps')
        : t('set.inv_num_gaps_found', { n: gaps.length }) + ': ' + gaps.slice(0, 20).join(', ');
      res.style.color = gaps.length === 0 ? 'var(--success)' : 'var(--warning)';
    }
  });
}

/* ============================================================
   Feature 8: Quote revision history
   ============================================================ */
function reviseQuote(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order || order.status !== 'quote') return;
  // Snapshot current state
  const snapshot = {
    version:     order.quoteVersion || 1,
    snapshotAt:  new Date().toISOString(),
    price:       order.price,
    parts:       (order.parts || []).map(p => ({ ...p })),
    notes:       order.notes || '',
    material:    order.material || '',
    printTime:   order.printTime || 0,
  };
  if (!order.quoteRevisions) order.quoteRevisions = [];
  order.quoteRevisions.push(snapshot);
  order.quoteVersion = (order.quoteVersion || 1) + 1;
  saveAll();
  // Open order editor so operator can revise
  openOrderEditor(orderId);
}

function openQuoteRevisionsModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const revisions = order.quoteRevisions || [];

  const revsHtml = revisions.length === 0
    ? `<p style="color:var(--text-muted); font-size:13px;">${escapeHtml(t('ord.quote_rev_empty'))}</p>`
    : `<div class="table-wrap"><table>
        <thead><tr>
          <th>${escapeHtml(t('ord.quote_version'))}</th>
          <th>${escapeHtml(t('ord.quote_rev_date'))}</th>
          <th>${escapeHtml(t('ord.quote_rev_price'))}</th>
          <th>Parts</th>
          <th>Notes</th>
        </tr></thead>
        <tbody>
          ${[...revisions].reverse().map(rev => `<tr>
            <td><strong>v${rev.version}</strong></td>
            <td style="font-size:11.5px;">${new Date(rev.snapshotAt).toLocaleDateString(localeTag())}</td>
            <td>${fmtPrice(rev.price)}</td>
            <td style="font-size:11.5px;">${(rev.parts || []).length} parts</td>
            <td style="font-size:11.5px; max-width:140px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${escapeHtml(rev.notes || '—')}</td>
          </tr>`).join('')}
        </tbody>
      </table></div>`;

  openFormModal({
    title: `📋 ${t('ord.quote_revisions')} — ${escapeHtml(order.project || order.id)} (${t('ord.quote_version', { n: order.quoteVersion || 1 })})`,
    noSave: true,
    bodyHtml: revsHtml,
  });
}

/* --- extracted 10062-10277 --- */
async function exportInvoicePDF(orderId, { askWhere = true, openAfter = true } = {}) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return null;
  const btn = document.querySelector(`[data-act="inv-pdf"][data-id="${orderId}"]`);
  if (btn) { btn.disabled = true; btn.textContent = '⏳'; }
  try {
    // Render invoice into print area, then call printToPDF via IPC
    await renderInvoiceForOrder(order);
    await new Promise(r => setTimeout(r, 60)); // let layout settle
    if (!window.hubAPI?.exportPDF) return null;
    const finalPath = await window.hubAPI.exportPDF({
      askWhere,
      defaultName: `${order.id}.pdf`
    });
    if (!finalPath) return null;
    toast(t('inv.saved'), 'success');
    if (openAfter && window.hubAPI.openPath) await window.hubAPI.openPath(finalPath);
    return finalPath;
  } catch (e) {
    console.error(e);
    toast('PDF error', 'error');
    return null;
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = t('inv.export_pdf') || 'Export PDF'; }
  }
}

async function shareInvoiceWhatsApp(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  // Save PDF to default location (not the dialog) so we have a file path to attach
  await renderInvoiceForOrder(order);
  await new Promise(r => setTimeout(r, 60));
  let pdfPath = null;
  if (window.hubAPI?.exportPDF) {
    try { pdfPath = await window.hubAPI.exportPDF({ askWhere: false, defaultName: `${order.id}.pdf` }); }
    catch (e) { console.error(e); }
  }
  const displayName = client ? (localName(client))
                              : (order.project || '');
  const total = fmtMoney(order.price);
  const message = t('inv.message_template', { name: displayName, id: order.id, total });
  if (!client?.phone) toast(t('inv.no_phone'), 'info', 3200);
  if (window.hubAPI?.shareWhatsApp) {
    await window.hubAPI.shareWhatsApp({
      phone: client?.phone || '',
      message,
      pdfPath
    });
  }
}

async function sendStatusWhatsApp(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  if (!client?.phone) { toast(t('queue.wa_no_phone'), 'info', 3200); return; }
  const displayName = localName(client);
  const statusLabel = t('queue.' + order.status);
  const message = t('queue.wa_status_msg', { name: displayName, project: order.project, id: order.id, status: statusLabel });
  if (window.hubAPI?.shareWhatsApp) {
    await window.hubAPI.shareWhatsApp({ phone: client.phone, message, pdfPath: null });
  }
}

async function sendPaymentReminder(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  if (!client?.phone) { toast(t('pay.remind_no_phone'), 'info', 3200); return; }
  // Use the payment-reminder WA template if available, otherwise a default
  const tpl = waTemplates.find(w => w.id === 'tpl-payment') || waTemplates[0];
  const message = tpl
    ? fillWaTemplate(tpl.body, order, client)
    : t('pay.remind_default', { name: localName(client), id: order.id, price: fmtPrice(order.price), currency: currencySymbol() });
  if (window.hubAPI?.shareWhatsApp) {
    await window.hubAPI.shareWhatsApp({ phone: client.phone, message, pdfPath: null });
  } else {
    // Fallback: open WhatsApp web
    const encodedMsg = encodeURIComponent(message);
    const phone = (client.phone || '').replace(/\D/g, '');
    window.hubAPI?.openExternal?.(`https://wa.me/${phone}?text=${encodedMsg}`);
    if (!window.hubAPI?.openExternal) {
      toast(t('pay.remind_sent') || 'Open WhatsApp manually to send the reminder', 'info');
    }
  }
}

/**
 * Gently follow up on an unapproved quote that is nearing/has passed expiry.
 * Reuses the existing WhatsApp transport (hubAPI.shareWhatsApp, with a wa.me
 * fallback) and records the follow-up on the quote (followUpSentAt/Count) via the
 * pure helper so the dashboard + auto-nudge de-duplicate correctly.
 * @param {string} orderId
 * @param {{ silent?: boolean }} [opts]  silent = no toast / for auto-nudge
 */
async function sendQuoteFollowUp(orderId, opts = {}) {
  const order = printLog.find(o => o.id === orderId);
  if (!order || order.status !== 'quote') return false;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const phone = (client?.phone || '').replace(/\D/g, '');
  if (!phone) {
    if (!opts.silent) toast(t('quote.followup_no_phone'), 'info', 3200);
    return false;
  }
  const name = client ? localName(client) : (order.project || order.id);
  const message = t('quote.followup_msg', {
    name,
    id: order.id,
    project: order.project || order.id,
    total: fmtPrice(order.price),
    expires: order.quoteExpiresAt || '',
  });
  if (window.hubAPI?.shareWhatsApp) {
    await window.hubAPI.shareWhatsApp({ phone: client.phone, message, pdfPath: null });
  } else if (window.hubAPI?.openExternal) {
    window.hubAPI.openExternal(`https://wa.me/${phone}?text=${encodeURIComponent(message)}`);
  } else if (!opts.silent) {
    toast(t('quote.followup_sent'), 'info');
  }
  // Record the follow-up so we don't repeat it within the cooldown window.
  if (typeof KhaytQuoteFollowUp !== 'undefined') {
    Object.assign(order, KhaytQuoteFollowUp.markFollowUpPatch(order, Date.now()));
  } else {
    order.followUpSentAt = new Date().toISOString();
    order.followUpCount = (+order.followUpCount || 0) + 1;
  }
  saveAll();
  if (typeof renderDashboard === 'function') renderDashboard();
  if (!opts.silent) toast(t('quote.followup_sent'), 'success', 3000);
  return true;
}

async function shareTrackingWhatsApp(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order?.trackingNumber) return;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const phone = client?.phone;
  if (!phone) { toast(t('pay.remind_no_phone'), 'info'); return; }
  const msg = t('ship.tracking_msg', {
    project: order.project || order.id,
    courier: order.courierName || '',
    tracking: order.trackingNumber,
  });
  if (window.hubAPI?.shareWhatsApp) await window.hubAPI.shareWhatsApp({ phone, message: msg, pdfPath: null });
}

/* ============================================================
   ZATCA Phase 2 — FATOORA submission
   ============================================================ */
// These keep their names and their no-argument shape because the rest of this
// file and its tests call them that way. What they no longer keep is their own
// opinion: each one now asks the shared module, handing it the shop's settings.
function zatcaPhase2Ready() {
  return !!ZatcaSubmit()?.zatcaPhase2Ready(settings);
}

// The fifth copy, and the last one. `xmlToBase64` in the shared module does
// this and the Buffer version too, picking by which host it is in — so the two
// apps encode the invoice they report with the same function rather than with
// two that happen to produce the same bytes.
function zatcaUtf8ToBase64(str) {
  return ZatcaSubmit().xmlToBase64(str);
}

function ensureZatcaUuid(order) {
  if (order.zatcaUuid) return order.zatcaUuid;
  order.zatcaUuid = `${order.id}-${Date.now().toString(36)}`;
  const idx = printLog.findIndex(o => o.id === order.id);
  if (idx !== -1) {
    printLog[idx] = { ...printLog[idx], zatcaUuid: order.zatcaUuid };
    saveAll();
  }
  return order.zatcaUuid;
}

function nextZatcaIcv(order) {
  return ZatcaSubmit().nextZatcaIcv(settings.zatcaPhase2 || {}, order);
}

function appendZatcaSubmissionLog(entry) {
  const z2 = settings.zatcaPhase2 || (settings.zatcaPhase2 = {});
  ZatcaSubmit().appendZatcaSubmissionLog(z2, entry);
}

function zatcaInvoiceAmounts(order) {
  const ts = order.timestamp
    || (order.date && !Number.isNaN(Date.parse(`${order.date}T12:00:00`))
      ? new Date(`${order.date}T12:00:00`).toISOString()
      : '');
  const price = +order.price || 0;
  // The arithmetic lives in lib/tax.js now. It was written out by hand in ten
  // places, all of them assuming the price INCLUDES the tax — true in the Gulf
  // and most of Europe, false in the US and Canada, where the tax is added on
  // top. profileFromSettings() maps a shop that has never seen the new settings
  // onto exactly the old inclusive single-rate behaviour, so this computes the
  // identical number for every existing shop.
  const _taxProfile = KhaytTax.profileFromSettings(settings);
  const _tax = KhaytTax.computeTax(price, _taxProfile);
  const rate = _taxProfile.rates.reduce((sum, r) => sum + r.percent, 0);
  const vatAmt = _tax.taxTotal;
  const exVat = _tax.subtotal;
  return { ts, price, rate, vatAmt, exVat, total: fmtMoney(price), vatAmount: fmtMoney(vatAmt), subtotal: fmtMoney(exVat) };
}

async function prepareZatcaPhase2Payload(order) {
  const z2 = settings.zatcaPhase2 || {};
  const { ts, price, rate, vatAmt, exVat } = zatcaInvoiceAmounts(order);
  const icv = nextZatcaIcv(order);
  const uuid = ensureZatcaUuid(order);
  const issueDt = ts.split('T');
  const xml = buildZatcaInvoiceXml({
    invoiceNumber: order.invoiceNumber || order.id,
    uuid,
    issueDate: issueDt[0],
    issueTime: (issueDt[1] || '00:00:00').split('.')[0],
    sellerName: shopName() || '',
    // ZATCA requires the seller's address. `settings.address` is not a key
    // this app has ever written — the field is `addr`, per language — so every
    // Phase-2 XML went to the authority with the street blank.
    sellerStreet: shopField('addr') || '',
    sellerCity: z2.city || 'Riyadh',
    vatNumber: settings.vat || '',
    buyerName: order.client || '',
    total: price,
    subtotal: exVat,
    vatAmount: vatAmt,
    vatRate: settings.enableVat ? rate : 0,
    itemName: order.project || order.id,
    invoiceCounter: icv,
    pih: z2.lastInvoiceHash || 'NWZlY2ViNjZmZmM4NmYzOGQ5NTI3ODZjNmQ2OTZjNzljMmRiYzIzOWRkNGU5MWI4NjJhNGRhNjM3NWQ2OGM5',
  });
  const signResult = await window.hubAPI?.zatcaSignInvoice?.({ canonicalData: xml });
  if (!signResult?.ok) throw new Error(signResult?.error || 'Invoice signing failed');
  return {
    xml,
    xmlBase64: zatcaUtf8ToBase64(xml),
    invoiceHash: signResult.hashBase64,
    uuid,
    invoiceNumber: order.invoiceNumber || order.id,
    invoiceCounter: icv,
    invoiceType: 'simplified',
    environment: z2.environment || 'sandbox',
    pcsid: z2.pcsid,
    csid: z2.csid,
  };
}

function zatcaSubmitAccepted(httpOk, body) {
  return ZatcaSubmit().zatcaSubmitAccepted(httpOk, body);
}

async function submitOrderToZatca(orderId, { manual = false, silent = false } = {}) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return { ok: false, error: 'Order not found' };
  if (order.voidedAt) return { ok: false, error: 'Invoice voided' };
  if (!zatcaPhase2Ready()) return { ok: false, error: 'ZATCA Phase 2 not configured' };
  // `orderEligibleForZatcaSubmit` is the same two conditions, named — and the
  // named one is what the tests exercise. The messages stay separate so a shop
  // is told which of the two stopped it.
  if (!ZatcaSubmit().orderEligibleForZatcaSubmit(order)) {
    return { ok: false, error: 'Order must be completed before ZATCA submission' };
  }
  if (order.zatcaSubmission?.status === 'accepted' && !manual) {
    return { ok: true, skipped: true };
  }

  try {
    const payload = await prepareZatcaPhase2Payload(order);
    const result = await window.hubAPI?.zatcaSubmit?.({
      xmlBase64: payload.xmlBase64,
      invoiceHash: payload.invoiceHash,
      uuid: payload.uuid,
      invoiceNumber: payload.invoiceNumber,
      invoiceType: payload.invoiceType,
      environment: payload.environment,
      pcsid: payload.pcsid,
      csid: payload.csid,
    });
    if (!result) throw new Error('ZATCA submit unavailable');

    const accepted = zatcaSubmitAccepted(result.ok, result.body);
    const errMsg = result.error
      || result.body?.validationResults?.errorMessages?.[0]?.message
      || (typeof result.body === 'object' ? JSON.stringify(result.body) : String(result.status || 'Unknown error'));

    const logEntry = {
      orderId: order.id,
      invoiceNumber: payload.invoiceNumber,
      uuid: payload.uuid,
      icv: payload.invoiceCounter,
      at: new Date().toISOString(),
      httpStatus: result.status ?? null,
      manual: !!manual,
    };

    if (accepted) {
      settings.zatcaPhase2.invoiceCounter = payload.invoiceCounter;
      settings.zatcaPhase2.lastInvoiceHash = payload.invoiceHash;
      order.zatcaSubmission = { ...logEntry, status: 'accepted', message: 'OK' };
      appendZatcaSubmissionLog({ ...logEntry, status: 'accepted', message: 'OK' });
      saveAll();
      if (!silent) toast(t('zatca2.submit_ok') || 'Invoice submitted to ZATCA', 'success');
      if (settings.zatcaPhase2.emailAfterSubmit && typeof emailOrderToClient === 'function') {
        emailOrderToClient(order.id, false).catch(() => {});
      }
      return { ok: true };
    }

    order.zatcaSubmission = { ...logEntry, status: 'rejected', message: errMsg };
    appendZatcaSubmissionLog({ ...logEntry, status: 'rejected', message: errMsg });
    saveAll();
    if (!silent) toast(t('zatca2.submit_failed') || `ZATCA submission failed: ${errMsg}`, 'error', 6000);
    return { ok: false, error: errMsg };
  } catch (e) {
    const msg = String(e.message || e);
    order.zatcaSubmission = {
      orderId: order.id,
      status: 'error',
      message: msg,
      at: new Date().toISOString(),
      manual: !!manual,
    };
    appendZatcaSubmissionLog({ orderId: order.id, status: 'error', message: msg, at: order.zatcaSubmission.at, manual: !!manual });
    saveAll();
    if (!silent) toast(t('zatca2.submit_failed') || `ZATCA submission failed: ${msg}`, 'error', 6000);
    return { ok: false, error: msg };
  }
}

function maybeAutoSubmitZatca(order) {
  const z2 = settings.zatcaPhase2 || {};
  if (!zatcaPhase2Ready() || z2.autoSubmit === false) return;
  if (order.voidedAt || order.status === 'quote') return;
  if (order.status !== 'completed' && order.status !== 'delivered') return;
  if (order.zatcaSubmission?.status === 'accepted') return;
  submitOrderToZatca(order.id, { silent: true })
    .then((r) => {
      if (r?.ok && !r.skipped) toast(t('zatca2.auto_submitted', { id: order.id }) || `Invoice ${order.id} submitted to ZATCA`, 'success', 4000);
      else if (r?.ok === false && !r.skipped) toast(t('zatca2.auto_submit_failed', { id: order.id }) || `ZATCA auto-submit failed for ${order.id}`, 'warning', 5000);
    })
    .catch((e) => console.error('ZATCA auto-submit:', e));
}

function zatcaSubmissionStatusLabel(order) {
  const s = order?.zatcaSubmission?.status;
  if (s === 'accepted') return t('zatca2.status_accepted') || 'Submitted to ZATCA';
  if (s === 'rejected') return t('zatca2.status_rejected') || 'ZATCA rejected';
  if (s === 'error') return t('zatca2.status_error') || 'ZATCA error';
  return t('zatca2.status_pending') || 'Not submitted';
}

// Render the invoice with QR (used by Print, PDF, and WhatsApp paths)
async function renderInvoiceForOrder(order) {
  const ts = order.timestamp
    || (order.date && !Number.isNaN(Date.parse(`${order.date}T12:00:00`))
      ? new Date(`${order.date}T12:00:00`).toISOString()
      : '');
  const price    = +order.price || 0;
  const shipping = +order.shippingCost || 0;
  // Same engine as zatcaInvoiceAmounts — see lib/tax.js. Whether the price
  // includes the tax or the tax is added to it is now the shop's setting rather
  // than an assumption baked into this line.
  const _taxProfile = KhaytTax.profileFromSettings(settings);
  const _tax      = KhaytTax.computeTax(price, _taxProfile);
  const rate      = _taxProfile.rates.reduce((sum, r) => sum + r.percent, 0);
  const vatAmt    = _tax.taxTotal;
  const exVat     = _tax.subtotal;
  // _tax.total, not price. Under INCLUSIVE pricing they are the same number and
  // this changes nothing. Under EXCLUSIVE pricing they are not: order.price is
  // the pre-tax figure and the customer owes tax on top of it, so printing
  // price here would invoice a US shop for less than it is charging.
  const total     = fmtMoney(_tax.total);
  const vatAmount = fmtMoney(vatAmt);
  const subtotal  = fmtMoney(exVat);
  // Reconciling summary (VAT-inclusive, matching the line-items table which is
  // also VAT-inclusive): Subtotal(items) + Rush + Shipping == Total, with VAT
  // shown as "included". order.price already bundles shipping+rush+extras
  // (build.js: finalPrice = goods + rush + shipping + extras), so the old
  // Subtotal=exVat double-counted the separate Rush/Shipping rows.
  const _shipIncl  = +order.shippingCost || 0;
  const _rushIncl  = +order.rushFeeAmount || 0;
  const _discAmt   = Math.max(0, (+order.priceBeforeDiscount || 0) * (+order.discountPct || 0) / 100);
  const itemsSubtotalIncl = price - _shipIncl - _rushIncl;          // parts + extras, post-discount
  const subtotalShown = fmtMoney(order.discountPct > 0 ? itemsSubtotalIncl + _discAmt : itemsSubtotalIncl);
  let qrSvg = '';
  // Why there is no QR, when there is none. An empty box on a tax invoice needs
  // to say what is missing, and the shop needs telling before it hands the
  // document over — not by noticing grey text on a PDF.
  let qrProblem = null;
  if (settings.enableZatca && window.hubAPI?.generateQR) {
    // A QR missing a required tag SCANS and is invalid, which is worse than an
    // empty box: a code that reads invites no question. Refuse to draw one.
    const ready = zatcaQrReadiness(settings);
    if (!ready.ok) {
      qrProblem = ready.missing.map((k) => t(k)).join(' · ');
      if (typeof toast === 'function') toast(t('inv.qr_not_compliant') + ' — ' + qrProblem, 'error', 12000);
    }
    try {
      if (!ready.ok) throw new Error('zatca-qr-not-ready');
      const z2 = settings.zatcaPhase2;
      let tlvB64;
      if (z2?.enabled && (z2.csid || z2.pcsid)) {
        // Phase 2: generate UBL XML, sign it, build TLV with tags 1–8
        const issueDt  = (ts || new Date().toISOString()).split('T');
        const _z2profile = KhaytTax.profileFromSettings(settings);
        const _z2tax = KhaytTax.computeTax(+price || 0, _z2profile);
        const xml = buildZatcaInvoiceXml({
          invoiceNumber: order.invoiceNumber || order.id,
          uuid:          order.zatcaUuid || order.id,
          issueDate:     issueDt[0],
          issueTime:     (issueDt[1] || '00:00:00').split('.')[0],
          sellerName:    shopName() || '',
          sellerStreet:  shopField('addr') || '',   // see the note on the other XML build
          sellerCity:    z2.city || 'Riyadh',
          vatNumber:     settings.vat || '',
          buyerName:     order.client || '',
          // Through the engine like every other money path. Identical arithmetic
          // for an inclusive shop — which is every shop that should have ZATCA
          // on — but a Saudi shop that switched to exclusive pricing would
          // otherwise submit a total that disagreed with its own invoice.
          total:         _z2tax.total,
          subtotal:      _z2tax.subtotal,
          vatAmount:     _z2tax.taxTotal,
          vatRate:       _z2profile.rates.reduce((sum, r) => sum + r.percent, 0),
          itemName:      order.project || order.id,
          invoiceCounter: (z2.invoiceCounter || 0) + 1,
          pih:           z2.lastInvoiceHash || 'NWZlY2ViNjZmZmM4NmYzOGQ5NTI3ODZjNmQ2OTZjNzljMmRiYzIzOWRkNGU5MWI4NjJhNGRhNjM3NWQ2OGM5',
        });
        tlvB64 = await buildZatcaPhase2TLV({
          sellerName: shopName() || '',
          vatNumber:  settings.vat || '',
          timestamp:  ts,
          total, vatAmount,
          canonicalData: xml,
        });
        // Store the UUID on the order for future reference
        if (!order.zatcaUuid) {
          order.zatcaUuid = order.id + '-' + Date.now().toString(36);
          const idx = printLog.findIndex(o => o.id === order.id);
          if (idx !== -1) { printLog[idx] = { ...printLog[idx], zatcaUuid: order.zatcaUuid }; saveAll(); }
        }
      } else {
        // Phase 1 fallback
        tlvB64 = buildZatcaTLV({ sellerName: shopName() || '', vatNumber: settings.vat || '', timestamp: ts, total, vatAmount });
      }
      qrSvg = await window.hubAPI.generateQR(tlvB64, { width: 140, margin: 1 });
    } catch (e) {
      // Keep a readiness reason: it is specific, and "could not be generated"
      // would send the shop looking in the wrong place.
      if (!qrProblem) {
        console.error('ZATCA QR error:', e);
        qrProblem = t('inv.qr_failed');
        if (typeof toast === 'function') toast(t('inv.qr_not_compliant') + ' — ' + qrProblem, 'error', 12000);
      }
    }
  }

  // Payment QR — EMVCo-inspired format for GCC banking apps (SARIE/Mada compatible)
  let payQrSvg = '';
  if (settings.iban && window.hubAPI?.generateQR) {
    const iban = settings.iban.replace(/\s+/g, '');
    const beneName = shopName() || '';
    const payAmt = price.toFixed(2);
    const payRef = order.invoiceNumber || order.id;
    // Structured format: BeneficiaryName\nIBAN\nAmount\nRef
    const payText = `${beneName}\n${iban}\n${payAmt}\n${payRef}`;
    try { payQrSvg = await window.hubAPI.generateQR(payText, { width: 120, margin: 1 }); }
    catch (e) { console.warn('Payment QR failed', e); }
  }

  renderInvoice(order, { qrSvg, qrProblem, payQrSvg, total, vatAmount, subtotal, subtotalShown, vatRate: rate, shipping });
  maybeAutoSubmitZatca(order);
}

/* ============================================================
   New Feature 3: Proforma Invoice
   ============================================================ */
async function generateProformaInvoice(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;

  // Render the regular invoice first
  await renderInvoiceForOrder(order);

  // Inject proforma watermark and change the title
  const area = $('#invoice-print-area');
  if (area) {
    // Change title text nodes that say "Invoice" / "فاتورة"
    area.querySelectorAll('.inv-title, .inv-heading, h1, h2').forEach(el => {
      if (/invoice|فاتورة/i.test(el.textContent)) {
        el.textContent = t('inv.proforma_title');
      }
    });
    // Inject watermark overlay if not already present
    if (!area.querySelector('.proforma-watermark')) {
      const wm = document.createElement('div');
      wm.className = 'proforma-watermark';
      wm.textContent = t('inv.proforma_title');
      area.style.position = 'relative';
      area.appendChild(wm);
    }
  }

  // Open print dialog
  window.print();

  // Remove watermark after print so area is clean for next real invoice
  setTimeout(() => {
    const wm = area?.querySelector('.proforma-watermark');
    if (wm) wm.remove();
  }, 1000);
}

/* --- extracted 18039-18214 --- */
/**
 * Can this shop produce a ZATCA QR that is actually valid?
 *
 * The QR encodes five TLV tags and ZATCA requires all five to be present and
 * non-empty. buildZatcaTLV coerced every field with `|| ''`, so a shop that had
 * switched ZATCA on but not entered its VAT number produced this:
 *
 *     tag 1 len 15 value: "Khayt Test Shop"
 *     tag 2 len  0 value: ""            ← the VAT number
 *     tag 3 len 20 value: "2026-09-03T10:00:00Z"
 *     tag 4 len  6 value: "450.00"
 *     tag 5 len  5 value: "58.70"
 *
 * That QR SCANS. It is also invalid, which makes it worse than no QR at all:
 * an empty box invites a question, and a code that scans does not. The shop
 * hands a customer an invoice that looks compliant and is not, and nothing
 * anywhere says so.
 *
 * Only the two fields a shop configures are checked. The timestamp and the two
 * money figures are computed per invoice and cannot be blank without a bigger
 * problem than this.
 *
 * @returns {{ok: boolean, missing: string[]}} missing holds i18n keys
 */
/**
 * ZATCA Phase 1 — the QR a Saudi tax invoice must carry.
 *
 * The payload is lib/zatca-qr.js: five BER-TLV tags, base64'd. It was here,
 * which meant only this window could produce a compliant invoice.
 *
 * These two keep their names because the rest of this file and its tests use
 * them, and because the readiness check needs the shop's name resolved through
 * the content languages — which is the app's job, not the module's.
 */
function zatcaQrReadiness(s) {
  return ZatcaQr().readiness(s || {}, typeof shopName === 'function' ? shopName() : '');
}

function buildZatcaTLV(fields) {
  return ZatcaQr().buildTLV(fields, { base64: (bin) => btoa(bin) });
}

/**
 * The submission rules, however this file happens to be loaded.
 *
 * Four of these — `zatcaPhase2Ready`, `nextZatcaIcv`, `appendZatcaSubmissionLog`
 * and `zatcaSubmitAccepted` — were written out again here, and this window ran
 * the copies. `lib/zatca-submit.js` had the test suite. They agreed, checked
 * line by line, but agreement between two copies is a fact about today.
 */
function ZatcaSubmit() {
  if (ZatcaSubmit.cached) return ZatcaSubmit.cached;
  if (typeof globalThis !== 'undefined' && globalThis.KhaytZatcaSubmit) {
    ZatcaSubmit.cached = globalThis.KhaytZatcaSubmit;
    return ZatcaSubmit.cached;
  }
  try { ZatcaSubmit.cached = require('../lib/zatca-submit.js'); }
  catch (e) { ZatcaSubmit.cached = null; }
  return ZatcaSubmit.cached;
}

/** The QR payload, however this file happens to be loaded. */
function ZatcaQr() {
  if (ZatcaQr.cached) return ZatcaQr.cached;
  if (typeof globalThis !== 'undefined' && globalThis.KhaytZatcaQr) {
    ZatcaQr.cached = globalThis.KhaytZatcaQr;
    return ZatcaQr.cached;
  }
  try { ZatcaQr.cached = require('../lib/zatca-qr.js'); }
  catch (e) { ZatcaQr.cached = null; }
  return ZatcaQr.cached;
}

/* ============================================================
   ZATCA Phase 2 — UBL 2.1 Simplified Invoice XML
   ============================================================ */
function buildZatcaInvoiceXml({ invoiceNumber, uuid, issueDate, issueTime, sellerName, sellerStreet, sellerCity, vatNumber, buyerName, total, subtotal, vatAmount, vatRate, itemName, invoiceCounter, pih }) {
  const x = (s) => String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  const amt = (n) => (Math.round((+n || 0) * 100) / 100).toFixed(2);
  // Reconcile the rounding penny onto the subtotal so the document balances, exactly as
  // lib/accounting-export.js does. Rounding subtotal and VAT INDEPENDENTLY from the
  // unrounded split can leave TaxExclusiveAmount + TaxAmount a cent away from
  // TaxInclusiveAmount, which is invalid UBL. Harmless at Saudi's 15% (0 mismatches over
  // 2M amounts, verified) — but the VAT rate is configurable and enableZatca defaults to
  // true, so a shop at 20% hit it on ~12.6% of totals (1.05 emitted as 0.88 + 0.18).
  const totalR = Math.round((+total || 0) * 100) / 100;
  const vatR = Math.round((+vatAmount || 0) * 100) / 100;
  total = totalR; vatAmount = vatR; subtotal = Math.round((totalR - vatR) * 100) / 100;
  return `<?xml version="1.0" encoding="UTF-8"?>
<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
         xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
         xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
  <cbc:ProfileID>reporting:1.0</cbc:ProfileID>
  <cbc:ID>${x(invoiceNumber)}</cbc:ID>
  <cbc:UUID>${x(uuid)}</cbc:UUID>
  <cbc:IssueDate>${x(issueDate)}</cbc:IssueDate>
  <cbc:IssueTime>${x(issueTime)}</cbc:IssueTime>
  <cbc:InvoiceTypeCode name="0200000">388</cbc:InvoiceTypeCode>
  <cbc:DocumentCurrencyCode>SAR</cbc:DocumentCurrencyCode>
  <cbc:TaxCurrencyCode>SAR</cbc:TaxCurrencyCode>
  <cac:AdditionalDocumentReference>
    <cbc:ID>ICV</cbc:ID>
    <cbc:UUID>${x(invoiceCounter)}</cbc:UUID>
  </cac:AdditionalDocumentReference>
  <cac:AdditionalDocumentReference>
    <cbc:ID>PIH</cbc:ID>
    <cac:Attachment>
      <cbc:EmbeddedDocumentBinaryObject mimeCode="text/plain">${x(pih)}</cbc:EmbeddedDocumentBinaryObject>
    </cac:Attachment>
  </cac:AdditionalDocumentReference>
  <cac:AccountingSupplierParty>
    <cac:Party>
      <cac:PartyName><cbc:Name>${x(sellerName)}</cbc:Name></cac:PartyName>
      <cac:PostalAddress>
        <cbc:StreetName>${x(sellerStreet || sellerCity)}</cbc:StreetName>
        <cbc:CityName>${x(sellerCity)}</cbc:CityName>
        <cac:Country><cbc:IdentificationCode>SA</cbc:IdentificationCode></cac:Country>
      </cac:PostalAddress>
      <cac:PartyTaxScheme>
        <cbc:CompanyID>${x(vatNumber)}</cbc:CompanyID>
        <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
      </cac:PartyTaxScheme>
      <cac:PartyLegalEntity><cbc:RegistrationName>${x(sellerName)}</cbc:RegistrationName></cac:PartyLegalEntity>
    </cac:Party>
  </cac:AccountingSupplierParty>
  <cac:AccountingCustomerParty>
    <cac:Party>
      <cac:PartyName><cbc:Name>${x(buyerName)}</cbc:Name></cac:PartyName>
      <cac:PartyLegalEntity><cbc:RegistrationName>${x(buyerName)}</cbc:RegistrationName></cac:PartyLegalEntity>
    </cac:Party>
  </cac:AccountingCustomerParty>
  <cac:TaxTotal>
    <cbc:TaxAmount currencyID="SAR">${amt(vatAmount)}</cbc:TaxAmount>
    <cac:TaxSubtotal>
      <cbc:TaxableAmount currencyID="SAR">${amt(subtotal)}</cbc:TaxableAmount>
      <cbc:TaxAmount currencyID="SAR">${amt(vatAmount)}</cbc:TaxAmount>
      <cac:TaxCategory>
        <cbc:ID>S</cbc:ID>
        <cbc:Percent>${amt(vatRate)}</cbc:Percent>
        <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
      </cac:TaxCategory>
    </cac:TaxSubtotal>
  </cac:TaxTotal>
  <cac:LegalMonetaryTotal>
    <cbc:LineExtensionAmount currencyID="SAR">${amt(subtotal)}</cbc:LineExtensionAmount>
    <cbc:TaxExclusiveAmount currencyID="SAR">${amt(subtotal)}</cbc:TaxExclusiveAmount>
    <cbc:TaxInclusiveAmount currencyID="SAR">${amt(total)}</cbc:TaxInclusiveAmount>
    <cbc:PayableAmount currencyID="SAR">${amt(total)}</cbc:PayableAmount>
  </cac:LegalMonetaryTotal>
  <cac:InvoiceLine>
    <cbc:ID>1</cbc:ID>
    <cbc:InvoicedQuantity unitCode="PCE">1</cbc:InvoicedQuantity>
    <cbc:LineExtensionAmount currencyID="SAR">${amt(subtotal)}</cbc:LineExtensionAmount>
    <cac:TaxTotal>
      <cbc:TaxAmount currencyID="SAR">${amt(vatAmount)}</cbc:TaxAmount>
      <cbc:RoundingAmount currencyID="SAR">${amt(total)}</cbc:RoundingAmount>
    </cac:TaxTotal>
    <cac:Item>
      <cbc:Name>${x(itemName)}</cbc:Name>
      <cac:ClassifiedTaxCategory>
        <cbc:ID>S</cbc:ID>
        <cbc:Percent>${amt(vatRate)}</cbc:Percent>
        <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
      </cac:ClassifiedTaxCategory>
    </cac:Item>
    <cac:Price>
      <cbc:PriceAmount currencyID="SAR">${amt(subtotal)}</cbc:PriceAmount>
    </cac:Price>
  </cac:InvoiceLine>
</Invoice>`;
}

/* ============================================================
   ZATCA Phase 2 — Signed TLV QR (tags 1–8)
   ============================================================ */
async function buildZatcaPhase2TLV({ sellerName, vatNumber, timestamp, total, vatAmount, canonicalData }) {
  const enc = new TextEncoder();
  function tlvBytes(tag, value) {
    const len = value.length;
    // BER-TLV length: 1-byte (≤127), 0x81 + 1-byte (≤255), 0x82 + 2-byte (>255).
    let header;
    if (len <= 127) {
      header = new Uint8Array([tag, len]);
    } else if (len <= 255) {
      header = new Uint8Array([tag, 0x81, len]);
    } else {
      header = new Uint8Array([tag, 0x82, (len >> 8) & 0xff, len & 0xff]);
    }
    const out = new Uint8Array(header.length + len);
    out.set(header, 0); out.set(value, header.length);
    return out;
  }

  const fields = [
    tlvBytes(1, enc.encode(String(sellerName || ''))),
    tlvBytes(2, enc.encode(String(vatNumber  || ''))),
    tlvBytes(3, enc.encode(String(timestamp  || ''))),
    tlvBytes(4, enc.encode(String(total      || ''))),
    tlvBytes(5, enc.encode(String(vatAmount  || ''))),
  ];

  // Sign via main process; it hashes + signs canonicalData and returns base64 values
  const signResult = await window.hubAPI?.zatcaSignInvoice?.({ canonicalData: canonicalData || '' });
  if (signResult?.ok) {
    // Tag 6: SHA-256 hash bytes (raw, not hex)
    const hashBytes = Uint8Array.from(atob(signResult.hashBase64), c => c.charCodeAt(0));
    fields.push(tlvBytes(6, hashBytes));
    // Tag 7: ECDSA signature bytes (DER)
    const sigBytes = Uint8Array.from(atob(signResult.signatureBase64), c => c.charCodeAt(0));
    fields.push(tlvBytes(7, sigBytes));
    // Tag 8: Public key (SPKI DER bytes, skip PEM header/footer)
    if (signResult.publicKey) {
      const pemBody = signResult.publicKey.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
      const pubBytes = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0));
      fields.push(tlvBytes(8, pubBytes));
    }
  }

  const totalLen = fields.reduce((s, f) => s + f.length, 0);
  const combined = new Uint8Array(totalLen);
  let off = 0; for (const f of fields) { combined.set(f, off); off += f.length; }
  let bin = ''; for (let i = 0; i < combined.length; i++) bin += String.fromCharCode(combined[i]);
  return btoa(bin);
}

// "Print invoice" path — renders into the print area then opens the system print dialog
async function generateInvoice(id) {
  const order = printLog.find(o => o.id === id);
  if (!order) return;
  await renderInvoiceForOrder(order);
  setTimeout(() => window.print(), 80);
}

/* --- extracted 18219-18408 --- */
async function voidInvoice(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  if (order.voidedAt) {
    toast(t('inv.already_voided'), 'warning');
    return;
  }
  const ok = await confirmModal(t('inv.void_confirm', { id: order.id }), { danger: true, okText: t('inv.void_btn') });
  if (!ok) return;
  // Calculate total weight for the waste checkbox label
  const voidTotalWeight = (order.parts || []).reduce((s, p) => s + (+p.weightG || +p.printWeight || 0), 0);
  const voidMaterial = order.material || (order.parts || []).find(p => p.material)?.material || '';
  const hasWeightData = voidTotalWeight > 0 && voidMaterial;
  openFormModal({
    title: t('inv.void_btn') + ' — ' + order.id,
    saveLabel: t('inv.void_btn'),
    sizeLg: false,
    bodyHtml: `
      <label>${escapeHtml(t('inv.void_reason'))}</label>
      <input type="text" id="voidReasonInput" placeholder="${escapeHtml(t('inv.void_reason_ph'))}" style="width:100%;">
      ${hasWeightData ? `
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-top:14px;font-size:13px;">
        <input type="checkbox" id="voidLogWasteCheck" checked style="width:auto;margin:0;">
        <span>${escapeHtml(t('waste.voided_order'))} (${voidTotalWeight.toFixed(0)}g ${escapeHtml(voidMaterial)})</span>
      </label>` : ''}
    `,
    onMount(modal) { setTimeout(() => modal.querySelector('#voidReasonInput')?.focus(), 40); },
    onSave(modal) {
      order.voidedAt = new Date().toISOString();
      order.voidedReason = modal.querySelector('#voidReasonInput').value.trim() || 'Voided';
      order.status = order.status === 'completed' ? 'completed' : order.status; // keep status
      order.paymentStatus = 'voided';
      if (!order.statusHistory) order.statusHistory = [];
      order.statusHistory.push({ status: 'voided', at: order.voidedAt });
      if (order.statusHistory.length > 200) order.statusHistory = order.statusHistory.slice(-200);
      // Feature 5 (UX): Auto-log material waste if the order has parts with weight data
      const logWasteChk = modal.querySelector('#voidLogWasteCheck');
      if (logWasteChk && logWasteChk.checked) {
        const totalWeight = (order.parts || []).reduce((s, p) => s + (+p.weightG || +p.printWeight || 0), 0);
        const material = order.material || (order.parts || []).find(p => p.material)?.material || '';
        if (totalWeight > 0 && material) {
          wasteLog.unshift({
            id: uid('W'),
            date: localDateStr(),
            orderId: order.id,
            machineId: order.machineId || null,
            material,
            weight: totalWeight,
            failureType: 'operator_error',
            notes: t('waste.voided_order'),
            cost: 0,
          });
        }
      }
      saveAll();
      renderLogs(); renderKanban();
      toast(t('inv.voided_toast', { id: order.id }), 'success');
      return true;
    }
  });
}

function openCreditNoteModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  let creditAmt = +order.price || 0;
  let reason = '';

  const bodyHtml = `
    <p style="font-size:12.5px; color:var(--text-muted); margin:0 0 14px;">
      ${escapeHtml(t('cn.ref_order'))}: <strong>${escapeHtml(order.id)}</strong> · ${fmtPrice(order.price)} ${currencySymbol()}
    </p>
    <label>${escapeHtml(t('cn.credit_amount'))} (${currencySymbol()})</label>
    <input type="number" id="cnAmtInput" value="${creditAmt.toFixed(2)}" min="0.01" step="0.01" max="${order.price}">
    <label style="margin-top:14px;">${escapeHtml(t('cn.reason'))}</label>
    <textarea id="cnReasonInput" rows="3" style="resize:vertical;" placeholder="${escapeHtml(t('cn.reason_ph'))}">${escapeHtml(reason)}</textarea>`;

  openFormModal({
    title: t('cn.title'),
    saveLabel: t('cn.generate'),
    sizeLg: false,
    bodyHtml,
    onSave() {
      const amt = Math.min(Math.max(0.01, num(document.getElementById('cnAmtInput').value, creditAmt)), +order.price);
      const rsn = document.getElementById('cnReasonInput').value.trim();
      generateCreditNote(order, amt, rsn);
      return true;
    }
  });
}

function generateCreditNote(order, creditAmount, reason) {
  // A credit note reduces the amount DUE (a refund / cancelled charge). It is
  // recorded only in creditNotes[]; paidAmount is left untouched so the credit
  // is applied exactly once — orderOwedBase and payStatus both subtract it from
  // the effective price. (Mutating paidAmount here double-counted the credit.)
  if (!order.creditNotes) order.creditNotes = [];
  order.creditNotes.push({ id: 'CN-' + Date.now().toString(36), amount: creditAmount, reason, issuedAt: new Date().toISOString() });
  const totalCredited = order.creditNotes.reduce((s, cn) => s + (+cn.amount || 0), 0);
  // If credit equals full price, treat as voided for reporting
  if (totalCredited >= (+order.price || 0)) {
    order.creditedAt = new Date().toISOString();
  }
  saveAll();
  const area = $('#invoice-print-area');
  const isAr = i18n.current === 'ar';
  const dir  = isAr ? 'rtl' : 'ltr';
  // Same rule as the invoice — see renderInvoice(). A credit note and a delivery
  // note are customer-facing documents too, and were bilingual unconditionally.
  const _dl = KhaytInvoiceLanguage.resolveDocumentLanguage({
    mode: settings.invoiceBilingual, lang: i18n.current,
    secondary: settings.invoiceSecondLang, enableZatca: settings.enableZatca,
  });
  const bi = _dl.bilingual;
  const secondLang = _dl.secondary;
  const bizPrimary = shopName();
  const cnId = 'CN-' + order.id;
  const today = localDateStr();
  const linkedClient = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const clientName = (order.project || '').trim() || t('inv.walk_in');
  const clientSub  = linkedClient ? [linkedClient.phone, linkedClient.email].filter(Boolean).join(' · ') : '';
  // Feature 3: Build reversal reference line
  const invoiceNumber = order.invoiceNumber || order.id;
  const originalDate  = order.date || '';

  area.innerHTML = `
    <div class="inv-wrap">
    <div class="inv-top-bar" style="background:#b91c1c;"></div>
    <div class="inv" dir="${dir}" lang="${i18n.current}" style="--brand:#7f1d1d; --accent:#dc2626; --highlight:#fee2e2;">
      <div class="inv-header">
        <div class="biz">
          <div class="mark">${safeBizLogo() ? `<img src="${safeBizLogo()}" style="max-height:60px; max-width:120px; object-fit:contain;" alt="logo">` : BRAND_MARK_SVG}</div>
          <div class="biz-name">
            <h1>${escapeHtml(bizPrimary || 'Khayt')}</h1>
          </div>
        </div>
        <div class="doc">
          <div class="title" style="color:#dc2626;">${escapeHtml(t("doc.credit_note"))}</div>
          ${bi ? `<div class="title-ar ${isAr ? 'ltr' : 'ar'}">${escapeHtml(i18n.tIn(secondLang, "doc.credit_note"))}</div>` : ''}
          <div class="meta">
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.no"))}</span><span class="v">${escapeHtml(cnId)}</span></div>
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.date"))}</span><span class="v">${escapeHtml(formatPrintDate(today))}</span></div>
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.ref"))}</span><span class="v">${escapeHtml(order.id)}</span></div>
          </div>
        </div>
      </div>

      <div class="cn-ref-line">
        ${escapeHtml(t('cn.reversal_of'))}: <strong>#${escapeHtml(invoiceNumber)}</strong>
        ${originalDate ? ` &mdash; ${escapeHtml(t('cn.original_date'))}: ${escapeHtml(formatPrintDate(originalDate))}` : ''}
      </div>

      <div class="bill-to">
        <div class="label"><span>${escapeHtml(t("doc.issued_to"))}</span></div>
        <div>
          <div class="name">${escapeHtml(clientName)}</div>
          ${clientSub ? `<div class="name-sub">${escapeHtml(clientSub)}</div>` : ''}
        </div>
      </div>

      <table class="lines">
        <thead>
          <tr>
            <th>${escapeHtml(t("doc.description"))}</th>
            <th style="text-align:center; width:60px;">${escapeHtml(t("doc.qty"))}</th>
            <th class="th-amount" style="width:150px;">${escapeHtml(t("doc.amount"))}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <div class="desc-en">${escapeHtml(t("doc.credit_note"))} — ${escapeHtml(order.project || order.id)}</div>
              ${reason ? `<div class="meta">${escapeHtml(reason)}</div>` : ''}
            </td>
            <td class="center">1</td>
            <td class="amount" style="color:#dc2626;">−${fmtMoney(creditAmount)} <span style="color:#666; font-weight:500;">${currencySymbol()}</span></td>
          </tr>
        </tbody>
      </table>

      <div class="totals">
        <div class="summary">
          <div class="row grand">
            <span class="label-en" style="color:#dc2626;">${escapeHtml(t("doc.credit_total"))}</span>
            <span class="v" style="color:#dc2626;">−${fmtMoney(creditAmount)}<span class="unit">${currencySymbol()}</span></span>
          </div>
        </div>
      </div>

      <div class="footer">
        <div class="legal">${escapeHtml(t("doc.generated_by"))}</div>
      </div>
    </div>
    </div>`;

  setTimeout(() => window.print(), 80);
}

/* --- extracted 18410-18484 --- */
function generateDeliveryNote(id) {
  const order = printLog.find(o => o.id === id);
  if (!order) return;
  const area = $('#invoice-print-area');
  const isAr = i18n.current === 'ar';
  const dir  = isAr ? 'rtl' : 'ltr';
  // Same rule as the invoice — see renderInvoice(). A credit note and a delivery
  // note are customer-facing documents too, and were bilingual unconditionally.
  const _dl = KhaytInvoiceLanguage.resolveDocumentLanguage({
    mode: settings.invoiceBilingual, lang: i18n.current,
    secondary: settings.invoiceSecondLang, enableZatca: settings.enableZatca,
  });
  const bi = _dl.bilingual;
  const secondLang = _dl.secondary;
  const bizPrimary = shopName();
  const linkedClient = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const clientName = (order.project || '').trim() || t('inv.walk_in');
  const clientSub  = linkedClient ? [linkedClient.phone, linkedClient.email].filter(Boolean).join(' · ') : '';
  const lines = (order.parts && order.parts.length > 0) ? order.parts
    : [{ name: t('inv.services_default'), qty: 1 }];

  area.innerHTML = `
    <div class="inv-wrap">
    <div class="inv-top-bar" style="background:var(--primary);"></div>
    <div class="inv" dir="${dir}" lang="${i18n.current}" style="--brand:#1a1a2e; --accent:#4a90e2; --highlight:#eef3fc;">
      <div class="inv-header">
        <div class="biz">
          <div class="mark">${safeBizLogo() ? `<img src="${safeBizLogo()}" style="max-height:60px; max-width:120px; object-fit:contain;" alt="logo">` : BRAND_MARK_SVG}</div>
          <div class="biz-name">
            <h1>${escapeHtml(bizPrimary || 'Khayt')}</h1>
          </div>
        </div>
        <div class="doc">
          <div class="title">${escapeHtml(t("doc.delivery_note"))}</div>
          ${bi ? `<div class="title-ar ${isAr ? 'ltr' : 'ar'}">${escapeHtml(i18n.tIn(secondLang, "doc.delivery_note"))}</div>` : ''}
          <div class="meta">
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.ref"))}</span><span class="v">${escapeHtml(order.id)}</span></div>
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.date"))}</span><span class="v">${escapeHtml(formatPrintDate(order.date))}</span></div>
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
        const docs = KhaytProductDocs.packableDocsForOrder(order, typeof products !== "undefined" ? products : []);
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

  setTimeout(() => window.print(), 80);
}

/* --- extracted 18489-18502 --- */
async function generateMilestoneInvoice(orderId, milestone) {
  const order = printLog.find(o => o.id === orderId);
  if (!order || !milestone) return;
  // Build a temporary order-like object with the milestone amount
  const tempOrder = Object.assign({}, order, {
    price: milestone.amount,
    // The milestone bills a % of the full total; shipping/rush/extras/discount are
    // already represented in that %, so don't re-show or re-bill them in full on
    // top of the (smaller) milestone amount.
    shippingCost: 0,
    rushFeeAmount: 0,
    extraLines: [],
    discountPct: 0,
    priceBeforeDiscount: 0,
    _milestoneLabel: milestone.label,
    _milestoneTotal: order.price,
    _milestonePct: milestone.percentage,
  });
  milestone.issuedAt = localDateStr();
  saveAll();
  await renderInvoiceForOrder(tempOrder);
}

/* --- extracted 18874-19253 --- */
/**
 * Put the invoice on the screen so it can be printed.
 *
 * THE DOCUMENT ITSELF IS lib/invoice-document.js. It used to be four hundred
 * lines here, which meant the only thing that could produce a Khayt invoice was
 * this window — and the native Mac app could take a job, price it and be paid
 * for it without being able to give anybody a receipt.
 *
 * What stays is the element, and the one thing a string cannot do: rewriting
 * the digits of laid-out elements when a shop reads Arabic-Indic numerals.
 */
function renderInvoice(order, money) {
  const area = $('#invoice-print-area');
  if (!area) return;
  const D = InvoiceDocument();
  const out = D.invoiceHtml(order, Object.assign({}, money, {
    settings, clients, CURRENCIES, i18n, t, escapeHtml, fmtMoney,
    // Neither the printed date nor the contact line under the bill-to name is
    // passed in: both are the document's own rules now, so this window and the
    // Mac app print the same invoice. `formatPrintDate` below is still the way
    // in for the other documents — delivery notes, credit notes, work orders.
    shopField, safeBizLogo, safeCssColor, BRAND_MARK_SVG,
    orderCurrency: (typeof orderCurrency === 'function') ? orderCurrency : null,
    clientCurrency, payStatus, hijriDate, toArabicNumerals,
  }));
  area.innerHTML = out.html;
  if (out.arabicNumerals) {
    // TEXT NODES, not `textContent`.
    //
    // Assigning `el.textContent` replaces everything inside the element with
    // one flat string, so it did not only change the digits — it deleted the
    // markup. `.biz-meta` holds the address in its own paragraphs and the
    // contact line in another; they came out as one run. `.amount` holds a
    // span for the currency; it lost its styling. And the `<bdi>` that keeps a
    // phone number the right way round was removed along with them, which put
    // the number back to front for exactly the shops that had asked for Arabic
    // digits.
    area.querySelectorAll(out.selector).forEach((el) => {
      const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      for (let node = walk.nextNode(); node; node = walk.nextNode()) {
        node.nodeValue = toArabicNumerals(node.nodeValue);
      }
    });
  }
}

/** The document, however this file happens to be loaded. */
function InvoiceDocument() {
  if (InvoiceDocument.cached) return InvoiceDocument.cached;
  if (typeof globalThis !== 'undefined' && globalThis.KhaytInvoiceDocument) {
    InvoiceDocument.cached = globalThis.KhaytInvoiceDocument;
    return InvoiceDocument.cached;
  }
  try { InvoiceDocument.cached = require('../lib/invoice-document.js'); }
  catch (e) { InvoiceDocument.cached = null; }
  return InvoiceDocument.cached;
}

// Pretty date for invoice headers — e.g. "21 May 2026". The rule is in
// lib/print-date.js so the Mac app prints the same one; this is the renderer's
// way in, kept because a dozen documents call it by this name.
function formatPrintDate(isoDate) {
  const dates = (typeof globalThis !== 'undefined' && globalThis.KhaytPrintDate)
    || require('../lib/print-date.js');
  return dates.printDate(isoDate, localeTag());
}

// The Khayt mark, inlined for the invoice header.
// Inline rather than a file reference: the invoice is rendered to a
// standalone HTML document for print, where a relative asset path has
// nothing to resolve against. currentColor so it prints in the
// document's ink instead of carrying a brand colour onto the paper.
const BRAND_MARK_SVG = `<svg viewBox="0 0 192 192" xmlns="http://www.w3.org/2000/svg" fill="currentColor" fill-rule="evenodd" aria-hidden="true"><path d="M78.2,0 H113.6 V37.5 L100.5,60.0 Q96.0,65.4 91.3,60.0 L78.2,37.5 Z"/><path d="M82.30,74.32 C80.61,74.55 76.82,74.77 73.95,75.35 C71.08,75.94 70.42,76.07 67.94,77.23 C65.46,78.40 63.61,79.35 61.56,81.17 C59.51,82.99 58.71,84.33 57.71,86.33 C56.72,88.34 56.62,89.04 56.59,91.21 C56.55,93.39 56.62,94.86 57.52,97.22 C58.43,99.58 59.42,100.95 61.09,103.04 C62.76,105.12 64.43,106.72 65.88,107.64 C67.32,108.56 67.55,107.96 68.32,107.64 C69.09,107.32 69.44,106.62 69.72,106.04 C70.01,105.46 70.44,106.08 69.72,104.73 C69.01,103.38 66.95,101.16 66.16,99.28 C65.37,97.41 65.46,96.68 65.78,95.34 C66.10,94.01 66.80,93.47 67.75,92.62 C68.71,91.78 68.80,91.72 70.57,91.12 C72.33,90.52 73.08,90.03 76.57,89.62 C80.07,89.21 83.29,88.87 88.02,89.06 C92.75,89.24 96.83,89.94 100.22,90.56 C103.62,91.18 106.55,90.61 105.01,92.15 C103.47,93.69 97.80,95.23 92.53,98.25 C87.25,101.27 83.69,103.41 78.64,107.26 C73.59,111.11 71.17,113.38 67.28,117.49 C63.40,121.60 61.88,123.65 59.21,127.81 C56.55,131.98 55.46,134.49 53.96,138.32 C52.46,142.15 52.16,142.83 51.71,146.96 C51.26,151.09 51.14,154.61 51.71,158.97 C52.27,163.32 52.87,165.05 54.52,168.73 C56.17,172.41 57.43,174.34 59.96,177.36 C62.50,180.38 63.76,181.53 67.19,183.84 C70.63,186.14 72.93,187.36 77.14,188.90 C81.34,190.44 83.86,190.97 88.21,191.53 C92.57,192.09 94.59,192.13 98.91,191.72 C103.23,191.31 105.52,190.93 109.79,189.47 C114.07,188.00 116.78,186.54 120.30,184.40 C123.83,182.26 124.60,181.60 127.44,178.77 C130.27,175.93 132.28,173.55 134.48,170.23 C136.67,166.91 137.25,165.35 138.42,162.16 C139.58,158.97 139.92,157.58 140.29,154.28 C140.67,150.97 140.63,148.80 140.29,145.64 C139.96,142.49 139.73,141.36 138.60,138.51 C137.48,135.66 136.63,133.87 134.66,131.38 C132.69,128.88 131.47,127.77 128.75,126.03 C126.03,124.28 125.11,123.70 121.06,122.65 C117.00,121.60 113.55,121.04 108.48,120.77 C103.41,120.51 99.77,120.89 95.72,121.34 C91.66,121.79 90.22,121.99 88.21,123.03 C86.20,124.06 86.03,124.98 85.68,126.50 C85.32,128.02 85.62,129.33 86.43,130.63 C87.24,131.92 87.03,132.73 89.71,132.97 C92.40,133.22 95.12,132.00 99.85,131.85 C104.58,131.70 109.01,131.70 113.36,132.22 C117.71,132.75 118.86,133.18 121.62,134.48 C124.38,135.77 125.56,136.58 127.16,138.70 C128.75,140.82 129.11,142.83 129.60,145.08 C130.08,147.33 129.86,147.93 129.60,149.96 C129.33,151.99 129.45,152.51 128.28,155.21 C127.12,157.92 126.31,160.30 123.78,163.47 C121.24,166.64 118.60,168.84 115.61,171.07 C112.63,173.31 111.45,173.55 108.86,174.64 C106.27,175.73 106.00,176.03 102.66,176.52 C99.32,177.00 95.27,177.12 92.15,177.08 C89.04,177.04 89.37,176.89 87.09,176.33 C84.80,175.77 83.33,175.47 80.70,174.26 C78.08,173.06 76.29,172.11 73.95,170.32 C71.60,168.54 70.61,167.47 68.97,165.35 C67.34,163.23 66.76,162.91 65.78,159.72 C64.81,156.53 64.02,153.41 64.09,149.40 C64.17,145.38 64.77,143.31 66.16,139.64 C67.55,135.96 68.54,134.40 71.04,131.00 C73.53,127.61 75.13,125.86 78.64,122.65 C82.15,119.44 84.12,117.81 88.59,114.96 C93.05,112.10 96.02,110.64 100.97,108.39 C105.93,106.13 107.47,105.53 113.36,103.70 C119.25,101.86 126.48,100.64 130.44,99.19 C134.40,97.75 132.24,97.91 133.16,96.47 C134.08,95.02 134.66,93.62 135.04,91.96 C135.41,90.31 135.34,89.64 135.04,88.21 C134.74,86.78 134.12,85.83 133.54,84.83 C132.95,83.84 133.31,83.93 132.13,83.24 C130.95,82.54 133.14,82.94 127.62,81.36 C122.11,79.78 111.15,76.78 104.54,75.35 C97.93,73.93 99.02,74.45 94.59,74.23 C90.16,74.00 84.85,74.21 82.39,74.23 C79.93,74.25 83.99,74.10 82.30,74.32Z"/></svg>`;;

  const api = {
    nextInvoiceNumber,
    nextQuoteSeq,
    generateClientStatement,
    exportClientInvoices,
    approveQuote,
    rejectQuote,
    renderInvoiceNumberingSection,
    reviseQuote,
    openQuoteRevisionsModal,
    exportInvoicePDF,
    shareInvoiceWhatsApp,
    sendStatusWhatsApp,
    sendPaymentReminder,
    sendQuoteFollowUp,
    shareTrackingWhatsApp,
    renderInvoiceForOrder,
    generateProformaInvoice,
    buildZatcaTLV,
    buildZatcaInvoiceXml,
    buildZatcaPhase2TLV,
    submitOrderToZatca,
    zatcaPhase2Ready,
    zatcaSubmissionStatusLabel,
    generateInvoice,
    voidInvoice,
    openCreditNoteModal,
    generateCreditNote,
    generateDeliveryNote,
    generateMilestoneInvoice,
    renderInvoice,
    formatPrintDate,
  };

  global.BRAND_MARK_SVG = BRAND_MARK_SVG;
  Object.assign(global, api);
  api.zatcaQrReadiness = zatcaQrReadiness;
  global.KhaytInvoicing = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
