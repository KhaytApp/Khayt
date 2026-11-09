'use strict';
/**
 * What a connector sends, byte for byte, the same on every device.
 *
 * The Mac, Windows/Linux and the iPhone all press the same button on the same
 * job, so they must send the same bytes to the same URL — otherwise "the
 * consent screen lists exactly what is sent" is true on one platform and
 * approximately true on the others. This module builds the request from a
 * manifest (already passed by lib/plugin-manifest.js validateManifest) and the
 * book's records; the platform only adds what it alone holds — the secret in
 * the auth header and the HMAC over `body` — and sends it.
 *
 * Nothing here reaches past what the manifest names. A field not referenced
 * is not read, a host not declared is not built, and a reply can only fill the
 * plugin's OWN fields.
 *
 * A plugin's own field values live on the record they are attached to, under
 * `plugins.<pluginId>.<key>` — so they sync with the job or customer like any
 * other field, and removing the plugin leaves nothing anywhere else.
 */
(function () {
  // The Mac and the phone load lib/ into JavaScriptCore, where there is no
  // `require` and the sibling is a global (lib/ order: manifest first).
  const M = (typeof globalThis !== 'undefined' && globalThis.KhaytPluginManifest) || (() => {
    try { return require('./plugin-manifest.js'); } catch (e) { return null; }
  })();
  if (!M) throw new Error('plugin-payload needs plugin-manifest loaded first');

  const PAYLOAD_VERSION = 'plugin-payload-v1';
  const PLACEHOLDER_RE = /\{([a-zA-Z0-9_.]+)\}/g;
  // A secret may sit in a POST URL's path (a Slack or Discord webhook IS its
  // secret). It is pasted unencoded, so it may only be characters that cannot
  // change where the URL points.
  const SECRET_IN_URL_RE = /^[A-Za-z0-9._~-]+(\/[A-Za-z0-9._~-]+)*$/;

  function isObj(v) { return !!v && typeof v === 'object' && !Array.isArray(v); }

  /** The value a plugin's own field holds on a record. */
  function fieldValue(record, pluginId, key) {
    const p = isObj(record) && isObj(record.plugins) && isObj(record.plugins[pluginId]) ? record.plugins[pluginId] : null;
    return p && p[key] !== undefined ? p[key] : null;
  }

  /**
   * One reference, read from the records it names. `ctx` is
   * { order, customer } — the customer is the order's client record, resolved
   * by the caller from `clients[]` by `clientId`.
   */
  function valueOf(manifest, ref, ctx) {
    const c = ctx || {};
    if (ref.startsWith('config.')) {
      // What the shop typed into the connector's settings (`entry.config`,
      // handed in as ctx.config). Checked against the setting's type and
      // capped: a value of the wrong shape, or a pasted blob, is unset.
      const key = ref.slice(7);
      const st = (manifest.settings || []).find(x => x.key === key);
      const v = st && isObj(c.config) ? c.config[key] : undefined;
      if (!st || v === undefined || v === null || v === '') return null;
      switch (st.type) {
        case 'number': return typeof v === 'number' && Number.isFinite(v) ? v : null;
        case 'bool': return typeof v === 'boolean' ? v : null;
        case 'enum': return (st.options || []).some(o => o.value === v) ? v : null;
        default: return typeof v === 'string' && v.length <= M.LIMITS.settingValue ? v : null;
      }
    }
    if (ref.startsWith('field.')) {
      const key = ref.slice(6);
      const f = (manifest.fields || []).find(x => x.key === key);
      if (!f) return null;
      return fieldValue(c[f.attach], manifest.id, key);
    }
    const s = M.SENDABLE_FIELDS[ref];
    if (!s) return null;
    const rec = c[s.from];
    let v = isObj(rec) ? rec[s.path] : undefined;
    const blank = (x) => x === undefined || x === null || String(x).trim() === '';
    // WHERE THE BOOK REALLY KEEPS THEM. The customer editors in all three
    // apps save `nameEn`/`nameAr` and an address book `addresses[]` of
    // {label, address}; a plain `name` and `address` exist only on CSV
    // imports and older records. Reading `path` alone sent null for nearly
    // every customer (found by the desktop lane, Nov 8 2026). The same
    // order of preference as lib/customer-records.js nameOf.
    if (ref === 'customer.name' && isObj(rec)) {
      for (const k of ['nameEn', 'nameAr', 'name']) if (!blank(rec[k])) { v = rec[k]; break; }
    }
    if (ref === 'customer.address' && blank(v) && isObj(rec) && Array.isArray(rec.addresses)) {
      const first = rec.addresses.find(a => isObj(a) && !blank(a.address));
      if (first) v = first.address;
    }
    // A job typed in without a customer record still has a name on it.
    if (ref === 'customer.name' && blank(v) && isObj(c.order)) v = c.order.client;
    if (v === undefined || v === '') return null;
    if (s.type === 'number') return Number.isFinite(Number(v)) ? Number(v) : null;
    if (typeof v === 'object') return null;
    return v;
  }

  function canonical(v) {
    if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
    if (isObj(v)) return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}';
    return JSON.stringify(v === undefined ? null : v);
  }

  /** A template string filled in. "{ref}" alone keeps the value's type. */
  function fillString(manifest, s, ctx) {
    const whole = /^\{([a-zA-Z0-9_.]+)\}$/.exec(s);
    if (whole) return valueOf(manifest, whole[1], ctx);
    return s.replace(PLACEHOLDER_RE, (_, ref) => {
      const v = valueOf(manifest, ref, ctx);
      return v === null ? '' : String(v);
    });
  }

  function fillTemplate(manifest, t, ctx) {
    if (typeof t === 'string') return fillString(manifest, t, ctx);
    if (Array.isArray(t)) return t.map(x => fillTemplate(manifest, x, ctx));
    if (isObj(t)) {
      const out = {};
      for (const k of Object.keys(t)) out[k] = fillTemplate(manifest, t[k], ctx);
      return out;
    }
    return t;
  }

  function triggerOf(manifest, trigger) {
    const t = trigger || {};
    if (t.action) {
      const a = (manifest.actions || []).find(x => x.id === t.action);
      return a ? { def: a, kind: 'action', id: a.id } : null;
    }
    if (t.event) {
      const e = (manifest.events || []).find(x => x.event === t.event);
      return e ? { def: e, kind: 'event', id: e.event } : null;
    }
    if (t.refresh) {
      return isObj(manifest.refresh) ? { def: manifest.refresh, kind: 'refresh', id: true } : null;
    }
    return null;
  }

  /** The record a trigger's reply is about: a button's placement; an event or a refresh is about a job. */
  function placementOf(t) {
    return t.kind === 'action' ? t.def.placement : 'order';
  }

  /** Every reference a trigger makes: send, URL and template placeholders. */
  function triggerRefs(def) {
    const refs = new Set(Array.isArray(def.send) ? def.send.map(String) : []);
    String(def.url || '').replace(PLACEHOLDER_RE, (_, r) => { refs.add(r); return ''; });
    const walk = (t) => {
      if (typeof t === 'string') t.replace(PLACEHOLDER_RE, (_, r) => { refs.add(r); return ''; });
      else if (Array.isArray(t)) t.forEach(walk);
      else if (isObj(t)) Object.values(t).forEach(walk);
    };
    if (isObj(def.body)) walk(def.body.template);
    return refs;
  }

  function hostOf(url) {
    const m = /^https:\/\/([^/?#{}]+)/.exec(String(url || ''));
    return m ? m[1] : '';
  }

  /**
   * The URL a trigger goes to, filled in. Book values are percent-encoded; a
   * `{secret.x}` is pasted as it is and must be path-safe. The finished URL
   * must still be https to the host the template named, or there is no URL.
   */
  function urlFor(manifest, trigger, ctx) {
    const t = triggerOf(manifest, trigger);
    if (!t) return { ok: false, error: 'no such action or event' };
    const host = hostOf(t.def.url);
    if (!host || !(manifest.domains || []).includes(host)) return { ok: false, error: 'host not declared' };
    const secrets = (ctx && ctx.secrets) || {};
    let error = null;
    const url = t.def.url.replace(PLACEHOLDER_RE, (_, ref) => {
      if (ref.startsWith('secret.')) {
        if (t.kind === 'action' && t.def.kind === 'open') { error = 'a secret cannot go in a link'; return ''; }
        const v = secrets[ref.slice(7)];
        if (typeof v !== 'string' || !v) { error = `secret "${ref.slice(7)}" is not set`; return ''; }
        if (!SECRET_IN_URL_RE.test(v) || v.split('/').includes('..')) { error = `secret "${ref.slice(7)}" is not URL-safe`; return ''; }
        return v;
      }
      const v = valueOf(manifest, ref, ctx);
      return encodeURIComponent(v === null ? '' : String(v));
    });
    if (error) return { ok: false, error };
    let parsed;
    try { parsed = new URL(url); } catch (_) { return { ok: false, error: 'not a URL once filled in' }; }
    if (parsed.protocol !== 'https:' || parsed.host !== host || parsed.username || parsed.password) {
      return { ok: false, error: 'the filled-in URL leaves its declared host' };
    }
    return { ok: true, url };
  }

  /**
   * The request a trigger makes. For an "open" button: just the URL. For a
   * POST: the URL, the body (a string — sign THESE bytes), and what the
   * platform must add from its own keychain: an auth header and/or an
   * HMAC-SHA256 of `body` under `signWith`, sent as X-Khayt-Signature.
   */
  function payloadFor(manifest, trigger, ctx) {
    const t = triggerOf(manifest, trigger);
    if (!t) return { ok: false, error: 'no such action or event' };
    // A required setting this trigger uses and the shop has not filled in:
    // say which, rather than send a request the receiver will refuse.
    for (const st of (manifest.settings || [])) {
      if (st.required && triggerRefs(t.def).has('config.' + st.key) && valueOf(manifest, 'config.' + st.key, ctx) === null) {
        return { ok: false, error: `setting ${st.key} is not set` };
      }
    }
    const u = urlFor(manifest, trigger, ctx);
    if (!u.ok) return u;
    if (t.kind === 'action' && t.def.kind === 'open') return { ok: true, method: 'OPEN', url: u.url };
    const auth = t.def.auth ? { header: t.def.auth.header, scheme: t.def.auth.scheme || '', secret: t.def.auth.secret } : null;
    // A GET refresh carries nothing but its URL (and Khayt's own headers).
    if (t.kind === 'refresh' && t.def.method === 'GET') {
      return { ok: true, method: 'GET', url: u.url, body: '', auth, signWith: t.def.signWith || null };
    }

    const format = (t.def.body && t.def.body.format) || 'khayt-v1';
    let body;
    if (format === 'json-template') {
      body = canonical(fillTemplate(manifest, t.def.body.template, ctx));
    } else {
      const data = {};
      for (const ref of (t.def.send || [])) data[ref] = valueOf(manifest, String(ref), ctx);
      body = canonical({
        khayt: PAYLOAD_VERSION,
        plugin: manifest.id,
        version: manifest.version,
        trigger: { [t.kind]: t.id },
        data,
      });
    }
    return {
      ok: true,
      method: 'POST',
      url: u.url,
      contentType: 'application/json',
      body,
      auth,
      signWith: t.def.signWith || null,
    };
  }

  function readPath(obj, path) {
    let v = obj;
    for (const p of path.split('.')) {
      if (Array.isArray(v) && /^\d+$/.test(p)) v = v[Number(p)];
      else if (isObj(v)) v = v[p];
      else return undefined;
    }
    return v;
  }

  function coerce(f, v) {
    if (v === undefined || v === null) return undefined;
    switch (f.type) {
      case 'number': return Number.isFinite(Number(v)) && typeof v !== 'boolean' ? Number(v) : undefined;
      case 'bool': return typeof v === 'boolean' ? v : undefined;
      case 'date': return typeof v === 'string' && /^\d{4}-\d{2}-\d{2}/.test(v) ? v.slice(0, 10) : undefined;
      case 'enum': return (f.options || []).some(o => o.value === v) ? v : undefined;
      default: return (typeof v === 'string' || typeof v === 'number') ? String(v).slice(0, 500) : undefined;
    }
  }

  /**
   * A reply, mapped into the plugin's own fields: { key: value }. Only the
   * fields the trigger's `response` names, each checked against its type; a
   * value of the wrong shape is dropped, not guessed at. `entry` is the
   * stored `settings.plugins[]` row: nothing is written unless it grants
   * fields.write and is not paused.
   *
   * `trigger` is `{action}`, `{event}` or `{refresh: true}` — or, as before
   * v1.1, a button's id alone.
   */
  function applyResponse(manifest, trigger, reply, entry) {
    const t = triggerOf(manifest, typeof trigger === 'string' ? { action: trigger } : trigger);
    const out = {};
    if (!t || (t.kind === 'action' && t.def.kind === 'open')) return out;
    const a = t.def;
    if (!isObj(a.response) || !isObj(a.response.fields) || !isObj(reply)) return out;
    // The shop granted fields.write, and the grant still covers this manifest.
    if (!M.mayWriteFields(entry)) return out;
    const placement = placementOf(t);
    for (const [key, path] of Object.entries(a.response.fields)) {
      const f = (manifest.fields || []).find(x => x.key === key && x.attach === placement);
      if (!f) continue;
      const v = coerce(f, readPath(reply, String(path)));
      if (v !== undefined) out[key] = v;
    }
    return out;
  }

  const api = { PAYLOAD_VERSION, payloadFor, urlFor, applyResponse, valueOf, fieldValue };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPluginPayload = api;
})();
