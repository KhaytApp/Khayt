/**
 * Flow screens — the board that replaces the dashboard.
 *
 * WHY A BOARD
 *
 * Khayt already has a kanban board, but it lives on a tab you visit. That makes
 * it a report: you go and look at it. Flow inverts that — the board IS the home
 * screen, and moving a card is how you run the shop. Opening the app puts you
 * in front of the work with your hands already on it, rather than in front of a
 * summary of the work.
 *
 * That is the whole difference from the other designs. Workbench and Command
 * answer "how is the shop doing". Foreman answers "what must I deal with".
 * Meridian answers "what does today look like". Flow answers "where is
 * everything, and what do I want to move next" — and lets you move it.
 *
 * EVERY RULE IS BORROWED. A second board with its own opinions would quietly
 * disagree with the first: the queue would call an order late while the board
 * called it fine. So:
 *
 *   - columns and their order   → the same six statuses the kanban tab uses
 *   - WIP limits                → settings.wipLimits, the same map, same test
 *   - what counts as late       → KhaytAttention.selectAttention()
 *   - paid / part-paid / unpaid → payStatus(), with orderOwedBase() for sums
 *   - which orders are in scope → orderMatchesActiveLocation(), so the board
 *                                 respects the location filter like every
 *                                 other screen
 *
 * Money is gated on KhaytTiers.showsBusiness. Foreman shipped leaking revenue
 * into enthusiast mode and the theme e2e caught it, not review — so the gate
 * goes in at the point the value is produced, not at the point it is styled.
 */
(function (global) {
  /* The kanban tab's columns, in its order. Duplicating the list would let the
     two boards drift apart on the next status change. */
  const COLUMNS = [
    { status: 'pending',   key: 'queue.pending',   fallback: 'Pending',         lane: 'var(--flow-lane-1)' },
    { status: 'printing',  key: 'queue.printing',  fallback: 'Printing',        lane: 'var(--flow-lane-2)' },
    { status: 'post',      key: 'queue.post',      fallback: 'Post-Processing', lane: 'var(--flow-lane-3)' },
    { status: 'qc',        key: 'queue.qc',        fallback: 'QC',              lane: 'var(--flow-lane-4)' },
    { status: 'completed', key: 'queue.completed', fallback: 'Completed',       lane: 'var(--flow-lane-5)' },
  ];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }

  function tr(key, fallback, vars) {
    if (typeof t === 'function') {
      const v = t(key, vars);
      if (v && v !== key) return v;
    }
    if (vars && fallback) {
      let s = fallback;
      for (const k of Object.keys(vars)) s = s.replaceAll(`{${k}}`, String(vars[k]));
      return s;
    }
    return fallback;
  }

  /**
   * Everything this board needs to know about the shop, answered by the shared
   * derivation rather than here.
   *
   * What used to live in this space was three helpers, one of which had been
   * silently broken since it was written. `lateOrderIds()` called the attention
   * engine — correctly, and its comment said so — then iterated the result as an
   * array. `selectAttention` returns `{count, items}`, so `for…of` threw
   * `TypeError: attn is not iterable` on every single render, and the catch two
   * lines below it swallowed the throw. It also looked for `a.orderId` where the
   * items carry `a.id`, so it would have found nothing even had it been
   * iterable. Two independent mistakes, one silent result: no card on this board
   * has ever shown a "late" chip, and the "{n} late" alert has never appeared.
   *
   * The board was not wrong to borrow. It was wrong to borrow at a call site
   * that had to know the engine's return shape, where being wrong costs nothing
   * visible. That knowledge now sits in one tested place.
   */
  function facts() {
    const all = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    return global.KhaytDashboardFacts.dashboardFacts({
      // Location scoping stays here: which shop you are looking at is a renderer
      // concern, and the facts module takes orders already narrowed.
      orders: (typeof orderMatchesActiveLocation === 'function') ? all.filter(orderMatchesActiveLocation) : all,
      machines: (typeof machines !== 'undefined' && Array.isArray(machines)) ? machines : [],
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

  function wipLimitFor(status) {
    const map = (typeof settings !== 'undefined' && settings.wipLimits) || {};
    return +map[status] || 0;
  }

  function cardHtml(o, late, money) {
    const chips = [];
    if (late.has(o.id)) {
      chips.push(`<span class="flow-chip late">${esc(tr('flow.late', 'late'))}</span>`);
    }
    if (money && typeof payStatus === 'function') {
      const ps = payStatus(o);
      if (ps === 'paid') chips.push(`<span class="flow-chip ok">${esc(tr('flow.paid', 'paid'))}</span>`);
      else if (ps === 'partial') chips.push(`<span class="flow-chip unpaid">${esc(tr('flow.part_paid', 'part-paid'))}</span>`);
      else chips.push(`<span class="flow-chip unpaid">${esc(tr('flow.unpaid', 'unpaid'))}</span>`);
    }
    const machine = o.machine || o.machineId || '';
    const meta = [];
    if (o.client) meta.push(esc(String(o.client)));
    if (machine) meta.push(esc(String(machine)));
    if (money && typeof fmtPrice === 'function' && +o.price) meta.push(esc(fmtPrice(+o.price)));

    return `<article class="flow-card" draggable="true" tabindex="0"
        data-order-id="${esc(o.id)}" data-status="${esc(o.status || '')}"
        aria-label="${esc(o.project || jobRef(o))}">
      <div class="flow-card-title">${esc(o.project || jobRef(o))}</div>
      ${meta.length ? `<div class="flow-card-meta">${meta.map((m) => `<span>${m}</span>`).join('')}</div>` : ''}
      ${chips.length ? `<div class="flow-card-meta">${chips.join('')}</div>` : ''}
    </article>`;
  }

  function columnHtml(col, orders, late, money) {
    const mine = orders.filter((o) => o.status === col.status);
    const limit = wipLimitFor(col.status);
    const over = limit > 0 && mine.length > limit;
    const cards = mine.length
      ? mine.map((o) => cardHtml(o, late, money)).join('')
      : `<div class="flow-empty">${esc(tr('flow.empty_col', 'Nothing here'))}</div>`;

    return `<section class="flow-col${over ? ' over-wip' : ''}" data-status="${esc(col.status)}" style="--lane:${col.lane};">
      <header class="flow-col-head">
        <span class="flow-col-title">${esc(tr(col.key, col.fallback))}</span>
        ${over ? `<span class="flow-col-wip">${esc(tr('flow.over_wip', 'over {n}', { n: limit }))}</span>` : ''}
        <span class="flow-col-count">${mine.length}</span>
      </header>
      <div class="flow-col-list" data-drop="${esc(col.status)}">${cards}</div>
    </section>`;
  }

  function stripHtml(f) {
    const bits = [
      `<span>${esc(tr('flow.in_flight', 'In flight'))}: <b>${f.activeCount}</b></span>`,
    ];
    // This branch has been dead since the board shipped, because f.lateCount was
    // always 0. It is the same line; the number behind it is now real.
    if (f.lateCount) {
      bits.push(`<span class="alert">${esc(tr('flow.n_late', '{n} late', { n: f.lateCount }))}</span>`);
    }
    if (f.owed > 0 && typeof fmtPrice === 'function') {
      bits.push(`<span>${esc(tr('flow.owed', 'Owed'))}: <b>${esc(fmtPrice(f.owed))}</b></span>`);
    }
    bits.push(`<span>${esc(tr('flow.drag_hint', 'Drag a card to move it'))}</span>`);
    return `<div class="flow-strip">${bits.join('')}</div>`;
  }

  /**
   * Returns true when it has taken over the dashboard element. dashboard.js
   * falls through to the generic dashboard on false, so a failure here degrades
   * to the shared home rather than to a blank screen.
   */
  function renderDashboard(el) {
    if (!el || !document.body.classList.contains('khayt-flow')) return false;
    if (!global.KhaytDashboardFacts) return false;   // degrade to the shared dashboard
    const f = facts();

    el.innerHTML = `
      ${stripHtml(f)}
      <div class="flow-board" role="list">
        ${COLUMNS.map((c) => columnHtml(c, f.orders, f.lateIds, f.showsMoney)).join('')}
      </div>`;

    global.KhaytFlowShell?.wireBoard?.(el);
    return true;
  }

  global.KhaytFlow = { renderDashboard, COLUMNS };
})(typeof globalThis !== 'undefined' ? globalThis : window);
