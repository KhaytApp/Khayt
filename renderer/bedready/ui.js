/* Bed Ready UI layer — filters, calculator layout, inventory screens.
 *
 * Was renderer/studio/, and was a Khayt design theme until 3.3. Nothing in Khayt
 * reaches it any more: it is loaded only by bedready.html and gated on a single
 * body class. Khayt's shared renderers still call through `KhaytBedReadyUI?.x?.()`,
 * which is simply undefined there, so those hooks no-op.
 *
 * `isStudio()` and `useHandoffScreens()` used to test two different classes
 * (khayt-studio, khayt-handoff). Once studio became the last handoff shell the
 * two could never disagree, so they are one class and one predicate now.
 */
(function () {
  const PREF = 'khayt_studio_';   // storage key kept — renaming it would orphan user prefs

  function isBedReadyUI() {
    return document.body.classList.contains('bedready-ui');
  }
  const useHandoffScreens = isBedReadyUI;

  function prefGet(key, fallback) {
    try {
      const v = localStorage.getItem(PREF + key);
      return v != null && v !== '' ? v : fallback;
    } catch {
      return fallback;
    }
  }

  function prefSet(key, value) {
    try {
      localStorage.setItem(PREF + key, value == null ? '' : String(value));
    } catch { /* ignore */ }
  }

  let studioQueueFilter = prefGet('queue_filter', 'all');
  let studioQueueMachineId = prefGet('queue_machine', '');
  let studioClientFilter = prefGet('client_filter', 'all');


  function machineIsResin(m) {
    if (!m) return false;
    const t = String(m.type || m.materialType || '').toLowerCase();
    return t.includes('resin') || t === 'sla' || t === 'msla';
  }

  function orderUsesResin(log) {
    if (log.isResin) return true;
    if (String(log.material || '').toLowerCase().includes('resin')) return true;
    for (const p of (log.parts || [])) {
      if (p.filamentId) {
        const inv = inventory.find(i => i.id === p.filamentId);
        if (inv?.materialType === 'resin') return true;
      }
      if (String(p.material || '').toLowerCase().includes('resin')) return true;
    }
    if (log.machineId) {
      const m = machines.find(x => x.id === log.machineId);
      if (machineIsResin(m)) return true;
    }
    return false;
  }

  function orderMatchesStudioQueueFilter(log) {
    const f = studioQueueFilter || 'all';
    if (f === 'all') return true;
    if (f === 'fdm') return !orderUsesResin(log);
    if (f === 'resin') return orderUsesResin(log);
    if (f === 'machine') {
      if (studioQueueMachineId) return log.machineId === studioQueueMachineId;
      return !!log.machineId;
    }
    return true;
  }

  function syncQueueMachinePicker() {
    const wrap = $('#studioQueueMachineWrap');
    const sel = $('#studioQueueMachine');
    if (!wrap || !sel) return;
    const show = studioQueueFilter === 'machine';
    wrap.style.display = show ? '' : 'none';
    wrap.setAttribute('aria-hidden', show ? 'false' : 'true');
    if (!show) return;
    const prev = studioQueueMachineId;
    sel.innerHTML =
      `<option value="">${escapeHtml(t('queue.filter_machine_all') || 'All assigned printers')}</option>` +
      machines.map(m =>
        `<option value="${escapeHtml(m.id)}"${m.id === prev ? ' selected' : ''}>${escapeHtml(m.name)}</option>`
      ).join('');
  }

  function wireStudioQueueFilters() {
    const seg = $('#studioQueueSeg');
    if (!seg || seg.dataset.wired === '1') return;
    seg.dataset.wired = '1';
    seg.querySelectorAll('[data-queue-filter]').forEach(btn => {
      const f = btn.dataset.queueFilter || 'all';
      btn.classList.toggle('on', f === studioQueueFilter);
      btn.addEventListener('click', () => {
        studioQueueFilter = btn.dataset.queueFilter || 'all';
        prefSet('queue_filter', studioQueueFilter);
        seg.querySelectorAll('button').forEach(b => b.classList.toggle('on', b === btn));
        syncQueueMachinePicker();
        renderKanban();
      });
    });
    $('#studioQueueMachine')?.addEventListener('change', (e) => {
      studioQueueMachineId = e.target.value || '';
      prefSet('queue_machine', studioQueueMachineId);
      renderKanban();
    });
    syncQueueMachinePicker();
  }


  function wireCalcTechSeg() {
    const seg = $('#calcTechSeg');
    if (!seg || seg.dataset.wired === '1') return;
    seg.dataset.wired = '1';
    const syncFromFilament = () => {
      const fid = $('#filamentSelect')?.value;
      const inv = fid ? inventory.find(i => i.id === fid) : null;
      const isResin = inv?.materialType === 'resin';
      seg.querySelectorAll('button').forEach(b => {
        b.classList.toggle('on', (b.dataset.calcTech === 'resin') === !!isResin);
      });
    };
    seg.querySelectorAll('[data-calc-tech]').forEach(btn => {
      btn.addEventListener('click', () => {
        const isResin = btn.dataset.calcTech === 'resin';
        seg.querySelectorAll('button').forEach(b => b.classList.toggle('on', b === btn));
        const sel = $('#filamentSelect');
        if (!sel) return;
        const match = [...sel.options].find(o => {
          const id = o.value;
          const inv = inventory.find(i => i.id === id);
          return inv && (inv.materialType === 'resin') === isResin;
        });
        if (match) {
          sel.value = match.value;
          sel.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (typeof handleFilamentChange === 'function') {
          handleFilamentChange();
        }
      });
    });
    $('#filamentSelect')?.addEventListener('change', syncFromFilament);
    syncFromFilament();
  }

  function initStudioCalculatorLayout() {
    const tab = $('#calculator-tab');
    if (!tab || !useHandoffScreens()) return;
    if (tab.querySelector('.khayt-calc-layout')) return;
    const grid = tab.querySelector('.grid');
    if (!grid) return;
    const cards = [...grid.querySelectorAll(':scope > .card')];
    const material = cards.find(c => c.classList.contains('material'));
    const machine = cards.find(c => c.classList.contains('machine'));
    const labor = cards.find(c => c.classList.contains('labor'));
    const summary = cards.find(c => c.classList.contains('summary'));
    if (!summary) return;

    const layout = document.createElement('div');
    layout.className = 'grid khayt-calc-layout';
    const formCol = document.createElement('div');
    formCol.className = 'khayt-calc-form';
    const asideCol = document.createElement('div');
    asideCol.className = 'khayt-calc-aside';
    [material, machine, labor].filter(Boolean).forEach(c => formCol.appendChild(c));
    summary.classList.add('khayt-calc-summary');
    asideCol.appendChild(summary);
    layout.appendChild(formCol);
    layout.appendChild(asideCol);
    grid.replaceWith(layout);
    wireCalcTechSeg();
    ensureCalcStudioPanel();
  }

  const BD_COLORS = {
    material: 'var(--accent)',
    machine: 'var(--info, #38bdf8)',
    labor: 'var(--violet, #a78bfa)',
    buffer: 'var(--warn)',
  };

  function ensureCalcStudioPanel() {
    if (!useHandoffScreens()) return;
    const summary = document.querySelector('#calculator-tab .card.summary');
    if (!summary || summary.querySelector('#calcStudioBreakdown')) return;
    const liveLine = summary.querySelector('.live-line');
    const bdLegacy = $('#costBreakdown');
    if (bdLegacy) bdLegacy.classList.add('khayt-bd-legacy-hidden');

    const panel = document.createElement('div');
    panel.id = 'calcStudioBreakdown';
    panel.className = 'khayt-calc-breakdown';
    panel.setAttribute('aria-live', 'polite');
    panel.innerHTML = `
      <div class="khayt-calc-breakdown-head">
        <span class="sec-title" data-i18n="calc.breakdown_title">Live cost breakdown</span>
        <span class="khayt-calc-breakdown-live" data-i18n="calc.breakdown_live">live</span>
      </div>
      <div class="khayt-calc-breakdown-body">
        <div class="khayt-donut-wrap">
          <div id="calcDonutHost"></div>
          <div class="khayt-donut-center">
            <div class="col" style="align-items:center;gap:2px">
              <span class="mono" style="font-size:9.5px;color:var(--text-muted)">COST</span>
              <span class="metric" id="calcDonutTotal">0</span>
              <span class="mono" id="calcDonutCur" style="font-size:9px;color:var(--text-muted)"></span>
            </div>
          </div>
        </div>
        <div class="khayt-calc-legend" id="calcBreakdownLegend"></div>
      </div>
      <div class="khayt-calc-margin-strip" id="calcMarginStrip"></div>`;

    if (liveLine && liveLine.nextSibling) {
      summary.insertBefore(panel, liveLine.nextSibling);
    } else {
      summary.prepend(panel);
    }
    if (typeof i18n !== 'undefined' && i18n.apply) i18n.apply(panel);
  }

  function updateCalcBreakdown(bd, opts) {
    if (!useHandoffScreens()) return;
    ensureCalcStudioPanel();
    const panel = $('#calcStudioBreakdown');
    const host = $('#calcDonutHost');
    const legend = $('#calcBreakdownLegend');
    const strip = $('#calcMarginStrip');
    if (!panel || !host || !legend) return;

    const items = [
      { key: 'material', label: t('calc.bd.material'), val: bd.material, color: BD_COLORS.material },
      { key: 'machine', label: t('calc.bd.machine'), val: bd.machine, color: BD_COLORS.machine },
      { key: 'labor', label: t('calc.bd.labor'), val: bd.labor, color: BD_COLORS.labor },
      { key: 'buffer', label: t('calc.bd.buffer'), val: bd.buffer, color: BD_COLORS.buffer },
    ].filter(x => x.val >= 0.01);

    const total = items.reduce((s, x) => s + x.val, 0);
    const cur = opts?.currency || settings.currency || 'SAR';

    if (items.length === 0 || total < 0.01) {
      panel.style.display = 'none';
      return;
    }
    panel.style.display = '';

    const segments = items.map(x => ({ pct: x.val, color: x.color }));
    host.innerHTML = window.KhaytCharts?.donutSvg?.(segments, 128, 17) || '';

    const totalEl = $('#calcDonutTotal');
    const curEl = $('#calcDonutCur');
    if (totalEl) totalEl.textContent = Math.round(total).toLocaleString();
    if (curEl) curEl.textContent = cur;

    legend.innerHTML = items.map(x => `
      <div class="khayt-calc-legend-row">
        <span class="row gap8" style="white-space:nowrap">
          <span class="dot" style="background:${x.color}"></span>
          ${escapeHtml(x.label)}
        </span>
        <span class="metric">${escapeHtml(fmtMoney(x.val))}</span>
      </div>`).join('');

    const scopeLabel = opts?.breakdownScope === 'cart'
      ? (t('calc.breakdown_cart') || 'Project breakdown')
      : (t('calc.breakdown_live') || 'Live part');
    const scopeEl = panel.querySelector('.khayt-calc-breakdown-live');
    if (scopeEl) scopeEl.textContent = scopeLabel;

    if (strip && opts) {
      const margin = opts.margin ?? 0;
      const priced = total * (1 + margin / 100);
      // Enthusiast (hobbyist) mode has no selling price — show COST only, hide
      // margin %, the at-margin sell price and the project total.
      const biz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : (typeof settings === 'undefined' || settings.mode !== 'enthusiast');
      strip.innerHTML = `
        <span>${escapeHtml(scopeLabel)}</span>
        <span>${escapeHtml(t('calc.breakdown_unit_cost') || 'Unit cost')}: <strong>${escapeHtml(fmtMoney(total))}</strong></span>
        ${biz ? `<span>${escapeHtml(t('calc.quote.margin') || 'Margin')}: <strong>${Math.round(margin)}%</strong></span>
        <span>${escapeHtml(t('calc.breakdown_at_margin') || 'At margin')}: <strong>${escapeHtml(fmtMoney(priced))}</strong></span>
        ${opts.finalPrice != null ? `<span>${escapeHtml(t('calc.quote.total') || 'Project total')}: <strong>${escapeHtml(fmtMoney(opts.finalPrice))}</strong></span>` : ''}` : ''}`;
    }
  }

  function patchInventoryTableHead() {
    if (!useHandoffScreens()) return;
    const table = $('#inventoryTable');
    if (!table) return;
    table.classList.add('tbl');
    const thead = table.querySelector('thead tr');
    if (!thead || thead.dataset.studioHead === '1') return;
    thead.dataset.studioHead = '1';
    thead.innerHTML = `
      <th data-i18n="inv.material">Material</th>
      <th data-i18n="inv.material_type">Type</th>
      <th data-i18n="inv.col_stock">Stock level</th>
      <th data-i18n="inv.col_spools">Spools</th>
      <th data-i18n="inv.col_unit_price">Unit price</th>
      <th data-i18n="common.actions">Actions</th>`;
    if (typeof i18n !== 'undefined' && i18n.apply) i18n.apply(thead);
  }

  function invDryingBadgeHtml(item) {
    const mat = (item.material || '').toLowerCase();
    const isHygroscopic = ['nylon', 'pa', 'tpu', 'tpe', 'pva', 'petg'].some(h => mat.includes(h));
    if (!isHygroscopic) return '';
    const dryLog = item.dryingLog || [];
    if (dryLog.length === 0) {
      return `<span class="drying-warn-badge" title="${escapeHtml(t('inv.dry_log'))}">⚠ ${escapeHtml(t('inv.dry_warn'))}</span>`;
    }
    const lastDry = [...dryLog].sort((a, b) => (b.date || '').localeCompare(a.date || ''))[0];
    const daysSince = lastDry.date ? Math.floor((Date.now() - new Date(lastDry.date + 'T00:00:00').getTime()) / 86400000) : 999;
    if (daysSince > 7) {
      return `<span class="drying-warn-badge">⚠ ${escapeHtml(t('inv.dry_warn'))}</span>`;
    }
    return `<span class="drying-ok-badge">✅ ${escapeHtml(t('inv.dry_ok', { n: daysSince }))}</span>`;
  }

  function invActionsHtml(item, low) {
    return `
      ${invDryingBadgeHtml(item)}
      ${low ? `<button type="button" class="btn sm" data-act="reorder-inv" data-id="${item.id}" style="color:var(--warn);border-color:var(--warn)">${escapeHtml(t('inv.reorder'))}</button>` : ''}
      <button type="button" class="btn sm ghost" data-act="inv-test-print" data-id="${item.id}" title="${escapeHtml(t('inv.test_prints'))}" aria-label="${escapeHtml(t('inv.test_prints'))}"><span aria-hidden="true">🧪</span></button>
      <button type="button" class="btn sm ghost" data-act="inv-dry-log" data-id="${item.id}" title="${escapeHtml(t('inv.dry_log'))}" aria-label="${escapeHtml(t('inv.dry_log'))}"><span aria-hidden="true">🌡</span></button>
      <button type="button" class="btn sm ghost" data-act="inv-spool-history" data-id="${item.id}" title="${escapeHtml(t('inv.spool_history'))}" aria-label="${escapeHtml(t('inv.spool_history'))}"><span aria-hidden="true">📋</span></button>
      <button type="button" class="btn sm ghost" data-act="adj-inv" data-id="${item.id}">${escapeHtml(t('inv.adjust'))}</button>
      ${(item.priceHistory && item.priceHistory.length > 0) ? `<button type="button" class="btn sm ghost" data-act="inv-price-history" data-id="${item.id}" title="${escapeHtml(t('inv.price_history'))}" aria-label="${escapeHtml(t('inv.price_history'))}"><span aria-hidden="true">📈</span></button>` : ''}
      <button type="button" class="btn sm" data-act="edit-inv" data-id="${item.id}">${escapeHtml(t('common.edit'))}</button>
      <button type="button" class="btn sm danger" data-act="del-inv" data-id="${item.id}">${escapeHtml(t('common.delete'))}</button>`;
  }

  function renderInventoryRow(item, ctx) {
    if (!useHandoffScreens()) return null;
    const { forecastMap = {}, todayMs = Date.now() } = ctx || {};
    const low = item.weight <= (item.reorderPoint ?? settings.lowStockThreshold);
    const queued = Math.round(getQueuedWeight(item.id));
    const warn = queued > 0 && queued > item.weight;
    const isResin = item.materialType === 'resin';
    const typeLabel = isResin ? (t('inv.type_resin') || 'Resin') : (t('inv.type_fdm') || 'FDM');
    const sw = Math.max(1, +item.spoolWeight || 1000);
    const unitPrice = (item.cost / sw) * 1000;
    const unitSuffix = isResin ? '/L' : '/kg';

    const refDate = item.openedAt || item.purchasedAt;
    let ageBadge = '';
    if (refDate) {
      const ageMonths = Math.floor((todayMs - new Date(refDate + 'T00:00:00').getTime()) / (30.44 * 86400000));
      if (ageMonths >= 12) ageBadge = `<span style="font-size:10px;color:var(--danger)">⚠ ${ageMonths}mo</span>`;
      else if (ageMonths >= 6) ageBadge = `<span style="font-size:10px;color:var(--warning)">📅 ${ageMonths}mo</span>`;
    }
    const fc = forecastMap[item.material];
    const runoutBadge = fc
      ? fc.available < 0
        ? `<span style="font-size:10px;background:var(--danger);color:#fff;padding:1px 5px;border-radius:3px;font-weight:600;">⚠ ${escapeHtml(t('inv.overcommit_warn'))}</span>`
        : `<span style="font-size:10px;color:${fc.urgent ? 'var(--danger)' : 'var(--warning)'};font-weight:600;" title="${escapeHtml(t('inv.runout_in') || 'Run-out in')} ${fc.daysRemaining} ${escapeHtml(t('common.days') || 'days')}">📉 ${fc.daysRemaining}d</span>`
      : '';
    const reserved = Math.round(getSpoolReservedGrams(item.id));
    const isOvercommit = reserved > item.weight;
    const reservedBadge = reserved > 0
      ? `<span class="spool-reserved-badge">${escapeHtml(t('inv.reserved'))}: ${reserved}${escapeHtml(t('common.grams'))}</span>`
      : '';
    const overcommitBadge = isOvercommit
      ? `<span style="background:var(--danger);color:#fff;font-size:10px;padding:1px 5px;border-radius:3px;font-weight:600;">⚠ ${escapeHtml(t('inv.overcommit_warn'))}</span>`
      : '';
    const spoolTestCount = (typeof testPrints !== 'undefined' ? testPrints : []).filter(tp => tp.spoolId === item.id).length;
    const testBadge = spoolTestCount > 0
      ? `<span style="font-size:10px;color:var(--primary);">🧪 ${spoolTestCount}</span>`
      : '';
    const lotChip = item.lot
      ? `<span style="font-size:10px;color:var(--text-dim);background:var(--bg-elev);border:1px solid var(--border-soft);border-radius:3px;padding:0 4px;" title="${escapeHtml(t('inv.lot') || 'Lot')}">${escapeHtml(item.lot)}</span>`
      : '';
    const dryingActive = (() => {
      const log = item.dryingLog || [];
      if (!log.length) return false;
      const last = [...log].sort((a, b) => (b.date || '').localeCompare(a.date || ''))[0];
      if (!last?.date) return false;
      return (Date.now() - new Date(last.date + 'T12:00:00').getTime()) / 3600000 < 48;
    })();

    return `
      <tr data-inv-id="${escapeHtml(item.id)}"${low ? ' class="khayt-inv-low"' : ''}>
        <td>
          <div class="khayt-inv-mat-cell">
            <span class="khayt-swatch" style="background:${safeCssColor(item.color, '#888')}"></span>
            <div class="col grow">
              <strong>${escapeHtml(item.material)}</strong>
              <div class="khayt-inv-meta">
                ${item.colourVariant ? `<span>${escapeHtml(item.colourVariant)}</span>` : ''}
                ${low ? `<span style="color:var(--warn)">· low</span>` : ''}
                ${lotChip}${ageBadge}${reservedBadge}${overcommitBadge}${testBadge}${runoutBadge}
                ${dryingActive ? `<span class="khayt-due" style="color:var(--violet);background:color-mix(in srgb,var(--violet) 18%,transparent)">${escapeHtml(t('inv.drying_now') || 'drying')}</span>` : ''}
              </div>
            </div>
          </div>
        </td>
        <td><span class="khayt-inv-type-pill">${escapeHtml(typeLabel)}</span></td>
        <td>${invStockMeterHtml(item)}${queued > 0 ? `<div class="mono" style="font-size:10px;color:${warn ? 'var(--danger)' : 'var(--text-muted)'};margin-top:4px">${escapeHtml(t('inv.col_queued') || 'Queued')}: ${queued}${isResin ? ' mL' : 'g'}</div>` : ''}</td>
        <td><span class="metric" style="font-size:13px">1</span></td>
        <td><span class="khayt-inv-unit-price">${escapeHtml(fmtMoney(unitPrice))}<span class="mono" style="font-size:10px;color:var(--text-muted)">${escapeHtml(unitSuffix)}</span></span></td>
        <td><div class="khayt-inv-actions">${invActionsHtml(item, low)}</div></td>
      </tr>`;
  }

  function wrapQueueFold(el, foldKey, titleKey, countFn) {
    if (!el || el.dataset.khaytFold === '1') return;
    const collapsed = prefGet('fold_' + foldKey, foldKey === 'waiting' ? '1' : '0') === '1';
    const fold = document.createElement('div');
    fold.className = 'khayt-fold' + (collapsed ? ' is-collapsed' : '');
    fold.dataset.foldKey = foldKey;

    const head = document.createElement('button');
    head.type = 'button';
    head.className = 'khayt-fold-head';
    head.setAttribute('aria-expanded', collapsed ? 'false' : 'true');

    const title = document.createElement('span');
    title.className = 'khayt-fold-title';
    title.setAttribute('data-i18n', titleKey);
    title.textContent = t(titleKey);

    const countEl = document.createElement('span');
    countEl.className = 'khayt-fold-count';
    countEl.style.display = 'none';

    const chev = document.createElement('span');
    chev.className = 'khayt-fold-chevron';
    chev.setAttribute('aria-hidden', 'true');
    chev.textContent = '▼';

    head.append(title, countEl, chev);

    const body = document.createElement('div');
    body.className = 'khayt-fold-body';

    const parent = el.parentNode;
    parent.insertBefore(fold, el);
    body.appendChild(el);
    fold.append(head, body);
    el.dataset.khaytFold = '1';
    if (el.classList.contains('quotes-section')) el.classList.add('khayt-fold-inner');

    const syncCount = () => {
      const n = countFn ? countFn() : 0;
      countEl.textContent = String(n);
      countEl.style.display = n > 0 ? '' : 'none';
      if (foldKey === 'quotes' && n === 0) fold.style.display = 'none';
      else fold.style.display = '';
    };
    syncCount();
    fold._syncCount = syncCount;

    head.addEventListener('click', () => {
      const nowCollapsed = !fold.classList.toggle('is-collapsed');
      prefSet('fold_' + foldKey, nowCollapsed ? '1' : '0');
      head.setAttribute('aria-expanded', nowCollapsed ? 'false' : 'true');
    });

    return fold;
  }


  function initWaitingStudioFold() {
    const wrap = $('#waitingListToggle')?.parentElement;
    if (!wrap || wrap.dataset.khaytFold === '1') return;

    const collapsed = prefGet('fold_waiting', '1') === '1';
    const fold = document.createElement('div');
    fold.className = 'khayt-fold' + (collapsed ? ' is-collapsed' : '');
    fold.dataset.foldKey = 'waiting';

    const head = document.createElement('button');
    head.type = 'button';
    head.className = 'khayt-fold-head';
    head.setAttribute('aria-expanded', collapsed ? 'false' : 'true');

    const title = document.createElement('span');
    title.className = 'khayt-fold-title';
    title.setAttribute('data-i18n', 'waiting.title');
    title.textContent = t('waiting.title');

    const countEl = document.createElement('span');
    countEl.className = 'khayt-fold-count';
    countEl.style.display = 'none';

    const addBtn = $('#btnAddWaiting');
    if (addBtn) {
      addBtn.type = 'button';
      addBtn.className = 'btn sm ghost khayt-fold-add';
      addBtn.removeAttribute('onclick');
      addBtn.addEventListener('click', (e) => e.stopPropagation());
      head.appendChild(addBtn);
    }

    const chev = document.createElement('span');
    chev.className = 'khayt-fold-chevron';
    chev.setAttribute('aria-hidden', 'true');
    chev.textContent = '▼';

    head.insertBefore(title, head.firstChild);
    head.append(countEl, chev);

    const toggle = $('#waitingListToggle');
    if (toggle) toggle.style.display = 'none';

    const body = document.createElement('div');
    body.className = 'khayt-fold-body';

    const parent = wrap.parentNode;
    parent.insertBefore(fold, wrap);
    body.appendChild(wrap);
    fold.append(head, body);
    wrap.dataset.khaytFold = '1';

    const section = $('#waitingListSection');
    const syncListVisibility = () => {
      const open = !fold.classList.contains('is-collapsed');
      if (section) section.style.display = open ? 'block' : 'none';
    };
    syncListVisibility();

    const syncCount = () => {
      const n = typeof waitingList !== 'undefined' ? waitingList.length : 0;
      countEl.textContent = String(n);
      countEl.style.display = n > 0 ? '' : 'none';
      const badge = $('#waitingBadge');
      if (badge) {
        badge.textContent = String(n);
        badge.style.display = n > 0 ? 'inline-flex' : 'none';
      }
    };
    syncCount();
    fold._syncCount = syncCount;

    head.addEventListener('click', (e) => {
      if (e.target.closest('.khayt-fold-add')) return;
      const nowCollapsed = !fold.classList.toggle('is-collapsed');
      prefSet('fold_waiting', nowCollapsed ? '1' : '0');
      head.setAttribute('aria-expanded', nowCollapsed ? 'false' : 'true');
      syncListVisibility();
    });

    return fold;
  }
  function initQueueStudioFolds() {
    if (!useHandoffScreens()) return;
    const quotes = $('#quotesSection');
    if (quotes) {
      wrapQueueFold(quotes, 'quotes', 'queue.quotes_awaiting', () => printLog.filter(o => o.status === 'quote').length);
    }
    initWaitingStudioFold();
  }

  function syncQueueFolds() {
    if (!useHandoffScreens()) return;
    document.querySelectorAll('.khayt-fold[data-fold-key="quotes"]').forEach(f => f._syncCount?.());
    document.querySelectorAll('.khayt-fold[data-fold-key="waiting"]').forEach(f => f._syncCount?.());
  }

  function initPhase5() {
    if (!useHandoffScreens()) return;
    patchInventoryTableHead();
    ensureCalcStudioPanel();
    initQueueStudioFolds();
  }

  function renderInventoryStudioStats() {
    const el = $('#invStudioStats');
    if (!el || !useHandoffScreens()) return;
    if (!inventory.length) {
      el.style.display = 'none';
      el.setAttribute('aria-hidden', 'true');
      return;
    }
    const low = inventory.filter(i => i.weight <= (i.reorderPoint ?? settings.lowStockThreshold));
    const totalValue = inventory.reduce((s, item) => {
      const sw = Math.max(1, +item.spoolWeight || 1000);
      const pricePerG = item.cost > 0 ? item.cost / sw : 0;
      return s + pricePerG * Math.max(0, +item.weight || 0);
    }, 0);
    const dryingNow = inventory.filter(i => {
      const log = i.dryingLog || [];
      if (!log.length) return false;
      const last = [...log].sort((a, b) => (b.date || '').localeCompare(a.date || ''))[0];
      if (!last?.date) return false;
      const hours = (Date.now() - new Date(last.date + 'T12:00:00').getTime()) / 3600000;
      return hours < 48;
    }).length;
    const stats = [
      { l: t('inv.total_spools') || 'Total spools', v: inventory.length, u: '', c: 'var(--info)' },
      { l: t('inv.total_value') || 'Stock value', v: Math.round(totalValue).toLocaleString(), u: settings.currency || 'SAR', c: 'var(--accent)' },
      { l: t('inv.low_stock_count') || 'Below reorder', v: low.length, u: t('inv.items') || 'items', c: 'var(--warn)' },
      { l: t('inv.drying_now') || 'Drying now', v: dryingNow, u: '', c: 'var(--violet, #a78bfa)' },
    ];
    el.innerHTML = stats.map(s => `
      <div class="khayt-inv-stat">
        <div class="col" style="gap:4px">
          <span class="eyebrow">${escapeHtml(s.l)}</span>
          <span class="row" style="align-items:baseline;gap:4px">
            <span class="metric">${escapeHtml(String(s.v))}</span>
            ${s.u ? `<span class="mono" style="font-size:11px;color:var(--text-muted)">${escapeHtml(s.u)}</span>` : ''}
          </span>
        </div>
        <span class="dot" style="background:${s.c};width:10px;height:10px"></span>
      </div>`).join('');
    el.style.display = 'grid';
    el.removeAttribute('aria-hidden');
  }

  function invStockMeterHtml(item) {
    const reorder = item.reorderPoint ?? settings.lowStockThreshold ?? 200;
    const cap = Math.max(reorder * 2, item.weight || 1, 1);
    const pct = Math.min(100, Math.round((item.weight / cap) * 100));
    const low = item.weight <= reorder;
    return `
      <div class="inv-stock-meter">
        <div class="row between" style="margin-bottom:4px">
          <span class="metric" style="font-size:12px;color:${low ? 'var(--warn)' : 'var(--text-dim)'}">${Math.round(item.weight)} ${item.materialType === 'resin' ? 'mL' : 'g'}</span>
          <span class="mono" style="font-size:10px;color:var(--text-faint)">${escapeHtml(t('inv.reorder_at') || 'reorder')} ${Math.round(reorder)}</span>
        </div>
        <div class="meter"><i style="width:${pct}%;background:${low ? 'var(--warn)' : 'var(--ok)'}"></i></div>
      </div>`;
  }



  function patchInitAppShellKanbanCols() {
    if (!useHandoffScreens()) return;
    $$('.kanban-col').forEach(col => {
      col.classList.add('khayt-kcol');
      const list = col.querySelector('[id^="list-"]');
      if (list) list.classList.add('khayt-kcol-body');
    });
  }

  function init() {
    if (!useHandoffScreens()) return;
    window.KhaytIcon?.hydrateHandoff?.();
    wireStudioQueueFilters();
    initStudioCalculatorLayout();
    patchInitAppShellKanbanCols();
    initPhase5();
    if (typeof i18n !== 'undefined' && i18n.apply) i18n.apply(document.body);
  }

  window.KhaytBedReadyUI = {
    isBedReadyUI,
    useHandoffScreens,
    init,
    initPhase5,
    syncQueueMachinePicker,
    syncQueueFolds,
    orderMatchesStudioQueueFilter,
    renderInventoryStudioStats,
    patchInventoryTableHead,
    renderInventoryRow,
    invStockMeterHtml,
    initStudioCalculatorLayout,
    ensureCalcStudioPanel,
    updateCalcBreakdown,
  };
})();
