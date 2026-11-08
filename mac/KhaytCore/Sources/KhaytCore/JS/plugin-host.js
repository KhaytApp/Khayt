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

  const api = {
    consentedEntry, updatedEntry, withEntry, withoutEntry, stateOf, liveEntries,
    actionsFor, eventTargets, fieldsFor, coerceField, withFieldValues, missingSecrets, labelOf, deliveryId,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPluginHost = api;
})();
