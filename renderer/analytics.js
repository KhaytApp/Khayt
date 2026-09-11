/**
 * Analytics tab: stats, charts, P&L sections, simple reports mode.
 */
/* Does this order count as trade? See lib/business-scope.js.
 *
 * Guarded the way renderer/currency.js guards the same module: when it is not
 * loaded, everything counts, which is exactly the behaviour that existed before
 * the flag. A report must not throw because an optional module is missing —
 * Bed Ready shares these screens, and the harness that renders this file in a
 * test does not load the whole app. */
const _countsForBusiness = (o) =>
  (typeof KhaytBusinessScope === 'undefined') || KhaytBusinessScope.countsForBusiness(o);

/* Who the shop's best customers are and what it is asked for most — the same
 * two rollups this file used to write out four times, now in lib/top-lists.js
 * so the Mac app shows the same lists rather than forming a second opinion.
 * Guarded like the line above, and for the same reason. */
const _topLists = () => (typeof KhaytTopLists === 'undefined' ? null : KhaytTopLists);
const _topCtx = () => ({
  settings: typeof settings !== 'undefined' ? settings : {},
  clients: typeof clients !== 'undefined' ? clients : [],
  products: typeof products !== 'undefined' ? products : [],
  currencies: (typeof KhaytCurrencies !== 'undefined' && KhaytCurrencies.CURRENCIES) || null,
  language: (typeof i18n !== 'undefined' && i18n.current) || 'en',
});

(function (global) {
/* ============================================================
   Simple Reports — shown instead of full Analytics in Simple mode
   ============================================================ */
function renderSimpleReports() {
  const wrap = $('#analyticsSimpleWrap');
  if (!wrap) return;

  const thisMonthStr = localMonthStr();
  /* The trade set. `!o.voidedAt` has always meant "this did not count";
   * countsForBusiness() adds the prints a shop marked as its own — a
   * calibration cube or a bracket for its own shelf is not turnover, and an
   * average order value diluted by a run of free test prints is worse than
   * no average at all.
   *
   * Machine HOURS deliberately keep counting them: the printer really ran,
   * and a utilisation figure that ignored half a machine's work would be the
   * same mistake as reading a printer's state from the order book. */
  const monthOrders = printLog.filter(o => o.status === 'completed' && !o.voidedAt && _countsForBusiness(o) && (o.date || '').startsWith(thisMonthStr));
  const monthRevenue = monthOrders.reduce((s, o) => s + orderNetRevenueBase(o), 0);
  const monthCount   = monthOrders.length;

  const outstanding = printLog
    .filter(o => payStatus(o) !== 'paid')
    .reduce((s, o) => s + orderOwedBase(o), 0);

  const tagRev = {};
  for (const o of monthOrders) {
    for (const tag of (o.tags || [])) {
      tagRev[tag] = (tagRev[tag] || 0) + orderNetRevenueBase(o);
    }
  }
  const topTags = Object.entries(tagRev).sort((a, b) => b[1] - a[1]).slice(0, 3);

  wrap.innerHTML = `
    <div class="card" id="simpleReportsCard" style="margin-top:0;">
    <h3 class="card-head"><span class="swatch"></span><span>${escapeHtml(t('an.simple_reports'))}</span></h3>
    <div class="grid-4" style="margin-bottom:16px;">
      <div class="stat revenue">
        <div class="stat-label">${escapeHtml(t('an.simple_revenue'))}</div>
        <div class="stat-value"><span>${fmtMoney(monthRevenue)}</span><span class="unit">${escapeHtml(currencySymbol())}</span></div>
      </div>
      <div class="stat orders">
        <div class="stat-label">${escapeHtml(t('an.simple_orders'))}</div>
        <div class="stat-value">${monthCount}</div>
      </div>
      <div class="stat receivables full">
        <div class="stat-label">${escapeHtml(t('an.simple_outstanding'))}</div>
        <div class="stat-value"><span>${fmtMoney(outstanding)}</span><span class="unit">${escapeHtml(currencySymbol())}</span></div>
      </div>
    </div>
    ${topTags.length > 0 ? `
    <h4 style="font-size:13px;font-weight:600;margin:0 0 10px;">${escapeHtml(t('an.simple_top_products') || 'Top products this month')}</h4>
    <ul class="leaderboard" style="margin-bottom:16px;">
      ${topTags.map(([ tag, rev ], i) => `
        <li>
          <span class="rank">${i + 1}.</span>
          <span class="name">${escapeHtml(tag)}</span>
          <span class="value">${fmtPrice(rev)}</span>
        </li>`).join('')}
    </ul>` : ''}
    <button class="btn small" id="btnSimpleReportsCsv">${escapeHtml(t('an.simple_csv') || 'Download CSV')}</button>
    </div>`;

  wrap.querySelector('#btnSimpleReportsCsv')?.addEventListener('click', () => {
    exportOrdersCsv();
  });
}

function useHandoffAnalytics() {
  return document.body.classList.contains('bedready-ui') && settings.mode === 'professional';
}

function handoffSparkSvg(data, w, h) {
  if (!data?.length) return '';
  const max = Math.max(...data, 1);
  const pts = data.map((v, i) => {
    const x = Math.round((i / Math.max(data.length - 1, 1)) * w);
    const y = Math.round(h - (v / max) * h * 0.9);
    return `${x},${y}`;
  }).join(' ');
  return `<svg width="${w}" height="${h}" class="khayt-spark" aria-hidden="true"><polyline points="${pts}" fill="none" stroke="var(--accent)" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round" opacity="0.85"/></svg>`;
}

/**
 * How many days the selected analytics range actually spans — the divisor for
 * utilisation (print hours per day vs target).
 *
 * The old ladder hardcoded 30 for anything it did not recognise, but the range selector
 * also offers "All time" (the DEFAULT) and "Custom", both of which fell through. 1000
 * print-hours over three years against a 10 h/day target rendered as 100% utilisation
 * (true value ~9%) — and Math.min(100, …) hid the overflow, so it looked plausible
 * instead of obviously broken. A 7-day custom range understated by ~4x.
 */
function analyticsRangeDays(range, ctx, dates) {
  const now = new Date();
  if (range === 'month') return new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
  if (range === 'last_month') return new Date(now.getFullYear(), now.getMonth(), 0).getDate();
  if (range === 'quarter') return 91;
  if (range === 'year') return 365;
  const spanDays = (from, to) => Math.max(1, Math.round((new Date(to) - new Date(from)) / 86400000) + 1);
  if (range === 'custom') {
    const from = (typeof customRangeFrom !== 'undefined' && ctx) ? customRangeFrom[ctx] : '';
    const to   = (typeof customRangeTo   !== 'undefined' && ctx) ? customRangeTo[ctx]   : '';
    if (from && to) return spanDays(from, to);
    if (from) return spanDays(from, localDateStr());
  }
  // 'all' (and a custom range with no bounds): span the data itself.
  const days = (dates || []).map(d => String(d || '').slice(0, 10)).filter(Boolean).sort();
  if (days.length) return spanDays(days[0], days[days.length - 1]);
  return 30;
}

function computeHandoffMachineRows() {
  const orders = printLog.filter(o => inRange(o.date, analyticsRange, 'analytics') && o.status === 'completed' && !o.voidedAt && _countsForBusiness(o));
  const machMap = {};
  for (const m of machines) {
    machMap[m.id] = { name: m.name, profit: 0, hours: 0, util: null };
  }
  const now = new Date();
  const rangeDays = analyticsRangeDays(analyticsRange, 'analytics', orders.map(o => o.date));

  for (const o of orders) {
    const key = o.machineId && machMap[o.machineId] ? o.machineId : null;
    if (!key) continue;
    const rev = orderNetRevenueBase(o);
    const cost = (o.parts || []).reduce((s, p) => s + partTotalCost(p), 0);
    machMap[key].profit += rev - cost;
    machMap[key].hours += +o.printTime || 0;
  }
  for (const m of machines) {
    if (!machMap[m.id]) continue;
    const target = +(m.targetHoursPerDay || 0);
    if (target > 0 && machMap[m.id].hours > 0) {
      machMap[m.id].util = Math.min(100, Math.round((machMap[m.id].hours / (target * rangeDays)) * 100));
    }
  }
  return Object.values(machMap).filter(r => r.hours > 0 || r.profit > 0).sort((a, b) => b.profit - a.profit);
}

function buildHandoffHeatmapCells() {
  const completed = printLog.filter(o =>
    o.status === 'completed' && o.completedAt && inRange(o.date, analyticsRange, 'analytics'),
  );
  const matrix = Array.from({ length: 7 }, () => Array(12).fill(0));
  completed.forEach(o => {
    try {
      const d = new Date(o.completedAt);
      const week = Math.min(11, Math.floor((Date.now() - d.getTime()) / (7 * 86400000)));
      const dow = d.getDay();
      if (week >= 0 && week < 12) matrix[dow][11 - week]++;
    } catch (_) { /* ignore */ }
  });
  const maxVal = Math.max(1, ...matrix.flat());
  const cells = [];
  for (let w = 0; w < 12; w++) {
    for (let d = 0; d < 7; d++) {
      const v = matrix[d][w] / maxVal;
      cells.push(`<span style="background:hsl(var(--accent-h) var(--accent-s) var(--accent-l) / ${(0.12 + v * 0.85).toFixed(2)})"></span>`);
    }
  }
  return { cells: cells.join(''), maxVal, hasData: completed.length >= 5 };
}

function renderHandoffAnalyticsOverview(ctx) {
  const wrap = $('#analyticsHandoffWrap');
  if (!wrap) return;
  if (!useHandoffAnalytics()) {
    wrap.innerHTML = '';
    return;
  }

  const { revenue, completed, receivables, convRate, revSpark } = ctx;
  const cur = currencySymbol();
  const netProfit = completed.reduce((s, o) => {
    const rev = orderNetRevenueBase(o);
    const cost = (o.parts || []).reduce((cs, p) => cs + partTotalCost(p), 0);
    return s + (rev - cost);
  }, 0);
  const avgOrder = completed.length ? revenue / completed.length : 0;
  const repeatClients = (() => {
    const counts = {};
    completed.forEach(o => { if (o.clientId) counts[o.clientId] = (counts[o.clientId] || 0) + 1; });
    const ids = Object.keys(counts);
    if (!ids.length) return null;
    return Math.round((ids.filter(id => counts[id] > 1).length / ids.length) * 100);
  })();

  const kpis = [
    { l: t('an.revenue') || 'Revenue', v: fmtCount(Math.round(revenue)), u: cur, spark: revSpark },
    { l: t('an.net_profit') || 'Net profit', v: fmtCount(Math.round(netProfit)), u: cur },
    { l: t('an.avg_order') || 'Avg. order value', v: fmtCount(Math.round(avgOrder)), u: cur },
    { l: t('an.repeat_rate') || 'Repeat rate', v: repeatClients != null ? String(repeatClients) : '—', u: repeatClients != null ? '%' : '' },
  ];

  const machines = computeHandoffMachineRows();
  const maxP = Math.max(...machines.map(m => m.profit), 1);
  const heat = buildHandoffHeatmapCells();
  const dayLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

  // Eight here, five on the simple screen — the whole of the difference
  // between the two copies this used to be.
  const topClients = (_topLists()?.topClients(completed, _topCtx(), { limit: 8 }) || [])
    .map(row => {
      const c = clients.find(x => x.id === row.id);
      const tier = typeof getClientTier === 'function' ? getClientTier(row.id) : null;
      return { ...row, color: c?.color || 'var(--accent)', tier: tier?.name || '—' };
    });
  const maxLtv = Math.max(...topClients.map(c => c.revenue), 1);

  wrap.innerHTML = `
    <div class="khayt-grid khayt-an-kpis" style="grid-template-columns:repeat(4,minmax(0,1fr));gap:var(--gap)">
      ${kpis.map(k => `
        <div class="card khayt-an-kpi">
          <span class="eyebrow">${escapeHtml(k.l)}</span>
          <span class="row" style="align-items:baseline;gap:4px">
            <span class="metric" style="font-size:26px">${escapeHtml(k.v)}</span>
            ${k.u ? `<span class="mono" style="font-size:11px;color:var(--text-muted)">${escapeHtml(k.u)}</span>` : ''}
          </span>
          ${k.spark ? `<div style="margin-top:8px">${handoffSparkSvg(k.spark, 200, 32)}</div>` : ''}
        </div>`).join('')}
    </div>
    <div class="khayt-grid khayt-an-grid-2" style="grid-template-columns:1fr 1fr;gap:var(--gap)">
      <div class="card">
        <span class="sec-title">${escapeHtml(t('an.machine_pl') || 'Machine P&L')}</span>
        <div class="col gap12" style="margin-top:14px">
          ${machines.length ? machines.map(m => `
            <div class="col gap6">
              <div class="row between">
                <span style="font-size:12.5px">${escapeHtml(m.name)}</span>
                <span class="metric" style="font-size:12.5px">${escapeHtml(fmtMoney(m.profit))}</span>
              </div>
              <div class="row gap10" style="align-items:center">
                <div class="meter grow"><i style="width:${Math.max(4, (m.profit / maxP) * 100)}%"></i></div>
                <span class="mono" style="font-size:10.5px;color:var(--text-muted);width:78px;text-align:end">${m.hours.toFixed(1)}h${m.util != null ? ` · ${m.util}%` : ''}</span>
              </div>
            </div>`).join('') : `<p class="dash-empty">${escapeHtml(t('an.no_data'))}</p>`}
        </div>
      </div>
      <div class="card">
        <div class="row between">
          <span class="sec-title">${escapeHtml(t('an.production_heatmap') || 'Production heatmap')}</span>
          <span style="font-size:11.5px;color:var(--text-muted)">${escapeHtml(t('an.last_12_weeks') || 'last 12 weeks')}</span>
        </div>
        ${heat.hasData ? `
        <div class="row gap10" style="margin-top:16px;align-items:flex-start">
          <div class="col" style="gap:4px;padding-top:1px">
            ${dayLabels.map((d2, i) => `<span class="mono" style="font-size:9px;color:var(--text-faint);height:16px;line-height:16px">${d2}</span>`).join('')}
          </div>
          <div class="heatmap-mini grow">${heat.cells}</div>
        </div>` : `<p class="dash-empty" style="margin-top:14px">${escapeHtml(t('an.heatmap_no_data'))}</p>`}
      </div>
    </div>
    <div class="card flush">
      <div class="row between" style="padding:14px 18px">
        <span class="sec-title">${escapeHtml(t('an.top_clients_revenue') || 'Top clients · revenue')}</span>
      </div>
      <div class="table-wrap">
        <table class="tbl">
          <thead><tr>
            <th>${escapeHtml(t('log.client'))}</th>
            <th>${escapeHtml(t('an.orders'))}</th>
            <th>${escapeHtml(t('cl.revenue'))}</th>
            <th>${escapeHtml(t('an.share'))}</th>
            <th>${escapeHtml(t('cl.tier'))}</th>
          </tr></thead>
          <tbody>
            ${topClients.length ? topClients.map(c => `
              <tr>
                <td><div class="row gap8" style="align-items:center"><span class="dot" style="background:${safeCssColor(c.color, 'var(--accent)')};width:8px;height:8px"></span><strong style="font-size:13">${escapeHtml(c.name)}</strong></div></td>
                <td><span class="metric" style="font-size:13px">${c.count}</span></td>
                <td><span class="metric" style="font-size:13px">${escapeHtml(fmtMoney(c.revenue))}</span></td>
                <td style="width:160px"><div class="meter"><i style="width:${(c.revenue / maxLtv * 100).toFixed(1)}%;background:${safeCssColor(c.color, 'var(--accent)')}"></i></div></td>
                <td><span class="pill" style="padding:2px 9px">${escapeHtml(c.tier)}</span></td>
              </tr>`).join('') : `<tr><td colspan="5">${escapeHtml(t('an.no_top_clients'))}</td></tr>`}
          </tbody>
        </table>
      </div>
    </div>`;
}

function renderAnalytics() {
  const orders = printLog.filter(o => inRange(o.date, analyticsRange, 'analytics'));
  const completed = orders.filter(o => o.status === 'completed' && !o.voidedAt && _countsForBusiness(o));
  const revenue = completed.reduce((s, o) => s + orderNetRevenueBase(o), 0);
  const hours   = orders.reduce((s, o) => s + (+o.printTime || 0), 0);
  const inProgress = orders.filter(o => o.status !== 'completed' && o.status !== 'pending').length;
  // Receivables — outstanding amount across all unpaid/partial orders, regardless of status
  const receivables = printLog
    .filter(o => (payStatus(o)) !== 'paid')
    .reduce((s, o) => s + orderOwedBase(o), 0);

  const revSpark = (() => {
    const months = [];
    const now = new Date();
    for (let i = 11; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
      const mRev = printLog.filter(o => o.status === 'completed' && !o.voidedAt && _countsForBusiness(o) && (o.date || '').startsWith(key))
        .reduce((s, o) => s + orderNetRevenueBase(o), 0);
      months.push(mRev);
    }
    return months;
  })();

  $('#stat-revenue').textContent = fmtMoney(revenue);
  $('#stat-orders').textContent  = completed.length;
  $('#stat-hours').textContent   = hours.toFixed(1);
  $('#stat-pending').textContent = inProgress;
  const recEl = $('#stat-receivables');
  if (recEl) recEl.textContent = fmtMoney(receivables);

  // Quote conversion rate
  const quotesCreated   = printLog.filter(o => o.quoteSentAt   && inRange(o.quoteSentAt,   analyticsRange, 'analytics'));
  // Conversion is measured within the created cohort (quotes sent in range that
  // were later accepted) — otherwise a quote accepted in-range but sent earlier
  // inflates the rate above 100%.
  const quotesConverted = quotesCreated.filter(o => o.quoteAcceptedAt);
  const convRate = quotesCreated.length > 0 ? Math.round(quotesConverted.length / quotesCreated.length * 100) : null;
  const qcEl = $('#stat-quotes-created');
  if (qcEl) qcEl.textContent = quotesCreated.length;
  const crEl = $('#stat-conv-rate');
  if (crEl) crEl.textContent = convRate !== null ? `${convRate}%` : '—';

  renderHandoffAnalyticsOverview({ revenue, completed, receivables, convRate, revSpark });

  // Top products
  const topProducts = _topLists()?.topProducts(orders, _topCtx(), { limit: 5 }) || [];

  const tpList = $('#topProductsList');
  if (topProducts.length === 0) {
    tpList.innerHTML = `<li><span class="rank">—</span><span class="name" style="color: var(--text-muted);">${escapeHtml(t('an.no_top_products'))}</span></li>`;
  } else {
    tpList.innerHTML = topProducts.map((p, i) => `
      <li>
        <span class="rank">${i + 1}.</span>
        <span class="name">${escapeHtml(p.name)}</span>
        <span class="value">${p.count}× · ${fmtPrice(p.revenue)}</span>
      </li>`).join('');
  }

  // Top clients
  const topClients = _topLists()?.topClients(completed, _topCtx(), { limit: 5 }) || [];

  const tcList = $('#topClientsList');
  if (topClients.length === 0) {
    tcList.innerHTML = `<li><span class="rank">—</span><span class="name" style="color: var(--text-muted);">${escapeHtml(t('an.no_top_clients'))}</span></li>`;
  } else {
    tcList.innerHTML = topClients.map((c, i) => `
      <li>
        <span class="rank">${i + 1}.</span>
        <span class="name">${escapeHtml(c.name)}</span>
        <span class="value">${fmtPrice(c.revenue)} · ${c.count}×</span>
      </li>`).join('');
  }

  // Recent activity
  const ul = $('#activityList');
  if (orders.length === 0) {
    ul.innerHTML = `<li>${escapeHtml(t('an.no_activity'))}</li>`;
  } else {
    ul.innerHTML = orders.slice(0, 8).map(log => `
      <li>
        <span class="date">${escapeHtml(log.date)}</span>
        <span><strong>${escapeHtml(log.project)}</strong> · <span class="badge ${escapeHtml(log.status)}">${escapeHtml(t('queue.' + log.status))}</span></span>
      </li>`).join('');
  }

  /* Per-model variance — what a MODEL costs against what it is quoted at.
   *
   * The accuracy panel below answers "how good are my estimates". This answers
   * "which model should I re-price", which is the one a shop can act on: an
   * order happened once, at a price already charged, but a model gets quoted
   * again tomorrow.
   *
   * Measured readings only, and only from single-part jobs — a divided figure is
   * a fair way to split a bill and not a measurement of any one part. See
   * lib/estimate-variance.js.
   */
  const varianceEl = $('#modelVarianceSection');
  if (varianceEl && typeof KhaytEstimateVariance !== 'undefined'
      && typeof KhaytOrderFileLink !== 'undefined' && typeof KhaytPrinterActuals !== 'undefined') {
    const rows = KhaytEstimateVariance.varianceByModel(completed, {
      allocate: (o) => KhaytOrderFileLink.allocateActuals(o),
      compare: KhaytPrinterActuals.compareToEstimate,
    });
    if (!rows.length) {
      varianceEl.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.mv_none'))}</p>`;
    } else {
      const pct = (v) => (v === null ? '—' : (v >= 0 ? '+' : '') + v.toFixed(1) + '%');
      const col = (v) => (v === null ? 'var(--text-muted)'
        : v >= 15 ? 'var(--danger)' : v >= 8 ? 'var(--warning)' : 'var(--success)');
      const conf = { good: t('an.mv_conf_good'), fair: t('an.mv_conf_fair'), thin: t('an.mv_conf_thin') };
      const advised = rows.map((r) => [r, KhaytEstimateVariance.advice(r)]).filter(([, a]) => a);
      varianceEl.innerHTML = `
        ${advised.length ? `<div class="mv-advice">${advised.slice(0, 3).map(([r, a]) => `
          <p>${escapeHtml(t('an.mv_underquoted', {
            name: r.name || r.printFileId, pct: a.pct,
            axis: a.axis === 'time' ? t('an.mv_axis_time') : t('an.mv_axis_filament'),
            n: a.sampled,
          }))}</p>`).join('')}</div>` : ''}
        <div class="table-wrap">
          <table>
            <thead><tr>
              <th>${escapeHtml(t('an.mv_model'))}</th>
              <th>${escapeHtml(t('an.mv_prints'))}</th>
              <th>${escapeHtml(t('an.mv_filament'))}</th>
              <th>${escapeHtml(t('an.mv_time'))}</th>
            </tr></thead>
            <tbody>
              ${rows.slice(0, 25).map((r) => `<tr>
                <td>${escapeHtml(r.name || r.printFileId)}</td>
                <td>${r.sampled} <span style="color:var(--text-muted);font-size:11px;">${escapeHtml(conf[r.confidence] || '')}</span></td>
                <td style="color:${col(r.gramsDeltaPct)}">${escapeHtml(pct(r.gramsDeltaPct))}</td>
                <td style="color:${col(r.hoursDeltaPct)}">${escapeHtml(pct(r.hoursDeltaPct))}</td>
              </tr>`).join('')}
            </tbody>
          </table>
        </div>`;
    }
  }

  // Accuracy section
  const accuracyEl = $('#accuracySection');
  if (accuracyEl) {
    const withActuals = completed.filter(o => o.actualPrintTime != null);
    if (withActuals.length === 0) {
      accuracyEl.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.accuracy_none'))}</p>`;
    } else {
      const sign = v => (v >= 0 ? '+' : '') + v.toFixed(1) + '%';
      const col  = v => Math.abs(v) <= 10 ? 'var(--success)' : Math.abs(v) <= 25 ? 'var(--warning)' : 'var(--danger)';
      const avgTimeVar = withActuals.reduce((s, o) =>
        s + (o.printTime > 0 ? (o.actualPrintTime - o.printTime) / o.printTime * 100 : 0), 0) / withActuals.length;
      const withWeight = withActuals.filter(o => o.actualWeight != null);
      const estW = o => (o.parts || []).reduce((s, p) => s + (+p.printWeight || 0) * (p.qty || 1), 0);
      const avgWeightVar = withWeight.length > 0
        ? withWeight.reduce((s, o) => {
            const e = estW(o);
            return s + (e > 0 ? (o.actualWeight - e) / e * 100 : 0);
          }, 0) / withWeight.length
        : null;

      accuracyEl.innerHTML = `
        <div class="accuracy-stats">
          <div class="accuracy-stat">
            <div class="v" style="color:${col(avgTimeVar)}">${sign(avgTimeVar)}</div>
            <div class="l">${escapeHtml(t('an.time_accuracy'))}</div>
            <div class="hint">${escapeHtml(t('an.accuracy_based_on', { n: withActuals.length }))}</div>
          </div>
          ${avgWeightVar !== null ? `
          <div class="accuracy-stat">
            <div class="v" style="color:${col(avgWeightVar)}">${sign(avgWeightVar)}</div>
            <div class="l">${escapeHtml(t('an.weight_accuracy'))}</div>
            <div class="hint">${escapeHtml(t('an.accuracy_based_on', { n: withWeight.length }))}</div>
          </div>` : ''}
        </div>
        <div class="table-wrap" style="margin-top:12px;">
          <table>
            <thead><tr>
              <th>${escapeHtml(t('log.client'))}</th>
              <th>${escapeHtml(t('an.est_time'))}</th>
              <th>${escapeHtml(t('an.act_time'))}</th>
              <th>${escapeHtml(t('an.variance'))}</th>
            </tr></thead>
            <tbody>
              ${withActuals.slice(0, 8).map(o => {
                const diff = o.printTime > 0 ? (o.actualPrintTime - o.printTime) / o.printTime * 100 : 0;
                return `<tr>
                  <td>${escapeHtml(o.project || o.id)}</td>
                  <td style="color:var(--text-dim);">${o.printTime} ${escapeHtml(t('common.hours'))}</td>
                  <td style="color:var(--text-dim);">${o.actualPrintTime} ${escapeHtml(t('common.hours'))}</td>
                  <td style="font-weight:600; color:${col(diff)};">${sign(diff)}</td>
                </tr>`;
              }).join('')}
            </tbody>
          </table>
        </div>`;
    }
  }

  // The second headline that used to stand here is gone.
  //
  // `renderTimestampAccuracy` answered the same question as #accuracySection
  // above — how far the shop's prints run from their estimates — and answered it
  // from `completedAt - printingStartedAt`. That field is written in one place,
  // `order-status.js`, when a job is dragged into the printing stage BY HAND, so
  // a shop whose jobs are logged from the printer's own history never had it and
  // the panel rendered an empty string every time. Two answers to one question,
  // one of them structurally blank, is not something to fix twice over.

  renderRevenueChart();
  renderMaterialUsageChart();
  renderFilamentAnalytics();
  renderPrinterUtilizationChart();
  renderPnLSection();
  renderProductProfitability();
  renderSLASection();
  renderQcSection();
  renderMachinePL();
  renderLocationPL();
  renderSupplierPriceHistory();
  renderThroughputHeatmap();
  renderClientRetention();
  renderCostTrends();
  renderOperatorAnalytics();
  // Round 12 additions
  renderAgedReceivables();
  renderSurveyAnalytics();
  renderNewVsReturning();
  renderQuoteFunnelChart();
  renderMonthlyTrendChart();
  renderRevenueForecast();
  renderMachineRevenueChart();
  renderProfitMarginChart();
  renderMachineAccuracy();
  renderClientSourceChart();
  // Round 13 additions
  renderWasteTrendChart();
  renderCycleTimeChart();
  renderCashFlowChart();
  renderExpenseCategoryChart();
  renderLeadTimeChart();
  renderNpsTrendChart();
  renderClientLtvTable();
  renderMachineDowntimeChart();
  renderMaintenanceCostChart();
  // Feature K: Time tracking analytics
  renderTimeAnalytics();
}

function renderClientSourceChart() {
  const el = $('#clientSourceChart');
  if (!el) return;
  const sources = ['instagram','referral','walk_in','website','exhibition','other'];
  const counts = {};
  for (const s of sources) counts[s] = 0;
  for (const c of clients) counts[c.source || 'other'] = (counts[c.source || 'other'] || 0) + 1;

  const maxCount = Math.max(...Object.values(counts), 1);

  const sourceColors = {
    instagram:  '#e1306c',
    referral:   '#22c55e',
    walk_in:    '#3b82f6',
    website:    '#f59e0b',
    exhibition: '#a855f7',
    other:      '#6b7280',
  };

  // Revenue per source in a single pass (was O(sources × orders × clients) with a nested
  // clients.find inside the per-source loop; now O(orders) using the clientById index).
  const revBySrc = {};
  for (const o of printLog) {
    if (o.status !== 'completed' || !o.clientId) continue;
    const c = clientById(o.clientId);
    if (!c) continue;
    const src = c.source || 'other';
    revBySrc[src] = (revBySrc[src] || 0) + orderNetRevenueBase(o);
  }

  const rows = sources
    .filter(s => counts[s] > 0)
    .sort((a, b) => counts[b] - counts[a])
    .map(s => {
      const pct = Math.round((counts[s] / maxCount) * 100);
      const revBySource = revBySrc[s] || 0;
      return `
        <div style="display:flex;align-items:center;gap:10px;margin-bottom:8px;">
          <div style="min-width:90px;font-size:12px;color:var(--text);text-align:end;">${escapeHtml(t('cl.source_' + s))}</div>
          <div style="flex:1;background:var(--border);border-radius:4px;height:14px;overflow:hidden;">
            <div style="width:${pct}%;height:100%;background:${sourceColors[s]};border-radius:4px;transition:width .4s;"></div>
          </div>
          <div style="min-width:60px;font-size:11px;color:var(--text-muted);">${counts[s]} · ${fmtPrice(revBySource)}</div>
        </div>`;
    }).join('');

  if (!rows) {
    el.innerHTML = `<p class="dash-empty">${escapeHtml(t('an.source_empty'))}</p>`;
    return;
  }
  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.source_title'))}</h3>
      <div style="padding:8px 0;">${rows}</div>
    </div>`;
}

/* ── Quote Conversion Funnel ────────────────────────────── */
function renderQuoteFunnelChart() {
  const el = $('#quoteFunnelChart');
  if (!el) return;

  // `lib/quote-funnel.js`, not the filters that used to be here. The last step
  // counted `status === 'completed'` ONLY — and `delivered` is past completed
  // in Khayt's pipeline, so every job that reached a customer fell out of the
  // funnel's final step and the rate printed below was too low for every shop
  // that marks work delivered. A CANCELLED order also counted as converted,
  // and the business scope was ignored.
  const funnel = KhaytQuoteFunnel.quoteFunnel(
    { orders: printLog || [], now: Date.now() },
    { priceOf: orderNetRevenueBase, countsForBusiness: _countsForBusiness });
  const colours = {
    created: '#6366f1', sent: '#3b82f6', accepted: '#22c55e',
    converted: '#f59e0b', finished: '#10b981',
  };
  const labels = {
    created: 'an.funnel_created', sent: 'an.funnel_sent', accepted: 'an.funnel_accepted',
    converted: 'an.funnel_converted', finished: 'an.funnel_completed',
  };
  const steps = funnel.steps.map((s) => ({
    key: labels[s.key], count: s.count, color: colours[s.key],
  }));
  const allQuoteOrders = { length: funnel.steps[0].count };

  if (allQuoteOrders.length === 0) {
    el.innerHTML = '';
    return;
  }

  const maxCount = Math.max(allQuoteOrders.length, 1);

  const rows = steps.map((step, i) => {
    const pct = maxCount > 0 ? Math.round((step.count / maxCount) * 100) : 0;
    const convFromPrev = i > 0 && steps[i - 1].count > 0
      ? Math.round((step.count / steps[i - 1].count) * 100)
      : null;
    const convColor = convFromPrev !== null
      ? (convFromPrev >= 80 ? 'var(--success)' : convFromPrev >= 50 ? 'var(--warning)' : 'var(--danger)')
      : '';
    return `
      <div style="display:flex;align-items:center;gap:10px;margin-bottom:10px;">
        <div style="min-width:130px;font-size:12px;color:var(--text);text-align:end;">${escapeHtml(t(step.key))}</div>
        <div style="flex:1;background:var(--border);border-radius:4px;height:18px;overflow:hidden;">
          <div style="width:${pct}%;height:100%;background:${step.color};border-radius:4px;transition:width .4s;display:flex;align-items:center;justify-content:flex-end;padding-inline-end:6px;">
            ${step.count > 0 ? `<span style="font-size:10px;font-weight:700;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.5);">${step.count}</span>` : ''}
          </div>
        </div>
        <div style="min-width:56px;font-size:12px;color:var(--text-muted);display:flex;flex-direction:column;align-items:flex-start;line-height:1.3;">
          <span>${step.count}</span>
          ${convFromPrev !== null ? `<span style="font-size:10px;color:${convColor};">${convFromPrev}%</span>` : ''}
        </div>
      </div>`;
  }).join('');

  const overallRate = funnel.totals.winRateByCount == null
    ? 0 : Math.round(funnel.totals.winRateByCount * 100);

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:12px;">
        <span class="swatch"></span>${escapeHtml(t('an.funnel_title'))}
        <span style="margin-inline-start:10px;font-size:11px;font-weight:600;padding:2px 8px;border-radius:10px;background:rgba(99,102,241,0.15);color:#818cf8;">
          ${escapeHtml(t('an.funnel_overall'))}: ${overallRate}%
        </span>
      </h3>
      ${rows}
    </div>`;
}

/* ── Monthly Revenue vs Expense Trend ───────────────────── */
function renderMonthlyTrendChart() {
  const el = $('#monthlyTrendChart');
  if (!el) return;

  // Build last 6 months (YYYY-MM strings, oldest first)
  const today = new Date();
  const months = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(today.getFullYear(), today.getMonth() - i, 1);
    months.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`);
  }

  const revByMonth = {};
  const expByMonth = {};
  months.forEach(m => { revByMonth[m] = 0; expByMonth[m] = 0; });

  for (const o of printLog) {
    if (o.status !== 'completed' || o.voidedAt) continue;
    const m = (o.date || '').slice(0, 7);
    if (revByMonth[m] !== undefined) revByMonth[m] += orderNetRevenueBase(o);
  }
  for (const e of expenses) {
    const m = (e.date || '').slice(0, 7);
    if (expByMonth[m] !== undefined) expByMonth[m] += +e.amount || 0;
  }

  const maxVal = Math.max(...months.map(m => Math.max(revByMonth[m], expByMonth[m])), 1);

  // SVG dimensions
  const svgW = 560, svgH = 160;
  const padL = 50, padR = 12, padT = 24, padB = 36;
  const chartW = svgW - padL - padR;
  const chartH = svgH - padT - padB;
  const groupW = chartW / months.length;
  const barW = Math.min(22, groupW * 0.35);
  const gap = 4;

  // Y-axis labels (3 lines: 0, 50%, 100%)
  const yLabels = [0, 0.5, 1].map(f => {
    const yVal = Math.round(maxVal * f);
    const y = padT + chartH - f * chartH;
    return `<text x="${padL - 6}" y="${y + 4}" text-anchor="end" font-size="9" fill="var(--text-muted)">${fmtMoney(yVal)}</text>
            <line x1="${padL}" y1="${y}" x2="${padL + chartW}" y2="${y}" stroke="var(--border)" stroke-dasharray="3,3" stroke-width="0.5"/>`;
  }).join('');

  const bars = months.map((m, i) => {
    const rev = revByMonth[m];
    const exp = expByMonth[m];
    const cx = padL + i * groupW + groupW / 2;
    const revH = rev > 0 ? Math.max(2, (rev / maxVal) * chartH) : 0;
    const expH = exp > 0 ? Math.max(2, (exp / maxVal) * chartH) : 0;
    const revY = padT + chartH - revH;
    const expY = padT + chartH - expH;
    const label = new Date(m + '-01').toLocaleDateString(localeTag(), { month: 'short' });
    const profit = rev - exp;
    const profitColor = profit >= 0 ? '#22c55e' : '#ef4444';

    return `
      <rect x="${cx - barW - gap / 2}" y="${revY}" width="${barW}" height="${revH}" fill="#22c55e" opacity="0.8" rx="2"/>
      <rect x="${cx + gap / 2}" y="${expY}" width="${barW}" height="${expH}" fill="#ef4444" opacity="0.7" rx="2"/>
      ${(rev > 0 || exp > 0) ? `<text x="${cx}" y="${Math.min(revY, expY) - 4}" text-anchor="middle" font-size="9" fill="${profitColor}" font-weight="600">${fmtMoney(profit)}</text>` : ''}
      <text x="${cx}" y="${padT + chartH + 16}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${label}</text>`;
  }).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.monthly_trend_title'))}</h3>
      <div style="display:flex;gap:16px;margin-bottom:8px;font-size:11px;">
        <span><span style="display:inline-block;width:10px;height:10px;background:#22c55e;border-radius:2px;margin-inline-end:4px;"></span>${escapeHtml(t('an.monthly_rev'))}</span>
        <span><span style="display:inline-block;width:10px;height:10px;background:#ef4444;border-radius:2px;margin-inline-end:4px;"></span>${escapeHtml(t('an.monthly_exp'))}</span>
        <span style="color:var(--text-muted);">${escapeHtml(t('an.monthly_profit_above'))}</span>
      </div>
      <svg viewBox="0 0 ${svgW} ${svgH}" style="width:100%;max-width:${svgW}px;overflow:visible;">
        ${yLabels}
        ${bars}
        <line x1="${padL}" y1="${padT}" x2="${padL}" y2="${padT + chartH}" stroke="var(--border)" stroke-width="1"/>
        <line x1="${padL}" y1="${padT + chartH}" x2="${padL + chartW}" y2="${padT + chartH}" stroke="var(--border)" stroke-width="1"/>
      </svg>
    </div>`;
}

/* ── Revenue forecast (regression over recent months → next 3) ──────────── */
function renderRevenueForecast() {
  const el = $('#revenueForecastChart');
  if (!el) return;
  if (typeof KhaytForecast === 'undefined') { el.innerHTML = ''; return; }
  const f = KhaytForecast.forecast(printLog, { now: Date.now(), months: 6, periods: 3, revenueOf: orderNetRevenueBase });
  if (f.method === 'none') { el.innerHTML = ''; return; } // nothing to forecast yet

  const monShort = (label) => { try { return new Date(label + '-01').toLocaleDateString(localeTag(), { month: 'short' }); } catch { return label; } };
  const series = [
    ...f.history.map((h) => ({ label: monShort(h.label), val: h.revenue, projected: false })),
    ...f.projection.map((p) => ({ label: monShort(p.label), val: p.projected, projected: true })),
  ];
  const maxVal = Math.max(...series.map((s) => s.val), 1);
  const svgW = 560, svgH = 160, padL = 50, padR = 12, padT = 24, padB = 36;
  const chartW = svgW - padL - padR, chartH = svgH - padT - padB;
  const groupW = chartW / series.length, barW = Math.min(26, groupW * 0.55);
  const yLabels = [0, 0.5, 1].map((fr) => {
    const y = padT + chartH - fr * chartH;
    return `<text x="${padL - 6}" y="${y + 4}" text-anchor="end" font-size="9" fill="var(--text-muted)">${fmtMoney(Math.round(maxVal * fr))}</text>
            <line x1="${padL}" y1="${y}" x2="${padL + chartW}" y2="${y}" stroke="var(--border)" stroke-dasharray="3,3" stroke-width="0.5"/>`;
  }).join('');
  const bars = series.map((s, i) => {
    const cx = padL + i * groupW + groupW / 2;
    const h = s.val > 0 ? Math.max(2, (s.val / maxVal) * chartH) : 0;
    const y = padT + chartH - h;
    const fill = s.projected ? 'var(--primary, #6366f1)' : '#22c55e';
    const op = s.projected ? '0.45' : '0.85';
    const dash = s.projected ? ' stroke="var(--primary,#6366f1)" stroke-width="1" stroke-dasharray="3,2"' : '';
    return `<rect x="${cx - barW / 2}" y="${y}" width="${barW}" height="${h}" fill="${fill}" opacity="${op}" rx="2"${dash}/>
      <text x="${cx}" y="${padT + chartH + 16}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${escapeHtml(s.label)}</text>`;
  }).join('');
  const trend = f.trendPct == null ? ''
    : `<span style="color:${f.trendPct >= 0 ? '#22c55e' : '#ef4444'};font-weight:600;">${f.trendPct >= 0 ? '▲' : '▼'} ${Math.abs(f.trendPct)}%</span>`;
  const note = f.method === 'average' ? ` · <span style="color:var(--text-muted);">${escapeHtml(t('an.forecast_avg') || 'based on average (limited history)')}</span>` : '';

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.forecast_title') || 'Revenue forecast')}</h3>
      <div style="font-size:13px;margin-bottom:8px;">
        ${escapeHtml(t('an.forecast_next') || 'Projected next month')}: <strong>${fmtPrice(f.nextMonth)}</strong> ${trend}${note}
      </div>
      <div style="display:flex;gap:16px;margin-bottom:8px;font-size:11px;">
        <span><span style="display:inline-block;width:10px;height:10px;background:#22c55e;border-radius:2px;margin-inline-end:4px;"></span>${escapeHtml(t('an.forecast_actual') || 'Actual')}</span>
        <span><span style="display:inline-block;width:10px;height:10px;background:var(--primary,#6366f1);opacity:.5;border-radius:2px;margin-inline-end:4px;"></span>${escapeHtml(t('an.forecast_projected') || 'Projected')}</span>
      </div>
      <svg viewBox="0 0 ${svgW} ${svgH}" style="width:100%;max-width:${svgW}px;overflow:visible;">
        ${yLabels}
        ${bars}
        <line x1="${padL}" y1="${padT}" x2="${padL}" y2="${padT + chartH}" stroke="var(--border)" stroke-width="1"/>
        <line x1="${padL}" y1="${padT + chartH}" x2="${padL + chartW}" y2="${padT + chartH}" stroke="var(--border)" stroke-width="1"/>
      </svg>
    </div>`;
}

/* ── Revenue by machine chart ───────────────────────────── */
function renderMachineRevenueChart() {
  const el = $('#machineRevenueChart');
  if (!el) return;

  const completed = printLog.filter(o => o.status === 'completed' && o.machineId);
  if (completed.length === 0) { el.innerHTML = ''; return; }

  const machMap = {};
  for (const m of machines) {
    machMap[m.id] = { name: m.name || m.model || m.id, color: m.color || '#6b7280', revenue: 0, count: 0 };
  }
  // Also capture orders with machineId that no longer maps to a known machine
  for (const o of completed) {
    if (!machMap[o.machineId]) {
      machMap[o.machineId] = { name: o.machine || o.machineId, color: '#6b7280', revenue: 0, count: 0 };
    }
    machMap[o.machineId].revenue += orderNetRevenueBase(o);
    machMap[o.machineId].count++;
  }

  const rows = Object.values(machMap)
    .filter(m => m.count > 0)
    .sort((a, b) => b.revenue - a.revenue);

  if (rows.length === 0) { el.innerHTML = ''; return; }

  const maxRev = rows[0].revenue;

  const bars = rows.map(m => {
    const pct = maxRev > 0 ? Math.round((m.revenue / maxRev) * 100) : 0;
    return `
      <div style="display:flex;align-items:center;gap:10px;margin-bottom:9px;">
        <div style="display:flex;align-items:center;gap:6px;min-width:130px;overflow:hidden;">
          <span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:${safeCssColor(m.color)};flex-shrink:0;"></span>
          <span style="font-size:12px;font-weight:500;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">${escapeHtml(m.name)}</span>
        </div>
        <div style="flex:1;background:var(--border);border-radius:4px;height:14px;overflow:hidden;">
          <div style="width:${pct}%;height:100%;background:${safeCssColor(m.color)};border-radius:4px;transition:width .4s;opacity:0.85;"></div>
        </div>
        <div style="min-width:100px;font-size:12px;text-align:end;">
          <span style="color:var(--success);font-weight:600;">${fmtPrice(m.revenue)}</span>
          <span style="color:var(--text-muted);font-size:11px;margin-inline-start:4px;">${m.count} ${escapeHtml(t('an.jobs') || 'jobs')}</span>
        </div>
      </div>`;
  }).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.machine_rev_title'))}</h3>
      <div style="padding:4px 0;">${bars}</div>
    </div>`;
}

function renderProfitMarginChart() {
  const el = $('#profitMarginChart');
  if (!el) return;

  const today = new Date();
  const months = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(today.getFullYear(), today.getMonth() - i, 1);
    months.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`);
  }

  // Blended, not the mean of per-order percentages. Averaging the percentages
  // let one tiny job dominate: a 100 order at 80% margin beside a 10,000 order
  // at 10% read as 45% (and coloured green) when the month's real margin was
  // 10.7%. Accumulate money, divide once.
  const marginByMonth = {};
  months.forEach(m => { marginByMonth[m] = { revenue: 0, cost: 0, count: 0 }; });
  for (const o of printLog) {
    // _countsForBusiness for the same reason every other revenue figure has it:
    // a print the shop marked as not business must not appear in a margin
    // report. This was the one money loop over printLog without the gate.
    if (o.status !== 'completed' || o.voidedAt || !_countsForBusiness(o) || !o.costBasis || !+o.price) continue;
    const m = (o.date || '').slice(0, 7);
    if (!marginByMonth[m]) continue;
    // Net of credit notes, in the ORDER's currency to stay paired with costBasis
    // (which is summed from part baseCost). Converting only one side would skew
    // the ratio for multi-currency orders.
    marginByMonth[m].revenue += Math.max(0, (+o.price || 0) - orderCreditedRaw(o));
    marginByMonth[m].cost += +o.costBasis;
    marginByMonth[m].count++;
  }

  const vals = months.map(m => {
    const b = marginByMonth[m];
    return (b.count > 0 && b.revenue > 0) ? (b.revenue - b.cost) / b.revenue * 100 : null;
  });

  const hasData = vals.some(v => v !== null);
  if (!hasData) { el.innerHTML = ''; return; }

  const maxVal = Math.max(...vals.filter(v => v !== null), 1);
  const H = 120, BAR_W = 40, GAP = 28;
  const total = months.length;
  const chartW = total * (BAR_W + GAP);

  const bars = months.map((m, i) => {
    const v = vals[i];
    if (v === null) return '';
    const bh = Math.max(4, Math.round((v / maxVal) * (H - 30)));
    const x = i * (BAR_W + GAP);
    const y = H - 22 - bh;
    const col = v >= 40 ? '#22c55e' : v >= 20 ? '#f59e0b' : '#ef4444';
    const label = m.slice(5);
    return `<rect x="${x}" y="${y}" width="${BAR_W}" height="${bh}" rx="3" fill="${col}" opacity="0.85"/>
      <text x="${x + BAR_W / 2}" y="${y - 4}" text-anchor="middle" font-size="10" fill="${col}">${v.toFixed(0)}%</text>
      <text x="${x + BAR_W / 2}" y="${H - 6}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${escapeHtml(label)}</text>`;
  }).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:12px;">
        <span class="swatch"></span>${escapeHtml(t('an.profit_margin_title') || 'Avg Profit Margin by Month')}
      </h3>
      <div style="overflow-x:auto;">
        <svg width="${chartW}" height="${H}" style="display:block;min-width:200px;">
          ${bars}
        </svg>
      </div>
    </div>`;
}

// ── Analytics Round 13: 9 new charts ──────────────────────────────────────────

function renderWasteTrendChart() {
  const el = $('#wasteTrendChart');
  if (!el) return;

  const today = new Date();
  const months = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(today.getFullYear(), today.getMonth() - i, 1);
    months.push({
      key: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
      label: `${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getFullYear()).slice(2)}`
    });
  }

  const failureColors = { warping: '#f59e0b', adhesion: '#ef4444', stringing: '#f97316' };
  const topTypes = ['warping', 'adhesion', 'stringing'];

  // Build data: {month -> {failureType -> weight}}
  const data = {};
  months.forEach(m => { data[m.key] = {}; topTypes.forEach(t2 => { data[m.key][t2] = 0; }); data[m.key]['other'] = 0; });

  for (const w of (wasteLog || [])) {
    if (!w.date) continue;
    const mk = localMonthStr(new Date(w.date));
    if (!data[mk]) continue;
    const ft = topTypes.includes(w.failureType) ? w.failureType : 'other';
    data[mk][ft] = (data[mk][ft] || 0) + (+w.weight || 0);
  }

  const allTypes = [...topTypes, 'other'];
  const typeColors = { ...failureColors, other: '#6b7280' };
  const allVals = months.flatMap(m => allTypes.map(ft => data[m.key][ft]));
  const hasData = allVals.some(v => v > 0);

  if (!hasData) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.waste_trend') || 'Waste by Failure Type')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  const maxVal = Math.max(...months.map(m => allTypes.reduce((s, ft) => s + data[m.key][ft], 0)), 1);
  const H = 140, BAR_W = 14, GAP = 30;
  const groupW = allTypes.length * BAR_W + 4;
  const chartW = months.length * (groupW + GAP);

  const bars = months.map((m, mi) => {
    const gx = mi * (groupW + GAP);
    const bars2 = allTypes.map((ft, fi) => {
      const v = data[m.key][ft];
      if (!v) return '';
      const bh = Math.max(3, Math.round((v / maxVal) * (H - 32)));
      const x = gx + fi * BAR_W;
      const y = H - 22 - bh;
      return `<rect x="${x}" y="${y}" width="${BAR_W - 2}" height="${bh}" rx="2" fill="${typeColors[ft]}" opacity="0.85"/>`;
    }).join('');
    return `${bars2}<text x="${gx + groupW / 2}" y="${H - 6}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${escapeHtml(m.label)}</text>`;
  }).join('');

  const legend = allTypes.map(ft => `<span style="display:inline-flex;align-items:center;gap:4px;margin-inline-end:10px;font-size:11px;color:var(--text-muted);"><span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${typeColors[ft]};"></span>${escapeHtml(ft)}</span>`).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:8px;"><span class="swatch"></span>${escapeHtml(t('an.waste_trend') || 'Waste by Failure Type')}</h3>
      <div style="margin-bottom:6px;">${legend}</div>
      <div style="overflow-x:auto;">
        <svg width="${chartW}" height="${H}" style="display:block;min-width:200px;">${bars}</svg>
      </div>
    </div>`;
}

function renderCycleTimeChart() {
  const el = $('#cycleTimeChart');
  if (!el) return;

  const today = new Date();
  const months = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(today.getFullYear(), today.getMonth() - i, 1);
    months.push({
      key: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
      label: `${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getFullYear()).slice(2)}`
    });
  }

  const byMonth = {};
  months.forEach(m => { byMonth[m.key] = { total: 0, count: 0 }; });

  for (const o of (printLog || [])) {
    if (o.status !== 'completed' || !o.date || !o.completedAt) continue;
    const mk = localMonthStr(new Date(o.completedAt));
    if (!byMonth[mk]) continue;
    const days = (new Date(o.completedAt) - new Date(o.date)) / 86400000;
    if (days < 0) continue;
    byMonth[mk].total += days;
    byMonth[mk].count++;
  }

  const vals = months.map(m => {
    const b = byMonth[m.key];
    return b.count > 0 ? b.total / b.count : null;
  });

  const hasData = vals.some(v => v !== null);
  if (!hasData) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.cycle_time') || 'Avg Cycle Time (days)')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  const maxVal = Math.max(...vals.filter(v => v !== null), 1);
  const H = 130, BAR_W = 40, GAP = 28;
  const chartW = months.length * (BAR_W + GAP);

  const bars = months.map((m, i) => {
    const v = vals[i];
    if (v === null) return `<text x="${i * (BAR_W + GAP) + BAR_W / 2}" y="${H - 6}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${escapeHtml(m.label)}</text>`;
    const bh = Math.max(4, Math.round((v / maxVal) * (H - 36)));
    const x = i * (BAR_W + GAP);
    const y = H - 22 - bh;
    const label = v.toFixed(1);
    return `<rect x="${x}" y="${y}" width="${BAR_W}" height="${bh}" rx="3" fill="var(--primary)" opacity="0.8"/>
      <text x="${x + BAR_W / 2}" y="${y - 4}" text-anchor="middle" font-size="10" fill="var(--primary)">${escapeHtml(label)}</text>
      <text x="${x + BAR_W / 2}" y="${H - 6}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${escapeHtml(m.label)}</text>`;
  }).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:12px;"><span class="swatch"></span>${escapeHtml(t('an.cycle_time') || 'Avg Cycle Time (days)')}</h3>
      <div style="overflow-x:auto;">
        <svg width="${chartW}" height="${H}" style="display:block;min-width:200px;">${bars}</svg>
      </div>
    </div>`;
}

function renderCashFlowChart() {
  const el = $('#cashFlowChart');
  if (!el) return;

  const today = new Date();
  const months = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(today.getFullYear(), today.getMonth() - i, 1);
    months.push({
      key: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
      label: `${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getFullYear()).slice(2)}`
    });
  }

  // `lib/cash-flow.js`, not the arithmetic that used to be here — which had
  // three faults, and the first is the one that matters:
  //
  //   `paidAt` is set on ANY payment, a deposit included, and this counted the
  //   job's WHOLE revenue on that day. A 10% deposit on a 20,000 job drew
  //   20,000 of cash in, on the one chart whose entire subject is money the
  //   shop actually has.
  //
  // It also counted voided orders, and ignored the business scope that every
  // neighbouring figure applies.
  const flow = KhaytCashFlow.cashFlow({
    orders: printLog || [],
    expenses: expenses || [],
    endMonth: localMonthStr(today),
    months: months.length,
  }, { revenueOf: orderNetRevenueBase, countsForBusiness: _countsForBusiness });
  const revByMonth = {};
  const expByMonth = {};
  for (const r of flow.rows) { revByMonth[r.month] = r.collected; expByMonth[r.month] = r.paidOut; }

  const hasData = flow.totals.anyMovement;
  if (!hasData) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.cash_flow') || 'Cash Flow')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  const maxVal = Math.max(...months.flatMap(m => [revByMonth[m.key], expByMonth[m.key]]), 1);
  const H = 140, BAR_W = 22, GAP = 28;
  const groupW = BAR_W * 2 + 4;
  const chartW = months.length * (groupW + GAP);

  const bars = months.map((m, i) => {
    const rv = revByMonth[m.key];
    const ev = expByMonth[m.key];
    const gx = i * (groupW + GAP);
    const rbh = Math.max(rv > 0 ? 3 : 0, Math.round((rv / maxVal) * (H - 32)));
    const ebh = Math.max(ev > 0 ? 3 : 0, Math.round((ev / maxVal) * (H - 32)));
    return `${rbh > 0 ? `<rect x="${gx}" y="${H - 22 - rbh}" width="${BAR_W}" height="${rbh}" rx="2" fill="var(--success)" opacity="0.85"/>` : ''}
      ${ebh > 0 ? `<rect x="${gx + BAR_W + 4}" y="${H - 22 - ebh}" width="${BAR_W}" height="${ebh}" rx="2" fill="var(--danger)" opacity="0.75"/>` : ''}
      <text x="${gx + groupW / 2}" y="${H - 6}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${escapeHtml(m.label)}</text>`;
  }).join('');

  const legend = `<span style="display:inline-flex;align-items:center;gap:4px;margin-inline-end:10px;font-size:11px;color:var(--text-muted);"><span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:var(--success);"></span>${escapeHtml(t('an.collected') || 'Collected')}</span><span style="display:inline-flex;align-items:center;gap:4px;font-size:11px;color:var(--text-muted);"><span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:var(--danger);"></span>${escapeHtml(t('an.expenses_paid') || 'Expenses')}</span>`;

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:8px;"><span class="swatch"></span>${escapeHtml(t('an.cash_flow') || 'Cash Flow')}</h3>
      <div style="margin-bottom:6px;">${legend}</div>
      <div style="overflow-x:auto;">
        <svg width="${chartW}" height="${H}" style="display:block;min-width:200px;">${bars}</svg>
      </div>
      ${flow.totals.undated > 0 ? `<p style="color:var(--text-muted);font-size:12px;margin:6px 0 0;">${escapeHtml(t('an.cf_undated', { amount: fmtPrice(flow.totals.undated) }))}</p>` : ''}
    </div>`;
}

function renderExpenseCategoryChart() {
  const el = $('#expenseCategoryChart');
  if (!el) return;

  const filtered = (expenses || []).filter(e => inRange(e.date, analyticsRange, 'analytics'));
  if (!filtered.length) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.exp_by_cat') || 'Expenses by Category')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  const totals = {};
  for (const e of filtered) {
    const cat = e.category || 'other';
    totals[cat] = (totals[cat] || 0) + (+e.amount || 0);
  }

  const sorted = Object.entries(totals).sort((a, b) => b[1] - a[1]);
  const grand = sorted.reduce((s, [, v]) => s + v, 0) || 1;
  const maxV = sorted[0]?.[1] || 1;
  const BAR_MAX_W = 200;

  const rows = sorted.map(([cat, v]) => {
    const pct = Math.round(v / grand * 100);
    const bw = Math.round((v / maxV) * BAR_MAX_W);
    return `<tr>
      <td style="padding:6px 8px;font-size:12px;white-space:nowrap;">${escapeHtml(expCatLabel(cat))}</td>
      <td style="padding:6px 8px;">
        <div style="background:var(--primary);opacity:0.7;height:14px;border-radius:3px;width:${bw}px;min-width:4px;"></div>
      </td>
      <td style="padding:6px 8px;font-size:12px;text-align:end;white-space:nowrap;">${escapeHtml(fmtPrice(v))}</td>
      <td style="padding:6px 8px;font-size:11px;color:var(--text-muted);text-align:end;">${pct}%</td>
    </tr>`;
  }).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:12px;"><span class="swatch"></span>${escapeHtml(t('an.exp_by_cat') || 'Expenses by Category')}</h3>
      <div style="overflow-x:auto;">
        <table style="border-collapse:collapse;width:100%;"><tbody>${rows}</tbody></table>
      </div>
    </div>`;
}

function renderLeadTimeChart() {
  const el = $('#leadTimeTable');
  if (!el) return;

  const completed = (printLog || []).filter(o => o.status === 'completed' && o.date && o.completedAt);
  if (completed.length < 3) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.lead_time') || 'Lead Time by Product')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  const byProduct = {};
  for (const o of completed) {
    const key = o.project || o.name || 'Unknown';
    const days = (new Date(o.completedAt) - new Date(o.date)) / 86400000;
    if (days < 0) continue;
    if (!byProduct[key]) byProduct[key] = { total: 0, count: 0, min: Infinity, max: -Infinity };
    byProduct[key].total += days;
    byProduct[key].count++;
    if (days < byProduct[key].min) byProduct[key].min = days;
    if (days > byProduct[key].max) byProduct[key].max = days;
  }

  const rows = Object.entries(byProduct)
    .map(([name, d]) => ({ name, avg: d.total / d.count, fastest: d.min, slowest: d.max, count: d.count }))
    .sort((a, b) => b.avg - a.avg)
    .slice(0, 10);

  const daysLabel = escapeHtml(t('an.days') || 'days');
  const tableRows = rows.map(r => `<tr>
    <td style="padding:6px 8px;font-size:12px;">${escapeHtml(r.name)}</td>
    <td style="padding:6px 8px;font-size:12px;text-align:end;">${r.avg.toFixed(1)} ${daysLabel}</td>
    <td style="padding:6px 8px;font-size:12px;text-align:end;">${r.fastest.toFixed(1)}</td>
    <td style="padding:6px 8px;font-size:12px;text-align:end;">${r.slowest.toFixed(1)}</td>
    <td style="padding:6px 8px;font-size:12px;text-align:end;">${r.count}</td>
  </tr>`).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:12px;"><span class="swatch"></span>${escapeHtml(t('an.lead_time') || 'Lead Time by Product')}</h3>
      <div style="overflow-x:auto;">
        <table style="border-collapse:collapse;width:100%;font-size:12px;">
          <thead><tr style="border-bottom:1px solid var(--border);">
            <th style="padding:6px 8px;text-align:start;">${escapeHtml(t('ord.project') || 'Product')}</th>
            <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('an.lead_time_avg') || 'Avg Days')}</th>
            <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('an.lead_time_fastest') || 'Fastest')}</th>
            <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('an.lead_time_slowest') || 'Slowest')}</th>
            <th style="padding:6px 8px;text-align:end;">#</th>
          </tr></thead>
          <tbody>${tableRows}</tbody>
        </table>
      </div>
    </div>`;
}

function renderNpsTrendChart() {
  const el = $('#npsTrendChart');
  if (!el) return;

  const today = new Date();
  const months = [];
  for (let i = 5; i >= 0; i--) {
    const d = new Date(today.getFullYear(), today.getMonth() - i, 1);
    months.push({
      key: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
      label: `${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getFullYear()).slice(2)}`
    });
  }

  const ratedOrders = (printLog || []).filter(o => o.survey?.rating && o.completedAt);
  if (ratedOrders.length < 3) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.nps_trend') || 'Customer Rating Trend')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  const byMonth = {};
  months.forEach(m => { byMonth[m.key] = { total: 0, count: 0 }; });
  for (const o of ratedOrders) {
    const mk = localMonthStr(new Date(o.completedAt));
    if (!byMonth[mk]) continue;
    byMonth[mk].total += +o.survey.rating;
    byMonth[mk].count++;
  }

  const totalResponses = ratedOrders.length;
  const globalAvg = ratedOrders.reduce((s, o) => s + +o.survey.rating, 0) / totalResponses;

  const vals = months.map(m => {
    const b = byMonth[m.key];
    return b.count > 0 ? b.total / b.count : null;
  });

  const H = 120, W_PER = 60;
  const chartW = months.length * W_PER;
  const MIN_R = 1, MAX_R = 5;

  const points = months.map((m, i) => {
    const v = vals[i];
    if (v === null) return null;
    const x = i * W_PER + W_PER / 2;
    const y = Math.round(H - 24 - ((v - MIN_R) / (MAX_R - MIN_R)) * (H - 40));
    return { x, y, v };
  }).filter(Boolean);

  const polyline = points.length >= 2
    ? `<polyline points="${points.map(p => `${p.x},${p.y}`).join(' ')}" fill="none" stroke="var(--primary)" stroke-width="2" stroke-linejoin="round"/>`
    : '';

  const dots = points.map(p => `<circle cx="${p.x}" cy="${p.y}" r="4" fill="var(--primary)"/>
    <text x="${p.x}" y="${p.y - 8}" text-anchor="middle" font-size="10" fill="var(--primary)">${p.v.toFixed(1)}</text>`).join('');

  const labels = months.map((m, i) => `<text x="${i * W_PER + W_PER / 2}" y="${H - 6}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${escapeHtml(m.label)}</text>`).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:12px;"><span class="swatch"></span>${escapeHtml(t('an.nps_trend') || 'Customer Rating Trend')}</h3>
      <div style="overflow-x:auto;">
        <svg width="${chartW}" height="${H}" style="display:block;min-width:200px;">${polyline}${dots}${labels}</svg>
      </div>
      <p style="font-size:12px;color:var(--text-muted);margin-top:6px;">${escapeHtml(String(totalResponses))} ${escapeHtml(t('an.nps_responses') || 'responses · Avg')} ${globalAvg.toFixed(1)} / 5</p>
    </div>`;
}

function renderClientLtvTable() {
  const el = $('#clientLtvTable');
  if (!el) return;

  if (!(clients || []).length) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.client_ltv') || 'Client Lifetime Value')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  // `lib/client-value.js`, not the arithmetic that used to be here — which
  // counted EVERY order carrying the client's id, with no status check at all.
  // So a customer who asked for ten quotes and bought nothing sat at the top of
  // "lifetime value", which is the one place on this screen that must not
  // reward asking. Voided orders and work outside the shop's trade counted too.
  const report = KhaytClientValue.clientValue({
    clients: clients || [], orders: printLog || [], now: Date.now(), limit: 10,
  }, {
    revenueOf: orderNetRevenueBase,
    countsForBusiness: _countsForBusiness,
  });
  const ltvData = report.rows.map((r) => ({
    name: r.name || '—', ltv: r.value, count: r.jobs, avgVal: r.averageJob,
    lastOrder: r.lastSeen == null ? null : new Date(r.lastSeen), churnRisk: r.quiet,
  }));

  if (!ltvData.some(d => d.ltv > 0)) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.client_ltv') || 'Client Lifetime Value')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  const tableRows = ltvData.map((d, i) => `<tr>
    <td style="padding:6px 8px;font-size:12px;">${i + 1}</td>
    <td style="padding:6px 8px;font-size:12px;">${escapeHtml(d.name)}${d.churnRisk ? ` <span title="${escapeHtml(t('an.churn_risk') || 'Churn risk')}">🟡</span>` : ''}</td>
    <td style="padding:6px 8px;font-size:12px;text-align:end;font-weight:600;">${escapeHtml(fmtPrice(d.ltv))}</td>
    <td style="padding:6px 8px;font-size:12px;text-align:end;">${d.count}</td>
    <td style="padding:6px 8px;font-size:12px;text-align:end;">${escapeHtml(fmtPrice(d.avgVal))}</td>
    <td style="padding:6px 8px;font-size:12px;text-align:end;color:var(--text-muted);">${d.lastOrder ? escapeHtml(localDateStr(d.lastOrder)) : '—'}</td>
  </tr>`).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:12px;"><span class="swatch"></span>${escapeHtml(t('an.client_ltv') || 'Client Lifetime Value')}</h3>
      <div style="overflow-x:auto;">
        <table style="border-collapse:collapse;width:100%;font-size:12px;">
          <thead><tr style="border-bottom:1px solid var(--border);">
            <th style="padding:6px 8px;text-align:start;">#</th>
            <th style="padding:6px 8px;text-align:start;">${escapeHtml(t('cl.name') || 'Client')}</th>
            <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('an.ltv') || 'LTV')}</th>
            <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('an.op_jobs') || '# Orders')}</th>
            <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('an.avg_order') || 'Avg')}</th>
            <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('ord.date') || 'Last Order')}</th>
          </tr></thead>
          <tbody>${tableRows}</tbody>
        </table>
      </div>
    </div>`;
}

function renderMachineDowntimeChart() {
  const el = $('#machineDowntimeChart');
  if (!el) return;

  const today = new Date();
  const months = [];
  for (let i = 2; i >= 0; i--) {
    const d = new Date(today.getFullYear(), today.getMonth() - i, 1);
    months.push({
      key: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
      label: `${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getFullYear()).slice(2)}`,
      start: new Date(d.getFullYear(), d.getMonth(), 1),
      end:   new Date(d.getFullYear(), d.getMonth() + 1, 0, 23, 59, 59, 999)
    });
  }

  const machineData = (machines || []).map(mach => {
    const blocks = mach.downtimeBlocks || [];
    const hoursByMonth = months.map(m => {
      let total = 0;
      for (const b of blocks) {
        if (!b.from || !b.to) continue;
        const bFrom = new Date(b.from);
        const bTo   = new Date(b.to);
        const start = bFrom < m.start ? m.start : bFrom;
        const end   = bTo   > m.end   ? m.end   : bTo;
        if (end > start) total += (end - start) / 3600000;
      }
      return total;
    });
    return { name: mach.name || mach.id, hoursByMonth, total: hoursByMonth.reduce((s, h) => s + h, 0) };
  }).filter(d => d.total > 0);

  if (!machineData.length) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.downtime') || 'Machine Downtime (hrs/month)')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  const stackColors = ['#6366f1', '#f59e0b', '#10b981', '#ef4444', '#8b5cf6'];
  const maxMonthTotal = Math.max(...months.map((_, mi) => machineData.reduce((s, md) => s + md.hoursByMonth[mi], 0)), 1);
  const H = 140, BAR_W = 40, GAP = 24;
  const chartW = months.length * (BAR_W + GAP);

  const bars = months.map((m, mi) => {
    const x = mi * (BAR_W + GAP);
    let yOffset = H - 22;
    const segments = machineData.map((md, ki) => {
      const v = md.hoursByMonth[mi];
      if (!v) return '';
      const bh = Math.max(2, Math.round((v / maxMonthTotal) * (H - 36)));
      yOffset -= bh;
      return `<rect x="${x}" y="${yOffset}" width="${BAR_W}" height="${bh}" rx="0" fill="${stackColors[ki % stackColors.length]}" opacity="0.85"/>`;
    }).join('');
    return `${segments}<text x="${x + BAR_W / 2}" y="${H - 6}" text-anchor="middle" font-size="10" fill="var(--text-muted)">${escapeHtml(m.label)}</text>`;
  }).join('');

  const legend = machineData.map((md, ki) => `<span style="display:inline-flex;align-items:center;gap:4px;margin-inline-end:10px;font-size:11px;color:var(--text-muted);"><span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${stackColors[ki % stackColors.length]};"></span>${escapeHtml(md.name)}</span>`).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:8px;"><span class="swatch"></span>${escapeHtml(t('an.downtime') || 'Machine Downtime (hrs/month)')}</h3>
      <div style="margin-bottom:6px;">${legend}</div>
      <div style="overflow-x:auto;">
        <svg width="${chartW}" height="${H}" style="display:block;min-width:120px;">${bars}</svg>
      </div>
    </div>`;
}

function renderMaintenanceCostChart() {
  const el = $('#maintenanceCostChart');
  if (!el) return;

  const currentYear = new Date().getFullYear();

  const machData = (machines || []).map(mach => {
    const log = mach.machMaintLog || [];
    const total = log.reduce((s, entry) => {
      if (!entry.date) return s;
      if (new Date(entry.date).getFullYear() !== currentYear) return s;
      return s + (+entry.cost || 0);
    }, 0);
    return { name: mach.name || mach.id, total };
  }).filter(d => d.total > 0).sort((a, b) => b.total - a.total);

  if (!machData.length) {
    el.innerHTML = `<div class="card" style="margin-bottom:16px;"><h3 class="card-head"><span class="swatch"></span>${escapeHtml(t('an.maint_cost') || 'Maintenance Cost by Machine')}</h3><p style="color:var(--text-muted);padding:12px 0;font-size:13px;">${escapeHtml(t('an.no_data') || 'No data yet')}</p></div>`;
    return;
  }

  const maxVal = machData[0].total || 1;
  const H = 130, BAR_W = 44, GAP = 20;
  const chartW = machData.length * (BAR_W + GAP);

  const bars = machData.map((d, i) => {
    const bh = Math.max(4, Math.round((d.total / maxVal) * (H - 48)));
    const x = i * (BAR_W + GAP);
    const y = H - 40 - bh;
    return `<rect x="${x}" y="${y}" width="${BAR_W}" height="${bh}" rx="3" fill="var(--warning)" opacity="0.85"/>
      <text x="${x + BAR_W / 2}" y="${y - 4}" text-anchor="middle" font-size="9" fill="var(--warning)">${escapeHtml(fmtPrice(d.total))}</text>
      <text x="${x + BAR_W / 2}" y="${H - 22}" text-anchor="middle" font-size="9" fill="var(--text-muted)" style="overflow:hidden;">${escapeHtml(d.name.slice(0, 10))}</text>`;
  }).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;">
      <h3 class="card-head" style="margin-bottom:12px;"><span class="swatch"></span>${escapeHtml(t('an.maint_cost') || 'Maintenance Cost by Machine')}</h3>
      <div style="overflow-x:auto;">
        <svg width="${chartW}" height="${H}" style="display:block;min-width:120px;">${bars}</svg>
      </div>
    </div>`;
}

function renderMachineAccuracy() {
  const el = $('#machineAccuracySection');
  if (!el) return;
  if (typeof KhaytMachineAccuracy === 'undefined'
      || typeof KhaytPrinterActuals === 'undefined'
      || typeof KhaytEstimateVariance === 'undefined') { el.innerHTML = ''; return; }

  // The rule, not a fourth copy of the arithmetic. It reads the duration the
  // PRINTER reported and refuses a typed one — see lib/machine-accuracy.js for
  // why the wall clock cannot answer this and why the median is taken rather
  // than the ratio of totals.
  const deps = {
    compare: KhaytPrinterActuals.compareToEstimate,
    median: KhaytEstimateVariance.median,
    confidence: KhaytEstimateVariance.confidenceFor,
  };
  const rows = KhaytMachineAccuracy.accuracyByMachine(printLog, deps);
  const all  = KhaytMachineAccuracy.accuracyOverall(printLog, deps);

  if (!rows.length) {
    // Said, not left blank. A shop with a rack of finished prints and an empty
    // panel deserves to know the figures are waiting on a MEASURED time.
    el.innerHTML = `<div style="margin-top:12px;"><p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.accuracy_none'))}</p></div>`;
    return;
  }

  const pct = (v) => (v === null ? '—' : (v >= 0 ? '+' : '') + v.toFixed(1) + '%');
  // Over is what costs a shop money; under is worth knowing and is not a fault.
  const col = (v) => (v === null ? 'var(--text-muted)'
    : v >= 25 ? 'var(--danger)' : v >= 10 ? 'var(--warning)' : 'var(--success)');

  el.innerHTML = `
    <div style="margin-top:12px;">
      <div style="font-size:12px; font-weight:600; color:var(--text-muted); margin-bottom:8px;">${escapeHtml(t('an.machine_accuracy'))}</div>
      ${all ? `<div style="font-size:12px; color:var(--text-muted); margin-bottom:8px;">
        ${escapeHtml(t('an.actual_vs_est', {
          actual: all.actHours === null ? '—' : all.actHours.toFixed(1),
          est: all.estHours === null ? '—' : all.estHours.toFixed(1),
          diff: all.hoursDeltaPct === null ? '—' : pct(all.hoursDeltaPct).replace('%', ''),
        }))} · ${escapeHtml(t('an.accuracy_measured', { n: all.sampled }))}
      </div>` : ''}
      <div style="display:flex; flex-direction:column; gap:5px;">
        ${rows.map((r) => {
          const machine = machines.find((m) => m.id === r.machineId);
          const name = machine ? machine.name : t('dash.unassigned');
          const colour = machine?.color || '#888';
          return `
          <div style="display:flex; align-items:center; gap:10px; font-size:12.5px;">
            <span style="display:inline-block; width:10px; height:10px; border-radius:50%; background:${safeCssColor(colour)}; flex-shrink:0;"></span>
            <span style="flex:1; font-weight:500;">${escapeHtml(name)}</span>
            <span style="color:var(--text-muted); font-size:11px;">${escapeHtml(t('an.accuracy_measured', { n: r.sampled }))}</span>
            <span style="color:var(--text-muted); font-size:11px;">${r.estHours === null ? '—' : r.estHours.toFixed(1)}h est</span>
            <span style="color:var(--text-muted); font-size:11px;">&rarr;</span>
            <span style="color:var(--text-muted); font-size:11px;">${r.actHours === null ? '—' : r.actHours.toFixed(1)}h actual</span>
            <span style="font-weight:700; min-width:52px; text-align:end; color:${col(r.hoursDeltaPct)};">${escapeHtml(pct(r.hoursDeltaPct))}</span>
          </div>`;
        }).join('')}
      </div>
    </div>`;
}

/* ============================================================
   Tab badge counts
   ============================================================ */

/* ============================================================
   New vs returning client revenue split
   ============================================================ */
function renderNewVsReturning() {
  const el = $('#newVsReturningSection');
  if (!el) return;
  // `lib/customer-mix.js`, not the arithmetic that used to be here. It decided
  // who was new by comparing DATES — `firstOrderDate[id] === o.date` — so a
  // customer whose first two jobs landed on the same day counted as new twice,
  // and a shop taking two jobs from one new customer recorded two
  // new-customer sales. Identity is the ORDER, not the day.
  //
  // It also counted voided orders, ignored the business scope, and counted
  // `completed` only — so work that reached the customer was in neither half.
  //
  // The window is applied by the module; history is handed over whole, because
  // who is NEW cannot be decided from a slice of it.
  const mix = KhaytCustomerMix.customerMix({ orders: printLog || [] }, {
    revenueOf: orderNetRevenueBase,
    countsForBusiness: _countsForBusiness,
    // The range picker's own predicate. It offers named periods — "this
    // quarter" — and `lib/date-range.js` already answers what they mean, so
    // the module takes the question rather than a pair of dates re-derived
    // here, which would be a second answer.
    inWindow: (o) => inRange(o.date, analyticsRange, 'analytics'),
  });
  if (mix.totals.jobs === 0) { el.innerHTML = ''; return; }

  const newRev = mix.fresh.revenue, retRev = mix.returning.revenue;
  const newCount = mix.fresh.jobs, retCount = mix.returning.jobs;
  const total = mix.totals.revenue;
  const newPct  = total > 0 ? Math.round(newRev / total * 100) : 0;
  const retPct  = 100 - newPct;

  el.innerHTML = `
    <div style="display:flex;gap:16px;flex-wrap:wrap;margin-bottom:10px;">
      <div style="flex:1;min-width:120px;text-align:center;padding:10px;background:var(--surface-2);border-radius:var(--radius);">
        <div style="font-size:20px;font-weight:700;color:var(--primary);">${fmtMoney(newRev)}</div>
        <div style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('an.new_clients'))} (${newCount} ${escapeHtml(t('an.orders_count'))})</div>
      </div>
      <div style="flex:1;min-width:120px;text-align:center;padding:10px;background:var(--surface-2);border-radius:var(--radius);">
        <div style="font-size:20px;font-weight:700;color:var(--success);">${fmtMoney(retRev)}</div>
        <div style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('an.returning_clients'))} (${retCount} ${escapeHtml(t('an.orders_count'))})</div>
      </div>
    </div>
    ${total > 0 ? `
    <div style="height:12px;border-radius:6px;overflow:hidden;display:flex;">
      <div style="width:${newPct}%;background:var(--primary);transition:width .3s;" title="${escapeHtml(t('an.new_clients'))}: ${newPct}%"></div>
      <div style="flex:1;background:var(--success);transition:width .3s;" title="${escapeHtml(t('an.returning_clients'))}: ${retPct}%"></div>
    </div>
    <div style="display:flex;gap:16px;margin-top:5px;font-size:11.5px;color:var(--text-muted);">
      <span>● ${escapeHtml(t('an.new_clients'))}: ${newPct}%</span>
      <span>● ${escapeHtml(t('an.returning_clients'))}: ${retPct}%</span>
    </div>` : ''}`;
}

/* ============================================================
   Printer utilization chart — hours per machine
   ============================================================ */
function renderPrinterUtilizationChart() {
  const el = $('#printerUtilSection');
  if (!el || machines.length === 0) { if (el) el.innerHTML = ''; return; }

  const orders = printLog.filter(o => inRange(o.date, analyticsRange, 'analytics') && o.status === 'completed' && !o.voidedAt && _countsForBusiness(o));
  const machMap = {};
  for (const m of machines) machMap[m.id] = { name: m.name, color: m.color, hours: 0, revenue: 0, cost: 0, count: 0 };
  for (const o of orders) {
    const key = o.machineId || '__none__';
    if (!machMap[key]) continue;
    machMap[key].hours += +o.printTime || 0;
    machMap[key].revenue += orderNetRevenueBase(o);
    machMap[key].count++;
    // Estimate material + machine cost from order parts
    const orderCost = (o.parts || []).reduce((s, p) => s + partTotalCost(p), 0);
    machMap[key].cost += orderCost;
  }
  // Determine date range for utilization calculation
  const now2 = new Date();
  const rangeDays = analyticsRangeDays(analyticsRange, 'analytics', orders.map(o => o.date));

  // Attach targetHoursPerDay from machines array to machMap
  for (const m of machines) {
    if (machMap[m.id]) machMap[m.id].targetHoursPerDay = m.targetHoursPerDay || null;
  }

  const rows = Object.values(machMap).filter(m => m.hours > 0).sort((a, b) => b.revenue - a.revenue);
  if (rows.length === 0) { el.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.no_utilization'))}</p>`; return; }

  const maxRev = Math.max(...rows.map(r => r.revenue), 1);
  el.innerHTML = rows.map(r => {
    const pct = (r.revenue / maxRev) * 100;
    const margin = r.cost > 0 && r.revenue > 0 ? ((r.revenue - r.cost) / r.revenue * 100) : null;
    const marginStr = margin !== null ? `${margin.toFixed(1)}%` : '—';
    const marginCol = margin !== null ? (margin >= 30 ? 'var(--success)' : margin >= 10 ? 'var(--warning)' : 'var(--danger)') : 'var(--text-muted)';
    // Utilization %
    let utilStr = '';
    if (r.targetHoursPerDay) {
      const targetTotal = r.targetHoursPerDay * rangeDays;
      const utilPct = targetTotal > 0 ? Math.min(100, (r.hours / targetTotal) * 100) : null;
      if (utilPct !== null) {
        const utilCol = utilPct >= 80 ? 'var(--success)' : utilPct >= 50 ? 'var(--warning)' : 'var(--danger)';
        utilStr = ` · <span style="color:${utilCol};font-weight:600;">${escapeHtml(t('an.utilization_pct'))}: ${utilPct.toFixed(0)}%</span>`;
      }
    }
    return `<div style="margin-bottom:14px;">
      <div style="display:flex; justify-content:space-between; font-size:12px; margin-bottom:3px; flex-wrap:wrap; gap:4px;">
        <span><span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:${safeCssColor(r.color||'#5b9cf0')};margin-inline-end:5px;vertical-align:middle;"></span><strong>${escapeHtml(r.name)}</strong></span>
        <span style="color:var(--text-muted);">${r.hours.toFixed(1)}h · ${r.count} ${escapeHtml(t('an.orders'))} · ${fmtPrice(r.revenue)} · <span style="color:${marginCol};font-weight:600;">${escapeHtml(t('an.margin_col'))}: ${marginStr}</span>${utilStr}</span>
      </div>
      <div style="background:rgba(255,255,255,0.08);border-radius:4px;height:10px;">
        <div style="background:${safeCssColor(r.color||'#5b9cf0')};width:${pct.toFixed(1)}%;height:100%;border-radius:4px;opacity:0.8;transition:width 0.4s;"></div>
      </div>
    </div>`;
  }).join('');

  // PNG export button
  const existingUtilBtn = el.parentElement?.querySelector('.chart-dl-btn');
  if (existingUtilBtn) existingUtilBtn.remove();
  const dlUtilBtn = document.createElement('button');
  dlUtilBtn.className = 'btn small ghost chart-dl-btn';
  dlUtilBtn.style.cssText = 'position:absolute;top:6px;inset-inline-end:6px;font-size:11px;padding:3px 8px;opacity:0.7;';
  dlUtilBtn.textContent = '⬇ ' + t('an.download_png');
  dlUtilBtn.title = 'Download chart as PNG';
  if (el.parentElement) el.parentElement.style.position = 'relative';
  el.parentElement?.appendChild(dlUtilBtn);
  dlUtilBtn.addEventListener('click', () => {
    const svg = el.querySelector('svg');
    if (!svg) return;
    const svgData = new XMLSerializer().serializeToString(svg);
    const canvas = document.createElement('canvas');
    const vb = svg.viewBox.baseVal;
    canvas.width  = vb.width  || 600;
    canvas.height = vb.height || 210;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#1e293b';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    const img = new Image();
    const blob = new Blob([svgData], { type: 'image/svg+xml;charset=utf-8' });
    const url  = URL.createObjectURL(blob);
    img.onload = () => {
      ctx.drawImage(img, 0, 0);
      URL.revokeObjectURL(url);
      const link = document.createElement('a');
      link.download = 'khayt-utilization-chart.png';
      link.href = canvas.toDataURL('image/png');
      link.click();
    };
    img.src = url;
  });
}

/* ============================================================
   P&L (Profit & Loss) quarterly/annual view
   ============================================================ */
function renderPnLSection() {
  const el = $('#pnlSection');
  if (!el) return;

  // The table is lib/pnl-report.js's `pnlByPeriod` — which orders count, which
  // are voided, how VAT is worked out, and how a quarter in progress is charged
  // its share of the overhead. It was all inline here, so the Mac app had no
  // P&L and no way to have one without a second opinion about the shop's money.
  const Pnl = (typeof globalThis !== 'undefined' && globalThis.KhaytPnl)
    || require('../lib/pnl-report.js');
  const rows = Pnl.pnlByPeriod(printLog, expenses, {
    settings, clients, currencies: CURRENCIES, now: new Date(),
  });
  if (rows.length === 0) { el.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.pnl_empty'))}</p>`; return; }
  const hasFixed = rows.some((r) => r.fixed > 0);

  const cur = currencySymbol();
  el.innerHTML = `
    ${hasFixed ? `<div style="font-size:12px;color:var(--text-muted);margin-bottom:8px;">Fixed overhead: ${fmtMoney(rows.find((r) => r.fixed > 0).fixed)}/quarter included in net</div>` : ''}
    <div style="overflow-x:auto;">
      <table style="width:100%; border-collapse:collapse; font-size:13px;">
        <thead>
          <tr style="color:var(--text-muted); text-align:right;">
            <th style="text-align:left; padding:4px 8px;">${escapeHtml(t('an.pnl_period'))}</th>
            <th style="padding:4px 8px;">${escapeHtml(t('an.pnl_orders'))}</th>
            <th style="padding:4px 8px;">${escapeHtml(t('an.revenue'))} (${cur})</th>
            <th style="padding:4px 8px;">${escapeHtml(t('an.pnl_expenses'))} (${cur})</th>
            <th style="padding:4px 8px;">${escapeHtml(t('an.pnl_vat'))} (${cur})</th>
            <th style="padding:4px 8px; font-weight:700;">${escapeHtml(t('an.pnl_net'))} (${cur})</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(r => {
            const netCol = r.net >= 0 ? 'var(--success)' : 'var(--danger)';
            return `<tr style="border-top:1px solid rgba(255,255,255,0.06);">
              <td style="padding:6px 8px; font-weight:600;">${escapeHtml(r.period)}</td>
              <td style="padding:6px 8px; text-align:right;">${r.orders}</td>
              <td style="padding:6px 8px; text-align:right; font-variant-numeric:tabular-nums;">${fmtMoney(r.revenue)}</td>
              <td style="padding:6px 8px; text-align:right; color:var(--danger); font-variant-numeric:tabular-nums;">−${fmtMoney(r.expenses + r.fixed)}</td>
              <td style="padding:6px 8px; text-align:right; color:var(--text-muted); font-variant-numeric:tabular-nums;">${fmtMoney(r.vatCollected)}</td>
              <td style="padding:6px 8px; text-align:right; font-weight:700; color:${netCol}; font-variant-numeric:tabular-nums;">${fmtMoney(r.net)}</td>
            </tr>`;
          }).join('')}
        </tbody>
      </table>
    </div>`;
}

/* ============================================================
   Profitability by product — shows revenue / cost / margin
   per product type for completed orders in selected range
   ============================================================ */
function renderProductProfitability() {
  const el = $('#productProfitSection');
  if (!el) return;

  // `lib/product-profit.js`, not the rollup that used to be here. Two changes
  // a reader will notice:
  //
  //   IT COUNTS `delivered`. This filtered on `completed` alone, so every
  //   product that actually reached a customer dropped out of its own
  //   profitability row.
  //
  //   IT RANKS BY PROFIT, not by revenue. The row a shop opens this table to
  //   find is the big seller that earns nothing, and ranking by revenue put
  //   that row at the top looking like the best thing in the shop.
  const report = KhaytProductProfit.productProfit({
    orders: (printLog || []).filter(o => inRange(o.date, analyticsRange, 'analytics')),
    products: products || [], expenses: expenses || [], untagged: t('an.untagged'),
  }, {
    revenueOf: orderNetRevenueBase, partCostOf: partTotalCost,
    nameOf: localName, countsForBusiness: _countsForBusiness,
  });
  if (report.rows.length === 0) {
    el.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.no_data'))}</p>`;
    return;
  }
  const rows = report.rows.map(r => ({
    name: r.name, revenue: r.revenue, cost: r.cost, count: r.jobs,
  }));
  const maxRev = Math.max(...rows.map(r => r.revenue), 1);

  el.innerHTML = `
    <div class="table-wrap">
      <table style="width:100%; border-collapse:collapse; font-size:13px;">
        <thead>
          <tr style="border-bottom:1px solid rgba(255,255,255,0.1); text-align:left;">
            <th style="padding:6px 8px;" data-i18n="an.product_col">${escapeHtml(t('an.product_col'))}</th>
            <th style="padding:6px 8px; text-align:center;" data-i18n="an.orders">${escapeHtml(t('an.orders'))}</th>
            <th style="padding:6px 8px; text-align:right;" data-i18n="an.revenue">${escapeHtml(t('an.revenue'))}</th>
            <th style="padding:6px 8px; text-align:right;" data-i18n="an.cost_col">${escapeHtml(t('an.cost_col'))}</th>
            <th style="padding:6px 8px; text-align:right;" data-i18n="an.margin_col">${escapeHtml(t('an.margin_col'))}</th>
            <th style="padding:6px 8px; width:120px;" data-i18n="an.revenue_bar">${escapeHtml(t('an.revenue_bar'))}</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(r => {
            const margin = (r.cost > 0 && r.revenue > 0) ? ((r.revenue - r.cost) / r.revenue * 100) : null;
            const marginStr = margin !== null ? `${margin.toFixed(1)}%` : '—';
            const marginCol = margin !== null ? (margin >= 30 ? 'var(--success)' : margin >= 10 ? 'var(--warning)' : 'var(--danger)') : 'var(--text-muted)';
            const barPct = (r.revenue / maxRev * 100).toFixed(1);
            return `<tr style="border-bottom:1px solid rgba(255,255,255,0.05);">
              <td style="padding:7px 8px; font-weight:500;">${escapeHtml(r.name)}</td>
              <td style="padding:7px 8px; text-align:center;">${r.count}</td>
              <td style="padding:7px 8px; text-align:right; font-variant-numeric:tabular-nums;">${fmtPrice(r.revenue)}</td>
              <td style="padding:7px 8px; text-align:right; color:var(--danger); font-variant-numeric:tabular-nums;">${r.cost > 0 ? fmtPrice(r.cost) : '—'}</td>
              <td style="padding:7px 8px; text-align:right; font-weight:600; color:${marginCol};">${marginStr}</td>
              <td style="padding:7px 8px;">
                <div style="background:rgba(255,255,255,0.08);border-radius:3px;height:8px;">
                  <div style="background:var(--primary);width:${barPct}%;height:100%;border-radius:3px;transition:width 0.4s;"></div>
                </div>
              </td>
            </tr>`;
          }).join('')}
        </tbody>
      </table>
    </div>`;
}

/* ============================================================
   SLA — On-Time Delivery Rate
   ============================================================ */
function renderSLASection() {
  const el = $('#slaSection');
  if (!el) return;

  /* On-time delivery is a promise KEPT OR MISSED, so only orders that were
   * actually a promise to a customer belong in it.
   *
   * This counted voided orders — every other completed-order filter that reports
   * on trade excludes them, and this one silently did not, so a cancelled job
   * counted against (or for) the shop's delivery record. It also counted prints
   * the shop marked as its own; a calibration cube is not a promise to anybody.
   *
   * Found by sweeping every `status === 'completed'` filter rather than the
   * single-line idiom — this one is spread over four lines, so the earlier pass
   * that added the trade check to thirteen of them walked straight past it. */
  const completed = printLog.filter(o =>
    o.status === 'completed' &&
    !o.voidedAt &&
    _countsForBusiness(o) &&
    o.dueDate &&
    inRange(o.date, analyticsRange, 'analytics')
  );

  if (completed.length === 0) {
    el.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.sla_no_data'))}</p>`;
    return;
  }

  // Delivered date in LOCAL time, comparable with the local dueDate. completedAt/
  // deliveredAt are ISO timestamps (UTC) — slicing them flips on-time vs late near
  // the day boundary; o.date is already a local YYYY-MM-DD.
  const deliveredDate = (o) => {
    const v = o.completedAt || o.deliveredAt || o.date || '';
    if (!v) return '';
    return v.length > 10 ? localDateStr(new Date(v)) : v;
  };
  const onTime = completed.filter(o => deliveredDate(o) <= o.dueDate);
  const late = completed.filter(o => deliveredDate(o) > o.dueDate);

  const rate = Math.round(onTime.length / completed.length * 100);
  const avgDelay = late.length > 0 ? Math.round(
    late.reduce((s, o) =>
      s + Math.round((new Date(deliveredDate(o) + 'T00:00:00') - new Date(o.dueDate + 'T00:00:00')) / 86400000)
    , 0) / late.length
  ) : 0;

  const rateColor = rate >= 90 ? 'var(--success)' : rate >= 70 ? 'var(--warning)' : 'var(--danger)';

  el.innerHTML = `
    <div style="display:flex; gap:24px; flex-wrap:wrap; margin-bottom:16px;">
      <div class="cl-hist-stat">
        <div class="v" style="color:${rateColor};">${rate}%</div>
        <div class="l">${escapeHtml(t('an.sla_rate'))}</div>
      </div>
      <div class="cl-hist-stat">
        <div class="v">${completed.length}</div>
        <div class="l">${escapeHtml(t('an.sla_with_due'))}</div>
      </div>
      <div class="cl-hist-stat">
        <div class="v">${onTime.length}</div>
        <div class="l" style="color:var(--success);">${escapeHtml(t('an.sla_on_time'))}</div>
      </div>
      <div class="cl-hist-stat">
        <div class="v">${late.length}</div>
        <div class="l" style="color:var(--danger);">${escapeHtml(t('an.sla_late'))}</div>
      </div>
      ${late.length > 0 ? `<div class="cl-hist-stat">
        <div class="v">${avgDelay}</div>
        <div class="l">${escapeHtml(t('an.sla_avg_delay'))}</div>
      </div>` : ''}
    </div>
    <div style="background:rgba(255,255,255,0.08);border-radius:6px;height:12px;overflow:hidden;">
      <div style="background:${rateColor};width:${rate}%;height:100%;border-radius:6px;transition:width 0.5s;"></div>
    </div>`;
}

/* ============================================================
   QC / reprint / RMA — quality metrics
   ============================================================ */
function renderQcSection() {
  const el = $('#qcSection');
  if (!el) return;
  if (typeof computeQcMetrics !== 'function') { el.innerHTML = ''; return; }

  const orders = printLog.filter(o =>
    o.status !== 'quote' && inRange(o.date, analyticsRange, 'analytics'));
  const m = computeQcMetrics(orders);

  if (m.qcd === 0 && m.rmaCount === 0) {
    el.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('qc.analytics_none') || t('an.no_data'))}</p>`;
    return;
  }

  const passRate = Math.round(m.passRate * 100);
  const fpy = Math.round(m.firstPassYield * 100);
  const passColor = passRate >= 90 ? 'var(--success)' : passRate >= 70 ? 'var(--warning)' : 'var(--danger)';
  const fpyColor = fpy >= 90 ? 'var(--success)' : fpy >= 70 ? 'var(--warning)' : 'var(--danger)';

  const defectRows = Object.entries(m.defectsByType).sort((a, b) => b[1] - a[1]);
  const maxDefect = defectRows.length ? defectRows[0][1] : 0;
  const defectsHtml = defectRows.length ? `
    <div style="margin-top:14px;">
      <div style="font-size:12px;color:var(--text-muted);margin-bottom:8px;">${escapeHtml(t('qc.defect_categories') || 'Defect categories')}</div>
      ${defectRows.map(([type, n]) => `
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:5px;">
          <span style="flex:0 0 130px;font-size:12px;">${escapeHtml(t('waste.ft.' + type) || type)}</span>
          <div style="flex:1;background:rgba(255,255,255,0.08);border-radius:4px;height:9px;overflow:hidden;">
            <div style="background:var(--danger);width:${maxDefect ? Math.round(n / maxDefect * 100) : 0}%;height:100%;"></div>
          </div>
          <span style="flex:0 0 28px;text-align:end;font-size:12px;">${n}</span>
        </div>`).join('')}
    </div>` : '';

  el.innerHTML = `
    <div style="display:flex; gap:24px; flex-wrap:wrap; margin-bottom:8px;">
      <div class="cl-hist-stat">
        <div class="v" style="color:${passColor};">${passRate}%</div>
        <div class="l">${escapeHtml(t('qc.pass_rate') || 'QC pass rate')}</div>
      </div>
      <div class="cl-hist-stat">
        <div class="v" style="color:${fpyColor};">${fpy}%</div>
        <div class="l">${escapeHtml(t('qc.first_pass_yield') || 'First-pass yield')}</div>
      </div>
      <div class="cl-hist-stat">
        <div class="v">${m.qcd}</div>
        <div class="l">${escapeHtml(t('qc.inspected') || 'Inspected')}</div>
      </div>
      <div class="cl-hist-stat">
        <div class="v" style="color:var(--danger);">${m.failed}</div>
        <div class="l">${escapeHtml(t('qc.failed') || 'QC failed')}</div>
      </div>
      <div class="cl-hist-stat">
        <div class="v">${m.rmaCount}</div>
        <div class="l">${escapeHtml(t('qc.rma_count') || 'RMAs')}</div>
      </div>
      ${m.rmaCost > 0 ? `<div class="cl-hist-stat">
        <div class="v">${fmtPrice(m.rmaCost)}</div>
        <div class="l">${escapeHtml(t('qc.rma_cost') || 'Warranty cost')}</div>
      </div>` : ''}
    </div>
    ${defectsHtml}`;
}

/* ============================================================
   Feature 7: Per-machine P&L
   ============================================================ */
function renderMachinePL() {
  const el = $('#machinePLSection');
  if (!el) return;
  if (machines.length === 0) { el.innerHTML = ''; return; }

  const completed = printLog.filter(o => o.status === 'completed' && inRange(o.date, analyticsRange, 'analytics'));
  if (completed.length === 0) {
    el.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.no_data'))}</p>`;
    return;
  }

  // ── THE RULE IS `lib/machine-pl.js`, NOT THIS FUNCTION ────────────────
  //
  // This computed it inline, which was fine until a second app wanted the same
  // answer. Then there are two implementations of "what did this machine earn"
  // and the one a shop happens to be looking at decides — and this is the
  // number an owner uses to decide whether to RETIRE a machine.
  //
  // MAINTENANCE RESPECTS THE SELECTED RANGE, like revenue and material above.
  // It used to be filtered by calendar year, so choosing "This month" charged
  // January's nozzle-and-belt overhaul against July's revenue and a profitable
  // printer read as loss-making. The module does not know what a range is —
  // all four collections are filtered here, the same way, before they go in.
  const { rows } = KhaytMachinePL.machineProfit({
    machines,
    completed,
    expenses: expenses.filter(e => e.orderId),
    maintenance: machMaintLog.filter(e => inRange(e.date, analyticsRange, 'analytics')),
    unassigned: t('dash.unassigned'),
  }, {
    revenueOf: orderNetRevenueBase,
    partCostOf: partTotalCost,
  });
  if (rows.length === 0) {
    el.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.no_data'))}</p>`;
    return;
  }

  const cur = currencySymbol();
  el.innerHTML = `
    <div class="table-wrap">
      <table class="machine-pl-table" style="width:100%; border-collapse:collapse; font-size:13px;">
        <thead>
          <tr style="color:var(--text-muted);">
            <th style="text-align:left; padding:6px 8px;">Machine</th>
            <th style="text-align:right; padding:6px 8px;">${escapeHtml(t('an.pnl_orders'))}</th>
            <th style="text-align:right; padding:6px 8px;">${escapeHtml(t('an.revenue'))} (${cur})</th>
            <th style="text-align:right; padding:6px 8px;">${escapeHtml(t('an.mat_cost_col'))} (${cur})</th>
            <th style="text-align:right; padding:6px 8px;">${escapeHtml(t('an.linked_exp_col'))} (${cur})</th>
            <th style="text-align:right; padding:6px 8px;">${escapeHtml(t('an.maint_cost_col'))} (${cur})</th>
            <th style="text-align:right; padding:6px 8px; font-weight:700;">${escapeHtml(t('an.net_col'))} (${cur})</th>
            <th style="text-align:right; padding:6px 8px;">${escapeHtml(t('an.margin_col'))}</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(r => {
            // Both figures come from the rule now. `marginPct` is NULL for a
            // machine that earned nothing — which is not the same claim as 0%,
            // and is why this reads it rather than recomputing.
            const net = r.net;
            const margin = r.marginPct;
            const marginCol = margin === null ? 'var(--text-muted)'
              : margin >= 30 ? 'var(--success)' : margin >= 10 ? 'var(--warning)' : 'var(--danger)';
            return `<tr style="border-top:1px solid rgba(255,255,255,0.06);">
              <td style="padding:6px 8px;">
                <span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:${safeCssColor(r.color)};margin-inline-end:6px;vertical-align:middle;"></span>
                <strong>${escapeHtml(r.name)}</strong>
              </td>
              <td style="text-align:right; padding:6px 8px;">${r.jobs}</td>
              <td style="text-align:right; padding:6px 8px; font-variant-numeric:tabular-nums;">${fmtMoney(r.revenue)}</td>
              <td style="text-align:right; padding:6px 8px; color:var(--danger); font-variant-numeric:tabular-nums;">−${fmtMoney(r.materialCost)}</td>
              <td style="text-align:right; padding:6px 8px; color:var(--danger); font-variant-numeric:tabular-nums;">−${fmtMoney(r.linkedExpenses)}</td>
              <td style="text-align:right; padding:6px 8px; color:var(--danger); font-variant-numeric:tabular-nums;">−${fmtMoney(r.maintenance)}</td>
              <td style="text-align:right; padding:6px 8px; font-weight:700; color:${net >= 0 ? 'var(--success)' : 'var(--danger)'}; font-variant-numeric:tabular-nums;">${fmtMoney(net)}</td>
              <td style="text-align:right; padding:6px 8px; font-weight:600; color:${marginCol};">${margin === null ? '—' : margin.toFixed(1) + '%'}</td>
            </tr>`;
          }).join('')}
        </tbody>
      </table>
    </div>`;
}

/* ============================================================
   Per-Location P&L
   ============================================================ */
function renderLocationPL() {
  const container = document.getElementById('locationPlChart');
  if (!container) return;

  if (!locations.length) {
    container.innerHTML = `<p style="color:var(--text-muted);font-size:13px;padding:12px 0;">${t('an.no_locations')}</p>`;
    return;
  }

  // Map machineId → locationId and machineName → locationId
  const machLocById  = {};
  const machLocByName = {};
  machines.forEach(m => {
    if (m.locationId) { machLocById[m.id] = m.locationId; machLocByName[m.name] = m.locationId; }
  });

  const locTotals = {}; // locationId | '__none__' → { revenue, matCost, expenses, orders }
  const getD = id => { if (!locTotals[id]) locTotals[id] = { revenue: 0, matCost: 0, expenses: 0, orders: 0 }; return locTotals[id]; };

  // Orders
  printLog.filter(o => o.status === 'completed' && !o.voidedAt && _countsForBusiness(o) && inRange(o.date || (o.timestamp || '').slice(0,10), analyticsRange, 'analytics')).forEach(o => {
    const lid = (o.machineId && machLocById[o.machineId]) || (o.machine && machLocByName[o.machine]) || '__none__';
    const d = getD(lid);
    d.revenue += orderNetRevenueBase(o);
    d.orders++;
    (o.parts || []).forEach(p => { d.matCost += (typeof partTotalCost === 'function' ? (partTotalCost(p) || 0) : 0); });
  });

  // Expenses
  expenses.filter(e => inRange(e.date, analyticsRange, 'analytics')).forEach(e => {
    getD(e.locationId || '__none__').expenses += +e.amount || 0;
  });

  // Build rows
  const nameMap = { '__none__': t('an.unassigned_location') };
  locations.forEach(l => { nameMap[l.id] = l.name; });

  const rows = Object.entries(locTotals)
    .map(([lid, d]) => ({ lid, name: nameMap[lid] || lid, ...d, net: d.revenue - d.matCost - d.expenses }))
    .sort((a, b) => b.revenue - a.revenue);

  if (!rows.length) {
    container.innerHTML = `<p style="color:var(--text-muted);font-size:13px;padding:12px 0;">${t('an.no_data')}</p>`;
    return;
  }

  const cur = currencySymbol();
  const maxRev = Math.max(...rows.map(r => r.revenue), 1);

  // SVG grouped bar chart (revenue / net per location)
  const BAR_W = 28, GAP = 18, GRP = 2 * BAR_W + 6, H = 120, PAD = 36;
  const svgW = rows.length * (GRP + GAP) + PAD * 2;
  const scale = v => H - Math.max(0, Math.min(H, (v / maxRev) * H));

  const bars = rows.map((r, i) => {
    const x = PAD + i * (GRP + GAP);
    const revH = Math.max(1, (r.revenue / maxRev) * H);
    const netH = Math.max(1, (Math.max(0, r.net) / maxRev) * H);
    const netColor = r.net >= 0 ? '#22c55e' : '#ef4444';
    return `
      <rect x="${x}" y="${H - revH}" width="${BAR_W}" height="${revH}" fill="#6366f1" opacity="0.85" rx="2">
        <title>${escapeHtml(r.name)}: ${t('an.location_revenue')} ${cur}${fmtMoney(r.revenue)}</title>
      </rect>
      <rect x="${x + BAR_W + 6}" y="${H - netH}" width="${BAR_W}" height="${netH}" fill="${netColor}" opacity="0.85" rx="2">
        <title>${escapeHtml(r.name)}: ${t('an.location_profit')} ${cur}${fmtMoney(r.net)}</title>
      </rect>
      <text x="${x + BAR_W + 3}" y="${H + 14}" text-anchor="middle" font-size="9" fill="var(--text-muted)">${escapeHtml(r.name.slice(0,8))}</text>`;
  }).join('');

  const legend = `<g transform="translate(${PAD},${H + 30})">
    <rect width="10" height="10" fill="#6366f1" rx="1"/><text x="14" y="9" font-size="9" fill="var(--text-muted)">${t('an.location_revenue')}</text>
    <rect x="80" width="10" height="10" fill="#22c55e" rx="1"/><text x="94" y="9" font-size="9" fill="var(--text-muted)">${t('an.location_profit')}</text>
  </g>`;

  const chart = `<svg viewBox="0 0 ${svgW} ${H + 50}" style="width:100%;max-width:${svgW}px;overflow:visible;">${bars}${legend}</svg>`;

  // Summary table
  const tableRows = rows.map(r => {
    const margin = r.revenue > 0 ? (r.net / r.revenue * 100).toFixed(1) + '%' : '—';
    const netCol = r.net >= 0 ? `<span style="color:var(--success)">${cur}${fmtMoney(r.net)}</span>` : `<span style="color:var(--danger)">${cur}${fmtMoney(r.net)}</span>`;
    return `<tr>
      <td><strong>${escapeHtml(r.name)}</strong></td>
      <td style="text-align:right;">${r.orders}</td>
      <td style="text-align:right;">${cur}${fmtMoney(r.revenue)}</td>
      <td style="text-align:right;">${cur}${fmtMoney(r.matCost + r.expenses)}</td>
      <td style="text-align:right;">${netCol}</td>
      <td style="text-align:right;">${margin}</td>
    </tr>`;
  }).join('');

  container.innerHTML = `
    <div style="overflow-x:auto;margin-bottom:12px;">${chart}</div>
    <div style="overflow-x:auto;">
      <table style="width:100%;font-size:12px;border-collapse:collapse;">
        <thead><tr style="color:var(--text-muted);font-size:11px;">
          <th style="text-align:left;padding:4px 8px;">${t('an.location')}</th>
          <th style="text-align:right;padding:4px 8px;">${t('an.orders')}</th>
          <th style="text-align:right;padding:4px 8px;">${t('an.location_revenue')}</th>
          <th style="text-align:right;padding:4px 8px;">${t('an.location_expenses')}</th>
          <th style="text-align:right;padding:4px 8px;">${t('an.location_profit')}</th>
          <th style="text-align:right;padding:4px 8px;">${t('an.margin')}</th>
        </tr></thead>
        <tbody>${tableRows}</tbody>
      </table>
    </div>`;
}

/* ============================================================
   Supplier Price History
   ============================================================ */
function renderSupplierPriceHistory() {
  const container = document.getElementById('supplierPriceHistoryChart');
  if (!container) return;

  // Aggregate all purchases by materialType
  const byMat = {}; // materialType → [{ date, unitPrice, supplier, total }]
  suppliers.forEach(sup => {
    (sup.purchases || []).forEach(p => {
      const mt = (p.materialType || '').trim() || t('sup.untagged');
      if (!byMat[mt]) byMat[mt] = [];
      byMat[mt].push({ date: p.date || '', unitPrice: computeUnitPrice(p), supplier: sup.name, total: +p.amount || 0, unit: p.unit || 'spool' });
    });
  });

  const allMats = Object.keys(byMat).sort();
  if (!allMats.length) {
    container.innerHTML = `<p style="color:var(--text-muted);font-size:13px;padding:12px 0;">${t('sup.no_price_data')}</p>`;
    return;
  }

  const cur = currencySymbol();

  // Price trend sparklines
  const sparks = allMats.map(mat => {
    const entries = byMat[mat].filter(e => e.date).sort((a,b) => a.date.localeCompare(b.date));
    if (!entries.length) return '';
    const prices = entries.map(e => e.unitPrice);
    const minP = Math.min(...prices), maxP = Math.max(...prices), rangeP = maxP - minP || 1;
    const W = 120, H = 36;
    const pts = entries.map((e, i) => {
      const x = entries.length > 1 ? (i / (entries.length - 1)) * W : W / 2;
      const y = H - ((e.unitPrice - minP) / rangeP) * H;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(' ');
    const last = entries[entries.length - 1];
    const prev = entries[entries.length - 2];
    const pctChange = prev ? ((last.unitPrice - prev.unitPrice) / prev.unitPrice * 100) : 0;
    const badge = Math.abs(pctChange) >= 5
      ? `<span style="font-size:10px;padding:1px 5px;border-radius:10px;background:${pctChange > 0 ? '#fee2e2' : '#dcfce7'};color:${pctChange > 0 ? '#ef4444' : '#16a34a'};">${pctChange > 0 ? '▲' : '▼'}${Math.abs(pctChange).toFixed(1)}%</span>`
      : '';
    return `<div style="padding:10px 12px;background:var(--bg-elev);border-radius:var(--radius);min-width:180px;">
      <div style="font-weight:600;font-size:12px;margin-bottom:4px;display:flex;justify-content:space-between;align-items:center;">
        <span>${escapeHtml(mat)}</span>${badge}
      </div>
      <svg viewBox="0 0 ${W} ${H}" style="width:100%;height:36px;overflow:visible;">
        <polyline points="${pts}" fill="none" stroke="#6366f1" stroke-width="1.5" stroke-linejoin="round"/>
        ${entries.map((e,i) => { const x = entries.length > 1 ? (i / (entries.length - 1)) * W : W/2; const y = H - ((e.unitPrice - minP) / rangeP) * H; return `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="2.5" fill="#6366f1"><title>${escapeHtml(e.supplier)}: ${cur}${e.unitPrice.toFixed(2)}/${escapeHtml(e.unit||'unit')} (${e.date})</title></circle>`; }).join('')}
      </svg>
      <div style="font-size:11px;color:var(--text-muted);margin-top:4px;">
        ${t('sup.latest')}: <strong>${cur}${last.unitPrice.toFixed(2)}/${last.unit||'unit'}</strong> · ${escapeHtml(last.supplier)}
      </div>
    </div>`;
  }).join('');

  // Best-price comparison table (one row per material)
  const tableRows = allMats.map(mat => {
    const entries = byMat[mat].sort((a,b) => a.unitPrice - b.unitPrice);
    const best = entries[0];
    const worst = entries[entries.length - 1];
    const count = entries.length;
    return `<tr>
      <td>${escapeHtml(mat)}</td>
      <td style="color:var(--success);text-align:right;">${cur}${best.unitPrice.toFixed(2)} <span style="font-size:10px;color:var(--text-muted);">${escapeHtml(best.supplier)}</span></td>
      <td style="color:var(--danger);text-align:right;">${cur}${worst.unitPrice.toFixed(2)} <span style="font-size:10px;color:var(--text-muted);">${escapeHtml(worst.supplier)}</span></td>
      <td style="text-align:right;">${count}</td>
    </tr>`;
  }).join('');

  container.innerHTML = `
    <h4 style="font-size:13px;margin-bottom:10px;">${t('sup.price_trend')}</h4>
    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:8px;margin-bottom:16px;">${sparks}</div>
    <h4 style="font-size:13px;margin-bottom:8px;">${t('sup.best_price')}</h4>
    <div style="overflow-x:auto;">
      <table style="width:100%;font-size:12px;border-collapse:collapse;">
        <thead><tr style="color:var(--text-muted);font-size:11px;">
          <th style="text-align:left;padding:4px 8px;">${t('sup.material_type')}</th>
          <th style="text-align:right;padding:4px 8px;">${t('sup.best_price')}</th>
          <th style="text-align:right;padding:4px 8px;">${t('sup.highest_price')}</th>
          <th style="text-align:right;padding:4px 8px;">${t('sup.purchase_count')}</th>
        </tr></thead>
        <tbody>${tableRows}</tbody>
      </table>
    </div>`;
}

/* ============================================================
   Revenue chart — SVG bar chart, last 12 months
   ============================================================ */
function renderRevenueChart() {
  const wrap = $('#revenueChartWrap');
  if (!wrap) return;

  const now = new Date();
  const months = [];

  // Build month buckets based on analyticsRange
  if (analyticsRange === 'month') {
    // Daily view for current month
    const daysInMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
    for (let d = 1; d <= daysInMonth; d++) {
      const key = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
      months.push({ key, label: String(d), revenue: 0, orders: 0, isDay: true });
    }
  } else if (analyticsRange === 'last_month') {
    const lm = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    const daysInMonth = new Date(lm.getFullYear(), lm.getMonth() + 1, 0).getDate();
    for (let d = 1; d <= daysInMonth; d++) {
      const key = `${lm.getFullYear()}-${String(lm.getMonth() + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
      months.push({ key, label: String(d), revenue: 0, orders: 0, isDay: true });
    }
  } else if (analyticsRange === 'quarter') {
    // Show 3 months for current quarter
    const qStart = Math.floor(now.getMonth() / 3) * 3;
    for (let i = 0; i < 3; i++) {
      const d = new Date(now.getFullYear(), qStart + i, 1);
      months.push({
        key:   `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
        label: d.toLocaleDateString(localeTag(), { month: 'short' }),
        revenue: 0, orders: 0
      });
    }
  } else {
    // Default (all / year / custom): last 12 months
    for (let i = 11; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      months.push({
        key:   `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
        label: d.toLocaleDateString(localeTag(), { month: 'short' }),
        revenue: 0, orders: 0
      });
    }
  }

  const isDay = months[0]?.isDay;
  for (const o of printLog) {
    if (o.status !== 'completed' || o.voidedAt) continue;
    if (!inRange(o.date, analyticsRange, 'analytics')) continue;
    const key = isDay ? (o.date || '').slice(0, 10) : (o.date || '').slice(0, 7);
    const m = months.find(x => x.key === key);
    if (m) { m.revenue += orderNetRevenueBase(o); m.orders++; }
  }

  const maxRev = Math.max(...months.map(m => m.revenue), 1);
  const W = 600, H = 210;
  const padL = 48, padR = 12, padT = 18, padB = 34;
  const chartW = W - padL - padR;
  const chartH = H - padT - padB;
  const barW   = chartW / months.length;
  const gap    = Math.max(2, barW * 0.18);
  const TICKS  = 4;

  let s = `<svg viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">`;

  // Grid lines + y-labels
  for (let i = 0; i <= TICKS; i++) {
    const y   = padT + chartH - (i / TICKS) * chartH;
    const val = (maxRev / TICKS) * i;
    const lbl = val >= 1000 ? (val / 1000).toFixed(val >= 10000 ? 0 : 1) + 'k' : val.toFixed(0);
    s += `<line x1="${padL}" y1="${y.toFixed(1)}" x2="${W - padR}" y2="${y.toFixed(1)}" stroke="#ffffff10" stroke-width="1"/>`;
    s += `<text x="${(padL - 6).toFixed(1)}" y="${(y + 3.5).toFixed(1)}" text-anchor="end" font-size="10" fill="#6b7793">${escapeHtml(lbl)}</text>`;
  }

  // Bars
  months.forEach((m, i) => {
    const x   = padL + i * barW + gap / 2;
    const bw  = barW - gap;
    const bh  = m.revenue > 0 ? Math.max(3, (m.revenue / maxRev) * chartH) : 3;
    const y   = padT + chartH - bh;
    const cx  = (x + bw / 2).toFixed(1);
    const op  = m.revenue > 0 ? '0.85' : '0.12';

    s += `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${bw.toFixed(1)}" height="${bh.toFixed(1)}" fill="#5b9cf0" rx="3" opacity="${op}"/>`;

    // Value above bar
    if (m.revenue > 0) {
      const vl = m.revenue >= 1000 ? (m.revenue / 1000).toFixed(1) + 'k' : m.revenue.toFixed(0);
      s += `<text x="${cx}" y="${(y - 4).toFixed(1)}" text-anchor="middle" font-size="9.5" fill="#9aa6c0">${escapeHtml(vl)}</text>`;
    }
    // Order count dot + label
    if (m.orders > 0) {
      s += `<text x="${cx}" y="${(padT + chartH + 14).toFixed(1)}" text-anchor="middle" font-size="9" fill="#5b9cf0" font-weight="600">${m.orders}</text>`;
    }
    // Month label
    s += `<text x="${cx}" y="${(padT + chartH + 26).toFixed(1)}" text-anchor="middle" font-size="10" fill="#6b7793">${escapeHtml(m.label)}</text>`;
  });

  s += `</svg>`;
  wrap.innerHTML = s;

  // PNG export button
  const existingBtn = wrap.parentElement?.querySelector('.chart-dl-btn');
  if (existingBtn) existingBtn.remove();
  const dlBtn = document.createElement('button');
  dlBtn.className = 'btn small ghost chart-dl-btn';
  dlBtn.style.cssText = 'position:absolute;top:6px;inset-inline-end:6px;font-size:11px;padding:3px 8px;opacity:0.7;';
  dlBtn.textContent = '⬇ ' + t('an.download_png');
  dlBtn.title = 'Download chart as PNG';
  if (wrap.parentElement) wrap.parentElement.style.position = 'relative';
  wrap.parentElement?.appendChild(dlBtn);
  dlBtn.addEventListener('click', () => {
    const svg = wrap.querySelector('svg');
    if (!svg) return;
    const svgData = new XMLSerializer().serializeToString(svg);
    const canvas = document.createElement('canvas');
    const vb = svg.viewBox.baseVal;
    canvas.width  = vb.width  || 600;
    canvas.height = vb.height || 210;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#1e293b';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    const img = new Image();
    const blob = new Blob([svgData], { type: 'image/svg+xml;charset=utf-8' });
    const url  = URL.createObjectURL(blob);
    img.onload = () => {
      ctx.drawImage(img, 0, 0);
      URL.revokeObjectURL(url);
      const link = document.createElement('a');
      link.download = 'khayt-revenue-chart.png';
      link.href = canvas.toDataURL('image/png');
      link.click();
    };
    img.src = url;
  });
}

function renderClientRetention() {
  const el = $('#clientRetentionSection');
  if (!el) return;
  const completed = printLog.filter(o => o.status === 'completed' && o.clientId && o.date);
  // Group by client, sorted by date
  const clientOrders = {};
  for (const o of completed) {
    if (!clientOrders[o.clientId]) clientOrders[o.clientId] = [];
    clientOrders[o.clientId].push(o.date);
  }
  // Only clients with at least one order
  const allClients = Object.entries(clientOrders).map(([id, dates]) => {
    const sorted = [...dates].sort();
    return { id, firstDate: sorted[0], secondDate: sorted[1] || null, total: sorted.length };
  });
  const withAtLeastOne = allClients.length;
  if (withAtLeastOne < 2) {
    el.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.retention_no_data'))}</p>`;
    return;
  }
  const withTwo = allClients.filter(c => c.secondDate !== null);
  const daysBetween = (a, b) => Math.round(Math.abs(new Date(b) - new Date(a)) / 86400000);
  const ret30 = withTwo.filter(c => daysBetween(c.firstDate, c.secondDate) <= 30).length;
  const ret60 = withTwo.filter(c => daysBetween(c.firstDate, c.secondDate) <= 60).length;
  const ret90 = withTwo.filter(c => daysBetween(c.firstDate, c.secondDate) <= 90).length;
  const pct = (n) => withAtLeastOne > 0 ? (n / withAtLeastOne * 100).toFixed(1) : '0.0';
  const avgDays = withTwo.length > 0
    ? (withTwo.reduce((s, c) => s + daysBetween(c.firstDate, c.secondDate), 0) / withTwo.length).toFixed(1)
    : '—';

  // Top returning clients
  const topReturning = [...allClients]
    .filter(c => c.total >= 2)
    .sort((a, b) => b.total - a.total)
    .slice(0, 5);

  el.innerHTML = `
    <div class="accuracy-stats" style="margin-bottom:16px;">
      <div class="retention-stat accuracy-stat">
        <div class="v" style="color:var(--primary);">${pct(ret30)}%</div>
        <div class="l">${escapeHtml(t('an.retention_30'))}</div>
      </div>
      <div class="retention-stat accuracy-stat">
        <div class="v" style="color:var(--primary);">${pct(ret60)}%</div>
        <div class="l">${escapeHtml(t('an.retention_60'))}</div>
      </div>
      <div class="retention-stat accuracy-stat">
        <div class="v" style="color:var(--primary);">${pct(ret90)}%</div>
        <div class="l">${escapeHtml(t('an.retention_90'))}</div>
      </div>
      <div class="retention-stat accuracy-stat">
        <div class="v">${escapeHtml(String(avgDays))}</div>
        <div class="l">${escapeHtml(t('an.retention_avg_days'))}</div>
      </div>
    </div>
    ${topReturning.length > 0 ? `
    <div style="font-size:12px;font-weight:600;color:var(--text-dim);margin-bottom:8px;">${escapeHtml(t('an.top_returning'))}</div>
    <ul class="leaderboard">
      ${topReturning.map((c, i) => {
        const cl = clients.find(x => x.id === c.id);
        const name = cl ? localName(cl) : c.id;
        return `<li><span class="rank">${i+1}.</span><span class="name">${escapeHtml(name)}</span><span class="value">${c.total}× orders</span></li>`;
      }).join('')}
    </ul>` : ''}`;
}

function renderCostTrends() {
  const el = $('#costTrendsSection');
  if (!el) return;
  // Build last 12 months
  const now = new Date();
  const months = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    months.push({
      year: d.getFullYear(),
      month: d.getMonth(),
      label: d.toLocaleString('en', { month: 'short' }) + ' ' + d.getFullYear().toString().slice(2),
      key: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`,
    });
  }

  // Revenue per print-hour for completed orders
  const revPerHour = months.map(m => {
    const orders = printLog.filter(o =>
      o.status === 'completed' && !o.voidedAt && _countsForBusiness(o) && (o.date || '').startsWith(m.key)
    );
    const totalRev = orders.reduce((s, o) => s + orderNetRevenueBase(o), 0);
    const totalHrs = orders.reduce((s, o) => s + (+o.printTime || 0), 0);
    return totalHrs > 0 ? totalRev / totalHrs : 0;
  });

  // Average material cost per gram from inventory (simple average)
  const avgCostPerGram = months.map(() => {
    const items = inventory.filter(i => i.cost > 0 && i.weight > 0);
    if (items.length === 0) return 0;
    return items.reduce((s, i) => s + (i.cost / i.weight), 0) / items.length;
  });

  const maxRev = Math.max(...revPerHour, 1);
  const maxCost = Math.max(...avgCostPerGram, 0.001);

  const cur = currencySymbol();
  const revBars = revPerHour.map((v, i) => {
    const pct = Math.round((v / maxRev) * 100);
    return `<div style="display:flex;flex-direction:column;align-items:center;gap:3px;flex:1;">
      <div style="font-size:9.5px;color:var(--text-muted);font-variant-numeric:tabular-nums;">${v > 0 ? fmtMoney(v) : '—'}</div>
      <div style="background:rgba(255,255,255,0.08);width:100%;height:80px;display:flex;align-items:flex-end;border-radius:3px 3px 0 0;">
        <div style="background:var(--primary);width:100%;height:${pct}%;border-radius:3px 3px 0 0;transition:height 0.4s;opacity:0.8;"></div>
      </div>
      <div style="font-size:9px;color:var(--text-muted);writing-mode:vertical-rl;transform:rotate(180deg);max-height:40px;overflow:hidden;">${escapeHtml(months[i].label)}</div>
    </div>`;
  }).join('');

  const costBars = avgCostPerGram.map((v, i) => {
    const pct = maxCost > 0 ? Math.round((v / maxCost) * 100) : 0;
    return `<div style="display:flex;flex-direction:column;align-items:center;gap:3px;flex:1;">
      <div style="font-size:9.5px;color:var(--text-muted);font-variant-numeric:tabular-nums;">${v > 0 ? fmtMoney(v) : '—'}</div>
      <div style="background:rgba(255,255,255,0.08);width:100%;height:80px;display:flex;align-items:flex-end;border-radius:3px 3px 0 0;">
        <div style="background:var(--warning);width:100%;height:${pct}%;border-radius:3px 3px 0 0;transition:height 0.4s;opacity:0.8;"></div>
      </div>
      <div style="font-size:9px;color:var(--text-muted);writing-mode:vertical-rl;transform:rotate(180deg);max-height:40px;overflow:hidden;">${escapeHtml(months[i].label)}</div>
    </div>`;
  }).join('');

  el.innerHTML = `
    <h3 class="card-head"><span class="swatch"></span><span>${escapeHtml(t('an.cost_trends'))}</span></h3>
    <div style="margin-bottom:16px;">
      <div style="font-size:12.5px;font-weight:600;color:var(--text-dim);margin-bottom:8px;">
        ${escapeHtml(t('an.rev_per_hour'))} (${cur}/hr)
      </div>
      <div style="display:flex;gap:4px;align-items:flex-end;">${revBars}</div>
    </div>
    <div>
      <div style="font-size:12.5px;font-weight:600;color:var(--text-dim);margin-bottom:8px;">
        ${escapeHtml(t('an.cost_per_gram'))} (${cur}/g)
      </div>
      <div style="display:flex;gap:4px;align-items:flex-end;">${costBars}</div>
    </div>`;
}

/* ============================================================
   New 8-pack Feature 1: Per-operator analytics
   ============================================================ */

function renderOperatorAnalytics() {
  const el = $('#operatorAnalyticsSection');
  if (!el) return;
  if (operators.length === 0) { el.innerHTML = ''; return; }

  const completed = printLog.filter(o => o.status === 'completed' && o.operatorId);
  if (completed.length === 0) {
    el.innerHTML = `<h3 class="card-head"><span class="swatch"></span><span>${escapeHtml(t('an.operator_title'))}</span></h3><p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('an.accuracy_none'))}</p>`;
    return;
  }

  const rows = operators.map(op => {
    const jobs = completed.filter(o => o.operatorId === op.id);
    const wasteEntries = wasteLog.filter(w => {
      // Match waste entries to orders assigned to this operator
      return jobs.some(j => j.id === w.orderId);
    });
    // Avg print time accuracy: (estimated - actual) / estimated
    const accuracyScores = jobs
      .filter(o => o.actualPrintTime != null && o.printTime > 0)
      .map(o => (1 - Math.abs(+o.actualPrintTime - +o.printTime) / +o.printTime) * 100);
    const avgAccuracy = accuracyScores.length > 0
      ? (accuracyScores.reduce((s, v) => s + v, 0) / accuracyScores.length).toFixed(1) + '%'
      : '—';
    return { op, jobs: jobs.length, wasteEntries: wasteEntries.length, avgAccuracy };
  }).filter(r => r.jobs > 0);

  if (rows.length === 0) { el.innerHTML = ''; return; }

  el.innerHTML = `
    <h3 class="card-head"><span class="swatch"></span><span>${escapeHtml(t('an.operator_title'))}</span></h3>
    <div class="table-wrap">
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead><tr style="border-bottom:1px solid var(--border-soft);color:var(--text-muted);">
          <th style="padding:6px 8px;text-align:start;">${escapeHtml(t('op.name'))}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('an.op_jobs'))}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('an.op_waste'))}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('an.op_accuracy'))}</th>
        </tr></thead>
        <tbody>
          ${rows.map(r => `<tr style="border-bottom:1px solid rgba(255,255,255,0.05);">
            <td style="padding:7px 8px;font-weight:500;">${escapeHtml(r.op.name)}${r.op.role ? `<span style="font-size:11px;color:var(--text-muted);margin-inline-start:5px;">${escapeHtml(r.op.role)}</span>` : ''}</td>
            <td style="padding:7px 8px;text-align:end;">${r.jobs}</td>
            <td style="padding:7px 8px;text-align:end;color:${r.wasteEntries > 0 ? 'var(--danger)' : 'var(--text-muted)'};">${r.wasteEntries}</td>
            <td style="padding:7px 8px;text-align:end;color:var(--primary);">${escapeHtml(String(r.avgAccuracy))}</td>
          </tr>`).join('')}
        </tbody>
      </table>
    </div>`;
}

function renderTimeAnalytics() {
  const el = $('#timeAnalyticsSection');
  if (!el) return;
  if (timeEntries.length === 0) {
    el.innerHTML = `<h3 class="card-head"><span class="swatch"></span><span>${escapeHtml(t('time.analytics_title') || 'Time Tracking')}</span></h3><p style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('time.no_entries') || 'No time entries yet — log time using ⏱ on orders.')}</p>`;
    return;
  }

  const totalHours = timeEntries.reduce((s, e) => s + (+e.hours || 0), 0);
  const totalCost  = timeEntries.reduce((s, e) => s + (+e.cost  || 0), 0);
  const orderIds   = [...new Set(timeEntries.map(e => e.orderId).filter(Boolean))];
  const avgHrsPerOrder = orderIds.length > 0 ? (totalHours / orderIds.length) : 0;

  // Per-operator stats
  const opStats = {};
  for (const entry of timeEntries) {
    const oid = entry.operatorId;
    if (!opStats[oid]) opStats[oid] = { name: entry.operatorName, hours: 0, cost: 0, orderIds: new Set() };
    opStats[oid].hours += +entry.hours || 0;
    opStats[oid].cost  += +entry.cost  || 0;
    if (entry.orderId) opStats[oid].orderIds.add(entry.orderId);
  }
  const opRows = Object.entries(opStats).map(([, s]) => {
    const ordersWorked = [...s.orderIds];
    const revenue = ordersWorked.reduce((sum, oid) => {
      const o = printLog.find(x => x.id === oid);
      return sum + (+o?.price || 0);
    }, 0);
    const avgRevPerHr = s.hours > 0 ? revenue / s.hours : 0;
    const avgHrs      = s.orderIds.size > 0 ? s.hours / s.orderIds.size : 0;
    return { ...s, orders: s.orderIds.size, avgHrs: avgHrs.toFixed(2), avgRevPerHr: avgRevPerHr.toFixed(2) };
  });

  // Top 3 orders by hours
  const orderHours = {};
  for (const e of timeEntries) {
    if (!e.orderId) continue;
    if (!orderHours[e.orderId]) orderHours[e.orderId] = { hours: 0, ops: new Set() };
    orderHours[e.orderId].hours += +e.hours || 0;
    orderHours[e.orderId].ops.add(e.operatorName);
  }
  const top3 = Object.entries(orderHours)
    .sort((a, b) => b[1].hours - a[1].hours)
    .slice(0, 3)
    .map(([oid, v]) => {
      const o = printLog.find(x => x.id === oid);
      return { name: o?.project || oid, hours: v.hours.toFixed(2), ops: [...v.ops].join(', ') };
    });

  el.innerHTML = `
    <h3 class="card-head"><span class="swatch"></span><span>${escapeHtml(t('time.analytics_title') || 'Time Tracking Analytics')}</span></h3>
    <div style="display:flex;gap:20px;flex-wrap:wrap;margin-bottom:16px;">
      <div style="flex:1;min-width:100px;text-align:center;">
        <div style="font-size:20px;font-weight:700;">${totalHours.toFixed(2)}h</div>
        <div style="font-size:11px;color:var(--text-muted);">Total hours</div>
      </div>
      <div style="flex:1;min-width:100px;text-align:center;">
        <div style="font-size:20px;font-weight:700;color:#22c55e;">${fmtPrice(totalCost)}</div>
        <div style="font-size:11px;color:var(--text-muted);">Total labor cost</div>
      </div>
      <div style="flex:1;min-width:100px;text-align:center;">
        <div style="font-size:20px;font-weight:700;">${avgHrsPerOrder.toFixed(2)}h</div>
        <div style="font-size:11px;color:var(--text-muted);">Avg hrs/order</div>
      </div>
    </div>
    ${opRows.length > 0 ? `
    <div style="font-weight:600;font-size:13px;margin-bottom:8px;">Per-Operator Breakdown</div>
    <div class="table-wrap">
      <table style="width:100%;border-collapse:collapse;font-size:12.5px;">
        <thead><tr style="border-bottom:1px solid var(--border-soft);color:var(--text-muted);">
          <th style="padding:6px 8px;text-align:start;">Operator</th>
          <th style="padding:6px 8px;text-align:end;">Hours</th>
          <th style="padding:6px 8px;text-align:end;">Cost</th>
          <th style="padding:6px 8px;text-align:end;">Orders</th>
          <th style="padding:6px 8px;text-align:end;">Avg h/order</th>
          <th style="padding:6px 8px;text-align:end;">Revenue/hr</th>
        </tr></thead>
        <tbody>
          ${opRows.map(r => `<tr style="border-bottom:1px solid rgba(255,255,255,.05);">
            <td style="padding:7px 8px;font-weight:500;">${escapeHtml(r.name)}</td>
            <td style="padding:7px 8px;text-align:end;">${r.hours.toFixed(2)}h</td>
            <td style="padding:7px 8px;text-align:end;">${fmtPrice(r.cost)}</td>
            <td style="padding:7px 8px;text-align:end;">${r.orders}</td>
            <td style="padding:7px 8px;text-align:end;">${r.avgHrs}h</td>
            <td style="padding:7px 8px;text-align:end;color:var(--primary);">${fmtPrice(+r.avgRevPerHr)}</td>
          </tr>`).join('')}
        </tbody>
      </table>
    </div>` : ''}
    ${top3.length > 0 ? `
    <div style="font-weight:600;font-size:13px;margin-top:16px;margin-bottom:8px;">Top Orders by Hours</div>
    <div class="table-wrap">
      <table style="width:100%;border-collapse:collapse;font-size:12.5px;">
        <thead><tr style="border-bottom:1px solid var(--border-soft);color:var(--text-muted);">
          <th style="padding:6px 8px;text-align:start;">Project</th>
          <th style="padding:6px 8px;text-align:end;">Total Hours</th>
          <th style="padding:6px 8px;text-align:start;">Operators</th>
        </tr></thead>
        <tbody>
          ${top3.map(r => `<tr style="border-bottom:1px solid rgba(255,255,255,.05);">
            <td style="padding:7px 8px;">${escapeHtml(r.name)}</td>
            <td style="padding:7px 8px;text-align:end;font-weight:600;">${r.hours}h</td>
            <td style="padding:7px 8px;font-size:11.5px;color:var(--text-muted);">${escapeHtml(r.ops)}</td>
          </tr>`).join('')}
        </tbody>
      </table>
    </div>` : ''}`;
}

/** Executive summary: at-a-glance KPIs (revenue, margin, on-time, cash) + top
 *  clients/products, scoped to a quick date range. Self-contained modal. */
function openExecutiveSummary() {
  if (typeof KhaytKpi === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  const cur = (typeof currencySymbol === 'function') ? currencySymbol() : '';
  let range = 'month';
  let locId = settings.activeLocationId || ''; // '' = all locations
  const locList = (typeof locations !== 'undefined' && Array.isArray(locations)) ? locations : [];

  /* The scoping and the completed/on-time rules moved to lib/kpi-rows.js so the
   * Mac app can use the same ones — it had reached for computeKpis directly,
   * with raw orders, and been handed a screen of zeros. Money stays here: base
   * currency needs the rates in settings and the client's own currency, which
   * is renderer/currency.js's business, so it is passed in per order. */
  const rowsFor = (r) => {
    const [from, to] = KhaytKpiRows.bounds(r);
    return KhaytKpiRows.kpiRows({
      orders: printLog || [],
      from, to,
      // So the rows come back with revenue NET OF TAX — the module resolves the
      // profile and decides, rather than each host netting it its own way.
      settings: (typeof settings !== 'undefined' ? settings : null),
      locationId: locId,
      locationOf: (typeof orderLocationId === 'function') ? orderLocationId : null,
      money: (o) => ({
        revenue: orderNetRevenueBase(o),
        cost: (o.parts || []).reduce((s, p) => s + partTotalCost(p), 0)
          + convertToBase(+o.shippingCost || 0, orderCurrency(o)),
        outstanding: (typeof orderOwedBase === 'function') ? orderOwedBase(o) : 0,
      }),
      clientName: (o) => {
        const client = o.clientId ? clients.find((c) => c.id === o.clientId) : null;
        if (!client) return '';
        return (typeof localName === 'function') ? localName(client) : client.name;
      },
      unassigned: t('dash.unassigned') || '—',
    });
  };

  const card = (label, value, sub) => `<div style="flex:1;min-width:120px;background:var(--bg-elev,#1a1d24);border:1px solid var(--border-soft);border-radius:12px;padding:12px 14px;">
    <div style="font-size:11px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.04em;">${escapeHtml(label)}</div>
    <div style="font-size:21px;font-weight:700;margin-top:3px;">${escapeHtml(value)}</div>
    ${sub ? `<div style="font-size:11px;color:var(--text-muted);margin-top:2px;">${escapeHtml(sub)}</div>` : ''}
  </div>`;
  const topList = (title, items) => `<div style="flex:1;min-width:200px;">
    <div style="font-size:12px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.04em;margin-bottom:6px;">${escapeHtml(title)}</div>
    ${items.length ? items.map((x) => `<div style="display:flex;justify-content:space-between;padding:3px 0;font-size:13px;border-bottom:1px solid var(--border-soft);"><span>${escapeHtml(x.name)}</span><span style="font-variant-numeric:tabular-nums;">${escapeHtml(fmtMoney(x.revenue))} · ${x.count}</span></div>`).join('') : `<div style="font-size:12.5px;color:var(--text-muted);">${escapeHtml(t('exec.none') || '—')}</div>`}
  </div>`;

  const renderBody = (modal) => {
    const k = KhaytKpi.computeKpis(rowsFor(range));
    const ranges = [['month', t('an.range.month')], ['last_month', t('an.range.last_month')], ['quarter', t('an.range.quarter')], ['year', t('an.range.year')], ['all', t('an.range.all')]];
    const locSelect = locList.length ? `<select id="execLoc" style="font-size:12px;margin-bottom:12px;margin-inline-start:8px;width:auto;">
        <option value=""${locId === '' ? ' selected' : ''}>${escapeHtml(t('loc.all') || 'All locations')}</option>
        ${locList.map((l) => `<option value="${escapeHtml(l.id)}"${l.id === locId ? ' selected' : ''}>${escapeHtml(l.name || l.id)}</option>`).join('')}
      </select>` : '';
    modal.querySelector('#execBody').innerHTML = `
      <div class="seg" style="display:inline-flex;flex-wrap:wrap;gap:4px;margin-bottom:12px;">
        ${ranges.map(([v, lbl]) => `<button type="button" class="execRange${v === range ? ' on' : ''}" data-r="${v}" style="font-size:12px;padding:5px 10px;">${escapeHtml(lbl || v)}</button>`).join('')}
      </div>${locSelect}
      <div style="display:flex;gap:8px;flex-wrap:wrap;">
        ${card(t('an.revenue') || 'Revenue', fmtMoney(k.revenue) + ' ' + cur, k.completedCount + ' ' + (t('exec.completed') || 'completed'))}
        ${card(t('pnl.gross') || 'Gross profit', fmtMoney(k.grossProfit) + ' ' + cur, (t('pnl.gross_margin') || 'Margin') + ' ' + k.grossMargin + '%')}
        ${card(t('exec.aov') || 'Avg order', fmtMoney(k.avgOrderValue) + ' ' + cur, '')}
        ${card(t('exec.on_time') || 'On-time', k.onTimePct == null ? '—' : k.onTimePct + '%', k.onTimeTotal + ' ' + (t('exec.with_due') || 'with due date'))}
        ${card(t('exec.outstanding') || 'Outstanding', fmtMoney(k.outstanding) + ' ' + cur, '')}
      </div>
      <div style="display:flex;gap:18px;flex-wrap:wrap;margin-top:16px;">
        ${topList(t('exec.top_clients') || 'Top clients', k.topClients)}
        ${topList(t('exec.top_products') || 'Top jobs', k.topProducts)}
      </div>`;
    modal.querySelectorAll('.execRange').forEach((b) => b.addEventListener('click', () => { range = b.dataset.r; renderBody(modal); }));
    modal.querySelector('#execLoc')?.addEventListener('change', (e) => { locId = e.target.value; renderBody(modal); });
  };

  openFormModal({
    title: '📊 ' + (t('exec.title') || 'Executive summary'),
    noSave: true,
    bodyHtml: `<div id="execBody"></div>`,
    onMount(modal) { renderBody(modal); },
  });
}

/** Custom report builder: choose fields/filters/range over orders → preview +
 *  CSV, and save report definitions for re-use. */
function openReportBuilder() {
  if (typeof KhaytReportBuilder === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  const STATUSES = ['quote', 'pending', 'printing', 'post', 'qc', 'completed', 'delivered', 'on_hold'];
  // The shape `report-builder.js` asks its caller for, built by
  // `lib/report-records.js` rather than here. It was twenty lines inline, and
  // they are not twenty lines of formatting: `price` is revenue in the shop's
  // base currency, `balance` is what is owed after credits, `paymentStatus` is
  // the rule that decides what "paid" means. The Mac app needs the same rows,
  // and a second copy of those three is how two apps come to disagree about a
  // shop's money.
  const flatten = () => KhaytReportRecords.reportRecords(printLog, {
    money: KhaytOrderMoney, payment: KhaytOrderPayment,
    clients, machines, localName,
    // order-money reads the base currency and the rates off the settings it is
    // handed; the renderer's own helpers close over the same object.
    ctx: { settings, clients },
  });
  const fieldLabel = (k) => t('rb.f_' + k) || (KhaytReportBuilder.FIELDS.find((f) => f.key === k) || {}).label || k;
  // `queue.`, not `status.` — there has never been a `status.*` key in any
  // locale, and `t()` returns the KEY for one it does not have, so every one
  // of these chips has read the literal "status.quote" in all nine languages
  // since the report builder shipped. The `|| s` could not save it: a returned
  // key is truthy. See the same trap in `lib/` — a fallback after `t()` is
  // dead code by construction.
  const statusLabel = (s) => t('queue.' + s);
  let sel = { fields: KhaytReportBuilder.DEFAULT_FIELDS.slice(), statusIn: [], from: '', to: '' };

  const render = (modal) => {
    const labels = {}; KhaytReportBuilder.FIELD_KEYS.forEach((k) => { labels[k] = fieldLabel(k); });
    const rep = KhaytReportBuilder.buildReport(flatten(), { ...sel, labels });
    const fieldBoxes = KhaytReportBuilder.FIELDS.map((f) => `<label style="display:inline-flex;align-items:center;gap:5px;font-size:12.5px;margin:0 10px 6px 0;"><input type="checkbox" class="rbField" value="${f.key}" ${sel.fields.includes(f.key) ? 'checked' : ''} style="width:auto;margin:0;">${escapeHtml(fieldLabel(f.key))}</label>`).join('');
    const statusBoxes = STATUSES.map((s) => `<label style="display:inline-flex;align-items:center;gap:5px;font-size:12px;margin:0 8px 6px 0;"><input type="checkbox" class="rbStatus" value="${s}" ${sel.statusIn.includes(s) ? 'checked' : ''} style="width:auto;margin:0;">${escapeHtml(statusLabel(s))}</label>`).join('');
    const saved = KhaytSavedReports.savedReports(settings);
    const preview = rep.rows.slice(0, 8);
    modal.querySelector('#rbBody').innerHTML = `
      ${saved.length ? `<div style="margin-bottom:10px;"><label style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('rb.saved') || 'Saved reports')}</label>
        <div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:4px;">${saved.map((r) => `<span style="display:inline-flex;align-items:center;"><button type="button" class="btn ghost small rbLoad" data-id="${escapeHtml(r.id)}">${escapeHtml(r.name)}</button><button type="button" class="btn ghost small rbDrop" data-id="${escapeHtml(r.id)}" title="${escapeHtml(t('rb.remove'))}" aria-label="${escapeHtml(t('rb.remove'))}">\u00d7</button></span>`).join('')}</div></div>` : ''}
      <label style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('rb.fields') || 'Columns')}</label>
      <div style="margin:4px 0 10px;">${fieldBoxes}</div>
      <label style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('rb.statuses') || 'Statuses (none = all)')}</label>
      <div style="margin:4px 0 10px;">${statusBoxes}</div>
      <div class="inline-pair" style="margin-bottom:10px;">
        <div><label style="margin-top:0;">${escapeHtml(t('rb.from') || 'From')}</label><input type="date" id="rbFrom" value="${escapeHtml(sel.from)}"></div>
        <div><label style="margin-top:0;">${escapeHtml(t('rb.to') || 'To')}</label><input type="date" id="rbTo" value="${escapeHtml(sel.to)}"></div>
      </div>
      <div style="font-size:12px;color:var(--text-muted);margin-bottom:6px;">${escapeHtml((t('rb.matches', { n: rep.count }) || `${rep.count} rows`))}</div>
      <div style="overflow-x:auto;border:1px solid var(--border-soft);border-radius:8px;max-height:240px;">
        <table style="width:100%;border-collapse:collapse;font-size:12px;"><thead><tr>${rep.headers.map((h) => `<th style="text-align:start;padding:5px 8px;color:var(--text-muted);border-bottom:1px solid var(--border-soft);white-space:nowrap;">${escapeHtml(h)}</th>`).join('')}</tr></thead>
        <tbody>${preview.map((row) => `<tr>${row.map((c) => `<td style="padding:4px 8px;border-bottom:1px solid var(--border-soft);white-space:nowrap;">${escapeHtml(String(c))}</td>`).join('')}</tr>`).join('') || `<tr><td style="padding:10px;color:var(--text-muted);">${escapeHtml(t('rb.empty') || 'No matching rows')}</td></tr>`}</tbody></table>
      </div>
      <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px;">
        <button type="button" id="rbExport" class="btn small primary">${escapeHtml(t('rb.export') || 'Export CSV')}</button>
        <button type="button" id="rbSave" class="btn small ghost">${escapeHtml(t('rb.save') || 'Save report')}</button>
      </div>`;

    const sync = () => {
      sel.fields = [...modal.querySelectorAll('.rbField:checked')].map((c) => c.value);
      sel.statusIn = [...modal.querySelectorAll('.rbStatus:checked')].map((c) => c.value);
      sel.from = modal.querySelector('#rbFrom').value; sel.to = modal.querySelector('#rbTo').value;
    };
    modal.querySelectorAll('.rbField, .rbStatus').forEach((c) => c.addEventListener('change', () => { sync(); render(modal); }));
    modal.querySelector('#rbFrom').addEventListener('change', () => { sync(); render(modal); });
    modal.querySelector('#rbTo').addEventListener('change', () => { sync(); render(modal); });
    modal.querySelector('#rbExport').addEventListener('click', () => {
      sync();
      const out = KhaytReportBuilder.buildReport(flatten(), { ...sel, labels });
      downloadBlob(new Blob([KhaytReportBuilder.reportToCsv(out)], { type: 'text/csv;charset=utf-8;' }), `report-${localDateStr()}.csv`);
      toast(t('rb.exported') || 'Report exported', 'success');
    });
    modal.querySelector('#rbSave').addEventListener('click', () => {
      sync();
      const name = (prompt(t('rb.name_prompt') || 'Report name:') || '').trim();
      if (!name) return;
      // `addReport`, not a push: saving twice under one name used to append
      // twice, so a shop correcting a report it had just run ended up with six
      // entries of the same name and no way to remove any of them.
      settings.savedReports = KhaytSavedReports.addReport(
        settings.savedReports, { name, fields: sel.fields, statusIn: sel.statusIn, from: sel.from, to: sel.to },
        uid('RPT'));
      saveAll(); render(modal);
      toast(t('rb.saved_ok') || 'Report saved', 'success');
    });
    modal.querySelectorAll('.rbLoad').forEach((b) => b.addEventListener('click', () => {
      const r = KhaytSavedReports.findReport(settings.savedReports, b.dataset.id);
      if (r) { sel = { fields: r.fields.slice(), statusIn: r.statusIn.slice(), from: r.from, to: r.to }; render(modal); }
    }));
    modal.querySelectorAll('.rbDrop').forEach((b) => b.addEventListener('click', () => {
      settings.savedReports = KhaytSavedReports.removeReport(settings.savedReports, b.dataset.id);
      saveAll(); render(modal);
    }));
  };

  openFormModal({
    title: '📑 ' + (t('rb.title') || 'Report builder'),
    noSave: true,
    bodyHtml: `<div id="rbBody"></div>`,
    onMount(modal) { render(modal); },
  });
}

/** Export a P&L summary CSV scoped to the selected analytics date range. */
function exportPnlCsv() {
  const sel = $('#analyticsRange');
  let label = sel?.selectedOptions?.[0]?.textContent?.trim() || t('an.range.all') || 'All time';
  if (analyticsRange === 'custom') {
    const f = customRangeFrom.analytics || '', tt = customRangeTo.analytics || '';
    if (f || tt) label = `${f || '…'} → ${tt || '…'}`;
  }
  const _taxProfile = KhaytTax.profileFromSettings(settings);
  const orders = (printLog || [])
    .filter(o => o.status === 'completed' && !o.voidedAt && _countsForBusiness(o) && inRange(o.date, analyticsRange, 'analytics'))
    .map(o => {
      const revenue = orderNetRevenueBase(o);
      const cogs = (o.parts || []).reduce((s, p) => s + partTotalCost(p), 0)
        + convertToBase(+o.shippingCost || 0, orderCurrency(o));
      // Same rule as above — see lib/tax.js. `revenue` here is gross.
      return { revenue, cogs, vat: KhaytTax.computeTax(revenue, _taxProfile).taxTotal };
    });
  const exps = (expenses || [])
    .filter(e => inRange(e.date, analyticsRange, 'analytics'))
    .map(e => ({ amount: +e.amount || 0, category: e.category || '' }));

  if (!orders.length && !exps.length) { toast(t('an.pnl_empty') || 'No data for this period', 'error'); return; }

  const summary = KhaytPnl.computePnl({ orders, expenses: exps, label });
  const labels = {
    title: t('pnl.title'), item: t('pnl.item'), amount: t('pnl.amount'), orders: t('an.pnl_orders'),
    revenue: t('an.revenue'), cogs: t('pnl.cogs'), gross: t('pnl.gross'), gross_margin: t('pnl.gross_margin'),
    opex: t('pnl.opex'), vat: t('an.pnl_vat'), net: t('an.pnl_net'),
  };
  const csv = KhaytPnl.pnlToCsv(summary, { currency: currencySymbol(), labels });
  downloadBlob(new Blob([csv], { type: 'text/csv;charset=utf-8;' }),
    `pnl-${localDateStr()}.csv`);
  toast(t('pnl.exported') || 'P&L exported', 'success');
}

async function exportAnalyticsReport() {
  // 1. Make sure analytics is freshly rendered
  renderAnalytics();

  // 2. Collect chart/table SVGs from DOM (already rendered)
  const chartIds = [
    'revenueChartWrap',
    'topProductsList',
    'topClientsList',
    'activityList',
    'accuracySection',
    'quoteFunnelChart',
    'monthlyTrendChart',
    'machineRevenueChart',
    'profitMarginChart',
    'wasteTrendChart',
    'cycleTimeChart',
    'cashFlowChart',
    'expenseCategoryChart',
    'leadTimeTable',
    'npsTrendChart',
    'clientLtvTable',
    'machineDowntimeChart',
    'maintenanceCostChart',
    'materialUsageChart',
    'filamentPerfSection',
    'printerUtilSection',
    'pnlSection',
    'productProfitSection',
    'slaSection',
    'machinePLSection',
    'throughputHeatmapSection',
    'clientRetentionSection',
    'costTrendsSection',
    'operatorAnalyticsSection',
    'agedReceivablesSection',
    'surveyAnalyticsSection',
    'newVsReturningSection',
  ];

  const sections = chartIds.map(id => {
    const el = document.getElementById(id);
    let inner = el?.innerHTML?.trim();
    if (!inner) return '';
    // Strip <script> blocks to prevent XSS when content is written via document.write()
    inner = inner.replace(/<script[\s\S]*?<\/script>/gi, '').replace(/<script[^>]*/gi, '');
    return `<div class="report-section">${inner}</div>`;
  }).filter(Boolean).join('\n');

  // 3. KPI summary
  const pl = printLog || [];
  const completedOrders = pl.filter(o => o.status === 'completed' && !o.voidedAt && _countsForBusiness(o));
  const totalRev = pl.filter(o => (o.status === 'completed' || o.status === 'delivered') && !o.voidedAt)
    .reduce((s, o) => s + orderNetRevenueBase(o), 0);
  const totalOrders = pl.length;
  const avgMargin = (() => {
    const withMargin = completedOrders.filter(o => o.costBasis > 0 && +o.price > 0);
    if (!withMargin.length) return null;
    return withMargin.reduce((s, o) => {
      const rev = Math.max(0, (+o.price || 0) - orderCreditedRaw(o));
      return s + (rev > 0 ? (rev - o.costBasis) / rev * 100 : 0);
    }, 0) / withMargin.length;
  })();
  const matCount = {};
  pl.forEach(o => { if (o.material) matCount[o.material] = (matCount[o.material] || 0) + 1; });
  const topMat = Object.entries(matCount).sort((a, b) => b[1] - a[1])[0]?.[0] || '—';

  const s = settings || {};
  const shopName = escapeHtml(s.bizName || s.bizEn || s.shopName || 'Khayt');
  const accentColor = safeCssColor(s.invoiceAccentColor || s.invAccentColor, '#5b9cf0');
  const rangeLabel = escapeHtml(t('an.range.' + analyticsRange) || analyticsRange);
  const reportDate = new Date().toLocaleDateString(localeTag());

  const safeLogo = typeof safeBizLogo === 'function' ? safeBizLogo() : '';

  // 4. Build HTML
  const html = `<!DOCTYPE html>
<html dir="${document.documentElement.dir || 'ltr'}" lang="${document.documentElement.lang || 'en'}">
<head>
<meta charset="UTF-8">
<title>${shopName} — ${escapeHtml(t('an.report_title') || 'Analytics Report')}</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:-apple-system,'Segoe UI',sans-serif; font-size:11pt; color:#111; background:#fff; padding:15mm 20mm; }
  .report-header { display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:10mm; border-bottom:2.5px solid ${accentColor}; padding-bottom:6mm; }
  .shop-name { font-size:20pt; font-weight:800; color:${accentColor}; }
  .report-meta { text-align:right; font-size:9.5pt; color:#666; line-height:1.7; }
  .report-title { font-size:14pt; font-weight:700; color:#111; margin-bottom:1mm; }
  .kpi-row { display:grid; grid-template-columns:repeat(4,1fr); gap:8px; margin-bottom:10mm; }
  .kpi-card { background:#f8fafc; border:1px solid #e5e7eb; border-radius:8px; padding:10px 14px; }
  .kpi-label { font-size:8.5pt; color:#888; text-transform:uppercase; letter-spacing:.4pt; }
  .kpi-value { font-size:16pt; font-weight:700; color:${accentColor}; margin-top:2px; }
  .report-section { margin-bottom:8mm; page-break-inside:avoid; }
  h4 { font-size:11pt; font-weight:700; color:#444; margin:6mm 0 3mm; }
  table { width:100%; border-collapse:collapse; font-size:9.5pt; }
  th { background:${accentColor}; color:#fff; padding:5px 8px; text-align:left; font-size:8.5pt; }
  td { padding:5px 8px; border-bottom:0.3mm solid #e5e7eb; }
  tr:nth-child(even) td { background:#f9fafb; }
  svg text { font-family:-apple-system,'Segoe UI',sans-serif !important; }
  ul { list-style:none; padding:0; }
  li { padding:4px 0; border-bottom:0.3mm solid #f0f0f0; font-size:10pt; }
  @media print {
    body { padding:10mm 15mm; }
    .report-section { page-break-inside:avoid; }
  }
  .logo-img { max-height:50px; max-width:120px; object-fit:contain; }
</style>
</head>
<body>
  <div class="report-header">
    <div>
      ${safeLogo ? `<img src="${safeLogo}" class="logo-img" alt="logo" style="margin-bottom:4px;display:block;">` : ''}
      <div class="shop-name">${shopName}</div>
    </div>
    <div class="report-meta">
      <div class="report-title">${escapeHtml(t('an.report_title') || 'Analytics Report')}</div>
      <div>${escapeHtml(t('an.period') || 'Period')}: <strong>${rangeLabel}</strong></div>
      <div>${escapeHtml(t('an.generated') || 'Generated')}: ${reportDate}</div>
    </div>
  </div>

  <div class="kpi-row">
    <div class="kpi-card">
      <div class="kpi-label">${escapeHtml(t('an.total_revenue') || 'Total Revenue')}</div>
      <div class="kpi-value">${escapeHtml(fmtPrice(totalRev))}</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">${escapeHtml(t('an.total_orders') || 'Total Orders')}</div>
      <div class="kpi-value">${totalOrders}</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">${escapeHtml(t('an.avg_margin') || 'Avg Margin')}</div>
      <div class="kpi-value">${avgMargin !== null ? avgMargin.toFixed(1) + '%' : '—'}</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">${escapeHtml(t('an.top_material') || 'Top Material')}</div>
      <div class="kpi-value" style="font-size:13pt;">${escapeHtml(topMat)}</div>
    </div>
  </div>

  ${sections}

  <div style="margin-top:12mm;padding-top:4mm;border-top:0.5px solid #ddd;font-size:8pt;color:#aaa;text-align:center;">
    ${shopName} · ${escapeHtml(t('an.report_footer') || 'Generated by Khayt')} · ${reportDate}
  </div>
</body>
</html>`;

  // 5. Open and print
  const win = window.open('', '_blank', 'width=1000,height=760,toolbar=0,menubar=0,scrollbars=1');
  if (win) {
    win.document.open();
    win.document.write(sanitizePrintHtml(html));
    win.document.close();
    win.focus();
    setTimeout(() => win.print(), 600);
  } else if (window.hubAPI?.saveHtml) {
    const fname = `analytics-report-${localDateStr()}.html`;
    const saved = await window.hubAPI.saveHtml(html, fname);
    if (saved?.path) { window.hubAPI?.openPath?.(saved.path); return; }
    if (typeof saved === 'string') { window.hubAPI?.openPath?.(saved); return; }
  }
}

function renderThroughputHeatmap() {
  const el = $('#throughputHeatmapSection');
  if (!el) return;

  // `lib/throughput.js`. It filtered on `completed` alone, so work that had
  // reached a customer was not in the picture of when the shop is busy.
  const wh = KhaytWorkingWeek.workingHours(settings);
  const DAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
  const flow = KhaytThroughput.throughput({
    orders: printLog || [],
    openDays: DAY_KEYS.map((k) => (wh[k] || 0) > 0),
  }, { inWindow: (o) => inRange(o.date, analyticsRange, 'analytics') });

  if (!flow.totals.enough) {
    el.innerHTML = `<p style="color:var(--text-muted); font-size:13px;">${escapeHtml(t('an.heatmap_no_data'))}</p>`;
    return;
  }

  const matrix = flow.matrix;
  const maxVal = Math.max(1, flow.totals.peak);
  // 2023-01-01 was a Sunday, so index 0 lines up with getDay() === 0.
  const dayFmt = new Intl.DateTimeFormat(localeTag(), { weekday: 'short' });
  const DAY_NAMES = Array.from({ length: 7 }, (_, i) => dayFmt.format(new Date(Date.UTC(2023, 0, i + 1))));
  const SHOWN_HOURS = [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22];

  const headerRow = `<tr>
    <th style="padding:2px 6px;">${escapeHtml(t('an.heatmap_day'))}</th>
    ${Array.from({ length: 24 }, (_, h) => `<th class="heatmap-cell" style="background:none; border:none; width:28px; height:28px;">${SHOWN_HOURS.includes(h) ? h : ''}</th>`).join('')}
  </tr>`;

  const bodyRows = matrix.map((row, dow) => {
    const cells = row.map((count, h) => {
      const intensity = count / maxVal;
      return `<td class="heatmap-cell" style="--hm-intensity:${intensity.toFixed(2)};" title="${DAY_NAMES[dow]} ${h}:00 — ${count} order(s)">${count > 0 ? count : ''}</td>`;
    }).join('');
    return `<tr><th style="font-size:11px; padding:2px 6px; text-align:start;">${escapeHtml(DAY_NAMES[dow])}</th>${cells}</tr>`;
  }).join('');

  el.innerHTML = `
    <div style="overflow-x:auto;">
      <table class="heatmap-table">
        <thead>${headerRow}</thead>
        <tbody>${bodyRows}</tbody>
      </table>
    </div>
    <div class="heatmap-legend">
      <span>0</span>
      <div class="heatmap-legend-bar"></div>
      <span>${maxVal}</span>
    </div>`;
}

function computeCapacityForecast() {
  // `lib/capacity.js`, not the arithmetic that used to be here.
  //
  // The clamp is gone, and that is the point: `pct` was `Math.min(100, …)`, so
  // a machine booked three weeks over read as exactly full — identical to one
  // with nothing left and nothing waiting. "Full" means take no more today;
  // "300%" means the shop is three weeks behind. It also counted voided orders
  // and dropped every machine with no target, so a queue could grow behind a
  // panel reading 40%.
  const report = KhaytCapacity.capacity({
    machines: machines || [], orders: printLog || [], days: 7,
    unassigned: t('dash.unassigned'),
  });
  const rows = report.rows
    .filter((r) => r.hoursPerDay > 0)
    .map((r) => ({
      machineName: r.name, color: r.color,
      bookedHours: r.bookedHours, availableHours: r.availableHours,
      // Rounded but NOT capped — a caller drawing a bar must clamp the WIDTH,
      // never the number it prints beside it.
      pct: Math.round(r.loadPct),
      overbooked: r.overbooked, daysToClear: r.daysToClear,
    }));
  return {
    rows,
    totalBooked: report.totals.bookedHours,
    totalAvail: report.totals.availableHours,
    totalPct: report.totals.loadPct == null ? 0 : Math.round(report.totals.loadPct),
    untargeted: report.totals.untargeted,
  };
}

function renderCapacityGauge() {
  const el = $('#capacityGaugeSection');
  if (!el) return;
  const { rows, totalPct } = computeCapacityForecast();
  if (rows.length === 0) {
    el.innerHTML = `<div class="dash-section" style="margin-bottom:14px;">
      <h3 class="dash-section-head">${escapeHtml(t('dash.capacity_title'))}</h3>
      <p style="color:var(--text-muted); font-size:12.5px;">${escapeHtml(t('dash.capacity_no_targets'))}</p>
    </div>`;
    return;
  }
  const gaugeRows = rows.map(r => {
    const col = r.pct >= 90 ? 'var(--danger)' : r.pct >= 70 ? 'var(--warning)' : 'var(--success)';
    return `<div style="margin-bottom:8px;">
      <div style="display:flex; justify-content:space-between; font-size:12px; margin-bottom:3px;">
        <span style="display:flex; align-items:center; gap:6px;">
          <span style="width:8px;height:8px;border-radius:50%;background:${safeCssColor(r.color)};display:inline-block;"></span>
          ${escapeHtml(r.machineName)}
        </span>
        <span style="color:var(--text-muted);">${r.bookedHours.toFixed(1)}h / ${r.availableHours.toFixed(1)}h (${r.pct}%)</span>
      </div>
      <div style="background:var(--surface-2); border-radius:3px; height:6px; overflow:hidden;">
        <div style="width:${Math.min(100, r.pct)}%; height:100%; background:${col}; transition:width 0.3s;"></div>
      </div>
    </div>`;
  }).join('');
  el.innerHTML = `<div class="dash-section" style="margin-bottom:14px;">
    <h3 class="dash-section-head">${escapeHtml(t('dash.capacity_title'))} <span style="font-size:11px;font-weight:400;color:var(--text-muted);">${escapeHtml(t('dash.capacity_booked', { pct: totalPct }))}</span></h3>
    ${gaugeRows}
  </div>`;
}

function renderAgedReceivables() {
  const el = $('#agedReceivablesSection');
  if (!el) return;

  // The ageing is lib/receivables.js's — which orders count, how an instalment
  // plan is aged by each payment's own due date, and what is owed in the shop's
  // own currency. It was all inline here, so the Mac app could show what a shop
  // was owed in total and not who, or since when, which is the half it acts on.
  const Rec = (typeof globalThis !== 'undefined' && globalThis.KhaytReceivables)
    || require('../lib/receivables.js');
  const aged = Rec.aged(printLog, { settings, clients, currencies: CURRENCIES, now: new Date() });
  if (aged.rows.length === 0) {
    el.innerHTML = `<p style="color:var(--success);margin:0;">✅ ${escapeHtml(t('an.aged_none'))}</p>`;
    return;
  }
  // The screen's own labels keep their en dash; the module's are ASCII because
  // they cross a JSON bridge into the Mac app.
  const LABEL = { '0-30': '0–30', '31-60': '31–60', '61-90': '61–90', '90+': '90+' };
  const buckets = {};
  for (const b of aged.buckets) buckets[LABEL[b.label]] = aged.rows.filter(r => r.bucket === b.label);
  const totalOwed = aged.total;

  const bucketColors = { '0–30': 'var(--success)', '31–60': 'var(--warning)', '61–90': '#f97316', '90+': 'var(--danger)' };

  let html = `
    <div style="display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px;">
      ${Object.entries(buckets).map(([label, items]) => {
        const total = items.reduce((s, i) => s + i.owed, 0);
        return `<div style="flex:1;min-width:120px;padding:12px 16px;background:var(--bg-elev);border-radius:var(--radius);border-inline-start:3px solid ${bucketColors[label]};">
          <div style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('an.aged_bucket_days', { label }))}</div>
          <div style="font-size:16px;font-weight:700;margin-top:4px;">${fmtPrice(total)}</div>
          <div style="font-size:11px;color:var(--text-dim);">${escapeHtml(t('an.aged_orders_n', { n: items.length }))}</div>
        </div>`;
      }).join('')}
    </div>
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;">
      <strong style="font-size:14px;">${escapeHtml(t('an.aged_total_outstanding'))} <span style="color:var(--danger);">${fmtPrice(totalOwed)}</span></strong>
      <button class="btn small ghost" id="btnExportAgedCsv">⬇ ${escapeHtml(t('exp.export_csv'))}</button>
    </div>`;

  Object.entries(buckets).forEach(([label, items]) => {
    if (items.length === 0) return;
    html += `<div style="margin-bottom:12px;">
      <div style="font-size:12px;font-weight:600;color:${bucketColors[label]};margin-bottom:6px;padding:4px 8px;background:rgba(0,0,0,0.1);border-radius:4px;">${label} DAYS — ${items.length} order(s)</div>
      <table style="width:100%;border-collapse:collapse;font-size:12.5px;">
        <thead><tr style="color:var(--text-dim);">
          <th style="text-align:left;padding:4px 6px;">${escapeHtml(t('an.aged_col_order'))}</th>
          <th style="text-align:left;padding:4px 6px;">${escapeHtml(t('an.aged_col_project'))}</th>
          <th style="text-align:left;padding:4px 6px;">${escapeHtml(t('an.aged_col_client'))}</th>
          <th style="text-align:right;padding:4px 6px;">${escapeHtml(t('an.aged_col_owed'))}</th>
          <th style="text-align:right;padding:4px 6px;">${escapeHtml(t('an.aged_col_days'))}</th>
        </tr></thead>
        <tbody>${items.map(i => `<tr style="border-top:1px solid var(--border);">
          <td style="padding:5px 6px;color:var(--text-muted);font-family:var(--font-num);">${escapeHtml(i.id)}</td>
          <td style="padding:5px 6px;">${escapeHtml(i.project||'—')}</td>
          <td style="padding:5px 6px;">${escapeHtml(i.client||'—')}</td>
          <td style="padding:5px 6px;text-align:right;color:var(--danger);font-weight:600;">${fmtPrice(i.owed)}</td>
          <td style="padding:5px 6px;text-align:right;color:${bucketColors[label]};">${i.days}</td>
        </tr>`).join('')}</tbody>
      </table></div>`;
  });
  el.innerHTML = html;

  el.querySelector('#btnExportAgedCsv')?.addEventListener('click', () => {
    const rows = [['Order ID','Project','Client','Owed','Days Outstanding','Bucket']];
    Object.entries(buckets).forEach(([label, items]) => {
      items.forEach(i => rows.push([i.id, i.project||'', i.client||'', i.owed.toFixed(2), i.days, label]));
    });
    downloadBlob(new Blob([rows.map(r => r.map(csvEsc).join(',')).join('\n')], { type: 'text/csv' }), 'aged-receivables.csv');
  });
}

function renderSurveyAnalytics() {
  const el = $('#surveyAnalyticsSection');
  if (!el) return;
  const surveyed = printLog.filter(o => o.survey?.rating);
  if (surveyed.length === 0) {
    el.innerHTML = `<p style="color:var(--text-muted);">${escapeHtml(t('an.no_survey_yet'))}</p>`;
    return;
  }
  const avg = surveyed.reduce((s, o) => s + o.survey.rating, 0) / surveyed.length;
  const dist = [1,2,3,4,5].map(r => ({ r, n: surveyed.filter(o => o.survey.rating === r).length }));
  // NPS on 5-star scale: 5 = promoter, 4 = passive, 1-3 = detractors
  // (True NPS requires 0-10 scale; adapt proportionally: 5→promoter, 4→passive, ≤3→detractor)
  const promoters  = surveyed.filter(o => o.survey.rating === 5).length;
  const detractors = surveyed.filter(o => o.survey.rating <= 3).length;
  const nps = Math.round((promoters - detractors) / surveyed.length * 100);

  el.innerHTML = `
    <div style="display:flex;gap:16px;flex-wrap:wrap;margin-bottom:16px;">
      <div style="text-align:center;padding:12px 20px;background:var(--bg-elev);border-radius:var(--radius);">
        <div style="font-size:28px;font-weight:700;color:var(--primary);">${avg.toFixed(1)}</div>
        <div style="font-size:11px;color:var(--text-muted);">Avg Rating</div>
      </div>
      <div style="text-align:center;padding:12px 20px;background:var(--bg-elev);border-radius:var(--radius);">
        <div style="font-size:28px;font-weight:700;color:${nps >= 50 ? 'var(--success)' : nps >= 0 ? 'var(--warning)' : 'var(--danger)'};">${nps >= 0 ? '+' : ''}${nps}</div>
        <div style="font-size:11px;color:var(--text-muted);">NPS Score</div>
      </div>
      <div style="text-align:center;padding:12px 20px;background:var(--bg-elev);border-radius:var(--radius);">
        <div style="font-size:28px;font-weight:700;">${surveyed.length}</div>
        <div style="font-size:11px;color:var(--text-muted);">Responses</div>
      </div>
    </div>
    <div style="display:flex;flex-direction:column;gap:4px;">
      ${dist.reverse().map(({r, n}) => {
        const pct = surveyed.length > 0 ? Math.round(n / surveyed.length * 100) : 0;
        return `<div style="display:flex;align-items:center;gap:8px;font-size:12.5px;">
          <span style="width:18px;text-align:right;">${r}⭐</span>
          <div style="flex:1;background:var(--bg);border-radius:4px;height:14px;overflow:hidden;">
            <div style="height:100%;width:${pct}%;background:var(--primary);border-radius:4px;transition:width .4s;"></div>
          </div>
          <span style="width:36px;color:var(--text-muted);">${pct}%</span>
          <span style="color:var(--text-dim);">(${n})</span>
        </div>`;
      }).join('')}
    </div>`;
}

/* ============================================================
   Round 12 — Feature 4: Break-Even & Overhead Allocation
   ============================================================ */
function computeBreakEven() {
  // `lib/break-even.js`, not the arithmetic that used to be here.
  //
  // THE FIGURE MOVES, UPWARD, AND THAT IS THE POINT. This costed a job by
  // looking up each part's spool and pricing its grams, and SKIPPED any part
  // with no `filamentId` — so an unlinked part cost nothing, the margin came
  // out too high, and the break-even target came out too LOW. A shop was told
  // it needed to bill less than it does, on a figure whose whole job is to be
  // a floor.
  //
  // `partTotalCost` is what the quote and the machine P&L already use: resin,
  // blended multicolour, per-unit cost and quantity, one opinion.
  // BEFORE the book is touched, as this has always done. `null` is this
  // function's way of saying "no fixed costs are set", every caller reads it
  // that way, and reaching past it to filter the whole print log first would
  // be work done to produce an answer that is thrown away.
  const fixed = settings.fixedCosts || [];
  if (fixed.reduce((s, c) => s + (+(c && c.amount) || 0), 0) === 0) return null;

  const cutoff = new Date(); cutoff.setDate(cutoff.getDate() - 90);
  const r = KhaytBreakEven.breakEven({
    fixedCosts: fixed,
    completed: printLog.filter(o => o.status === 'completed' && !o.voidedAt && _countsForBusiness(o)),
    since: localDateStr(cutoff),
    month: localMonthStr(new Date()),
  }, { revenueOf: orderNetRevenueBase, partCostOf: partTotalCost });
  // The callers below have always read `null` as "no fixed costs at all".
  return r.totalFixed === 0 ? null : {
    totalFixed: r.totalFixed,
    breakEvenRevenue: r.breakEvenRevenue,
    avgMarginPct: r.marginPct,
    avgRevPerOrder: r.avgRevenuePerJob,
  };
}

function renderBreakEvenCard() {
  const el = $('#breakEvenSection');
  if (!el) return;
  const fixedCosts = settings.fixedCosts || [];
  const be = computeBreakEven();

  const today = new Date();
  const thisMonthStr = localMonthStr(today);
  const monthRev = printLog
    .filter(o => o.status === 'completed' && !o.voidedAt && _countsForBusiness(o) && (o.date || '').startsWith(thisMonthStr))
    .reduce((s, o) => s + orderNetRevenueBase(o), 0);

  if (fixedCosts.length === 0) {
    el.innerHTML = `<p style="color:var(--text-muted);font-size:13px;">No fixed costs configured. <a href="#" id="goToBreakEvenSettings" style="color:var(--primary);">Add fixed costs in Settings →</a></p>`;
    el.querySelector('#goToBreakEvenSettings')?.addEventListener('click', e => {
      e.preventDefault();
      document.querySelector('[data-tab="settings-tab"]')?.click();
    });
    return;
  }

  const progress = be?.breakEvenRevenue ? Math.min(100, (monthRev / be.breakEvenRevenue) * 100) : 0;
  const surplus  = be?.breakEvenRevenue ? monthRev - be.breakEvenRevenue : null;

  el.innerHTML = `
    <div style="display:flex;gap:16px;flex-wrap:wrap;margin-bottom:16px;">
      <div style="flex:1;min-width:140px;padding:12px 16px;background:var(--bg-elev);border-radius:var(--radius);">
        <div style="font-size:11px;color:var(--text-muted);">Monthly Fixed Costs</div>
        <div style="font-size:18px;font-weight:700;color:var(--danger);">${fmtPrice(be?.totalFixed || 0)}</div>
      </div>
      ${be?.breakEvenRevenue ? `
      <div style="flex:1;min-width:140px;padding:12px 16px;background:var(--bg-elev);border-radius:var(--radius);">
        <div style="font-size:11px;color:var(--text-muted);">Break-Even Revenue</div>
        <div style="font-size:18px;font-weight:700;color:var(--warning);">${fmtPrice(be.breakEvenRevenue)}</div>
      </div>
      <div style="flex:1;min-width:140px;padding:12px 16px;background:var(--bg-elev);border-radius:var(--radius);border-inline-start:3px solid ${surplus >= 0 ? 'var(--success)' : 'var(--danger)'};">
        <div style="font-size:11px;color:var(--text-muted);">${surplus >= 0 ? 'Above Break-Even' : 'Below Break-Even'}</div>
        <div style="font-size:18px;font-weight:700;color:${surplus >= 0 ? 'var(--success)' : 'var(--danger)'};">${surplus >= 0 ? '+' : ''}${fmtPrice(surplus || 0)}</div>
      </div>` : ''}
    </div>
    ${be?.breakEvenRevenue ? `
    <div style="margin-bottom:16px;">
      <div style="display:flex;justify-content:space-between;font-size:12px;color:var(--text-muted);margin-bottom:4px;">
        <span>This month: ${fmtPrice(monthRev)}</span>
        <span>Target: ${fmtPrice(be.breakEvenRevenue)}</span>
      </div>
      <div style="background:var(--bg);border-radius:6px;height:10px;overflow:hidden;">
        <div style="height:100%;width:${progress}%;background:${progress >= 100 ? 'var(--success)' : 'var(--primary)'};border-radius:6px;transition:width .5s;"></div>
      </div>
    </div>` : '<p style="color:var(--text-muted);font-size:12.5px;margin-bottom:12px;">Not enough order history to compute break-even. Add more completed orders.</p>'}
    <table style="width:100%;border-collapse:collapse;font-size:12.5px;">
      <thead><tr style="color:var(--text-dim);">
        <th style="text-align:left;padding:4px 6px;">Fixed Cost</th>
        <th style="text-align:right;padding:4px 6px;">Monthly Amount</th>
        <th style="padding:4px 6px;"></th>
      </tr></thead>
      <tbody>
        ${fixedCosts.map((c, i) => `<tr style="border-top:1px solid var(--border);">
          <td style="padding:6px;">${escapeHtml(c.name)}</td>
          <td style="padding:6px;text-align:right;color:var(--danger);">${fmtPrice(c.amount)}</td>
          <td style="padding:6px;"><button class="btn danger small" data-del-cost="${i}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">✕</button></td>
        </tr>`).join('')}
      </tbody>
    </table>`;

  el.querySelectorAll('[data-del-cost]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const ok = await confirmModal(t('common.delete') + '?', { danger: true });
      if (!ok) return;
      settings.fixedCosts.splice(parseInt(btn.dataset.delCost), 1);
      saveAll();
      renderBreakEvenCard();
    });
  });
}
  const api = {
    renderSimpleReports,
    renderAnalytics,
    exportAnalyticsReport,
    exportPnlCsv,
    openExecutiveSummary,
    openReportBuilder,
    renderClientRetention,
    renderCostTrends,
    renderOperatorAnalytics,
    renderTimeAnalytics,
    renderThroughputHeatmap,
    computeCapacityForecast,
    renderCapacityGauge,
    renderAgedReceivables,
    renderSurveyAnalytics,
    computeBreakEven,
    renderBreakEvenCard,
    renderClientSourceChart,
    renderQuoteFunnelChart,
    renderMonthlyTrendChart,
    renderMachineRevenueChart,
    renderProfitMarginChart,
    renderWasteTrendChart,
    renderCycleTimeChart,
    renderCashFlowChart,
    renderExpenseCategoryChart,
    renderLeadTimeChart,
    renderNpsTrendChart,
    renderClientLtvTable,
    renderMachineDowntimeChart,
    renderMaintenanceCostChart,
    renderMachineAccuracy,
    renderNewVsReturning,
    renderPrinterUtilizationChart,
    renderPnLSection,
    renderProductProfitability,
    renderSLASection,
    renderMachinePL,
    renderLocationPL,
    renderSupplierPriceHistory,
    renderRevenueChart,
  };

  Object.assign(global, api);
  global.KhaytAnalytics = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
