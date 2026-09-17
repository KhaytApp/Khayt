/**
 * Foreman screens — the docket that replaces the dashboard.
 *
 * WHY A DOCKET
 *
 * Every other Khayt home answers "how is the shop doing" — tiles of counts, or
 * (in Meridian) the shape of the day. None of them answers the question an
 * owner actually opens the app with: "what do I have to deal with, and am I
 * done yet?" A dashboard cannot answer that, because a dashboard has no end.
 *
 * So this home is a LIST YOU EMPTY. Every row is one decision with one action,
 * ranked worst-first, and the goal state is zero rows. That is a different
 * model from a dashboard, not a different skin on one: you work it top-down
 * and it tells you when you can stop.
 *
 * EVERY RULE HERE IS BORROWED, NOT INVENTED. A triage list that used its own
 * thresholds would quietly disagree with the rest of the app — the queue would
 * call an order fine while the docket called it late. So:
 *
 *   - stopped machines + overdue orders  → KhaytAttention.selectAttention()
 *   - unpaid                             → payStatus(o) !== 'paid', the same
 *                                          test the dashboard's unpaid section
 *                                          uses, with orderOwedBase for the sum
 *   - low material                       → isLowStock(), the shared helper the
 *                                          reorder engine already uses
 *   - idle printers                      → KhaytAttention.machineState() === 'idle'
 *
 * The only thing this module decides for itself is the ORDER, and that is
 * stated as a table rather than buried in a comparator.
 */
(function (global) {
  /* Worst first. Money owed outranks an idle machine; a stopped machine
     outranks everything, because it is the only one actively costing hours. */
  const RANK = { crit: 0, due: 1, cash: 2, stock: 3, idle: 4 };

  function escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }

  function tr(key, fallback) {
    try {
      const v = (typeof t === 'function') ? t(key) : null;
      return (v && v !== key) ? v : fallback;
    } catch (_) { return fallback; }
  }

  function money(n) {
    try {
      if (typeof fmtPrice === 'function') return fmtPrice(n);
    } catch (_) { /* fall through */ }
    return String(Math.round(+n || 0));
  }

  function scopedOrders() {
    const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    return (typeof orderMatchesActiveLocation === 'function')
      ? log.filter(orderMatchesActiveLocation) : log;
  }

  function scopedMachines() {
    const m = (typeof machines !== 'undefined' && Array.isArray(machines)) ? machines : [];
    return (typeof machineMatchesActiveLocation === 'function')
      ? m.filter(machineMatchesActiveLocation) : m;
  }

  /**
   * Build the docket. Returns rows of
   * { key, sev, title, detail, action:{label,tab}, orderId?, machineId? }
   */
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

  function buildDocket() {
    const orders = scopedOrders();
    const mach = scopedMachines();
    const inv = (typeof inventory !== 'undefined' && Array.isArray(inventory)) ? inventory : [];
    const rows = [];

    // 1 + 2 — stopped machines and overdue work, straight from the shared selector.
    // The try/catch that stood here now lives inside the shared derivation, which
    // is rather the point: a catch at the call site is exactly what hid Flow's
    // broken read of this same engine.
    const attn = facts(orders, mach).attn;

    for (const it of attn.items || []) {
      if (it.kind === 'machine') {
        rows.push({
          key: `m:${it.id}`, sev: 'crit', machineId: it.id,
          title: it.name || it.id,
          detail: it.state === 'error'
            ? tr('fm.machine_error', 'Reporting an error — nothing will print until it is cleared')
            : tr('fm.machine_offline', 'Not answering — it has stopped, this is not a missed poll'),
          action: { label: tr('fm.go_printers', 'Printers'), tab: 'machines-tab' },
        });
      } else if (it.kind === 'nozzle') {
        // A nozzle past the threshold the shop set. `due`, not `crit`: it does
        // not stop the printer, it makes the parts wrong — worse to find late,
        // and still not a reason to outrank a machine that has gone down.
        rows.push({
          key: `n:${it.id}`, sev: 'due', machineId: it.id,
          title: it.name || it.id,
          detail: tr('fm.nozzle_due', 'Nozzle past {g} g — parts will start coming out wrong')
            .replace('{g}', String(it.threshold)),
          action: { label: tr('fm.go_printers', 'Printers'), tab: 'machines-tab' },
        });
      } else if (it.kind === 'order') {
        rows.push({
          key: `o:${it.id}`, sev: 'due', orderId: it.id,
          title: it.name || it.id,
          detail: tr('fm.days_late', '{n} days past the promised date').replace('{n}', it.daysLate),
          action: { label: tr('fm.go_queue', 'Queue'), tab: 'queue-tab' },
        });
      }
    }

    // 3 — money owed. Same test the dashboard's unpaid section uses.
    //
    // Gated on the tier: enthusiast mode is a hobbyist who does not invoice, and
    // every other themed dashboard suppresses revenue there. A docket row saying
    // "240.00 SAR outstanding" would put money back on a screen the rest of the
    // app has deliberately cleared of it — which is what the theme e2e caught.
    const showsMoney = (typeof KhaytTiers !== 'undefined' && KhaytTiers.showsBusiness)
      ? KhaytTiers.showsBusiness(typeof settings !== 'undefined' ? settings.mode : undefined)
      : (typeof settings === 'undefined' || settings.mode !== 'enthusiast');
    if (showsMoney && typeof payStatus === 'function') {
      for (const o of orders) {
        if (!KhaytOrderStatus.isFinished(o) || o.voidedAt) continue;
        if (payStatus(o) === 'paid') continue;
        const owed = (typeof orderOwedBase === 'function') ? orderOwedBase(o) : 0;
        if (!(owed > 0)) continue;
        rows.push({
          key: `p:${o.id}`, sev: 'cash', orderId: o.id, amount: owed,
          title: o.project || o.id,
          detail: tr('fm.owes', '{amt} outstanding').replace('{amt}', money(owed)),
          action: { label: tr('fm.go_orders', 'Orders'), tab: 'logs-tab' },
        });
      }
    }

    // 4 — material about to run out, via the shared helper (never a local rule).
    if (typeof isLowStock === 'function') {
      for (const item of inv) {
        let low = false;
        try { low = !!isLowStock(item); } catch (_) { low = false; }
        if (!low) continue;
        rows.push({
          key: `i:${item.id || item.name}`, sev: 'stock',
          title: item.name || item.id || '',
          detail: tr('fm.low_left', '{g} g left').replace('{g}', Math.round(+item.weight || 0)),
          action: { label: tr('fm.go_inventory', 'Inventory'), tab: 'inventory-tab' },
        });
      }
    }

    // 5 — capacity going unused, as ONE row rather than one per printer.
    //
    // Which printer is free is not the decision; "there is free capacity and
    // waiting work" is, and the answer is the same for all of them — go assign
    // something. Four idle machines emitting four near-identical rows padded a
    // list whose whole promise is that every row needs an action from you, and
    // pushed the genuinely urgent rows off the screen.
    const waiting = orders.filter((o) => o && !KhaytOrderStatus.isFinished(o) && o.status !== 'quote'
      && o.status !== 'printing' && !o.archived).length;
    if (waiting > 0 && global.KhaytAttention?.machineState) {
      const idle = [];
      for (const m of mach) {
        let st = 'idle';
        try {
          st = global.KhaytAttention.machineState(
            m, (typeof machineStatusCache !== 'undefined' ? machineStatusCache : {})[m.id], {},
          );
        } catch (_) { st = 'idle'; }
        if (st === 'idle') idle.push(m.name || m.id);
      }
      if (idle.length) {
        rows.push({
          key: 'd:idle', sev: 'idle',
          title: idle.length === 1
            ? tr('fm.idle_one', '{m} is free').replace('{m}', idle[0])
            : tr('fm.idle_many', '{n} printers are free').replace('{n}', idle.length),
          detail: tr('fm.idle_waiting', '{n} jobs are waiting to be assigned').replace('{n}', waiting),
          note: idle.join(' · '),
          action: { label: tr('fm.go_queue', 'Queue'), tab: 'queue-tab' },
        });
      }
    }

    rows.sort((a, b) => (RANK[a.sev] - RANK[b.sev]) || String(a.title).localeCompare(String(b.title)));
    return rows;
  }

  const SEV_LABEL = {
    crit:  ['fm.sev_crit', 'Stopped'],
    due:   ['fm.sev_due', 'Late'],
    cash:  ['fm.sev_cash', 'Unpaid'],
    stock: ['fm.sev_stock', 'Low stock'],
    idle:  ['fm.sev_idle', 'Idle'],
  };

  let focusKey = null;

  /* A severity with more than this many rows collapses to a single summary row.
     Worst-first ranking is defeated by volume otherwise: a shop with thirty
     unpaid invoices pushes its stopped printer off the screen, and the list
     stops being a ranking and becomes an accounts-receivable report. Three is
     the point where a run reads as "a few things" rather than "a category". */
  const GROUP_AT = 3;
  const expanded = new Set();   // severities the user has opened

  /**
   * Turn the ranked items into what actually gets drawn: runs of the same
   * severity longer than GROUP_AT become one group row unless opened.
   * Both the renderer and the keyboard walk this, so focus can never land on a
   * row that is not on screen.
   */
  function visibleRows(rows) {
    const out = [];
    let i = 0;
    while (i < rows.length) {
      const sev = rows[i].sev;
      let j = i;
      while (j < rows.length && rows[j].sev === sev) j++;
      const run = rows.slice(i, j);
      if (run.length > GROUP_AT && !expanded.has(sev)) {
        out.push({ group: true, sev, items: run, key: `g:${sev}` });
      } else {
        if (run.length > GROUP_AT) out.push({ group: true, sev, items: run, key: `g:${sev}`, open: true });
        out.push(...run);
      }
      i = j;
    }
    return out;
  }

  /** Money in a run, when the run is about money — otherwise just a count. */
  function groupSummary(sev, items) {
    if (sev === 'cash') {
      let total = 0;
      for (const it of items) total += (+it.amount || 0);
      return total > 0
        ? tr('fm.group_cash', '{n} unpaid · {amt} outstanding')
          .replace('{n}', items.length).replace('{amt}', money(total))
        : tr('fm.group_n', '{n} items').replace('{n}', items.length);
    }
    return tr('fm.group_n', '{n} items').replace('{n}', items.length);
  }

  function rowHtml(r, i) {
    const [k, f] = SEV_LABEL[r.sev] || SEV_LABEL.idle;
    return `<button type="button" class="fm-row fm-${r.sev}${r.key === focusKey ? ' focused' : ''}"
      data-fm-key="${escHtml(r.key)}" data-fm-i="${i}" tabindex="-1">
      <span class="fm-sev">${escHtml(tr(k, f))}</span>
      <span class="fm-row-main">
        <span class="fm-row-title">${escHtml(r.title)}</span>
        <span class="fm-row-detail">${escHtml(r.detail)}</span>
      </span>
    </button>`;
  }

  function groupRowHtml(g) {
    const [k, f] = SEV_LABEL[g.sev] || SEV_LABEL.idle;
    const open = !!g.open;
    return `<button type="button" class="fm-row fm-group fm-${g.sev}${g.key === focusKey ? ' focused' : ''}"
      data-fm-group="${escHtml(g.sev)}" aria-expanded="${open}" tabindex="-1">
      <span class="fm-sev">${escHtml(tr(k, f))}</span>
      <span class="fm-row-main">
        <span class="fm-row-title">${escHtml(groupSummary(g.sev, g.items))}</span>
        <span class="fm-row-detail">${escHtml(open
          ? tr('fm.group_hide', 'Hide them')
          : tr('fm.group_show', 'Show each one'))}</span>
      </span>
      <span class="fm-chev">${open ? '\u2303' : '\u2304'}</span>
    </button>`;
  }

  function detailHtml(r) {
    if (!r) {
      return `<div class="fm-detail-empty">${escHtml(tr('fm.pick_one', 'Select something on the left.'))}</div>`;
    }
    const [k, f] = SEV_LABEL[r.sev] || SEV_LABEL.idle;
    return `<div class="fm-detail-card">
      <span class="fm-sev fm-${r.sev}">${escHtml(tr(k, f))}</span>
      <h2>${escHtml(r.title)}</h2>
      <p>${escHtml(r.detail)}</p>
      ${r.note ? `<p class="fm-note">${escHtml(r.note)}</p>` : ''}
      <div class="fm-actions">
        <button type="button" class="btn primary" data-fm-act="${escHtml(r.action.tab)}"
          ${r.orderId ? `data-fm-order="${escHtml(r.orderId)}"` : ''}>${escHtml(r.action.label)} →</button>
      </div>
    </div>`;
  }

  function renderDashboard(host) {
    if (!document.body.classList.contains('khayt-foreman')) return false;
    if (!host) return false;

    const rows = buildDocket();
    const vis = visibleRows(rows);
    if (!vis.some((r) => r.key === focusKey)) focusKey = vis[0]?.key || null;
    const focused = vis.find((r) => r.key === focusKey && !r.group) || null;

    const list = vis.length
      ? vis.map((r, i) => (r.group ? groupRowHtml(r) : rowHtml(r, i))).join('')
      : `<div class="fm-clear">
           <strong>${escHtml(tr('fm.clear_title', 'Nothing needs you'))}</strong>
           <span>${escHtml(tr('fm.clear_sub', 'No stopped printers, nothing late, nothing unpaid.'))}</span>
         </div>`;

    host.innerHTML = `<div class="fm-shell">
      <section class="fm-docket" aria-label="${escHtml(tr('fm.docket', 'Docket'))}">
        <header class="fm-docket-head">
          <h2>${escHtml(tr('fm.docket', 'Docket'))}</h2>
          <span class="fm-count${rows.length ? '' : ' zero'}">${rows.length}</span>
        </header>
        <div class="fm-rows" id="fmRows">${list}</div>
        ${rows.length ? `<footer class="fm-hint">${escHtml(tr('fm.keys', 'J / K to move · Enter to open'))}</footer>` : ''}
      </section>
      <section class="fm-detail" aria-label="${escHtml(tr('fm.detail', 'Selected'))}">${detailHtml(focused)}</section>
    </div>`;

    host.querySelectorAll('[data-fm-key]').forEach((el) => {
      el.addEventListener('click', () => {
        focusKey = el.getAttribute('data-fm-key');
        renderDashboard(host);
      });
    });
    host.querySelectorAll('[data-fm-group]').forEach((el) => {
      el.addEventListener('click', () => {
        const sev = el.getAttribute('data-fm-group');
        if (expanded.has(sev)) expanded.delete(sev); else expanded.add(sev);
        focusKey = `g:${sev}`;
        renderDashboard(host);
      });
    });
    host.querySelectorAll('[data-fm-act]').forEach((el) => {
      el.addEventListener('click', () => {
        const orderId = el.getAttribute('data-fm-order');
        if (orderId && typeof openOrderDetail === 'function') { openOrderDetail(orderId); return; }
        const tab = el.getAttribute('data-fm-act');
        if (typeof switchTab === 'function') switchTab(tab);
      });
    });

    global.KhaytForemanShell?.syncDocketCount?.(rows.length);
    return true;
  }

  /** Keyboard triage: move the focus, open the focused row. */
  function moveFocus(delta) {
    // Walk what is on screen, not the raw list — otherwise focus lands inside a
    // collapsed group and the selection appears to vanish.
    const rows = visibleRows(buildDocket());
    if (!rows.length) return;
    let i = rows.findIndex((r) => r.key === focusKey);
    if (i < 0) i = 0; else i = Math.max(0, Math.min(rows.length - 1, i + delta));
    focusKey = rows[i].key;
    const host = document.getElementById('dashboardContent');
    if (host) renderDashboard(host);
    document.querySelector('.fm-row.focused')?.scrollIntoView({ block: 'nearest' });
  }

  function openFocused() {
    const r = visibleRows(buildDocket()).find((x) => x.key === focusKey);
    if (!r) return;
    if (r.group) {                       // Enter opens or closes a group
      if (expanded.has(r.sev)) expanded.delete(r.sev); else expanded.add(r.sev);
      const host = document.getElementById('dashboardContent');
      if (host) renderDashboard(host);
      return;
    }
    if (r.orderId && typeof openOrderDetail === 'function') { openOrderDetail(r.orderId); return; }
    if (typeof switchTab === 'function') switchTab(r.action.tab);
  }

  global.KhaytForeman = { renderDashboard, buildDocket, moveFocus, openFocused };
})(typeof window !== 'undefined' ? window : globalThis);
