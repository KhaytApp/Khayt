/**
 * Waste log (failed prints and wasted filament).
 */
let wasteSearchTerm = '';
let wasteMaterialFilter = '';
let wasteFailureFilter = '';
let wasteDateFilter = 'all';

(function (global) {
/** The rule, however this file happens to be loaded — a script tag in the
 *  window, or `require` in a test. */
const WasteEntry = (typeof globalThis !== 'undefined' && globalThis.KhaytWasteEntry)
  || (() => { try { return require('../lib/waste-entry.js'); } catch (e) { return null; } })();

/* ============================================================
   Waste Log (failed prints & wasted filament)
   ============================================================ */
// The list is lib/waste-entry.js's, so both apps label a failure the same way.
const WASTE_FAILURE_TYPES = WasteEntry.FAILURE_TYPES;

function renderWasteLog() {
  const tbody = document.querySelector('#wasteTable tbody');
  if (!tbody) return;
  // Enthusiast (hobbyist) mode has no revenue/customer orders — hide the % -of-revenue stat and the per-order table.
  const biz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : settings.mode !== 'enthusiast';

  const wasteFiltered = wasteLog.filter(w => {
    if (wasteMaterialFilter && w.material !== wasteMaterialFilter) return false;
    if (wasteFailureFilter && w.failureType !== wasteFailureFilter) return false;
    if (wasteSearchTerm) {
      const hay = [w.material || '', w.reason || '', w.failureType || ''].join(' ').toLowerCase();
      if (!hay.includes(wasteSearchTerm.toLowerCase())) return false;
    }
    if (wasteDateFilter !== 'all') {
      if (!inRange(w.date, wasteDateFilter, 'waste')) return false;
    }
    return true;
  });
  const sorted = [...wasteFiltered].sort((a, b) => (b.date || '').localeCompare(a.date || ''));
  const totalWasteCost = wasteLog.reduce((s, w) => s + (+w.cost || 0), 0);
  const totalWasteGrams = wasteLog.reduce((s, w) => s + (+w.weight || 0), 0);

  // Failure type breakdown
  const ftCounts = {};
  wasteLog.forEach(w => { const ft = w.failureType || 'other'; ftCounts[ft] = (ftCounts[ft] || 0) + 1; });

  const statEl = $('#wasteStats');
  // QW9: Populate waste filter dropdowns
  const wasteMaterialSel = $('#wasteMaterialFilter');
  if (wasteMaterialSel) {
    const mats = [...new Set(wasteLog.map(w => w.material).filter(Boolean))].sort();
    wasteMaterialSel.innerHTML = `<option value="">${escapeHtml(t('common.all') || 'All materials')}</option>` +
      mats.map(m => `<option value="${escapeHtml(m)}"${m === wasteMaterialFilter ? ' selected' : ''}>${escapeHtml(m)}</option>`).join('');
  }
  const wasteFailureSel = $('#wasteFailureFilter');
  if (wasteFailureSel) {
    wasteFailureSel.innerHTML = `<option value="">${escapeHtml(t('common.all') || 'All failure types')}</option>` +
      WASTE_FAILURE_TYPES.map(ft => `<option value="${escapeHtml(ft)}"${ft === wasteFailureFilter ? ' selected' : ''}>${escapeHtml(t('waste.ft.' + ft))}</option>`).join('');
  }
  if (statEl) {
    const completedRevenue = printLog.filter(o => o.status === 'completed').reduce((s, o) => s + orderNetRevenueBase(o), 0);
    const wastePct = completedRevenue > 0 ? (totalWasteCost / completedRevenue * 100) : null;
    const maxFt = Object.values(ftCounts).reduce((a, b) => Math.max(a, b), 1);
    const ftBars = WASTE_FAILURE_TYPES.filter(ft => ftCounts[ft] > 0).sort((a, b) => (ftCounts[b] || 0) - (ftCounts[a] || 0)).map(ft => {
      const pct = ((ftCounts[ft] || 0) / maxFt * 100).toFixed(1);
      return `<div style="display:flex;align-items:center;gap:8px;margin-bottom:4px;font-size:12px;">
        <span style="width:130px;color:var(--text-muted);text-align:end;">${escapeHtml(t('waste.ft.' + ft))}</span>
        <div style="flex:1;background:rgba(255,255,255,0.08);border-radius:3px;height:8px;"><div style="background:var(--danger);width:${pct}%;height:100%;border-radius:3px;opacity:0.75;"></div></div>
        <span style="width:24px;text-align:start;">${ftCounts[ft]}</span>
      </div>`;
    }).join('');
    const wastePctHtml = (biz && wastePct !== null)
      ? `<span>${escapeHtml(t('waste.pct_revenue'))}: <strong style="color:${wastePct > 5 ? 'var(--danger)' : wastePct > 2 ? 'var(--warning)' : 'var(--success)'};">${wastePct.toFixed(1)}%</strong></span>`
      : '';
    statEl.innerHTML = `
      <div style="display:flex;gap:20px;flex-wrap:wrap;margin-bottom:${ftBars ? '12px' : '0'};">
        <span>${escapeHtml(t('waste.total_entries'))}: <strong>${wasteLog.length}</strong></span>
        <span>${escapeHtml(t('waste.total_weight'))}: <strong>${totalWasteGrams.toFixed(0)}g</strong></span>
        <span>${escapeHtml(t('waste.total_cost'))}: <strong>${fmtPrice(totalWasteCost)}</strong></span>
        ${wastePctHtml}
      </div>
      ${ftBars ? `<div style="margin-top:8px;"><div style="font-size:11.5px;font-weight:600;color:var(--text-muted);margin-bottom:6px;">${escapeHtml(t('waste.failure_breakdown'))}</div>${ftBars}</div>` : ''}
    `;
  }

  // Top orders by waste cost — commerce surface, business modes only
  const topWasteOrdersEl = $('#wasteTopOrdersSection');
  if (topWasteOrdersEl && !biz) {
    topWasteOrdersEl.innerHTML = '';
  } else if (topWasteOrdersEl) {
    const orderWaste = {};
    for (const w of wasteLog) {
      if (!w.orderId) continue;
      if (!orderWaste[w.orderId]) orderWaste[w.orderId] = 0;
      orderWaste[w.orderId] += (+w.cost || 0);
    }
    const topOrders = Object.entries(orderWaste)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5);
    if (topOrders.length === 0) {
      topWasteOrdersEl.innerHTML = '';
    } else {
      const order_rows = topOrders.map(([oid, cost]) => {
        const ord = printLog.find(o => o.id === oid);
        return `<tr>
          <td style="font-size:12px; color:var(--text-dim);">${escapeHtml(oid)}</td>
          <td>${escapeHtml(ord ? (ord.project || '') : '—')}</td>
          <td style="color:var(--danger); font-variant-numeric:tabular-nums; text-align:right;">${fmtPrice(cost)}</td>
        </tr>`;
      }).join('');
      topWasteOrdersEl.innerHTML = `
        <div style="margin-top:16px; padding-top:12px; border-top:1px solid var(--border-soft);">
          <label style="margin-top:0; font-size:12px; font-weight:600; color:var(--text-muted);">${escapeHtml(t('waste.top_orders'))}</label>
          <div class="table-wrap" style="margin-top:6px;"><table style="width:100%;">
            <thead><tr>
              <th>${escapeHtml(t('log.order_id'))}</th>
              <th>${escapeHtml(t('ord.project'))}</th>
              <th style="text-align:right;">${escapeHtml(t('waste.est_cost'))}</th>
            </tr></thead>
            <tbody>${order_rows}</tbody>
          </table></div>
        </div>`;
    }
  }

  if (sorted.length === 0) {
    tbody.innerHTML = `<tr><td colspan="7" style="text-align:center; color:var(--text-muted); padding:24px;">${escapeHtml(t('waste.empty'))} <button class="btn small primary" id="btnLogWasteEmpty" style="margin-inline-start:12px;">${escapeHtml(t('waste.add') || 'Log Failed Print')}</button></td></tr>`;
    // Wire up the CTA
    document.querySelector('#btnLogWasteEmpty')?.addEventListener('click', () => document.querySelector('#btnLogWaste')?.click());
    return;
  }

  tbody.innerHTML = sorted.map(w => {
    const ftLabel = w.failureType ? `<span class="waste-ft-badge">${escapeHtml(t('waste.ft.' + w.failureType))}</span>` : '';
    return `
    <tr>
      <td>${escapeHtml(w.date || '')}</td>
      <td>${escapeHtml(w.material || '—')}</td>
      <td style="text-align:center;">${escapeHtml(String(w.weight || 0))}g</td>
      <td>${ftLabel}</td>
      <td>${escapeHtml(w.reason || '—')}</td>
      <td style="text-align:right; font-variant-numeric:tabular-nums;">${fmtPrice(+w.cost || 0)}</td>
      <td style="text-align:center;">
        <button class="btn danger small" data-act="del-waste" data-id="${escapeHtml(w.id)}">${escapeHtml(t('common.delete'))}</button>
      </td>
    </tr>`;
  }).join('');
}

function openWasteForm() {
  const today = localDateStr();
  const invOptions = inventory.map(f =>
    `<option value="${escapeHtml(f.material)}">${escapeHtml(f.material)}</option>`
  ).join('');
  const failureOptions = WASTE_FAILURE_TYPES.map(ft =>
    `<option value="${ft}">${escapeHtml(t('waste.ft.' + ft))}</option>`
  ).join('');
  const recentOrderOptions = printLog.slice(0, 60).map(o =>
    `<option value="${escapeHtml(o.id)}">${escapeHtml(o.id)} — ${escapeHtml(o.project || '')}</option>`
  ).join('');

  openFormModal({
    title: t('waste.add'),
    saveLabel: t('waste.log_btn'),
    bodyHtml: `
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:12px;">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('waste.date'))}</label>
          <input type="date" id="wf_date" value="${today}" max="${today}">
        </div>
        <div>
          <label style="margin-top:0;">${escapeHtml(t('waste.material'))}</label>
          <select id="wf_material">${invOptions || '<option value="">—</option>'}</select>
        </div>
      </div>
      <label style="margin-top:12px;">${escapeHtml(t('waste.failure_type'))}</label>
      <select id="wf_failure_type">${failureOptions}</select>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:12px;">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('waste.weight'))} (g)</label>
          <input type="number" id="wf_weight" value="0" min="0" step="1">
        </div>
        <div>
          <label style="margin-top:0;">${escapeHtml(t('waste.est_cost'))} (${currencySymbol()})</label>
          <input type="number" id="wf_cost" value="0" min="0" step="0.01">
        </div>
      </div>
      <label style="margin-top:12px;">${escapeHtml(t('waste.reason'))}</label>
      <input type="text" id="wf_reason" placeholder="${escapeHtml(t('waste.reason_ph'))}">
      <label style="margin-top:12px;">${escapeHtml(t('waste.order_ref'))}</label>
      <input type="text" id="wf_order_ref" list="wasteOrderList" placeholder="${escapeHtml(t('waste.order_ref'))}">
      <datalist id="wasteOrderList">${recentOrderOptions}</datalist>
      <label style="margin-top:12px;">${escapeHtml(t('waste.notes'))}</label>
      <textarea id="wf_notes" rows="2" style="resize:vertical;"></textarea>
      <label style="margin-top:12px;">${escapeHtml(t('waste.printer') || 'Printer / Machine')}</label>
      <select id="wf_machine">
        <option value="">${escapeHtml(t('mach.unassigned') || '— Unassigned —')}</option>
        ${machines.map(m => `<option value="${escapeHtml(m.id)}">${escapeHtml(m.name)}</option>`).join('')}
      </select>
      <label style="display:flex; align-items:center; gap:8px; cursor:pointer; margin-top:14px;">
        <input type="checkbox" id="wf_deduct" checked style="width:auto; margin:0;">
        <span>${escapeHtml(t('waste.deduct_inv'))}</span>
      </label>
    `,
    onMount(modal) {
      // Auto-calculate cost when material or weight changes
      const autoCalcCost = () => {
        const mat = modal.querySelector('#wf_material')?.value;
        const wt  = Math.max(0, +modal.querySelector('#wf_weight')?.value || 0);
        if (!mat || wt <= 0) return;
        // Net of reclaimable tax, like every other cost: a registered shop
        // gets the tax on the roll back, so that is not what the plastic cost.
        const profile = (typeof KhaytTax !== 'undefined' && typeof settings !== 'undefined')
          ? KhaytTax.profileFromSettings(settings) : null;
        const reclaims = !!(profile && profile.rates && profile.rates.length);
        const cost = WasteEntry.costOf(mat, wt, inventory, reclaims);
        const costEl = modal.querySelector('#wf_cost');
        if (cost > 0 && costEl) costEl.value = cost.toFixed(2);
      };
      modal.querySelector('#wf_material')?.addEventListener('change', autoCalcCost);
      modal.querySelector('#wf_weight')?.addEventListener('input', autoCalcCost);
    },
    onSave() {
      // The entry is lib/waste-entry.js's — the same record the Mac app writes,
      // and the one that remembers which spool it deducted from, so deleting
      // it can put the grams back. This handler deducted and never said which.
      const made = WasteEntry.newEntry({
        date:        $('#wf_date').value || today,
        material:    $('#wf_material').value,
        failureType: $('#wf_failure_type').value,
        weight:      $('#wf_weight').value,
        cost:        $('#wf_cost').value,
        reason:      $('#wf_reason').value,
        notes:       $('#wf_notes').value,
        orderId:     $('#wf_order_ref').value,
        machineId:   $('#wf_machine')?.value,
        deduct:      $('#wf_deduct').checked,
      }, { id: 'w-' + Date.now().toString(36), today, inventory });
      if (made.refused) { toast(t('waste.err_material'), 'error'); return false; }
      wasteLog.unshift(made.entry);

      saveAll();
      renderWasteLog();
      if (document.querySelector('#inventory-tab.active')) renderInventory();
      toast(t('waste.saved'), 'success');
    }
  });
}

function openLogWasteFromCard(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  // What the printer got through before it stopped, where one measured it.
  const measuredForCard = (typeof measuredWasteFor === 'function') ? measuredWasteFor(order) : null;
  // Pre-fill material from first part with material data
  const firstPart = (order.parts || []).find(p => p.material);
  const defaultMaterial = firstPart?.material || order.material || '';
  const invOptions = inventory.map(f =>
    `<option value="${escapeHtml(f.material)}"${f.material === defaultMaterial ? ' selected' : ''}>${escapeHtml(f.material)}</option>`
  ).join('');
  const failureOptions = WASTE_FAILURE_TYPES.map(ft =>
    `<option value="${ft}">${escapeHtml(t('waste.ft.' + ft))}</option>`
  ).join('');

  openFormModal({
    title: t('waste.log_from_card'),
    saveLabel: t('waste.log_btn'),
    sizeLg: false,
    bodyHtml: `
      <p style="font-size:12.5px;color:var(--text-muted);margin:0 0 12px;">${escapeHtml(order.id)} — ${escapeHtml(order.project || '')}</p>
      <label>${escapeHtml(t('waste.material'))}</label>
      <select id="wfc_material">${invOptions || `<option value="">${escapeHtml(defaultMaterial)}</option>`}</select>
      <label style="margin-top:12px;">${escapeHtml(t('waste.weight_g'))}</label>
      <input type="number" id="wfc_weight" value="${measuredForCard ? measuredForCard.grams : 0}" min="0" step="1">
      <div style="font-size:11px;color:var(--text-muted);margin-top:3px;">${escapeHtml(
        measuredForCard
          ? (t('qc.weight_measured', { source: measuredForCard.source || 'printer' })
             || `Measured by ${measuredForCard.source || 'your printer'}.`)
          : (t('qc.weight_typed') || 'The filament comes off the shelf.'))}</div>
      <label style="margin-top:12px;">${escapeHtml(t('waste.failure_type'))}</label>
      <select id="wfc_failure_type">${failureOptions}</select>
      <label style="margin-top:12px;">${escapeHtml(t('waste.notes'))}</label>
      <textarea id="wfc_notes" rows="2" style="resize:vertical;"></textarea>
    `,
    onSave() {
      // The entry is lib/waste-entry.js's `forOrder`, which takes the grams off
      // the spools THIS JOB was printing from — the same claims a completion
      // would settle. Logging waste against a job used to record it and take
      // nothing off the shelf at all, so the stock read high by every one.
      const made = WasteEntry.forOrder(order, {
        material:    $('#wfc_material').value,
        weight:      $('#wfc_weight').value,
        failureType: $('#wfc_failure_type').value,
        notes:       $('#wfc_notes').value,
      }, {
        id: uid('W'),
        today: localDateStr(),
        inventory,
        settings,
        machines: typeof machines !== 'undefined' ? machines : [],
      });
      if (made.refused) { toast(t('waste.err_material'), 'error'); return false; }
      wasteLog.unshift(made.entry);
      saveAll();
      renderWasteLog();
      if (typeof renderInventory === 'function') renderInventory();
      toast(t('waste.saved'), 'success');
      return true;
    }
  });
}

async function deleteWasteEntry(id) {
  const ok = await confirmModal(t('common.delete') + '?', { danger: true });
  if (!ok) return;
  // Takes the entry out and puts its grams back on the spool it came off.
  if (!WasteEntry.removeEntry(wasteLog, id, { inventory })) return;
  saveAll();
  renderWasteLog();
  renderInventory();
  toast(t('waste.deleted'), 'success');
}
  const api = {
    renderWasteLog,
    openWasteForm,
    openLogWasteFromCard,
    deleteWasteEntry,
  };
  Object.assign(global, api);
  global.KhaytWaste = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
