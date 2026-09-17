/**
 * Production queue: Kanban board, machine queues, drag-reorder, live printer status.
 */
(function (global) {
// Bed Ready swaps decorative emoji for its bespoke drafting glyphs (evaluated at render time);
/* `_kIco` = icon only, `_kIcoL` adds a trailing space before a label.
 *
 * Khayt used to keep the emoji here, exactly as printfiles.js did: the flavour's
 * own set or nothing, so every Khayt screen fell through to the glyph. It asks
 * the shared line icons first now (renderer/icons.js), which is what that file
 * has always said should happen. `emoji` is the last resort for a name neither
 * set draws, and is optional — a call with no emoji gets an empty string rather
 * than the word "undefined", which is what the old signature did. */
const _kBdr = (typeof document !== 'undefined' && document.documentElement && document.documentElement.dataset.app === 'bedready');
function _kGlyph(name, emoji, size) {
  if (_kBdr && window.BedReadyIcons) return `<span class="br-ico">${window.BedReadyIcons.get(name, size || 15)}</span>`;
  const svg = (typeof window !== 'undefined' && window.KhaytIcons) ? window.KhaytIcons.icon(name, size || 15) : '';
  if (svg) return `<span class="pf-ico" aria-hidden="true">${svg}</span>`;
  return emoji || '';
}
function _kIco(name, emoji, size) { return _kGlyph(name, emoji, size); }
function _kIcoL(name, emoji, size) { const g = _kGlyph(name, emoji, size); return g ? (/^<span/.test(g) ? g : g + ' ') : ''; }
function updateKanbanLiveStatus() {
  const cards = document.querySelectorAll('.printer-live-status[data-machine-id]');
  cards.forEach(el => {
    const mid = el.dataset.machineId;
    const s = machineStatusCache[mid];
    if (!s || s.error) {
      // A printer that moved gets the reason rather than the errno — see the
      // dashboard tile, which reads the same annotation from the same cache.
      const hint = (typeof KhaytPrinterRelocate !== 'undefined')
        ? KhaytPrinterRelocate.relocationHint(s) : null;
      const text = hint ? t('mach.moved_found', { host: hint.to }) : (s && s.error);
      el.innerHTML = text
        ? `<span style="color:var(--${hint ? 'warning' : 'danger'});font-size:10px;">${_kIcoL('alert', '⚠', 12)}${escapeHtml(text)}</span>`
        : '';
      return;
    }
    const pct = Math.min(100, Math.max(0, Math.round(+s.progress || 0)));
    const stateClass = (s.state || '').toLowerCase().includes('print') ? 'printing'
      : (s.state || '').toLowerCase().includes('error') ? 'error' : 'idle';
    const etaStr = s.timeRemaining ? (() => {
      const mins = Math.round(s.timeRemaining / 60);
      return mins > 60 ? `${Math.floor(mins/60)}h ${mins%60}m` : `${mins}m`;
    })() : null;
    el.innerHTML = `
      <div class="live-status-bar"><div class="live-progress" style="width:${pct}%"></div></div>
      <span class="live-state-badge ${escapeHtml(stateClass)}">${escapeHtml(s.state || '')}</span>
      <span style="font-size:10px;color:var(--text-muted);">${pct}%</span>
      ${(s.tempNozzle || s.tempBed) ? `<span class="live-temp">${s.tempNozzle ? Math.round(s.tempNozzle) + '°' : '?'}/${s.tempBed ? Math.round(s.tempBed) + '°' : '?'}</span>` : ''}
      ${etaStr ? `<span class="live-eta">${escapeHtml(t('mach.api_eta'))}: ${escapeHtml(etaStr)}</span>` : ''}`;
  });
}

let _kanbanDraggingId = null;
let _kanbanTimerPrintingCount = -1;

// Manual drag-reorder position is scoped to the column it was set in: an order
// that moves to another column (e.g. a QC-fail requeued to pending) must not keep
// a low position and jump the new column's queue.
function kanbanQueuePos(o, col) {
  return o.queueCol === col && typeof o.queuePos === 'number' ? o.queuePos : 9999;
}

/**
 * Order the cards within one kanban column: priority level first (urgent > high >
 * normal), then the owner's manual drag order.
 *
 * The queuePos tiebreaker applies to EVERY column. It used to apply only to `pending`,
 * while the drop handler wrote queuePos/queueCol for whichever column the card was
 * dropped in — so a drag in the other five columns was persisted to disk and then
 * silently reverted on the next render.
 */
function sortColumnOrders(items, status) {
  return [...(items || [])].sort((a, b) => {
    const pd = prioritySortValue(a) - prioritySortValue(b);
    if (pd !== 0) return pd;
    return kanbanQueuePos(a, status) - kanbanQueuePos(b, status);
  });
}

function setupKanbanDrag() {
  _kanbanDraggingId = null;
  const cols = ['pending', 'on_hold', 'printing', 'post', 'qc', 'completed'];
  cols.forEach(status => {
    const container = $('#list-' + status);
    if (!container) return;
    const cards = container.querySelectorAll('.kanban-card[draggable="true"]');
    cards.forEach(card => {
      card.addEventListener('dragstart', (e) => {
        _kanbanDraggingId = card.dataset.orderId;
        card.classList.add('dragging');
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/plain', _kanbanDraggingId);
      });
      card.addEventListener('dragend', () => {
        card.classList.remove('dragging');
        container.querySelectorAll('.kanban-drop-indicator').forEach(el => el.remove());
        container.querySelectorAll('.kanban-drag-over').forEach(el => el.classList.remove('kanban-drag-over'));
        _kanbanDraggingId = null;
      });
    });

    container.addEventListener('dragover', (e) => {
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      container.querySelectorAll('.kanban-drop-indicator').forEach(el => el.remove());
      container.querySelectorAll('.kanban-drag-over').forEach(el => el.classList.remove('kanban-drag-over'));
      const target = e.target.closest('.kanban-card[draggable="true"]');
      if (!target || target.dataset.orderId === _kanbanDraggingId) return;
      target.classList.add('kanban-drag-over');
      const rect = target.getBoundingClientRect();
      const mid  = rect.top + rect.height / 2;
      const indicator = document.createElement('div');
      indicator.className = 'kanban-drop-indicator';
      if (e.clientY < mid) {
        target.parentNode.insertBefore(indicator, target);
      } else {
        target.parentNode.insertBefore(indicator, target.nextSibling);
      }
    });

    container.addEventListener('dragleave', (e) => {
      if (!container.contains(e.relatedTarget)) {
        container.querySelectorAll('.kanban-drop-indicator').forEach(el => el.remove());
        container.querySelectorAll('.kanban-drag-over').forEach(el => el.classList.remove('kanban-drag-over'));
      }
    });

    container.addEventListener('drop', (e) => {
      e.preventDefault();
      container.querySelectorAll('.kanban-drop-indicator').forEach(el => el.remove());
      container.querySelectorAll('.kanban-drag-over').forEach(el => el.classList.remove('kanban-drag-over'));
      if (!_kanbanDraggingId) return;
      const target = e.target.closest('.kanban-card[draggable="true"]');
      if (!target || target.dataset.orderId === _kanbanDraggingId) return;
      const colOrders = printLog.filter(o => o.status === status)
        .sort((a, b) => kanbanQueuePos(a, status) - kanbanQueuePos(b, status));
      const dragIdx   = colOrders.findIndex(o => o.id === _kanbanDraggingId);
      const targetIdx = colOrders.findIndex(o => o.id === target.dataset.orderId);
      if (dragIdx < 0 || targetIdx < 0) return;
      const rect = target.getBoundingClientRect();
      const insertBefore = e.clientY < rect.top + rect.height / 2;
      const reordered = colOrders.filter(o => o.id !== _kanbanDraggingId);
      const dragged = colOrders[dragIdx];
      const newIdx = reordered.findIndex(o => o.id === target.dataset.orderId);
      const insertAt = insertBefore ? newIdx : newIdx + 1;
      reordered.splice(insertAt, 0, dragged);
      reordered.forEach((o, i) => { o.queuePos = i; o.queueCol = status; });
      saveAll();
      renderKanban();
    });
  });
}

function kanbanUrgencyScore(o) {
  const today0 = new Date(); today0.setHours(0,0,0,0);
  if (!o.dueDate) return 10000 + (+o.printTime || 0);
  const due = new Date(o.dueDate + 'T00:00:00');
  const diff = Math.round((due - today0) / 86400000);
  if (diff < 0)   return diff - 1000;  // overdue: most negative = most urgent
  if (diff === 0) return 0;
  if (diff <= 3)  return diff;
  return diff + (+o.printTime || 0) * 0.01;
}


function studioKanbanProgress(log) {
  if (log.status !== 'printing' || !(+log.printTime > 0)) return null;
  const start = new Date(log.printingStartedAt || log.timerStart || Date.now()).getTime();
  return Math.min(99, Math.round((Date.now() - start) / (+log.printTime * 3600000) * 100));
}

function studioKanbanDuePill(log, status) {
  if (!log.dueDate || status === 'completed' || status === 'delivered') return '';
  const today0 = new Date();
  today0.setHours(0, 0, 0, 0);
  const due = new Date(log.dueDate + 'T00:00:00');
  const diff = Math.round((due - today0) / 86400000);
  let label;
  let urgent = false;
  if (diff < 0) {
    label = t('dash.overdue') || 'Overdue';
    urgent = true;
  } else if (diff === 0) {
    label = t('oe.due_today') || 'Today';
    urgent = true;
  } else if (diff === 1) {
    label = t('kan.due_tomorrow') || 'Tomorrow';
  } else {
    label = due.toLocaleDateString(localeTag(), { month: 'short', day: 'numeric' });
  }
  return `<span class="khayt-due" style="color:${urgent ? 'var(--danger)' : 'var(--text-dim)'};background:${urgent ? 'var(--danger-soft)' : 'var(--surface-2)'}">${_kIcoL('clock', '🕐', 12)}${escapeHtml(label)}</span>`;
}

function renderStudioKanbanCard(b) {
  const {
    log, status, _pl, pausedClass, cardClientAccent, partColourHtml, partsLabel,
    machineBadge, operatorBadge, kanbanSplitBadge, kanbanSubBadge, qcBadge,
    postCheckHtml, resinCheckHtml, timerBadge, etaBadge, actions,
  } = b;

  const useStudio = document.body.classList.contains('bedready-ui');
  // Enthusiast (hobbyist) mode has no commerce — hide client identity, sale price and payment state on cards.
  const biz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : settings.mode !== 'enthusiast';
  const prioColor = { urgent: 'var(--danger)', high: 'var(--warn)', normal: 'var(--text-muted)' }[_pl] || 'var(--text-muted)';
  const client = log.clientId ? clientById(log.clientId) : null;
  const clientLine = biz ? (client ? localName(client) : (log.client || '')) : '';
  const part0 = (log.parts || [])[0];
  let swatchHex = '#6b7280';
  let swatchLabel = part0?.colour || part0?.material || '';
  if (part0?.filamentId) {
    const inv = inventory.find(i => i.id === part0.filamentId);
    if (inv?.color) swatchHex = inv.color;
    if (!swatchLabel) swatchLabel = inv?.material || '';
  }
  const progress = studioKanbanProgress(log);
  const machine = log.machineId ? machines.find(m => m.id === log.machineId) : null;
  const machineName = machine ? machine.name : '';
  const duePill = studioKanbanDuePill(log, status);
  const unassignedPill = !log.machineId && status !== 'completed' && status !== 'delivered'
    ? `<span class="khayt-due" style="color:var(--warn);background:var(--warn-soft)">${escapeHtml(t('dash.unassigned') || 'Unassigned')}</span>`
    : '';
  const priBadge = _pl !== 'normal' ? priorityBadgeHtml(log) + ' ' : '';
  const splitSpan = log._isSplitParent
    ? ' <span class="pill" style="font-size:10px">split</span>' : '';

  const headBlock = useStudio
    ? `
      <div class="row between" style="align-items:center">
        <span class="mono" style="font-size:12px;font-weight:600;color:var(--text-dim)">${escapeHtml(log.id)}</span>
        <span class="row gap6" style="align-items:center">
          <span class="dot" style="background:${prioColor};width:7px;height:7px" title="${escapeHtml(_pl)}"></span>
          <span class="khayt-kcard-grip" aria-hidden="true">⋮⋮</span>
        </span>
      </div>
      <strong class="khayt-kcard-title">${priBadge}${escapeHtml(log.project || log.id)}${splitSpan}</strong>
      ${clientLine ? `<span class="khayt-kcard-client">${escapeHtml(clientLine)}</span>` : ''}
      <div class="row gap8 khayt-kcard-mat" style="margin-top:8px;align-items:center;flex-wrap:wrap">
        ${swatchLabel ? `<span class="khayt-swatch" style="background:${safeCssColor(swatchHex)}"></span><span class="khayt-cname">${escapeHtml(swatchLabel)}</span>` : ''}
        <span class="grow"></span>
        <span class="pill" style="padding:2px 7px;font-size:10.5px">${escapeHtml(partsLabel)}</span>
      </div>`
    : `
      <h4>${priBadge}${escapeHtml(log.project)}${machineBadge}${operatorBadge}${kanbanSplitBadge}${kanbanSubBadge}${qcBadge}${splitSpan}</h4>`;

  const progressBlock = useStudio && progress !== null
    ? `<div class="khayt-kcard-progress">
        <div class="row between" style="margin-bottom:4px">
          <span class="mono" style="font-size:10px;color:var(--text-muted)">${escapeHtml(machineName || '—')}</span>
          <span class="mono" style="font-size:10px;color:var(--ok)">${progress}%</span>
        </div>
        <div class="meter"><i style="width:${progress}%;background:var(--ok)"></i></div>
      </div>`
    : '';

  const metaBlock = useStudio
    ? `<hr class="thread" style="margin:11px 0 9px" />
      <div class="row between" style="align-items:center">
        <span style="font-size:11px;color:var(--text-muted)">${log.printTime || 0} ${escapeHtml(t('common.hours'))}</span>
        ${biz ? `<span class="metric" style="font-size:12.5px">${fmtPrice(log.price)}</span>` : ''}
      </div>
      <div class="row gap6 khayt-kcard-pills" style="margin-top:8px;flex-wrap:wrap">
        ${duePill}${unassignedPill}${biz ? paymentBadge(log) : ''}${timerBadge}${etaBadge}
      </div>
      ${machineBadge || operatorBadge || kanbanSplitBadge || kanbanSubBadge || qcBadge
        ? `<div class="khayt-kcard-badges">${machineBadge}${operatorBadge}${kanbanSplitBadge}${kanbanSubBadge}${qcBadge}</div>` : ''}`
    : `
      <div class="meta">
        ${biz ? `<span class="price">${fmtPrice(log.price)}</span><span>·</span>` : ''}
        <span>${log.printTime} ${escapeHtml(t('common.hours'))}</span><span>·</span>
        <span>${escapeHtml(partsLabel)}</span>
      </div>
      <div class="order-meta-row">${biz ? paymentBadge(log) : ''}${log.dueDate && !KhaytOrderStatus.isFinished(log) ? ' ' + formatDueDateBadge(log.dueDate) : ''}${timerBadge}${etaBadge}</div>`;

  return `
    <div class="kanban-card khayt-kcard${_pl === 'urgent' ? ' kanban-priority-urgent' : _pl === 'high' ? ' kanban-priority-high' : ''}${pausedClass}${cardClientAccent ? ' has-client-accent' : ''}" draggable="true" data-order-id="${log.id}" style="${cardClientAccent}">
      ${headBlock}
      ${!useStudio && partColourHtml ? `<div style="margin-top:2px;">${partColourHtml}</div>` : ''}
      ${useStudio && partColourHtml ? `<div style="margin-top:4px">${partColourHtml}</div>` : ''}
      ${progressBlock}
      ${metaBlock}
      ${(() => { const refs = (log.parts || []).map(p => p.fileRef).filter(Boolean); return refs.length > 0 ? `<div class="part-file-ref" style="margin-top:4px;font-size:11px">${_kIcoL('clip', '📎', 12)}${escapeHtml(refs.join(', '))}</div>` : ''; })()}
      ${status === 'on_hold' && log.holdReason ? `<div style="font-size:11px;color:var(--warning);margin-top:6px">${_kIcoL('pause', '⏸', 12)}${escapeHtml(log.holdReason)}</div>` : ''}
      ${(log.tags && log.tags.length > 0) ? `<div class="kanban-tags">${renderTagChips(log.tags)}</div>` : ''}
      ${postCheckHtml}
      ${resinCheckHtml}
      ${log.parts && log.parts.length > 0 ? `
      <div class="part-status-list">
        ${log.parts.map((p, i) => {
          const ps = p.partStatus || 'pending';
          return `<div class="part-status-row">
            <button type="button" class="part-status-dot ${escapeHtml(ps)}" data-act="toggle-part-status" data-order-id="${log.id}" data-part-index="${i}" title="${escapeHtml(t('kan.parts_status'))}" aria-label="${escapeHtml(t('kan.parts_status'))}: ${escapeHtml(ps)}"></button>
            <span class="part-status-name">${escapeHtml(p.name || 'Part ' + (i + 1))}</span>
            <span class="part-status-badge ${escapeHtml(ps)}">${escapeHtml(t('kan.part_' + ps) || ps)}</span>
          </div>`;
        }).join('')}
      </div>` : ''}
      ${(() => {
        if (!log.parts || log.parts.length <= 1) return '';
        const delivered = log.parts.filter(p => p.delivered).length;
        if (delivered === 0) return '';
        return `<div class="partial-delivery-badge">${escapeHtml(t('ord.parts_delivered', { done: delivered, total: log.parts.length }))}</div>`;
      })()}
      <div class="actions khayt-kcard-actions"><button class="btn small ghost" data-act="order-timeline" data-id="${log.id}" title="${escapeHtml(t('ord.timeline'))}" aria-label="${escapeHtml(t('ord.timeline'))}"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="9"></circle><path d="M12 7v5l3 2"></path></svg></button><button class="btn small ghost" data-act="order-label" data-id="${log.id}" title="${escapeHtml(t('lbl.print_order') || 'Print label')}" aria-label="${escapeHtml(t('lbl.print_order') || 'Print label')}">${_kIco('tag', '🏷')}</button>${actions}</div>
      ${(() => {
        if (status !== 'printing') return '';
        const mid = log.machineId;
        if (!mid) return '';
        const mach = machines.find(m => m.id === mid);
        if (!mach?.printerApi?.type || mach.printerApi.type === 'none') return '';
        return `<div class="printer-live-status" data-machine-id="${escapeHtml(mid)}"></div>`;
      })()}
    </div>`;
}

function studioKanbanDecorateColumns() {
  const stageColors = {
    pending: 'var(--info)', on_hold: 'var(--warn)', printing: 'var(--ok)',
    post: 'var(--accent)', qc: '#a78bfa', completed: 'var(--text-muted)',
    shipped: '#06b6d4', delivered: 'var(--ok)',
  };
  $$('.kanban-col[data-status]').forEach(col => {
    const status = col.dataset.status;
    col.classList.add('khayt-kcol');
    const list = col.querySelector('[id^="list-"]');
    if (list) list.classList.add('khayt-kcol-body');
    let bar = col.querySelector('.khayt-kbar');
    if (!bar) {
      bar = document.createElement('div');
      bar.className = 'khayt-kbar';
      const head = col.querySelector('h3');
      if (head?.nextSibling) col.insertBefore(bar, head.nextSibling);
      else col.prepend(bar);
    }
    bar.style.background = stageColors[status] || 'var(--accent)';
    const countEl = col.querySelector('.count');
    if (countEl && !countEl.classList.contains('khayt-kcount')) {
      countEl.classList.add('khayt-kcount');
    }
  });
}

let _autoSchedRunning = false;

/** Apply auto-assignments silently (used mid-render when autoSchedule is on).
 *  Mutates orders + persists, but does NOT re-render (caller is rendering). */
function applyAutoSchedule() {
  if (typeof KhaytScheduling === 'undefined') return 0;
  const schedulable = printLog.filter(o => o && (o.status === 'pending' || o.status === 'queued') && !o.machineId);
  if (!schedulable.length) return 0;
  const { assignments } = KhaytScheduling.proposeSchedule(machines, schedulable, { now: Date.now() });
  let n = 0;
  for (const a of assignments) { const o = printLog.find(x => x.id === a.orderId); if (o) { o.machineId = a.machineId; n++; } }
  if (n) saveAll();
  return n;
}

/** One-click auto-assign (the 🪄 button): propose + apply immediately, then toast. */
function runAutoSchedule() {
  if (typeof KhaytScheduling === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  const schedulable = printLog.filter(o => o && (o.status === 'pending' || o.status === 'queued') && !o.machineId);
  if (!schedulable.length) { toast(t('sched.none_to_assign') || 'No unassigned orders', 'info'); return; }
  const { assignments, unassignable } = KhaytScheduling.proposeSchedule(machines, schedulable, { now: Date.now() });
  let n = 0;
  for (const a of assignments) { const o = printLog.find(x => x.id === a.orderId); if (o) { o.machineId = a.machineId; n++; } }
  if (n) { saveAll(); renderKanban(); }
  const skipped = (unassignable || []).length;
  toast((t('sched.applied') || 'Assigned') + ' (' + n + ')' + (skipped ? ' · ' + skipped + ' ' + (t('sched.skipped') || 'skipped') : ''), n ? 'success' : 'info');
}

function renderKanban() {
  // Auto-assign mode: silently place queued jobs before drawing the board.
  // The guard prevents re-entrancy (applyAutoSchedule → saveAll never re-renders).
  if (settings.autoSchedule && !_autoSchedRunning) {
    _autoSchedRunning = true;
    try { applyAutoSchedule(); } finally { _autoSchedRunning = false; }
  }
  window.KhaytBedReadyUI?.syncQueueMachinePicker?.();
  // The grouped list is the default board; it renders inside .kanban so the
  // existing delegated actions reach it. Columns stay in the DOM, hidden by CSS.
  window.KhaytIcons?.hydrateIcons?.(document.getElementById('queue-tab'));
  window.KhaytQueueList?.renderQueueList?.();
  window.KhaytQueueList?.syncQueueViewToggle?.();
  renderWaitingList();
  updateWaitingBadge();
  renderLocationScopeBanner?.();
  const locMatch = typeof orderMatchesActiveLocation === 'function' ? orderMatchesActiveLocation : () => true;
  // --- Quotes awaiting approval ---
  const quotes = printLog.filter(o => o.status === 'quote' && locMatch(o));
  const quotesSec = $('#quotesSection');
  // Quotes are commerce — never shown in enthusiast (hobbyist) mode.
  const quotesBiz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : settings.mode !== 'enthusiast';
  if (quotesSec && !quotesBiz) {
    quotesSec.style.display = 'none';
    const ql0 = $('#list-quote'); if (ql0) ql0.innerHTML = '';
  } else if (quotesSec) {
    if (window.KhaytBedReadyUI?.useHandoffScreens?.()) {
      quotesSec.style.display = '';
    } else {
      quotesSec.style.display = quotes.length > 0 ? '' : 'none';
    }
    const qCount = $('#count-quote');
    if (qCount) qCount.textContent = quotes.length;
    const ql = $('#list-quote');
    if (ql) {
      ql.innerHTML = quotes.map(q => {
        const today0 = new Date(); today0.setHours(0,0,0,0);
        const expiresIn = q.quoteExpiresAt
          ? Math.round((new Date(q.quoteExpiresAt + 'T00:00:00') - today0) / 86400000)
          : null;
        const expiryHtml = expiresIn !== null
          ? (expiresIn < 0
            ? `<span class="due-badge overdue">${escapeHtml(t('quote.expired'))}</span>`
            : `<span class="due-badge ${expiresIn <= 2 ? 'due-soon' : 'due-ok'}">${escapeHtml(t('quote.expires_in', { n: expiresIn }))}</span>`)
          : '';
        return `
          <div class="quote-card">
            <div class="quote-main">
              <div class="quote-title">${getPriorityLevel(q) !== 'normal' ? priorityBadgeHtml(q) + ' ' : ''}${escapeHtml(q.project || q.id)}</div>
              <div class="quote-meta">${escapeHtml(q.id)} · ${fmtPrice(q.price)} ${expiryHtml}</div>
            </div>
            <!-- Approving is the answer this row is waiting for. Rejecting sat
                 next to it in red; it is under the rule in the menu now, where
                 it cannot be hit on the way to the other one. -->
            <div class="act quote-actions">
              <button class="btn small success" data-act="approve-quote" data-id="${q.id}">${_kIco('check')}${escapeHtml(t('quote.approve'))}</button>
              <details class="ovf act-end">
                <summary class="btn small ghost icon" role="button" aria-label="${escapeHtml(t('common.more') || 'More actions')}" title="${escapeHtml(t('common.more') || 'More actions')}">${_kIco('more', 16)}</summary>
                <div class="ovf-menu">
                  <button data-act="quote-approval-link" data-id="${q.id}">${_kIco('link')}${escapeHtml(t('ord.quote_approval_link'))}</button>
                  <button data-act="share-quote" data-id="${q.id}">${_kIco('share')}${escapeHtml(t('quote.share_pdf'))}</button>
                  <div class="ovf-sep"></div>
                  <button class="danger" data-act="reject-quote" data-id="${q.id}">${_kIco('cross')}${escapeHtml(t('quote.reject'))}</button>
                </div>
              </details>
            </div>
          </div>`;
      }).join('');
    }
  }

  window.KhaytBedReadyUI?.syncQueueFolds?.();

  // --- Production columns (exclude quotes) ---
  const kanTerm = (kanSearchTerm || '').toLowerCase().trim();
  const cols = { pending: [], on_hold: [], printing: [], post: [], qc: [], completed: [], shipped: [], delivered: [] };
  printLog.filter(o => {
    if (o.status === 'quote') return false;
    if (!locMatch(o)) return false;
    if (kanTerm) {
      const client = o.clientId ? clientById(o.clientId) : null;
      const hay = [o.project, o.id, o.client, client?.nameEn, client?.nameAr, client?.phone].join(' ').toLowerCase();
      if (!hay.includes(kanTerm)) return false;
    }
    if (window.KhaytBedReadyUI?.orderMatchesStudioQueueFilter?.(o) === false) return false;
    return true;
  }).forEach(o => {
    // Which column a job is in is lib/order-status.js's answer now — the rule
    // that "delivered" is a completed job carrying a deliveredAt lived only in
    // this loop, and the Mac app's board, reading `status` alone, filed every
    // handed-over job under Completed.
    const stage = (typeof KhaytOrderStatus !== 'undefined')
      ? KhaytOrderStatus.stageOf(o)
      : (o.status === 'completed' && o.deliveredAt ? 'delivered' : o.status);
    if (cols[stage]) {
      cols[stage].push(o);
    } else if (o.status === 'split') {
      // Split parent orders shown in pending column with a visual indicator
      cols.pending.push({ ...o, _isSplitParent: true });
    }
  });

  // Apply collapse toggles to columns
  $$('.kanban-col[data-status]').forEach(col => {
    const st = col.dataset.status;
    const isCollapsed = kanbanCollapsed.has(st);
    col.classList.toggle('kanban-col-collapsed', isCollapsed);
    // Add/update collapse button in h3
    let collapseBtn = col.querySelector('.kan-col-collapse-btn');
    if (!collapseBtn) {
      collapseBtn = document.createElement('button');
      collapseBtn.className = 'kan-col-collapse-btn btn ghost small';
      // Hardcoded English previously, and the glyph was the accessible name. Both fixed:
      // a translated label, with aria-expanded carrying the state.
      const collapseLabel = t('queue.collapse_column') || 'Collapse / expand column';
      collapseBtn.title = collapseLabel;
      collapseBtn.setAttribute('aria-label', collapseLabel);
      collapseBtn.style.cssText = 'padding:1px 5px;font-size:11px;margin-inline-start:4px;';
      col.querySelector('h3')?.appendChild(collapseBtn);
      collapseBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (kanbanCollapsed.has(st)) kanbanCollapsed.delete(st);
        else kanbanCollapsed.add(st);
        settings.kanbanCollapsed = [...kanbanCollapsed];
        saveAll();
        renderKanban();
      });
    }
    // ▶ is horizontal so it must mirror in RTL; ▼ is vertical and must not.
    collapseBtn.innerHTML = `<span aria-hidden="true"${isCollapsed ? ' class="dir-glyph-inline"' : ''}>${isCollapsed ? '▶' : '▼'}</span>`;
    collapseBtn.setAttribute('aria-expanded', isCollapsed ? 'false' : 'true');
  });

  Object.entries(cols).forEach(([status, items]) => {
    let sorted = sortColumnOrders(items, status);
    if (kanbanSortByPriority) sorted = sorted.slice().sort((a, b) => kanbanUrgencyScore(a) - kanbanUrgencyScore(b));
    const countEl = $('#count-' + status);
    if (countEl) countEl.textContent = sorted.length;

    // WIP limit warning
    const wipLimit = (settings.wipLimits || {})[status] || 0;
    const colEl = $(`.kanban-col[data-status="${status}"]`);
    if (colEl) {
      const overWip = wipLimit > 0 && sorted.length > wipLimit;
      colEl.classList.toggle('kanban-wip-over', overWip);
      const existingWipBadge = colEl.querySelector('.wip-badge');
      if (overWip && !existingWipBadge) {
        const wipBadge = document.createElement('span');
        wipBadge.className = 'wip-badge';
        wipBadge.style.cssText = 'font-size:10.5px;padding:1px 6px;border-radius:10px;background:rgba(220,38,38,0.2);color:var(--danger);font-weight:600;margin-inline-start:4px;';
        wipBadge.textContent = `WIP: ${sorted.length}/${wipLimit}`;
        colEl.querySelector('h3')?.appendChild(wipBadge);
      } else if (overWip && existingWipBadge) {
        existingWipBadge.textContent = `WIP: ${sorted.length}/${wipLimit}`;
      } else if (!overWip && existingWipBadge) {
        existingWipBadge.remove();
      }
      if (document.body.classList.contains('bedready-ui')) {
        let foot = colEl.querySelector('.khayt-kcol-foot');
        if (!foot) {
          foot = document.createElement('div');
          foot.className = 'khayt-kcol-foot';
          colEl.appendChild(foot);
        }
        const totalValFoot = sorted.reduce((s, o) => s + orderNetRevenueBase(o), 0);
        // Enthusiast/maker mode has no commerce — omit the per-column money total.
        const showColMoney = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : settings.mode !== 'enthusiast';
        foot.innerHTML = `<span style="font-size:11px;color:var(--text-muted)">${sorted.length} ${escapeHtml(t('kan.orders') || 'orders')}</span>${showColMoney ? `<span class="metric" style="font-size:11.5px;color:var(--text-dim)">${fmtPrice(totalValFoot)}</span>` : ''}`;
      }
    }

    // Column totals meta line
    const totalHrs = sorted.reduce((s, o) => s + (+o.printTime || 0), 0);
    const totalVal = sorted.reduce((s, o) => s + orderNetRevenueBase(o), 0);
    const metaEl = $('#meta-' + status);
    if (metaEl) {
      const showMetaMoney = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : settings.mode !== 'enthusiast';
      metaEl.textContent = sorted.length > 0
        ? (showMetaMoney ? `${totalHrs.toFixed(1)} ${t('common.hours')} · ${fmtPrice(totalVal)}` : `${totalHrs.toFixed(1)} ${t('common.hours')}`)
        : '';
    }

    const container = $('#list-' + status);
    // Skip card rendering for collapsed columns
    if (kanbanCollapsed.has(status)) {
      container.style.display = 'none';
      return;
    }
    container.style.display = '';
    if (sorted.length === 0) {
      container.innerHTML = `<div class="empty-state" style="padding:20px 8px;">${escapeHtml(t('queue.empty'))}</div>`;
      return;
    }
    container.innerHTML = sorted.map(log => {
      let actions = '';
      // Enthusiast (hobbyist) mode = no commerce: hide customer-notify, invoice, payment and BNPL actions.
      const biz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : settings.mode !== 'enthusiast';
      const notifyBtn = biz ? `<button class="btn small ghost" data-act="wa-quick" data-id="${log.id}" title="${escapeHtml(t('queue.notify'))}" aria-label="${escapeHtml(t('queue.notify'))}"><span aria-hidden="true">📲</span></button>` : '';
      const woBtn = `<button class="btn small ghost" data-act="wo-kanban" data-id="${log.id}" title="${escapeHtml(t('wo.title'))}">WO</button>`;
      // Tracking link button — shown on all active cards that have a client
      const trackBtn = (biz && log.clientId)
        ? `<button class="btn small ghost" data-act="share-tracking-link" data-id="${log.id}" title="${escapeHtml(t('ord.status_page') || 'Share tracking link')}" aria-label="${escapeHtml(t('ord.status_page') || 'Share tracking link')}"><span aria-hidden="true">🔗</span></button>`
        : '';
      const labelBtn = `<button class="btn small ghost" data-act="print-label" data-id="${log.id}" title="${escapeHtml(t('ord.label_btn') || 'Print Label')}" style="padding:2px 6px;font-size:12px;">${_kIco('tag', '🏷')}</button>`;
      // BOM assemblies get an Assembly action (per-part QC + the assembled gate) — it is
      // how such an order becomes completable, so surface it during QC and at completion.
      const isAsm = Array.isArray(log.components) && log.components.length > 0;
      const asmBtn = isAsm ? `<button class="btn small ghost" data-act="assembly" data-id="${log.id}" title="${escapeHtml(t('asm.title') || 'Assembly')}" aria-label="${escapeHtml(t('asm.title') || 'Assembly')}"><span aria-hidden="true">🧩</span></button>` : '';
      // Slice & print: order on a machine with a printer API + an attached model/G-code.
      const printMachine = log.machineId ? machines.find(m => m.id === log.machineId) : null;
      const hasPrintFile = (log.attachedFiles || []).some(f => /\.(stl|3mf|obj|step|stp|gcode|gco|g|nc)$/i.test(f.filename || f.originalName || ''));
      const sliceBtn = (printMachine && printMachine.printerApi && printMachine.printerApi.type && printMachine.printerApi.type !== 'none' && hasPrintFile)
        ? `<button class="btn small ghost" data-act="kanban-slice-print" data-id="${log.id}" title="${escapeHtml(t('slicer.send_title') || 'Slice & print')}">${_kIco('printer', '🖨')}</button>`
        : '';
      // Manual ordering is available in EVERY column, not just pending: dragging works
      // everywhere, so the keyboard-accessible equivalent must too. Without this, the
      // other five columns could only be reordered with a mouse.
      const qIdx = sorted.indexOf(log);
      const queueControls = `<span class="queue-pos-ctrl">
        ${qIdx > 0 ? `<button data-act="q-up" data-id="${log.id}" title="${escapeHtml(t('queue.move_up'))}" aria-label="${escapeHtml(t('queue.move_up'))}"><span aria-hidden="true">▲</span></button>` : ''}
        ${qIdx < sorted.length - 1 ? `<button data-act="q-down" data-id="${log.id}" title="${escapeHtml(t('queue.move_down'))}" aria-label="${escapeHtml(t('queue.move_down'))}"><span aria-hidden="true">▼</span></button>` : ''}
      </span>`;
      if (status === 'pending') {
        // Feature 1: Per-machine ETA — for multi-machine orders use MAX across all machines
        let hrsBefore = 0;
        const logPartMids = [...new Set((log.parts || []).map(p => p.machineId).filter(Boolean))];
        if (logPartMids.length > 1) {
          // Multi-machine: take the max ETA across all machines used
          hrsBefore = Math.max(...logPartMids.map(mid =>
            sorted.slice(0, qIdx)
              .filter(o => o.machineId === mid || (o.parts || []).some(p => p.machineId === mid))
              .reduce((s, o) => s + (+o.printTime || 0), 0)
          ));
        } else if (log.machineId) {
          // Only count prior jobs on the same machine
          hrsBefore = sorted.slice(0, qIdx)
            .filter(o => o.machineId === log.machineId)
            .reduce((s, o) => s + (+o.printTime || 0), 0);
        } else {
          // Unassigned: pool all preceding unassigned jobs
          hrsBefore = sorted.slice(0, qIdx)
            .filter(o => !o.machineId)
            .reduce((s, o) => s + (+o.printTime || 0), 0);
        }
        const estStart = hrsBefore > 0 ? `<span class="est-start-badge">${escapeHtml(t('queue.est_start'))}: +${hrsBefore.toFixed(1)}h</span>` : '';
        const holdBtn = `<button class="btn small ghost" data-act="hold-order" data-id="${log.id}" title="${escapeHtml(t('ord.hold_btn'))}" style="color:var(--warning);">${_kIco('pause', '⏸')}</button>`;
        actions = `${queueControls}<button class="btn small primary" data-act="status" data-id="${log.id}" data-to="printing">${escapeHtml(t('queue.start'))}</button>${holdBtn}${estStart}${sliceBtn}${woBtn}${notifyBtn}${trackBtn}${labelBtn}`;
      }
      if (status === 'on_hold') {
        const holdReason = log.holdReason ? `<div style="font-size:11px; color:var(--warning); margin-top:2px;">${_kIcoL('pause', '⏸', 12)}${escapeHtml(log.holdReason)}</div>` : '';
        const failPhotoBtn = `<button class="btn small ghost" data-act="capture-failure-photo" data-id="${log.id}" title="Capture failure photo">${_kIco('camera', '📷')}</button>`;
        actions = `${queueControls}<button class="btn small primary" data-act="status" data-id="${log.id}" data-to="pending">${escapeHtml(t('ord.unhold_btn'))}</button>${woBtn}${notifyBtn}${labelBtn}${failPhotoBtn}`;
      }
      if (status === 'printing') {
        const wasteBtn = `<button class="btn ghost small" data-act="log-waste-card" data-id="${log.id}" title="${escapeHtml(t('waste.log_from_card'))}">${_kIco('trash', '🗑')}</button>`;
        actions = `${queueControls}<button class="btn small" data-act="status" data-id="${log.id}" data-to="post">${escapeHtml(t('queue.to_post'))}</button>${woBtn}${notifyBtn}${trackBtn}${wasteBtn}${labelBtn}`;
      }
      // Feature 2 (this batch): Post column → QC column instead of directly completing
      if (status === 'post') {
        const wasteBtn = `<button class="btn ghost small" data-act="log-waste-card" data-id="${log.id}" title="${escapeHtml(t('waste.log_from_card'))}">${_kIco('trash', '🗑')}</button>`;
        actions = `${queueControls}<button class="btn small primary" data-act="status" data-id="${log.id}" data-to="qc">${_kIcoL('clipboard', '📋')}${escapeHtml(t('ord.qc'))}</button>${woBtn}${notifyBtn}${trackBtn}${wasteBtn}${labelBtn}`;
      }
      // Feature 2 (this batch): QC column — pass or fail buttons
      if (status === 'qc') {
        actions = `${queueControls}${asmBtn}<button class="btn small success" data-act="qc-pass" data-id="${log.id}">${_kIcoL('check', '✅')}${escapeHtml(t('ord.qc_pass'))}</button>
          <button class="btn small danger" data-act="qc-fail" data-id="${log.id}" style="margin-inline-start:4px;">${_kIcoL('cross', '❌')}${escapeHtml(t('ord.qc_fail'))}</button>${woBtn}${notifyBtn}${trackBtn}${labelBtn}`;
      }
      const bnplBtn = (biz && (settings.bnpl?.tabby?.enabled || settings.bnpl?.tamara?.enabled || settings.bnpl?.stripe?.enabled))
        ? `<button class="btn small ghost" data-act="bnpl-pay" data-id="${log.id}" title="${escapeHtml(t('bnpl.payment_modal'))}" aria-label="${escapeHtml(t('bnpl.payment_modal'))}"><span aria-hidden="true">💳</span></button>`
        : '';
      // Shipping is orthogonal to print status — a "Ship" action off the completed/delivered
      // state (label reflects current shipping status once shipped).
      const shipBtn = biz ? `<button class="btn ghost small" data-act="ship-order" data-id="${log.id}" title="${escapeHtml(t('ship.title') || 'Ship order')}">${_kIco('box', '📦')} ${escapeHtml(log.shippingStatus ? (t('ship.st.' + log.shippingStatus) || log.shippingStatus) : (t('ship.ship') || 'Ship'))}</button>` : '';
      if (status === 'completed') {
        // Out the door but not yet arrived. Shipped is a stamp on a completed
        // job, exactly as delivered is — see lib/order-status.js.
        // Business only, like the Ship action beside it: a shop posting
        // parcels has a use for "in the post"; someone printing for themselves
        // hands the thing over.
        const shippedBtn = biz ? `<button class="btn small" data-act="mark-shipped" data-id="${log.id}">${escapeHtml(t('queue.mark_shipped'))}</button>` : '';
        const deliverBtn = `<button class="btn small success" data-act="mark-delivered" data-id="${log.id}">${escapeHtml(t('queue.mark_delivered'))}</button>`;
        const wasteBtn = `<button class="btn ghost small" data-act="log-waste-card" data-id="${log.id}" title="${escapeHtml(t('waste.log_from_card'))}">${_kIco('trash', '🗑')}</button>`;
        const isPaidCard = payStatus(log) === 'paid';
        const payBtn = (biz && !isPaidCard) ? `<button class="btn small primary" data-act="pay" data-id="${log.id}" title="${escapeHtml(t('pay.mark_paid'))}">💳 ${escapeHtml(t('pay.mark_paid'))}</button>` : '';
        const invoiceBtn = biz ? `<button class="btn small" data-act="invoice" data-id="${log.id}">${escapeHtml(t('queue.invoice'))}</button>` : '';
        actions = `${invoiceBtn}${payBtn}${bnplBtn}${shippedBtn}${deliverBtn}${shipBtn}${asmBtn}${wasteBtn}${notifyBtn}${labelBtn}`;
      }
      if (status === 'shipped') {
        const deliverBtn = `<button class="btn small success" data-act="mark-delivered" data-id="${log.id}">${escapeHtml(t('queue.mark_delivered'))}</button>`;
        const isPaidCard = payStatus(log) === 'paid';
        const payBtn = (biz && !isPaidCard) ? `<button class="btn small primary" data-act="pay" data-id="${log.id}" title="${escapeHtml(t('pay.mark_paid'))}">💳 ${escapeHtml(t('pay.mark_paid'))}</button>` : '';
        const wasteBtn = `<button class="btn ghost small" data-act="log-waste-card" data-id="${log.id}" title="${escapeHtml(t('waste.log_from_card'))}">${_kIco('trash', '🗑')}</button>`;
        const invoiceBtn = biz ? `<button class="btn small" data-act="invoice" data-id="${log.id}">${escapeHtml(t('queue.invoice'))}</button>` : '';
        actions = `${invoiceBtn}${payBtn}${bnplBtn}${deliverBtn}${shipBtn}${wasteBtn}${notifyBtn}${labelBtn}`;
      }
      if (status === 'delivered') {
        const isPaidCard = payStatus(log) === 'paid';
        const payBtn = (biz && !isPaidCard) ? `<button class="btn small primary" data-act="pay" data-id="${log.id}" title="${escapeHtml(t('pay.mark_paid'))}">💳 ${escapeHtml(t('pay.mark_paid'))}</button>` : '';
        const wasteBtn = `<button class="btn ghost small" data-act="log-waste-card" data-id="${log.id}" title="${escapeHtml(t('waste.log_from_card'))}">${_kIco('trash', '🗑')}</button>`;
        const invoiceBtn = biz ? `<button class="btn small" data-act="invoice" data-id="${log.id}">${escapeHtml(t('queue.invoice'))}</button>` : '';
        actions = `${invoiceBtn}${payBtn}${bnplBtn}${shipBtn}${wasteBtn}${notifyBtn}${labelBtn}`;
      }
      const partCount = log.parts ? log.parts.length : 1;
      const partsLabel = partCount === 1 ? t('queue.parts_count_1') : t('queue.parts_count', { n: partCount });
      // Feature 1: Multi-machine badge logic
      const partMachineIds = [...new Set((log.parts || []).map(p => p.machineId).filter(Boolean))];
      const isMultiMachine = partMachineIds.length > 1;
      let machineBadge = '';
      if (isMultiMachine) {
        machineBadge = partMachineIds.map(mid => {
          const m = machines.find(x => x.id === mid);
          return m ? `<span class="machine-badge${m.isOffline ? ' mach-offline' : ''}" style="background:${safeCssColor(m.color)};">${_kIcoL('printer', '🖨', 12)}${escapeHtml(m.name)}</span>` : '';
        }).join('') + `<span class="multi-machine-badge" data-multi-machine="true" style="font-size:10px; background:rgba(91,156,240,0.15); color:var(--primary); padding:1px 6px; border-radius:3px; margin-inline-start:2px;">${escapeHtml(t('kan.multi_machine', { n: partMachineIds.length }))}</span>`;
      } else {
        const machine = log.machineId ? machines.find(m => m.id === log.machineId) : null;
        machineBadge = machine
          ? `<span class="machine-badge${machine.isOffline ? ' mach-offline' : ''}" style="background:${safeCssColor(machine.color)};">${machine.isOffline ? _kIcoL('alert', '⚠', 12) : ''}${escapeHtml(machine.name)}</span>`
          : '';
      }
      let timerBadge = '';
      if (status === 'printing' && (log.timerStart || log.printingStartedAt)) {
        const startIso = log.timerStart || log.printingStartedAt;
        const isPaused = !!log.timerPausedAt;
        const pausedMs = (log.timerPausedMs || 0) + (isPaused ? Date.now() - new Date(log.timerPausedAt).getTime() : 0);
        const elapsed = Math.floor((Date.now() - new Date(startIso).getTime() - pausedMs) / 60000);
        const hrs = Math.floor(elapsed / 60);
        const mins = elapsed % 60;
        const elapsedStr = hrs > 0 ? `${hrs}h ${mins}m` : `${mins}m`;
        const expected = +log.printTime * 60;
        const isOver = !isPaused && elapsed > expected;
        const pauseBtnAct = isPaused ? 'resume-timer' : 'pause-timer';
        const pauseBtnIcon = isPaused ? _kIco('play', '▶') : _kIco('pause', '⏸');
        timerBadge = `<span class="elapsed-timer timer-badge${isOver ? ' timer-over' : ''}${isPaused ? ' timer-paused' : ''}" data-started="${escapeHtml(startIso)}" data-paused-ms="${pausedMs}" data-is-paused="${isPaused}">${isPaused ? _kIcoL('pause', '⏸', 12) : _kIcoL('clock', '⏱', 12)}${escapeHtml(elapsedStr)}${isOver ? ' ' + _kIco('alert', '⚠', 12) : ''}</span><button class="btn small ghost timer-pause-btn" data-act="${pauseBtnAct}" data-id="${log.id}" style="font-size:11px;padding:1px 6px;margin-inline-start:2px;" title="${isPaused ? escapeHtml(t('kan.resume_timer') || 'Resume timer') : escapeHtml(t('kan.pause_timer') || 'Pause timer')}">${pauseBtnIcon}</button>`;
      }
      // Post-processing checklist (shown only in 'post' column)
      let postCheckHtml = '';
      if (status === 'post' && settings.postChecklist && settings.postChecklist.length > 0) {
        const checks = log.postChecks || {};
        const doneCount = settings.postChecklist.filter(ch => checks[ch.id]).length;
        postCheckHtml = `
          <div class="post-checklist">
            <div class="post-checklist-header">
              <span>${escapeHtml(t('post.checklist'))}</span>
              <span class="post-check-count">${doneCount}/${settings.postChecklist.length}</span>
            </div>
            ${settings.postChecklist.map(ch => `
              <label class="post-check-item${checks[ch.id] ? ' done' : ''}">
                <input type="checkbox" class="post-check-cb" data-order="${log.id}" data-check="${ch.id}" ${checks[ch.id] ? 'checked' : ''}>
                <span>${escapeHtml(ch.label)}</span>
              </label>`).join('')}
          </div>`;
      }
      // Feature 3 (new batch): Resin post-processing checklist
      let resinCheckHtml = '';
      if (status === 'post' && log.isResin) {
        const rp = log.resinPost || {};
        resinCheckHtml = `
          <div class="resin-checklist">
            <button type="button" class="resin-step ${rp.washDurationMins ? 'done' : ''}" data-act="resin-log-wash" data-id="${log.id}">
              ${_kIcoL('droplet', '🧴', 13)}${escapeHtml(t('resin.wash'))} ${rp.washDurationMins ? `✓ ${rp.washDurationMins}min` : '— tap to log'}
            </button>
            <button type="button" class="resin-step ${rp.cureDurationMins ? 'done' : ''}" data-act="resin-log-cure" data-id="${log.id}">
              ${_kIcoL('sun', '☀️', 13)}${escapeHtml(t('resin.cure'))} ${rp.cureDurationMins ? `✓ ${rp.cureDurationMins}min` : '— tap to log'}
            </button>
            <button type="button" class="resin-step" data-act="resin-complete" data-id="${log.id}">
              ${_kIcoL('check', '✅', 13)}${escapeHtml(t('resin.complete_post'))}
            </button>
          </div>`;
      }
      // QW3: Est. completion badge for printing cards
      let etaBadge = '';
      if (status === 'printing' && log.printingStartedAt && +log.printTime > 0) {
        // Push the estimated finish out by paused time, matching the elapsed-timer
        // badge — otherwise a paused print shows "Overdue" while the timer reads fine.
        const _isPaused = !!log.timerPausedAt;
        const _pausedMs = (log.timerPausedMs || 0) + (_isPaused ? Date.now() - new Date(log.timerPausedAt).getTime() : 0);
        const etaMs = new Date(log.printingStartedAt).getTime() + (+log.printTime * 3600000) + _pausedMs;
        const nowMs = Date.now();
        const diffH = (etaMs - nowMs) / 3600000;
        const etaDate = new Date(etaMs);
        const timeStr = etaDate.toLocaleTimeString(localeTag(), { hour: '2-digit', minute: '2-digit' });
        let etaLabel;
        if (diffH < -0.5) {
          etaLabel = `<span style="color:var(--danger);">${_kIcoL('alert', '⚠', 12)}${escapeHtml(t('queue.overdue') || 'Overdue')}</span>`;
        } else {
          const today0 = new Date(); today0.setHours(0,0,0,0);
          const etaDay0 = new Date(etaDate); etaDay0.setHours(0,0,0,0);
          const dayDiff = Math.round((etaDay0 - today0) / 86400000);
          const dayLabel = dayDiff === 0 ? 'Today' : dayDiff === 1 ? 'Tomorrow' : etaDate.toLocaleDateString(localeTag(), { weekday: 'short', month: 'short', day: 'numeric' });
          etaLabel = `${escapeHtml(dayLabel)} ${escapeHtml(timeStr)}`;
        }
        etaBadge = `<span class="eta-badge">${_kIcoL('flag', '🏁', 12)}${etaLabel}</span>`;
      }
      const _pl = getPriorityLevel(log);
      const kanbanOperator = log.operatorId ? operators.find(o => o.id === log.operatorId) : null;
      const operatorBadge = kanbanOperator ? `<span class="operator-badge">${_kBdr ? '' : '👤 '}${escapeHtml(kanbanOperator.name)}</span>` : '';
      // Split/sub-order badges
      const kanbanSplitBadge = log.splitInto && log.splitInto.length > 0 ? `<span class="split-badge">${_kBdr ? '' : '🔀 '}${escapeHtml(t('ord.split_badge', { n: log.splitInto.length }))}</span>` : '';
      const kanbanSubBadge = log.parentOrderId
        ? `<span class="sub-order-badge">↳ #${escapeHtml(log.parentOrderId)}</span>`
        : log.reprintOf
          ? `<span class="sub-order-badge">↳ ${escapeHtml(t('qc.reprint_of') || 'reprint of')} #${escapeHtml(log.reprintOf)}</span>`
          : '';
      // QC badge — reflects qcStatus (pass / fail / awaiting), with inspector
      // initials when an inspector is required. Derives from legacy fields too.
      const _qcSt = (typeof qcStatusOf === 'function') ? qcStatusOf(log) : (log.qcPassedAt ? 'pass' : null);
      const _qcInsp = ((settings.qc && settings.qc.requireInspector) && log.inspector && typeof inspectorInitials === 'function')
        ? ' ' + inspectorInitials(log.inspector) : '';
      const qcBadge = _qcSt === 'pass'
        ? `<span class="qc-badge qc-pass">${_kIcoL('check', '✅', 12)}${escapeHtml(t('ord.qc_passed'))}${escapeHtml(_qcInsp)}</span>`
        : _qcSt === 'fail'
          ? `<span class="qc-badge qc-fail">${_kIcoL('alert', '❌', 12)}${escapeHtml(t('qc.failed') || 'QC failed')}${escapeHtml(_qcInsp)}</span>`
          : _qcSt === 'pending'
            ? `<span class="qc-badge qc-await">${_kIcoL('clock', '⏳', 12)}${escapeHtml(t('qc.awaiting') || 'Awaiting QC')}</span>`
            : '';
      // Feature 8 (this batch): paused overlay on pending cards
      const pausedClass = (settings.productionPaused && status === 'pending') ? ' kanban-paused-overlay' : '';
      // Feature 1 (this batch): colour chips on parts
      const partColourHtml = (log.parts || []).filter(p => p.colour).map(p =>
        `<span class="part-colour-chip">${escapeHtml(p.colour)}</span>`
      ).join('');
      // Client accent colour on card left border
      const cardClient = log.clientId ? clientById(log.clientId) : null;
      // The client's colour is DECORATION; the inline-start border is reserved
      // for CONDITION (.kanban-priority-urgent paints a 4px red stripe there).
      // Inline styles beat the stylesheet, so setting the border here silently
      // erased the urgent stripe on any card whose client had a colour set —
      // decoration overwriting a condition, exactly backwards. The colour now
      // rides a custom property and is drawn as a dot on the opposite corner.
      const cardClientAccent = cardClient?.color
        ? `--kcard-client:${safeCssColor(cardClient.color)};`
        : '';
      return renderStudioKanbanCard({
        log, status, _pl, pausedClass, cardClientAccent, partColourHtml, partsLabel,
        machineBadge, operatorBadge, kanbanSplitBadge, kanbanSubBadge, qcBadge,
        postCheckHtml, resinCheckHtml, timerBadge, etaBadge, actions,
      });
    }).join('');
  });

  // Feature 2 (new batch): Populate live status on rendered cards
  updateKanbanLiveStatus();
  updateTabBadges();

  // Feature 3 (new batch): FEP film alert — fire once per threshold crossing, not on every render
  (() => {
    if (typeof KhaytTiers === 'undefined' || !KhaytTiers.isProMode(settings.mode)) return;
    if (!renderKanban._fepAlerted) renderKanban._fepAlerted = new Map();
    const resinCompleted = printLog.filter(o => o.isResin && KhaytOrderStatus.isFinished(o));
    machines.forEach(m => {
      const count = resinCompleted.filter(o => o.machineId === m.id).length;
      const threshold = Math.floor(count / 50) * 50;
      const lastAlerted = renderKanban._fepAlerted.get(m.id) || 0;
      if (threshold > 0 && threshold > lastAlerted) {
        renderKanban._fepAlerted.set(m.id, threshold);
        toast(`${m.name}: ${t('resin.fep_alert')}`, 'warning', 6000);
      }
    });
  })();

  studioKanbanDecorateColumns();

  // Feature 1 (new): Drag-and-drop reorder within kanban columns
  setupKanbanDrag();

  // Feature 8: Live elapsed timer — update badge text every 60 s without full re-render
  const printingNow = printLog.filter(o => o.status === 'printing').length;
  if (printingNow !== _kanbanTimerPrintingCount) {
    _kanbanTimerPrintingCount = printingNow;
    clearInterval(window._elapsedTimerInterval);
    if (printingNow > 0) {
      window._elapsedTimerInterval = setInterval(() => {
        document.querySelectorAll('.elapsed-timer[data-started]').forEach(el => {
          if (el.dataset.isPaused === 'true') return;
          const started = new Date(el.dataset.started);
          const pausedMs = +(el.dataset.pausedMs || 0);
          const totalMs = Date.now() - started - pausedMs;
          const mins = Math.floor(totalMs / 60000);
          const h = Math.floor(mins / 60), m = mins % 60;
          const timeStr = h > 0 ? `${h}h ${m}m` : `${m}m`;
          el.textContent = `${_kBdr ? '' : '⏱ '}${timeStr}`;
        });
      }, 60000);
    }
  }
  if ($('#calendarView')?.style.display !== 'none') renderCalendarView();
  updateNotifBadge();
}

function renderMachineQueues() {
  const container = document.getElementById('machineQueuesContainer');
  if (!container) return;
  if (machines.length === 0) { container.innerHTML = `<div class="empty-state" style="padding:24px;">${escapeHtml(t('mach.empty'))}</div>`; return; }

  const today = localDateStr();
  const machList = typeof machineMatchesActiveLocation === 'function'
    ? machines.filter(machineMatchesActiveLocation)
    : machines;
  if (machList.length === 0) {
    container.innerHTML = `<div class="empty-state" style="padding:24px;">${escapeHtml(t('loc.no_machines'))}</div>`;
    return;
  }

  const locMatch = typeof orderMatchesActiveLocation === 'function' ? orderMatchesActiveLocation : () => true;

  const cards = machList.map(machine => {
    const activeOrder = printLog.find(o => locMatch(o) && o.status === 'printing' && (o.machineId === machine.id || o.machine === machine.name));
    const queue = printLog
      .filter(o => locMatch(o) && o.status === 'pending' && (o.machineId === machine.id || o.machine === machine.name))
      .sort((a, b) => prioritySortValue(a) - prioritySortValue(b))
      .slice(0, 5);

    let progressRingHtml = '';
    if (activeOrder && activeOrder.printingStartedAt && +activeOrder.printTime > 0) {
      const elapsed = (Date.now() - new Date(activeOrder.printingStartedAt).getTime()) / 3600000;
      const pct = Math.min(100, Math.round((elapsed / +activeOrder.printTime) * 100));
      const r = 20, c = 2 * Math.PI * r;
      const dash = (pct / 100) * c;
      progressRingHtml = `
        <svg width="48" height="48" style="flex-shrink:0;" viewBox="0 0 48 48">
          <circle cx="24" cy="24" r="${r}" fill="none" stroke="rgba(255,255,255,0.1)" stroke-width="4"/>
          <circle cx="24" cy="24" r="${r}" fill="none" stroke="var(--primary)" stroke-width="4"
            stroke-dasharray="${dash.toFixed(1)} ${c.toFixed(1)}"
            stroke-linecap="round" transform="rotate(-90 24 24)"/>
          <text x="24" y="28" text-anchor="middle" font-size="10" fill="var(--text)">${pct}%</text>
        </svg>`;
    }

    const activeHtml = activeOrder
      ? `<div style="display:flex;align-items:center;gap:8px;background:rgba(91,156,240,0.12);border-radius:6px;padding:6px 8px;margin-bottom:8px;">
          ${progressRingHtml}
          <div style="flex:1;min-width:0;">
            <div style="font-size:12px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(activeOrder.project || activeOrder.id)}</div>
            <div style="font-size:11px;color:var(--text-muted);">${escapeHtml(activeOrder.material || '')} · ${(+activeOrder.printTime || 0).toFixed(1)}h</div>
          </div>
        </div>`
      : `<div style="font-size:12px;color:var(--text-muted);padding:6px 0;margin-bottom:8px;">— ${t('queue.idle') || 'Idle'} —</div>`;

    const queueHtml = queue.length > 0
      ? queue.map((o, i) => `
          <div style="display:flex;align-items:center;gap:6px;padding:3px 0;border-bottom:1px solid var(--border-soft);">
            <span style="font-size:11px;color:var(--text-muted);min-width:16px;">${i + 1}.</span>
            <span style="font-size:12px;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(o.project || o.id)}</span>
            ${priorityBadgeHtml(o)}
          </div>`).join('')
      : `<div style="font-size:11px;color:var(--text-muted);">${t('queue.no_pending') || 'No pending jobs'}</div>`;

    const machColor = safeCssColor(machine.color, '#5b9cf0');
    return `
      <div style="background:var(--surface-2);border:1px solid var(--border);border-radius:10px;padding:12px;min-width:200px;max-width:280px;flex:1;">
        <div style="display:flex;align-items:center;gap:6px;margin-bottom:10px;">
          <span style="width:10px;height:10px;border-radius:50%;background:${machColor};flex-shrink:0;"></span>
          <strong style="font-size:13px;">${escapeHtml(machine.name)}</strong>
          ${machine.type ? `<span style="font-size:10px;background:rgba(255,255,255,0.08);border-radius:4px;padding:1px 5px;">${escapeHtml(machine.type)}</span>` : ''}
        </div>
        ${activeHtml}
        <div style="font-size:11px;font-weight:600;color:var(--text-muted);margin-bottom:4px;">${escapeHtml(t('machineQueue'))}</div>
        ${queueHtml}
      </div>`;
  }).join('');

  container.innerHTML = `<div style="display:flex;gap:12px;flex-wrap:wrap;padding:12px 0;">${cards}</div>`;
}

  /**
   * Assistive print-farm scheduling: propose machine assignments for unassigned
   * orders via lib/scheduling.js (deterministic), show them for review, and
   * apply only on the operator's confirmation (no auto-moves).
   */
  function openScheduleSuggestions() {
    if (typeof KhaytScheduling === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
    const schedulable = printLog.filter(o => o && (o.status === 'pending' || o.status === 'queued') && !o.machineId);
    if (!schedulable.length) { toast(t('sched.none_to_assign') || 'No unassigned orders', 'info'); return; }
    const { assignments, unassignable } = KhaytScheduling.proposeSchedule(machines, schedulable, { now: Date.now() });
    const oName = (id) => { const o = printLog.find(x => x.id === id) || {}; return o.orderName || o.project || o.item || id; };
    const mName = (id) => { const m = machines.find(x => x.id === id) || {}; return m.name || id; };
    const rows = assignments.map(a => `
      <tr data-oid="${escapeHtml(a.orderId)}" data-mid="${escapeHtml(a.machineId)}">
        <td><strong>${escapeHtml(oName(a.orderId))}</strong></td>
        <td>→ ${escapeHtml(mName(a.machineId))}</td>
        <td style="font-size:11px;color:var(--text-muted);">${escapeHtml(a.reason || '')}</td>
      </tr>`).join('');
    const unrows = unassignable.map(u => `<li>${escapeHtml(oName(u.orderId))} — <span style="color:var(--text-muted);">${escapeHtml(u.reason || '')}</span></li>`).join('');
    openFormModal({
      title: t('sched.suggest_title') || 'Suggested assignments',
      sizeLg: true,
      saveLabel: t('sched.apply') || 'Apply all',
      bodyHtml: `
        ${assignments.length ? `<div class="table-wrap"><table><tbody>${rows}</tbody></table></div>`
          : `<p style="color:var(--text-muted);text-align:center;padding:10px 0;">${escapeHtml(t('sched.none') || 'No assignments proposed')}</p>`}
        ${unrows ? `<p style="margin-top:12px;font-weight:600;">${escapeHtml(t('sched.unassignable') || 'Could not assign')}</p><ul style="font-size:13px;">${unrows}</ul>` : ''}`,
      onSave() {
        let n = 0;
        for (const a of assignments) {
          const o = printLog.find(x => x.id === a.orderId);
          if (o) { o.machineId = a.machineId; n++; }
        }
        if (n) { saveAll(); if (typeof renderKanban === 'function') renderKanban(); }
        toast((t('sched.applied') || 'Assigned') + ' (' + n + ')', 'success');
        return true;
      },
    });
  }

  // Slice (or upload) an order's attached file and start it on its assigned printer.
  async function kanbanSlicePrint(orderId) {
    const order = printLog.find(o => o.id === orderId);
    if (!order) return;
    const machine = order.machineId ? machines.find(m => m.id === order.machineId) : null;
    if (!machine || !(machine.printerApi && machine.printerApi.type && machine.printerApi.type !== 'none')) { toast(t('slicer.no_printer') || 'Assign this order to a machine with a printer API first.', 'error'); return; }
    const file = (order.attachedFiles || []).find(f => /\.(stl|3mf|obj|step|stp|gcode|gco|g|nc)$/i.test(f.filename || f.originalName || ''));
    if (!file) return;
    const isGcode = /\.(gcode|gco|g|nc)$/i.test(file.filename || file.originalName || '');
    const sl = settings.slicer || {};
    if (!isGcode && !sl.path) { toast(t('slicer.no_config'), 'error'); return; }
    const ok = await confirmModal(t(isGcode ? 'slicer.send_gcode_confirm' : 'slicer.start_confirm', { name: machine.name }));
    if (!ok) return;
    toast(t('slicer.sending') || 'Slicing & sending…', 'info');
    try {
      const r = await window.hubAPI.printOrderFile({ orderFile: file.filename, machine, slicerPath: sl.path, args: sl.args, startPrint: true });
      if (!r || !r.ok) throw new Error((r && r.error) || 'failed');
      toast(t('slicer.sent', { name: machine.name }), 'success');
    } catch (e) { toast(`${t('slicer.fail')} ${e.message}`, 'error'); }
  }

  const api = {
    updateKanbanLiveStatus,
    kanbanSlicePrint,
    openScheduleSuggestions,
    runAutoSchedule,
    setupKanbanDrag,
    kanbanUrgencyScore,
    kanbanQueuePos,
    sortColumnOrders,
    studioKanbanProgress,
    studioKanbanDuePill,
    renderStudioKanbanCard,
    studioKanbanDecorateColumns,
    renderKanban,
    renderMachineQueues,
  };

  Object.assign(global, api);
  global.KhaytKanban = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
