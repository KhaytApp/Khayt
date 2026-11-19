'use strict';
/**
 * Whether the person at this desktop may do something to a printer (P5),
 * decided in the MAIN process from the store, not trusted from the renderer.
 *
 * The renderer hides what a role may not do (operatorCan), but the printer
 * IPCs (send a file, pause, stop, light, speed, skip an object) checked
 * nothing: any renderer code could call them for a viewer. This reads the
 * same three fields the renderer reads (renderer/ops-locations.js
 * currentOperatorRoleKey), so the two can never disagree:
 *   - the operator lock OFF: everyone may, as RBAC has always said;
 *   - the lock ON and no active operator: the owner, as the renderer says;
 *   - else the active operator's roleKey (or their legacy role, mapped).
 * The shop's tightening is `settings.roleLimits` (lib/rbac.js canPrinter).
 *
 * `store` is main's in-memory copy (lanServerStore, kept current by every
 * save). A store main has never read is a shop with no lock set yet.
 */
const Rbac = require('../rbac.js');

function activeRole(store) {
  const settings = (store && store.settings) || {};
  if (!settings.operatorLockEnabled) return { lock: false, role: 'owner' };
  const ops = Array.isArray(store && store.operators) ? store.operators : [];
  const id = settings.activeOperatorId;
  const op = id ? ops.find((o) => o && o.id === id) : null;
  if (!op) return { lock: true, role: 'owner' };
  return { lock: true, role: op.roleKey || Rbac.roleFromLegacy(op.role) };
}

/**
 * @param {object} store  { settings, operators }
 * @param {'send'|'control'|'connection'|'unlink'} verb
 * @returns {{ ok: true } | { ok: false, error: 'not_permitted', verb: string, role: string }}
 */
function printerAllowed(store, verb) {
  const { lock, role } = activeRole(store);
  const limits = store && store.settings && store.settings.roleLimits;
  if (Rbac.canPrinter(role, verb, { lockEnabled: lock, limits })) return { ok: true };
  return { ok: false, error: 'not_permitted', verb, role };
}

module.exports = { activeRole, printerAllowed };
