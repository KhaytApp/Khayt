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
 * What the job remembers is `order.payLink`: `recordOf(claims)` —
 * `{ issuedAt, expiresAt, amount }` — plus the language it was sent in. A
 * payment on the store arrives as `order.payLink.paid`
 * (`{ storeOrder, amount, delivery, paidAt, url? }`, riyals, written by the
 * store import that settles the job); this file only reads it.
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
  const beganAsAcceptedQuote = (o) => o.status !== 'quote' && !!approvedAt(o);
  const paidElsewhere = (o) => (+o.paidAmount || 0) > 0 || o.paymentStatus === 'paid';

  /**
   * Which of the five states the job's line is in, or null for no line.
   *
   *   ready     an approved quote, nothing sent, nothing paid
   *   sent      a link is out and has not run out
   *   expired   the link ran out, still not paid
   *   paid      the store was paid what the quote says
   *   mismatch  the store was paid, but not what the quote now says
   */
  function lineState(order, nowMs) {
    if (!order || !PL()) return null;
    const rec = order.payLink && typeof order.payLink === 'object' ? order.payLink : null;
    if (rec && rec.paid && typeof rec.paid === 'object') {
      const quoted = PL().sums(order).total;
      return Math.round((+rec.paid.amount || 0) * 100) === quoted ? 'paid' : 'mismatch';
    }
    if (order.status === 'cancelled' || order.voidedAt || order.creditedAt) return null;
    if (paidElsewhere(order)) return null;
    if (rec && rec.expiresAt) return (nowMs / 1000) >= rec.expiresAt ? 'expired' : 'sent';
    if (!PL().configured(config()) || !beganAsAcceptedQuote(order)) return null;
    return 'ready';
  }

  function lineHtml(order) {
    const now = Date.now();
    const state = lineState(order, now);
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
      btn = secondary('qpl-send', t('qpl.send_again'));
    } else if (state === 'expired') {
      text = t('qpl.line_expired', { date: shortDate(rec.expiresAt * 1000) });
      btn = secondary('qpl-send', t('qpl.send_new'));
    } else if (state === 'paid') {
      const p = rec.paid;
      text = t('qpl.line_paid', { order: String(p.storeOrder || ''), amount: riyals(p.amount) + ' ' + t('qpl.sar'), delivery: riyals(p.delivery) });
      btn = /^https:\/\//.test(String(p.url || '')) ? secondary('qpl-open-order', t('qpl.open_order')) : '';
    } else {
      text = t('qpl.line_mismatch', { paid: riyals(rec.paid.amount), quoted: money(PL().sums(order).total) });
      btn = primary('qpl-settle', t('qpl.settle'));
    }
    return `<div class="qpl-line" data-state="${state}" data-id="${id}">
      <div class="qpl-line-words">
        <div class="qpl-line-label"><span class="qpl-dot" aria-hidden="true"></span>${escapeHtml(t('qpl.state_' + state))}</div>
        <div class="qpl-line-text">${escapeHtml(text)}</div>
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
      order.payLink = { ...res.record, locale: lang, sentAt: new Date().toISOString() };
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
      <p class="settings-panel-hint">${escapeHtml(t('qpl.settings_intro'))}</p>
      <label for="qpl_storeUrl">${escapeHtml(t('qpl.store_address'))}</label>
      <input type="url" id="qpl_storeUrl" inputmode="url" autocomplete="off" spellcheck="false" placeholder="https://" value="${escapeHtml(c.storeUrl || '')}">
      <div class="qpl-label" id="qpl_secretLabel">${escapeHtml(t('qpl.link_secret'))}</div>
      <div role="group" aria-labelledby="qpl_secretLabel">${stored}
        <div class="qpl-secret-edit" hidden>
          <input type="password" id="qpl_secretInput" autocomplete="off" spellcheck="false" aria-label="${escapeHtml(t('qpl.link_secret'))}" aria-describedby="qpl_secretRule">
          <button type="button" class="btn primary" data-qpl-set="save">${escapeHtml(t('qpl.save_secret'))}</button>
          <button type="button" class="btn ghost" data-qpl-set="cancel">${escapeHtml(t('common.cancel'))}</button>
          <p class="settings-field-hint" id="qpl_secretRule">${escapeHtml(t('qpl.secret_rule'))}</p>
        </div>
      </div>
      <p class="settings-field-hint">${escapeHtml(t('qpl.secret_hint'))}</p>`;
  }

  function renderPayLinkSettings(keepTyped) {
    const el = document.getElementById('quotePayLinkSection');
    if (!el || !PL()) return;
    // A redraw after the secret changes keeps an address typed and not yet saved.
    const typed = keepTyped ? el.querySelector('#qpl_storeUrl') : null;
    const value = typed ? typed.value : null;
    el.innerHTML = settingsHtml();
    if (value !== null) el.querySelector('#qpl_storeUrl').value = value;
  }

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
  const payLinkCanSend = (order) => ['ready', 'sent', 'expired'].includes(lineState(order, Date.now()));
  const renderPayLinkSettingsNow = () => renderPayLinkSettings(false);

  Object.assign(global, {
    payLinkLineHtml, payLinkLineState: lineState, payLinkCanSend, openPayLinkSheet: openSendSheet,
    renderPayLinkSettings: renderPayLinkSettingsNow, savePayLinkSettingsFromForm,
  });
})(typeof globalThis !== 'undefined' ? globalThis : window);
