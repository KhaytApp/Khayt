/**
 * Settings tab: form load/save, integrations, ZATCA, LAN API, BNPL, backups.
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
// Bed Ready swaps decorative emoji for its bespoke drafting glyphs; Khayt keeps the emoji.
const _sBdr = (typeof document !== 'undefined' && document.documentElement && document.documentElement.dataset.app === 'bedready');
function _sIco(name, emoji, size) { return (_sBdr && window.BedReadyIcons) ? `<span class="br-ico">${window.BedReadyIcons.get(name, size || 15)}</span>` : emoji; }
function _sIcoL(name, emoji, size) { return (_sBdr && window.BedReadyIcons) ? `<span class="br-ico">${window.BedReadyIcons.get(name, size || 15)}</span>` : emoji + ' '; }
function renderLocationsSettings() {
  const el = $('#locationsSettingsSection');
  if (!el) return;
  ensureDefaultLocation();
  el.innerHTML = locations.map(loc => `
    <div class="machine-row">
      <span class="machine-name">${escapeHtml(loc.name)}</span>
      ${loc.address ? `<span style="font-size:12px;color:var(--text-muted);margin-inline-start:8px;">${escapeHtml(loc.address)}</span>` : ''}
      <button class="btn small" data-act="edit-loc" data-id="${loc.id}">${escapeHtml(t('common.edit'))}</button>
      ${locations.length > 1 ? `<button class="btn danger small" data-act="del-loc" data-id="${loc.id}">${escapeHtml(t('common.delete'))}</button>` : ''}
    </div>`).join('');
}

function renderEmailNotificationSettings() {
  const el = $('#emailNotificationsSection');
  if (!el) return;
  const cfg = settings.emailConfig || {};
  const triggers = [
    { key: 'printing',         label: 'Printing started' },
    { key: 'post',             label: 'In post-processing' },
    { key: 'completed',        label: 'Ready for pickup' },
    { key: 'quote',            label: 'Quote created' },
    { key: 'payment_received', label: 'Payment received' },
  ];
  el.innerHTML = `
    <div style="margin-bottom:12px;">
      <label style="margin-top:0;">${escapeHtml(t('set.email_provider'))}</label>
      <select id="emailProviderSel" style="font-size:12.5px;">
        <option value="none"${cfg.provider === 'none' || !cfg.provider ? ' selected' : ''}>${escapeHtml(t('set.smtp_none'))}</option>
        <option value="sendgrid"${cfg.provider === 'sendgrid' ? ' selected' : ''}>${escapeHtml(t('set.smtp_sendgrid'))}</option>
        <option value="mailgun"${cfg.provider === 'mailgun' ? ' selected' : ''}>${escapeHtml(t('set.smtp_mailgun'))}</option>
        <option value="custom"${cfg.provider === 'custom' ? ' selected' : ''}>${escapeHtml(t('set.smtp_custom'))}</option>
        <option value="mailto"${cfg.provider === 'mailto' ? ' selected' : ''}>${escapeHtml(t('set.smtp_mailto'))}</option>
      </select>
    </div>
    <div id="emailProviderFields" style="${cfg.provider && cfg.provider !== 'none' && cfg.provider !== 'mailto' ? '' : 'display:none;'}">
      <div id="emailApiFields" style="${cfg.provider === 'custom' ? 'display:none;' : ''}">
      <div class="inline-pair">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('set.email_api_key'))}</label>
          <input type="text" id="emailApiKey" value="${escapeHtml(cfg.apiKey || '')}" placeholder="sk-..." style="font-size:12.5px;">
        </div>
        <div>
          <label style="margin-top:0;">${escapeHtml(t('set.email_domain'))} (Mailgun)</label>
          <input type="text" id="emailDomain" value="${escapeHtml(cfg.domain || '')}" placeholder="mg.yourshop.com" style="font-size:12.5px;">
        </div>
      </div>
      </div>
      <div id="emailCustomSmtpFields" style="${cfg.provider === 'custom' ? '' : 'display:none;'}">
        <div class="inline-pair">
          <div>
            <label style="margin-top:0;">${escapeHtml(t('set.smtp_host'))}</label>
            <input type="text" id="emailSmtpHost" value="${escapeHtml(cfg.smtpHost || '')}" placeholder="smtp.yourshop.com" style="font-size:12.5px;">
          </div>
          <div>
            <label style="margin-top:0;">${escapeHtml(t('set.smtp_port'))}</label>
            <input type="number" id="emailSmtpPort" value="${cfg.smtpPort || 587}" min="1" max="65535" style="font-size:12.5px;">
          </div>
        </div>
        <div class="inline-pair">
          <div>
            <label style="margin-top:0;">${escapeHtml(t('set.smtp_user'))}</label>
            <input type="text" id="emailSmtpUser" value="${escapeHtml(cfg.smtpUser || '')}" placeholder="orders@yourshop.com" style="font-size:12.5px;">
          </div>
          <div>
            <label style="margin-top:0;">${escapeHtml(t('set.smtp_pass'))}</label>
            <input type="password" id="emailSmtpPass" value="${escapeHtml(cfg.smtpPassword || '')}" placeholder="••••••••" style="font-size:12.5px;">
          </div>
        </div>
        <label style="display:flex;align-items:center;gap:8px;margin:8px 0;font-weight:400;">
          <input type="checkbox" id="emailSmtpSecure" style="width:auto;margin:0;" ${cfg.smtpSecure ? 'checked' : ''}>
          <span>${escapeHtml(t('set.smtp_secure'))}</span>
        </label>
      </div>
      <div class="inline-pair">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('set.email_from'))}</label>
          <input type="email" id="emailFrom" value="${escapeHtml(cfg.fromEmail || '')}" placeholder="orders@yourshop.com" style="font-size:12.5px;">
        </div>
        <div>
          <label style="margin-top:0;">${escapeHtml(t('set.email_from_name'))}</label>
          <input type="text" id="emailFromName" value="${escapeHtml(cfg.fromName || '')}" placeholder="${escapeHtml(shopName() || 'Khayt')}" style="font-size:12.5px;">
        </div>
      </div>
    </div>
    <div style="margin-top:10px;">
      <label style="margin-top:0;font-size:12.5px;font-weight:600;">${escapeHtml(t('set.email_triggers'))}</label>
      <div style="display:flex;flex-wrap:wrap;gap:8px;margin-top:6px;">
        ${triggers.map(tr => `
          <label style="display:flex;align-items:center;gap:5px;font-size:12px;cursor:pointer;">
            <input type="checkbox" class="email-trigger-cb" data-trigger="${escapeHtml(tr.key)}" style="width:auto;margin:0;" ${(cfg.triggers || []).includes(tr.key) ? 'checked' : ''}>
            <span>${escapeHtml(tr.label)}</span>
          </label>`).join('')}
      </div>
    </div>
    <div style="display:flex;align-items:center;gap:8px;margin-top:10px;">
      <button id="btnSaveEmailCfg" class="btn small primary">${escapeHtml(t('common.save'))}</button>
      <button id="btnTestEmail" class="btn small">${escapeHtml(t('set.email_test'))}</button>
      <span id="emailTestResult" style="font-size:12px;color:var(--text-muted);"></span>
    </div>`;

  el.querySelector('#emailProviderSel')?.addEventListener('change', (e) => {
    const val = e.target.value;
    const fields = el.querySelector('#emailProviderFields');
    const apiFields = el.querySelector('#emailApiFields');
    const customFields = el.querySelector('#emailCustomSmtpFields');
    if (fields) fields.style.display = (val !== 'none' && val !== 'mailto') ? '' : 'none';
    if (apiFields) apiFields.style.display = val === 'custom' ? 'none' : '';
    if (customFields) customFields.style.display = val === 'custom' ? '' : 'none';
  });

  el.querySelector('#btnSaveEmailCfg')?.addEventListener('click', () => {
    settings.emailConfig = {
      provider:   el.querySelector('#emailProviderSel').value,
      apiKey:     secretInputSave((settings.emailConfig || {}).apiKey, el.querySelector('#emailApiKey')?.value),
      domain:     el.querySelector('#emailDomain')?.value.trim() || '',
      smtpHost:   el.querySelector('#emailSmtpHost')?.value.trim() || '',
      smtpPort:   parseInt(el.querySelector('#emailSmtpPort')?.value, 10) || 587,
      smtpUser:   el.querySelector('#emailSmtpUser')?.value.trim() || '',
      smtpPassword: secretInputSave((settings.emailConfig || {}).smtpPassword, el.querySelector('#emailSmtpPass')?.value),
      smtpSecure: !!el.querySelector('#emailSmtpSecure')?.checked,
      fromEmail:  el.querySelector('#emailFrom')?.value.trim() || '',
      fromName:   el.querySelector('#emailFromName')?.value.trim() || '',
      triggers:   [...el.querySelectorAll('.email-trigger-cb:checked')].map(cb => cb.dataset.trigger),
    };
    saveAll();
    toast(t('common.save'), 'success');
  });

  el.querySelector('#btnTestEmail')?.addEventListener('click', async () => {
    const resEl = el.querySelector('#emailTestResult');
    if (resEl) resEl.textContent = '…';
    const to = settings.email || '';
    if (!to) { if (resEl) { resEl.textContent = 'No shop email set in Settings.'; } return; }
    const cfg2 = {
      provider:  el.querySelector('#emailProviderSel').value,
      apiKey:    secretInputSave((settings.emailConfig || {}).apiKey, el.querySelector('#emailApiKey')?.value),
      domain:    el.querySelector('#emailDomain')?.value.trim() || '',
      smtpHost:  el.querySelector('#emailSmtpHost')?.value.trim() || '',
      smtpPort:  parseInt(el.querySelector('#emailSmtpPort')?.value, 10) || 587,
      smtpUser:  el.querySelector('#emailSmtpUser')?.value.trim() || '',
      smtpPassword: secretInputSave((settings.emailConfig || {}).smtpPassword, el.querySelector('#emailSmtpPass')?.value),
      smtpSecure: !!el.querySelector('#emailSmtpSecure')?.checked,
      fromEmail: el.querySelector('#emailFrom')?.value.trim() || '',
      fromName:  el.querySelector('#emailFromName')?.value.trim() || '',
    };
    const result = await window.hubAPI?.sendEmail?.({
      to, subject: 'Khayt — Test email', body: '<p>Test email from Khayt. Email notifications are working.</p>', smtpConfig: cfg2
    });
    if (resEl) {
      if (result?.ok) { resEl.textContent = t('set.email_test_sent'); resEl.style.color = 'var(--success)'; }
      else if (result?.fallback) { resEl.textContent = 'mailto: fallback (no API configured)'; resEl.style.color = 'var(--text-muted)'; }
      else { resEl.textContent = 'Failed: ' + (result?.error || result?.status || ''); resEl.style.color = 'var(--danger)'; }
    }
  });
}

/** Storefronts & payments directory for the owner's market (+ a country switcher),
 *  with payment providers the owner can enable + give their own pay link. */
function renderIntegrationsSettings() {
  const el = $('#integrationsSection');
  if (!el || typeof KhaytIntegrations === 'undefined') return;
  if (!settings.paymentProviders) settings.paymentProviders = {};
  const lang = (typeof i18n !== 'undefined' && i18n.current) || 'en';
  const viewLoc = el.dataset.market || lang;
  const m = KhaytIntegrations.forLocale(viewLoc);
  const country = (l) => (m.country[l] || m.country.en);
  const markets = Object.keys(KhaytIntegrations.MARKETS);
  const dirLabel = (d) => d === 'in' ? (t('integ.import') || 'Import orders') : (t('integ.publish') || 'Publish catalog');

  const cloud = settings.cloud || {};
  const cloudReady = !!(cloud.enabled && cloud.url && cloud.shopId);
  const cloudBase = String(cloud.url || '').replace(/\/+$/, '');
  const importUrl = (pid) => `${cloudBase}/v1/shops/${cloud.shopId}/import/${pid}`;
  const feedUrl = (pid) => `${cloudBase}/v1/shops/${cloud.shopId}/feed/${pid}`;
  const pill = (label) => `<span style="font-size:10px;color:var(--text-muted);border:1px solid var(--border-soft);border-radius:999px;padding:1px 7px;">${escapeHtml(label)}</span>`;
  const linkBtn = (url, label) => `<button class="btn small ghost integCopy" type="button" data-url="${escapeHtml(url)}">${escapeHtml(label)}</button>`;
  const codeBtn = (label) => `<button class="btn small ghost integCode" type="button">${escapeHtml(label)}</button>`;
  const storefrontRows = m.storefronts.map((sf) => {
    const actions = [];
    if (sf.dir.includes('in')) actions.push(cloudReady ? linkBtn(importUrl(sf.id), t('integ.copy_import') || 'Copy import link') : pill(t('integ.connect_cloud') || 'connect cloud'));
    // A platform with no webhook UI needs the code as well as the URL — the link
    // alone is a URL with nowhere to paste it. See lib/medusa-subscriber.js.
    if (sf.setup === 'subscriber' && cloudReady) actions.push(codeBtn(t('integ.copy_subscriber') || 'Copy subscriber code'));
    if (sf.dir.includes('out')) actions.push(cloudReady ? linkBtn(feedUrl(sf.id), t('integ.copy_feed') || 'Copy feed link') : pill(t('integ.connect_cloud') || 'connect cloud'));
    if (!actions.length) actions.push(pill(t('integ.soon') || 'soon'));
    return `<div style="display:flex;align-items:center;gap:8px;padding:6px 0;border-bottom:1px solid var(--border-soft);flex-wrap:wrap;">
      <span style="flex:1;font-size:13px;font-weight:600;">${escapeHtml(sf.name)}</span>
      <span style="font-size:10.5px;color:var(--text-muted);">${sf.dir.map(dirLabel).map(escapeHtml).join(' · ')}</span>
      ${actions.join('')}
    </div>`;
  }).join('');

  const payRows = m.payments.map((p) => {
    const cfg = settings.paymentProviders[p.id] || {};
    return `<div style="padding:7px 0;border-bottom:1px solid var(--border-soft);">
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;font-size:13px;">
        <input type="checkbox" class="payEnable" data-pid="${escapeHtml(p.id)}" style="width:auto;margin:0;" ${cfg.enabled ? 'checked' : ''}>
        <span style="font-weight:600;flex:1;">${escapeHtml(p.name)}</span>
      </label>
      <input class="payLink" data-pid="${escapeHtml(p.id)}" type="url" placeholder="${escapeHtml(t('integ.pay_link_ph') || 'your payment link (optional) — use {amount}')}"
        value="${escapeHtml(cfg.payLink || '')}" style="font-size:12px;margin-top:5px;${cfg.enabled ? '' : 'opacity:.5;'}">
    </div>`;
  }).join('');

  el.innerHTML = `
    <label style="margin-top:0;">${escapeHtml(t('integ.market') || 'Market')}</label>
    <select id="integMarket" style="font-size:12.5px;">
      ${markets.map((loc) => `<option value="${loc}"${loc === viewLoc ? ' selected' : ''}>${escapeHtml(KhaytIntegrations.forLocale(loc).country[lang] || KhaytIntegrations.forLocale(loc).country.en)}</option>`).join('')}
    </select>
    <div style="margin-top:14px;font-size:12px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.04em;">${escapeHtml(t('integ.storefronts') || 'Storefronts')} — ${escapeHtml(country(lang))}</div>
    ${cloudReady
      ? `<div style="font-size:11.5px;color:var(--text-muted);margin-top:4px;line-height:1.5;"><strong>${escapeHtml(t('integ.import') || 'Import orders')}:</strong> ${escapeHtml(t('integ.import_help') || 'paste the import link as an order webhook in your store — new orders arrive in Order requests.')}<br><strong>${escapeHtml(t('integ.publish') || 'Publish catalog')}:</strong> ${escapeHtml(t('integ.feed_help') || 'add the feed link as a product import URL in your store — it mirrors your published storefront catalog.')}</div>`
      : `<div style="font-size:11.5px;color:var(--text-muted);margin-top:4px;line-height:1.5;">${escapeHtml(t('integ.cloud_hint') || 'Connect cloud sync (Settings → Cloud) to get import & feed links for these storefronts.')}</div>`}
    <div style="margin-top:4px;">${storefrontRows}</div>
    <div style="margin-top:16px;font-size:12px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.04em;">${escapeHtml(t('integ.payments') || 'Payment systems')}</div>
    <div style="margin-top:4px;">${payRows}</div>
    <div style="display:flex;align-items:center;gap:8px;margin-top:12px;">
      <button id="btnSavePayProviders" class="btn small primary">${escapeHtml(t('common.save'))}</button>
      <span id="integResult" style="font-size:12px;color:var(--text-muted);"></span>
    </div>`;

  el.querySelector('#integMarket')?.addEventListener('change', (e) => { el.dataset.market = e.target.value; renderIntegrationsSettings(); });
  el.querySelectorAll('.integCopy').forEach((btn) => btn.addEventListener('click', async () => {
    const ok = await copyText(btn.dataset.url || '');
    const isFeed = /\/feed\//.test(btn.dataset.url || '');
    const msg = isFeed
      ? (t('integ.feed_copied') || 'Feed link copied — add it as a product import URL in your store')
      : (t('integ.import_copied') || 'Import link copied — paste it as a webhook in your store');
    const r = el.querySelector('#integResult');
    if (!r) return;
    r.textContent = ok ? '✓ ' + msg : (t('common.copy_failed') || 'Copy failed');
    r.style.color = ok ? 'var(--success)' : 'var(--danger)';
  }));
  el.querySelectorAll('.integCode').forEach((btn) => btn.addEventListener('click', async () => {
    const r = el.querySelector('#integResult');
    const src = (typeof KhaytMedusa !== 'undefined') ? KhaytMedusa.subscriberSource(importUrl('medusa')) : '';
    const ok = src ? await copyText(src) : false;
    if (!r) return;
    r.textContent = ok
      ? '✓ ' + (t('integ.subscriber_copied') || 'Subscriber copied — save it as src/subscribers/khayt-order-placed.ts in your Medusa project')
      : (t('common.copy_failed') || 'Copy failed');
    r.style.color = ok ? 'var(--success)' : 'var(--danger)';
  }));
  el.querySelectorAll('.payEnable').forEach((cb) => cb.addEventListener('change', () => {
    const link = el.querySelector(`.payLink[data-pid="${cb.dataset.pid}"]`); if (link) link.style.opacity = cb.checked ? '1' : '.5';
  }));
  el.querySelector('#btnSavePayProviders')?.addEventListener('click', () => {
    const pp = { ...(settings.paymentProviders || {}) };
    el.querySelectorAll('.payEnable').forEach((cb) => {
      const id = cb.dataset.pid;
      const link = (el.querySelector(`.payLink[data-pid="${id}"]`)?.value || '').trim();
      pp[id] = { enabled: cb.checked, payLink: /^https?:\/\//i.test(link) ? link : '' };
    });
    settings.paymentProviders = pp;
    saveAll();
    const r = el.querySelector('#integResult'); if (r) { r.textContent = '✓ ' + (t('common.save') || 'Saved'); r.style.color = 'var(--success)'; }
  });
}

/** Accounting sync (one-way webhook push) provider config. */
function renderAccountingSyncSettings() {
  const el = $('#accountingSyncSection');
  if (!el) return;
  const cfg = settings.accountingSync || {};
  const v = (x) => escapeHtml(x || '');
  const fmt = cfg.format || 'generic';
  const fmtOpt = (val, label) => `<option value="${val}"${fmt === val ? ' selected' : ''}>${escapeHtml(label)}</option>`;
  el.innerHTML = `
    <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-top:0;">
      <input type="checkbox" id="acctEnabled" style="width:auto;margin:0;" ${cfg.enabled ? 'checked' : ''}>
      <span>${escapeHtml(t('acct.enable') || 'Enable accounting sync')}</span>
    </label>
    <div class="inline-pair" style="margin-top:10px;">
      <div>
        <label style="margin-top:0;">${escapeHtml(t('acct.format') || 'Format')}</label>
        <select id="acctFormat" style="font-size:12.5px;">
          ${fmtOpt('generic', t('acct.fmt_generic') || 'Generic')}${fmtOpt('quickbooks', 'QuickBooks')}${fmtOpt('xero', 'Xero')}${fmtOpt('zoho', 'Zoho Books')}
        </select>
      </div>
      <div>
        <label style="margin-top:0;">${escapeHtml(t('acct.secret') || 'Shared secret (optional)')}</label>
        <input type="password" id="acctSecret" value="${v(cfg.secret)}" placeholder="••••••••" style="font-size:12.5px;">
      </div>
    </div>
    <label style="margin-top:8px;">${escapeHtml(t('acct.url') || 'Webhook URL')}</label>
    <input type="url" id="acctUrl" value="${v(cfg.webhookUrl)}" placeholder="https://hooks…/khayt" style="font-size:12.5px;">
    <label style="display:flex;align-items:center;gap:8px;margin-top:10px;cursor:pointer;">
      <input type="checkbox" id="acctPushOnPaid" style="width:auto;margin:0;" ${cfg.pushOnPaid !== false ? 'checked' : ''}>
      <span>${escapeHtml(t('acct.push_on_paid') || 'Push automatically when an invoice is marked paid')}</span>
    </label>
    <div style="display:flex;align-items:center;gap:8px;margin-top:12px;">
      <button id="btnSaveAcct" class="btn small primary">${escapeHtml(t('common.save'))}</button>
      <button id="btnTestAcct" class="btn small">${escapeHtml(t('acct.test') || 'Send test')}</button>
      <span id="acctTestResult" style="font-size:12px;color:var(--text-muted);"></span>
    </div>`;

  const collect = () => ({
    enabled: el.querySelector('#acctEnabled').checked,
    format: el.querySelector('#acctFormat').value,
    webhookUrl: el.querySelector('#acctUrl').value.trim(),
    secret: secretInputSave((settings.accountingSync || {}).secret, el.querySelector('#acctSecret').value),
    pushOnPaid: el.querySelector('#acctPushOnPaid').checked,
  });
  el.querySelector('#btnSaveAcct')?.addEventListener('click', () => {
    settings.accountingSync = collect(); saveAll(); toast(t('common.save'), 'success');
  });
  el.querySelector('#btnTestAcct')?.addEventListener('click', async () => {
    const res = el.querySelector('#acctTestResult');
    settings.accountingSync = collect(); saveAll();
    if (!/^https?:\/\//i.test(settings.accountingSync.webhookUrl)) { res.textContent = t('acct.need_url') || 'Enter a webhook URL first.'; res.style.color = 'var(--danger)'; return; }
    res.textContent = '…';
    const payload = { type: 'test', format: settings.accountingSync.format, idempotencyKey: 'test:' + Date.now(), note: 'Khayt accounting sync test' };
    const r = await window.hubAPI?.accountingPush?.({ url: settings.accountingSync.webhookUrl, secret: settings.accountingSync.secret, payload });
    if (r?.ok) { res.textContent = '✓ ' + (t('acct.test_sent') || 'Sent'); res.style.color = 'var(--success)'; }
    else { res.textContent = '✗ ' + (r?.error || r?.status || 'failed'); res.style.color = 'var(--danger)'; }
  });
}

/** SMS / WhatsApp notification provider config (mirrors the email section). */
function renderSmsNotificationSettings() {
  const el = $('#smsNotificationsSection');
  if (!el) return;
  const cfg = settings.smsConfig || {};
  const prov = cfg.provider || 'none';
  const v = (x) => escapeHtml(x || '');
  const opt = (val, label) => `<option value="${val}"${prov === val ? ' selected' : ''}>${escapeHtml(label)}</option>`;
  el.innerHTML = `
    <div class="inline-pair">
      <div>
        <label style="margin-top:0;">${escapeHtml(t('sms.provider') || 'Provider')}</label>
        <select id="smsProvider" style="font-size:12.5px;">
          ${opt('none', t('sms.none') || 'Off')}
          ${opt('twilio', 'Twilio (SMS + WhatsApp)')}
          ${opt('whatsapp_cloud', 'WhatsApp Cloud API')}
          ${opt('unifonic', 'Unifonic (SMS)')}
          ${opt('webhook', t('sms.webhook') || 'Custom webhook')}
        </select>
      </div>
      <div>
        <label style="margin-top:0;">${escapeHtml(t('sms.channel') || 'Channel')}</label>
        <select id="smsChannel" style="font-size:12.5px;">
          <option value="whatsapp"${(cfg.channel || 'whatsapp') === 'whatsapp' ? ' selected' : ''}>WhatsApp</option>
          <option value="sms"${cfg.channel === 'sms' ? ' selected' : ''}>SMS</option>
        </select>
      </div>
    </div>
    <div id="smsProviderFields" style="${prov !== 'none' ? '' : 'display:none;'}margin-top:8px;">
      <div data-prov="twilio" style="${prov === 'twilio' ? '' : 'display:none;'}">
        <div class="inline-pair">
          <div><label style="margin-top:0;">Account SID</label><input id="smsTwSid" value="${v(cfg.accountSid)}" placeholder="AC…" style="font-size:12.5px;"></div>
          <div><label style="margin-top:0;">Auth Token</label><input id="smsTwToken" type="password" value="${v(cfg.authToken)}" placeholder="••••••••" style="font-size:12.5px;"></div>
        </div>
        <label style="margin-top:8px;">${escapeHtml(t('sms.from') || 'From number')}</label>
        <input id="smsTwFrom" value="${v(cfg.from)}" placeholder="+1 555…" style="font-size:12.5px;">
      </div>
      <div data-prov="whatsapp_cloud" style="${prov === 'whatsapp_cloud' ? '' : 'display:none;'}">
        <div class="inline-pair">
          <div><label style="margin-top:0;">Phone Number ID</label><input id="smsWaId" value="${v(cfg.phoneNumberId)}" placeholder="1234567890" style="font-size:12.5px;"></div>
          <div><label style="margin-top:0;">Access Token</label><input id="smsWaToken" type="password" value="${v(cfg.token)}" placeholder="EAA…" style="font-size:12.5px;"></div>
        </div>
      </div>
      <div data-prov="unifonic" style="${prov === 'unifonic' ? '' : 'display:none;'}">
        <div class="inline-pair">
          <div><label style="margin-top:0;">AppSid</label><input id="smsUnSid" type="password" value="${v(cfg.appSid)}" placeholder="••••••••" style="font-size:12.5px;"></div>
          <div><label style="margin-top:0;">${escapeHtml(t('sms.sender') || 'Sender ID')}</label><input id="smsUnSender" value="${v(cfg.senderId)}" placeholder="Acme" style="font-size:12.5px;"></div>
        </div>
      </div>
      <div data-prov="webhook" style="${prov === 'webhook' ? '' : 'display:none;'}">
        <label style="margin-top:0;">${escapeHtml(t('sms.url') || 'Webhook URL')}</label>
        <input id="smsHookUrl" value="${v(cfg.url)}" placeholder="https://…" style="font-size:12.5px;">
        <label style="margin-top:8px;">${escapeHtml(t('sms.secret') || 'Shared secret (optional)')}</label>
        <input id="smsHookSecret" type="password" value="${v(cfg.secret)}" placeholder="••••••••" style="font-size:12.5px;">
      </div>
    </div>
    <div style="display:flex;align-items:center;gap:8px;margin-top:12px;">
      <button id="btnSaveSmsCfg" class="btn small primary">${escapeHtml(t('common.save'))}</button>
      <button id="btnTestSms" class="btn small">${escapeHtml(t('sms.test') || 'Send test')}</button>
      <span id="smsTestResult" style="font-size:12px;color:var(--text-muted);"></span>
    </div>`;

  const refreshProvFields = () => {
    const p = el.querySelector('#smsProvider').value;
    el.querySelector('#smsProviderFields').style.display = p !== 'none' ? '' : 'none';
    el.querySelectorAll('#smsProviderFields [data-prov]').forEach((d) => { d.style.display = d.dataset.prov === p ? '' : 'none'; });
  };
  el.querySelector('#smsProvider')?.addEventListener('change', refreshProvFields);

  const collect = () => ({
    provider:     el.querySelector('#smsProvider').value,
    channel:      el.querySelector('#smsChannel').value,
    accountSid:   el.querySelector('#smsTwSid')?.value.trim() || '',
    authToken:    secretInputSave((settings.smsConfig || {}).authToken, el.querySelector('#smsTwToken')?.value),
    from:         el.querySelector('#smsTwFrom')?.value.trim() || '',
    phoneNumberId: el.querySelector('#smsWaId')?.value.trim() || '',
    token:        secretInputSave((settings.smsConfig || {}).token, el.querySelector('#smsWaToken')?.value),
    appSid:       secretInputSave((settings.smsConfig || {}).appSid, el.querySelector('#smsUnSid')?.value),
    senderId:     el.querySelector('#smsUnSender')?.value.trim() || '',
    url:          el.querySelector('#smsHookUrl')?.value.trim() || '',
    secret:       secretInputSave((settings.smsConfig || {}).secret, el.querySelector('#smsHookSecret')?.value),
  });

  el.querySelector('#btnSaveSmsCfg')?.addEventListener('click', () => {
    settings.smsConfig = collect();
    saveAll();
    toast(t('common.save'), 'success');
  });

  el.querySelector('#btnTestSms')?.addEventListener('click', async () => {
    const res = el.querySelector('#smsTestResult');
    const to = (settings.phone || '').trim();
    if (!to) { res.textContent = t('sms.need_phone') || 'Set your shop phone in Settings to test.'; res.style.color = 'var(--danger)'; return; }
    res.textContent = '…';
    settings.smsConfig = collect(); saveAll();
    const r = await window.hubAPI?.sendSms?.({ to, message: 'Khayt test message — notifications are working.', channel: settings.smsConfig.channel, smsConfig: settings.smsConfig });
    if (r?.ok) { res.textContent = '✓ ' + (t('sms.test_sent') || 'Sent'); res.style.color = 'var(--success)'; }
    else { res.textContent = '✗ ' + (r?.error || r?.status || 'failed'); res.style.color = 'var(--danger)'; }
  });
}

/* ============================================================
   Feature I: Email Digest Scheduler
   ============================================================ */

function buildDigestEmailHtml() {
  const now = new Date();
  const todayStr = localDateStr(now);
  const freq = settings.emailDigest?.frequency || 'daily';
  const freqLabel = freq === 'weekly' ? 'Weekly' : (freq === 'monthly' ? 'Monthly' : 'Daily');

  // Compute period bounds
  let periodLabel, periodFrom, periodTo;
  if (freq === 'weekly') {
    const jan1 = new Date(now.getFullYear(), 0, 1);
    const weekNum = Math.ceil(((now - jan1) / 86400000 + jan1.getDay() + 1) / 7);
    periodLabel = `Week ${weekNum}, ${now.getFullYear()}`;
    // Start of week (Monday)
    const dayOfWeek = now.getDay(); // 0=Sun
    const diffToMon = (dayOfWeek === 0) ? -6 : 1 - dayOfWeek;
    periodFrom = new Date(now);
    periodFrom.setDate(now.getDate() + diffToMon);
    periodFrom.setHours(0, 0, 0, 0);
    periodTo = new Date(now);
  } else if (freq === 'monthly') {
    periodLabel = now.toLocaleDateString(localeTag(), { month: 'long', year: 'numeric' });
    periodFrom = new Date(now.getFullYear(), now.getMonth(), 1, 0, 0, 0, 0);
    periodTo = new Date(now);
  } else {
    periodLabel = todayStr;
    periodFrom = new Date(now);
    periodFrom.setHours(0, 0, 0, 0);
    periodTo = new Date(now);
  }

  const fromIso = periodFrom.toISOString();
  const toIso = periodTo.toISOString();

  // Stats
  const completedThisPeriod = printLog.filter(o =>
    o.status === 'completed' &&
    o.completedAt && o.completedAt >= fromIso && o.completedAt <= toIso
  );
  const revenueThisPeriod = completedThisPeriod.reduce((s, o) => s + orderNetRevenueBase(o), 0);
  const outstanding = printLog
    .filter(o => o.status === 'completed' && payStatus(o) !== 'paid')
    .reduce((s, o) => s + orderOwedBase(o), 0);

  // Low-stock spools
  const reorderPt = settings.lowStockThreshold ?? 200;
  const lowStockSpools = inventory
    .filter(s => (+s.weight || 0) < (s.reorderPoint ?? reorderPt))
    .slice(0, 5);

  const waitingCount = waitingList.length;
  const shopName = escapeHtml(shopField('biz') || 'Khayt');
  const currency = escapeHtml(settings.currency || 'SAR');

  return `<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>${shopName} Digest</title></head>
<body style="margin:0;padding:0;background:#f4f4f7;font-family:Arial,sans-serif;">
  <div style="max-width:600px;margin:32px auto;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.1);">
    <div style="background:#6c47ff;padding:24px 32px;">
      <h1 style="margin:0;color:#fff;font-size:22px;">${shopName}</h1>
      <p style="margin:4px 0 0;color:rgba(255,255,255,.8);font-size:13px;">${freqLabel} Digest · ${escapeHtml(periodLabel)}</p>
    </div>
    <div style="padding:28px 32px;">
      <table style="width:100%;border-collapse:collapse;font-size:14px;margin-bottom:24px;">
        <thead><tr style="border-bottom:2px solid #eee;">
          <th style="text-align:left;padding:8px 0;color:#888;">Metric</th>
          <th style="text-align:right;padding:8px 0;color:#888;">Value</th>
        </tr></thead>
        <tbody>
          <tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:10px 0;">Completed orders this period</td>
            <td style="text-align:right;font-weight:600;">${completedThisPeriod.length}</td>
          </tr>
          <tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:10px 0;">Revenue this period</td>
            <td style="text-align:right;font-weight:600;color:#22c55e;">${revenueThisPeriod.toFixed(2)} ${currency}</td>
          </tr>
          <tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:10px 0;">Outstanding receivables</td>
            <td style="text-align:right;font-weight:600;color:${outstanding > 0 ? '#f59e0b' : '#888'};">${outstanding.toFixed(2)} ${currency}</td>
          </tr>
          <tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:10px 0;">Low-stock spools</td>
            <td style="text-align:right;font-weight:600;color:${lowStockSpools.length > 0 ? '#ef4444' : '#888'};">${lowStockSpools.length}</td>
          </tr>
          <tr>
            <td style="padding:10px 0;">Waiting list items</td>
            <td style="text-align:right;font-weight:600;">${waitingCount}</td>
          </tr>
        </tbody>
      </table>
      ${lowStockSpools.length > 0 ? `
      <div style="background:#fff5f5;border-left:3px solid #ef4444;padding:12px 16px;border-radius:4px;margin-bottom:20px;">
        <div style="font-weight:600;font-size:13px;color:#ef4444;margin-bottom:8px;">Low Stock Alert</div>
        <ul style="margin:0;padding:0 0 0 16px;font-size:13px;color:#333;">
          ${lowStockSpools.map(s => `<li style="margin-bottom:4px;">${escapeHtml(s.material || s.brand || 'Spool')} — ${+s.weight || 0}g remaining (reorder at ${s.reorderPoint ?? reorderPt}g)</li>`).join('')}
        </ul>
      </div>` : ''}
    </div>
    <div style="padding:16px 32px;background:#f8f8fb;text-align:center;font-size:11px;color:#aaa;border-top:1px solid #eee;">
      Sent by Khayt · ${escapeHtml(todayStr)}
    </div>
  </div>
</body>
</html>`;
}

/**
 * This month's AI spend, per feature. The key is the owner's, so the bill is
 * theirs — and until now nothing in the app told them what it was. Anthropic's
 * console shows one total; only Khayt knows which feature spent it.
 */
function aiSpendHtml() {
  const U = window.KhaytAiUsage;
  if (!U || typeof settings === 'undefined') return '';
  const { rows, total } = U.summarize(settings.aiUsage, Date.now());
  if (!rows.length) return '';
  const P = window.KhaytAiPrivacy;
  const label = (task) => {
    const spec = P && P.AI_FEATURES[task];
    return spec ? (t(spec.labelKey) || task) : task;
  };
  const body = rows.map((r) => `
    <div class="ai-spend-row">
      <span class="ai-spend-name">${escapeHtml(label(r.task))}</span>
      <span class="ai-spend-calls">${escapeHtml(String(r.calls))}</span>
      <span class="ai-spend-cost">${escapeHtml(U.fmtUsd(r.costExact))}</span>
    </div>`).join('');
  const est = U.isEstimatedModel((settings.ai || {}).model);
  return `
    <details class="ai-spend">
      <summary>
        <span>${escapeHtml(t('set.ai_spend') || 'This month’s AI usage')}</span>
        <b>${escapeHtml(U.fmtUsd(total.cost))}</b>
      </summary>
      <div class="ai-spend-head">
        <span>${escapeHtml(t('set.ai_spend_feature') || 'Feature')}</span>
        <span>${escapeHtml(t('set.ai_spend_calls') || 'Calls')}</span>
        <span>${escapeHtml(t('set.ai_spend_cost') || 'Est. cost')}</span>
      </div>
      ${body}
      <p class="ai-spend-note">${escapeHtml(
        (t('set.ai_spend_note') || 'Estimated from token counts at list prices. Your Anthropic console is authoritative.')
        + ' ' + (t('set.ai_spend_device') || 'Counted on this device only — settings do not sync between machines.')
        + (est ? ' ' + (t('set.ai_spend_unknown_model') || 'Prices for this model are unknown — Opus rates assumed.') : ''))}</p>
    </details>`;
}

function renderAiSettings() {
  const el = $('#aiSettingsSection');
  if (!el) return;
  const ai = settings.ai || {};
  const P = window.KhaytAiPrivacy;
  // One global toggle used to gate four features that send very different
  // things. Consent is now per feature, and each row states what it transmits.
  const { features, reconsentRequired } = P.migrateConsent(ai);

  // WHICH AI. These features were Anthropic and nothing else, so a shop already
  // paying OpenAI — or one that must keep its book on a machine inside the
  // building — could use none of them. See lib/ai-providers.js.
  const AP = window.KhaytAiProviders;
  const all = AP ? AP.providers() : [];
  const chosen = (AP ? AP.providerOf(settings) : { id: 'anthropic', defaultModel: '', needsBaseUrl: false });
  const providerOptions = all.map((p) => `
    <option value="${escapeHtml(p.id)}" ${p.id === chosen.id ? 'selected' : ''}>${escapeHtml(p.label)}</option>`).join('');

  const featureRows = Object.values(P.AI_FEATURES).map((f) => {
    const pii = f.dataClass === P.DATA_CLASS.CUSTOMER;
    const needsConsent = reconsentRequired.includes(f.id);
    return `
      <div class="ai-feat${pii ? ' ai-feat-pii' : ''}">
        <label class="ai-feat-head">
          <input type="checkbox" class="ai-feat-toggle" data-feature="${escapeHtml(f.id)}"
                 ${features[f.id] ? 'checked' : ''} ${ai.enabled ? '' : 'disabled'}>
          <span class="ai-feat-name">${escapeHtml(t(f.labelKey) || f.id)}</span>
          ${pii ? `<span class="ai-feat-badge">${escapeHtml(t('set.ai_pii_badge') || 'Customer data')}</span>` : ''}
        </label>
        <p class="ai-feat-sends"><span class="ai-feat-sends-label">${escapeHtml((t('set.ai_sends_to') || 'Sends to {provider}:').replace('{provider}', chosen.label || 'the provider'))}</span> ${escapeHtml(t(f.sendsKey) || f.sends.join('; '))}</p>
        ${needsConsent ? `<p class="ai-feat-reconsent">${escapeHtml(t('set.ai_reconsent') || 'Turned off in this update because it sends a customer’s personal data. Tick it to re-enable.')}</p>` : ''}
      </div>`;
  }).join('');

  el.innerHTML = `
    <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-top:0;">
      <input type="checkbox" id="aiEnabled" style="width:auto;margin:0;" ${ai.enabled ? 'checked' : ''}>
      <span style="font-weight:600;font-size:13px;">${escapeHtml(t('set.ai_master') || 'AI assist')}</span>
    </label>
    <p class="ai-master-hint">${escapeHtml(t('set.ai_hint') || '')}</p>
    <div class="ai-feats" id="aiFeatureList">${featureRows}</div>
    ${aiSpendHtml()}
    <label style="margin-top:10px;">${escapeHtml(t('set.ai_provider') || 'Provider')}</label>
    <select id="aiProviderSetting">${providerOptions}</select>
    ${chosen.needsBaseUrl || ai.baseUrl ? `
      <label style="margin-top:10px;">${escapeHtml(t('set.ai_base_url') || 'Address')}</label>
      <input type="text" id="aiBaseUrlSetting" value="${escapeHtml(ai.baseUrl || '')}"
             placeholder="http://localhost:11434">` : ''}
    <label style="margin-top:10px;">${escapeHtml(t('calc.ai_key') || 'API key')}</label>
    <input type="password" id="aiKeySetting" value="${escapeHtml(secretInputValue(ai.apiKey))}" placeholder="${escapeHtml(chosen.id === 'anthropic' ? 'sk-ant-...' : 'sk-...')}">
    <label style="margin-top:10px;">${escapeHtml(t('set.ai_model') || 'Model')}</label>
    <input type="text" id="aiModelSetting" value="${escapeHtml(ai.model || chosen.defaultModel)}" placeholder="${escapeHtml(chosen.defaultModel || 'llama3')}">
    <div style="display:flex;gap:8px;align-items:center;margin-top:10px;">
      <button id="btnSaveAiSettings" class="btn primary small">${escapeHtml(t('common.save') || 'Save')}</button>
      <button id="btnTestAiSettings" class="btn small">🔌 ${escapeHtml(t('calc.ai_test') || 'Test connection')}</button>
      <span id="aiSettingsTestResult" style="font-size:12px;"></span>
    </div>`;

  // The master switch only greys the per-feature rows out — it never rewrites
  // them, so turning AI off and on again restores the owner's exact choices
  // rather than silently re-enabling something they had declined.
  el.querySelector('#aiEnabled')?.addEventListener('change', (e) => {
    el.querySelectorAll('.ai-feat-toggle').forEach((c) => { c.disabled = !e.target.checked; });
  });

  // Changing provider re-renders: the placeholder, the default model and
  // whether an address is asked for all belong to the provider, and a form
  // still showing Anthropic's hints after picking Ollama is a form that will
  // be filled in wrong.
  el.querySelector('#aiProviderSetting')?.addEventListener('change', (e) => {
    // KEEP WHAT IS ON SCREEN BEFORE REDRAWING IT.
    //
    // Changing provider has to redraw the whole panel — every feature row says
    // "Sends to Anthropic:" and has to start saying "Sends to OpenAI:" — but
    // the redraw reads the checkboxes from SAVED settings, not from the DOM.
    // So an unsaved tick was silently reverted by touching the dropdown.
    //
    // Which is a consent bug on the screen whose whole job is consent, and the
    // dangerous direction is the second one: a shop that UNTICKED the feature
    // sending a customer's name, then changed provider, had that consent
    // quietly restored and would have had no way to know.
    const kept = {};
    el.querySelectorAll('.ai-feat-toggle').forEach((c) => { kept[c.dataset.feature] = c.checked; });
    const baseField = el.querySelector('#aiBaseUrlSetting');
    const keyField = el.querySelector('#aiKeySetting');
    settings.ai = Object.assign({}, settings.ai, {
      provider: e.target.value,
      // The model belongs to the provider. Carrying `claude-opus-5` across to
      // OpenAI produces a 404 that reads as a broken key.
      model: '',
      features: Object.assign({}, settings.ai && settings.ai.features, kept),
      // The master toggle and a half-typed key and address, for the same
      // reason. Losing those is only annoying rather than unsafe, but it is
      // the same redraw throwing them away.
      enabled: el.querySelector('#aiEnabled')?.checked ?? (settings.ai || {}).enabled,
      baseUrl: baseField ? baseField.value.trim() : (settings.ai || {}).baseUrl,
      // Through the same helper the Save button uses, so a masked key stays
      // masked and is never written back as the literal mask string.
      apiKey: keyField
        ? secretInputSave((settings.ai || {}).apiKey, keyField.value.trim())
        : (settings.ai || {}).apiKey,
    });
    renderAiSettings();
  });

  el.querySelector('#btnSaveAiSettings')?.addEventListener('click', () => {
    const picked = {};
    el.querySelectorAll('.ai-feat-toggle').forEach((c) => { picked[c.dataset.feature] = c.checked; });
    const provider = el.querySelector('#aiProviderSetting')?.value || chosen.id;
    const baseField = el.querySelector('#aiBaseUrlSetting');
    settings.ai = {
      enabled: el.querySelector('#aiEnabled').checked,
      provider,
      baseUrl: baseField ? baseField.value.trim() : (ai.baseUrl || ''),
      model: el.querySelector('#aiModelSetting').value.trim() || chosen.defaultModel,
      apiKey: secretInputSave(ai.apiKey, el.querySelector('#aiKeySetting').value.trim()),
      // Persisting `features` is also what marks the consent migration as done,
      // so a saved choice is never re-migrated (migrateConsent is idempotent).
      features: picked,
    };
    saveAll();
    toast(t('common.save') || 'Saved', 'success');
    renderAiSettings();
    if (typeof renderPrivacySettings === 'function') renderPrivacySettings();
  });

  el.querySelector('#btnTestAiSettings')?.addEventListener('click', async () => {
    const res = el.querySelector('#aiSettingsTestResult');
    const typed = el.querySelector('#aiKeySetting').value.trim();
    const key = typed || settings.ai?.apiKey || ai.apiKey || '';
    if (!key) { res.textContent = '✗ ' + (t('calc.ai_need_key') || 'Enter an API key'); res.style.color = 'var(--danger)'; return; }
    res.textContent = t('calc.ai_testing') || 'Testing…'; res.style.color = 'var(--text-muted)';
    try {
      const r = await khaytAiExtract({
        apiKey: key,
        model: el.querySelector('#aiModelSetting').value.trim() || 'claude-opus-5',
        task: 'quote',
        system: (typeof KhaytAiQuote !== 'undefined') ? KhaytAiQuote.buildSystemContext(inventory) : '',
        request: 'Estimate: one small 20mm PLA calibration cube.',
        schema: (typeof KhaytAiQuote !== 'undefined') ? KhaytAiQuote.EXTRACTION_SCHEMA : {},
      });
      if (r && r.ok && r.draft) { res.textContent = '✓ ' + (t('calc.ai_test_ok') || 'Connection works'); res.style.color = 'var(--success)'; }
      else { res.textContent = '✗ ' + ((r && r.error) || 'failed'); res.style.color = 'var(--danger)'; }
    } catch (e) { res.textContent = '✗ ' + (e.message || e); res.style.color = 'var(--danger)'; }
  });
}

// Mirror the default slicer into the legacy settings.slicer so slice-and-print /
// kanban-print / quote-slice consumers keep working with no change.
function syncDefaultSlicer() {
  const d = KhaytSlicers.defaultSlicer(settings);
  settings.slicer = d ? { path: d.path, args: d.args || '' } : { path: '', args: '' };
}

// Scan the machine for installed slicers and add any that aren't already listed
// (matched by executable path). Returns the number newly added.
async function detectAndMergeSlicers() {
  if (!window.hubAPI?.detectSlicers) return 0;
  let r;
  try { r = await window.hubAPI.detectSlicers(); } catch (_) { return 0; }
  if (!r || !r.ok || !Array.isArray(r.slicers)) return 0;
  if (!Array.isArray(settings.slicers)) settings.slicers = [];
  const have = new Set(settings.slicers.map((s) => String(s.path || '').toLowerCase()));
  let added = 0;
  for (const found of r.slicers) {
    const key = String(found.path || '').toLowerCase();
    if (!key || have.has(key)) continue;
    have.add(key);
    const entry = { id: uid('SL'), name: found.name || KhaytSlicers.slicerDisplayName(found.path) || 'Slicer', path: found.path, args: '' };
    settings.slicers.push(entry);
    if (!settings.defaultSlicerId) settings.defaultSlicerId = entry.id;
    added++;
  }
  if (added > 0) { syncDefaultSlicer(); saveAll(); }
  return added;
}

function renderSlicerSettings() {
  const el = $('#slicerSettingsSection');
  if (!el) return;
  // One-time migration from the legacy single slicer to the slicers[] array.
  if (!Array.isArray(settings.slicers)) {
    settings.slicers = (settings.slicer && settings.slicer.path)
      ? [{ id: uid('SL'), name: KhaytSlicers.slicerDisplayName(settings.slicer.path) || 'Slicer', path: settings.slicer.path, args: settings.slicer.args || '' }]
      : [];
    if (settings.slicers.length && !settings.defaultSlicerId) settings.defaultSlicerId = settings.slicers[0].id;
    saveAll();
  }
  // First time here with nothing configured: offer every slicer on the machine
  // automatically (the user can still remove any they don't want).
  if (!settings.slicersAutoDetected && !settings.slicers.length) {
    settings.slicersAutoDetected = true;
    saveAll();
    detectAndMergeSlicers().then((n) => { if (n > 0) renderSlicerSettings(); });
  }

  const list = settings.slicers;
  if (list.length && !list.some((s) => s.id === settings.defaultSlicerId)) settings.defaultSlicerId = list[0].id;
  syncDefaultSlicer(); // keep the legacy settings.slicer mirror consistent with the default

  const PRESETS = {
    prusa: '--export-gcode --load /path/to/config.ini -o {output} {model}',
    orca: '--slice 0 --load-settings "machine.json;process.json" --load-filaments "filament.json" --outputdir {outdir} {model}',
  };

  const rows = list.map((s) => `
    <div class="slicer-row" data-id="${escapeHtml(s.id)}">
      <label class="slicer-default" title="${escapeHtml(t('slicer.set_default') || 'Use as default')}">
        <input type="radio" name="slicerDefault" value="${escapeHtml(s.id)}" ${s.id === settings.defaultSlicerId ? 'checked' : ''} data-act="slicer-default">
      </label>
      <div class="slicer-info">
        <div class="slicer-name">${escapeHtml(s.name || KhaytSlicers.slicerDisplayName(s.path))}${s.id === settings.defaultSlicerId ? ` <span class="slicer-badge">${escapeHtml(t('slicer.default') || 'default')}</span>` : ''}</div>
        <div class="slicer-path" title="${escapeHtml(s.path)}">${escapeHtml(s.path)}</div>
      </div>
      <button class="btn ghost small" type="button" data-act="slicer-test" data-id="${escapeHtml(s.id)}">${_sIcoL('play', '🔌')}${escapeHtml(t('slicer.test') || 'Test')}</button>
      <button class="btn ghost small danger" type="button" data-act="slicer-remove" data-id="${escapeHtml(s.id)}" title="${escapeHtml(t('common.delete') || 'Remove')}">${_sIco('trash', '🗑')}</button>
      <span class="slicer-test-result" data-result="${escapeHtml(s.id)}"></span>
    </div>`).join('');

  el.innerHTML = `
    <p class="slicer-intro" style="font-size:12.5px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(t('slicer.multi_intro') || 'Add the slicers you use. When you open a print file you can pick which one to launch; the default is used for slice-and-print elsewhere.')}</p>
    <div style="display:flex;gap:8px;align-items:center;margin:0 0 10px;flex-wrap:wrap;">
      <button id="btnDetectSlicers" class="btn small" type="button">${_sIcoL('search', '🔍')}${escapeHtml(t('slicer.detect') || 'Detect installed slicers')}</button>
      <span id="slicerDetectResult" style="font-size:12px;color:var(--text-muted);"></span>
    </div>
    <div class="slicer-list">${list.length ? rows : `<p class="slicer-empty" style="font-size:12.5px;color:var(--text-muted);">${escapeHtml(t('slicer.none') || 'No slicers configured yet.')}</p>`}</div>
    <details class="slicer-add" ${list.length ? '' : 'open'}>
      <summary style="cursor:pointer;font-size:12.5px;font-weight:600;margin-top:12px;">＋ ${escapeHtml(t('slicer.add') || 'Add a slicer')}</summary>
      <div style="margin-top:10px;">
        <label style="margin-top:0;">${escapeHtml(t('slicer.name_label') || 'Name (optional)')}</label>
        <input type="text" id="slicerName" placeholder="PrusaSlicer" style="font-size:12.5px;">
        <label style="margin-top:10px;">${escapeHtml(t('slicer.path_label') || 'Slicer program')}</label>
        <div style="display:flex;gap:8px;">
          <input type="text" id="slicerPath" placeholder="/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer" style="flex:1;font-size:12.5px;">
          <button id="btnSlicerBrowse" class="btn small" type="button">${escapeHtml(t('slicer.browse') || 'Browse…')}</button>
        </div>
        <label style="margin-top:10px;">${escapeHtml(t('slicer.args_label') || 'Slice command (advanced)')}</label>
        <textarea id="slicerArgs" rows="2" style="font-size:12px;font-family:var(--mono,monospace);" placeholder="--export-gcode -o {output} {model}"></textarea>
        <p style="font-size:11.5px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('slicer.args_help') || 'Used for slice-and-print. Leave blank to just open the file in the slicer.')}</p>
        <div style="display:flex;gap:8px;align-items:center;margin-top:8px;flex-wrap:wrap;">
          <span style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('slicer.preset') || 'Preset:')}</span>
          <button class="btn ghost small" type="button" data-slicer-preset="prusa">PrusaSlicer</button>
          <button class="btn ghost small" type="button" data-slicer-preset="orca">OrcaSlicer</button>
          <button id="btnAddSlicer" class="btn primary small" type="button">＋ ${escapeHtml(t('slicer.add') || 'Add slicer')}</button>
          <span id="slicerAddResult" style="font-size:12px;"></span>
        </div>
      </div>
    </details>`;

  el.querySelector('#btnDetectSlicers')?.addEventListener('click', async () => {
    const out = el.querySelector('#slicerDetectResult');
    if (out) { out.textContent = t('slicer.detecting') || 'Scanning for slicers…'; out.style.color = 'var(--text-muted)'; }
    const added = await detectAndMergeSlicers();
    if (out) {
      if (added > 0) { out.textContent = '✓ ' + (t('slicer.detected_n') || 'Added {n} slicer(s)').replace('{n}', added); out.style.color = 'var(--success)'; }
      else { out.textContent = (t('slicer.detected_none') || 'No new slicers found — add one manually below.'); out.style.color = 'var(--text-muted)'; }
    }
    if (added > 0) renderSlicerSettings();
  });

  el.querySelector('#btnSlicerBrowse')?.addEventListener('click', async () => {
    const p = await window.hubAPI?.pickFile?.({ filters: [{ name: 'Slicer program', extensions: ['*', 'exe', 'app', 'AppImage'] }] });
    if (p) {
      el.querySelector('#slicerPath').value = p;
      const nameEl = el.querySelector('#slicerName');
      if (nameEl && !nameEl.value.trim()) nameEl.value = KhaytSlicers.slicerDisplayName(p) || '';
    }
  });
  el.querySelectorAll('[data-slicer-preset]').forEach((b) =>
    b.addEventListener('click', () => { el.querySelector('#slicerArgs').value = PRESETS[b.dataset.slicerPreset] || ''; }));

  el.querySelector('#btnAddSlicer')?.addEventListener('click', () => {
    const path = el.querySelector('#slicerPath').value.trim();
    const res = el.querySelector('#slicerAddResult');
    if (!path) { if (res) { res.textContent = '✗ ' + (t('slicer.path_required') || 'Enter a slicer program path.'); res.style.color = 'var(--danger)'; } return; }
    const name = el.querySelector('#slicerName').value.trim() || KhaytSlicers.slicerDisplayName(path) || 'Slicer';
    const args = el.querySelector('#slicerArgs').value.trim();
    const entry = { id: uid('SL'), name, path, args };
    settings.slicers.push(entry);
    if (settings.slicers.length === 1) settings.defaultSlicerId = entry.id;
    syncDefaultSlicer();
    saveAll();
    renderSlicerSettings();
  });

  // Delegated list actions (default / remove / test).
  el.querySelector('.slicer-list')?.addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-act]');
    if (!btn) return;
    const id = btn.dataset.id || (btn.matches('[data-act="slicer-default"]') ? btn.value : null);
    if (btn.dataset.act === 'slicer-default') {
      settings.defaultSlicerId = btn.value;
      syncDefaultSlicer(); saveAll(); renderSlicerSettings();
    } else if (btn.dataset.act === 'slicer-remove') {
      settings.slicers = settings.slicers.filter((s) => s.id !== id);
      if (settings.defaultSlicerId === id) settings.defaultSlicerId = settings.slicers[0] ? settings.slicers[0].id : null;
      syncDefaultSlicer(); saveAll(); renderSlicerSettings();
    } else if (btn.dataset.act === 'slicer-test') {
      const sl = KhaytSlicers.getSlicer(settings, id);
      const out = el.querySelector(`[data-result="${CSS.escape(id)}"]`);
      if (out) { out.textContent = t('slicer.testing') || 'Testing…'; out.style.color = 'var(--text-muted)'; }
      try {
        const r = await window.hubAPI.sliceTest({ slicerPath: sl ? sl.path : '' });
        if (out) {
          if (r && r.ok) { out.textContent = '✓ ' + (t('slicer.test_ok') || 'Slicer works'); out.style.color = 'var(--success)'; }
          else { out.textContent = '✗ ' + (t('slicer.test_fail') || 'Could not run the slicer'); out.style.color = 'var(--danger)'; }
        }
      } catch (err) { if (out) { out.textContent = '✗ ' + (err.message || err); out.style.color = 'var(--danger)'; } }
    }
  });
}

// Team management modal (owner): list members, invite by email+role, remove.
async function openTeamModal() {
  const c = settings.cloud || {};
  if (!c.shopId || !c.token) { toast(t('intake.connect_first'), 'error'); return; }
  let members = [];
  try {
    const r = await window.hubAPI.cloudMembersList({ url: c.url, shopId: c.shopId, token: c.token });
    if (!r.ok) throw new Error(r.error);
    members = r.members || [];
  } catch (e) { toast('✗ ' + e.message, 'error'); return; }
  const roleLabel = (r) => t('role.' + r) || r;
  const rolesOpts = ['manager', 'operator', 'viewer'].map((r) => `<option value="${r}">${escapeHtml(roleLabel(r))}</option>`).join('');
  const rows = members.map((m) => `<div class="card" data-mem="${escapeHtml(m.email)}" style="display:flex;justify-content:space-between;align-items:center;padding:8px 12px;margin-bottom:6px;">
      <div><div style="font-size:13px;">${escapeHtml(m.email)}</div><div style="font-size:11px;color:var(--text-muted);">${escapeHtml(roleLabel(m.role))}${m.verified ? '' : ' · ' + escapeHtml(t('team.unverified') || 'unverified')}</div></div>
      ${m.role === 'owner' ? `<span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('team.owner') || 'owner')}</span>` : `<button class="btn danger small" data-rm="${escapeHtml(m.email)}">${escapeHtml(t('common.remove') || 'Remove')}</button>`}
    </div>`).join('');
  openFormModal({
    title: `👥 ${t('team.title') || 'Team'}`,
    noSave: true,
    bodyHtml: `<div id="teamList">${rows}</div>
      <hr style="border:none;border-top:1px solid var(--border-soft);margin:12px 0;">
      <label>${escapeHtml(t('team.invite_label') || 'Invite a member')}</label>
      <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
        <input id="invEmail" type="email" placeholder="name@email.com" style="flex:1;min-width:160px;">
        <select id="invRole">${rolesOpts}</select>
        <button id="invBtn" class="btn primary small" type="button">${escapeHtml(t('team.send_invite') || 'Send invite')}</button>
      </div>
      <p style="font-size:11.5px;color:var(--text-muted);margin-top:8px;">${escapeHtml(t('team.invite_hint') || 'They get an emailed code, choose “Join a team” in Khayt, and unlock with the shop’s shared sync passphrase.')}</p>
      <span id="teamResult" style="font-size:12px;"></span>`,
    onMount(modal) {
      modal.querySelectorAll('[data-rm]').forEach((b) => b.addEventListener('click', async () => {
        const email = b.dataset.rm;
        // Say what removal does and does not do. It revokes the token, so the
        // device cannot connect or receive anything further; it does NOT reach
        // back and erase what already synced there, because that data is
        // decrypted with a key that device already holds. The user's intuition
        // ("I removed them, so they're cut off") is wrong in exactly one way,
        // and implying otherwise would be worse than admitting the limit.
        // docs/KHAYT-3.0-ORG-DATA-KEY.md, threat-model table, revoked-device row.
        const removeQ = t('team.remove_q_access') || t('team.remove_q')
          || 'Remove {email} from the team?\n\nThey will not be able to connect or receive anything new. Data already synced to their device stays on it — removing them does not reach back and erase it.';
        if (!(await confirmModal(removeQ.replace('{email}', email), { danger: true }))) return;
        const r = await window.hubAPI.cloudMemberRemove({ url: c.url, shopId: c.shopId, token: c.token, email });
        if (r.ok) { modal.querySelector(`[data-mem="${CSS.escape(email)}"]`)?.remove(); toast(t('team.removed') || 'Member removed', 'success'); }
        else toast('✗ ' + (r.error || 'failed'), 'error');
      }));
      modal.querySelector('#invBtn')?.addEventListener('click', async () => {
        const email = modal.querySelector('#invEmail').value.trim();
        const role = modal.querySelector('#invRole').value;
        const res = modal.querySelector('#teamResult');
        if (!email) return;
        res.textContent = t('team.sending') || 'Sending…'; res.style.color = 'var(--text-muted)';
        const r = await window.hubAPI.cloudMemberInvite({ url: c.url, shopId: c.shopId, token: c.token, email, role });
        if (r.ok) { res.textContent = '✓ ' + (t('team.invite_sent') || 'Invite sent'); res.style.color = 'var(--success)'; modal.querySelector('#invEmail').value = ''; }
        else { res.textContent = '✗ ' + (r.error || 'failed'); res.style.color = 'var(--danger)'; }
      });
    },
  });
}

/* ── Organisations (multi-shop) ───────────────────────────────────────────────
 *
 * A shop chain has one owner and several branches, each with its own encrypted
 * store. Without this, opening four branches means remembering four passphrases.
 *
 * The organisation gets its OWN passphrase and its own recovery key. A branch's
 * passphrase and recovery key are untouched by joining or leaving — a recovery
 * key printed and filed years ago still opens that branch afterwards, which is
 * what makes joining safe to try. See docs/KHAYT-3.0-ORG-DATA-KEY.md.
 */
async function openOrgModal() {
  const c = settings.cloud || {};
  if (!c.shopId || !c.token) { toast(t('intake.connect_first'), 'error'); return; }

  let org = null;
  try {
    const r = await window.hubAPI.orgGet({ url: c.url, shopId: c.shopId, token: c.token });
    if (!r.ok) throw new Error(r.error);
    org = r.org;
  } catch (e) { toast('✗ ' + e.message, 'error'); return; }

  let members = [];
  if (org) {
    const m = await window.hubAPI.orgMembers({ url: c.url, shopId: c.shopId, token: c.token });
    if (m.ok) members = m.members || [];
  }

  const memberRows = members.map((id) => `<div style="font-size:12.5px;padding:3px 0;font-family:monospace;">
      ${escapeHtml(id)}${id === c.shopId ? ` <span style="color:var(--text-muted);font-family:inherit;">· ${escapeHtml(t('org.this_branch') || 'this branch')}</span>` : ''}
    </div>`).join('');

  const inOrg = !!org;
  openFormModal({
    title: `🏢 ${t('org.title') || 'Organisation'}`,
    noSave: true,
    bodyHtml: inOrg ? `
      <p style="font-size:13px;margin:0 0 8px;">${escapeHtml(t('org.in_org') || 'This branch is part of an organisation. One organisation passphrase opens every branch in it.')}</p>

      <label>${escapeHtml(t('org.branches') || 'Branches')}</label>
      <div style="max-height:150px;overflow:auto;border:1px solid var(--border-soft);border-radius:6px;padding:6px 8px;">${memberRows}</div>
      <div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap;">
        <button id="orgOverviewBtn" class="btn primary small" type="button">${escapeHtml(t('org.overview') || 'Across the branches')}</button>
        <button id="orgInviteBtn" class="btn small" type="button">${escapeHtml(t('org.add_branch') || 'Add a branch')}</button>
        <button id="orgLeaveBtn" class="btn danger small" type="button">${escapeHtml(t('org.leave') || 'Remove this branch')}</button>
      </div>
      <p style="font-size:11.5px;color:var(--text-muted);margin-top:8px;">${escapeHtml(t('org.leave_note') || 'Removing this branch only closes the organisation’s way in. This branch’s own passphrase and recovery key keep working exactly as before.')}</p>
      <span id="orgResult" style="font-size:12px;"></span>`
    : `
      <p style="font-size:13px;margin:0 0 8px;">${escapeHtml(t('org.intro') || 'Run several branches? An organisation lets one passphrase open all of them, so you don’t keep a separate one per branch.')}</p>
      <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px;">
        <button id="orgCreateBtn" class="btn primary small" type="button">${escapeHtml(t('org.create') || 'Create an organisation')}</button>
        <button id="orgJoinBtn" class="btn small" type="button">${escapeHtml(t('org.join') || 'Join with a code')}</button>
      </div>
      <p style="font-size:11.5px;color:var(--text-muted);">${escapeHtml(t('org.own_pass_note') || 'The organisation gets its own passphrase and its own recovery key. This branch keeps the passphrase and recovery key it already has.')}</p>
      <span id="orgResult" style="font-size:12px;"></span>`,
    onMount(modal) {
      const res = modal.querySelector('#orgResult');
      const say = (msg, colour) => { res.textContent = msg; res.style.color = colour; };

      modal.querySelector('#orgOverviewBtn')?.addEventListener('click', () => openOrgOverview(c));
      modal.querySelector('#orgCreateBtn')?.addEventListener('click', () => createOrganisation(c));
      modal.querySelector('#orgJoinBtn')?.addEventListener('click', () => joinOrganisation(c));

      modal.querySelector('#orgInviteBtn')?.addEventListener('click', async () => {
        say(t('org.minting') || 'Creating a code…', 'var(--text-muted)');
        const r = await window.hubAPI.orgInvite({ url: c.url, shopId: c.shopId, token: c.token });
        if (!r.ok) { say('✗ ' + (r.error || 'failed'), 'var(--danger)'); return; }
        say('', 'var(--text-muted)');
        showOrgJoinCodeModal(r.code, r.expiresInSeconds);
      });

      modal.querySelector('#orgLeaveBtn')?.addEventListener('click', async () => {
        if (!(await confirmModal(t('org.leave_q')
          || 'Remove this branch from the organisation?\n\nThe organisation passphrase will no longer open it. This branch’s own passphrase and recovery key are unaffected and keep working.',
          { danger: true }))) return;
        const r = await window.hubAPI.orgLeave({ url: c.url, shopId: c.shopId, token: c.token });
        if (!r.ok) { say('✗ ' + (r.error || 'failed'), 'var(--danger)'); return; }
        // Drop the org slot from this shop's keyset too, then save it back, so the
        // local copy matches what the server now believes.
        const stripped = await window.hubAPI.orgRemoveShop({ keyset: settings.cloud.keyset });
        if (stripped.ok) {
          settings.cloud.keyset = stripped.keyset;
          await putCloudKeyset({ url: c.url, shopId: c.shopId, token: c.token, keyset: stripped.keyset }, 'org leave');
          saveAll();
        }
        toast(t('org.left') || 'This branch is no longer in the organisation', 'success');
        // openFormModal keeps its close() private, and it does more than empty the
        // mount — it releases the focus trap and pops the Escape stack. Clicking
        // Close is the only way to get all of that from outside.
        modal.querySelector('[data-act="cancel"]')?.click();
      });
    },
  });
}

/**
 * What is happening at every branch.
 *
 * Needs the organisation passphrase, because that is the only thing that opens
 * the other branches — it is asked for here rather than held from setup, so the
 * key is not sitting in memory all day for a screen the owner opens occasionally.
 *
 * Branches are reported one by one. One that has never pushed, or is still
 * setting up, or that this key cannot open, says so on its own row and the others
 * still appear.
 */
async function openOrgOverview(c) {
  const st = await window.hubAPI.orgStatus();
  if (!st.unlocked) {
    const opened = await promptOrgUnlock(c);
    if (!opened) return;
    // The unlock modal closes itself right after its onSave resolves, and
    // openFormModal's close() empties the shared #modalMount. Opening the
    // overview on this tick would put it into that mount just in time to be
    // wiped — the same trap as the recovery-key modal, one level of indirection
    // deeper, which is why the static guard did not see it. Measured: without
    // the deferral, no modal at all.
    setTimeout(() => renderOrgOverview(c), 0);
    return;
  }
  renderOrgOverview(c);
}

/** Ask for the organisation passphrase and unlock for this session. */
function promptOrgUnlock(c) {
  return new Promise((resolve) => {
    openFormModal({
      title: t('org.unlock_title') || 'Open your branches',
      saveLabel: t('org.unlock_do') || 'Open',
      bodyHtml: `
        <p style="font-size:13px;">${escapeHtml(t('org.unlock_hint') || 'Enter the organisation passphrase to read your other branches. It is not stored — Khayt asks again next time.')}</p>
        <label>${escapeHtml(t('org.org_pass') || 'Organisation passphrase')}</label>
        <input type="password" id="orgUnlockPass" autocomplete="off">
        <p id="orgUnlockErr" style="color:var(--danger);font-size:12px;min-height:14px;margin:6px 0 0;"></p>`,
      onSave: async (modal) => {
        const err = modal.querySelector('#orgUnlockErr');
        const got = await window.hubAPI.orgGet({ url: c.url, shopId: c.shopId, token: c.token });
        if (!got.ok || !got.org) { err.textContent = got.error || (t('org.not_in_org') || 'This branch is not in an organisation'); return false; }
        const un = await window.hubAPI.orgUnlock({ orgKeyset: got.org.keyset, passphrase: modal.querySelector('#orgUnlockPass').value });
        if (!un.ok) { err.textContent = un.error || 'failed'; return false; }
        resolve(true);
        return true;
      },
    });
    // Closing without unlocking resolves false, so the caller stops rather than
    // opening an overview that would show nothing but errors.
    const mount = $('#modalMount');
    mount.querySelectorAll('[data-act="cancel"]').forEach((b) =>
      b.addEventListener('click', () => resolve(false)));
  });
}

/**
 * "3 late · 1 due today" for one branch, or nothing.
 *
 * Absent rather than zero when the main process was given no calendar day: a
 * silent "0 late" is a claim, and the one thing this view must not do is make
 * claims about branches it could not judge.
 */
function orgLateLine(su) {
  if (!su || typeof su.overdue !== 'number') return '';
  const bits = [];
  if (su.overdue > 0) {
    bits.push(`<strong style="color:var(--danger);">${escapeHtml(String(su.overdue))}</strong> ${escapeHtml(t('org.overdue') || 'late')}`);
  }
  if (su.dueToday > 0) {
    bits.push(`<strong>${escapeHtml(String(su.dueToday))}</strong> ${escapeHtml(t('org.due_today') || 'due today')}`);
  }
  if (!bits.length) return '';
  return `<div style="font-size:12px;margin-top:1px;">${bits.join(' · ')}</div>`;
}

/**
 * Money for one branch, in THAT branch's currency.
 *
 * fmtMoneyIn, not fmtPrice: fmtPrice formats in the currency of the shop you are
 * sitting in, which would label a branch's riyals as dollars and read as a
 * conversion that never happened.
 */
function orgMoneyLine(m) {
  if (!m || typeof m !== 'object') return '';
  const rev = fmtMoneyIn(m.revenue || 0, m.currency);
  const owed = m.outstanding > 0
    ? ` · <span style="color:var(--warning,#d97706);">${escapeHtml(fmtMoneyIn(m.outstanding, m.currency))} ${escapeHtml(t('org.outstanding') || 'outstanding')}</span>`
    : '';
  return `<div style="font-size:12px;margin-top:1px;">${escapeHtml(rev)} ${escapeHtml(t('org.earned') || 'earned')}${owed}</div>`;
}

/**
 * The chain's money, or an honest refusal.
 *
 * Branches on different base currencies are not added — see totalMoney in
 * lib/branch-summary.js. Naming the currencies is the useful half of saying no.
 */
function orgTotalMoneyLine(m) {
  if (!m || typeof m !== 'object') return '';
  if (m.mixed) {
    const list = (m.currencies || []).join(', ');
    return `<div style="font-size:11.5px;color:var(--text-muted);margin-top:4px;">${escapeHtml(
      (t('org.money_mixed') || 'Branches price in {list}, so there is no single chain total to show.').replace('{list}', list)
    )}</div>`;
  }
  const owed = m.outstanding > 0
    ? ` · <strong>${escapeHtml(fmtMoneyIn(m.outstanding, m.currency))}</strong> ${escapeHtml(t('org.outstanding') || 'outstanding')}`
    : '';
  const partial = m.partial
    ? ` <span style="color:var(--warning,#d97706);">${escapeHtml(t('org.money_partial') || '(some branches left out)')}</span>`
    : '';
  return `<div style="font-size:12.5px;margin-top:4px;">
    <strong>${escapeHtml(fmtMoneyIn(m.revenue || 0, m.currency))}</strong> ${escapeHtml(t('org.earned') || 'earned')}${owed}${partial}
  </div>`;
}

async function renderOrgOverview(c) {
  openFormModal({
    title: `🏢 ${t('org.overview') || 'Across the branches'}`,
    noSave: true,
    bodyHtml: `<p id="orgOvLoading" style="font-size:13px;color:var(--text-muted);">${escapeHtml(t('org.loading') || 'Reading your branches…')}</p>
      <div id="orgOvBody"></div>`,
    onMount: async (modal) => {
      // The day that decides what is late is the day of the person reading, not
      // whatever day it is where a branch happens to be. localDateStr is the
      // local calendar day — never toISOString(), which test/local-dates.test.js
      // fails on sight for exactly this class of bug.
      const r = await window.hubAPI.orgOverview({
        url: c.url, shopId: c.shopId, token: c.token, today: localDateStr(),
      });
      const loading = modal.querySelector('#orgOvLoading');
      const body = modal.querySelector('#orgOvBody');
      if (loading) loading.remove();
      if (!r.ok) {
        body.innerHTML = `<p style="color:var(--danger);font-size:13px;">✗ ${escapeHtml(r.error || 'failed')}</p>`;
        return;
      }
      const n = (v) => escapeHtml(String(v ?? 0));
      const rows = (r.branches || []).map((b) => {
        const name = escapeHtml(b.shopId) + (b.isSelf ? ` <span style="color:var(--text-muted);">· ${escapeHtml(t('org.this_branch') || 'this branch')}</span>` : '');
        if (b.error) {
          return `<div style="padding:8px 0;border-bottom:1px solid var(--border-soft);">
            <div style="font-family:monospace;font-size:12.5px;">${name}</div>
            <div style="font-size:12px;color:var(--danger);">✗ ${escapeHtml(b.error)}</div></div>`;
        }
        if (b.empty) {
          return `<div style="padding:8px 0;border-bottom:1px solid var(--border-soft);">
            <div style="font-family:monospace;font-size:12.5px;">${name}</div>
            <div style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('org.never_synced') || 'has not synced anything yet')}</div></div>`;
        }
        const su = b.summary || {};
        // localeTag() is what every other date in the app formats through, so a
        // branch timestamp reads the same way as a local one — and Arabic keeps
        // Western digits, which test/date-locale.test.js pins.
        const when = su.lastActivity
          ? new Date(su.lastActivity).toLocaleString(localeTag(), { dateStyle: 'medium', timeStyle: 'short' })
          : '—';
        return `<div style="padding:8px 0;border-bottom:1px solid var(--border-soft);">
          <div style="font-family:monospace;font-size:12.5px;">${name}</div>
          <div style="font-size:12.5px;margin-top:2px;">
            <strong>${n(su.inFlight)}</strong> ${escapeHtml(t('org.in_flight') || 'in flight')}
            · <strong>${n(su.printing)}</strong> ${escapeHtml(t('org.printing') || 'printing')}
            ${su.onHold ? ` · <strong>${n(su.onHold)}</strong> ${escapeHtml(t('org.on_hold') || 'on hold')}` : ''}
            ${su.quotes ? ` · <strong>${n(su.quotes)}</strong> ${escapeHtml(t('org.quotes') || 'quotes')}` : ''}
          </div>
          ${orgLateLine(su)}
          ${orgMoneyLine(su.money)}
          <div style="font-size:11.5px;color:var(--text-muted);">${escapeHtml(t('org.last_activity') || 'last change')}: ${escapeHtml(when)}</div>
        </div>`;
      }).join('');

      const tot = r.total || {};
      const unreachable = (tot.branches || 0) - (tot.reachable || 0);
      body.innerHTML = `
        <div style="padding:8px 10px;background:var(--bg-soft,rgba(127,127,127,.08));border-radius:6px;margin-bottom:8px;font-size:13px;">
          <strong>${n(tot.inFlight)}</strong> ${escapeHtml(t('org.in_flight') || 'in flight')}
          · <strong>${n(tot.printing)}</strong> ${escapeHtml(t('org.printing') || 'printing')}
          ${escapeHtml(((tot.reachable === 1 ? t('org.across_one') : t('org.across_many'))
              || (tot.reachable === 1 ? 'across one branch' : 'across {n} branches')).replace('{n}', String(tot.reachable || 0)))}
          ${tot.overdue > 0 ? `<div style="font-size:12.5px;margin-top:2px;"><strong style="color:var(--danger);">${n(tot.overdue)}</strong> ${escapeHtml(t('org.overdue') || 'late')}${tot.dueToday > 0 ? ` · <strong>${n(tot.dueToday)}</strong> ${escapeHtml(t('org.due_today') || 'due today')}` : ''}</div>` : ''}
          ${orgTotalMoneyLine(tot.money)}
        </div>
        ${rows}
        ${unreachable > 0 ? `<p style="font-size:11.5px;color:var(--warning,#d97706);margin-top:8px;">${escapeHtml((t('org.n_unreadable') || '{n} branch(es) could not be read — the totals above leave them out.').replace('{n}', String(unreachable)))}</p>` : ''}
        <p style="font-size:11.5px;color:var(--text-muted);margin-top:8px;">${escapeHtml(t('org.from_last_sync') || 'These figures come from each branch’s last sync, not from its screen right now.')}</p>`;
    },
  });
}

/** Show a join code once, for pasting into the other branch's Khayt. */
function showOrgJoinCodeModal(code, expiresInSeconds) {
  const hours = Math.max(1, Math.round((expiresInSeconds || 86400) / 3600));
  openFormModal({
    title: t('org.code_title') || 'Add a branch',
    saveLabel: t('common.done') || 'Done',
    bodyHtml: `
      <p style="font-size:13px;">${escapeHtml((t('org.code_hint') || 'On the other branch’s computer, open Khayt Cloud → Organisation → “Join with a code” and enter this. It works once, and expires in {h} hours.').replace('{h}', String(hours)))}</p>
      <input type="text" readonly value="${escapeHtml(code)}" style="font-family:monospace;font-size:15px;letter-spacing:1px;" onclick="this.select()">`,
    onSave: () => {},
  });
}

/** Create the organisation: its own passphrase, its own recovery key, and this
 *  branch enrolled with the passphrase it already has. */
function createOrganisation(c) {
  openFormModal({
    title: t('org.create') || 'Create an organisation',
    saveLabel: t('org.create_do') || 'Create',
    bodyHtml: `
      <label>${escapeHtml(t('org.new_pass') || 'Organisation passphrase')}</label>
      <input type="password" id="orgPass" placeholder="${escapeHtml(t('org.new_pass_ph') || 'opens every branch — never uploaded')}">
      <label style="margin-top:8px;">${escapeHtml(t('org.new_pass_confirm') || 'Confirm')}</label>
      <input type="password" id="orgPass2">
      <label style="margin-top:8px;">${escapeHtml(t('org.this_pass') || 'This branch’s sync passphrase')}</label>
      <input type="password" id="orgShopPass" placeholder="${escapeHtml(t('org.this_pass_ph') || 'so this branch can be added to the organisation')}">
      <p style="font-size:11.5px;color:var(--text-muted);margin:8px 0 0;">${escapeHtml(t('org.create_note') || 'This branch keeps its own passphrase and recovery key. The organisation passphrase is a second way in, not a replacement.')}</p>
      <p id="orgErr" style="color:var(--danger);font-size:12px;min-height:14px;margin:6px 0 0;"></p>`,
    onSave: async (modal) => {
      const pass = modal.querySelector('#orgPass').value;
      const pass2 = modal.querySelector('#orgPass2').value;
      const shopPass = modal.querySelector('#orgShopPass').value;
      const err = modal.querySelector('#orgErr');
      if (!pass || pass.length < 8) { err.textContent = t('org.pass_short') || 'Use at least 8 characters'; return false; }
      if (pass !== pass2) { err.textContent = t('org.pass_mismatch') || 'The two passphrases do not match'; return false; }
      if (!shopPass) { err.textContent = t('org.need_shop_pass') || 'Enter this branch’s sync passphrase'; return false; }

      const ks = await window.hubAPI.orgCreateKeyset(pass);
      if (!ks.ok) { err.textContent = ks.error || 'failed'; return false; }

      // Enrol this branch BEFORE telling the server the org exists: if the
      // passphrase is wrong we stop here, with nothing created.
      const enrol = await window.hubAPI.orgEnrolShop({ keyset: settings.cloud.keyset, passphrase: shopPass });
      if (!enrol.ok) { err.textContent = t('cloud.wrong_pass') || 'Wrong sync passphrase for this branch'; return false; }

      const put = await window.hubAPI.orgPut({ url: c.url, shopId: c.shopId, token: c.token, orgId: ks.orgKeyset.orgId, keyset: ks.orgKeyset });
      if (!put.ok) { err.textContent = put.error || 'failed'; return false; }

      settings.cloud.keyset = enrol.keyset;
      await putCloudKeyset({ url: c.url, shopId: c.shopId, token: c.token, keyset: enrol.keyset }, 'org enrol');
      saveAll();
      renderCloudSettings();
      // openFormModal shares one #modalMount and its close() empties it, so a
      // modal opened from inside onSave is destroyed the instant this one closes.
      // Returning true closes this one — hence the deferral. The organisation
      // recovery key is shown exactly ONCE and cannot be re-issued, so losing it
      // to a wiped mount would cost the owner the only spare way into every
      // branch. Verified by running: without the defer, no modal appeared at all.
      setTimeout(() => showOrgRecoveryKeyModal(ks.recoveryKey), 0);
      return true;
    },
  });
}

/** Join an existing organisation with a code from another branch. */
function joinOrganisation(c) {
  openFormModal({
    title: t('org.join') || 'Join with a code',
    saveLabel: t('org.join_do') || 'Join',
    bodyHtml: `
      <label>${escapeHtml(t('org.code') || 'Join code')}</label>
      <input type="text" id="orgJoinCode" autocomplete="off" style="font-family:monospace;text-transform:uppercase;letter-spacing:1px;">
      <label style="margin-top:8px;">${escapeHtml(t('org.org_pass') || 'Organisation passphrase')}</label>
      <input type="password" id="orgJoinPass">
      <label style="margin-top:8px;">${escapeHtml(t('org.this_pass') || 'This branch’s sync passphrase')}</label>
      <input type="password" id="orgJoinShopPass" placeholder="${escapeHtml(t('org.this_pass_ph') || 'so this branch can be added to the organisation')}">
      <p id="orgJoinErr" style="color:var(--danger);font-size:12px;min-height:14px;margin:6px 0 0;"></p>`,
    onSave: async (modal) => {
      const code = modal.querySelector('#orgJoinCode').value.trim().toUpperCase();
      const orgPass = modal.querySelector('#orgJoinPass').value;
      const shopPass = modal.querySelector('#orgJoinShopPass').value;
      const err = modal.querySelector('#orgJoinErr');
      if (!code) { err.textContent = t('org.need_code') || 'Enter the join code'; return false; }

      const joined = await window.hubAPI.orgJoin({ url: c.url, shopId: c.shopId, token: c.token, code });
      if (!joined.ok) { err.textContent = joined.error || 'failed'; return false; }

      // The code got us the wrapped org keyset; the passphrase is what opens it.
      const un = await window.hubAPI.orgUnlock({ orgKeyset: joined.keyset, passphrase: orgPass });
      if (!un.ok) { err.textContent = un.error || 'failed'; return false; }

      const enrol = await window.hubAPI.orgEnrolShop({ keyset: settings.cloud.keyset, passphrase: shopPass });
      if (!enrol.ok) { err.textContent = t('cloud.wrong_pass') || 'Wrong sync passphrase for this branch'; return false; }

      settings.cloud.keyset = enrol.keyset;
      await putCloudKeyset({ url: c.url, shopId: c.shopId, token: c.token, keyset: enrol.keyset }, 'org enrol');
      saveAll();
      toast(t('org.joined') || 'This branch joined the organisation', 'success');
      renderCloudSettings();
      return true;
    },
  });
}

/** The org recovery key — one for the whole organisation, shown once. */
function showOrgRecoveryKeyModal(recoveryKey) {
  openFormModal({
    title: t('org.recovery_title') || 'Save the organisation recovery key',
    saveLabel: t('cloud.recovery_saved') || 'I saved it',
    bodyHtml: `
      <p style="font-size:13px;">${escapeHtml(t('org.recovery_hint') || 'This opens the organisation if the organisation passphrase is forgotten. There is one for the whole organisation, and it is shown ONCE. Each branch also keeps its own recovery key, which still works.')}</p>
      <input type="text" readonly value="${escapeHtml(recoveryKey)}" style="font-family:monospace;font-size:13px;" onclick="this.select()">`,
    onSave: () => {},
  });
}

// Storefront modal (owner): publish the product catalog as a public shop page,
// copy the link, or unpublish. Customer orders arrive in "Order requests".
/* ── Publishing a picture at a size worth looking at ─────────────────────────
 *
 * A published photo was the 240px grid thumbnail. That is the right size for
 * the product grid, and it was also the HERO IMAGE on the storefront's product
 * page, where a 240px picture of a printed part is visibly poor next to
 * anything else on the page.
 *
 * The full picture was never lost. It is written to disk on save — `img.path`,
 * around 1600px — and nothing had ever read it back. So this reads it, resizes
 * it once to a web size, and hands it to storefrontPhotos(). The size and the
 * quality live in lib/product-images.js, next to the catalogue budget that is
 * the real constraint on them.
 */

/* Keyed by file name, which carries the image id: a replaced picture is written
 * under a new name, so a stale entry cannot be served. A shop publishes far more
 * often than it re-photographs, and this is the expensive part of a publish. */
const heroPhotoCache = new Map();

/**
 * A data URL's bytes, as something FileReader will take.
 *
 * Decoded by hand rather than with `fetch(dataUrl).blob()`, which is the obvious
 * one-liner and is REFUSED by the renderer's content-security policy — `Failed
 * to fetch`, at publish time, on a path no unit test can reach.
 */
function dataUrlToBlob(dataUrl) {
  const m = /^data:([^;,]+);base64,([\s\S]*)$/.exec(String(dataUrl || ''));
  if (!m) return null;
  const bin = atob(m[2]);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new Blob([bytes], { type: m[1] });
}

/**
 * A web-sized rendition of one product image, or '' when there is nothing to read.
 *
 * '' is cached as readily as a picture: a product saved before per-image files
 * has no `path`, and retrying that on every publish would be a guaranteed miss
 * every time. The caller falls back to the thumbnail, which is the right answer
 * for those products and cannot be bettered without the shop re-adding the photo.
 */
async function heroPhotoFor(img) {
  const name = img && img.path;
  if (!name || !window.hubAPI?.loadProductImage) return '';
  if (heroPhotoCache.has(name)) return heroPhotoCache.get(name);
  let out = '';
  try {
    const full = await window.hubAPI.loadProductImage(name);
    const blob = /^data:image\//.test(String(full || '')) ? dataUrlToBlob(full) : null;
    if (blob) out = await resizeImage(blob, KhaytProductImages.HERO_MAX_DIM, KhaytProductImages.HERO_QUALITY);
  } catch (err) {
    // One unreadable file costs that picture its resolution, never the publish.
    console.error('hero photo failed', name, err);
  }
  heroPhotoCache.set(name, out);
  return out;
}

/** Every product image resized once, keyed by file name, before a catalogue is built. */
async function loadHeroPhotos(products) {
  const map = new Map();
  for (const p of (products || [])) {
    for (const img of KhaytProductImages.normalise(p).images) {
      if (!img.path || map.has(img.path)) continue;
      map.set(img.path, await heroPhotoFor(img));
    }
  }
  return map;
}

async function openStorefrontModal() {
  const c = settings.cloud || {};
  if (!c.shopId || !c.token) { toast(t('intake.connect_first'), 'error'); return; }
  const baseUrl = String(c.url || '').replace(/\/+$/, '');
  const link = `${baseUrl}/shop/${c.shopId}`;
  const reviewLink = `${baseUrl}/review/${c.shopId}`;
  const sf = settings.storefront || (settings.storefront = { prices: {}, depositPct: 0, payUrl: '', note: '' });
  if (!sf.prices) sf.prices = {};
  if (!sf.categories) sf.categories = {};
  if (!sf.soldOut) sf.soldOut = {};
  if (!sf.options) sf.options = {};
  /* How many of each product are printed, boxed and ready to post, and when
   * the shop last counted them. Two maps rather than one so an older build,
   * which merges whole records, cannot half-write a count with someone else's
   * timestamp attached to it. */
  if (!sf.stockQty) sf.stockQty = {};
  if (!sf.stockCountedAt) sf.stockCountedAt = {};
  // Parse "Color: Black, White; Size: S, M" → [{name, values}]; ≤5 groups, ≤12 vals.
  const parseOptionGroups = (raw) => String(raw || '').split(';').map((seg) => {
    const ci = seg.indexOf(':');
    if (ci < 0) return null;
    const name = seg.slice(0, ci).trim().slice(0, 40);
    const values = seg.slice(ci + 1).split(',').map((v) => v.trim().slice(0, 40)).filter(Boolean).slice(0, 12);
    return (name && values.length) ? { name, values } : null;
  }).filter(Boolean).slice(0, 5);
  const cur = settings.currency || 'SAR';
  const pubProducts = (products || []).slice(0, 60).filter((p) => (p.nameEn || (typeof localName === 'function' ? localName(p) : '') || '').trim());
  const priceRows = pubProducts.map((p) => {
    const nm = (p.nameEn || (typeof localName === 'function' ? localName(p) : '') || '').trim();
    return `<div style="display:flex;gap:6px;align-items:center;margin-bottom:6px;flex-wrap:wrap;">
      <span style="flex:1;min-width:90px;font-size:12.5px;">${escapeHtml(nm)}</span>
      <input class="sfPrice" data-pid="${escapeHtml(p.id)}" aria-label="${escapeHtml(nm || p.id)} — ${escapeHtml(cur)}" type="number" min="0" step="0.01" inputmode="decimal" placeholder="${escapeHtml(p.price != null ? String(p.price) : (p.basePrice != null ? String(p.basePrice) : '0'))}" value="${escapeHtml(sf.prices[p.id] != null ? String(sf.prices[p.id]) : '')}" style="width:72px;font-size:12.5px;text-align:right;" title="${escapeHtml(cur)}">
      <input class="sfCat" data-pid="${escapeHtml(p.id)}" aria-label="${escapeHtml(nm || p.id)} — ${escapeHtml(t('store.category_ph') || 'category')}" type="text" maxlength="60" placeholder="${escapeHtml((typeof productCategoryOf === 'function' ? productCategoryOf(p) : (p.category || '')) || t('store.category_ph') || 'category')}" value="${escapeHtml(sf.categories[p.id] || '')}" list="sfCatList" style="width:96px;font-size:12px;">
      <label style="font-size:11px;color:var(--text-muted);display:flex;align-items:center;gap:3px;cursor:pointer;" title="${escapeHtml(t('store.sold_out') || 'Sold out')}">
        <input class="sfSold" data-pid="${escapeHtml(p.id)}" aria-label="${escapeHtml(nm || p.id)} — ${escapeHtml(t('store.sold_out') || 'Sold out')}" type="checkbox" style="width:auto;margin:0;" ${sf.soldOut[p.id] ? 'checked' : ''}>${escapeHtml(t('store.sold_out') || 'Sold out')}
      </label>
      <input class="sfStock" data-pid="${escapeHtml(p.id)}" aria-label="${escapeHtml(nm || p.id)} — ${escapeHtml(t('store.stock_qty'))}" type="number" min="0" step="1" inputmode="numeric" placeholder="${escapeHtml(t('store.stock_qty'))}" value="${escapeHtml(sf.stockQty[p.id] != null ? String(sf.stockQty[p.id]) : '')}" title="${escapeHtml(t('store.stock_hint'))}" style="width:64px;font-size:12.5px;text-align:right;">
      <input class="sfOpts" data-pid="${escapeHtml(p.id)}" type="text" maxlength="240" placeholder="${escapeHtml(t('store.options_ph') || 'Options — Color: Black, White; Size: S, M')}" value="${escapeHtml(sf.options[p.id] || '')}" title="${escapeHtml(t('store.options_hint') || 'Optional product choices. Format: Group: value, value; Group: value')}" style="flex-basis:100%;font-size:12px;">
    </div>`;
  }).join('') || `<p style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('store.no_products') || 'Add products to your catalog first')}</p>`;
  /* Offer the categories the CATALOGUE already uses, not only the ones typed
   * into this dialog before — otherwise the box that is meant to stop drift is
   * the one place that cannot see it. */
  const catList = [...new Set(
    Object.values(sf.categories || {}).filter(Boolean)
      .concat(typeof organiseKnown === 'function' ? organiseKnown('category') : []),
  )];
  openFormModal({
    title: `🏬 ${t('store.title') || 'Storefront'}`,
    noSave: true,
    bodyHtml: `
      <p style="font-size:12.5px;color:var(--text-muted);margin:0 0 12px;">${escapeHtml(t('store.intro') || 'Publish your product catalog as a public page customers can browse. Their selections arrive in Order requests as draft quotes.')}</p>
      <label>${escapeHtml(t('store.note_label') || 'Shop note (optional)')}</label>
      <input id="storeNote" type="text" maxlength="200" placeholder="${escapeHtml(t('store.note_ph') || 'e.g. Lead time ~3 days · Riyadh pickup')}" value="${escapeHtml(sf.note || '')}">
      <label style="margin-top:14px;">${escapeHtml(t('store.prices_label') || 'Prices (leave blank to hide)')}</label>
      <div style="max-height:220px;overflow-y:auto;border:1px solid var(--border-soft);border-radius:8px;padding:8px;">${priceRows}</div>
      <datalist id="sfCatList">${catList.map((c) => `<option value="${escapeHtml(c)}">`).join('')}</datalist>
      <div class="inline-pair" style="margin-top:12px;">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('store.lead_time') || 'Lead time (optional)')}</label>
          <input id="storeLead" type="text" maxlength="80" placeholder="${escapeHtml(t('store.lead_ph') || 'e.g. 3–5 days')}" value="${escapeHtml(sf.leadTime || '')}">
        </div>
        <div>
          <label style="margin-top:0;">${escapeHtml(t('store.min_order') || 'Minimum order')}</label>
          <input id="storeMinOrder" type="number" min="0" step="0.01" inputmode="decimal" placeholder="0" value="${escapeHtml(sf.minOrder ? String(sf.minOrder) : '')}">
        </div>
      </div>
      <div class="inline-pair" style="margin-top:12px;">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('store.deposit_pct') || 'Deposit %')}</label>
          <input id="storeDeposit" type="number" min="0" max="100" step="1" inputmode="numeric" placeholder="0" value="${escapeHtml(sf.depositPct ? String(sf.depositPct) : '')}">
        </div>
        <div>
          <label style="margin-top:0;">${escapeHtml(t('store.pay_url') || 'Payment link')}</label>
          <input id="storePayUrl" type="url" placeholder="https://pay…/{amount}" value="${escapeHtml(sf.payUrl || '')}">
        </div>
      </div>
      <p style="font-size:11px;color:var(--text-muted);margin-top:4px;">${escapeHtml(t('store.pay_url_hint') || 'Paste a payment link from any provider; use {amount} or {total} where the figure goes. The customer pays there before sending the order.')}</p>
      <div class="inline-pair" style="margin-top:12px;">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('store.tax_rate') || 'Tax / VAT %')}</label>
          <input id="storeTax" type="number" min="0" max="100" step="0.01" inputmode="decimal" placeholder="0" value="${escapeHtml(sf.taxRate ? String(sf.taxRate) : '')}">
        </div>
        <div></div>
      </div>
      <label style="margin-top:14px;">${escapeHtml(t('store.shipping_label') || 'Shipping methods')}</label>
      <div id="sfShipping"></div>
      <button id="sfAddShip" class="btn ghost small" type="button" style="margin-top:6px;">+ ${escapeHtml(t('store.add_shipping') || 'Add method')}</button>
      <label style="margin-top:14px;">${escapeHtml(t('store.promos_label') || 'Promo codes')}</label>
      <div id="sfPromos"></div>
      <button id="sfAddPromo" class="btn ghost small" type="button" style="margin-top:6px;">+ ${escapeHtml(t('store.add_promo') || 'Add code')}</button>
      <label style="display:flex;align-items:center;gap:8px;margin-top:12px;cursor:pointer;">
        <input type="checkbox" id="storePhotos" checked style="width:auto;"> ${escapeHtml(t('store.include_photos') || 'Include product photos')}
      </label>
      <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:16px;">
        <button id="storePublish" class="btn primary small" type="button">${escapeHtml(t('store.publish') || 'Publish')} (${pubProducts.length})</button>
        <button id="storeCopy" class="btn ghost small" type="button">${escapeHtml(t('store.copy_link') || 'Copy link')}</button>
        <button id="storeUnpublish" class="btn danger small" type="button">${escapeHtml(t('store.unpublish') || 'Unpublish')}</button>
      </div>
      <div style="margin-top:10px;font-size:11.5px;color:var(--text-muted);word-break:break-all;">${escapeHtml(link)}</div>
      <span id="storeResult" style="font-size:12px;display:block;margin-top:8px;"></span>
      <hr style="border:none;border-top:1px solid var(--border-soft);margin:14px 0;">
      <label style="margin-top:0;">${escapeHtml(t('store.insights') || 'Storefront insights')}</label>
      <div id="storeInsights" style="font-size:12.5px;color:var(--text-muted);margin-top:4px;">${escapeHtml(t('common.loading') || '…')}</div>
      <hr style="border:none;border-top:1px solid var(--border-soft);margin:14px 0;">
      <label style="margin-top:0;">${escapeHtml(t('store.reviews') || 'Customer reviews')} <span id="storeRating" style="color:var(--accent);font-weight:600;"></span></label>
      <p style="font-size:11.5px;color:var(--text-muted);margin:2px 0 6px;">${escapeHtml(t('store.reviews_hint') || 'Share this link after an order to collect a rating; the average shows on your storefront.')}</p>
      <button id="storeReviewCopy" class="btn ghost small" type="button">${escapeHtml(t('store.review_link') || 'Copy review link')}</button>
      <div style="margin-top:6px;font-size:11.5px;color:var(--text-muted);word-break:break-all;">${escapeHtml(reviewLink)}</div>
      <div id="storeReviewList" style="margin-top:10px;font-size:12px;"></div>`,
    onMount(modal) {
      /* Remember that a human TOUCHED a stock box, not merely that the number
       * ended up different.
       *
       * The published stockCountedAt is what tells a storefront to re-apply a
       * count over what it has sold since. Stamping it whenever the number
       * changes sounds equivalent and is not: a shop that sells three, prints
       * three and counts twenty again types the same figure, and a
       * change-comparison reads that as nothing having happened — leaving the
       * storefront on its own decremented total and under-selling the shelf
       * from then on. That case is the entire reason the timestamp exists, so
       * it has to survive it.
       *
       * Typing fires `input` even when the result is identical, so touching the
       * box is the signal. Merely opening this dialog to edit a price is not,
       * which is the other half of it: that must NOT re-assert a count. */
      modal.querySelectorAll('.sfStock').forEach((inp) => {
        inp.addEventListener('input', () => { inp.dataset.counted = '1'; });
      });
      const res = modal.querySelector('#storeResult');
      const setRes = (m, ok) => { res.textContent = m; res.style.color = ok ? 'var(--success)' : 'var(--danger)'; };
      // Promo-code editor (rows of code / type / value / expiry / max uses).
      const promosEl = modal.querySelector('#sfPromos');
      const promoRow = (p) => {
        p = p || { code: '', type: 'pct', value: '', expires: '', maxUses: '' };
        const row = document.createElement('div');
        row.className = 'sfPromoRow';
        row.style.cssText = 'display:flex;gap:6px;align-items:center;margin-bottom:6px;flex-wrap:wrap;';
        row.innerHTML = `
          <input class="pCode" type="text" maxlength="32" placeholder="${escapeHtml(t('store.promo_code') || 'CODE')}" value="${escapeHtml(p.code || '')}" style="flex:1;min-width:90px;font-size:12px;text-transform:uppercase;">
          <select class="pType" style="font-size:12px;width:auto;"><option value="pct"${p.type !== 'fixed' ? ' selected' : ''}>%</option><option value="fixed"${p.type === 'fixed' ? ' selected' : ''}>${escapeHtml(cur)}</option></select>
          <input class="pValue" type="number" min="0" step="0.01" placeholder="0" value="${escapeHtml(p.value != null ? String(p.value) : '')}" style="width:62px;font-size:12px;">
          <input class="pExpires" type="date" value="${escapeHtml(p.expires || '')}" title="${escapeHtml(t('store.promo_expires') || 'Expires (optional)')}" style="width:130px;font-size:12px;">
          <input class="pMax" type="number" min="0" step="1" placeholder="∞" value="${escapeHtml(p.maxUses ? String(p.maxUses) : '')}" title="${escapeHtml(t('store.promo_max') || 'Max uses (blank = unlimited)')}" style="width:54px;font-size:12px;">
          <button type="button" class="btn danger small pDel" style="font-size:11px;" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">✕</button>`;
        row.querySelector('.pDel').addEventListener('click', () => row.remove());
        return row;
      };
      (sf.promos || []).forEach((p) => promosEl.appendChild(promoRow(p)));
      modal.querySelector('#sfAddPromo').addEventListener('click', () => promosEl.appendChild(promoRow()));
      const collectPromos = () => Array.from(promosEl.querySelectorAll('.sfPromoRow')).map((r) => ({
        code: r.querySelector('.pCode').value.trim().toUpperCase(),
        type: r.querySelector('.pType').value,
        value: num(r.querySelector('.pValue').value, 0),
        expires: r.querySelector('.pExpires').value || '',
        maxUses: parseInt(r.querySelector('.pMax').value, 10) || 0,
      })).filter((p) => p.code && p.value > 0);
      // Shipping methods (label + price; ≤8). Blank-priced rows are free.
      const shipEl = modal.querySelector('#sfShipping');
      const shipRow = (m) => {
        m = m || { label: '', price: '' };
        const row = document.createElement('div');
        row.className = 'sfShipRow';
        row.style.cssText = 'display:flex;gap:6px;align-items:center;margin-bottom:6px;';
        row.innerHTML = `
          <input class="shLabel" type="text" maxlength="60" placeholder="${escapeHtml(t('store.ship_label_ph') || 'e.g. Courier, Pickup')}" value="${escapeHtml(m.label || '')}" style="flex:1;font-size:12.5px;">
          <input class="shPrice" type="number" min="0" step="0.01" placeholder="0" value="${escapeHtml(m.price != null && m.price !== '' ? String(m.price) : '')}" style="width:80px;font-size:12.5px;text-align:right;" title="${escapeHtml(cur)}">
          <button type="button" class="btn danger small shDel" style="font-size:11px;" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">✕</button>`;
        row.querySelector('.shDel').addEventListener('click', () => row.remove());
        return row;
      };
      (sf.shipping || []).forEach((m) => shipEl.appendChild(shipRow(m)));
      modal.querySelector('#sfAddShip').addEventListener('click', () => shipEl.appendChild(shipRow()));
      const collectShipping = () => Array.from(shipEl.querySelectorAll('.sfShipRow')).map((r) => ({
        label: r.querySelector('.shLabel').value.trim(),
        price: Math.max(0, num(r.querySelector('.shPrice').value, 0)),
      })).filter((m) => m.label).slice(0, 8);
      // Persist the owner's storefront config (prices, deposit, pay link, note, promos).
      const captureConfig = () => {
        const prices = {}, categories = {}, soldOut = {}, options = {};
        modal.querySelectorAll('.sfPrice').forEach((inp) => { const v = inp.value.trim(); if (v) prices[inp.dataset.pid] = v; });
        modal.querySelectorAll('.sfCat').forEach((inp) => { const v = inp.value.trim(); if (v) categories[inp.dataset.pid] = v; });
        modal.querySelectorAll('.sfSold').forEach((inp) => { if (inp.checked) soldOut[inp.dataset.pid] = true; });
        modal.querySelectorAll('.sfOpts').forEach((inp) => { const v = inp.value.trim(); if (v) options[inp.dataset.pid] = v; });

        /* The batch count, and when it was taken.
         *
         * EMPTY IS NOT ZERO. Empty means the shop does not stock this piece —
         * it is made to order, and a storefront must leave its inventory alone
         * entirely. Zero means the shop stocks it and the batch has sold out,
         * which is a state it reverses next week. Reading one as the other
         * moves a customer's quoted date by weeks in whichever direction is
         * wrong, so the empty string is checked before the number is. */
        const stockQty = {}, stockCountedAt = {};
        modal.querySelectorAll('.sfStock').forEach((inp) => {
          const raw = inp.value.trim();
          if (raw === '') return;
          const n = Number(raw);
          if (!Number.isInteger(n) || n < 0) return;
          const pid = inp.dataset.pid;
          stockQty[pid] = n;
          // Touched in this dialog, or never dated before. Otherwise the shop
          // opened the dialog for some other reason and the previous count
          // stands — re-dating it would re-apply the number downstream and
          // undo the sales since.
          stockCountedAt[pid] = (inp.dataset.counted === '1' || !sf.stockCountedAt[pid])
            ? new Date().toISOString()
            : sf.stockCountedAt[pid];
        });

        sf.prices = prices; sf.categories = categories; sf.soldOut = soldOut; sf.options = options;
        sf.stockQty = stockQty; sf.stockCountedAt = stockCountedAt;
        sf.depositPct = Math.max(0, Math.min(100, num(modal.querySelector('#storeDeposit').value, 0)));
        sf.minOrder = Math.max(0, num(modal.querySelector('#storeMinOrder').value, 0));
        sf.taxRate = Math.max(0, Math.min(100, num(modal.querySelector('#storeTax').value, 0)));
        sf.leadTime = modal.querySelector('#storeLead').value.trim();
        sf.payUrl = modal.querySelector('#storePayUrl').value.trim();
        sf.note = modal.querySelector('#storeNote').value.trim();
        sf.promos = collectPromos();
        sf.shipping = collectShipping();
        settings.storefront = sf;
        saveAll();
      };
      const buildCatalog = async (withPhotos) => {
        /* Read the form BEFORE the await. Resizing every picture takes long
         * enough to type in, and a field edited during it would otherwise be
         * captured into a catalogue the shop thought it had already described. */
        captureConfig();
        const heroes = withPhotos ? await loadHeroPhotos(pubProducts) : null;
        const payload = {
          shopName: (shopField('biz') || 'Khayt').trim(),
          currency: cur,
          lang: (typeof i18n !== 'undefined' && i18n.current) || 'en',
          /* The languages this catalogue is WRITTEN in, so the storefront page
           * can offer them. It used to be able to show English or Arabic and
           * nothing else — hard-coded, with `lang === 'ar' ? nameAr : name` —
           * so a German-and-French shop published a catalogue its own customers
           * could only read half of. */
          langs: KhaytContentLanguages.contentLangs(settings),
          note: sf.note,
          leadTime: sf.leadTime || '',
          minOrder: sf.minOrder || 0,
          depositPct: sf.depositPct || 0,
          taxRate: sf.taxRate || 0,
          shipping: sf.shipping || [],
          payUrl: /^https?:\/\//i.test(sf.payUrl) ? sf.payUrl : '',
          promos: sf.promos || [],
          items: pubProducts.map((p) => {
            /* Read through the content-language model rather than the two
             * hard-coded fields: a shop writing Turkish or German published a
             * blank name and no description at all, because the storefront only
             * knew about `nameEn`, `nameAr` and a single unsuffixed
             * `description`. `name`/`nameAr` stay in the payload because the
             * published storefront page reads exactly those. */
            const CL = KhaytContentLanguages;
            const langs = CL.contentLangs(settings);
            const it = {
              id: p.id,
              name: CL.read(p, 'name', langs[0], settings).trim(),
              nameAr: (p.nameAr || '').trim(),
              desc: CL.read(p, 'description', langs[0], settings).trim(),
            };
            // The second language, where the shop keeps one, so a storefront
            // can show a customer the listing in their own.
            if (langs[1]) {
              const alt = CL.read(p, 'name', langs[1], settings).trim();
              const altDesc = CL.read(p, 'description', langs[1], settings).trim();
              if (alt || altDesc) it.alt = { lang: langs[1], name: alt, desc: altDesc };
            }
            /* The catalogue's own price is the price. A storefront entry is an
             * OVERRIDE, not the only source.
             *
             * This read `sf.prices[p.id]` and nothing else, so a shop that had
             * already priced every product in the catalogue — cost, margin,
             * rounding, the lot — published a storefront where every item cost
             * nothing, and had to type all of it a second time into a different
             * form. The product feeds other platforms import from are built from
             * this same payload, so they inherited the blank too.
             *
             * `!= null` rather than a truthy test, because 0 is a price: a
             * giveaway or a sample priced at nothing is a decision, and a truthy
             * check silently replaces it with the catalogue figure. */
            const sfPrice = sf.prices[p.id];
            const price = (sfPrice != null && String(sfPrice).trim() !== '')
              ? sfPrice
              : (p.price != null ? p.price : p.basePrice);
            if (price != null && String(price).trim() !== '') it.price = String(price);
            /* THE SAME OVERRIDE-NOT-ONLY-SOURCE FIX THE PRICE ABOVE GOT.
             *
             * `sf.categories[p.id]` is a map typed into a 96px box inside the
             * Storefront dialog, and it was the ONLY source — so a shop that had
             * categorised its whole catalogue on the catalogue screen published
             * a storefront where nothing had a category, and had to type all of
             * it a second time into a different form. The product feeds other
             * platforms import from are built from this same payload, so they
             * inherited the blank too.
             *
             * The override still wins where it is set; the product's own record
             * is what fills the rest. */
            const sfCat = sf.categories[p.id];
            const cat = (sfCat && String(sfCat).trim()) || (typeof productCategoryOf === 'function' ? productCategoryOf(p) : (p.category || ''));
            if (cat) it.category = cat;
            /* The collection this belongs to, so a storefront can show the seven
             * Saudi Kings together rather than scattered through one long grid.
             * Khayt has always known it and never published it. */
            const grp = (typeof productGroupOf === 'function' ? productGroupOf(p) : (p.group || p.folder || ''));
            if (grp) it.group = grp;
            if (sf.soldOut[p.id]) it.soldOut = true;
            /* The batch on the shelf, for a storefront that can ship it today.
             *
             * != null rather than a truthiness check: 0 is a sold-out batch and
             * has to be published as 0, or the piece reads as made to order and
             * is quoted a print lead time it does not need once restocked. */
            if (sf.stockQty[p.id] != null) {
              it.stockQty = sf.stockQty[p.id];
              if (sf.stockCountedAt[p.id]) it.stockCountedAt = sf.stockCountedAt[p.id];
            }
            /* What the thing is, for a storefront that has to reason about it.
             *
             * Khayt already knows all three and had never published them, so a
             * shop typed each one again into its storefront's admin — and a
             * hand-typed number that drifts from the shop's own record is worse
             * than none, because both look authoritative.
             *
             * printHours is MACHINE time only. Finishing is published separately
             * as part of the lead-time snapshot's handlingDays; adding prep and
             * post here would have a consumer count finishing twice. */
            const spec = KhaytProductSpecs.productSpecs(p);
            if (spec.printHours != null) it.printHours = spec.printHours;
            if (spec.weightGrams != null) it.weightGrams = spec.weightGrams;
            if (spec.material) it.material = spec.material;
            const og = parseOptionGroups(sf.options[p.id]);
            if (og.length) it.options = og;
            /* PHOTOS: more than one now, and each says what it is.
             *
             * A listing used to carry a single picture and no indication of
             * whether it was a render or the real thing — the one question a
             * customer is actually asking, and the one whose wrong answer is a
             * refund.
             *
             * The selection and the budget live in lib/product-images.js so
             * they can be tested: this modal is unreachable from an automation
             * context, so anything decided in here ships unverified. `photo`
             * stays as the first one, so a storefront page that has not been
             * updated still renders.
             */
            if (withPhotos) {
              const photos = KhaytProductImages.storefrontPhotos(p, {
                hero: (img) => (heroes && heroes.get(img.path)) || '',
              });
              /* `photo` is NOT set here. It is a view of photos[0] and the
               * server derives it from the gallery, so sending it put every
               * listing's primary photo on the wire twice — half a payload,
               * for a field the other end computes anyway. */
              if (photos.length) it.photos = photos;
            }
            return it;
          }).filter((it) => it.name),
        };
        /* Trim the pictures to what the server will accept, rather than letting
         * the whole publish fail.
         *
         * The per-listing budget in storefrontPhotos() says nothing about the
         * total, and the server caps a sanitised catalogue at 8 MB — so a shop
         * with about fourteen photo-rich products got 413 and no storefront at
         * all. Extra photos go before anyone's only photo. */
        KhaytProductImages.fitCatalogPhotos(payload.items);
        return payload;
      };
      modal.querySelector('#storeCopy')?.addEventListener('click', async () => {
        // On failure show the link itself, so it can still be selected by hand.
        setRes(await copyText(link) ? '✓ ' + (t('store.copied') || 'Link copied') : link, true);
      });
      modal.querySelector('#storeReviewCopy')?.addEventListener('click', async () => {
        setRes(await copyText(reviewLink) ? '✓ ' + (t('store.copied') || 'Link copied') : reviewLink, true);
      });
      // Show the live aggregate rating (best-effort).
      window.hubAPI.cloudReviewSummary({ url: c.url, shopId: c.shopId }).then((r) => {
        const s = r && r.ok && r.summary;
        if (s && s.count > 0) { const el = modal.querySelector('#storeRating'); if (el) el.textContent = `★ ${s.avg} (${s.count})`; }
      }).catch(() => {});

      /* THE REVIEWS THEMSELVES, AND A WAY TO REMOVE ONE.
       *
       * Anyone who can reach the public endpoint can leave a review, and every
       * one of them counts toward the star rating the storefront prints. Until
       * now this panel showed only that average: a shop could watch its rating
       * fall with no way to see what was dragging it down, and no way to remove
       * anything. The list is owner-only on the server. */
      const revEl = modal.querySelector('#storeReviewList');
      const renderReviews = async () => {
        if (!revEl || !window.hubAPI.cloudListReviews) return;
        revEl.textContent = t('common.loading') || '…';
        let r;
        try { r = await window.hubAPI.cloudListReviews({ url: c.url, shopId: c.shopId, token: c.token }); }
        catch (e) { r = { ok: false, error: String(e && e.message || e) }; }
        if (!r || !r.ok) {
          // Say why. A blank space here reads as "no reviews", which is the one
          // thing it must not be mistaken for.
          revEl.textContent = (t('store.reviews_load_failed') || 'Could not load your reviews') + (r && r.error ? ` — ${r.error}` : '');
          revEl.style.color = 'var(--text-muted)';
          return;
        }
        const list = r.reviews || [];
        if (!list.length) { revEl.textContent = t('store.reviews_none') || 'No reviews yet.'; return; }
        revEl.innerHTML = list.map((rv) => `
          <div style="display:flex;gap:8px;align-items:flex-start;padding:6px 0;border-bottom:1px solid var(--border-soft);">
            <span style="color:var(--accent);white-space:nowrap;">${'★'.repeat(Math.max(0, Math.min(5, +rv.rating || 0)))}</span>
            <div style="flex:1;min-width:0;">
              <div style="word-break:break-word;">${escapeHtml(rv.comment || '')}</div>
              <div style="font-size:11px;color:var(--text-muted);">${escapeHtml(rv.name || t('store.review_anon') || 'Anonymous')}
                · ${escapeHtml(String(rv.createdAt || '').slice(0, 10))}
                · ${rv.verified ? escapeHtml(t('store.review_verified') || 'verified customer') : escapeHtml(t('store.review_unverified') || 'unverified')}</div>
            </div>
            <button class="btn ghost small rev-del" data-rid="${escapeHtml(String(rv.id))}" type="button">${escapeHtml(t('common.delete') || 'Delete')}</button>
          </div>`).join('');
        revEl.querySelectorAll('.rev-del').forEach((btn) => {
          btn.addEventListener('click', async () => {
            if (!(await confirmModal(t('store.review_delete_q') || 'Remove this review from your storefront? This cannot be undone.', { danger: true }))) return;
            const d = await window.hubAPI.cloudDeleteReview({ url: c.url, shopId: c.shopId, token: c.token, reviewId: btn.dataset.rid });
            if (!d || !d.ok) { setRes('✗ ' + ((d && d.error) || 'failed'), false); return; }
            renderReviews();
          });
        });
      };
      renderReviews();
      // Storefront insights: views → carts → orders funnel + top products (best-effort).
      const insEl = modal.querySelector('#storeInsights');
      window.hubAPI.cloudStorefrontStats?.({ url: c.url, shopId: c.shopId, token: c.token }).then((r) => {
        if (!insEl) return;
        const s = r && r.ok && r.stats;
        if (!s || (!s.views && !s.carts && !s.orders)) { insEl.textContent = t('store.insights_empty') || 'No storefront activity yet.'; return; }
        const conv = s.views > 0 ? Math.round((s.orders / s.views) * 1000) / 10 : 0;
        const stat = (n, lbl) => `<span style="display:inline-block;margin-inline-end:14px;"><b style="color:var(--text);font-size:15px;">${n}</b> ${escapeHtml(lbl)}</span>`;
        const funnel = stat(s.views, t('store.ins_views') || 'views') + stat(s.carts, t('store.ins_carts') || 'carts')
          + stat(s.orders, t('store.ins_orders') || 'orders') + stat(conv + '%', t('store.ins_conv') || 'conversion');
        const top = (s.items || []).filter((it) => it.orders || it.carts).slice(0, 5)
          .map((it) => `<div style="display:flex;justify-content:space-between;padding:2px 0;"><span>${escapeHtml(it.name || it.id)}</span><span class="muted">${it.orders || 0} ${escapeHtml(t('store.ins_orders') || 'orders')} · ${it.carts || 0} ${escapeHtml(t('store.ins_carts') || 'carts')}</span></div>`).join('');
        insEl.innerHTML = `<div style="margin-bottom:6px;">${funnel}</div>` + (top ? `<div style="margin-top:6px;border-top:1px solid var(--border-soft);padding-top:6px;">${top}</div>` : '');
      }).catch(() => { if (insEl) insEl.textContent = t('store.insights_empty') || 'No storefront activity yet.'; });
      modal.querySelector('#storePublish')?.addEventListener('click', async () => {
        /* Say something BEFORE the build, not after it. Building now reads every
         * picture off disk and resizes it, which on a photo-rich catalogue is
         * seconds of a button that looks like it did nothing. */
        setRes(t('store.publishing') || 'Publishing…', true);
        const cat = await buildCatalog(modal.querySelector('#storePhotos').checked);
        if (!cat.items.length) { setRes('✗ ' + (t('store.no_products') || 'Add products to your catalog first'), false); return; }
        try {
          const r = await window.hubAPI.cloudCatalogPublish({ url: c.url, shopId: c.shopId, token: c.token, catalog: cat });
          if (r.ok) setRes('✓ ' + (t('store.published') || 'Storefront is live') + ` — ${cat.items.length}`, true);
          else setRes('✗ ' + (r.error || 'failed'), false);
        } catch (e) { setRes('✗ ' + (e.message || e), false); }
      });
      modal.querySelector('#storeUnpublish')?.addEventListener('click', async () => {
        if (!(await confirmModal(t('store.unpublish_q') || 'Take the storefront offline? The link will stop working.', { danger: true }))) return;
        setRes(t('store.publishing') || 'Working…', true);
        try {
          const r = await window.hubAPI.cloudCatalogPublish({ url: c.url, shopId: c.shopId, token: c.token, catalog: null });
          if (r.ok) setRes('✓ ' + (t('store.unpublished') || 'Storefront is offline'), true);
          else setRes('✗ ' + (r.error || 'failed'), false);
        } catch (e) { setRes('✗ ' + (e.message || e), false); }
      });
    },
  });
}

/**
 * @param {string} recoveryKey
 * @param {Function} [onDone]  runs after the key is acknowledged. Sign-up uses it
 *        to ask for the verification code NEXT, because the recovery key must be
 *        dealt with first and one modal cannot open over another.
 */
function showRecoveryKeyModal(recoveryKey, onDone) {
  openFormModal({
    title: t('cloud.recovery_title') || 'Save your recovery key',
    saveLabel: t('cloud.recovery_saved') || 'I saved it',
    bodyHtml: `
      <p style="font-size:13px;">${escapeHtml(t('cloud.recovery_hint') || 'This recovers your cloud data if you forget your passphrase. Shown ONCE — store it safely; it cannot be recovered for you.')}</p>
      <input type="text" readonly value="${escapeHtml(recoveryKey)}" style="font-family:monospace;font-size:13px;" onclick="this.select()">`,
    onSave: () => { if (typeof onDone === 'function') setTimeout(onDone, 0); },
  });
}

/** Modal to enter the emailed reset code + a new account password. */
function showResetPasswordModal(url, email) {
  openFormModal({
    title: t('cloud.reset_title') || 'Reset password',
    saveLabel: t('cloud.reset_do') || 'Reset password',
    bodyHtml: `
      <p style="font-size:13px;">${escapeHtml(t('cloud.reset_sent') || 'If that email has an account, we sent a reset code to')} <strong>${escapeHtml(email)}</strong>. ${escapeHtml(t('cloud.reset_enter') || 'Enter it below with your new account password.')}</p>
      <label>${escapeHtml(t('cloud.reset_code') || 'Reset code')}</label>
      <input type="text" id="rpCode" autocomplete="one-time-code" style="font-family:monospace;text-transform:uppercase;">
      <label style="margin-top:8px;">${escapeHtml(t('cloud.reset_newpw') || 'New account password')}</label>
      <input type="password" id="rpPass" placeholder="${escapeHtml(t('cloud.password_ph') || 'signs you in on any device (8+ chars)')}">
      <p style="font-size:11.5px;color:var(--text-muted);margin:6px 0 0;">${escapeHtml(t('cloud.reset_note') || 'This changes your account password only — your data stays encrypted; you’ll still unlock with your sync passphrase.')}</p>
      <p id="rpErr" style="color:var(--danger);font-size:12px;min-height:14px;margin:6px 0 0;"></p>`,
    onSave: async (modal) => {
      const code = modal.querySelector('#rpCode').value.trim().toUpperCase();
      const newPassword = modal.querySelector('#rpPass').value;
      const errEl = modal.querySelector('#rpErr');
      if (!code) { errEl.textContent = t('cloud.reset_need_code') || 'Enter the code from your email'; return false; }
      if (!newPassword || newPassword.length < 8) { errEl.textContent = t('cloud.need_password') || 'Account password must be 8+ chars'; return false; }
      const r = await window.hubAPI.cloudResetPassword({ url, email, code, newPassword });
      if (!r.ok) { errEl.textContent = '✗ ' + (r.error || 'reset failed'); return false; }
      toast(t('cloud.reset_done') || 'Password reset — log in with your new password', 'success');
    },
  });
}

/** Modal to enter the emailed verification code. On success marks the account verified. */
/**
 * Say WHY the server could not be reached, not just that it could not.
 *
 * The three failures need three different fixes — a network that swallows the
 * request, an address that answers but is not a Khayt server, and an address
 * that is not a URL — and "Server not reachable" pointed at none of them.
 */
function cloudReachErrorText(res, url) {
  const r = (res && res.reason) || 'unreachable';
  if (r === 'timeout') {
    const secs = Math.round(((res && res.timeoutMs) || 8000) / 1000);
    return t('cloud.unreachable_timeout', { url, secs })
      || `No answer from ${url} after ${secs}s — a firewall, VPN or proxy may be blocking it.`;
  }
  if (r === 'http') {
    return t('cloud.unreachable_http', { url, status: (res && res.status) || '?' })
      || `${url} answered, but not as a Khayt server (HTTP ${(res && res.status) || '?'}).`;
  }
  if (r === 'bad-url') {
    return (res && res.detail) || t('cloud.unreachable_badurl') || 'That is not a valid server address.';
  }
  return (t('cloud.unreachable') || 'Server not reachable') + ' ' + url;
}

function showVerifyEmailModal(url, email, sender) {
  // The code is sent, then the app goes quiet. A user who never receives it has
  // no idea whether to wait, look in spam, or give up — so say how long it may
  // take, name the address it comes from when the server tells us, and offer a
  // resend without making them close the dialog and start again.
  const fromLine = sender
    ? `<p style="font-size:12px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('cloud.verify_from', { sender }) || `It is sent from ${sender}.`)}</p>`
    : '';
  openFormModal({
    title: t('cloud.verify_title') || 'Verify your email',
    saveLabel: t('cloud.verify_do') || 'Verify',
    bodyHtml: `
      <p style="font-size:13px;">${escapeHtml(t('cloud.verify_sent') || 'We emailed a verification code to')} <strong>${escapeHtml(email)}</strong>.</p>
      <p style="font-size:12px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('cloud.verify_spam') || 'It can take a minute. If it does not arrive, check your spam or junk folder.')}</p>
      ${fromLine}
      <label style="margin-top:8px;">${escapeHtml(t('cloud.verify_code') || 'Verification code')}</label>
      <input type="text" id="veCode" autocomplete="one-time-code" style="font-family:monospace;text-transform:uppercase;">
      <button type="button" id="veResend" class="btn ghost small" style="margin-top:6px;">${escapeHtml(t('cloud.verify_resend') || 'Send it again')}</button>
      <p id="veErr" style="color:var(--danger);font-size:12px;min-height:14px;margin:6px 0 0;"></p>`,
    onMount: (modal) => {
      modal.querySelector('#veResend')?.addEventListener('click', async (ev) => {
        const btn = ev.currentTarget;
        const errEl = modal.querySelector('#veErr');
        btn.disabled = true;
        const rr = await window.hubAPI.cloudRequestVerify({ url, email });
        btn.disabled = false;
        if (!rr || !rr.ok) { errEl.textContent = '✗ ' + ((rr && rr.error) || 'could not send code'); return; }
        if (!rr.emailConfigured) {
          errEl.textContent = t('cloud.reset_no_email') || 'This server has no email set up — contact the admin';
          return;
        }
        if (rr.emailFailed) {
          errEl.style.color = 'var(--danger)';
          errEl.textContent = t('cloud.email_refused') || 'The server could not send the email — contact the admin';
          return;
        }
        errEl.style.color = 'var(--success)';
        errEl.textContent = t('cloud.verify_resent') || 'Sent again — check your inbox and spam folder.';
      });
    },
    onSave: async (modal) => {
      const code = modal.querySelector('#veCode').value.trim().toUpperCase();
      const errEl = modal.querySelector('#veErr');
      if (!code) { errEl.textContent = t('cloud.verify_need_code') || 'Enter the code from your email'; return false; }
      const r = await window.hubAPI.cloudVerifyEmail({ url, email, code });
      if (!r.ok) { errEl.textContent = '✗ ' + (r.error || 'verification failed'); return false; }
      if (settings.cloud) { settings.cloud.verified = true; saveAll(); }
      renderCloudSettings();
      toast(t('cloud.verify_done') || 'Email verified ✓', 'success');
    },
  });
}

// ---- Stage C: auto-sync wiring -------------------------------------------
// Append-only collections (ledgers/logs) are unioned, never overwritten, on merge.
// Which collections are ledgers now lives in lib/cloud-inbox.js, beside the
// merge that uses it, so the native Mac app cannot hold a different opinion
// about it. Nothing here needs the list any more.


/** I/O the auto-sync controller needs, bound to the live app + cloud IPC. */
/**
 * Tell the user when a sync merge discarded a local edit because the record was
 * deleted on another device. Delete-wins is the policy (a resurrected order is
 * worse than a lost edit for a shop); this just stops the loss being silent.
 * No restore button — the tombstone wins on every device, so a restored record
 * would be deleted again on the next sync. Naming what was lost lets the shop
 * re-enter it as a new order if it mattered.
 */
function reportSyncConflicts(conflicts) {
  const { count, firstName } = (typeof KhaytSync !== 'undefined' && KhaytSync.summarizeDiscardedEdits)
    ? KhaytSync.summarizeDiscardedEdits(conflicts)
    : { count: 0, firstName: '' };
  if (!count) return;
  const msg = count === 1
    ? (t('sync.discarded_one') || 'An edit was discarded — “{name}” was deleted on another device.').replace('{name}', firstName)
    : (t('sync.discarded_many') || '{n} edits were discarded — those records were deleted on another device.').replace('{n}', count);
  if (typeof toast === 'function') toast(msg, 'warning', 8000);
  // Durable trace for support/debugging — the transient toast can be missed.
  try { console.warn('[sync] discarded local edits (deleted elsewhere):', (conflicts || []).filter((c) => c && c.kind === 'delete_over_edit').map((c) => `${c.collection}/${c.id}`).join(', ')); } catch (e) { /* noop */ }
}

/**
 * Tell the shop about an edit another device's newer version wrote over.
 *
 * Separate from the delete case on purpose. `rev` is a per-record counter, not a
 * causal clock, so a peer that edited the same record twice arrives at a higher
 * rev than this device's own single edit and wins — correctly, for convergence,
 * but the local edit is gone and used to go unmentioned. The record still exists
 * here, showing the other machine's version, so the useful advice is "look at it
 * again", not "it was deleted".
 */
function reportOverwrittenEdits(conflicts) {
  const { count, firstName } = (typeof KhaytSync !== 'undefined' && KhaytSync.summarizeOverwrittenEdits)
    ? KhaytSync.summarizeOverwrittenEdits(conflicts)
    : { count: 0, firstName: '' };
  if (!count) return;
  const msg = count === 1
    ? t('sync.overwritten_one').replace('{name}', firstName)
    : t('sync.overwritten_many').replace('{n}', String(count));
  if (typeof toast === 'function') toast(msg, 'warning', 10000);
  try {
    console.warn('[sync] local edits overwritten by a newer version from another device:',
      (conflicts || []).filter((c) => c && c.kind === 'remote_over_local_edit')
        .map((c) => `${c.collection}/${c.id} (local rev ${c.localRev} → incoming ${c.incomingRev})`).join(', '));
  } catch (e) { /* noop */ }
}

/**
 * Tell the shop about records that came back after they deleted them.
 *
 * Until the tombstone fix, a pull that predated a local delete re-added the
 * record and the next save persisted it. That shipped in v3.3.0 and every 3.4
 * beta, so some stores carry resurrected records today. Fixing the merge does
 * not undo them, and re-deleting automatically would be a second silent data
 * change on top of the first — on a record the shop may well have worked on in
 * the weeks since it returned. So: name them, and let the owner decide.
 *
 * Announced when the set CHANGES, not on every launch. Nagging each start trains
 * the owner to dismiss it; announcing once ever is missed by anyone who was not
 * looking that day.
 */
function reportResurrectedRecords() {
  if (typeof KhaytSync === 'undefined' || !KhaytSync.findResurrected) return;
  let found = [];
  try { found = KhaytSync.findResurrected(buildStoreSnapshot()); } catch (e) { return; }

  const KEY = 'hub_resurrected_seen_v1';
  const signature = found.map((f) => `${f.collection}/${f.id}`).sort().join(',');
  let lastSeen = '';
  try { lastSeen = localStorage.getItem(KEY) || ''; } catch (e) { /* private mode */ }
  try { localStorage.setItem(KEY, signature); } catch (e) { /* non-fatal */ }

  // A durable trace whenever any exist: the toast is transient, and support
  // should not have to ask the owner to reproduce it.
  if (found.length) {
    try { console.warn('[sync] records present despite a tombstone:', signature); } catch (e) { /* noop */ }
  }
  if (!found.length || signature === lastSeen) return;

  const { count, firstName } = KhaytSync.summarizeResurrected(found);
  const msg = count === 1
    ? (t('sync.resurrected_one') || 'A record you deleted came back — “{name}”. An older sync bug could re-add deleted records; delete it again if it should be gone.').replace('{name}', firstName)
    : (t('sync.resurrected_many') || '{n} records you deleted came back. An older sync bug could re-add deleted records; delete them again if they should be gone.').replace('{n}', count);
  if (typeof toast === 'function') toast(msg, 'warning', 12000);
}

/**
 * Two things a shop upgrading from an earlier build meets in its own data.
 *
 * Both follow from money fixes in this release, and both are REPORT-ONLY:
 *
 *  - An instalment plan written before the deposit fix split the GROSS price, so
 *    it asks for more than the order still owes. A schedule is an agreement the
 *    shop may have put in writing to a customer; rewriting the amounts under it
 *    would be worse than saying so.
 *  - Points used to be earned on cancelled, personal and fully refunded jobs.
 *    Correcting that lowers what a client has EARNED, and the balance clamps at
 *    zero — so someone who was told they had points now has none, quietly.
 *    Re-inflating it would perpetuate a liability the shop does not owe.
 *
 * Announced when the set CHANGES, on the same rule and for the same reason as
 * reportResurrectedRecords: nagging every launch trains the owner to dismiss it,
 * and announcing once ever is missed by whoever was not looking that day.
 */
function reportLegacyMoneyState() {
  const plans = (typeof KhaytPaymentPlan !== 'undefined' && KhaytPaymentPlan.overBilledPlans)
    ? KhaytPaymentPlan.overBilledPlans(typeof printLog !== 'undefined' ? printLog : [])
    : [];
  const over = (typeof clientsOverRedeemed === 'function') ? clientsOverRedeemed() : [];
  if (!plans.length && !over.length) return;

  // A durable trace whenever any exist, whether or not the toast is shown:
  // support should not have to ask the owner to reproduce it.
  try {
    if (plans.length) console.warn('[money] instalment plans asking more than is owed:',
      plans.map((p) => `${p.id} (+${p.over})`).join(', '));
    if (over.length) console.warn('[money] clients who redeemed more than they earned:',
      over.map((c) => `${c.id} (+${c.over})`).join(', '));
  } catch (e) { /* noop */ }

  const KEY = 'hub_legacy_money_seen_v1';
  const signature = [...plans.map((p) => `p:${p.id}:${p.over}`), ...over.map((c) => `c:${c.id}:${c.over}`)].sort().join(',');
  let lastSeen = '';
  try { lastSeen = localStorage.getItem(KEY) || ''; } catch (e) { /* private mode */ }
  try { localStorage.setItem(KEY, signature); } catch (e) { /* non-fatal */ }
  if (signature === lastSeen) return;

  if (plans.length && typeof toast === 'function') {
    const first = plans[0];
    const msg = plans.length === 1
      ? t('money.plan_over_one').replace('{name}', first.project).replace('{amount}', fmtMoney(first.over))
      : t('money.plan_over_many').replace('{n}', String(plans.length));
    toast(msg, 'warning', 14000);
  }
  if (over.length && typeof toast === 'function') {
    const msg = over.length === 1
      ? t('money.points_over_one').replace('{name}', over[0].name)
      : t('money.points_over_many').replace('{n}', String(over.length));
    setTimeout(() => toast(msg, 'warning', 14000), 1200);
  }
}

/**
 * A restore or import is about to replace local state — tell the cloud backend
 * to forget what it believes the server holds.
 *
 * Restores are renderer-side (the main process only decrypts the file), so the
 * backend never learns that local just moved BACKWARDS. It goes on claiming the
 * server holds records at the revs it last pushed, and everything that
 * disagrees with that claim is what gets sent — which, after a restore, is the
 * older copy of every record, sent over the newer one on every device, silently.
 * `viewSafeForLocal` catches exactly this, but only when the backend is BUILT;
 * a restore while the app is running never rebuilds it.
 * docs/KHAYT-CLOUD-DELTA-SYNC.md §7.
 *
 * Called BEFORE the snapshot is applied, not after. The window between the two
 * is small but it is not empty — a sync debounced from an earlier save can fire
 * inside it — and the asymmetry is the same one that decides every judgement
 * call in the backend: forgetting a view that turned out not to need it costs
 * one cold pull, keeping one that did costs a shop its data.
 *
 * Never throws and never blocks the restore. Cloud off, cloud locked, or an IPC
 * that fails all mean the same thing here: no in-memory claim was dropped, and
 * the on-disk cache is still checked against the restored store at the next
 * unlock.
 */
async function forgetCloudServerView() {
  try { await window.hubAPI?.cloudForgetView?.(); }
  catch (e) { console.error('cloudForgetView:', e); }
}

/**
 * Write the shop's keyset to the server, and TELL SOMEONE IF IT FAILS.
 *
 * The keyset is what makes the encrypted store readable: without it on the
 * server, a second device logs in, gets no keyset, and cannot open a store that
 * is sitting right there. Four call sites awaited hub:cloud-put-keyset and threw
 * the `{ok:false,error}` away — each of them having carefully checked every
 * other call in the same handler, and then ignoring the one that persists the
 * result.
 *
 * The worst was the login path: an account with no keyset had one created from
 * the passphrase, and the recovery key was shown as though it were saved. If the
 * upload failed, that shop's store existed only on that one machine, behind a
 * recovery key the owner had been told to write down.
 *
 * Returns true when the server has it.
 */
async function putCloudKeyset({ url, shopId, token, keyset }, whatFailed) {
  let r;
  try {
    r = await window.hubAPI.cloudPutKeyset({ url, shopId, token, keyset });
  } catch (e) {
    r = { ok: false, error: String((e && e.message) || e) };
  }
  if (r && r.ok) return true;
  const why = (r && r.error) ? `: ${r.error}` : '';
  console.error('cloudPutKeyset failed', whatFailed || '', why);
  toast((t('cloud.keyset_put_failed')
    || 'Your sync key could not be saved to the server — other devices will not be able to open this shop. Check your connection and try again.') + why,
  'error', 12000);
  return false;
}

function cloudSyncDeps() {
  return {
    buildSnapshot: () => buildStoreSnapshot(),
    applySnapshot: (snap) => applyStoreFromSnapshot(snap),
    save: () => saveAll(),
    push: (snap) => window.hubAPI.cloudPush(snap),
    pull: () => window.hubAPI.cloudPull(),
    onConflicts: (conflicts) => { reportSyncConflicts(conflicts); reportOverwrittenEdits(conflicts); },
  };
}

/** Turn on background auto-sync after a successful unlock. initialPull merges
 *  any server-side changes first (safe on the same device); skip it right after
 *  sign-up (server is empty) so we just push the new shop's data. */
async function enableCloudAutoSync({ initialPull = true } = {}) {
  if (!window.KhaytCloudSync) return;
  KhaytCloudSync.configure(cloudSyncDeps());
  try {
    if (initialPull) await KhaytCloudSync.pullMerge();
    KhaytCloudSync.syncNow();
  } catch (e) { console.error('enableCloudAutoSync:', e); }
}

/** Fetch + show the shop's billing plan in the cloud card (silent if billing off). */
async function showCloudPlan(c) {
  const elx = document.getElementById('cloudPlan');
  if (!elx || !window.hubAPI?.cloudBillingMe) return;
  try {
    const r = await window.hubAPI.cloudBillingMe({ url: c.url, shopId: c.shopId, token: c.token });
    if (!r || !r.ok || !r.billingEnabled) { elx.textContent = ''; return; }
    // Cache whether this shop is actually subscribed, so the portal trial can
    // tell a payer from a free shop. Deliberately NOT saved: it is the server's
    // answer, refreshed on every render, and persisting it would let a stale
    // copy outlive the subscription it describes.
    if (settings.cloud) settings.cloud.planActive = !!(r.active && r.plan && r.plan !== 'free');
    const mb = (r.limits && +r.limits.maxStoreBytes) ? Math.round(+r.limits.maxStoreBytes / (1024 * 1024)) : null;
    const parts = [(t('cloud.plan') || 'Plan') + ': ' + (r.label || r.plan)];
    if (!r.active) parts.push(t('cloud.plan_inactive') || 'inactive');
    if (mb) parts.push((t('cloud.plan_storage') || 'up to') + ' ' + mb + ' MB');
    elx.textContent = parts.join(' · ');
    elx.style.color = r.active ? 'var(--text-muted)' : 'var(--danger)';
  } catch (e) { /* billing is optional — stay silent */ }
}

function cloudSyncStatusLabel(s) {
  const map = {
    syncing: t('cloud.status_syncing') || 'Syncing…',
    synced: t('cloud.status_synced') || 'Synced ✓',
    conflict: t('cloud.status_conflict') || 'Resolving…',
    locked: t('cloud.status_locked') || 'Locked',
    offline: t('cloud.status_offline') || 'Offline — will retry',
    error: t('cloud.status_error') || 'Sync error',
    idle: t('cloud.status_idle') || 'Auto-sync on',
  };
  return map[s] || '';
}

// One persistent status listener that paints the #cloudSyncStatus badge whenever
// it exists (the element is recreated on each settings render).
let _cloudStatusWired = false;
function wireCloudSyncStatusOnce() {
  if (_cloudStatusWired || !window.KhaytCloudSync) return;
  _cloudStatusWired = true;
  KhaytCloudSync.onStatus((s, detail) => {
    const badge = document.getElementById('cloudSyncStatus');
    if (!badge) return;
    badge.textContent = cloudSyncStatusLabel(s);
    badge.style.color = (s === 'error' || s === 'offline') ? 'var(--danger)'
      : (s === 'synced' ? 'var(--success)' : 'var(--text-muted)');
    // Say WHY it failed. The reason has always reached this callback and was
    // thrown away, so a shop that had outgrown its plan saw a red "Sync error"
    // with no cause and no next step, indefinitely — while the server had
    // already said "Store exceeds your plan's size limit" in as many words.
    // Hover text rather than inline: the badge sits in a sentence, and the
    // reasons are sentences themselves.
    // `window.`-qualified, not bare: Bed Ready loads this file but not
    // cloud-sync.js, and a bare global read there is a ReferenceError. The
    // module-parity test enforces exactly that, and caught this.
    const why = (detail && detail.error)
      || (s === 'error' && window.KhaytCloudSync ? window.KhaytCloudSync.error() : '');
    if ((s === 'error' || s === 'offline') && why) badge.title = String(why);
    else badge.removeAttribute('title');
  });
}

/** Settings → Khayt Cloud: account sign-up / log-in / sync / restore (opt-in, E2E).
 *  Two independent secrets: the ACCOUNT PASSWORD authenticates (reaches the shop);
 *  the SYNC PASSPHRASE encrypts (decrypts data) and never leaves this device. */
/**
 * Where the model files are kept, and whether Khayt can reach it.
 *
 * Both paths come from a folder picker rather than a text field: a typed path is
 * one that can silently not exist, and this setting decides where a shop's most
 * expensive asset is written. The status line is the other half of writes
 * failing loudly — refusing a save without saying the share is unmounted just
 * moves the confusion.
 */
async function renderPrintLibLocation() {
  const rootEl = $('#set_plibRoot');
  const mirrorEl = $('#set_plibMirror');
  const statusEl = $('#plibLocStatus');
  if (!rootEl || !mirrorEl) return;
  const cfg = (settings && settings.printLibrary) || {};
  rootEl.value = cfg.root || '';
  mirrorEl.value = cfg.mirror || '';
  const s3 = cfg.s3 || {};
  const setV = (id, v) => { const el = $(id); if (el) el.value = v || ''; };
  if ($('#set_plibS3On')) $('#set_plibS3On').checked = !!s3.enabled;
  setV('#set_plibS3Endpoint', s3.endpoint);
  setV('#set_plibS3Bucket', s3.bucket);
  setV('#set_plibS3Region', s3.region);
  setV('#set_plibS3Prefix', s3.prefix);
  setV('#set_plibS3Key', s3.accessKeyId);
  // Never render the secret back. The renderer only ever holds a mask; typing
  // nothing keeps what is on disk (see secretInputSave).
  const sec = $('#set_plibS3Secret');
  if (sec) { sec.value = ''; sec.placeholder = secretFieldPlaceholder(s3.secretAccessKey); }
  // Both are independent of whether the library folder is reachable — a shop
  // whose NAS is unplugged still needs to be able to configure its bucket, which
  // is often the reason they are on this screen.
  await renderPrintLibProviders();
  renderPrintLibGDrive();
  renderPrintLibTier();
  // Typing an account id rebuilds the endpoint live, so the shop can see the URL
  // the app will actually use rather than discovering it after a failed test.
  const vars = $('#plibS3Vars');
  if (vars && !vars.dataset.wired) {
    vars.dataset.wired = '1';
    vars.addEventListener('input', () => { refreshPrintLibEndpointPreview(); });
  }
  if (!statusEl || !window.hubAPI?.printLibStatus) return;
  let st = null;
  try { st = await window.hubAPI.printLibStatus(); } catch (_) { st = null; }
  if (!st) { statusEl.textContent = ''; return; }
  if (!st.ok) {
    statusEl.textContent = '⚠ ' + (st.error || '');
    statusEl.style.color = 'var(--danger)';
    return;
  }
  const where = st.isCustom ? st.root : (t('set.plib_this_mac') || 'this Mac');
  const mirrorNote = st.mirror
    ? ' · ' + (st.mirrorOk === false
      ? (t('set.plib_mirror_missing') || 'backup folder not reachable')
      : (t('set.plib_mirror_ok') || 'backup folder ready'))
    : '';
  statusEl.textContent = '✓ ' + (t('set.plib_ready') || 'Library folder ready') + ': ' + where + mirrorNote;
  statusEl.style.color = st.mirror && st.mirrorOk === false ? 'var(--warning, #d97706)' : 'var(--text-muted)';
  // Offered, not hidden behind a button nobody knows to press: a shop that has
  // just moved the library sees an empty one, and has no reason to suspect the
  // files are elsewhere rather than gone.
  scanPrintLibMigrate();
}

/**
 * Persist the bucket settings.
 *
 * The secret goes through secretInputSave: the renderer is handed a mask rather
 * than the real key, so an empty field means "keep what is on disk" and NOT
 * "clear it" — saving any other setting on this page would otherwise wipe the
 * credential.
 */
/**
 * The provider table, fetched once. Main owns it; this is a read-through cache
 * so the dropdown does not re-cross IPC on every keystroke.
 */
let plibProviders = null;
let plibPricedOn = '';

/**
 * Paint the provider dropdown and the fields the chosen one needs.
 *
 * The endpoint box does not disappear for templated providers — it goes
 * read-only and shows what was built. A shop that pastes an endpoint from a
 * support article needs to see that the app agrees with it, and a field that
 * vanishes looks like the setting was lost.
 */
async function renderPrintLibProviders() {
  const sel = $('#set_plibS3Provider');
  if (!sel || !window.hubAPI?.storageProviders) return;
  if (!plibProviders) {
    try {
      const r = await window.hubAPI.storageProviders();
      plibProviders = r && Array.isArray(r.providers) ? r.providers : [];
      plibPricedOn = (r && r.pricedOn) || '';
      // Only adopt main's detected provider on the FIRST paint. Re-detecting on
      // every render would fight the shop mid-edit: pick a provider, start
      // typing an account id, and the half-built endpoint would snap the
      // dropdown back to whatever it currently parses as.
      if (r && r.current) {
        sel.dataset.initial = r.current;
        sel.dataset.initialVars = JSON.stringify(r.vars || {});
      }
    } catch (_) { plibProviders = []; }
  }
  if (!plibProviders.length) return;

  if (!sel.options.length) {
    for (const p of plibProviders) {
      const o = document.createElement('option');
      o.value = p.id;
      o.textContent = p.recommended ? `${p.label} ★` : p.label;
      sel.appendChild(o);
    }
    sel.value = sel.dataset.initial || plibProviders[0].id;
    let initVars = {};
    try { initVars = JSON.parse(sel.dataset.initialVars || '{}'); } catch (_) { initVars = {}; }
    renderPrintLibProviderFields(initVars);
    return;
  }
  renderPrintLibProviderFields();
}

/** Build the account-id / region inputs the chosen provider asks for. */
function renderPrintLibProviderFields(preset) {
  const sel = $('#set_plibS3Provider');
  const box = $('#plibS3Vars');
  const note = $('#plibS3ProviderNote');
  const epRow = $('#plibS3EndpointRow');
  const ep = $('#set_plibS3Endpoint');
  if (!sel || !box) return;
  const p = (plibProviders || []).find((x) => x.id === sel.value);
  if (!p) return;

  // Keep whatever is already typed across a re-render, so switching provider and
  // back does not silently empty a field the shop had filled in.
  const existing = {};
  for (const el of box.querySelectorAll('input[data-var]')) existing[el.dataset.var] = el.value;
  const seed = preset && typeof preset === 'object' ? preset : existing;

  box.innerHTML = '';
  for (const v of p.vars) {
    const wrap = document.createElement('div');
    const label = document.createElement('label');
    label.textContent = v.label;
    const input = document.createElement('input');
    input.type = 'text';
    input.dataset.var = v.key;
    input.id = `set_plibVar_${v.key}`;
    input.value = seed[v.key] || '';
    input.placeholder = v.hint || '';
    const hint = document.createElement('p');
    hint.style.cssText = 'font-size:11px;color:var(--text-muted);margin:4px 0 0;';
    hint.textContent = v.hint || '';
    wrap.appendChild(label); wrap.appendChild(input); wrap.appendChild(hint);
    box.appendChild(wrap);
  }

  if (note) {
    const bits = [];
    if (p.cost) bits.push(p.cost);
    if (p.note) bits.push(p.note);
    note.textContent = bits.join(' · ');
    // The figures are hints and are labelled as such — providers reprice, and a
    // number in a dropdown that claims more precision than that is a lie with a
    // currency symbol on it.
    if (p.cost && plibPricedOn) note.textContent += ` (checked ${plibPricedOn}; confirm with the provider)`;
  }

  // "Where do I get an account id?" has no answer for a shop that has no
  // account. Every other field here is copied off a dashboard, so before the
  // signup this whole form is unfillable and the presets help the one shop that
  // needs them most not at all. Hidden for 'Other', which has nothing to sign
  // up for.
  const signup = $('#plibS3Signup');
  const signupRef = $('#plibS3SignupRef');
  if (signup) {
    // inline-block rather than '': an inline anchor ignores margin-top and the
    // link ends up jammed against the cost note.
    signup.style.display = p.signup ? 'inline-block' : 'none';
    if (p.signup) {
      signup.dataset.url = p.signup;
      // The destination on hover. The shop is about to hand this provider a
      // card number, so "where does this actually go" deserves an answer that
      // does not require clicking it first.
      signup.title = p.signup;
      signup.textContent = p.selfHosted
        ? (t('set.plib_s3_signup_self') || 'Download and run it yourself \u2197')
        : t('set.plib_s3_signup', { provider: p.label });
    } else {
      delete signup.dataset.url;
      signup.removeAttribute('title');
    }
    // Wired once: this function re-runs on every provider change, and a fresh
    // listener each time would open the same page once per change.
    if (!signup.dataset.wired) {
      signup.dataset.wired = '1';
      signup.addEventListener('click', (e) => {
        e.preventDefault();
        if (signup.dataset.url) window.hubAPI?.openExternal?.(signup.dataset.url);
      });
    }
  }
  if (signupRef) {
    // Disclosed next to the link rather than in a policy page nobody opens. A
    // link that pays the project is still a link the shop is entitled to
    // recognise as one before they click it.
    const disclose = !!p.signup && !!p.signupReferral;
    signupRef.style.display = disclose ? '' : 'none';
    signupRef.textContent = disclose
      ? (t('set.plib_s3_signup_ref') || 'Referral link \u2014 Khayt may receive credit. It costs you nothing.')
      : '';
  }

  // A templated provider builds its own endpoint; only the ones that cannot show
  // an editable box. IDrive e2 is the case that forced this — it issues every
  // account a different host, so there is no pattern to fill in.
  const templated = !!p.vars.length && !p.endpointFromDashboard && p.id !== 'custom';
  if (ep) {
    ep.readOnly = templated;
    ep.style.opacity = templated ? '0.7' : '1';
    ep.placeholder = p.endpointHint || 'https://…';
  }
  if (epRow) epRow.style.display = '';
}

function onPrintLibProviderChange() {
  renderPrintLibProviderFields();
  refreshPrintLibEndpointPreview();
}

/** Show the endpoint that will actually be saved, as it is typed. */
async function refreshPrintLibEndpointPreview() {
  const sel = $('#set_plibS3Provider');
  const ep = $('#set_plibS3Endpoint');
  if (!sel || !ep || !window.hubAPI?.storageResolveEndpoint) return;
  const p = (plibProviders || []).find((x) => x.id === sel.value);
  if (!p || !p.vars.length || p.endpointFromDashboard) return;
  const vars = {};
  for (const el of document.querySelectorAll('#plibS3Vars input[data-var]')) vars[el.dataset.var] = el.value.trim();
  try {
    const r = await window.hubAPI.storageResolveEndpoint(sel.value, vars);
    if (r && r.ok && r.endpoint) {
      ep.value = r.endpoint;
      if (r.region && !($('#set_plibS3Region')?.value || '').trim()) $('#set_plibS3Region').value = r.region;
    }
  } catch (_) { /* the shop can still type one */ }
}

async function savePrintLibS3() {
  const v = (id) => ($(id)?.value || '').trim();
  const cur = ((settings.printLibrary || {}).s3) || {};
  const sel = $('#set_plibS3Provider');
  const provider = sel ? sel.value : '';

  // Build the endpoint from the preset before saving. Main owns the table, so a
  // provider the dropdown offers is always one main can resolve.
  let endpoint = v('#set_plibS3Endpoint');
  let region = v('#set_plibS3Region');
  const p = (plibProviders || []).find((x) => x.id === provider);
  if (p && p.vars.length && !p.endpointFromDashboard && window.hubAPI?.storageResolveEndpoint) {
    const vars = {};
    for (const el of document.querySelectorAll('#plibS3Vars input[data-var]')) vars[el.dataset.var] = el.value.trim();
    let r;
    try { r = await window.hubAPI.storageResolveEndpoint(provider, vars); } catch (_) { r = null; }
    if (r && !r.ok) {
      // Refuse rather than save half a URL. A bucket configured with a literal
      // "{account}" in the hostname fails as a 403, which reads as a bad secret
      // and sends the shop off to re-copy a key that was never wrong.
      toast(r.error || t('set.plib_s3_incomplete') || 'Fill in the provider details first', 'error');
      return;
    }
    if (r && r.ok) { endpoint = r.endpoint; region = region || r.region; }
  }

  settings.printLibrary = Object.assign({}, settings.printLibrary, {
    s3: {
      enabled: !!$('#set_plibS3On')?.checked,
      provider,
      endpoint,
      bucket: v('#set_plibS3Bucket'),
      region: region || 'auto',
      prefix: v('#set_plibS3Prefix'),
      accessKeyId: v('#set_plibS3Key'),
      secretAccessKey: secretInputSave(cur.secretAccessKey, v('#set_plibS3Secret')),
    },
  });
  saveAll();
  renderPrintLibLocation();
  toast(t('set.plib_s3_saved') || 'Object storage settings saved', 'success');
}

/** Prove the bucket works before anyone relies on it as a backup. */
async function testPrintLibS3() {
  const out = $('#plibS3Result');
  if (!window.hubAPI?.printLibS3Test) return;
  // Awaited: savePrintLibS3 became async when it started building the endpoint
  // from the provider preset, and testing before that lands tests the PREVIOUS
  // endpoint — which passes or fails for reasons unrelated to what is on screen.
  await savePrintLibS3();                            // test what is configured, not what was typed
  if (out) { out.textContent = t('set.plib_s3_testing') || 'Testing…'; out.style.color = 'var(--text-muted)'; }
  let r;
  try { r = await window.hubAPI.printLibS3Test(); } catch (err) { r = { ok: false, error: String(err.message || err) }; }
  if (!out) return;
  out.textContent = r && r.ok
    ? '✓ ' + (t('set.plib_s3_ok') || 'Wrote, read back and removed a test file')
    : '✗ ' + ((r && r.error) || '');
  out.style.color = r && r.ok ? 'var(--success, #16a34a)' : 'var(--danger)';
}

// ── Google Drive ────────────────────────────────────────────────────────────

/**
 * Bytes as a person reads them. Mirrors lib/print-library-tier's formatBytes —
 * duplicated rather than imported because the renderer cannot require(), and
 * crossing IPC to format a number would be worse than seven lines.
 */
function plibBytes(n) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = Number(n) || 0;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return `${i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
}

/** Paint the Drive fields, and say who is actually connected. */
async function renderPrintLibGDrive() {
  const cfg = ((settings && settings.printLibrary) || {}).gdrive || {};
  const status = $('#plibGDStatus');
  if ($('#set_plibGDriveOn')) $('#set_plibGDriveOn').checked = !!cfg.enabled;
  if ($('#set_plibGDClientId')) $('#set_plibGDClientId').value = cfg.clientId || '';
  if ($('#set_plibGDFolder')) $('#set_plibGDFolder').value = cfg.folderName || '';
  // Same rule as the bucket secret: the renderer holds a mask, never the value,
  // so an empty box means "keep what is on disk".
  const sec = $('#set_plibGDSecret');
  if (sec) { sec.value = ''; sec.placeholder = secretFieldPlaceholder(cfg.clientSecret); }
  if (!status || !window.hubAPI?.gdriveStatus) return;

  let s;
  try { s = await window.hubAPI.gdriveStatus(); } catch (_) { s = null; }
  if (!s) { status.textContent = ''; return; }
  if (!s.connected) {
    // A revoked grant looks identical to "never connected" in the settings file,
    // so the error from Drive is what distinguishes them.
    status.textContent = s.error ? `⚠ ${s.error}` : (t('set.plib_gd_none') || 'No Google account connected.');
    status.style.color = s.error ? 'var(--danger)' : 'var(--text-muted)';
    return;
  }
  const cap = s.limit == null ? (t('set.plib_gd_unlimited') || 'unlimited') : plibBytes(s.limit);
  status.textContent = `✓ ${s.email} · ${plibBytes(s.usage)} of ${cap} used`;
  status.style.color = 'var(--text-muted)';
}

function savePrintLibGDrive(extra) {
  const v = (id) => ($(id)?.value || '').trim();
  const cur = ((settings.printLibrary || {}).gdrive) || {};
  settings.printLibrary = Object.assign({}, settings.printLibrary, {
    gdrive: Object.assign({}, cur, {
      enabled: !!$('#set_plibGDriveOn')?.checked,
      clientId: v('#set_plibGDClientId'),
      clientSecret: secretInputSave(cur.clientSecret, v('#set_plibGDSecret')),
      folderName: v('#set_plibGDFolder') || 'Khayt print library',
    }, extra || {}),
  });
  saveAll();
  renderPrintLibGDrive();
  if (!extra) toast(t('set.plib_gd_saved') || 'Google Drive settings saved', 'success');
}

/**
 * Open the consent screen and store what comes back.
 *
 * The client id is saved FIRST: main reads it from the store to build the auth
 * URL, so connecting without saving would send the shop through a sign-in for
 * whatever id was there before.
 */
async function connectPrintLibGDrive() {
  const status = $('#plibGDStatus');
  if (!window.hubAPI?.gdriveConnect) return;
  savePrintLibGDrive({});
  if (!($('#set_plibGDClientId')?.value || '').trim()) {
    toast(t('set.plib_gd_need_client') || 'Add the OAuth client ID first', 'error');
    return;
  }
  if (status) { status.textContent = t('set.plib_gd_waiting') || 'Waiting for the browser sign-in…'; status.style.color = 'var(--text-muted)'; }

  let r;
  try { r = await window.hubAPI.gdriveConnect(); } catch (err) { r = { ok: false, error: String(err.message || err) }; }
  if (!r || !r.ok) {
    if (status) { status.textContent = '✗ ' + ((r && r.error) || 'Could not connect.'); status.style.color = 'var(--danger)'; }
    return;
  }
  // Saved through the ordinary settings path so store-io encrypts it like every
  // other credential, rather than main writing it to disk its own way.
  savePrintLibGDrive({ refreshToken: r.refreshToken, folderId: '' });
  toast(t('set.plib_gd_connected') || 'Google Drive connected', 'success');
}

/**
 * Forget the account.
 *
 * Clears the token here and points the shop at Google to revoke the grant —
 * deleting our copy stops Khayt using it, but only Google can actually withdraw
 * the access, and saying otherwise would overstate what this button does.
 */
function disconnectPrintLibGDrive() {
  if (!confirm('Disconnect this Google account?\n\nAnything already in Drive stays there. If models have been moved to the cloud, bring them back first or they will not open.')) return;
  const cur = ((settings.printLibrary || {}).gdrive) || {};
  settings.printLibrary = Object.assign({}, settings.printLibrary, {
    gdrive: Object.assign({}, cur, { enabled: false, refreshToken: '', folderId: '' }),
  });
  saveAll();
  renderPrintLibGDrive();
  toast(t('set.plib_gd_disconnected') || 'Disconnected. Remove Khayt at myaccount.google.com to fully revoke access.', 'success');
}

// ── Cloud tiering ───────────────────────────────────────────────────────────
// The backup block above only ever writes. This one deletes local files once the
// bucket has verifiably received them, so everything here leans towards saying
// what is about to happen before it happens.

/**
 * Show what a sweep would free, and why it would not.
 *
 * "Nothing to free" and "your bucket is not configured" and "nothing is old
 * enough yet" all produce a button that appears to do nothing, so the status
 * line has to distinguish them.
 */
async function renderPrintLibTier() {
  const cfg = ((settings && settings.printLibrary) || {}).tier || {};
  const on = $('#set_plibTierOn');
  const days = $('#set_plibTierDays');
  const status = $('#plibTierStatus');
  if (on) on.checked = !!cfg.enabled;
  if (days) days.value = Number(cfg.keepDays) > 0 ? Number(cfg.keepDays) : 90;
  if (!status || !window.hubAPI?.printLibTierScan) return;

  let s;
  try { s = await window.hubAPI.printLibTierScan(); } catch (_) { s = null; }
  if (!s || !s.ok) { status.textContent = ''; return; }

  const parts = [];
  if (!s.configured) {
    parts.push(t('set.plib_tier_no_bucket')
      || 'Add your object storage details above before switching this on.');
    status.style.color = 'var(--warning, #d97706)';
  } else if (s.count > 0) {
    parts.push(`${s.count} ${s.count === 1 ? 'model' : 'models'} could move to the cloud, freeing ${s.human}.`);
    status.style.color = 'var(--text-muted)';
  } else {
    const recent = (s.skipped && s.skipped['too-recent']) || 0;
    parts.push(recent
      ? `Nothing to move yet — ${recent} ${recent === 1 ? 'model has' : 'models have'} been used in the last ${s.keepDays} days.`
      : 'Nothing to move — the library is already as small as this setting allows.');
    status.style.color = 'var(--text-muted)';
  }
  if (s.alreadyTiered > 0) parts.push(`${s.alreadyTiered} already in the cloud.`);
  status.textContent = parts.join(' ');
}

function savePrintLibTier() {
  const days = Number($('#set_plibTierDays')?.value);
  settings.printLibrary = Object.assign({}, settings.printLibrary, {
    tier: {
      enabled: !!$('#set_plibTierOn')?.checked,
      // Main normalises this too; doing it here as well means the box shows the
      // value that will actually be used rather than the one that was typed.
      keepDays: Number.isFinite(days) && days >= 1 ? Math.floor(days) : 90,
    },
  });
  saveAll();
  renderPrintLibTier();
  toast(t('set.plib_tier_saved') || 'Cloud storage settings saved', 'success');
}

/**
 * Run a sweep, having said out loud what it will delete.
 *
 * Confirmed because it removes models from this computer. The confirmation names
 * the count and the space, since "are you sure?" with no figures is a dialog
 * people learn to dismiss.
 */
async function runPrintLibTier() {
  const out = $('#plibTierResult');
  if (!window.hubAPI?.printLibTierRun) return;
  savePrintLibTier();

  let s;
  try { s = await window.hubAPI.printLibTierScan(); } catch (_) { s = null; }
  if (!s || !s.ok) { if (out) { out.textContent = '✗ ' + ((s && s.error) || 'Could not check the library.'); out.style.color = 'var(--danger)'; } return; }
  if (!s.configured) { toast(t('set.plib_tier_no_bucket') || 'Add your object storage details first', 'error'); return; }
  if (!s.count) { if (out) { out.textContent = t('set.plib_tier_nothing') || 'Nothing to move right now.'; out.style.color = 'var(--text-muted)'; } return; }

  const ok = confirm(
    `${s.count} ${s.count === 1 ? 'model' : 'models'} will be uploaded and then removed from this computer, freeing ${s.human}.\n\n`
    + 'Each file is checked in the cloud before the local copy goes. They stay in your library and download again automatically when you open them.\n\n'
    + 'Continue?',
  );
  if (!ok) return;

  if (window.hubAPI.onPrintLibTierProgress) {
    window.hubAPI.onPrintLibTierProgress((p) => {
      if (!out || !p) return;
      if (p.phase === 'file') { out.textContent = `Uploading ${p.filename}… (${p.done}/${p.total})`; out.style.color = 'var(--text-muted)'; }
    });
  }
  if (out) { out.textContent = t('set.plib_tier_running') || 'Working…'; out.style.color = 'var(--text-muted)'; }

  let r;
  try { r = await window.hubAPI.printLibTierRun(); } catch (err) { r = { ok: false, error: String(err.message || err) }; }
  if (!out) return;
  if (!r || !r.ok) { out.textContent = '✗ ' + ((r && r.error) || 'Could not free up space.'); out.style.color = 'var(--danger)'; return; }

  // Failures are named, not counted. "3 files failed" leaves the shop unable to
  // tell whether it was three thumbnails or three customer models.
  const bits = [`✓ Moved ${r.moved} of ${r.attempted}, freeing ${r.human}.`];
  if (r.failed && r.failed.length) {
    bits.push(`${r.failed.length} left on this computer: ` + r.failed.slice(0, 3).map((f) => `${f.filename} (${f.error})`).join('; '));
    if (r.failed.length > 3) bits.push(`…and ${r.failed.length - 3} more.`);
  }
  out.textContent = bits.join(' ');
  out.style.color = r.failed && r.failed.length ? 'var(--warning, #d97706)' : 'var(--success, #16a34a)';
  renderPrintLibTier();
}

/**
 * The way out. A feature that deletes local files and cannot be reversed is a
 * trap, and a shop leaving Khayt must be able to get its models back without
 * knowing what an object key is.
 */
async function restorePrintLibTier() {
  const out = $('#plibTierResult');
  if (!window.hubAPI?.printLibTierRestoreAll) return;
  if (!confirm('Download every model that is currently in the cloud back onto this computer?\n\nThis needs enough free disk space for all of them.')) return;

  if (window.hubAPI.onPrintLibTierProgress) {
    window.hubAPI.onPrintLibTierProgress((p) => {
      if (!out || !p) return;
      if (p.phase === 'file') { out.textContent = `Downloading ${p.filename}… (${p.done}/${p.total})`; out.style.color = 'var(--text-muted)'; }
    });
  }
  if (out) { out.textContent = t('set.plib_tier_running') || 'Working…'; out.style.color = 'var(--text-muted)'; }

  let r;
  try { r = await window.hubAPI.printLibTierRestoreAll(); } catch (err) { r = { ok: false, error: String(err.message || err) }; }
  if (!out) return;
  if (!r || !r.ok) { out.textContent = '✗ ' + ((r && r.error) || 'Could not bring the files back.'); out.style.color = 'var(--danger)'; return; }
  out.textContent = r.failed && r.failed.length
    ? `Brought back ${r.restored} of ${r.attempted}. Still in the cloud: ` + r.failed.slice(0, 3).map((f) => `${f.filename} (${f.error})`).join('; ')
    : `✓ Brought back ${r.restored} ${r.restored === 1 ? 'model' : 'models'}.`;
  out.style.color = r.failed && r.failed.length ? 'var(--warning, #d97706)' : 'var(--success, #16a34a)';
  renderPrintLibTier();
}

/**
 * Record the folder the library is leaving, so it stays readable.
 *
 * Main decides what the history should be (rememberRoot); this only stores the
 * answer. Without it a second move drops the first custom folder out of the
 * known roots, and files that are merely in the wrong place become unreachable.
 */
async function printLibRootPatch(which, next) {
  const patch = { [which]: next };
  if (which !== 'root' || !window.hubAPI?.printLibRememberRoot) return patch;
  try {
    const r = await window.hubAPI.printLibRememberRoot(next);
    if (r && Array.isArray(r.history)) patch.history = r.history;
  } catch (_) { /* the move still works; only the old root is forgotten */ }
  return patch;
}

/** Pick a folder for the library or its backup, and persist it. */
async function pickPrintLibFolder(which) {
  if (!window.hubAPI?.printLibPickFolder) return;
  let r;
  try { r = await window.hubAPI.printLibPickFolder(); } catch (err) { toast(String(err.message || err), 'error'); return; }
  if (!r) return;                                  // cancelled
  if (!r.ok) { toast(r.error || t('set.plib_choose_failed') || 'Could not use that folder', 'error'); return; }
  settings.printLibrary = Object.assign({}, settings.printLibrary, await printLibRootPatch(which, r.path));
  saveAll();
  renderPrintLibLocation();
  toast(t('set.plib_saved') || 'Print library location updated', 'success');
}

async function clearPrintLibFolder(which) {
  settings.printLibrary = Object.assign({}, settings.printLibrary, await printLibRootPatch(which, ''));
  saveAll();
  renderPrintLibLocation();
}

/**
 * Offer to bring in whatever is still sitting in a folder the library has left.
 *
 * Shown only when there is something to move. The count and size are the point:
 * "some files" is not enough for anyone to tell whether this is the thing that
 * emptied their library.
 */
async function scanPrintLibMigrate() {
  const box = $('#plibMoveBox');
  const what = $('#plibMoveWhat');
  if (!box || !window.hubAPI?.printLibMigrateScan) return;
  let r;
  try { r = await window.hubAPI.printLibMigrateScan(); } catch (_) { r = null; }
  if (!r || !r.ok || !r.files) { box.style.display = 'none'; return; }
  box.style.display = '';
  const mb = (n) => (n >= 1e9 ? `${(n / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(n / 1e6))} MB`);
  const where = r.roots.map((x) => x.root).join(', ');
  if (what) {
    what.textContent = (t('set.plib_move_what') || '{n} files ({size}) are still in {from}. The library now reads from {to}, so they do not show up.')
      .replace('{n}', r.files).replace('{size}', mb(r.bytes)).replace('{from}', where).replace('{to}', r.to);
  }
  const btn = $('#btnPlibMove');
  // A move that cannot fit is refused here rather than half-done on disk.
  if (btn) btn.disabled = !(r.space && r.space.ok);
  const out = $('#plibMoveResult');
  if (out && r.space && !r.space.ok) {
    out.textContent = '⚠ ' + (t('set.plib_move_space') || 'Not enough room in the new folder.');
    out.style.color = 'var(--danger)';
  }
}

async function runPrintLibMigrate() {
  const btn = $('#btnPlibMove');
  const out = $('#plibMoveResult');
  if (!window.hubAPI?.printLibMigrateRun) return;
  if (btn) btn.disabled = true;
  if (out) { out.textContent = t('set.plib_move_working') || 'Moving…'; out.style.color = 'var(--text-muted)'; }
  if (window.hubAPI.onPrintLibMigrateProgress) {
    window.hubAPI.onPrintLibMigrateProgress((p) => {
      if (out && p && p.total) out.textContent = `${p.done} / ${p.total} — ${p.file || ''}`;
    });
  }
  let r;
  try { r = await window.hubAPI.printLibMigrateRun(); } catch (err) { r = { ok: false, error: String(err.message || err) }; }
  if (btn) btn.disabled = false;
  if (!out) return;
  if (!r || !r.ok) {
    out.textContent = '✗ ' + ((r && r.error) || '');
    out.style.color = 'var(--danger)';
    return;
  }
  // Report the awkward outcomes too. A count of files moved, with three
  // failures folded into it, is the kind of success message that gets believed.
  const bits = [(t('set.plib_move_done') || '{n} moved').replace('{n}', r.moved)];
  if (r.duplicates) bits.push((t('set.plib_move_dupes') || '{n} already here').replace('{n}', r.duplicates));
  if (r.collisions) bits.push((t('set.plib_move_renamed') || '{n} renamed to avoid overwriting').replace('{n}', r.collisions));
  if (r.failed) bits.push((t('set.plib_move_failed') || '{n} left in place — see the log').replace('{n}', r.failed));
  out.textContent = (r.failed ? '⚠ ' : '✓ ') + bits.join(' · ');
  out.style.color = r.failed ? 'var(--warning, #d97706)' : 'var(--success, #16a34a)';
  if (r.errors && r.errors.length) console.warn('print library move:', r.errors);
  scanPrintLibMigrate();
  renderPrintLibLocation();
}

/**
 * Format one plan's price for display: "$9" / "35 SAR" / the Free tier's word.
 * Symbol-before for USD, code-after for SAR, which is how each is normally
 * written — and the SAR code rather than ﷼ because the glyph does not render
 * on every platform Khayt ships to.
 */
function cloudPlanPriceText(price) {
  if (!price) return '';
  if (price.free) return t('plans.price_free') || 'Free';
  return price.currency === 'USD' ? `$${price.amount}` : `${price.amount} ${price.currency}`;
}

/**
 * The Khayt Cloud price ladder.
 *
 * Every paid figure renders struck through beside "Free during beta" while
 * KhaytCloudPlans.BETA_FREE is on. Showing the real price now — rather than a
 * blank or a "pricing TBA" — is the point: a shop should not build on Khayt
 * Cloud and discover a price afterwards. See lib/cloud-plans.js.
 *
 * Guarded on the global because settings.js is shared with the other flavor,
 * which does not load this module and has its own separate pricing line — same
 * pattern as KhaytTiers in build.js.
 */
/**
 * The free tier's portal trial, shown only when it means something.
 *
 * During beta it renders NOTHING: the plans block directly below already says
 * every plan is free, and a second banner counting down a clock that is not
 * running would contradict it. `isTrialVisible` is the single place that decides.
 */
function cloudPortalTrialHtml() {
  if (typeof KhaytPortalTrial === 'undefined') return '';
  const Trial = KhaytPortalTrial;
  const c = settings.cloud || {};
  const s = Trial.portalTrialState({
    betaFree: (typeof KhaytCloudPlans !== 'undefined') ? KhaytCloudPlans.isBetaFree() : true,
    subscribed: c.planActive === true,
    startedAt: c.portalTrialStartedAt || null,
    now: Date.now(),
  });
  if (!Trial.isTrialVisible(s.state)) return '';

  const over = s.state === 'expired';
  const msg = over
    ? (t('trial.portal_over') || 'Your 30-day portal trial has ended — subscribe to keep publishing links')
    : (t('trial.portal_left') || '{n} days left in your portal trial').replace('{n}', s.daysLeft);
  // Tint carries the state; the text stays on the theme's normal foreground, so
  // it cannot fail contrast in a light theme the way a coloured text token can.
  const tint = over ? 'var(--danger,#dc2626)' : 'var(--warning,#d97706)';
  return `
    <p style="font-size:11.5px;margin:0 0 10px;padding:6px 9px;border-radius:6px;background:color-mix(in srgb, ${tint} 12%, transparent);border:1px solid color-mix(in srgb, ${tint} 55%, transparent);">
      ${escapeHtml(msg)}
    </p>`;
}

function cloudPlansHtml() {
  if (typeof KhaytCloudPlans === 'undefined') return '';
  const Plans = KhaytCloudPlans;   // bind once: every later read is then guarded by construction
  const lang = (typeof i18n !== 'undefined' && i18n.current) || 'en';
  const rows = Plans.planComparison(lang, settings.currency);
  const betaFree = Plans.isBetaFree();

  const card = (p) => {
    const priceText = escapeHtml(cloudPlanPriceText(p.price));
    // Struck through, dimmed and marked aria-hidden-ish for meaning: the number
    // is information about the future, not the amount due today.
    const price = p.price.strike
      ? `<s style="color:var(--text-muted);font-weight:600;">${priceText}</s>`
      : `<span style="font-weight:700;">${priceText}</span>`;
    const per = p.price.free ? '' :
      `<span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('plans.per_month') || '/mo')}</span>`;
    // Colour carries meaning through the TINT, never through the text colour.
    // --success and --warning are not defined by every theme (flow defines
    // neither), so they fall back to the styles.css defaults — and #f5a623 as
    // text on a light background is the 1.77:1 contrast failure that shipped in
    // beta.18. A tinted panel with normal-coloured text cannot fail that way.
    const now = p.price.strike
      ? `<div style="display:inline-block;font-size:11.5px;font-weight:700;margin-top:3px;padding:1px 7px;border-radius:999px;background:color-mix(in srgb, var(--success,#16a34a) 18%, transparent);">${escapeHtml(t('plans.free_during_beta') || 'Free during beta')}</div>`
      : '';
    const soon = p.soon
      ? `<span style="font-size:10.5px;font-weight:600;color:var(--text-muted);border:1px solid var(--border,#3a3a3a);border-radius:999px;padding:1px 6px;margin-inline-start:6px;">${escapeHtml(t('plans.soon') || 'Not built yet')}</span>`
      : '';
    return `
      <div style="flex:1 1 180px;min-width:170px;border:1px solid var(--border,#3a3a3a);border-radius:8px;padding:10px 12px;">
        <div style="font-weight:600;font-size:13px;margin-bottom:2px;">${escapeHtml(p.label)}${soon}</div>
        <div style="display:flex;align-items:baseline;gap:3px;">${price}${per}</div>
        ${now}
        <div style="font-size:11.5px;color:var(--text-muted);margin:6px 0 8px;">${escapeHtml(p.tagline)}</div>
        <ul style="margin:0;padding-inline-start:16px;font-size:11.5px;line-height:1.55;">
          ${p.features.map((f) => `<li>${escapeHtml(f.label)}</li>`).join('')}
        </ul>
      </div>`;
  };

  return `
    <div style="margin-top:14px;border-top:1px solid var(--border,#3a3a3a);padding-top:12px;">
      ${cloudPortalTrialHtml()}
      <p style="font-size:12.5px;font-weight:600;margin:0 0 2px;">${escapeHtml(t('plans.title') || 'What Khayt Cloud costs')}</p>
      <p style="font-size:11.5px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(t('plans.intro') || 'The desktop app is free forever and works with no account. These prices are only for the hosted service.')}</p>
      ${betaFree ? `<p style="font-size:11.5px;margin:0 0 10px;padding:6px 9px;border-radius:6px;background:color-mix(in srgb, var(--success,#16a34a) 12%, transparent);border:1px solid color-mix(in srgb, var(--success,#16a34a) 55%, transparent);">${escapeHtml(t('plans.beta_note') || 'Khayt Cloud is in beta, so every plan is free right now. The prices below are what they will cost, shown early so nothing comes as a surprise later.')}</p>` : ''}
      <div style="display:flex;gap:8px;flex-wrap:wrap;">${rows.map(card).join('')}</div>
    </div>`;
}

function renderCloudSettings() {
  const el = $('#cloudSettingsSection');
  if (!el) return;
  wireCloudSyncStatusOnce();
  const c = settings.cloud || {};
  const connected = !!(c.enabled && c.shopId);
  const syncStatus = (connected && window.KhaytCloudSync) ? cloudSyncStatusLabel(KhaytCloudSync.status()) : '';
  const showUnverified = connected && c.email && c.verified === false;
  el.innerHTML = `
    ${connected ? `<p style="font-size:12.5px;margin:0 0 8px;">${escapeHtml(t('cloud.signed_in_as') || 'Signed in as')}: <strong>${escapeHtml(c.email || c.shopId)}</strong> · <span style="color:var(--text-muted);">${escapeHtml(c.url || '')}</span> <span id="cloudSyncStatus" style="font-size:12px;margin-inline-start:6px;color:var(--text-muted);">${escapeHtml(syncStatus)}</span></p>` : ''}
    ${showUnverified ? `<div style="background:color-mix(in srgb, var(--warning,#d97706) 14%, transparent);border:1px solid var(--warning,#d97706);border-radius:6px;padding:8px 10px;margin:0 0 8px;font-size:12.5px;">⚠ ${escapeHtml(t('cloud.unverified') || 'Email not verified.')} <button id="btnCloudVerify" class="btn small" style="margin-inline-start:6px;">${escapeHtml(t('cloud.verify_email') || 'Verify email')}</button></div>` : ''}
    ${connected ? `<p id="cloudPlan" style="font-size:12.5px;margin:0 0 8px;color:var(--text-muted);"></p>` : ''}
    <label>${escapeHtml(t('cloud.url') || 'Server URL')}</label>
    <input type="text" id="cloudUrl" value="${escapeHtml(c.url || 'https://cloud.khaytapp.com')}" ${connected ? 'disabled' : ''} placeholder="https://cloud.khaytapp.com">
    ${!connected ? `
      <label style="margin-top:8px;">${escapeHtml(t('cloud.email') || 'Email')}</label>
      <input type="email" id="cloudEmail" placeholder="you@example.com" autocomplete="username">
      <label style="margin-top:8px;">${escapeHtml(t('cloud.password') || 'Account password')}</label>
      <input type="password" id="cloudAcctPass" placeholder="${escapeHtml(t('cloud.password_ph') || 'signs you in on any device (8+ chars)')}" autocomplete="current-password">
      <label style="margin-top:8px;">${escapeHtml(t('cloud.passphrase') || 'Sync passphrase')}</label>
      <input type="password" id="cloudPass" placeholder="${escapeHtml(t('cloud.passphrase_ph') || 'encrypts your data — never uploaded')}">
      <p style="font-size:11.5px;color:var(--text-muted);margin:6px 0 0;">${escapeHtml(t('cloud.passphrase_explain') || 'The sync passphrase encrypts your data and is never sent to the server. Same passphrase on every device.')}</p>
      <label style="margin-top:8px;">${escapeHtml(t('cloud.secret') || 'Invite secret (optional)')}</label>
      <input type="password" id="cloudSecret" placeholder="${escapeHtml(t('cloud.secret_ph') || 'only if your server requires one for sign-up')}">
      <div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
        <button id="btnCloudSignup" class="btn primary small">${escapeHtml(t('cloud.signup') || 'Create account')}</button>
        <button id="btnCloudLogin" class="btn small">${escapeHtml(t('cloud.login') || 'Log in (existing)')}</button>
        <button id="btnCloudJoin" class="btn small">${escapeHtml(t('team.join') || 'Join a team')}</button>
        <button id="btnCloudForgot" class="btn ghost small">${escapeHtml(t('cloud.forgot') || 'Forgot password?')}</button>
        <span id="cloudResult" style="font-size:12px;"></span>
      </div>`
    : `
      <label style="margin-top:8px;">${escapeHtml(t('cloud.passphrase') || 'Sync passphrase')}</label>
      <input type="password" id="cloudPass" placeholder="${escapeHtml(t('cloud.unlock_ph') || 'enter to unlock this session')}">
      <div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
        <button id="btnCloudUnlock" class="btn small">${escapeHtml(t('cloud.unlock') || 'Unlock')}</button>
        <button id="btnCloudSync" class="btn small">${escapeHtml(t('cloud.sync_now') || 'Sync now')}</button>
        <button id="btnCloudRestore" class="btn small">${escapeHtml(t('cloud.restore') || 'Restore from cloud')}</button>
        <button id="btnCloudSnapshots" class="btn small">🕑 ${escapeHtml(t('cloud.snapshots') || 'Snapshot history')}</button>
        <button id="btnCloudRequests" class="btn small">🛎 ${escapeHtml(t('intake.requests') || 'Order requests')}</button>
        <button id="btnCloudIntakeLink" class="btn ghost small">${escapeHtml(t('intake.copy_link') || 'Copy request link')}</button>
        ${(settings.cloud?.role || 'owner') === 'owner' ? `<button id="btnCloudTeam" class="btn small">👥 ${escapeHtml(t('team.title') || 'Team')}</button>` : ''}
        ${(settings.cloud?.role || 'owner') === 'owner' ? `<button id="btnCloudOrg" class="btn small">🏢 ${escapeHtml(t('org.title') || 'Organisation')}</button>` : ''}
        ${(settings.cloud?.role || 'owner') === 'owner' ? `<button id="btnCloudStorefront" class="btn small">🏬 ${escapeHtml(t('store.title') || 'Storefront')}</button>` : ''}
        <button id="btnCloudDisconnect" class="btn danger small">${escapeHtml(t('cloud.disconnect') || 'Sign out')}</button>
        <span id="cloudResult" style="font-size:12px;"></span>
      </div>
      ${(settings.cloud?.role || 'owner') === 'owner' ? `
      <!-- A shop id is shop_282eb707… — not something anyone puts on a card. -->
      <label style="margin-top:12px;">${escapeHtml(t('cloud.slug_label') || 'Public web address')}</label>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
        <span style="font-size:12px;color:var(--text-muted);" dir="ltr">${escapeHtml(String(settings.cloud?.url || '').replace(/\/+$/, ''))}/shop/</span>
        <input type="text" id="cloudSlug" dir="ltr" spellcheck="false" maxlength="32" style="width:180px;"
               placeholder="${escapeHtml(t('cloud.slug_ph') || 'your-shop-name')}">
        <button id="btnCloudSlug" class="btn small">${escapeHtml(t('common.save') || 'Save')}</button>
        <span id="cloudSlugResult" style="font-size:12px;"></span>
      </div>
      <p style="font-size:11.5px;color:var(--text-muted);margin:6px 0 0;">${escapeHtml(t('cloud.slug_hint') || 'Lower case letters, numbers and hyphens. Your old address keeps working for 90 days if you change it, and the original link never stops working.')}</p>` : ''}`}
    ${cloudPlansHtml()}`;

  const result = (msg, color) => { const r = el.querySelector('#cloudResult'); if (r) { r.textContent = msg; r.style.color = color || 'var(--text-muted)'; } };

  // Shared validation for the not-connected form. Returns {url,email,password,pass,secret} or null.
  const readConnectForm = async () => {
    const url = el.querySelector('#cloudUrl').value.trim();
    const email = el.querySelector('#cloudEmail').value.trim();
    const password = el.querySelector('#cloudAcctPass').value;
    const pass = el.querySelector('#cloudPass').value;
    const secret = el.querySelector('#cloudSecret').value.trim();
    if (!url) { result(t('cloud.need_url') || 'Enter the server URL', 'var(--danger)'); return null; }
    if (!email) { result(t('cloud.need_email') || 'Enter your email', 'var(--danger)'); return null; }
    if (!password || password.length < 8) { result(t('cloud.need_password') || 'Account password must be 8+ chars', 'var(--danger)'); return null; }
    if (!pass || pass.length < 6) { result(t('cloud.need_pass') || 'Choose a sync passphrase (6+ chars)', 'var(--danger)'); return null; }
    result(t('cloud.connecting') || 'Connecting…');
    const hz = await window.hubAPI.cloudHealthDetail(url);
    if (!hz || !hz.ok) { result(cloudReachErrorText(hz, url), 'var(--danger)'); return null; }
    return { url, email, password, pass, secret };
  };

  // Create account: signup → make keyset locally → save → unlock → upload encrypted keyset.
  el.querySelector('#btnCloudSignup')?.addEventListener('click', async () => {
    const f = await readConnectForm(); if (!f) return;
    const su = await window.hubAPI.cloudSignup({ url: f.url, email: f.email, password: f.password, registerSecret: f.secret });
    if (!su.ok) { result('✗ ' + (su.error || 'sign-up failed'), 'var(--danger)'); return; }
    const ks = await window.hubAPI.cloudCreateKeyset(f.pass);
    if (!ks.ok) { result('✗ ' + (ks.error || 'keyset failed'), 'var(--danger)'); return; }
    settings.cloud = { enabled: true, url: f.url, email: f.email, accountId: su.accountId, shopId: su.shopId, token: su.token, keyset: ks.keyset, lastServerRev: 0, verified: false, role: 'owner' };
    syncScopeToShop(); // this store now has a shop id — see app-state.js
    saveAll();
    await window.hubAPI.cloudUnlock({ url: f.url, shopId: su.shopId, token: su.token, keyset: ks.keyset, passphrase: f.pass });
    const up = await window.hubAPI.cloudPutKeyset({ url: f.url, shopId: su.shopId, token: su.token, keyset: ks.keyset });
    if (!up.ok) { result('✗ ' + (up.error || 'could not save keyset'), 'var(--danger)'); return; }
    /* ASK FOR THE CODE WHILE THE SHOP IS HOLDING IT.
     *
     * Sign-up sends a verification email, and this used to end with a success
     * toast and a warning banner in the cloud settings panel — a panel the shop
     * has just finished with, behind the recovery-key modal it was reading. So
     * the code arrived and there was visibly nowhere to type it. Reported
     * exactly that way: "I got an email with a code but nowhere to enter it."
     *
     * The banner and its button stay: somebody who closes this, or whose email
     * takes a few minutes, still needs a way back. But the moment the email is
     * sent is the moment to ask, and the recovery key has to be acknowledged
     * first — it is shown once and losing it loses the data. */
    showRecoveryKeyModal(ks.recoveryKey, () => {
      // Not when the server could not send it: there is no code coming, and a
      // box waiting for one would be a worse lie than the toast below.
      // No sender argument: /v1/signup does not return one (only /v1/request-verify
      // does), and passing `su.sender` would be a parameter that is always
      // undefined — a branch that reads as handled and cannot run. The modal
      // renders correctly without it and simply omits the "sent from" line.
      // Two separate reasons no code is coming, and both have to be checked.
      // emailFailed is "we tried, the provider refused". emailConfigured:false
      // is "this server has no mail set up at all" — the self-hosting case,
      // which used to fall through to the dialog because the client parser
      // dropped the field, leaving a box waiting for a code that did not exist.
      if (su.emailConfigured !== false && !su.emailFailed) showVerifyEmailModal(f.url, f.email);
    });
    await enableCloudAutoSync({ initialPull: false }); // new shop: just push local
    renderCloudSettings();
    toast(t('cloud.account_created') || 'Account created — Khayt Cloud connected', 'success');
    // Sign-up succeeds either way, but the welcome/verification email may not
    // have gone. Saying so now beats the shop discovering it when the code they
    // are waiting for never arrives.
    if (su.emailConfigured === false) {
      toast(t('cloud.reset_no_email') || 'This server has no email set up — contact the admin', 'warning', 8000);
    } else if (su.emailFailed) {
      toast(t('cloud.email_refused_signup')
        || 'Account created, but the verification email could not be sent — contact the admin', 'warning', 8000);
    }
  });

  // Log in (existing account, e.g. a second device): login → get encrypted keyset → unlock with passphrase.
  el.querySelector('#btnCloudLogin')?.addEventListener('click', async () => {
    const f = await readConnectForm(); if (!f) return;
    const lr = await window.hubAPI.cloudLogin({ url: f.url, email: f.email, password: f.password });
    if (!lr.ok) { result('✗ ' + (lr.error || 'login failed'), 'var(--danger)'); return; }
    let keyset = lr.keyset;
    let recoveryKey = null;
    if (!keyset) {
      // Account exists but never finished keyset setup — create one now from this passphrase.
      const ks = await window.hubAPI.cloudCreateKeyset(f.pass);
      if (!ks.ok) { result('✗ ' + (ks.error || 'keyset failed'), 'var(--danger)'); return; }
      keyset = ks.keyset; recoveryKey = ks.recoveryKey;
    }
    settings.cloud = { enabled: true, url: f.url, email: f.email, shopId: lr.shopId, token: lr.token, keyset, lastServerRev: 0, verified: !!lr.verified, role: lr.role || 'owner' };
    syncScopeToShop(); // this store now has a shop id — see app-state.js
    saveAll();
    const un = await window.hubAPI.cloudUnlock({ url: f.url, shopId: lr.shopId, token: lr.token, keyset, passphrase: f.pass });
    if (!un.ok) { result('✗ ' + (t('cloud.wrong_pass') || 'Wrong sync passphrase for this account'), 'var(--danger)'); renderCloudSettings(); return; }
    if (recoveryKey) {
      // The keyset was created HERE and exists nowhere else yet. Showing a
      // recovery key before the server has it tells the owner their shop is
      // recoverable when it is not — it would live on this machine alone.
      const saved = await putCloudKeyset({ url: f.url, shopId: lr.shopId, token: lr.token, keyset }, 'first keyset');
      if (saved) showRecoveryKeyModal(recoveryKey);
      else toast(t('cloud.keyset_retry')
        || 'Sync is not finished: your key is not on the server yet. Log in again once you are back online, before relying on this shop being recoverable.', 'error', 15000);
    }
    // Configure auto-sync but DON'T auto-pull on a new device — let the user
    // click "Restore from cloud" (full replace) to populate, then it stays synced.
    if (window.KhaytCloudSync) KhaytCloudSync.configure(cloudSyncDeps());
    renderCloudSettings();
    toast(t('cloud.logged_in') || 'Logged in — use “Restore from cloud” to pull your data', 'success');
  });

  // Join a team: accept an emailed invite → member account in the shared shop.
  el.querySelector('#btnCloudJoin')?.addEventListener('click', async () => {
    const f = await readConnectForm(); if (!f) return;
    openFormModal({
      title: t('team.join') || 'Join a team',
      saveLabel: t('team.join') || 'Join',
      bodyHtml: `<p style="color:var(--text-muted);font-size:12.5px;margin:0 0 10px;">${escapeHtml(t('team.join_hint') || 'Enter the invite code from your shop owner. Use your own email + password (above) and the shop’s shared sync passphrase.')}</p>
        <label>${escapeHtml(t('team.code') || 'Invite code')}</label><input id="joinCode" autocomplete="off" style="text-transform:uppercase;">`,
      onSave: async (modal) => {
        const code = modal.querySelector('#joinCode').value.trim();
        if (!code) { toast(t('team.code') || 'Invite code', 'error'); return false; }
        const r = await window.hubAPI.cloudAcceptInvite({ url: f.url, email: f.email, password: f.password, code });
        if (!r.ok) { toast('✗ ' + (r.error || 'join failed'), 'error'); return false; }
        if (!r.keyset) { toast(t('team.no_keyset') || 'The owner hasn’t set up sync yet — ask them to enable Khayt Cloud first.', 'error'); return false; }
        settings.cloud = { enabled: true, url: f.url, email: f.email, shopId: r.shopId, token: r.token, keyset: r.keyset, lastServerRev: 0, verified: false, role: r.role || 'operator' };
        syncScopeToShop(); // this store now has a shop id — see app-state.js
        saveAll();
        const un = await window.hubAPI.cloudUnlock({ url: f.url, shopId: r.shopId, token: r.token, keyset: r.keyset, passphrase: f.pass });
        renderCloudSettings();
        if (!un.ok) { toast(t('cloud.wrong_pass') || 'Wrong shared sync passphrase', 'error'); return true; }
        if (window.KhaytCloudSync) KhaytCloudSync.configure(cloudSyncDeps());
        toast(t('team.joined') || 'Joined the team — use “Restore from cloud” to pull data', 'success');
        return true;
      },
    });
  });

  // Forgot password: email a reset code, then open the reset modal.
  el.querySelector('#btnCloudForgot')?.addEventListener('click', async () => {
    const url = el.querySelector('#cloudUrl').value.trim();
    const email = el.querySelector('#cloudEmail').value.trim();
    if (!url) { result(t('cloud.need_url') || 'Enter the server URL', 'var(--danger)'); return; }
    if (!email) { result(t('cloud.need_email') || 'Enter your email first', 'var(--danger)'); return; }
    result(t('cloud.connecting') || 'Connecting…');
    const hz = await window.hubAPI.cloudHealthDetail(url);
    if (!hz || !hz.ok) { result(cloudReachErrorText(hz, url), 'var(--danger)'); return; }
    const r = await window.hubAPI.cloudRequestReset({ url, email });
    if (!r.ok) { result('✗ ' + (r.error || 'request failed'), 'var(--danger)'); return; }
    if (!r.emailConfigured) { result(t('cloud.reset_no_email') || 'This server has no email set up — contact the admin', 'var(--danger)'); return; }
    // The server tried and the provider turned it away. Opening the code dialog
    // here would ask the shop to wait for a message that was never accepted.
    if (r.emailFailed) { result(t('cloud.email_refused') || 'The server could not send the email — contact the admin', 'var(--danger)'); return; }
    result('');
    showResetPasswordModal(url, email);
  });

  // Verify email: (re)send a code, then open the verify modal.
  el.querySelector('#btnCloudVerify')?.addEventListener('click', async () => {
    const rv = await window.hubAPI.cloudRequestVerify({ url: c.url, email: c.email });
    if (rv.ok && rv.alreadyVerified) { if (settings.cloud) { settings.cloud.verified = true; saveAll(); } renderCloudSettings(); toast(t('cloud.verify_done') || 'Email verified ✓', 'success'); return; }
    if (!rv.ok) { toast('✗ ' + (rv.error || 'could not send code'), 'error'); return; }
    if (!rv.emailConfigured) { toast(t('cloud.reset_no_email') || 'This server has no email set up — contact the admin', 'error'); return; }
    if (rv.emailFailed) { toast(t('cloud.email_refused') || 'The server could not send the email — contact the admin', 'error', 6000); return; }
    showVerifyEmailModal(c.url, c.email, rv.sender);
  });

  el.querySelector('#btnCloudUnlock')?.addEventListener('click', async () => {
    const pass = el.querySelector('#cloudPass').value;
    const r = await window.hubAPI.cloudUnlock({ url: c.url, shopId: c.shopId, token: c.token, keyset: c.keyset, passphrase: pass });
    if (r.ok) {
      result('✓ ' + (t('cloud.unlocked') || 'Unlocked'), 'var(--success)');
      await enableCloudAutoSync({ initialPull: true }); // same device returning: merge in changes from elsewhere
    } else {
      result('✗ ' + (t('cloud.wrong_pass') || 'Wrong passphrase'), 'var(--danger)');
    }
  });

  el.querySelector('#btnCloudSync')?.addEventListener('click', async () => {
    result(t('cloud.syncing') || 'Syncing…');
    // Prefer the auto-sync controller (handles conflicts via pull+merge+re-push).
    if (window.KhaytCloudSync && KhaytCloudSync.isOn()) {
      const r = await KhaytCloudSync.syncNow();
      if (r.ok) { settings.cloud.lastServerRev = r.rev; saveAll(); result('✓ ' + (t('cloud.synced') || 'Synced') + ' (rev ' + r.rev + ')', 'var(--success)'); }
      else if (r.error === 'locked') result('✗ ' + (t('cloud.locked') || 'Unlock first (enter passphrase)'), 'var(--danger)');
      else result('✗ ' + (r.error || 'sync failed'), 'var(--danger)');
      return;
    }
    // Fallback (not unlocked this session): a plain push.
    const r = await window.hubAPI.cloudPush(buildStoreSnapshot());
    if (r.ok && !r.conflict) { settings.cloud.lastServerRev = r.rev; saveAll(); result('✓ ' + (t('cloud.synced') || 'Synced') + ' (rev ' + r.rev + ')', 'var(--success)'); }
    else if (r.conflict) result('⚠ ' + (t('cloud.conflict') || 'Server has newer data — Restore from cloud first'), 'var(--warning, #d97706)');
    else if (r.error === 'locked') result('✗ ' + (t('cloud.locked') || 'Unlock first (enter passphrase)'), 'var(--danger)');
    else result('✗ ' + (r.error || 'sync failed'), 'var(--danger)');
  });

  // Restore from cloud: pull the encrypted store, decrypt, and replace local data
  // (keeping THIS device's cloud identity/token). Mirrors the import-backup flow.
  el.querySelector('#btnCloudRestore')?.addEventListener('click', async () => {
    const r = await window.hubAPI.cloudPull();
    if (!r.ok) {
      if (r.error === 'locked') result('✗ ' + (t('cloud.locked') || 'Unlock first (enter passphrase)'), 'var(--danger)');
      else result('✗ ' + (r.error || 'pull failed'), 'var(--danger)');
      return;
    }
    if (!r.store) { result(t('cloud.nothing_yet') || 'Nothing in the cloud yet — Sync now first', 'var(--warning, #d97706)'); return; }
    const ok = await confirmModal(t('cloud.restore_q') || 'Replace all local data with the cloud copy? This cannot be undone.', { danger: true });
    if (!ok) return;
    const keepCloud = Object.assign({}, settings.cloud);
    try {
      // Refuse a snapshot that failed validation — replaceStoreFromSnapshot leaves the
      // existing data untouched when it returns false, so do NOT save or report success.
      if (!replaceStoreFromSnapshot(r.store)) { toast(t('set.restore_error') || 'Restore failed — the file could not be read', 'error'); return; }
      settings.cloud = Object.assign({}, settings.cloud, keepCloud, { lastServerRev: r.rev }); // keep this device's token/login
      saveAll();
      initialRender();
      loadSettingsIntoForm();
      applyTheme(settings.theme);
      i18n.set(settings.lang);
      if (window.KhaytCloudSync) KhaytCloudSync.configure(cloudSyncDeps()); // local now == cloud; keep it synced going forward
      renderCloudSettings();
      toast((t('cloud.restored') || 'Restored from cloud') + ' (rev ' + r.rev + ')', 'success');
    } catch (e) {
      console.error('cloud restore:', e);
      toast(t('cloud.restore_error') || 'Could not restore from cloud', 'error');
    }
  });

  el.querySelector('#btnCloudSnapshots')?.addEventListener('click', () => { openCloudSnapshotsModal(); });

  el.querySelector('#btnCloudRequests')?.addEventListener('click', () => {
    if (typeof openOrderRequestsModal === 'function') openOrderRequestsModal();
  });
  el.querySelector('#btnCloudIntakeLink')?.addEventListener('click', () => {
    if (typeof copyIntakeLink === 'function') copyIntakeLink();
  });
  el.querySelector('#btnCloudTeam')?.addEventListener('click', openTeamModal);
  el.querySelector('#btnCloudOrg')?.addEventListener('click', openOrgModal);
  el.querySelector('#btnCloudStorefront')?.addEventListener('click', openStorefrontModal);

  /* The shop's public web address.
   *
   * The cloud has served /v1/shops/{id}/slug since it shipped, and until now
   * NOTHING in the app called it — the endpoint existed and no shop could reach
   * it, which is the same "built and never plugged in" this repo keeps catching.
   */
  (async () => {
    const slugInput = el.querySelector('#cloudSlug');
    if (!slugInput) return;
    const c = settings.cloud || {};
    const say = (msg, color) => {
      const r = el.querySelector('#cloudSlugResult');
      if (r) { r.textContent = msg || ''; r.style.color = color || 'var(--text-muted)'; }
    };
    try {
      const r = await window.hubAPI.cloudGetSlug({ url: c.url, shopId: c.shopId, token: c.token });
      if (r?.ok && r.slug) slugInput.value = r.slug;
    } catch (e) { /* not fatal: the field simply starts empty */ }

    el.querySelector('#btnCloudSlug')?.addEventListener('click', async () => {
      const slug = slugInput.value.trim().toLowerCase();
      if (!slug) { say(t('cloud.slug_empty') || 'Type a name first.', 'var(--danger)'); return; }
      say(t('common.saving') || 'Saving…');
      const r = await window.hubAPI.cloudSetSlug({ url: c.url, shopId: c.shopId, token: c.token, slug });
      // The server owns the rules — reserved words, what is already taken — so
      // its message is the one worth showing rather than a guess made here.
      if (!r?.ok) { say(r?.error || (t('cloud.slug_failed') || 'Could not save that name.'), 'var(--danger)'); return; }
      slugInput.value = r.slug;
      say(t('cloud.slug_saved') || 'Saved — your shop is reachable at that address.', 'var(--success)');
    });
  })();

  el.querySelector('#btnCloudDisconnect')?.addEventListener('click', async () => {
    if (!(await confirmModal(t('cloud.disconnect_q') || 'Sign out of Khayt Cloud on this device? Local data stays; the cloud copy is kept.', { danger: true }))) return;
    if (window.KhaytCloudSync) KhaytCloudSync.stop(); // halt background auto-sync
    await window.hubAPI.cloudLock();
    settings.cloud = Object.assign({}, settings.cloud, { enabled: false });
    saveAll();
    renderCloudSettings();
    toast(t('cloud.disconnected') || 'Signed out', 'success');
  });

  if (connected) showCloudPlan(c); // async; fills #cloudPlan if the server has billing on
}


/**
 * Which languages the shop writes its products in.
 *
 * A different question from which language the app is SHOWN in, and it had
 * never been asked: content was hard-coded to English and Arabic, so a Turkish
 * shop could not enter its own language and an Arabic-only shop still faced an
 * English box it had to leave blank.
 *
 * Capped at two on purpose. Three name fields and three description fields is a
 * form nobody finishes, and the storefront shows one language at a time anyway.
 */

/**
 * The shop's own text, one field per language it writes content in.
 *
 * Business name, tagline, address, invoice footer and terms were five
 * hard-coded English/Arabic pairs. A Turkish shop could not enter its business
 * name in Turkish — the interface translated for it and the invoice a customer
 * receives did not — and an Arabic-only shop faced five English boxes it had to
 * leave blank.
 *
 * The ids stay `set_bizEn` and `set_bizAr` for English and Arabic, and become
 * `set_biz_tr` for anything else, matching lib/content-languages.js. That is
 * what lets loadSettingsIntoForm and the save path keep working unchanged for
 * every shop that stays on the two languages this always had.
 */
function renderContentFields() {
  if (typeof KhaytContentLanguages === 'undefined') return;
  const CL = KhaytContentLanguages;
  const langs = CL.contentLangs(settings);

  const build = (host, base, label, kind) => {
    const el = $(host);
    if (!el) return;
    el.innerHTML = langs.map((lang) => {
      const key = CL.fieldKey(base, lang);
      const rtl = lang === 'ar' ? ' dir="rtl"' : '';
      const val = escapeHtml(settings[key] || '');
      const cap = `${escapeHtml(label)} · ${escapeHtml(CL.languageName(lang))}`;
      const input = kind === 'textarea'
        ? `<textarea id="set_${key}" rows="3"${rtl} style="resize:vertical;">${val}</textarea>`
        : `<input type="text" id="set_${key}"${rtl} value="${val}">`;
      return `<div><label>${cap}</label>${input}</div>`;
    }).join('');
  };

  build('#bizNameFields', 'biz', t('set.biz_name') || 'Business name');
  build('#taglineFields', 'tagline', t('set.tagline') || 'Tagline');
  build('#addressFields', 'addr', t('set.address') || 'Address');
  build('#footerFields', 'footer', t('set.footer') || 'Invoice footer');
  build('#invTermsFields', 'invTerms', t('set.inv_terms') || 'Terms & notes', 'textarea');
}

/** Read the shop's per-language text back out of whatever fields are on screen. */
function readContentFields() {
  const out = {};
  if (typeof KhaytContentLanguages === 'undefined') return out;
  const CL = KhaytContentLanguages;
  for (const base of ['biz', 'tagline', 'addr', 'footer', 'invTerms']) {
    for (const lang of CL.SUPPORTED) {
      const key = CL.fieldKey(base, lang);
      const el = document.getElementById('set_' + key);
      // Only fields that are ON SCREEN. A language the shop has stopped using
      // keeps whatever it had — removing a language must not erase the text,
      // because putting the language back should bring it with it.
      if (el) out[key] = el.value.trim();
    }
  }
  return out;
}

function renderContentLangsPicker() {
  const el = $('#contentLangsPicker');
  if (!el || typeof KhaytContentLanguages === 'undefined') return;
  const CL = KhaytContentLanguages;
  const chosen = CL.contentLangs(settings);
  el.innerHTML = CL.SUPPORTED.map((code) => `
    <label style="display:flex;align-items:center;gap:5px;font-size:12.5px;font-weight:400;margin:0;">
      <input type="checkbox" class="content-lang" value="${escapeHtml(code)}"
             ${chosen.includes(code) ? 'checked' : ''} style="width:auto;margin:0;">
      ${escapeHtml(CL.languageName(code))}
    </label>`).join('');

  el.querySelectorAll('.content-lang').forEach((box) => box.addEventListener('change', () => {
    const picked = [...el.querySelectorAll('.content-lang:checked')].map((b) => b.value);
    if (!picked.length) {
      // A shop with no content language has a product editor with no name
      // field. Refuse rather than allow a form that cannot be filled in.
      box.checked = true;
      toast(t('set.content_langs_min') || 'Pick at least one language for your products', 'warning');
      return;
    }
    if (picked.length > CL.MAX_LANGS) {
      box.checked = false;
      toast(t('set.content_langs_max') || 'Two languages at most', 'warning');
      return;
    }
    settings.contentLangs = picked;
    saveAll();
    renderContentFields();
  renderContentLangsPicker();
    toast(t('set.saved'), 'success');
  }));
}

function renderDigestSettings() {
  const el = $('#emailDigestSection');
  if (!el) return;
  const d = settings.emailDigest || {};
  const hourOpts = Array.from({ length: 24 }, (_, i) =>
    `<option value="${i}" ${(d.hour ?? 8) === i ? 'selected' : ''}>${String(i).padStart(2,'0')}:00</option>`
  ).join('');
  // Weekday names come from Intl, not from locale keys: the digest picker needs
  // all seven in whatever language is active, and Intl already knows them for
  // every language we ship (and every one we don't). 2023-01-01 was a Sunday,
  // so day-of-month i+1 lines up with weekday index i.
  const lang = (typeof i18n !== 'undefined' && i18n.current) || 'en';
  const dayFmt = new Intl.DateTimeFormat(lang, { weekday: 'long' });
  const dayNames = Array.from({ length: 7 }, (_, i) => dayFmt.format(new Date(Date.UTC(2023, 0, i + 1))));
  const dayOpts = dayNames.map((n, i) =>
    `<option value="${i}" ${(d.weekday ?? 1) === i ? 'selected' : ''}>${escapeHtml(n)}</option>`
  ).join('');

  el.innerHTML = `
    <div style="margin-bottom:12px;">
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-top:0;">
        <input type="checkbox" id="digestEnabled" style="width:auto;margin:0;" ${d.enabled ? 'checked' : ''}>
        <span style="font-weight:600;font-size:13px;">${escapeHtml(t('digest.enable') || 'Enable automated email digest')}</span>
      </label>
    </div>
    <div id="digestFields" style="${d.enabled ? '' : 'opacity:.5;pointer-events:none;'}">
      <div style="margin-bottom:10px;">
        <label style="margin-top:0;">${escapeHtml(t('digest.frequency') || 'Frequency')}</label>
        <div style="display:flex;gap:16px;margin-top:4px;">
          <label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:normal;">
            <input type="radio" name="digestFreq" value="daily" ${d.frequency !== 'weekly' ? 'checked' : ''} style="width:auto;margin:0;">
            ${escapeHtml(t('digest.daily') || 'Daily')}
          </label>
          <label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:normal;">
            <input type="radio" name="digestFreq" value="weekly" ${d.frequency === 'weekly' ? 'checked' : ''} style="width:auto;margin:0;">
            ${escapeHtml(t('digest.weekly') || 'Weekly')}
          </label>
          <label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-weight:normal;">
            <input type="radio" name="digestFreq" value="monthly" ${d.frequency === 'monthly' ? 'checked' : ''} style="width:auto;margin:0;">
            ${escapeHtml(t('digest.monthly') || 'Monthly')}
          </label>
        </div>
      </div>
      <div style="display:flex;gap:12px;flex-wrap:wrap;margin-bottom:10px;">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('digest.send_hour') || 'Send at hour')}</label>
          <select id="digestHour" style="font-size:12.5px;">${hourOpts}</select>
        </div>
        <div id="digestWeekdayWrap" style="${d.frequency === 'weekly' ? '' : 'display:none;'}">
          <label style="margin-top:0;">${escapeHtml(t('digest.weekday') || 'Day of week')}</label>
          <select id="digestWeekday" style="font-size:12.5px;">${dayOpts}</select>
        </div>
        <div id="digestMonthdayWrap" style="${d.frequency === 'monthly' ? '' : 'display:none;'}">
          <label style="margin-top:0;">${escapeHtml(t('digest.monthday') || 'Day of month')}</label>
          <select id="digestMonthday" style="font-size:12.5px;">${Array.from({ length: 28 }, (_, i) => `<option value="${i + 1}" ${(d.monthday ?? 1) === i + 1 ? 'selected' : ''}>${i + 1}</option>`).join('')}</select>
        </div>
      </div>
      <div style="margin-bottom:10px;">
        <label style="margin-top:0;">${escapeHtml(t('digest.recipient') || 'Recipient email')}</label>
        <input type="email" id="digestRecipient" value="${escapeHtml(d.recipientEmail || '')}" placeholder="${escapeHtml(settings.email || 'defaults to shop email')}" style="font-size:12.5px;">
      </div>
    </div>
    <div style="display:flex;align-items:center;gap:8px;margin-top:10px;">
      <button id="btnSaveDigest" class="btn small primary">${escapeHtml(t('common.save'))}</button>
      <button id="btnTestDigest" class="btn small">${escapeHtml(t('digest.send_test') || 'Send Test Now')}</button>
      <span id="digestTestResult" style="font-size:12px;color:var(--text-muted);"></span>
    </div>`;

  el.querySelector('#digestEnabled')?.addEventListener('change', (e) => {
    const fields = el.querySelector('#digestFields');
    if (fields) fields.style.cssText = e.target.checked ? '' : 'opacity:.5;pointer-events:none;';
  });

  el.querySelectorAll('[name="digestFreq"]').forEach(r => {
    r.addEventListener('change', () => {
      const freq = el.querySelector('[name="digestFreq"]:checked')?.value;
      const wdWrap = el.querySelector('#digestWeekdayWrap');
      const mdWrap = el.querySelector('#digestMonthdayWrap');
      if (wdWrap) wdWrap.style.display = freq === 'weekly' ? '' : 'none';
      if (mdWrap) mdWrap.style.display = freq === 'monthly' ? '' : 'none';
    });
  });

  el.querySelector('#btnSaveDigest')?.addEventListener('click', () => {
    settings.emailDigest = {
      enabled:        el.querySelector('#digestEnabled').checked,
      frequency:      el.querySelector('[name="digestFreq"]:checked')?.value || 'daily',
      hour:           parseInt(el.querySelector('#digestHour').value, 10) || 8,
      weekday:        parseInt(el.querySelector('#digestWeekday').value, 10) || 1,
      monthday:       parseInt(el.querySelector('#digestMonthday')?.value, 10) || 1,
      recipientEmail: el.querySelector('#digestRecipient').value.trim(),
      lastSentDate:   settings.emailDigest?.lastSentDate || '',
    };
    saveAll();
    toast(t('common.save'), 'success');
  });

  el.querySelector('#btnTestDigest')?.addEventListener('click', async () => {
    const resEl = el.querySelector('#digestTestResult');
    if (resEl) resEl.textContent = '…';
    const cfg = settings.emailConfig;
    if (!cfg || cfg.provider === 'none') {
      if (resEl) resEl.textContent = 'No email provider configured.';
      return;
    }
    const to = (el.querySelector('#digestRecipient').value.trim()) || settings.email || '';
    if (!to) { if (resEl) resEl.textContent = 'No recipient email.'; return; }
    const body = buildDigestEmailHtml();
    const subject = `${shopName() || 'Khayt'} — Test Digest`;
    const result = await window.hubAPI?.sendEmail?.({ to, subject, body, smtpConfig: cfg });
    if (resEl) {
      if (result?.ok) { resEl.textContent = 'Test sent!'; resEl.style.color = 'var(--success)'; }
      else if (result?.fallback) { resEl.textContent = 'mailto: fallback'; resEl.style.color = 'var(--text-muted)'; }
      else { resEl.textContent = 'Failed: ' + (result?.error || ''); resEl.style.color = 'var(--danger)'; }
    }
  });
}

function renderOperatorLockSettings() {
  const el = $('#operatorLockSection');
  if (!el) return;
  const activeOp = settings.activeOperatorId ? operators.find(o => o.id === settings.activeOperatorId) : null;
  el.innerHTML = `
    <div style="font-size:12.5px;color:var(--text-muted);margin-bottom:10px;">
      ${activeOp
        ? `Active operator: <strong>${escapeHtml(activeOp.name)}</strong> (${escapeHtml(activeOp.role || 'no role')})`
        : 'No operator active — all features accessible.'}
    </div>
    <div style="display:flex;gap:8px;flex-wrap:wrap;">
      <button id="btnSwitchOperator" class="btn small primary">${escapeHtml(t('op.switch') || 'Switch operator')}</button>
      ${activeOp ? `<button id="btnLockNow" class="btn small">${escapeHtml(t('op.lock') || 'Lock now')}</button>` : ''}
    </div>
    ${operators.length === 0
      ? `<p style="font-size:11.5px;color:var(--text-muted);margin-top:8px;">Add operators in the Operators section above, then assign PINs.</p>`
      : `<div style="margin-top:12px;font-size:12.5px;font-weight:600;margin-bottom:6px;">Operator PINs</div>
         <div style="display:flex;flex-direction:column;gap:6px;">
           ${operators.map(op => `
             <div style="display:flex;align-items:center;gap:10px;">
               <span style="flex:1;font-size:13px;">${escapeHtml(op.name)}</span>
               <span style="font-size:11px;color:var(--text-muted);">${escapeHtml(op.role || '')}</span>
               <input type="password" class="op-pin-input" data-op-id="${op.id}" aria-label="${escapeHtml(t('ops.pin_for') || 'PIN for')} ${escapeHtml(op.name || op.id)}"
                 value="${op.pinHash ? '****' : ''}"
                 placeholder="${op.pinHash ? '(set)' : 'Set PIN'}"
                 maxlength="8" style="width:80px;font-size:12px;">
               <button class="btn small op-save-pin" data-op-id="${op.id}">Save PIN</button>
             </div>`).join('')}
         </div>`}`;

  el.querySelector('#btnSwitchOperator')?.addEventListener('click', () => openPinPadModal());
  el.querySelector('#btnLockNow')?.addEventListener('click', () => {
    settings.activeOperatorId = null;
    saveAll();
    renderOperatorLockSettings();
    applyOperatorPermissions();
    toast(t('op.lock') || 'Locked', 'info', 1800);
  });

  el.querySelectorAll('.op-save-pin').forEach(btn => {
    btn.addEventListener('click', async () => {
      const opId = btn.dataset.opId;
      const pinInput = el.querySelector(`.op-pin-input[data-op-id="${opId}"]`);
      const pin = pinInput?.value?.trim() || '';
      const op = operators.find(o => o.id === opId);
      if (!op) return;
      if (pin && pin !== '****') {
        op.pinHash = await hashPin(pin); // SHA-256 hex, not btoa
        saveAll();
        toast(t('op.pin_set') || 'PIN saved', 'success', 1800);
        if (pinInput) pinInput.value = '****';
      } else if (!pin) {
        op.pinHash = '';
        saveAll();
        toast('PIN cleared', 'info', 1800);
      }
    });
  });
}

/** Show PIN pad modal to switch operator */

function renderLoyaltyTiersSettings() {
  const el = $('#loyaltyTiersSection');
  if (!el) return;
  const tiers = settings.loyaltyTiers || [];

  el.innerHTML = `
    <div id="loyaltyTiersList" style="display:flex;flex-direction:column;gap:8px;margin-bottom:10px;">
      ${tiers.map((tier, idx) => `
        <div style="display:flex;align-items:center;gap:8px;padding:8px 10px;border:1px solid var(--border);border-radius:var(--radius);background:var(--surface-2);">
          <input type="text" class="tier-name" data-idx="${idx}" value="${escapeHtml(tier.name || '')}" placeholder="e.g. Gold" style="flex:1.5;font-size:12.5px;">
          <input type="number" class="tier-min-orders" data-idx="${idx}" value="${tier.minOrders || ''}" placeholder="${escapeHtml(t('set.loyalty_min_orders') || 'Min orders')}" min="0" style="flex:1;font-size:12.5px;">
          <input type="number" class="tier-min-spend" data-idx="${idx}" value="${tier.minSpend || ''}" placeholder="${escapeHtml(t('set.loyalty_min_spend') || 'Min spend')}" min="0" style="flex:1;font-size:12.5px;">
          <input type="number" class="tier-discount" data-idx="${idx}" value="${tier.discountPct || ''}" placeholder="${escapeHtml(t('set.loyalty_benefit') || 'Discount %')}" min="0" max="100" style="flex:1;font-size:12.5px;">
          <button class="btn small danger tier-del" data-idx="${idx}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
        </div>`).join('')}
    </div>
    <div style="font-size:11px;color:var(--text-muted);margin-bottom:8px;">Name · Min completed orders · Min total spend (${currencySymbol()}) · Auto-discount %</div>
    <div style="display:flex;gap:8px;">
      <button id="btnAddLoyaltyTier" class="btn small primary">${escapeHtml(t('set.loyalty_add_tier') || '+ Add tier')}</button>
      <button id="btnSaveLoyaltyTiers" class="btn small">${escapeHtml(t('common.save'))}</button>
    </div>`;

  el.querySelector('#btnAddLoyaltyTier')?.addEventListener('click', () => {
    settings.loyaltyTiers = settings.loyaltyTiers || [];
    settings.loyaltyTiers.push({ name: '', minOrders: 5, minSpend: 0, discountPct: 0 });
    renderLoyaltyTiersSettings();
  });

  el.querySelector('#btnSaveLoyaltyTiers')?.addEventListener('click', () => {
    const rows = el.querySelectorAll('[data-idx]');
    const seen = new Set();
    rows.forEach(inp => {
      const idx = parseInt(inp.dataset.idx, 10);
      if (!seen.has(idx)) seen.add(idx);
    });
    const newTiers = [];
    seen.forEach(idx => {
      const name = el.querySelector(`.tier-name[data-idx="${idx}"]`)?.value.trim() || '';
      const minOrders = +(el.querySelector(`.tier-min-orders[data-idx="${idx}"]`)?.value || 0);
      const minSpend  = +(el.querySelector(`.tier-min-spend[data-idx="${idx}"]`)?.value || 0);
      const discountPct = +(el.querySelector(`.tier-discount[data-idx="${idx}"]`)?.value || 0);
      if (name) newTiers.push({ name, minOrders, minSpend, discountPct });
    });
    settings.loyaltyTiers = newTiers;
    saveAll();
    toast(t('common.save'), 'success');
    renderLoyaltyTiersSettings();
  });

  el.querySelectorAll('.tier-del').forEach(btn => {
    btn.addEventListener('click', () => {
      const idx = parseInt(btn.dataset.idx, 10);
      settings.loyaltyTiers = (settings.loyaltyTiers || []).filter((_, i) => i !== idx);
      saveAll();
      renderLoyaltyTiersSettings();
    });
  });
}

/* ============================================================
   Feature 6 (new 8-pack): Capacity check — estimate when a machine's
   queue will clear, accounting for working hours.
   ============================================================ */

function renderWebhookSettings() {
  const el = $('#webhookSettingsSection');
  if (!el) return;
  const wh = settings.webhooks || {};
  const events = [
    { key: 'order_created',    label: 'Order created' },
    { key: 'status_changed',   label: 'Status changed' },
    { key: 'payment_received', label: 'Payment received' },
    { key: 'quote_approved',   label: 'Quote approved' },
    { key: 'order_delivered',  label: 'Order delivered' },
  ];
  el.innerHTML = `
    <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:14px;">
      <input type="checkbox" id="whk_enabled" style="width:auto;margin:0;" ${wh.enabled ? 'checked' : ''}>
      <span data-i18n="whk.enabled">Enable outbound webhooks</span>
    </label>
    <div style="margin-bottom:12px;">
      <label data-i18n="whk.secret">Signing secret (HMAC-SHA256, optional)</label>
      <input type="text" id="whk_secret" value="${escapeHtml(wh.secret||'')}" placeholder="my-secret-key" style="font-family:var(--font-mono,monospace);">
    </div>
    <h4 style="margin:0 0 10px;font-size:13px;font-weight:600;" data-i18n="whk.event_urls">Webhook URLs per event</h4>
    ${events.map(ev => `
      <div style="margin-bottom:10px;">
        <label style="font-size:12px;color:var(--text-dim);">${escapeHtml(ev.label)}</label>
        <input type="url" id="whk_${ev.key}" value="${escapeHtml((wh.events||{})[ev.key]||'')}" placeholder="https://hooks.zapier.com/...">
      </div>`).join('')}
    <button class="btn primary" id="btnSaveWebhooks" data-i18n="common.save">Save</button>
    <button class="btn ghost small" id="btnTestWebhook" style="margin-inline-start:8px;" data-i18n="whk.test">Test (send ping)</button>`;

  el.querySelector('#btnSaveWebhooks').addEventListener('click', () => {
    settings.webhooks = {
      enabled: el.querySelector('#whk_enabled').checked,
      secret:  el.querySelector('#whk_secret').value.trim(),
      events:  Object.fromEntries(events.map(ev => [ev.key, el.querySelector(`#whk_${ev.key}`).value.trim()]))
    };
    saveAll();
    toast(t('webhook.saved'), 'success');
  });
  el.querySelector('#btnTestWebhook').addEventListener('click', async () => {
    const url = el.querySelector('#whk_status_changed')?.value || Object.values((settings.webhooks?.events||{})).find(Boolean);
    if (!url) { toast(t('webhook.enter_url'), 'warning'); return; }
    const res = await window.hubAPI?.fireWebhook?.(url, 'ping', { message: 'Khayt webhook test' }, settings.webhooks?.secret || '');
    if (res?.ok) toast(t('hook.delivered'), 'success');
    else toast(`⚠ Webhook failed: ${res?.error || res?.status || '?'}`, 'error');
  });
}

/* beta.19 — Signed event webhooks (developer). One HTTPS endpoint receives the
   normalized, HMAC-signed `order.*` envelope built by lib/webhooks.js. Distinct
   from the per-event Zapier hooks above. */
function renderEventWebhookSettings() {
  const el = $('#eventWebhookSection');
  if (!el) return;
  const w = settings.eventWebhooks || {};
  const ev = w.events || {};
  const events = [
    { key: 'created', label: t('ewh.ev_created') || 'order.created' },
    { key: 'status',  label: t('ewh.ev_status')  || 'order.status (status changed)' },
    { key: 'paid',    label: t('ewh.ev_paid')    || 'order.paid (fully paid)' },
  ];
  el.innerHTML = `
    <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:14px;">
      <input type="checkbox" id="ewh_enabled" style="width:auto;margin:0;" ${w.enabled ? 'checked' : ''}>
      <span data-i18n="ewh.enabled">Enable signed event webhooks</span>
    </label>
    <div style="margin-bottom:12px;">
      <label data-i18n="ewh.url">Endpoint URL (https only)</label>
      <input type="url" id="ewh_url" value="${escapeHtml(w.url || '')}" placeholder="https://api.example.com/khayt/webhook">
    </div>
    <div style="margin-bottom:12px;">
      <label data-i18n="ewh.secret">Signing secret (HMAC-SHA256)</label>
      <input type="text" id="ewh_secret" value="${escapeHtml(w.secret || '')}" placeholder="whsec_…" style="font-family:var(--font-mono,monospace);">
    </div>
    <h4 style="margin:0 0 10px;font-size:13px;font-weight:600;" data-i18n="ewh.events">Events to send</h4>
    ${events.map(e => `
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:8px;font-size:12.5px;">
        <input type="checkbox" id="ewh_ev_${e.key}" style="width:auto;margin:0;" ${ev[e.key] === false ? '' : 'checked'}>
        <span>${escapeHtml(e.label)}</span>
      </label>`).join('')}
    <div style="margin-top:12px;">
      <button class="btn primary" id="btnSaveEwh" data-i18n="common.save">Save</button>
      <button class="btn ghost small" id="btnTestEwh" style="margin-inline-start:8px;" data-i18n="ewh.test">Test (send sample)</button>
    </div>`;

  el.querySelector('#btnSaveEwh').addEventListener('click', () => {
    settings.eventWebhooks = {
      enabled: el.querySelector('#ewh_enabled').checked,
      url:     el.querySelector('#ewh_url').value.trim(),
      secret:  el.querySelector('#ewh_secret').value.trim(),
      events:  Object.fromEntries(events.map(e => [e.key, el.querySelector(`#ewh_ev_${e.key}`).checked])),
    };
    saveAll();
    toast(t('webhook.saved') || 'Saved', 'success');
  });
  el.querySelector('#btnTestEwh').addEventListener('click', async () => {
    const url = el.querySelector('#ewh_url').value.trim();
    if (!/^https:\/\//i.test(url)) { toast(t('ewh.enter_url') || 'Enter an https:// URL first', 'warning'); return; }
    const secret = el.querySelector('#ewh_secret').value.trim();
    const sample = (typeof KhaytWebhooks !== 'undefined')
      ? KhaytWebhooks.buildWebhookEvent('created',
          { id: 'SAMPLE-1', project: 'Test order', status: 'pending', paymentStatus: 'unpaid', price: 100 },
          { at: new Date().toISOString(), shopName: shopField('biz') || 'Khayt', clientName: 'Test client', currency: (typeof currencySymbol === 'function') ? currencySymbol() : '' })
      : { id: 'SAMPLE-1', event: 'order.created' };
    const res = await window.hubAPI?.webhookPost?.({ url, secret, payload: sample });
    if (res?.ok) toast(t('hook.delivered'), 'success');
    else toast(`⚠ ${res?.error || 'HTTP ' + (res?.status || '?')}`, 'error');
  });
}

/* ============================================================
   Round 12 — Feature 2: Aged-Receivables Report
   ============================================================ */

function renderFixedCostSettings() {
  const el = $('#fixedCostsSection');
  if (!el) return;
  const fixedCosts = settings.fixedCosts || [];
  el.innerHTML = `
    <div id="fixedCostList" style="margin-bottom:12px;">
      ${fixedCosts.length === 0 ? '<p style="color:var(--text-muted);font-size:12.5px;margin:0;">No fixed costs added yet.</p>' :
        fixedCosts.map((c, i) => `
          <div style="display:flex;align-items:center;gap:8px;padding:6px 0;border-bottom:1px solid var(--border);">
            <span style="flex:1;">${escapeHtml(c.name)}</span>
            <strong>${fmtPrice(c.amount)}</strong>
            <button class="btn danger small" data-del-fc="${i}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">✕</button>
          </div>`).join('')
      }
    </div>
    <div style="display:flex;gap:8px;flex-wrap:wrap;">
      <input type="text"   id="fcName"   placeholder="e.g. Rent"   style="flex:2;min-width:120px;">
      <input type="number" id="fcAmount" placeholder="Amount/month" style="flex:1;min-width:100px;" min="0" step="0.01">
      <button class="btn primary" id="btnAddFixedCost">+ Add</button>
    </div>`;

  el.querySelectorAll('[data-del-fc]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const ok = await confirmModal(t('common.delete') + '?', { danger: true });
      if (!ok) return;
      settings.fixedCosts.splice(parseInt(btn.dataset.delFc), 1);
      saveAll(); renderFixedCostSettings(); renderBreakEvenCard();
    });
  });
  el.querySelector('#btnAddFixedCost')?.addEventListener('click', () => {
    const name = el.querySelector('#fcName').value.trim();
    const amount = parseFloat(el.querySelector('#fcAmount').value) || 0;
    if (!name || amount <= 0) { toast(t('set.fixed_cost_name_amt'), 'warning'); return; }
    settings.fixedCosts = [...(settings.fixedCosts || []), { id: Date.now().toString(36), name, amount }];
    saveAll(); renderFixedCostSettings(); renderBreakEvenCard();
    el.querySelector('#fcName').value = '';
    el.querySelector('#fcAmount').value = '';
  });
}

/* Carrier tracking URLs — renderer/integrations.js (getCarrierTrackingUrl) */

/**
 * The five numbers lib/stl-estimate.js needs. They used to be constants; a shop
 * printing PETG at 40% infill had its quotes built on PLA at 20%.
 *
 * Throughput is shown but rarely typed: Khayt derives it from the shop's own
 * measured jobs when it has enough of them, and says so.
 */
function renderEstimatorSettings() {
  const el = $('#estimatorSettings');
  if (!el || typeof KhaytStl === 'undefined' || !KhaytStl.fromSettings) return;
  const cur = KhaytStl.fromSettings(settings);
  const CAL = (typeof KhaytEstimateCalibration !== 'undefined') ? KhaytEstimateCalibration : null;
  const OL = (typeof KhaytOrderFileLink !== 'undefined') ? KhaytOrderFileLink : null;
  const cal = (CAL && OL)
    ? CAL.calibrate(typeof printLog !== 'undefined' ? printLog : [], { allocate: OL.allocateActuals }, {})
    : null;

  el.innerHTML = `
    <div class="inline-pair">
      <div>
        <label data-i18n="est.density">Filament density (g/cm³)</label>
        <input type="number" id="est_density" step="0.01" min="0.1" max="25" value="${cur.densityGPerCm3}">
      </div>
      <div>
        <label data-i18n="est.infill">Default infill %</label>
        <input type="number" id="est_infill" step="1" min="0" max="100" value="${Math.round(cur.infillPct * 100)}">
      </div>
    </div>
    <div class="inline-pair" style="margin-top:8px;">
      <div>
        <label data-i18n="est.wall">Wall thickness (mm)</label>
        <input type="number" id="est_wall" step="0.1" min="0.1" max="20" value="${cur.wallThicknessMm}">
        <div style="font-size:11px;color:var(--text-muted);margin-top:4px;" data-i18n="est.wall_hint">Total wall thickness — perimeters plus top and bottom skin. Khayt works out how much of a part is shell from its surface area and this.</div>
      </div>
      <div>
        <label data-i18n="est.waste">Waste %</label>
        <input type="number" id="est_waste" step="1" min="0" max="50" value="${Math.round(cur.wastePct * 100)}">
      </div>
    </div>
    <div style="margin-top:10px;">
      <label data-i18n="est.rate">How fast your printers actually run (g/hour)</label>
      <input type="number" id="est_rate" step="0.1" min="0.1" value="${Math.round(cur.densityGPerCm3 * cur.throughputMm3PerS * 3.6 * 10) / 10}"${cal ? ' disabled' : ''}>
      <div style="font-size:11px;margin-top:4px;color:${cal ? 'var(--ok,#159d68)' : 'var(--text-muted)'};">${escapeHtml(cal
        ? t('est.rate_measured', { rate: cal.gramsPerHour, n: cal.jobs })
        : t('est.rate_guess'))}</div>
    </div>`;

  // Saved as they are edited — this panel has no save button, and a shop that
  // types a density and navigates away should not lose it.
  el.querySelectorAll('input').forEach((f) => f.addEventListener('change', () => {
    saveEstimatorSettingsFromForm();
    saveAll();
    renderEstimatorSettings();
  }));
}

function saveEstimatorSettingsFromForm() {
  const el = $('#estimatorSettings');
  if (!el) return;
  const pct = (sel, fallback) => {
    const v = parseFloat(el.querySelector(sel)?.value);
    return Number.isFinite(v) ? Math.max(0, Math.min(100, v)) / 100 : fallback;
  };
  const prev = settings.estimator || {};
  const density = parseFloat(el.querySelector('#est_density')?.value);
  const rate = parseFloat(el.querySelector('#est_rate')?.value);
  settings.estimator = {
    ...prev,
    densityGPerCm3: Number.isFinite(density) && density > 0 ? density : undefined,
    infillPct: pct('#est_infill', prev.infillPct),
    // shellFactor is deliberately NOT edited here any more. It only applies to
    // geometry that arrives with no surface area, which nothing in the app now
    // produces — leaving it on screen meant a dial a shop could turn with no
    // effect on any real file. It is preserved through ...prev so an existing
    // shop's stored value is not discarded.
    wallThicknessMm: (() => {
      const v = parseFloat(el.querySelector('#est_wall')?.value);
      return Number.isFinite(v) && v >= 0.1 && v <= 20 ? v : prev.wallThicknessMm;
    })(),
    wastePct: Math.min(0.5, pct('#est_waste', prev.wastePct ?? 0.03)),
    // Stored as a throughput because that is what the estimator takes; shown as
    // grams per hour because that is the only form a shop can sanity-check.
    throughputMm3PerS: (Number.isFinite(rate) && rate > 0 && Number.isFinite(density) && density > 0)
      ? rate / density / 3.6
      : prev.throughputMm3PerS,
  };
  Object.keys(settings.estimator).forEach((k) => settings.estimator[k] === undefined && delete settings.estimator[k]);
}

function renderLanApiSettings() {
  const el = $('#lanApiSection');
  if (!el) return;
  migrateLanApiSettings();
  const lan = settings.lanApi || {};

  el.innerHTML = `
    <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:14px;">
      <input type="checkbox" id="lan_enabled" style="width:auto;margin:0;" ${lan.enabled ? 'checked' : ''}>
      <span data-i18n="lan.enabled">Enable LAN REST API</span>
    </label>
    <div class="inline-pair">
      <div>
        <label data-i18n="lan.port">Port</label>
        <input type="number" id="lan_port" value="${lan.port || 3219}" min="1024" max="65535">
      </div>
      <div>
        <label data-i18n="lan.pin">Owner LAN PIN (queue API, kiosk, tunnel)</label>
        <input type="password" id="lan_pin" value="${escapeHtml(secretInputValue(lan.pin))}" maxlength="12" placeholder="${escapeHtml(secretFieldPlaceholder(lan.pin) || 'e.g. 1234')}" autocomplete="off">
      </div>
    </div>
    <div class="inline-pair" style="margin-top:10px;">
      <div>
        <label data-i18n="lan.intake_pin">Intake form PIN (customers)</label>
        <input type="text" id="lan_intake_pin" value="${escapeHtml(secretInputValue(lan.intakePin))}" maxlength="12" placeholder="${escapeHtml(secretFieldPlaceholder(lan.intakePin) || 'Auto-generated on start')}" autocomplete="off" style="font-family:monospace;letter-spacing:.1em;">
        <div style="font-size:11px;color:var(--text-muted);margin-top:4px;" data-i18n="lan.intake_pin_hint">Optional legacy PIN — customers open /intake directly; no PIN required on current versions</div>
        <div id="lanIntakePinLive" style="font-size:11px;color:var(--text-muted);margin-top:4px;display:none;"></div>
      </div>
    </div>
    <label style="display:flex;align-items:flex-start;gap:8px;cursor:pointer;margin-top:10px;">
      <input type="checkbox" id="lan_bind_lan" style="width:auto;margin:3px 0 0;" ${lan.bindLan || settings.onlineEnabled ? 'checked' : ''}>
      <span>
        <span data-i18n="lan.bind_lan">Listen on all network interfaces (LAN)</span>
        <div style="font-size:11px;color:var(--text-muted);margin-top:4px;font-weight:400;" data-i18n="lan.bind_lan_hint">Required for phones and other computers on your shop Wi‑Fi. Off = this Mac only.</div>
      </span>
    </label>
    <div style="font-size:11px;color:var(--text-muted);margin:4px 0 10px;padding:8px 10px;background:var(--bg-elev);border-radius:var(--radius);word-break:break-all;">
      Customer intake form: <code style="font-size:11px;">/intake</code> — scan the QR or open this path on your shop Wi‑Fi (no PIN required).
    </div>
    <div style="margin:10px 0;padding:10px 12px;border:1px solid var(--border);border-radius:var(--radius);">
      <label style="display:flex;align-items:flex-start;gap:8px;cursor:pointer;">
        <input type="checkbox" id="lan_iq_enabled" style="width:auto;margin:3px 0 0;" ${lan.intakeQuote?.enabled ? 'checked' : ''}>
        <span>
          <span data-i18n="lan.iq_enable">Let customers price their own model</span>
          <div style="font-size:11px;color:var(--text-muted);margin-top:4px;font-weight:400;" data-i18n="lan.iq_enable_hint">Adds a file upload to the intake form. The file is priced in memory and never stored, and the customer is told the figure is not a confirmed quote.</div>
        </span>
      </label>
      <div id="lanIqFields" style="margin-top:10px;${lan.intakeQuote?.enabled ? '' : 'display:none;'}">
        <div class="inline-pair">
          <div>
            <label data-i18n="lan.iq_printer">Price using this printer preset</label>
            <select id="lan_iq_preset">
              <option value="" data-i18n="lan.iq_pick">— Select —</option>
              ${(printers || []).map((p) => `<option value="${escapeHtml(p.id)}" ${lan.intakeQuote?.presetId === p.id ? 'selected' : ''}>${escapeHtml(p.name)}</option>`).join('')}
            </select>
          </div>
          <div>
            <label data-i18n="lan.iq_filament">Material</label>
            <select id="lan_iq_filament">
              <option value="" data-i18n="lan.iq_flat">Use the figures below</option>
              ${(inventory || []).filter((i) => i && i.id).map((i) => `<option value="${escapeHtml(i.id)}" ${lan.intakeQuote?.filamentId === i.id ? 'selected' : ''}>${escapeHtml(i.material || i.name || i.id)}</option>`).join('')}
            </select>
          </div>
        </div>
        <div class="inline-pair" style="margin-top:8px;">
          <div>
            <label data-i18n="lan.iq_spool_cost">Spool cost</label>
            <input type="number" id="lan_iq_spool_cost" min="0" step="0.01" value="${+(lan.intakeQuote?.spoolCost) || ''}">
          </div>
          <div>
            <label data-i18n="lan.iq_spool_weight">Spool weight (g)</label>
            <input type="number" id="lan_iq_spool_weight" min="1" value="${+(lan.intakeQuote?.spoolWeight) || 1000}">
          </div>
        </div>
        <div class="inline-pair" style="margin-top:8px;">
          <div>
            <label data-i18n="lan.iq_margin">Margin %</label>
            <input type="number" id="lan_iq_margin" min="0" step="1" value="${+(lan.intakeQuote?.marginPct) || 0}">
          </div>
          <div>
            <label data-i18n="lan.iq_min">Minimum price</label>
            <input type="number" id="lan_iq_min" min="0" step="0.01" value="${+(lan.intakeQuote?.minPrice) || 0}">
          </div>
        </div>
        <div class="inline-pair" style="margin-top:8px;">
          <div>
            <label data-i18n="lan.iq_waste">Waste %</label>
            <input type="number" id="lan_iq_waste" min="0" max="50" step="1" value="${Math.round((+(lan.intakeQuote?.wastePct) || 0) * 100)}">
          </div>
          <div>
            <label data-i18n="lan.iq_limit">Estimates per visitor, per hour</label>
            <input type="number" id="lan_iq_limit" min="1" max="10000" value="${+(lan.intakeQuote?.hourlyLimit) || 12}">
          </div>
        </div>
        <div style="font-size:11px;color:var(--text-muted);margin-top:8px;" data-i18n="lan.iq_note">A model nobody has sliced is priced from its shape alone, which can be well out on a sparse or heavily supported part. The customer is always shown which of the two they are looking at.</div>
      </div>
    </div>
    <div class="inline-pair" style="margin-top:10px;">
      <div style="flex:1;">
        <label data-i18n="lan.webhook_token">Printer Webhook Token</label>
        <div style="display:flex;gap:6px;">
          <input type="password" id="lan_wh_token" value="${escapeHtml(secretInputValue(lan.webhookToken))}" placeholder="${escapeHtml(secretFieldPlaceholder(lan.webhookToken) || 'e.g. secret123')}" style="flex:1;" autocomplete="off">
          <button class="btn ghost small" id="btnGenWebhookToken" title="Generate random token" aria-label="Generate random token"><span aria-hidden="true">🎲</span></button>
        </div>
        <div style="font-size:11px;color:var(--text-muted);margin-top:4px;" data-i18n="lan.webhook_token_hint">Used to authenticate printer webhook calls</div>
      </div>
    </div>
    <div class="inline-pair" style="margin-top:10px;">
      <div style="flex:1;">
        <label data-i18n="lan.salla_secret">Salla webhook secret</label>
        <input type="password" id="lan_salla_secret" value="${escapeHtml(secretInputValue(lan.sallaWebhookSecret))}" placeholder="${escapeHtml(secretFieldPlaceholder(lan.sallaWebhookSecret) || 'From Salla dashboard')}" autocomplete="off">
      </div>
      <div style="flex:1;">
        <label data-i18n="lan.zid_secret">Zid webhook secret</label>
        <input type="password" id="lan_zid_secret" value="${escapeHtml(secretInputValue(lan.zidWebhookSecret))}" placeholder="${escapeHtml(secretFieldPlaceholder(lan.zidWebhookSecret) || 'From Zid dashboard')}" autocomplete="off">
      </div>
    </div>
    <div id="lanStatusRow" style="margin:12px 0;padding:10px 12px;background:var(--bg-elev);border-radius:var(--radius);font-size:13px;">${lan.enabled ? '🟢 Server active' : '⚫ Server stopped'}</div>
    <div id="lanQrWrap" style="margin-bottom:12px;display:${lan.enabled ? 'block' : 'none'};"></div>
    <div id="lanWebhookSection" style="display:${lan.enabled && lan.webhookToken ? 'block' : 'none'};margin:10px 0;">
      <label data-i18n="lan.printer_webhook">Printer Webhook URL</label>
      <button type="button" style="font-size:11px;color:var(--text-muted);padding:8px 10px;background:var(--bg-elev);border:none;border-radius:var(--radius);word-break:break-all;cursor:pointer;text-align:start;width:100%;" id="webhookUrlDisplay" data-i18n-title="lan.click_to_copy" data-i18n-aria="lan.click_to_copy" title="Click to copy" aria-label="Click to copy">—</button>
      <div style="font-size:11px;color:var(--text-muted);margin-top:4px;" data-i18n="lan.webhook_url_hint">Configure this URL in OctoPrint/Moonraker webhook plugin for each machine.</div>
    </div>
    <div style="display:flex;gap:8px;flex-wrap:wrap;">
      <button class="btn primary" id="btnSaveLan" data-i18n="common.save">Save</button>
      <button class="btn ghost" id="btnStartLan" data-i18n="lan.start">Start server</button>
      <button class="btn ghost" id="btnStopLan"  data-i18n="lan.stop">Stop server</button>
    </div>
    <div style="margin-top:18px;padding-top:14px;border-top:1px solid var(--border);">
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:10px;">
        <input type="checkbox" id="lan_tunnel_enabled" style="width:auto;margin:0;" ${lan.tunnelEnabled ? 'checked' : ''}>
        <span data-i18n="lan.tunnel_enable">Enable remote tunnel (via localtunnel.me)</span>
      </label>
      <div id="tunnelStatusRow" style="font-size:13px;padding:8px 12px;background:var(--bg-elev);border-radius:var(--radius);margin-bottom:8px;">
        ⚫ Tunnel inactive
      </div>
      <div style="display:flex;gap:8px;">
        <button class="btn ghost small" id="btnStartTunnel" data-i18n="lan.tunnel_start">Start Tunnel</button>
        <button class="btn ghost small" id="btnStopTunnel" data-i18n="lan.tunnel_stop">Stop Tunnel</button>
      </div>
      <div style="font-size:11px;color:var(--text-muted);margin-top:8px;" data-i18n="lan.tunnel_hint">Exposes your LAN server to the internet via a temporary URL. Requires LAN server to be running.</div>
      <div style="font-size:11px;color:var(--danger);margin-top:8px;padding:8px 10px;background:rgba(239,68,68,0.08);border-radius:var(--radius);" data-i18n="lan.tunnel_security_warning">Warning: the tunnel exposes your full LAN API surface to the internet. Set a strong owner PIN and disable when not needed.</div>
    </div>`;

  if (lan.enabled) {
    loadLanQr();
    refreshLanIntakePinLive?.();
  }

  el.querySelector('#btnSaveLan')?.addEventListener('click', () => {
    saveLanApiSettingsFromForm({ restartServer: true });
    toast(t('lan.settings_saved'), 'success');
  });

  // Reveal the pricing fields only when the shop opts in, so the panel does not
  // ask nine questions nobody has to answer.
  el.querySelector('#lan_iq_enabled')?.addEventListener('change', (e) => {
    const fields = el.querySelector('#lanIqFields');
    if (fields) fields.style.display = e.target.checked ? '' : 'none';
  });
  // A chosen inventory item IS the material price, so the flat figures beside it
  // would be two answers to one question.
  el.querySelector('#lan_iq_filament')?.addEventListener('change', (e) => {
    const usingInventory = !!e.target.value;
    for (const id of ['#lan_iq_spool_cost', '#lan_iq_spool_weight']) {
      const f = el.querySelector(id);
      if (f) { f.disabled = usingInventory; f.style.opacity = usingInventory ? '.5' : ''; }
    }
  });
  el.querySelector('#lan_iq_filament')?.dispatchEvent(new Event('change'));
  el.querySelector('#btnStartLan')?.addEventListener('click', startLanServer);
  el.querySelector('#btnStopLan')?.addEventListener('click', async () => {
    await window.hubAPI?.stopLanServer?.();
    el.querySelector('#lanStatusRow').textContent = '⚫ Server stopped';
    el.querySelector('#lanQrWrap').style.display = 'none';
  });

  el.querySelector('#btnGenWebhookToken')?.addEventListener('click', () => {
    const arr = new Uint8Array(16);
    crypto.getRandomValues(arr);
    const token = Array.from(arr).map(b => b.toString(16).padStart(2,'0')).join('');
    el.querySelector('#lan_wh_token').value = token;
  });

  el.querySelector('#btnStartTunnel')?.addEventListener('click', () => {
    startTunnelFromSettings?.({ confirm: true });
  });

  el.querySelector('#btnStopTunnel')?.addEventListener('click', async () => {
    await window.hubAPI?.stopTunnel?.();
    const tRow = el.querySelector('#tunnelStatusRow');
    if (tRow) tRow.textContent = '⚫ Tunnel inactive';
  });

  el.querySelector('#webhookUrlDisplay')?.addEventListener('click', async () => {
    const url = el.querySelector('#webhookUrlDisplay').textContent;
    if (!url || url === '—') return;
    await copyAndToast(url);
  });
}

function renderZatcaPhase2Settings() {
  const el = $('#zatcaPhase2Section');
  if (!el) return;
  // ZATCA Phase 2 (cryptographic e-invoicing) is a Professional-only feature —
  // don't render its onboarding UI in Simple mode (nav pane is .biz-only, but
  // this Pro block sits inside it). CSS .pro-only hides it too; this skips work.
  const pro = (typeof KhaytTiers !== 'undefined')
    ? KhaytTiers.isProMode(settings.mode)
    : ((settings.mode || 'professional') === 'professional');
  if (!pro) { el.innerHTML = ''; return; }
  const z2 = settings.zatcaPhase2 || {};
  const hasKey = !!(z2.cn); // crude check — replaced by IPC status
  const hasCsid  = !!z2.csid;
  const hasPcsid = !!z2.pcsid;

  const stepClass = (done) => done ? 'style="color:var(--success)"' : '';
  el.innerHTML = `
    <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:12px;">
      <input type="checkbox" id="z2_enabled" style="width:auto;margin:0;" ${z2.enabled ? 'checked' : ''}>
      <span data-i18n="zatca2.enable">Enable ZATCA Phase 2 (cryptographic invoices)</span>
    </label>
    <div id="z2Body" style="${z2.enabled ? '' : 'display:none;'}">
      <div class="inline-pair">
        <div>
          <label data-i18n="zatca2.environment">Environment</label>
          <select id="z2_env">
            <option value="sandbox" ${z2.environment !== 'production' ? 'selected' : ''}>Sandbox (testing)</option>
            <option value="production" ${z2.environment === 'production' ? 'selected' : ''}>Production</option>
          </select>
        </div>
        <div>
          <label data-i18n="zatca2.city">City (for CSR)</label>
          <input type="text" id="z2_city" value="${escapeHtml(z2.city || 'Riyadh')}" placeholder="Riyadh">
        </div>
      </div>
      <div class="inline-pair">
        <div>
          <label data-i18n="zatca2.org">Organization name (for CSR)</label>
          <input type="text" id="z2_org" value="${escapeHtml(z2.org || shopName() || '')}" placeholder="My Shop LLC">
        </div>
        <div>
          <label data-i18n="zatca2.industry">Industry (for CSR)</label>
          <input type="text" id="z2_industry" value="${escapeHtml(z2.industry || '3D Printing')}" placeholder="3D Printing">
        </div>
      </div>

      <h4 style="margin:16px 0 10px;font-size:13px;color:var(--text-muted);" data-i18n="zatca2.steps_title">Onboarding Steps</h4>

      <!-- Step 1: Key pair -->
      <div style="margin-bottom:12px;padding:12px;background:var(--bg-elev);border-radius:var(--radius);">
        <div style="font-weight:600;font-size:13px;margin-bottom:6px;">
          <span ${stepClass(hasKey)}>● </span><span data-i18n="zatca2.step1">Step 1 — Generate Device Key Pair</span>
        </div>
        <div style="font-size:11px;color:var(--text-muted);margin-bottom:8px;" data-i18n="zatca2.step1_hint">Creates an ECDSA secp256k1 key pair. Private key is encrypted at rest.</div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;">
          <button class="btn ghost small" id="btnZ2GenKey" data-i18n="zatca2.gen_key">Generate Key Pair</button>
          <button class="btn ghost small" id="btnZ2ShowKey" data-i18n="zatca2.show_pubkey">Show Public Key</button>
        </div>
        <div id="z2KeyStatus" style="font-size:11px;margin-top:6px;color:var(--text-muted);"></div>
      </div>

      <!-- Step 2: CSR -->
      <div style="margin-bottom:12px;padding:12px;background:var(--bg-elev);border-radius:var(--radius);">
        <div style="font-weight:600;font-size:13px;margin-bottom:6px;">
          <span data-i18n="zatca2.step2">Step 2 — Generate CSR &amp; Get CSID</span>
        </div>
        <div style="font-size:11px;color:var(--text-muted);margin-bottom:6px;" data-i18n="zatca2.step2_hint">Submit the CSR to ZATCA's Fatoorah portal to get a compliance CSID (OTP required).</div>
        <label data-i18n="zatca2.egs_cn">EGS Common Name (format: 1-{OIC}{CR}|{brand}|{serial})</label>
        <input type="text" id="z2_cn" value="${escapeHtml(z2.cn || '')}" placeholder="1-123456789-1|MyShop|SN001" style="margin-bottom:8px;">
        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:8px;">
          <button class="btn ghost small" id="btnZ2GenCsr" data-i18n="zatca2.gen_csr">Generate CSR</button>
        </div>
        <div id="z2CsrOut" style="display:none;margin-bottom:8px;">
          <label data-i18n="zatca2.csr_label">CSR (copy and submit to ZATCA)</label>
          <textarea id="z2CsrText" rows="4" style="font-family:monospace;font-size:10px;width:100%;resize:vertical;" readonly></textarea>
          <button class="btn ghost small" id="btnZ2CopyCsr" style="margin-top:4px;" data-i18n="zatca2.copy_csr">Copy CSR</button>
        </div>
        <label data-i18n="zatca2.otp_label">OTP (from ZATCA Fatoorah portal)</label>
        <input type="text" id="z2_otp" placeholder="123456" maxlength="6" style="margin-bottom:8px;">
        <button class="btn ghost small" id="btnZ2GetCsid" data-i18n="zatca2.get_csid">Get CSID from ZATCA</button>
        <div id="z2CsidStatus" style="font-size:11px;margin-top:6px;"></div>
      </div>

      <!-- Step 3: Production CSID -->
      <div style="margin-bottom:12px;padding:12px;background:var(--bg-elev);border-radius:var(--radius);">
        <div style="font-weight:600;font-size:13px;margin-bottom:6px;">
          <span ${stepClass(hasPcsid)}>● </span><span data-i18n="zatca2.step3">Step 3 — Upgrade to Production CSID</span>
        </div>
        <div style="font-size:11px;color:var(--text-muted);margin-bottom:8px;" data-i18n="zatca2.step3_hint">Run compliance checks, then upgrade. Leave blank if staying on sandbox.</div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;">
          <button class="btn ghost small" id="btnZ2GetPcsid" data-i18n="zatca2.get_pcsid">Get Production CSID</button>
        </div>
        <div id="z2PcsidStatus" style="font-size:11px;margin-top:6px;color:var(--text-muted);">${hasPcsid ? '✅ Production CSID stored' : hasCsid ? '🔵 Compliance CSID ready' : '—'}</div>
      </div>

      <!-- Step 4: Submit invoices -->
      <div style="padding:12px;background:var(--bg-elev);border-radius:var(--radius);">
        <div style="font-weight:600;font-size:13px;margin-bottom:6px;" data-i18n="zatca2.step4">Step 4 — Submit invoices to ZATCA</div>
        <div style="font-size:11px;color:var(--text-muted);margin-bottom:8px;" data-i18n="zatca2.step4_hint">Completed invoices auto-submit when Phase 2 is enabled. Retry manually from the Orders log.</div>
        <label style="display:flex;align-items:center;gap:8px;margin:10px 0;font-weight:400;">
          <input type="checkbox" id="z2_autoSubmit" style="width:auto;margin:0;" ${z2.autoSubmit !== false ? 'checked' : ''}>
          <span data-i18n="zatca2.auto_submit">Auto-submit when invoice is generated</span>
        </label>
        <label style="display:flex;align-items:center;gap:8px;margin:0 0 10px;font-weight:400;">
          <input type="checkbox" id="z2_emailAfterSubmit" style="width:auto;margin:0;" ${z2.emailAfterSubmit ? 'checked' : ''}>
          <span data-i18n="zatca2.email_after_submit">Email invoice to client after successful submission</span>
        </label>
        <div id="z2SubmitStatus" style="font-size:12px;color:var(--text-muted);margin-bottom:10px;">
          ${(z2.invoiceCounter||0) > 0 ? `✅ ${z2.invoiceCounter} ${escapeHtml(t('zatca2.invoices_submitted') || 'invoice(s) submitted')}` : t('zatca2.no_submissions')}
        </div>
        <div id="z2SubmissionLog" style="max-height:180px;overflow:auto;font-size:11px;"></div>
      </div>

      <button class="btn primary" id="btnZ2Save" style="margin-top:14px;" data-i18n="common.save">Save Phase 2 Settings</button>
    </div>`;

  // Toggle body visibility
  el.querySelector('#z2_enabled')?.addEventListener('change', (e) => {
    const body = el.querySelector('#z2Body');
    if (body) body.style.display = e.target.checked ? '' : 'none';
  });

  // Save
  el.querySelector('#btnZ2Save')?.addEventListener('click', () => {
    settings.zatcaPhase2 = {
      ...settings.zatcaPhase2,
      enabled:     el.querySelector('#z2_enabled').checked,
      environment: el.querySelector('#z2_env').value,
      cn:          el.querySelector('#z2_cn').value.trim(),
      org:         el.querySelector('#z2_org').value.trim(),
      city:        el.querySelector('#z2_city').value.trim(),
      industry:    el.querySelector('#z2_industry').value.trim(),
      autoSubmit:  el.querySelector('#z2_autoSubmit')?.checked !== false,
      emailAfterSubmit: !!el.querySelector('#z2_emailAfterSubmit')?.checked,
    };
    saveAll();
    toast(t('zatca2.saved'), 'success');
  });

  // Generate key pair
  el.querySelector('#btnZ2GenKey')?.addEventListener('click', async () => {
    const res = await window.hubAPI?.zatcaGenKeypair?.();
    const ks = el.querySelector('#z2KeyStatus');
    if (res?.ok) {
      if (ks) ks.textContent = '✅ Key pair generated and encrypted on disk';
      toast(t('zatca2.key_generated'), 'success');
    } else {
      if (ks) ks.textContent = `❌ ${res?.error || 'Failed'}`;
    }
  });

  // Show public key
  el.querySelector('#btnZ2ShowKey')?.addEventListener('click', async () => {
    const res = await window.hubAPI?.zatcaGetPubkey?.();
    const ks = el.querySelector('#z2KeyStatus');
    if (res?.ok) {
      if (ks) ks.innerHTML = `<details><summary>Public Key (click to expand)</summary><pre style="font-size:9px;white-space:pre-wrap;word-break:break-all;">${escapeHtml(res.publicKey)}</pre></details>`;
    } else {
      if (ks) ks.textContent = 'No key pair found — generate one first';
    }
  });

  // Generate CSR
  el.querySelector('#btnZ2GenCsr')?.addEventListener('click', async () => {
    const cn = el.querySelector('#z2_cn').value.trim();
    const org = el.querySelector('#z2_org').value.trim() || shopName() || '';
    const vat = settings.vat || '';
    if (!cn) { toast(t('zatca2.cn_required'), 'warning'); return; }
    const res = await window.hubAPI?.zatcaGenCsr?.({
      cn, org, vat,
      invoiceType: '1100',
      location: el.querySelector('#z2_city').value.trim() || 'Riyadh',
      industry: el.querySelector('#z2_industry').value.trim() || '3D Printing',
    });
    if (res?.ok) {
      const out = el.querySelector('#z2CsrOut');
      const txt = el.querySelector('#z2CsrText');
      if (out) out.style.display = 'block';
      if (txt) txt.value = res.csr;
    } else {
      toast(res?.error || t('zatca2.csr_failed'), 'error');
    }
  });

  // Copy CSR
  el.querySelector('#btnZ2CopyCsr')?.addEventListener('click', async () => {
    const txt = el.querySelector('#z2CsrText');
    if (txt?.value) await copyAndToast(txt.value);
  });

  // Get CSID from ZATCA
  el.querySelector('#btnZ2GetCsid')?.addEventListener('click', async () => {
    const csrTxt = el.querySelector('#z2CsrText')?.value;
    const otp = el.querySelector('#z2_otp')?.value.trim();
    const env = el.querySelector('#z2_env').value;
    if (!csrTxt) { toast(t('zatca2.gen_csr_first'), 'warning'); return; }
    if (!otp) { toast(t('zatca2.otp_required'), 'warning'); return; }
    const csrB64 = csrTxt.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
    const st = el.querySelector('#z2CsidStatus');
    if (st) st.textContent = '⏳ Contacting ZATCA…';
    const res = await window.hubAPI?.zatcaCompliance?.({ csrBase64: csrB64, otp, environment: env });
    if (res?.ok) {
      settings.zatcaPhase2 = { ...settings.zatcaPhase2, csid: res.csid };
      saveAll();
      if (st) st.textContent = `✅ Compliance CSID stored (request ID: ${res.requestId || 'N/A'})`;
      toast(t('zatca2.csid_received'), 'success');
    } else {
      if (st) st.textContent = `❌ ${res?.error || JSON.stringify(res?.body || '')}`;
    }
  });

  // Get Production CSID
  el.querySelector('#btnZ2GetPcsid')?.addEventListener('click', async () => {
    const csid = settings.zatcaPhase2?.csid;
    const env = el.querySelector('#z2_env').value;
    if (!csid) { toast(t('zatca2.need_csid_first'), 'warning'); return; }
    const ps = el.querySelector('#z2PcsidStatus');
    if (ps) ps.textContent = '⏳ Upgrading…';
    const res = await window.hubAPI?.zatcaProductionCsid?.({ csid, environment: env });
    if (res?.ok) {
      settings.zatcaPhase2 = { ...settings.zatcaPhase2, pcsid: res.pcsid };
      saveAll();
      if (ps) ps.textContent = '✅ Production CSID stored';
      toast(t('zatca2.pcsid_received'), 'success');
    } else {
      if (ps) ps.textContent = `❌ ${res?.error || JSON.stringify(res?.body || '')}`;
    }
  });

  const logEl = el.querySelector('#z2SubmissionLog');
  const subs = (settings.zatcaPhase2?.submissions || []).slice(0, 20);
  if (logEl) {
    if (!subs.length) {
      logEl.innerHTML = `<p style="color:var(--text-muted);margin:0;">${escapeHtml(t('zatca2.log_empty') || 'No submission attempts yet.')}</p>`;
    } else {
      logEl.innerHTML = `<table style="width:100%;border-collapse:collapse;">
        <thead><tr style="text-align:left;color:var(--text-muted);">
          <th style="padding:4px 6px;">${escapeHtml(t('inv.date') || 'Date')}</th>
          <th style="padding:4px 6px;">${escapeHtml(t('inv.invoice_no') || 'Invoice')}</th>
          <th style="padding:4px 6px;">${escapeHtml(t('common.status') || 'Status')}</th>
        </tr></thead>
        <tbody>${subs.map(s => {
          const color = s.status === 'accepted' ? 'var(--success)' : s.status === 'rejected' ? 'var(--danger)' : 'var(--warning)';
          return `<tr style="border-top:1px solid var(--border);">
            <td style="padding:4px 6px;">${escapeHtml((s.at || '').slice(0, 10))}</td>
            <td style="padding:4px 6px;">${escapeHtml(s.invoiceNumber || s.orderId || '—')}</td>
            <td style="padding:4px 6px;color:${color};">${escapeHtml(s.status || '—')}</td>
          </tr>`;
        }).join('')}</tbody></table>`;
    }
  }
}

function renderExchangeRatesSettings() {
  const el = $('#exchangeRatesSection');
  if (!el) return;
  const base = settings.currency || 'SAR';
  const rates = settings.exchangeRates || {};
  const otherCurrencies = Object.entries(CURRENCIES).filter(([code]) => code !== base);

  const rows = otherCurrencies.map(([code, cur]) => {
    const rate = rates[code] || '';
    return `<tr>
      <td style="padding:6px 8px;font-size:12.5px;">
        <strong>${escapeHtml(code)}</strong>
        <span style="color:var(--text-muted);margin-inline-start:4px;font-size:11px;">${escapeHtml(cur.label)}</span>
      </td>
      <td style="padding:6px 8px;">
        <div style="display:flex;align-items:center;gap:6px;">
          <span style="font-size:11px;color:var(--text-muted);">1 ${escapeHtml(code)} =</span>
          <input type="number" class="xr-input" data-code="${escapeHtml(code)}" aria-label="1 ${escapeHtml(code)} = ? ${escapeHtml(base)}" value="${escapeHtml(String(rate))}" min="0" step="0.0001" placeholder="0.00" style="width:90px;padding:3px 6px;font-size:12px;">
          <span style="font-size:11px;color:var(--text-muted);">${escapeHtml(base)}</span>
        </div>
      </td>
    </tr>`;
  }).join('');

  const updatedAt = settings.exchangeRatesUpdatedAt;
  const updatedHtml = updatedAt
    ? `<span style="font-size:11px;color:var(--text-muted);">${escapeHtml((t('xr.updated') || 'Updated') + ' ' + new Date(updatedAt).toLocaleString())}</span>`
    : '';
  el.innerHTML = `
    <div style="margin-bottom:6px;">
      <p style="font-size:12px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(t('xr.hint') || 'Exchange rates are used to convert foreign-currency orders into your base currency for analytics reporting.')}</p>
      <div style="display:flex;align-items:center;gap:10px;margin:0 0 10px;flex-wrap:wrap;">
        <button type="button" id="xrFetchBtn" class="btn small">⟳ ${escapeHtml(t('xr.fetch') || 'Fetch live rates')}</button>
        ${updatedHtml}
      </div>
      <table style="width:100%;border-collapse:collapse;font-size:12.5px;">
        <thead>
          <tr style="border-bottom:1px solid var(--border);">
            <th style="padding:6px 8px;text-align:start;font-weight:600;color:var(--text-muted);font-size:11px;">${escapeHtml(t('xr.currency') || 'Currency')}</th>
            <th style="padding:6px 8px;text-align:start;font-weight:600;color:var(--text-muted);font-size:11px;">${escapeHtml(t('xr.rate') || 'Rate')} (${escapeHtml(t('xr.rate_hint') || 'base currency units per 1 foreign unit')})</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;

  el.querySelectorAll('.xr-input').forEach(input => {
    input.addEventListener('input', () => {
      const code = input.dataset.code;
      const val = parseFloat(input.value);
      if (!settings.exchangeRates) settings.exchangeRates = {};
      if (!isNaN(val) && val > 0) {
        settings.exchangeRates[code] = val;
      } else {
        delete settings.exchangeRates[code];
      }
      saveAll();
    });
  });

  const fetchBtn = el.querySelector('#xrFetchBtn');
  fetchBtn?.addEventListener('click', async () => {
    if (!window.hubAPI?.fetchExchangeRates) return;
    const base = settings.currency || 'SAR';
    const orig = fetchBtn.textContent;
    fetchBtn.disabled = true;
    fetchBtn.textContent = (t('xr.fetching') || 'Fetching…');
    try {
      const res = await window.hubAPI.fetchExchangeRates(base);
      if (res && res.ok && res.rates) {
        if (!settings.exchangeRates) settings.exchangeRates = {};
        let n = 0;
        for (const [code, rate] of Object.entries(res.rates)) {
          if (CURRENCIES[code] && +rate > 0) { settings.exchangeRates[code] = +(+rate).toFixed(4); n++; }
        }
        settings.exchangeRatesUpdatedAt = res.updatedAt || new Date().toISOString();
        saveAll();
        renderExchangeRatesSettings();
        toast((t('xr.fetched') || 'Updated {n} rates vs {base}').replace('{n}', n).replace('{base}', base), 'success');
      } else {
        fetchBtn.disabled = false; fetchBtn.textContent = orig;
        toast((t('xr.fetch_failed') || 'Could not fetch rates') + (res && res.error ? `: ${res.error}` : ''), 'error', 5000);
      }
    } catch (e) {
      fetchBtn.disabled = false; fetchBtn.textContent = orig;
      toast((t('xr.fetch_failed') || 'Could not fetch rates') + `: ${e.message || e}`, 'error', 5000);
    }
  });
}

function renderBnplSettings() {
  const el = $('#bnplSection');
  if (!el) return;
  const b = settings.bnpl || {};

  // Build config rows for API-integrated services
  const apiSvcs = [
    { id: 'tabby',  label: 'Tabby',  fields: [
        { key: 'apiKey',       label: t('bnpl.api_key'),       type: 'password', ph: 'sk_test_...' },
        { key: 'merchantCode', label: t('bnpl.merchant_code'), type: 'text',     ph: 'MERCHANT_CODE' },
        { key: 'currency',     label: t('bnpl.currency'),      type: 'text',     ph: 'SAR' },
    ]},
    { id: 'tamara', label: 'Tamara', fields: [
        { key: 'apiKey',            label: t('bnpl.api_key'),            type: 'password', ph: 'Bearer token...' },
        { key: 'notificationToken', label: t('bnpl.notification_token'), type: 'password', ph: 'Notification token' },
        { key: 'currency',          label: t('bnpl.currency'),           type: 'text',     ph: 'SAR' },
        { key: 'country',           label: t('bnpl.country'),            type: 'text',     ph: 'SA' },
    ]},
    { id: 'stripe', label: 'Stripe', fields: [
        { key: 'apiKey',      label: t('bnpl.api_key'),     type: 'password', ph: 'sk_live_...' },
        { key: 'currency',    label: t('bnpl.currency'),    type: 'text',     ph: 'sar' },
        { key: 'successUrl',  label: t('bnpl.success_url'), type: 'text',     ph: 'https://...' },
        { key: 'cancelUrl',   label: t('bnpl.cancel_url'),  type: 'text',     ph: 'https://...' },
    ]},
  ];

  const apiRows = apiSvcs.map(svc => {
    const cfg = b[svc.id] || {};
    const flds = svc.fields.map(f =>
      `<div style="flex:1;min-width:140px;">
        <label style="font-size:11px;">${escapeHtml(f.label)}</label>
        <input type="${f.type}" id="bnpl_${svc.id}_${f.key}" value="${escapeHtml(cfg[f.key]||'')}" placeholder="${escapeHtml(f.ph)}" autocomplete="off">
      </div>`
    ).join('');
    return `
    <div style="padding:12px;background:var(--bg-elev);border-radius:var(--radius);margin-bottom:10px;">
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:8px;font-weight:600;">
        <input type="checkbox" id="bnpl_${svc.id}_en" style="width:auto;margin:0;" ${cfg.enabled?'checked':''}>
        <span style="color:${BNPL_CATALOG.find(c=>c.id===svc.id)?.color||'inherit'}">${escapeHtml(svc.label)}</span>
        <span style="font-size:11px;font-weight:400;color:var(--text-muted);">${escapeHtml(BNPL_CATALOG.find(c=>c.id===svc.id)?.desc||'')}</span>
      </label>
      <div style="display:flex;gap:8px;flex-wrap:wrap;">${flds}</div>
    </div>`;
  }).join('');

  // Directory cards for info-only services
  const dirCards = BNPL_CATALOG.filter(s => !s.hasApi).map(s =>
    `<a href="#" class="bnpl-dir-card" data-url="${escapeHtml(s.dashUrl)}" style="display:flex;flex-direction:column;gap:4px;padding:10px 12px;background:var(--bg-elev);border-radius:var(--radius);border-inline-start:3px solid ${escapeHtml(s.color)};text-decoration:none;color:inherit;cursor:pointer;">
      <div style="font-weight:600;font-size:13px;">${escapeHtml(s.name)}</div>
      <div style="font-size:11px;color:var(--text-muted);">${s.regions.slice(0,5).join(' · ')}</div>
      <div style="font-size:11px;color:var(--text-muted);margin-top:2px;">${escapeHtml(s.desc)}</div>
    </a>`
  ).join('');

  el.innerHTML = `
    <h4 style="margin-bottom:10px;font-size:13px;" data-i18n="bnpl.integrated">${t('bnpl.integrated')}</h4>
    ${apiRows}
    <button class="btn primary small" id="btnSaveBnpl" style="margin-bottom:18px;" data-i18n="common.save">${t('common.save')}</button>
    <h4 style="margin-bottom:8px;font-size:13px;" data-i18n="bnpl.directory">${t('bnpl.directory')}</h4>
    <p style="font-size:11px;color:var(--text-muted);margin-bottom:10px;" data-i18n="bnpl.directory_hint">${t('bnpl.directory_hint')}</p>
    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:8px;">${dirCards}</div>`;

  el.querySelector('#btnSaveBnpl')?.addEventListener('click', () => {
    const saved = {};
    for (const svc of apiSvcs) {
      saved[svc.id] = { enabled: el.querySelector(`#bnpl_${svc.id}_en`)?.checked || false };
      for (const f of svc.fields) {
        const curVal = (settings.bnpl || {})[svc.id]?.[f.key];
        saved[svc.id][f.key] = (f.type === 'password')
          ? secretInputSave(curVal, el.querySelector(`#bnpl_${svc.id}_${f.key}`)?.value)
          : (el.querySelector(`#bnpl_${svc.id}_${f.key}`)?.value?.trim() || '');
      }
    }
    settings.bnpl = { ...(settings.bnpl || {}), ...saved };
    saveAll();
    toast(t('bnpl.saved'), 'success');
  });

  el.querySelectorAll('.bnpl-dir-card').forEach(card => {
    card.addEventListener('click', (e) => {
      e.preventDefault();
      const url = card.dataset.url;
      if (url) window.hubAPI?.openExternal?.(url);
    });
  });
}

// Shipping & fulfillment — per-carrier opt-in credentials (encrypted) + webhook secret
// and its displayed inbound URL. Manual shipping needs none of this; this only enables
// the API/webhook path for SMSA / Aramex / SPL. See docs/KHAYT-3.0-SHIPPING-SPEC.md.
function renderShippingSettings() {
  const el = $('#shippingSection');
  if (!el) return;
  const sh = settings.shipping || {};
  const carriers = [
    { id: 'smsa',   label: 'SMSA Express' },
    { id: 'aramex', label: 'Aramex' },
    { id: 'spl',    label: 'Saudi Post (SPL)' },
  ];
  const fields = [
    { key: 'apiKey',        label: t('ship.api_key') || 'API key',         type: 'password', ph: 'API key / token' },
    { key: 'accountNumber', label: t('ship.account') || 'Account number',  type: 'text',     ph: 'Account / customer #' },
    { key: 'webhookSecret', label: t('ship.webhook_secret') || 'Webhook secret', type: 'password', ph: 'Shared HMAC secret' },
  ];
  // Reuse the LAN base URL already resolved into the printer-webhook display (if the
  // server is running); otherwise show the relative path. Never throws on an undefined var.
  const baseUrl = (() => {
    const disp = document.getElementById('webhookUrlDisplay');
    const txt = disp && disp.textContent && disp.textContent !== '—' ? disp.textContent : '';
    const m = txt.match(/^(https?:\/\/[^/]+)/);
    return m ? m[1] : '';
  })();
  const rows = carriers.map(c => {
    const cfg = sh[c.id] || {};
    const flds = fields.map(f => `
      <div style="flex:1;min-width:150px;">
        <label style="font-size:11px;">${escapeHtml(f.label)}</label>
        <input type="${f.type}" id="ship_${c.id}_${f.key}" value="${escapeHtml(f.type === 'password' ? secretInputValue(cfg[f.key]) : (cfg[f.key] || ''))}" placeholder="${escapeHtml(f.type === 'password' ? (secretFieldPlaceholder(cfg[f.key]) || f.ph) : f.ph)}" autocomplete="off">
      </div>`).join('');
    const hookUrl = `${baseUrl}/api/webhook/${c.id}`;
    return `
    <div style="padding:12px;background:var(--bg-elev);border-radius:var(--radius);margin-bottom:10px;">
      <label style="display:flex;align-items:center;gap:8px;cursor:pointer;margin-bottom:8px;font-weight:600;">
        <input type="checkbox" id="ship_${c.id}_en" style="width:auto;margin:0;" ${cfg.enabled ? 'checked' : ''}>
        <span>${escapeHtml(c.label)}</span>
      </label>
      <div style="display:flex;gap:8px;flex-wrap:wrap;">${flds}</div>
      <div style="font-size:11px;color:var(--text-muted);margin-top:8px;">${escapeHtml(t('ship.webhook_url') || 'Inbound status webhook')}: <code style="user-select:all;">${escapeHtml(hookUrl)}</code></div>
    </div>`;
  }).join('');

  el.innerHTML = `
    <p style="font-size:11.5px;color:var(--text-muted);margin-bottom:10px;">${escapeHtml(t('ship.settings_hint') || 'Optional — shipping works fully by hand. Add a carrier key to auto-create labels, and a webhook secret to receive live status updates.')}</p>
    ${rows}
    <button class="btn primary small" id="btnSaveShipping" data-i18n="common.save">${escapeHtml(t('common.save'))}</button>`;

  el.querySelector('#btnSaveShipping')?.addEventListener('click', () => {
    const saved = { ...(settings.shipping || {}) };
    for (const c of carriers) {
      const cur = (settings.shipping || {})[c.id] || {};
      saved[c.id] = { enabled: el.querySelector(`#ship_${c.id}_en`)?.checked || false };
      for (const f of fields) {
        const raw = el.querySelector(`#ship_${c.id}_${f.key}`)?.value;
        saved[c.id][f.key] = (f.type === 'password') ? secretInputSave(cur[f.key], raw) : (raw?.trim() || '');
      }
    }
    settings.shipping = saved;
    saveAll();
    toast(t('ship.saved') || 'Shipping settings saved', 'success');
  });
}

// Privacy / PDPL — retention window for customer-submitted intake data plus a manual
// sweep that anonymizes (not deletes) stale rows, keeping the operational record while
// dropping the PII. See docs/KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md.
// Scoped API tokens (PUBLIC-API-SPEC §1). The plaintext token is shown exactly once,
// at mint time — only its hash is ever stored, so it cannot be recovered afterwards.
const API_TOKEN_SCOPES = ['orders:read', 'orders:write', 'clients:read', 'clients:write', 'inventory:read', 'inventory:write', 'machines:read'];

// Telemetry consent (TELEMETRY-SPEC §3). Off by default, crash and usage consented
// SEPARATELY, revocable without restart — opting out purges the local queue and clears
// the install id so nothing identifying survives.
function renderTelemetrySettings() {
  const el = $('#telemetrySection');
  if (!el) return;
  const tm = settings.telemetry || {};
  el.innerHTML = `
    <p style="font-size:11.5px;color:var(--text-muted);margin-bottom:10px;">${escapeHtml(t('tel.hint') || 'Khayt sends nothing by default. You can optionally share crash reports and anonymous usage counts to help fix bugs. Never your orders, customers, prices or files.')}</p>
    <label style="display:flex;align-items:flex-start;gap:8px;font-weight:400;cursor:pointer;margin-bottom:8px;">
      <input type="checkbox" id="tel_crash" style="width:auto;margin-top:3px;" ${tm.crashOptIn ? 'checked' : ''}>
      <span><b>${escapeHtml(t('tel.crash') || 'Share crash reports')}</b><br>
      <span style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('tel.crash_hint') || 'A scrubbed error message and stack trace when something breaks.')}</span></span>
    </label>
    <label style="display:flex;align-items:flex-start;gap:8px;font-weight:400;cursor:pointer;">
      <input type="checkbox" id="tel_usage" style="width:auto;margin-top:3px;" ${tm.usageOptIn ? 'checked' : ''}>
      <span><b>${escapeHtml(t('tel.usage') || 'Share anonymous usage counts')}</b><br>
      <span style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('tel.usage_hint') || 'Which features are used, as counts only — never what is in them.')}</span></span>
    </label>
    <div style="display:flex;gap:10px;align-items:center;margin-top:12px;flex-wrap:wrap;">
      <button class="btn small" id="btnViewTelemetry">${escapeHtml(t('tel.view') || 'View what’s collected')}</button>
      ${tm.consentAt ? `<span style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('tel.consented') || 'Consented')}: ${escapeHtml(String(tm.consentAt).split('T')[0])}</span>` : ''}
    </div>`;

  const persist = async () => {
    const crash = !!el.querySelector('#tel_crash')?.checked;
    const usage = !!el.querySelector('#tel_usage')?.checked;
    const prev = settings.telemetry || {};
    const anyOn = crash || usage;
    let installId = prev.installId || '';
    if (anyOn && !installId) {
      // Rotating, non-identifying install id — created only on opt-in.
      const b = new Uint8Array(8); crypto.getRandomValues(b);
      installId = Array.from(b, x => x.toString(16).padStart(2, '0')).join('');
    }
    settings.telemetry = {
      crashOptIn: crash, usageOptIn: usage,
      installId: anyOn ? installId : '',
      consentAt: anyOn ? (prev.consentAt || new Date().toISOString()) : '',
    };
    saveAll();
    // Opting fully out purges anything queued locally, immediately.
    if (!anyOn) { try { await window.hubAPI?.telemetryPurge?.(); } catch (_) {} }
    renderTelemetrySettings();
    toast(t('tel.saved') || 'Telemetry preferences saved', 'success');
  };
  el.querySelector('#tel_crash')?.addEventListener('change', persist);
  el.querySelector('#tel_usage')?.addEventListener('change', persist);

  el.querySelector('#btnViewTelemetry')?.addEventListener('click', async () => {
    const Scrub = (typeof KhaytTelemetryScrub !== 'undefined') ? KhaytTelemetryScrub : null;
    const tmNow = settings.telemetry || {};
    const sample = { crash: null, usage: null };
    if (Scrub) {
      if (tmNow.crashOptIn) sample.crash = Scrub.buildCrashReport({
        type: 'uncaughtException', name: 'TypeError', message: 'example failure',
        stack: 'TypeError: example\n    at someFunction (renderer/app.js:1:1)',
        process: 'renderer', appVersion: (window.KHAYT_VERSION || ''), osFamily: 'macOS', osMajor: '14',
        locale: (typeof i18n !== 'undefined' ? i18n.current : 'en'), channel: settings.betaUpdates ? 'beta' : 'stable',
        installId: tmNow.installId,
      });
      if (tmNow.usageOptIn) sample.usage = Scrub.buildUsageEvent({
        feature: 'quote_created', count: 1, mode: settings.mode, businessType: settings.businessType,
        vatEnabled: !!settings.enableVat, zatcaEnabled: !!settings.zatcaEnabled,
        onlineEnabled: !!settings.onlineEnabled, lanEnabled: !!(settings.lanApi || {}).enabled,
        sessions: 1, appVersion: (window.KHAYT_VERSION || ''),
        locale: (typeof i18n !== 'undefined' ? i18n.current : 'en'), channel: settings.betaUpdates ? 'beta' : 'stable',
        installId: tmNow.installId,
      });
    }
    const body = (!sample.crash && !sample.usage)
      ? `<p style="font-size:13px;">${escapeHtml(t('tel.nothing') || 'Nothing is collected — both options are off.')}</p>`
      : `<p style="font-size:12.5px;color:var(--text-dim);margin-bottom:8px;">${escapeHtml(t('tel.view_hint') || 'This is exactly what would be sent — nothing else.')}</p>
         <pre style="max-height:52vh;overflow:auto;background:var(--bg-elev);padding:12px;border-radius:var(--radius);font-size:11.5px;white-space:pre-wrap;">${escapeHtml(JSON.stringify(sample, null, 2))}</pre>`;
    openFormModal({ title: t('tel.view') || 'What’s collected', sizeLg: false, noSave: true, bodyHtml: body });
  });
}

function renderApiTokensSettings() {
  const el = $('#apiTokensSection');
  if (!el) return;
  const toks = ((settings.lanApi || {}).apiTokens) || [];

  const list = toks.length ? toks.map(tk => `
    <div style="display:flex;align-items:center;gap:10px;padding:8px 10px;background:var(--bg-elev);border-radius:var(--radius);margin-bottom:6px;flex-wrap:wrap;">
      <b style="font-size:13px;">${escapeHtml(tk.label || tk.id)}</b>
      <span style="font-size:11px;color:var(--text-muted);">${escapeHtml((tk.scopes || []).join(', ') || '—')}</span>
      <span class="grow" style="flex:1;"></span>
      <span style="font-size:11px;color:var(--text-muted);">${escapeHtml((tk.createdAt || '').split('T')[0] || '')}</span>
      <button class="btn danger small" data-act="revoke-api-token" data-id="${escapeHtml(tk.id)}" style="margin:0;">${escapeHtml(t('api.revoke') || 'Revoke')}</button>
    </div>`).join('') : `<div class="empty-state" style="padding:12px;font-size:12px;">${escapeHtml(t('api.none') || 'No API tokens yet.')}</div>`;

  el.innerHTML = `
    <p style="font-size:11.5px;color:var(--text-muted);margin-bottom:10px;">${escapeHtml(t('api.hint') || 'Give an automation tool (Zapier, Make, a script) access to this shop over the local API. A token only gets the scopes you tick, and is shown once.')}</p>
    ${list}
    <div style="margin-top:12px;padding-top:12px;border-top:1px solid var(--border-soft);">
      <label>${escapeHtml(t('api.label') || 'Label')}</label>
      <input type="text" id="apiTokLabel" placeholder="${escapeHtml(t('api.label_ph') || 'e.g. Zapier')}" style="max-width:260px;">
      <div style="display:flex;flex-wrap:wrap;gap:10px;margin-top:10px;">
        ${API_TOKEN_SCOPES.map(sc => `<label style="display:flex;align-items:center;gap:6px;font-weight:400;font-size:12px;cursor:pointer;">
          <input type="checkbox" class="apiScope" value="${sc}" style="width:auto;margin:0;"> ${escapeHtml(sc)}</label>`).join('')}
      </div>
      <button class="btn primary small" id="btnMintApiToken" style="margin-top:12px;">${escapeHtml(t('api.mint') || 'Create token')}</button>
    </div>`;

  el.querySelector('#btnMintApiToken')?.addEventListener('click', async () => {
    const label = el.querySelector('#apiTokLabel')?.value.trim() || '';
    const scopes = Array.from(el.querySelectorAll('.apiScope:checked')).map(c => c.value);
    if (!scopes.length) { toast(t('api.need_scope') || 'Tick at least one scope', 'warning'); return; }
    const r = await window.hubAPI?.mintApiToken?.({ label, scopes });
    if (!r || !r.ok) { toast((r && r.error) || 'Could not create token', 'error'); return; }
    settings.lanApi = { ...(settings.lanApi || {}), apiTokens: [...(((settings.lanApi || {}).apiTokens) || []), r.record] };
    saveAll();
    renderApiTokensSettings();
  renderTelemetrySettings();
    // Shown once — the plaintext is never stored and cannot be retrieved again.
    openFormModal({
      title: t('api.created') || 'API token created',
      sizeLg: false,
      noSave: true,
      bodyHtml: `
        <p style="font-size:12.5px;color:var(--text-dim);margin-bottom:10px;">${escapeHtml(t('api.copy_now') || 'Copy this now — it is shown only once and cannot be recovered.')}</p>
        <input type="text" readonly value="${escapeHtml(r.token)}" style="width:100%;font-family:monospace;font-size:12px;" onclick="this.select()">`,
    });
  });

  el.querySelectorAll('[data-act="revoke-api-token"]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const ok = await confirmModal(t('api.revoke_q') || 'Revoke this token? Any automation using it stops working immediately.', { danger: true });
      if (!ok) return;
      settings.lanApi = { ...(settings.lanApi || {}), apiTokens: (((settings.lanApi || {}).apiTokens) || []).filter(x => x.id !== btn.dataset.id) };
      saveAll();
      renderApiTokensSettings();
      toast(t('api.revoked') || 'Token revoked', 'success');
    });
  });
}

function renderPrivacySettings() {
  const el = $('#privacySection');
  if (!el) return;
  const months = Math.max(0, num((settings.privacy || {}).retentionMonths, 0));
  const P = (typeof KhaytPrivacy !== 'undefined') ? KhaytPrivacy : null;
  const stale = P ? P.selectStaleIntakeRows(
    [...(waitingList || []), ...(waitingListHistory || [])].map(r => ({ ...r, at: r.at || r.submittedAt || r.date })),
    months, Date.now()).length : 0;

  // "Customer data stays on this machine" is only true while no AI feature that
  // transmits customer data is on. Rather than weaken the claim for everyone,
  // qualify it exactly when it stops holding.
  const aiP = window.KhaytAiPrivacy;
  const aiSending = aiP ? aiP.activeCustomerDataFeatures(settings.ai) : [];
  const aiCaveat = aiSending.length ? `
    <p class="priv-ai-caveat">
      ${escapeHtml(t('priv.ai_active') || 'Except: an AI feature you enabled sends customer data to Anthropic.')}
      <strong>${escapeHtml(aiSending.map((id) => t(aiP.AI_FEATURES[id].labelKey) || id).join(', '))}</strong>
      <button type="button" class="btn small ghost" id="btnPrivReviewAi">${escapeHtml(t('priv.ai_review') || 'Review AI settings')}</button>
    </p>` : '';

  el.innerHTML = `
    <p style="font-size:11.5px;color:var(--text-muted);margin-bottom:10px;">${escapeHtml(t('priv.settings_hint') || 'Customer data stays on this machine. Optionally anonymize old intake submissions after a set period — their contact details are removed, the request record is kept.')}</p>
    ${aiCaveat}
    <div style="max-width:240px;">
      <label>${escapeHtml(t('priv.retention_months') || 'Anonymize intake data after (months)')}</label>
      <input type="number" id="set_privacyRetention" min="0" step="1" value="${months}" placeholder="0 = keep indefinitely">
    </div>
    <div style="display:flex;align-items:center;gap:10px;margin-top:12px;flex-wrap:wrap;">
      <button class="btn small primary" id="btnSavePrivacy">${escapeHtml(t('common.save'))}</button>
      <button class="btn small" id="btnRunRetention" ${stale ? '' : 'disabled'}>${escapeHtml(t('priv.run_sweep') || 'Anonymize stale intake now')}</button>
      <span style="font-size:11.5px;color:var(--text-muted);">${escapeHtml(
        months > 0 ? (t('priv.stale_count', { n: stale }) || `${stale} submission(s) older than ${months} month(s)`) : (t('priv.retention_off') || 'Retention off'))}</span>
    </div>`;

  el.querySelector('#btnPrivReviewAi')?.addEventListener('click', () => {
    document.querySelector('#aiSettingsSection')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  });

  el.querySelector('#btnSavePrivacy')?.addEventListener('click', () => {
    settings.privacy = { ...(settings.privacy || {}), retentionMonths: Math.max(0, num($('#set_privacyRetention')?.value, 0)) };
    saveAll();
    renderPrivacySettings();
  renderApiTokensSettings();
    toast(t('priv.saved') || 'Privacy settings saved', 'success');
  });

  el.querySelector('#btnRunRetention')?.addEventListener('click', async () => {
    if (!P) return;
    const ok = await confirmModal(t('priv.sweep_q') || 'Anonymize the contact details on stale intake submissions? This cannot be undone.', { danger: true });
    if (!ok) return;
    const cutoffOf = (r) => ({ ...r, at: r.at || r.submittedAt || r.date });
    const staleIds = new Set(P.selectStaleIntakeRows([...(waitingList || []), ...(waitingListHistory || [])].map(cutoffOf), months, Date.now()).map(r => r.id));
    let n = 0;
    waitingList = (waitingList || []).map(r => { if (staleIds.has(r.id)) { n++; return P.anonymizeIntakeRow(r); } return r; });
    waitingListHistory = (waitingListHistory || []).map(r => { if (staleIds.has(r.id)) { n++; return P.anonymizeIntakeRow(r); } return r; });
    saveAll();
    if (typeof renderWaitingList === 'function') renderWaitingList();
    renderPrivacySettings();
    toast(t('priv.swept', { n }) || `Anonymized ${n} submission(s)`, 'success');
  });
}

function renderSavedFilterPresets() {
  const el = $('#savedFiltersBar');
  if (!el) return;
  const saved = settings.savedFilters || [];
  if (saved.length === 0) {
    el.style.display = 'none';
    return;
  }
  el.style.display = 'flex';
  el.innerHTML = `
    <span style="font-size:11.5px;color:var(--text-muted);white-space:nowrap;">Saved:</span>
    ${saved.map((f, i) => `
      <button class="btn ghost small" data-load-filter="${i}" title="${escapeHtml(f.name)}" style="font-size:12px;">${escapeHtml(f.name)}</button>
      <button class="btn ghost small" data-del-filter="${i}" style="font-size:10px;padding:2px 5px;color:var(--text-muted);" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">✕</button>
    `).join('')}`;

  el.querySelectorAll('[data-load-filter]').forEach(btn => {
    btn.addEventListener('click', () => {
      const f = saved[parseInt(btn.dataset.loadFilter)];
      if (!f) return;
      logStatusFilter = f.status || '';
      logPayFilter    = f.pay    || '';
      logTagFilter    = f.tag    || '';
      logRangeFilter  = f.range  || 'all';
      logSearchTerm   = f.search || '';
      logOperatorFilter = f.operator || '';
      // Sync UI dropdowns
      const s = $('#logStatusFilter'); if (s) s.value = logStatusFilter;
      const p = $('#logPayFilter');    if (p) p.value = logPayFilter;
      const tg = $('#logTagFilter');   if (tg) tg.value = logTagFilter;
      const r = $('#logRangeFilter');  if (r) r.value = logRangeFilter;
      const sr = $('#logSearch');      if (sr) sr.value = logSearchTerm;
      renderLogs();
      toast(`Filter "${f.name}" loaded`, 'success', 1800);
    });
  });
  el.querySelectorAll('[data-del-filter]').forEach(btn => {
    btn.addEventListener('click', () => {
      settings.savedFilters.splice(parseInt(btn.dataset.delFilter), 1);
      saveAll(); renderSavedFilterPresets();
    });
  });
}

function saveCurrentFilterPreset() {
  openFormModal({
    title: '💾 Save Filter Preset',
    saveLabel: 'Save',
    bodyHtml: `<label>Preset name</label><input type="text" id="filterPresetName" placeholder="e.g. Unpaid this month">`,
    onSave: () => {
      const name = $('#filterPresetName')?.value?.trim();
      if (!name) {
        toast(t('log.preset_name_required') || 'Enter a preset name', 'warning');
        return false;
      }
      const preset = {
        id: Date.now().toString(36),
        name,
        status: logStatusFilter,
        pay:    logPayFilter,
        tag:    logTagFilter,
        range:  logRangeFilter,
        search: logSearchTerm,
        operator: logOperatorFilter,
      };
      settings.savedFilters = [...(settings.savedFilters || []), preset];
      saveAll();
      renderSavedFilterPresets();
      toast(`Preset "${name}" saved ✓`, 'success');
    }
  });
}

function updateLogoPreview() {
  const preview = $('#logoPreview');
  const removeBtn = $('#btnRemoveLogo');
  if (!preview) return;
  if (safeBizLogo()) {
    preview.src = safeBizLogo();
    preview.style.display = 'block';
    if (removeBtn) removeBtn.style.display = 'inline-flex';
  } else {
    preview.style.display = 'none';
    if (removeBtn) removeBtn.style.display = 'none';
  }
}

async function syncUpdaterOptionsFromSettings() {
  const allowBeta = !!settings.betaUpdates;
  if (!window.hubAPI?.setUpdateOptions) return;
  try {
    await window.hubAPI.setUpdateOptions({ allowBeta });
  } catch (_) {}
}

/** How each language names itself — what a picker of languages should show. */
const LANG_ENDONYMS = {
  en: 'English', ar: 'العربية', de: 'Deutsch', es: 'Español', fr: 'Français',
  zh: '中文 (简体)', ja: '日本語', tr: 'Türkçe', 'pt-BR': 'Português (Brasil)',
};

/**
 * Keep the two document-language controls honest about what they will actually do.
 *
 * Neither is disabled, deliberately: the owner's choices are remembered and take
 * effect the moment ZATCA is switched off. Greying them out would lose that and
 * would read as "unavailable" rather than "currently outranked".
 *
 * Reads the live checkbox rather than saved settings, so the note appears the
 * moment ZATCA is ticked instead of after a save.
 */
function syncInvLanguageControls() {
  const sel = $('#set_invoiceSecondLang');
  const note = $('#invBilingualZatcaNote');
  const row = $('#invSecondLangRow');
  const zatcaOn = $('#set_enableZatca')
    ? !!$('#set_enableZatca').checked
    : settings.enableZatca !== false;
  const mode = $('#set_invoiceBilingual')?.value || settings.invoiceBilingual || 'auto';
  const primary = i18n.current;

  if (note) note.style.display = zatcaOn ? '' : 'none';

  if (sel) {
    // The working language cannot also be the second one — that is the same
    // labels printed twice, and the resolver refuses it anyway.
    const langs = KhaytInvoiceLanguage.LANGS.filter((l) => l !== primary);
    const want = KhaytInvoiceLanguage.resolveSecondary(primary, settings.invoiceSecondLang);
    sel.innerHTML = langs.map((l) =>
      `<option value="${escapeHtml(l)}"${l === want ? ' selected' : ''}>${escapeHtml(LANG_ENDONYMS[l] || l)}</option>`
    ).join('');
    sel.value = want;
  }

  // Hide the picker when nothing will be printed in a second language. Under
  // ZATCA the answer is Arabic and not the shop's to choose, so the row goes
  // too — the note above already explains why.
  if (row) {
    const willBeBilingual = KhaytInvoiceLanguage.resolveDocumentLanguage({
      mode, lang: primary, secondary: settings.invoiceSecondLang, enableZatca: zatcaOn,
    });
    row.style.display = (willBeBilingual.bilingual && !willBeBilingual.forced) ? '' : 'none';
  }
}

/** Country names for the tax-rules picker, in the shop's own language where we have one. */
const TAX_COUNTRY_NAMES = {
  SA: 'Saudi Arabia', AE: 'United Arab Emirates', KW: 'Kuwait', QA: 'Qatar', BH: 'Bahrain',
  OM: 'Oman', EG: 'Egypt', JO: 'Jordan', GB: 'United Kingdom', DE: 'Germany', FR: 'France',
  ES: 'Spain', IT: 'Italy', NL: 'Netherlands', PT: 'Portugal', IE: 'Ireland', CH: 'Switzerland',
  NO: 'Norway', SE: 'Sweden', TR: 'Türkiye', ZA: 'South Africa', AU: 'Australia',
  NZ: 'New Zealand', SG: 'Singapore', JP: 'Japan', IN: 'India', US: 'United States',
  CA: 'Canada', MX: 'Mexico', BR: 'Brazil',
};

/**
 * Fill the tax controls and explain, in money, what the pricing mode means.
 *
 * The inclusive/exclusive choice is the one a shop can get wrong without
 * noticing — both look plausible in a settings panel and they differ by the tax
 * on every order. So the hint shows the actual arithmetic on a round number
 * rather than describing it.
 */
function syncTaxControls() {
  const profile = KhaytTax.profileFromSettings(settings);
  const sel = $('#set_taxCountry');
  if (sel && !sel.options.length) {
    const codes = Object.keys(KhaytTax.PRESETS).sort((a, b) =>
      (TAX_COUNTRY_NAMES[a] || a).localeCompare(TAX_COUNTRY_NAMES[b] || b));
    sel.innerHTML = '<option value="">' + escapeHtml(t('set.tax_country_custom') || 'Custom') + '</option>'
      + codes.map((c) => `<option value="${escapeHtml(c)}">${escapeHtml(TAX_COUNTRY_NAMES[c] || c)}</option>`).join('');
  }
  if (sel) sel.value = settings.tax?.country || '';
  const modeEl = $('#set_taxMode');
  if (modeEl) modeEl.value = profile.mode;
  const hint = $('#taxModeHint');
  if (hint) {
    const rate = profile.rates.reduce((sum, r) => sum + r.percent, 0);
    if (!rate) { hint.textContent = ''; return; }
    const shown = KhaytTax.computeTax(100, profile);
    hint.textContent = (t('set.tax_mode_example')
      || 'A price of 100 is invoiced as {total} — {subtotal} plus {tax} tax.')
      .replace('{total}', fmtMoney(shown.total))
      .replace('{subtotal}', fmtMoney(shown.subtotal))
      .replace('{tax}', fmtMoney(shown.taxTotal));
  }
}

function loadSettingsIntoForm() {
  // The per-language text fields are built by renderContentFields() from the
  // shop's chosen languages, and carry their own values — there is no fixed set
  // of ids to populate here any more.
  renderContentFields();
  $('#set_vat').value       = settings.vat       || '';
  $('#set_cr').value        = settings.cr        || '';
  $('#set_phone').value     = settings.phone     || '';
  $('#set_email').value     = settings.email     || '';
  $('#set_lang').value      = settings.lang      || 'en';
  $('#set_theme').value     = settings.theme     || 'dark';
  if (typeof populateDesignSelects === 'function') populateDesignSelects();
  if (typeof syncDesignSettingsUi === 'function') syncDesignSettingsUi();
  $('#set_invPrefix').value = settings.invPrefix || 'INV';
  $('#set_autoDeduct').checked = settings.autoDeduct !== false;
  $('#set_lowStock').value  = settings.lowStockThreshold ?? 200;
  // 1.3 additions
  $('#set_bankName').value      = settings.bankName      || '';
  $('#set_accountHolder').value = settings.accountHolder || '';
  $('#set_iban').value          = settings.iban          || '';
  $('#set_useHijri').checked    = settings.useHijri !== false;
  $('#set_useArabicNumerals').checked = !!settings.useArabicNumerals;
  $('#set_autoBackup').checked  = settings.autoBackup !== false;
  renderPrintLibLocation();
  if ($('#set_coachTips')) $('#set_coachTips').checked = settings.coachTips !== false;
  $('#set_enableVat').checked   = !!settings.enableVat;
  $('#set_vatRate').value       = settings.vatRate ?? 15;
  $('#set_quotePrefix').value   = settings.quotePrefix || 'QUO';
  $('#set_useIcloud').checked   = !!settings.useIcloud;
  $('#set_invAccent').value     = safeCssColor(settings.invAccentColor, '#5E2E14');
  if ($('#set_invTemplate')) $('#set_invTemplate').value = settings.invTemplate || 'classic';
  const lscEl = $('#set_lowStockColor');
  // The unset swatch shows the THEME's low-stock colour, not a literal amber —
  // every theme darkens it for light appearance, so a fixed hex here would
  // advertise a colour the inventory tab is not using.
  if (lscEl) lscEl.value = safeCssColor(settings.lowStockColor, themeLowStockColor());
  if (lscEl && !lscEl.dataset.lowStockBound) {
    lscEl.dataset.lowStockBound = '1';
    // Live: a colour is judged by looking at it, not by saving and navigating
    // to the inventory tab to find out.
    lscEl.addEventListener('input', () => {
      document.documentElement.style.setProperty('--low-stock', safeCssColor(lscEl.value, themeLowStockColor()));
    });
    $('#btnResetLowStockColor')?.addEventListener('click', () => {
      settings.lowStockColor = '';
      // Clear the override FIRST: themeLowStockColor() reads --warning, which
      // this feature never overrides, but clearing first keeps the swatch and
      // the rendered colour in step even if that ever stops being true.
      document.documentElement.style.removeProperty('--low-stock');
      lscEl.value = themeLowStockColor();
    });
  }
  const biEl = $('#set_invoiceBilingual');
  if (biEl) biEl.value = settings.invoiceBilingual || 'auto';
  if (biEl && !biEl.dataset.langRowBound) {
    biEl.dataset.langRowBound = '1';
    biEl.addEventListener('change', syncInvLanguageControls);
  }
  $('#set_monthlyGoal').value     = settings.monthlyGoal ?? 0;
  $('#set_supplierPhone').value   = settings.supplierPhone || '';
  // New Feature 7: Working hours
  const wh = KhaytWorkingWeek.workingHours(settings);
  ['mon','tue','wed','thu','fri','sat','sun'].forEach(d => {
    const el = $(`#wh_${d}`);
    if (el) el.value = wh[d] ?? 0;
  });
  renderHolidayList();
  updateLogoPreview();
  // Accepted payments checkboxes
  $$('#acceptedPaymentsList input[data-pm]').forEach(cb => {
    cb.checked = (settings.acceptedPayments || []).includes(cb.dataset.pm);
  });
  // 2.0 worldwide / regional
  const curSel = $('#set_currency');
  if (curSel && !curSel.options.length) {
    curSel.innerHTML = Object.entries(CURRENCIES)
      .map(([code, c]) => `<option value="${code}">${escapeHtml(c.label)}</option>`)
      .join('');
  }
  if (curSel) {
    curSel.value = settings.currency || 'SAR';
    if (!curSel.dataset.currencyPreviewBound) {
      curSel.dataset.currencyPreviewBound = '1';
      curSel.addEventListener('change', () => {
        const sym = (CURRENCIES[curSel.value] || CURRENCIES.SAR).symbol;
        document.querySelectorAll('[data-i18n="common.currency"]').forEach((el) => {
          el.textContent = sym;
        });
      });
    }
  }
  const langSelHdr = $('#langSelect');
  if (langSelHdr) langSelHdr.value = settings.lang || 'en';
  const zatcaEl = $('#set_enableZatca');
  if (zatcaEl) zatcaEl.checked = settings.enableZatca !== false;
  // The document-language picker is overridden while ZATCA is on, so say so
  // rather than leaving a control that silently does nothing. Bound here off the
  // live checkbox, not the saved setting, so the note appears the moment ZATCA
  // is ticked instead of after a save.
  if (zatcaEl && !zatcaEl.dataset.bilingualNoteBound) {
    zatcaEl.dataset.bilingualNoteBound = '1';
    zatcaEl.addEventListener('change', syncInvLanguageControls);
  }
  // Deliberately AFTER the ZATCA checkbox is populated, not with the other
  // invoice fields above it. This reads the live controls rather than saved
  // settings so it reacts before a save — which means running it while the
  // checkbox still holds the previous load's value computes the wrong answer
  // and leaves the picker hidden on a shop that is not under ZATCA at all.
  syncInvLanguageControls();
  syncTaxControls();
  // A country choice rewrites name, rate, mode and registration label together —
  // picking them apart is exactly the fiddly bit a preset exists to remove.
  const tcEl = $('#set_taxCountry');
  if (tcEl && !tcEl.dataset.taxBound) {
    tcEl.dataset.taxBound = '1';
    tcEl.addEventListener('change', () => {
      const code = tcEl.value;
      if (!code) return;
      // The rule is shared with the Mac app's Settings window, which applies
      // it at save time rather than on the change.
      settings = KhaytSettingsEdit.chooseCountry(settings, code);
      const first = settings.tax.rates[0];
      if ($('#set_enableVat')) $('#set_enableVat').checked = !!first;
      if ($('#set_vatRate') && first) $('#set_vatRate').value = first.percent;
      syncTaxControls();
    });
  }
  const tmEl = $('#set_taxMode');
  if (tmEl && !tmEl.dataset.taxBound) {
    tmEl.dataset.taxBound = '1';
    tmEl.addEventListener('change', () => {
      const prof = KhaytTax.profileFromSettings(settings);
      settings.tax = { ...(settings.tax || {}), name: prof.name, registration: prof.registration, rates: prof.rates, mode: tmEl.value };
      syncTaxControls();
    });
  }
  // Min-margin warning threshold
  const minMargEl = $('#set_minMarginPct');
  if (minMargEl) minMargEl.value = settings.minMarginPct ?? 0;
  // Easy-wins: Calculator settings
  const qvEl = $('#set_quoteValidityDays');
  if (qvEl) qvEl.value = settings.quoteValidityDays ?? 7;
  // Delivery estimates. Read from settings.leadTime with the same conservative
  // defaults the engine uses — a blank field must not become "no limit", which
  // for hours per day would promise a shop working round the clock.
  {
    const lt = settings.leadTime || {};
    const put = (id, v) => { const el = $(id); if (el) el.value = v; };
    put('#set_leadFinishingDays', lt.finishingDays != null ? lt.finishingDays : 1);
    put('#set_leadDispatchDays', lt.dispatchDays != null ? lt.dispatchDays : 1);
    put('#set_leadSafetyDays', lt.safetyDays != null ? lt.safetyDays : 1);
    const pub = $('#set_leadPublish');
    if (pub) pub.checked = !!lt.publishToCloud;
  }

  const qfEnEl = $('#set_quoteFollowUpEnabled');
  if (qfEnEl) qfEnEl.checked = !!(settings.quoteFollowUp && settings.quoteFollowUp.enabled);
  const qfWinEl = $('#set_quoteFollowUpWindow');
  if (qfWinEl) qfWinEl.value = (settings.quoteFollowUp && settings.quoteFollowUp.windowDays != null) ? settings.quoteFollowUp.windowDays : 2;
  const prEnEl = $('#set_payReminderEnabled');
  if (prEnEl) prEnEl.checked = !!(settings.paymentReminder && settings.paymentReminder.enabled);
  const prGrEl = $('#set_payReminderGrace');
  if (prGrEl) prGrEl.value = (settings.paymentReminder && settings.paymentReminder.graceDays != null) ? settings.paymentReminder.graceDays : 3;
  const moEl = $('#set_minOrderAmount');
  if (moEl) moEl.value = settings.minOrderAmount ?? 0;
  const rfEl = $('#set_rushFeeEnabled');
  if (rfEl) rfEl.checked = !!settings.rushFeeEnabled;
  const rpEl = $('#set_rushFeePct');
  if (rpEl) rpEl.value = settings.rushFeePct ?? 25;
  // Packaging cost + payment instructions
  const pcEl = $('#set_defaultPackagingCost');
  if (pcEl) pcEl.value = settings.defaultPackagingCost ?? 0;
  const piEl = $('#set_paymentInstructions');
  if (piEl) piEl.value = settings.paymentInstructions ?? '';
  // WIP limits
  const wipCols = ['pending', 'printing', 'post', 'qc'];
  wipCols.forEach(col => {
    const el = $(`#set_wip_${col}`);
    if (el) el.value = (settings.wipLimits || {})[col] || '';
  });
  const wipHardEl = $('#set_wipEnforceHardLimit');
  if (wipHardEl) wipHardEl.checked = !!settings.wipEnforceHardLimit;
  // QC / reprint / RMA
  const _qc = settings.qc || {};
  if ($('#set_qcEnabled')) $('#set_qcEnabled').checked = !!_qc.enabled;
  if ($('#set_qcRequireInspector')) $('#set_qcRequireInspector').checked = !!_qc.requireInspector;
  if ($('#set_qcRequirePhotoOnFail')) $('#set_qcRequirePhotoOnFail').checked = !!_qc.requirePhotoOnFail;
  if ($('#set_qcWarrantyDays')) $('#set_qcWarrantyDays').value = (_qc.warrantyDays != null ? _qc.warrantyDays : 30);
  // Post-process presets list
  renderPostProcessPresetsList();
  // Expense budgets
  EXP_CATEGORIES.forEach(c => {
    const el = $(`#set_budget_${c}`);
    if (el) el.value = (settings.expBudgets || {})[c] || 0;
  });
  // Post-processing checklist
  renderPostChecklistSettings();
  // Custom order fields
  renderCustomFieldsSettings();
  refreshCurrencyLabels();
  updateLastBackupDisplay();
  // Invoice numbering section (Feature 7)
  renderInvoiceNumberingSection();
  // Feature 8 / Task 0: Storage usage display
  renderStorageUsage();
  renderSecuritySettings();
  // Feature 7 (new 8-pack): Operator lock checkbox
  const opLockEl = $('#set_operatorLock');
  if (opLockEl) opLockEl.checked = !!settings.operatorLockEnabled;
  // Feature 8 (new 8-pack): Loyalty enabled checkbox
  const loyaltyEl = $('#set_loyaltyEnabled');
  if (loyaltyEl) loyaltyEl.checked = !!settings.loyaltyEnabled;
  // Feature 5 (new 8-pack): Email notifications
  renderEmailNotificationSettings();
  renderSmsNotificationSettings();
  renderAccountingSyncSettings();
  renderIntegrationsSettings();
  // Batch-2 Feature 10: Telegram settings
  renderTelegramSettings();
  // Feature I: Email digest scheduler
  renderDigestSettings();
  renderAiSettings();
  renderSlicerSettings();
  renderContentLangsPicker();
  // The nozzle wear table lives beside the printers it applies to.
  if (typeof renderNozzleWearSettings === 'function') renderNozzleWearSettings();
  renderCloudSettings();
  // Feature 7 (new 8-pack): Operator lock section
  renderOperatorLockSettings();
  // Feature 8 (new 8-pack): Loyalty tiers
  renderLoyaltyTiersSettings();
  // Round 12: Webhooks
  renderWebhookSettings();
  renderEventWebhookSettings();
  // Round 12: Fixed costs / break-even
  renderFixedCostSettings();
  // Online (customer intake)
  renderOnlineSettings?.();
  // Round 12: LAN API
  renderLanApiSettings();
  renderEstimatorSettings();
  // ZATCA Phase 2
  renderZatcaPhase2Settings();
  renderBnplSettings();
  renderShippingSettings();
  renderPrivacySettings();
  // Feature H: Exchange rates
  renderExchangeRatesSettings();
  // Round 12: Saved filter presets
  renderSavedFilterPresets();
  // Business Mode toggle buttons
  applyMode();
  // New feature sections inside settings tab
  renderSlicerProfiles();
  renderEnvLogs();
  const betaUpdEl = $('#set_betaUpdates');
  if (betaUpdEl) {
    betaUpdEl.checked = !!settings.betaUpdates;
    if (!betaUpdEl.dataset.updaterBound) {
      betaUpdEl.dataset.updaterBound = '1';
      betaUpdEl.addEventListener('change', () => {
        settings.betaUpdates = betaUpdEl.checked;
        syncUpdaterOptionsFromSettings();
      });
    }
  }
  syncUpdaterOptionsFromSettings();
}

/* Feature 8 / Task 0: File-store size display in Settings */
async function renderStorageUsage() {
  const el = $('#storageUsageDisplay');
  if (!el) return;
  let sizeBytes = 0;
  try {
    sizeBytes = await window.hubAPI?.storeSize?.() || 0;
  } catch(e) {}
  /* THERE IS A SIZE LIMIT, AND THIS SAID THERE WAS NOT.
   *
   * "No size limit — file-based storage ✓", in green, with a tick. main.js
   * refuses to WRITE a store over 50 MB (`hub:save-store`) and refuses to READ
   * one (`recoverStoreRaw(50_000_000)`). Past that line every save fails: the
   * shop gets a toast, keeps working, and loses the day at the next launch.
   *
   * A shop with a few thousand print files was reaching it — previews were about
   * nine tenths of what a record cost — and the one screen they would look at to
   * find out told them the opposite, in the colour that means "fine".
   *
   * So: say the number, say the limit, and change colour BEFORE the wall rather
   * than after it. */
  const LIMIT = 50 * 1000 * 1000;          // the byte figure main.js compares against
  const pct = Math.min(100, Math.round((sizeBytes / LIMIT) * 100));
  /* DECIMAL MB on both sides, because the limit is a decimal figure — main.js
   * refuses at 50,000,000 bytes. Dividing by 1024x1024 rendered it as "48 MB",
   * which is the same limit described with a number nobody has written down. */
  const sizeMB = (sizeBytes / 1_000_000).toFixed(1);
  const limitMB = Math.round(LIMIT / 1_000_000);
  const tone = pct >= 90 ? 'var(--danger)' : pct >= 70 ? 'var(--warning, #d97706)' : 'var(--success)';
  const note = pct >= 90
    ? (t('set.store_full') || 'Almost full. Past this, saving stops working — open Print Files to move previews out of the data file.')
    : pct >= 70
      ? (t('set.store_filling') || 'Filling up. Opening Print Files moves model previews out of the data file.')
      : (t('set.store_room') || 'Plenty of room.');
  el.innerHTML = `
    <div style="margin-bottom:6px;">
      <span style="font-weight:600;">${escapeHtml(t('set.store_file') || 'Storage file')}:</span> khayt-store.json
    </div>
    <div style="margin-bottom:6px;">
      <span style="font-weight:600;">${escapeHtml(t('set.store_size') || 'Size')}:</span>
      <span style="color:${tone};">${escapeHtml(t('set.store_of_limit', { used: sizeMB, limit: String(limitMB), pct: String(pct) }))}</span>
    </div>
    <div style="color:${tone}; font-size:12px;">${escapeHtml(note)}</div>
    <button id="btnRevealStoreFile" class="btn small" style="margin-top:10px;">${escapeHtml(t('set.reveal_store') || 'Reveal data file')}</button>`;
  el.querySelector('#btnRevealStoreFile')?.addEventListener('click', () => {
    window.hubAPI?.revealStoreFile?.();
  });
}

function saveLanApiSettingsFromForm({ restartServer = false } = {}) {
  const section = document.getElementById('lanApiSection');
  if (!section) return;
  const prev = settings.lanApi || {};
  settings.lanApi = {
    ...prev,
    enabled: section.querySelector('#lan_enabled')?.checked ?? prev.enabled,
    port: parseInt(section.querySelector('#lan_port')?.value, 10) || 3219,
    pin: secretInputSave(prev.pin, section.querySelector('#lan_pin')?.value),
    intakePin: secretInputSave(prev.intakePin, section.querySelector('#lan_intake_pin')?.value),
    webhookToken: secretInputSave(prev.webhookToken, section.querySelector('#lan_wh_token')?.value),
    sallaWebhookSecret: secretInputSave(prev.sallaWebhookSecret, section.querySelector('#lan_salla_secret')?.value),
    zidWebhookSecret: secretInputSave(prev.zidWebhookSecret, section.querySelector('#lan_zid_secret')?.value),
    tunnelEnabled: !!section.querySelector('#lan_tunnel_enabled')?.checked,
    bindLan: !!section.querySelector('#lan_bind_lan')?.checked,
    // Public model pricing. Kept whole rather than spread so an older store
    // without the key simply arrives as "off".
    intakeQuote: {
      ...(prev.intakeQuote || {}),
      enabled: !!section.querySelector('#lan_iq_enabled')?.checked,
      presetId: section.querySelector('#lan_iq_preset')?.value || '',
      filamentId: section.querySelector('#lan_iq_filament')?.value || '',
      spoolCost: Math.max(0, parseFloat(section.querySelector('#lan_iq_spool_cost')?.value) || 0),
      spoolWeight: Math.max(1, parseFloat(section.querySelector('#lan_iq_spool_weight')?.value) || 1000),
      marginPct: Math.max(0, parseFloat(section.querySelector('#lan_iq_margin')?.value) || 0),
      minPrice: Math.max(0, parseFloat(section.querySelector('#lan_iq_min')?.value) || 0),
      // Stored as a fraction; shown as a percentage.
      wastePct: Math.min(0.5, Math.max(0, (parseFloat(section.querySelector('#lan_iq_waste')?.value) || 0) / 100)),
      hourlyLimit: Math.max(1, Math.min(10000, parseInt(section.querySelector('#lan_iq_limit')?.value, 10) || 12)),
    },
  };
  if (!restartServer) return;
  saveAll();
  if (settings.lanApi.enabled) {
    startLanServer?.();
  } else {
    window.hubAPI?.stopLanServer?.();
    section.querySelector('#lanStatusRow').textContent = '⚫ Server stopped';
    section.querySelector('#lanQrWrap').style.display = 'none';
  }
}

function saveSettingsFromPanel() {
  const onlineCb = document.getElementById('online_enabled');
  if (onlineCb) settings.onlineEnabled = onlineCb.checked;
  saveLanApiSettingsFromForm({ restartServer: false });
  saveSettingsFromForm();
}

/**
 * What the Settings page holds, as the shared rule reads it.
 *
 * Only what is on screen: a control that is not on the page is not in the
 * object, and `lib/settings-edit.js` keeps the stored value for it. That is
 * what lets Bed Ready's page, which hides a third of these, save without
 * zeroing the third it hides.
 */
function readSettingsForm() {
  const opt = (id) => { const el = $(id); return el ? el.value : undefined; };
  const tick = (id) => { const el = $(id); return el ? el.checked : undefined; };
  const group = (pairs) => {
    const out = {};
    let any = false;
    for (const [key, id, kind] of pairs) {
      const v = kind === 'tick' ? tick(id) : opt(id);
      if (v !== undefined) { out[key] = v; any = true; }
    }
    return any ? out : undefined;
  };
  const form = {
    content: readContentFields(),
    vat: opt('#set_vat'), cr: opt('#set_cr'), phone: opt('#set_phone'), email: opt('#set_email'),
    lang: opt('#set_lang'), theme: opt('#set_theme'),
    designTheme: opt('#set_designTheme'), accent: opt('#set_accent'),
    invPrefix: opt('#set_invPrefix'), autoDeduct: tick('#set_autoDeduct'), lowStock: opt('#set_lowStock'),
    bankName: opt('#set_bankName'), accountHolder: opt('#set_accountHolder'), iban: opt('#set_iban'),
    acceptedPayments: $$('#acceptedPaymentsList input[data-pm]').filter(cb => cb.checked).map(cb => cb.dataset.pm),
    useHijri: tick('#set_useHijri'), useArabicNumerals: tick('#set_useArabicNumerals'),
    autoBackup: tick('#set_autoBackup'), coachTips: tick('#set_coachTips'),
    enableVat: tick('#set_enableVat'), vatRate: opt('#set_vatRate'),
    invAccent: opt('#set_invAccent'), invTemplate: opt('#set_invTemplate'),
    invoiceBilingual: opt('#set_invoiceBilingual'), invoiceSecondLang: opt('#set_invoiceSecondLang'),
    lowStockColor: opt('#set_lowStockColor'),
    quotePrefix: opt('#set_quotePrefix'), useIcloud: tick('#set_useIcloud'),
    monthlyGoal: opt('#set_monthlyGoal'), supplierPhone: opt('#set_supplierPhone'),
    currency: opt('#set_currency'), enableZatca: tick('#set_enableZatca'),
    taxMode: opt('#set_taxMode'), taxCountry: opt('#set_taxCountry'),
    minMarginPct: opt('#set_minMarginPct'),
    budgets: Object.fromEntries(EXP_CATEGORIES.map(c => [c, opt(`#set_budget_${c}`)])),
    workingHours: Object.fromEntries(['mon','tue','wed','thu','fri','sat','sun'].map(d => [d, opt(`#wh_${d}`)])),
    operatorLock: tick('#set_operatorLock'), loyaltyEnabled: tick('#set_loyaltyEnabled'),
    paymentInstructions: opt('#set_paymentInstructions'), betaUpdates: tick('#set_betaUpdates'),
    quoteValidityDays: opt('#set_quoteValidityDays'),
    leadTime: group([
      ['finishingDays', '#set_leadFinishingDays'], ['dispatchDays', '#set_leadDispatchDays'],
      ['safetyDays', '#set_leadSafetyDays'], ['publishToCloud', '#set_leadPublish', 'tick'],
    ]),
    quoteFollowUp: group([['enabled', '#set_quoteFollowUpEnabled', 'tick'], ['windowDays', '#set_quoteFollowUpWindow']]),
    paymentReminder: group([['enabled', '#set_payReminderEnabled', 'tick'], ['graceDays', '#set_payReminderGrace']]),
    minOrderAmount: opt('#set_minOrderAmount'), rushFeeEnabled: tick('#set_rushFeeEnabled'),
    rushFeePct: opt('#set_rushFeePct'), defaultPackagingCost: opt('#set_defaultPackagingCost'),
    wip: Object.fromEntries(['pending', 'printing', 'post', 'qc'].map(col => [col, opt(`#set_wip_${col}`)])),
    wipEnforceHardLimit: tick('#set_wipEnforceHardLimit'),
    qc: group([
      ['enabled', '#set_qcEnabled', 'tick'], ['requireInspector', '#set_qcRequireInspector', 'tick'],
      ['requirePhotoOnFail', '#set_qcRequirePhotoOnFail', 'tick'], ['warrantyDays', '#set_qcWarrantyDays'],
    ]),
  };
  // Absent, not undefined: the rule keeps what the form does not carry, and it
  // tells the two apart by whether the key is there.
  for (const k of Object.keys(form)) if (form[k] === undefined) delete form[k];
  return form;
}

function saveSettingsFromForm() {
  // The rule is lib/settings-edit.js, so the Mac app writes the same record by
  // the same clamps and defaults. It was a 240-line literal here, which is why
  // only this window could change a setting. The legacy webhook secrets are
  // moved under lanApi FIRST, because the rule preserves lanApi as it finds it.
  migrateLanApiSettings();
  settings = KhaytSettingsEdit.apply(settings, readSettingsForm(), {
    year: new Date().getFullYear(),
    themeLowStockColor: themeLowStockColor(),
    expenseCategories: EXP_CATEGORIES,
  });
  saveAll();
  syncUpdaterOptionsFromSettings();
  i18n.set(settings.lang);
  applyTheme(settings.theme);
  if (typeof applyDesignSettings === 'function') applyDesignSettings();
  // The sidebar now carries the shop's name, so a shop that has just entered or
  // changed it must see that immediately rather than after a theme switch.
  if (typeof KhaytThemes !== 'undefined' && typeof KhaytThemes.syncSidebarSubtitle === 'function') {
    KhaytThemes.syncSidebarSubtitle(document.documentElement.dataset.design);
  }
  applyMode();
  renderInventory();
  refreshCurrencyLabels();
  if (typeof renderBuild === 'function') renderBuild();
  if (typeof applyCoachTips === 'function') applyCoachTips(document);
  toast(t('set.saved'), 'success');
}

/* ============================================================
   Backup restore UI (Feature 6)
   ============================================================ */
async function openRestoreBackupModal() {
  if (!window.hubAPI?.listBackups) { toast(t('set.restore_error'), 'error'); return; }
  // Distinguish "the listing failed" from "there genuinely are none". This modal is
  // opened precisely when someone is trying to recover, and telling them no backups
  // exist when the read merely failed can convince them their data is unrecoverable.
  let backups = [];
  let listFailed = false;
  try {
    backups = await window.hubAPI.listBackups();
    if (!Array.isArray(backups)) { backups = []; listFailed = true; }
  } catch (e) {
    console.error('listBackups failed:', e);
    listFailed = true;
  }
  if (listFailed) {
    toast('⚠ ' + (t('set.backups_unreadable') ||
      'Could not read the backups folder — your backups may still be there. Try opening the folder directly.'), 'error', 9000);
    return;
  }
  if (backups.length === 0) {
    toast(t('set.restore_error') + ': no backups found', 'error');
    return;
  }
  const listHtml = backups.map((b, i) => `
    <label style="display:flex; align-items:center; gap:10px; padding:6px 8px; border-radius:6px; cursor:pointer; border:1px solid var(--border); margin-bottom:6px; ${i === 0 ? 'background:rgba(91,156,240,0.07);' : ''}">
      <input type="radio" name="backupChoice" value="${escapeHtml(b.filename)}" ${i === 0 ? 'checked' : ''} style="width:auto; margin:0;">
      <span style="flex:1; font-size:13px; font-weight:${i === 0 ? '600' : '400'};">${escapeHtml(b.name)}</span>
      <span style="font-size:11px; color:var(--text-muted);">${new Date(b.mtime).toLocaleDateString(localeTag())}</span>
    </label>`).join('');
  openFormModal({
    title: t('set.restore_title'),
    saveLabel: t('common.confirm'),
    sizeLg: false,
    bodyHtml: `
      <p style="font-size:13px; color:var(--text-muted); margin:0 0 14px;">${escapeHtml(t('set.restore_hint'))}</p>
      <div id="backupList">${listHtml}</div>`,
    async onSave(modal) {
      const chosen = modal.querySelector('input[name="backupChoice"]:checked');
      if (!chosen) return false;
      const ok = await confirmModal(t('set.restore_confirm'), { danger: true });
      if (!ok) return false;
      try {
        const json = await window.hubAPI.restoreBackup(chosen.value);
        if (!json) { toast(t('set.restore_error'), 'error'); return false; }
        const data = safeJsonParse(json);
        // Local is about to go backwards; the cloud backend has to stop claiming
        // the server holds what this device last pushed.
        await forgetCloudServerView();
      // Refuse a snapshot that failed validation — replaceStoreFromSnapshot leaves the
      // existing data untouched when it returns false, so do NOT save or report success.
        if (!replaceStoreFromSnapshot(data)) { toast(t('set.restore_error') || 'Restore failed — the backup could not be read', 'error'); return false; }
        saveAll();
        initialRender();
        loadSettingsIntoForm();
        applyTheme(settings.theme);
        i18n.set(settings.lang);
        refreshCurrencyLabels();
        toast(t('set.restore_success'), 'success');
        return true;
      } catch (e) {
        console.error('restore backup failed', e);
        toast(t('set.restore_error'), 'error');
        return false;
      }
    }
  });
}

/** Named restore points: create labeled snapshots + one-click restore/delete.
 *  Disaster recovery beyond the dated auto-backups (separate, non-pruned set). */
async function openRestorePointsModal() {
  if (!window.hubAPI?.listRestorePoints) { toast(t('rp.unavailable') || 'Restore points unavailable', 'error'); return; }
  const fmtWhen = (ms) => { try { return new Date(ms).toLocaleString(i18n.current === 'ar' ? 'ar-SA-u-nu-latn' : 'en-US', { dateStyle: 'medium', timeStyle: 'short' }); } catch (e) { return ''; } };
  const render = async (modal) => {
    let list = [];
    try { list = await window.hubAPI.listRestorePoints() || []; } catch (e) { /* ignore */ }
    const rows = list.length ? list.map((rp) => `
      <div style="display:flex;align-items:center;gap:8px;padding:7px 0;border-bottom:1px solid var(--border-soft);">
        <div style="flex:1;"><div style="font-size:13px;font-weight:600;">${escapeHtml(rp.label)}</div><div style="font-size:11px;color:var(--text-muted);">${escapeHtml(fmtWhen(rp.mtime))}</div></div>
        <button class="btn small primary rpRestore" data-f="${escapeHtml(rp.filename)}">${escapeHtml(t('rp.restore') || 'Restore')}</button>
        <button class="btn small ghost rpDelete" data-f="${escapeHtml(rp.filename)}" style="color:var(--danger);" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">✕</button>
      </div>`).join('') : `<div style="text-align:center;color:var(--text-muted);padding:18px 0;">${escapeHtml(t('rp.empty') || 'No restore points yet.')}</div>`;
    modal.querySelector('#rpBody').innerHTML = `
      <p style="font-size:12.5px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(t('rp.hint') || 'Save a labeled snapshot of all your data you can roll back to anytime — e.g. before a big import or month-end.')}</p>
      <div style="display:flex;gap:8px;margin-bottom:12px;">
        <input id="rpLabel" type="text" maxlength="60" placeholder="${escapeHtml(t('rp.label_ph') || 'Label (e.g. Before June import)')}" style="flex:1;">
        <button id="rpCreate" class="btn small primary">+ ${escapeHtml(t('rp.create') || 'Create')}</button>
      </div>
      ${rows}`;
    modal.querySelector('#rpCreate')?.addEventListener('click', async () => {
      const label = modal.querySelector('#rpLabel').value.trim();
      const r = await window.hubAPI.createRestorePoint({ json: JSON.stringify(buildExportPayload({ redactSecrets: false })), label });
      if (r?.ok) { toast(t('rp.created') || 'Restore point saved', 'success'); render(modal); }
      else toast((r && r.error) || 'Failed', 'error');
    });
    modal.querySelectorAll('.rpRestore').forEach((b) => b.addEventListener('click', async () => {
      if (!(await confirmModal(t('rp.restore_q') || 'Replace all current data with this restore point? This cannot be undone.', { danger: true }))) return;
      const json = await window.hubAPI.readRestorePoint(b.dataset.f);
      if (!json) { toast(t('set.restore_error') || 'Restore failed', 'error'); return; }
      try {
        // Same rollback as a backup restore, from a different folder.
        await forgetCloudServerView();
      // Refuse a snapshot that failed validation — replaceStoreFromSnapshot leaves the
      // existing data untouched when it returns false, so do NOT save or report success.
        if (!replaceStoreFromSnapshot(safeJsonParse(json))) { toast(t('set.restore_error') || 'Restore failed', 'error'); return; }
        saveAll(); initialRender(); loadSettingsIntoForm(); applyTheme(settings.theme); i18n.set(settings.lang); refreshCurrencyLabels();
        toast(t('set.restore_success') || 'Restored', 'success');
        modal.querySelector('.modal-close')?.click();
      } catch (e) { console.error('restore point failed', e); toast(t('set.restore_error') || 'Restore failed', 'error'); }
    }));
    modal.querySelectorAll('.rpDelete').forEach((b) => b.addEventListener('click', async () => {
      await window.hubAPI.deleteRestorePoint(b.dataset.f); render(modal);
    }));
  };
  openFormModal({
    title: '🛟 ' + (t('rp.title') || 'Restore points'),
    noSave: true,
    bodyHtml: `<div id="rpBody"></div>`,
    onMount(modal) { render(modal); },
  });
}

/** beta.19 #7 — Cloud snapshot history. Lists the server-side versioned snapshots
 *  (kept automatically on each sync) and restores any one across devices. The
 *  ciphertext is decrypted in the main process with the session DEK; restoring
 *  replaces local data, then pushes it up as a new head revision. */
async function applyCloudSnapshotRestore(store) {
  const keepCloud = Object.assign({}, settings.cloud); // preserve this device's token/login/rev
      // Refuse a snapshot that failed validation — replaceStoreFromSnapshot leaves the
      // existing data untouched when it returns false, so do NOT save or report success.
  if (!replaceStoreFromSnapshot(store)) { toast(t('set.restore_error') || 'Restore failed', 'error'); return; }
  settings.cloud = Object.assign({}, settings.cloud, keepCloud);
  saveAll();
  initialRender();
  loadSettingsIntoForm();
  applyTheme(settings.theme);
  i18n.set(settings.lang);
  if (typeof refreshCurrencyLabels === 'function') refreshCurrencyLabels();
  // Local now holds the restored version; push it as a new revision so every
  // device converges on it (the backend keeps its head rev, so no false conflict).
  if (window.KhaytCloudSync) { KhaytCloudSync.configure(cloudSyncDeps()); KhaytCloudSync.syncNow(); }
  renderCloudSettings();
}

async function openCloudSnapshotsModal() {
  if (!window.hubAPI?.cloudSnapshotsList) { toast(t('cloud.snapshots_unavailable') || 'Snapshot history unavailable', 'error'); return; }
  const fmtWhen = (ms) => { try { return new Date(ms).toLocaleString(i18n.current === 'ar' ? 'ar-SA-u-nu-latn' : 'en-US', { dateStyle: 'medium', timeStyle: 'short' }); } catch (e) { return ''; } };
  const fmtBytes = (n) => (n >= 1024 * 1024 ? (n / (1024 * 1024)).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB');
  const render = async (modal) => {
    const body = modal.querySelector('#csBody');
    body.innerHTML = `<div style="text-align:center;color:var(--text-muted);padding:18px 0;">${escapeHtml(t('common.loading') || 'Loading…')}</div>`;
    const r = await window.hubAPI.cloudSnapshotsList();
    if (!r?.ok) {
      const msg = r?.error === 'locked' ? (t('cloud.locked') || 'Unlock first (enter passphrase)') : (r?.error || 'Failed to load');
      body.innerHTML = `<div style="text-align:center;color:var(--danger);padding:18px 0;">${escapeHtml(msg)}</div>`;
      return;
    }
    const list = r.snapshots || [];
    const rows = list.length ? list.map((s) => `
      <div style="display:flex;align-items:center;gap:8px;padding:7px 0;border-bottom:1px solid var(--border-soft);">
        <div style="flex:1;">
          <div style="font-size:13px;font-weight:600;">${escapeHtml(t('cloud.snap_rev') || 'Version')} ${Number(s.rev)}</div>
          <div style="font-size:11px;color:var(--text-muted);">${escapeHtml(fmtWhen(s.createdAt))} · ${escapeHtml(fmtBytes(Number(s.bytes) || 0))}</div>
        </div>
        <button class="btn small primary csRestore" data-id="${escapeHtml(String(s.id))}" data-rev="${Number(s.rev)}">${escapeHtml(t('cloud.restore_this') || 'Restore')}</button>
      </div>`).join('') : `<div style="text-align:center;color:var(--text-muted);padding:18px 0;">${escapeHtml(t('cloud.snapshots_empty') || 'No cloud snapshots yet — Sync now first.')}</div>`;
    body.innerHTML = `
      <p style="font-size:12.5px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(t('cloud.snapshots_hint') || 'Your shop is versioned in the cloud on every sync. Restore any version here — it replaces local data on this device and syncs to the others.')}</p>
      ${rows}`;
    body.querySelectorAll('.csRestore').forEach((b) => b.addEventListener('click', async () => {
      const rev = b.dataset.rev;
      if (!(await confirmModal((t('cloud.snap_restore_q') || 'Replace all data on this device with version {rev} from the cloud, and sync it everywhere? This cannot be undone.').replace('{rev}', rev), { danger: true }))) return;
      b.disabled = true;
      const g = await window.hubAPI.cloudSnapshotGet({ id: b.dataset.id });
      if (!g?.ok || !g.store) {
        toast((g && g.error) || (t('cloud.restore_error') || 'Could not restore from cloud'), 'error');
        b.disabled = false; return;
      }
      try {
        await applyCloudSnapshotRestore(g.store);
        toast((t('cloud.restored') || 'Restored from cloud') + ' (' + (t('cloud.snap_rev') || 'Version').toLowerCase() + ' ' + rev + ')', 'success');
        modal.querySelector('.modal-close')?.click();
      } catch (e) { console.error('cloud snapshot restore:', e); toast(t('cloud.restore_error') || 'Could not restore from cloud', 'error'); b.disabled = false; }
    }));
  };
  openFormModal({
    title: '🕑 ' + (t('cloud.snapshots') || 'Cloud snapshot history'),
    noSave: true,
    bodyHtml: `<div id="csBody"></div>`,
    onMount(modal) { render(modal); },
  });
}

/* ============================================================
   Post-processing checklist (settings management)
   ============================================================ */
/* New Feature 7: Holiday/closure dates list */
function renderHolidayList() {
  const el = $('#holidayList');
  if (!el) return;
  const holidays = settings.holidays || [];
  if (holidays.length === 0) {
    el.innerHTML = `<span style="font-size:12px; color:var(--text-muted);">${escapeHtml(t('set.holidays'))}: none</span>`;
    return;
  }
  el.innerHTML = [...holidays].sort().map(d => `
    <span class="holiday-chip" style="display:inline-flex; align-items:center; gap:4px; background:var(--surface-2); border:1px solid var(--border-soft); border-radius:16px; padding:2px 10px; font-size:12px;">
      ${escapeHtml(d)}
      <button type="button" data-act="rm-holiday" data-date="${escapeHtml(d)}" aria-label="${escapeHtml(t('common.delete'))}" style="background:none; border:none; color:var(--danger); cursor:pointer; font-size:13px; padding:0; line-height:1;" title="${escapeHtml(t('common.delete'))}">×</button>
    </span>`).join('');
}

function renderPostChecklistSettings() {
  const el = $('#postChecklistItems');
  if (!el) return;
  const list = settings.postChecklist || [];
  if (list.length === 0) {
    el.innerHTML = `<div style="color:var(--text-muted); font-size:12.5px; padding:6px 0;" data-i18n="post.empty">${escapeHtml(t('post.empty'))}</div>`;
    return;
  }
  el.innerHTML = list.map((ch, i) => `
    <div class="post-check-setting-row">
      <span style="flex:1; font-size:13px;">${escapeHtml(ch.label)}</span>
      <button class="btn danger small" data-act="del-post-check" data-idx="${i}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
    </div>`).join('');
}

function addPostCheckItem() {
  const inp = $('#postCheckInput');
  if (!inp) return;
  const label = inp.value.trim();
  if (!label) return;
  if (!settings.postChecklist) settings.postChecklist = [];
  settings.postChecklist.push({ id: uid('PCH'), label });
  inp.value = '';
  saveAll();
  renderPostChecklistSettings();
}

function deletePostCheckItem(idx) {
  if (!settings.postChecklist) return;
  settings.postChecklist.splice(idx, 1);
  saveAll();
  renderPostChecklistSettings();
  renderKanban(); // refresh cards
}

/* ============================================================
   Custom order metadata fields — settings management
   ============================================================ */
function renderCustomFieldsSettings() {
  const el = $('#customFieldsList');
  if (!el) return;
  const fields = settings.customFields || [];
  if (fields.length === 0) {
    el.innerHTML = `<div style="color:var(--text-muted); font-size:12.5px; padding:6px 0;">${escapeHtml(t('set.custom_fields_empty'))}</div>`;
    return;
  }
  el.innerHTML = fields.map((f, i) => `
    <div class="post-check-setting-row">
      <span style="flex:1; font-size:13px;">${escapeHtml(f.label)}</span>
      <span style="font-size:11px; color:var(--text-muted); margin-inline-end:8px;">${escapeHtml(f.type || 'text')}</span>
      <button class="btn danger small" data-act="del-custom-field" data-idx="${i}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
    </div>`).join('');
}

function addCustomField() {
  const inp = $('#customFieldInput');
  if (!inp) return;
  const label = inp.value.trim();
  if (!label) return;
  if (!settings.customFields) settings.customFields = [];
  settings.customFields.push({ id: uid('CF'), label, type: 'text' });
  inp.value = '';
  saveAll();
  renderCustomFieldsSettings();
  toast(t('set.custom_field_added'), 'success');
}

function deleteCustomField(idx) {
  if (!settings.customFields) return;
  settings.customFields.splice(idx, 1);
  saveAll();
  renderCustomFieldsSettings();
}

/** Load explorable demo data (clients, products, spools, machines, orders).
 *  Each record is flagged sample:true and uses a stable DEMO-* id, so loading
 *  is idempotent and it can be removed cleanly later. */
async function loadSampleData() {
  if (typeof KhaytSampleData === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  const ok = await confirmModal(t('set.sample_load_q') || 'Add demo clients, products, spools and orders to explore? You can remove them anytime.');
  if (!ok) return;
  const data = KhaytSampleData.buildSampleData({ today: localDateStr() });
  const targets = { machines, clients, products, inventory, printLog };
  let added = 0;
  for (const key of KhaytSampleData.SAMPLE_COLLECTIONS) {
    const arr = targets[key]; if (!Array.isArray(arr)) continue;
    for (const rec of data[key]) {
      if (!arr.some((x) => x && x.id === rec.id)) { arr.push(rec); added++; }
    }
  }
  saveAll();
  initialRender();
  loadSettingsIntoForm();
  toast((t('set.sample_loaded', { n: added }) || `Added ${added} demo records`), 'success');
}

/** Remove every record previously added as sample/demo data. */
async function clearSampleData() {
  const ok = await confirmModal(t('set.sample_clear_q') || 'Remove all demo data? Your real records are kept.', { danger: true });
  if (!ok) return;
  const strip = (arr) => (Array.isArray(arr) ? arr.filter((x) => !(x && x.sample)) : arr);
  machines = strip(machines); clients = strip(clients); products = strip(products);
  inventory = strip(inventory); printLog = strip(printLog);
  saveAll();
  initialRender();
  loadSettingsIntoForm();
  toast(t('set.sample_cleared') || 'Demo data removed', 'success');
}

function exportData() {
  if (!confirm(t('set.export_secrets_warning') || 'Export will redact API keys and secrets. Continue?')) return;
  downloadBlob(
    new Blob([JSON.stringify(buildExportPayload({ redactSecrets: true }), null, 2)], { type: 'application/json' }),
    `khayt-${localDateStr()}.json`
  );
  toast(t('set.exported'), 'success');
}


/**
 * Prune archived orders: export them to a JSON file, then remove them from the
 * live store. Export-first is mandatory (the download is the user's only copy
 * afterwards) and the removal is gated behind a danger confirm. Deletions
 * propagate to cloud automatically — the next save tombstones the missing ids.
 */
async function pruneArchivedOrders() {
  // Logic is intentionally inline (not via a browser global) — the pure helpers
  // in lib/order-archive.js exist for Node unit coverage; the renderer keeps the
  // filter here so no extra <script> tag is needed. See test/order-archive.test.js.
  const archived = (printLog || []).filter((o) => o && typeof o === 'object' && o.archived);
  if (archived.length === 0) {
    toast(t('prune.none') || 'No archived orders to prune.', 'info');
    return;
  }
  let version = null;
  try { version = window.hubAPI?.appVersion ? await window.hubAPI.appVersion() : null; } catch { /* ignore */ }
  const stamp = new Date().toISOString();
  const payload = { type: 'khayt-archived-orders', version, exportedAt: stamp, count: archived.length, orders: archived };
  // Export first — always, before anything is removed.
  downloadBlob(
    new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' }),
    `khayt-archived-orders-${stamp.split('T')[0]}.json`,
  );
  const ok = await confirmModal(
    (t('prune.confirm') || 'Remove {n} archived order(s) from the app? They were just exported to a file — keep it safe. This cannot be undone.')
      .replace('{n}', archived.length),
    { danger: true },
  );
  if (!ok) return;
  const removed = new Set(archived.map((o) => o.id));
  printLog = printLog.filter((o) => !removed.has(o.id));
  saveAll();
  if (typeof renderLogs === 'function') renderLogs();
  if (typeof renderDashboard === 'function') renderDashboard();
  if (typeof renderStorageUsage === 'function') renderStorageUsage();
  toast((t('prune.done') || 'Removed {n} archived order(s).').replace('{n}', archived.length), 'success');
}


async function importData(file) {
  const ok = await confirmModal(
    t('set.import_confirm') || 'Replace all local data with this backup? This cannot be undone.',
    { danger: true },
  );
  if (!ok) return;
  const reader = new FileReader();
  reader.onload = async (ev) => {
    try {
      const data = safeJsonParse(ev.target.result);
      // An imported file is someone else's store, or an older copy of this one —
      // either way the backend's claim about the server no longer describes it.
      await forgetCloudServerView();
      // Refuse a snapshot that failed validation — replaceStoreFromSnapshot leaves the
      // existing data untouched when it returns false, so do NOT save or report success.
      if (!replaceStoreFromSnapshot(data)) { toast(t('set.import_error') || t('set.restore_error') || 'Import failed — that file is not a Khayt backup', 'error'); return; }
      saveAll();
      initialRender();
      loadSettingsIntoForm();
      applyTheme(settings.theme);
      i18n.set(settings.lang);
      toast(t('set.imported'), 'success');
    } catch (e) {
      console.error(e);
      toast(t('set.import_error'), 'error');
    }
  };
  reader.readAsText(file);
}

async function clearAppDataForReset() {
  printLog = []; templates = []; products = []; clients = []; printers = [];
  expenses = []; machines = []; waTemplates = defaultWaTemplates(); wasteLog = [];
  machMaintLog = []; consumables = []; suppliers = []; purchaseOrders = []; testPrints = [];
  locations = []; operators = []; waitingList = []; waitingListHistory = [];
  timeEntries = []; shiftLogs = []; giftCards = []; slicerProfiles = []; envLogs = [];
  inventory = [];
  settings = defaultSettings();
  settings.firstRun = true;
  settings.firstRunDone = false;
  saveAll();
}

async function resetAllData() {
  const ok = await verifyDestructiveGate({
    phrase: 'RESET',
    title: t('set.reset'),
    message: t('set.reset_q'),
    requireSecurity: securityIsEnabled(),
  });
  if (!ok) return;
  await clearAppDataForReset();
  applyTheme(settings.theme || 'light');
  i18n.set(settings.lang || 'en');
  initialRender();
  loadSettingsIntoForm();
  renderSecuritySettings();
  initWizard();
  toast(t('log.cleared'), 'success');
}

async function fullWipeData() {
  const phrase = (settings.businessName || shopName() || 'WIPE').trim() || 'WIPE';
  const ok = await verifyDestructiveGate({
    phrase,
    title: t('set.full_wipe'),
    message: t('set.full_wipe_q'),
    requireSecurity: securityIsEnabled(),
  });
  if (!ok) return;
  if (!window.hubAPI?.requestFullWipe) {
    toast(t('set.full_wipe_unavailable'), 'error');
    return;
  }
  const wipeRes = await window.hubAPI.requestFullWipe();
  if (wipeRes?.canceled) return;
}

function renderSecuritySettings() {
  const el = $('#securitySettingsSection');
  if (!el) return;
  const enabled = securityIsEnabled();
  el.innerHTML = `
    <div style="padding:14px 16px;background:var(--bg-soft);border:1px solid var(--border-soft);border-radius:var(--radius);">
      <div style="font-size:13px;font-weight:600;margin-bottom:8px;" data-i18n="sec.settings_title">App security</div>
      <p style="font-size:12px;color:var(--text-muted);margin:0 0 10px;">
        ${enabled
          ? escapeHtml(t('sec.settings_enabled'))
          : escapeHtml(t('sec.settings_disabled'))}
      </p>
      ${enabled ? `
        <div class="btn-row" style="gap:8px;flex-wrap:wrap;">
          <button type="button" class="btn small" id="btnChangeAdminPin">${escapeHtml(t('sec.change_pin'))}</button>
          <button type="button" class="btn small" id="btnRegenRecovery">${escapeHtml(t('sec.regen_recovery'))}</button>
          <button type="button" class="btn small ghost" id="btnDisableSecurity">${escapeHtml(t('sec.disable'))}</button>
        </div>` : `
        <button type="button" class="btn small primary" id="btnEnableSecurity">${escapeHtml(t('sec.enable'))}</button>`}
    </div>`;
  i18n.applyToDom(el);

  el.querySelector('#btnEnableSecurity')?.addEventListener('click', () => openEnableSecurityModal());
  el.querySelector('#btnChangeAdminPin')?.addEventListener('click', () => openChangePinModal());
  el.querySelector('#btnRegenRecovery')?.addEventListener('click', () => openRegenRecoveryModal());
  el.querySelector('#btnDisableSecurity')?.addEventListener('click', () => disableSecurity());
}

function openEnableSecurityModal() {
  openFormModal({
    title: t('sec.enable'),
    sizeLg: false,
    bodyHtml: `
      <label>${escapeHtml(t('sec.pin_label'))}</label>
      <input type="password" id="enableSecPin" inputmode="numeric" maxlength="8" class="form-control">
      <label style="margin-top:10px;">${escapeHtml(t('sec.pin_confirm'))}</label>
      <input type="password" id="enableSecPin2" inputmode="numeric" maxlength="8" class="form-control">
      <p id="enableSecErr" style="color:var(--danger);font-size:12px;min-height:18px;margin-top:8px;"></p>`,
    async onSave(modal) {
      const pin = modal.querySelector('#enableSecPin').value.trim();
      const pin2 = modal.querySelector('#enableSecPin2').value.trim();
      const err = modal.querySelector('#enableSecErr');
      if (!isValidPin(pin)) { if (err) err.textContent = t('sec.pin_invalid_format'); return false; }
      if (isWeakPin(pin)) { if (err) err.textContent = t('sec.pin_weak'); return false; }
      if (pin !== pin2) { if (err) err.textContent = t('sec.pin_mismatch'); return false; }
      const code = generateRecoveryCode();
      await setupAdminSecurity({ pin, recoveryCodePlain: code });
      saveAll();
      renderSecuritySettings();
      renderOperatorsList();
      renderOperatorLockSettings();
      applyOperatorPermissions();
      toast(t('sec.enabled_toast'), 'success');
      // Deferred past the close for the same reason as the organisation recovery
      // key: openFormModal's close() empties the shared #modalMount, and
      // appendStackedModal appends INTO that mount — so opening it here and then
      // returning true wiped it before anyone could read it. Shipped that way;
      // the operator-lock recovery code is the only way back in if the PIN is
      // forgotten. Proven by running: present inside onSave, gone 300 ms later.
      setTimeout(() => showRecoveryCodeModal(code, t('sec.recovery_title')), 0);
      return true;
    },
  });
}

function showRecoveryCodeModal(code, title) {
  const overlay = appendStackedModal(`
      <div class="modal modal-form" role="dialog" aria-modal="true" style="max-width:480px;">
        <div class="modal-header">
          <h3>${escapeHtml(title || t('sec.recovery_title'))}</h3>
          <button class="btn ghost small" data-act="close" aria-label="Close" title="Close">×</button>
        </div>
        <div class="modal-body">
        <p style="font-size:13px;color:var(--text-muted);margin:0 0 8px;">${escapeHtml(t('sec.recovery_subtitle'))}</p>
        <div style="font-family:ui-monospace,monospace;font-size:17px;text-align:center;padding:12px;background:var(--bg-soft);border-radius:8px;margin:12px 0;" id="recoveryCodeDisplay">${escapeHtml(formatRecoveryCode(code))}</div>
        <div class="btn-row" style="justify-content:center;gap:8px;">
          <button class="btn" id="modalRecoveryCopy">${escapeHtml(t('sec.copy'))}</button>
          <button class="btn" id="modalRecoveryDownload">${escapeHtml(t('sec.download'))}</button>
        </div>
        </div>
        <div class="modal-footer">
          <button class="btn primary" data-act="close">${escapeHtml(t('common.close'))}</button>
        </div>
      </div>`);
  if (!overlay) return;
  overlay.querySelector('#modalRecoveryCopy')?.addEventListener('click', async () => {
    const res = await copyRecoveryCode(code);
    toast(res.ok ? t('sec.copied') : t('sec.copy_failed'), res.ok ? 'success' : 'error');
  });
  overlay.querySelector('#modalRecoveryDownload')?.addEventListener('click', async () => {
    const res = await downloadRecoveryCode(code);
    toast(res.ok ? t('sec.downloaded') : t('sec.download_failed'), res.ok ? 'success' : 'error');
  });
  const closeRecovery = () => overlay.remove();
  overlay.querySelectorAll('[data-act="close"]').forEach(b => b.addEventListener('click', closeRecovery));
  overlay.addEventListener('click', (e) => { if (e.target === overlay) closeRecovery(); });
}

async function openChangePinModal() {
  const verified = await pinOrRecoveryModal({ title: t('sec.change_pin'), message: t('sec.verify_body') });
  if (!verified) return;
  openFormModal({
    title: t('sec.change_pin'),
    sizeLg: false,
    bodyHtml: `
      <label>${escapeHtml(t('sec.pin_label'))}</label>
      <input type="password" id="newSecPin" inputmode="numeric" maxlength="8" class="form-control">
      <label style="margin-top:10px;">${escapeHtml(t('sec.pin_confirm'))}</label>
      <input type="password" id="newSecPin2" inputmode="numeric" maxlength="8" class="form-control">`,
    async onSave(modal) {
      const pin = modal.querySelector('#newSecPin').value.trim();
      const pin2 = modal.querySelector('#newSecPin2').value.trim();
      if (!isValidPin(pin) || isWeakPin(pin) || pin !== pin2) {
        toast(t('sec.pin_invalid_format'), 'error');
        return false;
      }
      const admin = getAdminOperator();
      if (!admin) return false;
      admin.pinHash = await hashSecret(pin);
      saveAll();
      toast(t('sec.pin_changed'), 'success');
      return true;
    },
  });
}

async function openRegenRecoveryModal() {
  const verified = await pinOrRecoveryModal({ title: t('sec.regen_recovery'), message: t('sec.verify_body') });
  if (!verified) return;
  const code = generateRecoveryCode();
  settings.recoveryCodeHash = await hashSecret(normalizeRecoveryCode(code));
  settings.recoveryCodeCreatedAt = localDateStr();
  saveAll();
  showRecoveryCodeModal(code, t('sec.regen_recovery'));
}

async function disableSecurity() {
  const verified = await pinOrRecoveryModal({ title: t('sec.disable'), message: t('sec.disable_q') });
  if (!verified) return;
  settings.securityEnabled = false;
  settings.recoveryCodeHash = '';
  settings.operatorLockEnabled = false;
  settings.activeOperatorId = null;
  operators = [];
  saveAll();
  renderSecuritySettings();
  renderOperatorsList();
  renderOperatorLockSettings();
  applyOperatorPermissions();
  toast(t('sec.disabled_toast'), 'success');
}

function renderTelegramSettings() {
  const el = document.getElementById('telegramSettingsSection');
  if (!el) return;
  const tg = settings.telegram || {};
  el.innerHTML = `
    <h4 style="margin-bottom:10px;">Telegram Notifications</h4>
    <label>Bot Token</label>
    <input type="password" id="tgBotToken" value="${escapeHtml(tg.botToken || '')}" placeholder="123456:ABC-...">
    <label style="margin-top:8px;">Chat ID</label>
    <input type="text" id="tgChatId" value="${escapeHtml(tg.chatId || '')}" placeholder="-100123456789 or @yourchannel">
    <div style="font-size:11px;color:var(--text-muted);margin-top:3px;">${escapeHtml(t('tg.chat_id_hint') || 'A numeric id for a group, or the @username of a public channel.')}</div>
    <div style="margin-top:10px;display:flex;gap:8px;align-items:center;">
      <button class="btn small" id="btnTgTest">Test</button>
      <span style="font-size:12px;color:var(--text-muted);">Sends a test message to verify the bot works</span>
    </div>
    <div style="margin-top:12px;">
      <label style="display:flex;align-items:center;gap:8px;">
        <input type="checkbox" id="tgNotifyComplete" style="width:auto;" ${tg.notifyOnComplete ? 'checked' : ''}> Notify on order completed
      </label>
      <label style="display:flex;align-items:center;gap:8px;margin-top:6px;">
        <input type="checkbox" id="tgNotifyHold" style="width:auto;" ${tg.notifyOnHold ? 'checked' : ''}> Notify on order on_hold
      </label>
      <label style="display:flex;align-items:center;gap:8px;margin-top:6px;">
        <input type="checkbox" id="tgNotifyLowStock" style="width:auto;" ${tg.notifyOnLowStock ? 'checked' : ''}> Notify on low stock
      </label>
      <label style="display:flex;align-items:center;gap:8px;margin-top:6px;">
        <input type="checkbox" id="tgNotifyPrinterError" style="width:auto;" ${(tg.notifyPrinterError ?? true) ? 'checked' : ''}> ${escapeHtml(t('fleet.notify_error'))}
      </label>
      <label style="display:flex;align-items:center;gap:8px;margin-top:6px;">
        <input type="checkbox" id="tgNotifyPrinterOffline" style="width:auto;" ${(tg.notifyPrinterOffline ?? true) ? 'checked' : ''}> ${escapeHtml(t('fleet.notify_offline'))}
      </label>
      <label style="display:flex;align-items:center;gap:8px;margin-top:6px;">
        <input type="checkbox" id="tgNotifyPrinterStall" style="width:auto;" ${tg.notifyPrinterStall ? 'checked' : ''}> ${escapeHtml(t('fleet.notify_stall'))}
      </label>
    </div>
    <button class="btn primary small" id="btnSaveTgSettings" style="margin-top:12px;">Save Telegram Settings</button>`;

  el.querySelector('#btnTgTest')?.addEventListener('click', () => {
    const botToken = el.querySelector('#tgBotToken').value.trim();
    const chatId   = el.querySelector('#tgChatId').value.trim();
    if (!botToken || !chatId) { toast(t('tg.need_credentials'), 'error'); return; }
    // A chat id Telegram cannot deliver to, said now rather than as a silent
    // non-delivery weeks later. `@khaytshop` used to be mangled to `@`.
    const TG = (typeof globalThis !== 'undefined' && globalThis.KhaytTelegramMessage) || null;
    if (TG && !TG.isChatId(chatId)) { toast(t('tg.bad_chat_id'), 'error'); return; }
    if (window.hubAPI?.sendTelegram) {
      window.hubAPI.sendTelegram({ botToken, chatId, message: '✅ Khayt test notification' })
        .then(() => toast(t('tg.test_sent'), 'success'))
        .catch(e => toast(t('tg.error') + ': ' + e.message, 'error'));
    } else {
      toast(t('common.telegram_unavailable'), 'info');
    }
  });

  el.querySelector('#btnSaveTgSettings')?.addEventListener('click', () => {
    const botToken         = secretInputSave((settings.telegram || {}).botToken, el.querySelector('#tgBotToken').value);
    const chatId           = el.querySelector('#tgChatId').value.trim();
    const notifyOnComplete = el.querySelector('#tgNotifyComplete').checked;
    const notifyOnHold     = el.querySelector('#tgNotifyHold').checked;
    const notifyOnLowStock = el.querySelector('#tgNotifyLowStock').checked;
    const notifyPrinterError   = el.querySelector('#tgNotifyPrinterError').checked;
    const notifyPrinterOffline = el.querySelector('#tgNotifyPrinterOffline').checked;
    const notifyPrinterStall   = el.querySelector('#tgNotifyPrinterStall').checked;
    settings.telegram = {
      botToken, chatId, notifyOnComplete, notifyOnHold, notifyOnLowStock,
      notifyPrinterError, notifyPrinterOffline, notifyPrinterStall,
    };
    saveAll();
    toast(t('tg.settings_saved'), 'success');
  });
}
  const api = {
    // wire-events.js is a separate IIFE and can only reach what is exported
    // here. Left out, the location buttons render and do nothing.
    //
    // openStorefrontModal is here because the Catalogue tab now offers Publish
    // directly, and that button lives in another file. Publishing was reachable
    // only from Settings → Advanced → Automation → Khayt Cloud, four levels in
    // from the screen the shop is actually looking at.
    openStorefrontModal,
    renderPrintLibLocation,
    pickPrintLibFolder,
    clearPrintLibFolder,
    savePrintLibS3,
    testPrintLibS3,
    scanPrintLibMigrate,
    runPrintLibMigrate,
    onPrintLibProviderChange,
    savePrintLibGDrive,
    connectPrintLibGDrive,
    disconnectPrintLibGDrive,
    savePrintLibTier,
    runPrintLibTier,
    restorePrintLibTier,
    buildDigestEmailHtml,
    renderLocationsSettings,
    renderEmailNotificationSettings,
    renderSmsNotificationSettings,
    renderAccountingSyncSettings,
    renderIntegrationsSettings,
    renderDigestSettings,
    renderAiSettings,
    renderSlicerSettings,
    renderCloudSettings,
    renderOperatorLockSettings,
    renderLoyaltyTiersSettings,
    renderWebhookSettings,
    renderEventWebhookSettings,
    renderFixedCostSettings,
    renderLanApiSettings,
    renderEstimatorSettings,
    saveEstimatorSettingsFromForm,
    renderZatcaPhase2Settings,
    renderExchangeRatesSettings,
    renderBnplSettings,
    renderSavedFilterPresets,
    saveCurrentFilterPreset,
    updateLogoPreview,
    loadSettingsIntoForm,
    syncUpdaterOptionsFromSettings,
    renderStorageUsage,
    saveSettingsFromForm,
    saveSettingsFromPanel,
    saveLanApiSettingsFromForm,
    openRestoreBackupModal,
    openRestorePointsModal,
    openCloudSnapshotsModal,
    renderHolidayList,
    renderPostChecklistSettings,
    addPostCheckItem,
    deletePostCheckItem,
    renderCustomFieldsSettings,
    addCustomField,
    deleteCustomField,
    exportData,
    pruneArchivedOrders,
    importData,
    loadSampleData,
    clearSampleData,
    resetAllData,
    fullWipeData,
    renderSecuritySettings,
    renderTelegramSettings,
    // These four panels were declared like every other one but never added to
    // this hand-maintained list, so nothing outside this IIFE could re-render
    // them — renderPrivacySettings in particular, which now has to refresh when
    // AI consent changes. test/settings-exports.test.js keeps the list honest.
    renderPrivacySettings,
    renderApiTokensSettings,
    renderShippingSettings,
    renderTelemetrySettings,
    // Called from app-state.js at load. This file is IIFE-wrapped, so without
    // this line the typeof check there just sees undefined and the whole thing
    // silently never runs — which is the failure the four names above document.
    reportResurrectedRecords,
    reportLegacyMoneyState,
    // The organisation overview's three line builders. Pure string in, string
    // out, and the only place money is put in front of a chain owner — so they
    // are exported to be asserted on rather than eyeballed inside a modal.
    orgLateLine,
    orgMoneyLine,
    orgTotalMoneyLine,
    /* The picture pipeline, exported so it can be RUN rather than eyeballed.
     * It needs a canvas and the file system, so a unit test cannot reach it —
     * but the Electron smoke run can, and does. Publishing 240px thumbnails as
     * product-page heroes was a defect nothing failed on: the publish
     * succeeded, the pictures appeared, and they were simply too small. */
    loadHeroPhotos,
    heroPhotoFor,
  };

  Object.assign(global, api);
  global.KhaytSettings = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
