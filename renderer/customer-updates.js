/**
 * Order updates sent to the customer by themselves, through the shop's own
 * WhatsApp Business account — the desktop doing what the Mac has done since
 * alpha (`mac/.../WhatsAppCloud.swift`, `WhatsAppReports.swift`), by the same
 * shared rules:
 *
 *   - WHEN: a job steps FORWARD into a milestone — received (a quote taken
 *     on, or any working status), ready (finished), shipped, delivered.
 *     `KhaytWhatsappMessage.cloudMessage` decides; a job moved back, or edited
 *     without moving, owes nothing.
 *   - TO WHOM: a customer who agreed to order updates on WhatsApp
 *     (`client.whatsappOptIn`, its own consent, apart from offers), with a
 *     number WhatsApp can take.
 *   - WITH WHAT: the template the shop had Meta approve for that milestone
 *     (`settings.whatsappTemplates`), in the language nearest the customer's.
 *     A milestone with no template sends nothing — that is how a shop sends
 *     "shipped" and nothing else.
 *   - ONCE: the send writes a line to the customer's log carrying the job id
 *     and milestone (`commEntry`: `orderId`, `milestone`, `messageId`,
 *     `status: 'sent'`, `via: 'whatsapp_cloud'`, `template`). That line is
 *     what `sentAt` reads on BOTH apps, so a job finished on the Mac and then
 *     shipped here is told each step once, and never the same step twice.
 *
 * Texts through Twilio, Unifonic or a webhook are not sent on their own here,
 * and are not on the Mac either: only an approved template the shop wrote
 * reaches a customer unasked.
 *
 * The token never passes through this window in the clear: `hub:send-whatsapp-
 * template` opens the saved one in the main process.
 */
(function (global) {
  'use strict';

  const CU = () => global.KhaytCustomerUpdates;
  const WM = () => global.KhaytWhatsappMessage;
  const WS = () => global.KhaytWhatsappStatus;

  /** `orderId|milestone` while a send is out, and after Meta took it. */
  const sending = new Set();

  const shopLang = () => (typeof settings !== 'undefined' && settings && settings.lang) || 'en';

  /** What only the host formats (`Shop.whatsAppValues` on the Mac). */
  function jobValues(order) {
    return {
      price: order.price == null ? '' : String(order.price),
      currency: order.currency || (settings && settings.currency) || '',
      due: order.dueDate || '',
    };
  }

  function milestoneName(m) { return t('cu.m_' + m); }

  /** The customer agreed and cannot be reached: why, in the shop's words. */
  function unreachableText(reason) {
    return ['too_short', 'too_long', 'no_country_code', 'bad_saudi_number'].includes(reason)
      ? t('cu.r_' + reason) : t('cu.r_no_phone');
  }

  /** Why Meta did not take it — the campaign's words for the same answers. */
  function refusedText(r) {
    const known = ['bad_token', 'bad_phone_number_id', 'template_missing', 'template_paused', 'not_on_whatsapp', 'rate_limited'];
    let reason = (r && r.reason) || 'other';
    if (reason === 'template_disabled') reason = 'template_paused';
    const said = t(known.includes(reason) ? 'wab.reason.' + reason : 'wab.reason.other');
    const title = r && r.title ? ' — ' + r.title : '';
    const code = r && r.code != null ? ` (#${r.code})` : '';
    return said + title + code;
  }

  /** What a change to this job owes its customer (`cloudMessage`). */
  function messageFor(before, order, now) {
    return WM().cloudMessage(before, order, {
      settings, clients, shopLang: shopLang(), values: jobValues(order), now: !!now,
    });
  }

  /**
   * Send one update and write it to the customer's log. `{ ok, text }`.
   *
   * The line is written only for a message Meta ACCEPTED, with its id. A send
   * that failed writes nothing, so the job goes on offering the update.
   */
  async function sendCustomerUpdate(order, msg) {
    if (!msg || !msg.send || !msg.template) return { ok: false, text: '' };
    if (!global.hubAPI || !global.hubAPI.sendWhatsappTemplate) return { ok: false, text: refusedText(null) };
    const key = order.id + '|' + msg.milestone;
    if (sending.has(key)) return { ok: false, text: '', inFlight: true };
    sending.add(key);
    let accepted = false;
    try {
      let r;
      try {
        r = await global.hubAPI.sendWhatsappTemplate({
          to: msg.to, template: msg.template, params: msg.params, smsConfig: settings.smsConfig,
        });
      } catch (e) { r = { ok: false, reason: 'unavailable' }; }
      if (!r || !r.ok || !r.messageId) return { ok: false, text: refusedText(r) };
      accepted = true;
      const client = clients.find((c) => c && c.id === msg.clientId);
      if (client) {
        const entry = WM().commEntry({
          id: uid('CMM'), at: new Date().toISOString(),
          text: t('cu.note', { name: msg.template.name, params: msg.params.join(' · ') }),
          orderId: order.id, milestone: msg.milestone, lang: msg.lang,
          messageId: r.messageId, template: msg.template.name,
        });
        client.commLog = CU().appendComm(client.commLog, entry);
        saveAll();
      }
      refreshJobUpdates(order.id);
      return { ok: true, text: '' };
    } finally {
      // Kept once Meta has it, so it is never sent twice this session; released
      // on a failure, so the job goes on offering it.
      if (!accepted) sending.delete(key);
    }
  }

  /**
   * After a change to a job has been made: send what it owes the customer,
   * and say what did not go. Not fatal — the job IS moved, as with a Telegram
   * message or an email that failed.
   *
   * `before` is the job as it was, or null when that is not known; a step
   * that cannot be shown to be forward sends nothing.
   */
  async function sendOwedCustomerUpdate(order, before) {
    if (!order || !WM() || !CU() || before == null) return;
    if (!WM().cloudAccount(settings).ok) return;   // no WhatsApp Business account: quiet
    const msg = messageFor(before, order, false);
    const m = msg.milestone ? milestoneName(msg.milestone) : '';
    if (!msg.send) {
      // Most reasons are quiet: no template for this step, a customer who has
      // not agreed, an update already sent. One who agreed and cannot be
      // reached is a customer who will not be told, and that is said.
      if (WM().isUnreachable(msg.reason)) {
        toast(t('cu.not_sent', { m }) + ' ' + unreachableText(msg.reason), 'warning', 7000);
      }
      return;
    }
    const out = await sendCustomerUpdate(order, msg);
    if (out.ok) toast(t('cu.sent', { m }), 'success', 4000);
    else if (!out.inFlight) toast(t('cu.not_sent', { m }) + ' ' + out.text, 'warning', 7000);
  }

  // ── IN THE JOB EDITOR ───────────────────────────────────────────────────

  function lineHtml(line) {
    const kind = (line.type || line.channel) === 'sms' ? 'SMS' : 'WhatsApp';
    const m = line.milestone ? milestoneName(line.milestone) : '';
    const day = line.at ? localDateStr(new Date(line.at)) : '';
    const state = CU().deliveryOf(line);
    const failed = state === 'failed';
    const badge = state
      ? `<span class="badge" data-cu-state="${escapeHtml(state)}" style="font-size:10.5px;${failed ? 'color:var(--danger);' : ''}">${escapeHtml(t('cu.st_' + state))}${failed && line.errorTitle ? ': ' + escapeHtml(line.errorTitle) : ''}</span>`
      : '';
    return `<div class="cu-line" style="display:flex;align-items:center;gap:8px;font-size:12px;padding:3px 0;">
      <span style="color:var(--text-muted);">${escapeHtml(day)}</span>
      <span>${escapeHtml(kind)}${m ? ' · ' + escapeHtml(m) : ''}</span>${badge}</div>`;
  }

  /** The inside of the job editor's updates box: what went, and a send button when one is owed. */
  function jobUpdatesInner(order) {
    if (!order || !CU() || !WM()) return '';
    const client = order.clientId ? clients.find((c) => c && c.id === order.clientId) : null;
    const lines = CU().jobLines(client, order.id).slice(0, 8);
    let button = '';
    if (WM().cloudAccount(settings).ok && WM().milestoneOf(order)) {
      const now = messageFor(null, order, true);
      if (now.send && !sending.has(order.id + '|' + now.milestone)) {
        button = `<button type="button" class="btn ghost small" data-act="cu-send-now" data-id="${escapeHtml(order.id)}">${escapeHtml(t('cu.send_now'))} · ${escapeHtml(milestoneName(now.milestone))}</button>`;
      }
    }
    if (!lines.length && !button) return '';
    return `<label style="margin:0 0 4px;font-size:12.5px;font-weight:600;">${escapeHtml(t('cu.title'))}</label>
      ${lines.map(lineHtml).join('')}${button ? `<div style="margin-top:6px;">${button}</div>` : ''}`;
  }

  /** The box itself, for the job editor's body. Empty when there is nothing to show. */
  function jobUpdatesHtml(order) {
    const inner = jobUpdatesInner(order);
    return `<div id="oeCustomerUpdates" data-order="${escapeHtml(order.id)}" style="margin-top:14px;${inner ? '' : 'display:none;'}">${inner}</div>`;
  }

  function refreshJobUpdates(orderId) {
    const box = typeof document !== 'undefined' ? document.getElementById('oeCustomerUpdates') : null;
    if (!box || (orderId && box.dataset.order !== orderId)) return;
    const order = printLog.find((o) => o.id === box.dataset.order);
    const inner = jobUpdatesInner(order);
    box.innerHTML = inner;
    box.style.display = inner ? '' : 'none';
  }

  /** "Send through WhatsApp Business", for a job that reached its step somewhere the move could not send it. */
  async function sendJobUpdateNow(orderId) {
    const order = printLog.find((o) => o.id === orderId);
    if (!order) return;
    const msg = messageFor(null, order, true);
    const m = msg.milestone ? milestoneName(msg.milestone) : '';
    if (!msg.send) {
      if (WM().isUnreachable(msg.reason)) toast(t('cu.not_sent', { m }) + ' ' + unreachableText(msg.reason), 'warning', 7000);
      refreshJobUpdates(orderId);
      return;
    }
    const out = await sendCustomerUpdate(order, msg);
    if (out.ok) toast(t('cu.sent', { m }), 'success', 4000);
    else if (!out.inFlight) toast(t('cu.not_sent', { m }) + ' ' + out.text, 'warning', 7000);
    refreshJobUpdates(orderId);
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('click', (e) => {
      const b = e.target && e.target.closest && e.target.closest('[data-act="cu-send-now"]');
      if (!b) return;
      b.disabled = true;
      sendJobUpdateNow(b.dataset.id);
    });
  }

  // ── DELIVERY REPORTS ────────────────────────────────────────────────────
  //
  // Meta reports sent / delivered / read / failed to Khayt Cloud, which keeps
  // them; this device reads them every two minutes, as the Mac does, and moves
  // the log line carrying each `messageId` forward (`lib/whatsapp-status.js`).

  const sinceKey = (shop) => 'khayt.whatsappReports.since.' + shop;
  const keptKey = (shop) => 'khayt.whatsappReports.kept.' + shop;
  function readJson(k, fallback) {
    try { const v = localStorage.getItem(k); return v == null ? fallback : JSON.parse(v); } catch (e) { return fallback; }
  }
  function writeJson(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* storage off: next poll reads again */ } }

  /** The cloud this shop is connected to, or null. */
  function cloudOf() {
    const c = (typeof settings !== 'undefined' && settings && settings.cloud) || {};
    if (c.enabled === false || !c.shopId || !c.url || !c.token) return null;
    return c;
  }

  let hookFor = null;       // the shop the hook answer is for
  let hookReads = false;    // configured, or a staff sign-in (which may read)
  let polling = false;

  /**
   * Write the reports into the book WITHOUT stamping the customers they move.
   * A report is not an edit: stamped, a "read" arriving here could win a merge
   * over a person's change to that customer on another device (the Mac writes
   * these unstamped for the same reason). So anything pending is saved and
   * stamped first, the lines are moved, and the change index is reseeded so
   * the next save sees nothing to stamp.
   */
  function writeReportsUnstamped(moved) {
    if (typeof flushSave === 'function') flushSave();
    for (let i = 0; i < clients.length; i++) {
      const next = moved[i];
      if (next && clients[i] && next !== clients[i] && next.id === clients[i].id) clients[i].commLog = next.commLog;
    }
    try {
      if (global.KhaytSync && global.KhaytSync.seedIndex && typeof collectStoreCollections === 'function') {
        global.KhaytSync.seedIndex(collectStoreCollections());
      }
    } catch (e) { console.error('[customer-updates] reseed failed:', e); }
    if (typeof flushSave === 'function') flushSave(); else saveAll();
  }

  async function pollWhatsappReports() {
    const c = cloudOf();
    const api = global.hubAPI;
    if (!c || !api || !api.cloudWhatsappStatuses || !CU() || !WS() || polling) return;
    polling = true;
    try {
      const auth = { url: c.url, shopId: c.shopId, token: c.token };
      if (hookFor !== c.shopId) {
        const h = await api.cloudWhatsappHook(auth);
        if (h && h.ok) hookReads = !!(h.hook && h.hook.configured);
        else if (h && h.status === 403) hookReads = true;   // staff: may read, not set up
        else return;                                       // offline or not offered: ask again next time
        hookFor = c.shopId;
      }
      if (!hookReads) return;
      let since = CU().seq(readJson(sinceKey(c.shopId), null));
      for (let page = 0; page < 20; page++) {
        const r = await api.cloudWhatsappStatuses(Object.assign({}, auth, { since }));
        if (!r || !r.ok) {
          if (r && (r.status === 403 || r.status === 404 || r.status === 405)) hookReads = false;
          break;
        }
        const items = Array.isArray(r.items) ? r.items : [];
        writeJson(keptKey(c.shopId), CU().keep(readJson(keptKey(c.shopId), []), items));
        const next = CU().seq(r.nextSince);
        if (next != null) writeJson(sinceKey(c.shopId), next);
        if (next == null || next === since || items.length < 500) break;
        since = next;
      }
      // Everything this device was told, laid over the book: the new reports
      // and any a merge took back off. Most polls move nothing and write nothing.
      const kept = readJson(keptKey(c.shopId), []);
      if (!Array.isArray(kept) || !kept.length) return;
      const applied = WS().apply(clients, kept);
      if (!applied.changed) return;
      writeReportsUnstamped(applied.clients);
      refreshJobUpdates();
      if (typeof renderClients === 'function') try { renderClients(); } catch (e) { /* not on screen */ }
    } catch (e) {
      console.warn('[customer-updates] delivery reports:', e && e.message);
    } finally {
      polling = false;
    }
  }

  let timer = null;
  function startWhatsappReportPolling() {
    if (timer) return;
    setTimeout(pollWhatsappReports, 5000);
    timer = setInterval(pollWhatsappReports, CU().POLL_MS);
  }

  Object.assign(global, {
    sendOwedCustomerUpdate, sendCustomerUpdate, sendJobUpdateNow,
    customerUpdatesHtml: jobUpdatesHtml, refreshJobUpdates,
    pollWhatsappReports, startWhatsappReportPolling,
  });
})(typeof globalThis !== 'undefined' ? globalThis : window);
