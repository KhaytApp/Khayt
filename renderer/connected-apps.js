'use strict';
/**
 * Connected apps (Windows/Linux): the slicers paired with this computer, "Show
 * prices in OrcaSlicer" and each slicer's grant, and the "From slicer" inbox.
 * Built to the frames Turki signed off (Figma 7Iqw0GcrLLRW7CLDEhTa1P, page
 * 131:151): CA1 the owner with prices on and the inbox, CA2 a manager (prices
 * shown, not changeable), CA3 nothing paired yet, CA4 the sidebar entry whose
 * count is the files waiting; the Arabic frame 132:220 right to left.
 *
 * DARK BEHIND "PAIR A SLICER" (KHAYT_CONNECTOR_PAIRING=1, main's switch, off by
 * default): while off there is no sidebar entry and no screen.
 *
 * Main decides everything here (lib/lan-server.js hub:connector-*,
 * hub:slicer-inbox-*): who may pair, change prices or grant cost is main's own
 * reading of who is signed in. This file draws main's answers and sends the
 * person's choices. The inbox's three answers go through the paths the app
 * already has: the library's own intake (KhaytPrintFiles.addFromPath), and the
 * New Job sheet (openNewJobSheet) for a job or a quote, as the Mac's
 * Shop+SlicerInbox takeSlicerUpload does. Nothing is added on its own: "Asked:"
 * is the plugin's suggestion, shown and never acted on.
 *
 * No customer data on this screen. The only text from outside the app is what
 * a slicer sent: its name and the file names, each inside <bdi>.
 */
(function (global) {

const ACTIVE_MS = 10 * 60 * 1000;   // a signed request in the last 10 minutes
const POLL_MS = 4000;               // the screen, while it is open
const COUNT_MS = 20000;             // the sidebar count

const tr = (k, v) => (typeof t === 'function' ? t(k, v) : k);
const esc = (s) => (typeof escapeHtml === 'function' ? escapeHtml(String(s == null ? '' : s))
  : String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])));
const api = () => global.hubAPI || {};
// Dates and numbers in the chosen language, the app's one rule (renderer/format.js localeTag).
const localeTag = () => (global.KhaytFormat && typeof global.KhaytFormat.localeTag === 'function' ? global.KhaytFormat.localeTag() : 'en-US');
const may = (area, action) => (typeof operatorCan === 'function' ? operatorCan(area, action) : true);
const say = (text, kind) => { if (typeof toast === 'function') toast(text, kind || 'info'); };

/**
 * A translated sentence with machine-supplied values (a slicer's name, a file
 * name, a machine) set inside <bdi>, so a Latin name keeps its own direction
 * inside an Arabic sentence. Everything is escaped.
 */
function withBdi(key, vars) {
  const names = Object.keys(vars || {});
  const marks = {};
  names.forEach((n, i) => { marks[n] = `\u0001${i}\u0001`; });
  let out = esc(tr(key, marks));
  names.forEach((n, i) => { out = out.split(`\u0001${i}\u0001`).join(`<bdi>${esc(vars[n])}</bdi>`); });
  return out;
}

// ── What main says ──────────────────────────────────────────────────────────

let _state = null;      // { pair, prices, items }
let _sig = '';
let _enabled = null;

async function load() {
  const a = api();
  const safe = async (f, d) => { try { return (typeof f === 'function' ? await f() : null) || d; } catch (_) { return d; } };
  const [pair, prices, inbox] = await Promise.all([
    safe(a.connectorPairState, { enabled: false }),
    safe(a.connectorPricesState, { on: false, mayChange: false, mayGrantCost: false, connectors: [] }),
    safe(a.slicerInboxList, { items: [] }),
  ]);
  return { pair, prices, items: Array.isArray(inbox.items) ? inbox.items : [] };
}

// ── Pieces ──────────────────────────────────────────────────────────────────

const day = (iso) => {
  const n = Date.parse(String(iso || ''));
  return Number.isFinite(n) ? new Date(n).toLocaleDateString(localeTag(), { day: 'numeric', month: 'short' }) : '';
};
const isActive = (iso, now) => { const n = Date.parse(String(iso || '')); return Number.isFinite(n) && now - n <= ACTIVE_MS; };

function filesFrom(n) {
  if (n === 1) return tr('ca.files_from_one');
  if (n === 2) return tr('ca.files_from_two', { n });
  return tr('ca.files_from', { n });
}

/** "12.3 g · 1 h 02 m · PLA": what this computer read off the file itself. */
function figures(item) {
  const out = [];
  const g = Number(item.grams);
  if (Number.isFinite(g) && g > 0) out.push(esc(tr('ca.grams', { n: g.toLocaleString(localeTag(), { minimumFractionDigits: 1, maximumFractionDigits: 1 }) })));
  const mins = Math.round(Number(item.minutes));
  if (Number.isFinite(mins) && mins > 0) {
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    out.push(esc(h ? tr('ca.hours_mins', { h, m: String(m).padStart(2, '0') }) : tr('ca.mins', { m })));
  }
  if (item.material) out.push(`<bdi>${esc(item.material)}</bdi>`);
  return out;
}

/** Where it came from: the paired plugin, or a slicer sending to Khayt as a printer. */
function originHtml(item) {
  if (item.source === 'connector') return `<bdi>${esc(item.connectorName || tr('ca.unnamed'))}</bdi>`;
  return item.slicer ? withBdi('ca.via_printer', { slicer: item.slicer }) : esc(tr('ca.via_printer_unknown'));
}

/** The plugin's suggestion, in words: "Asked: quote". Never acted on. */
function askedHtml(item) {
  const s = item.suggested && typeof item.suggested === 'object' ? item.suggested : null;
  if (!s || item.source !== 'connector') return '';
  let text = '';
  if (s.intent === 'quote') text = esc(tr('ca.asked_quote'));
  else if (s.intent === 'job') text = esc(tr('ca.asked_job'));
  else if (s.intent === 'print') {
    const list = typeof machines !== 'undefined' && Array.isArray(machines) ? machines : [];
    const m = list.find((x) => x && x.id === s.machineId);
    text = withBdi('ca.asked_print', { machine: (m && m.name) || s.machineId || '' });
  } else if (s.intent === 'attach') {
    const orders = typeof printLog !== 'undefined' && Array.isArray(printLog) ? printLog : [];
    const o = orders.find((x) => x && x.id === s.jobId);
    text = withBdi('ca.asked_attach', { job: o && typeof jobRef === 'function' ? jobRef(o) : (s.jobId || '') });
  }
  return text ? `<span class="ca-asked">${text}</span>` : '';
}

function switchHtml(on, enabled) {
  return `<button type="button" class="iu-switch ca-switch${on ? ' on' : ''}" role="switch" aria-checked="${on}" aria-label="${esc(tr('ca.prices_title'))}" title="${esc(tr('ca.prices_title'))}" data-ca-prices${enabled ? '' : ' disabled'}><span class="iu-knob"></span></button>`;
}

function grantHtml(c, pr) {
  const grant = c.priceGrant === 'price' || c.priceGrant === 'cost' ? c.priceGrant : '';
  const opts = [['', tr('ca.grant_none')], ['price', tr('ca.grant_price')], ['cost', tr('ca.grant_cost')]]
    .map(([v, label]) => {
      // "Price and cost" also needs the right to see reports (main checks it again).
      const off = v === 'cost' && !pr.mayGrantCost && grant !== 'cost';
      return `<option value="${v}"${v === grant ? ' selected' : ''}${off ? ' disabled' : ''}>${esc(label)}</option>`;
    }).join('');
  const id = 'caGrant_' + String(c.deviceId).replace(/[^A-Za-z0-9_-]/g, '');
  return `<div class="ca-field"><label for="${esc(id)}">${esc(tr('ca.grant_label'))}</label>
    <select id="${esc(id)}" data-ca-grant="${esc(c.deviceId)}"${pr.mayChange ? '' : ' disabled'}>${opts}</select></div>`;
}

function slicerRowHtml(c, ctx) {
  const name = c.name || tr('ca.unnamed');
  const active = isActive(c.lastSeenAt, ctx.now);
  const state = active
    ? `<span class="ca-active">${esc(tr('ca.active'))}</span>`
    : (day(c.lastSeenAt) ? `<span class="ca-seen">${esc(tr('ca.last_seen', { date: day(c.lastSeenAt) }))}</span>` : '');
  const scope = [tr('ca.scope_base')];
  if (ctx.pricesOn && c.priceGrant === 'price') scope.push(tr('ca.scope_price'));
  if (ctx.pricesOn && c.priceGrant === 'cost') scope.push(tr('ca.scope_cost'));
  const waiting = ctx.items.filter((i) => i.connectorId === c.deviceId).length;
  return `<div class="ca-row" data-ca-slicer="${esc(c.deviceId)}">
    <div class="ca-main">
      <div class="ca-name"><bdi>${esc(name)}</bdi>${state}</div>
      <div class="ca-line">${esc(tr('ca.app_orca'))}</div>
      <div class="ca-line">${esc(scope.join(' · '))}</div>
      ${waiting ? `<div class="ca-line ca-link">${esc(filesFrom(waiting))}</div>` : ''}
    </div>
    ${grantHtml(c, ctx.prices)}
    ${ctx.canSignOut ? `<button type="button" class="linkish ca-linkbtn" data-ca-signout="${esc(c.deviceId)}" data-name="${esc(name)}">${esc(tr('ca.sign_out'))}</button>` : ''}
  </div>`;
}

function inboxRowHtml(item, ctx) {
  const meta = [originHtml(item)].concat(figures(item)).join(' · ');
  const dis = (ok) => (ok ? '' : ' disabled');
  return `<div class="ca-row ca-item" data-ca-item="${esc(item.id)}">
    <div class="ca-main">
      <div class="ca-name ca-file"><bdi>${esc(item.name)}</bdi>${askedHtml(item)}</div>
      <div class="ca-line">${meta}</div>
      <div class="ca-actions">
        <button type="button" class="btn small" data-ca-act="library" data-id="${esc(item.id)}"${dis(ctx.canFile)}>${esc(tr('ca.add_library'))}</button>
        <button type="button" class="btn small" data-ca-act="job" data-id="${esc(item.id)}"${dis(ctx.canJob)}>${esc(tr('ca.new_job'))}</button>
        <button type="button" class="btn small" data-ca-act="quote" data-id="${esc(item.id)}"${dis(ctx.canJob)}>${esc(tr('ca.new_quote'))}</button>
        <button type="button" class="linkish ca-linkbtn" data-ca-act="discard" data-id="${esc(item.id)}"${dis(ctx.canFile)}>${esc(tr('ca.discard'))}</button>
      </div>
    </div>
  </div>`;
}

function inboxHtml(items, ctx) {
  return `<div class="card ca-card" data-ca-inbox>
    <div class="ca-head"><div><div class="ca-h">${esc(tr('ca.inbox_title'))}</div>
      <div class="ca-sub">${esc(items.length ? tr('ca.inbox_sub', { n: items.length }) : tr('ca.inbox_empty'))}</div></div></div>
    ${items.map((i) => inboxRowHtml(i, ctx)).join('')}
  </div>`;
}

/** The whole screen, from main's answers. */
function screenHtml(st, now) {
  const pr = st.prices || {};
  const connectors = Array.isArray(pr.connectors) ? pr.connectors : [];
  const mayPair = !!(st.pair && st.pair.mayPair);
  const pairBtn = `<button type="button" class="btn primary ca-pair" data-ca-pair${mayPair ? '' : ` disabled title="${esc(tr('ca.pair_ask_owner'))}"`}>${esc(tr('ca.pair_btn'))}</button>`;
  const ctx = {
    now, items: st.items, prices: pr, pricesOn: !!pr.on,
    // Signing a slicer out is for whoever may pair one (the owner or a manager, main's reading), as on the Mac.
    canSignOut: mayPair,
    canFile: may('inventory', 'create'),
    canJob: may('inventory', 'create') && may('orders', 'create'),
  };
  if (!connectors.length) {
    // CA3: nothing paired yet. The inbox still shows what a slicer sent as a printer.
    return `<div class="ca-screen ca-empty">
      <h2 class="ca-title">${esc(tr('ca.title'))}</h2>
      <div class="ca-none">${esc(tr('ca.none_title'))}</div>
      <p class="ca-sub ca-none-body">${esc(tr('ca.none_body'))}</p>
      <div class="ca-none-act">${pairBtn}</div>
      ${st.items.length ? inboxHtml(st.items, ctx) : ''}
    </div>`;
  }
  return `<div class="ca-screen">
    <div class="ca-top">
      <div class="ca-top-text"><h2 class="ca-title">${esc(tr('ca.title'))}</h2><div class="ca-sub">${esc(tr('ca.sub'))}</div></div>
      ${pairBtn}
    </div>
    <div class="card ca-card ca-prices">
      <div class="ca-switch-row">
        <div class="ca-switch-text"><div class="ca-label">${esc(tr('ca.prices_title'))}</div><div class="ca-sub">${esc(tr('ca.prices_sub'))}</div></div>
        ${switchHtml(!!pr.on, !!pr.mayChange)}
      </div>
      ${pr.mayChange ? '' : `<div class="ca-sub ca-owner-only">${esc(tr('ca.prices_owner_only'))}</div>`}
    </div>
    <div class="card ca-card" data-ca-slicers>
      <div class="ca-head"><span class="ca-h">${esc(tr('ca.paired_title'))}</span><span class="ca-count">${esc(String(connectors.length))}</span></div>
      ${connectors.map((c) => slicerRowHtml(c, ctx)).join('')}
      ${pr.mayChange ? `<div class="ca-sub ca-note">${esc(tr('ca.grant_note'))}</div>` : ''}
    </div>
    ${inboxHtml(st.items, ctx)}
  </div>`;
}

// ── The screen ──────────────────────────────────────────────────────────────

const root = () => document.getElementById('connectedAppsRoot');
const isOpen = () => !!document.getElementById('connectedapps-tab')?.classList.contains('active');

async function render(force) {
  const box = root();
  if (!box) return;
  const st = await load();
  setEnabled(!!(st.pair && st.pair.enabled));
  setCount(st.items.length);
  if (!st.pair || !st.pair.enabled) { box.innerHTML = ''; return; }
  // A redraw that would change nothing, or would pull a list out from under
  // the person choosing in it, waits for the next one.
  const sig = JSON.stringify([st, i18nLang(), Math.floor(Date.now() / 60000)]);
  if (!force && (sig === _sig || box.contains(document.activeElement) && document.activeElement.tagName === 'SELECT')) return;
  _sig = sig;
  _state = st;
  box.innerHTML = screenHtml(st, Date.now());
}
const i18nLang = () => (typeof i18n !== 'undefined' && i18n && i18n.current) || 'en';

function itemOf(id) { return (_state && _state.items || []).find((i) => i.id === id) || null; }

/** Into the library first, as the Mac does: then a job or a quote opens from it. */
async function take(id, what) {
  const item = itemOf(id);
  if (!item) return;
  let read = null;
  try { read = await api().slicerInboxRead(id); } catch (_) { read = null; }
  if (!read || !read.ok || !read.file) { say(tr('ca.gone'), 'error'); return render(true); }
  const P = global.KhaytPrintFiles;
  const rec = P && typeof P.addFromPath === 'function' ? await P.addFromPath(read.file, item.sha256) : null;
  if (!rec) { say(tr('ca.add_failed'), 'error'); return; }
  try { await api().slicerInboxDiscard(id); } catch (_) { /* it is in the library; the row goes on the next read */ }
  await render(true);
  if (what === 'library') { say(tr('ca.added', { name: rec.name || item.name }), 'success'); return; }
  const stem = String(item.name).replace(/\.gcode\.3mf$/i, '').replace(/\.[^.]+$/, '');
  const fromSlicer = item.source === 'connector' && item.connectorId
    ? Object.assign({ connectorId: item.connectorId, name: item.name }, item.sha256 ? { sha256: item.sha256 } : {}, item.sliceId ? { sliceId: item.sliceId } : {})
    : null;
  if (typeof openNewJobSheet === 'function') {
    openNewJobSheet({
      project: stem, asQuote: what === 'quote', fromSlicer,
      part: { name: stem, grams: Number(item.grams) || 0, hours: (Number(item.minutes) || 0) / 60, material: item.material || '' },
    });
  }
}

async function discard(id) {
  const item = itemOf(id);
  if (!item) return;
  const ok = typeof confirmModal === 'function'
    ? await confirmModal(tr('ca.discard_q', { name: item.name }) + '\n\n' + tr('ca.discard_note'), { okText: tr('ca.discard'), danger: true })
    : true;
  if (!ok) return;
  let r = null;
  try { r = await api().slicerInboxDiscard(id); } catch (_) { r = null; }
  if (!r || !r.ok) say(tr('ca.gone'), 'error');
  render(true);
}

async function signOut(btn) {
  const name = btn.dataset.name || tr('ca.unnamed');
  const ok = typeof confirmModal === 'function'
    ? await confirmModal(tr('ca.signout_q', { name }) + '\n\n' + tr('ca.signout_note'), { okText: tr('ca.sign_out'), danger: true })
    : true;
  if (!ok) return;
  let r = null;
  try { r = await api().removeLanDevice(btn.dataset.caSignout); } catch (_) { r = null; }
  if (!r || !r.ok) say(tr('ca.signout_failed'), 'error');
  render(true);
}

function wire() {
  const box = root();
  if (!box || box.dataset.caWired) return;
  box.dataset.caWired = '1';
  box.addEventListener('click', async (e) => {
    const pair = e.target.closest('[data-ca-pair]');
    if (pair && !pair.disabled) {
      if (global.KhaytPhonePairing) global.KhaytPhonePairing.openDialog(() => render(true), { kind: 'connector' });
      return;
    }
    const sw = e.target.closest('[data-ca-prices]');
    if (sw && !sw.disabled) {
      let r = null;
      try { r = await api().setConnectorPrices({ on: !sw.classList.contains('on') }); } catch (_) { r = null; }
      if (!r || r.ok === false) say(tr('ca.change_failed'), 'error');
      render(true);
      return;
    }
    const so = e.target.closest('[data-ca-signout]');
    if (so) { signOut(so); return; }
    const act = e.target.closest('[data-ca-act]');
    if (act && !act.disabled) {
      const id = act.dataset.id;
      act.disabled = true;
      if (act.dataset.caAct === 'discard') await discard(id);
      else await take(id, act.dataset.caAct);
      act.disabled = false;
    }
  });
  box.addEventListener('change', async (e) => {
    const sel = e.target.closest('[data-ca-grant]');
    if (!sel) return;
    let r = null;
    try { r = await api().setConnectorGrant({ deviceId: sel.dataset.caGrant, grant: sel.value || null }); } catch (_) { r = null; }
    if (!r || r.ok === false) say(tr('ca.change_failed'), 'error');
    sel.blur();
    render(true);
  });
}

// ── The sidebar entry (CA4): there only while pairing is on; its count is the files waiting ──

function navBtn() { return document.querySelector('.tab-btn[data-tab="connectedapps-tab"]'); }

function setEnabled(on) {
  _enabled = on;
  const b = navBtn();
  // A class, not an inline style: the staff lock resets every tab button's display.
  if (b) b.classList.toggle('ca-off', !on);
  // A theme hides a nav group with nothing showing in it.
  try { global.KhaytWorkbenchShell?.syncGroupVisibility?.(); } catch (_) { /* no theme */ }
  if (!on && isOpen() && global.KhaytShell?.switchTab) global.KhaytShell.switchTab('dashboard-tab');
}

function setCount(n) {
  const b = navBtn();
  if (!b) return;
  let c = b.querySelector('.ca-nav-count');
  if (!n) { if (c) c.remove(); return; }
  if (!c) { c = document.createElement('span'); c.className = 'ca-nav-count'; b.appendChild(c); }
  c.textContent = String(n);
  c.setAttribute('aria-label', tr('ca.nav_count', { n }));
}

async function refreshCount() {
  let pair = null;
  try { pair = await api().connectorPairState(); } catch (_) { pair = null; }
  setEnabled(!!(pair && pair.enabled));
  if (!_enabled) return;
  let inbox = null;
  try { inbox = await api().slicerInboxList(); } catch (_) { inbox = null; }
  setCount(inbox && Array.isArray(inbox.items) ? inbox.items.length : 0);
}

let _poll = null;
/** Called by switchTab when the screen opens. */
function renderConnectedApps() {
  wire();
  render(true);
  if (!_poll) _poll = setInterval(() => { if (isOpen()) render(false); }, POLL_MS);
}

function boot() {
  refreshCount().then(() => {
    if (_enabled) setInterval(() => { if (!isOpen()) refreshCount(); }, COUNT_MS);
  });
  document.addEventListener('languagechange', () => { if (isOpen()) render(true); else if (_enabled) refreshCount(); });
}

const exported = { renderConnectedApps, refreshCount, screenHtml, withBdi, figures, isActive, ACTIVE_MS };
global.KhaytConnectedApps = exported;
global.renderConnectedApps = renderConnectedApps;
if (typeof module !== 'undefined' && module.exports) module.exports = exported;
if (typeof document !== 'undefined' && typeof window !== 'undefined') {
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else setTimeout(boot, 0);
}

})(typeof window !== 'undefined' ? window : globalThis);
