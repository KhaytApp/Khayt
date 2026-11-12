/* ============================================================
   Production queue — grouped list view
   ============================================================

   The default board. Kanban stays one click away, but it answers a different
   question: it is built for moving work along, and makes you sweep seven
   columns to answer "what needs me right now". The list groups by the state of
   the work, pulls anything blocked to the top regardless of its status, and
   totals what is outstanding at the foot.

   Two deliberate constraints:

   - It renders INSIDE `.kanban`. Every queue action is delegated from that
     element (see wire-events.js), so rendering here inherits start/hold/advance
     and the rest with no new wiring and no second dispatcher to drift.
   - The kanban columns stay in the DOM, hidden by CSS rather than removed.
     Other code and the e2e suites address `#list-pending` and count
     `.kanban-col`; taking them out would break contracts this view has no
     business touching.

   Grouping and totals are decided by lib/queue-groups.js, which is pure and
   tested. This file only draws.
   ============================================================ */
(function (global) {

  /** Group heading copy. Falls back to English so a missing key never renders a key. */
  const GROUP_LABEL = {
    attention: ['queue.grp_attention', 'Needs attention'],
    running: ['queue.grp_running', 'Running'],
    // Plain text: this fallback is passed through esc() below, so a pre-escaped
    // '&amp;' rendered as the literal characters "&amp;" whenever the locale key
    // was missing.
    finishing: ['queue.grp_finishing', 'Post & QC'],
    queued: ['queue.grp_queued', 'Queued'],
    done: ['queue.grp_done', 'Finished today'],
  };

  /** The one transition each status most wants, mirroring the kanban card's primary button. */
  const PRIMARY_ACTION = {
    pending: { to: 'printing', key: 'queue.start', fallback: 'Start' },
    on_hold: { to: 'pending', key: 'ord.unhold_btn', fallback: 'Resume' },
    printing: { to: 'post', key: 'queue.to_post', fallback: 'Done' },
    post: { to: 'qc', key: 'ord.qc', fallback: 'QC' },
  };

  function tr(key, fallback) {
    const s = (typeof t === 'function') ? t(key) : null;
    return (s && s !== key) ? s : fallback;
  }

  function esc(s) {
    const v = String(s ?? '');
    // Never a pass-through — see renderer/calibration.js for why. The global is
    // always loaded in the app; this branch is written to be safe when it is not.
    return (typeof escapeHtml === 'function') ? escapeHtml(v)
      : v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
         .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function isBiz() {
    if (typeof KhaytTiers !== 'undefined' && typeof settings !== 'undefined') {
      return KhaytTiers.showsBusiness(settings.mode);
    }
    return typeof settings === 'undefined' || settings.mode !== 'enthusiast';
  }

  function money(n) {
    const v = (typeof fmtMoney === 'function') ? fmtMoney(n) : String(Math.round(+n || 0));
    const c = (typeof currencySymbol === 'function') ? currencySymbol() : '';
    return c ? `${v} ${c}` : v;
  }

  function hours(n) {
    return `${(+n || 0).toFixed(1)}${tr('common.hours_short', 'h')}`;
  }

  function clockTime(ms) {
    const d = new Date(ms);
    return d.toLocaleTimeString(localeTag(), { hour: '2-digit', minute: '2-digit' });
  }

  /** Why this row is in the attention group, in words. */
  function reasonText(row) {
    if (!row.reason) return '';
    if (row.reason.kind === 'overdue') {
      return tr('oe.due_overdue', 'Overdue by {n}d').replace('{n}', row.reason.daysLate);
    }
    const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x && x.id === row.reason.machineId);
    return tr('queue.blocked_machine', '{name} stopped').replace('{name}', m ? m.name : tr('mach.offline', 'offline'));
  }

  function rowHtml(row, opts) {
    const o = row.order;
    const machine = o.machineId
      ? (typeof machines !== 'undefined' ? machines : []).find((m) => m && m.id === o.machineId)
      : null;
    const sub = machine ? machine.name : tr('queue.unassigned', 'unassigned');

    const meta = [];
    if (+o.printTime > 0) meta.push(hours(o.printTime));
    if (opts.money && +o.price > 0) meta.push(money(o.price));
    if (row.reason) meta.push(reasonText(row));
    else if (o.dueDate) meta.push(tr('queue.due', 'due {d}').replace('{d}', o.dueDate));

    const act = PRIMARY_ACTION[o.status];
    // Same data-act/data-to contract the kanban card uses, so the existing
    // delegated handler on .kanban drives it.
    // Same emphasis as the kanban card's equivalent button (btn small primary).
    // As a ghost it was the faintest control on the row it is built around.
    const action = act
      ? `<button type="button" class="btn small primary ql-act" data-act="status" data-id="${esc(o.id)}" data-to="${esc(act.to)}">${esc(tr(act.key, act.fallback))}</button>`
      : '';

    const sev = row.reason ? (row.reason.kind === 'overdue' ? 'is-warn' : 'is-crit') : '';
    // The row paints a hover highlight; it now honours it by opening the order.
    return `<div class="ql-row ${sev} is-openable" data-order-id="${esc(o.id)}" tabindex="0" role="button">
      <span class="ql-stripe" aria-hidden="true"></span>
      <span class="ql-name">${esc(o.project || jobRef(o))} <em>— ${esc(sub)}</em></span>
      <span class="ql-meta">${esc(meta.join(' · '))}</span>
      <span class="ql-state">${esc(tr('queue.' + o.status, o.status))}</span>
      <span class="ql-actions">${action}</span>
    </div>`;
  }

  function groupHtml(group, opts) {
    if (!group.items.length && group.key !== 'attention') return '';
    if (!group.items.length) return '';
    const [key, fallback] = GROUP_LABEL[group.key] || [null, group.key];
    const agg = group.aggregate;
    const bits = [String(agg.count)];
    if (agg.hours > 0) bits.push(hours(agg.hours));
    if (opts.money && agg.money > 0) bits.push(money(agg.money));
    // The head is a real button. `is-collapsed` used to be rendered from
    // lib/queue-groups.js (where `done` is collapsed: true) but nothing in the
    // app ever toggled it — so "Finished today" showed a count and totals that
    // could never be opened, with no affordance and nothing for a screen reader.
    const collapsed = !!group.collapsed;
    return `<section class="ql-group ql-group-${esc(group.key)}${collapsed ? ' is-collapsed' : ''}">
      <h3 class="ql-group-h">
        <button type="button" class="ql-group-head" data-act="ql-toggle-group"
                aria-expanded="${collapsed ? 'false' : 'true'}">
          <span class="ql-group-chev" aria-hidden="true">▾</span>
          <span>${esc(tr(key, fallback))}</span>
          <span class="ql-group-agg">${esc(bits.join(' · '))}</span>
        </button>
      </h3>
      <div class="ql-rows">${group.items.map((r) => rowHtml(r, opts)).join('')}</div>
    </section>`;
  }

  function footerHtml(footer, opts) {
    const bits = [];
    bits.push(`<span>${esc(tr('queue.total', 'Queue total'))}</span>`);
    bits.push(`<span><b>${esc(hours(footer.hours))}</b></span>`);
    if (opts.money && footer.money > 0) bits.push(`<span><b>${esc(money(footer.money))}</b></span>`);
    // Null means something is idle right now, which is a better answer than a time.
    bits.push(footer.nextFreeAt
      ? `<span>${esc(tr('queue.next_free', 'Next machine free {t}').replace('{t}', clockTime(footer.nextFreeAt)))}</span>`
      : `<span>${esc(tr('queue.machine_free_now', 'A machine is free now'))}</span>`);
    return `<div class="ql-foot">${bits.join('')}</div>`;
  }

  /** Per-group collapse state, remembered in settings so it survives a reload. */
  function collapsePrefs() {
    if (typeof settings === 'undefined' || !settings) return {};
    const p = settings.queueGroupCollapsed;
    return (p && typeof p === 'object') ? p : {};
  }

  function rememberCollapse(key, collapsed) {
    if (typeof settings === 'undefined' || !settings || !key) return;
    if (!settings.queueGroupCollapsed || typeof settings.queueGroupCollapsed !== 'object') {
      settings.queueGroupCollapsed = {};
    }
    settings.queueGroupCollapsed[key] = !!collapsed;
    if (typeof saveAll === 'function') saveAll();
  }

  /** True when the grouped list is the active board. Kanban is opt-in per shop. */
  function isListView() {
    if (typeof settings === 'undefined') return false;
    // Until a shop works the toggle, the board wins whatever is on disk. Every
    // install predating this carries queueView: 'list' because that was the
    // default, not because anyone asked for it — honouring that would keep the
    // advertised feature hidden from exactly the people already using Khayt.
    if (!settings.queueViewChosen) return false;
    return (settings.queueView || 'kanban') !== 'kanban';
  }

  function renderQueueList() {
    const board = document.querySelector('.kanban');
    if (!board) return false;

    let host = document.getElementById('queueListView');
    if (!host) {
      host = document.createElement('div');
      host.id = 'queueListView';
      board.insertBefore(host, board.firstChild);
      // Delegated once on the host, which survives every innerHTML rewrite, so
      // re-rendering the list cannot stack duplicate listeners.
      // Open the order behind a row — but never when the click landed on a
      // control inside it, or advancing a job would also open the editor.
      host.addEventListener('click', (e) => {
        if (!e.target.closest('button, a, input, select, textarea')) {
          const row = e.target.closest('.ql-row.is-openable');
          if (row && host.contains(row) && typeof openOrderEditor === 'function') {
            openOrderEditor(row.dataset.orderId);
            return;
          }
        }
        const btn = e.target.closest('[data-act="ql-toggle-group"]');
        if (!btn || !host.contains(btn)) return;
        // The queue action dispatcher lives on .kanban and would also see this
        // click; it has no 'ql-toggle-group' case, but stopping here keeps the
        // two dispatchers from ever fighting over the same event.
        e.stopPropagation();
        const section = btn.closest('.ql-group');
        if (!section) return;
        const nowCollapsed = section.classList.toggle('is-collapsed');
        btn.setAttribute('aria-expanded', nowCollapsed ? 'false' : 'true');
        const key = [...section.classList].find((c) => c.startsWith('ql-group-') && c !== 'ql-group-head');
        if (key) rememberCollapse(key.replace('ql-group-', ''), nowCollapsed);
      });
      host.addEventListener('keydown', (e) => {
        if (e.key !== 'Enter' && e.key !== ' ') return;
        const row = e.target.closest('.ql-row.is-openable');
        if (!row || !host.contains(row)) return;
        e.preventDefault();
        if (typeof openOrderEditor === 'function') openOrderEditor(row.dataset.orderId);
      });
    }

    board.classList.toggle('queue-list-mode', isListView());
    // An empty host is still a grid item: left in the board it took the first
    // column, so Pending started one column in and the stages wrapped to two
    // rows even at 1920 px. Hidden, it takes nothing.
    host.hidden = !isListView();
    if (!isListView()) { host.innerHTML = ''; return false; }

    const locMatch = (typeof orderMatchesActiveLocation === 'function') ? orderMatchesActiveLocation : () => true;
    const orders = (typeof printLog !== 'undefined' ? printLog : []).filter(locMatch);
    const machMatch = (typeof machineMatchesActiveLocation === 'function') ? machineMatchesActiveLocation : () => true;
    const mach = (typeof machines !== 'undefined' ? machines : []).filter(machMatch);
    const opts = { money: isBiz() };

    const res = (typeof KhaytQueueGroups !== 'undefined')
      ? KhaytQueueGroups.groupQueue({
        orders,
        machines: mach,
        statusCache: (typeof machineStatusCache !== 'undefined' ? machineStatusCache : {}),
        now: Date.now(),
        money: opts.money,
        revenueOf: (typeof orderNetRevenueBase === 'function') ? orderNetRevenueBase : undefined,
      })
      : null;
    if (!res) { host.innerHTML = ''; return false; }

    // Honour the shop's own collapse choices over the defaults from
    // lib/queue-groups.js, so a group you opened stays open across re-renders.
    const prefs = collapsePrefs();
    for (const g of res.groups) {
      if (Object.prototype.hasOwnProperty.call(prefs, g.key)) g.collapsed = !!prefs[g.key];
    }
    const body = res.groups.map((g) => groupHtml(g, opts)).join('');
    host.innerHTML = body
      ? body + footerHtml(res.footer, opts)
      : `<p class="ql-empty">${esc(tr('queue.empty', 'Nothing in the queue.'))}</p>`;
    return true;
  }

  /** Flip the board and remember it. */
  function setQueueView(view) {
    if (typeof settings === 'undefined') return;
    settings.queueView = (view === 'kanban') ? 'kanban' : 'list';
    // Working the toggle IS the choice. From here the shop's answer outranks
    // the product default, in both directions and permanently.
    settings.queueViewChosen = true;
    if (typeof saveAll === 'function') saveAll();
    if (typeof renderKanban === 'function') renderKanban();
    syncQueueViewToggle();
  }

  /**
   * Reflect the current view in the segmented control.
   *
   * This used to be ONE button that renamed itself — reading "Board view" while
   * you were in the list, so the label was the destination on one press and the
   * origin on the next, and nothing on screen said which of the two you were
   * looking at. Two halves with a pressed state say it without being read.
   *
   * It also set `textContent`, which would now delete the icon inside the
   * button. Only the state is touched here; the labels are markup and stay in
   * the markup, where the translator can see them.
   */
  function syncQueueViewToggle() {
    const board = document.getElementById('btnQueueView');
    const list = document.getElementById('btnQueueViewList');
    if (!board && !list) return;
    const onList = isListView();
    if (board) {
      board.setAttribute('aria-pressed', String(!onList));
      board.title = tr('queue.view_kanban_hint', 'Switch to the kanban board');
    }
    if (list) {
      list.setAttribute('aria-pressed', String(onList));
      list.title = tr('queue.view_list_hint', 'Switch to the grouped list');
    }
  }

  const api = { renderQueueList, setQueueView, isListView, syncQueueViewToggle };
  Object.assign(global, api);
  global.KhaytQueueList = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;

})(typeof globalThis !== 'undefined' ? globalThis : window);
