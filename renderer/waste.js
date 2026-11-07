/**
 * Waste log (failed prints and wasted filament).
 */
let wasteSearchTerm = '';
let wasteMaterialFilter = '';
let wasteFailureFilter = '';
let wasteDateFilter = 'all';
let wasteWhereBy = 'machine';

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

/** lib/failed-print-cost.js, however this file is loaded. */
const FailedCost = () => (typeof globalThis !== 'undefined' && globalThis.KhaytFailedPrintCost)
  || (() => { try { return require('../lib/failed-print-cost.js'); } catch (e) { return null; } })();

/**
 * What a failed attempt is costed from, for lib/failed-print-cost.js — the
 * Mac's `failedCosting`, field for field: the machine, the shop's tariff, how
 * long the attempt ran and how far it got, and what its plug metered.
 *
 * The hours are the PRINTER's when the last print that ended on the job's
 * machine was this job's; else the job's actual time for an inspected print
 * (it ran to the end); else the rule scales the estimate by the progress at
 * failure — 100% for an inspected print.
 *
 * The energy: an inspected print finished, so its reading is already on the
 * job and that one wins — a kept attempt for the same job is an EARLIER
 * stopped print, and costing the whole failed print at the stopped one's
 * reading under-costs it. A stopped print's reading was kept by the meter
 * (`KhaytPrintEnds`, renderer/integrations.js).
 *
 * `spent` is the job whose kept reading this used, for the caller to consume
 * once the waste row is saved.
 */
function failedCostingFor(order, opts) {
  const o = order || {};
  const inspected = !!(opts && opts.inspected);
  const ends = (typeof globalThis !== 'undefined' && globalThis.KhaytPrintEnds) || null;
  const mid = String(o.machineId || '');
  const list = typeof machines !== 'undefined' && Array.isArray(machines) ? machines : [];
  const machine = mid ? list.find((m) => m && m.id === mid) || null : null;
  const lastEnd = ends && mid ? ends.endedFor(mid) : null;
  const ended = lastEnd && lastEnd.orderId === o.id ? lastEnd : null;
  const costing = {};
  if (machine) costing.machine = machine;
  // Only the tariff travels, as on the Mac: a failure is charged what the
  // shop pays for power rather than the built-in default.
  const tariff = typeof settings !== 'undefined' && settings ? settings.elecRate : null;
  if (tariff !== undefined && tariff !== null && tariff !== '') costing.settings = { elecRate: tariff };
  if (ended && ended.durationS > 0) costing.actualHours = ended.durationS / 3600;
  else if (inspected && +o.actualPrintTime > 0) costing.actualHours = +o.actualPrintTime;
  if (inspected) costing.progress = 100;
  else if (ended && ended.progress > 0) costing.progress = ended.progress;
  let spent = null;
  if (inspected && +o.actualEnergyWh > 0) {
    costing.energy = { wh: +o.actualEnergyWh };
    if (o.actualEnergy && o.actualEnergy.coverage !== undefined) costing.energy.coverage = o.actualEnergy.coverage;
  } else {
    const attempt = ends && o.id ? ends.attemptFor(o.id) : null;
    if (attempt) { costing.energy = attempt; spent = o.id; }
  }
  return { costing, spent };
}

/**
 * Write the failed print's machine time and electricity beside its filament
 * on the waste row (`costMachine`, `costPower`, `costFull`, …). `cost` is
 * never changed: it stays the material figure the P&L reads. Returns the job
 * whose kept meter reading was used, or null.
 */
function attachFailedCost(entry, order, opts) {
  const FC = FailedCost();
  if (!FC || !entry || !order) return null;
  const { costing, spent } = failedCostingFor(order, opts);
  FC.attach(entry, order, costing, { machine: costing.machine || null, preset: null, settings: costing.settings || null });
  return spent;
}

/** The waste row is saved: the meter reading it used is spent. */
function spendAttempt(orderId) {
  const ends = (typeof globalThis !== 'undefined' && globalThis.KhaytPrintEnds) || null;
  if (orderId && ends) ends.consumeAttempt(orderId);
}

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
    // The book's whole trade (lib/kpi-rows.js `tradeRevenue`: finished, not
    // voided, not Not business, net of tax) against the whole log, through
    // lib/waste-entry.js `shareOfRevenue` — the Mac's Waste screen asks the
    // same two rules for its period. This divided by every finished job's
    // gross price, voided ones included.
    const completedRevenue = KhaytKpiRows.tradeRevenue({ orders: printLog, settings, clients,
      known: (typeof KhaytCurrencies !== 'undefined' && KhaytCurrencies.CURRENCIES) || undefined });
    const share = WasteEntry.shareOfRevenue(totalWasteCost, completedRevenue);
    const wastePct = share ? share.pct : null;
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
      ${trueCostHtml(wasteFiltered, biz)}
      <div style="display:flex;gap:20px;flex-wrap:wrap;margin-bottom:${ftBars ? '12px' : '0'};">
        <span>${escapeHtml(t('waste.total_entries'))}: <strong>${wasteLog.length}</strong></span>
        <span>${escapeHtml(t('waste.total_weight'))}: <strong>${totalWasteGrams.toFixed(0)}g</strong></span>
        <span>${escapeHtml(t('waste.total_cost'))}: <strong>${fmtPrice(totalWasteCost)}</strong></span>
        ${wastePctHtml}
      </div>
      ${ftBars ? `<div style="margin-top:8px;"><div style="font-size:11.5px;font-weight:600;color:var(--text-muted);margin-bottom:6px;">${escapeHtml(t('waste.failure_breakdown'))}</div>${ftBars}</div>` : ''}
    `;
    statEl.querySelector('#wasteWhereBy')?.addEventListener('change', (e) => {
      wasteWhereBy = e.target.value;
      renderWasteLog();
    });
  }

  // Top orders by waste cost — commerce surface, business modes only
  const topWasteOrdersEl = $('#wasteTopOrdersSection');
  if (topWasteOrdersEl && !biz) {
    topWasteOrdersEl.innerHTML = '';
  } else if (topWasteOrdersEl) {
    // lib/waste-entry.js `topOrders`, the list the Mac shows too.
    const topOrders = WasteEntry.topOrders(wasteLog, 5).map((r) => [r.orderId, r.cost]);
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
    tbody.innerHTML = `<tr><td colspan="10" style="text-align:center; color:var(--text-muted); padding:24px;">${escapeHtml(t('waste.empty'))} <button class="btn small primary" id="btnLogWasteEmpty" style="margin-inline-start:12px;">${escapeHtml(t('waste.add') || 'Log Failed Print')}</button></td></tr>`;
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
      ${breakdownCells(w)}
      <td style="text-align:center;">
        <button class="btn danger small" data-act="del-waste" data-id="${escapeHtml(w.id)}">${escapeHtml(t('common.delete'))}</button>
      </td>
    </tr>`;
  }).join('');
}

/**
 * A row's machine time, electricity and true cost. A dash, not a zero, on a
 * row with no breakdown: a failure logged without a job, or before this
 * existed, was never costed, which is not the same as costing nothing.
 */
function breakdownCells(w) {
  const has = (v) => v !== undefined && v !== null && v !== '' && Number.isFinite(Number(v));
  const cell = (v, title) => `<td class="waste-breakdown" style="text-align:right; font-variant-numeric:tabular-nums; color:var(--text-muted);"${title ? ` title="${escapeHtml(title)}"` : ''}>${has(v) ? fmtPrice(+v) : '—'}</td>`;
  const kwh = has(w.energyWh) && +w.energyWh > 0 ? (+w.energyWh / 1000).toFixed(2) + ' kWh' : '';
  const full = has(w.costFull) ? +w.costFull : (+w.cost || 0);
  return cell(w.costMachine) + cell(w.costPower, kwh)
    + `<td class="waste-full" style="text-align:right; font-variant-numeric:tabular-nums;${has(w.costFull) ? ' font-weight:600;' : ''}">${fmtPrice(full)}</td>`;
}

/**
 * The true cost of the shown failures (KhaytFailedPrintCost.totals) and where
 * it went, by printer, material or customer (`byGroup`, biggest first). The
 * same one definition of the three costs, so the groups add up to the total.
 * Information, not a P&L figure — the note says so in those words. Drawn only
 * once some row carries the breakdown.
 */
function trueCostHtml(rows, biz) {
  const FC = FailedCost();
  if (!FC || !rows.length) return '';
  const tot = FC.totals(rows);
  if (!(tot.costed > 0)) return '';
  const line = (label, value, strong) => `<div style="display:flex;justify-content:space-between;gap:12px;font-size:12.5px;${strong ? 'font-weight:600;' : ''}">
      <span style="color:${strong ? 'var(--text)' : 'var(--text-muted)'};">${escapeHtml(label)}</span><span style="font-variant-numeric:tabular-nums;">${escapeHtml(value)}</span></div>`;
  const by = (wasteWhereBy === 'customer' && !biz) ? 'machine' : wasteWhereBy;
  const groups = FC.byGroup(rows, {
    by,
    orders: printLog,
    machines: typeof machines !== 'undefined' ? machines : [],
    spools: inventory,
    clients: typeof clients !== 'undefined' ? clients : [],
  }).slice(0, 5);
  const options = [['machine', 'waste.by_printer'], ['material', 'waste.by_material']]
    .concat(biz ? [['customer', 'waste.by_customer']] : [])
    .map(([k, w]) => `<option value="${k}"${k === by ? ' selected' : ''}>${escapeHtml(t(w))}</option>`).join('');
  const groupRows = groups.map((g) => line(
    (g.unknown ? t('waste.unknown') : g.label) + ' · ' + t(g.count === 1 ? 'waste.n_failures_one' : 'waste.n_failures', { n: g.count }),
    fmtPrice(g.full))).join('');
  return `
    <div id="wasteTrueCost" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:20px;margin-bottom:14px;padding-bottom:12px;border-bottom:1px solid var(--border-soft);">
      <div>
        <div style="font-size:11.5px;font-weight:600;color:var(--text-muted);margin-bottom:6px;">${escapeHtml(t('waste.true_title'))}</div>
        ${line(t('waste.filament'), fmtPrice(tot.material))}
        ${line(t('waste.machine'), fmtPrice(tot.machine))}
        ${line(t('waste.power'), fmtPrice(tot.power))}
        ${tot.energyWh > 0 ? line(t('waste.energy'), (tot.energyWh / 1000).toFixed(2) + ' kWh') : ''}
        ${line(t('waste.full'), fmtPrice(tot.full), true)}
        <p style="font-size:11px;color:var(--text-muted);margin:6px 0 0;">${escapeHtml(t('waste.true_note'))}</p>
        ${tot.costed < rows.length ? `<p style="font-size:11px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('waste.true_older'))}</p>` : ''}
      </div>
      <div id="wasteWhere">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px;">
          <span style="font-size:11.5px;font-weight:600;color:var(--text-muted);">${escapeHtml(t('waste.where_title'))}</span>
          <select id="wasteWhereBy" style="width:auto;font-size:12px;padding:2px 6px;">${options}</select>
        </div>
        ${groupRows}
      </div>
    </div>`;
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
    `<option value="${escapeHtml(o.id)}">${escapeHtml(jobRef(o))} — ${escapeHtml(o.project || '')}</option>`
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
        ${activeMachines().map(m => `<option value="${escapeHtml(m.id)}">${escapeHtml(m.name)}</option>`).join('')}
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
      const ref = String(made.entry.orderId || '').trim();
      const job = ref ? printLog.find((o) => o && o.id === ref) : null;
      const spent = job ? attachFailedCost(made.entry, job, { inspected: false }) : null;
      wasteLog.unshift(made.entry);

      saveAll();
      spendAttempt(spent);
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
      <p style="font-size:12.5px;color:var(--text-muted);margin:0 0 12px;">${escapeHtml(jobRef(order))} — ${escapeHtml(order.project || '')}</p>
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
      const spent = attachFailedCost(made.entry, order, { inspected: false });
      wasteLog.unshift(made.entry);
      saveAll();
      spendAttempt(spent);
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
    failedCostingFor,
    attachFailedCost,
    spendAttempt,
  };
  Object.assign(global, api);
  global.KhaytWaste = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
