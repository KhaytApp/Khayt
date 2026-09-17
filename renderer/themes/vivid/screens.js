/**
 * Vivid theme — custom screen renderers wired to REAL app data.
 *
 * Mirrors the Workbench hook pattern (window.KhaytWorkbench.renderDashboard):
 * the shared `renderDashboard` delegates here when the Vivid theme is active,
 * and this module emits the `design/proto-c-vivid.html` Dashboard markup
 * populated from the same globals the legacy dashboard reads (printLog,
 * machines, machineStatusCache, inventory, settings, quote-followup selector).
 *
 * Visual contract: markup/classes mirror the prototype's Dashboard screen
 * (gradient stat tiles, CSS bar chart, SVG donut, today's-work list, fleet
 * rings). The matching CSS lives in `renderer/themes/vivid/screens.css`. All
 * colors come from the `--vv-*` / `--ink-*` / `--line` / `--hue` tokens in
 * tokens.css so light-default + dark + per-module hue all work without changes.
 */
(function (global) {
  function isOn() {
    return typeof document !== 'undefined'
      && document.body.classList.contains('khayt-vivid');
  }

  // Translate with graceful English fallback (follows language switches).
  function tr(key, fallback) {
    const s = (typeof t === 'function') ? t(key) : null;
    return (s && s !== key) ? s : fallback;
  }

  // Inline SVG glyphs (stroked, 24-grid) — same set the Workbench hook uses.
  const ICON = {
    money: '<path d="M3 6h18v12H3z"/><path d="M3 10h18M7 14h4"/>',
    printer: '<rect x="6" y="3" width="12" height="6" rx="1"/><path d="M6 14H4a2 2 0 0 1-2-2v-1a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v1a2 2 0 0 1-2 2h-2"/><rect x="6" y="13" width="12" height="8" rx="1"/>',
    inv: '<path d="M3 7l9-4 9 4v10l-9 4-9-4z"/><path d="M3 7l9 4 9-4M12 11v10"/>',
    queue: '<rect x="3" y="4" width="7" height="7" rx="1.5"/><rect x="14" y="4" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="6" rx="1.5"/><rect x="14" y="14" width="7" height="6" rx="1.5"/>',
    warn: '<path d="M12 3l9 16H3z"/><path d="M12 10v4M12 17h.01"/>',
  };
  function svg(path, w = 18) {
    return `<svg viewBox="0 0 24 24" width="${w}" height="${w}" fill="none" stroke="currentColor"`
      + ` stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${path}</svg>`;
  }

  const CHIP = {
    blue: { fg: 'var(--vv-blue)', bg: 'var(--vv-blue-bg)' },
    green: { fg: 'var(--vv-green)', bg: 'var(--vv-green-bg)' },
    red: { fg: 'var(--vv-red)', bg: 'var(--vv-red-bg)' },
    amber: { fg: 'var(--vv-amber)', bg: 'var(--vv-amber-bg)' },
    violet: { fg: 'var(--vv-violet)', bg: 'var(--vv-violet-bg)' },
    teal: { fg: 'var(--vv-teal)', bg: 'var(--vv-teal-bg)' },
    cyan: { fg: 'var(--vv-cyan)', bg: 'var(--vv-cyan-bg)' },
    gray: { fg: 'var(--ink-2)', bg: 'rgba(120,130,150,.14)' },
  };

  // Top-level `let clients` lives in the shared global lexical scope, not on
  // window — reach it via the bare identifier (guarded for safety).
  function findClient(id) {
    if (!id || typeof clients === 'undefined' || !Array.isArray(clients)) return null;
    return clients.find((c) => c.id === id) || null;
  }

  function fmtMoneyVal(n) {
    return (typeof fmtMoney === 'function') ? fmtMoney(n) : String(Math.round(+n || 0));
  }
  function ccy() {
    return (typeof currencySymbol === 'function') ? currencySymbol() : 'SAR';
  }

  // Bucket a queue status into one of the prototype's chip colors.
  function statusChipClass(status) {
    switch (status) {
      case 'printing': return 'blue';
      case 'completed': return 'green';
      case 'qc': return 'amber';
      case 'post': return 'violet';
      case 'on_hold': return 'gray';
      case 'pending': return 'cyan';
      case 'quote': return 'teal';
      default: return 'gray';
    }
  }

  /* ---------- Gradient KPI tile ---------- */
  function tile(gradCls, iconPath, label, value, unit, delta) {
    const unitHtml = unit ? `<span class="vv-tile-u">${escapeHtml(unit)}</span>` : '';
    const deltaHtml = delta ? `<div class="vv-tile-d">${escapeHtml(delta)}</div>` : '<div class="vv-tile-d">&nbsp;</div>';
    return `<div class="vv-tile ${gradCls}">
      <div class="vv-tile-ic">${svg(iconPath, 18)}</div>
      <div class="vv-tile-l">${escapeHtml(label)}</div>
      <div class="vv-tile-v">${escapeHtml(value)}${unitHtml}</div>
      ${deltaHtml}
    </div>`;
  }

  /* ---------- Today's work list row ---------- */
  function jobRow(order) {
    const title = order.project || tr('inv.walk_in', 'Walk-in');
    const cls = statusChipClass(order.status);
    const label = tr('queue.' + order.status, order.status);
    // Enthusiast (hobbyist) mode has no clients — show project/id only.
    const showBiz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(typeof settings !== 'undefined' ? settings.mode : undefined) : (typeof settings === 'undefined' || settings.mode !== 'enthusiast');
    const client = showBiz ? findClient(order.clientId) : null;
    const parts = [];
    if (client) parts.push(localName(client));
    if (order.dueDate) {
      const today = new Date(); today.setHours(0, 0, 0, 0);
      const due = new Date(order.dueDate + 'T00:00:00');
      const diff = Math.round((due - today) / 86400000);
      if (diff < 0) parts.push(tr('oe.due_overdue', 'Overdue by {n}d').replace('{n}', Math.abs(diff)));
      else if (diff === 0) parts.push(tr('dash.due_today_sub', 'due today'));
      else if (diff === 1) parts.push(tr('dash.due_tomorrow_sub', 'due tomorrow'));
      else parts.push(tr('oe.due_in', 'Due in {n}d').replace('{n}', diff));
    }
    if (!parts.length) parts.push(order.id);
    const sub = parts.join(' · ');
    const due = order.dueDate || '';
    const c = CHIP[cls];
    return `<div class="vv-workrow">
      <span class="vv-badge-stat" style="color:${c.fg};background:${c.bg}">${escapeHtml(label)}</span>
      <div class="vv-grow"><div class="vv-nm">${escapeHtml(title)}</div><div class="vv-meta">${escapeHtml(order.id)} · ${escapeHtml(sub)}</div></div>
      <span class="vv-due">${escapeHtml(due)}</span>
    </div>`;
  }

  // Time-based progress estimate for a printing order (same math as the floor).
  function jobProgress(order) {
    if (order.status !== 'printing' || !(+order.printTime > 0)) return null;
    const start = new Date(order.printingStartedAt || order.timerStart || Date.now()).getTime();
    return Math.min(99, Math.max(0, Math.round((Date.now() - start) / (order.printTime * 3600000) * 100)));
  }

  /* ---------- Progress ring (SVG) ---------- */
  function ring(pct, color) {
    const r = 15.9155;
    const dash = Math.max(0, Math.min(100, pct));
    const gap = 100 - dash;
    return `<svg viewBox="0 0 36 36" style="width:100%;height:100%">
      <circle cx="18" cy="18" r="${r}" fill="none" stroke="var(--chip-bg, var(--surface-3))" stroke-width="3.4"/>
      <circle cx="18" cy="18" r="${r}" fill="none" stroke="${color}" stroke-width="3.4" stroke-linecap="round"
        stroke-dasharray="${dash} ${gap}" stroke-dashoffset="25" transform="rotate(-90 18 18)"/></svg>`;
  }

  /* ---------- Fleet · live mini row (with ring) ---------- */
  function fleetRow(machine, order) {
    let pct = 0;
    let state = 'idle';
    const cache = (typeof machineStatusCache !== 'undefined') ? machineStatusCache[machine.id] : null;
    // Shared resolver — see the note in command/screens.js. A single missed poll
    // used to paint this row red while the attention bar stayed silent.
    const shared = (typeof KhaytAttention !== 'undefined')
      ? KhaytAttention.machineState(machine, cache)
      : null;
    if (shared === 'offline' || shared === 'error') {
      state = 'error';
    } else if (shared === 'reconnecting') {
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
    const jobName = order ? (order.project || order.id) : machine.materialType || tr('mach.status_idle', 'idle');
    let color = 'var(--vv-blue)';
    if (state === 'error') color = 'var(--vv-red)';
    else if (state === 'idle' || state === 'reconnecting') color = 'var(--ink-3)';
    const tail = state === 'idle'
      ? tr('mach.status_idle', 'idle')
      : state === 'error'
        ? tr('mach.offline', 'offline')
        : state === 'reconnecting'
          ? tr('mach.reconnecting', 'reconnecting')
          : tr('queue.printing', 'printing');
    const pctLbl = state === 'idle' ? '–' : `${pct}%`;
    /* reconnecting keeps its last known percentage rather than blanking */
    return `<div class="vv-fleetrow">
      <div class="vv-ring">${ring(state === 'idle' ? 3 : pct, color)}<div class="vv-ring-pct">${escapeHtml(pctLbl)}</div></div>
      <div class="vv-grow"><div class="vv-nm">${escapeHtml(machine.name)}</div><div class="vv-meta">${escapeHtml(jobName)}</div></div>
      <div class="vv-fleet-tail"><div class="vv-fleet-state" style="color:${color}"><span class="vv-statusdot" style="background:${color}"></span>${escapeHtml(tail)}</div></div>
    </div>`;
  }

  /* ---------- Needs-attention row ---------- */
  function attnRow(item) {
    return `<div class="vv-workrow">
      <span class="vv-attn-ico" style="background:${item.bg};color:${item.fg}">${svg(item.icon, 16)}</span>
      <div class="vv-grow"><div class="vv-nm">${escapeHtml(item.title)}</div><div class="vv-meta">${escapeHtml(item.sub)}</div></div>
      <span class="vv-badge-stat" style="color:${CHIP[item.chip].fg};background:${CHIP[item.chip].bg}">${escapeHtml(item.chipLabel)}</span>
    </div>`;
  }

  /* ---------- CSS bar chart (revenue, last 7 days) ---------- */
  function barChart(data) {
    const max = Math.max(1, ...data.map((d) => d.v));
    return data.map((d) => {
      const h = Math.round(d.v / max * 100);
      const amt = d.v >= 1000 ? `${(d.v / 1000).toFixed(1)}k` : String(Math.round(d.v));
      return `<div class="vv-bar"><div class="vv-bar-amt">${escapeHtml(amt)}</div>`
        + `<div class="vv-bar-col" style="height:${h}%"></div>`
        + `<div class="vv-bar-cap">${escapeHtml(d.cap)}</div></div>`;
    }).join('');
  }

  /* ---------- SVG donut (orders by status) ---------- */
  function donut(segs, total) {
    let off = 25;
    let arcs = '';
    segs.forEach((s) => {
      const pct = total > 0 ? (s.v / total * 100) : 0;
      arcs += `<circle cx="21" cy="21" r="15.9155" fill="transparent" stroke="${s.color}" stroke-width="6"`
        + ` stroke-dasharray="${pct.toFixed(2)} ${(100 - pct).toFixed(2)}" stroke-dashoffset="${off.toFixed(2)}"/>`;
      off -= pct;
    });
    arcs += `<text x="21" y="20" text-anchor="middle" font-size="6.5" font-weight="800" fill="currentColor">${total}</text>`
      + `<text x="21" y="26" text-anchor="middle" font-size="3" fill="var(--ink-3)">${escapeHtml(tr('dash.vv_orders', 'orders'))}</text>`;
    const legend = segs.map((s) =>
      `<div class="vv-leg-row"><span class="vv-leg-sw" style="background:${s.color}"></span>${escapeHtml(s.label)}<b>${s.v}</b></div>`).join('');
    return { arcs, legend };
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
    // Mode separation: enthusiast = no commerce — substitute revenue KPI + revenue
    // chart with personal print stats so the dashboard stays visually complete.
    const biz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(cfg.mode) : cfg.mode !== 'enthusiast';

    const today = new Date(); today.setHours(0, 0, 0, 0);
    const todayStr = (typeof localDateStr === 'function') ? localDateStr(today) : localDateStr(today);

    /* ---- KPI figures (real) — Revenue (month), Active orders, Fleet util, Filament ---- */
    const thisMonthStr = (typeof localMonthStr === 'function') ? localMonthStr(today) : todayStr.slice(0, 7);
    const monthDone = log.filter((o) => KhaytOrderStatus.isFinished(o) && (o.date || '').startsWith(thisMonthStr));
    const monthRev = monthDone.reduce((s, o) => s + orderNetRevenueBase(o), 0);
    const printsMonth = monthDone.length;
    // Previous month delta.
    const prevMonth = new Date(today); prevMonth.setMonth(prevMonth.getMonth() - 1);
    const prevMonthStr = (typeof localMonthStr === 'function') ? localMonthStr(prevMonth) : '';
    const prevRev = prevMonthStr
      ? log.filter((o) => KhaytOrderStatus.isFinished(o) && (o.date || '').startsWith(prevMonthStr))
        .reduce((s, o) => s + orderNetRevenueBase(o), 0)
      : 0;
    const revDeltaPct = prevRev > 0 ? Math.round((monthRev - prevRev) / prevRev * 100) : null;
    const revDelta = revDeltaPct != null
      ? `${revDeltaPct >= 0 ? '▲' : '▼'} ${Math.abs(revDeltaPct)}% ${tr('dash.vs_prev_month', 'vs last month')}`
      : '';

    const openOrders = log.filter((o) => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote');
    const nowPrinting = log.filter((o) => o.status === 'printing');
    const queued = openOrders.filter((o) => o.status === 'pending').length;
    const activeDelta = tr('dash.vv_active_sub', `${queued} in queue · ${nowPrinting.length} printing`)
      .replace('{q}', queued).replace('{p}', nowPrinting.length);

    const totalMach = mach.length;
    const busyMach = mach.filter((m) => {
      if (m.isOffline) return false;
      const cache = (typeof machineStatusCache !== 'undefined') ? machineStatusCache[m.id] : null;
      if (cache && !cache.error && (cache.state || '').toLowerCase().includes('print')) return true;
      return nowPrinting.some((o) => o.machineId === m.id || (o.parts || []).some((p) => p.machineId === m.id));
    }).length;
    const utilPct = totalMach > 0 ? Math.round(busyMach / totalMach * 100) : 0;
    const utilSub = totalMach > 0
      ? tr('dash.vv_fleet_sub', `${busyMach} of ${totalMach} printing`).replace('{b}', busyMach).replace('{t}', totalMach)
      : tr('dash.no_machines', 'No printers yet');

    // Filament used today (g) — usageHistory aggregation, same as legacy dashboard.
    const gToday = inv.reduce((s, item) => s
      + (item.usageHistory || [])
        .filter((h) => h.date === todayStr)
        .reduce((a, h) => a + (+h.weightUsed || 0), 0), 0);
    const kgToday = (gToday / 1000);
    const filamentVal = kgToday >= 1 ? kgToday.toFixed(1) : String(Math.round(gToday));
    const filamentUnit = kgToday >= 1 ? ' kg' : ' g';
    const totalRemainingG = inv.reduce((s, item) => s + (+item.weight || 0), 0);
    const filamentSub = totalRemainingG > 0
      ? tr('dash.vv_remaining', `${(totalRemainingG / 1000).toFixed(1)} kg in stock`).replace('{n}', (totalRemainingG / 1000).toFixed(1))
      : '';

    const tiles = [
      biz
        ? tile('vv-t-indigo', ICON.money, tr('dash.vv_revenue_month', 'Revenue (month)'), fmtMoneyVal(monthRev), ` ${ccy()}`, revDelta)
        : tile('vv-t-indigo', ICON.printer, tr('dash.pstat_prints_month', 'Prints this month'), String(printsMonth), '', ''),
      tile('vv-t-blue', ICON.queue, tr('dash.vv_active_orders', 'Active orders'), String(openOrders.length), '', activeDelta),
      tile('vv-t-teal', ICON.printer, tr('dash.vv_fleet_util', 'Fleet utilisation'), String(utilPct), '%', utilSub),
      tile('vv-t-violet', ICON.inv, tr('dash.vv_filament_used', 'Filament used'), filamentVal, filamentUnit, filamentSub),
    ].join('');

    /* ---- 7-day bars: revenue (business) or prints/day (enthusiast) ---- */
    const barData = [];
    for (let i = 6; i >= 0; i -= 1) {
      const d = new Date(today); d.setDate(d.getDate() - i);
      const ds = (typeof localDateStr === 'function') ? localDateStr(d) : localDateStr(d);
      const doneThatDay = log.filter((o) => KhaytOrderStatus.isFinished(o) && o.date === ds);
      const v = biz ? doneThatDay.reduce((s, o) => s + orderNetRevenueBase(o), 0) : doneThatDay.length;
      const cap = d.toLocaleDateString(localeTag(), { weekday: 'short' });
      barData.push({ cap, v });
    }

    /* ---- Orders-by-status donut (real) ---- */
    const statusCounts = [
      { key: 'printing', label: tr('queue.printing', 'Printing'), color: 'var(--vv-blue)' },
      { key: 'pending', label: tr('queue.pending', 'Queue'), color: 'var(--vv-cyan)' },
      { key: 'post', label: tr('queue.post', 'Post'), color: 'var(--vv-violet)' },
      { key: 'qc', label: tr('queue.qc', 'QC'), color: 'var(--vv-amber)' },
      { key: 'completed', label: tr('queue.completed', 'Done'), color: 'var(--vv-green)' },
    ].map((s) => ({
      ...s,
      // The "Done" segment counts both spellings of finished: the donut has no
      // delivered bucket, so a delivered job used to appear in no segment at all.
      v: log.filter((o) => (s.key === 'completed'
        ? KhaytOrderStatus.isFinished(o) && (o.date || '').startsWith(thisMonthStr)
        : o.status === s.key)).length,
    })).filter((s) => s.v > 0);
    const donutTotal = statusCounts.reduce((a, s) => a + s.v, 0);
    const dn = donut(statusCounts, donutTotal);

    /* ---- Today's work (real active orders) ---- */
    const ACTIVE_ORDER = ['printing', 'pending', 'post', 'qc', 'on_hold'];
    const todaysWork = openOrders
      .filter((o) => ACTIVE_ORDER.includes(o.status))
      .sort((a, b) => {
        const ap = a.status === 'printing' ? 0 : 1;
        const bp = b.status === 'printing' ? 0 : 1;
        if (ap !== bp) return ap - bp;
        return (a.dueDate || '~').localeCompare(b.dueDate || '~');
      })
      .slice(0, 6);
    const workBody = todaysWork.length
      ? todaysWork.map(jobRow).join('')
      : `<div class="vv-empty">${escapeHtml(tr('dash.all_clear', 'All clear'))}</div>`;

    /* ---- Fleet · right now (real machines + telemetry) ---- */
    const fleetRows = mach.slice(0, 4).map((m) => {
      const job = nowPrinting.find((o) => o.machineId === m.id
        || (o.parts || []).some((p) => p.machineId === m.id));
      return fleetRow(m, job);
    }).join('');

    /* ---- What needs me now ---- */
    // One selector drives both the bar and the panel below, so the two cannot
    // show different counts. It also replaces `m.isOffline || cache.error`,
    // which called a printer broken on a single missed poll while fleetRow()
    // in this same file correctly showed it reconnecting.
    const attn = facts(log, mach).attn;

    /* ---- Needs attention (real signals) ---- */
    // The panel is the bar's drill-down: urgent items first and in the same
    // order, then the softer signals the bar stays quiet about.
    const attention = attn.items.map((a) => {
      if (a.kind === 'machine') {
        const cache = (typeof machineStatusCache !== 'undefined') ? machineStatusCache[a.id] : null;
        return {
          icon: ICON.warn, fg: 'var(--vv-red)', bg: 'var(--vv-red-bg)',
          title: tr('dash.vv_printer_issue', `${a.name} — needs attention`).replace('{name}', a.name),
          sub: cache && cache.error ? String(cache.error) : tr('mach.offline', 'Offline'),
          chip: 'red', chipLabel: tr('dash.vv_error', 'Error'),
        };
      }
      return {
        icon: ICON.warn, fg: 'var(--vv-amber)', bg: 'var(--vv-amber-bg)',
        title: a.name || a.id,
        sub: tr('oe.due_overdue', 'Overdue by {n}d').replace('{n}', a.daysLate),
        chip: 'amber', chipLabel: tr('dash.vv_due', 'Due'),
      };
    });
    if (typeof isLowStock === 'function') {
      inv.filter(isLowStock).slice(0, 3).forEach((item) => {
        const unit = item.materialType === 'resin' ? 'mL' : 'g';
        attention.push({
          icon: ICON.inv, fg: 'var(--vv-amber)', bg: 'var(--vv-amber-bg)',
          title: `${item.material || tr('inv.material', 'Material')}`,
          sub: `${Math.round(+item.weight || 0)} ${unit} · ${tr('dash.vv_reorder_point', 'reorder point')}`,
          chip: 'amber', chipLabel: tr('dash.vv_low', 'Low'),
        });
      });
    }
    const followUps = (biz && typeof KhaytQuoteFollowUp !== 'undefined' && typeof cfg === 'object')
      ? KhaytQuoteFollowUp.selectQuotesDueForFollowUp(log, cfg, Date.now())
      : [];
    followUps.slice(0, 2).forEach((q) => {
      const client = findClient(q.clientId);
      const bits = [`${fmtMoneyVal(q.price)} ${ccy()}`];
      if (client) bits.push(localName(client));
      attention.push({
        icon: ICON.money, fg: 'var(--vv-blue)', bg: 'var(--vv-blue-bg)',
        title: q.project || tr('dash.vv_quote', 'Quote') + ' ' + q.id,
        sub: bits.join(' · '),
        chip: 'blue', chipLabel: tr('dash.vv_due', 'Due'),
      });
    });
    const attnTrimmed = attention.slice(0, 5);
    // Say what the cap hid — urgent items lead this list now, so a silent
    // truncation would let the bar's count outrun what the panel shows.
    const attnHidden = attention.length - attnTrimmed.length;
    const attnBody = attnTrimmed.length
      ? attnTrimmed.map(attnRow).join('') + (attnHidden > 0
        ? `<div class="vv-empty">${escapeHtml(tr('cl.show_more', 'Show {n} more').replace('{n}', attnHidden))}</div>`
        : '')
      : `<div class="vv-empty">${escapeHtml(tr('dash.all_clear', 'All clear'))}</div>`;

    /* ---- Compose ---- */
    const attnBar = (typeof KhaytDashboard !== 'undefined')
      ? KhaytDashboard.buildAttentionBar(attn, mach.length)
      : '';

    host.innerHTML = `<div class="vv-dash">
      ${attnBar}
      <div class="vv-tiles">${tiles}</div>

      <div class="vv-card">
        <h3>${escapeHtml(tr('dash.vv_fleet_now', 'Fleet right now'))}</h3>
        <div class="vv-fleetmini">${fleetRows || `<div class="vv-empty">${escapeHtml(tr('dash.no_machines', 'No printers yet'))}</div>`}</div>
      </div>

      <div class="vv-grid2">
        <div class="vv-card">
          <h3>${escapeHtml(biz ? tr('dash.vv_revenue_7d', 'Revenue — last 7 days') : tr('dash.pstat_prints_7d', 'Prints — last 7 days'))}</h3>
          <div class="vv-bars">${barChart(barData)}</div>
        </div>
        <div class="vv-card">
          <h3>${escapeHtml(tr('dash.vv_orders_by_status', 'Orders by status'))}</h3>
          ${donutTotal > 0 ? `<div class="vv-donut-wrap">
            <svg class="vv-donut" viewBox="0 0 42 42">${dn.arcs}</svg>
            <div class="vv-legend">${dn.legend}</div>
          </div>` : `<div class="vv-empty">${escapeHtml(tr('dash.all_clear', 'All clear'))}</div>`}
        </div>
      </div>

      <div class="vv-card">
        <h3>${escapeHtml(tr('dash.wb_todays_work', "Today's work"))}</h3>
        <div class="vv-worklist">${workBody}</div>
      </div>

      <div class="vv-card vv-attn">
        <h3>${escapeHtml(tr('dash.needs_attention', 'Needs attention'))}</h3>
        <div class="vv-worklist">${attnBody}</div>
      </div>
    </div>`;

    if (typeof i18n !== 'undefined' && i18n.apply) i18n.apply(host);
    // Keep the bottom status bar current with the freshly-rendered dashboard
    // (it otherwise only refreshes on tab switch).
    if (global.KhaytVividShell && typeof global.KhaytVividShell.syncStatusBar === 'function') {
      global.KhaytVividShell.syncStatusBar();
    }
    return true;
  }

  global.KhaytVivid = {
    isOn,
    renderDashboard,
  };
})(typeof window !== 'undefined' ? window : globalThis);
