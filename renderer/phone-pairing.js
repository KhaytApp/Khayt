'use strict';
/**
 * Settings ▸ Online ▸ LAN API: pairing a phone by a code, with a role, and
 * each paired phone's role. Built to the frames Turki signed off on Nov 22
 * (Figma 7Iqw0GcrLLRW7CLDEhTa1P, page 123:151: P1 waiting, P2/P3 a phone
 * asked, P4 how it ended, P5 the list, P6 who can pair; AR the same).
 *
 * Main decides everything (lib/lan-server.js hub:phone-pair-*, lib/main/
 * phone-pairing.js): who may open the window and give which role is main's
 * own reading of who is signed in, never this window's. This file only draws
 * main's snapshot and sends the person's answer, with the exact pairId and
 * check number they were shown.
 */
(function (global) {

const ROLES = ['viewer', 'operator', 'manager', 'owner'];
const tr = (k, v) => (typeof t === 'function' ? t(k, v) : k);
const esc = (s) => (typeof escapeHtml === 'function' ? escapeHtml(String(s == null ? '' : s)) : String(s == null ? '' : s));
const api = () => global.hubAPI || {};
const mmss = (ms) => { const s = Math.max(0, Math.ceil((Number(ms) || 0) / 1000)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
const roleName = (r) => tr('pp.role.' + r);
/** "418207" → "418 207", the way both screens show it. */
const spaced = (c) => { const s = String(c || ''); return s.length === 6 ? `${s.slice(0, 3)} ${s.slice(3)}` : s; };

/** Nobody signed in under the staff lock (the lock signs everyone out at start, #2608). */
function nobodySignedIn() {
  // `settings` is the window's top-level binding (app-state.js), not a window property.
  const s = (typeof settings !== 'undefined' && settings) || {};
  return !!s.operatorLockEnabled && !s.activeOperatorId;
}

// ── The list (frame P5; P6 for a manager and for nobody signed in) ──────────

/** The paired phones, each with its role; the owner may change a code-paired phone's role. */
function listHtml(devices, ctx) {
  const day = ctx.day || ((iso) => String(iso || '').slice(0, 10));
  const owner = ctx.approverRole === 'owner';
  return devices.map((d) => {
    const code = d.codePaired === true;
    const role = code ? (ROLES.includes(d.role) ? d.role : 'viewer') : 'owner';
    const how = tr(code ? 'pp.code_paired' : 'pp.pin_paired', { date: day(d.lastSeenAt) });
    const roleCell = code && owner
      ? `<label class="pp-role"><span class="sr-only">${esc(tr('pp.role_label'))}</span><select data-pp-role="${esc(d.deviceId)}" aria-label="${esc(tr('pp.role_label'))}">${ROLES.map((r) => `<option value="${r}"${r === role ? ' selected' : ''}>${esc(roleName(r))}</option>`).join('')}</select></label>`
      : `<span class="pp-role-text">${esc(roleName(role))}</span>`;
    return `<div class="pp-row" data-pp-device="${esc(d.deviceId)}">
      <div class="pp-who"><div class="pp-name">${esc(d.name || tr('lan.phones_unnamed'))}</div><div class="pp-how">${esc(how)}</div></div>
      ${roleCell}
      ${ctx.canSignOut ? `<button type="button" class="btn ghost small" data-sign-out="${esc(d.deviceId)}" data-name="${esc(d.name || '')}">${esc(tr('lan.phones_sign_out'))}…</button>` : ''}
    </div>`;
  }).join('');
}

/** Under the list: the notes, and Pair a phone, the ask-the-owner line, or Sign in. */
function footHtml(state, ctx) {
  const out = [];
  if (ctx.hasCodePhones || state.enabled) {
    out.push(`<div class="pp-note">${esc(tr(ctx.approverRole === 'owner' ? 'pp.role_note' : 'pp.manager_note'))}</div>`);
    out.push(`<div class="pp-note">${esc(tr('pp.pin_change_note'))}</div>`);
  }
  if (!state.enabled) return out.join('');
  if (Array.isArray(state.grantable) && state.grantable.length) {
    out.push(`<div class="pp-actions"><button type="button" class="btn primary" data-pp-open>${esc(tr('pp.pair_btn'))}</button></div>`);
  } else if (nobodySignedIn()) {
    out.push(`<div class="pp-ask">${esc(tr('pp.sign_in_needed'))}<button type="button" class="btn primary small" data-pp-signin>${esc(tr('pp.sign_in'))}</button></div>`);
  } else {
    out.push(`<div class="pp-ask">${esc(tr('pp.ask_owner'))}</div>`);
  }
  return out.join('');
}

async function renderList(box, foot, devices, ctx) {
  let state = null;
  try { state = api().phonePairState ? await api().phonePairState() : null; } catch (_) { state = null; }
  const st = state && state.ok ? state : { enabled: false, grantable: [] };
  // Main's reading of who is at this computer: the owner is the one who may give Owner.
  const approverRole = (st.grantable || []).includes('owner') ? 'owner' : ((st.grantable || []).length ? 'manager' : null);
  const c = Object.assign({}, ctx, { approverRole, hasCodePhones: devices.some((d) => d.codePaired === true) });
  if (box) box.innerHTML = devices.length ? listHtml(devices, c) : `<div style="color:var(--text-muted);">${esc(tr('lan.phones_none'))}</div>`;
  if (foot) foot.innerHTML = footHtml(st, c);
  if (box) box.querySelectorAll('[data-pp-role]').forEach((sel) => sel.addEventListener('change', async () => {
    let r = null;
    try { r = await api().setLanDeviceRole({ deviceId: sel.getAttribute('data-pp-role'), role: sel.value }); } catch (_) { r = null; }
    if (!r || !r.ok) { if (typeof toast === 'function') toast(tr('pp.role_failed'), 'error'); }
    if (typeof ctx.refresh === 'function') ctx.refresh();
  }));
  if (foot) {
    const open = foot.querySelector('[data-pp-open]');
    if (open) open.addEventListener('click', () => openDialog(ctx.refresh));
    const sin = foot.querySelector('[data-pp-signin]');
    if (sin) sin.addEventListener('click', () => { if (typeof openPinPadModal === 'function') openPinPadModal(() => { if (typeof ctx.refresh === 'function') ctx.refresh(); }); });
  }
}

// ── The dialog (frames P1–P4) ───────────────────────────────────────────────
//
// One sheet, two kinds (Figma page 131, "Pair a slicer…"): `opts.kind ===
// 'connector'` pairs a slicer plugin through hub:connector-pair-*, the same
// window and the same 6-digit number, without the role choice (a slicer has
// one fixed scope, said in words instead).

/** The five calls, for a phone or for a slicer. */
function pairApi(slicer) {
  const a = api();
  return slicer
    ? { state: () => a.connectorPairState(), open: () => a.connectorPairOpen(), close: () => a.connectorPairClose(),
      approve: (x) => a.connectorPairApprove({ pairId: x.pairId, check: x.check }), deny: () => a.connectorPairDeny() }
    : { state: () => a.phonePairState(), open: () => a.phonePairOpen(), close: () => a.phonePairClose(),
      approve: (x) => a.phonePairApprove(x), deny: () => a.phonePairDeny() };
}

let _timer = null;
function openDialog(onClose, opts) {
  const slicer = !!(opts && opts.kind === 'connector');
  const P = pairApi(slicer);
  const unnamed = () => tr(slicer ? 'ca.unnamed' : 'lan.phones_unnamed');
  const overlayId = slicer ? 'connectorPairOverlay' : 'phonePairOverlay';
  let overlay = document.getElementById(overlayId);
  if (overlay) overlay.remove();
  overlay = document.createElement('div');
  overlay.id = overlayId;
  overlay.className = 'modal-backdrop confirm-modal-overlay';
  overlay.style.zIndex = '10040';
  (document.getElementById('modalMount') || document.body).appendChild(overlay);
  const memo = { chosen: null, asked: null, lastPending: null, end: null, address: '' };

  const close = async (stopWindow) => {
    if (_timer) { clearInterval(_timer); _timer = null; }
    if (stopWindow) { try { await P.close(); } catch (_) { /* main closes it on its own clock */ } }
    overlay.remove();
    if (typeof onClose === 'function') onClose();
  };

  const draw = (st) => {
    const head = `<div class="modal-header"><h3 id="ppTitle">${esc(tr(slicer ? 'ca.pair_title' : 'pp.title'))}</h3></div>`;
    let body = '', foot = '';
    const p = st && st.pending && st.pending.revealed ? st.pending : null;
    if (memo.end) {
      // P4: how it ended, in words.
      body = `<div class="pp-end">${esc(memo.end)}</div>`;
      foot = `<button type="button" class="btn primary" data-pp-act="done">${esc(tr('pp.done'))}</button>`;
    } else if (p && slicer) {
      // P2 for a slicer: the same number on both screens, and what it may do (no role).
      memo.asked = { pairId: p.pairId, check: p.check, name: p.name };
      body = `<div class="pp-asks">${esc(tr('pp.asks', { name: p.name || unnamed() }))}</div>
        <div class="pp-sub">${esc([p.app && p.version ? `${p.app} ${p.version}` : (p.app || ''), p.address || ''].filter(Boolean).join(' · '))}</div>
        <div class="pp-check" dir="ltr">${esc(spaced(p.check))}</div>
        <div class="pp-sub pp-center">${esc(tr('ca.pair_check_same'))}</div>
        <div class="pp-may">${esc(tr('ca.pair_may'))}</div>
        <div class="pp-sub">${esc(tr('ca.pair_scope'))}</div>
        <div class="pp-sub">${esc(tr('ca.pair_deny_note'))}</div>`;
      foot = `<span class="pp-left">${esc(tr('pp.left', { time: mmss(st.remainingMs) }))}</span><span style="flex:1"></span>
        <button type="button" class="btn" data-pp-act="deny">${esc(tr('pp.deny'))}</button>
        <button type="button" class="btn primary" data-pp-act="approve">${esc(tr('pp.approve'))}</button>`;
    } else if (p) {
      // P2/P3: the same number on both screens, and a role.
      const grantable = (st.grantable || []).filter((r) => ROLES.includes(r));
      if (!memo.chosen || !grantable.includes(memo.chosen)) memo.chosen = st.defaultRole && grantable.includes(st.defaultRole) ? st.defaultRole : grantable[grantable.length - 1];
      memo.asked = { pairId: p.pairId, check: p.check, name: p.name };
      body = `<div class="pp-asks">${esc(tr('pp.asks', { name: p.name || tr('lan.phones_unnamed') }))}</div>
        <div class="pp-sub">${esc([p.app && p.version ? `${p.app} ${p.version}` : (p.app || ''), p.address || ''].filter(Boolean).join(' · '))}</div>
        <div class="pp-check" dir="ltr">${esc(spaced(p.check))}</div>
        <div class="pp-sub pp-center">${esc(tr('pp.check_same'))}</div>
        <div class="pp-may">${esc(tr('pp.may'))}</div>
        <div class="pp-roles" role="radiogroup">${ROLES.filter((r) => grantable.includes(r)).map((r) => `
          <label class="pp-role-opt${r === memo.chosen ? ' on' : ''}"><input type="radio" name="ppRole" value="${r}"${r === memo.chosen ? ' checked' : ''}>
            <span><b>${esc(roleName(r))}</b><small>${esc(tr('pp.role_desc.' + r))}</small></span></label>`).join('')}</div>
        ${grantable.includes('owner') ? '' : `<div class="pp-sub">${esc(tr('pp.only_owner_owner'))}</div>`}
        <div class="pp-sub">${esc(tr('pp.deny_note'))}</div>`;
      foot = `<span class="pp-left">${esc(tr('pp.left', { time: mmss(st.remainingMs) }))}</span><span style="flex:1"></span>
        <button type="button" class="btn" data-pp-act="deny">${esc(tr('pp.deny'))}</button>
        <button type="button" class="btn primary" data-pp-act="approve">${esc(tr('pp.approve'))}</button>`;
    } else {
      // P1: waiting.
      body = `<div class="pp-wait"><b>${esc(tr(slicer ? 'ca.pair_waiting' : 'pp.waiting'))}</b><span class="pp-left">${esc(tr('pp.left', { time: mmss(st && st.remainingMs) }))}</span></div>
        <div class="pp-sub">${esc(tr(slicer ? 'ca.pair_instructions' : 'pp.instructions'))}</div>
        <div class="field"><label>${esc(tr('pp.address_label'))}</label>
          <div class="pp-addr"><input type="text" readonly dir="ltr" value="${esc(memo.address)}"><button type="button" class="btn" data-pp-act="copy">${esc(tr('pp.copy'))}</button></div></div>
        <div class="pp-sub">${esc(tr(slicer ? 'ca.pair_note' : 'pp.older_note'))}</div>`;
      foot = `<span style="flex:1"></span><button type="button" class="btn" data-pp-act="stop">${esc(tr('pp.stop'))}</button>`;
    }
    overlay.innerHTML = `<div class="modal modal-form pp-dialog" role="dialog" aria-modal="true" aria-labelledby="ppTitle" style="max-width:560px;">${head}<div class="modal-body">${body}</div><div class="modal-footer">${foot}</div></div>`;
    overlay.querySelectorAll('input[name="ppRole"]').forEach((r) => r.addEventListener('change', () => { memo.chosen = r.value; draw(st); }));
    overlay.querySelectorAll('[data-pp-act]').forEach((b) => b.addEventListener('click', () => act(b.getAttribute('data-pp-act'))));
  };

  /** What ended the window, from main's snapshot and what this window did. */
  const ended = (st) => {
    const why = st && st.lastClosed;
    if (why === 'paired') return null;   // said by the approve answer itself
    if (why === 'timedOut') return tr('pp.timed_out');
    if (why === 'offersUsed') return tr(slicer ? 'ca.pair_offers_used' : 'pp.offers_used');
    if (why === 'pinUnreadable') return tr('pp.pin_unreadable');
    if (why === 'serverStopped') return tr(slicer ? 'ca.pair_server_stopped' : 'pp.server_stopped');
    return null;
  };

  const act = async (what) => {
    if (what === 'copy') { try { await navigator.clipboard.writeText(memo.address); if (typeof toast === 'function') toast(tr('pp.copied'), 'success'); } catch (_) { /* nothing to copy */ } return; }
    if (what === 'stop' || what === 'done') return close(what === 'stop');
    if (what === 'deny') {
      memo.denied = memo.asked && memo.asked.name;
      try { await P.deny(); } catch (_) { /* main's state decides */ }
      return tick();
    }
    if (what === 'approve' && memo.asked) {
      let r = null;
      try { r = await P.approve({ role: memo.chosen, pairId: memo.asked.pairId, check: memo.asked.check }); } catch (_) { r = null; }
      if (r && r.ok && r.paired) {
        memo.end = slicer ? tr('ca.paired', { name: memo.asked.name || unnamed() })
          : tr('pp.paired', { name: memo.asked.name || tr('lan.phones_unnamed'), role: roleName(memo.chosen) });
      }
      else if (r && r.error === 'pin') memo.end = tr('pp.pin_unreadable');
      return tick();
    }
  };

  const tick = async () => {
    let st = null;
    try { st = await P.state(); } catch (_) { st = null; }
    if (!memo.end && st && !st.open) memo.end = ended(st) || memo.end;
    // A request that went away while the window stays open: denied here, or the phone gave up.
    const p = st && st.pending && st.pending.revealed ? st.pending : null;
    if (memo.lastPending && !p && st && st.open && !memo.end) {
      const name = memo.lastPending.name || unnamed();
      if (typeof toast === 'function') toast(memo.denied ? tr('pp.denied', { name }) : tr(slicer ? 'ca.pair_stopped_asking' : 'pp.stopped_asking', { name }), 'info', 6000);
      memo.denied = null;
    }
    memo.lastPending = p;
    if (memo.end && _timer) { clearInterval(_timer); _timer = null; }
    draw(st || { open: false });
  };

  (async () => {
    try { const u = await api().getLanUrl(); memo.address = u && u.ok ? String(u.url || '').replace(/^https?:\/\//, '') : ''; } catch (_) { memo.address = ''; }
    let opened = null;
    try { opened = await P.open(); } catch (_) { opened = null; }
    if (!opened || opened.ok === false) {
      const e = opened && opened.error;
      const stopped = tr(slicer ? 'ca.pair_server_stopped' : 'pp.server_stopped');
      memo.end = e === 'server_stopped' ? stopped : e === 'pin' ? tr('pp.pin_needed') : e === 'not_permitted' ? tr(slicer ? 'ca.pair_ask_owner' : 'pp.ask_owner') : stopped;
      draw({});
      return;
    }
    draw(opened);
    _timer = setInterval(tick, 1000);
  })();
}

const exported = { renderList, openDialog, listHtml, footHtml, spaced, ROLES };
global.KhaytPhonePairing = exported;
if (typeof module !== 'undefined' && module.exports) module.exports = exported;

})(typeof window !== 'undefined' ? window : globalThis);
