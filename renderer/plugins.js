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

/* ── Settings › Automation › Connectors ─────────────────────────────── */

function renderPluginSettings() {
  const el = $('#pluginSection');
  if (!el || !PluginHost()) return;
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
      return `
      <div class="plg-row" data-plugin="${escapeHtml(entry.id)}" style="border:1px solid var(--border-soft);border-radius:10px;padding:12px;margin-bottom:10px;">
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
          <strong>${escapeHtml(pluginLabel(m.name))}</strong>
          <span style="font-size:11.5px;color:var(--text-muted);">${escapeHtml(m.publisher || '')} · ${escapeHtml(m.version || '')}</span>
          <span class="plg-state" data-state="${state}" style="margin-inline-start:auto;font-size:11.5px;font-weight:600;">${escapeHtml(stateWord(state))}</span>
        </div>
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
          ${state === 'paused' ? `<button class="btn primary small" type="button" data-plugin-act="consent">${escapeHtml(t('plg.review_agree'))}</button>` : ''}
          ${state === 'on' || state === 'off' ? `<button class="btn ghost small" type="button" data-plugin-act="toggle">${escapeHtml(state === 'on' ? t('plg.turn_off') : t('plg.turn_on'))}</button>` : ''}
          <button class="btn ghost small" type="button" data-plugin-act="details">${escapeHtml(t('plg.what_it_sends'))}</button>
          <button class="btn danger small" type="button" data-plugin-act="remove" style="margin-inline-start:auto;">${escapeHtml(t('plg.remove'))}</button>
        </div>
      </div>`;
    }).join('')}`;

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
      // and not secret, each checked against its declared type.
      const config = Object.assign({}, entry.config || {});
      row.querySelectorAll('[data-plugin-config]').forEach((inp) => {
        const st = (entry.manifest.settings || []).find((x) => x.key === inp.dataset.pluginConfig);
        if (!st) return;
        const v = PluginHost().coerceField(st, inp.type === 'checkbox' ? inp.checked : inp.value.trim());
        if (v === undefined || (st.type === 'bool' && v === false && !st.required)) delete config[st.key];
        else config[st.key] = v;
      });
      settings.plugins = PluginHost().withEntry(settings.plugins, Object.assign({}, entry, { config }));
      saveAll();
      toast(t('webhook.saved') || 'Saved', 'success');
    } else if (act === 'consent') {
      if (await pluginConsent(entry.manifest)) {
        settings.plugins = PluginHost().withEntry(settings.plugins, PluginHost().consentedEntry(entry, entry.manifest));
        saveAll();
      }
    } else if (act === 'toggle') {
      settings.plugins = PluginHost().withEntry(settings.plugins, Object.assign({}, entry, { enabled: entry.enabled === false }));
      saveAll();
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
  if (!(await pluginConsent(manifest))) return false;
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
function pluginConsent(manifest, { readOnly = false } = {}) {
  const M = PluginManifest();
  const rows = M.consentRows(manifest);
  const scopes = M.permissionsOf(manifest).scopes;
  const fieldName = (key) => {
    if (key.startsWith('field.')) {
      const f = (manifest.fields || []).find((x) => x.key === key.slice(6));
      return f ? pluginLabel(f.label) : key;
    }
    const w = t('plg.f.' + key);
    return w && w !== 'plg.f.' + key ? w : key;
  };
  return new Promise((resolve) => {
    const overlay = appendStackedModal(`
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="plgConsentTitle" style="max-width:520px;">
        <h3 id="plgConsentTitle">${escapeHtml(pluginLabel(manifest.name))}</h3>
        <p style="font-size:12px;color:var(--text-muted);margin:0 0 12px;">${escapeHtml(manifest.publisher || '')} · ${escapeHtml(manifest.version || '')} · ${escapeHtml(t('plg.reviewed_by_khayt'))}</p>
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
  if (!H) return '';
  const fields = H.fieldsFor(settings, attach, pluginIsReviewed);
  const actions = H.actionsFor(settings, attach, pluginIsReviewed);
  if (!fields.length && !actions.length) return '';
  const P = PluginPayload();
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
      ${actions.length ? `<div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px;">${actions.map(({ entry, action }) =>
        `<button type="button" class="btn small" data-plugin-action="${escapeHtml(entry.id)}|${escapeHtml(action.id)}">${escapeHtml(pluginLabel(action.label))}</button>`).join('')}</div>` : ''}
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
      btn.disabled = true;
      try { await runPluginAction(id, actionId, attach, getRecords()); }
      finally { btn.disabled = false; }
    });
  });
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
    toast(t('plg.err_refused', { why: (r && r.refused) || '?' }), 'error', 6000);
    return r;
  }
  if (r.method === 'OPEN') return r;
  if (!r.ok) { toast(t('plg.err_failed', { why: r.error || ('HTTP ' + (r.status || '?')) }), 'error', 6000); return r; }
  // applyResponse checks the grant itself (fields.write, still covering this
  // manifest) and returns nothing without it.
  if (r.reply && typeof recs.write === 'function') {
    const values = PluginPayload().applyResponse(entry.manifest, actionId, r.reply, entry);
    if (Object.keys(values).length) recs.write(PluginHost().withFieldValues(recs[attach], entry, attach, values));
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
    if (!H || !orderId) return;
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
  if (r && (r.ok || r.refused)) { clearPluginOutbox(item.delivery); return; }
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
  await refreshPluginReviewed();
  const list = Array.isArray(settings.pluginOutbox) ? settings.pluginOutbox.slice() : [];
  for (const item of list) {
    if (!item || !item.delivery) continue;
    const wait = Math.max(0, Date.parse(item.nextAttemptAt || '') - Date.now()) || 0;
    setTimeout(() => deliverPluginEvent(item), Math.min(wait, 2_147_000_000));
  }
}
