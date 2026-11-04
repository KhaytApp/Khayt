/**
 * Document exports: auto-backup, quote approval, milestones, work orders.
 */
/* ============================================================
   Daily auto-backup
   ============================================================ */
async function maybeAutoBackup() {
  if (!settings.autoBackup || !window.hubAPI?.lastBackupDate) return;
  try {
    const last  = await window.hubAPI.lastBackupDate();
    const today = localDateStr();
    const localJson  = JSON.stringify(buildExportPayload({ redactSecrets: false }));
    const icloudJson = JSON.stringify(buildExportPayload({ redactSecrets: true }));
    if (last !== today) {
      // A backup that fails is worse than no backup, because the settings screen
      // goes on showing yesterday's date as though the net were still there.
      // Whatever the reason — too large, disk full, folder gone — say so.
      const r = await window.hubAPI.writeBackup(localJson);
      if (r && r.ok === false) { reportBackupFailure(r.error); return; }
      updateLastBackupDisplay();
    }
    if (settings.useIcloud && window.hubAPI?.writeIcloudBackup) {
      await window.hubAPI.writeIcloudBackup(icloudJson).catch(e => console.warn('iCloud backup failed', e));
    }
  } catch (e) { reportBackupFailure(e && e.message); }
}

/** Auto-backup runs unattended, so a failure has to leave a mark that outlives a toast. */
function reportBackupFailure(detail) {
  console.warn('Auto-backup failed', detail || '');
  try { toast(t('set.backup_failed'), 'error'); } catch (e) { /* toast may not be up yet */ }
  const el = $('#lastBackupDate');
  if (el) {
    // The span carries an inline colour in the markup, so a class would lose.
    el.textContent = t('set.backup_failed');
    el.style.color = 'var(--danger)';
  }
}

async function updateLastBackupDisplay() {
  const el = $('#lastBackupDate');
  if (!el || !window.hubAPI?.lastBackupDate) return;
  try {
    const last = await window.hubAPI.lastBackupDate();
    el.textContent = last || t('set.backup_never');
    el.style.color = 'var(--text-dim)';
  } catch { /* ignore */ }
}

/** One-click "Export all data (CSV)" — writes a CSV per collection into a chosen folder. */
async function exportAllCsv() {
  if (!window.hubAPI?.exportCsvBundle) { toast(t('set.csv_export_error') || 'CSV export unavailable', 'error'); return; }
  const files = KhaytCsvBundle.buildCsvBundle(collectStoreCollections());
  if (!files.length) { toast(t('set.csv_export_empty') || 'No data to export yet', 'error'); return; }
  try {
    const r = await window.hubAPI.exportCsvBundle(files);
    if (r?.canceled) return;
    if (!r?.ok) throw new Error(r?.error || 'failed');
    toast((t('set.csv_exported') || 'Exported {n} CSV files').replace('{n}', r.count), 'success');
  } catch (e) {
    console.error('CSV bundle export failed', e);
    toast(t('set.csv_export_error') || 'CSV export failed', 'error');
  }
}

/* ============================================================
   Dashboard
   ============================================================ */
/* ============================================================
   Feature 6: Quote Approval Page Export
   ============================================================ */
async function exportQuoteApprovalPage(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const bizName = shopName() || 'Khayt';
  const contactEmail = settings.email || '';
  const contactPhone = settings.phone || '';
  const cur = currencySymbol();
  const _tp = KhaytTax.profileFromSettings(settings);
  const _t = KhaytTax.computeTax(+order.price || 0, _tp);
  const vatRate = _tp.rates.reduce((sum, r) => sum + r.percent, 0);
  const vatEnabled = vatRate > 0;
  const subtotal = _t.subtotal;
  const vatAmt = _t.taxTotal;
  // Under exclusive pricing the sheet total is price PLUS tax, so it cannot be
  // the price itself the way it could when every price included tax.
  const grandTotal = _t.total;

  const _qaParts = order.parts || [];
  const _qaTotalBase = _qaParts.reduce((s, p) => s + (+p.baseCost || 0), 0);
  const _qaTotal = +order.price || 0;
  const partsHtml = _qaParts.map((p, i) => {
    const lineTotal = _qaTotalBase > 0
      ? (+p.baseCost / _qaTotalBase) * _qaTotal
      : _qaTotal / Math.max(1, _qaParts.length);
    const qty = p.qty || 1;
    const unitPrice = lineTotal / qty;
    return `
    <tr>
      <td>${i + 1}. ${escapeHtml(p.name || '')}</td>
      <td style="text-align:center;">${qty}</td>
      <td>${escapeHtml(p.material || '')}</td>
      <td style="text-align:right;">${fmtMoney(unitPrice)} ${cur}</td>
      <td style="text-align:right;">${fmtMoney(lineTotal)} ${cur}</td>
    </tr>`;
  }).join('');

  const lanInfo = await window.hubAPI?.getLanUrl?.();
  const approveUrl = lanInfo?.ok ? buildLanQuoteApprovalUrl(lanInfo.url, order) : null;
  let approveQrHtml = '';
  if (approveUrl) {
    try {
      const qrDataUrl = await window.hubAPI.generateQR(approveUrl, { width: 160, dataUrl: true });
      if (qrDataUrl) {
        approveQrHtml = `
        <div style="text-align:center;margin-top:16px;">
          <img src="${qrDataUrl}" alt="QR" width="160" height="160" style="display:block;margin:0 auto 12px;">
          <p style="font-size:0.85rem;word-break:break-all;"><a href="${escapeHtml(approveUrl)}">${escapeHtml(approveUrl)}</a></p>
        </div>`;
      }
    } catch (e) { /* silent */ }
  }
  const howToApprove = approveUrl
    ? (t('ord.quote_how_to_approve_lan') || 'Open the link or scan the QR code to approve online.')
    : t('ord.quote_how_to_approve');

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Quote ${escapeHtml(order.id)} — ${escapeHtml(bizName)}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; color: #1a1a2e; background: #f8f9fa; padding: 20px; }
    .container { max-width: 700px; margin: 0 auto; background: #fff; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 20px rgba(0,0,0,0.08); }
    .header { background: ${safeCssColor(settings.invAccentColor, '#5E2E14')}; color: #fff; padding: 28px 32px; }
    .header h1 { font-size: 1.6rem; font-weight: 700; }
    .header p { opacity: 0.85; font-size: 0.9rem; margin-top: 4px; }
    .body { padding: 28px 32px; }
    .meta { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 24px; }
    .meta-block { }
    .meta-block h3 { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.08em; color: #888; margin-bottom: 4px; }
    .meta-block p { font-size: 0.95rem; color: #1a1a2e; }
    table { width: 100%; border-collapse: collapse; margin: 16px 0; }
    th { background: #f1f3f5; font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.06em; color: #555; padding: 10px 14px; text-align: left; }
    td { padding: 10px 14px; border-bottom: 1px solid #eee; font-size: 0.9rem; }
    .total-row { font-weight: 700; background: #f8f9fa; }
    .approve-section { margin-top: 28px; padding: 20px; background: #f0f7ff; border-radius: 8px; border-left: 4px solid ${safeCssColor(settings.invAccentColor, '#5E2E14')}; }
    .approve-section h2 { font-size: 1.1rem; margin-bottom: 10px; color: ${safeCssColor(settings.invAccentColor, '#5E2E14')}; }
    .approve-section p { font-size: 0.9rem; color: #333; line-height: 1.5; }
    @media (max-width: 600px) { .meta { grid-template-columns: 1fr; } .container { border-radius: 0; } }
    @media print { body { background: #fff; } .container { box-shadow: none; } }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>${escapeHtml(bizName)}</h1>
      <p>${escapeHtml(t('ord.quote_approval_page'))} · ${escapeHtml(order.id)}</p>
    </div>
    <div class="body">
      <div class="meta">
        <div class="meta-block">
          <h3>${escapeHtml(t('inv.invoice_no') || 'Quote #')}</h3>
          <p>${escapeHtml(order.id)}</p>
        </div>
        <div class="meta-block">
          <h3>${escapeHtml(t('inv.date'))}</h3>
          <p>${escapeHtml(order.date || '')}</p>
        </div>
        ${order.quoteExpiresAt ? `<div class="meta-block">
          <h3>Expires</h3>
          <p>${escapeHtml(order.quoteExpiresAt)}</p>
        </div>` : ''}
        ${client ? `<div class="meta-block">
          <h3>${escapeHtml(t('inv.billed_to'))}</h3>
          <p>${escapeHtml(localName(client))}</p>
        </div>` : ''}
      </div>

      <table>
        <thead><tr>
          <th>${escapeHtml(t('inv.description'))}</th>
          <th style="text-align:center;">${escapeHtml(t('inv.qty'))}</th>
          <th>Material</th>
          <th style="text-align:right;">Unit Price</th>
          <th style="text-align:right;">${escapeHtml(t('inv.line_total'))}</th>
        </tr></thead>
        <tbody>
          ${partsHtml || `<tr><td colspan="5">${escapeHtml(order.project || '')}</td></tr>`}
        </tbody>
        <tfoot>
          <tr class="total-row">
            <td colspan="4" style="text-align:right;">${escapeHtml(t('inv.grand_total'))}</td>
            <td style="text-align:right;">${fmtMoney(grandTotal)} ${cur}</td>
          </tr>
          ${vatEnabled ? `<tr style="font-size:0.82rem;color:#888;"><td colspan="4" style="text-align:right;">VAT (${vatRate}%)</td><td style="text-align:right;">${fmtMoney(vatAmt)} ${cur}</td></tr>` : ''}
        </tfoot>
      </table>

      <div class="approve-section">
        <h2>✅ ${escapeHtml(t('ord.quote_approval_page'))}</h2>
        <p>${escapeHtml(howToApprove)}</p>
        ${approveQrHtml}
        ${!approveUrl && contactEmail ? `<p style="margin-top:8px;">📧 <a href="mailto:${encodeURIComponent(contactEmail)}?subject=${encodeURIComponent('I approve quote ' + order.id)}">${escapeHtml(contactEmail)}</a></p>` : ''}
        ${!approveUrl && contactPhone ? `<p style="margin-top:4px;">📱 <a href="https://wa.me/${contactPhone.replace(/\D/g,'')}?text=${encodeURIComponent('I approve quote ' + order.id)}">${escapeHtml(contactPhone)} (WhatsApp)</a></p>` : ''}
      </div>
    </div>
  </div>
</body>
</html>`;

  try {
    const saved = await window.hubAPI.saveHtml(html, `quote-${orderId}.html`);
    if (saved) toast(t('ord.quote_approval_saved'), 'success');
  } catch (e) {
    console.error('exportQuoteApprovalPage error', e);
    toast(t('ord.approval_save_failed'), 'error');
  }
}

/* ============================================================
   Feature 3 (this batch): Milestone / partial invoice
   ============================================================ */

function openMilestoneInvoices(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  if (!order.milestoneInvoices) order.milestoneInvoices = [];

  function listHtml() {
    if (order.milestoneInvoices.length === 0) {
      return `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('waste.empty'))}</p>`;
    }
    return `<table style="width:100%;font-size:12.5px;border-collapse:collapse;">
      <thead><tr style="border-bottom:1px solid var(--border-soft);color:var(--text-muted);">
        <th style="padding:5px 8px;text-align:left;">${escapeHtml(t('ord.milestone_label'))}</th>
        <th style="padding:5px 8px;text-align:right;">${escapeHtml(t('ord.milestone_pct'))}</th>
        <th style="padding:5px 8px;text-align:right;">${escapeHtml(t('ord.milestone_amount'))}</th>
        <th style="padding:5px 8px;">${escapeHtml(t('ord.milestone_issued'))}</th>
        <th style="padding:5px 8px;">${escapeHtml(t('ord.milestone_due'))}</th>
        <th></th>
      </tr></thead>
      <tbody>
        ${order.milestoneInvoices.map((m, i) => `<tr style="border-bottom:1px solid rgba(255,255,255,0.05);">
          <td style="padding:6px 8px;">${escapeHtml(m.label)}</td>
          <td style="padding:6px 8px;text-align:right;">${escapeHtml(String(m.percentage))}%</td>
          <td style="padding:6px 8px;text-align:right;">${fmtPrice(m.amount)}</td>
          <td style="padding:6px 8px;color:var(--text-muted);">${m.issuedAt ? escapeHtml(m.issuedAt) : '—'}</td>
          <td style="padding:6px 8px;"><input type="date" data-mi-due="${i}" value="${escapeHtml(m.dueDate || '')}" aria-label="${escapeHtml(t('ord.milestone_due'))}" style="font-size:12px;"></td>
          <td style="padding:6px 8px;">
            <button class="btn small" data-mi="${i}">${escapeHtml(t('ord.milestone_issue'))}</button>
            <button class="btn danger small" data-mi-del="${i}" style="margin-inline-start:4px;" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
  }

  openFormModal({
    title: `${t('ord.milestone_invoices')} — ${escapeHtml(order.id)}`,
    sizeLg: true,
    noSave: true,
    bodyHtml: `
      <div id="milestoneListWrap">${listHtml()}</div>
      <hr class="divider" style="margin:16px 0;">
      <div style="display:grid;grid-template-columns:2fr 1fr 1fr 1fr;gap:8px;align-items:end;">
        <div>
          <label style="margin:0;">${escapeHtml(t('ord.milestone_label'))}</label>
          <input type="text" id="msLabel" placeholder="e.g. Deposit" style="font-size:12.5px;">
        </div>
        <div>
          <label style="margin:0;">${escapeHtml(t('ord.milestone_pct'))} (%)</label>
          <input type="number" id="msPct" min="1" max="100" step="1" placeholder="50" style="font-size:12.5px;">
        </div>
        <div>
          <label style="margin:0;">${escapeHtml(t('ord.milestone_amount'))} (${currencySymbol()})</label>
          <input type="number" id="msAmount" min="0" step="0.01" placeholder="0.00" style="font-size:12.5px;">
        </div>
        <div>
          <label style="margin:0;" for="msDue">${escapeHtml(t('ord.milestone_due'))}</label>
          <input type="date" id="msDue" style="font-size:12.5px;">
        </div>
      </div>
      <div style="display:flex;gap:8px;margin-top:10px;">
        <button class="btn small primary" id="btnAddMilestone">${escapeHtml(t('ord.milestone_add'))}</button>
      </div>`,
    onMount(modal) {
      const wrap = modal.querySelector('#milestoneListWrap');
      function refresh() { wrap.innerHTML = listHtml(); wireIssue(); }
      function wireIssue() {
        wrap.querySelectorAll('[data-mi]').forEach(btn => {
          btn.addEventListener('click', () => {
            generateMilestoneInvoice(orderId, order.milestoneInvoices[+btn.dataset.mi]);
          });
        });
        // A milestone's optional due date: what the payment reminder chases it by
        // (lib/payment-reminder.js milestonesDue). Set on the row in place, so any
        // other key the row carries stays as it was.
        wrap.querySelectorAll('[data-mi-due]').forEach(input => {
          input.addEventListener('change', () => {
            const m = order.milestoneInvoices[+input.dataset.miDue];
            if (!m) return;
            if (/^\d{4}-\d{2}-\d{2}$/.test(input.value)) m.dueDate = input.value; else delete m.dueDate;
            saveAll();
          });
        });
        wrap.querySelectorAll('[data-mi-del]').forEach(btn => {
          btn.addEventListener('click', () => {
            order.milestoneInvoices.splice(+btn.dataset['mi-del'] ?? +btn.getAttribute('data-mi-del'), 1);
            saveAll(); refresh();
          });
        });
      }
      wireIssue();
      // Auto-compute amount when % changes
      modal.querySelector('#msPct')?.addEventListener('input', (e) => {
        const pct = parseFloat(e.target.value) || 0;
        const amtEl = modal.querySelector('#msAmount');
        if (amtEl && order.price) amtEl.value = fmtMoney(+order.price * pct / 100);
      });
      modal.querySelector('#btnAddMilestone').addEventListener('click', () => {
        const label = modal.querySelector('#msLabel').value.trim() || 'Milestone';
        const pct = parseFloat(modal.querySelector('#msPct').value) || 0;
        const amount = parseFloat(modal.querySelector('#msAmount').value) || 0;
        const due = modal.querySelector('#msDue').value;
        const row = { id: uid('MS'), label, percentage: pct, amount, issuedAt: null };
        if (/^\d{4}-\d{2}-\d{2}$/.test(due)) row.dueDate = due;
        order.milestoneInvoices.push(row);
        saveAll(); refresh();
        modal.querySelector('#msDue').value = '';
        modal.querySelector('#msLabel').value = '';
        modal.querySelector('#msPct').value = '';
        modal.querySelector('#msAmount').value = '';
      });
    }
  });
}

/* ============================================================
   Work Order — internal shop-floor sheet (no pricing shown)
   ============================================================ */
function generateWorkOrder(id) {
  const order = printLog.find(o => o.id === id);
  if (!order) return;
  const area = $('#work-order-print-area');
  const isAr = i18n.current === 'ar';
  const dir  = isAr ? 'rtl' : 'ltr';
  // The work order is a customer-facing-adjacent document printed for the shop
  // floor, and it was bilingual unconditionally like the rest. Same rule, same
  // resolver — see renderInvoice() in renderer/invoicing.js.
  const _dl = KhaytInvoiceLanguage.resolveDocumentLanguage({
    mode: settings.invoiceBilingual, lang: i18n.current,
    secondary: settings.invoiceSecondLang, enableZatca: settings.enableZatca,
  });
  const bi = _dl.bilingual;
  // shopField() already resolves the shop's own content languages, so both
  // branches of the ternary this replaced were the same expression.
  const bizPrimary = shopField('biz');
  const today = localDateStr();
  const linkedClient = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const clientName = (order.project || '').trim() || (linkedClient ? localName(linkedClient) : t('inv.walk_in'));
  const lines = (order.parts && order.parts.length > 0) ? order.parts
    : [{ name: order.project || order.id, qty: 1, material: '', weight: '', printTime: order.printTime || 0 }];
  const machine = order.machineId ? machines.find(m => m.id === order.machineId) : null;
  const customDataHtml = (settings.customFields || []).length > 0 && order.customData
    ? (settings.customFields || []).map(f => {
        const val = (order.customData || {})[f.id] || '';
        return val ? `<div class="meta-row"><span class="k">${escapeHtml(f.label)}</span><span class="v">${escapeHtml(val)}</span></div>` : '';
      }).join('')
    : '';

  area.innerHTML = `
    <div class="inv-wrap wo-wrap">
    <div class="inv-top-bar" style="background:#374151;"></div>
    <div class="inv" dir="${dir}" lang="${i18n.current}" style="--brand:#1f2937; --accent:#374151; --highlight:#f3f4f6;">
      <div class="inv-header">
        <div class="biz">
          <div class="mark">${safeBizLogo() ? `<img src="${safeBizLogo()}" style="max-height:50px; max-width:100px; object-fit:contain;" alt="logo">` : BRAND_MARK_SVG}</div>
          <div class="biz-name"><h1>${escapeHtml(bizPrimary || 'Khayt')}</h1></div>
        </div>
        <div class="doc">
          <div class="title">${escapeHtml(t("doc.work_order"))}</div>
          ${bi ? `<div class="title-ar ${isAr ? 'ltr' : 'ar'}">${escapeHtml(i18n.tIn(_dl.secondary, "doc.work_order"))}</div>` : ''}
          <div class="meta">
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.wo_no"))}</span><span class="v">WO-${escapeHtml(order.id)}</span></div>
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.date"))}</span><span class="v">${escapeHtml(formatPrintDate(today))}</span></div>
            <div class="meta-row"><span class="k">${escapeHtml(t("doc.due"))}</span><span class="v">${order.dueDate ? escapeHtml(formatPrintDate(order.dueDate)) : '—'}</span></div>
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
        const docs = KhaytProductDocs.docsForOrder(order, typeof products !== "undefined" ? products : []);
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

  setTimeout(() => window.print(), 80);
}
(function (global) {
  const api = {
    maybeAutoBackup,
    updateLastBackupDisplay,
    exportAllCsv,
    exportQuoteApprovalPage,
    openMilestoneInvoices,
    generateWorkOrder,
  };
  Object.assign(global, api);
  global.KhaytAppExports = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
