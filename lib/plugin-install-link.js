'use strict';
/**
 * `khayt://plugin/install?id=<connector id>&version=<version>` — "Install in
 * Khayt" on a connector's page in the directory (plugin-directory-design.md
 * 3.6). The desktop's reading of the link the Mac reads in
 * PluginInstallLink.swift; test/fixtures/plugin-install-link-vectors.json
 * holds the cases both are held to.
 *
 * ── THE LINK NAMES A CONNECTOR; IT INSTALLS NOTHING ──────────────────────
 *
 * A web page can open a khayt:// link, so the link carries only an id and a
 * version: no manifest, no address to fetch from, no consent. Khayt reads its
 * OWN signed index for the rest (lib/main/plugin-install-link.js) and opens the
 * same consent sheet as a hand install.
 *
 * Anything that is not exactly this shape is not a link at all: another path,
 * an extra or repeated field, a fragment, a user or port, an id that is not a
 * connector id (lib/plugin-manifest.js ID_RE, at most 100 characters), a
 * version that is not a version.
 *
 * The query is read by hand, not with URLSearchParams: that reads `+` as a
 * space, and a version may carry a `+build` tag, as on the Mac.
 */
(function () {
  const ID_RE = /^[a-z0-9]+(\.[a-z0-9][a-z0-9-]*)+$/;
  const VERSION_RE = /^[0-9]+(\.[0-9]+){0,3}([-+][0-9A-Za-z.-]{1,24})?$/;
  const MAX_ID = 100;
  const MAX_VERSION = 40;
  const MAX_URL = 2048;

  const isId = (s) => typeof s === 'string' && s.length <= MAX_ID && ID_RE.test(s);
  const isVersion = (s) => typeof s === 'string' && s.length <= MAX_VERSION && VERSION_RE.test(s);

  /** `{ id, version }` for a link of exactly this shape, else null. */
  function parse(url) {
    if (typeof url !== 'string' || !url || url.length > MAX_URL) return null;
    if (url.indexOf('#') !== -1) return null;
    const m = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?]*)(\/[^?]*)?(?:\?(.*))?$/.exec(url);
    if (!m) return null;
    const [, scheme, authority, pathPart, query] = m;
    if (scheme.toLowerCase() !== 'khayt') return null;
    // A bare host: no user, password or port.
    if (authority.toLowerCase() !== 'plugin') return null;
    if (pathPart !== '/install') return null;
    if (query === undefined) return null;
    const items = query.split('&');
    if (items.length !== 2) return null;
    const fields = {};
    for (const item of items) {
      const eq = item.indexOf('=');
      const name = eq === -1 ? item : item.slice(0, eq);
      let value;
      try { value = eq === -1 ? '' : decodeURIComponent(item.slice(eq + 1)); } catch (_) { return null; }
      if ((name !== 'id' && name !== 'version') || Object.prototype.hasOwnProperty.call(fields, name)) return null;
      fields[name] = value;
    }
    if (!isId(fields.id) || !isVersion(fields.version)) return null;
    return { id: fields.id, version: fields.version };
  }

  /** Is this argument a khayt:// URL at all (an argv entry, an open-url)? */
  function isKhaytUrl(s) {
    return typeof s === 'string' && /^khayt:\/\//i.test(s);
  }

  /**
   * The URL schemes this build claims at launch. Bed Ready owns `bedready://`
   * and never `khayt://`. Khayt claims `khayt://` only when packaged (a dev
   * run would point the scheme at the bare Electron binary), and not on macOS,
   * where `khayt://` belongs to the native Mac app.
   */
  function protocolSchemes({ isBedReady, isPackaged, platform } = {}) {
    if (isBedReady) return ['bedready'];
    if (!isPackaged || platform === 'darwin') return [];
    return ['khayt'];
  }

  const api = { parse, isId, isVersion, isKhaytUrl, protocolSchemes, MAX_ID, MAX_VERSION };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPluginInstallLink = api;
})();
