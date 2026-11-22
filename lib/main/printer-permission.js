'use strict';
/**
 * Whether the person at this desktop may do something to a printer (P5),
 * decided in the MAIN process from the store, not trusted from the renderer.
 *
 * The renderer hides what a role may not do (operatorCan), but the printer
 * IPCs (send a file, pause, stop, light, speed, skip an object) checked
 * nothing: any renderer code could call them for a viewer. This reads the
 * same three fields the renderer reads (renderer/ops-locations.js
 * currentOperatorRoleKey):
 *   - the operator lock OFF: everyone may, as RBAC has always said;
 *   - the lock ON and nobody (or nobody main can name) signed in: REFUSED,
 *     where the renderer's screens read the owner;
 *   - else the active operator's roleKey (or their legacy role, mapped).
 * The shop's tightening is `settings.roleLimits` (lib/rbac.js canPrinter).
 *
 * `store` is main's in-memory copy (lanServerStore). Every save reaches it
 * through guardSave below, so the window cannot simply write itself a
 * better role (#2592 security review, M2).
 *
 * FAILS CLOSED under the lock: no store at all, or the lock on with nobody
 * (or an id that names nobody) signed in, refuses. The renderer reads "nobody
 * signed in" as the owner for its screens; main does not act on that.
 */
const Rbac = require('../rbac.js');

function opRole(op) {
  return op.roleKey || Rbac.roleFromLegacy(op.role, { hasLock: true });
}

/** { lock, role } with role null when nobody main can name is signed in under the lock. */
function activeRole(store) {
  if (!store || !store.settings) return { lock: true, role: null };   // nothing read: refuse
  const settings = store.settings;
  if (!settings.operatorLockEnabled) return { lock: false, role: 'owner' };
  const ops = Array.isArray(store.operators) ? store.operators : [];
  const id = settings.activeOperatorId;
  const op = id ? ops.find((o) => o && o.id === id) : null;
  if (!op) return { lock: true, role: null };
  return { lock: true, role: opRole(op) };
}

/**
 * @param {object} store  { settings, operators }
 * @param {'send'|'control'|'connection'|'unlink'} verb
 * @returns {{ ok: true } | { ok: false, error: 'not_permitted', verb: string, role: string }}
 */
function printerAllowed(store, verb) {
  const { lock, role } = activeRole(store);
  if (lock && !role) return { ok: false, error: 'not_permitted', verb, role: null };
  const limits = store && store.settings && store.settings.roleLimits;
  if (Rbac.canPrinter(role, verb, { lockEnabled: lock, limits })) return { ok: true };
  return { ok: false, error: 'not_permitted', verb, role };
}

// ── THE SAVE GUARD (#2592 security review, M2 and L1) ─────────────────────
//
// hub:save-store writes whatever the window sends, and main reads the role
// from what was written. So under the lock ON DISK a save may not:
//   - change the lock, roleLimits or any operator's role, or add or remove an
//     operator, unless the role on disk may edit security (the owner);
//   - change another operator's PIN (only the owner may; anyone their own);
//   - sign someone in whom main has not just verified (hub:verify-operator-pin
//     or the owner's PIN / recovery code through hub:verify-pin), unless that
//     operator has no PIN; signing out (null) is always allowed;
//   - change a printer's connection without printers 'connection', or take a
//     printer away without 'unlink' (L1).
// What it may not change is put back as it is on disk, the way
// ApiTokens.guardTokenSave keeps the token list. A book whose lock is OFF on
// disk saves exactly as today: that is how the lock is first turned on.

const CONNECTION_KEYS = ['type', 'host', 'port', 'apiKey', 'accessCode', 'serial', 'printerSlug', 'deviceId', 'mainboardId'];
// `network` is the "make no internet calls" switch and its kept purposes
// (lib/outbound.js): only the owner changes it (Turki, Nov 22 round 2), as
// the lock itself.
// `telemetry` is the crash-report and usage-statistics opt-ins (and the
// install id that goes with them): owner-only under the lock too (Turki,
// Nov 22), so a staff member can neither switch sharing on for the shop nor
// switch it off.
const SECURITY_SETTINGS = ['operatorLockEnabled', 'securityEnabled', 'roleLimits', 'recoveryCodeHash', 'adminPinHash', 'network', 'telemetry'];
const same = (a, b) => JSON.stringify(a === undefined ? null : a) === JSON.stringify(b === undefined ? null : b);
/** Owner-only settings whose default the window fills in: what they MEAN. */
const SETTING_VIEW = {
  telemetry: (v) => {
    const t = v && typeof v === 'object' ? v : {};
    return { crash: t.crashOptIn === true, usage: t.usageOptIn === true, id: String(t.installId || ''), at: String(t.consentAt || '') };
  },
};
const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

function connectionOf(m) {
  const api = (m && m.printerApi) || {};
  const out = {};
  for (const k of CONNECTION_KEYS) if (api[k] !== undefined && api[k] !== '') out[k] = api[k];
  if (m && m.smartPlug !== undefined) out.smartPlug = m.smartPlug;
  return out;
}

/**
 * @param {object} incoming  the store the window sent (secrets already merged from disk)
 * @param {object} disk      the store on disk
 * @param {{ verified?: (opId: string) => boolean, consume?: (opId: string) => void }} [ctx]
 *   main's record of PINs it checked; `consume` spends one on the save that uses it
 * @returns {{ store: object, refused: string[] }}
 */
function guardSave(incoming, disk, ctx) {
  const refused = [];
  const plain = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
  // No settings object over a book that has one: nothing to write (H1). The
  // caller refuses the save; passed through, it wiped every setting.
  if (incoming && disk && plain(disk.settings) && !plain(incoming.settings)) return { store: null, refused: ['settings'] };
  if (!incoming || !plain(incoming.settings) || !disk || !plain(disk.settings) || !disk.settings.operatorLockEnabled) return { store: incoming, refused };
  const verified = (ctx && typeof ctx.verified === 'function') ? ctx.verified : () => false;
  const consume = (ctx && typeof ctx.consume === 'function') ? ctx.consume : () => {};
  const next = { ...incoming, settings: { ...incoming.settings } };
  let putBackQuietly = false;   // a default the window filled in, set back as on disk
  const diskOps = Array.isArray(disk.operators) ? disk.operators : [];
  const diskRole = activeRole(disk).role;
  const owner = !!(diskRole && Rbac.can(diskRole, 'security', 'edit', { lockEnabled: true }));

  // Who is signed in after this save.
  const wantId = next.settings.activeOperatorId || null;
  if (wantId !== (disk.settings.activeOperatorId || null) && wantId !== null) {
    const op = diskOps.find((o) => o && o.id === wantId);
    // Nobody by that id, a deactivated person (L4), or a PIN main did not check.
    if (!op || op.active === false || (op.pinHash && !verified(wantId))) {
      next.settings.activeOperatorId = disk.settings.activeOperatorId || null;
      refused.push('activeOperatorId');
    } else if (op.pinHash) {
      consume(wantId);   // one verification, one sign-in (L1)
    }
  }

  if (!owner) {
    for (const k of SECURITY_SETTINGS) {
      if (same(next.settings[k], disk.settings[k])) continue;
      // What the window sent may differ only in shape: the window fills in
      // defaults a book saved before the field existed does not have. That is
      // no change, so it is put back WITHOUT a refusal; otherwise every save by
      // a manager on such a book would be refused and reloaded (Nov 22).
      const view = SETTING_VIEW[k];
      const changed = !view || !same(view(next.settings[k]), view(disk.settings[k]));
      if (disk.settings[k] === undefined) delete next.settings[k]; else next.settings[k] = clone(disk.settings[k]);
      if (changed) refused.push('settings.' + k); else putBackQuietly = true;
    }
    // Operators: the same people with the same roles; a PIN only one's own.
    const inOps = Array.isArray(next.operators) ? next.operators : [];
    // The same people: compared as SETS of ids (L3), and every entry an
    // operator with an id (a missing or duplicated id is a different list).
    const idSet = (l) => new Set(l.map((o) => (o && typeof o.id === 'string') ? o.id : null));
    const a = idSet(inOps), b = idSet(diskOps);
    const sameIds = !a.has(null) && a.size === inOps.length && a.size === b.size && [...a].every((x) => b.has(x));
    const self = next.settings.activeOperatorId || null;
    if (!sameIds) {
      next.operators = clone(diskOps);
      refused.push('operators');
    } else {
      next.operators = inOps.map((o) => {
        const d = diskOps.find((x) => x && x.id === o.id) || {};
        const out = { ...o };
        let touched = false;
        if (!same(o.roleKey, d.roleKey) || !same(o.role, d.role)) { out.roleKey = d.roleKey; out.role = d.role; if (d.roleKey === undefined) delete out.roleKey; touched = true; }
        if (!same(o.pinHash, d.pinHash) && o.id !== self) { out.pinHash = d.pinHash; touched = true; }
        // Who may sign in is the owner's to change: a deactivated owner can
        // neither be verified nor signed in (#2592 release review, MED-1).
        if (!same(o.active, d.active)) { if (d.active === undefined) delete out.active; else out.active = d.active; touched = true; }
        if (touched) refused.push('operators.' + o.id);
        return out;
      });
    }
  }

  // THE SHOP KEEPS AN OWNER, whoever saves (owner included). An operator
  // who is the owner on disk cannot be deactivated, and a save that would
  // leave no active owner (deactivating, demoting or removing the last one)
  // keeps the operators as they are on disk: with the lock on, the owner is
  // the only one who can unlock, restore or change roles (MED-1).
  {
    const ownerOnDisk = new Set(diskOps.filter((o) => o && o.id && opRole(o) === 'owner').map((o) => o.id));
    let ops = Array.isArray(next.operators) ? next.operators : [];
    if (ops.some((o) => o && ownerOnDisk.has(o.id) && o.active === false)) {
      ops = ops.map((o) => (o && ownerOnDisk.has(o.id) && o.active === false ? { ...o, active: true } : o));
      next.operators = ops;
      refused.push('operators:owner-active');
    }
    const anyOwner = ops.some((o) => o && o.id && o.active !== false && opRole(o) === 'owner');
    if (!anyOwner && ownerOnDisk.size) {
      next.operators = clone(diskOps);
      refused.push('operators:last-owner');
    }
  }

  // Printers (L1), for whoever is signed in after this save.
  const role = activeRole(next).role;
  const limits = disk.settings.roleLimits;
  const may = (verb) => !!role && Rbac.canPrinter(role, verb, { lockEnabled: true, limits });
  const inM = Array.isArray(next.machines) ? next.machines.slice() : [];
  const diskM = Array.isArray(disk.machines) ? disk.machines : [];
  let changed = false;
  for (const d of diskM) {
    if (!d || !d.id) continue;
    const i = inM.findIndex((m) => m && m.id === d.id);
    if (i === -1) {
      if (connectionOf(d).type && !may('unlink')) { inM.push(clone(d)); changed = true; refused.push('machines.' + d.id + ':unlink'); }
      continue;
    }
    if (!same(connectionOf(inM[i]), connectionOf(d)) && !may('connection')) {
      const m = { ...inM[i] };
      if (d.printerApi === undefined) delete m.printerApi; else m.printerApi = clone(d.printerApi);
      if (d.smartPlug === undefined) delete m.smartPlug; else m.smartPlug = clone(d.smartPlug);
      inM[i] = m; changed = true; refused.push('machines.' + d.id + ':connection');
    }
  }
  for (let i = 0; i < inM.length; i++) {
    const m = inM[i];
    if (!m || !m.id || diskM.some((d) => d && d.id === m.id)) continue;
    if (Object.keys(connectionOf(m)).length && !may('connection')) {
      const c = { ...m }; delete c.printerApi; delete c.smartPlug;
      inM[i] = c; changed = true; refused.push('machines.' + m.id + ':connection');
    }
  }
  if (changed) next.machines = inM;
  return { store: refused.length || putBackQuietly ? next : incoming, refused };
}

// ── A LOCK THAT PREDATES roleKey (#2264, Nov 6) ───────────────────────────
//
// The admin the lock made (renderer/app-security.js setupAdminSecurity) was
// given a TRANSLATED title and, before #2264, no roleKey. rbac reads
// "Admin…" as the owner, but not the Arabic, Turkish, Japanese or Chinese
// title, so under the owner-only rules of #2592 such a shop had nobody who
// could restore, unlock or change a role (#2592 data review, MED-3). Once,
// under the lock, when no operator resolves to the owner: the one whose
// title is any language's admin title (or the only operator) becomes the
// owner by roleKey. Nothing else is touched.
/** renderer/locales/*.js "op.role_admin", every language (a test keeps them equal). */
const ADMIN_TITLES = ['Admin', 'مدير', 'Administrator', 'Administrador', 'Administrateur', 'Yönetici', '管理者', '管理员'];

function migrateLegacyOwner(store) {
  const st = store && store.settings;
  const ops = store && Array.isArray(store.operators) ? store.operators : [];
  if (!st || !st.operatorLockEnabled || !ops.length) return { store, changed: false };
  // Once, ever (settings.ownerMigratedAt), and only on a book from before
  // roleKey (#2264): if ANY operator has a roleKey, the roles were set by
  // someone, and "مدير" there can be a real manager (security review LOW).
  if (st.ownerMigratedAt) return { store, changed: false };
  if (ops.some((o) => o && o.roleKey)) return { store, changed: false };
  if (ops.some((o) => o && opRole(o) === 'owner')) return { store, changed: false };
  const norm = (v) => String(v == null ? '' : v).trim().toLowerCase();
  const titles = new Set(ADMIN_TITLES.map(norm));
  const real = ops.filter((o) => o && o.id);
  let pick = real.filter((o) => !o.roleKey && titles.has(norm(o.role)));
  if (pick.length !== 1) pick = real.length === 1 && !real[0].roleKey ? real : [];
  if (pick.length !== 1) return { store, changed: false };
  const id = pick[0].id;
  return {
    store: {
      ...store,
      settings: { ...st, ownerMigratedAt: new Date().toISOString() },
      operators: ops.map((o) => (o && o.id === id ? { ...o, roleKey: 'owner' } : o)),
    },
    changed: true,
    operatorId: id,
  };
}

/**
 * May the person at this computer change the outbound switch: the book's
 * `settings.network` or this computer's own stricter switch? With the lock
 * off, anyone (as RBAC has always said). Under the lock, only the owner
 * (security/edit), the same rule as the lock and the API tokens (Turki, Nov 22
 * round 2). Nobody main can name signed in under the lock: no.
 */
function mayChangeNetwork(store) {
  const { lock, role } = activeRole(store);
  if (!lock) return true;
  return !!(role && Rbac.can(role, 'security', 'edit', { lockEnabled: true }));
}

/**
 * May the person at this computer change what Khayt shares about the shop:
 * the anonymous install count (this computer's switch, hub:active-count-set)
 * and the crash-report and usage-statistics opt-ins (`settings.telemetry`,
 * held by the save guard below)? The same rule as the outbound switch:
 * anyone with the lock off, only the owner under it (Turki, Nov 22).
 */
function mayChangePrivacy(store) {
  return mayChangeNetwork(store);
}

module.exports = { mayChangePrivacy, mayChangeNetwork, activeRole, printerAllowed, guardSave, migrateLegacyOwner, ADMIN_TITLES, CONNECTION_KEYS };
