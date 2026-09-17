/**
 * Online customer features: intake form and LAN-backed links (same Wi‑Fi or tunnel).
 */
(function (global) {
  /** Apply LAN defaults when the shop enables online intake. */
  function applyOnlineLanPrefs(lanApi, onlineEnabled) {
    const lan = { ...(lanApi || {}) };
    if (!onlineEnabled) return lan;
    return { ...lan, enabled: true, bindLan: true };
  }

  function intakeUrlFromBase(baseUrl) {
    if (!baseUrl) return '';
    return String(baseUrl).replace(/\/$/, '') + '/intake';
  }

  function formatIntakePinHint() {
    const pin = settings.lanApi?.intakePin;
    if (!pin) return t('online.intake_pin_pending') || 'PIN auto-generated when the server starts (or set one below).';
    if (typeof isSecretMasked === 'function' && isSecretMasked(pin)) {
      return t('online.intake_pin_masked') || 'PIN is set — restart the server to see it again, or change it in LAN settings.';
    }
    return pin; // caller renders it with a label and copy button
  }

  async function getLanBaseUrl() {
    const res = await window.hubAPI?.getLanUrl?.().catch(() => null);
    return res?.ok && res.url ? res.url : null;
  }

  async function copyTextToClipboard(text, btn, okLabel) {
    if (!text) {
      toast(t('online.need_server') || 'Start the LAN server in Settings first', 'warning');
      return;
    }
    if (!await copyText(text)) {
      toast(t('common.copy_failed') || 'Copy failed', 'error');
      return;
    }
    toast(okLabel || t('common.copied') || 'Copied', 'success');
    if (btn) {
      const prev = btn.textContent;
      btn.textContent = '✓';
      setTimeout(() => { btn.textContent = prev; }, 2000);
    }
  }

  async function refreshOnlineIntakeUrlDisplay(wrapEl) {
    if (!wrapEl) return;
    const urlEl = wrapEl.querySelector('[data-online-intake-url]');
    const pinEl = wrapEl.querySelector('[data-online-intake-pin]');
    if (!settings.onlineEnabled) {
      wrapEl.style.display = 'none';
      return;
    }
    wrapEl.style.display = '';
    if (pinEl) {
      pinEl.textContent = settings.onlineEnabled
        ? (t('online.intake_no_pin_needed') || 'Customers open the link above — no PIN required.')
        : formatIntakePinHint();
    }
    if (!urlEl) return;
    const base = await getLanBaseUrl();
    if (base) {
      const intakeUrl = intakeUrlFromBase(base);
      urlEl.innerHTML =
        `<a href="#" class="online-intake-link" data-url="${escapeHtml(intakeUrl)}" style="color:var(--primary);word-break:break-all;font-weight:600;font-size:13px;">${escapeHtml(intakeUrl)}</a>`;
      urlEl.querySelectorAll('.online-intake-link').forEach((a) => {
        a.addEventListener('click', (e) => {
          e.preventDefault();
          window.hubAPI?.openExternal?.(a.dataset.url);
        });
      });
    } else {
      urlEl.textContent = t('online.start_server_hint') || 'Start the server below to get your link.';
    }
  }

  async function copyOnlineIntakeUrl(btn) {
    const base = await getLanBaseUrl();
    await copyTextToClipboard(base ? intakeUrlFromBase(base) : '', btn, t('copyIntakeUrl') || 'Copied');
  }

  async function renderOnlineCustomerLinks() {
    const el = $('#onlineHubLinks');
    if (!el || !settings.onlineEnabled) return;

    const base = await getLanBaseUrl();
    if (!base) {
      el.innerHTML = `<p style="font-size:12px;color:var(--text-muted);margin:0;">${escapeHtml(t('online.hub_need_server') || 'Start the server to generate customer links.')}</p>`;
      return;
    }

    const quotes = printLog
      .filter((o) => o.status === 'quote')
      .slice()
      .sort((a, b) => (b.date || '').localeCompare(a.date || ''))
      .slice(0, 5);
    const trackable = printLog
      .filter((o) => o.status !== 'quote' && !KhaytOrderStatus.isFinished(o))
      .slice()
      .sort((a, b) => (a.dueDate || a.date || '').localeCompare(b.dueDate || b.date || ''))
      .slice(0, 5);

    const linkRow = (label, url, orderId, kind) => {
      if (!url) return '';
      return `<div class="online-hub-row" style="display:flex;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid var(--border-soft);flex-wrap:wrap;">
        <div class="col grow" style="min-width:140px;gap:2px;">
          <span style="font-size:12px;font-weight:600;">${escapeHtml(label)}</span>
          <span style="font-size:11px;color:var(--text-muted);word-break:break-all;">${escapeHtml(url)}</span>
        </div>
        <button type="button" class="btn small ghost" data-online-copy="${escapeHtml(url)}">${escapeHtml(t('common.copy') || 'Copy')}</button>
        ${orderId ? `<button type="button" class="btn small subtle" data-online-open-order="${escapeHtml(orderId)}" data-online-kind="${kind}">${escapeHtml(t('common.view') || 'View')}</button>` : ''}
      </div>`;
    };

    let html = `<div style="font-size:12px;color:var(--text-muted);margin-bottom:8px;" data-i18n="online.hub_intro">Share these links with customers on your shop network (same Wi‑Fi).</div>`;

    html += `<div style="margin-bottom:12px;">
      <div style="font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--text-muted);margin-bottom:4px;" data-i18n="onlineIntakeForm">Online Intake Form</div>
      <div data-online-intake-url style="font-size:13px;margin-bottom:6px;"></div>
      <div data-online-intake-pin style="font-size:11px;color:var(--text-muted);margin-bottom:6px;"></div>
      <button type="button" class="btn small primary" id="btnHubCopyIntake" data-i18n="copyIntakeUrl">Copy URL</button>
    </div>`;

    html += `<div style="margin-bottom:10px;">
      <div style="font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--text-muted);margin-bottom:4px;" data-i18n="online.hub_quotes">Open quotes (approve online)</div>
      ${quotes.length ? quotes.map((o) => linkRow(o.project || o.id, buildLanQuoteApprovalUrl(base, o), o.id, 'quote')).join('') : `<p style="font-size:12px;color:var(--text-muted);margin:0;">${escapeHtml(t('online.hub_no_quotes') || 'No open quotes yet.')}</p>`}
    </div>`;

    html += `<div>
      <div style="font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--text-muted);margin-bottom:4px;" data-i18n="online.hub_tracking">Active orders (live tracking)</div>
      ${trackable.length ? trackable.map((o) => linkRow(o.project || o.id, buildLanOrderTrackingUrl(base, o), o.id, 'track')).join('') : `<p style="font-size:12px;color:var(--text-muted);margin:0;">${escapeHtml(t('online.hub_no_active') || 'No active orders to track.')}</p>`}
    </div>`;

    el.innerHTML = html;
    i18n.applyToDom(el);

    refreshOnlineIntakeUrlDisplay(el);

    el.querySelector('#btnHubCopyIntake')?.addEventListener('click', (e) => copyOnlineIntakeUrl(e.currentTarget));
    el.querySelectorAll('[data-online-copy]').forEach((btn) => {
      btn.addEventListener('click', () => copyTextToClipboard(btn.dataset.onlineCopy, btn));
    });
    el.querySelectorAll('[data-online-open-order]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const id = btn.dataset.onlineOpenOrder;
        const kind = btn.dataset.onlineKind;
        if (kind === 'quote' && typeof openQuoteApprovalLinkModal === 'function') openQuoteApprovalLinkModal(id);
        else if (typeof openCustomerPortalModal === 'function') openCustomerPortalModal(id);
      });
    });
  }

  function renderOnlineSettings() {
    const el = $('#onlineSection');
    if (!el) return;
    const on = !!settings.onlineEnabled;
    const lanOn = !!settings.lanApi?.enabled;
    const serverStatusId = 'onlineServerStatus';

    el.innerHTML = `
      <label style="display:flex;align-items:flex-start;gap:8px;cursor:pointer;margin-bottom:12px;">
        <input type="checkbox" id="online_enabled" style="width:auto;margin:3px 0 0;" ${on ? 'checked' : ''}>
        <span>
          <strong data-i18n="online.enable_title">Enable online quote requests</strong>
          <div style="font-size:12px;color:var(--text-muted);margin-top:4px;font-weight:400;" data-i18n="online.enable_desc">
            Customers on your Wi‑Fi open a link to submit requests; they appear in Job Intake. Data stays on your computer — no Khayt cloud.
          </div>
        </span>
      </label>
      <div id="onlineDetails" style="display:${on ? 'block' : 'none'};">
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:12px;">
          <span id="${serverStatusId}" style="font-size:12px;">${lanOn ? '🟢 ' + (t('online.server_on') || 'Server running') : '⚫ ' + (t('online.server_off') || 'Server stopped')}</span>
          <button type="button" class="btn small ghost" id="btnOnlineStartServer" data-i18n="lan.start">Start server</button>
          <button type="button" class="btn small ghost" id="btnOnlineOpenLanSettings" data-i18n="online.open_lan">LAN & tunnel settings</button>
        </div>
        <div id="onlineHubLinks" style="padding:12px 14px;background:var(--bg-elev);border-radius:var(--radius);margin-bottom:12px;border:1px solid var(--border);"></div>
        <p style="font-size:11px;color:var(--text-muted);margin:0;line-height:1.5;" data-i18n="online.remote_hint">
          For customers outside your shop Wi‑Fi, use <strong>Remote tunnel</strong> in the LAN section below (advanced; use a strong owner PIN).
        </p>
      </div>`;

    i18n.applyToDom(el);

    el.querySelector('#online_enabled')?.addEventListener('change', async (e) => {
      const enabled = e.target.checked;
      settings.onlineEnabled = enabled;
      settings.lanApi = applyOnlineLanPrefs(settings.lanApi, enabled);
      await saveAll();
      renderOnlineSettings();
      if (enabled) {
        try {
          await startLanServer?.();
          renderOnlineCustomerLinks();
          renderWaitingOnlinePanel?.();
        } catch (_) {}
      } else {
        renderWaitingOnlinePanel?.();
      }
    });

    el.querySelector('#btnOnlineStartServer')?.addEventListener('click', () => {
      // Without a .catch this is an unhandled rejection and the panel never updates.
      Promise.resolve(startLanServer?.())
        .then(() => {
          renderOnlineSettings();
          renderOnlineCustomerLinks();
        })
        .catch((err) => {
          console.error('startLanServer failed:', err);
          renderOnlineSettings();  // reflect the real (stopped) state
        });
    });

    el.querySelector('#btnOnlineOpenLanSettings')?.addEventListener('click', () => {
      (typeof openSettingsSection === 'function' ? openSettingsSection : KhaytShell?.openSettingsSection)?.('online');
      setTimeout(() => {
        document.getElementById('lanApiSection')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }, 200);
    });

    if (on) renderOnlineCustomerLinks();
    syncOnlineServerStatusUI();
  }

  async function syncOnlineServerStatusUI() {
    const el = document.getElementById('onlineServerStatus');
    if (!el) return;
    const res = await window.hubAPI?.getLanUrl?.().catch(() => null);
    const live = !!res?.ok;
    settings.lanApi = { ...settings.lanApi, enabled: live };
    el.textContent = live
      ? '🟢 ' + (t('online.server_on') || 'Server running')
      : '⚫ ' + (t('online.server_off') || 'Server stopped');
  }

  function renderWaitingOnlinePanel() {
    const el = $('#waitingOnlinePanel');
    if (!el) return;
    if (!settings.onlineEnabled) {
      el.innerHTML = '';
      el.style.display = 'none';
      return;
    }
    el.style.display = 'block';
    el.innerHTML = `
      <div class="card" style="padding:12px 14px;margin-bottom:10px;border:1px solid var(--border);">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;">
          <div>
            <div style="font-weight:600;font-size:13px;">🌐 ${escapeHtml(t('onlineIntakeForm') || 'Online Intake Form')}</div>
            <div style="font-size:11px;color:var(--text-muted);margin-top:2px;" data-i18n="online.waiting_hint">Share this link; new requests land here.</div>
          </div>
          <div style="display:flex;gap:6px;flex-wrap:wrap;">
            <button type="button" class="btn small" id="btnWaitingCopyIntake" data-i18n="copyIntakeUrl">Copy URL</button>
            <button type="button" class="btn small ghost" id="btnWaitingOnlineSettings" data-i18n="online.hub_short">Online hub</button>
          </div>
        </div>
        <div data-online-intake-url style="font-size:12px;margin-top:8px;word-break:break-all;">—</div>
        <div data-online-intake-pin style="font-size:11px;color:var(--text-muted);margin-top:6px;"></div>
      </div>`;
    i18n.applyToDom(el);
    el.querySelector('#btnWaitingCopyIntake')?.addEventListener('click', (e) => copyOnlineIntakeUrl(e.currentTarget));
    el.querySelector('#btnWaitingOnlineSettings')?.addEventListener('click', () => {
      (typeof openSettingsSection === 'function' ? openSettingsSection : KhaytShell?.openSettingsSection)?.('online');
    });
    refreshOnlineIntakeUrlDisplay(el);
  }

  const api = {

    copyOnlineIntakeUrl,
    applyOnlineLanPrefs,
    intakeUrlFromBase,
    renderOnlineSettings,
    renderOnlineCustomerLinks,
    renderWaitingOnlinePanel,
    refreshOnlineIntakeUrlDisplay,
    syncOnlineServerStatusUI,
  };
  Object.assign(global, api);
  global.KhaytOnline = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
