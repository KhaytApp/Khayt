/**
 * Orders log tab: filtering, table render, batch actions, CSV export.
 */
(function (global) {
// Net revenue base for margin display/sort: strip shipping and VAT so margin is
// not overstated. Kept in the order's own currency to stay consistent with the
// parts cost (baseCost). VAT is extracted with the same rate/(100+rate) formula
// used in invoicing/expenses/analytics.
function orderNetRevenue(o) {
  // Credit notes (refunds) reduce the sale before shipping and VAT come out,
  // otherwise a refunded order still shows its full original margin.
  const credited = (typeof orderCreditedRaw === 'function') ? orderCreditedRaw(o) : 0;
  const gross = (+o.price || 0) - (+o.shippingCost || 0) - credited;
  if (gross <= 0) return 0;
  // Net of tax, whichever way the shop prices. The old line divided the tax back
  // out unconditionally, which is only right when the price INCLUDES tax — the
  // single assumption Khayt used to be built on. For a shop pricing tax-exclusive
  // (the US and Canadian norm) `o.price` is already the net figure, and dividing
  // it again understated revenue on every screen that reads this.
  //
  // computeTax().subtotal is correct in both modes without a branch: exclusive
  // returns the amount untouched, inclusive divides the tax out.
  return KhaytTax.computeTax(gross, KhaytTax.profileFromSettings(settings)).subtotal;
}

function getFilteredLogs() {
  const filtered = printLog.filter(log => {
    if (!showArchivedOrders && log.archived) return false;
    if (logStatusFilter && log.status !== logStatusFilter) return false;
    if (logPayFilter    && payStatus(log) !== logPayFilter) return false;
    if (!inRange(log.date, logRangeFilter, 'log')) return false;
    if (logTagFilter && !(log.tags || []).includes(logTagFilter)) return false;
    if (logClientFilter && log.clientId !== logClientFilter) return false;
    if (logOperatorFilter && log.operatorId !== logOperatorFilter) return false;
    if (typeof orderMatchesActiveLocation === 'function' && !orderMatchesActiveLocation(log)) return false;
    if (logSearchTerm) {
      const cl = log.clientId ? clientById(log.clientId) : null;
      const hay = [log.project, log.client, cl?.nameEn, cl?.nameAr, log.id, log.material, ...(log.tags || [])].join(' ').toLowerCase();
      if (!hay.includes(logSearchTerm.toLowerCase())) return false;
    }
    return true;
  });
  const dir = logSortDir === 'asc' ? 1 : -1;
  return filtered.sort((a, b) => {
    if (logSortCol === 'date')     return dir * (a.date || '').localeCompare(b.date || '');
    if (logSortCol === 'project')  return dir * (a.project || '').localeCompare(b.project || '');
    if (logSortCol === 'price')    return dir * ((+a.price || 0) - (+b.price || 0));
    if (logSortCol === 'material') return dir * (a.material || '').localeCompare(b.material || '');
    if (logSortCol === 'status')   return dir * (a.status || '').localeCompare(b.status || '');
    if (logSortCol === 'margin') {
      const costA = (a.parts || []).reduce((s, p) => s + (+p.baseCost || 0), 0);
      const costB = (b.parts || []).reduce((s, p) => s + (+p.baseCost || 0), 0);
      const revA = orderNetRevenue(a);
      const revB = orderNetRevenue(b);
      const mA = costA > 0 && revA > 0 ? (revA - costA) / revA : -Infinity;
      const mB = costB > 0 && revB > 0 ? (revB - costB) / revB : -Infinity;
      return dir * (mA - mB);
    }
    return 0;
  });
}

function clearLogFilters() {
  logSearchTerm   = '';
  logStatusFilter = '';
  logPayFilter    = '';
  logTagFilter    = '';
  logOperatorFilter = '';
  logClientFilter = '';
  logRangeFilter  = 'all';
  const sr = $('#logSearch');         if (sr)  sr.value  = '';
  const sf = $('#logStatusFilter');   if (sf)  sf.value  = '';
  const pf = $('#logPayFilter');      if (pf)  pf.value  = '';
  const tf = $('#logTagFilter');      if (tf)  tf.value  = '';
  const of = $('#logOperatorFilter'); if (of)  of.value  = '';
  const cf = $('#logClientFilter');   if (cf)  cf.value  = '';
  const rf = $('#logRangeFilter');    if (rf)  rf.value  = 'all';
  renderLogs();
}

/**
 * Warn about deposits erased by the instalment-save defect (#500), and offer to
 * put them back.
 *
 * Before that fix, saving an order that had instalments assigned instPaid over
 * paidAmount — and the plan generator builds schedules with depositAmount:0
 * spanning the full price, so a freshly generated plan had instPaid = 0. A 500
 * deposit became 0, the order moved to 'unpaid', and receivables rose by 500
 * with nothing on screen to say so.
 *
 * The money is recoverable: createOrder writes a separate `depositAmount` the
 * defect never touched. This banner names each affected order with the figure
 * that will be restored. It does not repair silently — paidAmount drives
 * receivables, payment status and the payment webhooks, so the shop sees the
 * change before it happens.
 */
function renderDepositAuditBanner() {
  const el = $('#depositAuditBanner');
  if (!el) return;
  const A = window.KhaytDepositAudit;
  if (!A) { el.innerHTML = ''; return; }
  const hits = A.findErasedDeposits(printLog);
  if (!hits.length) { el.innerHTML = ''; return; }

  const cur = (typeof currencySymbol === 'function') ? currencySymbol() : '';
  const money = (n) => `${(typeof fmtMoney === 'function' ? fmtMoney(n) : Math.round(n))}${cur ? ' ' + cur : ''}`;
  const rows = hits.map((e) => `
    <div class="dep-audit-row">
      <span class="dep-audit-name">${escapeHtml(e.order.project || e.order.id)}</span>
      <span class="dep-audit-gap">${escapeHtml(money(e.currentPaid))}</span>
      <span class="dep-audit-arrow" aria-hidden="true">→</span>
      <span class="dep-audit-fixed">${escapeHtml(money(e.recovered))}</span>
      <button type="button" class="btn small" data-act="dep-restore" data-id="${escapeHtml(e.order.id)}">${escapeHtml(t('dep.restore_btn') || 'Restore')}</button>
    </div>`).join('');

  el.innerHTML = `
    <div class="dep-audit">
      <p class="dep-audit-head">
        <strong>${escapeHtml(t('dep.head') || 'Some deposits were lost by an earlier bug.')}</strong>
        ${escapeHtml((t('dep.body') || 'Saving an order with a payment plan used to erase the deposit recorded against it, so these orders show less paid than they should and their outstanding balance is too high. The original figures were recovered from your data — nothing has been changed yet.')
          + ' ' + (t('dep.total') || 'Unaccounted so far: {n}.').replace('{n}', money(A.totalLost(hits))))}
      </p>
      ${rows}
    </div>`;
}

/**
 * Clients that appear on at least one order, for the log's client filter.
 *
 * Was `clients.filter(c => printLog.some(o => o.clientId === c.id))` — a scan of
 * every order for every client, rebuilt on each render, and renderLogs() has 64
 * call sites. That is O(clients x orders): measured at 15 ms for 2,000 clients
 * over 20k orders and 100 ms at 5,000 over 50k, against 4 ms here. The shape
 * matters more than today's numbers — it degrades quadratically, so it gets
 * worse exactly as a shop's history becomes more valuable.
 *
 * Order is preserved (it drives a dropdown a human reads), and the id set is
 * built once. test/logs-client-filter.test.js pins both the result and the
 * complexity, by counting property reads rather than timing anything.
 */
function clientsWithAnyOrder(clients, printLog) {
  const withOrders = new Set();
  for (const o of (printLog || [])) {
    if (o && o.clientId != null) withOrders.add(o.clientId);
  }
  return (clients || []).filter((c) => c && withOrders.has(c.id));
}

function renderLogs() {
  renderDepositAuditBanner();
  const tbody = $('#logTable tbody');
  // Repopulate tag filter dropdown with all existing tags
  const tagSel = $('#logTagFilter');
  if (tagSel) {
    const allTags = getAllTags();
    const curTag = tagSel.value;
    tagSel.innerHTML = `<option value="">${escapeHtml(t('tag.all'))}</option>` +
      allTags.map(tg => `<option value="${escapeHtml(tg)}"${tg === curTag ? ' selected' : ''}>${escapeHtml(tg)}</option>`).join('');
  }
  // Client filter dropdown — only show clients that have orders
  const clientSel = $('#logClientFilter');
  if (clientSel) {
    const clientsWithOrders = clientsWithAnyOrder(clients, printLog);
    clientSel.innerHTML = `<option value="">${escapeHtml(t('log.all_clients') || 'All clients')}</option>` +
      clientsWithOrders.map(c => `<option value="${escapeHtml(c.id)}"${c.id === logClientFilter ? ' selected' : ''}>${escapeHtml(localName(c))}</option>`).join('');
  }
  // QW6: Operator filter dropdown
  const operatorSel = $('#logOperatorFilter');
  if (operatorSel) {
    operatorSel.innerHTML = `<option value="">${escapeHtml(t('log.all_operators') || 'All operators')}</option>` +
      operators.map(op => `<option value="${escapeHtml(op.id)}"${op.id === logOperatorFilter ? ' selected' : ''}>${escapeHtml(op.name)}</option>`).join('');
  }
  // QW1: Update sort indicators on headers
  $$('#logTable thead th[data-sort]').forEach(th => {
    const col = th.dataset.sort;
    const arrow = logSortCol === col ? (logSortDir === 'asc' ? ' ▲' : ' ▼') : '';
    th.querySelectorAll('.sort-arrow').forEach(el => el.remove());
    if (arrow) {
      const span = document.createElement('span');
      span.className = 'sort-arrow';
      span.textContent = arrow;
      span.style.cssText = 'font-size:10px;color:var(--primary);';
      th.appendChild(span);
    }
  });
  renderKitStrip();
  const filtered = getFilteredLogs();

  // Reset display limit when any filter or sort criterion changes
  const filterHash = [logSearchTerm, logStatusFilter, logPayFilter, logTagFilter,
    logClientFilter, logOperatorFilter, logRangeFilter, logSortCol, logSortDir].join('\x00');
  if (filterHash !== _lastLogFilterHash) {
    logDisplayLimit = 100;
    _lastLogFilterHash = filterHash;
  }

  if (printLog.length === 0) {
    tbody.innerHTML = `<tr><td colspan="9" class="empty-state">${escapeHtml(t('log.empty'))} <button class="btn small primary" data-act="new-order" style="margin-inline-start:12px;">${escapeHtml(t('common.new_order') || 'New Order')}</button></td></tr>`;
    return;
  }
  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="9" class="empty-state">${escapeHtml(t('log.empty_search'))} <button type="button" class="btn small ghost" style="margin-inline-start:10px;" data-act="clear-log-filters">${escapeHtml(t('log.clear_filters') || 'Clear filters')}</button></td></tr>`;
    return;
  }
  const page = filtered.slice(0, logDisplayLimit);
  tbody.innerHTML = page.map(log => {
    const ps = payStatus(log);
    const isPaid = ps === 'paid';
    const photoCount = (log.printPhotos || []).length;
    const fileCount  = (log.attachedFiles || []).length;
    const isOverdue = log.dueDate && !KhaytOrderStatus.isFinished(log) && new Date(log.dueDate + 'T00:00:00') < new Date(new Date().setHours(0,0,0,0));
    const isSel = selectedOrders.has(log.id);
    const logOperator = log.operatorId ? operators.find(o => o.id === log.operatorId) : null;
    const logSplitBadge = log.splitInto && log.splitInto.length > 0 ? `<span class="split-badge">🔀 ${escapeHtml(t('ord.split_badge', { n: log.splitInto.length }))}</span>` : '';
    const logSubBadge = log.parentOrderId ? `<span class="sub-order-badge">↳ ${escapeHtml(t('ord.sub_order'))} #${escapeHtml(log.parentOrderId)}</span>` : '';
    const kitOf = log.kitId ? (settings.kits || []).find((k) => k.id === log.kitId) : null;
    // Shown even when the definition is gone, so a job never looks unfiled when
    // it is not — matching groupByKit()'s own orphan handling.
    const logKitBadge = log.kitId
      ? `<span class="split-badge" title="${escapeHtml(t('kit.badge_title') || 'Part of a kit')}">🧩 ${escapeHtml(kitOf ? kitOf.name : (t('kit.orphaned') || 'kit deleted'))}</span>`
      : '';
    // Profit margin estimation
    const partsCost = (log.parts || []).reduce((s, p) => s + (+p.baseCost || 0), 0);
    const netRevenue = orderNetRevenue(log);
    const hasMarginData = partsCost > 0 && netRevenue > 0;
    const marginPct = hasMarginData ? ((netRevenue - partsCost) / netRevenue * 100) : null;
    const marginHtml = marginPct !== null
      ? `<span style="font-size:11px;font-weight:600;padding:2px 6px;border-radius:10px;background:${marginPct >= 40 ? 'rgba(34,197,94,0.15)' : marginPct >= 20 ? 'rgba(245,158,11,0.15)' : 'rgba(239,68,68,0.15)'};color:${marginPct >= 40 ? 'var(--success)' : marginPct >= 20 ? 'var(--warning)' : 'var(--danger)'};">${marginPct.toFixed(0)}%</span>`
      : `<span style="color:var(--text-muted);font-size:11px;">—</span>`;
    return `
    <tr${isOverdue ? ' class="row-overdue"' : ''}${isSel ? ' style="background:rgba(91,156,240,0.07);"' : ''}>
      <td style="width:32px;padding:8px 6px;"><input type="checkbox" class="log-sel" data-id="${log.id}" style="width:auto;" ${isSel ? 'checked' : ''}></td>
      <td style="font-family: var(--font-num); font-size: 12px; color: var(--text-dim); white-space:nowrap;">${escapeHtml(log.date)}</td>
      <td>
        ${getPriorityLevel(log) !== 'normal' ? priorityBadgeHtml(log) + ' ' : ''}<strong>${escapeHtml(log.project)}</strong>${log.dueDate && !KhaytOrderStatus.isFinished(log) ? ' ' + formatDueDateBadge(log.dueDate) : ''}${logSplitBadge}${logSubBadge}${logKitBadge}
        ${logOperator ? `<span class="operator-badge">👤 ${escapeHtml(logOperator.name)}</span>` : ''}
        ${(log.tags && log.tags.length > 0) ? `<div style="margin-top:3px;">${renderTagChips(log.tags, true)}</div>` : ''}
        <div style="font-family: var(--font-num); font-size: 11.5px; color: var(--text-muted);">${escapeHtml(log.id)}${photoCount ? ` · ${photoCount}📷` : ''}${fileCount ? ` · ${fileCount}📎` : ''}${log.notes ? ' · 📝' : ''}</div>
      </td>
      <td>
        <span class="badge ${escapeHtml(log.status)}">${escapeHtml(t('queue.' + log.status))}</span>${log.deliveredAt ? ` <span style="font-size:10px; color:var(--success);">✓ ${escapeHtml(t('queue.delivered'))}</span>` : ''}
        ${KhaytOrderStatus.isFinished(log) && log.completedAt ? `<div style="font-size:10.5px; color:var(--text-muted); margin-top:2px;">✓ ${escapeHtml(t('ord.completed_at'))}: ${escapeHtml(new Date(log.completedAt).toLocaleDateString(localeTag()))}</div>` : ''}
        ${log.qcPassedAt ? `<div style="margin-top:2px;"><span class="qc-badge">✅ ${escapeHtml(t('ord.qc_passed'))}</span>${log.qcNotes ? `<span style="font-size:11px;color:var(--text-muted);margin-inline-start:5px;">${escapeHtml(log.qcNotes)}</span>` : ''}</div>` : ''}
        ${(log.milestoneInvoices && log.milestoneInvoices.length > 0) ? `<div style="margin-top:2px;font-size:10.5px;color:var(--primary);">📄 ${log.milestoneInvoices.length} ${escapeHtml(t('ord.milestone_invoices'))}</div>` : ''}
        ${(() => {
          // Feature 2: Actual duration badge
          if (log.printingStartedAt && log.completedAt) {
            const ms = new Date(log.completedAt) - new Date(log.printingStartedAt);
            if (ms > 0) {
              const totalMins = Math.round(ms / 60000);
              const h = Math.floor(totalMins / 60), m = totalMins % 60;
              return `<div style="font-size:10.5px; color:var(--primary); margin-top:1px;">⏱ ${escapeHtml(t('ord.actual_duration', { h, m }))}</div>`;
            }
          }
          return '';
        })()}
        ${(() => {
          // Feature 4: Instalment due badge
          if (!log.instalments) return '';
          const sevenDaysFromNow = todayPlusDays(7);
          const hasDue = log.instalments.some(ins => !ins.paidAt && ins.dueDate && ins.dueDate <= sevenDaysFromNow);
          return hasDue ? `<span style="font-size:10px; background:var(--primary); color:#fff; padding:1px 5px; border-radius:3px; margin-top:2px; display:inline-block;">💳 ${escapeHtml(t('ord.inst_badge'))}</span>` : '';
        })()}
      </td>
      <td>${paymentBadge(log)}</td>
      <td style="font-size: 12.5px; color: var(--text-dim);">${escapeHtml(log.material)}</td>
      <td style="color: var(--success); font-weight: 600; font-variant-numeric: tabular-nums; white-space:nowrap;">${fmtPrice(log.price)}</td>
      <td style="text-align:center;">${marginHtml}</td>
      <td class="log-actions-td">
        <div class="row-actions-wrap">
          <!-- ── Primary actions (always visible) ── -->
          <button class="btn small primary" data-act="edit-log" data-id="${log.id}" title="${escapeHtml(t('common.edit'))}">${escapeHtml(t('common.edit'))}</button>
          <button class="btn small ${isPaid ? 'success' : 'primary'}" data-act="${isPaid ? 'unpay' : 'pay'}" data-id="${log.id}" title="${escapeHtml(isPaid ? t('pay.mark_unpaid') : t('pay.mark_paid'))}">${isPaid ? '✓' : '💳'}</button>
          <button class="btn small" data-act="invoice" data-id="${log.id}" title="${escapeHtml(t('inv.print'))}">${escapeHtml(t('inv.print'))}</button>
          <button class="btn small ghost" data-act="inv-pdf" data-id="${log.id}" title="${escapeHtml(t('inv.save_pdf'))}">PDF</button>
          <!-- ⋯ dropdown trigger -->
          <button class="btn small ghost row-more-btn" data-id="${log.id}" title="${escapeHtml(t('common.more') || 'More actions')}" aria-haspopup="true" aria-expanded="false" aria-label="${escapeHtml(t('common.more') || 'More actions')}"><span aria-hidden="true">⋯</span></button>
          <!-- ── Dropdown menu ── -->
          <div class="row-actions-menu" data-for="${log.id}">
            <!-- Documents -->
            <div class="menu-label">${escapeHtml(t('menu.documents') || 'Documents')}</div>
            <button class="menu-item" data-act="inv-wa"  data-id="${log.id}">📱 ${escapeHtml(t('inv.share_whatsapp'))}</button>
            <button class="menu-item" data-act="dn-log"  data-id="${log.id}">📋 ${escapeHtml(t('dn.print'))}</button>
            <button class="menu-item pro-only" data-act="cn-log" data-id="${log.id}">↩️ ${escapeHtml(t('cn.title'))}</button>
            <button class="menu-item" data-act="wo-log"  data-id="${log.id}">🔧 ${escapeHtml(t('wo.title'))}</button>
            ${(log.status === 'pending' || log.status === 'printing') && log.clientId && (+log.price || 0) > 0 ? `<button class="menu-item pro-only" data-act="gen-proforma" data-id="${log.id}">📄 ${escapeHtml(t('ord.gen_proforma'))}</button>` : ''}
            <button class="menu-item pro-only" data-act="milestone-invoices" data-id="${log.id}">📋 ${escapeHtml(t('ord.milestone_invoices'))}</button>
            ${!log.voidedAt ? `<button class="menu-item pro-only" data-act="void-invoice" data-id="${log.id}">🚫 ${escapeHtml(t('inv.void_btn'))}</button>` : `<span class="menu-item" style="color:var(--danger);cursor:default;">🚫 ${escapeHtml(t('inv.already_voided'))}</span>`}
            ${(() => { const cl = log.clientId ? clientById(log.clientId) : null; return cl?.email ? `<button class="menu-item" data-act="${log.status === 'quote' ? 'email-quote' : 'email-invoice'}" data-id="${log.id}">✉️ ${escapeHtml(t(log.status === 'quote' ? 'ord.email_quote' : 'ord.email_invoice'))}</button>` : ''; })()}
            ${(() => {
              if (typeof zatcaPhase2Ready !== 'function' || !zatcaPhase2Ready()) return '';
              if (log.status !== 'completed' && log.status !== 'delivered') return '';
              if (log.voidedAt) return '';
              const lbl = log.zatcaSubmission?.status === 'accepted' ? (t('zatca2.resubmit') || 'Retry ZATCA') : (t('zatca2.submit') || 'Submit to ZATCA');
              return `<button class="menu-item pro-only" data-act="zatca-submit" data-id="${log.id}">🇸🇦 ${escapeHtml(lbl)}</button>`;
            })()}
            <div class="menu-sep"></div>
            <!-- Tracking & sharing -->
            <div class="menu-label">${escapeHtml(t('menu.tracking') || 'Tracking')}</div>
            <button class="menu-item" data-act="export-status-page"  data-id="${log.id}">📄 ${escapeHtml(t('ord.status_page'))}</button>
            <button class="menu-item" data-act="portal-qr"           data-id="${log.id}">📱 ${escapeHtml(t('ord.portal_qr_title') || 'Portal QR')}</button>
            <button class="menu-item" data-act="copy-tracking-url"   data-id="${log.id}">🔗 ${escapeHtml(t('ord.copy_tracking_url') || 'Copy tracking URL')}</button>
            <button class="menu-item" data-act="portal-messages"     data-id="${log.id}">💬 ${escapeHtml(t('pm.menu') || 'Portal messages')}</button>
            <button class="menu-item" data-act="ai-reply"            data-id="${log.id}">✨ ${escapeHtml(t('ai.reply_menu') || 'Draft message (AI)')}</button>
            ${log.clientId ? `<button class="menu-item" data-act="open-status-page" data-id="${log.id}">🔗 ${escapeHtml(t('ord.status_page_open'))}</button>` : ''}
            ${log.trackingNumber ? `<button class="menu-item" data-act="share-tracking" data-id="${log.id}">📦 ${escapeHtml(t('ship.tracking_share'))}</button>` : ''}
            <div class="menu-sep"></div>
            <!-- Operations -->
            <div class="menu-label">${escapeHtml(t('menu.operations') || 'Operations')}</div>
            <button class="menu-item" data-act="dup-log"       data-id="${log.id}">⊕ ${escapeHtml(t('oe.duplicate'))}</button>
            <button class="menu-item" data-act="log-time"      data-id="${log.id}">⏱ ${escapeHtml(t('time.log_title') || 'Log time')}</button>
            <button class="menu-item" data-act="order-timeline" data-id="${log.id}">🕐 ${escapeHtml(t('ord.timeline'))}</button>
            ${(log.parts || []).length > 1 && log.status !== 'split' ? `<button class="menu-item pro-only" data-act="split-order" data-id="${log.id}">⚡ ${escapeHtml(t('ord.split'))}</button>` : ''}
            ${!KhaytOrderStatus.isFinished(log) && (log.parts || []).length > 1 ? `<button class="menu-item" data-act="partial-delivery" data-id="${log.id}">📦 ${escapeHtml(t('ord.partial_delivery'))}</button>` : ''}
            ${!KhaytOrderStatus.isFinished(log) && (log.parts || []).some(p => p.spoolId) ? `<button class="menu-item" data-act="log-spool-switch" data-id="${log.id}">🔄 ${escapeHtml(t('ord.spool_switch'))}</button>` : ''}
            <button class="menu-item" data-act="change-order"  data-id="${log.id}">🔀 ${escapeHtml(t('ord.change_order') || 'Change Order')}</button>
            ${!isPaid ? `<button class="menu-item" data-act="pay-remind" data-id="${log.id}">💰 ${escapeHtml(t('pay.remind_btn'))}</button>` : ''}
            <div class="menu-sep"></div>
            <!-- Print & labels -->
            <div class="menu-label">${escapeHtml(t('menu.print_label') || 'Print & labels')}</div>
            <button class="menu-item" data-act="reprint-log"   data-id="${log.id}">🖨 ${escapeHtml(t('oe.reprint'))}</button>
            ${(log.status === 'completed' || log.status === 'delivered') ? `<button class="menu-item" data-act="ship-order" data-id="${log.id}">📦 ${escapeHtml(log.shippingStatus ? (t('ship.st.' + log.shippingStatus) || t('ship.manage_title') || 'Shipment') : (t('ship.ship') || 'Ship'))}</button>` : ''}
            ${log.status === 'delivered' ? `<button class="menu-item" data-act="rma-log" data-id="${log.id}">🛡 ${escapeHtml(t('qc.rma_title') || 'Open RMA')}${log.rma ? ' ✓' : ''}</button>` : ''}
            <button class="menu-item" data-act="print-label"   data-id="${log.id}">🏷 ${escapeHtml(t('ord.label_btn') || 'Print Label')}</button>
            <button class="menu-item" data-act="packing-slip"  data-id="${log.id}">🗒 ${escapeHtml(t('ps.title') || 'Packing Slip')}</button>
            ${expenses.some(e => e.orderId === log.id) ? `<button class="menu-item" data-act="linked-expenses" data-id="${log.id}">💰 ${escapeHtml(t('exp.linked_expenses'))}</button>` : ''}
            <!-- Quotes (shown only for quote status) -->
            ${log.status === 'quote' ? `<div class="menu-sep"></div><div class="menu-label">${escapeHtml(t('menu.quote') || 'Quote')}</div>` : ''}
            ${log.status === 'quote' ? `<button class="menu-item" data-act="quote-approval-link" data-id="${log.id}">🔗 ${escapeHtml(t('ord.quote_approval_link'))}</button>` : ''}
            ${log.status === 'quote' && log.clientId ? `<button class="menu-item" data-act="export-quote-approval" data-id="${log.id}">📋 ${escapeHtml(t('ord.quote_approval_page'))}</button>` : ''}
            ${log.status === 'quote' ? `<button class="menu-item" data-act="revise-quote" data-id="${log.id}">📝 ${escapeHtml(t('ord.revise_quote'))}</button>` : ''}
            ${log.status === 'quote' && (log.quoteRevisions || []).length > 0 ? `<button class="menu-item" data-act="quote-revisions" data-id="${log.id}">🕐 ${escapeHtml(t('ord.quote_revisions'))} v${log.quoteVersion || 1}</button>` : ''}
            <!-- Engagement -->
            ${KhaytOrderStatus.isFinished(log) ? `<div class="menu-sep"></div><div class="menu-label">${escapeHtml(t('menu.engagement') || 'Engagement')}</div>` : ''}
            ${KhaytOrderStatus.isFinished(log) ? `<button class="menu-item" data-act="gen-survey" data-id="${log.id}">📊 ${escapeHtml(t('ord.gen_survey') || 'Generate survey')}</button>` : ''}
            ${KhaytOrderStatus.isFinished(log) && !log.survey?.rating ? `<button class="menu-item" data-act="record-survey" data-id="${log.id}">⭐ ${escapeHtml(t('ord.record_survey') || 'Record rating')}</button>` : ''}
            ${log.survey?.rating ? `<span class="menu-item" style="cursor:default;">⭐ ${escapeHtml(t('ord.survey_rating') || 'Rating')}: ${log.survey.rating}/5</span>` : ''}
            <!-- History & admin -->
            <div class="menu-sep"></div>
            <div class="menu-label">${escapeHtml(t('menu.admin') || 'Admin')}</div>
            ${(log.editHistory && log.editHistory.length > 0) ? `<button class="menu-item" data-act="view-edit-history" data-id="${log.id}">📝 ${escapeHtml(t('ord.edit_history'))}</button>` : ''}
            <button class="menu-item" data-act="${log.archived ? 'unarchive-log' : 'archive-log'}" data-id="${log.id}">📦 ${escapeHtml(log.archived ? (t('ord.unarchive') || 'Unarchive') : (t('ord.archive') || 'Archive'))}</button>
            <button class="menu-item danger" data-act="del-log" data-id="${log.id}">🗑 ${escapeHtml(t('common.delete'))}</button>
          </div><!-- /.row-actions-menu -->
        </div><!-- /.row-actions-wrap -->
      </td>
    </tr>`;
  }).join('');
  if (filtered.length > logDisplayLimit) {
    tbody.innerHTML += `<tr><td colspan="9" style="text-align:center;padding:12px;">
      <button class="btn small ghost" data-act="load-more-logs">
        ${escapeHtml(t('log.load_more') || 'Load more')} (${filtered.length - logDisplayLimit} ${escapeHtml(t('log.remaining') || 'remaining')})
      </button>
    </td></tr>`;
  }
  updateNotifBadge();
}

/* ============================================================
   Batch order actions (logs tab)
   ============================================================ */
function renderBatchBar() {
  const bar = $('#batchBar');
  if (!bar) return;
  const count = selectedOrders.size;
  if (count === 0) {
    bar.style.display = 'none';
    const selAll = $('#logSelectAll');
    if (selAll) selAll.checked = false;
  } else {
    bar.style.display = 'flex';
    const countEl = $('#batchCount');
    if (countEl) countEl.textContent = t('batch.selected', { n: count });
    const machSel = $('#batchMachineSelect');
    if (machSel) {
      const prev = machSel.value;
      machSel.innerHTML = `<option value="">${escapeHtml(t('batch.assign_machine_ph') || '— Assign machine —')}</option>` +
        machines.map(m => `<option value="${m.id}"${m.id === prev ? ' selected' : ''}>${escapeHtml(m.name)}</option>`).join('');
    }
    // Kits the shop already has, offered rather than retyped.
    //
    // This is the case kits are FOR: three parts filed last week, the fourth
    // printed today. Asking for the name again is asking the shop to reproduce a
    // string from memory, and a near miss does not fail — it quietly mints a
    // second kit and splits the rollup between them.
    //
    // Any kit is offered, not just an unfinished one: a shop that reprints a
    // cracked leg is adding to a kit it already called done.
    const kitSel = $('#batchKitSelect');
    if (kitSel) {
      const prev = kitSel.value;
      const defs = (settings.kits || []).slice()
        .sort((a, b) => String(a.name || '').localeCompare(String(b.name || '')));
      // Is anything selected already in a kit? Only then is "take it out" a
      // sensible thing to offer.
      const anyFiled = [...selectedOrders].some((id) => {
        const o = printLog.find((x) => x.id === id);
        return !!(o && o.kitId);
      });
      kitSel.innerHTML =
        `<option value="__new">${escapeHtml(t('kit.opt_new') || '— New kit… —')}</option>` +
        defs.map((k) => `<option value="${escapeHtml(k.id)}"${k.id === prev ? ' selected' : ''}>${escapeHtml(k.name)}</option>`).join('') +
        (anyFiled ? `<option value="__none">${escapeHtml(t('kit.opt_remove') || '— Remove from kit —')}</option>` : '');
      if (prev) kitSel.value = prev;
      if (!kitSel.value) kitSel.value = '__new';
    }
  }
}

async function batchExportPDFs() {
  const ids = [...selectedOrders];
  if (ids.length === 0) return;
  for (let i = 0; i < ids.length; i++) {
    toast(t('batch.exporting', { n: i + 1, total: ids.length }), 'info', 1600);
    await exportInvoicePDF(ids[i], { askWhere: false, openAfter: false });
    await new Promise(r => setTimeout(r, 120));
  }
  toast(t('batch.done', { n: ids.length }), 'success');
}

function batchWaSend() {
  const ids = [...selectedOrders];
  if (ids.length === 0) return;
  if (waTemplates.length === 0) { toast(t('wa.no_templates'), 'info'); return; }
  const tplOptions = waTemplates.map((tpl, i) =>
    `<option value="${i}">${escapeHtml(tpl.name)}</option>`).join('');
  const ordersHtml = ids.map(id => {
    const o = printLog.find(x => x.id === id);
    if (!o) return '';
    const client = o.clientId ? clientById(o.clientId) : null;
    const name = client ? (localName(client)) : (o.project || '');
    return `<div style="font-size:12px;color:var(--text-dim);padding:2px 0;">${escapeHtml(o.id)} — ${escapeHtml(name)} — ${fmtPrice(o.price)}</div>`;
  }).join('');
  openFormModal({
    title: `${t('batch.wa_all')} (${ids.length})`,
    saveLabel: t('wa.open_btn'),
    bodyHtml: `
      <label>${escapeHtml(t('wa.template'))}</label>
      <select id="batchWaTplSelect">${tplOptions}</select>
      <div style="margin-top:10px; padding:8px 10px; background:var(--surface-2); border-radius:var(--radius-sm); max-height:110px; overflow-y:auto;">${ordersHtml}</div>
      <p style="font-size:11.5px;color:var(--text-muted);margin:8px 0 0;">${escapeHtml(t('batch.wa_hint'))}</p>`,
    async onSave(modal) {
      const tpl = waTemplates[+modal.querySelector('#batchWaTplSelect').value];
      if (!tpl) return true;
      for (const id of ids) {
        const order = printLog.find(o => o.id === id);
        if (!order) continue;
        const client = order.clientId ? clientById(order.clientId) : null;
        const msg = fillWaTemplate(tpl.body, order, client);
        if (window.hubAPI?.shareWhatsApp) {
          await window.hubAPI.shareWhatsApp({ phone: client?.phone || '', message: msg, pdfPath: null });
          await new Promise(r => setTimeout(r, 250));
        }
      }
      return true;
    }
  });
}

async function batchMoveStatus() {
  const status = $('#batchStatusSelect')?.value;
  if (!status) { toast(t('batch.move_to_hint'), 'info'); return; }
  const ids = [...selectedOrders];
  if (ids.length === 0) return;
  const ok = await confirmModal(
    `Move ${ids.length} order(s) to "${status}"?`,
    { danger: status === 'completed' || status === 'on_hold' }
  );
  if (!ok) return;
  const now = new Date().toISOString();
  for (const id of ids) {
    const o = printLog.find(x => x.id === id);
    if (!o) continue;
    o.status = status;
    if (!o.statusHistory) o.statusHistory = [];
    o.statusHistory.push({ status, at: now });
    if (o.statusHistory.length > 200) o.statusHistory = o.statusHistory.slice(-200);
    if (status === 'completed') {
      if (!o.completedAt) o.completedAt = now;
      deductFilamentForOrder(o, { skipRender: true });
      deductPackagingConsumables(o);
      if (o.clientId) autoExportStatusPage(o);
      autoSendEmailNotification(o, 'completed');
      fireStatusWebhook('status_changed', o, 'completed');
      fireStatusWebhook('order_delivered', o);
      fireOrderWebhook('status', o);
    }
  }
  renderInventory();
  saveAll();
  selectedOrders.clear();
  renderBatchBar();
  renderKanban();
  renderLogs();
  renderDashboard();
  toast(t('batch.moved', { n: ids.length }), 'success');
}

async function batchAssignMachine() {
  const machineId = $('#batchMachineSelect')?.value;
  if (!machineId) { toast(t('batch.assign_machine_ph') || 'Select a machine first', 'info'); return; }
  const machine = machines.find(m => m.id === machineId);
  const ids = [...selectedOrders];
  if (ids.length === 0) return;
  const ok = await confirmModal(
    `${t('batch.assign_confirm') || 'Assign'} ${ids.length} ${t('batch.orders') || 'order(s)'} → ${machine?.name || machineId}?`,
    { danger: false }
  );
  if (!ok) return;
  for (const id of ids) {
    const o = printLog.find(x => x.id === id);
    if (!o) continue;
    o.machineId = machineId;
    o.machine   = machine?.name || machineId;
  }
  saveAll();
  renderKanban(); renderLogs(); renderDashboard();
  toast(`🖨 ${ids.length} ${t('batch.orders') || 'order(s)'} ${t('batch.assigned_to') || 'assigned to'} ${machine?.name || machineId}`, 'success');
}

/**
 * Put the selected orders into a kit — several printed jobs that are one object.
 *
 * The batch bar is the right home for this: a kit is defined by selecting the
 * jobs that make it up, which is exactly what the checkboxes already do.
 *
 * Kits group ACROSS orders rather than merging them, because actuals live on the
 * order and merging would replace four measured numbers with one. See
 * lib/print-kits.js.
 */
async function batchAddToKit() {
  const ids = [...selectedOrders];
  if (ids.length === 0) return;
  if (!Array.isArray(settings.kits)) settings.kits = [];
  const K = (typeof KhaytPrintKits !== 'undefined') ? KhaytPrintKits : null;
  const picked = $('#batchKitSelect')?.value || '__new';

  // Taking jobs back OUT. Grouping after the fact means grouping the wrong
  // things sometimes, and disbanding the whole kit to correct one job was the
  // only way to do it — which is why anyone would rather leave it wrong.
  if (picked === '__none') {
    let moved = 0;
    for (const id of ids) {
      const o = printLog.find((x) => x.id === id);
      if (o && o.kitId) { delete o.kitId; moved++; }
    }
    if (!moved) return;
    // A name attached to nothing is clutter the shop reads past every time it
    // files something. The jobs are what a kit IS; with none left there is
    // nothing to keep.
    if (K) {
      const dead = new Set(K.emptyKitIds(printLog, settings.kits));
      if (dead.size) settings.kits = settings.kits.filter((k) => !dead.has(String(k.id)));
    }
    selectedOrders.clear();
    saveAll();
    renderBatchBar();
    renderLogs();
    toast(`🧩 ${moved} ${t('batch.orders') || 'order(s)'} — ${t('kit.opt_remove') || 'removed from kit'}`, 'success');
    return;
  }

  let kit = picked === '__new' ? null : settings.kits.find((k) => String(k.id) === picked);

  // Naming one is only asked for when there is a new one to name. Adding to a
  // kit that already exists is a pick, not a retype — see renderBatchBar.
  if (!kit) {
    const name = prompt(t('kit.name_prompt') || 'Kit name — these jobs are one object',
      printLog.find((o) => o.id === ids[0])?.project || '');
    const clean = String(name || '').trim();
    if (!clean) return;                       // cancelled, or nothing typed

    // A name one edit away from a kit that already exists is far more often a
    // slip than a second kit, and the cost of being wrong is asymmetric: a
    // wrongly-merged job is one click to pull out again, while a silently split
    // rollup looks correct and is never noticed. Asked, never assumed — "Leg L"
    // and "Leg R" are one edit apart and genuinely different.
    const near = K ? K.similarKitNames(clean, settings.kits) : [];
    if (near.length) {
      const useExisting = confirm(
        (t('kit.near_confirm') || 'A kit called "{name}" already exists. Add these jobs to it instead of creating "{typed}"?')
          .replace('{name}', near[0].name).replace('{typed}', clean));
      if (useExisting) kit = settings.kits.find((k) => String(k.id) === near[0].id) || null;
    }
    if (!kit) {
      const resolved = K
        ? K.resolveKitName(clean, settings.kits, () => 'KIT-' + Math.random().toString(36).slice(2, 11))
        : { id: 'KIT-' + Math.random().toString(36).slice(2, 11), name: clean, created: true };
      kit = settings.kits.find((k) => String(k.id) === resolved.id);
      if (!kit) { kit = { id: resolved.id, name: resolved.name }; settings.kits.push(kit); }
    }
  }

  for (const id of ids) {
    const o = printLog.find((x) => x.id === id);
    if (o) o.kitId = kit.id;
  }
  selectedOrders.clear();
  saveAll();
  renderBatchBar();
  renderLogs();
  toast(`🧩 ${ids.length} ${t('batch.orders') || 'order(s)'} → ${kit.name}`, 'success');
}

/**
 * The kit rollup strip above the log table.
 *
 * Every total is shown with the count of jobs behind it. A build total that
 * silently omits an unmeasured job is the one bug lib/print-kits.js exists to
 * prevent, and hiding the count here would reintroduce it at the last step.
 */
function renderKitStrip() {
  const el = $('#kitStrip');
  if (!el || typeof KhaytPrintKits === 'undefined') return;
  const { kits } = KhaytPrintKits.groupByKit(printLog, settings.kits || []);
  if (!kits.length) { el.style.display = 'none'; el.innerHTML = ''; return; }
  el.style.display = '';
  el.innerHTML = kits.map((k) => {
    const r = k.rollup;
    const acc = k.accuracy;
    // "3 of 4 measured" only when it is not all of them — noise otherwise.
    const partial = r.measuredTime < r.jobs
      ? ` <span style="color:var(--warning);">(${r.measuredTime}/${r.jobs} ${escapeHtml(t('kit.measured') || 'measured')})</span>`
      : '';
    const money = r.mixedCurrency
      ? `<span style="color:var(--warning);">${escapeHtml(t('kit.mixed_currency') || 'mixed currencies')}</span>`
      : `${fmtMoney(r.cost)}`;
    const delta = acc && acc.time !== null
      ? `<span style="color:var(--text-muted);">· ${acc.time > 0 ? '+' : ''}${acc.time}% ${escapeHtml(t('kit.vs_estimate') || 'vs estimate')}</span>`
      : '';
    return `<div class="card" style="padding:8px 11px;margin-bottom:6px;display:flex;align-items:center;gap:10px;flex-wrap:wrap;">
      <strong>🧩 ${escapeHtml(k.name)}</strong>
      ${k.orphaned ? `<span style="font-size:11px;color:var(--warning);">${escapeHtml(t('kit.orphaned') || 'kit deleted')}</span>` : ''}
      <span style="font-size:12px;color:var(--text-dim);">${r.jobs} ${escapeHtml(t('kit.jobs') || 'jobs')}${partial}</span>
      <span style="font-size:12px;font-family:var(--font-num);">${r.actualHours} ${escapeHtml(t('common.hours'))} · ${r.actualGrams} g · ${money}</span>
      ${delta}
      <span style="flex:1;"></span>
      <button class="btn ghost small" data-kit-rename="${escapeHtml(k.id)}">${escapeHtml(t('kit.rename') || 'Rename')}</button>
      <button class="btn ghost small" data-kit-clear="${escapeHtml(k.id)}">${escapeHtml(t('kit.disband') || 'Disband')}</button>
    </div>`;
  }).join('');
}

/**
 * Rename a kit.
 *
 * Also ADOPTS an orphan. A kit whose definition was deleted still groups its
 * jobs (groupByKit keeps orphans on purpose), but there was previously no way
 * back — the jobs were stuck in something unnameable. Naming one writes the
 * definition again.
 *
 * Refuses a name another kit already holds rather than merging into it. Merging
 * would move somebody else's jobs on the strength of a typo, and "reuse the kit
 * with this name" is a rule that belongs to ADDING, where the shop has just
 * chosen which jobs are involved.
 */
async function renameKit(kitId) {
  const kits = Array.isArray(settings.kits) ? settings.kits : [];
  const cur = kits.find((k) => k.id === kitId);
  const name = prompt(t('kit.rename_prompt') || 'Kit name', cur ? cur.name : '');
  const clean = String(name || '').trim();
  if (!clean || (cur && clean === cur.name)) return;
  const clash = kits.find((k) => k.id !== kitId
    && String(k.name).trim().toLowerCase() === clean.toLowerCase());
  if (clash) {
    toast((t('kit.name_taken') || 'Another kit is already called {name}').replace('{name}', clash.name), 'error');
    return;
  }
  if (cur) cur.name = clean;
  else settings.kits = kits.concat([{ id: kitId, name: clean }]);   // adopt the orphan
  saveAll();
  renderLogs();
  toast(t('kit.renamed') || 'Kit renamed', 'success');
}

/** Take every job out of a kit and forget the kit. The jobs are untouched. */
async function disbandKit(kitId) {
  const kit = (settings.kits || []).find((k) => k.id === kitId);
  const ok = await confirmModal(
    (t('kit.disband_confirm') || 'Take these jobs out of {name}? The prints themselves are not touched.')
      .replace('{name}', kit?.name || kitId),
    { danger: false },
  );
  if (!ok) return;
  for (const o of printLog) if (o.kitId === kitId) delete o.kitId;
  settings.kits = (settings.kits || []).filter((k) => k.id !== kitId);
  saveAll();
  renderLogs();
  toast(t('kit.disbanded') || 'Kit disbanded', 'success');
}

async function batchArchiveOrders() {
  const ids = [...selectedOrders];
  if (ids.length === 0) return;
  const ok = await confirmModal(`Archive ${ids.length} order(s)?`, { danger: false });
  if (!ok) return;
  for (const id of ids) {
    const o = printLog.find(x => x.id === id);
    if (o) o.archived = true;
  }
  selectedOrders.clear();
  saveAll();
  renderBatchBar();
  renderLogs();
  toast(`📦 ${ids.length} order(s) archived`, 'success');
}

function exportOrdersCsv() {
  const rows = getFilteredLogs();

  const headers = ['ID', 'Date', 'Client', 'Material', 'Print Time (hrs)', `Price (${currencySymbol()})`, 'Status', 'Payment', 'Paid Amount', 'Due Date', 'Machine', 'Tags', 'Notes'];
  const lines = [
    headers.map(csvEsc).join(','),
    ...rows.map(o => [
      o.id,
      o.date,
      o.project || '',
      o.material || '',
      o.printTime,
      o.price,
      o.status,
      payStatus(o),
      o.paidAmount || 0,
      o.dueDate || '',
      machines.find(m => m.id === o.machineId)?.name || '',
      (o.tags || []).join(', '),
      (o.notes || '').replace(/\n/g, ' ')
    ].map(csvEsc).join(','))
  ];

  downloadBlob(new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' }),
    `orders-${localDateStr()}.csv`);
}
  const api = {
    clientsWithAnyOrder,
    // wire-events.js calls this bare when the shop clicks Restore on a deposit
    // the audit no longer finds — the "the banner is stale, redraw it" path.
    // Private to this IIFE, that was a ReferenceError that killed the click
    // handler instead, leaving the stale row on screen. Same class as the cloud
    // login freeze; test/cross-file-wiring.test.js now covers bare calls.
    renderDepositAuditBanner,
    getFilteredLogs,
    clearLogFilters,
    renderLogs,
    renderBatchBar,
    batchExportPDFs,
    batchWaSend,
    batchMoveStatus,
    batchAssignMachine,
    batchArchiveOrders,
    batchAddToKit,
    renderKitStrip,
    disbandKit,
    renameKit,
    exportOrdersCsv,
  };

  Object.assign(global, api);
  global.KhaytLogs = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
