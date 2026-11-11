/* ============================================================
   Connectors (plugins v1) — the desktop's half.

   What a connector is and sends is the shared lib/ (plugin-manifest.js,
   plugin-payload.js, plugin-host.js), the same on the Mac and the iPhone.
   This file is the window: Settings › Automation › Connectors (install,
   consent, keys, on/off, remove), the fields and buttons a connector adds
   to a job or a customer, and the events it listens to. Whether a request
   goes out, where and with which key is decided in the main process
   (lib/main/plugin-send.js) — the window never holds a connector's secret
   after it is saved, only the mask.
   ============================================================ */

const PLUGIN_RETRY_MAX = 5;
/** Ids of installed connectors whose signature verified (asked of main). */
let pluginReviewed = {};

function PluginHost() { return (typeof KhaytPluginHost !== 'undefined') ? KhaytPluginHost : null; }
function PluginManifest() { return (typeof KhaytPluginManifest !== 'undefined') ? KhaytPluginManifest : null; }
function PluginPayload() { return (typeof KhaytPluginPayload !== 'undefined') ? KhaytPluginPayload : null; }
function PluginUpdate() { return (typeof KhaytPluginUpdate !== 'undefined') ? KhaytPluginUpdate : null; }
function PluginUpdateSheet() { return (typeof KhaytPluginUpdateSheet !== 'undefined') ? KhaytPluginUpdateSheet : null; }
const pluginIsReviewed = (entry) => !!pluginReviewed[entry && entry.id];
const pluginLang = () => (typeof i18n !== 'undefined' && i18n.current) || 'en';
const pluginLabel = (l) => (PluginHost() ? PluginHost().labelOf(l, pluginLang()) : (l && l.en) || '');

/** Ask main which installed connectors are reviewed. Called at boot and after a change. */
async function refreshPluginReviewed() {
  const list = Array.isArray(settings.plugins) ? settings.plugins : [];
  if (!list.length || !window.hubAPI?.pluginReviewed) { pluginReviewed = {}; return; }
  try { pluginReviewed = await window.hubAPI.pluginReviewed(list.map((e) => e && e.manifest).filter(Boolean)) || {}; }
  catch (_) { pluginReviewed = {}; }
}

function pluginDeliveryId() {
  return PluginHost().deliveryId(() => crypto.randomUUID());
}

function customerOfOrder(order) {
  return order && order.clientId ? (clients || []).find((c) => c && c.id === order.clientId) : undefined;
}

/* ── Switched off until they ship ────────────────────────────────────── */

// The main process decides (main.js CONNECTORS_ON). Until it has said yes,
// this window shows no connector anywhere, fires no event and resumes no
// retry; main refuses each request anyway.
let pluginsOn = false;
async function loadPluginsEnabled() {
  try { pluginsOn = !!(window.hubAPI?.pluginsEnabled && await window.hubAPI.pluginsEnabled()); }
  catch (_) { pluginsOn = false; }
  const card = document.getElementById('pluginCard');
  if (card) card.hidden = !pluginsOn;
  if (pluginsOn) renderPluginSettings();
  return pluginsOn;
}

/* ── Settings › Automation › Connectors ─────────────────────────────── */

function renderPluginSettings() {
  const el = $('#pluginSection');
  const card = document.getElementById('pluginCard');
  if (card) card.hidden = !pluginsOn;
  renderPluginNavBadge();
  if (!el || !PluginHost() || !pluginsOn) return;
  const list = Array.isArray(settings.plugins) ? settings.plugins : [];
  const stateWord = (s) => t('plg.state_' + s);
  el.innerHTML = `
    <div style="display:flex;gap:8px;align-items:center;margin-bottom:12px;">
      <button class="btn primary small" id="btnPluginInstall" type="button">${escapeHtml(t('plg.install'))}</button>
      <input type="file" id="pluginFile" accept=".json,.khaytplugin,application/json" hidden>
    </div>
    ${list.length ? '' : `<p class="plg-empty" style="font-size:12px;color:var(--text-muted);margin:0;">${escapeHtml(t('plg.none'))}</p>`}
    ${list.map((entry) => {
      if (!entry || !entry.manifest) return '';
      const m = entry.manifest;
      const state = PluginHost().stateOf(entry, pluginIsReviewed(entry));
      const missing = PluginHost().missingSecrets(entry);
      const upd = pluginUpdateState(entry.id);
      const waiting = pluginUpdateWaiting(entry);
      // While its version is withdrawn the entry is off whatever the shop
      // chose; the button says what the shop chose (kept for the fix).
      const withdrawn = upd.revoked && upd.revoked.version === entry.version;
      const switchedOn = withdrawn ? upd.revoked.wasEnabled !== false : state === 'on';
      return `
      <div class="plg-row" data-plugin="${escapeHtml(entry.id)}" style="border:1px solid var(--border-soft);border-radius:10px;padding:12px;margin-bottom:10px;">
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
          <strong>${escapeHtml(pluginLabel(m.name))}</strong>
          <span style="font-size:11.5px;color:var(--text-muted);">${escapeHtml(m.publisher || '')} · ${escapeHtml(m.version || '')}</span>
          ${waiting ? `<span class="plg-update-badge" data-plugin-update="${escapeHtml(waiting.version)}">${escapeHtml(t('plg.update_waiting'))}</span>` : ''}
          <span class="plg-state" data-state="${state}" style="margin-inline-start:auto;font-size:11.5px;font-weight:600;">${escapeHtml(stateWord(state))}</span>
        </div>
        ${withdrawn ? `<p class="plg-revoked" style="font-size:12px;color:var(--danger,#c0392b);margin:6px 0 0;">${escapeHtml(t('plg.upd_revoked', { v: entry.version }))}${upd.revoked.reason ? ' ' + escapeHtml(upd.revoked.reason) : ''}</p>` : ''}
        ${upd.updatedFrom && upd.previous ? `<p class="plg-updated-note" style="font-size:12px;color:var(--text-muted);margin:6px 0 0;">${escapeHtml(t('plg.upd_updated_note', { from: upd.updatedFrom, to: entry.version }))}</p>` : ''}
        ${m.description ? `<p style="font-size:12px;color:var(--text-muted);margin:6px 0 0;">${escapeHtml(pluginLabel(m.description))}</p>` : ''}
        ${(m.settings || []).map((st) => {
          const v = (entry.config || {})[st.key];
          const lab = `<label style="margin-top:10px;">${escapeHtml(pluginLabel(st.label))}${st.required ? ' *' : ''}</label>`;
          if (st.type === 'bool') return `<label style="display:flex;align-items:center;gap:8px;margin-top:10px;"><input type="checkbox" style="width:auto;margin:0;" data-plugin-config="${escapeHtml(st.key)}" ${v === true ? 'checked' : ''}> ${escapeHtml(pluginLabel(st.label))}</label>`;
          if (st.type === 'enum') return lab + `<select data-plugin-config="${escapeHtml(st.key)}"><option value=""></option>${(st.options || []).map((o) =>
            `<option value="${escapeHtml(o.value)}" ${v === o.value ? 'selected' : ''}>${escapeHtml(pluginLabel(o.label))}</option>`).join('')}</select>`;
          return lab + `<input type="${st.type === 'number' ? 'number' : 'text'}" data-plugin-config="${escapeHtml(st.key)}" value="${escapeHtml(v === undefined || v === null ? '' : String(v))}">`;
        }).join('')}
        ${(m.secrets || []).map((s) => `
          <label style="margin-top:10px;">${escapeHtml(pluginLabel(s.label))}</label>
          <input type="password" autocomplete="off" data-plugin-secret="${escapeHtml(s.name)}"
            value="${escapeHtml((entry.secrets || {})[s.name] || '')}" placeholder="${escapeHtml(t('plg.secret_ph'))}">`).join('')}
        ${missing.length && state === 'on' ? `<p style="font-size:11.5px;color:var(--warning,#b45309);margin:6px 0 0;">${escapeHtml(t('plg.keys_missing'))}</p>` : ''}
        <div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap;">
          ${(m.settings || []).length ? `<button class="btn small" type="button" data-plugin-act="save-config">${escapeHtml(t('common.save'))}</button>` : ''}
          ${(m.secrets || []).length ? `<button class="btn small" type="button" data-plugin-act="save-keys">${escapeHtml(t('plg.save_keys'))}</button>` : ''}
          ${waiting ? `<button class="btn primary small" type="button" data-plugin-act="review-update">${escapeHtml(t('plg.review_update'))}</button>` : ''}
          ${upd.updatedFrom && upd.previous ? `<button class="btn ghost small" type="button" data-plugin-act="revert">${escapeHtml(t('plg.upd_revert', { v: upd.previous.version }))}</button>` : ''}
          ${state === 'paused' ? `<button class="btn primary small" type="button" data-plugin-act="consent">${escapeHtml(t('plg.review_agree'))}</button>` : ''}
          ${state === 'on' || state === 'off' ? `<button class="btn ghost small" type="button" data-plugin-act="toggle">${escapeHtml(switchedOn ? t('plg.turn_off') : t('plg.turn_on'))}</button>` : ''}
          <button class="btn ghost small" type="button" data-plugin-act="details">${escapeHtml(t('plg.what_it_sends'))}</button>
          <button class="btn danger small" type="button" data-plugin-act="remove" style="margin-inline-start:auto;">${escapeHtml(t('plg.remove'))}</button>
        </div>
      </div>`;
    }).join('')}
    ${pluginFailedHtml()}`;

  el.querySelectorAll('[data-plugin-failed]').forEach((btn) => btn.addEventListener('click', () => {
    const delivery = btn.dataset.pluginFailed;
    const item = (settings.pluginOutbox || []).find((p) => p && p.delivery === delivery);
    if (!item) return;
    if (btn.dataset.act === 'retry') {
      // Due now, with the SAME delivery id, so a receiver that did take it drops the repeat.
      settings.pluginOutbox = PluginHost().withRetried(settings.pluginOutbox, delivery, new Date().toISOString());
      saveAll();
      // A fresh ladder: the shop fixed the cause, so a network blip may be retried again.
      const again = Object.assign({}, item, { attempt: 1 });
      delete again.failed;
      deliverPluginEvent(again);
    } else {
      clearPluginOutbox(delivery);
    }
    renderPluginSettings();
  }));

  const file = el.querySelector('#pluginFile');
  el.querySelector('#btnPluginInstall').addEventListener('click', () => file.click());
  file.addEventListener('change', async () => {
    const f = file.files && file.files[0];
    file.value = '';
    if (!f) return;
    if (f.size > 256 * 1024) { toast(t('plg.err_invalid'), 'error'); return; }
    let manifest;
    try { manifest = JSON.parse(await f.text()); } catch (_) { toast(t('plg.err_invalid'), 'error'); return; }
    await installPluginManifest(manifest);
  });
  el.querySelectorAll('[data-plugin-act]').forEach((btn) => btn.addEventListener('click', async () => {
    const row = btn.closest('[data-plugin]');
    const id = row && row.dataset.plugin;
    const entry = (settings.plugins || []).find((p) => p && p.id === id);
    if (!entry) return;
    const act = btn.dataset.pluginAct;
    if (act === 'save-keys') {
      const secrets = Object.assign({}, entry.secrets || {});
      row.querySelectorAll('[data-plugin-secret]').forEach((inp) => {
        const v = inp.value.trim();
        if (v) secrets[inp.dataset.pluginSecret] = v; else delete secrets[inp.dataset.pluginSecret];
      });
      settings.plugins = PluginHost().withEntry(settings.plugins, Object.assign({}, entry, { secrets }));
      saveAll();
      toast(t('plg.keys_saved'), 'success');
    } else if (act === 'save-config') {
      // The connector's settings (manifest settings[]): synced with the book
      // and not secret. lib/plugin-host.js withConfig keeps declared keys
      // only, each checked against its type — the Mac's rule too.
      const values = {};
      row.querySelectorAll('[data-plugin-config]').forEach((inp) => {
        values[inp.dataset.pluginConfig] = inp.type === 'checkbox' ? inp.checked : inp.value.trim();
      });
      settings.plugins = PluginHost().withEntry(settings.plugins, PluginHost().withConfig(entry, values));
      saveAll();
      toast(t('plib.saved'), 'success');
    } else if (act === 'consent') {
      if (await pluginConsent(entry.manifest)) {
        settings.plugins = PluginHost().withEntry(settings.plugins, PluginHost().consentedEntry(entry, entry.manifest));
        saveAll();
      }
    } else if (act === 'toggle') {
      const rev = pluginUpdateState(id).revoked;
      if (rev && rev.version === entry.version) {
        // Withdrawn: the shop's choice is kept beside the entry, which stays
        // off until the fix arrives (lib/plugin-update.js setSwitch) — main's.
        await pluginUpdateOp({ op: 'switch', id, enabled: !(rev.wasEnabled !== false) });
      } else {
        settings.plugins = PluginHost().withEntry(settings.plugins, Object.assign({}, entry, { enabled: entry.enabled === false }));
        saveAll();
      }
    } else if (act === 'review-update') {
      await openConnectorUpdateSheet(id);
      return;
    } else if (act === 'revert') {
      const prev = pluginUpdateState(id).previous;
      if (await pluginUpdateOp({ op: 'revert', id })) toast(t('plg.upd_reverted', { v: prev ? prev.version : '' }), 'success');
    } else if (act === 'details') {
      await pluginConsent(entry.manifest, { readOnly: true });
      return;
    } else if (act === 'remove') {
      const ok = await confirmModal(t('plg.remove_q', { name: pluginLabel(entry.manifest.name) }), { danger: true, okText: t('plg.remove') });
      if (!ok) return;
      settings.plugins = PluginHost().withoutEntry(settings.plugins, id);
      settings.pluginOutbox = (settings.pluginOutbox || []).filter((p) => p && p.id !== id);
      saveAll();
      toast(t('plg.removed'), 'success');
    }
    await refreshPluginReviewed();
    renderPluginSettings();
  }));
}

/**
 * Events a service turned down (a 2xx with success:false): the provider's
 * words, the job, and Retry / Dismiss. They are never retried on their own.
 */
function pluginFailedHtml() {
  const H = PluginHost();
  const failed = H && H.failedQueued ? H.failedQueued(settings.pluginOutbox) : [];
  if (!failed.length) return '';
  const rows = failed.slice().reverse().map((item) => {
    const entry = (settings.plugins || []).find((p) => p && p.id === item.id);
    const name = entry ? pluginLabel(entry.manifest.name) : item.id;
    const order = (printLog || []).find((o) => o && o.id === item.orderId);
    const job = order ? jobRef(order) : '';
    const when = item.failed.at ? new Date(item.failed.at).toLocaleString(settings.lang || undefined) : '';
    const d = escapeHtml(item.delivery);
    return `
      <div class="plg-failed-row" style="border-top:1px solid var(--border-soft);padding:8px 0;">
        <div style="font-size:12.5px;"><strong>${escapeHtml(name)}</strong>${job ? ` · ${escapeHtml(job)}` : ''} · <span style="color:var(--text-muted);">${escapeHtml(item.event || '')}${when ? ' · ' + escapeHtml(when) : ''}</span></div>
        <div style="font-size:12px;margin:4px 0 6px;">${escapeHtml(item.failed.message || t('plg.failed_nomsg'))}</div>
        <div style="display:flex;gap:8px;">
          <button class="btn small" type="button" data-plugin-failed="${d}" data-act="retry">${escapeHtml(t('plg.failed_retry'))}</button>
          <button class="btn ghost small" type="button" data-plugin-failed="${d}" data-act="dismiss">${escapeHtml(t('plg.failed_dismiss'))}</button>
        </div>
      </div>`;
  }).join('');
  return `
    <div class="plg-failed" style="border:1px solid var(--danger, #c0392b);border-radius:10px;padding:12px;margin-top:6px;">
      <div style="font-weight:600;font-size:13px;margin-bottom:4px;">${escapeHtml(t('plg.failed_title'))} (${failed.length})</div>
      ${rows}
    </div>`;
}

/**
 * Install (or update) from a manifest file: main checks it is valid and
 * signed by Khayt; the shop is shown exactly what goes where; only then is it
 * stored, granted what was shown. Unreviewed connectors are refused here —
 * dev mode is the Mac's alone.
 */
async function installPluginManifest(manifest) {
  const check = window.hubAPI?.pluginCheck ? await window.hubAPI.pluginCheck(manifest) : { ok: false, error: 'invalid' };
  if (!check || !check.ok) {
    toast(check && check.error === 'unreviewed' ? t('plg.err_unreviewed') : t('plg.err_invalid'), 'error', 6000);
    return false;
  }
  const prev = (settings.plugins || []).find((p) => p && p.id === manifest.id) || null;
  if (!(await pluginConsent(manifest, { replacing: prev && (prev.version || (prev.manifest && prev.manifest.version)) }))) return false;
  settings.plugins = PluginHost().withEntry(settings.plugins, PluginHost().consentedEntry(prev, manifest));
  saveAll();
  await refreshPluginReviewed();
  renderPluginSettings();
  toast(t('plg.installed', { name: pluginLabel(manifest.name) }), 'success');
  return true;
}

/**
 * The consent sheet: one row per host with the fields that go there and the
 * kind of data each is, then the scopes. `readOnly` shows the same thing
 * from the Settings row ("What it sends").
 */
/**
 * "Updates version {from} …" when an install goes over a version the shop
 * already has; '' for a first install, the same version again, or the
 * read-only view. Same rule as the Mac's ConnectorConsentSheet.updatesLine.
 */
function pluginUpdatesLine(manifest, replacing, readOnly) {
  const from = replacing == null ? '' : String(replacing);
  if (readOnly || !from || from === String((manifest && manifest.version) || '')) return '';
  return t('plg.consent_updates', { from });
}

/** A field a manifest sends, in the shop's words. */
function pluginFieldName(manifest, key) {
  if (key.startsWith('field.')) {
    const f = (manifest.fields || []).find((x) => x.key === key.slice(6));
    return f ? pluginLabel(f.label) : key;
  }
  // One of the connector's own settings (manifest settings[]), by its label.
  if (key.startsWith('config.')) {
    const st = (manifest.settings || []).find((x) => x.key === key.slice(7));
    return st ? pluginLabel(st.label) : key;
  }
  const w = t('plg.f.' + key);
  return w && w !== 'plg.f.' + key ? w : key;
}

function pluginConsent(manifest, { readOnly = false, replacing = null } = {}) {
  const M = PluginManifest();
  const rows = M.consentRows(manifest);
  const scopes = M.permissionsOf(manifest).scopes;
  const fieldName = (key) => pluginFieldName(manifest, key);
  const updates = pluginUpdatesLine(manifest, replacing, readOnly);
  return new Promise((resolve) => {
    const overlay = appendStackedModal(`
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="plgConsentTitle" style="max-width:520px;">
        <h3 id="plgConsentTitle">${escapeHtml(pluginLabel(manifest.name))}</h3>
        <p style="font-size:12px;color:var(--text-muted);margin:0 0 12px;">${escapeHtml(manifest.publisher || '')} · ${escapeHtml(manifest.version || '')} · ${escapeHtml(t('plg.reviewed_by_khayt'))}</p>
        ${updates ? `<p class="plg-consent-updates" style="font-size:12.5px;color:var(--text-muted);margin:0 0 8px;">${escapeHtml(updates)}</p>` : ''}
        <p style="font-size:12.5px;margin:0 0 10px;">${escapeHtml(t('plg.consent_lead'))}</p>
        ${rows.map((r) => `
          <div class="plg-consent-host" data-host="${escapeHtml(r.host)}" style="border:1px solid var(--border-soft);border-radius:8px;padding:8px 10px;margin-bottom:8px;">
            <div style="font-family:var(--font-mono,monospace);font-size:12.5px;font-weight:600;" dir="ltr">${escapeHtml(r.host)}</div>
            ${r.fields.length ? `<ul style="margin:6px 0 0;padding-inline-start:18px;font-size:12px;">${r.fields.map((f) =>
              `<li data-field="${escapeHtml(f.key)}">${escapeHtml(fieldName(f.key))} <span style="color:var(--text-muted);">— ${escapeHtml(t('plg.cat.' + f.category))}</span></li>`).join('')}</ul>`
              : `<p style="font-size:12px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('plg.consent_link_only'))}</p>`}
          </div>`).join('')}
        ${scopes.length ? `<p style="font-size:12px;margin:8px 0 0;">${escapeHtml(t('plg.consent_scopes'))}: ${scopes.map((s) => escapeHtml(t('plg.scope.' + s))).join(', ')}</p>` : ''}
        <p style="font-size:11.5px;color:var(--text-muted);margin:10px 0 0;">${escapeHtml(t('plg.consent_keys_here'))}</p>
        <div class="btn-row">
          ${readOnly ? `<button class="btn primary" data-act="cancel">${escapeHtml(t('common.close'))}</button>` : `
          <button class="btn ghost" data-act="cancel">${escapeHtml(t('common.cancel'))}</button>
          <button class="btn primary" data-act="ok">${escapeHtml(t('plg.agree_install'))}</button>`}
        </div>
      </div>`);
    const done = (v) => { overlay.remove(); resolve(v); };
    overlay.querySelector('[data-act="cancel"]').addEventListener('click', () => done(false));
    overlay.querySelector('[data-act="ok"]')?.addEventListener('click', () => done(true));
    overlay.addEventListener('click', (e) => { if (e.target === overlay) done(false); });
  });
}

/* ── Fields and buttons on a job or a customer ──────────────────────── */

/** The Connectors block for an editor: the fields connectors add, then their buttons. */
function pluginEditorHtml(attach, record) {
  const H = PluginHost();
  if (!H || !pluginsOn) return '';
  const fields = H.fieldsFor(settings, attach, pluginIsReviewed);
  const actions = H.actionsFor(settings, attach, pluginIsReviewed);
  if (!fields.length && !actions.length) return '';
  const P = PluginPayload();
  // A button that sends the customer's details, on a job with no customer
  // record, would go out with them empty and be turned down (Lamha): grey it
  // out and say why, before anything is sent (lib/plugin-payload.js usesCustomer).
  const noCustomer = attach === 'order' && !(typeof customerOfOrder === 'function' && customerOfOrder(record));
  const actionButton = ({ entry, action }) => {
    const blocked = noCustomer && P && P.usesCustomer && P.usesCustomer(entry.manifest, { action: action.id });
    return `<button type="button" class="btn small" data-plugin-action="${escapeHtml(entry.id)}|${escapeHtml(action.id)}"${blocked
      ? ` disabled data-plugin-blocked="1" title="${escapeHtml(t('plg.no_customer'))}"` : ''}>${escapeHtml(pluginLabel(action.label))}</button>`
      + (blocked ? `<span style="font-size:11.5px;color:var(--text-muted);align-self:center;">${escapeHtml(t('plg.no_customer'))}</span>` : '');
  };
  const input = ({ entry, field, editable }) => {
    const v = P ? P.fieldValue(record, entry.id, field.key) : null;
    const id = `${escapeHtml(entry.id)}|${escapeHtml(field.key)}`;
    const dis = editable ? '' : 'disabled';
    if (field.type === 'bool') {
      return `<label style="display:flex;align-items:center;gap:8px;margin-top:10px;"><input type="checkbox" style="width:auto;margin:0;" data-plugin-field="${id}" ${v === true ? 'checked' : ''} ${dis}> ${escapeHtml(pluginLabel(field.label))}</label>`;
    }
    const label = `<label style="margin-top:10px;">${escapeHtml(pluginLabel(field.label))}</label>`;
    if (field.type === 'enum') {
      return label + `<select data-plugin-field="${id}" ${dis}><option value=""></option>${(field.options || []).map((o) =>
        `<option value="${escapeHtml(o.value)}" ${v === o.value ? 'selected' : ''}>${escapeHtml(pluginLabel(o.label))}</option>`).join('')}</select>`;
    }
    const type = field.type === 'number' ? 'number' : field.type === 'date' ? 'date' : 'text';
    return label + `<input type="${type}" data-plugin-field="${id}" value="${escapeHtml(v === null ? '' : String(v))}" ${dis}>`;
  };
  return `
    <div class="plg-editor" data-plugin-attach="${escapeHtml(attach)}" style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <label style="margin-top:0; font-weight:600;">${escapeHtml(t('plg.title'))}</label>
      ${fields.map(input).join('')}
      ${actions.length ? `<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px;">${actions.map(actionButton).join('')}</div>` : ''}
    </div>`;
}

/** The record with what the editor's connector fields now say. */
function readPluginEditor(modal, attach, record) {
  const H = PluginHost();
  if (!H || !modal) return record;
  const byEntry = new Map();
  modal.querySelectorAll(`.plg-editor[data-plugin-attach="${attach}"] [data-plugin-field]`).forEach((inp) => {
    if (inp.disabled) return;
    const [id, key] = inp.dataset.pluginField.split('|');
    if (!byEntry.has(id)) byEntry.set(id, {});
    byEntry.get(id)[key] = inp.type === 'checkbox' ? inp.checked : inp.value;
  });
  let rec = record;
  for (const [id, values] of byEntry) {
    const entry = (settings.plugins || []).find((p) => p && p.id === id);
    if (entry) rec = H.withFieldValues(rec, entry, attach, values);
  }
  return rec;
}

/** Wire the editor's connector buttons. `getRecords()` → { order, customer, write(rec) }. */
function wirePluginEditor(modal, attach, getRecords) {
  modal.querySelectorAll(`.plg-editor[data-plugin-attach="${attach}"] [data-plugin-action]`).forEach((btn) => {
    btn.addEventListener('click', async () => {
      const [id, actionId] = btn.dataset.pluginAction.split('|');
      if (btn.dataset.pluginBlocked) return;
      btn.disabled = true;
      try { await runPluginAction(id, actionId, attach, getRecords()); }
      finally { btn.disabled = false; }
    });
  });
}

/**
 * Why nothing was sent, in the shop's words. A setting or key that is not
 * filled in comes back from lib/plugin-payload.js and the main process as the
 * developer's key ("setting senderPhone is not set"); the shop is shown the
 * label the manifest gives it, in their language.
 */
function pluginRefusalText(entry, why) {
  const m = entry && entry.manifest;
  const set = /^setting (\S+) is not set$/.exec(String(why || ''));
  if (set && m) {
    const s = (m.settings || []).find((x) => x.key === set[1]);
    if (s) return t('plg.err_setting', { name: pluginLabel(s.label) || s.key });
  }
  const sec = /^secret "([^"]+)" is not set$/.exec(String(why || ''));
  if (sec && m) {
    const s = (m.secrets || []).find((x) => x.name === sec[1]);
    if (s) return t('plg.err_secret', { name: pluginLabel(s.label) || s.name });
  }
  return t('plg.err_refused', { why: why || '?' });
}

/**
 * A button pressed. Never retried (a press is the shop's, and a second one
 * is theirs to make). A reply fills the connector's own fields only with
 * fields.write granted (lib/plugin-manifest.js mayWriteFields).
 */
async function runPluginAction(id, actionId, attach, recs) {
  const entry = (settings.plugins || []).find((p) => p && p.id === id);
  if (!entry || !window.hubAPI?.pluginSend) return null;
  // The main process reads the entry, and its keys, from disk.
  if (typeof flushSave === 'function') { try { await flushSave(); } catch (_) {} }
  const r = await window.hubAPI.pluginSend({ id, action: actionId, delivery: pluginDeliveryId(),
    records: { order: recs.order, customer: recs.customer } });
  if (!r || (!r.ok && r.refused)) {
    toast(pluginRefusalText(entry, r && r.refused), 'error', 6000);
    return r;
  }
  if (r.method === 'OPEN') return r;
  if (!r.ok) { toast(t('plg.err_failed', { why: r.error || ('HTTP ' + (r.status || '?')) }), 'error', 6000); return r; }
  // A 2xx is not yet "Sent": the reply may turn it down, or fill none of the
  // fields it promises (lib/plugin-payload.js replyVerdict, one rule for every
  // app). applyResponse checks the grant itself and returns nothing without it.
  const P = PluginPayload();
  const reply = r.reply || {};
  const values = P.applyResponse(entry.manifest, actionId, reply, entry);
  const verdict = P.replyVerdict(entry.manifest, { action: actionId }, reply, entry, values);
  const name = pluginLabel(entry.manifest.name);
  if (verdict.kind === 'refused') {
    toast(verdict.message ? t('plg.err_declined', { name, msg: verdict.message }) : t('plg.err_declined_nomsg', { name }), 'error', 8000);
    return Object.assign({}, r, { ok: false, verdict });
  }
  if (Object.keys(values).length && typeof recs.write === 'function') {
    recs.write(PluginHost().withFieldValues(recs[attach], entry, attach, values));
  }
  if (verdict.kind === 'unconfirmed') {
    // Every field the manifest says the reply fills, by its declared label.
    const labels = verdict.fields.map((k) => {
      const f = (entry.manifest.fields || []).find((x) => x.key === k && x.attach === attach);
      return f ? pluginLabel(f.label) : k;
    });
    toast(t('plg.sent_unconfirmed', { name, field: labels.join(', ') }), 'warning', 8000);
    return Object.assign({}, r, { verdict });
  }
  toast(t('plg.sent'), 'success');
  return r;
}

/* ── Events ─────────────────────────────────────────────────────────── */

/**
 * A bus event on a job: every live connector listening to it is sent one
 * delivery, retried on the bus's ladder (lib/webhook-bus.js) with the SAME
 * delivery id. The retry queue is `settings.pluginOutbox`, persisted before
 * the timer is armed so a quit mid-backoff resumes on launch.
 */
function firePluginEvent(eventName, orderId) {
  try {
    const H = PluginHost();
    if (!H || !orderId || !pluginsOn) return;
    const targets = H.eventTargets(settings, eventName, pluginIsReviewed);
    for (const { entry } of targets) {
      deliverPluginEvent({ delivery: pluginDeliveryId(), id: entry.id, event: eventName, orderId, attempt: 1 });
    }
  } catch (_) { /* a connector must never break the action */ }
}

async function deliverPluginEvent(item) {
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  const order = (printLog || []).find((o) => o && o.id === item.orderId);
  if (!order || !window.hubAPI?.pluginSend) { clearPluginOutbox(item.delivery); return; }
  let r;
  try {
    r = await window.hubAPI.pluginSend({ id: item.id, event: item.event, delivery: item.delivery,
      records: { order, customer: customerOfOrder(order) } });
  } catch (e) { r = { ok: false, error: String(e && e.message || e) }; }
  if (r && r.ok) {
    // A 2xx the service turned down is not transient: the same request would
    // be turned down again. Kept as failed with its words and a manual Retry
    // (lib/plugin-host.js withFailed), never put back on the retry ladder.
    const entry = (settings.plugins || []).find((p) => p && p.id === item.id);
    const P = PluginPayload();
    const verdict = entry && P ? P.replyVerdict(entry.manifest, { event: item.event }, r.reply || {}, entry, {}) : { ok: true };
    if (verdict.kind === 'refused') {
      settings.pluginOutbox = PluginHost().withFailed(settings.pluginOutbox, item, new Date().toISOString(), verdict.message);
      saveAll();
      if (typeof renderPluginSettings === 'function') renderPluginSettings();
      return;
    }
    clearPluginOutbox(item.delivery);
    return;
  }
  if (r && r.refused) { clearPluginOutbox(item.delivery); return; }
  const status = r && r.status;
  const again = Bus ? Bus.shouldRetry(status, item.attempt) : item.attempt < PLUGIN_RETRY_MAX;
  if (!again) { clearPluginOutbox(item.delivery); return; }
  const next = Object.assign({}, item, { attempt: item.attempt + 1 });
  const delay = Bus ? Bus.backoffDelayMs(next.attempt) : 30000;
  persistPluginOutbox(next, delay);
  setTimeout(() => deliverPluginEvent(next), delay);
}

function persistPluginOutbox(item, delayMs) {
  const list = (settings.pluginOutbox || []).filter((p) => p && p.delivery !== item.delivery);
  list.push(Object.assign({}, item, { nextAttemptAt: new Date(Date.now() + (delayMs || 0)).toISOString() }));
  settings.pluginOutbox = list.slice(-200);
  saveAll();
}

function clearPluginOutbox(delivery) {
  if (!Array.isArray(settings.pluginOutbox) || !settings.pluginOutbox.some((p) => p && p.delivery === delivery)) return;
  settings.pluginOutbox = settings.pluginOutbox.filter((p) => p && p.delivery !== delivery);
  saveAll();
}

/** At launch: retries left from the last run, due ones now, the rest on their timers. */
async function resumePluginOutbox() {
  if (!(await loadPluginsEnabled())) return;
  await refreshPluginReviewed();
  checkConnectorUpdates();
  const list = Array.isArray(settings.pluginOutbox) ? settings.pluginOutbox.slice() : [];
  for (const item of list) {
    if (!item || !item.delivery || (item.failed && typeof item.failed === 'object')) continue;
    const wait = Math.max(0, Date.parse(item.nextAttemptAt || '') - Date.now()) || 0;
    setTimeout(() => deliverPluginEvent(item), Math.min(wait, 2_147_000_000));
  }
}

/* ── Updates (lib/plugin-update.js) ─────────────────────────────────── */

// What a check found lives in `settings.connectorUpdates`, written by the
// main process only (a save from this window keeps the disk's copy). This
// window draws it — the badge, the sheet, the quiet notes — and hands the
// shop's answer to main, then takes back what main wrote.

function pluginUpdateState(id) {
  const U = PluginUpdate();
  return U ? U.stateOf(settings, id) : {};
}

/** The pending update this connector is waiting on the shop's yes for, or null. */
function pluginUpdateWaiting(entry) {
  const S = PluginUpdateSheet();
  const U = PluginUpdate();
  if (!S || !U || !entry) return null;
  return S.waitingFor(entry, U.stateOf(settings, entry.id), U.compareVersions);
}

/** Settings › Connections in the nav: a steel badge while an update waits. */
function renderPluginNavBadge() {
  const nav = document.querySelector('.settings-nav-item[data-settings-section="connections"]');
  if (!nav) return;
  const n = pluginsOn ? (settings.plugins || []).filter((e) => e && pluginUpdateWaiting(e)).length : 0;
  let badge = nav.querySelector('.plg-nav-badge');
  if (!n) { if (badge) badge.remove(); return; }
  if (!badge) {
    badge = document.createElement('span');
    badge.className = 'plg-nav-badge';
    nav.appendChild(badge);
  }
  badge.textContent = String(n);
  badge.title = t('plg.update_waiting');
}

/** Take what main wrote: the connectors (keys masked) and their update state. */
function adoptConnectorUpdates(r) {
  if (!r || !Array.isArray(r.plugins)) return;
  settings.plugins = r.plugins;
  settings.connectorUpdates = r.connectorUpdates || undefined;
  if (!settings.connectorUpdates) delete settings.connectorUpdates;
}

/** The shop's Agree / Revert / switch, applied by main. True when it applied. */
async function pluginUpdateOp(req) {
  if (!window.hubAPI?.connectorUpdate) return false;
  // Main reads the store from disk: what this window has not saved yet goes first.
  if (typeof flushSave === 'function') { try { await flushSave(); } catch (_) {} }
  let r;
  try { r = await window.hubAPI.connectorUpdate(req); } catch (e) { r = { ok: false, error: String(e && e.message || e) }; }
  if (!r || !r.ok) { toast(t('plg.err_failed', { why: (r && (r.error || r.refused)) || '?' }), 'error', 6000); return false; }
  adoptConnectorUpdates(r);
  return true;
}

/** At launch: ask main to check the signed index. Main refuses while updates are off. */
async function checkConnectorUpdates() {
  if (!pluginsOn || !window.hubAPI?.connectorUpdatesCheck) return;
  if (typeof flushSave === 'function') { try { await flushSave(); } catch (_) {} }
  let r;
  try { r = await window.hubAPI.connectorUpdatesCheck(); } catch (_) { return; }
  if (!r || !r.ok || !r.changed) return;
  adoptConnectorUpdates(r);
  for (const n of r.notes || []) {
    const e = (settings.plugins || []).find((p) => p && p.id === n.id);
    const name = e ? pluginLabel(e.manifest.name) : n.id;
    if (n.kind === 'updated') toast(t('plg.upd_updated', { name, v: n.to }), 'success');
    else if (n.kind === 'revoked') toast(t('plg.upd_revoked', { v: n.from }) + (n.reason ? ' ' + n.reason : ''), 'warning', 8000);
  }
  await refreshPluginReviewed();
  renderPluginSettings();
}

/**
 * The update sheet (Figma 52:2434, the Mac's 70:284). Opened only from
 * "Review update". What is NEW comes first, each line tagged; what the shop
 * already agreed to after, quieter. "Not now" changes nothing — the installed
 * version keeps running and the badge stays. "Agree and update" is the
 * default button; nothing is accepted for the shop.
 */
async function openConnectorUpdateSheet(id) {
  const entry = (settings.plugins || []).find((p) => p && p.id === id);
  const pending = entry && pluginUpdateWaiting(entry);
  const S = PluginUpdateSheet();
  const sheet = pending && S ? S.sheetFor(entry, pending) : null;
  if (!sheet) return false;
  const manifest = pending.manifest;
  let reviewed = false;
  try { reviewed = !!(window.hubAPI?.pluginReviewed && (await window.hubAPI.pluginReviewed([manifest]) || {})[manifest.id]); } catch (_) { reviewed = false; }
  const itemName = (it) => {
    if (it.kind === 'link') return t('plg.consent_link_only');
    if (it.kind === 'secret') {
      const s = (manifest.secrets || []).find((x) => x.name === it.key);
      return s ? pluginLabel(s.label) : it.key;
    }
    return pluginFieldName(manifest, it.key);
  };
  const tag = (it) => it.tag ? `<span class="plg-upd-tag" data-tag="${it.tag}">${escapeHtml(t(it.tag === 'new' ? 'plg.upd_tag_new' : 'plg.upd_tag_new_place'))}</span>` : '';
  const hostRows = (rows, fresh) => rows.map((r) => `
    <div class="plg-upd-host" data-host="${escapeHtml(r.host)}">
      <div class="plg-upd-hostname" dir="ltr">${escapeHtml(r.host)}</div>
      <ul>${r.items.map((it) => `<li data-kind="${it.kind}" data-key="${escapeHtml(it.key)}"${fresh ? ` data-tag="${it.tag}"` : ''}>${escapeHtml(itemName(it))}${tag(it)}</li>`).join('')}</ul>
    </div>`).join('');
  const hasNew = sheet.fresh.length || sheet.scopes.length || sheet.refresh;
  const extras = [
    sheet.scopes.length ? `<p class="plg-upd-line" data-new="scopes">${escapeHtml(t('plg.consent_scopes'))}: ${sheet.scopes.map((s) => escapeHtml(t('plg.scope.' + s))).join(', ')}<span class="plg-upd-tag" data-tag="new">${escapeHtml(t('plg.upd_tag_new'))}</span></p>` : '',
    sheet.refresh ? `<p class="plg-upd-line" data-new="refresh">${escapeHtml(t('plg.upd_refresh', { n: sheet.refresh }))}<span class="plg-upd-tag" data-tag="new">${escapeHtml(t('plg.upd_tag_new'))}</span></p>` : '',
  ].join('');
  const agreeNow = await new Promise((resolve) => {
    const overlay = appendStackedModal(`
      <div class="modal plg-upd-sheet" role="dialog" aria-modal="true" aria-labelledby="plgUpdTitle" data-plugin-update-sheet="${escapeHtml(id)}" style="max-width:560px;">
        <div class="plg-upd-head">
          <h3 id="plgUpdTitle">${escapeHtml(pluginLabel(manifest.name))} <span class="plg-upd-ver">${escapeHtml(sheet.to)}</span></h3>
          ${reviewed ? `<span class="plg-upd-reviewed">✓ ${escapeHtml(t('plg.reviewed_by_khayt'))}</span>` : ''}
        </div>
        <p class="plg-upd-sub">${escapeHtml(t('plg.upd_updates', { v: sheet.from }))}</p>
        ${sheet.asksMore ? `<p class="plg-upd-lead">${escapeHtml(t('plg.upd_asks_more'))}</p>` : ''}
        ${hasNew ? `<section class="plg-upd-new">
          <div class="plg-upd-label">${escapeHtml(t('plg.upd_new_head'))}</div>
          ${hostRows(sheet.fresh, true)}${extras}
        </section>` : ''}
        ${sheet.agreed.length ? `<section class="plg-upd-agreed">
          <div class="plg-upd-label">${escapeHtml(t('plg.upd_agreed_head', { v: sheet.from }))}</div>
          ${hostRows(sheet.agreed, false)}
        </section>` : ''}
        <p class="plg-upd-foot">${escapeHtml(t('plg.upd_footer', { v: sheet.from }))}</p>
        <div class="btn-row">
          <button class="btn ghost" type="button" data-act="not-now">${escapeHtml(t('plg.upd_not_now'))}</button>
          <button class="btn primary" type="button" data-act="agree">${escapeHtml(t('plg.upd_agree'))}</button>
        </div>
      </div>`);
    const done = (v) => { overlay.remove(); resolve(v); };
    overlay.querySelector('[data-act="not-now"]').addEventListener('click', () => done(false));
    overlay.querySelector('[data-act="agree"]').addEventListener('click', () => done(true));
    overlay.addEventListener('click', (e) => { if (e.target === overlay) done(false); });
    overlay.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); done(false); } });
    try { overlay.querySelector('[data-act="agree"]').focus(); } catch (_) { /* ignore */ }
  });
  if (!agreeNow) return false;
  if (!(await pluginUpdateOp({ op: 'agree', id }))) return false;
  toast(t('plg.upd_updated', { name: pluginLabel(manifest.name), v: sheet.to }), 'success');
  await refreshPluginReviewed();
  renderPluginSettings();
  return true;
}
