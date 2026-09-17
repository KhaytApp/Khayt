/**
 * Notification centre, tab badges, due-date desktop alerts, stale order detection.
 */
(function (global) {
function getStaleOrders() {
  const thresholds = settings.staleHours || { printing: 48, post: 24, qc: 12, pending: 72 };
  const now = Date.now();
  return printLog.filter(o => {
    if (KhaytOrderStatus.isFinished(o) || o.status === 'quote' || o.status === 'on_hold') return false;
    const threshold = thresholds[o.status];
    if (!threshold) return false;
    // Find the last status change time
    let lastAt = null;
    if (o.statusHistory && o.statusHistory.length > 0) {
      lastAt = o.statusHistory[o.statusHistory.length - 1].at;
    } else if (o.status === 'printing' && o.printingStartedAt) {
      lastAt = o.printingStartedAt;
    } else if (o.date) {
      lastAt = o.date + 'T00:00:00.000Z';
    }
    if (!lastAt) return false;
    const hoursAgo = (now - new Date(lastAt).getTime()) / 3600000;
    return hoursAgo >= threshold;
  }).sort((a, b) => {
    // Most stale first
    const getLastAt = o => {
      if (o.statusHistory?.length) return o.statusHistory[o.statusHistory.length - 1].at;
      return o.printingStartedAt || o.date + 'T00:00:00Z' || '';
    };
    return getLastAt(a).localeCompare(getLastAt(b));
  });
}

/* ============================================================
   Notification Centre
   ============================================================ */
function buildNotifications() {
  const alerts = [];
  const today = new Date(); today.setHours(0,0,0,0);

  // Enthusiast (hobbyist) mode has no commerce — skip quote/payment/recurring-order
  // alerts. Personal alerts (overdue jobs, low stock, maintenance, stalls) still fire.
  const biz = (typeof KhaytTiers !== 'undefined' && typeof settings !== 'undefined')
    ? KhaytTiers.showsBusiness(settings.mode)
    : (typeof settings === 'undefined' || settings.mode !== 'enthusiast');

  const dismissed = settings.dismissedNotifs || {};
  const now = new Date().toISOString();
  function isDismissed(key) {
    const until = dismissed[key];
    if (!until) return false;
    if (until === 'forever') return true;
    return until > now;
  }

  // 1. Overdue orders
  const overdue = printLog.filter(o =>
    o.dueDate && !KhaytOrderStatus.isFinished(o) && o.status !== 'quote' &&
    new Date(o.dueDate + 'T00:00:00') < today
  );
  for (const o of overdue.slice(0, 8)) {
    const key = 'overdue:' + o.id;
    if (!isDismissed(key)) {
      alerts.push({
        key,
        type: 'overdue', icon: '🔴',
        title: escapeHtml(t('notif.overdue') || 'Overdue'),
        body:  escapeHtml(o.project || o.id),
        action() { switchTab('queue-tab'); }
      });
    }
  }
  if (overdue.length > 8) alerts.push({ key: 'overdue:more', type: 'overdue', icon: '🔴', title: '', body: `+${overdue.length - 8} more overdue`, action() { switchTab('queue-tab'); } });

  // 2. Expiring quotes (≤ 2 days) — commerce only.
  if (biz) {
    const expiringQuotes = printLog
      .filter(o => o.status === 'quote' && o.quoteExpiresAt)
      .filter(o => Math.round((new Date(o.quoteExpiresAt + 'T00:00:00') - today) / 86400000) <= 2)
      .slice(0, 5);
    for (const o of expiringQuotes) {
      const key = 'quote:' + o.id;
      if (!isDismissed(key)) {
        const d = Math.round((new Date(o.quoteExpiresAt + 'T00:00:00') - today) / 86400000);
        alerts.push({
          key,
          type: 'quote', icon: '📋',
          title: escapeHtml(t('notif.quote_expiring') || 'Quote expiring'),
          body:  `${escapeHtml(o.project || o.id)} — ${d <= 0 ? (t('oe.due_overdue', {n: Math.abs(d)}) || 'expired') : d + 'd left'}`,
          action() { switchTab('logs-tab'); }
        });
      }
    }
  }

  // 3. Low stock spools
  const lowSpools = inventory.filter(i =>
    i.weight <= (i.reorderPoint ?? settings.lowStockThreshold ?? 200)
  ).slice(0, 6);
  for (const spool of lowSpools) {
    const key = 'stock:' + spool.id;
    if (!isDismissed(key)) {
      alerts.push({
        key,
        type: 'stock', icon: '🧵',
        title: escapeHtml(t('notif.low_stock') || 'Low stock'),
        body:  `${escapeHtml(spool.material)} — ${Math.round(spool.weight)}g remaining`,
        action() { switchTab('inventory-tab'); }
      });
    }
  }

  // 4. Machines due for service
  for (const m of machines) {
    const svc = machineServiceStatus(m);
    if (svc.due || svc.warning) {
      const key = 'service:' + m.id;
      if (!isDismissed(key)) {
        alerts.push({
          key,
          type: 'service', icon: '🔧',
          title: escapeHtml(svc.due ? (t('notif.service_due') || 'Service due') : (t('notif.service_soon') || 'Service soon')),
          body:  escapeHtml(m.name),
          action() { switchTab('settings-tab'); }
        });
      }
    }
  }

  // 4b. Recurring maintenance tasks due/overdue (hours- or date-based)
  if (typeof KhaytMaintenance !== 'undefined' && Array.isArray(machMaintTasks) && machMaintTasks.length) {
    const hoursByMachine = {};
    for (const m of machines) hoursByMachine[m.id] = machineHoursMeter(m.id);
    const machineName = (id) => (machines.find(m => m.id === id) || {}).name || '';
    for (const task of KhaytMaintenance.dueTasks(machMaintTasks, hoursByMachine, Date.now())) {
      const key = 'mtask:' + task.id;
      if (isDismissed(key)) continue;
      const overdue = task.status === 'overdue';
      alerts.push({
        key,
        type: 'service', icon: '🔧',
        title: escapeHtml((overdue ? (t('notif.maint_overdue') || 'Maintenance overdue')
                                   : (t('notif.maint_due') || 'Maintenance due')) + ': ' + (task.name || '')),
        body: escapeHtml(machineName(task.machineId)),
        action() { switchTab('settings-tab'); },
      });
    }
  }

  // 4c. Recurring-order subscriptions due (robust date logic via lib/subscriptions,
  // over the existing per-client recurring config — reminder only, operator fulfils).
  if (biz && typeof KhaytSubscriptions !== 'undefined' && Array.isArray(clients)) {
    const subView = clients
      .filter(c => c.recurring && c.recurring.enabled && !c.recurring.paused && c.recurring.nextDue)
      .map(c => ({ id: c.id, status: 'active', interval: c.recurring.interval || 'monthly', nextRunAt: c.recurring.nextDue, _name: c.name }));
    for (const sub of KhaytSubscriptions.selectDueSubscriptions(subView, Date.now())) {
      const key = 'recurdue:' + sub.id;
      if (isDismissed(key)) continue;
      alerts.push({
        key, type: 'service', icon: '🔁',
        title: escapeHtml(t('notif.recurring_due') || 'Recurring order due'),
        body: escapeHtml(sub._name || ''),
        action() { switchTab('clients-tab'); },
      });
    }
  }

  // 4d. Installment payments due/overdue (per-order plans; existing instalments + lib).
  if (biz && typeof KhaytPaymentPlan !== 'undefined') {
    const today = Date.now();
    for (const o of printLog) {
      if (!o || !Array.isArray(o.instalments) || !o.instalments.length) continue;
      if (typeof payStatus === 'function' && payStatus(o) === 'paid') continue;
      const sched = o.instalments.map(ins => ({ dueDate: ins.dueDate, amount: ins.amount, paidAt: ins.paid ? 'x' : null }));
      const due = KhaytPaymentPlan.dueInstallments(sched, today);
      if (!due.length) continue;
      const key = 'instdue:' + o.id;
      if (isDismissed(key)) continue;
      alerts.push({
        key, type: 'overdue', icon: '💸',
        title: escapeHtml(t('notif.installment_due') || 'Installment due'),
        body: escapeHtml((o.orderName || o.project || o.id) + ' · ' + due.length),
        action() { switchTab('logs-tab'); },
      });
    }
  }

  // 5. Stale orders (uses existing helper)
  const stale = typeof getStaleOrders === 'function' ? getStaleOrders().slice(0, 5) : [];
  for (const o of stale) {
    const key = 'stale:' + o.id;
    if (!isDismissed(key)) {
      alerts.push({
        key,
        type: 'stale', icon: '⚠️',
        title: escapeHtml(t('notif.stale_order') || 'Order stalled'),
        body:  `${escapeHtml(o.project || o.id)} — ${escapeHtml(t('queue.' + o.status) || o.status)}`,
        action() { switchTab('queue-tab'); }
      });
    }
  }

  // 6. Consumables low stock
  const lowCons = consumables.filter(c => c.minStock > 0 && c.stock <= c.minStock).slice(0, 4);
  for (const c of lowCons) {
    const key = 'cons:' + (c.id || c.name);
    if (!isDismissed(key)) {
      alerts.push({
        key,
        type: 'stock', icon: '📦',
        title: escapeHtml(t('notif.low_consumable') || 'Low consumable'),
        body:  `${escapeHtml(c.name)} — ${c.stock} ${escapeHtml(c.unit || '')}`,
        action() { switchTab('inventory-tab'); }
      });
    }
  }

  // 7. Recurring order reminders — commerce only.
  if (biz) clients.filter(c => c.recurring?.enabled && c.recurring?.intervalDays).forEach(c => {
    const lastOrder = printLog.filter(o => o.clientId === c.id)
      .sort((a, b) => (b.date || '').localeCompare(a.date || ''))[0];
    if (!lastOrder) return;
    const daysSince = Math.floor((Date.now() - new Date(lastOrder.date).getTime()) / 86400000);
    const due = daysSince >= c.recurring.intervalDays;
    if (!due) return;
    const key = 'recurring:' + c.id;
    if (isDismissed(key)) return;
    alerts.push({
      key,
      type: 'recurring',
      icon: '🔄',
      title: escapeHtml(t('notif.group_recurring') || 'Recurring Orders'),
      body: escapeHtml(t('notif.recurring_due_body', { name: localName(c), days: daysSince })),
      dismissKey: key,
      clientId: c.id,
      action() { logClientFilter = c.id; switchTab('queue-tab'); logPrint && logPrint(); }
    });
  });

  return alerts;
}

function updateNotifBadge() {
  const badge = $('#notifBadge');
  if (!badge) return;
  const count = buildNotifications().length;
  if (count === 0) {
    badge.style.display = 'none';
  } else {
    badge.style.display = '';
    badge.textContent = count > 99 ? '99+' : String(count);
  }
}

function setNotifBellExpanded(open) {
  const bell = $('#btnNotifBell');
  if (bell) bell.setAttribute('aria-expanded', open ? 'true' : 'false');
}

function openNotifPanel() {
  const panel = $('#notifPanel');
  if (!panel) return;
  if (panel.style.display !== 'none') {
    panel.style.display = 'none';
    setNotifBellExpanded(false);
    return;
  }

  const alerts = buildNotifications();

  if (alerts.length === 0) {
    panel.innerHTML = `<div style="padding:24px 16px;text-align:center;color:var(--text-muted);font-size:13px;">
      ✅ ${escapeHtml(t('notif.all_clear') || 'All clear — no active alerts')}
    </div>`;
    panel.style.display = 'block';
    setNotifBellExpanded(true);
    return;
  }

  // Group by type
  const groups = [
    { key: 'overdue',    label: t('notif.group_overdue')    || 'Overdue Orders' },
    { key: 'quote',      label: t('notif.group_quotes')     || 'Expiring Quotes' },
    { key: 'stock',      label: t('notif.group_stock')      || 'Low Stock' },
    { key: 'service',    label: t('notif.group_service')    || 'Machine Service' },
    { key: 'recurring',  label: t('notif.group_recurring')  || 'Recurring Orders' },
    { key: 'stale',   label: t('notif.group_stale')   || 'Stalled Orders' },
  ];

  let html = `<div style="padding:10px 14px 6px;font-size:13px;font-weight:700;border-bottom:1px solid var(--border-soft);">
    🔔 ${escapeHtml(t('notif.title') || 'Notifications')}
    <span style="margin-inline-start:auto;font-size:11px;font-weight:400;color:var(--text-muted);">${alerts.length} alert${alerts.length !== 1 ? 's' : ''}</span>
  </div>`;

  for (const g of groups) {
    const items = alerts.filter(a => a.type === g.key);
    if (items.length === 0) continue;
    html += `<div style="padding:6px 14px 2px;font-size:10.5px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;color:var(--text-muted);">${escapeHtml(g.label)}</div>`;
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const newOrderBtn = item.type === 'recurring' && item.clientId
        ? `<button type="button" class="btn small ghost notif-new-order-btn" data-client="${escapeHtml(item.clientId)}" style="font-size:11px;padding:2px 6px;margin-inline-end:4px;">${escapeHtml(t('common.new_order') || 'New Order')}</button>`
        : '';
      html += `<div class="notif-row" data-notif-idx="${alerts.indexOf(item)}"
        style="display:flex;align-items:flex-start;gap:10px;padding:9px 14px;cursor:pointer;border-bottom:1px solid var(--border-soft);transition:background .1s;">
        <span style="font-size:15px;flex-shrink:0;margin-top:1px;">${escapeHtml(String(item.icon || ''))}</span>
        <div style="flex:1;overflow:hidden;">
          ${item.title ? `<div style="font-size:11px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.4px;">${escapeHtml(item.title)}</div>` : ''}
          <div style="font-size:12.5px;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">${escapeHtml(item.body)}</div>
        </div>
        ${newOrderBtn}
        ${item.key ? `<button type="button" class="btn small ghost notif-dismiss-btn" data-key="${escapeHtml(item.key)}" title="${escapeHtml(t('notif.dismiss') || 'Snooze until tomorrow')}" style="font-size:11px;padding:2px 6px;margin-inline-end:4px;" aria-label="${escapeHtml(t('notif.dismiss') || 'Snooze until tomorrow')}"><span aria-hidden="true">✕</span></button>` : ''}
        <span style="font-size:11px;color:var(--primary);flex-shrink:0;padding-top:2px;">${escapeHtml(t('notif.go') || 'Go →')}</span>
      </div>`;
    }
  }

  html += `<div style="padding:8px 14px;border-top:1px solid var(--border-soft);text-align:center;">
    <button class="btn small ghost" id="notifDismissAll">${escapeHtml(t('notif.dismiss_all') || 'Snooze all for today')}</button>
  </div>`;

  panel.innerHTML = html;
  panel.style.display = 'block';
  panel.setAttribute('role', 'region');
  panel.setAttribute('aria-label', t('notif.title') || 'Notifications');
  setNotifBellExpanded(true);

  // Attach click handlers
  panel.querySelectorAll('.notif-row').forEach(row => {
    const idx = parseInt(row.dataset.notifIdx, 10);
    row.addEventListener('mouseenter', () => row.style.background = 'var(--bg-elev)');
    row.addEventListener('mouseleave', () => row.style.background = '');
    row.addEventListener('click', () => {
      panel.style.display = 'none';
      setNotifBellExpanded(false);
      if (alerts[idx]) alerts[idx].action();
    });
  });

  panel.querySelectorAll('.notif-new-order-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      panel.style.display = 'none';
      logClientFilter = btn.dataset.client || '';
      switchTab('calculator-tab');
    });
  });

  panel.querySelectorAll('.notif-dismiss-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const key = btn.dataset.key;
      if (!settings.dismissedNotifs) settings.dismissedNotifs = {};
      const tomorrow = new Date();
      tomorrow.setDate(tomorrow.getDate() + 1);
      tomorrow.setHours(8, 0, 0, 0);
      settings.dismissedNotifs[key] = tomorrow.toISOString();
      saveAll();
      updateNotifBadge();
      openNotifPanel();
    });
  });

  panel.querySelector('#notifDismissAll')?.addEventListener('click', () => {
    const tomorrow = new Date();
    tomorrow.setDate(tomorrow.getDate() + 1);
    tomorrow.setHours(8, 0, 0, 0);
    const exp = tomorrow.toISOString();
    if (!settings.dismissedNotifs) settings.dismissedNotifs = {};
    alerts.forEach(a => { if (a.key) settings.dismissedNotifs[a.key] = exp; });
    saveAll();
    updateNotifBadge();
    panel.style.display = 'none';
  });
}

function updateTabBadges() {
  // Queue tab: count all active (non-completed, non-quote) orders
  const activeCount = printLog.filter(o => !KhaytOrderStatus.isFinished(o) && o.status !== 'quote').length;
  const queueTabBtn = document.querySelector('.tab-btn[data-tab="queue-tab"]');
  if (queueTabBtn) {
    let badge = queueTabBtn.querySelector('.tab-badge');
    if (!badge) {
      badge = document.createElement('span');
      badge.className = 'tab-badge';
      badge.style.cssText = 'display:inline-block;min-width:16px;padding:0 4px;height:16px;line-height:16px;border-radius:8px;font-size:10px;font-weight:700;background:var(--primary);color:#fff;margin-inline-start:4px;text-align:center;vertical-align:middle;';
      queueTabBtn.appendChild(badge);
    }
    badge.textContent = activeCount > 0 ? String(activeCount) : '';
    badge.style.display = activeCount > 0 ? 'inline-block' : 'none';
  }
  // Overdue orders badge on logs tab
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const overdueCount = printLog.filter(o => o.dueDate && !KhaytOrderStatus.isFinished(o) && new Date(o.dueDate + 'T00:00:00') < today).length;
  const logsTabBtn = document.querySelector('.tab-btn[data-tab="logs-tab"]');
  if (logsTabBtn) {
    let badge = logsTabBtn.querySelector('.tab-badge');
    if (!badge) {
      badge = document.createElement('span');
      badge.className = 'tab-badge';
      badge.style.cssText = 'display:inline-block;min-width:16px;padding:0 4px;height:16px;line-height:16px;border-radius:8px;font-size:10px;font-weight:700;background:var(--danger);color:#fff;margin-inline-start:4px;text-align:center;vertical-align:middle;';
      logsTabBtn.appendChild(badge);
    }
    badge.textContent = overdueCount > 0 ? String(overdueCount) : '';
    badge.style.display = overdueCount > 0 ? 'inline-block' : 'none';
  }
}


/* ============================================================
   Due-date desktop notifications
   ============================================================ */
async function checkDueDateNotifications() {
  if (!('Notification' in window)) return;
  if (Notification.permission === 'denied') return;
  if (Notification.permission === 'default') {
    await Notification.requestPermission();
  }
  if (Notification.permission !== 'granted') return;

  const today = new Date(); today.setHours(0, 0, 0, 0);
  const active = printLog.filter(o => o.dueDate && !KhaytOrderStatus.isFinished(o));

  const overdue = active.filter(o => new Date(o.dueDate + 'T00:00:00') < today);
  const dueToday = active.filter(o => {
    const d = new Date(o.dueDate + 'T00:00:00');
    return Math.round((d - today) / 86400000) === 0;
  });
  const dueTomorrow = active.filter(o => {
    const d = new Date(o.dueDate + 'T00:00:00');
    return Math.round((d - today) / 86400000) === 1;
  });

  const bizName = shopField('biz') || 'Khayt';

  if (overdue.length > 0) {
    new Notification(t('notif.overdue_title', { n: overdue.length }), {
      body: overdue.slice(0, 3).map(o => o.project || o.id).join(', ') + (overdue.length > 3 ? ` +${overdue.length - 3}` : ''),
      tag:  'hub-overdue'
    });
  }
  if (dueToday.length > 0) {
    new Notification(t('notif.due_today_title', { n: dueToday.length }), {
      body: dueToday.map(o => o.project || o.id).join(', '),
      tag:  'hub-due-today'
    });
  }
  if (dueTomorrow.length > 0) {
    new Notification(t('notif.due_tomorrow_title', { n: dueTomorrow.length }), {
      body: dueTomorrow.map(o => o.project || o.id).join(', '),
      tag:  'hub-due-tomorrow'
    });
  }

  // Expiring quotes (≤ 1 day remaining, not yet reminded this session)
  if (!checkDueDateNotifications._quotesReminded) checkDueDateNotifications._quotesReminded = new Set();
  const expiringQuotes = printLog.filter(o => {
    if (o.status !== 'quote' || !o.quoteExpiresAt) return false;
    const daysLeft = Math.round((new Date(o.quoteExpiresAt + 'T00:00:00') - today) / 86400000);
    return daysLeft <= 1;
  });
  for (const q of expiringQuotes) {
    if (checkDueDateNotifications._quotesReminded.has(q.id)) continue;
    checkDueDateNotifications._quotesReminded.add(q.id);
    const daysLeft = Math.round((new Date(q.quoteExpiresAt + 'T00:00:00') - today) / 86400000);
    const msg = daysLeft < 0
      ? `Quote ${q.id} for "${q.project}" expired ${Math.abs(daysLeft)} day(s) ago`
      : `Quote ${q.id} for "${q.project}" expires ${daysLeft === 0 ? 'today' : 'tomorrow'}`;
    toast(msg, 'warning', 6000);
  }
}





  const api = {
    getStaleOrders,
    buildNotifications,
    updateNotifBadge,
    openNotifPanel,
    updateTabBadges,
    checkDueDateNotifications,
  };

  Object.assign(global, api);
  global.KhaytNotifications = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
