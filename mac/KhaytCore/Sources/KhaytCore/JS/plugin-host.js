'use strict';
/**
 * Installed connectors, as a host app runs them.
 *
 * lib/plugin-manifest.js says what a connector IS and may do, and
 * lib/plugin-payload.js what it sends. This module is the part between: which
 * installed connectors are live, which buttons go on a job or a customer,
 * which ones listen to an event, the fields they add, and how the stored
 * entry changes when a shop installs, agrees, updates, switches off or
 * removes one. Pure: no network, no crypto, no DOM — the desktop's renderer
 * and main process both load it, and so can any other host.
 *
 * THE ENTRY (`settings.plugins[]`, the shape lib/plugin-manifest.js
 * checkEntry holds every device to):
 *   { id, version, enabled, manifest, granted, config, secrets }
 * `secrets` exists on the desktop only, sealed on disk and per DEVICE
 * (lib/store-secret-paths.js PER_DEVICE_PATHS). A plugin's own field values
 * live on the record they belong to, under `record.plugins[<id>][<key>]`.
 *
 * REVIEWED is not in here on purpose. It is a signature check the platform
 * does (the desktop's main process, node:crypto) every time, never a stored
 * flag: anyone can write a flag into a synced book.
 */
(function () {
  const M = (typeof globalThis !== 'undefined' && globalThis.KhaytPluginManifest) || (() => {
    try { return require('./plugin-manifest.js'); } catch (_) { return null; }
  })();
  if (!M) throw new Error('plugin-host needs plugin-manifest loaded first');

  const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
  const list = (settings) => (isObj(settings) && Array.isArray(settings.plugins) ? settings.plugins : []);

  /**
   * The entry once the shop has agreed to this manifest: granted exactly what
   * it was shown (`grantFor`). Installing over an existing entry keeps its
   * settings and this device's secrets, and its on/off switch.
   */
  function consentedEntry(prev, manifest) {
    const p = isObj(prev) ? prev : {};
    const e = {
      id: manifest.id,
      version: manifest.version,
      enabled: p.enabled === undefined ? true : !!p.enabled,
      manifest,
      granted: M.grantFor(manifest),
      config: isObj(p.config) ? p.config : {},
    };
    if (isObj(p.secrets)) e.secrets = p.secrets;
    return e;
  }

  /**
   * A newer manifest for an installed connector, WITHOUT a new consent: the
   * grant stays as it was, so an update that asks for more is paused
   * (`checkEntry().paused`) until the shop agrees again.
   */
  function updatedEntry(prev, manifest) {
    const e = Object.assign({}, prev, { version: manifest.version, manifest });
    return e;
  }

  /** The book's plugins with `entry` put in its place (by id), or added. */
  function withEntry(plugins, entry) {
    const arr = Array.isArray(plugins) ? plugins.slice() : [];
    const i = arr.findIndex((p) => isObj(p) && p.id === entry.id);
    if (i >= 0) arr[i] = entry; else arr.push(entry);
    return arr;
  }

  /** The book's plugins without this one. Its secrets go with it. */
  function withoutEntry(plugins, id) {
    return (Array.isArray(plugins) ? plugins : []).filter((p) => !(isObj(p) && p.id === id));
  }

  /**
   * Where an entry stands: 'invalid' (fails checkEntry — a damaged or edited
   * entry), 'paused' (asks for more than was granted), 'off', or 'on'.
   * `reviewed` is the platform's signature verdict, passed in; an entry that
   * is not reviewed never runs on the desktop (dev mode is the Mac's only).
   */
  function stateOf(entry, reviewed) {
    const c = M.checkEntry(entry);
    if (!c.ok) return 'invalid';
    if (reviewed === false) return 'unreviewed';
    if (c.paused) return 'paused';
    return entry.enabled === false ? 'off' : 'on';
  }

  /** Entries that may run now. `isReviewed(entry)` is the platform's check. */
  function liveEntries(settings, isReviewed) {
    return list(settings).filter((e) => isObj(e) && stateOf(e, isReviewed ? !!isReviewed(e) : undefined) === 'on');
  }

  /** Buttons for a record: [{ entry, action }] for `placement` 'order' or 'customer'. */
  function actionsFor(settings, placement, isReviewed) {
    const out = [];
    for (const entry of liveEntries(settings, isReviewed)) {
      for (const action of (entry.manifest.actions || [])) {
        if (action.placement === placement) out.push({ entry, action });
      }
    }
    return out;
  }

  /** Connectors listening to a bus event: [{ entry, event }]. */
  function eventTargets(settings, event, isReviewed) {
    if (!M.EVENTS.includes(event)) return [];
    const out = [];
    for (const entry of liveEntries(settings, isReviewed)) {
      for (const ev of (entry.manifest.events || [])) if (ev.event === event) out.push({ entry, event: ev });
    }
    return out;
  }

  /**
   * The fields connectors add to a kind of record ('order', 'customer', …):
   * [{ entry, field }]. A paused or switched-off connector's fields are still
   * SHOWN (the values are the shop's), only not editable — `editable` says so.
   */
  function fieldsFor(settings, attach, isReviewed) {
    const out = [];
    for (const entry of list(settings)) {
      if (!isObj(entry) || !isObj(entry.manifest)) continue;
      const state = stateOf(entry, isReviewed ? !!isReviewed(entry) : undefined);
      if (state === 'invalid') continue;
      for (const field of (entry.manifest.fields || [])) {
        if (field.attach === attach) out.push({ entry, field, editable: state === 'on' });
      }
    }
    return out;
  }

  /** A value typed into a plugin field, checked against its type; undefined when it does not fit. */
  function coerceField(field, raw) {
    if (raw === undefined || raw === null || raw === '') return undefined;
    switch (field.type) {
      case 'number': { const n = Number(raw); return Number.isFinite(n) && typeof raw !== 'boolean' ? n : undefined; }
      case 'bool': return raw === true || raw === 'true' || raw === 'on';
      case 'date': return /^\d{4}-\d{2}-\d{2}/.test(String(raw)) ? String(raw).slice(0, 10) : undefined;
      case 'enum': return (field.options || []).some((o) => o.value === raw) ? raw : undefined;
      default: return String(raw).slice(0, 500);
    }
  }

  /**
   * A record with these values written into one plugin's fields: only keys
   * the manifest declares for this kind of record, each coerced; an empty
   * value removes the key. Returns a NEW record.
   */
  function withFieldValues(record, entry, attach, values) {
    const rec = Object.assign({}, record);
    const all = isObj(rec.plugins) ? Object.assign({}, rec.plugins) : {};
    const mine = isObj(all[entry.id]) ? Object.assign({}, all[entry.id]) : {};
    for (const field of (entry.manifest.fields || [])) {
      if (field.attach !== attach || !Object.prototype.hasOwnProperty.call(values || {}, field.key)) continue;
      const v = coerceField(field, values[field.key]);
      if (v === undefined) delete mine[field.key]; else mine[field.key] = v;
    }
    if (Object.keys(mine).length) all[entry.id] = mine; else delete all[entry.id];
    if (Object.keys(all).length) rec.plugins = all; else delete rec.plugins;
    return rec;
  }

  /**
   * The entry with the shop's settings for it (manifest `settings[]`, stored
   * as `entry.config`, synced and not secret) changed: only keys the manifest
   * declares and `values` names, each checked by `coerceField`. An empty value
   * removes the key, and so does an unticked box that is not required. Returns
   * a NEW entry; anything else in `config` is kept as it was.
   */
  function withConfig(entry, values) {
    const config = Object.assign({}, isObj(entry && entry.config) ? entry.config : {});
    for (const st of ((entry && entry.manifest && entry.manifest.settings) || [])) {
      if (!isObj(st) || !Object.prototype.hasOwnProperty.call(values || {}, st.key)) continue;
      const v = coerceField(st, values[st.key]);
      if (v === undefined || (st.type === 'bool' && v === false && !st.required)) delete config[st.key];
      else config[st.key] = v;
    }
    return Object.assign({}, entry, { config });
  }

  /**
   * The retry queue for connector events (`settings.pluginOutbox`): one item
   * per delivery, `{ delivery, id, event, orderId, attempt, nextAttemptAt }`,
   * kept BEFORE the wait so a quit mid-backoff resumes on the next launch.
   * The same delivery id on every attempt. The newest 200 are kept.
   */
  const OUTBOX_CAP = 200;
  function withQueued(list, item, nextAttemptAt) {
    const out = (Array.isArray(list) ? list : []).filter((p) => isObj(p) && p.delivery !== item.delivery);
    out.push(Object.assign({}, item, { nextAttemptAt }));
    return out.slice(-OUTBOX_CAP);
  }
  function withoutQueued(list, delivery) {
    return (Array.isArray(list) ? list : []).filter((p) => isObj(p) && p.delivery !== delivery);
  }
  /**
   * An event the service TURNED DOWN (a 2xx with `success: false`,
   * lib/plugin-payload.js replyRefusal) is not retried on its own — the same
   * request would be turned down the same way. It stays in the outbox with
   * `failed: { at, message }` and no next attempt, so the shop sees it and
   * the provider's words, and can Retry once it has fixed the cause.
   */
  function withFailed(list, item, at, message) {
    const out = (Array.isArray(list) ? list : []).filter((p) => isObj(p) && p.delivery !== item.delivery);
    const failed = Object.assign({}, item, { failed: { at: String(at || ''), message: String(message || '') } });
    delete failed.nextAttemptAt;
    out.push(failed);
    return out.slice(-OUTBOX_CAP);
  }
  /** The shop pressed Retry: no longer failed, and due now. */
  function withRetried(list, delivery, nowIso) {
    return (Array.isArray(list) ? list : []).map((p) => {
      if (!isObj(p) || p.delivery !== delivery || !isObj(p.failed)) return p;
      const again = Object.assign({}, p, { nextAttemptAt: String(nowIso || '') });
      delete again.failed;
      return again;
    });
  }
  /** Items the service turned down, newest last. */
  function failedQueued(list) {
    return (Array.isArray(list) ? list : []).filter((p) => isObj(p) && typeof p.delivery === 'string' && isObj(p.failed));
  }
  /** Items whose time has come (an unreadable time counts as due). A failed one never is. */
  function dueQueued(list, nowMs) {
    return (Array.isArray(list) ? list : []).filter((p) => {
      if (!isObj(p) || typeof p.delivery !== 'string' || !p.delivery) return false;
      if (isObj(p.failed)) return false;
      const at = Date.parse(p.nextAttemptAt || '');
      return !Number.isFinite(at) || at <= nowMs;
    });
  }

  // ── REFRESH ──────────────────────────────────────────────────────────
  //
  // What a computer holding the book does on its own (lib/plugin-manifest.js
  // REFRESH says what refresh is and where it may run). These say which
  // connectors check, whether one is due, and which jobs it asks about; the
  // host keeps the clock — when each connector last ran and when each job was
  // last asked about — wherever it likes, OUT of the book, because a time
  // stamped into a synced book every quarter hour is a write every device
  // would sync for nothing.

  /** Connectors that are on and whose manifest has a `refresh`: [{ entry, refresh }]. */
  function refreshTargets(settings, isReviewed) {
    return liveEntries(settings, isReviewed)
      .filter((entry) => isObj(entry.manifest.refresh))
      .map((entry) => ({ entry, refresh: entry.manifest.refresh }));
  }

  /**
   * Is a connector's refresh due? `lastRunMs` is when it last ran (anything
   * unreadable counts as never). Never more often than every
   * `REFRESH.minEvery` minutes, whatever the manifest says.
   */
  function refreshDue(refresh, lastRunMs, nowMs) {
    const every = M.refreshEvery({ refresh });
    if (!every) return false;
    const last = Number(lastRunMs);
    if (!Number.isFinite(last) || last <= 0) return true;
    // A clock set back is not a reason to wait days.
    if (last > nowMs) return true;
    return nowMs - last >= every * 60000;
  }

  /**
   * A job refresh may ask about: not cancelled, not archived, not voided and
   * not delivered (a delivery is a date stamp on a completed job, and the
   * legacy `delivered` status means the same).
   */
  function isOpenJob(o) {
    return isObj(o) && typeof o.id === 'string' && !!o.id
      && o.status !== 'cancelled' && o.status !== 'delivered'
      && !o.archived && !o.voidedAt && !o.deliveredAt;
  }

  /**
   * The jobs one run asks about: open, with the connector's `when` field
   * filled in, least recently asked about first (`checkedAt` maps a job id to
   * ms; a job never asked about goes first), then by id so the order is the
   * same on every computer. At most `REFRESH.jobsPerRun`.
   */
  function refreshJobs(printLog, entry, checkedAt) {
    const r = isObj(entry && entry.manifest) ? entry.manifest.refresh : null;
    if (!isObj(r) || typeof r.when !== 'string') return [];
    const seen = isObj(checkedAt) ? checkedAt : {};
    const at = (id) => { const n = Number(seen[id]); return Number.isFinite(n) ? n : -Infinity; };
    return (Array.isArray(printLog) ? printLog : [])
      .filter((o) => {
        if (!isOpenJob(o)) return false;
        const mine = isObj(o.plugins) && isObj(o.plugins[entry.id]) ? o.plugins[entry.id] : null;
        const v = mine ? mine[r.when] : undefined;
        return v !== undefined && v !== null && v !== '' && v !== false;
      })
      .sort((a, b) => (at(a.id) - at(b.id)) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
      .slice(0, M.REFRESH.jobsPerRun);
  }

  /** The secrets a connector declares that this device has not been given. */
  function missingSecrets(entry) {
    const have = isObj(entry && entry.secrets) ? entry.secrets : {};
    return ((entry && entry.manifest && entry.manifest.secrets) || []).map((s) => s.name).filter((n) => !have[n]);
  }

  /** A label in the shop's language, else English, else the first one. */
  function labelOf(label, lang) {
    if (typeof label === 'string') return label;
    if (!isObj(label)) return '';
    return label[lang] || label[String(lang || '').split('-')[0]] || label.en || Object.values(label)[0] || '';
  }

  /**
   * A delivery id: "dlv_" + a lowercase UUID v4, minted ONCE per press or
   * event and kept with a retry, so every attempt carries the same one. Never
   * derived from the order or plugin, which would put them in a receiver's
   * logs. `randomUUID` is the platform's.
   */
  function deliveryId(randomUUID) {
    return 'dlv_' + String(randomUUID()).toLowerCase();
  }

  /**
   * A record a paired phone sent, with its connector values held to what the
   * phone may change. Each connector that is on (`reviewedIds` names the ones
   * whose signature this Mac verified) takes the phone's values for the
   * fields it declares on `attach` ('order' or 'customer'), checked by
   * `coerceField`. Everything else under `plugins` stays as `held` (this
   * Mac's copy of the record) has it: an id with no connector, a connector
   * that is off or paused, a key nobody declared. So a phone can fill a
   * connector's field and save its reply, and cannot invent a connector's
   * values or wipe one that is switched off.
   *
   * A record with no `plugins` key at all keeps every value `held` has: an
   * older phone build that does not know the field must not clear it. To
   * clear a connector's last value, the phone sends `plugins: {}`.
   */
  function phoneRecord(incoming, held, settings, attach, reviewedIds) {
    if (!isObj(incoming)) return incoming;
    if (!Object.prototype.hasOwnProperty.call(incoming, 'plugins')) {
      const kept = Object.assign({}, incoming);
      if (isObj(held) && isObj(held.plugins)) kept.plugins = held.plugins;
      return kept;
    }
    const sent = isObj(incoming.plugins) ? incoming.plugins : {};
    const out = Object.assign({}, incoming);
    if (isObj(held) && isObj(held.plugins)) out.plugins = held.plugins; else delete out.plugins;
    const ok = new Set(Array.isArray(reviewedIds) ? reviewedIds : []);
    let rec = out;
    for (const entry of liveEntries(settings, (e) => ok.has(e.id))) {
      const mine = isObj(sent[entry.id]) ? sent[entry.id] : {};
      const values = {};
      for (const field of (entry.manifest.fields || [])) {
        if (field.attach === attach) values[field.key] = mine[field.key];
      }
      rec = withFieldValues(rec, entry, attach, values);
    }
    return rec;
  }

  const api = {
    consentedEntry, updatedEntry, withEntry, withoutEntry, stateOf, liveEntries,
    actionsFor, eventTargets, fieldsFor, coerceField, withFieldValues, missingSecrets, labelOf, deliveryId,
    phoneRecord, withConfig, withQueued, withoutQueued, dueQueued, OUTBOX_CAP,
    withFailed, withRetried, failedQueued,
    refreshTargets, refreshDue, refreshJobs, isOpenJob,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPluginHost = api;
})();
