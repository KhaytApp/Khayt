/**
 * Clients tab, autocomplete, recurring orders, portal export.
 */
let clientSearchTerm = '';
let clientSortCol = 'name';   // 'name' | 'orders' | 'revenue' | 'last' | 'outstanding'
let clientSortDir = 'asc';    // 'asc' | 'desc'
let clientDisplayLimit = 50;  // rows shown before "show more"

(function (global) {
/* ============================================================
   Clients
   ============================================================ */

/**
 * Pure comparator for the clients table. Returns a sort fn for the given
 * column/direction. `rowOf(client)` supplies the precomputed display fields
 * { name, orders, revenue, outstanding, last } so it stays O(1) per compare
 * and is unit-testable without DOM/state.
 */
function clientCompare(col, dir, rowOf) {
  const mul = dir === 'desc' ? -1 : 1;
  return (a, b) => {
    const ra = rowOf(a);
    const rb = rowOf(b);
    let d;
    switch (col) {
      case 'orders':      d = (ra.orders || 0) - (rb.orders || 0); break;
      case 'revenue':     d = (ra.revenue || 0) - (rb.revenue || 0); break;
      case 'outstanding': d = (ra.outstanding || 0) - (rb.outstanding || 0); break;
      case 'last':        d = (ra.last || '').localeCompare(rb.last || ''); break;
      case 'name':
      default:            d = (ra.name || '').localeCompare(rb.name || ''); break;
    }
    if (d !== 0) return mul * d;
    // Stable, direction-independent tiebreak on name so equal primary values
    // always read alphabetically regardless of the chosen sort direction.
    return (ra.name || '').localeCompare(rb.name || '');
  };
}

function getClientStats(clientId) {
  const orders = printLog.filter(o => o.clientId === clientId);
  const completed = orders.filter(o => KhaytOrderStatus.isFinished(o));
  const sorted = [...orders].sort((a, b) => (b.date || '').localeCompare(a.date || ''));
  return {
    count: orders.length,
    completedCount: completed.length,
    revenue: completed.reduce((s, o) => s + orderNetRevenueBase(o), 0),
    lastDate: sorted[0]?.date || null
  };
}

function renderClients() {
  const tbody = $('#clientsTable tbody');
  const term = (clientSearchTerm || '').toLowerCase().trim();
  let filtered = clients;
  if (term) {
    filtered = clients.filter(c =>
      (c.id || '').toLowerCase().includes(term) ||
      (c.nameEn || '').toLowerCase().includes(term) ||
      (c.nameAr || '').toLowerCase().includes(term) ||
      (c.phone || '').toLowerCase().includes(term) ||
      (c.email || '').toLowerCase().includes(term)
    );
  }
  if (clients.length === 0) {
    tbody.innerHTML = `<tr><td colspan="7" class="empty-state">${escapeHtml(t('cl.empty'))}</td></tr>`;
    return;
  }
  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="7" class="empty-state">${escapeHtml(t('cl.empty_search'))}</td></tr>`;
    return;
  }
  // Precompute all per-client aggregates in a single O(n) pass to avoid O(n²) scans
  const clientStatsMap = new Map();
  const clientSurveyMap = new Map();  // clientId -> { sum, count }
  const clientBalanceMap = new Map(); // clientId -> outstanding balance
  for (const o of printLog) {
    if (!o.clientId) continue;
    // Stats (count, revenue, lastDate)
    let s = clientStatsMap.get(o.clientId);
    if (!s) { s = { count: 0, completedCount: 0, revenue: 0, lastDate: null }; clientStatsMap.set(o.clientId, s); }
    s.count++;
    if (KhaytOrderStatus.isFinished(o)) { s.completedCount++; s.revenue += orderNetRevenueBase(o); }
    if (!s.lastDate || o.date > s.lastDate) s.lastDate = o.date;
    // Survey ratings
    if (o.survey?.rating) {
      let sv = clientSurveyMap.get(o.clientId);
      if (!sv) { sv = { sum: 0, count: 0 }; clientSurveyMap.set(o.clientId, sv); }
      sv.sum += o.survey.rating; sv.count++;
    }
    // Outstanding balance (unpaid non-quote orders)
    if (o.status !== 'quote' && payStatus(o) !== 'paid') {
      const outstanding = orderOwedBase(o);
      if (outstanding > 0) clientBalanceMap.set(o.clientId, (clientBalanceMap.get(o.clientId) || 0) + outstanding);
    }
  }
  // Precompute loyalty tiers in one pass (getClientTier itself iterates printLog)
  const clientTierMap = new Map();
  if (settings.loyaltyEnabled) {
    const tiers = (settings.loyaltyTiers || []).filter(tier => tier.name);
    if (tiers.length > 0) {
      const tierSpend  = new Map(); // clientId -> { completedCount, totalSpend }
      for (const o of printLog) {
        if (!o.clientId || o.status !== 'completed') continue;
        let ts = tierSpend.get(o.clientId);
        if (!ts) { ts = { completedCount: 0, totalSpend: 0 }; tierSpend.set(o.clientId, ts); }
        ts.completedCount++; ts.totalSpend += orderNetRevenueBase(o);
      }
      for (const [cid, { completedCount, totalSpend }] of tierSpend) {
        const eligible = tiers.filter(tier =>
          (!tier.minOrders || completedCount >= +tier.minOrders) &&
          (!tier.minSpend  || totalSpend     >= +tier.minSpend)
        );
        if (eligible.length > 0) {
          clientTierMap.set(cid, eligible.sort((a, b) => {
            const d = (+b.minOrders || 0) - (+a.minOrders || 0);
            return d !== 0 ? d : (+b.minSpend || 0) - (+a.minSpend || 0);
          })[0]);
        }
      }
    }
  }


  // Sortable columns — mirror the orders-log pattern. rowOf maps a client to the
  // comparable display fields using the precomputed O(n) aggregates above.
  const rowOf = (c) => {
    const s = clientStatsMap.get(c.id);
    return {
      name: localName(c) || '',
      orders: s ? s.count : 0,
      revenue: s ? s.revenue : 0,
      outstanding: clientBalanceMap.get(c.id) || 0,
      last: (s && s.lastDate) || '',
    };
  };
  filtered = [...filtered].sort(clientCompare(clientSortCol, clientSortDir, rowOf));

  // Reflect sort state in the header arrows
  const thead = document.querySelector('#clientsTable thead');
  if (thead) {
    thead.querySelectorAll('th[data-sort]').forEach(th => {
      th.querySelectorAll('.sort-arrow').forEach(el => el.remove());
      if (th.dataset.sort === clientSortCol) {
        const span = document.createElement('span');
        span.className = 'sort-arrow';
        span.textContent = clientSortDir === 'asc' ? ' ▲' : ' ▼';
        span.style.cssText = 'font-size:10px;color:var(--primary);';
        th.appendChild(span);
      }
    });
  }

  // Display cap with a "show more" footer to keep large client lists snappy
  const totalRows = filtered.length;
  const page = filtered.slice(0, clientDisplayLimit);
  const moreRow = totalRows > clientDisplayLimit
    ? `<tr><td colspan="7" style="text-align:center;padding:12px;">
         <button class="btn small ghost" data-act="cl-show-more">${escapeHtml(t('cl.show_more', { n: totalRows - clientDisplayLimit }))}</button>
       </td></tr>`
    : '';

  tbody.innerHTML = page.map(c => {
    const stats = clientStatsMap.get(c.id) || { count: 0, completedCount: 0, revenue: 0, lastDate: null };
    const displayName = localName(c);
    // The shop's other content language — see altLocalName(). The pair this
    // replaced was blank for any shop not writing English and Arabic.
    const altName     = altLocalName(c);
    const balance = clientBalanceMap.get(c.id) || 0;
    const isOverLimit = (c.creditLimit > 0) && (balance > c.creditLimit);
    // Feature 8 (new 8-pack): Loyalty tier badge
    const tier = clientTierMap.get(c.id) || null;
    const tierHtml = tier ? `<span class="loyalty-tier-badge tier-${escapeHtml(tier.name.toLowerCase().replace(/\s+/g,''))}">${escapeHtml(tier.name)}</span>` : '';
    const loyaltyPts = clientLoyaltyAvailable(c.id);
    const loyaltyHtml = loyaltyPts > 0 ? `<span class="loyalty-tier-badge" title="${escapeHtml(t('loyalty.points') || 'Loyalty points')}">⭐ ${loyaltyPts}</span>` : '';
    // Survey rating from completed orders (pre-computed above)
    const sv = clientSurveyMap.get(c.id);
    const avgRating = sv ? sv.sum / sv.count : null;
    const clientOrdersWithSurveyCount = sv ? sv.count : 0;
    const ratingBadge = avgRating !== null
      ? `<span style="font-size:10px;color:#f59e0b;margin-inline-start:5px;white-space:nowrap;" title="${clientOrdersWithSurveyCount} ${escapeHtml(t('an.survey_responses') || 'survey response(s)')}">⭐ ${avgRating.toFixed(1)}</span>`
      : '';
    const sourceBadge = c.source && c.source !== 'other'
      ? `<span class="source-badge source-${escapeHtml(c.source)}">${escapeHtml(t('cl.source_' + c.source))}</span>`
      : '';
    return `
      <tr>
        <td>
          <div style="display:flex; align-items:center; gap:10px;">
            <span class="avatar">${escapeHtml(initials(displayName))}</span>
            <div>
              <strong>${escapeHtml(displayName || '—')}</strong>${ratingBadge}${sourceBadge}
              ${c.recurring?.enabled ? `<span class="rec-badge">${escapeHtml(t('rec.badge.' + (c.recurring.interval || 'monthly')))}</span>` : ''}
              ${c.currency && c.currency !== (settings.currency || 'SAR') ? `<span class="currency-badge">${escapeHtml(c.currency)}</span>` : ''}
              ${(c.addresses && c.addresses.length > 0) ? `<span style="font-size:10px; color:var(--primary); margin-inline-start:4px;">📍 ${c.addresses.length}</span>` : ''}
              ${isOverLimit ? `<span class="machine-jobs-badge" style="background:var(--danger);color:#fff;font-size:10px;">⚠ ${escapeHtml(t('cl.over_limit'))}</span>` : ''}
              ${tierHtml}
              ${loyaltyHtml}
              ${altName ? `<div style="font-size:11.5px; color:var(--text-muted);">${escapeHtml(altName)}</div>` : ''}
            </div>
          </div>
        </td>
        <td style="font-variant-numeric: tabular-nums;">${escapeHtml(c.phone || '—')}</td>
        <td style="font-variant-numeric: tabular-nums;">${stats.count}</td>
        <td style="font-variant-numeric: tabular-nums; color: var(--success);">${fmtPrice(stats.revenue)}</td>
        <td style="font-variant-numeric: tabular-nums; color: var(--text-dim);">${escapeHtml(stats.lastDate || t('cl.never_ordered'))}</td>
        <td style="font-variant-numeric:tabular-nums;text-align:right;color:${balance > 0 ? 'var(--danger)' : 'var(--text-muted)'};">${balance > 0 ? fmtPrice(balance) : '—'}</td>
        <td>
          <button class="btn small" data-act="cl-history" data-id="${c.id}">${escapeHtml(t('cl.history'))}</button>
          <button class="btn small success" data-act="cl-quote" data-id="${c.id}">${escapeHtml(t('cl.quote'))}</button>
          <button class="btn small" data-act="cl-intake-form" data-id="${c.id}" title="${escapeHtml(t('cl.intake_form'))}" aria-label="${escapeHtml(t('cl.intake_form'))}"><span aria-hidden="true">📋</span></button>
          <button class="btn small" data-act="cl-note" data-id="${c.id}" title="${escapeHtml(t('cl.add_note'))}" aria-label="${escapeHtml(t('cl.add_note'))}"><span aria-hidden="true">💬</span></button>
          <button class="btn small" data-act="cl-edit" data-id="${c.id}">${escapeHtml(t('common.edit'))}</button>
          <button class="btn small" data-act="cl-export-data" data-id="${c.id}" title="${escapeHtml(t('priv.export_data') || "Export this customer's data")}" aria-label="${escapeHtml(t('priv.export_data') || "Export this customer's data")}"><span aria-hidden="true">🗂</span></button>
          <button class="btn danger small" data-act="cl-del" data-id="${c.id}">${escapeHtml(t('common.delete'))}</button>
        </td>
      </tr>`;
  }).join('') + moreRow;
}

function quoteForClient(clientId) {
  const c = clients.find(x => x.id === clientId);
  if (!c) return;
  currentClientId = c.id;
  const display = localName(c);
  $('#clientInput').value = display;
  switchTab('calculator-tab');
}

/* Feature 6: Client job intake form (PDF/HTML export) */
async function generateIntakeForm(clientId) {
  const client = clientId ? clients.find(c => c.id === clientId) : null;
  const shopName  = shopField('biz') || 'Khayt';
  const shopPhone = settings.phone || '';
  const shopEmail = settings.email || '';
  const clientName = client ? localName(client) : '';
  const dateStr = new Date().toLocaleDateString(localeTag(), { year: 'numeric', month: 'long', day: 'numeric' });
  const accentColor = safeCssColor(settings.invAccentColor, '#5E2E14');

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${shopName} — ${t('cl.intake_title')}</title>
<style>
  body { font-family: Arial, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 24px; color: #222; }
  .header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 3px solid ${accentColor}; padding-bottom: 16px; margin-bottom: 24px; }
  .shop-name { font-size: 22px; font-weight: 700; color: ${accentColor}; }
  .shop-contact { font-size: 12px; color: #555; text-align: end; }
  h1 { font-size: 20px; color: ${accentColor}; margin-bottom: 20px; }
  .field { margin-bottom: 18px; }
  label { display: block; font-weight: 600; font-size: 13px; margin-bottom: 6px; color: #333; }
  .field-line { border-bottom: 1px solid #999; height: 28px; }
  .checkbox-row { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
  .checkbox-row input { width: 16px; height: 16px; }
  .signature-area { display: flex; gap: 40px; margin-top: 32px; border-top: 1px solid #ccc; padding-top: 20px; }
  .sig-block { flex: 1; }
  .sig-block .sig-line { border-bottom: 1px solid #555; height: 40px; margin-bottom: 6px; }
  .sig-block label { font-size: 12px; color: #666; }
  .footer { margin-top: 32px; font-size: 11px; color: #888; text-align: center; border-top: 1px solid #eee; padding-top: 12px; }
  @media print { body { margin: 20px; } }
</style>
</head>
<body>
  <div class="header">
    <div>
      <div class="shop-name">${escapeHtml(shopName)}</div>
      ${shopPhone ? `<div style="font-size:12px; color:#555;">${escapeHtml(shopPhone)}</div>` : ''}
    </div>
    <div class="shop-contact">
      ${shopEmail ? `<div>${escapeHtml(shopEmail)}</div>` : ''}
      <div>${dateStr}</div>
    </div>
  </div>

  <h1>${escapeHtml(t('cl.intake_title'))}</h1>

  <div class="field">
    <label>${escapeHtml(t('cl.name'))}</label>
    <div class="field-line">${escapeHtml(clientName)}</div>
  </div>
  <div class="field">
    <label>${escapeHtml(t('cl.phone'))} / ${escapeHtml(t('cl.email'))}</label>
    <div class="field-line"></div>
  </div>
  <div class="field">
    <label>${escapeHtml(t('cl.intake_project'))}</label>
    <div class="field-line"></div>
    <div class="field-line" style="margin-top:8px;"></div>
  </div>
  <div class="field">
    <label>${escapeHtml(t('cl.intake_qty'))}</label>
    <div class="field-line"></div>
  </div>
  <div class="field">
    <label>Material preference</label>
    <div class="field-line"></div>
  </div>
  <div class="field">
    <label>Color preference</label>
    <div class="field-line"></div>
  </div>
  <div class="field">
    <label>${escapeHtml(t('cl.intake_deadline'))}</label>
    <div class="field-line"></div>
  </div>
  <div class="field">
    <label>${escapeHtml(t('cl.intake_requirements'))}</label>
    <div class="field-line"></div>
    <div class="field-line" style="margin-top:8px;"></div>
  </div>
  <div class="field">
    <label>File delivery method</label>
    <div class="checkbox-row"><input type="checkbox"> Email</div>
    <div class="checkbox-row"><input type="checkbox"> WeTransfer</div>
    <div class="checkbox-row"><input type="checkbox"> USB</div>
  </div>
  <div class="checkbox-row" style="margin-top:12px;">
    <input type="checkbox">
    <label style="font-weight:400; font-size:13px;">I approve minor design adjustments if needed</label>
  </div>

  <div class="signature-area">
    <div class="sig-block">
      <div class="sig-line"></div>
      <label>Client Signature &amp; Date</label>
    </div>
    <div class="sig-block">
      <div class="sig-line"></div>
      <label>Studio Representative</label>
    </div>
  </div>

  <div class="footer">${escapeHtml(shopName)} · ${escapeHtml(shopField('addr') || '')}</div>
</body>
</html>`;

  if (window.hubAPI?.saveHtml) {
    await window.hubAPI.saveHtml(html, 'intake-form.html');
    toast(t('cl.intake_saved'), 'success');
  }
}

function openClientHistory(clientId) {
  const c = clients.find(x => x.id === clientId);
  if (!c) return;
  const displayName = localName(c);
  const orders = printLog.filter(o => o.clientId === clientId)
    .sort((a, b) => (b.date || '').localeCompare(a.date || ''));

  const { revenue: totalRev, count: completedCount } = getClientStats(clientId);
  const totalOrders = orders.length;
  const avgOrder = completedCount > 0 ? totalRev / completedCount : 0;

  const statusCls = { pending:'pending', printing:'printing', post:'post', completed:'completed' };

  const rowsHtml = orders.length === 0
    ? `<p style="color:var(--text-muted); font-size:13px; margin:12px 0 0;">${escapeHtml(t('cl.history_empty'))}</p>`
    : `<div class="table-wrap" style="margin-top:14px;">
        <table>
          <thead><tr>
            <th data-i18n="common.date">${escapeHtml(t('common.date'))}</th>
            <th>${escapeHtml(t('log.client'))}</th>
            <th>${escapeHtml(t('common.status'))}</th>
            <th>${escapeHtml(t('log.price'))}</th>
            <th>${escapeHtml(t('log.pay_status'))}</th>
          </tr></thead>
          <tbody>
            ${orders.map(o => `
              <tr>
                <td style="font-size:12px; color:var(--text-dim); white-space:nowrap;">${escapeHtml(o.date)}</td>
                <td><strong>${escapeHtml(o.project || o.id)}</strong><div style="font-size:11px; color:var(--text-muted);">${escapeHtml(o.id)}</div></td>
                <td><span class="badge ${escapeHtml(o.status)}">${escapeHtml(t('queue.' + o.status))}</span></td>
                <td style="font-weight:600; color:var(--success); font-variant-numeric:tabular-nums; white-space:nowrap;">${fmtPrice(o.price)}</td>
                <td>${paymentBadge(o)}</td>
              </tr>`).join('')}
          </tbody>
        </table>
      </div>`;

  openFormModal({
    title:     `${displayName} — ${t('cl.history')}`,
    saveLabel: t('cl.quote'),
    sizeLg:    true,
    bodyHtml:  `
      <div class="cl-hist-stats">
        <div class="cl-hist-stat">
          <div class="v">${totalOrders}</div>
          <div class="l">${escapeHtml(t('cl.hist_orders'))}</div>
        </div>
        <div class="cl-hist-stat">
          <div class="v">${fmtMoney(totalRev)}</div>
          <div class="l">${escapeHtml(t('cl.hist_revenue'))} ${escapeHtml(currencySymbol())}</div>
        </div>
        <div class="cl-hist-stat">
          <div class="v">${isFinite(avgOrder) && avgOrder > 0 ? fmtMoney(avgOrder) : '—'}</div>
          <div class="l">${escapeHtml(t('cl.hist_avg'))} ${escapeHtml(currencySymbol())}</div>
        </div>
      </div>
      ${rowsHtml}
      <div style="margin-top:16px; padding-top:14px; border-top:1px solid var(--border-soft); display:flex; gap:8px; flex-wrap:wrap;">
        <button class="btn small primary" id="btnPrintStatement">${escapeHtml(t('cl.print_statement'))}</button>
        <button class="btn small ghost" id="btnExportClientInvoices">${escapeHtml(t('cl.export_all_invoices'))}</button>
        <button class="btn small ghost" id="btnExportClientPortal">🌐 ${escapeHtml(t('cl.portal_export'))}</button>
      </div>`,
    onMount(modal) {
      modal.querySelector('#btnPrintStatement')?.addEventListener('click', () => {
        generateClientStatement(clientId);
      });
      modal.querySelector('#btnExportClientInvoices')?.addEventListener('click', () => {
        exportClientInvoices(clientId);
      });
      modal.querySelector('#btnExportClientPortal')?.addEventListener('click', () => {
        exportClientPortal(clientId);
      });
    },
    onSave() { quoteForClient(clientId); return true; }
  });
}


/* ============================================================
   PDPL / data-subject rights — export (access & portability) and
   erasure with an explicit order-handling choice.
   See docs/KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md.
   ============================================================ */

/** Right of access / portability: everything Khayt holds about one customer, as JSON. */
async function exportClientData(clientId) {
  const P = (typeof KhaytPrivacy !== 'undefined') ? KhaytPrivacy : null;
  if (!P) { toast(t('priv.unavailable') || 'Privacy tools unavailable', 'error'); return; }
  const client = clients.find(c => c.id === clientId);
  if (!client) return;
  const payload = P.buildClientDataExport(clientId, { clients, printLog, waitingList, waitingListHistory });
  const name = (localName(client) || client.id).replace(/[^\w؀-ۿ -]/g, '').trim() || client.id;
  const fname = `khayt-customer-data-${name}-${localDateStr()}.json`;
  const json = JSON.stringify(payload, null, 2);
  try {
    if (window.hubAPI?.saveTextFile) {
      const r = await window.hubAPI.saveTextFile({
        content: json,
        defaultName: fname,
        filters: [{ name: 'JSON', extensions: ['json'] }],
      });
      if (r && r.canceled) return;
      if (r && r.ok === false) throw new Error(r.error || 'save failed');
    } else {
      const blob = new Blob([json], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob); a.download = fname; a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    }
    toast(t('priv.exported', { n: payload.counts.orders }) || `Exported customer data (${payload.counts.orders} orders)`, 'success');
  } catch (e) {
    toast(String(e.message || e), 'error');
  }
}

async function deleteClient(clientId) {
  const P = (typeof KhaytPrivacy !== 'undefined') ? KhaytPrivacy : null;
  const client = clients.find(c => c.id === clientId);
  // Show what erasure will touch, and let the owner choose whether order records survive.
  const plan = P ? P.planClientErasure(clientId, { clients, printLog, waitingList, waitingListHistory }, 'full') : null;
  let fullErase = false;
  if (P && plan && (plan.counts.orders || plan.counts.intake || plan.counts.communications)) {
    const choice = await new Promise((resolve) => {
      openFormModal({
        title: t('priv.erase_title') || 'Delete customer',
        sizeLg: false,
        saveLabel: t('common.delete'),
        bodyHtml: `
          <p style="font-size:13px;color:var(--text-dim);margin-bottom:12px;">${escapeHtml(
            t('priv.erase_summary', { orders: plan.counts.orders, intake: plan.counts.intake, comms: plan.counts.communications })
            || `This customer has ${plan.counts.orders} order(s), ${plan.counts.intake} intake submission(s) and ${plan.counts.communications} logged communication(s).`)}</p>
          <label style="display:flex;align-items:flex-start;gap:8px;font-weight:400;cursor:pointer;margin-bottom:8px;">
            <input type="radio" name="eraseMode" value="unlink" checked style="width:auto;margin-top:3px;">
            <span><b>${escapeHtml(t('priv.mode_unlink') || 'Unlink (recommended)')}</b><br>
            <span style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('priv.mode_unlink_hint') || 'Delete the customer record but keep the orders for your financial / ZATCA records.')}</span></span>
          </label>
          <label style="display:flex;align-items:flex-start;gap:8px;font-weight:400;cursor:pointer;">
            <input type="radio" name="eraseMode" value="full" style="width:auto;margin-top:3px;">
            <span><b>${escapeHtml(t('priv.mode_full') || 'Full erase')}</b><br>
            <span style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('priv.mode_full_hint') || 'Also blank the customer name on those orders and purge their intake submissions and communication log. Invoices may legally need to retain some data.')}</span></span>
          </label>`,
        onSave(modal) {
          resolve(modal.querySelector('input[name="eraseMode"]:checked')?.value === 'full');
          return true;
        },
      });
      // Cancel/close resolves as "no erase" via the modal teardown.
      setTimeout(() => {
        const mount = document.getElementById('modalMount');
        const obs = new MutationObserver(() => { if (!mount.querySelector('.modal')) { obs.disconnect(); resolve(null); } });
        obs.observe(mount, { childList: true, subtree: true });
      }, 0);
    });
    if (choice === null) return;   // cancelled
    fullErase = choice === true;
  } else {
    const ok = await confirmModal(t('ce.delete_q'), { danger: true });
    if (!ok) return;
  }

  const idx = clients.findIndex(c => c.id === clientId);
  const removed = idx >= 0 ? clients[idx] : null;
  clients = clients.filter(c => c.id !== clientId);
  // Null-out orders that reference the deleted client (tracked so undo can relink)
  const unlinked = [];
  const priorNames = new Map();
  for (const o of printLog) {
    if (o.clientId === clientId) {
      unlinked.push(o);
      o.clientId = null;
      if (fullErase) { priorNames.set(o.id, o.client); o.client = ''; }
    }
  }
  // Full erase additionally purges the subject's self-submitted intake rows.
  let removedIntake = [], removedHistory = [];
  if (fullErase && P) {
    const plan2 = P.planClientErasure(clientId, { clients: removed ? [removed] : [], printLog, waitingList, waitingListHistory }, 'full');
    const ids = new Set(plan2.purgeIntakeIds), hids = new Set(plan2.purgeIntakeHistoryIds);
    removedIntake = waitingList.filter(r => ids.has(r.id));
    removedHistory = waitingListHistory.filter(r => hids.has(r.id));
    waitingList = waitingList.filter(r => !ids.has(r.id));
    waitingListHistory = waitingListHistory.filter(r => !hids.has(r.id));
  }
  saveAll();   // cloud-on: this re-push propagates the erasure to the server copy
  renderClients();
  toast(fullErase ? (t('priv.erased_full') || 'Customer fully erased') : t('ce.deleted'), 'success', 5000, removed ? {
    undo: () => {
      clients.splice(Math.min(Math.max(idx, 0), clients.length), 0, removed);
      for (const o of unlinked) {
        o.clientId = clientId;
        if (priorNames.has(o.id)) o.client = priorNames.get(o.id);
      }
      if (removedIntake.length) waitingList = waitingList.concat(removedIntake);
      if (removedHistory.length) waitingListHistory = waitingListHistory.concat(removedHistory);
      saveAll();
      renderClients();
    },
  } : {});
}

function openClientEditor(clientId = null) {
  const existing = clientId ? clients.find(c => c.id === clientId) : null;
  const draft = existing
    ? { ...existing }
    : { id: uid('CLI'), nameEn: '', nameAr: '', phone: '', email: '', cr: '', vat: '', notes: '', defaultDiscount: 0, createdAt: localDateStr() };
  if (!draft.priceList) draft.priceList = [];
  const rec = draft.recurring || { enabled: false, interval: 'monthly', nextDue: '' };

  const intervalOptions = ['weekly','biweekly','monthly','quarterly']
    .map(v => `<option value="${v}" ${rec.interval === v ? 'selected' : ''}>${escapeHtml(t('rec.interval.' + v))}</option>`)
    .join('');

  const bodyHtml = `
    <div class="inline-pair">
      <div>
        <label>${escapeHtml(t('ce.name_en'))}</label>
        <input type="text" data-f="nameEn" placeholder="${escapeHtml(t('ce.name_en_ph'))}" value="${escapeHtml(draft.nameEn || '')}">
      </div>
      <div>
        <label>${escapeHtml(t('ce.name_ar'))}</label>
        <input type="text" data-f="nameAr" dir="rtl" placeholder="${escapeHtml(t('ce.name_ar_ph'))}" value="${escapeHtml(draft.nameAr || '')}">
      </div>
    </div>
    <div class="inline-pair">
      <div>
        <label>${escapeHtml(t('ce.phone'))}</label>
        <input type="tel" data-f="phone" placeholder="+966 5x xxx xxxx" value="${escapeHtml(draft.phone || '')}">
      </div>
      <div>
        <label>${escapeHtml(t('ce.email'))}</label>
        <input type="email" data-f="email" value="${escapeHtml(draft.email || '')}">
      </div>
    </div>
    <div class="inline-pair">
      <div>
        <label>${escapeHtml(t('ce.cr'))}</label>
        <input type="text" data-f="cr" value="${escapeHtml(draft.cr || '')}">
      </div>
      <div>
        <label>${escapeHtml(t('ce.vat'))}</label>
        <input type="text" data-f="vat" maxlength="15" value="${escapeHtml(draft.vat || '')}">
      </div>
    </div>
    <label>${escapeHtml(t('ce.notes'))}</label>
    <input type="text" data-f="notes" placeholder="${escapeHtml(t('ce.notes_ph'))}" value="${escapeHtml(draft.notes || '')}">

    <label style="margin-top:10px;">${escapeHtml(t('cl.source'))}</label>
    <select data-f="source">
      ${['instagram','referral','walk_in','website','exhibition','other'].map(s =>
        `<option value="${s}" ${(draft.source || 'other') === s ? 'selected' : ''}>${escapeHtml(t('cl.source_' + s))}</option>`
      ).join('')}
    </select>

    <div style="margin-top:14px; display:flex; align-items:center; gap:12px;">
      <div style="flex:1;">
        <label style="margin-top:0;">${escapeHtml(t('ce.default_discount'))} (%)</label>
        <input type="number" data-f="defaultDiscount" min="0" max="100" step="1" value="${draft.defaultDiscount || 0}" placeholder="0">
      </div>
      <div style="flex:2; padding-top:20px; font-size:12px; color:var(--text-muted);">${escapeHtml(t('ce.default_discount_hint'))}</div>
    </div>

    <div style="margin-top:14px;">
      <label style="margin-top:0;">${escapeHtml(t('ce.currency'))}</label>
      <select id="ceCurrency">
        <option value="">${escapeHtml(t('common.default') !== 'common.default' ? t('common.default') : 'Default')} (${escapeHtml(settings.currency || 'SAR')})</option>
        ${Object.entries(CURRENCIES).map(([code, c]) => `<option value="${code}"${draft.currency === code ? ' selected' : ''}>${escapeHtml(c.label)}</option>`).join('')}
      </select>
      <p style="font-size:11.5px;color:var(--text-muted);margin:3px 0 0;">${escapeHtml(t('ce.currency_hint'))}</p>
    </div>

    <div style="margin-top:14px; display:flex; align-items:center; gap:12px;">
      <div style="flex:1;">
        <label style="margin-top:0;">${escapeHtml(t('ce.credit_limit'))} (${currencySymbol()})</label>
        <input type="number" id="ceCreditLimit" min="0" step="1" value="${draft.creditLimit || 0}" placeholder="0">
      </div>
      <div style="flex:2; padding-top:20px; font-size:12px; color:var(--text-muted);">${escapeHtml(t('ce.credit_limit_hint'))}</div>
    </div>

    <div style="margin-top:16px;padding-top:14px;border-top:1px solid var(--border-soft);">
      <div style="display:flex; align-items:center; gap:8px; margin-bottom:6px;">
        <label style="margin:0; flex:1; font-size:12.5px; font-weight:600;">${escapeHtml(t('ce.price_list'))}</label>
        <button class="btn ghost small" id="cePlAdd" type="button">${escapeHtml(t('ce.pl_add'))}</button>
      </div>
      <p style="font-size:11.5px;color:var(--text-muted);margin:0 0 8px;">${escapeHtml(t('ce.price_list_hint'))}</p>
      <div id="cePriceListWrap"></div>
    </div>

    <div style="margin-top:16px;padding-top:14px;border-top:1px solid var(--border-soft);">
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-top:0;">
        <input type="checkbox" id="recEnabled" style="width:auto;margin:0;" ${rec.enabled ? 'checked' : ''}>
        <span>${escapeHtml(t('rec.enable'))}</span>
      </label>
      <div id="recFields" style="${rec.enabled ? '' : 'display:none;'} margin-top:10px;">
        <div class="inline-pair">
          <div>
            <label>${escapeHtml(t('rec.interval'))}</label>
            <select id="recInterval">${intervalOptions}</select>
          </div>
          <div>
            <label>${escapeHtml(t('rec.next_due'))}</label>
            <input type="date" id="recNextDue" value="${escapeHtml(rec.nextDue || '')}">
          </div>
        </div>
        <div class="inline-pair" style="margin-top:8px;">
          <div>
            <label style="display:flex;align-items:center;gap:8px;cursor:pointer;">
              <input type="checkbox" id="recPaused" style="width:auto;margin:0;" ${rec.paused ? 'checked' : ''}>
              <span>${escapeHtml(t('rec.paused') || 'Paused')}</span>
            </label>
          </div>
          <div>
            <label>${escapeHtml(t('rec.end_date') || 'Stop after (optional)')}</label>
            <input type="date" id="recEndDate" value="${escapeHtml(rec.endDate || '')}">
          </div>
        </div>
        <button type="button" id="recSkip" class="btn ghost small" style="margin-top:8px;">${escapeHtml(t('rec.skip_next') || 'Skip next cycle')}</button>
        <p style="font-size:11.5px;color:var(--text-muted);margin:6px 0 0;">${escapeHtml(t('rec.hint'))}</p>
      </div>
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-top:12px;">
        <input type="checkbox" id="ceMarketingOptOut" style="width:auto;margin:0;" ${draft.marketingOptOut ? 'checked' : ''}>
        <span>${escapeHtml(t('camp.opt_out') || 'Exclude from marketing campaigns')}</span>
      </label>
    </div>

    <div style="margin-top:16px;padding-top:14px;border-top:1px solid var(--border-soft);">
      <div style="display:flex; align-items:center; gap:8px; margin-bottom:6px;">
        <label style="margin:0; flex:1; font-size:12.5px; font-weight:600;">📍 ${escapeHtml(t('ce.address_book'))}</label>
        <button class="btn ghost small" id="ceAddrAdd" type="button">${escapeHtml(t('ce.addr_add'))}</button>
      </div>
      <div id="ceAddressBookWrap"></div>
    </div>

    <div id="clientHistorySection" style="margin-top:16px; padding-top:14px; border-top:1px solid var(--border-soft);">
    </div>

    <div style="margin-top:16px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <div style="display:flex; align-items:center; gap:8px; margin-bottom:8px;">
        <label style="margin:0; flex:1; font-size:12.5px; font-weight:600;">💬 ${escapeHtml(t('ce.comm_log'))}</label>
      </div>
      <div style="display:flex; gap:6px; margin-bottom:8px;">
        <select id="ceCommType" style="min-width:90px; font-size:12px;">
          <option value="call">${escapeHtml(t('ce.comm_call'))}</option>
          <option value="email">${escapeHtml(t('ce.comm_email'))}</option>
          <option value="whatsapp">${escapeHtml(t('ce.comm_wa'))}</option>
          <option value="meeting">${escapeHtml(t('ce.comm_meeting'))}</option>
          <option value="note">${escapeHtml(t('ce.comm_note'))}</option>
        </select>
        <input type="text" id="ceCommNote" placeholder="${escapeHtml(t('ce.comm_note_ph'))}" style="flex:1; font-size:12px;">
        <button type="button" id="ceCommAdd" class="btn small primary">${escapeHtml(t('common.add'))}</button>
      </div>
      <div id="ceCommLogList" style="max-height:160px; overflow-y:auto;"></div>
    </div>
    ${existing && settings.loyaltyEnabled && clientLoyaltyAvailable(existing.id) > 0 ? `
    <div style="margin-top:14px; padding-top:12px; border-top:1px solid var(--border-soft); display:flex; align-items:center; gap:10px; flex-wrap:wrap;">
      <span style="font-weight:600; font-size:12.5px;">⭐ ${escapeHtml(t('loyalty.points') || 'Loyalty points')}: ${clientLoyaltyAvailable(existing.id)}</span>
      <button type="button" id="btnRedeemLoyalty" class="btn small">${escapeHtml(t('loyalty.redeem_btn') || 'Redeem for store credit')}</button>
    </div>` : ''}
  `;

  openFormModal({
    title: existing ? t('ce.edit_title') : t('ce.new_title'),
    saveLabel: t('ce.save'),
    sizeLg: false,
    bodyHtml,
    onMount(modal) {
      modal.querySelectorAll('[data-f]').forEach(input => {
        input.addEventListener('input', () => { draft[input.dataset.f] = input.value; });
      });
      modal.querySelector('#btnRedeemLoyalty')?.addEventListener('click', (e) => {
        redeemLoyaltyPoints(existing.id);
        e.target.disabled = true;
        e.target.textContent = t('loyalty.redeemed_short') || 'Redeemed ✓';
      });
      const recCb  = modal.querySelector('#recEnabled');
      const recDiv = modal.querySelector('#recFields');
      recCb.addEventListener('change', () => { recDiv.style.display = recCb.checked ? '' : 'none'; });
      modal.querySelector('#recInterval').addEventListener('change', e => { rec.interval = e.target.value; });
      modal.querySelector('#recNextDue').addEventListener('change', e => { rec.nextDue = e.target.value; });
      modal.querySelector('#recSkip')?.addEventListener('click', () => {
        const ndEl = modal.querySelector('#recNextDue');
        const from = ndEl.value || localDateStr();
        const iv = modal.querySelector('#recInterval').value;
        const next = (typeof KhaytSubscriptions !== 'undefined') ? KhaytSubscriptions.nextRunDate(from, iv) : from;
        ndEl.value = next; rec.nextDue = next;
        toast(t('rec.skipped') || 'Skipped to ' + next, 'info');
      });
      // Currency (Feature 1)
      const ceCurrEl = modal.querySelector('#ceCurrency');
      if (ceCurrEl) ceCurrEl.addEventListener('change', e => { draft.currency = e.target.value || null; });

      // Price list (Feature 4)
      const plWrap = modal.querySelector('#cePriceListWrap');
      function renderPriceList() {
        if (!plWrap) return;
        if (!draft.priceList || draft.priceList.length === 0) {
          plWrap.innerHTML = `<div style="color:var(--text-muted);font-size:12.5px;padding:4px 0;">${escapeHtml(t('ce.price_list_empty'))}</div>`;
          return;
        }
        plWrap.innerHTML = `<div class="table-wrap"><table class="price-list-table">
          <thead><tr>
            <th>${escapeHtml(t('ce.pl_product'))}</th>
            <th>${escapeHtml(t('ce.pl_price'))}</th>
            <th>${escapeHtml(t('ce.pl_note'))}</th>
            <th></th>
          </tr></thead>
          <tbody>
          ${draft.priceList.map((pl, i) => `<tr>
            <td><input type="text" class="pl-prod" data-pli="${i}" value="${escapeHtml(pl.product || '')}" placeholder="${escapeHtml(t('ce.pl_product'))}" style="width:100%;font-size:12px;"></td>
            <td><input type="number" class="pl-price" data-pli="${i}" value="${pl.price || ''}" min="0" step="0.01" style="width:90px;font-size:12px;"></td>
            <td><input type="text" class="pl-note" data-pli="${i}" value="${escapeHtml(pl.note || '')}" placeholder="${escapeHtml(t('ce.pl_note'))}" style="width:100%;font-size:12px;"></td>
            <td><button class="btn danger small pl-rm" data-pli="${i}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button></td>
          </tr>`).join('')}
          </tbody></table></div>`;
        plWrap.querySelectorAll('.pl-prod').forEach(inp => { inp.addEventListener('input', () => { draft.priceList[+inp.dataset.pli].product = inp.value; }); });
        plWrap.querySelectorAll('.pl-price').forEach(inp => { inp.addEventListener('input', () => { draft.priceList[+inp.dataset.pli].price = Math.max(0, +inp.value || 0); }); });
        plWrap.querySelectorAll('.pl-note').forEach(inp => { inp.addEventListener('input', () => { draft.priceList[+inp.dataset.pli].note = inp.value; }); });
        plWrap.querySelectorAll('.pl-rm').forEach(btn => { btn.addEventListener('click', () => { draft.priceList.splice(+btn.dataset.pli, 1); renderPriceList(); }); });
      }
      renderPriceList();
      const cePlBtn = modal.querySelector('#cePlAdd');
      if (cePlBtn) cePlBtn.addEventListener('click', () => { draft.priceList.push({ product: '', price: 0, note: '' }); renderPriceList(); });

      // Address book (Feature 4)
      if (!draft.addresses) draft.addresses = [];
      const addrWrap = modal.querySelector('#ceAddressBookWrap');
      function renderAddressBook() {
        if (!addrWrap) return;
        if (!draft.addresses || draft.addresses.length === 0) {
          addrWrap.innerHTML = `<div style="color:var(--text-muted);font-size:12.5px;padding:4px 0;">${escapeHtml(t('ce.price_list_empty'))}</div>`;
          return;
        }
        addrWrap.innerHTML = `<div class="table-wrap"><table style="width:100%; border-collapse:collapse;">
          <thead><tr>
            <th style="font-size:11px; text-align:start; padding:2px 4px;">${escapeHtml(t('ce.addr_label'))}</th>
            <th style="font-size:11px; text-align:start; padding:2px 4px;">${escapeHtml(t('ce.addr_address'))}</th>
            <th></th>
          </tr></thead>
          <tbody>${draft.addresses.map((a, i) => `<tr>
            <td style="padding:2px 4px;"><input type="text" class="addr-label" data-ai="${i}" value="${escapeHtml(a.label || '')}" placeholder="${escapeHtml(t('ce.addr_label'))}" style="width:100%;font-size:12px;"></td>
            <td style="padding:2px 4px;"><input type="text" class="addr-addr" data-ai="${i}" value="${escapeHtml(a.address || '')}" placeholder="${escapeHtml(t('ce.addr_address'))}" style="width:100%;font-size:12px;"></td>
            <td><button class="btn danger small addr-rm" data-ai="${i}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button></td>
          </tr>`).join('')}</tbody>
        </table></div>`;
        addrWrap.querySelectorAll('.addr-label').forEach(inp => { inp.addEventListener('input', () => { draft.addresses[+inp.dataset.ai].label = inp.value; }); });
        addrWrap.querySelectorAll('.addr-addr').forEach(inp => { inp.addEventListener('input', () => { draft.addresses[+inp.dataset.ai].address = inp.value; }); });
        addrWrap.querySelectorAll('.addr-rm').forEach(btn => { btn.addEventListener('click', () => { draft.addresses.splice(+btn.dataset.ai, 1); renderAddressBook(); }); });
      }
      renderAddressBook();
      const ceAddrAddBtn = modal.querySelector('#ceAddrAdd');
      if (ceAddrAddBtn) ceAddrAddBtn.addEventListener('click', () => { draft.addresses.push({ id: uid('ADDR'), label: '', address: '' }); renderAddressBook(); });

      // Communication log
      if (!draft.commLog) draft.commLog = [];
      const commListEl = modal.querySelector('#ceCommLogList');
      const COMM_ICONS = { call: '📞', email: '📧', whatsapp: '💬', meeting: '🤝', note: '📝' };
      function renderCommLog() {
        if (!commListEl) return;
        if (draft.commLog.length === 0) {
          commListEl.innerHTML = `<p style="color:var(--text-muted);font-size:12px;margin:4px 0;">${escapeHtml(t('ce.comm_empty'))}</p>`;
          return;
        }
        const sorted = [...draft.commLog].sort((a, b) => (b.at || '').localeCompare(a.at || ''));
        commListEl.innerHTML = sorted.map((e, idx) => `
          <div style="display:flex;align-items:flex-start;gap:6px;padding:5px 0;border-bottom:1px solid var(--border-soft);font-size:12px;">
            <span>${COMM_ICONS[e.type] || '📝'}</span>
            <div style="flex:1;">
              <span style="font-weight:600;">${escapeHtml(t('ce.comm_' + (e.type || 'note')))}</span>
              <span style="color:var(--text-dim);font-size:11px;margin-inline-start:6px;">${escapeHtml((e.at || '').slice(0, 10))}</span>
              <div style="color:var(--text-muted);">${escapeHtml(e.note || '')}</div>
            </div>
            <button class="btn danger small comm-del" data-ci="${idx}" style="flex-shrink:0;" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
          </div>`).join('');
        commListEl.querySelectorAll('.comm-del').forEach(btn => {
          btn.addEventListener('click', () => {
            // find by reverse index since we sorted
            const sorted2 = [...draft.commLog].sort((a, b) => (b.at || '').localeCompare(a.at || ''));
            const toRemove = sorted2[+btn.dataset.ci];
            const idx2 = draft.commLog.indexOf(toRemove);
            if (idx2 >= 0) draft.commLog.splice(idx2, 1);
            renderCommLog();
          });
        });
      }
      renderCommLog();
      const commAddBtn = modal.querySelector('#ceCommAdd');
      if (commAddBtn) {
        commAddBtn.addEventListener('click', () => {
          const noteInput = modal.querySelector('#ceCommNote');
          const typeInput = modal.querySelector('#ceCommType');
          const noteVal = (noteInput?.value || '').trim();
          if (!noteVal) return;
          const newEntry = { id: uid('CMM'), type: typeInput?.value || 'note', note: noteVal, at: new Date().toISOString() };
          draft.commLog.push(newEntry);
          if (draft.commLog.length > 200) draft.commLog.length = 200;
          // Immediately persist to the real client record so it isn't lost if modal is closed via ×
          const liveClient = clients.find(c => c.id === draft.id);
          if (liveClient) {
            if (!liveClient.commLog) liveClient.commLog = [];
            liveClient.commLog.push(newEntry);
            if (liveClient.commLog.length > 200) liveClient.commLog.length = 200;
            saveAll();
          }
          if (noteInput) noteInput.value = '';
          renderCommLog();
        });
      }

      // Order history
      const histEl = modal.querySelector('#clientHistorySection');
      if (clientId && histEl) {
        const clientOrders = printLog
          .filter(o => o.clientId === clientId)
          .sort((a, b) => (b.date || '').localeCompare(a.date || ''));
        if (clientOrders.length === 0) {
          histEl.innerHTML = `<p style="font-size:12.5px; color:var(--text-muted);">${escapeHtml(t('ce.no_history'))}</p>`;
        } else {
          histEl.innerHTML = `
            <h4 style="font-size:11.5px; font-weight:600; color:var(--text-dim); text-transform:uppercase; letter-spacing:0.07em; margin:0 0 10px;">${escapeHtml(t('ce.history_title'))} (${clientOrders.length})</h4>
            <div class="client-history">
              ${clientOrders.slice(0, 30).map(o => `
                <div class="ch-row">
                  <span class="ch-date">${escapeHtml(o.date)}</span>
                  <span class="ch-name">${escapeHtml(o.project)}</span>
                  <span class="badge ${escapeHtml(o.status)}">${escapeHtml(t('queue.' + o.status))}</span>
                  <span class="ch-price">${fmtPrice(o.price)}</span>
                </div>`).join('')}
            </div>
            ${clientOrders.length > 30 ? `<p style="font-size:11.5px;color:var(--text-muted);margin:6px 0 0;">+${clientOrders.length - 30} more — see Orders log</p>` : ''}`;
        }
      }
    },
    async onSave(modal) {
      if (!draft.nameEn.trim() && !draft.nameAr.trim()) {
        toast(t('ce.need_name'), 'error');
        return false;
      }
      draft.defaultDiscount = Math.min(100, Math.max(0, num(draft.defaultDiscount, 0)));
      draft.recurring = {
        enabled:  modal.querySelector('#recEnabled').checked,
        interval: modal.querySelector('#recInterval').value,
        nextDue:  modal.querySelector('#recNextDue').value || null,
        paused:   modal.querySelector('#recPaused')?.checked || false,
        endDate:  modal.querySelector('#recEndDate')?.value || null,
      };
      draft.marketingOptOut = modal.querySelector('#ceMarketingOptOut')?.checked || false;
      draft.currency = modal.querySelector('#ceCurrency')?.value || null;
      draft.creditLimit = Math.max(0, num(modal.querySelector('#ceCreditLimit')?.value, 0)) || 0;
      draft.source = modal.querySelector('[data-f="source"]')?.value || 'other';
      draft.priceList = (draft.priceList || []).filter(pl => pl.product.trim() || pl.price > 0);
      draft.addresses = (draft.addresses || []).filter(a => a.label.trim() || a.address.trim());
      const idx = clients.findIndex(c => c.id === draft.id);
      if (idx >= 0) clients[idx] = draft;
      else clients.push(draft);
      saveAll();
      renderClients();
      toast(t('ce.saved'), 'success');
      return true;
    }
  });
}

/* ============================================================
   Recurring orders — the rule is lib/recurring-orders.js; this is its host
   ============================================================ */
/**
 * Create every standing order that is due and move its schedule on.
 *
 * Runs at boot and every six hours (`wire-events.js`). This used to be two
 * functions — one for the due day, one that knew about lead days — each
 * guarding against the other and each making a slightly different job. The
 * rule is one now and the same in both apps; it is idempotent (a cycle that
 * already has its job asks for nothing), so running it twice creates nothing
 * twice. It mutates `printLog`, the client's schedule and `settings` (the
 * invoice counter) in place, which is why the one saveAll() here is enough
 * and also why it is required.
 */
function checkRecurringOrders() {
  if (typeof KhaytRecurringOrders === 'undefined') return;
  const { created } = KhaytRecurringOrders.run(clients, printLog, { settings, now: new Date() });
  if (created.length > 0) {
    saveAll();
    renderKanban(); renderLogs(); renderDashboard();
    toast(t('rec.created', { n: created.length }), 'success', 4500);
  }
}

/* ============================================================
   Subscriptions / retainers — recurring revenue (distinct from
   recurring orders: this bills a flat fee per cycle, not a reprint)
   ============================================================ */

/** Materialize due subscription billings into invoices. Runs on boot; creates
 *  one invoice per due cycle (deduped by subscriptionId+cycle), advances the
 *  schedule. Safe + idempotent. */
function checkSubscriptionBilling() {
  if (typeof KhaytSubscriptions === 'undefined') return;
  const now = Date.now();
  let created = 0;
  for (const sub of subscriptions) {
    if (!sub || sub.status !== 'active') continue;
    // Catch up across every cycle boundary crossed while the app was closed.
    let guard = 0;
    while (KhaytSubscriptions.isDueForCycle(sub, now) && guard < 240) {
      guard++;
      const cycle = sub.nextRunAt;
      const already = printLog.some(o => o.subscriptionId === sub.id && o.recurringCycle === cycle);
      if (!already) {
        const nowD = new Date();
        const invoiceNum = nextInvoiceNumber();
        const seq = String(settings.invNumNext - 1).padStart(4, '0');
        const client = clients.find(c => c.id === sub.clientId);
        printLog.unshift({
          id: `${settings.invPrefix || 'INV'}-${nowD.getFullYear()}-${seq}`,
          invoiceNum, invoiceNumber: invoiceNum,
          date: cycle, timestamp: nowD.toISOString(),
          project: sub.planName || (t('subs.plan') || 'Subscription'),
          clientId: sub.clientId || null,
          price: Math.max(0, +sub.amount || 0),
          status: 'pending', statusHistory: [{ status: 'pending', at: nowD.toISOString() }],
          paymentStatus: 'unpaid', paidAmount: 0,
          parts: [], tags: ['subscription'], notes: '',
          internalNotes: `↳ ${sub.planName || (t('subs.plan') || 'Subscription')}`,
          subscriptionId: sub.id, recurringCycle: cycle,
          currency: sub.currency || undefined,
        });
        created++;
      }
      // Advance one cycle (calendar-safe).
      const patch = KhaytSubscriptions.markCyclePatch(sub, now);
      sub.lastRunAt = patch.lastRunAt; sub.nextRunAt = patch.nextRunAt;
      if (sub.endAt && sub.nextRunAt > sub.endAt) { sub.status = 'ended'; break; }
    }
  }
  if (created > 0) {
    saveAll();
    if (typeof renderKanban === 'function') renderKanban();
    if (typeof renderLogs === 'function') renderLogs();
    if (typeof renderDashboard === 'function') renderDashboard();
    toast((t('subs.billed', { n: created }) || `Billed ${created} subscription invoice(s)`), 'success', 4500);
  }
}

/** Manage subscriptions/retainers: list, add, pause/resume, end. Shows MRR. */
function openSubscriptionsModal() {
  if (typeof KhaytSubscriptions === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  const cur = (typeof currencySymbol === 'function') ? currencySymbol() : '';
  const intervals = KhaytSubscriptions.INTERVALS;
  const render = (modal) => {
    const mrr = KhaytSubscriptions.monthlyRecurringRevenue(subscriptions);
    const rows = subscriptions.length ? subscriptions.map(s => {
      const client = clients.find(c => c.id === s.clientId);
      const cname = client ? localName(client) : (t('subs.no_client') || '—');
      const statusColor = s.status === 'active' ? 'var(--success)' : (s.status === 'paused' ? 'var(--warning,#d97706)' : 'var(--text-muted)');
      return `<tr style="border-top:1px solid var(--border-soft);">
        <td style="padding:6px 8px;">${escapeHtml(s.planName || '')}<div style="font-size:11px;color:var(--text-muted);">${escapeHtml(cname)}</div></td>
        <td style="padding:6px 8px;text-align:end;">${escapeHtml(fmtMoney(+s.amount || 0))} ${escapeHtml(cur)}<div style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('rec.badge.' + s.interval) || s.interval)}</div></td>
        <td style="padding:6px 8px;text-align:end;font-size:12px;">${escapeHtml(s.nextRunAt || '—')}</td>
        <td style="padding:6px 8px;text-align:center;color:${statusColor};font-size:12px;">${escapeHtml(t('subs.status_' + s.status) || s.status)}</td>
        <td style="padding:6px 8px;text-align:end;white-space:nowrap;">
          ${s.status !== 'ended' ? `<button class="btn ghost small subToggle" data-id="${escapeHtml(s.id)}">${escapeHtml(s.status === 'active' ? (t('subs.pause') || 'Pause') : (t('subs.resume') || 'Resume'))}</button>
          <button class="btn ghost small subEnd" data-id="${escapeHtml(s.id)}" style="color:var(--danger);">${escapeHtml(t('subs.end') || 'End')}</button>` : ''}
        </td>
      </tr>`;
    }).join('') : `<tr><td colspan="5" style="text-align:center;color:var(--text-muted);padding:18px 0;">${escapeHtml(t('subs.empty') || 'No subscriptions yet.')}</td></tr>`;

    const clientOpts = clients.slice().sort((a, b) => localName(a).localeCompare(localName(b)))
      .map(c => `<option value="${escapeHtml(c.id)}">${escapeHtml(localName(c))}</option>`).join('');
    const intervalOpts = intervals.map(iv => `<option value="${escapeHtml(iv)}"${iv === 'monthly' ? ' selected' : ''}>${escapeHtml(t('rec.badge.' + iv) || iv)}</option>`).join('');

    modal.querySelector('#subsBody').innerHTML = `
      <div style="font-size:13px;margin-bottom:10px;">${escapeHtml(t('subs.mrr') || 'Monthly recurring revenue')}: <strong style="color:var(--success);">${escapeHtml(fmtMoney(mrr))} ${escapeHtml(cur)}</strong></div>
      <table style="width:100%;border-collapse:collapse;font-size:13px;"><thead><tr style="color:var(--text-muted);text-align:start;">
        <th style="padding:6px 8px;text-align:start;">${escapeHtml(t('subs.plan') || 'Plan')}</th>
        <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('subs.amount') || 'Amount')}</th>
        <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('subs.next') || 'Next bill')}</th>
        <th style="padding:6px 8px;text-align:center;">${escapeHtml(t('subs.status') || 'Status')}</th>
        <th></th>
      </tr></thead><tbody>${rows}</tbody></table>
      <div style="margin-top:14px;border-top:1px solid var(--border-soft);padding-top:12px;">
        <div style="font-weight:600;font-size:13px;margin-bottom:8px;">${escapeHtml(t('subs.add') || 'New subscription')}</div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;">
          <input id="subPlan" type="text" maxlength="80" placeholder="${escapeHtml(t('subs.plan_ph') || 'e.g. Monthly maintenance')}">
          <select id="subClient">${clientOpts}</select>
          <input id="subAmount" type="number" min="0" step="0.01" placeholder="${escapeHtml(t('subs.amount') || 'Amount')} (${escapeHtml(cur)})">
          <select id="subInterval">${intervalOpts}</select>
          <input id="subStart" type="date" value="${localDateStr()}" title="${escapeHtml(t('subs.next') || 'Next bill')}">
          <button class="btn primary small" id="subAdd">+ ${escapeHtml(t('subs.add') || 'Add')}</button>
        </div>
      </div>`;

    modal.querySelectorAll('.subToggle').forEach(b => b.addEventListener('click', () => {
      const s = subscriptions.find(x => x.id === b.dataset.id); if (!s) return;
      s.status = s.status === 'active' ? 'paused' : 'active'; saveAll(); render(modal);
    }));
    modal.querySelectorAll('.subEnd').forEach(b => b.addEventListener('click', async () => {
      if (!(await confirmModal(t('subs.end_q') || 'End this subscription? It will stop billing.', { danger: true }))) return;
      const s = subscriptions.find(x => x.id === b.dataset.id); if (!s) return;
      s.status = 'ended'; saveAll(); render(modal);
    }));
    modal.querySelector('#subAdd')?.addEventListener('click', () => {
      const plan = modal.querySelector('#subPlan').value.trim();
      const clientId = modal.querySelector('#subClient').value;
      const amount = Math.max(0, num(modal.querySelector('#subAmount').value, 0));
      const interval = modal.querySelector('#subInterval').value;
      const start = modal.querySelector('#subStart').value || localDateStr();
      if (!plan || !amount) { toast(t('subs.need_fields') || 'Add a plan name and amount', 'error'); return; }
      subscriptions.unshift({ id: uid('SUB'), planName: plan, clientId: clientId || null, amount, interval, nextRunAt: start, status: 'active', createdAt: new Date().toISOString() });
      saveAll(); render(modal);
      toast(t('subs.added') || 'Subscription added', 'success');
    });
  };
  openFormModal({
    title: `🔁 ${t('subs.title') || 'Subscriptions & retainers'}`,
    noSave: true,
    bodyHtml: `<div id="subsBody"></div>`,
    onMount(modal) { render(modal); },
  });
}

/* ----- Client autocomplete on the calculator ----- */
function renderClientSuggestions() {
  const input = $('#clientInput');
  const list  = $('#clientSuggestions');
  const term  = input.value.toLowerCase().trim();
  let matches = clients;
  if (term) {
    matches = clients.filter(c =>
      (c.nameEn || '').toLowerCase().includes(term) ||
      (c.nameAr || '').toLowerCase().includes(term) ||
      (c.phone || '').toLowerCase().includes(term)
    );
  }
  matches = matches.slice(0, 6);

  const items = matches.map(c => {
    const dn = localName(c);
    const stats = getClientStats(c.id);
    return `<div class="suggest-item" data-cid="${c.id}">
      <span class="avatar">${escapeHtml(initials(dn))}</span>
      <span>${escapeHtml(dn)}</span>
      ${stats.count > 0 ? `<span class="meta">${stats.count} · ${fmtPrice(stats.revenue)}</span>` : ''}
    </div>`;
  }).join('');

  // Matching on English-or-Arabic only meant a shop writing German compared the
  // typed name against an empty string and offered to create a duplicate of a
  // client it already had. Every language the record carries is checked.
  const nameMatches = (c) => KhaytContentLanguages.allKeys('name')
    .some((k) => String(c[k] || '').trim().toLowerCase() === term);
  const newRow = (term && !clients.some(nameMatches))
    ? `<div class="suggest-item new" data-act="cl-new" data-name="${escapeHtml(input.value)}">+ ${escapeHtml(t('calc.quote.client_save_new'))}: “${escapeHtml(input.value)}”</div>`
    : '';

  if (!items && !newRow) { list.style.display = 'none'; return; }
  list.innerHTML = items + newRow;
  list.style.display = 'block';
}

function hideClientSuggestions() {
  setTimeout(() => { $('#clientSuggestions').style.display = 'none'; }, 150);
}

/**
 * Loyalty points a client has earned across completed orders (read-only display).
 * Earns on the ex-VAT base × the tier's points multiplier, via lib/loyalty.
 * Gated by settings.loyaltyEnabled; 0 when disabled or the lib is absent.
 */
function clientLoyaltyPoints(clientId) {
  if (!settings.loyaltyEnabled || typeof KhaytLoyalty === 'undefined') return 0;
  const perUnit = +settings.loyaltyPointsPerUnit || 1;
  const tier = getClientTier(clientId);
  const mult = (tier && +tier.pointsMultiplier) || 1;
  const _tp = KhaytTax.profileFromSettings(settings);
  let pts = 0;
  for (const o of printLog) {
    if (o.clientId !== clientId || o.status !== 'completed') continue;
    // A voided order is not a sale, and neither is a print the shop marked as
    // not business. Both earned points anyway — this loop checked only the
    // status — and so did an order refunded in full by a credit note, because
    // it read the gross price. Points are a liability the shop honours, so it
    // was awarding a discount on money it never kept: four times the real
    // figure on a client with one kept sale, one void, one personal print and
    // one refund.
    if (o.voidedAt) continue;
    // orderNetRevenueBase is the shop's revenue chokepoint: it excludes a
    // non-business print and a split parent, subtracts credit notes, and
    // converts to the shop's base currency — which this sum needs anyway, since
    // it was adding prices from different currencies together.
    const kept = orderNetRevenueBase(o);
    if (kept <= 0) continue;
    // Points are earned on the value the shop keeps, not on the tax it merely
    // collects — true whichever way it prices.
    const exVat = KhaytTax.computeTax(kept, _tp).subtotal;
    pts += KhaytLoyalty.earnPoints(exVat, { pointsPerUnit: perUnit, tierMultiplier: mult });
  }
  return pts;
}

/** Points a client has already redeemed (sum of loyaltyLedger redeem entries). */
function clientLoyaltyRedeemed(clientId) {
  if (!Array.isArray(loyaltyLedger)) return 0;
  return loyaltyLedger
    .filter(e => e && e.clientId === clientId && e.type === 'redeem')
    .reduce((s, e) => s + (+e.points || 0), 0);
}

/**
 * Clients who have redeemed more points than they now appear to have earned.
 *
 * Points used to be awarded for cancelled orders, prints marked not-business and
 * orders refunded in full. Correcting that lowers what a client has EARNED — and
 * `clientLoyaltyAvailable` clamps at zero, so nothing breaks and nothing goes
 * negative. What does happen is that a customer who was told they had a balance
 * now has none, silently, and the shop finds out when they ask.
 *
 * `redeemed > earned` is exactly that situation and needs no stored history to
 * detect: it can only arise from points that were awarded and spent against
 * something that was not a sale.
 *
 * Report-only. The points were over-awarded, the shop has already honoured some
 * of them, and re-inflating the balance would perpetuate a liability it does not
 * owe. Naming the clients lets the shop decide what to tell them.
 */
function clientsOverRedeemed() {
  if (!settings.loyaltyEnabled || typeof KhaytLoyalty === 'undefined') return [];
  if (!Array.isArray(clients)) return [];
  const out = [];
  for (const c of clients) {
    if (!c || typeof c.id !== 'string') continue;
    const redeemed = clientLoyaltyRedeemed(c.id);
    if (redeemed <= 0) continue;
    const earned = clientLoyaltyPoints(c.id);
    if (redeemed > earned) out.push({ id: c.id, name: c.name || c.id, earned, redeemed, over: redeemed - earned });
  }
  return out;
}

/** Spendable points = earned − already-redeemed (never negative). */
function clientLoyaltyAvailable(clientId) {
  return Math.max(0, clientLoyaltyPoints(clientId) - clientLoyaltyRedeemed(clientId));
}

/**
 * Redeem a client's available points into STORE CREDIT — issues a gift card the
 * owner applies via the existing gift-card flow (we never write giftCardDiscount
 * directly), and records a ledger entry so points can't be double-spent.
 */
function redeemLoyaltyPoints(clientId) {
  const avail = clientLoyaltyAvailable(clientId);
  if (avail <= 0) { toast(t('loyalty.none_to_redeem') || 'No points to redeem', 'info'); return; }
  const rate = +settings.loyaltyRedeemRate || 0.01; // credit per point (default 100 pts = 1)
  const credit = (typeof KhaytLoyalty !== 'undefined')
    ? KhaytLoyalty.pointsToCredit(avail, rate)
    : Math.round(avail * rate * 100) / 100;
  if (credit <= 0) { toast(t('loyalty.none_to_redeem') || 'No points to redeem', 'info'); return; }
  const cl = clients.find(c => c.id === clientId);
  const code = uid('LOY');
  giftCards.push({
    id: uid('GC'), code, initialBalance: credit, balance: credit,
    issuedTo: clientId, issuedToName: cl ? localName(cl) : '',
    issuedAt: new Date().toISOString(), expiresAt: null, redeemedOrders: [], source: 'loyalty',
  });
  loyaltyLedger.push({ id: uid('LOY'), clientId, type: 'redeem', points: avail, credit, giftCardCode: code, ts: new Date().toISOString() });
  saveAll();
  if (typeof renderClients === 'function') renderClients();
  toast(t('loyalty.redeemed', { pts: avail, amt: fmtMoney(credit), code }) || `Redeemed ${avail} pts → ${fmtMoney(credit)} store credit (${code})`, 'success', 7000);
}

function getClientTier(clientId) {
  if (!settings.loyaltyEnabled) return null;
  const tiers = (settings.loyaltyTiers || []).filter(tier => tier.name);
  if (tiers.length === 0) return null;

  let completedCount = 0;
  let totalSpend = 0;
  for (const o of printLog) {
    if (o.clientId !== clientId || o.status !== 'completed') continue;
    completedCount++;
    totalSpend += orderNetRevenueBase(o);
  }

  // Find the highest tier the client qualifies for
  const eligible = tiers.filter(tier =>
    (!tier.minOrders || completedCount >= +tier.minOrders) &&
    (!tier.minSpend  || totalSpend     >= +tier.minSpend)
  );
  if (eligible.length === 0) return null;
  // Return the tier with the highest benefit (largest minOrders/minSpend combo)
  return eligible.sort((a, b) => {
    const orderDiff = (+b.minOrders || 0) - (+a.minOrders || 0);
    if (orderDiff !== 0) return orderDiff;
    return (+b.minSpend || 0) - (+a.minSpend || 0);
  })[0];
}

function exportClientsCsv() {
  // Build stats map (same as renderClients uses)
  const clientStatsMap = new Map();
  for (const o of printLog) {
    if (!o.clientId) continue;
    let s = clientStatsMap.get(o.clientId);
    if (!s) { s = { count: 0, revenue: 0, lastDate: null }; clientStatsMap.set(o.clientId, s); }
    s.count++;
    if (KhaytOrderStatus.isFinished(o)) s.revenue += orderNetRevenueBase(o);
    if (!s.lastDate || o.date > s.lastDate) s.lastDate = o.date;
  }

  const headers = [
    'ID', 'Name (EN)', 'Name (AR)', 'Phone', 'Email',
    'Source', 'Total Orders', `Revenue (${currencySymbol()})`,
    `Outstanding (${currencySymbol()})`, 'Last Order'
  ];

  const lines = [
    headers.map(csvEsc).join(','),
    ...clients.map(c => {
      const stats = clientStatsMap.get(c.id) || { count: 0, revenue: 0, lastDate: null };
      const outstanding = clientOutstandingBalance(c.id);
      return [
        c.id,
        c.nameEn || '',
        c.nameAr || '',
        c.phone  || '',
        c.email  || '',
        c.source || '',
        stats.count,
        stats.revenue.toFixed(2),
        outstanding.toFixed(2),
        stats.lastDate || ''
      ].map(csvEsc).join(',');
    })
  ];

  downloadBlob(
    new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' }),
    `clients-${localDateStr()}.csv`
  );
}

function exportClientPortal(clientId) {
  const c = clients.find(x => x.id === clientId);
  if (!c) return;
  const displayName = localName(c);
  const orders = printLog.filter(o => o.clientId === clientId)
    .sort((a, b) => (b.date || '').localeCompare(a.date || ''));
  // Both spellings, both ways round: a delivered order is finished, so it is
  // not still active and it does belong in the finished count.
  const activeOrders = orders.filter(o => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote');
  const completedOrders = orders.filter(o => KhaytOrderStatus.isFinished(o));
  const outstanding = orders
    .filter(o => payStatus(o) !== 'paid')
    .reduce((s, o) => s + orderOwedBase(o), 0);

  const statusColors = {
    pending: '#f59e0b', printing: '#3b82f6', post: '#8b5cf6',
    qc: '#a78bfa', completed: '#22c55e', on_hold: '#f97316', quote: '#94a3b8'
  };
  const statusSteps = ['pending','printing','post','qc','completed'];

  const stepperHtml = (order) => {
    const si = statusSteps.indexOf(order.status);
    return `<div style="display:flex;gap:4px;align-items:center;margin-top:6px;font-size:10px;">
      ${statusSteps.map((st, i) => {
        const done = i < si;
        const cur  = i === si;
        const col  = cur ? (statusColors[st] || '#94a3b8') : (done ? '#22c55e' : '#374151');
        return `<span style="background:${col};color:#fff;padding:2px 7px;border-radius:4px;opacity:${cur?1:done?0.7:0.35};">${escapeHtml(st)}</span>${i < statusSteps.length-1 ? `<span style="color:#555;font-size:9px;">›</span>` : ''}`;
      }).join('')}
    </div>`;
  };

  const bizName = (shopField('biz') || 'Khayt');
  const portalIsAr = i18n.current === 'ar';
  const portalLang = portalIsAr ? 'ar' : 'en';
  const PL = {
    activeOrders:      portalIsAr ? 'طلبات نشطة'   : 'Active orders',
    completed:         portalIsAr ? 'مكتملة'        : 'Completed',
    outstandingBal:    portalIsAr ? 'الرصيد المستحق': 'Outstanding balance',
    date:              portalIsAr ? 'التاريخ'       : 'Date',
    project:           portalIsAr ? 'المشروع'       : 'Project',
    status:            portalIsAr ? 'الحالة'        : 'Status',
    amount:            portalIsAr ? 'المبلغ'        : 'Amount',
    payment:           portalIsAr ? 'الدفع'         : 'Payment',
    paid:              portalIsAr ? '✓ مدفوع'      : '✓ Paid',
    outstanding:       portalIsAr ? 'مستحق'         : 'Outstanding',
    paymentInfo:       portalIsAr ? 'معلومات الدفع' : 'Payment Information',
    orderPortal:       portalIsAr ? 'بوابة الطلبات' : 'Order portal for',
    generatedBy:       portalIsAr ? 'أُنشئ بواسطة Khayt' : 'Generated by Khayt',
  };
  const rowsHtml = orders.map(o => {
    const isPaid = payStatus(o) === 'paid';
    return `<tr style="border-bottom:1px solid #2a2a2a;">
      <td style="padding:8px;font-size:12px;white-space:nowrap;color:#888;">${escapeHtml(o.date || '')}</td>
      <td style="padding:8px;font-size:12px;"><strong style="color:#e2e8f0;">${escapeHtml(o.project || o.id)}</strong><div style="font-size:10px;color:#666;">${escapeHtml(o.id)}</div>
        ${!['completed','quote'].includes(o.status) ? stepperHtml(o) : ''}
      </td>
      <td style="padding:8px;"><span style="background:${statusColors[o.status]||'#555'};color:#fff;padding:2px 8px;border-radius:10px;font-size:11px;">${escapeHtml(o.status)}</span></td>
      <td style="padding:8px;text-align:right;font-weight:600;color:#4ade80;">${fmtPrice(o.price)}</td>
      <td style="padding:8px;text-align:center;font-size:11px;color:${isPaid?'#4ade80':'#f87171'};">${isPaid ? PL.paid : PL.outstanding}</td>
    </tr>`;
  }).join('');

  const paymentBlock = settings.paymentInstructions
    ? `<div style="margin-top:24px;padding:16px;background:#1a1a2e;border-radius:8px;border:1px solid #2a2a3e;">
        <h3 style="margin:0 0 8px;color:#94a3b8;font-size:13px;">${escapeHtml(PL.paymentInfo)}</h3>
        <p style="margin:0;color:#cbd5e1;font-size:13px;white-space:pre-line;">${escapeHtml(settings.paymentInstructions)}</p>
      </div>` : '';

  const html = `<!DOCTYPE html>
<html lang="${portalLang}" dir="${portalIsAr ? 'rtl' : 'ltr'}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${escapeHtml(displayName)} — Client Portal — ${escapeHtml(bizName)}</title>
  <style>
    * { box-sizing: border-box; }
    body { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; background:#0f0f0f; color:#e2e8f0; margin:0; padding:20px; }
    .header { background:linear-gradient(135deg,#1e1e3f,#2d2d5a); padding:24px 28px; border-radius:12px; margin-bottom:20px; }
    h1 { margin:0 0 4px; font-size:1.4rem; color:#a78bfa; }
    .subtitle { color:#94a3b8; font-size:13px; }
    .stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; margin-bottom:20px; }
    .stat-card { background:#1a1a2e; border:1px solid #2a2a3e; border-radius:8px; padding:14px 16px; }
    .stat-val { font-size:1.5rem; font-weight:700; color:#a78bfa; }
    .stat-lbl { font-size:11px; color:#64748b; margin-top:2px; }
    table { width:100%; border-collapse:collapse; background:#111; border-radius:8px; overflow:hidden; }
    th { padding:10px 8px; text-align:left; font-size:11px; color:#64748b; border-bottom:1px solid #2a2a2a; }
    @media(max-width:600px){ td,th { padding:6px 4px; font-size:11px; } }
  </style>
</head>
<body>
  <div class="header">
    <h1>${escapeHtml(bizName)}</h1>
    <div class="subtitle">${escapeHtml(PL.orderPortal)} ${escapeHtml(displayName)}</div>
  </div>
  <div class="stats">
    <div class="stat-card"><div class="stat-val">${activeOrders.length}</div><div class="stat-lbl">${escapeHtml(PL.activeOrders)}</div></div>
    <div class="stat-card"><div class="stat-val">${completedOrders.length}</div><div class="stat-lbl">${escapeHtml(PL.completed)}</div></div>
    <div class="stat-card"><div class="stat-val">${fmtPrice(outstanding)}</div><div class="stat-lbl">${escapeHtml(PL.outstandingBal)}</div></div>
  </div>
  <table>
    <thead><tr>
      <th>${escapeHtml(PL.date)}</th><th>${escapeHtml(PL.project)}</th><th>${escapeHtml(PL.status)}</th><th style="text-align:right;">${escapeHtml(PL.amount)}</th><th style="text-align:center;">${escapeHtml(PL.payment)}</th>
    </tr></thead>
    <tbody>${rowsHtml}</tbody>
  </table>
  ${paymentBlock}
  <p style="text-align:center;color:#374151;font-size:11px;margin-top:24px;">${escapeHtml(PL.generatedBy)} · ${localDateStr()}</p>
</body>
</html>`;

  if (window.hubAPI?.saveHtml) {
    window.hubAPI.saveHtml(html, `client-portal-${c.id}.html`).then(() => {
      toast(t('cl.portal_saved'), 'success');
    }).catch(() => {
      toast(t('cl.portal_save_failed'), 'error');
    });
  } else {
    const blob = new Blob([html], { type: 'text/html' });
    downloadBlob(blob, `client-portal-${c.id}.html`);
    toast(t('cl.portal_saved'), 'info');
  }
}

/* ============================================================
   Marketing campaigns — segment + broadcast over email / SMS
   ============================================================ */
function openCampaignModal() {
  if (typeof KhaytCampaigns === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  const tierOf = (id) => (getClientTier(id) || {}).name || '';
  const tierNames = (settings.loyaltyEnabled ? (settings.loyaltyTiers || []) : []).map((x) => x.name).filter(Boolean);
  const allTags = [...new Set(clients.flatMap((c) => Array.isArray(c.tags) ? c.tags : []))].filter(Boolean);
  const fmtMoney = (n) => (typeof fmtPrice === 'function' ? fmtPrice(n) : String(n));
  const emailReady = (settings.emailConfig?.provider || 'none') !== 'none';
  const smsReady = (settings.smsConfig?.provider || 'none') !== 'none';

  const criteriaFrom = (modal) => {
    const c = {};
    const minS = num(modal.querySelector('#campMinSpend').value, NaN);
    if (!Number.isNaN(minS) && modal.querySelector('#campMinSpend').value !== '') c.minSpend = minS;
    const noOrd = parseInt(modal.querySelector('#campNoOrder').value, 10);
    if (Number.isFinite(noOrd) && modal.querySelector('#campNoOrder').value !== '') c.noOrderDays = noOrd;
    const tag = modal.querySelector('#campTag').value.trim();
    if (tag) c.tag = tag;
    const tier = modal.querySelector('#campTier')?.value || '';
    if (tier) c.tier = tier;
    return c;
  };
  const channelOf = (modal) => modal.querySelector('#campChannel').value;
  const recipientsOf = (modal) => KhaytCampaigns.segmentRecipients(clients, printLog, criteriaFrom(modal), channelOf(modal), Date.now(), { tierOf });

  openFormModal({
    title: `📣 ${t('camp.title') || 'Marketing campaign'}`,
    sizeLg: true,
    saveLabel: t('camp.send') || 'Send',
    bodyHtml: `
      <div class="inline-pair">
        <div><label style="margin-top:0;">${escapeHtml(t('camp.channel') || 'Channel')}</label>
          <select id="campChannel">
            ${emailReady ? `<option value="email">${escapeHtml(t('camp.ch_email') || 'Email')}</option>` : ''}
            ${smsReady ? `<option value="whatsapp">WhatsApp</option><option value="sms">SMS</option>` : ''}
            ${!emailReady && !smsReady ? `<option value="">${escapeHtml(t('camp.no_channel') || 'Configure email or SMS in Settings first')}</option>` : ''}
          </select>
        </div>
        <div><label style="margin-top:0;">${escapeHtml(t('camp.tag') || 'Tag (optional)')}</label>
          <input id="campTag" list="campTagList" placeholder="${escapeHtml(t('camp.any') || 'any')}">
          <datalist id="campTagList">${allTags.map((tg) => `<option value="${escapeHtml(tg)}">`).join('')}</datalist>
        </div>
      </div>
      <div class="inline-pair" style="margin-top:8px;">
        <div><label style="margin-top:0;">${escapeHtml(t('camp.min_spend') || 'Min lifetime spend')}</label>
          <input id="campMinSpend" type="number" min="0" step="1" placeholder="${escapeHtml(t('camp.any') || 'any')}"></div>
        <div><label style="margin-top:0;">${escapeHtml(t('camp.no_order_days') || 'No order in (days)')}</label>
          <input id="campNoOrder" type="number" min="0" step="1" placeholder="${escapeHtml(t('camp.any') || 'any')}"></div>
      </div>
      ${tierNames.length ? `<label style="margin-top:8px;">${escapeHtml(t('camp.tier') || 'Loyalty tier')}</label>
        <select id="campTier"><option value="">${escapeHtml(t('camp.any') || 'any')}</option>${tierNames.map((n) => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join('')}</select>` : ''}
      <label style="margin-top:10px;" id="campSubjLabel">${escapeHtml(t('camp.subject') || 'Subject (email)')}</label>
      <input id="campSubject" maxlength="160" placeholder="${escapeHtml(t('camp.subject_ph') || 'A note from {{name}}…')}">
      <label style="margin-top:8px;">${escapeHtml(t('camp.message') || 'Message')}</label>
      <textarea id="campBody" rows="4" placeholder="${escapeHtml(t('camp.body_ph') || 'Hi {{name}}, …')}"></textarea>
      <p style="font-size:11px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('camp.merge_hint') || 'Merge fields: {{name}} {{orders}} {{spend}} {{last_order}} · opted-out customers are skipped.')}</p>
      <div style="margin-top:8px;font-size:12.5px;"><strong id="campCount">0</strong> ${escapeHtml(t('camp.recipients') || 'recipients')}</div>
      <div id="campPreview" style="margin-top:6px;font-size:12px;color:var(--text-muted);white-space:pre-wrap;"></div>
      <span id="campResult" style="font-size:12px;display:block;margin-top:6px;"></span>`,
    onMount(modal) {
      const refresh = () => {
        const ch = channelOf(modal);
        modal.querySelector('#campSubjLabel').style.display = ch === 'email' ? '' : 'none';
        modal.querySelector('#campSubject').style.display = ch === 'email' ? '' : 'none';
        const recips = ch ? recipientsOf(modal) : [];
        modal.querySelector('#campCount').textContent = recips.length;
        const sample = recips[0];
        modal.querySelector('#campPreview').textContent = sample
          ? (t('camp.preview') || 'Preview') + ' → ' + sample.contact + ':\n' + KhaytCampaigns.fillTemplate(modal.querySelector('#campBody').value, sample, fmtMoney, settings)
          : '';
      };
      // Debounce: segmentation is O(clients × orders), so don't recompute per keystroke.
      let _refreshTimer = null;
      const refreshDebounced = () => { clearTimeout(_refreshTimer); _refreshTimer = setTimeout(refresh, 180); };
      modal.querySelectorAll('#campChannel,#campTag,#campMinSpend,#campNoOrder,#campTier,#campBody').forEach((el) => {
        el.addEventListener('input', refreshDebounced); el.addEventListener('change', refreshDebounced);
      });
      refresh();
    },
    async onSave(modal) {
      const ch = channelOf(modal);
      const res = modal.querySelector('#campResult');
      if (!ch) { res.textContent = '✗ ' + (t('camp.no_channel') || 'Configure email or SMS first'); res.style.color = 'var(--danger)'; return false; }
      const body = modal.querySelector('#campBody').value.trim();
      if (!body) { res.textContent = '✗ ' + (t('camp.need_body') || 'Write a message first'); res.style.color = 'var(--danger)'; return false; }
      const subject = modal.querySelector('#campSubject').value.trim();
      const recips = recipientsOf(modal);
      if (!recips.length) { res.textContent = '✗ ' + (t('camp.none') || 'No recipients match'); res.style.color = 'var(--danger)'; return false; }
      if (!(await confirmModal((t('camp.confirm', { n: recips.length }) || `Send to ${recips.length} customers?`)))) return false;
      let sent = 0, failed = 0;
      const btn = modal.querySelector('.modal-save'); if (btn) btn.disabled = true;
      for (let i = 0; i < recips.length; i++) {
        const r = recips[i];
        res.textContent = `${t('camp.sending') || 'Sending'} ${i + 1}/${recips.length}…`; res.style.color = 'var(--text-muted)';
        const msg = KhaytCampaigns.fillTemplate(body, r, fmtMoney, settings);
        try {
          let ok;
          if (ch === 'email') ok = await window.hubAPI.sendEmail({ to: r.contact, subject: KhaytCampaigns.fillTemplate(subject || 'Khayt', r, fmtMoney, settings), body: msg.replace(/\n/g, '<br>'), smtpConfig: settings.emailConfig });
          else ok = await window.hubAPI.sendSms({ to: r.contact, message: msg, channel: ch, smsConfig: settings.smsConfig });
          (ok && ok.ok) ? sent++ : failed++;
        } catch (e) { failed++; }
        await new Promise((rs) => setTimeout(rs, 350)); // throttle: be gentle on the provider
      }
      // Record the campaign for history.
      settings.campaignLog = (settings.campaignLog || []).slice(-49);
      settings.campaignLog.push({ at: new Date().toISOString(), channel: ch, recipients: recips.length, sent, failed });
      saveAll();
      res.textContent = `✓ ${t('camp.done') || 'Sent'}: ${sent}${failed ? ` · ${failed} ${t('camp.failed') || 'failed'}` : ''}`;
      res.style.color = failed ? 'var(--warning)' : 'var(--success)';
      if (btn) btn.disabled = false;
      return false; // keep open to show the result
    },
  });
}

  const api = {
    getClientStats,
    renderClients,
    quoteForClient,
    generateIntakeForm,
    openClientHistory,
    openClientEditor,
    deleteClient,
    exportClientData,
    checkRecurringOrders,
    checkSubscriptionBilling,
    openSubscriptionsModal,
    renderClientSuggestions,
    hideClientSuggestions,
    getClientTier,
    clientLoyaltyPoints,
    clientLoyaltyRedeemed,
    clientsOverRedeemed,
    clientLoyaltyAvailable,
    redeemLoyaltyPoints,
    exportClientsCsv,
    exportClientPortal,
    clientCompare,
    openCampaignModal,
  };
  if (typeof global.importClientsCsv === 'function') api.importClientsCsv = global.importClientsCsv;
  Object.assign(global, api);
  global.KhaytClients = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
