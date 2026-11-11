'use strict';

/**
 * The connector update sheet: what a waiting update asks for, in the order
 * every app shows it (Electron Figma 52:2434, from the Mac's 70:284).
 *
 *   1. NEW IN THIS VERSION — host by host, each line tagged:
 *        `new`        a field (or key) the shop never agreed to send anywhere
 *        `new_place`  one it agreed to, now sent to a host it never went to
 *      then a new host that receives nothing (a link), new scopes, and a
 *      refresh it never agreed to (or a more frequent one).
 *   2. ALREADY AGREED — what the new version still sends that the grant
 *      already covers, host by host, quieter.
 *
 * Read against the entry's GRANT (what the shop agreed to), not the stored
 * diff: the diff was taken when the update was offered, and the shop may have
 * agreed to something else since. Pure — no DOM, no i18n; the window words it.
 *
 *   sheetFor(entry, pending) → {
 *     id, from, to, asksMore,
 *     fresh:  [{ host, items: [{ kind: 'field'|'secret'|'link', key, tag }] }],
 *     scopes: [scope, …],          // new ones
 *     refresh: minutes | 0,        // a refresh it asks for anew
 *     agreed: [{ host, items: [{ kind, key }] }],
 *   } | null
 */
(function () {
  const G = typeof globalThis !== 'undefined' ? globalThis : {};
  const manifestLib = () => G.KhaytPluginManifest || (typeof require === 'function' ? (() => {
    try { return require('./plugin-manifest.js'); } catch (_) { return null; }
  })() : null);

  const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);

  /** "host ref" → [host, ref]. A host never holds a space. */
  const split = (route) => {
    const i = route.indexOf(' ');
    return i < 0 ? [route, ''] : [route.slice(0, i), route.slice(i + 1)];
  };

  function sheetFor(entry, pending) {
    const M = manifestLib();
    if (!M || !isObj(entry) || !isObj(pending) || !isObj(pending.manifest)) return null;
    const manifest = pending.manifest;
    const g = isObj(entry.granted) ? entry.granted : {};
    const diff = M.diffPermissions(g, manifest);
    const grantedFields = new Set(Array.isArray(g.fields) ? g.fields : []);
    const legacy = !Array.isArray(g.routes);
    const grantedSecrets = new Set();
    for (const r of (legacy ? [] : g.routes)) {
      const ref = split(String(r))[1];
      if (ref.startsWith('secret:')) grantedSecrets.add(ref.slice(7));
    }
    const movedRoutes = new Set(diff.routes);
    const newHosts = new Set(diff.domains);

    const fresh = new Map();
    const agreed = new Map();
    const add = (map, host, item) => {
      if (!map.has(host)) map.set(host, []);
      map.get(host).push(item);
    };
    for (const route of M.routesOf(manifest)) {
      const [host, ref] = split(route);
      if (ref.startsWith('secret:')) {
        const name = ref.slice(7);
        if (!movedRoutes.has(route)) { add(agreed, host, { kind: 'secret', key: name }); continue; }
        const known = legacy ? (Array.isArray(g.domains) && g.domains.length > 0) : grantedSecrets.has(name);
        add(fresh, host, { kind: 'secret', key: name, tag: known ? 'new_place' : 'new' });
        continue;
      }
      if (!grantedFields.has(ref)) add(fresh, host, { kind: 'field', key: ref, tag: 'new' });
      else if (movedRoutes.has(route)) add(fresh, host, { kind: 'field', key: ref, tag: 'new_place' });
      else add(agreed, host, { kind: 'field', key: ref });
    }
    // A host that is sent nothing from the book (an "open" link) still gets
    // a line: the shop is still sent there.
    for (const row of M.consentRows(manifest)) {
      if (row.fields.length) continue;
      if (fresh.has(row.host) || agreed.has(row.host)) continue;
      if (newHosts.has(row.host)) add(fresh, row.host, { kind: 'link', key: '', tag: 'new' });
      else add(agreed, row.host, { kind: 'link', key: '' });
    }
    // Within a host: new before new place, then by key — the same every time.
    const order = { new: 0, new_place: 1 };
    const rows = (map, tagged) => Array.from(map.keys()).sort().map((host) => ({
      host,
      items: map.get(host).slice().sort((a, b) => (tagged ? order[a.tag] - order[b.tag] : 0)
        || (a.kind === b.kind ? 0 : a.kind === 'field' ? -1 : 1) || a.key.localeCompare(b.key)),
    }));
    return {
      id: entry.id,
      from: String(entry.version || ''),
      to: String(pending.version || manifest.version || ''),
      asksMore: !!diff.widened,
      fresh: rows(fresh, true),
      scopes: diff.scopes.slice(),
      refresh: diff.refresh ? (M.refreshEvery(manifest) || 0) : 0,
      agreed: rows(agreed, false),
    };
  }

  /**
   * Whether this connector has an update waiting for the shop's yes: a
   * pending version newer than the one installed. A pending version the
   * entry has already reached (installed by hand since) is not waiting.
   */
  function waitingFor(entry, state, compareVersions) {
    if (!isObj(entry) || !isObj(state) || !isObj(state.pending) || !isObj(state.pending.manifest)) return null;
    const cmp = typeof compareVersions === 'function' ? compareVersions : null;
    if (cmp && cmp(String(state.pending.version), String(entry.version)) <= 0) return null;
    if (!cmp && String(state.pending.version) === String(entry.version)) return null;
    return state.pending;
  }

  const api = { sheetFor, waitingFor };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPluginUpdateSheet = api;
})();
