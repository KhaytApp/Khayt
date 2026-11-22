'use strict';
/**
 * The plugin and connector directory on khaytapp.com, as data: what a listing
 * may say, what a slicer package record must hold, and the page a listing
 * becomes. Pure (no network, no crypto, no clock); nothing calls it yet.
 * Design: Khayt-proposals plugin-directory-design.md (approved Nov 17 2026).
 *
 * ── THE ONE RULE ──────────────────────────────────────────────────────────
 *
 * The directory is a front door to the trust that already exists, never a
 * second one. Only Khayt's signature makes anything installable: the signed
 * index (lib/plugin-update.js) says which version is current, and the signed
 * manifest (lib/plugin-manifest.js) says what it may do. So:
 *
 *   - A listing describes; it never grants. Its keys are an ALLOWLIST, and a
 *     listing that carries permissions, fields, domains or scopes of its own is
 *     refused: the permissions a page shows are COMPUTED here from the signed
 *     manifest (consentRows, the same rows the app's consent sheet shows), or,
 *     for a slicer package, from the scopes the Mac shows at pairing.
 *   - WHO an item is from is the platform's to say, never the listing's
 *     (security review): the publisher registry that proved the namespace (DNS
 *     or .well-known) and the verified domain is handed to `pageFor` as
 *     `owner`. A listing may not claim a verified domain, and a listing whose id
 *     is not under the owner's namespace is refused, so nobody can appear as
 *     Khayt, or as another vendor beside that vendor's signed download.
 *   - A page joins a listing to an index row and, for a connector, to its
 *     manifest. The caller has already checked the manifest's bytes against the
 *     row's sha256 and its signature (the platform's job); this module checks
 *     that the three agree on id, kind and version, and refuses the page if not.
 *
 * ── TURKI'S DECISIONS (Nov 17) ────────────────────────────────────────────
 *
 *   - Code must publish source: a plugin, an addon and a slicer package need a
 *     `source` URL. Only a data-only item (a connector manifest) may be closed.
 *   - Free only in v1: there is no price key at all.
 *   - Downloads come from khaytapp.com only: a row's url is https on that host.
 *
 * The page's TEXT (name, summary, descriptions, screenshot alt) is the
 * developer's: whatever renders it must escape it. Nothing here is HTML.
 *   - The Arabic description stays optional, now and later.
 *   - Slicer packages are hosted on khaytapp.com, signed into the index.
 *
 * And from the Orca lane: printer control (`printer:send`) does not exist and
 * is never listed; a slicer package that is not yet in the signed index shows
 * as "not released", with nothing to download.
 */
(function () {
  const M = (typeof globalThis !== 'undefined' && globalThis.KhaytPluginManifest) || (() => {
    try { return require('./plugin-manifest.js'); } catch (_) { return null; }
  })();

  const KINDS = ['connector', 'addon', 'plugin', 'slicer'];
  /** Kinds that are code: they must publish source (Turki, Nov 17). */
  const CODE_KINDS = ['addon', 'plugin', 'slicer'];
  /** Kinds the apps can install today; the rest list as "coming". */
  const INSTALLABLE = ['connector'];
  const CATEGORIES = ['shipping', 'payments', 'messaging', 'accounting', 'storefront', 'productivity', 'slicer', 'other'];
  const LISTING_KEYS = ['id', 'kind', 'name', 'publisher', 'summary', 'description', 'descriptionAr', 'category',
    'licence', 'source', 'privacy', 'support', 'screenshots', 'deprecated', 'transferredFrom'];
  /** Keys a listing must never carry: what an item may do is the signed manifest's to say. */
  const GRANTING_KEYS = ['permissions', 'fields', 'domains', 'scopes', 'events', 'actions', 'secrets', 'refresh', 'price', 'signature'];

  /** What a slicer connector may ask the Mac for at pairing (lib/connector-*, LanConnectorPairing). */
  /* What a slicer package may ask for at pairing, as the Mac's connectorScopes()
   * names them (LanServer+Connector.swift). price:read and cost:read are only
   * ever in force while the shop shows prices in the slicer AND has granted that
   * device; the Mac grants cost only on top of price, so a record cannot ask for
   * cost:read alone. Order here is the order the page shows them in. */
  const SLICER_SCOPES = ['slices:send', 'queue:read', 'price:read', 'cost:read'];
  const SLICER_HOSTS = { orca: 'OrcaSlicer' };
  const SLICER_KEYS = ['kind', 'id', 'version', 'host', 'hostVersion', 'package', 'requires', 'scopes', 'hostPermissions', 'source', 'licence'];

  const ID_RE = /^[a-z0-9]+(\.[a-z0-9][a-z0-9-]*)+$/;
  const SEMVER_RE = /^(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,5})$/;
  const SPDX_RE = /^[A-Za-z0-9.+-]{2,40}( (AND|OR|WITH) [A-Za-z0-9.+-]{2,40})*$/;
  const HTTPS_RE = /^https:\/\/[a-z0-9.-]+(?::\d{2,5})?(?:\/[^\s]*)?$/i;
  const HEX64 = /^[0-9a-f]{64}$/;
  const LIMITS = { name: 60, summary: 140, description: 4000, screenshots: 8, alt: 140, hostPermissions: 10 };

  const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
  /** Where a download may come from: https on khaytapp.com, nothing else (no port, no user info). */
  const HOST = 'khaytapp.com';
  function onKhaytapp(url) {
    if (typeof url !== 'string' || !/^https:\/\//.test(url)) return false;
    try { const u = new URL(url); return u.protocol === 'https:' && u.hostname === HOST && !u.port && !u.username && !u.password; } catch (_) { return false; }
  }
  const str = (v) => (typeof v === 'string' ? v : '');
  const text = (v, max) => typeof v === 'string' && v.trim().length > 0 && v.length <= max;

  /**
   * A listing's problems, or [] when it may be shown. A listing is what the
   * developer writes about an item: words, links and pictures, never powers.
   */
  function checkListing(l) {
    const errors = [];
    if (!isObj(l)) return ['a listing is an object'];
    for (const k of Object.keys(l)) {
      if (GRANTING_KEYS.includes(k)) errors.push(`${k}: a listing cannot say what an item may do; that comes from its signed manifest`);
      else if (!LISTING_KEYS.includes(k)) errors.push(`${k}: not a listing key`);
    }
    if (typeof l.id !== 'string' || !ID_RE.test(l.id) || l.id.length > 100) errors.push('id: reverse-DNS in lower case, like "com.example.shipping"');
    if (!KINDS.includes(l.kind)) errors.push(`kind: one of ${KINDS.join(', ')}`);
    if (!text(l.name, LIMITS.name)) errors.push(`name: 1–${LIMITS.name} characters`);
    if (!text(l.summary, LIMITS.summary)) errors.push(`summary: 1–${LIMITS.summary} characters`);
    if (l.description !== undefined && !text(l.description, LIMITS.description)) errors.push(`description: up to ${LIMITS.description} characters`);
    // Optional, now and later (Turki, Nov 17): without it the page shows the English, marked LTR.
    if (l.descriptionAr !== undefined && !text(l.descriptionAr, LIMITS.description)) errors.push(`descriptionAr: up to ${LIMITS.description} characters`);
    if (!CATEGORIES.includes(l.category)) errors.push(`category: one of ${CATEGORIES.join(', ')}`);
    if (typeof l.licence !== 'string' || !SPDX_RE.test(l.licence)) errors.push('licence: an SPDX identifier, like "MIT"');
    const pub = l.publisher;
    if (!isObj(pub) || !text(pub.name, LIMITS.name) || typeof pub.namespace !== 'string' || !ID_RE.test(pub.namespace)) {
      errors.push('publisher: { name, namespace (reverse-DNS) }');
    } else {
      if (typeof l.id === 'string' && !(l.id === pub.namespace || l.id.startsWith(pub.namespace + '.'))) errors.push(`id: must sit under the publisher's namespace "${pub.namespace}"`);
      // Verification is the platform's record (the publisher registry), never the developer's word.
      if (pub.verifiedDomain !== undefined) errors.push('publisher.verifiedDomain: set by Khayt when the domain is proven, never in a listing');
      for (const k of Object.keys(pub)) if (!['name', 'namespace', 'verifiedDomain'].includes(k)) errors.push(`publisher.${k}: not a publisher key`);
    }
    if (CODE_KINDS.includes(l.kind) && !HTTPS_RE.test(str(l.source))) errors.push('source: code must publish its source (an https URL)');
    if (l.source !== undefined && !HTTPS_RE.test(str(l.source))) errors.push('source: an https URL');
    if (l.privacy !== undefined && !HTTPS_RE.test(str(l.privacy))) errors.push('privacy: an https URL to the developer\'s privacy statement');
    if (!HTTPS_RE.test(str(l.support)) && !/^mailto:[^\s@]+@[^\s@]+$/.test(str(l.support))) errors.push('support: an https URL or a mailto: address');
    if (l.screenshots !== undefined) {
      if (!Array.isArray(l.screenshots) || l.screenshots.length > LIMITS.screenshots) errors.push(`screenshots: at most ${LIMITS.screenshots}`);
      else l.screenshots.forEach((s, i) => { if (!isObj(s) || !HTTPS_RE.test(str(s.url)) || !text(s.alt, LIMITS.alt)) errors.push(`screenshots[${i}]: { url (https), alt }`); });
    }
    if (l.deprecated !== undefined && l.deprecated !== true) errors.push('deprecated: true, or absent');
    if (l.transferredFrom !== undefined && !text(l.transferredFrom, LIMITS.name)) errors.push('transferredFrom: the previous publisher\'s name');
    return errors;
  }

  /**
   * A slicer package record's problems, or []: the `kind: "slicer"` row the
   * index carries for a package the slicer installs (design 1). Its sha256 is
   * the only proof of what a download is: Orca checks no signature itself.
   */
  function checkSlicerRecord(r) {
    const errors = [];
    if (!isObj(r)) return ['a slicer record is an object'];
    for (const k of Object.keys(r)) if (!SLICER_KEYS.includes(k)) errors.push(`${k}: not a slicer record key`);
    if (r.kind !== 'slicer') errors.push('kind: "slicer"');
    if (typeof r.id !== 'string' || !ID_RE.test(r.id)) errors.push('id: reverse-DNS in lower case');
    if (typeof r.version !== 'string' || !SEMVER_RE.test(r.version)) errors.push('version: major.minor.patch');
    if (!Object.prototype.hasOwnProperty.call(SLICER_HOSTS, r.host)) errors.push(`host: one of ${Object.keys(SLICER_HOSTS).join(', ')}`);
    if (typeof r.hostVersion !== 'string' || !/^>=\d+\.\d+(\.\d+)?$/.test(r.hostVersion)) errors.push('hostVersion: like ">=2.5.1"');
    const p = r.package;
    if (!isObj(p) || typeof p.name !== 'string' || !/^[a-z0-9][a-z0-9._-]{0,63}$/.test(p.name)
        || typeof p.file !== 'string' || !/^[A-Za-z0-9._+-]{1,128}$/.test(p.file)
        || !HEX64.test(str(p.sha256)) || !Number.isInteger(p.size) || p.size < 1 || p.size > 20 * 1024 * 1024) {
      errors.push('package: { name, file, sha256 (64 hex), size (bytes, at most 20 MB) }');
    } else if (p.version !== undefined) errors.push('package.version: the record\'s own version is the version');
    if (!Array.isArray(r.scopes) || r.scopes.length === 0 || r.scopes.some((s) => !SLICER_SCOPES.includes(s)) || new Set(r.scopes).size !== r.scopes.length) {
      errors.push(`scopes: some of ${SLICER_SCOPES.join(', ')} (printer control does not exist)`);
    } else if (r.scopes.includes('cost:read') && !r.scopes.includes('price:read')) {
      errors.push('scopes: cost:read only with price:read (the Mac grants cost on top of price)');
    }
    if (r.hostPermissions !== undefined && (!Array.isArray(r.hostPermissions) || r.hostPermissions.length > LIMITS.hostPermissions
        || r.hostPermissions.some((h) => typeof h !== 'string' || !/^[a-z_]+(:[A-Za-z0-9._~\/-]{1,120})?$/.test(h)))) {
      errors.push('hostPermissions: what the slicer itself will ask for, like "threading"');
    }
    if (r.requires !== undefined) {
      const k = isObj(r.requires) && r.requires.khayt;
      if (!isObj(k) || Object.keys(k).some((x) => !['mac', 'desktop'].includes(x) || typeof k[x] !== 'string')) errors.push('requires: { khayt: { mac?, desktop? } }');
    }
    if (!HTTPS_RE.test(str(r.source))) errors.push('source: code must publish its source (an https URL)');
    if (typeof r.licence !== 'string' || !SPDX_RE.test(r.licence)) errors.push('licence: an SPDX identifier');
    return errors;
  }

  /**
   * What an item may do, as the page shows it. A connector: the consent
   * sheet's own rows from its signed manifest (`consentRows`), plus its scopes
   * and whether it checks on its own. A slicer package: its pairing scopes, as
   * locale keys whose words the Mac shows (never typed by the developer).
   */
  function permissionsFor(kind, signed) {
    if (kind === 'connector') {
      if (!M) throw new Error('plugin-directory needs plugin-manifest loaded first');
      return {
        sends: M.consentRows(signed),
        scopes: Array.isArray(signed.scopes) ? signed.scopes.slice().sort() : [],
        refreshes: M.refreshEvery(signed) || null,
      };
    }
    if (kind === 'slicer') {
      return {
        pairing: SLICER_SCOPES.filter((s) => signed.scopes.includes(s)),
        hostPermissions: Array.isArray(signed.hostPermissions) ? signed.hostPermissions.slice() : [],
        // What the package MAY be shown, never what it is shown: both need the
        // shop's own switch and a per-device grant on the Mac (default off).
        prices: signed.scopes.includes('cost:read') ? 'cost' : signed.scopes.includes('price:read') ? 'price' : 'none',
        printerControl: false,
      };
    }
    return null;
  }

  /**
   * The page a listing becomes, or `{ error }`. `row` is the item's signed
   * index row (null when it has none yet); `signed` is the verified manifest of
   * that row's version for a connector, or the row itself for a slicer package.
   * States: `listed`, `coming` (a kind the apps cannot install yet),
   * `not-released` (no signed row), `deprecated`, `withdrawn` (the current
   * version is revoked; the reason is shown).
   */
  function pageFor(listing, row, signed, owner) {
    const problems = checkListing(listing);
    if (problems.length) return { error: 'listing', problems };
    // `owner`: the publisher registry's record for this namespace, { namespace, name, verifiedDomain? }.
    // Without it there is no page: the listing alone cannot say who it is from.
    if (!isObj(owner) || typeof owner.namespace !== 'string' || !ID_RE.test(owner.namespace) || !text(owner.name, LIMITS.name)) {
      return { error: 'owner', problems: ['the publisher registry has no owner for this namespace'] };
    }
    if (listing.publisher.namespace !== owner.namespace || !(listing.id === owner.namespace || listing.id.startsWith(owner.namespace + '.'))) {
      return { error: 'owner', problems: [`"${listing.id}" belongs to another publisher`] };
    }
    const page = {
      id: listing.id, kind: listing.kind, name: listing.name, summary: listing.summary,
      description: listing.description || null,
      descriptionAr: listing.descriptionAr || null,
      // Without its own Arabic, the AR page shows the English, marked as such (lang="en" dir="ltr").
      descriptionArFallback: !listing.descriptionAr,
      category: listing.category, licence: listing.licence,
      publisher: { name: owner.name, namespace: owner.namespace, verifiedDomain: typeof owner.verifiedDomain === 'string' ? owner.verifiedDomain : null },
      source: listing.source || null, privacy: listing.privacy || null, support: listing.support,
      screenshots: (listing.screenshots || []).map((s) => ({ url: s.url, alt: s.alt })),
      transferredFrom: listing.transferredFrom || null,
      free: true,
      version: null, permissions: null, download: null, state: 'listed', withdrawnReason: null,
    };
    if (!row) {
      page.state = listing.kind === 'slicer' ? 'not-released' : (INSTALLABLE.includes(listing.kind) ? 'not-released' : 'coming');
      return page;
    }
    if (!isObj(row) || row.id !== listing.id || row.kind !== listing.kind) return { error: 'mismatch', problems: ['the index row is for another item'] };
    if (row.url !== undefined && !onKhaytapp(row.url)) return { error: 'row-url', problems: ['a row\'s url is https on khaytapp.com'] };
    if (listing.kind === 'slicer') {
      const bad = checkSlicerRecord(signed);
      if (bad.length) return { error: 'slicer-record', problems: bad };
      if (signed.kind !== row.kind || (signed !== row && (signed.id !== row.id || signed.version !== row.version))) return { error: 'mismatch', problems: ['the slicer record is for another version'] };
      page.download = { file: signed.package.file, sha256: signed.package.sha256, size: signed.package.size, url: str(row.url) || null };
      page.worksIn = { host: SLICER_HOSTS[signed.host], hostVersion: signed.hostVersion, pairedWith: 'mac' };
    } else if (listing.kind === 'connector') {
      // A connector manifest names no kind of its own (the validator refuses the key), so it is a
      // connector by being one; anything that says otherwise is not this row's manifest.
      if (!isObj(signed) || (signed.kind !== undefined && signed.kind !== row.kind) || signed.id !== row.id || signed.version !== row.version) {
        return { error: 'mismatch', problems: ['the manifest is not the index row\'s version'] };
      }
      page.worksIn = { install: ['mac', 'desktop'], runs: ['mac', 'desktop', 'ios'] };
    } else {
      page.state = 'coming';
    }
    page.version = row.version;
    page.permissions = page.state === 'coming' ? null : permissionsFor(listing.kind, signed);
    const revoked = Array.isArray(row.revoked) ? row.revoked.find((x) => isObj(x) && x.version === row.version) : null;
    if (revoked) {
      page.state = 'withdrawn';
      page.withdrawnReason = str(revoked.reason) || null;
      page.download = null;
    } else if (listing.deprecated === true) page.state = 'deprecated';
    return page;
  }

  const api = { HOST, onKhaytapp, KINDS, CODE_KINDS, INSTALLABLE, CATEGORIES, LISTING_KEYS, GRANTING_KEYS, SLICER_SCOPES, SLICER_HOSTS, SLICER_KEYS, LIMITS,
    checkListing, checkSlicerRecord, permissionsFor, pageFor };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPluginDirectory = api;
})();
