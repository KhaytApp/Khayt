'use strict';
/**
 * Settings › General › Internet use: the "Make no internet calls" switch (P8
 * PR 5). Built to the frames Turki signed off on Nov 22 (Figma
 * 7Iqw0GcrLLRW7CLDEhTa1P page 111:1041: A switch on, B switch off, C updates
 * off for 30+ days, D the refusal messages).
 *
 *   - The shop's switch is `settings.network` in the book ({offline, keep,
 *     changedAt, changedBy}). Only the owner changes it under the staff lock;
 *     main's save guard puts back anyone else's change, and the window says so
 *     in its own words (err.refused_network).
 *   - "Also on this computer only" is main's network-local.json (stricter,
 *     never looser): hub:outbound-set-local.
 *   - One row per purpose from lib/outbound.js describe() through
 *     hub:outbound-describe, with this session's block counts. "Lookups" is
 *     the Mac's and the iPhone's only, so it is not listed here.
 *   - The Updates row turns red, and a banner shows on every screen, after 30
 *     days without a check while updates are blocked (D2: no one-time
 *     override; "Keep updates" is one tick away).
 *   - A person-started call the switch refuses is said in the shop's language
 *     with a way here (frame D). The preload reports every refused reply; it is
 *     said only when a person acted a moment before, so automatic calls never
 *     toast: they are counted on their row.
 */
(function (global) {

const DAY = 24 * 60 * 60 * 1000;
const STALE_DAYS = 30;
/** Frame A's order. 'lookups' is Mac and iPhone only. */
const ORDER = ['updates', 'install-count', 'crash-reports', 'usage-stats', 'cloud', 'storage', 'messaging', 'webhooks',
  'payments', 'storefront', 'ai', 'tax-authority', 'exchange-rates', 'makerrun', 'catalogues', 'tunnel', 'switch-sync', 'lan'];
/** Consequence lines, on these rows only (design §4.4) and only while the row is blocked. */
const CONSEQUENCE = ['updates', 'cloud', 'storage', 'messaging', 'payments', 'storefront'];

const tr = (k, p) => (typeof t === 'function' ? t(k, p) : k);
const esc = (s) => (typeof escapeHtml === 'function' ? escapeHtml(String(s == null ? '' : s))
  : String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])));
const S = () => (typeof settings !== 'undefined' && settings) ? settings : {};
// Dates in the chosen language, the app's one rule (renderer/format.js localeTag).
const localeTag = () => (global.KhaytFormat && typeof global.KhaytFormat.localeTag === 'function' ? global.KhaytFormat.localeTag() : 'en-US');
const ms = (iso) => { const n = Date.parse(String(iso || '')); return Number.isFinite(n) ? n : null; };
const fmtDate = (iso) => { const n = ms(iso); return n === null ? '' : new Date(n).toLocaleDateString(localeTag(), { day: 'numeric', month: 'short', year: 'numeric' }); };
const fmtDay = (iso) => { const n = ms(iso); return n === null ? '' : new Date(n).toLocaleDateString(localeTag(), { day: 'numeric', month: 'short' }); };
const fmtTime = (iso) => { const n = ms(iso); return n === null ? '' : new Date(n).toLocaleTimeString(localeTag(), { hour: '2-digit', minute: '2-digit' }); };

function network() {
  const n = S().network;
  return n && typeof n === 'object' && !Array.isArray(n) ? n : {};
}
/* The shop's switch as MAIN reads it from the saved book (hub:outbound-describe
 * `shop`), so the page never shows a change that a refused or failed save did
 * not keep (review of #2633). Before the first answer, the window's copy, read
 * as lib/outbound.js reads it: anything present but false is ON. */
function shopView() {
  if (_last && _last.shop) return _last.shop;
  const n = network();
  return { offline: n.offline !== undefined && n.offline !== null && n.offline !== false,
    keep: Array.isArray(n.keep) ? n.keep.filter((k) => typeof k === 'string') : [], changedAt: n.changedAt || null, changedBy: n.changedBy || null };
}
function shopOffline() { return !!shopView().offline; }
function keptList() { return Array.isArray(shopView().keep) ? shopView().keep.slice() : []; }

/** Who may change it: the owner, or anyone while the staff lock is off (main decides; this only greys the controls). */
function mayChange() {
  if (!S().operatorLockEnabled) return true;
  return typeof currentOperatorRoleKey === 'function' && currentOperatorRoleKey() === 'owner';
}
function whoChanges() {
  if (!S().operatorLockEnabled) return null;
  const ops = typeof operators !== 'undefined' && Array.isArray(operators) ? operators : [];
  const op = ops.find((o) => o && o.id === S().activeOperatorId);
  return op && op.name ? String(op.name) : null;
}

/** Whether an integration is set up, where the book can say. Unknown is "set up": never hide a real call. */
function setUp(purpose, ctx) {
  const s = S();
  switch (purpose) {
    case 'webhooks': {
      const w = s.webhooks || {};
      const ev = s.eventWebhooks || {};
      return !!((w.enabled && Object.values(w.events || {}).some((u) => String(u || '').trim()))
        || (ev.enabled && Object.values(ev).some((u) => /^https:\/\//i.test(String(u || '')))));
    }
    case 'tax-authority': return !!(s.zatcaPhase2 && s.zatcaPhase2.enabled);
    case 'ai': return !!(s.ai && s.ai.enabled);
    case 'payments': { const b = s.bnpl || {}; return !!((b.tabby && b.tabby.enabled) || (b.tamara && b.tamara.enabled) || (b.stripe && b.stripe.enabled)); }
    case 'messaging': {
      const email = s.emailConfig && s.emailConfig.provider && s.emailConfig.provider !== 'none';
      const sms = s.smsConfig && s.smsConfig.provider && s.smsConfig.provider !== 'none';
      return !!(email || sms || (s.ntfy && s.ntfy.enabled) || (s.telegram && s.telegram.botToken && s.telegram.chatId) || (s.customSmtp && s.customSmtp.host));
    }
    // The library's own bucket or Drive, or off-site backups to one. A folder
    // (a USB disk, a NAS) is never an internet call (review of #2633).
    case 'storage': return !!((ctx && ctx.setup && ctx.setup.storageLibrary) || cloudBackups(ctx));
    case 'tunnel': return !!(s.lanApi && s.lanApi.enabled);
    default: return true;
  }
}

/** Off-site backups that go over the internet: on, to the bucket or Drive, and able to run. */
function cloudBackups(ctx) {
  const o = ctx && ctx.offsite;
  const st = o && o.settings;
  return !!(st && st.enabled === true && (st.destination === 'bucket' || st.destination === 'drive') && o.ready);
}

/** { key, tone } of a row's state: tone 'ok' green, 'off' grey, 'bad' red. */
/** A purpose's OWN switch is off (frame A shows it so even while the master switch blocks). */
function ownSwitchOff(row, ctx) {
  if (row.reason === 'opted-out') return true;
  const tel = S().telemetry || {};
  if (row.purpose === 'crash-reports') return tel.crashOptIn !== true;
  if (row.purpose === 'usage-stats') return tel.usageOptIn !== true;
  if (row.purpose === 'install-count') return !!(ctx && ctx.activeCount && ctx.activeCount.on === false);
  return false;
}

function stateOf(row, ctx) {
  if (row.purpose === 'lan') return { key: 'iu.st.always', tone: 'ok' };
  if (ownSwitchOff(row, ctx)) return { key: 'iu.st.own_switch', tone: 'off' };
  if (!setUp(row.purpose, ctx)) return { key: 'iu.st.not_set_up', tone: 'off' };
  if (row.allowed) return row.reason === 'kept' ? { key: 'iu.st.kept', tone: 'ok' } : { key: 'iu.st.allowed', tone: 'ok' };
  return { key: 'iu.st.blocked', tone: 'bad' };
}

/** Days since updates last reached the feed, or since the switch went on when they never have. */
function updatesStale(row, ctx) {
  if (!row || row.purpose !== 'updates' || row.allowed) return null;
  // The last check; else when the switch first refused one here; else when the
  // switch that blocks it (the shop's, or this computer's own) went on.
  const switchAt = row.reason === 'offline-here' ? (ctx && ctx.local && ctx.local.changedAt) : shopView().changedAt;
  const since = ms(ctx && ctx.updatesLastCheckedAt) || ms(ctx && ctx.updatesBlockedSince) || ms(switchAt);
  if (since === null) return null;
  const days = Math.floor((Date.now() - since) / DAY);
  return days >= STALE_DAYS ? days : null;
}

function consequence(row, ctx) {
  if (CONSEQUENCE.indexOf(row.purpose) === -1 || row.allowed || ownSwitchOff(row, ctx) || !setUp(row.purpose, ctx)) return '';
  if (row.purpose === 'updates') {
    const at = ctx && ctx.updatesLastCheckedAt;
    if (!at) return tr('iu.c.updates_never');
    const days = updatesStale(row, ctx);
    return days ? tr('iu.c.updates_days', { date: fmtDate(at), n: days }) : tr('iu.c.updates', { date: fmtDate(at) });
  }
  if (row.purpose === 'storage') {
    if (!cloudBackups(ctx)) return '';
    const last = ctx && ctx.offsite && ctx.offsite.status && ctx.offsite.status.lastAt;
    return last ? tr('iu.c.storage', { date: fmtDate(last) }) : tr('iu.c.storage_never');
  }
  return tr('iu.c.' + row.purpose);
}

function blockedLine(row) {
  if (!row.blockedCount) return '';
  return ' ' + tr(row.blockedCount === 1 ? 'iu.blocked_one' : 'iu.blocked_many', { n: row.blockedCount, at: fmtTime(row.lastBlockedAt) });
}

let _last = null;   // the last describe() answer, for the banner

async function load() {
  const api = global.hubAPI || {};
  let d = null, offsite = null, activeCount = null;
  try { d = api.outboundDescribe ? await api.outboundDescribe() : null; } catch (_) { d = null; }
  try { offsite = api.offsiteGet ? await api.offsiteGet() : null; } catch (_) { offsite = null; }
  try { activeCount = api.activeCountGet ? await api.activeCountGet() : null; } catch (_) { activeCount = null; }
  _last = d && Array.isArray(d.rows) ? Object.assign({}, d, { offsite, activeCount }) : null;
  return _last;
}

function switchHtml(id, on, disabled, labelId) {
  return `<button type="button" class="iu-switch${on ? ' on' : ''}" id="${id}" role="switch" aria-checked="${on}" aria-labelledby="${labelId}"${disabled ? ' disabled' : ''}><span class="iu-knob"></span></button>`;
}

function render(ctx) {
  const host = document.getElementById('internetUseBody');
  if (!host) return;
  if (!ctx) { host.innerHTML = `<p class="iu-muted">${esc(tr('iu.unavailable'))}</p>`; return; }
  const on = shopOffline();
  const here = !!(ctx.local && ctx.local.offline);
  const can = mayChange();
  const n = shopView();
  let shopNote = tr('iu.shop_hint');
  if (on) {
    const when = ms(n.changedAt) !== null ? tr(n.changedBy ? 'iu.turned_on_by' : 'iu.turned_on', { who: n.changedBy || '', day: fmtDay(n.changedAt), time: fmtTime(n.changedAt) }) : '';
    shopNote += ' ' + [when, tr('iu.turned_on_tail')].filter(Boolean).join(' ');
  } else {
    shopNote += ' ' + tr('iu.off_tail');
  }
  const rows = ORDER.map((p) => ctx.rows.find((r) => r.purpose === p)).filter(Boolean);
  const showKeep = on;
  const head = `
    <div class="card iu-switches">
      <div class="iu-switch-row">
        ${switchHtml('iuShopSwitch', on, !can, 'iuShopLabel')}
        <div><div class="iu-label" id="iuShopLabel">${esc(tr('iu.shop_switch'))}</div>
        <div class="iu-sub">${esc(shopNote)}</div></div>
      </div>
      <div class="iu-switch-row">
        ${switchHtml('iuHereSwitch', here, !can, 'iuHereLabel')}
        <div><div class="iu-label" id="iuHereLabel">${esc(tr('iu.here_switch'))}</div>
        <div class="iu-sub">${esc(tr('iu.here_hint'))}</div></div>
      </div>
      ${can ? '' : `<p class="iu-sub iu-owner-only">${esc(tr('iu.owner_only'))}</p>`}
    </div>
    <div class="iu-section">${esc(tr('iu.section'))}</div>
    <div class="iu-cols${showKeep ? '' : ' no-keep'}"><span>${esc(tr('iu.col_what'))}</span><span>${esc(tr('iu.col_when'))}</span><span>${esc(tr('iu.col_state'))}</span>${showKeep ? `<span>${esc(tr('iu.col_keep'))}</span>` : ''}</div>`;
  const body = rows.map((row) => {
    const st = stateOf(row, ctx);
    const stale = updatesStale(row, ctx);
    const cons = consequence(row, ctx);
    const lanRow = row.purpose === 'lan';
    // switch-sync is kept by its own rule (lib/outbound.js switchSyncKept):
    // its tick is "not unticked", settings.network.dropSwitchSync, never `keep`.
    const syncRow = row.purpose === 'switch-sync';
    const ticked = syncRow ? network().dropSwitchSync !== true : keptList().indexOf(row.purpose) !== -1;
    const keepCell = showKeep && !lanRow
      ? `<label class="iu-keep"><input type="checkbox" data-iu-keep="${esc(row.purpose)}"${ticked ? ' checked' : ''}${can ? '' : ' disabled'}> ${esc(tr('iu.keep'))}</label>`
      : (showKeep ? '<span></span>' : '');
    return `<div class="iu-row${lanRow ? ' iu-lan' : ''}${stale ? ' iu-stale' : ''}${showKeep ? '' : ' no-keep'}" data-iu-row="${esc(row.purpose)}">
      <div class="iu-what"><div class="iu-name">${esc(tr('iu.p.' + row.purpose))}</div>
        <div class="iu-desc">${esc(tr('iu.d.' + row.purpose) + (lanRow ? '' : blockedLine(row)))}</div>
        ${cons ? `<div class="iu-cons${row.purpose === 'updates' ? ' iu-red' : ''}">${esc(cons)}</div>` : ''}</div>
      <div class="iu-when">${esc(tr(syncRow ? 'iu.every_15m' : (row.automatic ? 'iu.automatic' : 'iu.when_asked')))}</div>
      <div class="iu-state"><span class="iu-dot ${st.tone}"></span>${esc(tr(st.key))}</div>
      ${keepCell}
    </div>`;
  }).join('');
  host.innerHTML = head + `<div class="card iu-rows">${body}</div>`;
  wire(host);
}

function refuseSay(error) {
  if (error === 'not_permitted') toast('⚠ ' + tr('err.refused', { what: tr('err.refused_network') }), 'error', 9000);
  else if (error) toast('⚠ ' + String(error), 'error', 6000);
}

/** Save the shop's switch through the window's ordinary save; main's guard decides. */
async function saveNetwork(patch) {
  const cur = shopView();
  const next = Object.assign({}, network(), { offline: !!cur.offline, keep: keptList() }, patch);
  // When and by whom are the SWITCH's: a Keep tick changes neither (review of
  // #2633: it re-dated "Turned on by" and reset the 30-day clock).
  const flipped = !!next.offline !== !!cur.offline;
  if (flipped) { next.changedAt = new Date().toISOString(); next.changedBy = whoChanges(); }
  else { next.changedAt = cur.changedAt || null; next.changedBy = cur.changedBy || null; }
  // Through Khayt Cloud (lib/main/network-switch-sync.js): turning it ON
  // tells the cloud FIRST, while this computer is still online (the last
  // call); only a value the cloud took makes this `via: 'cloud'`, which keeps
  // the 15-minute check while offline. Main decides whether to send at all
  // (the owner, this computer's option); it answers at once when it does not.
  if (flipped && next.offline) {
    let pub = null;
    try { pub = global.hubAPI && global.hubAPI.networkSwitchPublish ? await global.hubAPI.networkSwitchPublish({ offline: true, network: next, changedBy: next.changedBy }) : null; } catch (_) { pub = null; }
    next.via = pub && pub.ok && pub.via === 'cloud' ? 'cloud' : null;
  }
  settings.network = next;
  if (typeof saveAll === 'function') saveAll();
  if (typeof flushSave === 'function') { try { await flushSave(); } catch (_) { /* the refusal toast says it */ } }
  // Turning it OFF tells the cloud AFTER, as the first call back: main asks
  // first and sends offline:false if a value is published there, whatever
  // this computer's own option (contract rule 1).
  if (flipped && !next.offline && global.hubAPI && global.hubAPI.networkSwitchPublish) {
    try { await global.hubAPI.networkSwitchPublish({ offline: false, network: next, changedBy: next.changedBy }); } catch (_) { /* main keeps the outcome */ }
  }
  // What main kept is what the window holds: a save that failed or was put
  // back must not wait in memory for the next save to carry it.
  const ctx = await load();
  if (ctx && ctx.shop) {
    const kept = ctx.shop;
    const same = !!kept.offline === !!next.offline && JSON.stringify((kept.keep || []).slice().sort()) === JSON.stringify((next.keep || []).slice().sort());
    if (!same) settings.network = Object.assign({}, network(), { offline: !!kept.offline, keep: kept.keep || [], changedAt: kept.changedAt, changedBy: kept.changedBy });
  }
}

function wire(host) {
  const shop = host.querySelector('#iuShopSwitch');
  if (shop) shop.addEventListener('click', async () => {
    if (!mayChange()) return refuseSay('not_permitted');
    const turnOn = !shopOffline();
    await saveNetwork({ offline: turnOn, keep: keptList() });
    await refresh();
  });
  const here = host.querySelector('#iuHereSwitch');
  if (here) here.addEventListener('click', async () => {
    const turnOn = here.getAttribute('aria-checked') !== 'true';
    let r = null;
    try { r = await global.hubAPI.outboundSetLocal({ offline: turnOn }); } catch (e) { r = { ok: false, error: String((e && e.message) || e) }; }
    if (!r || !r.ok) refuseSay(r && r.error);
    await refresh();
  });
  host.querySelectorAll('[data-iu-keep]').forEach((box) => box.addEventListener('change', async () => {
    if (!mayChange()) { box.checked = !box.checked; return refuseSay('not_permitted'); }
    const p = box.getAttribute('data-iu-keep');
    if (p === 'switch-sync') { await saveNetwork({ dropSwitchSync: !box.checked }); await refresh(); return; }
    const keep = keptList().filter((k) => k !== p);
    if (box.checked) keep.push(p);
    await saveNetwork({ keep });
    await refresh();
  }));
}

/** The banner on every screen (frame C): updates blocked and not checked for 30+ days. */
function renderBanner(ctx) {
  const el = document.getElementById('updatesOffBanner');
  if (!el) return;
  const row = ctx && Array.isArray(ctx.rows) ? ctx.rows.find((r) => r.purpose === 'updates') : null;
  const days = updatesStale(row, ctx);
  if (!days) { el.style.display = 'none'; el.innerHTML = ''; return; }
  const why = row.reason === 'offline-here' ? tr('iu.banner_here') : tr('iu.banner_shop');
  el.innerHTML = `<div class="iu-banner-text">${esc(tr('iu.banner', { n: days }) + ' ' + why)}</div>
    <div class="iu-banner-btns">
      ${row.reason === 'offline' && mayChange() ? `<button type="button" class="btn primary small" data-iu-banner="keep">${esc(tr('iu.keep_updates'))}</button>` : ''}
      <button type="button" class="btn small" data-iu-banner="open">${esc(tr('iu.open'))}</button>
    </div>`;
  el.style.display = '';
  const k = el.querySelector('[data-iu-banner="keep"]');
  if (k) k.addEventListener('click', async () => {
    if (!mayChange()) return refuseSay('not_permitted');
    const keep = keptList().filter((x) => x !== 'updates');
    keep.push('updates');
    await saveNetwork({ keep });
    await refresh();
  });
  el.querySelector('[data-iu-banner="open"]').addEventListener('click', open);
}

/** The one line on the General pane that leads here. */
function renderEntry() {
  const el = document.getElementById('internetUseEntryState');
  if (!el) return;
  el.textContent = tr(shopOffline() ? 'iu.entry_on' : 'iu.entry_off');
}

async function refresh() {
  const ctx = await load();
  render(ctx);
  renderBanner(ctx);
  renderEntry();
}
/** After a refusal: at most once a second, and the list only while it is on screen. */
let _soon = null;
function refreshSoon() {
  if (_soon) return;
  _soon = setTimeout(async () => {
    _soon = null;
    const panel = document.getElementById('settings-panel-internet');
    const ctx = await load();
    if (panel && panel.classList.contains('active')) render(ctx);
    renderBanner(ctx);
  }, 1000);
}

function open() {
  const go = typeof openSettingsSection === 'function' ? openSettingsSection : (global.KhaytShell && global.KhaytShell.openSettingsSection);
  if (go) go('internet');
  refresh();
}

// ── Refusals (frame D) ───────────────────────────────────────────────────

const PURPOSE_IN_SENTENCE = (p) => {
  const k = 'iu.in.' + p;
  const s = tr(k);
  return s && s !== k ? s : tr('iu.in.unrouted');   // the belt's 'unrouted', or anything new
};

/** The words for one refusal, or '' for a shape that is not one. */
function refusalText(blocked) {
  if (!blocked || typeof blocked !== 'object') return '';
  const reason = String(blocked.reason || 'offline');
  const purpose = String(blocked.purpose || '');
  // Only the switch's own refusals are said as the switch: a purpose's own
  // opt-out, or an unknown purpose, is not "Khayt is set to make no internet
  // calls" (review of #2633).
  if (['offline', 'offline-here', 'lan-host-public', 'lan-host-missing', 'settings-unknown'].indexOf(reason) === -1) return '';
  if (reason === 'settings-unknown') return tr('outbound.blocked.settings-unknown');
  if (reason === 'offline-here') return tr('outbound.blocked.offline-here', { purpose: PURPOSE_IN_SENTENCE(purpose) });
  if (reason === 'lan-host-public' || reason === 'lan-host-missing') {
    return blocked.host ? tr('outbound.blocked.lan-host-public', { host: String(blocked.host) }) : tr('outbound.blocked.lan-host-missing');
  }
  return tr('outbound.blocked.offline', { purpose: PURPOSE_IN_SENTENCE(purpose) });
}

/* Only these hubAPI calls are a person's (a button they pressed). Everything
 * else that a refusal comes back from (a cloud push after a save, the email
 * digest, printer alerts, auto-submitted invoices) is automatic: counted on its
 * row, never toasted (design §4.5; review of #2633: "a person acted in the
 * last 8 s" alone toasted the cloud push every save triggers). */
const PERSON_STARTED = new Set([
  'fetchExchangeRates', 'aiExtract', 'checkForUpdates', 'startUpdateDownload',
  'makerrunBrowse', 'makerrunDesign', 'makerrunDownloadToLib', 'makerrunPublishCreate', 'makerrunPublishFile',
  'makerrunPublishImages', 'makerrunFindRecent', 'makerrunDelete',
  'orcaFilaManifest', 'orcaFilaInstall', 'connectorUpdate',
  'offsiteRun', 'printLibS3Test', 'gdriveConnect', 'vaultShare',
  'cloudCreateKeyset', 'cloudSignup', 'cloudLogin', 'cloudAcceptInvite', 'cloudMemberInvite', 'cloudMemberRemove',
  'cloudSetSlug', 'cloudPayLink', 'cloudCatalogPublish', 'cloudDeleteReview', 'cloudRequestReset', 'cloudResetPassword',
  'cloudRequestVerify', 'cloudVerifyEmail', 'cloudPublish', 'cloudUnpublish', 'cloudIntakeTakeFile', 'cloudPortalReply',
  'cloudSetPlan', 'cloudUnlock', 'cloudSnapshotGet', 'cloudAcceptRollback',
  'startTunnel', 'zatcaCompliance', 'zatcaProductionCsid',
  'bnplTabby', 'bnplTamara', 'bnplStripe', 'bnplCapture', 'sendWhatsappTemplate', 'webhookPost',
]);
/** A person acted a moment ago: a refusal now answers them. Automatic calls are counted, not toasted. */
let _lastInput = 0;
const PERSON_MS = 8000;
['pointerdown', 'keydown'].forEach((ev) => { try { global.addEventListener(ev, () => { _lastInput = Date.now(); }, true); } catch (_) { /* no window */ } });
const _saidAt = Object.create(null);

function sayBlocked(blocked, method) {
  if (!blocked || Date.now() - _lastInput > PERSON_MS) return false;
  if (method !== undefined && !PERSON_STARTED.has(String(method))) return false;
  const key = `${blocked.purpose}|${blocked.reason}`;
  if (_saidAt[key] && Date.now() - _saidAt[key] < 3000) return true;   // one press, one message
  _saidAt[key] = Date.now();
  const text = refusalText(blocked);
  if (!text) return false;
  const act = blocked.reason === 'settings-unknown' ? undefined : { label: tr('iu.open'), run: open };
  toast(text, 'error', 9000, act ? { action: act } : {});
  return true;
}

// The preload reports every refused reply it sees (preload.js reportBlocked).
try {
  global.addEventListener('khayt:outbound-blocked', (e) => {
    let b = null;
    try { b = JSON.parse(String(e && e.detail)); } catch (_) { b = null; }
    if (b && typeof b.purpose === 'string') { sayBlocked(b, typeof b.method === 'string' ? b.method : ''); refreshSoon(); }
  });
} catch (_) { /* no window */ }

// The entry on General, the way back, and the banner kept current.
function boot() {
  const openBtn = document.getElementById('btnOpenInternetUse');
  if (openBtn) openBtn.addEventListener('click', open);
  const back = document.getElementById('btnInternetUseBack');
  if (back) back.addEventListener('click', () => {
    const go = typeof openSettingsSection === 'function' ? openSettingsSection : (global.KhaytShell && global.KhaytShell.openSettingsSection);
    if (go) go('general');
  });
  // The page, the entry line and the banner follow a language change.
  document.addEventListener('languagechange', () => { refresh().catch(() => {}); });
  // A switch main applied from Khayt Cloud: the window takes it, so its next
  // save does not carry the older one (main refuses that anyway).
  if (global.hubAPI && typeof global.hubAPI.onNetworkApplied === 'function') {
    global.hubAPI.onNetworkApplied((n) => {
      if (!n || typeof settings === 'undefined' || !settings) return;
      settings.network = Object.assign({}, n);
      refresh().catch(() => {});
    });
  }
  // Hourly, so the 30-day banner appears on a computer left running.
  setInterval(() => { refresh().catch(() => {}); }, 60 * 60 * 1000);
}
try {
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
} catch (_) { /* no document */ }

const api = { ORDER, STALE_DAYS, ownSwitchOff, refresh, render, renderBanner, open, refusalText, sayBlocked, stateOf, updatesStale, setUp };
global.KhaytInternetUse = api;
if (typeof module !== 'undefined' && module.exports) module.exports = api;

})(typeof window !== 'undefined' ? window : globalThis);
