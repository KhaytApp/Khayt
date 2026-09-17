/**
 * Meridian screens — the schedule that replaces the card dashboard.
 *
 * WHY A SCHEDULE
 *
 * A print shop's binding constraint is time on machines: a job occupies one
 * printer for hours, and the owner's real questions are "what is running, when
 * does it free up, and what is going to be late". Every other Khayt dashboard
 * answers those with tiles and lists — counts of a thing, not the shape of the
 * day. This one puts an hour axis across the top and a lane per machine under
 * it, so occupancy, gaps and collisions are visible as geometry instead of
 * having to be inferred from a queue list.
 *
 * WHAT IS REAL AND WHAT IS INFERRED — stated plainly, because a schedule that
 * quietly invents times would be worse than no schedule:
 *
 *   - A PRINTING job's start is real when the order carries printingStartedAt;
 *     its width is printTime hours. Those come from the order.
 *   - A QUEUED job has no start time in the data model. Khayt does not schedule
 *     work — nothing assigns a slot. So queued jobs are laid out by PROJECTION:
 *     packed onto their assigned machine's lane after whatever is already
 *     running. The lane marks them projected, and the legend says so.
 *   - Jobs with no machine cannot be placed on any lane and go to the staging
 *     strip underneath, which is the honest place for them.
 *
 * The projection is deliberately simple (first-fit, in queue order). It is a
 * picture of what the queue implies, not a promise, and calling it a plan would
 * be the kind of number-that-lies this codebase has spent several releases
 * removing.
 */
(function (global) {
  const HOURS_BEFORE = 2;   // context to the left of now
  const HOURS_SPAN = 14;    // hours drawn on the axis

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

  const num = (v) => (Number.isFinite(+v) ? +v : 0);

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

  /** Axis origin: HOURS_BEFORE before now, rounded down to the hour. */
  function axisStart(now) {
    const d = new Date(now.getTime());
    d.setMinutes(0, 0, 0);
    d.setHours(d.getHours() - HOURS_BEFORE);
    return d;
  }

  const hoursBetween = (a, b) => (b.getTime() - a.getTime()) / 3600000;

  function stateOf(order, now) {
    if (KhaytOrderStatus.isFinished(order)) return 'done';
    if (order.status === 'printing') return 'run';
    const due = order.dueDate ? new Date(order.dueDate + 'T23:59:59') : null;
    if (due && due < now) return 'late';
    if (order.status === 'on_hold' || order.blocked) return 'hold';
    return 'queue';
  }

  const STATE_LABEL = {
    run:   ['dash.mrd_running', 'Printing'],
    queue: ['dash.mrd_queued', 'Queued'],
    late:  ['dash.mrd_late', 'Overdue'],
    done:  ['dash.mrd_done', 'Done'],
    hold:  ['dash.mrd_hold', 'On hold'],
  };

  /**
   * Place orders onto machine lanes.
   * Running jobs anchor to printingStartedAt; queued jobs are PROJECTED after
   * them, first-fit in queue order. Returns lanes + whatever could not be placed.
   */
  function buildLanes(orders, mach, now) {
    const start = axisStart(now);
    const lanes = mach.map((m) => ({ machine: m, blocks: [], cursor: null }));
    const byId = new Map(lanes.map((l) => [l.machine.id, l]));
    const staged = [];

    const active = orders.filter((o) => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote' && !o.archived);

    // Anchor the running work first — it is the only thing with a real start.
    for (const o of active.filter((x) => x.status === 'printing')) {
      const lane = byId.get(o.machineId);
      const dur = Math.max(0.25, num(o.printTime));
      if (!lane) { staged.push({ order: o, state: 'run', projected: false }); continue; }
      const began = o.printingStartedAt ? new Date(o.printingStartedAt) : now;
      const from = Math.max(0, hoursBetween(start, began));
      lane.blocks.push({ order: o, state: 'run', from, span: dur, projected: false });
      lane.cursor = Math.max(lane.cursor ?? 0, from + dur);
    }

    // Then project the queue onto whichever lane its machine names.
    for (const o of active.filter((x) => x.status !== 'printing')) {
      const lane = byId.get(o.machineId);
      const dur = Math.max(0.25, num(o.printTime));
      if (!lane) { staged.push({ order: o, state: stateOf(o, now), projected: true }); continue; }
      const from = Math.max(lane.cursor ?? hoursBetween(start, now), hoursBetween(start, now));
      lane.blocks.push({ order: o, state: stateOf(o, now), from, span: dur, projected: true });
      lane.cursor = from + dur;
    }

    return { lanes, staged, start };
  }

  function blockHtml(b) {
    const [k, f] = STATE_LABEL[b.state] || STATE_LABEL.queue;
    const label = escHtml(b.order.project || b.order.id || '');
    // A running job is physically on that machine — dragging it to another lane
    // would claim something untrue about the shop floor, so only work that has
    // not started can be moved.
    const movable = b.state !== 'run' && b.state !== 'done';
    const title = `${label} · ${escHtml(tr(k, f))}${b.projected ? ` · ${escHtml(tr('dash.mrd_projected', 'projected'))}` : ''}${
      movable ? ` · ${escHtml(tr('dash.mrd_drag_hint', 'drag to another printer to reassign'))}` : ''}`;
    return `<button type="button" class="mrd-block mrd-${b.state}${b.projected ? ' mrd-proj' : ''}${movable ? ' mrd-movable' : ''}"
      style="--from:${b.from.toFixed(3)};--span:${b.span.toFixed(3)}"
      ${movable ? 'draggable="true"' : ''}
      data-order-id="${escHtml(b.order.id || '')}" title="${title}">
      <span class="mrd-block-label">${label}</span>
      <span class="mrd-block-meta">${b.span.toFixed(1)}h</span>
    </button>`;
  }

  /**
   * Assign an order to a machine by dropping it on that lane.
   *
   * Writes the same two fields the existing batch-assign path writes —
   * machineId AND machine (the name) — because parts of the app still resolve a
   * machine by name (analytics maps location that way). Setting only the id
   * would leave those readers looking at a stale name.
   */
  function assignToMachine(orderId, machineId) {
    const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    const order = log.find((o) => o && o.id === orderId);
    const machine = (typeof machines !== 'undefined' ? machines : []).find((m) => m && m.id === machineId);
    if (!order || !machine) return false;
    if (order.status === 'printing' || KhaytOrderStatus.isFinished(order)) return false;
    if (order.machineId === machineId) return false;

    order.machineId = machineId;
    order.machine = machine.name || machineId;
    if (typeof saveAll === 'function') saveAll();
    if (typeof renderKanban === 'function') renderKanban();
    if (typeof renderLogs === 'function') renderLogs();
    if (typeof renderDashboard === 'function') renderDashboard();
    if (typeof toast === 'function') {
      toast(`${order.project || order.id} → ${machine.name || machineId}`, 'success');
    }
    return true;
  }

  /** Wire HTML5 drag-and-drop: blocks and staged chips onto machine lanes. */
  function wireDragAndDrop(root) {
    root.querySelectorAll('[draggable="true"]').forEach((el) => {
      el.addEventListener('dragstart', (e) => {
        const id = el.getAttribute('data-order-id') || '';
        e.dataTransfer?.setData('text/plain', id);
        if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move';
        el.classList.add('mrd-dragging');
      });
      el.addEventListener('dragend', () => {
        el.classList.remove('mrd-dragging');
        root.querySelectorAll('.mrd-drop').forEach((l) => l.classList.remove('mrd-drop'));
      });
    });

    root.querySelectorAll('[data-machine-id]').forEach((lane) => {
      lane.addEventListener('dragover', (e) => {
        e.preventDefault();                       // required to allow a drop
        if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
        lane.classList.add('mrd-drop');
      });
      lane.addEventListener('dragleave', () => lane.classList.remove('mrd-drop'));
      lane.addEventListener('drop', (e) => {
        e.preventDefault();
        lane.classList.remove('mrd-drop');
        const orderId = e.dataTransfer?.getData('text/plain');
        if (orderId) assignToMachine(orderId, lane.getAttribute('data-machine-id'));
      });
    });
  }

  function axisHtml(start, now) {
    let cells = '';
    for (let i = 0; i < HOURS_SPAN; i++) {
      const d = new Date(start.getTime() + i * 3600000);
      const strong = d.getHours() % 6 === 0;
      cells += `<div class="mrd-hour${strong ? ' strong' : ''}">
        <span>${String(d.getHours()).padStart(2, '0')}</span></div>`;
    }
    const nowAt = hoursBetween(start, now);
    return `<div class="mrd-axis">
      <div class="mrd-axis-gutter">${escHtml(tr('dash.mrd_machines', 'Printers'))}</div>
      <div class="mrd-axis-track">
        ${cells}
        <div class="mrd-nowline" id="mrdNowLine" style="--at:${nowAt.toFixed(3)}">
          <span class="mrd-nowflag">${escHtml(tr('dash.mrd_now', 'now'))}</span>
        </div>
      </div>
    </div>`;
  }

  function laneHtml(lane, start, now) {
    const m = lane.machine;
    const blocks = lane.blocks
      .filter((b) => b.from < HOURS_SPAN && (b.from + b.span) > 0)
      .map(blockHtml).join('');
    const running = lane.blocks.some((b) => b.state === 'run');
    return `<div class="mrd-lane" data-machine-id="${escHtml(m.id || '')}">
      <div class="mrd-lane-gutter">
        <span class="mrd-dot${running ? ' on' : ''}" aria-hidden="true"></span>
        <span class="mrd-lane-name">${escHtml(m.name || m.id || '')}</span>
      </div>
      <div class="mrd-lane-track">${blocks || `<span class="mrd-lane-empty">${escHtml(tr('dash.mrd_free', 'free'))}</span>`}</div>
    </div>`;
  }

  function legendHtml() {
    const item = (cls, k, f) => `<span class="mrd-key"><i class="mrd-sw mrd-${cls}"></i>${escHtml(tr(k, f))}</span>`;
    return `<div class="mrd-legend">
      ${item('run', 'dash.mrd_running', 'Printing')}
      ${item('queue', 'dash.mrd_queued', 'Queued')}
      ${item('late', 'dash.mrd_late', 'Overdue')}
      ${item('hold', 'dash.mrd_hold', 'On hold')}
      <span class="mrd-key mrd-note">${escHtml(tr('dash.mrd_proj_note', 'Hatched blocks are projected from the queue — Khayt does not assign start times.'))}</span>
    </div>`;
  }

  function renderDashboard(host) {
    if (!document.body.classList.contains('khayt-meridian')) return false;
    if (!host) return false;

    const now = new Date();
    const orders = scopedOrders();
    const mach = scopedMachines();
    const { lanes, staged, start } = buildLanes(orders, mach, now);

    /* KhaytAttention.compute DOES NOT EXIST, and never has.
     *
     * The module exports `selectAttention`; `compute` is a name nothing
     * defines. The `typeof … && …compute` guard reads as defensive and is
     * really the bug: it made a missing FUNCTION indistinguishable from a
     * missing MODULE, so this passed `null` to the bar on every render and
     * Meridian has shown "All clear" since the day it shipped — with printers
     * offline and orders late.
     *
     * Same shape as Flow's, which that file's own header already records: a
     * guarded call into the attention engine that could never fire.
     *
     * Routed through KhaytDashboardFacts like every other theme, rather than
     * calling the engine directly — test/theme-facts.test.js enforces that, and
     * it is how the nozzle-wear injection reaches all of them at once.
     */
    const attnData = (typeof KhaytDashboardFacts !== 'undefined')
      ? KhaytDashboardFacts.dashboardFacts({
        orders, machines: mach,
        statusCache: (typeof machineStatusCache !== 'undefined' && machineStatusCache) || {},
        settings: (typeof settings !== 'undefined') ? settings : {},
        now: now.getTime(),
        attention: (typeof KhaytAttention !== 'undefined') ? KhaytAttention : undefined,
        nozzleWear: (typeof KhaytNozzleWear !== 'undefined') ? KhaytNozzleWear : undefined,
      }).attn
      : null;
    const attn = (typeof KhaytDashboard !== 'undefined' && KhaytDashboard.buildAttentionBar)
      ? KhaytDashboard.buildAttentionBar(attnData, mach.length) : '';

    const lanesHtml = lanes.length
      ? lanes.map((l) => laneHtml(l, start, now)).join('')
      : `<div class="mrd-empty">${escHtml(tr('dash.no_machines', 'No printers yet'))}</div>`;

    const stagedHtml = staged.length
      ? staged.slice(0, 12).map((s) => `
        <button type="button" class="mrd-chip mrd-${s.state} mrd-movable" draggable="true" data-order-id="${escHtml(s.order.id || '')}"
          title="${escHtml(tr('dash.mrd_drag_hint', 'drag to another printer to reassign'))}">
          <span>${escHtml(s.order.project || s.order.id || '')}</span>
          <span class="mrd-chip-h">${Math.max(0.25, num(s.order.printTime)).toFixed(1)}h</span>
        </button>`).join('')
      : `<span class="mrd-empty-inline">${escHtml(tr('dash.mrd_nothing_staged', 'Nothing waiting on a printer'))}</span>`;

    host.innerHTML = `<div class="mrd-dash">
      ${attn}
      <section class="mrd-sched" aria-label="${escHtml(tr('dash.mrd_schedule', 'Schedule'))}">
        ${axisHtml(start, now)}
        <div class="mrd-lanes">${lanesHtml}</div>
      </section>
      ${legendHtml()}
      <section class="mrd-staging" aria-label="${escHtml(tr('dash.mrd_staging', 'Unassigned work'))}">
        <h3>${escHtml(tr('dash.mrd_staging', 'Unassigned work'))}
          <span class="mrd-staging-sub">${escHtml(tr('dash.mrd_staging_sub', 'no printer chosen yet'))}</span>
        </h3>
        <div class="mrd-chips">${stagedHtml}</div>
      </section>
    </div>`;

    // Clicking a block or chip opens the order the same way every other screen
    // does, rather than this shell growing its own detail view.
    wireDragAndDrop(host);

    host.querySelectorAll('[data-order-id]').forEach((el) => {
      el.addEventListener('click', () => {
        const id = el.getAttribute('data-order-id');
        if (!id) return;
        if (typeof openOrderDetail === 'function') openOrderDetail(id);
        else if (typeof switchTab === 'function') switchTab('queue-tab');
      });
    });

    return true;
  }

  /** Move the now-line without re-rendering the whole schedule (30s tick). */
  function tickNowLine() {
    const line = document.getElementById('mrdNowLine');
    if (!line) return;
    const now = new Date();
    line.style.setProperty('--at', hoursBetween(axisStart(now), now).toFixed(3));
  }

  global.KhaytMeridian = { renderDashboard, tickNowLine, buildLanes };
})(typeof window !== 'undefined' ? window : globalThis);
