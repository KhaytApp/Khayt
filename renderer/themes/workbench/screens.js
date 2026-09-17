/**
 * Workbench theme — custom screen renderers wired to REAL app data.
 *
 * Mirrors the theme screen-hook pattern (window.KhaytWorkbench.renderDashboard):
 * the shared `render*` functions delegate here when the Workbench theme is active,
 * and this module emits the `design/proto-a-workbench.html` markup populated from
 * the same globals the legacy dashboard reads (printLog, machines,
 * machineStatusCache, inventory, settings, quote-followup selector, etc.).
 *
 * Visual contract: markup/classes mirror the prototype's Dashboard screen. The
 * matching CSS lives in `renderer/themes/workbench/screens.css`. All colors come
 * from the `--wb-*` / `--ink-*` / `--line` / `--accent` tokens in tokens.css so
 * light-default + dark + accent swaps all work without changes here.
 */
(function (global) {
  /**
   * How many polls in a row a printer must miss before the fleet panel calls it
   * offline. The poller runs every 30s, so 2 gives a machine up to a minute to
   * come back — comfortably longer than a CORE One's 20-30s reconnect — before
   * it turns red. Below this it shows the last known reading as "reconnecting".
   */
  const OFFLINE_AFTER_MISSED_POLLS = 2;

  function isOn() {
    return typeof document !== 'undefined'
      && document.body.classList.contains('khayt-workbench');
  }

  // Translate with graceful English fallback (follows language switches).
  function tr(key, fallback) {
    const s = (typeof t === 'function') ? t(key) : null;
    return (s && s !== key) ? s : fallback;
  }

  // Inline SVG glyphs lifted from the prototype (stroked, 24-grid).
  const ICON = {
    money: '<path d="M3 6h18v12H3z"/><path d="M3 10h18M7 14h4"/>',
    printer: '<rect x="6" y="3" width="12" height="6" rx="1"/><path d="M6 14H4a2 2 0 0 1-2-2v-1a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v1a2 2 0 0 1-2 2h-2"/><rect x="6" y="13" width="12" height="8" rx="1"/>',
    inv: '<path d="M3 7l9-4 9 4v10l-9 4-9-4z"/><path d="M3 7l9 4 9-4M12 11v10"/>',
    queue: '<rect x="3" y="4" width="7" height="7" rx="1.5"/><rect x="14" y="4" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="6" rx="1.5"/><rect x="14" y="14" width="7" height="6" rx="1.5"/>',
    warn: '<path d="M12 3l9 16H3z"/><path d="M12 10v4M12 17h.01"/>',
    calc: '<rect x="4" y="2" width="16" height="20" rx="2"/><path d="M8 6h8M8 10h2M8 14h2M8 18h2M14 10h2v8h-2z"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
  };
  function svg(path, w = 14) {
    return `<svg viewBox="0 0 24 24" width="${w}" height="${w}" fill="none" stroke="currentColor"`
      + ` stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${path}</svg>`;
  }

  // Map a token name (e.g. var(--wb-blue)) to its companion soft-bg token for tinting.
  const CHIP = {
    blue: { fg: 'var(--wb-blue)', bg: 'var(--wb-blue-bg)' },
    green: { fg: 'var(--wb-green)', bg: 'var(--wb-green-bg)' },
    red: { fg: 'var(--wb-red)', bg: 'var(--wb-red-bg)' },
    amber: { fg: 'var(--wb-amber)', bg: 'var(--wb-amber-bg)' },
    purple: { fg: 'var(--wb-purple)', bg: 'var(--wb-purple-bg)' },
    teal: { fg: 'var(--wb-teal)', bg: 'var(--wb-teal-bg)' },
    gray: { fg: 'var(--ink-2)', bg: 'rgba(120,130,150,.14)' },
  };

  function chip(cls, label) {
    const c = CHIP[cls] || CHIP.gray;
    return `<span class="wb-chip" style="color:${c.fg};background:${c.bg}">`
      + `<span class="wb-cd" style="background:${c.fg}"></span>${escapeHtml(label)}</span>`;
  }

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
      case 'qc': return 'green';
      case 'post': return 'purple';
      case 'on_hold': return 'gray';
      case 'pending': return 'amber';
      case 'quote': return 'teal';
      default: return 'gray';
    }
  }

  /* ---------- KPI stat tile ---------- */
  /* ---------- "Today's work" list row ---------- */
  function jobRow(order) {
    const title = order.project || tr('inv.walk_in', 'Walk-in');
    const cls = statusChipClass(order.status);
    const label = tr('queue.' + order.status, order.status);
    // Subtitle: client + due hint, reusing the shared due-date language.
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
    const pct = jobProgress(order);
    const pctHtml = pct != null
      ? `<span class="wb-tail-pct">${pct}%</span>` : '';
    // The row paints a hover highlight, so it must actually do something —
    // it used to be an inert <li> with a pointer affordance and no handler.
    return `<li class="is-openable" data-order-id="${escapeHtml(order.id)}" tabindex="0" role="button">
      <span class="wb-attn-ico" style="background:color-mix(in srgb, ${CHIP[cls].fg} 12%, transparent);color:${CHIP[cls].fg}">${svg(ICON.printer)}</span>
      <div class="wb-li-text"><div class="wb-ttl">${escapeHtml(title)}</div><div class="wb-sub">${escapeHtml(sub)}</div></div>
      <span class="wb-tail">${pctHtml}${chip(cls, label)}</span>
    </li>`;
  }

  // Time-based progress estimate for a printing order (same math as the legacy floor).
  function jobProgress(order) {
    if (order.status !== 'printing' || !(+order.printTime > 0)) return null;
    const start = new Date(order.printingStartedAt || order.timerStart || Date.now()).getTime();
    return Math.min(99, Math.max(0, Math.round((Date.now() - start) / (order.printTime * 3600000) * 100)));
  }

  /* ---------- Fleet · live mini row ---------- */
  function fleetRow(machine, order) {
    // Prefer live telemetry from machineStatusCache (same source the kanban uses),
    // falling back to the time-based estimate, then idle.
    let pct = 0;
    let state = 'idle';
    const cache = (typeof machineStatusCache !== 'undefined') ? machineStatusCache[machine.id] : null;
    if (machine.isOffline) {
      state = 'error';
    } else if (cache && !cache.error) {
      pct = Math.min(100, Math.max(0, Math.round(+cache.progress || 0)));
      const st = (cache.state || '').toLowerCase();
      if (st.includes('print')) state = 'printing';
      else if (st.includes('error')) state = 'error';
      else if (pct > 0) state = 'printing';
    } else if (cache && cache.error) {
      // Don't call a printer offline on the strength of one missed poll — the
      // poller now preserves the last telemetry and counts consecutive misses,
      // so hold the previous reading and say "reconnecting" until it has really
      // stopped answering. Calling a live machine dead trains the operator to
      // distrust the panel, which is worse than being 30 seconds stale.
      if ((cache.consecutiveFailures || 0) < OFFLINE_AFTER_MISSED_POLLS) {
        state = 'stale';
        pct = Math.min(100, Math.max(0, Math.round(+cache.progress || 0)));
      } else {
        state = 'error';
      }
    } else if (order) {
      const est = jobProgress(order);
      pct = est != null ? est : 0;
      state = 'printing';
    }
    const jobName = order ? (order.project || order.id) : tr('dash.idle_dash', '— idle —');
    let cls = 'blue';
    if (state === 'error') cls = 'red';
    else if (state === 'idle' || state === 'stale') cls = 'gray';
    const c = CHIP[cls];
    const fill = cls === 'gray'
      ? 'background:var(--line)'
      : cls === 'red'
        ? 'background:linear-gradient(90deg,var(--wb-red),#f47a72)'
        : '';
    const tail = state === 'idle'
      ? tr('mach.status_idle', 'idle')
      : state === 'stale'
        ? tr('mach.reconnecting', 'reconnecting')
        : state === 'error'
          ? tr('mach.offline', 'offline')
          : `${pct}%`;
    return `<div class="wb-fm-row">
      <span class="wb-fm-nm" title="${escapeHtml(machine.name)}">${escapeHtml(machine.name)}</span>
      <span class="wb-fm-job">${escapeHtml(jobName)}</span>
      <div class="wb-bar"><i style="width:${Math.max(pct, state === 'idle' ? 0 : 3)}%;${fill}"></i></div>
      <span class="wb-fm-pct" style="color:${state === 'idle' ? 'var(--ink-3)' : c.fg}">${escapeHtml(tail)}</span>
    </div>`;
  }

  /* ---------- "Needs attention" row ---------- */
  function attnRow(item) {
    return `<li>
      <span class="wb-attn-ico" style="background:${item.bg};color:${item.fg}">${svg(item.icon)}</span>
      <div class="wb-li-text"><div class="wb-ttl">${escapeHtml(item.title)}</div><div class="wb-sub">${escapeHtml(item.sub)}</div></div>
      <span class="wb-tail">${chip(item.chip, item.chipLabel)}</span>
    </li>`;
  }

  /* ---------- Quick action tile ---------- */
  function qa(tab, label, tokenColor, iconPath) {
    return `<button type="button" class="wb-qa" data-act="goto-tab" data-tab="${escapeHtml(tab)}">
      <span class="wb-qa-glyph" style="background:${tokenColor}">${svg(iconPath)}</span>${escapeHtml(label)}</button>`;
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
    // Mode separation: enthusiast = no commerce (revenue/receivables/quotes/clients).
    const biz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(cfg.mode) : cfg.mode !== 'enthusiast';

    /* ---- Working figures ---- */
    // The KPI wall that stood here is gone. Four tiles reading "Revenue today",
    // "Active prints", "Filament today" and "Open orders" shouted at the same
    // volume as everything else and answered questions nobody had walked up to
    // the screen to ask — while "Fleet · live" sat below the fold.
    //
    // Where each number went, so this is a move and not a deletion:
    //   Revenue today   → Analytics (revenue + aged receivables live there)
    //   Filament today  → Analytics (filament performance / material usage)
    //   Active prints   → the Fleet panel's live count, next to the machines
    //   Open orders     → the status bar footer
    //   Overdue         → promoted into the attention bar, which is the point:
    //                     it is the only one of these you must act on, and it
    //                     was the only one Analytics had no home for.
    const nowPrinting = log.filter((o) => o.status === 'printing');
    const openOrders = log.filter((o) => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote');

    /* ---- Today's work (real active orders) ---- */
    const ACTIVE_ORDER = ['printing', 'pending', 'post', 'qc', 'on_hold'];
    const todaysWork = openOrders
      .filter((o) => ACTIVE_ORDER.includes(o.status))
      .sort((a, b) => {
        // printing first, then by due date.
        const ap = a.status === 'printing' ? 0 : 1;
        const bp = b.status === 'printing' ? 0 : 1;
        if (ap !== bp) return ap - bp;
        return (a.dueDate || '~').localeCompare(b.dueDate || '~');
      })
      .slice(0, 8);
    const workHrs = todaysWork.reduce((s, o) => s + (+o.printTime || 0), 0);
    const workMeta = todaysWork.length
      ? `${todaysWork.length} ${tr('dash.wb_jobs', 'jobs')} · ${workHrs.toFixed(1)}h ${tr('dash.wb_est', 'est.')}`
      : '';
    const workBody = todaysWork.length
      ? todaysWork.map(jobRow).join('')
      : `<li class="wb-empty">${escapeHtml(tr('dash.all_clear', 'All clear'))}</li>`;

    /* ---- Fleet · live (real machines + telemetry) ---- */
    const fleetRows = mach.slice(0, 6).map((m) => {
      const job = nowPrinting.find((o) => o.machineId === m.id
        || (o.parts || []).some((p) => p.machineId === m.id));
      return fleetRow(m, job);
    }).join('');
    const liveCount = nowPrinting.length;

    /* ---- What needs me now ---- */
    // One selector feeds both the bar and the panel below it. They used to be
    // derived separately and showed two different counts a few inches apart —
    // the bar saying 3 while the panel said 2, under near-identical wording.
    const attn = facts(log, mach).attn;

    /* ---- Needs attention (real signals) ---- */
    // The panel is the bar's drill-down: the same urgent items in the same
    // order, then the softer signals the bar deliberately stays quiet about.
    // Only the bar carries a number, so there is nothing left to disagree.
    const attention = attn.items.map((a) => {
      if (a.kind === 'machine') {
        const cache = (typeof machineStatusCache !== 'undefined') ? machineStatusCache[a.id] : null;
        return {
          icon: ICON.warn, fg: 'var(--wb-red)', bg: 'var(--wb-red-bg)',
          title: tr('dash.wb_printer_issue', `${a.name} — needs attention`).replace('{name}', a.name),
          sub: cache && cache.error ? String(cache.error) : tr('mach.offline', 'Offline'),
          chip: 'red', chipLabel: tr('dash.wb_error', 'Error'),
        };
      }
      return {
        icon: ICON.queue, fg: 'var(--wb-amber)', bg: 'var(--wb-amber-bg)',
        title: a.name || tr('inv.walk_in', 'Walk-in'),
        sub: tr('oe.due_overdue', 'Overdue by {n}d').replace('{n}', a.daysLate),
        chip: 'amber', chipLabel: tr('dash.wb_due', 'Due'),
      };
    });
    // Low stock (via isLowStock).
    if (typeof isLowStock === 'function') {
      inv.filter(isLowStock).slice(0, 3).forEach((item) => {
        const unit = item.materialType === 'resin' ? 'mL' : 'g';
        attention.push({
          icon: ICON.inv, fg: 'var(--wb-amber)', bg: 'var(--wb-amber-bg)',
          title: `${item.material || tr('inv.material', 'Material')}`,
          sub: `${Math.round(+item.weight || 0)} ${unit} · ${tr('dash.wb_reorder_point', 'reorder point')}`,
          chip: 'amber', chipLabel: tr('dash.wb_low', 'Low'),
        });
      });
    }
    // Expiring / follow-up quotes via the shared selector (business modes only).
    const followUps = (biz && typeof KhaytQuoteFollowUp !== 'undefined' && typeof cfg === 'object')
      ? KhaytQuoteFollowUp.selectQuotesDueForFollowUp(log, cfg, Date.now())
      : [];
    followUps.slice(0, 3).forEach((q) => {
      const client = findClient(q.clientId);
      const bits = [`${fmtMoneyVal(q.price)} ${ccy()}`];
      if (client) bits.push(localName(client));
      attention.push({
        icon: ICON.money, fg: 'var(--wb-blue)', bg: 'var(--wb-blue-bg)',
        title: q.project || tr('dash.wb_quote', 'Quote') + ' ' + q.id,
        sub: bits.join(' · '),
        chip: 'blue', chipLabel: tr('dash.wb_due', 'Due'),
      });
    });
    // Overdue receivables (completed but unpaid past due) as a fallback signal (business only).
    if (biz && attention.length < 5) {
      log.filter((o) => KhaytOrderStatus.isFinished(o) && payStatus(o) !== 'paid' && payStatus(o) !== 'voided' && orderOwedBase(o) > 0)
        .slice(0, 5 - attention.length).forEach((o) => {
          const client = findClient(o.clientId);
          const bits = [`${fmtMoneyVal(orderOwedBase(o))} ${ccy()}`];
          if (client) bits.push(localName(client));
          const payLbl = payStatus(o) === 'partial'
            ? tr('dash.wb_partial', 'balance due')
            : tr('dash.wb_unpaid', 'unpaid');
          attention.push({
            icon: ICON.money, fg: 'var(--wb-blue)', bg: 'var(--wb-blue-bg)',
            title: `${tr('dash.wb_invoice', 'Invoice')} ${o.id} ${payLbl}`,
            sub: bits.join(' · '),
            chip: 'blue', chipLabel: tr('dash.wb_due', 'Due'),
          });
        });
    }
    const attnTrimmed = attention.slice(0, 6);
    // Say what the cap hid. Urgent items lead this list now, so a shop with
    // seven offline printers would otherwise see a bar counting 7 above a panel
    // showing 6 — the same two-numbers-disagreeing problem in a new place.
    const attnHidden = attention.length - attnTrimmed.length;
    const attnMore = attnHidden > 0
      ? `<li class="wb-empty">${escapeHtml(tr('cl.show_more', 'Show {n} more').replace('{n}', attnHidden))}</li>`
      : '';
    const attnBody = attnTrimmed.length
      ? attnTrimmed.map(attnRow).join('') + attnMore
      : `<li class="wb-empty">${escapeHtml(tr('dash.all_clear', 'All clear'))}</li>`;

    // The bar itself is shared with the legacy dashboard, so the interruption
    // line reads identically across themes even where the layout around it isn't.
    const attnBar = (typeof KhaytDashboard !== 'undefined')
      ? KhaytDashboard.buildAttentionBar(attn, mach.length)
      : '';

    /* ---- Compose ---- */
    host.innerHTML = `<div class="wb-dash">
      ${attnBar}

      <div class="wb-grid2">
        <div class="wb-col">
          <div class="wb-section-title">${escapeHtml(tr('dash.wb_fleet_glance', 'Fleet · live'))}</div>
          <div class="wb-panel">
            <div class="wb-panel-h"><h3>${escapeHtml(tr('dash.wb_fleet', 'Fleet'))}</h3>${liveCount ? `<span class="wb-meta wb-live">${liveCount} ${escapeHtml(tr('dash.live', 'live'))}</span>` : ''}</div>
            <div class="wb-fleet-mini">${fleetRows || `<div class="wb-empty">${escapeHtml(tr('dash.no_machines', 'No printers yet'))}</div>`}</div>
          </div>

          <div class="wb-panel">
            <div class="wb-panel-h"><h3>${escapeHtml(tr('dash.wb_todays_work', "Today's work"))}</h3><span class="wb-meta">${escapeHtml(workMeta)}</span></div>
            <ul class="wb-glist">${workBody}</ul>
          </div>
        </div>

        <div class="wb-col">
          <div class="wb-panel">
            <div class="wb-panel-h"><h3>${escapeHtml(tr('dash.needs_attention', 'Needs attention'))}</h3></div>
            <ul class="wb-glist">${attnBody}</ul>
          </div>

          <div class="wb-section-title">${escapeHtml(tr('dash.wb_quick_actions', 'Quick actions'))}</div>
          <div class="wb-panel wb-qa-grid">
            ${qa('calculator-tab', tr('dash.wb_estimate', 'Estimate'), 'var(--wb-purple)', ICON.calc)}
            ${qa('queue-tab', tr('dash.wb_add_job', 'Add job'), 'var(--wb-blue)', ICON.plus)}
            ${biz
              ? qa('logs-tab', tr('dash.wb_new_invoice', 'New invoice'), 'var(--wb-green)', ICON.money)
              : qa('waste-tab', tr('waste.log_from_card', 'Log waste'), 'var(--wb-green)', ICON.inv)}
            ${qa('inventory-tab', tr('dash.wb_add_stock', 'Add stock'), 'var(--wb-amber)', ICON.inv)}
          </div>
        </div>
      </div>
    </div>`;

    // Wire navigation buttons (same contract as the legacy dashboard).
    host.querySelectorAll('[data-act="goto-tab"]').forEach((btn) => {
      btn.addEventListener('click', () => {
        if (typeof switchTab === 'function') switchTab(btn.dataset.tab);
      });
    });

    // Open the order behind a job row. Delegated on the host (which this render
    // just replaced), so listeners cannot accumulate across re-renders.
    const openRow = (el) => {
      const id = el && el.dataset.orderId;
      if (id && typeof openOrderEditor === 'function') openOrderEditor(id);
    };
    host.addEventListener('click', (e) => {
      const li = e.target.closest('li.is-openable');
      if (li) openRow(li);
    });
    host.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter' && e.key !== ' ') return;
      const li = e.target.closest('li.is-openable');
      if (!li) return;
      e.preventDefault();
      openRow(li);
    });

    if (typeof i18n !== 'undefined' && i18n.apply) i18n.apply(host);
    return true;
  }

  global.KhaytWorkbench = {
    isOn,
    renderDashboard,
  };
})(typeof window !== 'undefined' ? window : globalThis);
