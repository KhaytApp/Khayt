/**
 * Locations, production pause, operators, time entries, and PIN lock.
 */
/** Hash a PIN. Delegates to the main process for a salted PBKDF2 hash
 *  ("p2$iters$salt$hash"); falls back to in-renderer SHA-256 hex only if the
 *  bridge is unavailable (keeps the old format, still verifiable). */
async function hashPin(pin) {
  if (window.hubAPI?.hashPin) {
    try {
      const h = await window.hubAPI.hashPin(String(pin));
      if (typeof h === 'string' && h.length) return h;
    } catch (_) { /* fall through to legacy */ }
  }
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(pin)));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}
/** True for a recognized PIN hash format (salted PBKDF2 or legacy 64-hex SHA-256). */
function isManagedPinHash(hash) {
  return typeof hash === 'string' && (/^p2\$\d+\$[0-9a-f]+\$[0-9a-f]+$/i.test(hash) || /^[0-9a-f]{64}$/i.test(hash));
}
/** Detect the very old base64 PINs (NOT a managed format) — these get re-prompted.
 *  Critically, the salted PBKDF2 format is NOT legacy, so it is never wiped. */
function isLegacyPin(hash) { return typeof hash === 'string' && hash.length > 0 && !isManagedPinHash(hash); }
/** Plain SHA-256 hex — only for comparing against legacy 64-hex hashes. */
async function sha256Hex(s) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(s)));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}

/* ============================================================
   Feature 8 (new): Locations management
   ============================================================ */
function ensureDefaultLocation() {
  if (locations.length === 0) {
    locations.push({ id: uid('LOC'), name: 'Main', address: '' });
    saveAll();
  }
}

/* Settings tab — renderer/settings.js */

function openLocationEditor(locId = null) {
  const existing = locId ? locations.find(l => l.id === locId) : null;
  const draft = existing ? { ...existing } : { id: uid('LOC'), name: '', address: '' };
  openFormModal({
    title: existing ? t('set.locations') : t('set.location_add'),
    sizeLg: false,
    bodyHtml: `
      <label>${escapeHtml(t('set.location_name'))}</label>
      <input type="text" id="locName" value="${escapeHtml(draft.name)}" placeholder="Main">
      <label style="margin-top:12px;">${escapeHtml(t('set.location_addr'))}</label>
      <input type="text" id="locAddr" value="${escapeHtml(draft.address || '')}" placeholder="e.g. Riyadh, Floor 2">`,
    async onSave(modal) {
      draft.name = modal.querySelector('#locName').value.trim();
      draft.address = modal.querySelector('#locAddr').value.trim();
      if (!draft.name) { toast(t('mach.need_name'), 'error'); return false; }
      const idx = locations.findIndex(l => l.id === draft.id);
      if (idx >= 0) locations[idx] = draft; else locations.push(draft);
      saveAll();
      renderLocationsSettings();
      renderLocationFilter();
      toast(t('common.save'), 'success');
      return true;
    }
  });
}

const ACTIVE_LOCATION_KEY = 'khayt_active_location';

/** Resolve site/branch for an order via assigned machine (or optional order.locationId). */
function orderLocationId(order) {
  if (!order) return null;
  if (order.locationId) return order.locationId;
  const mid = order.machineId;
  const m = mid
    ? machines.find(x => x.id === mid)
    : machines.find(x => x.name && order.machine && x.name === order.machine);
  return m?.locationId || null;
}

/** Top-bar location filter: all sites when unset; unassigned jobs stay visible at every site. */
function orderMatchesActiveLocation(order) {
  if (!activeLocation) return true;
  const loc = orderLocationId(order);
  if (!loc) return true;
  return loc === activeLocation;
}

function machineMatchesActiveLocation(machine) {
  if (!activeLocation) return true;
  if (!machine?.locationId) return true;
  return machine.locationId === activeLocation;
}

function restoreActiveLocationFromSession() {
  try {
    const v = sessionStorage.getItem(ACTIVE_LOCATION_KEY);
    if (!v) {
      activeLocation = null;
      return;
    }
    activeLocation = locations.some(l => l.id === v) ? v : null;
  } catch {
    activeLocation = null;
  }
}

function persistActiveLocation() {
  try {
    sessionStorage.setItem(ACTIVE_LOCATION_KEY, activeLocation || '');
  } catch (_) {}
}

function renderLocationFilter() {
  const sel = $('#locationFilter');
  if (!sel) return;
  if (activeLocation && !locations.some(l => l.id === activeLocation)) activeLocation = null;
  sel.innerHTML = `<option value="">${escapeHtml(t('loc.all'))}</option>` +
    locations.map(l => `<option value="${l.id}">${escapeHtml(l.name)}</option>`).join('');
  sel.value = activeLocation || '';
  renderLocationScopeBanner();
}

/** Banner when filtering queue/dashboard to one branch. */
function renderLocationScopeBanner() {
  const hosts = ['locationScopeBannerQueue', 'locationScopeBannerDash'];
  const loc = activeLocation ? locations.find(l => l.id === activeLocation) : null;
  hosts.forEach((id) => {
    const host = document.getElementById(id);
    if (!host) return;
    if (!loc) {
      host.innerHTML = '';
      host.style.display = 'none';
      return;
    }
    host.style.display = 'flex';
    host.innerHTML = `
      <span style="font-size:12px;color:var(--text-muted);">
        ${escapeHtml(t('loc.filtering'))} <strong style="color:var(--text);">${escapeHtml(loc.name)}</strong>
      </span>
      <button type="button" class="btn small ghost" data-act="clear-location-filter">${escapeHtml(t('loc.show_all'))}</button>`;
  });
}

function locationBadgeHtml(locationId) {
  if (!locationId) return '';
  const loc = locations.find(l => l.id === locationId);
  if (!loc) return '';
  return `<span class="location-badge">${escapeHtml(loc.name)}</span>`;
}

/* ============================================================
   Feature 8 (this batch): Production pause
   ============================================================ */
function applyProductionPause() {
  const label = settings.productionPaused
    ? `"${(t('prod.paused_label') || 'Production paused').replace(/"/g, '')}"`
    : '';
  document.documentElement.style.setProperty(
    '--kanban-paused-label',
    settings.productionPaused ? label : 'none',
  );
  const banner = document.getElementById('pauseBanner');
  const btn = document.getElementById('btnPauseProduction');
  if (!banner) return;
  if (settings.productionPaused) {
    const reason = settings.pauseReason ? ` — ${escapeHtml(settings.pauseReason)}` : '';
    banner.innerHTML = `⏸ ${escapeHtml(t('prod.paused_banner'))}${reason} <button data-act="resume-production">${escapeHtml(t('prod.resume'))}</button>`;
    banner.style.display = 'flex';
    setPauseButton(btn, 'play', t('prod.resume'), true);
  } else {
    banner.style.display = 'none';
    setPauseButton(btn, 'pause', t('prod.pause'), false);
  }
}

/**
 * The pause control, in whichever of its two states it is in.
 *
 * It used to be written with `textContent` and four inline style properties,
 * which meant the colours lived here rather than in the stylesheet, and setting
 * the text deleted the icon inside the button. Worse, it was red at rest — a
 * button that is red all day is a red button nobody reads. It is quiet now
 * until production is ACTUALLY paused, which is the state worth shouting about.
 */
function setPauseButton(btn, iconName, label, paused) {
  if (!btn) return;
  const ico = (typeof window !== 'undefined' && window.KhaytIcons)
    ? window.KhaytIcons.icon(iconName, 15) : '';
  const lbl = btn.querySelector('.pp-label');
  if (lbl) {
    lbl.textContent = label;
    const slot = btn.querySelector('.pp-ico');
    if (slot) { slot.innerHTML = ico; slot.setAttribute('data-icon-done', '1'); }
  } else {
    // A build whose markup predates the icon slots still gets a correct button.
    btn.innerHTML = `<span class="pp-ico" data-icon-done="1">${ico}</span> <span class="pp-label"></span>`;
    btn.querySelector('.pp-label').textContent = label;
  }
  btn.classList.toggle('state-on', !!paused);
  btn.classList.toggle('state-resume', !!paused);
}

function pauseProduction() {
  openFormModal({
    title: t('prod.pause'),
    sizeLg: false,
    saveLabel: t('prod.pause'),
    bodyHtml: `
      <label>${escapeHtml(t('prod.pause_reason'))}</label>
      <input type="text" id="pauseReasonInput" placeholder="${escapeHtml(t('prod.pause_reason'))}" style="width:100%;">`,
    onMount(modal) { setTimeout(() => modal.querySelector('#pauseReasonInput')?.focus(), 40); },
    onSave(modal) {
      const reason = modal.querySelector('#pauseReasonInput').value.trim();
      settings.productionPaused = true;
      settings.pauseReason = reason || '';
      settings.pausedAt = new Date().toISOString();
      saveAll();
      applyProductionPause();
      renderKanban();
      toast(t('prod.paused_toast'), 'warning');
      return true;
    }
  });
}

function resumeProduction() {
  settings.productionPaused = false;
  settings.pauseReason = '';
  settings.pausedAt = null;
  saveAll();
  applyProductionPause();
  renderKanban();
  toast(t('prod.resumed'), 'success');
}

/* ============================================================
   New 8-pack Feature 7: Cost & Revenue Trends
   ============================================================ */

/* ============================================================
   Feature K: Multi-Operator Time Tracking
   ============================================================ */

function openTimeEntryModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  const activeOps = operators.filter(o => o.active !== false);
  const today = localDateStr();

  if (activeOps.length === 0) {
    toast(t('op.no_operators') || 'No active operators — add operators in Settings first', 'warning', 3000);
    return;
  }

  const opOpts = activeOps.map(op =>
    `<option value="${escapeHtml(op.id)}" data-rate="${+op.hourlyRate || 0}">${escapeHtml(op.name)}${op.role ? ' (' + escapeHtml(op.role) + ')' : ''}</option>`
  ).join('');

  openFormModal({
    title: t('time.log_title') || 'Log Work Time',
    sizeLg: false,
    bodyHtml: `
      ${order ? `<p style="font-size:13px;color:var(--text-muted);margin-top:0;">Order: <strong>${escapeHtml(order.project || order.id)}</strong></p>` : ''}
      <label>${escapeHtml(t('time.operator') || 'Operator')}</label>
      <select id="teOperator">${opOpts}</select>
      <div style="display:flex;gap:12px;margin-top:10px;">
        <div style="flex:1;">
          <label style="margin-top:0;">${escapeHtml(t('time.hours') || 'Hours')}</label>
          <input type="number" id="teHours" value="1" min="0.25" step="0.25">
        </div>
        <div style="flex:1;">
          <label style="margin-top:0;">${escapeHtml(t('time.date') || 'Date')}</label>
          <input type="date" id="teDate" value="${today}">
        </div>
      </div>
      <label style="margin-top:10px;">${escapeHtml(t('time.notes') || 'Notes (optional)')}</label>
      <textarea id="teNotes" rows="2" style="resize:vertical;"></textarea>`,
    onSave(modal) {
      const opId    = modal.querySelector('#teOperator').value;
      const op      = operators.find(o => o.id === opId);
      const hours   = parseFloat(modal.querySelector('#teHours').value) || 0;
      const date    = modal.querySelector('#teDate').value || today;
      const notes   = modal.querySelector('#teNotes').value.trim();
      if (!opId)    { toast('Select an operator', 'error'); return false; }
      if (hours <= 0) { toast(t('shift.hours_positive'), 'error'); return false; }
      const rate = +op?.hourlyRate || 0;
      timeEntries.push({
        id: uid('TE'),
        orderId:       orderId || null,
        operatorId:    opId,
        operatorName:  op?.name || '',
        hours,
        hourlyRate:    rate,
        cost:          hours * rate,
        date,
        notes,
        createdAt:     new Date().toISOString(),
      });
      saveAll();
      toast(`${t('time.logged') || 'Time logged'}: ${hours}h ${t('common.by') || 'by'} ${op?.name || ''}`, 'success');
      return true;
    }
  });
}


/* ============================================================
   New 8-pack Feature 1: Operators / Staff
   ============================================================ */
function renderOperatorsList() {
  const el = $('#operatorsList');
  if (!el) return;
  if (operators.length === 0) {
    el.innerHTML = `<div style="color:var(--text-muted);font-size:13px;padding:8px 0;">${escapeHtml(t('mach.empty') || 'No operators yet.')}</div>`;
    return;
  }
  el.innerHTML = operators.map(op => `
    <div class="machine-row">
      <span class="machine-name">${escapeHtml(op.name)}</span>
      ${op.role ? `<span style="font-size:11.5px;color:var(--text-muted);margin-inline-start:8px;">${escapeHtml(op.role)}</span>` : ''}
      ${op.hourlyRate ? `<span style="font-size:11px;color:var(--primary);margin-inline-start:8px;">${fmtPrice(+op.hourlyRate)}/hr</span>` : ''}
      ${op.active === false ? `<span class="machine-jobs-badge" style="background:var(--danger);color:#fff;">${escapeHtml(t('op.inactive'))}</span>` : ''}
      <button class="btn small" data-act="edit-operator" data-id="${op.id}">${escapeHtml(t('common.edit'))}</button>
      <button class="btn danger small" data-act="del-operator" data-id="${op.id}">${escapeHtml(t('common.delete'))}</button>
    </div>`).join('');
}

function openOperatorEditor(opId = null) {
  const existing = opId ? operators.find(o => o.id === opId) : null;
  const draft = existing ? { ...existing } : { id: uid('OP'), name: '', role: '', active: true, hourlyRate: 0 };
  if (!('hourlyRate' in draft)) draft.hourlyRate = 0;
  const currency = settings.currency || 'SAR';
  openFormModal({
    title: existing ? t('op.title') : t('op.add'),
    sizeLg: false,
    bodyHtml: `
      <label>${escapeHtml(t('op.name'))}</label>
      <input type="text" id="opName" value="${escapeHtml(draft.name)}" placeholder="e.g. Ali Al-Hassan">
      <label style="margin-top:12px;">${escapeHtml(t('op.role'))}</label>
      <input type="text" id="opRole" value="${escapeHtml(draft.role || '')}" placeholder="e.g. Senior Technician">
      <label style="margin-top:12px;">${escapeHtml(t('op.access_level') || 'Access level')}</label>
      <select id="opRoleKey">
        ${(typeof KhaytRbac !== 'undefined' ? KhaytRbac.ROLES : ['owner','manager','operator','viewer']).map(rk => {
          const sel = (draft.roleKey || (typeof KhaytRbac !== 'undefined' ? KhaytRbac.roleFromLegacy(draft.role) : 'operator')) === rk ? ' selected' : '';
          return `<option value="${rk}"${sel}>${escapeHtml(t('role.' + rk) || rk)}</option>`;
        }).join('')}
      </select>
      <label style="margin-top:12px;">${escapeHtml(t('op.hourly_rate') || 'Hourly Rate')} (${escapeHtml(currency)})</label>
      <input type="number" id="opHourlyRate" value="${+draft.hourlyRate || 0}" min="0" step="0.01">
      <label style="margin-top:12px;display:flex;align-items:center;gap:8px;cursor:pointer;">
        <input type="checkbox" id="opActive" style="width:auto;margin:0;" ${draft.active !== false ? 'checked' : ''}>
        <span>Active</span>
      </label>`,
    async onSave(modal) {
      draft.name       = modal.querySelector('#opName').value.trim();
      draft.role       = modal.querySelector('#opRole').value.trim();
      draft.roleKey    = modal.querySelector('#opRoleKey')?.value || draft.roleKey || 'operator';
      draft.hourlyRate = parseFloat(modal.querySelector('#opHourlyRate')?.value) || 0;
      draft.active     = modal.querySelector('#opActive').checked;
      if (!draft.name) { toast(t('mach.need_name'), 'error'); return false; }
      const idx = operators.findIndex(o => o.id === draft.id);
      if (idx >= 0) operators[idx] = draft; else operators.push(draft);
      saveAll();
      renderOperatorsList();
      toast(t('common.save'), 'success');
      return true;
    }
  });
}

/* ============================================================
   Feature 7 (new 8-pack): Operator PIN lock
   ============================================================ */

/** Render the PIN lock settings sub-section inside settings tab */
function openPinPadModal(afterUnlock) {
  const opList = operators.filter(o => o.active !== false);
  if (opList.length === 0) { toast(t('shift.no_operators'), 'info'); return; }

  let selectedOpId = opList[0].id;
  let enteredPin = '';
  let overlay = document.getElementById('pinPadOverlay');
  if (!overlay) {
    overlay = document.createElement('div');
    overlay.id = 'pinPadOverlay';
    overlay.className = 'modal-backdrop confirm-modal-overlay';
    overlay.style.zIndex = '10050';
    $('#modalMount').appendChild(overlay);
  }

  const closePinPad = () => {
    overlay.remove();
    overlay = null;
  };

  const render = () => {
    overlay.innerHTML = `
        <div class="modal modal-form" role="dialog" aria-modal="true" style="max-width:340px;">
          <div class="modal-header">
            <h3>${escapeHtml(t('op.switch') || 'Switch Operator')}</h3>
          </div>
          <div class="modal-body">
          <div style="margin-bottom:12px;">
            <label style="font-size:12.5px;">${escapeHtml(t('op.enter_pin') || 'Select operator')}</label>
            <select id="pinOpSelect" style="margin-top:4px;">
              ${opList.map(op => `<option value="${escapeHtml(op.id)}"${op.id === selectedOpId ? ' selected' : ''}>${escapeHtml(op.name)}${op.role ? ' · ' + escapeHtml(op.role) : ''}</option>`).join('')}
            </select>
          </div>
          <div id="pinDisplay" style="font-size:24px;letter-spacing:10px;text-align:center;margin:10px 0;min-height:36px;color:var(--primary);">${'●'.repeat(enteredPin.length)}</div>
          <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:8px;">
            ${[1,2,3,4,5,6,7,8,9].map(n => `<button class="btn pin-key" data-k="${n}" style="font-size:18px;padding:12px;">${n}</button>`).join('')}
            <button class="btn pin-key" data-k="C" style="font-size:14px;padding:12px;">C</button>
            <button class="btn pin-key" data-k="0" style="font-size:18px;padding:12px;">0</button>
            <button class="btn pin-key" data-k="⌫" style="font-size:18px;padding:12px;" aria-label="${escapeHtml(t('pin.backspace') || 'Backspace')}" title="${escapeHtml(t('pin.backspace') || 'Backspace')}">⌫</button>
          </div>
          <div id="pinError" style="color:var(--danger);font-size:12.5px;min-height:20px;text-align:center;"></div>
          </div>
          <div class="modal-footer btn-row">
            <button class="btn ghost" data-act="cancel-pin">${escapeHtml(t('common.cancel'))}</button>
            <button class="btn primary" id="btnConfirmPin">${escapeHtml(t('common.confirm'))}</button>
          </div>
        </div>`;

    overlay.querySelector('#pinOpSelect')?.addEventListener('change', e => {
      selectedOpId = e.target.value;
      enteredPin = '';
      render();
    });

    overlay.querySelectorAll('.pin-key').forEach(btn => {
      btn.addEventListener('click', () => {
        const k = btn.dataset.k;
        if (k === 'C') { enteredPin = ''; }
        else if (k === '⌫') { enteredPin = enteredPin.slice(0, -1); }
        else if (enteredPin.length < 8) { enteredPin += k; }
        const disp = overlay.querySelector('#pinDisplay');
        if (disp) disp.textContent = '●'.repeat(enteredPin.length);
      });
    });

    overlay.querySelector('[data-act="cancel-pin"]')?.addEventListener('click', closePinPad);
    overlay.addEventListener('click', (e) => { if (e.target === overlay) closePinPad(); });

    overlay.querySelector('#btnConfirmPin')?.addEventListener('click', async () => {
      const op = operators.find(o => o.id === selectedOpId);
      if (!op) { closePinPad(); return; }
      // If no PIN set, allow free switch
      if (!op.pinHash) {
        settings.activeOperatorId = op.id;
        saveAll();
        closePinPad();
        renderOperatorLockSettings();
        applyOperatorPermissions();
        toast(`Switched to ${op.name}`, 'success', 1800);
        if (afterUnlock) afterUnlock();
        return;
      }
      const errEl = overlay.querySelector('#pinError');
      // A PIN that reached this computer only as the sync mask. It IS set —
      // on another computer — so it is not a free switch, and it is not a
      // legacy PIN either: the branch below clears what it cannot read, and
      // clearing this would turn "set elsewhere" into "no PIN" for anyone at
      // the pad. Refused until it is set again here.
      if (op.pinHash === '__KHAYT_MASKED__') {
        if (errEl) errEl.textContent = t('op.pin_elsewhere');
        enteredPin = '';
        return;
      }
      // Support legacy btoa PINs (migration: clear them and prompt re-set)
      if (isLegacyPin(op.pinHash)) {
        op.pinHash = '';
        saveAll();
        if (errEl) errEl.textContent = 'PIN reset for security upgrade — please set a new PIN in Settings.';
        enteredPin = '';
        return;
      }
      if (typeof flushSave === 'function') await flushSave();
      let verified = await window.hubAPI?.verifyOperatorPin?.({ operatorId: selectedOpId, pin: enteredPin });
      // Renderer fallback only when the main bridge couldn't resolve the operator.
      // The stored hash here is legacy 64-hex (main verifies PBKDF2 directly), so
      // compare with a plain SHA-256 — NOT hashPin(), which now returns PBKDF2.
      if (!verified?.ok && (verified?.error === 'operator_not_found' || verified == null) && /^[0-9a-f]{64}$/i.test(op.pinHash || '')) {
        const entered = await sha256Hex(enteredPin);
        if (timingSafeEqualHex(entered, op.pinHash)) verified = { ok: true };
      }
      if (verified?.error === 'legacy_pin') {
        op.pinHash = '';
        saveAll();
        if (errEl) errEl.textContent = 'PIN reset for security upgrade — please set a new PIN in Settings.';
        enteredPin = '';
        return;
      }
      if (!verified?.ok) {
        if (errEl) errEl.textContent = t('op.wrong_pin') || 'Incorrect PIN';
        enteredPin = '';
        const disp = overlay.querySelector('#pinDisplay');
        if (disp) disp.textContent = '';
        return;
      }
      // The PIN was right. If it was checked against the old unsalted hash,
      // main has handed back a salted replacement — this is the only moment it
      // can be made, because it is the only moment the PIN itself is in hand.
      if (verified.upgraded) op.pinHash = verified.upgraded;
      settings.activeOperatorId = op.id;
      saveAll();
      closePinPad();
      renderOperatorLockSettings();
      applyOperatorPermissions();
      toast(`Switched to ${op.name}`, 'success', 1800);
      if (afterUnlock) afterUnlock();
    });
  };

  render();
}

/** Resolve the active operator's structured RBAC role key (owner when lock off). */
function currentOperatorRoleKey() {
  if (!settings.operatorLockEnabled) return 'owner';
  const activeOp = settings.activeOperatorId ? operators.find(o => o.id === settings.activeOperatorId) : null;
  if (!activeOp) return 'owner';
  const rbac = (typeof KhaytRbac !== 'undefined') ? KhaytRbac : null;
  return activeOp.roleKey || (rbac ? rbac.roleFromLegacy(activeOp.role) : 'operator');
}

/** Canonical permission check for the active operator. Fail-open if RBAC absent
 *  or lock is off (matches the historical "no lock = unrestricted" behavior). */
function operatorCan(area, action) {
  const rbac = (typeof KhaytRbac !== 'undefined') ? KhaytRbac : null;
  if (!rbac) return true;
  return rbac.can(currentOperatorRoleKey(), area, action, { lockEnabled: !!settings.operatorLockEnabled });
}

/** Apply tab/feature restrictions based on the active operator's role (RBAC matrix). */
function applyOperatorPermissions() {
  if (!settings.operatorLockEnabled) {
    // Remove all restrictions
    $$('.tab-btn').forEach(b => b.style.display = '');
    $$('.restricted-blur').forEach(el => el.classList.remove('restricted-blur'));
    const badge = $('#operatorNavBadge');
    if (badge) badge.textContent = '';
    return;
  }
  // Tab visibility derives from the RBAC matrix (area-level 'view' permission).
  const TAB_AREA = { 'settings-tab': 'settings', 'analytics-tab': 'analytics', 'clients-tab': 'clients' };
  for (const [tab, area] of Object.entries(TAB_AREA)) {
    const btn = $(`[data-tab="${tab}"]`);
    if (btn) btn.style.display = operatorCan(area, 'view') ? '' : 'none';
  }
  const activeOp = settings.activeOperatorId ? operators.find(o => o.id === settings.activeOperatorId) : null;
  const badge = $('#operatorNavBadge');
  if (badge) badge.textContent = activeOp ? activeOp.name : '';
}


(function (global) {
  const api = {
    hashPin,
    isLegacyPin,
    ensureDefaultLocation,
    openLocationEditor,
    renderLocationFilter,
    orderLocationId,
    orderMatchesActiveLocation,
    machineMatchesActiveLocation,
    restoreActiveLocationFromSession,
    persistActiveLocation,
    renderLocationScopeBanner,
    locationBadgeHtml,
    applyProductionPause,
    pauseProduction,
    resumeProduction,
    openTimeEntryModal,
    renderOperatorsList,
    openOperatorEditor,
    openPinPadModal,
    applyOperatorPermissions,
    currentOperatorRoleKey,
    operatorCan,
    // app-security.js verifies legacy 64-hex PIN hashes with this, behind a
    // typeof guard. From outside this IIFE the guard was false, the branch was
    // skipped, and the function fell through to `return false` — so a legacy
    // hash could never verify and the operator was simply locked out.
    sha256Hex,
  };
  Object.assign(global, api);
  global.KhaytOpsLocations = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
