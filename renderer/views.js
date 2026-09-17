/**
 * Alternate views: schedule timeline, calendar, kiosk, portfolio, post-process presets.
 */
let portfolioSearchTerm = '';

(function (global) {
function renderScheduleView() {
  const el = $('#scheduleView');
  if (!el) return;
  const activeOrders = printLog.filter(o => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote');
  if (activeOrders.length === 0) {
    el.innerHTML = `<div class="card"><p style="color:var(--text-muted); font-size:13px; text-align:center; padding:20px 0;">${escapeHtml(t('queue.empty'))}</p></div>`;
    return;
  }

  // Group orders by machine
  const machineMap = {};
  activeOrders.forEach(o => {
    const mid = o.machineId || '__unassigned__';
    if (!machineMap[mid]) machineMap[mid] = [];
    machineMap[mid].push(o);
  });

  // Completion ETAs + due-date risk from queue depth × working hours/day.
  const etaById = {}; const readyByMachine = {};
  if (typeof KhaytSchedule !== 'undefined') {
    const dailyHrs = (typeof avgDailyWorkingHours === 'function' && avgDailyWorkingHours() > 0) ? avgDailyWorkingHours() : 8;
    const sched = KhaytSchedule.computeSchedule({
      startDate: localDateStr(),
      dailyHours: dailyHrs,
      jobs: activeOrders.map(o => ({ id: o.id, machineId: o.machineId || '', hours: +o.printTime || 0, dueDate: o.dueDate || '', project: o.project || '', status: o.status })),
    });
    for (const m of sched.machines) {
      readyByMachine[m.machineId || '__unassigned__'] = { readyDate: m.readyDate, lateCount: m.lateCount };
      for (const j of m.jobs) etaById[j.id] = j;
    }
  }
  const fmtDay = (iso) => { try { return new Date(iso + 'T00:00:00').toLocaleDateString(localeTag(), { month: 'short', day: 'numeric' }); } catch (e) { return iso; } };

  // Determine time horizon (max 48h or sum of queued)
  const totalHours = Math.max(48, activeOrders.reduce((s, o) => s + (+o.printTime || 0), 0));
  const tickMarks = [0, 4, 8, 12, 16, 24, 32, 48].filter(h => h <= totalHours + 4);

  // Build axis HTML
  const axisHtml = `<div class="schedule-axis">
    ${tickMarks.map(h => {
      const pct = (h / totalHours) * 100;
      return `<div class="schedule-axis-tick" style="position:absolute; left:${pct.toFixed(1)}%; transform:translateX(-50%);">${h}h</div>`;
    }).join('')}
  </div>`;

  // Build rows
  const rowsHtml = Object.entries(machineMap).map(([mid, orders]) => {
    const machine = machines.find(m => m.id === mid);
    const label = machine ? machine.name : t('dash.unassigned');
    const dotColor = machine ? machine.color : '#888';
    let offset = 0;
    const blocks = orders.map(o => {
      const pct = ((+o.printTime || 0) / totalHours) * 100;
      const eta = etaById[o.id];
      const late = eta && eta.late;
      const etaTip = eta ? ` · ${t('sched.ready_by') || 'ready'} ${fmtDay(eta.etaDate)}${late ? ' ⚠' : ''}` : '';
      const blockHtml = `<div class="schedule-block status-${escapeHtml(o.status)}"
        style="flex: 0 0 ${pct.toFixed(2)}%; background:${escapeHtml(dotColor)};${late ? 'outline:2px solid #f87171;outline-offset:-2px;' : ''}"
        title="${escapeHtml((o.invoiceNum || o.id) + ' · ' + (o.project || '') + etaTip)}">
        ${pct > 5 ? escapeHtml((o.invoiceNum || o.id).slice(-6)) : ''}
      </div>`;
      offset += pct;
      return blockHtml;
    }).join('');
    const summary = readyByMachine[mid];
    const readyHtml = summary
      ? `<span style="font-size:10.5px;color:var(--text-muted);">${escapeHtml(t('sched.ready_by') || 'ready')} ${escapeHtml(fmtDay(summary.readyDate))}</span>`
        + (summary.lateCount ? ` <span style="font-size:10px;color:#f87171;font-weight:600;">${summary.lateCount} ${escapeHtml(t('sched.late') || 'late')}</span>` : '')
      : '';
    return `<div class="schedule-machine-row">
      <div class="schedule-machine-label">
        <span style="display:inline-block; width:8px; height:8px; border-radius:50%; background:${escapeHtml(dotColor)}; flex-shrink:0;"></span>
        <span style="display:flex;flex-direction:column;line-height:1.25;">${escapeHtml(label)}${readyHtml ? '<span>' + readyHtml + '</span>' : ''}</span>
      </div>
      <div class="schedule-track">${blocks}</div>
    </div>`;
  }).join('');

  el.innerHTML = `<div class="card">
    <div style="display:flex; align-items:center; gap:10px; margin-bottom:10px;">
      <h3 class="card-head" style="margin:0; flex:1;"><span class="swatch"></span>${escapeHtml(t('kan.schedule_view'))}</h3>
      <span style="font-size:11.5px; color:var(--text-muted);">${escapeHtml(t('kan.schedule_now'))}: ${new Date().toLocaleTimeString(localeTag())}</span>
    </div>
    <div class="schedule-view" style="position:relative; padding-top:22px;">
      <div style="position:relative; height:22px; margin-inline-start:130px; margin-bottom:4px;">
        ${tickMarks.map(h => {
          const pct = (h / totalHours) * 100;
          return `<div style="position:absolute; inset-inline-start:${pct.toFixed(1)}%; transform:translateX(-50%); font-size:10.5px; color:var(--text-muted);">${h}h</div>`;
        }).join('')}
      </div>
      <div style="position:absolute; inset-inline-start:130px; top:22px; bottom:0; width:2px; background:var(--primary); opacity:0.6; z-index:2; pointer-events:none;">
        <span style="position:absolute; top:-18px; inset-inline-start:50%; transform:translateX(-50%); font-size:9.5px; font-weight:700; color:var(--primary); white-space:nowrap; background:var(--bg-card); padding:0 3px;">▼ NOW</span>
      </div>
      ${rowsHtml}
    </div>
  </div>`;
}

/* ============================================================
   Calendar view — monthly grid by due date
   ============================================================ */
let calendarViewMonth = null; // null = current month

/**
 * Reset the calendar to the current month. Exported because wire-events.js used to do
 * `calendarViewMonth = null` directly — but that binding is private to this file's IIFE,
 * so in sloppy mode the assignment created a NEW global and this variable never changed:
 * reopening the calendar kept whatever month the user had paged to.
 */
function resetCalendarMonth() { calendarViewMonth = null; }

function renderCalendarView() {
  const el = $('#calendarView');
  if (!el) return;

  const now = new Date();
  if (!calendarViewMonth) calendarViewMonth = { y: now.getFullYear(), m: now.getMonth() };
  const { y, m } = calendarViewMonth;

  const firstDay = new Date(y, m, 1);
  const lastDay  = new Date(y, m + 1, 0);
  const monthStr = firstDay.toLocaleDateString(localeTag(), { year: 'numeric', month: 'long' });

  // Build a map: "YYYY-MM-DD" -> orders[]
  const dayMap = {};
  printLog.forEach(o => {
    if (!o.dueDate || KhaytOrderStatus.isFinished(o) || o.status === 'quote') return;
    const d = (o.dueDate || '').slice(0, 10);
    if (!dayMap[d]) dayMap[d] = [];
    dayMap[d].push(o);
  });

  // Day-of-week headers, Sun-first to match getDay(). 2023-01-01 was a Sunday,
  // so index 0 is Sunday in whatever language is active.
  const dayFmt = new Intl.DateTimeFormat(localeTag(), { weekday: 'short' });
  const dayNames = Array.from({ length: 7 }, (_, i) => dayFmt.format(new Date(Date.UTC(2023, 0, i + 1))));
  const headerHtml = dayNames.map(d => `<div class="cal-day-header">${d}</div>`).join('');

  // Calendar cells: pad before first day
  const startDow = firstDay.getDay(); // 0=Sun
  let cells = '';
  for (let i = 0; i < startDow; i++) cells += `<div class="cal-cell cal-empty"></div>`;

  const todayStr = localDateStr(now);

  for (let d = 1; d <= lastDay.getDate(); d++) {
    const dateStr = `${y}-${String(m + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    const isToday = dateStr === todayStr;
    const orders  = dayMap[dateStr] || [];

    const chips = orders.slice(0, 3).map(o => {
      const mc = machines.find(x => x.id === o.machineId);
      const bg = mc?.color ? mc.color : (
        o.status === 'printing' ? '#5b9cf0' :
        o.status === 'post'     ? '#a78bfa' :
        o.status === 'qc'       ? '#f59e0b' :
                                  '#6b7793'
      );
      // The chip text is the project name; machine identity and status were carried by the
      // BACKGROUND COLOUR ALONE — invisible to anyone who cannot distinguish those colours
      // and to a screen reader. Put both into the tooltip and the accessible name.
      const who = mc ? (mc.name || mc.id) : '';
      const detail = [o.project || o.id, who, o.status].filter(Boolean).join(' · ');
      return `<div class="cal-chip" style="background:${escapeHtml(bg)};" title="${escapeHtml(detail)}" aria-label="${escapeHtml(detail)}">${escapeHtml((o.project || o.id).slice(0, 18))}</div>`;
    }).join('');

    const overflow = orders.length > 3 ? `<div class="cal-chip-more">+${orders.length - 3}</div>` : '';

    // A <div> with a click handler is invisible to the keyboard; the day-detail popup
    // was mouse-only. role+tabindex+key handling makes each day a real control.
    cells += `<div class="cal-cell${isToday ? ' cal-today' : ''}" data-date="${dateStr}"
      role="button" tabindex="0" aria-label="${escapeHtml(dateStr)}">
      <div class="cal-day-num" aria-hidden="true">${d}</div>
      ${chips}${overflow}
    </div>`;
  }

  el.innerHTML = `<div class="card" style="padding:12px;">
    <div style="display:flex; align-items:center; gap:10px; margin-bottom:12px;">
      <button class="btn small ghost dir-glyph" id="calPrev" aria-label="${escapeHtml(t('cal.prev_month'))}" title="${escapeHtml(t('cal.prev_month'))}"><span aria-hidden="true">‹</span></button>
      <h3 style="margin:0; flex:1; text-align:center; font-size:14px;">${escapeHtml(monthStr)}</h3>
      <button class="btn small ghost dir-glyph" id="calNext" aria-label="${escapeHtml(t('cal.next_month'))}" title="${escapeHtml(t('cal.next_month'))}"><span aria-hidden="true">›</span></button>
    </div>
    <div class="cal-grid">
      ${headerHtml}
      ${cells}
    </div>
  </div>`;

  el.querySelector('#calPrev')?.addEventListener('click', () => {
    calendarViewMonth = { y: m === 0 ? y - 1 : y, m: m === 0 ? 11 : m - 1 };
    renderCalendarView();
  });
  el.querySelector('#calNext')?.addEventListener('click', () => {
    calendarViewMonth = { y: m === 11 ? y + 1 : y, m: m === 11 ? 0 : m + 1 };
    renderCalendarView();
  });

  // Click a day cell to open a popup showing orders for that day
  el.querySelectorAll('.cal-cell[data-date]').forEach(cell => {
    cell.addEventListener('click', () => {
      const date = cell.dataset.date;
      const orders = dayMap[date] || [];
      if (orders.length === 0) return;
      const body = orders.map(o => {
        const mc = machines.find(x => x.id === o.machineId);
        return `<div style="padding:8px 0; border-bottom:1px solid var(--border-soft); font-size:13px;">
          <strong>${escapeHtml(o.project || o.id)}</strong>
          <span style="margin-inline-start:8px; font-size:11px; color:var(--text-muted);">${escapeHtml(o.status)}</span>
          ${mc ? `<span style="margin-inline-start:6px; font-size:11px; color:var(--primary);">🖨 ${escapeHtml(mc.name)}</span>` : ''}
        </div>`;
      }).join('');
      openFormModal({
        title: `📆 ${escapeHtml(date)}`,
        noSave: true,
        bodyHtml: `<div>${body}</div>`
      });
    });
  });
}

/* ── Kiosk view ─────────────────────────────────────────── */
function renderKioskView() {
  const el = $('#kioskView');
  if (!el) return;

  // Build a map: machineId → current active order
  const activeMachines = machines.filter(m => !m.deleted);
  const activeOrders = printLog.filter(o => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote');

  const cards = activeMachines.map(m => {
    const job = activeOrders.filter(o => o.machineId === m.id)
      .sort((a, b) => {
        const rankOf = s => ({ printing: 0, post: 1, qc: 2, pending: 3, on_hold: 4 })[s] ?? 5;
        return rankOf(a.status) - rankOf(b.status);
      })[0] || null;

    const statusColors = {
      printing: '#22c55e',
      post:     '#f59e0b',
      qc:       '#3b82f6',
      pending:  '#6b7280',
      on_hold:  '#ef4444',
    };
    const idleColor = '#374151';

    const borderColor = job ? (statusColors[job.status] || '#6b7280') : idleColor;

    let progressHtml = '';
    if (job) {
      const printHrs = +job.printTime || 0;
      const startedAt = job.printingStartedAt ? new Date(job.printingStartedAt).getTime() : null;
      let pct = 0;
      let etaStr = '';
      if (printHrs > 0 && startedAt) {
        const elapsed = (Date.now() - startedAt) / 3600000;
        pct = Math.min(100, Math.round((elapsed / printHrs) * 100));
        const remaining = Math.max(0, printHrs - elapsed);
        if (remaining > 0) {
          const h = Math.floor(remaining);
          const min = Math.round((remaining - h) * 60);
          etaStr = h > 0 ? `${h}h ${min}m` : `${min}m`;
        } else {
          etaStr = t('kiosk.done') || 'Done';
        }
      } else if (printHrs > 0) {
        etaStr = `~${printHrs}h total`;
      }

      // Enthusiast (hobbyist) mode has no clients — don't show a client name on kiosk cards.
      const kioskBiz = (typeof KhaytTiers !== 'undefined') ? KhaytTiers.showsBusiness(settings.mode) : settings.mode !== 'enthusiast';
      const client = (kioskBiz && job.clientId) ? clients.find(c => c.id === job.clientId) : null;
      const clientName = kioskBiz ? (client ? localName(client) : (job.client || '')) : '';

      progressHtml = `
        <div class="kiosk-job">
          <div class="kiosk-job-name">${escapeHtml(job.project || t('inv.walk_in'))}</div>
          ${clientName ? `<div class="kiosk-job-client">👤 ${escapeHtml(clientName)}</div>` : ''}
          <div class="kiosk-job-status">
            <span class="badge ${escapeHtml(job.status)}" style="font-size:13px;padding:3px 10px;">${escapeHtml(t('queue.' + job.status))}</span>
          </div>
          ${pct > 0 ? `
          <div class="kiosk-progress-wrap">
            <div class="kiosk-progress-bar" style="width:${pct}%;background:${borderColor};"></div>
          </div>
          <div class="kiosk-eta">${pct}% ${etaStr ? `· ETA ${escapeHtml(etaStr)}` : ''}</div>` : ''}
          ${job.dueDate ? `<div class="kiosk-due">📅 ${escapeHtml(job.dueDate)}</div>` : ''}
        </div>`;
    } else {
      progressHtml = `<div class="kiosk-idle">${escapeHtml(t('kiosk.idle') || 'Idle')}</div>`;
    }

    return `
      <div class="kiosk-card" style="border-color:${borderColor};">
        <div class="kiosk-machine-name">${escapeHtml(m.name || m.model || m.id)}</div>
        ${m.model && m.name !== m.model ? `<div class="kiosk-machine-model">${escapeHtml(m.model)}</div>` : ''}
        ${progressHtml}
      </div>`;
  });

  if (cards.length === 0) {
    el.innerHTML = `<p style="text-align:center;color:var(--text-muted);padding:32px;">${escapeHtml(t('kiosk.no_machines') || 'No machines configured.')}</p>`;
    return;
  }

  el.innerHTML = `<div class="kiosk-grid">${cards.join('')}</div>`;
}

/* ============================================================
   Feature 3: Spool switch modal
   ============================================================ */

/* ============================================================
   Feature 5: Throughput heatmap
   ============================================================ */

/* ============================================================
   Feature 7: Invoice numbering settings UI helpers
   ============================================================ */
function renderPostProcessPresetsList() {
  const el = $('#postProcessPresetsList');
  if (!el) return;
  const presets = settings.postProcessPresets || [];
  if (presets.length === 0) {
    el.innerHTML = `<p style="font-size:12px;color:var(--text-muted);margin:0 0 6px;">${escapeHtml(t('set.no_presets') || 'No presets yet.')}</p>`;
  } else {
    el.innerHTML = presets.map((p, i) => `
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:5px;">
        <span style="flex:1;font-size:13px;">${escapeHtml(p.name)}</span>
        <span style="font-size:13px;color:var(--success);min-width:60px;text-align:right;">${fmtMoney(p.amount)}</span>
        <button class="btn danger small" data-pp-del="${i}" aria-label="${escapeHtml(`${t('common.remove') || 'Remove'} ${p.name}`)}" title="${escapeHtml(`${t('common.remove') || 'Remove'} ${p.name}`)}">×</button>
      </div>`).join('');
    el.querySelectorAll('[data-pp-del]').forEach(btn => {
      btn.addEventListener('click', () => {
        settings.postProcessPresets.splice(+btn.dataset.ppDel, 1);
        saveAll();
        renderPostProcessPresetsList();
      });
    });
  }
  // Wire Add button
  const addBtn = $('#btnAddPostPreset');
  if (addBtn && !addBtn._wired) {
    addBtn._wired = true;
    addBtn.addEventListener('click', () => {
      const name = $('#set_ppName')?.value.trim();
      const amount = Math.max(0, num($('#set_ppAmount')?.value, 0));
      if (!name) return toast(t('common.required') || 'Name is required', 'error');
      if (!settings.postProcessPresets) settings.postProcessPresets = [];
      settings.postProcessPresets.push({ name, amount });
      saveAll();
      if ($('#set_ppName')) $('#set_ppName').value = '';
      if ($('#set_ppAmount')) $('#set_ppAmount').value = '';
      renderPostProcessPresetsList();
      toast(t('set.preset_saved') || 'Preset saved', 'success');
    });
  }
}


/* ============================================================
   Portfolio
   ============================================================ */
function getPortfolioEntries() {
  // Flatten all order photos into a single browsable list
  const entries = [];
  for (const o of printLog) {
    for (let i = 0; i < (o.printPhotos || []).length; i++) {
      entries.push({
        orderId: o.id,
        project: o.project,
        date: o.date,
        photoIndex: i,
        thumb: o.printPhotos[i].thumb,
        filename: o.printPhotos[i].filename
      });
    }
  }
  return entries;
}

function renderPortfolio() {
  const grid = $('#portfolioGrid');
  if (!grid) return;
  const term = (portfolioSearchTerm || '').toLowerCase().trim();
  let entries = getPortfolioEntries();
  if (term) {
    entries = entries.filter(e =>
      (e.project || '').toLowerCase().includes(term) ||
      (e.orderId || '').toLowerCase().includes(term));
  }
  if (entries.length === 0) {
    grid.innerHTML = `<div class="empty-state" style="grid-column: 1 / -1;">${escapeHtml(t('pf.empty'))}</div>`;
    return;
  }
  grid.innerHTML = entries.map(e => `
    <div class="portfolio-cell" data-oid="${e.orderId}" data-pi="${e.photoIndex}">
      <img src="${safeImageSrc(e.thumb)}" alt="">
      <div class="overlay">
        <div>${escapeHtml(e.project)}</div>
        <div class="id">${escapeHtml(e.orderId)} · ${escapeHtml(e.date)}</div>
      </div>
    </div>`).join('');
}


  const api = {


    resetCalendarMonth,
    renderScheduleView,
    renderCalendarView,
    renderKioskView,
    renderPostProcessPresetsList,
    getPortfolioEntries,
    renderPortfolio,
  };

  Object.assign(global, api);
  global.KhaytViews = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
