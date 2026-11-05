/**
 * Invoicing: numbering, ZATCA QR/XML, render/print/export, quotes, credit notes.
 */
(function (global) {

/* Feature 7: Configurable invoice number sequence.
   The format, the counter and the January reset are lib/order-new.js
   `allocateInvoiceNumber`, the rule the Mac and the recurring orders number
   with, so a desktop invoice cannot be numbered differently.
   This only adds the save. */
const OrderNew = () => global.KhaytOrderNew
  || (typeof require === 'function' ? require('../lib/order-new.js') : null);
/** Voiding and crediting — lib/invoice-reversal.js, which the Mac writes with too. */
const Reversal = () => global.KhaytInvoiceReversal
  || (typeof require === 'function' ? require('../lib/invoice-reversal.js') : null);
function nextInvoiceNumber() {
  // The book goes in so the counter moves past numbers another computer on
  // this book already issued — settings, where the counter lives, never sync.
  const result = OrderNew().allocateInvoiceNumber(settings, new Date().getFullYear(),
    typeof printLog !== 'undefined' ? printLog : undefined);
  saveAll();
  return result;
}
/* A quote that leaves the quote column for anything but cancelled is an order,
   and an order's invoice carries a number. Only the Approve button and the LAN
   path used to give it one: a quote dragged to Pending, or moved from the Job
   menu or the batch bar, kept no number and its invoice printed the quote's id.
   A number already there (either spelling) is kept, so calling it again never
   uses up a second one. Returns true when it took a new number. */
function ensureOrderInvoiceNumber(order, newStatus) {
  if (!order || order.status !== 'quote' || newStatus === 'quote' || newStatus === 'cancelled') return false;
  const had = order.invoiceNum || order.invoiceNumber;
  if (had) {
    order.invoiceNum = had;
    order.invoiceNumber = had;
    return false;
  }
  order.invoiceNum = nextInvoiceNumber();
  order.invoiceNumber = order.invoiceNum;
  return true;
}
/* Separate quote sequence so two quotes never collide on id (Bug A).
   Quotes intentionally do NOT advance the invoice counter, but they still
   need their own monotonic number or back-to-back quotes share an id. */
function nextQuoteSeq() {
  // lib/order-new.js `allocateQuoteSeq` — the rule the Mac numbers quotes with,
  // reading the book so a quote number another computer used is skipped.
  const seq4 = OrderNew().allocateQuoteSeq(settings, new Date().getFullYear(),
    typeof printLog !== 'undefined' ? printLog : undefined);
  saveAll();
  return seq4;
}

/* --- extracted 6543-6682 --- */
function generateClientStatement(clientId) {
  const c = clients.find(x => x.id === clientId);
  if (!c) return;
  // The statement is lib/shop-documents.js, which the Mac app prints as well.
  // Every figure on it is in the shop's BASE currency, so a multi-currency
  // customer's rows and totals reconcile (orderRevenueBase/orderOwedBase).
  const area = $('#invoice-print-area');
  area.innerHTML = KhaytShopDocuments.clientStatementHtml(c, printLog, shopDocumentContext(null));
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
  const orders = KhaytShopDocuments.invoicesToExport(clientId, printLog, KhaytOrderStatus.isFinished);
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
  // Rejecting a quote deletes it, so it answers to the delete rule: a quote
  // that already took a deposit (or was numbered) is cancelled instead.
  const order = printLog.find(o => o.id === orderId);
  const R = (typeof KhaytRecordDelete !== 'undefined') ? KhaytRecordDelete : null;
  if (!order || !R) return;
  const verdict = R.canDeleteOrder(order);
  if (!verdict.ok) {
    const cancel = await confirmModal(
      t(verdict.reason === 'paid' ? 'oe.delete_refused_paid' : 'oe.delete_refused_invoiced', { id: orderId }),
      { okText: t('oe.cancel_job') },
    );
    if (cancel) updateStatus(orderId, 'cancelled');
    return;
  }
  const ok = await confirmModal(t('quote.reject_q'), { danger: true });
  if (!ok) return;
  // The same delete as deleteLog: the quote goes, and anything booked to it
  // (an expense, time, waste) stays with its link cleared; Undo relinks it.
  const out = R.deleteOrders({ printLog, inventory, expenses, wasteLog, timeEntries, loyaltyLedger }, [orderId]);
  if (!out.deleted.length) return;
  ({ printLog, inventory, expenses, wasteLog, timeEntries, loyaltyLedger } = out.book);
  saveAll();
  renderKanban(); renderLogs();
  toast(t('quote.rejected'), 'success', 5000, {
    undo: () => {
      const back = R.restoreOrders({ printLog, inventory, expenses, wasteLog, timeEntries, loyaltyLedger }, out.deleted);
      ({ printLog, inventory, expenses, wasteLog, timeEntries, loyaltyLedger } = back);
      saveAll(); renderKanban(); renderLogs();
    },
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

  // lib/settings-edit.js `invoiceNumbering` / `invoiceNumberGaps`: the Mac's
  // numbering section sets and audits the counter through the same rules.
  const numbering = (form) => {
    const next = KhaytSettingsEdit.invoiceNumbering(settings, form, { year: new Date().getFullYear() });
    for (const k of ['invNumPrefix', 'invNumNext', 'invNumFormat', 'invNumYear']) {
      if (next[k] !== undefined) settings[k] = next[k];
    }
  };
  el.querySelector('#btnSaveInvNum').addEventListener('click', () => {
    numbering({
      prefix: el.querySelector('#invNumPrefix').value,
      next: el.querySelector('#invNumNext').value,
      format: el.querySelector('#invNumFormat').value,
    });
    saveAll();
    toast(t('set.saved'), 'success');
  });
  el.querySelector('#btnInvNumReset').addEventListener('click', () => {
    numbering({ reset: true });
    saveAll();
    el.querySelector('#invNumNext').value = '1';
    toast(t('set.inv_num_reset'), 'success');
  });
  el.querySelector('#btnInvNumDetectGaps').addEventListener('click', () => {
    const gaps = KhaytSettingsEdit.invoiceNumberGaps(printLog);
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
  // Snapshot current state — lib/quote-revision.js, the rule the Mac app
  // revises a quote by, so both keep the same quoteRevisions[] / quoteVersion.
  KhaytQuoteRevision.revise(order, Date.now());
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
          ${KhaytQuoteRevision.history(order).map(rev => `<tr>
            <td><strong>v${rev.version}</strong></td>
            <td style="font-size:11.5px;">${new Date(rev.snapshotAt).toLocaleDateString(localeTag())}</td>
            <td>${fmtPrice(rev.price)}</td>
            <td style="font-size:11.5px;">${(rev.parts || []).length} parts</td>
            <td style="font-size:11.5px; max-width:140px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">${escapeHtml(rev.notes || '—')}</td>
          </tr>`).join('')}
        </tbody>
      </table></div>`;

  openFormModal({
    title: `📋 ${t('ord.quote_revisions')} — ${escapeHtml(order.project || jobRef(order))} (${t('ord.quote_version', { n: order.quoteVersion || 1 })})`,
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
      defaultName: `${jobRef(order)}.pdf`
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
    try { pdfPath = await window.hubAPI.exportPDF({ askWhere: false, defaultName: `${jobRef(order)}.pdf` }); }
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

/**
 * Send one payment reminder the shop's way, and record it once it has gone.
 *
 * The rules are `lib/payment-reminder.js`, the Mac's too: which way it goes
 * (`reminderChannel`: the shop's choice in Settings, else WhatsApp when the
 * customer has a number, else email), how much it asks for (`reminderAmount`:
 * the unpaid part of the milestones that are due, else what is owed, in the
 * job's own currency), the shop's pay link, and the record
 * (`markReminderPatch`), written HERE, after the send, and nowhere else, so
 * one reminder is one mark. The 6-hour timer only flags.
 *
 * Returns true when a reminder went out (and was recorded).
 */
async function sendPaymentReminder(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return false;
  const R = typeof KhaytPaymentReminder !== 'undefined' ? KhaytPaymentReminder : null;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const channel = R ? R.reminderChannel(settings, client) : (client?.phone ? 'whatsapp' : 'none');
  if (channel === 'none') { toast(t('pay.remind_no_phone'), 'info', 3200); return false; }

  const text = reminderMessage(order, client);
  let sent = false;
  try {
    if (channel === 'email') {
      const name = (typeof shopName === 'function' && shopName()) || 'Khayt';
      const mail = R.reminderEmail({ settings, client, text, shopName: name,
        subject: t('pay.remind_subject', { shop: name }) });
      const result = mail && await window.hubAPI?.sendEmail?.({ to: mail.to, subject: mail.subject,
        body: mail.html, smtpConfig: settings.emailConfig });
      // A mailto fallback opened the shop's mail app with it written: as sent as
      // WhatsApp opened with it typed in.
      sent = !!(result && (result.ok || (result.fallback && result.mailtoUrl)));
      if (!sent) toast((result && result.error) || t('notify.email_failed') || 'Email failed', 'warning', 4000);
    } else if (window.hubAPI?.shareWhatsApp) {
      await window.hubAPI.shareWhatsApp({ phone: client.phone, message: text, pdfPath: null });
      sent = true;
    } else if (window.hubAPI?.openExternal) {
      const phone = (client.phone || '').replace(/\D/g, '');
      window.hubAPI.openExternal(`https://wa.me/${phone}?text=${encodeURIComponent(text)}`);
      sent = true;
    } else {
      toast(t('pay.remind_sent') || 'Open WhatsApp manually to send the reminder', 'info');
    }
  } catch (e) {
    console.warn('sendPaymentReminder:', e);
    toast(t('notify.email_failed') || 'The reminder did not go out', 'warning', 4000);
    sent = false;
  }
  if (!sent) return false;
  if (R) Object.assign(order, R.markReminderPatch(order, Date.now()));
  saveAll();
  if (typeof renderDashboard === 'function') renderDashboard();
  return true;
}

/**
 * The reminder's words: the shop's `tpl-payment`, else Khayt's default, asking
 * for what the reminder is FOR (`reminderAmount`) in the job's own currency,
 * with the shop's pay link after (`payLinkFor`, converted into the shop's
 * currency at the job's saved rate, or left out when there is none).
 */
function reminderMessage(order, client) {
  const R = typeof KhaytPaymentReminder !== 'undefined' ? KhaytPaymentReminder : null;
  const code = typeof orderCurrency === 'function' ? orderCurrency(order) : settings.currency;
  const owed = typeof orderOwedRaw === 'function'
    ? orderOwedRaw(order) : Math.max(0, (+order.price || 0) - (+order.paidAmount || 0));
  const asked = R ? R.reminderAmount(order, owed, settings, Date.now(), client) : { amount: owed };
  const symbol = ((typeof CURRENCIES !== 'undefined' && CURRENCIES[code]) || {}).symbol || code;
  const name = client ? localName(client) : (order.project || '');
  const tpl = waTemplates.find(w => w.id === 'tpl-payment');
  const message = tpl
    ? KhaytWaTemplate.fillTemplate(tpl.body, {
        client: name, id: jobRef(order), price: fmtMoney(asked.amount), currency: symbol,
        due: order.dueDate, status: t('queue.' + order.status),
      })
    : t('pay.remind_default', { name, id: jobRef(order), amount: fmtMoneyIn(asked.amount, code) });
  if (!R) return message;
  const link = R.payLinkFor(settings, asked.amount, { order, currency: code });
  return R.reminderText({ body: message, values: null, payLink: link, payLabel: t('pay.remind_pay_here') });
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
  const name = client ? localName(client) : (order.project || jobRef(order));
  const message = t('quote.followup_msg', {
    name,
    id: order.id,
    project: order.project || jobRef(order),
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
    project: order.project || jobRef(order),
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
    invoiceNumber: invoiceDocNumber(order),
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
    itemName: order.project || jobRef(order),
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
    invoiceNumber: invoiceDocNumber(order),
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
      if (r?.ok && !r.skipped) toast(t('zatca2.auto_submitted', { id: jobRef(order) }) || `Invoice ${jobRef(order)} submitted to ZATCA`, 'success', 4000);
      else if (r?.ok === false && !r.skipped) toast(t('zatca2.auto_submit_failed', { id: jobRef(order) }) || `ZATCA auto-submit failed for ${jobRef(order)}`, 'warning', 5000);
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
async function renderInvoiceForOrder(order, opts = {}) {
  // A proforma is a request for payment before the work is done, not a tax
  // invoice: no ZATCA QR (and no ZATCA UUID stamped on the job for one), no
  // auto-submit, and the job's id rather than an invoice number. The document
  // itself titles and watermarks it (`proforma` in lib/invoice-document.js).
  const proforma = opts.proforma === true;
  // ONE PART OF THE JOB, asked for as a proforma (Turki, Nov 2026): the job's
  // single tax invoice stays the job's; a milestone never takes an invoice
  // number or a ZATCA QR. lib/invoice-document.js prints it as one line.
  const milestone = proforma && opts.milestone ? opts.milestone : null;
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
  // The items row: price less rush and shipping, before any discount. The rule
  // is lib/invoice-document.js invoiceSummary, so the Mac's invoice prints the
  // same Subtotal (it printed the whole price there).
  const subtotalShown = fmtMoney(KhaytInvoiceDocument.invoiceSummary(order, _taxProfile).itemsSubtotal);
  let qrSvg = '';
  // Why there is no QR, when there is none. An empty box on a tax invoice needs
  // to say what is missing, and the shop needs telling before it hands the
  // document over — not by noticing grey text on a PDF.
  let qrProblem = null;
  if (settings.enableZatca && !proforma && window.hubAPI?.generateQR) {
    // A QR missing a required tag SCANS and is invalid, which is worse than an
    // empty box: a code that reads invites no question. Refuse to draw one.
    const ready = zatcaQrReadiness(settings);
    // Tags 4 and 5 are riyals. A job saved in a client's currency is converted
    // at the rate stored on it; with none, there is no honest figure to state
    // and the QR is refused like a missing VAT number (lib/zatca-qr.js qrAmounts).
    const qrMoney = ZatcaQr().qrAmounts(order, settings, { total: _tax.total, vatAmount: vatAmt });
    if (!qrMoney.ok) ready.missing = ready.missing.concat(qrMoney.missing);
    ready.ok = ready.ok && qrMoney.ok;
    // Phase 2 signs the job's own figures into the XML and the QR. Converting
    // the whole document belongs with the Phase 2 work, so until then a job in
    // another currency gets no Phase 2 QR rather than a EUR figure signed as
    // riyals (lib/zatca-qr.js phase2Currency).
    const z2on = !!(settings.zatcaPhase2?.enabled && (settings.zatcaPhase2.csid || settings.zatcaPhase2.pcsid));
    const z2cur = z2on ? ZatcaQr().phase2Currency(order, settings) : { ok: true, missing: [] };
    if (!z2cur.ok) { ready.missing = ready.missing.concat(z2cur.missing); ready.ok = false; }
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
          invoiceNumber: invoiceDocNumber(order),
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
          itemName:      order.project || jobRef(order),
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
        tlvB64 = buildZatcaTLV({ sellerName: shopName() || '', vatNumber: settings.vat || '', timestamp: ts,
          total: fmtMoney(qrMoney.total), vatAmount: fmtMoney(qrMoney.vatAmount) });
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
    // A milestone asks for its own part, tax worked out on it the way the
    // document prints it — not the whole job's price.
    const payAmt = (milestone
      ? KhaytTax.computeTax(+milestone.amount || 0, _taxProfile).total
      : price).toFixed(2);
    const payRef = proforma ? String(order.id) : invoiceDocNumber(order);
    // Structured format: BeneficiaryName\nIBAN\nAmount\nRef
    const payText = `${beneName}\n${iban}\n${payAmt}\n${payRef}`;
    try { payQrSvg = await window.hubAPI.generateQR(payText, { width: 120, margin: 1 }); }
    catch (e) { console.warn('Payment QR failed', e); }
  }

  renderInvoice(order, { qrSvg, qrProblem, payQrSvg, total, vatAmount, subtotal, subtotalShown, vatRate: rate, shipping, proforma, milestone });
  if (!proforma) maybeAutoSubmitZatca(order);
}

/* ============================================================
   New Feature 3: Proforma Invoice
   ============================================================ */
async function generateProformaInvoice(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  // The shared document draws the proforma — title, watermark, no QR, the
  // job's id under "No." — the same paper the Mac prints. This used to render
  // a full tax invoice and then patch its DOM, which left the ZATCA QR and the
  // invoice number on a document that is neither.
  await renderInvoiceForOrder(order, { proforma: true });
  window.print();
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
  const voidMat = Reversal().materialOf(order);
  const voidTotalWeight = voidMat.weight;
  const voidMaterial = voidMat.material;
  const hasWeightData = voidMat.loggable;
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
      // The stamps, the status history and the optional waste row are
      // lib/invoice-reversal.js `voidInvoice`; the status itself is kept.
      const logWasteChk = modal.querySelector('#voidLogWasteCheck');
      const out = Reversal().voidInvoice(order, {
        reason: modal.querySelector('#voidReasonInput').value,
        now: new Date().toISOString(),
        logWaste: !!(logWasteChk && logWasteChk.checked),
        wasteId: uid('W'),
        today: localDateStr(),
        wasteNote: t('waste.voided_order'),
      });
      if (!out.ok) { toast(t('inv.already_voided'), 'warning'); return true; }
      if (out.waste) wasteLog.unshift(out.waste);
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
  // What is left to credit: the price less any earlier credit notes.
  const creditRoom = Reversal().creditRoom(order);
  if (creditRoom < 0.01) { toast(t('cn.nothing_left'), 'warning'); return; }
  let creditAmt = creditRoom;
  let reason = '';

  const bodyHtml = `
    <p style="font-size:12.5px; color:var(--text-muted); margin:0 0 14px;">
      ${escapeHtml(t('cn.ref_order'))}: <strong>${escapeHtml(jobRef(order))}</strong> · ${fmtOrderPrice(order.price, order)}
    </p>
    <label>${escapeHtml(t('cn.credit_amount'))} (${escapeHtml(orderCurrencySymbol(order))})</label>
    <input type="number" id="cnAmtInput" value="${creditAmt.toFixed(2)}" min="0.01" step="0.01" max="${creditRoom}">
    <label style="margin-top:14px;">${escapeHtml(t('cn.reason'))}</label>
    <textarea id="cnReasonInput" rows="3" style="resize:vertical;" placeholder="${escapeHtml(t('cn.reason_ph'))}">${escapeHtml(reason)}</textarea>`;

  openFormModal({
    title: t('cn.title'),
    saveLabel: t('cn.generate'),
    sizeLg: false,
    bodyHtml,
    onSave() {
      const amt = num(document.getElementById('cnAmtInput').value, creditAmt);
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
  // the effective price. The record, the cap and `creditedAt` at full credit
  // are lib/invoice-reversal.js, and so is the document, so the Mac prints
  // the same credit note.
  const R = Reversal();
  const out = R.creditNote(order, {
    amount: creditAmount, reason, now: new Date().toISOString(), id: 'CN-' + Date.now().toString(36),
  });
  if (!out.ok) { toast(t('cn.nothing_left'), 'warning'); return; }
  saveAll();
  const area = $('#invoice-print-area');
  const linkedClient = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const doc = R.creditNoteHtml(order, out.note, {
    t, i18n, escapeHtml, fmtMoney, formatPrintDate, settings,
    shopName: shopName(), logo: safeBizLogo(), BRAND_MARK_SVG,
    currencySymbol: escapeHtml(orderCurrencySymbol(order)),
    jobRef: jobRef(order), invoiceNumber: invoiceDocNumber(order),
    clientName: (order.project || '').trim() || t('inv.walk_in'),
    clientSub: linkedClient ? [linkedClient.phone, linkedClient.email].filter(Boolean).join(' · ') : '',
    today: localDateStr(),
  });
  area.innerHTML = doc.html;

  setTimeout(() => window.print(), 80);
}

/* --- extracted 18410-18484 --- */
function generateDeliveryNote(id) {
  const order = printLog.find(o => o.id === id);
  if (!order) return;
  const area = $('#invoice-print-area');
  // The paper is lib/shop-documents.js, which the Mac app prints as well.
  area.innerHTML = KhaytShopDocuments.deliveryNoteHtml(order, shopDocumentContext(order));
  setTimeout(() => window.print(), 80);
}

/* --- extracted 18489-18502 --- */
async function generateMilestoneInvoice(orderId, milestone) {
  const order = printLog.find(o => o.id === orderId);
  if (!order || !milestone) return;
  // A PROFORMA, one line (Turki, Nov 2026). This printed a tax invoice under
  // the job's own number, listing every part at full price above the smaller
  // milestone total, with a ZATCA QR for an amount that was never the
  // invoice's. The job keeps its one tax invoice; each milestone is a request
  // for part of the money — the same paper the Mac prints
  // (lib/invoice-document.js `milestone`).
  milestone.issuedAt = localDateStr();
  saveAll();
  await renderInvoiceForOrder(order, {
    proforma: true,
    milestone: {
      label: milestone.label || '',
      percentage: +milestone.percentage || 0,
      amount: +milestone.amount || 0,
      total: +order.price || 0,
    },
  });
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
    // Named rather than reached for. The document used to call this window's
    // `getClientTier` as a free variable, which is why the Mac app could not
    // build an invoice for a customer at all once loyalty was on.
    clientTier: (order.clientId && typeof getClientTier === 'function')
      ? getClientTier(order.clientId) : null,
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

/* The number a document names this job by: the one its paper prints
   (lib/invoice-document.js documentNumber). The payment QR's reference, a
   credit note's "reversal of", the ZATCA XML, a payment link and the invoice
   export all name it this way. Before, they read `invoiceNumber || id` while
   the paper printed the id, so for a shop whose invoice prefix differs from
   its numbering prefix the customer paid with INV-… against an ATH-… invoice. */
function invoiceDocNumber(order) {
  return InvoiceDocument().documentNumber(order, settings);
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
const BRAND_MARK_SVG = `<svg viewBox="300 110 424 760" xmlns="http://www.w3.org/2000/svg" fill="currentColor" aria-hidden="true"><rect x="497" y="130" width="30" height="60" rx="12"/><rect x="420" y="176" width="184" height="118" rx="26"/><rect x="452" y="294" width="120" height="22" rx="8"/><path d="M466 316H558L528 362H496Z"/><circle cx="512" cy="396" r="30"/><path d="M368 512C350 480 380 452 424 458C520 472 612 464 688 460C560 488 362 566 354 694C346 816 470 860 690 810" fill="none" stroke="currentColor" stroke-width="64" stroke-linecap="round"/></svg>`;;

  const api = {
    nextInvoiceNumber,
    ensureOrderInvoiceNumber,
    invoiceDocNumber,
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
