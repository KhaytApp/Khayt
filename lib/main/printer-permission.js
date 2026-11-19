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
const SECURITY_SETTINGS = ['operatorLockEnabled', 'securityEnabled', 'roleLimits', 'recoveryCodeHash', 'adminPinHash'];
const same = (a, b) => JSON.stringify(a === undefined ? null : a) === JSON.stringify(b === undefined ? null : b);
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
      if (!same(next.settings[k], disk.settings[k])) {
        if (disk.settings[k] === undefined) delete next.settings[k]; else next.settings[k] = clone(disk.settings[k]);
        refused.push('settings.' + k);
      }
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
        if (touched) refused.push('operators.' + o.id);
        return out;
      });
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
  return { store: refused.length ? next : incoming, refused };
}

module.exports = { activeRole, printerAllowed, guardSave, CONNECTION_KEYS };
