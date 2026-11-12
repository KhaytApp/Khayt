'use strict';

/**
 * Connector updates: one signed index on khaytapp.com, and what a device does
 * with it. Turki's rules (Nov 10, 2026):
 *
 *   - An update that sends nothing beyond what the shop agreed to (the same
 *     fields, domains, scopes and refresh — `diffPermissions(...).widened`
 *     false) installs BY ITSELF on the Mac and the desktop, with a quiet
 *     "updated to 1.1.1 · Revert" note.
 *   - An update that asks for more waits for the shop's yes, and the version it
 *     has KEEPS RUNNING until then. "Not now" asks again only for a newer
 *     version; the badge stays.
 *   - A version Khayt withdraws (`revoked`) is paused on every device, and says
 *     why — the one case a running connector stops without the shop's word.
 *   - A JS plugin (`kind: "plugin"`, phase 3) never updates by itself, even
 *     asking for nothing new, until there is a sandbox. An addon follows the
 *     connector rules.
 *
 * ── WHERE THE STATE LIVES ─────────────────────────────────────────────────
 * NOT on the connector's entry. `checkEntry` refuses an entry with a key it
 * does not know, so a `previous` written onto an entry would turn Lamha
 * invalid on every build that shipped before this file — beta.33, the
 * desktop, every phone in the field. The entry only ever changes the way
 * those builds already accept (a new manifest, version, grant or switch), and
 * the rest is beside it:
 *
 *   settings.connectorUpdates = {
 *     serial,                                   // highest index serial VERIFIED
 *     connectors: { [id]: {
 *       previous?:  { version, manifest, granted },   // Revert, and the fallback
 *       pending?:   { version, manifest, diff, offeredAt },
 *       revoked?:   { version, reason, at, wasEnabled },
 *       skipped?:   [version, …],               // reverted: never auto again
 *       updatedAt?, updatedFrom?,               // the quiet note (ISO, version)
 *       previousWithdrawn?,                     // version: why there is no Revert
 *     } } }
 *
 * Old builds leave an unknown settings key alone (the Mac writes settings by
 * key over what is on disk; the desktop window keeps what it loaded). A
 * revocation also sets the entry's own `enabled: false`, which every build
 * already honours, so a phone that has never heard of this file stops too.
 *
 * ── TRUST ─────────────────────────────────────────────────────────────────
 * PURE, and it does no cryptography (the Mac's JavaScriptCore has none). The
 * platform verifies the index signature over `indexSigningMessage(index)` and
 * says who signed it (`ctx.signedBy`), and verifies every downloaded manifest
 * — sha256 of the bytes, then the manifest's own signature — before handing it
 * here. The index only says WHICH version is current; what a connector may do
 * is still only what Khayt signed in the manifest itself.
 *
 * An index that cannot be trusted — unreadable, unsigned, an older serial than
 * one already seen, expired, or issued in the future — FAILS SAFE: nothing
 * at all changes, the settings come back as the very same object, and every
 * connector keeps running as it is.
 *
 * ── THREE THINGS THE FIRST REVIEW FOUND (Nov 11) ──────────────────────────
 * Each was a way round the rules above, and each is pinned by a test:
 *
 *   - A WITHDRAWN VERSION IS NEVER KEPT. The version an update replaces is
 *     kept as `previous` for Revert and for a device too old to read the new
 *     one — unless that version is withdrawn, when keeping it would let it
 *     run again by either road. A withdrawn version is not kept (no Revert is
 *     offered), a `previous` or `pending` the index later withdraws is
 *     dropped, and `revert` and `runnable` refuse one all the same.
 *   - THE SERIAL IS REMEMBERED WHENEVER IT RISES, not only when something
 *     else changed. Otherwise a device that read serial 10 and had nothing to
 *     do would accept serial 9 again tomorrow, and with it a version
 *     withdrawn in between. So a check that changes nothing else still writes
 *     `serial` — once per new index, never for the same one twice.
 *   - A GRANT FROM BEFORE PAIRS WERE KEPT (no `routes`) is read, for an
 *     update, as what the INSTALLED manifest really sends — not as every
 *     field to every host it lists — and the automatic update writes those
 *     pairs into the grant, so it is an old grant only once.
 *
 * And one found while fixing them: an automatic update to a version that
 * sends LESS left the grant listing a field the new manifest no longer has,
 * which `checkEntry` refuses — the connector went invalid on every device.
 * The grant is now narrowed to what the new manifest still declares (never
 * widened; Revert puts the old grant back).
 */
(function () {
  const G = typeof globalThis !== 'undefined' ? globalThis : {};
  const lazy = (name, file) => () => G[name] || (typeof require === 'function' ? (() => {
    try { return require(file); } catch (_) { return null; }
  })() : null);
  const manifestLib = lazy('KhaytPluginManifest', './plugin-manifest.js');
  const hostLib = lazy('KhaytPluginHost', './plugin-host.js');

  /** Prepended to the index's canonical JSON before signing: an index
   *  signature can never pass as a manifest's, nor the other way round. */
  const INDEX_CONTEXT = 'khayt-index-v1\n';
  const INDEX_FORMAT = 1;
  /** The manifest format this build reads (`khayt.manifest`): what a device
   *  passes as `ctx.schema`, and what a row's `requires.schema` is held to.
   *  One number here, so no platform types its own. */
  const SCHEMA = 1;
  const KINDS = ['connector', 'plugin', 'addon'];
  /** The index is re-signed every RESIGN_DAYS and good for EXPIRY_DAYS. */
  const EXPIRY_DAYS = 45;
  const RESIGN_DAYS = 30;
  /** A clock this far behind the signer's is still believed. */
  const CLOCK_SLACK_MS = 24 * 3600 * 1000;
  const REASON_MAX = 200;

  const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
  const str = (v) => (typeof v === 'string' ? v : '');
  const iso = (ms) => new Date(ms).toISOString();
  const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

  /* ── VERSIONS ─────────────────────────────────────────────────────────── */

  /**
   * Semver order, field by field: "1.10.0" is newer than "1.9.9", and a
   * pre-release ("1.1.0-beta.2") is older than its release. Plain digits (the
   * phone's build number, 202611101200) compare as one number. Never a string
   * comparison.
   */
  function compareVersions(a, b) {
    const parse = (v) => {
      const s = String(v == null ? '' : v).trim();
      const [core, pre] = s.split('-', 2);
      return { core: core.split('.').map((x) => (/^\d+$/.test(x) ? Number(x) : NaN)), pre: pre === undefined ? null : pre };
    };
    const x = parse(a); const y = parse(b);
    const n = Math.max(x.core.length, y.core.length);
    for (let i = 0; i < n; i += 1) {
      const p = x.core[i] === undefined ? 0 : x.core[i];
      const q = y.core[i] === undefined ? 0 : y.core[i];
      if (Number.isNaN(p) || Number.isNaN(q)) return String(a).localeCompare(String(b));
      if (p !== q) return p < q ? -1 : 1;
    }
    if (x.pre === y.pre) return 0;
    if (x.pre === null) return 1;
    if (y.pre === null) return -1;
    const xp = x.pre.split('.'); const yp = y.pre.split('.');
    for (let i = 0; i < Math.max(xp.length, yp.length); i += 1) {
      if (xp[i] === undefined) return -1;
      if (yp[i] === undefined) return 1;
      const xn = /^\d+$/.test(xp[i]); const yn = /^\d+$/.test(yp[i]);
      if (xn && yn && Number(xp[i]) !== Number(yp[i])) return Number(xp[i]) < Number(yp[i]) ? -1 : 1;
      if (xn !== yn) return xn ? -1 : 1;
      if (!xn && xp[i] !== yp[i]) return xp[i] < yp[i] ? -1 : 1;
    }
    return 0;
  }

  /* ── THE INDEX ────────────────────────────────────────────────────────── */

  /** The exact bytes the index signature covers (`signature` left out). */
  function indexSigningMessage(index) {
    return INDEX_CONTEXT + manifestLib().canonicalJSON(index);
  }

  /** What a well-formed index row looks like; null when it does. */
  function rowProblem(r) {
    if (!isObj(r)) return 'a row is an object';
    if (!KINDS.includes(r.kind)) return null;  // a later kind: ignored, not an error
    if (!str(r.id) || !str(r.version)) return 'a row has an id and a version';
    if (!/^https:\/\//.test(str(r.url))) return `${r.id}: url is https`;
    if (!/^[0-9a-f]{64}$/.test(str(r.sha256))) return `${r.id}: sha256 is 64 hex digits`;
    if (r.requires !== undefined && !isObj(r.requires)) return `${r.id}: requires is an object`;
    if (r.revoked !== undefined && !(Array.isArray(r.revoked) && r.revoked.every((x) => isObj(x) && str(x.version)))) {
      return `${r.id}: revoked is a list of { version, reason }`;
    }
    return null;
  }

  /**
   * May this index be acted on? `{ ok, reason }`. `ctx`: `{ signedBy` — the
   * key id the platform verified the signature with, or null — `, lastSerial,
   * nowMs }`. Reasons: `unreadable`, `unsigned`, `old_serial`, `expired`,
   * `from_future`. The same serial again is fine: it is the same index.
   */
  function checkIndex(index, ctx) {
    const c = isObj(ctx) ? ctx : {};
    if (!isObj(index) || index.khaytIndex !== INDEX_FORMAT || !Array.isArray(index.entries)
        || !Number.isInteger(index.serial) || index.serial < 1) return { ok: false, reason: 'unreadable' };
    const issued = Date.parse(index.issuedAt); const expires = Date.parse(index.expires);
    if (!Number.isFinite(issued) || !Number.isFinite(expires) || expires <= issued) return { ok: false, reason: 'unreadable' };
    if (index.entries.some((r) => rowProblem(r) !== null)) return { ok: false, reason: 'unreadable' };
    if (!str(c.signedBy)) return { ok: false, reason: 'unsigned' };
    if (Number.isInteger(c.lastSerial) && index.serial < c.lastSerial) return { ok: false, reason: 'old_serial' };
    const now = typeof c.nowMs === 'number' ? c.nowMs : NaN;
    if (!Number.isFinite(now)) return { ok: false, reason: 'unreadable' };
    if (now >= expires) return { ok: false, reason: 'expired' };
    if (issued > now + CLOCK_SLACK_MS) return { ok: false, reason: 'from_future' };
    return { ok: true, reason: null };
  }

  /** This connector's row, or null. */
  function rowFor(index, id, kind) {
    const k = kind || 'connector';
    return (isObj(index) && Array.isArray(index.entries) ? index.entries : [])
      .find((r) => isObj(r) && r.kind === k && r.id === id) || null;
  }

  /* ── THE STATE BESIDE THE ENTRIES ─────────────────────────────────────── */

  function stateOf(settings, id) {
    const u = isObj(settings) && isObj(settings.connectorUpdates) ? settings.connectorUpdates : {};
    const all = isObj(u.connectors) ? u.connectors : {};
    return isObj(all[id]) ? all[id] : {};
  }

  function lastSerial(settings) {
    const u = isObj(settings) && isObj(settings.connectorUpdates) ? settings.connectorUpdates : {};
    return Number.isInteger(u.serial) ? u.serial : null;
  }

  /* ── WHAT TO DO ───────────────────────────────────────────────────────── */

  /** The row's revocation of this version, if any. */
  function revocationOf(row, version) {
    const hit = (row && Array.isArray(row.revoked) ? row.revoked : []).find((x) => x.version === version);
    if (!hit) return null;
    const reason = String(hit.reason == null ? '' : hit.reason).replace(/\s+/g, ' ').trim();
    return { version, reason: Array.from(reason).slice(0, REASON_MAX).join('') };
  }

  /**
   * What one installed connector should do about its index row, BEFORE any
   * download: `{ plan }` where plan is
   *   `none`     nothing (no row, not newer, skipped, already offered),
   *   `revoke`   this version is withdrawn (`reason`) — pause it,
   *   `blocked`  newer exists but needs a newer app or schema (`needs`),
   *   `fetch`    download `url`, check `sha256`, then `planWithManifest`.
   * `ctx`: `{ platform: 'mac' | 'desktop' | 'ios', appVersion, schema }`.
   */
  function planUpdate(entry, state, row, ctx) {
    const c = isObj(ctx) ? ctx : {};
    const s = isObj(state) ? state : {};
    if (!isObj(entry) || !row) return { plan: 'none', reason: 'not_listed' };
    const rev = revocationOf(row, entry.version);
    if (rev && !(isObj(s.revoked) && s.revoked.version === entry.version)) return Object.assign({ plan: 'revoke' }, rev);
    if (compareVersions(row.version, entry.version) <= 0) return { plan: 'none', reason: 'current' };
    if (Array.isArray(s.skipped) && s.skipped.includes(row.version)) return { plan: 'none', reason: 'skipped' };
    if (isObj(s.pending) && s.pending.version === row.version) return { plan: 'none', reason: 'offered' };
    if (revocationOf(row, row.version)) return { plan: 'none', reason: 'withdrawn' };
    const req = isObj(row.requires) ? row.requires : {};
    if (Number.isInteger(req.schema) && req.schema > (Number(c.schema) || 1)) {
      return { plan: 'blocked', version: row.version, needs: { schema: req.schema } };
    }
    const need = c.platform && req[c.platform] !== undefined ? String(req[c.platform]) : '';
    if (need && compareVersions(String(c.appVersion || '0'), need) < 0) {
      return { plan: 'blocked', version: row.version, needs: { app: need } };
    }
    return { plan: 'fetch', version: row.version, url: row.url, sha256: row.sha256, size: row.size || null };
  }

  /**
   * The entry's grant with its pairs. A grant made before pairs were kept has
   * no `routes`; read flat, it allows every field it lists to every host it
   * lists and any key to any of them, so a two-host connector could move the
   * customer's phone from one company to the other and install by itself.
   * What the shop was SHOWN is what the installed manifest sends, so those
   * are its pairs — held to the fields and hosts the grant lists, in case the
   * installed manifest already asks for more than was agreed.
   */
  function grantWithPairs(entry) {
    const g = isObj(entry && entry.granted) ? entry.granted : null;
    if (!g || Array.isArray(g.routes)) return g;
    const fields = new Set(Array.isArray(g.fields) ? g.fields : []);
    const hosts = new Set(Array.isArray(g.domains) ? g.domains : []);
    const sent = isObj(entry.manifest) ? manifestLib().permissionsOf(entry.manifest).routes : [];
    const routes = sent.filter((r) => {
      const at = r.indexOf(' ');
      const what = r.slice(at + 1);
      return hosts.has(r.slice(0, at)) && (what.startsWith('secret:') || fields.has(what));
    });
    return Object.assign({}, g, { routes });
  }

  /**
   * The grant an automatic update leaves: what the shop agreed to, with its
   * pairs (`grantWithPairs`), less anything the new manifest no longer
   * declares — `checkEntry` refuses a grant that lists what the manifest does
   * not. Never more than was granted; the very same object when nothing has
   * to change.
   */
  function grantAfterAuto(entry, manifest) {
    const g = grantWithPairs(entry);
    if (!g) return entry.granted;
    const declared = manifestLib().permissionsOf(manifest);
    const out = Object.assign({}, g);
    let same = g === entry.granted;
    for (const k of ['fields', 'domains', 'scopes', 'routes']) {
      if (!Array.isArray(g[k])) continue;
      const kept = g[k].filter((x) => declared[k].includes(x));
      if (kept.length !== g[k].length) { out[k] = kept; same = false; }
    }
    return same ? entry.granted : out;
  }

  /** Is `version` the one this connector's state records as withdrawn? */
  function knownRevoked(state, version) {
    return isObj(state) && isObj(state.revoked) && state.revoked.version === version;
  }

  /**
   * With the new manifest in hand — VERIFIED by the platform (sha256, then its
   * signature) — what to do: `auto`, `needs_setup`, `consent` or `none`.
   * `none` with `reason` `mismatch` or `invalid` when the manifest is not the
   * one the row promised, or does not validate here.
   */
  function planWithManifest(entry, manifest, row) {
    const M = manifestLib();
    if (!isObj(manifest) || manifest.id !== entry.id || manifest.version !== row.version) return { plan: 'none', reason: 'mismatch' };
    if (!M.validateManifest(manifest).ok) return { plan: 'none', reason: 'invalid' };
    const diff = M.diffPermissions(grantWithPairs(entry), manifest);
    if (row.kind === 'plugin' || diff.widened) return { plan: 'consent', version: row.version, diff };
    const config = isObj(entry.config) ? entry.config : {};
    const missing = (Array.isArray(manifest.settings) ? manifest.settings : [])
      .filter((st) => isObj(st) && st.required && (config[st.key] === undefined || config[st.key] === null || config[st.key] === ''))
      .map((st) => st.key);
    if (missing.length) return { plan: 'needs_setup', version: row.version, missing };
    return { plan: 'auto', version: row.version };
  }

  /* ── WRITING IT DOWN ──────────────────────────────────────────────────── */

  /** The entry's settings, without any the manifest no longer declares
   *  (checkEntry refuses a setting the manifest does not have). */
  function configFor(config, manifest) {
    const keys = new Set((Array.isArray(manifest && manifest.settings) ? manifest.settings : []).filter(isObj).map((s) => s.key));
    const out = {};
    for (const [k, v] of Object.entries(isObj(config) ? config : {})) if (keys.has(k)) out[k] = v;
    return out;
  }

  /** settings with one entry and one state replaced — new objects, never edits. */
  function withBoth(settings, entry, state, serial) {
    const next = Object.assign({}, settings);
    if (entry) next.plugins = hostLib().withEntry(settings.plugins, entry);
    const u = isObj(settings.connectorUpdates) ? settings.connectorUpdates : {};
    const all = Object.assign({}, isObj(u.connectors) ? u.connectors : {});
    if (state !== undefined && entry) {
      const tidy = {};
      for (const [k, v] of Object.entries(state)) if (v !== undefined && v !== null) tidy[k] = v;
      if (Object.keys(tidy).length) all[entry.id] = tidy; else delete all[entry.id];
    }
    const nu = Object.assign({}, u, { connectors: all });
    if (Number.isInteger(serial)) nu.serial = Math.max(serial, Number.isInteger(u.serial) ? u.serial : 0);
    next.connectorUpdates = nu;
    return next;
  }

  /** The switch as the shop had it before a revocation turned it off. */
  function unrevoked(entry, state) {
    if (!isObj(state.revoked)) return entry;
    return Object.assign({}, entry, { enabled: state.revoked.wasEnabled !== false });
  }

  /**
   * Apply one plan. `plan` is planUpdate's or planWithManifest's; `manifest`
   * the verified new one for auto / needs_setup / consent. Returns `{
   * settings, note }` — `note` `{ id, kind: 'updated'|'needs_setup'|'pending'|
   * 'revoked'|'blocked', from, to, reason }` for the device to show, or null.
   */
  function applyPlan(settings, id, plan, manifest, ctx) {
    const c = isObj(ctx) ? ctx : {};
    const now = typeof c.nowMs === 'number' ? c.nowMs : Date.now();
    const s0 = isObj(settings) ? settings : {};
    const entry = (Array.isArray(s0.plugins) ? s0.plugins : []).find((p) => isObj(p) && p.id === id);
    if (!entry || !plan) return { settings: s0, note: null };
    const state = clone(stateOf(s0, id));
    switch (plan.plan) {
      case 'revoke': {
        state.revoked = { version: entry.version, reason: plan.reason || '', at: iso(now),
                          wasEnabled: entry.enabled !== false };
        const off = Object.assign({}, entry, { enabled: false });
        return { settings: withBoth(s0, off, state), note: { id, kind: 'revoked', from: entry.version, to: null, reason: plan.reason || '' } };
      }
      case 'auto':
      case 'needs_setup': {
        const H = hostLib();
        // A withdrawn version is never kept: not for Revert, not as a fallback.
        if (knownRevoked(state, entry.version)) { delete state.previous; state.previousWithdrawn = entry.version; }
        else { state.previous = { version: entry.version, manifest: entry.manifest, granted: entry.granted }; delete state.previousWithdrawn; }
        state.updatedAt = iso(now);
        state.updatedFrom = entry.version;
        if (isObj(state.pending) && compareVersions(state.pending.version, manifest.version) <= 0) delete state.pending;
        const next = unrevoked(Object.assign(H.updatedEntry(entry, manifest),
                                             { granted: grantAfterAuto(entry, manifest), config: configFor(entry.config, manifest) }), state);
        delete state.revoked;
        return { settings: withBoth(s0, next, state),
                 note: { id, kind: plan.plan === 'auto' ? 'updated' : 'needs_setup', from: entry.version, to: manifest.version,
                         missing: plan.missing || [] } };
      }
      case 'consent': {
        state.pending = { version: manifest.version, manifest, diff: plan.diff, offeredAt: iso(now) };
        return { settings: withBoth(s0, entry, state), note: { id, kind: 'pending', from: entry.version, to: manifest.version } };
      }
      case 'blocked':
        return { settings: s0, note: { id, kind: 'blocked', from: entry.version, to: plan.version, needs: plan.needs } };
      default:
        return { settings: s0, note: null };
    }
  }

  /**
   * The shop said yes to what is pending: the new manifest, granted exactly
   * what the sheet showed (`consentedEntry`), the old one kept for Revert.
   */
  function agree(settings, id, ctx) {
    const c = isObj(ctx) ? ctx : {};
    const now = typeof c.nowMs === 'number' ? c.nowMs : Date.now();
    const s0 = isObj(settings) ? settings : {};
    const entry = (Array.isArray(s0.plugins) ? s0.plugins : []).find((p) => isObj(p) && p.id === id);
    const state = clone(stateOf(s0, id));
    if (!entry || !isObj(state.pending) || !isObj(state.pending.manifest)) return { ok: false, settings: s0 };
    const manifest = state.pending.manifest;
    if (knownRevoked(state, entry.version)) { delete state.previous; state.previousWithdrawn = entry.version; }
    else { state.previous = { version: entry.version, manifest: entry.manifest, granted: entry.granted }; delete state.previousWithdrawn; }
    state.updatedAt = iso(now);
    state.updatedFrom = entry.version;
    delete state.pending;
    const next = unrevoked(Object.assign(hostLib().consentedEntry(entry, manifest), { config: configFor(entry.config, manifest) }), state);
    delete state.revoked;
    return { ok: true, settings: withBoth(s0, next, state) };
  }

  /**
   * Back to the version before the last update. That version is remembered as
   * skipped, so tomorrow's check does not install it again; a newer one will.
   * `{ ok: false }` when there is nothing to go back to — which includes a
   * previous version that was withdrawn.
   *
   * WHY THERE IS NOTHING TO GO BACK TO is `previousWithdrawn` on the
   * connector's state: the version Khayt withdrew, set wherever a `previous`
   * is dropped or not kept for that reason (an update away from a withdrawn
   * version, or `withoutWithdrawn` at a later check) and cleared by the next
   * update that does keep one and by a Revert. A device says "Khayt withdrew
   * version {v}, so you can't go back to it" from THAT field. `updatedFrom`
   * with no `previous` is not the test: it is also what a book written
   * before this field looks like, and it stays after the note is read.
   *
   * `reason: 'revoked'` is a guard, close to unreachable: a withdrawn
   * `previous` is never kept and is dropped at the next check. It answers the
   * one window in between — a revocation learnt (`state.revoked` names the
   * previous version) before `withoutWithdrawn` has run on this book.
   */
  function revert(settings, id) {
    const s0 = isObj(settings) ? settings : {};
    const entry = (Array.isArray(s0.plugins) ? s0.plugins : []).find((p) => isObj(p) && p.id === id);
    const state = clone(stateOf(s0, id));
    const prev = state.previous;
    if (!entry || !isObj(prev) || !isObj(prev.manifest)) return { ok: false, settings: s0 };
    // Never back to a version Khayt withdrew.
    if (knownRevoked(state, prev.version)) return { ok: false, settings: s0, reason: 'revoked' };
    let back = Object.assign({}, entry, { version: prev.version, manifest: prev.manifest, granted: prev.granted,
                                          config: configFor(entry.config, prev.manifest) });
    // Reverting AWAY from a withdrawn version: the switch the revocation
    // turned off comes back as the shop had it, and the record goes with the
    // version it was about.
    if (knownRevoked(state, entry.version)) { back = unrevoked(back, state); delete state.revoked; }
    state.skipped = Array.from(new Set([].concat(Array.isArray(state.skipped) ? state.skipped : [], [entry.version])));
    delete state.previous; delete state.updatedAt; delete state.updatedFrom; delete state.previousWithdrawn;
    return { ok: true, settings: withBoth(s0, back, state) };
  }

  /**
   * The shop flips a connector's switch. While its version is withdrawn the
   * entry stays OFF — an old build only reads `enabled` — and the shop's
   * choice is kept as `revoked.wasEnabled`, which is what the fixed version
   * restores: switched off by the shop while revoked stays off after the fix.
   */
  function setSwitch(settings, id, enabled) {
    const s0 = isObj(settings) ? settings : {};
    const entry = (Array.isArray(s0.plugins) ? s0.plugins : []).find((p) => isObj(p) && p.id === id);
    if (!entry) return { ok: false, settings: s0 };
    const state = clone(stateOf(s0, id));
    if (isObj(state.revoked) && state.revoked.version === entry.version) {
      state.revoked.wasEnabled = !!enabled;
      return { ok: true, settings: withBoth(s0, Object.assign({}, entry, { enabled: false }), state), revoked: true };
    }
    return { ok: true, settings: withBoth(s0, Object.assign({}, entry, { enabled: !!enabled }), undefined) };
  }

  /**
   * Which manifest this device runs for an entry: `{ run, which, manifest,
   * granted, why }`. A withdrawn version never runs. Otherwise the entry when
   * it checks out; else the previous version when THAT checks out here (a
   * device too old to read the new manifest keeps the old one going); else
   * nothing, with `why`.
   */
  function runnable(entry, state) {
    const M = manifestLib();
    const s = isObj(state) ? state : {};
    if (!isObj(entry)) return { run: false, which: null, why: 'missing' };
    if (isObj(s.revoked) && s.revoked.version === entry.version) {
      return { run: false, which: null, why: 'revoked', reason: s.revoked.reason || '' };
    }
    const cur = M.checkEntry(entry);
    if (cur.ok && !cur.paused) return { run: entry.enabled !== false, which: 'current', manifest: entry.manifest, granted: entry.granted, why: entry.enabled === false ? 'off' : null };
    if (isObj(s.previous) && isObj(s.previous.manifest) && !knownRevoked(s, s.previous.version)) {
      const old = Object.assign({}, entry, { version: s.previous.version, manifest: s.previous.manifest,
                                             granted: s.previous.granted, config: configFor(entry.config, s.previous.manifest) });
      const p = M.checkEntry(old);
      if (p.ok && !p.paused) return { run: entry.enabled !== false, which: 'previous', manifest: old.manifest, granted: old.granted, why: entry.enabled === false ? 'off' : null };
    }
    return { run: false, which: null, why: cur.ok ? 'paused' : 'invalid' };
  }

  /* ── KEYS WHEN HOSTS MOVE ─────────────────────────────────────────────── */

  /**
   * Which entered keys a device must forget when a grant changes from
   * `before` to `after` (an Agree, or a Revert): `{ all, names }`.
   *
   * A key was typed in for the hosts the shop was shown. When the hosts a
   * secret is sent to change, the key held for it is dropped on that device
   * and asked for again — so a key entered for one company is never sent to
   * another just because the shop said yes to a new version. A secret whose
   * hosts did not change keeps its key.
   *
   * Per secret, the hosts are the grant's `routes` of the form
   * "host secret:name". A grant from before pairs were kept has none: there,
   * ANY change in `domains` is a change for every secret (`all: true`), since
   * nothing says which key went where.
   *
   * Devices do not call this with a bare old grant: they call `keysToForget`,
   * which first gives an old grant the pairs its own manifest sends. So the
   * `all` answer is reached only for an entry with no grant at all, and "any
   * new host drops every key" is NOT the rule a shop gets. The rule is: a key
   * is dropped when the hosts THAT key is sent to change, and only then.
   * Adding a host that receives no secret drops nothing.
   */
  function secretsToForget(before, after) {
    const b = isObj(before) ? before : {};
    const a = isObj(after) ? after : {};
    if (!Array.isArray(b.routes) || !Array.isArray(a.routes)) {
      const hosts = (g) => Array.from(new Set(Array.isArray(g.domains) ? g.domains : [])).sort().join(' ');
      return { all: hosts(b) !== hosts(a), names: [] };
    }
    const byName = (routes) => {
      const out = {};
      for (const r of routes) {
        const at = typeof r === 'string' ? r.indexOf(' secret:') : -1;
        if (at <= 0) continue;
        const name = r.slice(at + ' secret:'.length);
        (out[name] = out[name] || new Set()).add(r.slice(0, at));
      }
      return out;
    };
    const was = byName(b.routes); const now = byName(a.routes);
    const key = (set) => (set ? Array.from(set).sort().join(' ') : '');
    const names = Array.from(new Set(Object.keys(was).concat(Object.keys(now))))
      .filter((n) => key(was[n]) !== key(now[n])).sort();
    return { all: false, names };
  }

  /**
   * The same for two whole entries — the connector before and after an Agree
   * or a Revert — as a plain list of secret names for the device to drop.
   * An older grant is first given the pairs its own manifest sends
   * (`grantWithPairs`), so a key moving between two hosts it already listed
   * is seen; when even that cannot say (`all`), every secret either manifest
   * declares is named.
   *
   * THE RULE EVERY APP DESCRIBES (desktop, Mac, and the words under the
   * consent sheet): "a key you entered is asked for again when the place it
   * is sent to changes". Worked through, for a grant with domains [one] whose
   * manifest sends a and b to one:
   *   - the new version also sends order.number to two → nothing dropped;
   *   - the new version sends b to two instead        → b dropped, a kept.
   * A secret that only appears in the new version counts as moved (it had no
   * hosts and now has some), which is right: no key was shown for it before.
   */
  function keysToForget(beforeEntry, afterEntry) {
    const r = secretsToForget(grantWithPairs(beforeEntry), grantWithPairs(afterEntry));
    if (!r.all) return r.names;
    const names = new Set();
    for (const e of [beforeEntry, afterEntry]) {
      const list = isObj(e) && isObj(e.manifest) && Array.isArray(e.manifest.secrets) ? e.manifest.secrets : [];
      list.forEach((x) => { if (isObj(x) && str(x.name)) names.add(x.name); });
    }
    return Array.from(names).sort();
  }

  /* ── ONE PASS OVER THE BOOK ───────────────────────────────────────────── */

  /**
   * The book without a kept or waiting version the index has withdrawn: a
   * `previous` that could be reverted to or fallen back on, or a `pending` the
   * shop could still agree to. The very same object when there is neither.
   */
  function withoutWithdrawn(settings, id, row) {
    const st = stateOf(settings, id);
    const dropPrevious = isObj(st.previous) && !!revocationOf(row, st.previous.version);
    const dropPending = isObj(st.pending) && !!revocationOf(row, st.pending.version);
    if (!dropPrevious && !dropPending) return settings;
    const entry = (Array.isArray(settings.plugins) ? settings.plugins : []).find((p) => isObj(p) && p.id === id);
    const state = clone(st);
    if (dropPrevious) { state.previousWithdrawn = st.previous.version; delete state.previous; }
    if (dropPending) delete state.pending;
    return withBoth(settings, entry, state);
  }

  /**
   * Step 1 of a check: what to download. `[]` for an index that fails
   * `checkIndex` — a device then does nothing else.
   */
  function fetchesFor(settings, index, ctx) {
    const c = Object.assign({}, isObj(ctx) ? ctx : {}, { lastSerial: lastSerial(settings) });
    if (!checkIndex(index, c).ok) return [];
    const out = [];
    for (const e of (isObj(settings) && Array.isArray(settings.plugins) ? settings.plugins : [])) {
      if (!isObj(e)) continue;
      const p = planUpdate(e, stateOf(settings, e.id), rowFor(index, e.id, 'connector'), c);
      if (p.plan === 'fetch') out.push({ id: e.id, version: p.version, url: p.url, sha256: p.sha256, size: p.size });
    }
    return out;
  }

  /**
   * Step 2: apply the index to the book. `fetched` maps id → the VERIFIED
   * manifest for each download that succeeded (a failed download is simply
   * absent: tried again next time). Returns `{ ok, reason, settings, changed,
   * notes }`. When the index fails `checkIndex`, `settings` is the very object
   * passed in and nothing has changed. When it passes and there is nothing to
   * do, the only thing written is its serial, and only if it is higher than
   * the one remembered.
   */
  function applyIndex(settings, index, ctx, fetched) {
    const c = Object.assign({}, isObj(ctx) ? ctx : {}, { lastSerial: lastSerial(settings) });
    const verdict = checkIndex(index, c);
    if (!verdict.ok) return { ok: false, reason: verdict.reason, settings, changed: false, notes: [] };
    const got = isObj(fetched) ? fetched : {};
    let s = settings;
    const notes = [];
    for (const e of (isObj(settings) && Array.isArray(settings.plugins) ? settings.plugins : [])) {
      if (!isObj(e)) continue;
      const row = rowFor(index, e.id, 'connector');
      s = withoutWithdrawn(s, e.id, row);
      let p = planUpdate(e, stateOf(s, e.id), row, c);
      if (p.plan === 'revoke') {
        const r = applyPlan(s, e.id, p, null, c);
        s = r.settings; if (r.note) notes.push(r.note);
        const now = (Array.isArray(s.plugins) ? s.plugins : []).find((x) => isObj(x) && x.id === e.id);
        p = planUpdate(now, stateOf(s, e.id), row, c);
      }
      if (p.plan === 'blocked') { const r = applyPlan(s, e.id, p, null, c); if (r.note) notes.push(r.note); continue; }
      if (p.plan !== 'fetch' || !isObj(got[e.id])) continue;
      const now = (Array.isArray(s.plugins) ? s.plugins : []).find((x) => isObj(x) && x.id === e.id);
      const q = planWithManifest(now, got[e.id], row);
      if (q.plan === 'none') continue;
      const r = applyPlan(s, e.id, q, got[e.id], c);
      s = r.settings; if (r.note) notes.push(r.note);
    }
    // The serial is remembered whenever it RISES, even when nothing else
    // changed: a device that verified serial 10 and found nothing to do must
    // still refuse serial 9 tomorrow, or an older index — unexpired for up to
    // 45 days, and needing no key to serve again — could bring back a version
    // withdrawn since. The same serial again writes nothing.
    const seen = lastSerial(settings);
    if (seen === null || index.serial > seen) s = withBoth(s, null, undefined, index.serial);
    const changed = s !== settings;
    return { ok: true, reason: null, settings: s, changed, notes };
  }

  const api = {
    INDEX_CONTEXT, INDEX_FORMAT, SCHEMA, KINDS, EXPIRY_DAYS, RESIGN_DAYS, CLOCK_SLACK_MS, REASON_MAX,
    compareVersions, indexSigningMessage, checkIndex, rowFor, stateOf, lastSerial,
    planUpdate, planWithManifest, grantWithPairs, applyPlan, agree, revert, setSwitch, runnable, secretsToForget, keysToForget, fetchesFor, applyIndex,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPluginUpdate = api;
})();
