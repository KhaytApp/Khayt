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
 * The rest of what the printer says, under the badge: heater targets, the
 * chamber, the layer, the part fan, speed and flow overrides and the
 * printer's own message. The poller has read all of it since the richer status
 * landed in lib/ (moonraker.readStatus and the other adapters); only the Mac
 * drew it. Every figure is null when the machine did not say, and a null is
 * left out rather than drawn as 0 — "Fan 0%" about a fan nobody measured is a
 * reading a shop would act on. The job figures (layer, fan, speed, flow) only
 * while a job is on, where they mean something.
 */
function machineLiveDetailHtml(m) {
  if (!m || !m.printerApi || !m.printerApi.type || m.printerApi.type === 'none') return '';
  const cache = (typeof machineStatusCache !== 'undefined' && machineStatusCache) || {};
  const s = cache[m.id];
  if (!s || s.error) return '';
  const age = s.lastUpdated ? Date.now() - s.lastUpdated : null;
  if (age !== null && age > MACHINE_LIVE_STALE_MS) return '';
  const fin = (v) => typeof v === 'number' && Number.isFinite(v);
  const deg = (cur, target) => {
    if (!fin(cur)) return null;
    return fin(target) && target > 0 ? `${Math.round(cur)}/${Math.round(target)}°` : `${Math.round(cur)}°`;
  };
  const bits = [];
  const add = (label, fig) => { if (fig != null) bits.push(`${escapeHtml(label)} <bdi>${escapeHtml(fig)}</bdi>`); };
  add(t('mach.live_nozzle'), deg(s.tempNozzle, s.targetNozzle));
  add(t('mach.live_bed'), deg(s.tempBed, s.targetBed));
  add(t('mach.live_chamber'), deg(s.tempChamber, s.targetChamber));
  const raw = String(s.state || '').toLowerCase();
  const onJob = /paus/.test(raw) || (/print/.test(raw) && !/error/.test(raw));
  if (onJob) {
    if (fin(s.layer) && fin(s.totalLayers)) {
      bits.push(`<bdi>${escapeHtml(t('mach.live_layer', { layer: String(s.layer), total: String(s.totalLayers) }))}</bdi>`);
    }
    add(t('mach.live_fan'), fin(s.fanPart) ? `${s.fanPart}%` : null);
    add(t('mach.live_speed'), fin(s.speedFactor) ? `${s.speedFactor}%` : null);
    add(t('mach.live_flow'), fin(s.flowFactor) ? `${s.flowFactor}%` : null);
  }
  const msg = typeof s.message === 'string' ? s.message.trim().slice(0, 140) : '';
  // WHY it is paused or failed, when the printer says (a Bambu's print_error /
  // HMS notice, lib/bambu-faults.js via lib/bambu.js statusWithFault). Bambu's
  // own sentence and the code to look it up by — the code is what the
  // printer's screen and Bambu's wiki use, in any language. The Mac's
  // ShopFloor card draws the same line.
  const fault = typeof s.fault === 'string' ? s.fault.trim().slice(0, 200) : '';
  const faultHtml = fault
    ? `<div class="machine-fault" style="font-size:11px;color:var(--warning);text-align:start;">⚠ <bdi>${escapeHtml(fault)}</bdi></div>`
    : '';
  if (!bits.length && !msg) return faultHtml;
  return `${faultHtml}<div style="font-size:11px;color:var(--text-muted);">${bits.join(' · ')}${msg ? `${bits.length ? ' · ' : ''}<span style="font-style:italic;">${escapeHtml(msg)}</span>` : ''}</div>`;
}

/* ── JOB CONTROL on the machine card ──────────────────────────────────────────
 * main.js has carried pause / resume / cancel and "drop one object" since the
 * Mac got them, and preload exposed all three — but nothing on this screen
 * called them, so a desktop shop watched a print it could not stop. The Mac's
 * card (ShopFloor.swift controls) is the model: shown only while a job is
 * running or paused; Pause and Resume are each other's undo and go straight
 * through; Cancel ASKS FIRST, because it scraps every hour on the plate and no
 * printer asks twice; dropping an object is Klipper only and asks too. A verb
 * the protocol cannot do (lib/printer-commands.js) is not offered at all. */
function _printerVerbOk(m, cmd) {
  const PC = (typeof KhaytPrinterCommands !== 'undefined') ? KhaytPrinterCommands : null;
  const api = (m && m.printerApi) || {};
  if (!PC) return false;
  // The shared answer (supports): one table of what each protocol can do. This
  // app performs HTTP, Bambu's MQTT and Elegoo's SDCP (main.js sendPrinterCommand).
  return PC.supports(api.type, cmd, { duetFlavour: api.duetFlavour, printerSlug: api.printerSlug || 'printer', transports: ['http', 'mqtt', 'sdcp'] });
}

/* ── Smart plug (lib/smart-plug.js; main: lib/main/smart-plug.js) ────────
 * The Mac's MachineSheet plug section and card buttons. Turning a plug OFF is
 * checked twice — here for the button, and again in the main process against
 * the poller's own reading — because power is never cut while the printer is
 * printing, paused, not answering or hot. */
/**
 * What the machine's plug measured it drawing over its recent metered prints
 * (lib/print-energy.js `suggestPowerDraw`), with "Use this" — the Mac's
 * machine sheet line. Nothing when fewer than three prints were metered, or
 * when the figure already matches.
 */
function measuredPowerHtml(draft) {
  const PE = (typeof KhaytPrintEnergy !== 'undefined') ? KhaytPrintEnergy : null;
  if (!PE || !draft || !draft.id) return '';
  const s = PE.suggestPowerDraw(printLog, draft.id);
  if (!s || Math.round(Number(draft.powerDraw)) === s.watts) return '';
  return `<div id="machPowerMeasured" style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;font-size:11px;color:var(--text-muted);margin-top:5px;">
        <span>${escapeHtml(t('mach.power_measured', { watts: s.watts, n: s.basedOn }))}</span>
        <button class="btn ghost small" id="machPowerUse" type="button" data-watts="${escapeHtml(String(s.watts))}">${escapeHtml(t('mach.power_use'))}</button>
      </div>`;
}

function smartPlugEditorHtml(draft) {
  const p = draft.smartPlug || {};
  const type = p.type || 'none';
  const opt = (v, label) => `<option value="${v}"${type === v ? ' selected' : ''}>${escapeHtml(label)}</option>`;
  const show = (kinds) => (kinds.includes(type) ? '' : 'display:none;');
  return `<div id="plugSection" style="margin-top:16px; padding-top:12px; border-top:1px solid var(--border-soft);">
    <label style="margin-top:0; font-weight:600;">${escapeHtml(t('splug.title'))}</label>
    <select id="plugType">${opt('none', t('splug.none'))}${opt('shelly', t('splug.kind_shelly'))}${opt('shelly-rpc', 'Shelly (Gen 2+ / Plus)')}${opt('tasmota', 'Tasmota')}${opt('homeassistant', 'Home Assistant')}</select>
    <div data-plug-fields style="${type === 'none' ? 'display:none;' : ''}">
      <label>${escapeHtml(t('splug.host'))}</label>
      <input type="text" id="plugHost" value="${escapeHtml(p.host || '')}" placeholder="192.168.1.50" autocomplete="off" spellcheck="false">
      <div data-plug-for="homeassistant" style="${show(['homeassistant'])}">
        <label>${escapeHtml(t('splug.entity'))}</label><input type="text" id="plugEntity" value="${escapeHtml(p.entity || '')}" placeholder="switch.printer_plug">
        <label>${escapeHtml(t('splug.token'))}</label><input type="password" id="plugToken" value="" placeholder="${escapeHtml(secretFieldPlaceholder(p.token))}" autocomplete="off">
      </div>
      <div data-plug-for="tasmota" style="${show(['tasmota'])}">
        <label>${escapeHtml(t('splug.user'))}</label><input type="text" id="plugUser" value="${escapeHtml(p.user || '')}" autocomplete="off">
        <label>${escapeHtml(t('splug.password'))}</label><input type="password" id="plugPassword" value="" placeholder="${escapeHtml(secretFieldPlaceholder(p.password))}" autocomplete="off">
      </div>
      <label style="display:flex;align-items:center;gap:8px;margin-top:10px;cursor:pointer;">
        <input type="checkbox" id="plugAutoOff" style="width:auto;margin:0;" ${p.autoOff === true ? 'checked' : ''}> ${escapeHtml(t('splug.auto_off'))}
      </label>
      <div style="display:flex;align-items:center;gap:6px;margin:6px 0 0 24px;">
        <span>${escapeHtml(t('splug.delay'))}</span>
        <input type="number" id="plugDelay" min="0" max="240" value="${escapeHtml(String(p.delayMin ?? 10))}" style="width:70px;">
        <span>${escapeHtml(t('splug.minutes'))}</span>
      </div>
      <div style="font-size:11.5px;color:var(--text-muted);margin:6px 0 0 24px;">${escapeHtml(t('splug.why'))}</div>
    </div>
  </div>`;
}

/** Wired once per editor: show the fields the chosen kind needs. */
function wireSmartPlugEditor(modal) {
  const sel = modal.querySelector('#plugType');
  if (!sel) return;
  sel.addEventListener('change', () => {
    modal.querySelector('[data-plug-fields]').style.display = sel.value === 'none' ? 'none' : '';
    modal.querySelectorAll('[data-plug-for]').forEach((el) => { el.style.display = el.dataset.plugFor === sel.value ? '' : 'none'; });
  });
}

/** The card's plug line: its state, and Turn on / Turn off. */
const _plugState = {};
function smartPlugCardHtml(m) {
  if (!m || !m.smartPlug || !m.smartPlug.type || m.smartPlug.type === 'none') return '';
  const st = _plugState[m.id];
  const word = !st ? '' : st.on === true ? t('splug.on') : st.on === false ? t('splug.off') : t('splug.unknown');
  const watts = st && Number.isFinite(st.watts) ? ` · ${Math.round(st.watts)} W` : '';
  const id = escapeHtml(m.id);
  return `<div class="plug-line" data-plug-line="${id}" style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-top:6px;font-size:12px;">
    <span style="color:var(--text-muted);">🔌 ${escapeHtml(word)}${escapeHtml(watts)}</span>
    <button class="btn small ghost" data-act="plug-on" data-id="${id}">${escapeHtml(t('splug.turn_on'))}</button>
    <button class="btn small ghost" data-act="plug-off" data-id="${id}">${escapeHtml(t('splug.turn_off'))}</button>
  </div>`;
}

async function refreshPlug(machineId) {
  const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x.id === machineId);
  if (!m || !window.hubAPI?.smartPlug) return;
  const r = await window.hubAPI.smartPlug(m, 'status').catch(() => null);
  _plugState[machineId] = r && r.ok ? { on: r.on, watts: r.watts, at: Date.now() } : { on: null, watts: null, at: Date.now() };
  const line = document.querySelector(`[data-plug-line="${CSS.escape(machineId)}"]`);
  if (line) line.outerHTML = smartPlugCardHtml(m);
}

async function plugSwitch(machineId, on) {
  const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x.id === machineId);
  if (!m || !window.hubAPI?.smartPlug) return;
  if (!on) {
    // The button asks the rule first, with what this window last heard.
    const live = (typeof machineStatusCache !== 'undefined' && machineStatusCache[machineId]) || null;
    const safe = (typeof KhaytSmartPlug !== 'undefined') ? KhaytSmartPlug.canTurnOff(live) : { ok: true };
    if (!safe.ok) { toast(t('splug.' + String(safe.reason).replace(/^plug\./, '')), 'error', 6000); return; }
  }
  const r = await window.hubAPI.smartPlug(m, on ? 'on' : 'off').catch((e) => ({ ok: false, error: e.message }));
  if (!r || !r.ok) { toast((r && r.reason ? t(r.reason) : '') || (r && r.error) || t('splug.unreachable'), 'error', 6000); return; }
  _plugState[machineId] = { on: r.on == null ? on : r.on, watts: r.watts };
  refreshPlug(machineId);
}

function machineControlsHtml(m) {
  if (!m || !m.printerApi || !m.printerApi.type || m.printerApi.type === 'none') return '';
  const cache = (typeof machineStatusCache !== 'undefined' && machineStatusCache) || {};
  const entry = cache[m.id];
  if (!entry || entry.error) return '';
  const age = entry.lastUpdated ? Date.now() - entry.lastUpdated : null;
  if (age !== null && age > MACHINE_LIVE_STALE_MS) return '';
  const raw = String(entry.state || '').toLowerCase();
  // By the state word only, as the Mac's card: a printer that has finished can
  // still report its last job's progress, and that is no job to pause.
  const paused = /paus/.test(raw);
  const running = !paused && /print/.test(raw) && !/error/.test(raw);
  if (!(paused || running)) return '';
  const id = escapeHtml(m.id);
  const out = [];
  if (paused) {
    if (_printerVerbOk(m, 'resume')) out.push(`<button class="btn small" data-act="printer-resume" data-id="${id}">${escapeHtml(t('mach.printer_resume'))}</button>`);
  } else if (_printerVerbOk(m, 'pause')) {
    out.push(`<button class="btn small" data-act="printer-pause" data-id="${id}">${escapeHtml(t('mach.printer_pause'))}</button>`);
  }
  if (_printerVerbOk(m, 'cancel')) out.push(`<button class="btn small danger" data-act="printer-cancel" data-id="${id}">${escapeHtml(t('mach.printer_cancel'))}</button>`);
  if (m.printerApi.type === 'moonraker') out.push(`<button class="btn small ghost" data-act="printer-drop" data-id="${id}">${escapeHtml(t('mach.drop_object'))}…</button>`);
  // A Bambu's speed preset and chamber light (the Mac's card has both). One
  // compact menu; a change event sends it, and the menu resets to its label.
  const PC = (typeof KhaytPrinterCommands !== 'undefined') ? KhaytPrinterCommands : null;
  if (PC && m.printerApi.type === 'bambu' && !PC.buildControl('bambu', 'light', 'on', { transports: ['mqtt'] }).unsupported) {
    const speeds = [1, 2, 3, 4].map((n) => `<option value="speed:${n}">${escapeHtml(t('mach.printer_speed_' + n))}</option>`).join('');
    out.push(`<select class="btn small ghost" data-printer-control="${id}" aria-label="${escapeHtml(t('mach.printer_speed'))}">
      <option value="" selected>${escapeHtml(t('mach.printer_speed'))} / ${escapeHtml(t('mach.printer_light'))}…</option>
      <optgroup label="${escapeHtml(t('mach.printer_speed'))}">${speeds}</optgroup>
      <optgroup label="${escapeHtml(t('mach.printer_light'))}">
        <option value="light:on">${escapeHtml(t('mach.printer_light_on'))}</option>
        <option value="light:off">${escapeHtml(t('mach.printer_light_off'))}</option>
      </optgroup></select>`);
  }
  return out.join('');
}

const _printerBusy = new Set();
async function printerJobCommand(machineId, command, confirmed = false) {
  const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x.id === machineId);
  if (!m || _printerBusy.has(machineId) || !window.hubAPI?.printerCommand) return;
  // Cancel asks first; the dialog's own Save sends it, and dismissing it sends nothing.
  if (command === 'cancel' && !confirmed) {
    openFormModal({
      title: t('mach.cancel_ask', { machine: m.name || '' }),
      bodyHtml: `<p style="margin:0;">${escapeHtml(t('mach.cancel_why'))}</p>`,
      saveLabel: t('mach.printer_cancel'),
      onSave: () => { printerJobCommand(machineId, 'cancel', true); return true; },
    });
    return;
  }
  _printerBusy.add(machineId);
  try {
    const r = await window.hubAPI.printerCommand(m, command).catch((e) => ({ ok: false, error: String(e && e.message || e) }));
    if (r && r.ok) toast(t('mach.printer_sent'), 'success');
    else toast(t('mach.printer_failed', { error: (r && (r.error || r.unsupported)) || '' }), r && r.unconfirmed ? 'warning' : 'error');
  } finally {
    _printerBusy.delete(machineId);
  }
}

// Speed changes the print running now, so it asks (the Mac's speed_ask); the
// light is harmless and goes straight through.
async function printerControl(machineId, control, value, confirmed = false) {
  const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x.id === machineId);
  if (!m || _printerBusy.has(machineId) || !window.hubAPI?.printerControl) return;
  if (control === 'speed' && !confirmed) {
    openFormModal({
      title: t('mach.speed_ask', { machine: m.name || '', speed: t('mach.printer_speed_' + value) }),
      bodyHtml: `<p style="margin:0;">${escapeHtml(t('mach.speed_why'))}</p>`,
      saveLabel: t('mach.speed_set'),
      onSave: () => { printerControl(machineId, control, value, true); return true; },
    });
    return;
  }
  _printerBusy.add(machineId);
  try {
    const r = await window.hubAPI.printerControl(m, control, value).catch((e) => ({ ok: false, error: String(e && e.message || e) }));
    if (r && r.ok) toast(t('mach.printer_sent'), 'success');
    else toast(t('mach.printer_failed', { error: (r && (r.error || r.unsupported)) || '' }), r && r.unconfirmed ? 'warning' : 'error');
  } finally {
    _printerBusy.delete(machineId);
  }
}

async function openDropObject(machineId) {
  const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x.id === machineId);
  if (!m || !window.hubAPI?.printerPlate) return;
  const plate = await window.hubAPI.printerPlate(m).catch(() => null);
  if (!plate || !plate.ok) { toast(t('mach.printer_failed', { error: (plate && plate.error) || '' }), 'error'); return; }
  const remaining = Array.isArray(plate.remaining) ? plate.remaining : [];
  let body;
  if (!plate.supported) body = `<p style="margin:0;">${escapeHtml(t('mach.drop_unsupported'))}</p>`;
  else if (!remaining.length) body = `<p style="margin:0;">${escapeHtml(t('mach.drop_nothing'))}</p>`;
  else {
    body = `<div style="display:flex;flex-direction:column;gap:6px;max-height:220px;overflow:auto;">${remaining.map((name, i) => `
      <label style="display:flex;align-items:center;gap:8px;font-weight:400;cursor:pointer;">
        <input type="radio" name="dropObj" value="${i}" style="width:auto;margin:0;">
        <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(name)}</span>
        ${name === plate.current ? `<span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('mach.drop_printing_now'))}</span>` : ''}
      </label>`).join('')}</div>
      <p style="margin:10px 0 0;font-size:12px;color:var(--warning);">${escapeHtml(t('mach.drop_forever'))}</p>`;
  }
  const canDrop = plate.supported && remaining.length > 0;
  openFormModal({
    title: `${t('mach.drop_object')} · ${m.name || ''}`,
    bodyHtml: body,
    noSave: !canDrop,
    saveLabel: t('mach.drop_it'),
    async onSave(modal) {
      const pick = modal.querySelector('input[name="dropObj"]:checked');
      if (!pick) { toast(t('mach.drop_choose'), 'error'); return false; }
      const name = remaining[+pick.value];
      const r = await window.hubAPI.printerExcludeObject(m, name).catch((e) => ({ ok: false, error: String(e && e.message || e) }));
      if (r && r.ok) toast(t('mach.printer_sent'), 'success');
      else { toast(t('mach.printer_failed', { error: (r && r.error) || '' }), 'error'); return false; }
      return true;
    },
  });
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
  document.querySelectorAll('#machinesList [data-machine-detail]').forEach((el) => {
    const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x.id === el.dataset.machineDetail);
    if (m) el.innerHTML = machineLiveDetailHtml(m);
  });
  document.querySelectorAll('#machinesList [data-machine-ctl]').forEach((el) => {
    const m = (typeof machines !== 'undefined' ? machines : []).find((x) => x.id === el.dataset.machineCtl);
    if (m) el.innerHTML = machineControlsHtml(m);
  });
}

function renderMachines() {
  const list = $('#machinesList');
  if (!list) return;
  if (machines.length === 0) {
    list.innerHTML = `<div style="color:var(--text-muted);font-size:13px;padding:8px 0;">${escapeHtml(t('mach.empty'))}</div>`;
    return;
  }
  // Retired printers last: still listed, for their history and to be
  // returned to service, but behind the ones in use.
  const MS = typeof KhaytMachineStatus !== 'undefined' ? KhaytMachineStatus : null;
  const isRetired = (m) => !!(MS && MS.isRetired(m));
  const ordered = machines.filter(m => !isRetired(m)).concat(machines.filter(isRetired));
  list.innerHTML = ordered.map(m => {
    const retired = isRetired(m);
    const active = printLog.filter(o => o.machineId === m.id && KhaytOrderStatus.isOpen(o)).length;
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
        ${retired ? `<span class="machine-jobs-badge" style="background:var(--text-muted); color:#fff;">${escapeHtml(t('mach.retired_badge', { date: m.retiredAt || '' }))}</span>` : ''}
        ${m.isOffline ? `<span class="machine-jobs-badge" style="background:var(--danger); color:#fff;">${_mIcoL('alert', '⚠', 12)}${escapeHtml(t('mach.offline_badge'))}</span>` : ''}
        <span data-machine-live="${escapeHtml(m.id)}">${machineLiveBadge(m)}</span>
        <span data-machine-ctl="${escapeHtml(m.id)}" style="display:inline-flex;gap:6px;">${retired ? '' : machineControlsHtml(m)}</span>
        ${retired ? '' : smartPlugCardHtml(m)}
        ${active > 0 ? `<span class="machine-jobs-badge">${active} ${escapeHtml(t('mach.active_jobs'))}</span>` : ''}
        ${svcBadge ? `<span class="pro-only">${svcBadge}</span>` : ''}
        ${downtimeBadge ? `<span class="pro-only">${downtimeBadge}</span>` : ''}
        ${hrsLine}
        ${(m.printerApi && m.printerApi.type && m.printerApi.type !== 'none') ? `<button class="btn small ghost" data-act="slice-print" data-id="${m.id}" title="${escapeHtml(t('slicer.send_title') || 'Slice & print')}" style="font-size:11px;">${_mIco('printer', '🖨')}</button>` : ''}
        <button class="btn small pro-only" data-act="maint-log" data-id="${m.id}" title="${escapeHtml(t('maint.btn'))}" aria-label="${escapeHtml(t('maint.btn'))}"><span aria-hidden="true">🔧</span></button>
        <button class="btn small ghost pro-only" data-act="log-nozzle-change" data-id="${m.id}" title="${escapeHtml(t('mach.log_nozzle'))}" style="font-size:11px;" aria-label="${escapeHtml(t('mach.log_nozzle'))}"><span aria-hidden="true">🔩</span></button>
        ${m.printerApi?.type === 'moonraker' ? `<button class="btn small ghost pro-only" data-act="import-history" data-id="${m.id}" title="${escapeHtml(t('mach.import_history_hint') || 'Read every job this printer has run. Read-only — safe while it is printing.')}" style="font-size:11px;" aria-label="${escapeHtml(t('mach.import_history') || 'Import print history')}"><span aria-hidden="true">📥</span></button>` : ''}
        <button class="btn small" data-act="edit-mach" data-id="${m.id}">${escapeHtml(t('common.edit'))}</button>
        ${retired
          ? `<button class="btn small" data-act="unretire-mach" data-id="${m.id}">${escapeHtml(t('mach.unretire'))}</button>`
          : `<button class="btn danger small" data-act="del-mach" data-id="${m.id}">${escapeHtml(t('common.delete'))}</button>`}
        <div data-machine-detail="${escapeHtml(m.id)}" style="flex-basis:100%;">${retired ? '' : machineLiveDetailHtml(m)}</div>
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
  // Each plug's state, read once per draw (the button line updates in place).
  machines.forEach((m) => {
    if (!m || !m.smartPlug || !m.smartPlug.type || m.smartPlug.type === 'none' || m.retiredAt) return;
    const st = _plugState[m.id];
    if (!st || Date.now() - (st.at || 0) > 60000) refreshPlug(m.id);
  });
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
    activeMachines().map(m => `<option value="${m.id}">${escapeHtml(m.name)}${m.isOffline ? ' (' + escapeHtml(t('mach.offline_badge')) + ')' : ''}</option>`).join('');
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
      ${measuredPowerHtml(draft)}
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
      ${(() => {
        /* DEPRECIATION — what the machine cost and how long it lasts. It sets
         * the machine's wear rate for quotes (lib/print-rates.js) and is the
         * ONE place its wear reaches the P&L (lib/pnl-report.js, the
         * maintainer's decision of 2026-09-28). No price, no depreciation. */
        const dep = draft.depreciation || {};
        const v = (x) => (x == null || x === '' ? '' : escapeHtml(String(x)));
        const sel = (a, b) => (a === b ? ' selected' : '');
        return `<div style="margin-top:16px; padding-top:12px; border-top:1px solid var(--border-soft);">
        <label style="margin-top:0; font-weight:600;">${escapeHtml(t('mach.dep_title'))}</label>
        <div style="font-size:11.5px; color:var(--text-muted); margin:2px 0 8px;">${escapeHtml(t(document.documentElement.dataset.app === 'bedready' ? 'mach.dep_hint_maker' : 'mach.dep_hint'))}</div>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:8px 12px;">
          <div><label style="margin-top:0;">${escapeHtml(t('mach.dep_price'))}</label>
            <input type="number" id="machDepPrice" min="0" step="0.01" value="${v(dep.price)}"></div>
          <div><label style="margin-top:0;">${escapeHtml(t('mach.dep_date'))}</label>
            <input type="date" id="machDepDate" value="${v(dep.purchaseDate)}"></div>
          <div><label style="margin-top:0;">${escapeHtml(t('mach.dep_life'))}</label>
            <div style="display:flex; gap:6px;">
              <input type="number" id="machDepLife" min="0" step="1" value="${v(dep.life)}" style="flex:1;">
              <select id="machDepLifeUnit" style="flex:1;">
                <option value="hours"${sel(dep.lifeUnit || 'hours', 'hours')}>${escapeHtml(t('mach.dep_unit_hours'))}</option>
                <option value="years"${sel(dep.lifeUnit, 'years')}>${escapeHtml(t('mach.dep_unit_years'))}</option>
              </select>
            </div></div>
          <div><label style="margin-top:0;">${escapeHtml(t('mach.dep_residual'))}</label>
            <input type="number" id="machDepResidual" min="0" step="0.01" value="${v(dep.residual)}" placeholder="0"></div>
          <div><label style="margin-top:0;">${escapeHtml(t('mach.dep_method'))}</label>
            <select id="machDepMethod">
              <option value="perHour"${sel(dep.method || (dep.lifeUnit === 'years' ? 'straightLine' : 'perHour'), 'perHour')}>${escapeHtml(t('mach.dep_per_hour'))}</option>
              <option value="straightLine"${sel(dep.method || (dep.lifeUnit === 'years' ? 'straightLine' : 'perHour'), 'straightLine')}>${escapeHtml(t('mach.dep_straight'))}</option>
            </select></div>
          <div><label style="margin-top:0;">${escapeHtml(t('mach.dep_monthly_hours'))}</label>
            <input type="number" id="machDepMonthlyHours" min="0" step="1" value="${v(dep.monthlyHours)}"></div>
        </div>
      </div>`;
      })()}
      <label style="margin-top:14px;">${escapeHtml(t('mach.location'))}</label>
      <select id="machLocationId" style="margin-top:6px;">
        <option value="">— ${escapeHtml(t('an.unassigned_location'))} —</option>
        ${locations.map(l => `<option value="${escapeHtml(l.id)}"${draft.locationId === l.id ? ' selected' : ''}>${escapeHtml(l.name)}</option>`).join('')}
      </select>

      <label style="margin-top:16px; display:flex; align-items:center; gap:8px; cursor:pointer;">
        <input type="checkbox" id="machOffline" style="width:auto; margin:0;" ${draft.isOffline ? 'checked' : ''}>
        <span data-i18n="mach.mark_offline">${escapeHtml(t('mach.mark_offline'))}</span>
      </label>

      <label style="margin-top:10px; display:flex; align-items:center; gap:8px; cursor:pointer;">
        <input type="checkbox" id="machClearsOwnBed" style="width:auto; margin:0;" ${draft.clearsOwnBed === true ? 'checked' : ''}>
        <span>${escapeHtml(t('mach.clears_own_bed'))}</span>
      </label>
      <div style="font-size:11.5px; color:var(--text-muted); margin:4px 0 0 24px; line-height:1.45;">
        ${escapeHtml(t('mach.clears_own_bed_hint'))} ${escapeHtml(t('mach.clears_own_bed_mac'))}
      </div>

      ${smartPlugEditorHtml(draft)}

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
      // The plug's measured wattage: offered, never applied for the shop.
      modal.querySelector('#machPowerUse')?.addEventListener('click', (e) => {
        const w = Number(e.currentTarget.dataset.watts);
        if (!Number.isFinite(w) || w <= 0) return;
        draft.powerDraw = w;
        const line = modal.querySelector('#machPowerMeasured');
        if (line) line.textContent = t('mach.power_set', { watts: w });
      });

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
        if (resultEl) resultEl.textContent = t('slicer.testing');
        try {
          if (window.hubAPI?.probePrinter) {
            // One question to this printer; the fleet's polling carries on.
            const testMachine = { id: draft.id, printerApi: { ...draft.printerApi } };
            const s = await window.hubAPI.probePrinter(testMachine);
            if (resultEl) {
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
      // Only a real true is kept, and unticking REMOVES the field — the rule
      // lib/machine-edit.js applies on the Mac, so the two never disagree on
      // whether a machine clears its own plate (lib/auto-dispatch.js reads it).
      wireSmartPlugEditor(modal);
      modal.querySelector('#machClearsOwnBed').addEventListener('change', e => {
        if (e.target.checked) draft.clearsOwnBed = true; else delete draft.clearsOwnBed;
      });
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
          // As the API key: a blank field over a stored code keeps it. Read raw,
          // an edit that did not retype it saved '' and erased the Bambu's code.
          accessCode:   secretInputSave(draft.printerApi?.accessCode, document.getElementById('machApiAccessCode')?.value),
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
      // Depreciation, cleaned by the rule the Mac's machine sheet uses
      // (lib/depreciation.js clean): no price removes it, rather than keeping
      // a block that says nothing.
      const DEP = (typeof KhaytDepreciation !== 'undefined') ? KhaytDepreciation : null;
      if (DEP && document.getElementById('machDepPrice')) {
        const val = (id) => document.getElementById(id)?.value ?? '';
        const next = DEP.clean({
          price: val('machDepPrice'), purchaseDate: val('machDepDate'), life: val('machDepLife'),
          lifeUnit: val('machDepLifeUnit'), residual: val('machDepResidual'),
          method: val('machDepMethod'), monthlyHours: val('machDepMonthlyHours'),
        });
        if (next) draft.depreciation = next; else delete draft.depreciation;
      }
      // The smart plug (lib/smart-plug.js reads `smartPlug`); secrets as the
      // printer's: a blank field over a stored token or password keeps it.
      {
        const val = (id) => (document.getElementById(id)?.value ?? '').trim();
        const type = val('plugType');
        if (!type || type === 'none') delete draft.smartPlug;
        else {
          const was = draft.smartPlug || {};
          draft.smartPlug = {
            type, host: val('plugHost'), entity: val('plugEntity'),
            token: secretInputSave(was.token, document.getElementById('plugToken')?.value),
            user: val('plugUser'),
            password: secretInputSave(was.password, document.getElementById('plugPassword')?.value),
            autoOff: !!document.getElementById('plugAutoOff')?.checked,
            delayMin: Math.max(0, Math.floor(Number(val('plugDelay')) || 10)),
          };
        }
      }
      // Persist locationId
      const machLocEl = document.getElementById('machLocationId');
      if (machLocEl) draft.locationId = machLocEl.value || '';
      const idx = machines.findIndex(m => m.id === draft.id);
      if (idx >= 0) machines[idx] = draft;
      else machines.push(draft);
      // The overhead rate sums every machine's monthly hours: an added,
      // changed or retired printer moves it now.
      if (typeof clearOverheadCache === 'function') clearOverheadCache();
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
    // The machines boot polls: active ones (a retired printer is not watched).
    const pool = typeof activeMachines === 'function' ? activeMachines() : (typeof machines !== 'undefined' ? machines : []);
    const apiMachines = pool.filter((m) => m && m.printerApi && m.printerApi.type && m.printerApi.type !== 'none');
    // The last connected printer removed: stop, or it is polled until restart.
    if (!apiMachines.length) { window.hubAPI.stopPrinterPolling?.(); return; }
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

/** Back in service: the retirement undone, its history untouched. */
function unretireMachine(machineId) {
  const i = machines.findIndex(m => m.id === machineId);
  if (i < 0) return;
  machines[i] = KhaytMachineStatus.unretire(machines[i]);
  if (typeof clearOverheadCache === 'function') clearOverheadCache();
  saveAll();
  refreshPrinterPolling();   // a removed, retired or returned printer changes what is polled
  renderMachines();
  renderMachineDropdown();
}

/**
 * Delete a printer only when nothing in the book names it — one added by
 * mistake. One with history is RETIRED instead (lib/machine-status.js):
 * deleting it rewrote the past, dropping its depreciation from earlier
 * periods, its jobs into "Unassigned" and its service costs from the P&L.
 * Retiring keeps all of that and takes it off its unfinished jobs.
 */
async function deleteMachine(machineId) {
  const MS = KhaytMachineStatus;
  const book = collectStoreCollections();
  const verdict = MS.canDelete(book, machineId);
  if (verdict.reason === 'missing') return;
  if (!verdict.ok) {
    const ok = await confirmModal(t('mach.retire_instead_q', { n: verdict.total }), { okText: t('mach.retire') });
    if (!ok) return;
    const r = MS.retire(book, machineId, { at: localDateStr() });
    if (!r.ok) return;
    // retire() changed `book.machines` and the jobs in `book.printLog`, which
    // are this window's own arrays.
    if (r.unassigned.length) toast(t('mach.retired_unassigned', { n: r.unassigned.length }), 'info', 6000);
    else toast(t('mach.retired_done'), 'success');
  } else {
    const ok = await confirmModal(t('mach.delete_q'), { danger: true });
    if (!ok) return;
    MS.remove(book, machineId);
  }
  if (typeof clearOverheadCache === 'function') clearOverheadCache();
  saveAll();
  refreshPrinterPolling();   // a removed, retired or returned printer changes what is polled
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
      // "Inspected, not needed yet" replaces OK while a deferral is running; once
      // the pushed-out date comes round the task reads Soon/Due as usual.
      const label = st.deferred && st.status === 'ok' ? t('maint.deferred') : (t('maint.status_' + st.status) || st.status);
      // "Not needed" only on a task that is asking for attention: deferring an OK
      // task would push it further out than the interval ever said.
      const notNeeded = st.status !== 'ok'
        ? `<button class="btn small" data-act="mt-defer" data-id="${tk.id}" title="${escapeHtml(t('maint.not_needed_help'))}">${escapeHtml(t('maint.not_needed'))}</button> `
        : '';
      return `<tr>
        <td><strong>${escapeHtml(tk.name || '')}</strong><br><span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('maint.every') || 'every')} ${every}</span></td>
        <td style="white-space:nowrap;color:${STATUS_COLOR[st.status] || 'var(--text-muted)'};font-weight:600;font-size:12px;" data-status="${escapeHtml(st.status)}"${st.deferred ? ' data-deferred="1"' : ''}>${escapeHtml(label)}</td>
        <td style="white-space:nowrap;text-align:end;">
          ${notNeeded}<button class="btn small" data-act="mt-done" data-id="${tk.id}">${escapeHtml(t('maint.mark_done') || 'Done')}</button>
          <button class="btn danger small" data-act="mt-del" data-id="${tk.id}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
        </td></tr>`;
    }).join('')}</tbody></table></div>`;
  }

  // Common tasks a shop can start from instead of a blank form
  // (lib/maintenance.js starterTasks, the list the Mac offers). The intervals
  // are starting points; a click only fills the form, so the shop still reads
  // and adjusts them before adding. A task already on this machine by the same
  // name is not offered again.
  function starterHtml() {
    const M = (typeof KhaytMaintenance !== 'undefined') ? KhaytMaintenance : null;
    if (!M || typeof M.starterTasks !== 'function') return '';
    const have = new Set((typeof machMaintTasks !== 'undefined' ? machMaintTasks : [])
      .filter(tk => tk.machineId === machineId).map(tk => String(tk.name || '').trim().toLowerCase()));
    const list = M.starterTasks(machine.kind).filter(st => !have.has(t('maint.t_' + st.id).trim().toLowerCase()));
    if (!list.length) return '';
    return `<div style="margin-bottom:10px;">
      <div style="font-size:11.5px;color:var(--text-muted);margin-bottom:6px;">${escapeHtml(t('maint.common'))}</div>
      <div style="display:flex;flex-wrap:wrap;gap:6px;">${list.map(st =>
        `<button type="button" class="btn small" data-act="mt-starter" data-id="${escapeHtml(st.id)}" data-h="${st.intervalHours || ''}" data-d="${st.intervalDays || ''}">${escapeHtml(t('maint.t_' + st.id))}</button>`).join('')}</div>
    </div>`;
  }

  // Care plans per printer model (lib/care-plans.js, the catalogue the Mac uses).
  // The picker starts on the plan the machine's record matches; applying adds the
  // plan's missing tasks counted from now and links the ones the machine already
  // has, and changes a shop's own interval only when "use the plan's intervals" is
  // ticked. Nothing is marked done either way.
  const CP = (typeof KhaytCarePlans !== 'undefined') ? KhaytCarePlans : null;
  const enWord = (k) => (globalThis.KhaytLocales && globalThis.KhaytLocales.en && globalThis.KhaytLocales.en[k]) || '';
  function cpNamesById(planId) {
    const p = CP && CP.plan(planId);
    const out = {};
    // The shop's language and English: a starter task added before a language
    // switch is still recognised as the same task.
    if (p) for (const tk of p.tasks) out[tk.id] = [...new Set([t('maint.t_' + tk.id), enWord('maint.t_' + tk.id)].filter(Boolean))];
    return out;
  }
  const cpEvery = (h, d) => [h > 0 ? `${h}h` : '', d > 0 ? `${d}d` : ''].filter(Boolean).join(' / ') || '—';
  const cpPartsText = (task) => (task.parts || []).map(x => `${t('maint.part_' + x.id)}${x.qty > 1 ? ' ×' + x.qty : ''}`).join(', ');
  let cpPlanId = CP ? (CP.matchPlan(machine.vendor, machine.printerModelName || machine.printerModel, machine.name) || '') : '';
  let cpBrand = cpPlanId ? CP.plan(cpPlanId).brand : (CP ? CP.brands()[0] : '');
  function cpPanelHtml() {
    if (!CP) return '';
    const plans = CP.plansFor(cpBrand);
    if (!plans.some(p => p.id === cpPlanId)) cpPlanId = plans[0] ? plans[0].id : '';
    const p = CP.plan(cpPlanId);
    const opt = (v, label, on) => `<option value="${escapeHtml(v)}"${on ? ' selected' : ''}>${escapeHtml(label)}</option>`;
    let body = '';
    if (p) {
      const cmp = CP.comparePlan(machMaintTasks, machineId, p.id, cpNamesById(p.id));
      const source = p.source === 'starter'
        ? `<p style="font-size:12px;color:var(--text-muted);margin:8px 0;">${escapeHtml(t('maint.cp_source_starter'))}</p>`
        : `<p style="font-size:12px;color:var(--text-muted);margin:8px 0;">${escapeHtml(t('maint.cp_source'))} <a href="#" data-act="cp-source" data-url="${escapeHtml(p.source)}">${escapeHtml(t('maint.cp_open_source'))}</a></p>`;
      const row = (task, extra) => `<li style="margin:4px 0;"><strong>${escapeHtml(t('maint.t_' + task.id))}</strong> · ${escapeHtml(cpEvery(task.intervalHours, task.intervalDays))}${
        task.parts && task.parts.length ? `<br><span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('maint.cp_parts_used').replace('{parts}', cpPartsText(task)))}</span>` : ''}${
        task.source === 'starter' && p.source !== 'starter' ? `<br><span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('maint.cp_task_starter'))}</span>` : ''}${extra || ''}</li>`;
      body = source
        + (cmp.add.length ? `<ul id="cpAddList" style="margin:6px 0;padding-inline-start:18px;font-size:12.5px;">${cmp.add.map(x => row(x)).join('')}</ul>`
          : `<p id="cpNothing" style="font-size:12.5px;margin:6px 0;">${escapeHtml(t('maint.cp_nothing'))}</p>`)
        + (cmp.same.length ? `<div style="font-size:11.5px;color:var(--text-muted);margin-top:8px;">${escapeHtml(t('maint.cp_have'))}: ${cmp.same.map(r => escapeHtml(t('maint.t_' + r.task.id))).join(', ')}</div>` : '')
        + (cmp.differ.length ? `<div style="margin-top:10px;font-size:12.5px;">${escapeHtml(t('maint.cp_differ_title'))}
            <ul style="margin:4px 0;padding-inline-start:18px;">${cmp.differ.map(r => `<li>${escapeHtml(t('maint.t_' + r.task.id))}: ${escapeHtml(cpEvery(r.hadHours, r.hadDays))} → ${escapeHtml(cpEvery(r.task.intervalHours, r.task.intervalDays))}</li>`).join('')}</ul>
            <label style="display:flex;align-items:center;gap:6px;cursor:pointer;margin:4px 0;font-size:12.5px;"><input type="checkbox" id="cpUsePlan" style="width:auto;margin:0;"> <span>${escapeHtml(t('maint.cp_use_plan'))}</span></label>
            <div style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('maint.cp_differ_keep'))}</div></div>` : '');
    }
    return `<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;">
        <div><label style="margin:0;">${escapeHtml(t('maint.cp_brand'))}</label><select id="cpBrand">${CP.brands().map(b => opt(b, b, b === cpBrand)).join('')}</select></div>
        <div><label style="margin:0;">${escapeHtml(t('maint.cp_model'))}</label><select id="cpPlan">${plans.map(x => opt(x.id, x.model, x.id === cpPlanId)).join('')}</select></div>
      </div>${body}
      <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px;">
        <button type="button" class="btn small" data-act="cp-cancel">${escapeHtml(t('common.cancel'))}</button>
        <button type="button" class="btn primary small" data-act="cp-apply"${p ? '' : ' disabled'}>${escapeHtml(t('maint.cp_apply_btn'))}</button>
      </div>`;
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
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;">
        <span style="font-weight:600;font-size:13px;">${escapeHtml(t('maint.recurring') || 'Recurring maintenance')}</span>
        ${CP ? `<button type="button" class="btn small" id="btnCarePlan">${escapeHtml(t('maint.cp_apply'))}</button>` : ''}
      </div>
      <div id="cpPanel" hidden style="background:var(--surface-2);padding:12px;border-radius:var(--radius);margin-bottom:8px;border:1px solid var(--border);"></div>
      <div style="background:var(--surface-2);padding:12px;border-radius:var(--radius);margin-bottom:8px;">
        <div id="mtStarters">${starterHtml()}</div>
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
        const st = modal.querySelector('#mtStarters');
        if (st) st.innerHTML = starterHtml();
      };
      const cpPanel = modal.querySelector('#cpPanel');
      const cpPaint = () => { if (cpPanel) cpPanel.innerHTML = cpPanelHtml(); };
      modal.querySelector('#btnCarePlan')?.addEventListener('click', () => {
        if (!cpPanel) return;
        cpPanel.hidden = !cpPanel.hidden;
        if (!cpPanel.hidden) cpPaint();
      });
      cpPanel?.addEventListener('change', (e) => {
        if (e.target.id === 'cpBrand') { cpBrand = e.target.value; cpPlanId = ''; cpPaint(); }
        else if (e.target.id === 'cpPlan') { cpPlanId = e.target.value; cpPaint(); }
      });
      cpPanel?.addEventListener('click', (e) => {
        const src = e.target.closest('[data-act="cp-source"]');
        if (src) {
          e.preventDefault();
          if (/^https:\/\//.test(src.dataset.url || '')) window.hubAPI?.openExternal?.(src.dataset.url);
          return;
        }
        if (e.target.closest('[data-act="cp-cancel"]')) { cpPanel.hidden = true; return; }
        if (!e.target.closest('[data-act="cp-apply"]') || !cpPlanId) return;
        const namesById = cpNamesById(cpPlanId);
        const cmp = CP.comparePlan(machMaintTasks, machineId, cpPlanId, namesById);
        const usePlan = !!cpPanel.querySelector('#cpUsePlan')?.checked;
        const r = CP.applyPlan(machMaintTasks, {
          machineId, planId: cpPlanId,
          meter: machineHoursMeter(machineId), nowIso: new Date().toISOString(),
          namesById,
          nameOf: (id) => t('maint.t_' + id),
          confirm: usePlan ? cmp.differ.map(x => x.recordId) : [],
          newId: () => uid('MTASK'),
        });
        if (!r.added.length && !r.changed.length) { toast(t('maint.cp_nothing'), 'info'); cpPanel.hidden = true; return; }
        machMaintTasks = r.tasks;
        saveAll();
        cpPanel.hidden = true;
        refreshTasks();
        toast(t('maint.cp_applied').replace('{added}', r.added.length).replace('{changed}', r.changed.length), 'success');
      });
      modal.addEventListener('click', (e) => {
        const b = e.target.closest('[data-act="mt-starter"]');
        if (!b) return;
        modal.querySelector('#mtName').value = t('maint.t_' + b.dataset.id);
        modal.querySelector('#mtHours').value = b.dataset.h || '';
        modal.querySelector('#mtDays').value = b.dataset.d || '';
        modal.querySelector('#mtName').focus();
      });
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
        const deferBtn = e.target.closest('[data-act="mt-defer"]');
        if (deferBtn) {
          // Inspected and fine: push the task out without a "done" — no log row,
          // and lastDone* untouched, so the wear history still says when the
          // part was really last changed.
          const tk = machMaintTasks.find(x => x.id === deferBtn.dataset.id);
          if (!tk) return;
          Object.assign(tk, KhaytMaintenance.deferTask(tk, machineHoursMeter(machineId), new Date().toISOString()));
          saveAll();
          refreshTasks();
          toast(t('maint.deferred'), 'success');
        } else if (doneBtn) {
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
   Parts to buy (care plans)
   ============================================================ */
// The parts the shop's care-plan tasks will consume in the next 90 days, with
// the date to order each by (lib/care-plans.js partsBuyList: due dates projected
// from each machine's last 30 days of print hours, less a typical delivery
// time). Read-only: nothing here changes the book.
function partsToBuyRows() {
  if (typeof KhaytCarePlans === 'undefined') return [];
  return KhaytCarePlans.partsBuyList({
    machines, tasks: typeof machMaintTasks !== 'undefined' ? machMaintTasks : [],
    jobs: printLog, now: Date.now(),
  });
}

function partsToBuyText(rows) {
  const day = (iso) => new Date(iso).toLocaleDateString(localeTag());
  return [t('maint.pb_title'), ''].concat(rows.map(r =>
    `${t('maint.part_' + r.partId)} ×${r.qty} — ${r.machineName} (${r.taskName}) — ${
      r.late ? t('maint.pb_late') : t('maint.pb_order_by').replace('{date}', day(r.orderBy))}; ${
      t('maint.pb_due').replace('{date}', day(r.dueAt))}`)).join('\n');
}

function openPartsToBuy() {
  const rows = partsToBuyRows();
  const day = (iso) => new Date(iso).toLocaleDateString(localeTag());
  const table = rows.length ? `<div class="table-wrap"><table id="pbTable"><tbody>${rows.map(r => `
      <tr data-part="${escapeHtml(r.partId)}">
        <td><strong>${escapeHtml(t('maint.part_' + r.partId))}</strong> ×${r.qty}<br><span style="font-size:11px;color:var(--text-muted);">${escapeHtml(r.machineName)} · ${escapeHtml(r.taskName)}</span></td>
        <td style="white-space:nowrap;font-size:12px;${r.late ? 'color:var(--danger);font-weight:600;' : ''}">${escapeHtml(r.late ? t('maint.pb_late') : t('maint.pb_order_by').replace('{date}', day(r.orderBy)))}</td>
        <td style="white-space:nowrap;font-size:12px;color:var(--text-muted);">${escapeHtml(t('maint.pb_due').replace('{date}', day(r.dueAt)))}</td>
      </tr>`).join('')}</tbody></table></div>`
    : `<p id="pbNone" style="color:var(--text-muted);font-size:13px;text-align:center;padding:16px 0;">${escapeHtml(t('maint.pb_none'))}</p>`;
  openFormModal({
    title: t('maint.pb_title'),
    noSave: true,
    sizeLg: true,
    bodyHtml: `<p style="font-size:12px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(t('maint.pb_hint'))}</p>
      ${table}
      ${rows.length ? `<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px;">
        <button type="button" class="btn small" id="pbCopy">${escapeHtml(t('maint.pb_copy'))}</button>
        <button type="button" class="btn small" id="pbPrint">${escapeHtml(t('common.print'))}</button>
      </div>` : ''}`,
    onMount(modal) {
      modal.querySelector('#pbCopy')?.addEventListener('click', () => { copyAndToast(partsToBuyText(rows)); });
      modal.querySelector('#pbPrint')?.addEventListener('click', () => {
        const area = document.getElementById('work-order-print-area');
        if (!area) return;
        area.innerHTML = `<div class="inv-wrap wo-wrap" dir="${document.documentElement.dir || 'ltr'}"><h2>${escapeHtml(t('maint.pb_title'))}</h2>${table}</div>`;
        setTimeout(() => window.print(), 80);
      });
    },
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
      jobs: printLog.filter((o) => o && o.machineId === machine.id && KhaytOrderStatus.isFinished(o)),
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
    if (KhaytOrderStatus.isFinished(o) || o.status === 'quote') continue;
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

// What each machine with depreciation set has printed a month lately
// (lib/depreciation.js recentMonthlyHours, the last 90 days of finished work),
// `{ [machineId]: hours }`. A straight-line machine needs it to turn its
// monthly amount into an hourly wear rate; the Mac passes the same figure to
// its quotes and both P&Ls (Shop.swift `recentMonthlyHours`).
function machineRecentHours() {
  const D = (typeof KhaytDepreciation !== 'undefined') ? KhaytDepreciation : null;
  if (!D) return {};
  const d = new Date();
  const today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const orders = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
  const out = {};
  for (const m of (typeof machines !== 'undefined' && Array.isArray(machines)) ? machines : []) {
    if (!m || !m.id || !D.settingsOf(m)) continue;
    const h = D.recentMonthlyHours(orders, m.id, { today });
    if (h) out[m.id] = h;
  }
  return out;
}

// The wear rate a quote charges on this machine: the one its depreciation
// works out when it has any (lib/print-rates.js step 4, as the Mac quotes),
// else the flat rate the shop typed. Null when it has neither.
function machineWearRate(m) {
  if (!m) return null;
  const D = (typeof KhaytDepreciation !== 'undefined') ? KhaytDepreciation : null;
  const derived = D ? D.hourlyRate(m, { recentMonthlyHours: machineRecentHours()[m.id] }) : null;
  if (derived !== null && derived !== undefined) return derived;
  return (m.wearRate != null && m.wearRate !== '') ? m.wearRate : null;
}

  const api = {
    machineControlsHtml,
    printerJobCommand,
    plugSwitch,
    refreshPlug,
    smartPlugCardHtml,
    printerControl,
    openDropObject,

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
    unretireMachine,
    openMaintLog,
    openPartsToBuy,
    partsToBuyRows,
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
    machineRecentHours,
    machineWearRate,
  };
  Object.assign(global, api);
  global.KhaytMachines = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
