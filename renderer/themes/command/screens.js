/**
 * Command theme — custom screen renderers wired to REAL app data.
 *
 * Mirrors the Workbench hook pattern (window.KhaytWorkbench.renderDashboard):
 * the shared `renderDashboard` delegates here when the Command theme is active,
 * and this module emits the `design/proto-b-cockpit.html` Dashboard markup
 * populated from the same globals the legacy dashboard reads (printLog, machines,
 * machineStatusCache, inventory, settings, quote-followup selector, clients).
 *
 * Visual contract: markup/classes mirror the prototype's Dashboard screen. The
 * matching CSS lives in `renderer/themes/command/screens.css`. All colors come
 * from the `--cmd-*` / `--ink-*` / `--line` / `--accent` tokens in tokens.css so
 * light-default + dark + accent swaps all work without changes here.
 *
 * Clicking a production-board / fleet row opens the shell-level right inspector
 * (window.KhaytCommandShell.openInspector) with real order / machine details.
 */
(function (global) {
  function isOn() {
    return typeof document !== 'undefined'
      && document.body.classList.contains('khayt-command');
  }

  function tr(key, fallback) {
    const s = (typeof t === 'function') ? t(key) : null;
    return (s && s !== key) ? s : fallback;
  }

  function esc(s) {
    return (typeof escapeHtml === 'function') ? escapeHtml(String(s)) : String(s);
  }

  function fmtMoneyVal(n) {
    return (typeof fmtMoney === 'function') ? fmtMoney(n) : String(Math.round(+n || 0));
  }
  function ccy() {
    return (typeof currencySymbol === 'function') ? currencySymbol() : 'SAR';
  }

  function findClient(id) {
    if (!id || typeof clients === 'undefined' || !Array.isArray(clients)) return null;
    return clients.find((c) => c.id === id) || null;
  }
  function clientName(c) {
    if (!c) return '';
    return (typeof localName === 'function') ? localName(c) : (c.name || '');
  }

  // Time-based progress estimate for a printing order (same math as legacy floor).
  function jobProgress(order) {
    if (order.status !== 'printing' || !(+order.printTime > 0)) return null;
    const start = new Date(order.printingStartedAt || order.timerStart || Date.now()).getTime();
    return Math.min(99, Math.max(0, Math.round((Date.now() - start) / (order.printTime * 3600000) * 100)));
  }

  function machineProgress(machine, order) {
    let pct = 0;
    let state = 'idle';
    const cache = (typeof machineStatusCache !== 'undefined') ? machineStatusCache[machine.id] : null;
    // Shared resolver, so this row cannot contradict the attention bar above it.
    // It previously called a printer offline on the first missed poll, which is
    // what put "Offline" on a machine the bar was deliberately staying quiet
    // about — the exact disagreement the bar exists to prevent.
    const shared = (typeof KhaytAttention !== 'undefined')
      ? KhaytAttention.machineState(machine, cache)
      : null;
    if (shared === 'offline' || shared === 'error') {
      state = 'offline';
    } else if (shared === 'reconnecting') {
      // Hold the last good reading rather than blanking the row.
      state = 'reconnecting';
      pct = Math.min(100, Math.max(0, Math.round(+((cache || {}).progress) || 0)));
    } else if (cache && !cache.error) {
      pct = Math.min(100, Math.max(0, Math.round(+cache.progress || 0)));
      const st = (cache.state || '').toLowerCase();
      if (st.includes('print')) state = 'printing';
      else if (pct > 0) state = 'printing';
    } else if (order) {
      const est = jobProgress(order);
      pct = est != null ? est : 0;
      state = 'printing';
    }
    return { pct, state };
  }

  /* ---------- KPI strip cell ---------- */
  function kpi(label, value, delta, deltaCls, tokenColor, valueCls) {
    const d = delta ? `<div class="cmd-kpi-d ${deltaCls}">${esc(delta)}</div>` : '<div class="cmd-kpi-d"></div>';
    return `<div class="cmd-kpi" style="--kc:${tokenColor}">
      <div class="cmd-kpi-l">${esc(label)}</div>
      <div class="cmd-kpi-v${valueCls ? ` ${valueCls}` : ''}">${esc(value)}</div>
      ${d}
    </div>`;
  }

  /* ---------- Panel scaffold ---------- */
  function panel(accentColor, title, more, bodyHtml) {
    const moreHtml = more ? `<span class="cmd-panel-more">${esc(more)}</span>` : '';
    return `<div class="cmd-panel">
      <div class="cmd-panel-hd"><span class="cmd-panel-ac" style="background:${accentColor}"></span>${esc(title)}${moreHtml}</div>
      <div class="cmd-panel-bd">${bodyHtml}</div>
    </div>`;
  }

  // Machines actively printing — single source of truth shared by the dashboard
  // KPI and the status bar (uses machineProgress, so offline/error/100% are
  // handled identically and the two surfaces never diverge).
  function activePrinterCount() {
    const mach = (typeof machines !== 'undefined' && Array.isArray(machines)) ? machines : [];
    const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    const nowPrinting = log.filter((o) => o.status === 'printing');
    // Match a printing order to a machine via order.machineId OR parts[].machineId,
    // the same way the fleet panel and machine inspector resolve the current job.
    const jobFor = (m) => nowPrinting.find((o) => o.machineId === m.id
      || (Array.isArray(o.parts) && o.parts.some((p) => p.machineId === m.id)));
    return mach.filter((m) => machineProgress(m, jobFor(m)).state === 'printing').length;
  }

  /**
   * The shared derivations. Layout stays this theme's business; the answers to
   * "is it late", "is it printing", "does this shop show money" do not — six
   * screens were each working those out, and one of them (Flow) had been getting
   * `late` wrong since it shipped without anything to say so.
   */
  function facts(orders, mach) {
    return global.KhaytDashboardFacts.dashboardFacts({
      orders, machines: mach,
      statusCache: (typeof machineStatusCache !== 'undefined' && machineStatusCache) || {},
      settings: (typeof settings !== 'undefined') ? settings : {},
      now: Date.now(),
      attention: global.KhaytAttention,
      // So an overdue nozzle reaches the attention bar on every theme.
      nozzleWear: global.KhaytNozzleWear,
      tiers: (typeof KhaytTiers !== 'undefined') ? KhaytTiers : undefined,
      money: (typeof payStatus === 'function' && typeof orderOwedBase === 'function')
        ? { payStatus, owedFor: orderOwedBase } : undefined,
    });
  }

  /* =========================================================
     Dashboard
     ========================================================= */
  function renderDashboard(host) {
    if (!host || !isOn()) return false;

    const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    const mach = (typeof machines !== 'undefined' && Array.isArray(machines)) ? machines : [];
    const inv = (typeof inventory !== 'undefined' && Array.isArray(inventory)) ? inventory : [];
    const cfg = (typeof settings !== 'undefined') ? settings : {};
    // Mode separation: enthusiast = no commerce (no revenue/receivables/margin/quotes/clients);
    // margin analytics is Pro-only. Personal stats fill the vacated KPI slots.
    const biz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(cfg.mode) : cfg.mode !== 'enthusiast';
    const pro = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.isProMode(cfg.mode) : (cfg.mode || 'professional') === 'professional';

    const today = new Date(); today.setHours(0, 0, 0, 0);
    const todayStr = (typeof localDateStr === 'function') ? localDateStr(today) : localDateStr(today);
    const yest = new Date(today); yest.setDate(yest.getDate() - 1);
    const yestStr = (typeof localDateStr === 'function') ? localDateStr(yest) : localDateStr(yest);

    /* ---- KPI figures (real) ---- */
    const revBase = (o) => (typeof orderNetRevenueBase === 'function') ? orderNetRevenueBase(o) : (+o.price || 0);
    const owedBase = (o) => (typeof orderOwedBase === 'function') ? orderOwedBase(o) : 0;
    const pay = (o) => (typeof payStatus === 'function') ? payStatus(o) : (o.paid ? 'paid' : 'unpaid');

    const todayRev = log.filter((o) => KhaytOrderStatus.isFinished(o) && o.date === todayStr).reduce((s, o) => s + revBase(o), 0);
    const yestRev = log.filter((o) => KhaytOrderStatus.isFinished(o) && o.date === yestStr).reduce((s, o) => s + revBase(o), 0);
    const revDeltaPct = yestRev > 0 ? Math.round((todayRev - yestRev) / yestRev * 100) : null;
    const revDelta = revDeltaPct != null
      ? `${revDeltaPct >= 0 ? '▲' : '▼'} ${Math.abs(revDeltaPct)}% ${tr('dash.vs_yest', 'vs yest')}` : '';
    const revDeltaCls = revDeltaPct == null ? '' : revDeltaPct >= 0 ? 'up' : 'down';

    const openOrders = log.filter((o) => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote');
    const dueToday = openOrders.filter((o) => o.dueDate === todayStr).length;

    const nowPrinting = log.filter((o) => o.status === 'printing');
    const printers = mach.length;
    const activePrinters = activePrinterCount();
    const utilPct = printers > 0 ? Math.round(activePrinters / printers * 100) : 0;

    const lowStock = (typeof isLowStock === 'function') ? inv.filter(isLowStock) : [];

    const unpaidOrders = log.filter((o) => pay(o) !== 'paid' && pay(o) !== 'voided' && owedBase(o) > 0);
    const unpaidTotal = unpaidOrders.reduce((s, o) => s + owedBase(o), 0);

    // Average margin across completed orders that expose cost (best-effort, real).
    let marginPct = null;
    const withCost = log.filter((o) => KhaytOrderStatus.isFinished(o) && +o.cost > 0 && revBase(o) > 0);
    if (withCost.length) {
      const totRev = withCost.reduce((s, o) => s + revBase(o), 0);
      const totCost = withCost.reduce((s, o) => s + (+o.cost || 0), 0);
      if (totRev > 0) marginPct = Math.round((totRev - totCost) / totRev * 100);
    }

    // Personal stats (enthusiast substitutes for the revenue/unpaid money tiles).
    const doneToday = log.filter((o) => KhaytOrderStatus.isFinished(o) && o.date === todayStr);
    const printHoursToday = doneToday.reduce((s, o) => s + (+o.printTime || 0), 0);

    const revenueTile = biz
      ? kpi(tr('command.kpi.revenue_today', 'Revenue today'), `${fmtMoneyVal(todayRev)} ${ccy()}`, revDelta, revDeltaCls, 'var(--cmd-invoice)')
      : kpi(tr('dash.pstat_prints_today', 'Prints today'), String(doneToday.length), '', '', 'var(--cmd-invoice)');
    const secondMoneyTile = biz
      ? kpi(tr('command.kpi.unpaid', 'Unpaid'), `${fmtMoneyVal(unpaidTotal)} ${ccy()}`,
          unpaidOrders.length > 0 ? tr('dash.wb_invoices', `${unpaidOrders.length} invoices`).replace('{n}', unpaidOrders.length) : '',
          '', 'var(--cmd-danger)')
      : kpi(tr('dash.pstat_print_hours', 'Print hours today'), `${printHoursToday.toFixed(1)}h`, '', '', 'var(--cmd-danger)');
    const marginTile = pro
      ? kpi(tr('command.kpi.avg_margin', 'Avg margin'),
          marginPct != null ? `${marginPct}%` : tr('command.kpi.na', 'n/a'),
          marginPct != null
            ? (withCost.length === 1
                ? tr('command.kpi.from_one_order', '1 order')
                : tr('command.kpi.from_n_orders', `${withCost.length} orders`).replace('{n}', withCost.length))
            : tr('command.kpi.add_costs', 'add order costs'),
          '', 'var(--cmd-analytics)', marginPct != null ? '' : 'muted')
      : '';

    const kpis = [
      revenueTile,
      kpi(tr('command.kpi.open_queue', 'Open queue'), String(openOrders.length),
        dueToday > 0 ? tr('dash.wb_due_today', `${dueToday} due today`).replace('{n}', dueToday) : '',
        dueToday > 0 ? 'down' : '', 'var(--cmd-queue)'),
      kpi(tr('command.kpi.printers_active', 'Printers active'), `${activePrinters} / ${printers}`,
        printers > 0 ? tr('command.kpi.utilization', `${utilPct}% utilization`).replace('{n}', utilPct) : '',
        '', 'var(--cmd-fleet)'),
      kpi(tr('command.kpi.low_stock', 'Low stock'), String(lowStock.length),
        lowStock.length > 0 ? tr('command.kpi.reorder_needed', 'reorder needed') : '',
        lowStock.length > 0 ? 'down' : '', 'var(--cmd-inv)'),
      secondMoneyTile,
      marginTile,
    ].join('');

    /* ---- Production board (real printing orders) ---- */
    const boardRows = nowPrinting.slice(0, 8).map((o) => {
      const pct = jobProgress(o) ?? 0;
      const client = biz ? findClient(o.clientId) : null;
      const title = o.project || tr('inv.walk_in', 'Walk-in');
      const sub = `${o.id}${client ? ' · ' + esc(clientName(client)) : ''}`;
      return `<button type="button" class="cmd-lrow" data-cmd-order="${esc(o.id)}">
        <span class="cmd-dotc" style="background:var(--cmd-queue)"></span>
        <span class="cmd-grow"><span class="cmd-lrow-t">${esc(title)}</span><span class="cmd-sub">${sub}</span></span>
        <span class="cmd-gauge" style="--gc:var(--cmd-queue)"><i style="width:${pct}%"></i></span>
        <span class="cmd-pct">${pct}%</span>
      </button>`;
    }).join('') || `<div class="cmd-empty">${esc(tr('dash.all_clear', 'All clear'))}</div>`;

    /* ---- Fleet (real machines + telemetry) ---- */
    const fleetRows = mach.slice(0, 6).map((m) => {
      const job = nowPrinting.find((o) => o.machineId === m.id
        || (o.parts || []).some((p) => p.machineId === m.id));
      const { pct, state } = machineProgress(m, job);
      const stc = state === 'printing' ? 'var(--cmd-ok)'
        : (state === 'idle' || state === 'reconnecting') ? 'var(--ink-3)'
        : 'var(--cmd-danger)';
      const jobName = job ? (job.project || job.id) : tr('mach.status_idle', 'idle');
      const tail = state === 'printing'
        ? `<span class="cmd-gauge" style="width:70px;--gc:var(--cmd-fleet)"><i style="width:${pct}%"></i></span><span class="cmd-pct">${pct}%</span>`
        : `<span class="cmd-badge cmd-b-gray">${esc(state === 'offline' ? tr('mach.offline', 'offline')
          : state === 'reconnecting' ? tr('mach.reconnecting', 'reconnecting')
          : tr('mach.status_idle', 'idle'))}</span>`;
      return `<button type="button" class="cmd-lrow" data-cmd-machine="${esc(m.id)}">
        <span class="cmd-dotc" style="background:${stc}"></span>
        <span class="cmd-grow"><span class="cmd-lrow-t">${esc(m.name)} <span class="cmd-sub">${esc(jobName)}</span></span></span>
        ${tail}
      </button>`;
    }).join('') || `<div class="cmd-empty">${esc(tr('dash.no_machines', 'No printers yet'))}</div>`;
    const printingCount = nowPrinting.length;

    /* ---- What needs me now ---- */
    // One selector drives both the bar and the Alerts panel, so the two cannot
    // disagree. It also replaces `m.isOffline || cache.error`, which called a
    // printer broken on a single missed poll — the fleet row above already knew
    // better, and the two contradicting each other is what the bar exists to stop.
    const attn = facts(log, mach).attn;

    /* ---- Alerts (real signals) ---- */
    // The panel is the bar's drill-down: its urgent items first, in the same
    // order, then the softer signals the bar deliberately stays quiet about.
    const alerts = attn.items.map((a) => {
      if (a.kind === 'machine') {
        const cache = (typeof machineStatusCache !== 'undefined') ? machineStatusCache[a.id] : null;
        return { cls: 'cmd-b-red', ico: '⚠',
          text: `${esc(a.name)} — ${cache && cache.error ? esc(String(cache.error)) : esc(tr('mach.offline', 'offline'))}`,
          act: tr('command.alert.open', 'Open'), tab: 'queue-tab' };
      }
      return { cls: 'cmd-b-amber', ico: '◷',
        text: `${esc(a.name || a.id)} — ${esc(tr('oe.due_overdue', 'Overdue by {n}d').replace('{n}', a.daysLate))}`,
        act: tr('command.alert.open', 'Open'), tab: 'queue-tab' };
    });
    lowStock.slice(0, 3).forEach((item) => {
      const unit = item.materialType === 'resin' ? 'mL' : 'g';
      const matName = esc(item.material || tr('inv.material', 'Material'));
      const grams = Math.round(+item.weight || 0);
      alerts.push({ cls: 'cmd-b-red', ico: '⚠',
        text: tr('command.alert.low', `${matName} low — ${grams} ${unit} left`)
          .replace('{name}', matName)
          .replace('{n}', grams).replace('{unit}', unit),
        act: tr('command.alert.reorder', 'Reorder'), tab: 'inventory-tab' });
    });
    const followUps = (biz && typeof KhaytQuoteFollowUp !== 'undefined')
      ? KhaytQuoteFollowUp.selectQuotesDueForFollowUp(log, cfg, Date.now()) : [];
    followUps.slice(0, 2).forEach((q) => {
      const qName = esc(q.project || q.id);
      alerts.push({ cls: 'cmd-b-amber', ico: '◷',
        text: tr('command.alert.quote_due', `${qName} quote follow-up due`).replace('{name}', qName),
        act: tr('command.alert.open', 'Open'), tab: 'logs-tab' });
    });
    if (biz) {
      unpaidOrders.filter((o) => KhaytOrderStatus.isFinished(o)).slice(0, Math.max(0, 5 - alerts.length)).forEach((o) => {
        const oid = esc(o.id);
        const amt = `${esc(fmtMoneyVal(owedBase(o)))} ${esc(ccy())}`;
        alerts.push({ cls: 'cmd-b-blue', ico: '❖',
          text: tr('command.alert.unpaid', `${oid} unpaid — ${amt}`)
            .replace('{id}', oid).replace('{amt}', amt),
          act: tr('command.alert.chase', 'Chase'), tab: 'logs-tab' });
      });
    }
    const alertsShown = alerts.slice(0, 6);
    const alertsHidden = alerts.length - alertsShown.length;
    const alertsBody = (alertsShown.map((a) => `<div class="cmd-lrow">
      <span class="cmd-badge ${a.cls}">${a.ico}</span>
      <span class="cmd-grow">${a.text}</span>
      <button type="button" class="cmd-btn-xs" data-act="goto-tab" data-tab="${esc(a.tab)}">${esc(a.act)}</button>
    </div>`).join('') + (alertsHidden > 0
      ? `<div class="cmd-empty">${esc(tr('cl.show_more', 'Show {n} more').replace('{n}', alertsHidden))}</div>`
      : '')) || `<div class="cmd-empty">${esc(tr('dash.all_clear', 'All clear'))}</div>`;

    /* ---- Today's activity (recent completed / picked-up) ---- */
    const recent = log
      .filter((o) => KhaytOrderStatus.isFinished(o) && o.date === todayStr)
      .slice(-4).reverse();
    const activityBody = recent.map((o) => {
      const client = biz ? findClient(o.clientId) : null;
      const subText = biz ? (client ? clientName(client) : o.id) : (o.printTime ? `${(+o.printTime).toFixed(1)}h` : o.id);
      return `<div class="cmd-lrow">
        <span class="cmd-grow"><span class="cmd-lrow-t">${esc(o.project || o.id)}</span><span class="cmd-sub">${esc(subText)}</span></span>
        ${biz ? `<span class="cmd-money">${esc(fmtMoneyVal(revBase(o)))} ${esc(ccy())}</span>` : ''}
      </div>`;
    }).join('') || `<div class="cmd-empty">${esc(tr('command.activity.none', 'No activity yet today'))}</div>`;

    /* ---- Compose ---- */
    const attnBar = (typeof KhaytDashboard !== 'undefined')
      ? KhaytDashboard.buildAttentionBar(attn, mach.length)
      : '';

    host.innerHTML = `<div class="cmd-dash">
      ${attnBar}
      <div class="cmd-kstrip">${kpis}</div>
      <div class="cmd-dgrid">
        <div class="cmd-stack">
          ${panel('var(--cmd-fleet)', tr('dash.wb_fleet', 'Fleet'),
            printingCount ? tr('command.panel.printing', `${printingCount} printing`).replace('{n}', printingCount) : '', fleetRows)}
          ${panel('var(--cmd-queue)', tr('command.panel.board', 'Production board'),
            tr('command.panel.view_queue', 'View queue →'), boardRows)}
        </div>
        <div class="cmd-stack">
          ${panel('var(--cmd-danger)', tr('dash.needs_attention', 'Alerts'), '', alertsBody)}
          ${panel('var(--cmd-invoice)', tr('command.panel.activity', "Today's activity"), '', activityBody)}
        </div>
      </div>
    </div>`;

    // Wire navigation actions.
    host.querySelectorAll('[data-act="goto-tab"]').forEach((btn) => {
      btn.addEventListener('click', () => {
        if (typeof switchTab === 'function') switchTab(btn.dataset.tab);
      });
    });
    // Wire inspector open on production-board rows.
    host.querySelectorAll('[data-cmd-order]').forEach((row) => {
      row.addEventListener('click', () => openOrderInspector(row.dataset.cmdOrder));
    });
    host.querySelectorAll('[data-cmd-machine]').forEach((row) => {
      row.addEventListener('click', () => openMachineInspector(row.dataset.cmdMachine));
    });

    if (typeof i18n !== 'undefined' && i18n.apply) i18n.apply(host);
    // Keep the bottom status bar in sync with the freshly-rendered dashboard
    // (it otherwise only refreshes on tab switch).
    if (global.KhaytCommandShell && typeof global.KhaytCommandShell.syncStatusBar === 'function') {
      global.KhaytCommandShell.syncStatusBar();
    }
    return true;
  }

  /* ---------- Inspector content builders (real data) ---------- */
  function openOrderInspector(orderId) {
    const shell = global.KhaytCommandShell;
    if (!shell || typeof shell.openInspector !== 'function') return;
    const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    const o = log.find((x) => x.id === orderId);
    if (!o) return;
    const cfg = (typeof settings !== 'undefined') ? settings : {};
    const biz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(cfg.mode) : cfg.mode !== 'enthusiast';
    const client = biz ? findClient(o.clientId) : null;
    const pct = jobProgress(o) ?? 0;
    const revBase = (typeof orderNetRevenueBase === 'function') ? orderNetRevenueBase(o) : (+o.price || 0);
    const kv = (k, v, mono) => `<div class="cmd-kv"><span class="k">${esc(k)}</span><span class="v${mono ? ' mono' : ''}">${esc(v)}</span></div>`;
    const body = `
      <div class="cmd-insp-sec">${esc(tr('command.insp.progress', 'Progress'))}</div>
      <div class="cmd-insp-prog"><span class="cmd-gauge" style="--gc:var(--cmd-queue)"><i style="width:${pct}%"></i></span><span class="cmd-pct">${pct}%</span></div>
      <div class="cmd-insp-sec">${esc(tr('command.insp.details', 'Details'))}</div>
      ${kv(tr('command.insp.order', 'Order'), o.id, true)}
      ${client ? kv(tr('command.insp.client', 'Client'), clientName(client)) : ''}
      ${o.dueDate ? kv(tr('command.insp.due', 'Due'), o.dueDate, true) : ''}
      ${o.machineId ? kv(tr('command.insp.printer', 'Printer'), (typeof machines !== 'undefined' && machines.find((m) => m.id === o.machineId)?.name) || o.machineId) : ''}
      ${biz ? `<div class="cmd-insp-sec">${esc(tr('command.insp.pricing', 'Pricing'))}</div>
      ${kv(tr('command.insp.total', 'Total'), `${fmtMoneyVal(revBase)} ${ccy()}`, true)}` : ''}`;
    const title = `${esc(o.project || tr('inv.walk_in', 'Walk-in'))}<span class="cmd-insp-sub">${esc(o.id)}${client ? ' · ' + esc(clientName(client)) : ''}</span>`;
    shell.openInspector(body, title);
  }

  function openMachineInspector(machineId) {
    const shell = global.KhaytCommandShell;
    if (!shell || typeof shell.openInspector !== 'function') return;
    const mach = (typeof machines !== 'undefined' && Array.isArray(machines)) ? machines : [];
    const m = mach.find((x) => x.id === machineId);
    if (!m) return;
    const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    const job = log.find((o) => o.status === 'printing' && (o.machineId === m.id || (Array.isArray(o.parts) && o.parts.some((p) => p.machineId === m.id))));
    const { pct, state } = machineProgress(m, job);
    const kv = (k, v, mono) => `<div class="cmd-kv"><span class="k">${esc(k)}</span><span class="v${mono ? ' mono' : ''}">${esc(v)}</span></div>`;
    const body = `
      <div class="cmd-insp-sec">${esc(tr('command.insp.status', 'Status'))}</div>
      ${kv(tr('command.insp.state', 'State'), state === 'printing' ? tr('mach.printing', 'printing')
        : state === 'offline' ? tr('mach.offline', 'offline')
        : state === 'reconnecting' ? tr('mach.reconnecting', 'reconnecting')
        : tr('mach.status_idle', 'idle'))}
      <div class="cmd-insp-prog"><span class="cmd-gauge" style="--gc:var(--cmd-fleet)"><i style="width:${pct}%"></i></span><span class="cmd-pct">${pct}%</span></div>
      <div class="cmd-insp-sec">${esc(tr('command.insp.current_job', 'Current job'))}</div>
      ${kv(tr('command.insp.job', 'Job'), job ? (job.project || job.id) : '—')}
      ${m.model ? kv(tr('command.insp.model', 'Model'), m.model) : ''}`;
    const title = `${esc(m.name)}<span class="cmd-insp-sub">${esc(m.model || tr('dash.wb_fleet', 'Fleet'))}</span>`;
    shell.openInspector(body, title);
  }

  global.KhaytCommand = {
    isOn,
    renderDashboard,
    activePrinterCount,
  };
})(typeof window !== 'undefined' ? window : globalThis);
