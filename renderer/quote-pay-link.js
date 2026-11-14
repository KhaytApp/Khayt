/**
 * Quote pay link on the desktop: the job's one line, the Send sheet, and the
 * Settings card (Online Store › Pay links for approved quotes).
 *
 * What may be sent, what each line charges and what is signed are the shared
 * rule (lib/quote-pay-link.js), the same file the Mac runs. This window never
 * holds the shop's secret: it sees the mask, hands a typed secret to main once
 * (`hubAPI.quotePayLinkSetSecret`), and asks main to sign
 * (`hubAPI.quotePayLinkSign`) — main reads the job from the book on disk, so
 * the window flushes its save first.
 *
 * What the job remembers is `order.payLink`, the shared `recordOf(claims,
 * { locale, sentAt })` main hands back. A payment on the store arrives as
 * `order.payLink.paid` (`paidRecord`, written by the store import); where the
 * line stands is the shared `stateOf`, and this file only draws it.
 *
 * Figma: file 7Iqw0GcrLLRW7CLDEhTa1P, page "Pay link (desktop)".
 */
(function (global) {
  'use strict';

  const PL = () => global.KhaytQuotePayLink;
  const DAY = 86400;

  const q = () => (settings && settings.quotePayLink) || {};
  const hasSecret = () => { const s = q().secret; return typeof s === 'string' && s.length > 0; };
  const config = () => ({ storeUrl: q().storeUrl || '', hasSecret: hasSecret() });
  const clientOf = (order) => (order && order.clientId && Array.isArray(clients) ? clients.find((c) => c && c.id === order.clientId) : null);

  /** A word in the customer's language, not the shop's. */
  function tIn(lang, key, vars) {
    const table = (global.KhaytLocales && global.KhaytLocales[lang]) || null;
    let s = table && typeof table[key] === 'string' ? table[key] : null;
    if (s === null) return t(key, vars);
    if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
    return s;
  }

  /** The link speaks Arabic or English (lib urlFor); the customer's, else Arabic. */
  function customerLocale(order) {
    const WM = global.KhaytWhatsappMessage;
    const lang = WM && typeof WM.customerLanguage === 'function'
      ? WM.customerLanguage(clientOf(order) || {}, settings && settings.lang) : 'ar';
    return lang === 'en' ? 'en' : 'ar';
  }

  const words = (lang) => ({ rush: tIn(lang, 'qpl.word_rush'), extra: tIn(lang, 'qpl.word_extra') });
  const money = (halalas) => (Math.round(halalas) / 100).toFixed(2);
  const riyals = (amount) => (Math.round((+amount || 0) * 100) / 100).toFixed(2);
  const shortDate = (ms) => new Date(ms).toLocaleDateString(localeTag(), { day: 'numeric', month: 'short' });
  const approvedAt = (o) => o.quoteAcceptedAt || o.clientApprovedAt || '';

  /**
   * Where the job's link stands: the shared rule's `stateOf` (ready, sent,
   * expired, paid, mismatch or null, and `outdated` when a link is out but
   * the quote has changed since). `configured: false` takes away READY only,
   * so a shop that never uses pay links sees no line on its approved quotes,
   * while a link sent from another computer is still told.
   */
  function lineState(order, nowMs) {
    if (!order || !PL()) return { state: null, outdated: false };
    return PL().stateOf(order, Math.floor(nowMs / 1000), { configured: PL().configured(config()) });
  }

  function lineHtml(order) {
    const now = Date.now();
    const { state, outdated } = lineState(order, now);
    if (!state) return '';
    const rec = order.payLink || {};
    const id = escapeHtml(String(order.id));  // an attribute, never shown
    let text = '';
    let btn = '';
    const primary = (act, label) => `<button type="button" class="btn primary qpl-btn" data-act="${act}" data-id="${id}">${escapeHtml(label)}</button>`;
    const secondary = (act, label) => `<button type="button" class="btn qpl-btn" data-act="${act}" data-id="${id}">${escapeHtml(label)}</button>`;
    if (state === 'ready') {
      text = t('qpl.line_ready');
      btn = primary('qpl-send', t('qpl.send'));
    } else if (state === 'sent') {
      const days = Math.max(1, Math.ceil((rec.expiresAt - now / 1000) / DAY));
      text = t(days === 1 ? 'qpl.line_sent_one' : 'qpl.line_sent', { date: shortDate(rec.issuedAt * 1000), days });
      btn = (outdated ? primary : secondary)('qpl-send', t('qpl.send_again'));
    } else if (state === 'expired') {
      text = t('qpl.line_expired', { date: shortDate(rec.expiresAt * 1000) });
      btn = outdated ? primary('qpl-send', t('qpl.send_again')) : secondary('qpl-send', t('qpl.send_new'));
    } else if (state === 'paid') {
      const p = rec.paid;
      text = t('qpl.line_paid', { order: String(p.storeOrder || ''), amount: riyals(p.amount) + ' ' + t('qpl.sar'), delivery: riyals(p.delivery) });
      btn = /^https:\/\//.test(String(p.url || '')) ? secondary('qpl-open-order', t('qpl.open_order')) : '';
    } else {
      text = t('qpl.line_mismatch', { paid: riyals(rec.paid.amount), quoted: money(PL().sums(order).total) });
      btn = primary('qpl-settle', t('qpl.settle'));
    }
    const note = outdated
      ? `<div class="qpl-line-outdated">${escapeHtml(t('qpl.line_outdated', { sent: riyals(rec.amount), now: money(PL().sums(order).total) }))}</div>`
      : '';
    return `<div class="qpl-line" data-state="${state}"${outdated ? ' data-outdated="true"' : ''} data-id="${id}">
      <div class="qpl-line-words">
        <div class="qpl-line-label"><span class="qpl-dot" aria-hidden="true"></span>${escapeHtml(t('qpl.state_' + state))}</div>
        <div class="qpl-line-text">${escapeHtml(text)}</div>${note}
      </div>
      ${btn}
    </div>`;
  }

  /** Redraw every line on screen for this job (the editor, a list row). */
  function refreshLines(orderId) {
    const order = printLog.find((o) => o.id === orderId);
    document.querySelectorAll('.qpl-line-host').forEach((host) => {
      if (host.dataset.id !== orderId) return;
      host.innerHTML = order ? lineHtml(order) : '';
    });
  }

  /* ── Why a link cannot be sent ─────────────────────────────────────── */

  function reasonText(code, order) {
    if (code === 'no_weight') {
      const part = (order.parts || []).find((p) => !(Math.round(+p.printWeight || 0) >= 1));
      return { title: t('qpl.why_no_weight'), body: t('qpl.why_no_weight_body', { name: (part && part.name) || order.project || '—' }) };
    }
    const known = ['not_set_up', 'not_a_quote', 'closed', 'paid', 'milestones', 'currency', 'tax', 'reference', 'no_parts', 'negative', 'too_many', 'amount'];
    const k = known.includes(code) ? code : 'amount';
    return { title: t('qpl.why_' + k), body: t('qpl.why_' + k + '_body') };
  }

  /* ── The Send sheet ─────────────────────────────────────────────────── */

  let openSheet = null;

  function closeSheet() {
    if (!openSheet) return;
    const s = openSheet;
    openSheet = null;
    document.removeEventListener('keydown', s.esc);
    const i = _escHandlerStack.indexOf(s.esc);
    if (i !== -1) _escHandlerStack.splice(i, 1);
    s.overlay.remove();
  }

  function headerHtml(order) {
    const cl = clientOf(order);
    const name = cl ? localName(cl) : (order.client || '');
    const at = approvedAt(order);
    const bits = [PL().refOf(order), name, at ? t('qpl.approved_on', { date: shortDate(Date.parse(at)) }) : ''].filter(Boolean);
    return `<div class="qpl-sheet-head">
      <div><h3 id="qplTitle">${escapeHtml(t('qpl.send'))}</h3>
      <div class="qpl-sub">${escapeHtml(bits.join(' · '))}</div></div>
      <button type="button" class="btn ghost small qpl-x" data-qpl="close" aria-label="${escapeHtml(t('common.close'))}" title="${escapeHtml(t('common.close'))}">×</button>
    </div>`;
  }

  function blockedHtml(order, code) {
    const r = reasonText(code, order);
    const action = code === 'not_set_up'
      ? `<button type="button" class="btn primary" data-qpl="settings">${escapeHtml(t('qpl.open_settings'))}</button>`
      : `<button type="button" class="btn primary" data-qpl="open-job">${escapeHtml(t('qpl.open_job'))}</button>`;
    return `${headerHtml(order)}
      <div class="qpl-note qpl-why" data-reason="${escapeHtml(code)}">
        <div class="qpl-note-title">${escapeHtml(r.title)}</div>
        <div class="qpl-note-body">${escapeHtml(r.body)}</div>
      </div>
      <hr class="qpl-rule">
      <div class="qpl-actions">
        <button type="button" class="btn" data-qpl="close">${escapeHtml(t('common.close'))}</button>
        ${action}
      </div>`;
  }

  function readyHtml(order, lang) {
    const P = PL();
    const { items } = P.linesFor(order, words(lang));
    const total = P.totalOf(items);
    const grams = items.reduce((g, it) => g + it.weight_grams * it.quantity, 0);
    const delivery = P.deliveryOnQuote(order);
    const until = shortDate(Date.now() + P.LIFETIME_S * 1000);
    const rows = items.map((it) => {
      const sub = [it.spec || '',
        it.quantity > 1 ? `${it.quantity} × ${money(it.unit_amount)}` : '',
        it.weight_grams > 0 ? t(it.quantity > 1 ? 'qpl.grams_each' : 'qpl.grams', { g: it.weight_grams }) : ''].filter(Boolean).join(' · ');
      return `<li class="qpl-item"><div class="qpl-item-what"><div class="qpl-item-title">${escapeHtml(it.title)}</div>${sub ? `<div class="qpl-item-sub">${escapeHtml(sub)}</div>` : ''}</div>
        <div class="qpl-num">${escapeHtml(money(it.unit_amount * it.quantity))}</div></li>`;
    }).join('');
    const seg = ['ar', 'en'].map((l) => `<label class="qpl-seg-opt"><input type="radio" name="qplLang" value="${l}"${l === lang ? ' checked' : ''}><span${l === 'ar' ? ' lang="ar" dir="rtl"' : ' lang="en"'}>${l === 'ar' ? 'العربية' : 'English'}</span></label>`).join('');
    return `${headerHtml(order)}
      <ul class="qpl-items">${rows}</ul>
      <div class="qpl-total"><span>${escapeHtml(t('qpl.customer_pays'))}</span><strong class="qpl-num" data-qpl-total>${escapeHtml(money(total))} ${escapeHtml(t('qpl.sar'))}</strong></div>
      <div class="qpl-note">
        <div class="qpl-note-title">${escapeHtml(t('qpl.delivery_title'))}</div>
        <div class="qpl-note-body">${escapeHtml(delivery > 0
          ? t('qpl.delivery_body', { amount: riyals(delivery) + ' ' + t('qpl.sar'), g: grams })
          : t('qpl.delivery_body_none', { g: grams }))}</div>
      </div>
      <fieldset class="qpl-reads"><legend>${escapeHtml(t('qpl.customer_reads'))}</legend><div class="qpl-seg">${seg}</div></fieldset>
      <p class="qpl-valid">${escapeHtml(t('qpl.valid_until', { date: until }))}</p>
      <p class="qpl-status" role="status"></p>
      <hr class="qpl-rule">
      <div class="qpl-actions">
        <button type="button" class="btn" data-qpl="close">${escapeHtml(t('common.cancel'))}</button>
        <button type="button" class="btn" data-qpl="copy">${escapeHtml(t('qpl.copy_link'))}</button>
        <button type="button" class="btn primary" data-qpl="whatsapp">${escapeHtml(t('qpl.send_whatsapp'))}</button>
      </div>`;
  }

  function openSendSheet(orderId) {
    const order = printLog.find((o) => o.id === orderId);
    if (!order || !PL()) return;
    closeSheet();
    const P = PL();
    const blockers = P.blockers(order, { settings, clients, config: config() });
    let lang = customerLocale(order);
    const signed = {};  // locale → url, for this opening of the sheet
    const overlay = appendStackedModal(`<div class="modal qpl-sheet" role="dialog" aria-modal="true" aria-labelledby="qplTitle" data-id="${escapeHtml(order.id)}"></div>`);
    const sheet = overlay.querySelector('.qpl-sheet');
    const draw = (code) => {
      sheet.innerHTML = code ? blockedHtml(order, code) : readyHtml(order, lang);
      const first = sheet.querySelector('.qpl-actions .btn.primary') || sheet.querySelector('button');
      if (first) first.focus();
    };
    draw(blockers[0]);
    const esc = (e) => {
      if (e.key !== 'Escape' || _escHandlerStack[_escHandlerStack.length - 1] !== esc) return;
      closeSheet();
    };
    _escHandlerStack.push(esc);
    document.addEventListener('keydown', esc);
    openSheet = { overlay, esc };
    overlay.addEventListener('click', (e) => { if (e.target === overlay) closeSheet(); });

    const say = (msg) => { const st = sheet.querySelector('.qpl-status'); if (st) st.textContent = msg; };
    const sign = async () => {
      if (signed[lang]) return signed[lang];
      if (typeof flushSave === 'function') await flushSave();
      const res = await global.hubAPI?.quotePayLinkSign?.({ orderId: order.id, locale: lang, words: words(lang) });
      if (!res || !res.ok) {
        if (res && Array.isArray(res.blockers) && res.blockers.length) draw(res.blockers[0]);
        else toast(t('qpl.sign_failed'), 'error');
        return '';
      }
      order.payLink = res.record;
      saveAll();
      signed[lang] = res.url;
      refreshLines(order.id);
      if (typeof renderLogs === 'function') renderLogs();
      return res.url;
    };

    sheet.addEventListener('change', (e) => {
      if (e.target && e.target.name === 'qplLang') { lang = e.target.value === 'en' ? 'en' : 'ar'; draw(''); }
    });
    sheet.addEventListener('click', async (e) => {
      const b = e.target.closest('[data-qpl]');
      if (!b) return;
      const act = b.dataset.qpl;
      if (act === 'close') { closeSheet(); return; }
      if (act === 'open-job') { closeSheet(); openOrderEditor(order.id); return; }
      if (act === 'settings') { closeSheet(); openSettingsSection('store'); return; }
      if (act === 'copy') {
        const url = await sign();
        if (!url) return;
        if (await copyText(url)) { say(t('qpl.copied')); toast(t('common.copied'), 'success'); }
        else say(t('qpl.copy_failed'));
        return;
      }
      if (act === 'whatsapp') {
        const url = await sign();
        if (!url) return;
        const cl = clientOf(order);
        const message = tIn(lang, 'qpl.wa_message', { ref: P.refOf(order), url });
        if (global.hubAPI?.shareWhatsApp) await global.hubAPI.shareWhatsApp({ phone: (cl && cl.phone) || '', message, pdfPath: null });
        else global.open(`https://wa.me/?text=${encodeURIComponent(message)}`, '_blank');
        closeSheet();
      }
    });
  }

  /* ── Settings › Online Store › Pay links for approved quotes ────────── */

  function settingsHtml() {
    const c = q();
    const at = c.secretSetAt ? shortDate(Date.parse(c.secretSetAt)) : '';
    const stored = hasSecret()
      ? `<div class="qpl-secret-row">
          <div class="qpl-secret-dots" id="qpl_secretState"><span aria-hidden="true">••••••••</span> ${escapeHtml(at ? t('qpl.secret_saved_on', { date: at }) : t('qpl.secret_saved'))}</div>
          <button type="button" class="btn" data-qpl-set="replace">${escapeHtml(t('qpl.replace'))}</button>
          <button type="button" class="btn ghost qpl-remove" data-qpl-set="remove">${escapeHtml(t('qpl.remove'))}</button>
        </div>`
      : `<div class="qpl-secret-row">
          <div class="qpl-secret-dots is-empty" id="qpl_secretState">${escapeHtml(t('qpl.secret_none'))}</div>
          <button type="button" class="btn" data-qpl-set="replace">${escapeHtml(t('qpl.set_secret'))}</button>
        </div>`;
    return `<div class="settings-section-head">${escapeHtml(t('qpl.settings_title'))}</div>
      <p class="settings-panel-hint" id="qpl_intro">${escapeHtml(t('qpl.settings_intro'))}</p>
      <label for="qpl_storeUrl">${escapeHtml(t('qpl.store_address'))}</label>
      <input type="url" id="qpl_storeUrl" inputmode="url" autocomplete="off" spellcheck="false" placeholder="https://" value="${escapeHtml(c.storeUrl || '')}">
      <div class="qpl-v2" id="qpl_v2" hidden></div>
      <div class="qpl-v1" id="qpl_v1">
      <div class="qpl-label" id="qpl_secretLabel">${escapeHtml(t('qpl.link_secret'))}</div>
      <div role="group" aria-labelledby="qpl_secretLabel">${stored}
        <div class="qpl-secret-edit" hidden>
          <input type="password" id="qpl_secretInput" autocomplete="off" spellcheck="false" aria-label="${escapeHtml(t('qpl.link_secret'))}" aria-describedby="qpl_secretRule">
          <button type="button" class="btn primary" data-qpl-set="save">${escapeHtml(t('qpl.save_secret'))}</button>
          <button type="button" class="btn ghost" data-qpl-set="cancel">${escapeHtml(t('common.cancel'))}</button>
          <p class="settings-field-hint" id="qpl_secretRule">${escapeHtml(t('qpl.secret_rule'))}</p>
        </div>
      </div>
      <p class="settings-field-hint">${escapeHtml(t('qpl.secret_hint'))}</p>
      </div>`;
  }

  function renderPayLinkSettings(keepTyped) {
    const el = document.getElementById('quotePayLinkSection');
    if (!el || !PL()) return;
    // A redraw after the secret changes keeps an address typed and not yet saved.
    const typed = keepTyped ? el.querySelector('#qpl_storeUrl') : null;
    const value = typed ? typed.value : null;
    el.innerHTML = settingsHtml();
    if (value !== null) el.querySelector('#qpl_storeUrl').value = value;
    refreshV2();
  }

  /* ── Pay link v2: this computer's key and the shop's keys ────────────────
   * Figma 7Iqw0GcrLLRW7CLDEhTa1P, frames 94:543 (this computer signs),
   * 94:778 (waiting for approval) and 94:1013 (approving another computer).
   * Off unless main answers `enabled` (KHAYT_PAYLINK_V2=1); then the v1
   * secret rows are hidden and these take their place. Main holds the key and
   * the Cloud token; the window gets short kids, statuses and labels. */

  let v2Revoking = '';
  const isOwner = () => ((settings.cloud && settings.cloud.role) || 'owner') === 'owner';
  const v2Date = (iso) => { const ms = Date.parse(iso || ''); return Number.isFinite(ms) ? shortDate(ms) : ''; };
  const tail = (kid) => String(kid || '').slice(-4);

  function v2Row(text, buttons) {
    return `<div class="qpl-secret-row qpl-key-row">
      <div class="qpl-secret-dots">${escapeHtml(text)}</div>${buttons || ''}</div>`;
  }
  const v2Btn = (act, label, kid, cls) => `<button type="button" class="btn ${cls || ''}" data-qpl-v2="${act}"${kid ? ` data-kid="${escapeHtml(kid)}"` : ''}>${escapeHtml(label)}</button>`;

  function v2Html(st) {
    if (!st.cloud) return `<div class="qpl-label">${escapeHtml(t('qpl.v2_keys'))}</div>${v2Row(t('qpl.v2_no_cloud'))}`;
    if (!st.ok) return `<div class="qpl-label">${escapeHtml(t('qpl.v2_keys'))}</div>${v2Row(t('qpl.v2_unreachable'), v2Btn('refresh', t('qpl.v2_retry')))}`;
    const others = (st.keys || []).filter((k) => !k.mine);
    // While this computer waits for approval it acts on no other key (frame 94:778).
    const mayAct = isOwner() && st.state !== 'pending';
    const otherRows = others.map((k) => v2Row(t('qpl.v2_key_other', { device: k.device || t('qpl.v2_another_computer'), date: v2Date(k.created), key: k.short }),
      mayAct ? v2Btn('revoke', t('qpl.v2_revoke'), k.kid, 'ghost qpl-remove') : '')).join('');
    const codeRow = v2Revoking ? `<div class="qpl-secret-edit">
        <input type="text" id="qpl_v2Code" autocomplete="one-time-code" spellcheck="false" maxlength="8" aria-label="${escapeHtml(t('qpl.v2_code'))}" placeholder="${escapeHtml(t('qpl.v2_code'))}">
        ${v2Btn('revoke-confirm', t('qpl.v2_revoke'), v2Revoking, 'danger')}
        ${v2Btn('revoke-cancel', t('common.cancel'), '', 'ghost')}
        <p class="settings-field-hint">${escapeHtml(t('qpl.v2_code_sent'))}</p></div>` : '';

    if (st.state === 'none' || st.state === 'unpublished' || st.state === 'revoked') {
      return `<div class="qpl-label">${escapeHtml(t('qpl.v2_this_computer'))}</div>
        ${v2Row(t('qpl.v2_none'), v2Btn('setup', t('qpl.v2_setup'), '', 'primary'))}${otherRows}${codeRow}
        <p class="settings-field-hint">${escapeHtml(t('qpl.v2_hint'))}</p>`;
    }
    if (st.state === 'pending') {
      return `<div class="qpl-label">${escapeHtml(t('qpl.v2_this_computer'))}</div>
        ${v2Row(t('qpl.v2_waiting', { date: v2Date(st.mine && st.mine.requestedAt) }), v2Btn('cancel', t('qpl.v2_cancel_request')))}${otherRows}
        <p class="settings-field-hint">${escapeHtml(t('qpl.v2_waiting_hint', { key: tail(st.mine && st.mine.kid) }))}</p>`;
    }
    const mine = (st.keys || []).find((k) => k.mine);
    const mineRow = v2Row(t('qpl.v2_key_mine', { status: t('qpl.v2_status_' + st.state), date: v2Date(mine && mine.created), key: st.mine.short }),
      (st.state === 'current' ? v2Btn('rotate', t('qpl.v2_rotate')) : '') + (isOwner() ? v2Btn('revoke', t('qpl.v2_revoke'), st.mine.kid, 'ghost qpl-remove') : ''));
    const asks = (st.pending || []).map((p) => v2Row(t('qpl.v2_asks', { device: p.device || t('qpl.v2_another_computer'), key: p.short, date: v2Date(p.requested) }),
      v2Btn('approve', t('qpl.v2_approve'), p.kid) + v2Btn('decline', t('qpl.v2_decline'), p.kid, 'ghost qpl-remove'))).join('');
    const asksBlock = asks ? `<div class="qpl-label">${escapeHtml(t('qpl.v2_asks_head'))}</div>${asks}
        <p class="settings-field-hint">${escapeHtml(t('qpl.v2_approve_hint', { key: tail(st.pending[0].kid) }))}</p>` : '';
    return `${asksBlock}<div class="qpl-label">${escapeHtml(t('qpl.v2_keys'))}</div>${mineRow}${otherRows}${codeRow}
      <p class="settings-field-hint">${escapeHtml(t('qpl.v2_hint'))}</p>`;
  }

  async function refreshV2() {
    const host = document.getElementById('qpl_v2');
    if (!host || !global.hubAPI?.qlkStatus) return;
    let st;
    try { st = await global.hubAPI.qlkStatus(); } catch (_) { return; }
    if (!st || !st.enabled) return;
    const v1 = document.getElementById('qpl_v1');
    if (v1) v1.hidden = true;
    const intro = document.getElementById('qpl_intro');
    if (intro) intro.textContent = t('qpl.v2_intro');
    host.hidden = false;
    host.innerHTML = v2Html(st);
  }

  async function onV2Click(e) {
    const b = e.target.closest('#qpl_v2 [data-qpl-v2]');
    if (!b) return;
    const act = b.dataset.qplV2;
    const kid = b.dataset.kid || '';
    const api = global.hubAPI || {};
    const done = (res, okMsg) => {
      if (res && res.ok) { if (okMsg) toast(t(okMsg), 'success'); }
      else toast(t('qpl.v2_failed', { reason: (res && res.error) || '—' }), 'error');
      refreshV2();
    };
    if (act === 'refresh') { refreshV2(); return; }
    if (act === 'setup') { done(await api.qlkSetup?.(), 'qpl.v2_setup_done'); return; }
    if (act === 'cancel') { done(await api.qlkCancel?.()); return; }
    if (act === 'approve') {
      if (!(await confirmModal(t('qpl.v2_approve_confirm', { key: tail(kid) }), { okText: t('qpl.v2_approve') }))) return;
      done(await api.qlkApprove?.(kid), 'qpl.v2_approved'); return;
    }
    if (act === 'decline') { done(await api.qlkDecline?.(kid)); return; }
    if (act === 'rotate') {
      if (!(await confirmModal(t('qpl.v2_rotate_confirm'), { okText: t('qpl.v2_rotate') }))) return;
      done(await api.qlkRotate?.(), 'qpl.v2_rotated'); return;
    }
    if (act === 'revoke') {
      if (!(await confirmModal(t('qpl.v2_revoke_confirm'), { okText: t('qpl.v2_revoke'), danger: true }))) return;
      const res = await api.qlkRevoke?.(kid);
      if (res && res.ok && res.codeSent) { v2Revoking = kid; refreshV2(); return; }
      done(res); return;
    }
    if (act === 'revoke-cancel') { v2Revoking = ''; refreshV2(); return; }
    if (act === 'revoke-confirm') {
      const code = (document.getElementById('qpl_v2Code')?.value || '').trim();
      if (!code) { document.getElementById('qpl_v2Code')?.focus(); return; }
      const res = await api.qlkRevoke?.(kid, code);
      if (res && res.ok) v2Revoking = '';
      done(res, 'qpl.v2_revoked');
    }
  }
  document.addEventListener('click', onV2Click);

  /* Settings › Data: "Reset pay link keys…" (lost keys). Owner only, v2 on
   * only. Revokes every key of the shop; each connected store must re-pin
   * once. Two steps, like Revoke: a warning, then the code Khayt Cloud emails. */
  let resetAsked = false;
  function resetHtml() {
    const btn = `<button type="button" class="btn danger" data-qlk-reset="start">${escapeHtml(t('qpl.v2_reset'))}</button>`;
    if (!resetAsked) return `<div class="btn-row" style="margin-top:10px;">${btn}</div>`;
    return `<div class="qpl-secret-edit" style="margin-top:10px;">
      <input type="text" id="qlk_resetCode" autocomplete="one-time-code" spellcheck="false" maxlength="8" aria-label="${escapeHtml(t('qpl.v2_code'))}" placeholder="${escapeHtml(t('qpl.v2_code'))}">
      <button type="button" class="btn danger" data-qlk-reset="confirm">${escapeHtml(t('qpl.v2_reset_now'))}</button>
      <button type="button" class="btn ghost" data-qlk-reset="cancel">${escapeHtml(t('common.cancel'))}</button>
      <p class="settings-field-hint">${escapeHtml(t('qpl.v2_code_sent'))}</p></div>`;
  }
  async function renderResetKeys() {
    const host = document.getElementById('qlkResetHost');
    if (!host || !global.hubAPI?.qlkStatus) return;
    let st;
    try { st = await global.hubAPI.qlkStatus(); } catch (_) { return; }
    if (!st || !st.enabled || !st.cloud || !isOwner()) { host.hidden = true; host.innerHTML = ''; return; }
    host.hidden = false;
    host.innerHTML = resetHtml();
  }
  document.addEventListener('click', async (e) => {
    if (e.target.closest('.settings-nav-item')) { setTimeout(renderResetKeys, 0); }
    const b = e.target.closest('#qlkResetHost [data-qlk-reset]');
    if (!b) return;
    const act = b.dataset.qlkReset;
    const api = global.hubAPI || {};
    if (act === 'cancel') { resetAsked = false; renderResetKeys(); return; }
    if (act === 'start') {
      if (!(await confirmModal(t('qpl.v2_reset_confirm'), { okText: t('qpl.v2_reset'), danger: true }))) return;
      const res = await api.qlkReset?.();
      if (res && res.ok && res.codeSent) { resetAsked = true; renderResetKeys(); return; }
      toast(t('qpl.v2_failed', { reason: (res && res.error) || '—' }), 'error');
      return;
    }
    if (act === 'confirm') {
      const input = document.getElementById('qlk_resetCode');
      const code = (input?.value || '').trim();
      if (!code) { input?.focus(); return; }
      const res = await api.qlkReset?.(code);
      if (res && res.ok) { resetAsked = false; toast(t('qpl.v2_reset_done'), 'success'); renderResetKeys(); refreshV2(); }
      else toast(t('qpl.v2_failed', { reason: (res && res.error) || '—' }), 'error');
    }
  });
  // What Khayt Cloud says can change between visits (another computer asks,
  // a key is revoked), so the keys are read again each time the pane opens.
  document.addEventListener('click', (e) => {
    if (e.target.closest('.settings-nav-item[data-settings-section="store"]')) refreshV2();
  });

  /** Called by the pane's Save: the store address is an ordinary setting. */
  function savePayLinkSettingsFromForm() {
    const input = document.getElementById('qpl_storeUrl');
    if (!input || !PL()) return true;
    const typed = input.value.trim();
    const base = typed ? PL().storeBase(typed) : '';
    if (typed && !base) { toast(t('qpl.store_address_bad'), 'error'); input.focus(); return false; }
    settings.quotePayLink = { ...q(), storeUrl: base };
    return true;
  }

  async function onSettingsClick(e) {
    const b = e.target.closest('#quotePayLinkSection [data-qpl-set]');
    if (!b) return;
    const box = document.getElementById('quotePayLinkSection');
    const edit = box.querySelector('.qpl-secret-edit');
    const act = b.dataset.qplSet;
    if (act === 'replace') { edit.hidden = false; box.querySelector('#qpl_secretInput').focus(); return; }
    if (act === 'cancel') { box.querySelector('#qpl_secretInput').value = ''; edit.hidden = true; return; }
    if (act === 'save') {
      const input = box.querySelector('#qpl_secretInput');
      const secret = input.value;
      input.value = '';
      if (!PL().secretIsUsable(secret)) { toast(t('qpl.secret_rule'), 'error'); input.focus(); return; }
      const res = await global.hubAPI?.quotePayLinkSetSecret?.(secret);
      if (!res || !res.ok) { toast(t('qpl.secret_failed'), 'error'); return; }
      settings.quotePayLink = { ...q(), secret: STORE_SECRET_MASK, secretSetAt: res.setAt };
      renderPayLinkSettings(true);
      toast(t('qpl.secret_set'), 'success');
      return;
    }
    if (act === 'remove') {
      if (!(await confirmModal(t('qpl.remove_confirm'), { okText: t('qpl.remove'), danger: true }))) return;
      const res = await global.hubAPI?.quotePayLinkRemoveSecret?.();
      if (!res || !res.ok) { toast(t('qpl.secret_failed'), 'error'); return; }
      const next = { ...q() };
      delete next.secret; delete next.secretSetAt;
      settings.quotePayLink = next;
      renderPayLinkSettings(true);
    }
  }

  function onClick(e) {
    const b = e.target.closest('[data-act="qpl-send"], [data-act="qpl-settle"], [data-act="qpl-open-order"]');
    if (!b) return;
    const id = b.dataset.id;
    if (b.dataset.act === 'qpl-send') { openSendSheet(id); return; }
    if (b.dataset.act === 'qpl-settle') { if (typeof openPaymentModal === 'function') openPaymentModal(id); return; }
    const order = printLog.find((o) => o.id === id);
    const url = order && order.payLink && order.payLink.paid && order.payLink.paid.url;
    if (/^https:\/\//.test(String(url || ''))) global.hubAPI?.openExternal?.(url);
  }

  document.addEventListener('click', onClick);
  document.addEventListener('click', onSettingsClick);

  const payLinkLineHtml = (order) => `<div class="qpl-line-host" data-id="${escapeHtml(String(order.id))}">${lineHtml(order)}</div>`;
  const payLinkCanSend = (order) => !!PL() && PL().canSendFrom(lineState(order, Date.now()).state);
  const renderPayLinkSettingsNow = () => renderPayLinkSettings(false);

  Object.assign(global, {
    payLinkLineHtml, payLinkLineState: (order) => lineState(order, Date.now()), payLinkCanSend, openPayLinkSheet: openSendSheet,
    renderPayLinkSettings: renderPayLinkSettingsNow, savePayLinkSettingsFromForm,
  });
})(typeof globalThis !== 'undefined' ? globalThis : window);
