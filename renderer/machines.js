/**
 * Machine profiles, maintenance log, service status, WhatsApp templates.
 */
/* Make sure the working week is loaded, WITHOUT declaring a binding for it.
 *
 * lib/working-week.js assigns globalThis.KhaytWorkingWeek itself, so the script
 * tag has already done this in the renderer, and `require` does it under Node,
 * where these files are pulled in directly by tests.
 *
 * The obvious version — a shared `const` at the top of each file — is a trap.
 * Classic scripts share ONE global lexical scope, so the second file to declare
 * the same top-level const throws "already been declared" and kills every script
 * after it. That is what happened: settings.js never reached its export list,
 * and the app died wiring a button whose handler had silently ceased to exist. */
if (typeof KhaytWorkingWeek === 'undefined' && typeof require === 'function') {
  require('../lib/working-week.js');
}
(function (global) {
/** The shop floor's rules, however this file happens to be loaded. */
const MachineEdit = (typeof globalThis !== 'undefined' && globalThis.KhaytMachineEdit)
  || (() => { try { return require('../lib/machine-edit.js'); } catch (e) { return null; } })();

// Bed Ready swaps decorative emoji for its bespoke drafting glyphs; Khayt keeps the emoji.
const _mBdr = (typeof document !== 'undefined' && document.documentElement && document.documentElement.dataset.app === 'bedready');
function _mIco(name, emoji, size) { return (_mBdr && window.BedReadyIcons) ? `<span class="br-ico">${window.BedReadyIcons.get(name, size || 15)}</span>` : emoji; }
function _mIcoL(name, emoji, size) { return (_mBdr && window.BedReadyIcons) ? `<span class="br-ico">${window.BedReadyIcons.get(name, size || 15)}</span>` : emoji + ' '; }
/* ============================================================
   Machine profiles (physical printers you assign jobs to)
   ============================================================ */
const MACHINE_COLORS = ['#5b9cf0','#2bb673','#f5a623','#ef4d5e','#a78bfa','#fb923c','#34d399','#f472b6'];

/* Feature 4: Grams printed on a machine since last nozzle install */
/**
 * Nozzle wear for one machine. See lib/nozzle-wear.js for the model.
 *
 * This used to sum `p.weight` — a field a part does not have. `+undefined || 0`
 * meant every job contributed nothing, so the bar sat at zero and the "Replace
 * nozzle" warning had never fired for anyone. A real shop: twelve completed
 * jobs, 2,461 g through a 2,000 g threshold, card reading 0 g.
 */
function machineNozzleWear(machine) {
  return KhaytNozzleWear.nozzleWear(printLog, machine, settings);
}

/** Grams through the nozzle since it was fitted. Kept for callers that want the raw figure. */
function machineGramsSinceNozzle(machine) {
  return machineNozzleWear(machine).grams;
}

/**
 * What the printer itself says this machine is doing, on the machine card.
 *
 * The card had NO live state at all. Every number on it — the active-jobs badge,
 * the hours, the nozzle wear — is derived from the ORDER BOOK, so a printer
 * running a job that was sent to it straight from a slicer showed as having
 * nothing on. Reported exactly that way: the U1 mid-print, and the app calling
 * it idle. Meanwhile the poller had the answer every thirty seconds and only the
 * dashboard tile and the kanban badge ever read it.
 *
 * Staleness is checked here for the same reason the dashboard checks it: a
 * stopped poller otherwise leaves the last good reading on screen forever, and
 * "Printing 47%" that has not moved since the laptop woke up is worse than
 * saying nothing.
 */
const MACHINE_LIVE_STALE_MS = 90_000;

function machineLiveBadge(m) {
  if (!m || !m.printerApi || !m.printerApi.type || m.printerApi.type === 'none') return '';
  const cache = (typeof machineStatusCache !== 'undefined' && machineStatusCache) || {};
  const entry = cache[m.id];
  const st = (typeof KhaytAttention !== 'undefined')
    ? KhaytAttention.machineState(m, entry)
    : (entry && String(entry.state || '').toLowerCase().includes('print') ? 'printing' : 'idle');

  const badge = (bg, fg, text, title) =>
    `<span class="machine-jobs-badge" style="background:${bg};color:${fg};"${title ? ` title="${escapeHtml(title)}"` : ''}>${escapeHtml(text)}</span>`;

  if (st === 'unknown') return badge('var(--surface-2)', 'var(--text-muted)', t('mach.live_no_reading') || 'No reading', t('mach.live_no_reading_hint') || 'This printer is configured but has not answered yet.');
  if (st === 'error') return badge('var(--danger)', '#fff', (entry && entry.state) || (t('mach.live_error') || 'Error'));
  if (st === 'reconnecting') return badge('var(--warning)', '#000', t('mach.live_reconnecting') || 'Reconnecting');
  if (st === 'offline' && !m.isOffline) return badge('var(--danger)', '#fff', t('mach.offline_badge'));

  const age = (entry && entry.lastUpdated) ? Date.now() - entry.lastUpdated : null;
  if (age !== null && age > MACHINE_LIVE_STALE_MS) {
    const mins = Math.round(age / 60000);
    return badge('var(--surface-2)', 'var(--text-muted)', t('dash.printer_stale', { mins: String(mins) }) || `No update for ${mins} min`);
  }

  if (st === 'printing') {
    const pct = Math.min(100, Math.max(0, Math.round(+(entry && entry.progress) || 0)));
    const label = `${t('mach.live_printing') || 'Printing'} · ${pct}%`;
    return badge('var(--success)', '#fff', label, (entry && entry.filename) || '');
  }
  return badge('var(--surface-2)', 'var(--text-muted)', t('mach.live_idle') || 'Idle');
}

/**
 * Refresh the live badges in place, on every poll.
 *
 * In place rather than re-rendering the list: renderMachines() rebuilds every
 * card, which would drop an open inline editor and reset scroll every thirty
 * seconds.
 */
function updateMachinesLiveStatus() {
  document.querySelectorAll('#machinesList [data-machine-live]').forEach((el) => {
    const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x.id === el.dataset.machineLive);
    if (m) el.innerHTML = machineLiveBadge(m);
  });
}

function renderMachines() {
  const list = $('#machinesList');
  if (!list) return;
  if (machines.length === 0) {
    list.innerHTML = `<div style="color:var(--text-muted);font-size:13px;padding:8px 0;">${escapeHtml(t('mach.empty'))}</div>`;
    return;
  }
  list.innerHTML = machines.map(m => {
    const active = printLog.filter(o => o.machineId === m.id && !['completed','quote'].includes(o.status)).length;
    const svc = machineServiceStatus(m);
    const svcBadge = svc.due
      ? `<span class="machine-jobs-badge" style="background:var(--danger); color:#fff;">⚠ ${escapeHtml(t('mach.service_due'))}</span>`
      : svc.warning
        ? `<span class="machine-jobs-badge" style="background:var(--warning); color:#000;">⚠ ${escapeHtml(t('mach.service_warn'))}</span>`
        : '';
    const hrsLine = `<span class="machine-hrs-stat">${_mIcoL('wrench', '🔧', 13)}${svc.total.toFixed(1)}h ${escapeHtml(t('mach.hours_total'))}${m.serviceInterval > 0 ? ` · ${svc.hours.toFixed(1)}h since service` : ''}</span>`;
    const now2Str = new Date().toISOString();
    const hasDowntime = (m.downtimeBlocks || []).some(b => b.to && b.to > now2Str);
    const downtimeBadge = hasDowntime
      ? `<span class="machine-jobs-badge" style="background:var(--warning); color:#000;">🔧 ${escapeHtml(t('mach.downtime_badge'))}</span>`
      : '';
    // Feature 4: Nozzle info
    const nz = machineNozzleWear(m);
    const nozzleThreshold = nz.threshold;
    const nozzlePct = nz.pct;
    const nozzleOver = nz.over;
    // Show the wear figure, because that is what the threshold measures — but
    // when they differ, show what was actually printed beside it and name the
    // filament responsible. A bar reading 2,400 g after 300 g of printing is
    // alarming and unexplained on its own; "300 g printed · PLA-CF counts 8×"
    // is the same fact with its reason attached.
    const nozzleCount = nz.abrasive
      ? `${nz.wear.toFixed(0)}g/${nozzleThreshold}g ${escapeHtml(t('mach.nozzle_wear_suffix') || 'wear')}`
      : `${nz.grams.toFixed(0)}g/${nozzleThreshold}g`;
    const nozzleWhy = nz.abrasive && nz.worst
      ? ` <span title="${escapeHtml(t('mach.nozzle_abrasive_hint') || 'Abrasive filament wears a nozzle faster than its weight suggests.')}">· ${nz.grams.toFixed(0)}g ${escapeHtml(t('mach.nozzle_printed') || 'printed')} · ${escapeHtml(nz.worst.material)} ${nz.worst.mult}×</span>`
      : '';
    const nozzleHtml = m.nozzle?.installedAt ? `
      <div style="margin-top:4px; font-size:11px; color:var(--text-muted);">
        ${_mIcoL('nozzle', '🔩', 13)}${escapeHtml(m.nozzle.material || 'brass')} nozzle${m.nozzleDiameter ? ` · ${m.nozzleDiameter}mm` : ''}${m.extruderType ? ` · ${escapeHtml(m.extruderType)}` : ''}
        · ${nozzleCount}${nozzleWhy}
        ${nozzleOver ? `<span class="machine-jobs-badge" style="background:var(--danger);color:#fff;">${_mIcoL('nozzle', '🔩', 12)}${escapeHtml(t('mach.nozzle_replace'))}</span>` : ''}
      </div>
      <div class="nozzle-progress" style="max-width:200px;margin-top:3px;">
        <div class="nozzle-progress-bar" style="width:${nozzlePct.toFixed(1)}%;background:${nozzleOver ? 'var(--danger)' : 'var(--primary)'};"></div>
      </div>` : '';
    /* THE CHECKED SPECS, AND THE SUPPORT LINK.
     *
     * All of this was collected, stored on the machine and displayed nowhere —
     * including the support URL, which was the thing actually asked for and
     * which had every one of its forty-nine addresses checked for a 200. Data
     * that reaches the store and never reaches the screen is the same as data
     * that was never collected, and it is harder to notice.
     *
     * Only what is known: a printer the catalog has not been swept for shows
     * nothing here rather than a row of dashes.
     */
    const specBits = [];
    if (m.maxHotendC) specBits.push(`${m.maxHotendC}°C ${escapeHtml(t('mach.hotend') || 'hotend')}`);
    if (m.maxBedC) specBits.push(`${m.maxBedC}°C ${escapeHtml(t('mach.bed') || 'bed')}`);
    if (m.chamber === 'active') specBits.push(`${m.maxChamberC || '?'}°C ${escapeHtml(t('mach.chamber') || 'chamber')}`);
    else if (m.chamber === 'passive') specBits.push(escapeHtml(t('mach.chamber_passive') || 'enclosed'));
    if (m.filamentMm && m.filamentMm !== 1.75) specBits.push(`${m.filamentMm} mm ${escapeHtml(t('mach.filament') || 'filament')}`);
    if (m.toolheads > 1) specBits.push(`${m.toolheads} ${escapeHtml(t('mach.toolheads') || 'toolheads')}`);
    if (m.lcdK) specBits.push(`${escapeHtml(m.lcdK)} ${escapeHtml(t('mach.screen') || 'screen')}`);
    if (m.xyMicrons) specBits.push(`${m.xyMicrons} µm XY`);
    const specsHtml = (specBits.length || m.support) ? `
      <div style="margin-top:4px; font-size:11px; color:var(--text-muted);">
        ${specBits.join(' · ')}
        ${m.support ? `${specBits.length ? ' · ' : ''}<a href="#" class="mach-support" data-url="${escapeHtml(m.support)}" style="color:var(--primary);">${escapeHtml(t('mach.support') || 'Support')} ↗</a>` : ''}
      </div>` : '';
    // Feature 3: compat materials
    const compatHtml = (m.compatMaterials && m.compatMaterials.length > 0)
      ? `<span style="font-size:10.5px;color:var(--text-muted);margin-inline-start:6px;">[${escapeHtml(m.compatMaterials.join(', '))}]</span>`
      : '';
    return `
      <div class="machine-row" data-machine-id="${escapeHtml(m.id)}" style="flex-wrap:wrap;">
        <span class="machine-dot" style="background:${safeCssColor(m.color)};"></span>
        <span class="machine-name">${escapeHtml(m.name)}</span>
        ${compatHtml}
        ${m.isOffline ? `<span class="machine-jobs-badge" style="background:var(--danger); color:#fff;">${_mIcoL('alert', '⚠', 12)}${escapeHtml(t('mach.offline_badge'))}</span>` : ''}
        <span data-machine-live="${escapeHtml(m.id)}">${machineLiveBadge(m)}</span>
        ${active > 0 ? `<span class="machine-jobs-badge">${active} ${escapeHtml(t('mach.active_jobs'))}</span>` : ''}
        ${svcBadge ? `<span class="pro-only">${svcBadge}</span>` : ''}
        ${downtimeBadge ? `<span class="pro-only">${downtimeBadge}</span>` : ''}
        ${hrsLine}
        ${(m.printerApi && m.printerApi.type && m.printerApi.type !== 'none') ? `<button class="btn small ghost" data-act="slice-print" data-id="${m.id}" title="${escapeHtml(t('slicer.send_title') || 'Slice & print')}" style="font-size:11px;">${_mIco('printer', '🖨')}</button>` : ''}
        <button class="btn small pro-only" data-act="maint-log" data-id="${m.id}" title="${escapeHtml(t('maint.btn'))}" aria-label="${escapeHtml(t('maint.btn'))}"><span aria-hidden="true">🔧</span></button>
        <button class="btn small ghost pro-only" data-act="log-nozzle-change" data-id="${m.id}" title="${escapeHtml(t('mach.log_nozzle'))}" style="font-size:11px;" aria-label="${escapeHtml(t('mach.log_nozzle'))}"><span aria-hidden="true">🔩</span></button>
        ${m.printerApi?.type === 'moonraker' ? `<button class="btn small ghost pro-only" data-act="import-history" data-id="${m.id}" title="${escapeHtml(t('mach.import_history_hint') || 'Read every job this printer has run. Read-only — safe while it is printing.')}" style="font-size:11px;" aria-label="${escapeHtml(t('mach.import_history') || 'Import print history')}"><span aria-hidden="true">📥</span></button>` : ''}
        <button class="btn small" data-act="edit-mach" data-id="${m.id}">${escapeHtml(t('common.edit'))}</button>
        <button class="btn danger small" data-act="del-mach" data-id="${m.id}">${escapeHtml(t('common.delete'))}</button>
        ${nozzleHtml}
        ${specsHtml}
        ${(typeof KhaytWebcam !== 'undefined' && KhaytWebcam.hasCamera(m)) ? `
        <div class="mach-cam" data-cam="${escapeHtml(m.id)}" style="margin-top:8px;position:relative;width:160px;height:120px;background:var(--bg-elev);border-radius:8px;overflow:hidden;display:flex;align-items:center;justify-content:center;">
          <span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('cam.loading') || 'Camera…')}</span>
        </div>` : ''}
      </div>`;
  }).join('');
  // The support link opens in the shop's browser, not in the app window.
  // Wired here rather than in the markup because the list is rebuilt on every
  // render and an inline handler would be a CSP violation in this renderer.
  list.querySelectorAll('.mach-support').forEach((a) => a.addEventListener('click', (e) => {
    e.preventDefault();
    window.hubAPI?.openExternal?.(a.dataset.url);
  }));
  updateNotifBadge();
}

/**
 * Fill any camera tiles on the machine cards with a fresh snapshot. Best-effort and
 * silent: a printer that is off or has no camera simply shows a placeholder.
 */
async function refreshMachineCameras() {
  const W = (typeof KhaytWebcam !== 'undefined') ? KhaytWebcam : null;
  if (!W || !window.hubAPI?.webcamSnapshot) return;
  for (const el of document.querySelectorAll('[data-cam]')) {
    const m = machines.find(x => x.id === el.dataset.cam);
    if (!m) continue;
    try {
      const tf = W.renderTransform(m.webcam);
      const style = `width:100%;height:100%;object-fit:cover;${tf ? `transform:${tf};` : ''}`;
      // A stream-only camera has no still to proxy — point the <img> straight at the
      // MJPEG stream, which browsers render natively. (The proxy deliberately refuses
      // to buffer a stream; see snapshotUrlFor.)
      if (!W.snapshotUrlFor(m) && m.webcam.streamUrl) {
        el.innerHTML = `<img src="${escapeHtml(m.webcam.streamUrl)}" alt="" style="${style}">`;
        continue;
      }
      const r = await window.hubAPI.webcamSnapshot({ machineId: m.id });
      if (r && r.ok && r.dataUrl) {
        /* safeImageSrc, NOT the raw string.
         *
         * `dataUrl` is built from the camera's own Content-Type header, and the
         * branch above already escapes `streamUrl` — this one did not. A device
         * answering the snapshot URL with
         *
         *     Content-Type: image/png" onerror="…
         *
         * passed the prefix check in checkSnapshotHeaders, survived fetch with
         * the quote intact, and closed the src attribute here: the browser saw
         * an onerror handler and ran it, in a renderer that holds window.hubAPI.
         * safeImageSrc requires `;base64,` immediately after a known image type,
         * so the crafted value resolves to '' instead. */
        const src = safeImageSrc(r.dataUrl);
        el.innerHTML = src ? `<img src="${src}" alt="" style="${style}">` : '';
      } else {
        // "Camera offline" was shown for every failure, including the one that
        // means the opposite: the printer answered promptly, about a camera it
        // has, that simply has no frame yet. Telling someone their camera is
        // offline while it warms up sends them to check a cable.
        const noFrame = r && r.error === 'no_frame_yet';
        const msg = noFrame
          ? (t('cam.no_frame') || 'No picture yet')
          : (t('cam.offline') || 'Camera offline');
        el.innerHTML = `<span style="font-size:11px;color:var(--text-muted);">${escapeHtml(msg)}</span>`;
      }
    } catch (e) {
      // Still must not break the machines view — but the tile was left reading "Camera…"
      // forever on a throw, while the !ok path correctly shows "Camera offline".
      console.error('webcamSnapshot failed:', e);
      try {
        el.innerHTML = `<span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('cam.offline') || 'Camera offline')}</span>`;
      } catch (_) { /* element gone — nothing to show */ }
    }
  }
}

function renderMachineDropdown() {
  const optionsHtml = `<option value="">${escapeHtml(t('mach.unassigned'))}</option>` +
    machines.map(m => `<option value="${m.id}">${escapeHtml(m.name)}${m.isOffline ? ' (' + escapeHtml(t('mach.offline_badge')) + ')' : ''}</option>`).join('');
  const sel = $('#machineAssign');
  if (sel) {
    const prev = sel.value;
    sel.innerHTML = optionsHtml;
    if (prev && machines.find(m => m.id === prev)) sel.value = prev;
  }
  // Also populate per-part machine select in calculator
  const partSel = $('#partMachineId');
  if (partSel) {
    const prev2 = partSel.value;
    partSel.innerHTML = optionsHtml;
    if (prev2 && machines.find(m => m.id === prev2)) partSel.value = prev2;
  }
}

function openMachineEditor(machineId = null) {
  const existing = machineId ? machines.find(m => m.id === machineId) : null;
  const draft = existing
    ? { ...existing }
    : { id: uid('MACH'), name: '', color: MACHINE_COLORS[machines.length % MACHINE_COLORS.length] };

  openFormModal({
    title: existing ? t('mach.edit') : t('mach.add'),
    sizeLg: false,
    bodyHtml: `
      <label>${escapeHtml(t('mach.name'))}</label>
      <input type="text" id="machName" value="${escapeHtml(draft.name)}" placeholder="${escapeHtml(t('mach.name_ph'))}">
      <label style="margin-top:12px;">${escapeHtml(t('mach.printer_model') || 'Printer model')}</label>
      <input type="text" id="machPrinterModel" list="machPrinterModelList" value="${escapeHtml(draft.printerModelName || '')}" placeholder="${escapeHtml(t('mach.printer_model_ph') || "Search — e.g. 'Bambu X1', 'Ender 3'")}" autocomplete="off">
      <datalist id="machPrinterModelList"></datalist>
      <div style="display:flex;align-items:center;gap:8px;margin-top:5px;">
        <button class="btn ghost small" id="btnScanNetwork" type="button">${escapeHtml(t('mach.scan_network'))}</button>
        <span id="machScanStatus" style="font-size:11px;color:var(--text-muted);"></span>
      </div>
      <div id="machScanResults" style="display:none;margin-top:6px;"></div>
      <div id="machPrinterModelHint" style="font-size:11px;color:var(--text-muted);margin-top:3px;">${escapeHtml(t('mach.printer_model_hint') || 'Pick a model to auto-fill nozzle, build volume, colours and power.')}</div>
      <label style="margin-top:12px;">${escapeHtml(t('mach.color'))}</label>
      <div id="machColorPicker" style="display:flex;gap:8px;margin-top:6px;flex-wrap:wrap;">
        ${MACHINE_COLORS.map(c => `
          <label style="cursor:pointer;">
            <input type="radio" name="machColor" value="${c}" ${draft.color === c ? 'checked' : ''} class="visually-hidden-input" aria-label="${escapeHtml(t('mach.color') || 'Colour')} ${escapeHtml(c)}">
            <span class="mach-color-swatch" style="background:${c};outline:${draft.color === c ? '3px solid #fff' : '3px solid transparent'};"></span>
          </label>`).join('')}
      </div>
      <div class="inline-pair" style="margin-top:14px;">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('mach.target_hours'))}</label>
          <input type="number" id="machTargetHours" value="${draft.targetHoursPerDay || ''}" min="0" step="0.5" placeholder="8">
        </div>
        <div style="padding-top:20px; font-size:11.5px; color:var(--text-muted);">${escapeHtml(t('mach.target_hours_hint'))}</div>
      </div>
      <div class="inline-pair" style="margin-top:14px;">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('mach.service_interval'))}</label>
          <input type="number" id="machServiceInterval" value="${draft.serviceInterval || ''}" min="0" step="1" placeholder="500">
        </div>
        <div>
          <label style="margin-top:0;">${escapeHtml(t('mach.last_service'))}</label>
          <input type="number" id="machLastServiceHours" value="${draft.lastServiceHours || ''}" min="0" step="0.1" placeholder="0">
        </div>
      </div>
      <label style="margin-top:14px;">${escapeHtml(t('mach.location'))}</label>
      <select id="machLocationId" style="margin-top:6px;">
        <option value="">— ${escapeHtml(t('an.unassigned_location'))} —</option>
        ${locations.map(l => `<option value="${escapeHtml(l.id)}"${draft.locationId === l.id ? ' selected' : ''}>${escapeHtml(l.name)}</option>`).join('')}
      </select>

      <label style="margin-top:16px; display:flex; align-items:center; gap:8px; cursor:pointer;">
        <input type="checkbox" id="machOffline" style="width:auto; margin:0;" ${draft.isOffline ? 'checked' : ''}>
        <span data-i18n="mach.mark_offline">${escapeHtml(t('mach.mark_offline'))}</span>
      </label>

      <div style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
        <label style="font-size:12.5px; font-weight:600; margin-bottom:8px;">${escapeHtml(t('mach.compat_materials'))}</label>
        <div id="machCompatMaterialsSection" style="display:flex;flex-wrap:wrap;gap:6px;margin-top:4px;"></div>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:10px; margin-top:12px;">
          <div>
            <label style="margin:0;">${escapeHtml(t('mach.nozzle_diameter'))}</label>
            <input type="number" id="machNozzleDiameter" value="${draft.nozzleDiameter || ''}" step="0.1" min="0.1" placeholder="0.4" style="font-size:12.5px;">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('mach.extruder_type'))}</label>
            <input type="text" id="machExtruderType" value="${escapeHtml(draft.extruderType || '')}" placeholder="Bowden / Direct Drive" style="font-size:12.5px;">
          </div>
        </div>
      </div>

      <div style="margin-top:16px; padding-top:14px; border-top:1px solid var(--border-soft);">
        <label style="font-size:12.5px; font-weight:600; margin:0 0 8px;">${escapeHtml(t('mach.nozzle'))}</label>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:10px; margin-top:8px;">
          <div>
            <label style="margin:0;">${escapeHtml(t('mach.nozzle_material'))}</label>
            <select id="machNozzleMaterial" style="font-size:12.5px;">
              <option value="brass"${(draft.nozzle?.material||'brass') === 'brass' ? ' selected' : ''}>${escapeHtml(t('mach.nozzle_brass'))}</option>
              <option value="hardened"${draft.nozzle?.material === 'hardened' ? ' selected' : ''}>${escapeHtml(t('mach.nozzle_hardened'))}</option>
              <option value="ruby"${draft.nozzle?.material === 'ruby' ? ' selected' : ''}>${escapeHtml(t('mach.nozzle_ruby'))}</option>
              <option value="stainless"${draft.nozzle?.material === 'stainless' ? ' selected' : ''}>Stainless</option>
              <option value="other"${draft.nozzle?.material === 'other' ? ' selected' : ''}>Other</option>
            </select>
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('mach.nozzle_installed'))}</label>
            <input type="date" id="machNozzleInstalledAt" value="${escapeHtml(draft.nozzle?.installedAt || '')}" style="font-size:12.5px;">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('mach.nozzle_threshold'))}</label>
            <input type="number" id="machNozzleGramsThreshold" value="${draft.nozzle?.gramsThreshold || KhaytNozzleWear.defaultThresholdFor(draft.nozzle?.material, settings)}" min="0" step="100" style="font-size:12.5px;">
            <p id="machNozzleHint" style="font-size:11px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('mach.nozzle_threshold_hint') || 'A starting point for this nozzle material — set your own once you know how yours wears.')}</p>
          </div>
          <div>
            <label style="margin:0;">${escapeHtml('Lifetime grams at install')}</label>
            <input type="number" id="machNozzleGramsAtInstall" value="${draft.nozzle?.gramsAtInstall || 0}" min="0" step="1" style="font-size:12.5px;">
          </div>
        </div>
      </div>

      <div style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
        <label style="display:flex;align-items:center;gap:8px;font-size:12.5px;font-weight:600;cursor:pointer;">
          <input type="checkbox" id="machWebcamEnabled" style="width:auto;margin:0;" ${draft.webcam?.enabled ? 'checked' : ''}>
          ${escapeHtml(t('cam.section') || 'Camera')}
        </label>
        <p style="font-size:11px;color:var(--text-muted);margin:6px 0 8px;">${escapeHtml(t('cam.hint') || 'Show a live view of this printer. The camera stays on your network — Khayt only reads it from the printer’s own address.')}</p>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;">
          <div>
            <label style="margin:0;">${escapeHtml(t('cam.snapshot_url') || 'Snapshot URL')}</label>
            <input type="text" id="machWebcamSnapshot" value="${escapeHtml(draft.webcam?.snapshotUrl || '')}" placeholder="/webcam/?action=snapshot" style="font-size:12px;">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('cam.stream_url') || 'Stream URL')}</label>
            <input type="text" id="machWebcamStream" value="${escapeHtml(draft.webcam?.streamUrl || '')}" placeholder="/webcam/?action=stream" style="font-size:12px;">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('cam.rotate') || 'Rotate')}</label>
            <select id="machWebcamRotate" style="font-size:12px;">
              ${[0, 90, 180, 270].map(r => `<option value="${r}"${(+(draft.webcam?.rotate || 0)) === r ? ' selected' : ''}>${r}°</option>`).join('')}
            </select>
          </div>
          <div style="display:flex;align-items:end;gap:12px;padding-bottom:4px;">
            <label style="display:flex;align-items:center;gap:6px;font-weight:400;font-size:12px;cursor:pointer;margin:0;">
              <input type="checkbox" id="machWebcamFlipH" style="width:auto;margin:0;" ${draft.webcam?.flipH ? 'checked' : ''}> ${escapeHtml(t('cam.flip_h') || 'Flip H')}</label>
            <label style="display:flex;align-items:center;gap:6px;font-weight:400;font-size:12px;cursor:pointer;margin:0;">
              <input type="checkbox" id="machWebcamFlipV" style="width:auto;margin:0;" ${draft.webcam?.flipV ? 'checked' : ''}> ${escapeHtml(t('cam.flip_v') || 'Flip V')}</label>
          </div>
        </div>
        <button type="button" class="btn small ghost" id="btnDetectWebcam" style="margin-top:10px;">${escapeHtml(t('cam.detect') || 'Detect from printer')}</button>
      </div>

      <div style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);" class="pro-only">
        <div style="display:flex; align-items:center; gap:8px; margin-bottom:8px;">
          <label style="margin:0; flex:1; font-size:12.5px; font-weight:600;">${escapeHtml(t('mach.downtime'))}</label>
          <button class="btn ghost small" id="btnAddDowntime" type="button">${escapeHtml(t('mach.downtime_add'))}</button>
        </div>
        <div id="downtimeBlocksList"></div>
      </div>

      <details style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);" class="pro-only">
        <summary style="cursor:pointer; font-size:12.5px; font-weight:600; color:var(--text-dim); user-select:none; padding:2px 0;">${escapeHtml(t('mach.api_live'))}</summary>
        <div style="margin-top:10px;">
          <label style="margin-top:0;">${escapeHtml(t('mach.api_type'))}</label>
          <select id="machApiType" style="font-size:12.5px;">
            <option value="none">${escapeHtml(t('common.none'))}</option>
            <option value="octoprint">OctoPrint</option>
            <option value="moonraker">Moonraker / Klipper</option>
            <option value="bambu">Bambu Lab (local network)</option>
            <option value="prusalink">PrusaLink (Prusa CORE One / MK4 / XL / Mini+)</option>
            <option value="duet">Duet / RepRapFirmware</option>
            <option value="repetier">Repetier-Server</option>
            <option value="sdcp">Elegoo resin (SDCP — Mars / Saturn)</option>
          </select>
          <div id="machApiFields" style="display:none; margin-top:8px;">
            <div class="inline-pair">
              <div>
                <label style="margin-top:0;">${escapeHtml(t('mach.api_host'))}</label>
                <input id="machApiHost" placeholder="192.168.1.50" style="font-size:12.5px;" value="${escapeHtml(draft.printerApi?.host || '')}">
              </div>
              <div>
                <label style="margin-top:0;">${escapeHtml(t('mach.api_port'))}</label>
                <input id="machApiPort" type="number" placeholder="default" style="font-size:12.5px;" value="${draft.printerApi?.port || ''}">
              </div>
            </div>
            <label style="margin-top:8px;">${escapeHtml(t('mach.api_key'))}</label>
            <input id="machApiKey" type="password" placeholder="API key / token" style="font-size:12.5px;" value="${escapeHtml(secretInputValue(draft.printerApi?.apiKey))}" autocomplete="off">
            <!-- One field, several names. A Duet has no API key: it has a machine
                 password (M551), and until now there was nowhere to put it, so a
                 password-protected Duet could not be polled at all — every
                 request answered 401 and the machine read as unreachable. Same
                 field, because it is the same thing from Khayt's side: the secret
                 that gets you in. Said out loud because "API key" is exactly what
                 stops someone typing their Duet password here. -->
            <div class="muted" style="font-size:11px;margin-top:4px;line-height:1.45;">
              ${escapeHtml(t('mach.api_key_hint') || 'PrusaLink calls this the Password (Settings → Network → PrusaLink). On a Duet it is the machine password from M551 — leave it empty if you have not set one.')}
            </div>
            <label style="margin-top:8px;">Access code (Bambu)</label>
            <input id="machApiAccessCode" type="password" placeholder="Bambu access code" style="font-size:12.5px;" value="${escapeHtml(secretInputValue(draft.printerApi?.accessCode))}" autocomplete="off">
            <!-- Said here rather than only in the error, because the error only
                 arrives after an eight-second wait that looks like a dead
                 printer. Developer Mode is a SEPARATE toggle from LAN-only Mode
                 and it is what actually opens MQTT; with it off the printer
                 accepts the connection and then answers nothing. -->
            <div class="muted" style="font-size:11px;margin-top:4px;line-height:1.45;">
              On the printer, turn on <b>LAN-only Mode</b> <i>and</i> <b>Developer Mode</b> — the access code is shown in that same screen. Developer Mode is what opens the connection Khayt uses; it also takes the printer off Bambu Cloud.
            </div>
            <!-- One field, two protocols: Bambu addresses a printer by its serial
                 and SDCP by its mainboard id, and both are the same thing here —
                 the string that identifies the machine on its own transport.
                 A network scan fills either one in, which matters more for SDCP
                 because a mainboard id is not printed anywhere on the printer. -->
            <label style="margin-top:8px;">Serial number (Bambu) / Mainboard ID (Elegoo SDCP)</label>
            <input id="machApiSerial" placeholder="e.g. 00M00A000000000" style="font-size:12.5px;" value="${escapeHtml(draft.printerApi?.serial || '')}" autocomplete="off">
            <label style="margin-top:8px;">Printer slug (Repetier)</label>
            <input id="machApiSlug" placeholder="default" style="font-size:12.5px;" value="${escapeHtml(draft.printerApi?.printerSlug || '')}">
            <div style="display:flex; align-items:center; gap:8px; margin-top:10px;">
              <button type="button" id="btnTestApi" class="btn small">${escapeHtml(t('mach.api_test'))}</button>
              <span id="apiTestResult" style="font-size:12px;"></span>
            </div>
          </div>
        </div>
      </details>`,
    onMount(modal) {
      if (!draft.downtimeBlocks) draft.downtimeBlocks = [];
      if (!draft.compatMaterials) draft.compatMaterials = [];
      if (!draft.nozzle) draft.nozzle = { material: 'brass', installedAt: '', gramsThreshold: KhaytNozzleWear.defaultThresholdFor('brass', settings), gramsAtInstall: 0 };
      if (!draft.printerApi) draft.printerApi = { type: 'none', host: '', port: '', apiKey: '', accessCode: '', serial: '', printerSlug: '' };
      modal.querySelector('#machName').addEventListener('input', e => { draft.name = e.target.value; });

      // Printer-model picker — auto-fill specs from the bundled catalog (works offline)
      // + the installed slicer's profiles (breadth). Selecting a model fills nozzle,
      // build volume, colour slots, extruder and typical power draw so nothing is typed by hand.
      (function wirePrinterModel() {
        const pmInput = modal.querySelector('#machPrinterModel');
        const pmList  = modal.querySelector('#machPrinterModelList');
        const pmHint  = modal.querySelector('#machPrinterModelHint');
        if (!pmInput) return;
        const PC = (typeof window !== 'undefined') ? window.KhaytPrinterCatalog : null;
        const catalog = PC ? PC.list() : [];
        let orcaNames = [];
        const rebuildList = () => {
          if (!pmList) return;
          const seen = new Set(); const uniq = [];
          for (const p of catalog) { const k = p.name.toLowerCase(); if (!seen.has(k)) { seen.add(k); uniq.push(p.name); } }
          for (const n of orcaNames) { const k = String(n).toLowerCase(); if (!seen.has(k)) { seen.add(k); uniq.push(n); } if (uniq.length > 1500) break; }
          pmList.innerHTML = uniq.map(n => `<option value="${escapeHtml(n)}"></option>`).join('');
        };
        rebuildList();
        if (window.hubAPI?.orcaPrinters) {
          window.hubAPI.orcaPrinters().then(r => {
            if (r && r.available && Array.isArray(r.printers) && r.printers.length) {
              orcaNames = r.printers.map(p => p.name).filter(Boolean);
              rebuildList();
            }
          }).catch(() => {});
        }
        const fillSpecs = (s, name) => {
          // What a model fills in is lib/machine-edit.js's `applySpecs`, so the
          // Mac app's machine sheet fills in the same things — including the
          // two rules that took a while to get right: the nozzle MATERIAL is
          // the point of the catalog knowing it, and an existing threshold is
          // never rewritten because the app cannot tell a default from a
          // decision. Both live in the module now, with their reasoning.
          MachineEdit.applySpecs(draft, s, name, { settings });
          // The draft is the record; these mirror it into the form the shop is
          // looking at, which is this window's job and not the rule's.
          const put = (sel, value) => { const el = modal.querySelector(sel); if (el && value != null) el.value = value; };
          put('#machName', draft.name);
          put('#machNozzleDiameter', draft.nozzleDiameter);
          put('#machExtruderType', draft.extruderType);
          if (draft.nozzle) {
            put('#machNozzleMaterial', draft.nozzle.material);
            const thEl = modal.querySelector('#machNozzleGramsThreshold');
            if (thEl && !thEl.value) thEl.value = draft.nozzle.gramsThreshold;
          }
          if (pmHint) {
            pmHint.textContent = MachineEdit.specsLine(s, { chamber: t('mach.chamber') })
              || (t('mach.printer_model_hint') || '');
          }
        };
        // Network scan — find printers that announce themselves over mDNS, so the owner
        // never types an IP address. Purely a suggestion: picking one fills the form, and
        // nothing is saved until they press Save like any other machine.
        (function wireNetworkScan() {
          const btn = modal.querySelector('#btnScanNetwork');
          const statusEl = modal.querySelector('#machScanStatus');
          const resultsEl = modal.querySelector('#machScanResults');
          if (!btn || !window.hubAPI?.discoverPrinters) { if (btn) btn.style.display = 'none'; return; }

          const applyFound = (p) => {
            // Specs first (via the catalog, when the advertised model matched one)…
            if (p.catalogId && PC) fillSpecs(PC.toMachineSpecs(p.catalogId), p.name);
            const pmEl = modal.querySelector('#machPrinterModel');
            if (pmEl && p.name) pmEl.value = p.name;
            const nameEl = modal.querySelector('#machName');
            if (nameEl && !nameEl.value.trim()) { nameEl.value = p.name; draft.name = p.name; }
            // …then the connection, but ONLY when Khayt actually has an adapter for it.
            // A printer we can identify but not drive must not get a half-configured
            // connection that silently never reports status.
            if (p.connection) {
              const typeEl = modal.querySelector('#machApiType');
              const hostEl = modal.querySelector('#machApiHost');
              const portEl = modal.querySelector('#machApiPort');
              if (typeEl) { typeEl.value = p.connection; typeEl.dispatchEvent(new Event('change')); }
              if (hostEl) hostEl.value = p.host;
              if (portEl && p.port) portEl.value = p.port;
              draft.printerApi = Object.assign({}, draft.printerApi, {
                type: p.connection, host: p.host, port: p.port || undefined,
                // The serial is the one thing about a printer a DHCP lease cannot
                // change, so it is what identifies this machine again if the
                // address moves. Recorded here because this is the moment it is
                // provable — once the printer has moved, its announcement no
                // longer matches the address on file and the best available match
                // has already dropped to a guess. See lib/printer-relocate.js.
                serial: p.serial || draft.printerApi?.serial || undefined,
              });
            }
            if (statusEl) statusEl.textContent = t('mach.scan_applied') || '';
            if (resultsEl) resultsEl.style.display = 'none';
          };

          btn.addEventListener('click', async () => {
            btn.disabled = true;
            if (statusEl) statusEl.textContent = t('mach.scan_running');
            if (resultsEl) { resultsEl.style.display = 'none'; resultsEl.innerHTML = ''; }
            let res;
            try { res = await window.hubAPI.discoverPrinters({ timeoutMs: 6000 }); }
            catch (_) { res = { ok: false }; }
            btn.disabled = false;
            const printers = (res && res.ok && Array.isArray(res.printers)) ? res.printers : [];
            if (!printers.length) {
              if (statusEl) statusEl.textContent = t('mach.scan_none');
              return;
            }

            // Is one of these THIS machine, at an address it has moved to?
            //
            // A DHCP lease moves overnight and Khayt goes on polling a host that
            // answers nothing. The owner sees "offline", which is also what a
            // switched-off printer says — so without this the scan lists the
            // printer they are looking for as if it were a new one, and they have
            // to notice the IP differs to understand what happened.
            //
            // Only ever a suggestion, like every other result here: picking it
            // fills the form and nothing is saved until Save. See
            // lib/printer-relocate.js for why a guess is never applied silently.
            let moved = null;
            try {
              const R = (typeof KhaytPrinterRelocate !== 'undefined') ? KhaytPrinterRelocate : null;
              if (R && draft.id && draft.printerApi && draft.printerApi.host) {
                // requireOffline is false: the owner opened this dialog and pressed
                // the button, which is a stronger signal than a missed poll.
                moved = R.planRelocations({
                  machines: [draft], discovered: printers, requireOffline: false,
                }).moves[0] || null;
              }
            } catch (_) { moved = null; }

            // Put it first. It is the answer to the question that made them scan.
            const ordered = moved
              ? [...printers].sort((a, b) => (b.host === moved.to) - (a.host === moved.to))
              : printers;

            if (statusEl) statusEl.textContent = '';
            if (!resultsEl) return;
            resultsEl.style.display = '';
            resultsEl.innerHTML = ordered.map((p, i) => {
              const isMoved = !!moved && p.host === moved.to;
              // Say plainly what Khayt can do with each result rather than implying
              // every discovered printer is connectable.
              const note = p.connection
                ? `${escapeHtml(p.host)}${p.port ? ':' + p.port : ''}`
                : escapeHtml(t('mach.scan_no_adapter'));
              // The old address is shown alongside the new one because that is the
              // whole explanation: nothing is broken, it is somewhere else.
              const movedBadge = isMoved
                ? `<div style="font-size:11px;color:var(--warning);margin-top:2px;">${_mIcoL('alert', '⚠', 12)}${escapeHtml(t('mach.scan_moved'))} — ${escapeHtml(moved.from)} → ${escapeHtml(moved.to)}</div>`
                : '';
              // NOTE: no cloud-mode warning. link_mode=wan means the printer is bound to
              // its vendor cloud, but that does NOT stop local control — the Snapmaker U1
              // serves a full Moonraker API on the LAN while in wan mode (verified).
              return `<div class="card" style="padding:7px 9px;margin-bottom:5px;display:flex;align-items:center;gap:9px;">
                <div style="flex:1;min-width:0;">
                  <div style="font-size:12.5px;font-weight:600;">${escapeHtml(p.name)}</div>
                  <div style="font-size:11px;color:var(--text-muted);">${note}</div>
                  ${movedBadge}
                </div>
                <button class="btn ${isMoved ? '' : 'ghost'} small" type="button" data-scan-pick="${i}">${escapeHtml(t('mach.scan_use'))}</button>
              </div>`;
            }).join('');
            resultsEl.querySelectorAll('[data-scan-pick]').forEach(el => {
              el.addEventListener('click', () => applyFound(ordered[+el.dataset.scanPick]));
            });
          });
        })();

        const applyModel = async (raw) => {
          const nm = (raw || '').trim();
          if (!nm) return;
          const hit = catalog.find(p => p.name.toLowerCase() === nm.toLowerCase());
          if (hit && PC) { fillSpecs(PC.toMachineSpecs(hit.id), hit.name); return; }
          if (window.hubAPI?.orcaMachineInfo) {
            try {
              const r = await window.hubAPI.orcaMachineInfo(nm);
              if (r && r.ok && r.info) {
                fillSpecs({
                  printerModel: nm, nozzleDiameter: r.info.nozzle, maxColors: r.info.colors,
                  bed: r.info.bed, flavour: r.info.gcodeFlavor,
                  extruderType: '', powerDraw: null,
                }, nm);
                return;
              }
            } catch (_) { /* fall through to free-text */ }
          }
          // Unknown model — keep it as a free-text label; specs stay whatever the user entered.
          draft.printerModel = nm; draft.printerModelName = nm;
        };
        pmInput.addEventListener('change', () => applyModel(pmInput.value));
      })();

      // Camera detect: ASK the printer, and only guess if it cannot answer.
      //
      // This button used to derive URLs from each family's convention and call
      // that "auto-detect". Moonraker and OctoPrint both publish what camera
      // they actually have, and lib/webcam.js could already read both replies —
      // nothing had ever called it. A convention is a guess; the printer's own
      // answer is not.
      //
      // It is the difference between the two Snapmaker U1 firmwares: stock
      // answers with an empty list, and the community extended firmware runs a
      // full Moonraker stack and names a real camera.
      modal.querySelector('#btnDetectWebcam')?.addEventListener('click', async () => {
        const W = (typeof KhaytWebcam !== 'undefined') ? KhaytWebcam : null;
        if (!W) return;
        const api = { type: modal.querySelector('#machApiType')?.value, host: modal.querySelector('#machApiHost')?.value };
        // `enabled` is only ticked for a camera that has actually answered. A
        // guess that gets switched on produces a machine card with a tile
        // reading "Camera offline" forever — seen on a Snapmaker U1 whose
        // webcam was enabled against :8080, an address nothing on that printer
        // has ever listened on. The URLs are still filled in either way, so
        // nothing is lost if the owner knows better than the probe.
        const fill = (snap, stream, verified) => {
          modal.querySelector('#machWebcamSnapshot').value = snap || '';
          modal.querySelector('#machWebcamStream').value = stream || '';
          const en = modal.querySelector('#machWebcamEnabled'); if (en) en.checked = !!verified;
        };

        // Only a saved machine can be queried: the main process resolves the
        // host from the STORED machine, never from anything this modal sends,
        // which is what stops the detect call being pointed anywhere.
        const saved = (typeof machines !== 'undefined') && machines.some((m) => m && m.id === draft.id);
        if (saved && W.detectPathFor(api) && window.hubAPI?.webcamDetect) {
          const r = await window.hubAPI.webcamDetect({ machineId: draft.id }).catch(() => null);
          if (r && r.ok && r.webcam) {
            // The printer named this camera itself, which is as verified as it gets.
            fill(r.webcam.snapshotUrl, r.webcam.streamUrl, true);
            toast(t('cam.detect_live') || 'Camera read from the printer — check the preview', 'success');
            return;
          }
          // An empty list is a real answer, not a failure: this printer has no
          // camera registered. Say that, then fall through to the guess rather
          // than leaving the owner with nothing.
          if (r && r.error === 'no_camera_registered') {
            toast(t('cam.detect_none_registered') || 'The printer reports no camera — filling the usual URLs to try', 'warning');
          }
        }

        // The printer had nothing to say, so the remaining options are guesses —
        // and there is more than one convention, so ask the printer which (if
        // either) is real rather than picking the first and hoping.
        if (saved && window.hubAPI?.webcamProbe) {
          const pr = await window.hubAPI.webcamProbe({ machineId: draft.id }).catch(() => null);
          if (pr && pr.ok && pr.found) {
            fill(pr.found.snapshotUrl, pr.found.streamUrl, true);
            toast(t('cam.detect_ok') || 'Camera URLs filled — check the preview', 'success');
            return;
          }
          if (pr && pr.ok) {
            // Nothing answered anywhere. Fill the usual address so the owner has
            // somewhere to start, but leave the camera OFF: switching on a
            // camera that did not answer is how a card ends up showing a
            // permanently blank tile.
            const g = W.deriveWebcamUrls(api);
            fill(g.snapshotUrl, g.streamUrl, false);
            toast(t('cam.probe_none') || 'No camera answered at the usual addresses — left switched off', 'warning', 6000);
            return;
          }
        }

        const guess = W.deriveWebcamUrls(api);
        if (!guess.snapshotUrl && !guess.streamUrl) { toast(t('cam.detect_none') || 'Set the printer type and address first', 'warning'); return; }
        // Unsaved machine, so there was nothing to probe against — the owner
        // checks the preview, as before.
        fill(guess.snapshotUrl, guess.streamUrl, true);
        toast(t('cam.detect_ok') || 'Camera URLs filled — check the preview', 'success');
      });

      // Feature 2 (new batch): Printer API section wiring
      const apiTypeSel = modal.querySelector('#machApiType');
      const apiFields  = modal.querySelector('#machApiFields');
      if (apiTypeSel) {
        apiTypeSel.value = draft.printerApi.type || 'none';
        const toggleApiFields = () => {
          if (apiFields) apiFields.style.display = apiTypeSel.value !== 'none' ? 'block' : 'none';
        };
        toggleApiFields();
        apiTypeSel.addEventListener('change', () => {
          draft.printerApi.type = apiTypeSel.value;
          toggleApiFields();
        });
      }
      modal.querySelector('#machApiHost')?.addEventListener('input', e => { draft.printerApi.host = e.target.value; });
      modal.querySelector('#machApiPort')?.addEventListener('input', e => { draft.printerApi.port = e.target.value ? parseInt(e.target.value) : null; });
      modal.querySelector('#machApiKey')?.addEventListener('input', e => { draft.printerApi.apiKey = e.target.value; });
      modal.querySelector('#machApiAccessCode')?.addEventListener('input', e => { draft.printerApi.accessCode = e.target.value; });
      modal.querySelector('#machApiSerial')?.addEventListener('input', e => { draft.printerApi.serial = e.target.value.trim(); });
      modal.querySelector('#machApiSlug')?.addEventListener('input', e => { draft.printerApi.printerSlug = e.target.value; });
      modal.querySelector('#btnTestApi')?.addEventListener('click', async () => {
        const resultEl = modal.querySelector('#apiTestResult');
        if (resultEl) resultEl.textContent = '…testing';
        try {
          if (window.hubAPI?.startPrinterPolling) {
            const testMachine = { id: draft.id, printerApi: { ...draft.printerApi } };
            await window.hubAPI.startPrinterPolling([testMachine]);
            const cache = await window.hubAPI.getPrinterStatus();
            if (resultEl) {
              const s = cache[draft.id];
              if (s?.error) {
                // The owner is standing in the dialog that can fix it, so this is
                // the best possible moment to say "it moved" rather than "it timed
                // out" — Scan network is one button away and will offer the swap.
                const hint = (typeof KhaytPrinterRelocate !== 'undefined')
                  ? KhaytPrinterRelocate.relocationHint(s) : null;
                resultEl.textContent = hint
                  ? t('mach.moved_found', { host: hint.to })
                  : t('mach.api_fail') + ': ' + s.error;
                resultEl.style.color = hint ? 'var(--warning)' : 'var(--danger)';
              } else if (s) {
                resultEl.textContent = t('mach.api_ok') + ' — ' + (s.state || '');
                resultEl.style.color = 'var(--success)';
              }
            }
          }
        } catch(e) {
          if (resultEl) { resultEl.textContent = t('mach.api_fail'); resultEl.style.color = 'var(--danger)'; }
        }
      });

      // Compat materials checkboxes (Feature 3)
      const compatEl = modal.querySelector('#machCompatMaterialsSection');
      if (compatEl) {
        const COMMON_MATS = ['PLA', 'PETG', 'ABS', 'ASA', 'TPU', 'PA/Nylon', 'PC', 'PVA', 'HIPS', 'Resin'];
        const allMats = [...new Set([...COMMON_MATS, ...inventory.map(i => i.material).filter(Boolean)])];
        compatEl.innerHTML = allMats.map(mat => {
          const checked = draft.compatMaterials.includes(mat);
          return `<label style="display:flex;align-items:center;gap:4px;font-size:12px;cursor:pointer;background:var(--surface-2);padding:3px 8px;border-radius:4px;border:1px solid ${checked ? 'var(--primary)' : 'var(--border)'};">
            <input type="checkbox" class="compat-mat-cb" data-mat="${escapeHtml(mat)}" style="width:auto;margin:0;" ${checked ? 'checked' : ''}>
            ${escapeHtml(mat)}
          </label>`;
        }).join('');
        compatEl.querySelectorAll('.compat-mat-cb').forEach(cb => {
          cb.addEventListener('change', () => {
            const m = cb.dataset.mat;
            if (cb.checked) { if (!draft.compatMaterials.includes(m)) draft.compatMaterials.push(m); }
            else { draft.compatMaterials = draft.compatMaterials.filter(x => x !== m); }
            cb.closest('label').style.borderColor = cb.checked ? 'var(--primary)' : 'var(--border)';
          });
        });
      }
      // Nozzle field listeners (Feature 4)
      modal.querySelector('#machNozzleDiameter')?.addEventListener('input', e => { draft.nozzleDiameter = parseFloat(e.target.value) || null; });
      modal.querySelector('#machExtruderType')?.addEventListener('input', e => { draft.extruderType = e.target.value; });
      modal.querySelector('#machNozzleMaterial')?.addEventListener('change', e => {
        draft.nozzle.material = e.target.value;
        // SUGGEST, DO NOT REWRITE. Changing which nozzle is fitted does not
        // give the app permission to change a threshold the shop set — see the
        // comment in fillSpecs. The hint says what this material is usually
        // good for and leaves the decision alone.
        const field = modal.querySelector('#machNozzleGramsThreshold');
        const hint = modal.querySelector('#machNozzleHint');
        const suggested = KhaytNozzleWear.defaultThresholdFor(e.target.value, settings);
        if (field && !field.value) { field.value = suggested; draft.nozzle.gramsThreshold = suggested; }
        else if (hint) {
          hint.textContent = (t('mach.nozzle_suggest') || 'Usually about')
            + ` ${suggested.toLocaleString()} g `
            + (t('mach.nozzle_suggest_tail') || 'for this nozzle — yours is yours to set.');
        }
      });
      modal.querySelector('#machNozzleInstalledAt')?.addEventListener('change', e => { draft.nozzle.installedAt = e.target.value; });
      modal.querySelector('#machNozzleGramsThreshold')?.addEventListener('input', e => { draft.nozzle.gramsThreshold = parseFloat(e.target.value) || KhaytNozzleWear.defaultThresholdFor(draft.nozzle?.material, settings); });
      modal.querySelector('#machNozzleGramsAtInstall')?.addEventListener('input', e => { draft.nozzle.gramsAtInstall = parseFloat(e.target.value) || 0; });
      modal.querySelectorAll('input[name="machColor"]').forEach(radio => {
        radio.addEventListener('change', () => {
          draft.color = radio.value;
          modal.querySelectorAll('.mach-color-swatch').forEach((s, i) => {
            s.style.outline = `3px solid ${MACHINE_COLORS[i] === draft.color ? '#fff' : 'transparent'}`;
          });
        });
      });
      modal.querySelector('#machOffline').addEventListener('change', e => { draft.isOffline = e.target.checked; });
      modal.querySelector('#machTargetHours').addEventListener('input', e => { draft.targetHoursPerDay = Math.max(0, +e.target.value || 0) || null; });
      modal.querySelector('#machServiceInterval').addEventListener('input', e => { draft.serviceInterval = parseFloat(e.target.value) || 0; });
      modal.querySelector('#machLastServiceHours').addEventListener('input', e => { draft.lastServiceHours = parseFloat(e.target.value) || 0; });

      // Downtime blocks
      function renderDowntimeList() {
        const el = modal.querySelector('#downtimeBlocksList');
        if (!el) return;
        if (!draft.downtimeBlocks || draft.downtimeBlocks.length === 0) {
          el.innerHTML = `<div style="color:var(--text-muted);font-size:12.5px;padding:4px 0;">${escapeHtml(t('mach.empty') || 'No downtime blocks.')}</div>`;
          return;
        }
        el.innerHTML = draft.downtimeBlocks.map((b, i) => `
          <div style="display:grid; grid-template-columns:1fr 1fr auto auto; gap:6px; align-items:center; margin-bottom:6px; font-size:12px;">
            <input type="datetime-local" class="dt-from" data-dti="${i}" value="${escapeHtml(b.from || '')}" style="font-size:11.5px;">
            <input type="datetime-local" class="dt-to" data-dti="${i}" value="${escapeHtml(b.to || '')}" style="font-size:11.5px;">
            <input type="text" class="dt-reason" data-dti="${i}" value="${escapeHtml(b.reason || '')}" placeholder="${escapeHtml(t('mach.downtime_reason'))}" style="font-size:11.5px; min-width:80px;">
            <button class="btn danger small dt-rm" data-dti="${i}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
          </div>`).join('');
        el.querySelectorAll('.dt-from').forEach(inp => { inp.addEventListener('change', () => { draft.downtimeBlocks[+inp.dataset.dti].from = inp.value; }); });
        el.querySelectorAll('.dt-to').forEach(inp => { inp.addEventListener('change', () => { draft.downtimeBlocks[+inp.dataset.dti].to = inp.value; }); });
        el.querySelectorAll('.dt-reason').forEach(inp => { inp.addEventListener('input', () => { draft.downtimeBlocks[+inp.dataset.dti].reason = inp.value; }); });
        el.querySelectorAll('.dt-rm').forEach(btn => {
          btn.addEventListener('click', () => { draft.downtimeBlocks.splice(+btn.dataset.dti, 1); renderDowntimeList(); });
        });
      }
      renderDowntimeList();
      modal.querySelector('#btnAddDowntime').addEventListener('click', () => {
        if (!draft.downtimeBlocks) draft.downtimeBlocks = [];
        draft.downtimeBlocks.push({ id: uid('DT'), from: '', to: '', reason: '' });
        renderDowntimeList();
      });
    },
    async onSave() {
      if (!draft.name.trim()) { toast(t('mach.need_name'), 'error'); return false; }
      draft.downtimeBlocks = (draft.downtimeBlocks || []).filter(b => b.from && b.to);
      // Feature 2 (new batch): Persist printer API config from modal
      const apiTypeFinal = document.getElementById('machApiType');
      if (apiTypeFinal) {
        draft.printerApi = {
          type:         apiTypeFinal.value || 'none',
          host:         document.getElementById('machApiHost')?.value.trim() || '',
          port:         document.getElementById('machApiPort')?.value ? parseInt(document.getElementById('machApiPort').value) : null,
          apiKey:       secretInputSave(draft.printerApi?.apiKey, document.getElementById('machApiKey')?.value),
          accessCode:   document.getElementById('machApiAccessCode')?.value.trim() || '',
          printerSlug:  document.getElementById('machApiSlug')?.value.trim() || '',
        };
      }
      // Webcam block — normalized + clamped through the shared sanitizer.
      const W = (typeof KhaytWebcam !== 'undefined') ? KhaytWebcam : null;
      if (W) {
        draft.webcam = W.sanitizeWebcam({
          enabled: document.getElementById('machWebcamEnabled')?.checked,
          snapshotUrl: document.getElementById('machWebcamSnapshot')?.value,
          streamUrl: document.getElementById('machWebcamStream')?.value,
          rotate: document.getElementById('machWebcamRotate')?.value,
          flipH: document.getElementById('machWebcamFlipH')?.checked,
          flipV: document.getElementById('machWebcamFlipV')?.checked,
          timelapse: draft.webcam?.timelapse,
          cloudRelay: draft.webcam?.cloudRelay,
        }, draft.printerApi);
      }
      // Persist nozzle/compat fields from form (Feature 3 & 4)
      const nozzleDiamEl = document.getElementById('machNozzleDiameter');
      if (nozzleDiamEl) draft.nozzleDiameter = parseFloat(nozzleDiamEl.value) || null;
      const extruderTypeEl = document.getElementById('machExtruderType');
      if (extruderTypeEl) draft.extruderType = extruderTypeEl.value.trim() || null;
      const nozzleMatEl = document.getElementById('machNozzleMaterial');
      const nozzleInstEl = document.getElementById('machNozzleInstalledAt');
      const nozzleThreshEl = document.getElementById('machNozzleGramsThreshold');
      const nozzleAtInstEl = document.getElementById('machNozzleGramsAtInstall');
      if (nozzleMatEl) {
        draft.nozzle = {
          material: nozzleMatEl.value || 'brass',
          installedAt: nozzleInstEl?.value || '',
          gramsThreshold: parseFloat(nozzleThreshEl?.value) || KhaytNozzleWear.defaultThresholdFor(nozzleMatEl?.value, settings),
          gramsAtInstall: parseFloat(nozzleAtInstEl?.value) || 0,
        };
      }
      // Persist locationId
      const machLocEl = document.getElementById('machLocationId');
      if (machLocEl) draft.locationId = machLocEl.value || '';
      const idx = machines.findIndex(m => m.id === draft.id);
      if (idx >= 0) machines[idx] = draft;
      else machines.push(draft);
      saveAll();
      renderMachines();
      renderMachineDropdown();
      // Live polling was started ONCE, at boot, from whatever machines existed then — so a
      // printer added or reconnected afterwards never went live until the app was
      // restarted. Restart it here so a machine works the moment it is saved.
      refreshPrinterPolling();
      toast(t('mach.saved'), 'success');
      return true;
    }
  });
}

/**
 * (Re)start live polling for every machine that has a connection configured.
 *
 * app-boot calls startPrinterPolling once at startup with the machines present at that
 * moment. Adding a printer, changing its address, or switching its connection type had no
 * effect until the next launch — the machine simply never appeared as live, which is
 * exactly what a new user hits after running "Scan network" for the first time.
 */
function refreshPrinterPolling() {
  try {
    if (!window.hubAPI?.startPrinterPolling) return;
    const apiMachines = (typeof machines !== 'undefined' ? machines : [])
      .filter((m) => m.printerApi && m.printerApi.type && m.printerApi.type !== 'none');
    if (!apiMachines.length) return;
    window.hubAPI.startPrinterPolling(apiMachines).then((cache) => {
      if (typeof machineStatusCache !== 'undefined') machineStatusCache = cache || {};
      if (typeof updateKanbanLiveStatus === 'function') updateKanbanLiveStatus();
      // Re-RENDER the dashboard, not just refresh the tile grid. renderDashLivePrinters()
      // returns '' when no machine has a connection, so the panel does not exist at all
      // until one does — and updateDashLivePrinters() only fills a grid that is already on
      // screen. After adding the first printer there was nothing to fill, so the fleet
      // stayed invisible even once polling returned live data.
      if (typeof renderDashboard === 'function') renderDashboard();
      else if (typeof updateDashLivePrinters === 'function') updateDashLivePrinters();
      if (typeof renderMachines === 'function') renderMachines();
    }).catch((e) => console.error('startPrinterPolling:', e));
  } catch (e) { console.error('refreshPrinterPolling:', e); }
}

function logNozzleChange(machineId) {
  const machine = machines.find(m => m.id === machineId);
  if (!machine) return;
  const totalGrams = machineGramsSinceNozzle(machine);
  openFormModal({
    title: `${machine.name} — ${t('mach.log_nozzle')}`,
    sizeLg: false,
    saveLabel: t('common.save'),
    bodyHtml: `
      <label>${escapeHtml(t('mach.nozzle_material'))}</label>
      <select id="nlNozzleMat" style="margin-bottom:10px;">
        <option value="brass">${escapeHtml(t('mach.nozzle_brass'))}</option>
        <option value="hardened">${escapeHtml(t('mach.nozzle_hardened'))}</option>
        <option value="ruby">${escapeHtml(t('mach.nozzle_ruby'))}</option>
        <option value="stainless">Stainless</option>
        <option value="other">Other</option>
      </select>
      <label>${escapeHtml(t('mach.nozzle_installed'))}</label>
      <input type="date" id="nlInstalledAt" value="${localDateStr()}">
      <label style="margin-top:10px;">${escapeHtml(t('mach.nozzle_threshold'))}</label>
      <input type="number" id="nlThreshold" value="${machine.nozzle?.gramsThreshold || KhaytNozzleWear.defaultThresholdFor(machine.nozzle?.material, settings)}" min="0" step="100">
      <p style="font-size:11px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('mach.nozzle_threshold_hint') || 'A starting point for this nozzle material — set your own once you know how yours wears.')}</p>
      <p style="font-size:12px;color:var(--text-muted);margin-top:8px;">
        Lifetime grams at install: <strong>${totalGrams.toFixed(0)}g</strong>
      </p>`,
    onMount(modal) {
      // Pre-select what is actually fitted — the dropdown always opened on brass
      // regardless — and let the threshold follow a change of nozzle, but only
      // while it still holds a suggested value. A typed number is a decision.
      const sel = modal.querySelector('#nlNozzleMat');
      const field = modal.querySelector('#nlThreshold');
      if (sel) sel.value = machine.nozzle?.material || 'brass';
      sel?.addEventListener('change', () => {
        // Only when the shop has left it blank. Fitting a different nozzle is
        // not consent to rewrite a figure they chose.
        if (field && !field.value) field.value = KhaytNozzleWear.defaultThresholdFor(sel.value, settings);
      });
    },
    async onSave(modal) {
      const mat       = modal.querySelector('#nlNozzleMat').value;
      const installed = modal.querySelector('#nlInstalledAt').value;
      const threshold = parseFloat(modal.querySelector('#nlThreshold').value) || KhaytNozzleWear.defaultThresholdFor(mat, settings);
      const idx = machines.findIndex(m => m.id === machineId);
      if (idx < 0) return false;
      machines[idx].nozzle = {
        material: mat,
        installedAt: installed,
        gramsThreshold: threshold,
        gramsAtInstall: totalGrams,
      };
      saveAll();
      renderMachines();
      toast(t('mach.nozzle_done'), 'success');
      return true;
    }
  });
}

async function deleteMachine(machineId) {
  const inUse = printLog.some(o => o.machineId === machineId && o.status !== 'completed');
  const msg = inUse ? t('mach.delete_active_q') : t('mach.delete_q');
  const ok = await confirmModal(msg, { danger: true });
  if (!ok) return;
  machines = machines.filter(m => m.id !== machineId);
  saveAll();
  renderMachines();
  renderMachineDropdown();
  if (typeof refreshMachineCameras === 'function') refreshMachineCameras();
}

/* ============================================================
   Printer Maintenance Log
   ============================================================ */
function openMaintLog(machineId) {
  const machine = machines.find(m => m.id === machineId);
  if (!machine) return;

  const getEntries = () => machMaintLog.filter(e => e.machineId === machineId)
    .sort((a, b) => b.date.localeCompare(a.date));

  function listHtml() {
    const list = getEntries();
    if (list.length === 0)
      return `<p style="color:var(--text-muted);font-size:13px;text-align:center;padding:16px 0;">${escapeHtml(t('maint.empty'))}</p>`;
    return `<div class="table-wrap"><table>
      <thead><tr>
        <th>${escapeHtml(t('maint.date'))}</th>
        <th>${escapeHtml(t('maint.note'))}</th>
        <th>${escapeHtml(t('maint.cost'))}</th>
        <th></th>
      </tr></thead>
      <tbody>${list.map(e => `
        <tr>
          <td style="white-space:nowrap;">${escapeHtml(e.date)}</td>
          <td>${escapeHtml(e.note || '')}</td>
          <td style="white-space:nowrap;">${e.cost > 0 ? fmtPrice(e.cost) : '—'}</td>
          <td><button class="btn danger small" data-act="del-maint" data-id="${e.id}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button></td>
        </tr>`).join('')}
      </tbody>
    </table></div>`;
  }

  // Recurring preventive-maintenance tasks (Feature: maintenance scheduler).
  const STATUS_COLOR = { overdue: 'var(--danger)', due: 'var(--danger)', warning: 'var(--warning,#d97706)', ok: 'var(--text-muted)' };
  function taskListHtml() {
    const tasks = (typeof machMaintTasks !== 'undefined' ? machMaintTasks : []).filter(tk => tk.machineId === machineId);
    if (!tasks.length)
      return `<p style="color:var(--text-muted);font-size:13px;text-align:center;padding:10px 0;">${escapeHtml(t('maint.no_tasks') || 'No recurring tasks')}</p>`;
    const hours = machineHoursMeter(machineId);
    return `<div class="table-wrap"><table><tbody>${tasks.map(tk => {
      const st = (typeof KhaytMaintenance !== 'undefined') ? KhaytMaintenance.taskStatus(tk, hours, Date.now()) : { status: 'ok' };
      const every = tk.intervalHours ? `${tk.intervalHours}h` : (tk.intervalDays ? `${tk.intervalDays}d` : '—');
      return `<tr>
        <td><strong>${escapeHtml(tk.name || '')}</strong><br><span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('maint.every') || 'every')} ${every}</span></td>
        <td style="white-space:nowrap;color:${STATUS_COLOR[st.status] || 'var(--text-muted)'};font-weight:600;font-size:12px;">${escapeHtml(t('maint.status_' + st.status) || st.status)}</td>
        <td style="white-space:nowrap;text-align:right;">
          <button class="btn small" data-act="mt-done" data-id="${tk.id}">${escapeHtml(t('maint.mark_done') || 'Done')}</button>
          <button class="btn danger small" data-act="mt-del" data-id="${tk.id}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
        </td></tr>`;
    }).join('')}</tbody></table></div>`;
  }

  openFormModal({
    title: `${machine.name} — ${t('maint.title')}`,
    noSave: true,
    sizeLg: true,
    bodyHtml: `
      <div style="background:var(--surface-2);padding:14px;border-radius:var(--radius);margin-bottom:14px;">
        <div style="display:grid;grid-template-columns:1fr 2fr 1fr;gap:8px;align-items:end;">
          <div>
            <label style="margin:0;">${escapeHtml(t('maint.date'))}</label>
            <input type="date" id="maintDate" value="${localDateStr()}" max="${localDateStr()}">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('maint.note'))}</label>
            <input type="text" id="maintNote" placeholder="${escapeHtml(t('maint.note_ph'))}">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('maint.cost'))} (${currencySymbol()})</label>
            <input type="number" id="maintCost" value="0" min="0" step="0.01">
          </div>
        </div>
        <div style="display:flex;align-items:center;gap:10px;margin-top:10px;">
          <label style="display:flex;align-items:center;gap:6px;cursor:pointer;margin:0;font-size:12.5px;">
            <input type="checkbox" id="maintAddExpense" style="width:auto;margin:0;">
            <span>${escapeHtml(t('maint.expense_q'))}</span>
          </label>
          <button class="btn primary small" id="btnAddMaintEntry">${escapeHtml(t('maint.add'))}</button>
        </div>
      </div>
      <div style="margin-bottom:6px;font-weight:600;font-size:13px;">${escapeHtml(t('maint.recurring') || 'Recurring maintenance')}</div>
      <div style="background:var(--surface-2);padding:12px;border-radius:var(--radius);margin-bottom:8px;">
        <div style="display:grid;grid-template-columns:2fr 1fr 1fr auto;gap:8px;align-items:end;">
          <div><label style="margin:0;">${escapeHtml(t('maint.task_name') || 'Task')}</label><input type="text" id="mtName" placeholder="${escapeHtml(t('maint.task_ph') || 'e.g. Replace nozzle')}"></div>
          <div><label style="margin:0;">${escapeHtml(t('maint.every_hours') || 'Every (hours)')}</label><input type="number" id="mtHours" min="0" step="1"></div>
          <div><label style="margin:0;">${escapeHtml(t('maint.or_days') || 'or (days)')}</label><input type="number" id="mtDays" min="0" step="1"></div>
          <button class="btn primary small" id="btnAddMaintTask">${escapeHtml(t('maint.add') )}</button>
        </div>
      </div>
      <div id="maintTasksList" style="margin-bottom:16px;">${taskListHtml()}</div>
      <div id="maintEntriesList">${listHtml()}</div>`,
    onMount(modal) {
      const refresh = () => {
        const el = modal.querySelector('#maintEntriesList');
        if (el) el.innerHTML = listHtml();
      };
      const refreshTasks = () => {
        const el = modal.querySelector('#maintTasksList');
        if (el) el.innerHTML = taskListHtml();
      };
      modal.querySelector('#btnAddMaintTask')?.addEventListener('click', () => {
        const name = modal.querySelector('#mtName').value.trim();
        const intervalHours = Math.max(0, +(modal.querySelector('#mtHours').value) || 0);
        const intervalDays = Math.max(0, +(modal.querySelector('#mtDays').value) || 0);
        if (!name) { toast(t('maint.need_name') || t('maint.need_note'), 'error'); return; }
        if (!intervalHours && !intervalDays) { toast(t('maint.need_interval') || 'Set an interval', 'error'); return; }
        machMaintTasks.push({
          id: uid('MTASK'), machineId, name,
          intervalHours: intervalHours || null, intervalDays: intervalDays || null,
          lastDoneHours: machineHoursMeter(machineId), lastDoneAt: new Date().toISOString(),
        });
        saveAll();
        modal.querySelector('#mtName').value = '';
        modal.querySelector('#mtHours').value = '';
        modal.querySelector('#mtDays').value = '';
        refreshTasks();
        toast(t('maint.saved'), 'success');
      });
      modal.querySelector('#maintTasksList')?.addEventListener('click', async (e) => {
        const doneBtn = e.target.closest('[data-act="mt-done"]');
        const delBtn = e.target.closest('[data-act="mt-del"]');
        if (doneBtn) {
          const tk = machMaintTasks.find(x => x.id === doneBtn.dataset.id);
          if (!tk) return;
          const patch = KhaytMaintenance.markDone(tk, machineHoursMeter(machineId), new Date().toISOString());
          Object.assign(tk, patch);
          const today = localDateStr();
          machMaintLog.unshift({ id: uid('MAINT'), machineId, date: today, note: tk.name, cost: 0 });
          saveAll();
          refreshTasks(); refresh();
          toast(t('maint.saved'), 'success');
        } else if (delBtn) {
          const ok = await confirmModal(t('common.delete') + '?', { danger: true });
          if (!ok) return;
          machMaintTasks = machMaintTasks.filter(x => x.id !== delBtn.dataset.id);
          saveAll();
          refreshTasks();
          toast(t('maint.deleted'), 'success');
        }
      });
      modal.querySelector('#btnAddMaintEntry').addEventListener('click', () => {
        const date  = modal.querySelector('#maintDate').value || localDateStr();
        const note  = modal.querySelector('#maintNote').value.trim();
        const cost  = Math.max(0, +(modal.querySelector('#maintCost').value) || 0);
        const addExp = modal.querySelector('#maintAddExpense').checked;
        if (!note) { toast(t('maint.need_note'), 'error'); return; }
        machMaintLog.unshift({ id: uid('MAINT'), machineId, date, note, cost });
        if (addExp && cost > 0) {
          expenses.unshift({ id: uid('EXP'), date, category: 'maintenance', amount: cost,
            note: `${machine.name}: ${note}` });
        }
        saveAll();
        modal.querySelector('#maintNote').value  = '';
        modal.querySelector('#maintCost').value  = '0';
        modal.querySelector('#maintAddExpense').checked = false;
        refresh();
        toast(t('maint.saved'), 'success');
      });
      modal.querySelector('#maintEntriesList').addEventListener('click', async (e) => {
        const btn = e.target.closest('[data-act="del-maint"]');
        if (!btn) return;
        const ok = await confirmModal(t('common.delete') + '?', { danger: true });
        if (!ok) return;
        machMaintLog = machMaintLog.filter(e => e.id !== btn.dataset.id);
        saveAll();
        refresh();
        toast(t('maint.deleted'), 'success');
      });
    }
  });
}

/* ============================================================
   Machine hour meter + service status (Feature 1)
   ============================================================ */
function machineHoursMeter(machineId) {
  // The rule itself lives in lib/maintenance.js, because the Mac app measures
  // every maintenance interval against this same number and two definitions of
  // "which jobs count" is two answers to when a nozzle is due.
  return KhaytMaintenance.hoursMeter(printLog, machineId);
}

function machineServiceStatus(machine) {
  const totalHours = machineHoursMeter(machine.id);
  // "Hours at last service" is a reading off the printer's own clock, so it can be far
  // larger than anything this app has logged — see KhaytMaintenance.hoursSinceService for
  // why subtracting one from the other showed "-200.0h since service" and left the
  // reminder unable to fire.
  const M = (typeof KhaytMaintenance !== 'undefined') ? KhaytMaintenance : null;
  const hoursSinceService = M
    ? M.hoursSinceService({
      totalHours,
      lastServiceHours: machine.lastServiceHours,
      lastServiceAt: machine.lastServiceAt,
      jobs: printLog.filter((o) => o && o.machineId === machine.id && o.status === 'completed'),
    })
    : Math.max(0, totalHours - (machine.lastServiceHours || 0));
  if (machine.serviceInterval > 0) {
    if (hoursSinceService >= machine.serviceInterval) {
      return { due: true, hours: hoursSinceService, interval: machine.serviceInterval, total: totalHours };
    }
    if (hoursSinceService >= machine.serviceInterval * 0.9) {
      return { warning: true, hours: hoursSinceService, interval: machine.serviceInterval, total: totalHours };
    }
  }
  return { ok: true, hours: hoursSinceService, interval: machine.serviceInterval || 0, total: totalHours };
}

function logMachineService(machineId) {
  const machine = machines.find(m => m.id === machineId);
  if (!machine) return;
  openFormModal({
    title: `${t('mach.log_service')} — ${escapeHtml(machine.name)}`,
    sizeLg: false,
    saveLabel: t('mach.log_service'),
    bodyHtml: `
      <label>${escapeHtml(t('mach.service_note'))}</label>
      <input type="text" id="svcNoteInput" placeholder="${escapeHtml(t('maint.note_ph'))}">
      <p style="font-size:12px; color:var(--text-muted); margin:8px 0 0;">
        ${escapeHtml(t('mach.hours_total'))}: <strong>${machineHoursMeter(machineId).toFixed(1)}h</strong>
      </p>`,
    onMount(modal) { setTimeout(() => modal.querySelector('#svcNoteInput')?.focus(), 40); },
    async onSave(modal) {
      const note = modal.querySelector('#svcNoteInput').value.trim();
      const totalHrs = machineHoursMeter(machineId);
      machine.lastServiceHours = totalHrs;
      // The moment, not just the meter. Hours-since-service is counted from here, which
      // is the only figure that stays right when the owner's "hours at last service" is
      // a reading off the printer rather than this app's own tally.
      machine.lastServiceAt = new Date().toISOString();
      const today = localDateStr();
      machMaintLog.unshift({ id: uid('MAINT'), machineId, date: today, note: note || t('mach.log_service'), cost: 0 });
      saveAll();
      renderMachines();
      renderDashboard();
      toast(t('mach.service_done'), 'success');
      return true;
    }
  });
}

/* ============================================================
   WhatsApp Quick-Reply Templates
   ============================================================ */
function renderWaTemplates() {
  const el = $('#waTemplatesList');
  if (!el) return;
  if (waTemplates.length === 0) {
    el.innerHTML = `<p class="empty-state" style="padding:8px 0; font-size:13px;">${escapeHtml(t('wa.no_templates_hint'))}</p>`;
    return;
  }
  el.innerHTML = waTemplates.map(tpl => `
    <div class="wa-tpl-row">
      <div class="wa-tpl-info">
        <span class="wa-tpl-name">${escapeHtml(tpl.name)}</span>
        <span class="wa-tpl-preview">${escapeHtml(tpl.body.slice(0, 70))}${tpl.body.length > 70 ? '…' : ''}</span>
      </div>
      <div class="wa-tpl-actions">
        <button class="btn small" data-act="edit-wa-tpl" data-id="${tpl.id}">${escapeHtml(t('common.edit'))}</button>
        <button class="btn danger small" data-act="del-wa-tpl" data-id="${tpl.id}">${escapeHtml(t('common.delete'))}</button>
      </div>
    </div>`).join('');
}

function openWaTemplateEditor(tplId = null) {
  const existing = tplId ? waTemplates.find(x => x.id === tplId) : null;
  const draft = existing ? { ...existing } : { id: uid('WATPL'), name: '', body: '' };
  const bodyHtml = `
    <label>${escapeHtml(t('wa.tpl_name'))}</label>
    <input type="text" id="waTplName" value="${escapeHtml(draft.name)}" placeholder="${escapeHtml(t('wa.tpl_name_ph'))}">
    <label style="margin-top:10px;">${escapeHtml(t('wa.tpl_body'))}</label>
    <textarea id="waTplBody" rows="5" style="resize:vertical;">${escapeHtml(draft.body)}</textarea>
    <p style="font-size:11.5px; color:var(--text-muted); margin:6px 0 0;" data-i18n="wa.tpl_hint"></p>
    <p style="font-size:11px; color:var(--text-muted); margin:2px 0 0; font-family:monospace;">{{client}} · {{id}} · {{price}} · {{due}} · {{status}}</p>
  `;
  openFormModal({
    title: existing ? t('wa.edit_tpl') : t('wa.new_tpl'),
    saveLabel: t('common.save'),
    bodyHtml,
    async onSave(modal) {
      draft.name = modal.querySelector('#waTplName').value.trim();
      draft.body = modal.querySelector('#waTplBody').value.trim();
      if (!draft.name) { toast(t('wa.tpl_need_name'), 'error'); return false; }
      if (!draft.body) { toast(t('wa.tpl_need_body'), 'error'); return false; }
      const idx = waTemplates.findIndex(x => x.id === draft.id);
      if (idx >= 0) waTemplates[idx] = draft; else waTemplates.push(draft);
      saveAll();
      renderWaTemplates();
      toast(t('wa.tpl_saved'), 'success');
      return true;
    }
  });
}

async function deleteWaTemplate(tplId) {
  const ok = await confirmModal(t('common.delete') + '?', { danger: true });
  if (!ok) return;
  waTemplates = waTemplates.filter(x => x.id !== tplId);
  saveAll();
  renderWaTemplates();
}

function openWaSendModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  if (waTemplates.length === 0) { toast(t('wa.no_templates'), 'info'); return; }
  const tplOptions = waTemplates.map((tpl, i) =>
    `<option value="${i}">${escapeHtml(tpl.name)}</option>`).join('');
  const bodyHtml = `
    <div style="margin-bottom:10px;">
      <label>${escapeHtml(t('wa.phone'))}</label>
      <input type="tel" id="waSendPhone" value="${escapeHtml(client?.phone || '')}" placeholder="+966 5x xxx xxxx">
    </div>
    <label>${escapeHtml(t('wa.template'))}</label>
    <select id="waTplSelect">${tplOptions}</select>
    <label style="margin-top:12px;">${escapeHtml(t('wa.preview'))}</label>
    <textarea id="waMsgPreview" rows="5" style="resize:vertical; font-size:12.5px;" readonly></textarea>
  `;
  openFormModal({
    title: t('wa.send_title'),
    saveLabel: t('wa.open_btn'),
    bodyHtml,
    onMount(modal) {
      const sel     = modal.querySelector('#waTplSelect');
      const preview = modal.querySelector('#waMsgPreview');
      const update  = () => {
        const tpl = waTemplates[+sel.value];
        if (tpl) preview.value = fillWaTemplate(tpl.body, order, client);
      };
      sel.addEventListener('change', update);
      update();
    },
    async onSave(modal) {
      const phone = modal.querySelector('#waSendPhone').value.trim();
      const msg   = modal.querySelector('#waMsgPreview').value;
      if (window.hubAPI?.shareWhatsApp) {
        await window.hubAPI.shareWhatsApp({ phone, message: msg, pdfPath: null });
      }
      return true;
    }
  });
}

function estimateMachineQueueClearDate(machineId, excludeOrderId) {
  const wh = KhaytWorkingWeek.workingHours(settings);
  const holidays = settings.holidays || [];
  const dayKeys = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

  // Sum queued print hours for this machine (active/pending orders)
  let queueHours = 0;
  for (const o of printLog) {
    if (o.id === excludeOrderId) continue;
    if (o.status === 'completed' || o.status === 'quote') continue;
    if (o.machineId !== machineId) continue;
    const hrs = +(o.printTime || 0);
    queueHours += hrs;
  }
  if (queueHours <= 0) return new Date();

  // Walk forward through working hours until queue is consumed
  const cursor = new Date();
  cursor.setSeconds(0, 0);
  let remaining = queueHours;
  let safety = 0;
  while (remaining > 0 && safety < 730) { // max 2 years
    safety++;
    const dateStr = localDateStr(cursor);
    if (!holidays.includes(dateStr)) {
      const dayKey = dayKeys[cursor.getDay()];
      const hoursAvail = +(wh[dayKey] || 0);
      if (hoursAvail > 0) {
        remaining -= hoursAvail;
      }
    }
    if (remaining > 0) cursor.setDate(cursor.getDate() + 1);
  }
  return cursor;
}

// Slice a chosen model with the user's slicer and send it to this machine's
// printer (OctoPrint/Moonraker), starting the print on confirm.
async function sliceAndPrintForMachine(machineId) {
  const machine = machines.find((m) => m.id === machineId);
  if (!machine || !(machine.printerApi && machine.printerApi.type && machine.printerApi.type !== 'none')) return;
  const filePath = await window.hubAPI?.pickFile?.({ filters: [{ name: 'Model or G-code', extensions: ['stl', '3mf', 'obj', 'step', 'stp', 'gcode', 'gco', 'g'] }] });
  if (!filePath) return;
  const isGcode = /\.(gcode|gco|g)$/i.test(filePath);
  const sl = settings.slicer || {};
  if (!isGcode && !sl.path) { toast(t('slicer.no_config'), 'error'); return; } // slicing needs a slicer; pre-sliced G-code doesn't
  const ok = await confirmModal(t(isGcode ? 'slicer.send_gcode_confirm' : 'slicer.start_confirm', { name: machine.name }));
  if (!ok) return;
  toast(t('slicer.sending') || 'Slicing & sending…', 'info');
  try {
    const r = isGcode
      ? await window.hubAPI.printerSendGcode({ machine, gcodePath: filePath, startPrint: true })
      : await window.hubAPI.sliceAndPrint({ modelPath: filePath, slicerPath: sl.path, args: sl.args, machine, startPrint: true });
    if (!r || !r.ok) throw new Error((r && r.error) || 'failed');
    toast(t('slicer.sent', { name: machine.name }), 'success');
  } catch (e) {
    toast(`${t('slicer.fail')} ${e.message}`, 'error');
  }
}


/* ============================================================
   Nozzle wear reference — the published table, and the shop's overrides
   ============================================================ */

/**
 * Render the wear table with its sources, editable.
 *
 * The figures behind the nozzle warning came from published tests, and the
 * published tests disagree with each other by an order of magnitude — E3D
 * measured real damage to brass at 250 g of carbon-filled PETG while other
 * sources put the same nozzle at 1–2 kg. Neither is wrong; they are answering
 * "when is it measurably worn" and "when do parts stop being acceptable".
 *
 * A shop cannot resolve that from a number in a dropdown, so the table shows
 * WHERE EACH FIGURE CAME FROM and lets the shop replace any of it. Rows with no
 * source are marked as estimates, because a number nobody checked should not
 * look like one somebody did — which is exactly how the first version of this
 * table shipped.
 */
function renderNozzleWearSettings() {
  const el = $('#nozzleWearSection');
  if (!el || typeof KhaytNozzleWear === 'undefined') return;
  const s = KhaytNozzleWear.suggestions(settings);

  const sourceCell = (row) => {
    if (row.source) {
      return `<a href="#" class="nw-src" data-url="${escapeHtml(row.source.url)}" title="${escapeHtml(row.source.what)}" style="color:var(--primary);">${escapeHtml(row.source.name.split('—')[0].trim())}</a>`;
    }
    return `<span title="${escapeHtml(row.note)}" style="color:var(--warning,#d97706);">${escapeHtml(t('nw.estimated') || 'estimate, unverified')}</span>`;
  };

  const rows = (list, kind, unit) => list.map((row) => `
    <tr>
      <td style="padding:4px 8px 4px 0;">${escapeHtml(row.label)}</td>
      <td style="padding:4px 8px 4px 0;white-space:nowrap;">
        <input type="number" class="nw-input" data-kind="${kind}" data-key="${escapeHtml(row.key)}"
               value="${row.override != null ? row.override : ''}" placeholder="${kind === 'life' ? row.grams : row.multiplier}"
               min="0" step="${kind === 'life' ? '500' : '0.5'}" style="width:88px;font-size:12px;padding:2px 6px;">
        <span style="color:var(--text-muted);font-size:11px;">${escapeHtml(unit)}</span>
      </td>
      <td style="padding:4px 8px 4px 0;font-size:11.5px;color:var(--text-muted);">${sourceCell(row)}</td>
      <td style="padding:4px 0;font-size:11px;color:var(--text-muted);">${escapeHtml(row.note)}</td>
    </tr>`).join('');

  el.innerHTML = `
    <p style="font-size:12px;color:var(--text-muted);margin:0 0 10px;line-height:1.55;">
      ${escapeHtml(t('nw.intro') || 'These figures decide when Khayt says a nozzle is due for replacement. They come from published tests, which disagree with each other — so treat them as a starting point and put your own numbers in once you know how your filament wears yours. Leave a box empty to use the published figure.')}
      <br><span style="font-size:11px;">${escapeHtml(t('nw.checked') || 'Sources checked')}: ${escapeHtml(s.checkedOn)}</span>
    </p>
    <div style="overflow-x:auto;">
      <table style="font-size:12px;border-collapse:collapse;min-width:520px;">
        <tr><th colspan="4" style="text-align:start;padding:6px 0 2px;font-size:11.5px;text-transform:uppercase;letter-spacing:.04em;color:var(--text-muted);">${escapeHtml(t('nw.life') || 'Nozzle life on ordinary filament')}</th></tr>
        ${rows(s.life, 'life', 'g')}
        <tr><th colspan="4" style="text-align:start;padding:12px 0 2px;font-size:11.5px;text-transform:uppercase;letter-spacing:.04em;color:var(--text-muted);">${escapeHtml(t('nw.abrasive') || 'How much faster filled filament wears it')}</th></tr>
        ${rows(s.abrasive, 'abrasive', '×')}
      </table>
    </div>
    <button class="btn small ghost" id="btnNozzleWearReset" style="margin-top:10px;">${escapeHtml(t('nw.reset') || 'Reset to the published figures')}</button>`;

  el.querySelectorAll('.nw-input').forEach((input) => {
    input.addEventListener('change', () => {
      settings.nozzleWear = settings.nozzleWear || { life: {}, abrasive: {} };
      const bucket = settings.nozzleWear[input.dataset.kind] = settings.nozzleWear[input.dataset.kind] || {};
      const v = parseFloat(input.value);
      // An empty box means "use the published figure", which has to DELETE the
      // override rather than store 0 — a stored 0 would read as a real setting
      // and the model would fall back anyway, leaving the box looking set.
      if (Number.isFinite(v) && v > 0) bucket[input.dataset.key] = v;
      else delete bucket[input.dataset.key];
      saveAll();
      renderMachines();
      toast(t('set.saved'), 'success');
    });
  });
  el.querySelector('#btnNozzleWearReset')?.addEventListener('click', () => {
    settings.nozzleWear = { life: {}, abrasive: {} };
    saveAll();
    renderNozzleWearSettings();
    renderMachines();
    toast(t('set.saved'), 'success');
  });
  el.querySelectorAll('.nw-src').forEach((a) => {
    a.addEventListener('click', (e) => { e.preventDefault(); window.hubAPI?.openExternal?.(a.dataset.url); });
  });
}


/**
 * Read the printer's own job history and keep it on the machine.
 *
 * STRICTLY READ-ONLY — a single GET to Moonraker's history endpoint — so this is
 * safe to run while the printer is mid-job, which is exactly when a shop tends
 * to want it.
 *
 * Why it matters: the nozzle-wear counter reads completed ORDERS, and a printer
 * runs far more than orders. Test prints, reprints, calibration and everything
 * nobody paid for are all real filament through the same nozzle. A machine can
 * be at two and a half times its replacement threshold while the order log says
 * it is comfortably inside — and the warning fires late, which ruins parts
 * rather than wasting nozzles.
 */
async function importPrinterHistory(machineId) {
  const m = machines.find((x) => x.id === machineId);
  if (!m) return;
  if (!window.hubAPI?.printerHistory) { toast(t('mach.import_history_unavailable') || 'This build cannot read printer history', 'error'); return; }
  toast(t('mach.import_history_running') || 'Reading the printer’s job history…', 'info');
  const r = await window.hubAPI.printerHistory({ machine: m, limit: 500 });
  if (!r || !r.ok) { toast('✗ ' + ((r && r.error) || 'could not read the history'), 'error', 7000); return; }

  const before = (m.printerHistory && m.printerHistory.jobs) || [];
  const jobs = KhaytMoonrakerHistory.merge(before, r.jobs || []);
  const added = jobs.length - before.length;
  m.printerHistory = { source: 'moonraker', importedAt: new Date().toISOString(), jobs };
  m.rev = (m.rev || 0) + 1;
  m.updatedAt = new Date().toISOString();
  saveAll();
  renderMachines();
  if (typeof renderDashboard === 'function') renderDashboard();

  const since = KhaytMoonrakerHistory.totalsSince(jobs, m.nozzle?.installedAt || '');
  const all = KhaytMoonrakerHistory.totalsSince(jobs, '');
  toast(`${t('mach.import_history_done') || 'Imported'} ${jobs.length} ${t('mach.jobs') || 'jobs'}`
    + (added ? ` (+${added})` : '')
    + ` · ${all.grams.toFixed(0)}g · ${all.hours.toFixed(0)}h`
    + (m.nozzle?.installedAt ? ` · ${since.grams.toFixed(0)}g ${t('mach.since_nozzle') || 'since this nozzle'}` : ''),
    'success', 9000);
}

  const api = {

    MACHINE_COLORS,
    machineGramsSinceNozzle,
    machineNozzleWear,
    renderNozzleWearSettings,
    importPrinterHistory,
    renderMachines,
    sliceAndPrintForMachine,
    renderMachineDropdown,
    refreshMachineCameras,
    openMachineEditor,
    logNozzleChange,
    deleteMachine,
    openMaintLog,
    machineHoursMeter,
    machineServiceStatus,
    logMachineService,
    renderWaTemplates,
    openWaTemplateEditor,
    deleteWaTemplate,
    openWaSendModal,
    estimateMachineQueueClearDate,
    machineLiveBadge,
    updateMachinesLiveStatus,
  };
  Object.assign(global, api);
  global.KhaytMachines = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
