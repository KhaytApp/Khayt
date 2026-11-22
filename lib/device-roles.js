'use strict';
/**
 * What a paired PHONE may do on the LAN server, by the role the shop gave it
 * when it approved the pairing (C1 + C9, ~/Khayt-proposals/phone-pairing-code-design.md,
 * decided by Turki Nov 22: all as recommended).
 *
 * Until now every phone was the owner: its key opened whatever the owner PIN
 * opens. A phone paired by code is given a role from the existing ladder
 * (lib/rbac.js ROLES: owner > manager > operator > viewer) and the SERVER
 * enforces it on every signed request, through scopes, the same shape the API
 * tokens already use (lib/api-token-scopes.js). The phone's screens follow
 * the role too, but that is a convenience; this is the check.
 *
 * THE CONTRACT (LanServer.swift, lib/lan-server.js, the iPhone):
 *
 *   roleOf(device)                → 'owner'|'manager'|'operator'|'viewer'
 *       A device with no `role` (enrolled before roles, by the owner PIN) is
 *       the owner, which is what it is today. Anything else that is not a
 *       role on the ladder is a viewer: a newer app's role fails closed.
 *   scopesFor(role)               → the role's scopes (a frozen array)
 *   requiredScope(path, method)   → the scope a request needs: a scope from
 *       SCOPES, null for a route any paired device may use, or 'owner' for a
 *       route this table does not name (fails closed: only the owner).
 *   allows(role, path, method)    → { ok, required, role }
 *       403 `{"reason":"role-scope","required":<required>}` when !ok.
 *   grantable(approverRole)       → the roles that person may give a phone
 *       (D-P3: a manager up to manager, only the owner may grant owner).
 *
 * Paths are matched as given on the request line without the query, with or
 * without the `/v1` prefix (`/v1/orders` is `/api/orders`). Segments are
 * compared one by one, never by a pattern over the path.
 *
 * Pure and JavaScriptCore-safe: no Node API, no clock, no I/O. Under Node it
 * is `module.exports`; under JavaScriptCore the `KhaytDeviceRoles` global.
 */
(function (root) {

const ROLES = Object.freeze(['owner', 'manager', 'operator', 'viewer']);

/** Every scope a phone's role can hold. `owner` is not a scope: it is "only the owner". */
const SCOPES = Object.freeze([
  'queue:read', 'machines:read', 'orders:read', 'inventory:read',
  'orders:write', 'inventory:write', 'waste:write', 'machines:control',
  'clients:read', 'clients:write', 'expense:write', 'quote:write', 'book:read',
  'book:write',
]);

/** D-P4, as decided: each role is the one below it plus its own row. */
const VIEWER = ['queue:read', 'machines:read', 'orders:read', 'inventory:read'];
const OPERATOR = VIEWER.concat(['orders:write', 'inventory:write', 'waste:write', 'machines:control']);
const MANAGER = OPERATOR.concat(['clients:read', 'clients:write', 'expense:write', 'quote:write', 'book:read']);
const OWNER = SCOPES.slice();
const BY_ROLE = Object.freeze({
  viewer: Object.freeze(VIEWER.slice()),
  operator: Object.freeze(OPERATOR.slice()),
  manager: Object.freeze(MANAGER.slice()),
  owner: Object.freeze(OWNER),
});

function roleOf(device) {
  if (!device || typeof device !== 'object') return 'viewer';
  if (device.role === undefined || device.role === null) return 'owner';   // enrolled by the PIN, before roles
  return ROLES.indexOf(device.role) !== -1 ? device.role : 'viewer';
}

function scopesFor(role) {
  return Object.prototype.hasOwnProperty.call(BY_ROLE, role) ? BY_ROLE[role] : BY_ROLE.viewer;
}

const MAX_PATH = 2048;
const isWrite = (m) => ['POST', 'PATCH', 'PUT', 'DELETE'].indexOf(String(m || '').toUpperCase()) !== -1;

/** The path's segments after `/api` (or `/v1`), lower case, no query; null when it is neither. */
function segmentsOf(path) {
  let p = String(path == null ? '' : path);
  if (p.length > MAX_PATH) return null;
  const q = p.indexOf('?');
  if (q !== -1) p = p.slice(0, q);
  // One leading slash and one trailing slash; an empty segment anywhere else
  // (`/api/orders//photos`) is not a route, rather than another route with
  // the gap closed up.
  const segs = p.split('/');
  if (segs[0] === '') segs.shift();
  if (segs.length && segs[segs.length - 1] === '') segs.pop();
  if (!segs.length || segs.indexOf('') !== -1) return null;
  const head = segs[0].toLowerCase();
  if (head !== 'api' && head !== 'v1') return null;
  return segs.slice(1).map((s, i) => (i === 0 ? s.toLowerCase() : s));
}

/**
 * Every route a phone uses, mapped. Read top to bottom; the first match wins.
 * `id` stands for one segment of any value.
 */
const ROUTES = Object.freeze([
  // Any paired device: who is this computer, who am I.
  { path: ['status'], any: null },
  { path: ['identity'], any: null },
  { path: ['proof'], any: null },
  { path: ['devices', 'self'], any: null },
  // The queue and the printers.
  { path: ['queue'], read: 'queue:read' },
  { path: ['machines'], read: 'machines:read' },
  { path: ['machines', 'live'], read: 'machines:read' },
  { path: ['printer', 'id', 'pause'], write: 'machines:control' },
  { path: ['printer', 'id', 'resume'], write: 'machines:control' },
  { path: ['printer', 'id', 'stop'], write: 'machines:control' },
  // Jobs. A quote's customer link and approving a quote for the customer are
  // pricing, so they need quote:write (a manager), not orders:write.
  { path: ['orders'], read: 'orders:read', write: 'orders:write' },
  { path: ['orders', 'id'], read: 'orders:read', write: 'orders:write' },
  { path: ['orders', 'id', 'photos'], write: 'orders:write' },
  { path: ['orders', 'id', 'quote-url'], read: 'quote:write' },
  { path: ['orders', 'id', 'approve'], write: 'quote:write' },
  // Stock and the shop floor's logs.
  { path: ['inventory'], read: 'inventory:read', write: 'inventory:write' },
  { path: ['inventory', 'id'], read: 'inventory:read', write: 'inventory:write' },
  { path: ['waste'], write: 'waste:write' },
  { path: ['expense'], write: 'expense:write' },
  // Customers (the waiting list holds customers' names, as for API tokens).
  { path: ['clients'], read: 'clients:read' },
  { path: ['waiting-list'], read: 'clients:read' },
  { path: ['waiting-list', 'id'], read: 'clients:read', write: 'clients:write' },
  // Pricing: quotes, the library's estimate, the shop's own intake estimate.
  { path: ['quote'], write: 'quote:write' },
  { path: ['library'], read: 'quote:write' },
  { path: ['library', 'id', 'thumbnail'], read: 'quote:write' },
  { path: ['library', 'id', 'estimate'], write: 'quote:write' },
  { path: ['intake', 'estimate'], write: 'quote:write' },
  // The book itself: a local copy (manager up) and writing it back (owner).
  { path: ['store'], read: 'book:read' },
  { path: ['store', 'settings'], read: 'book:read' },
  { path: ['store', 'deltas'], write: 'book:write' },
].map((r) => Object.freeze(Object.assign({}, r, { path: Object.freeze(r.path.slice()) }))));

function requiredScope(path, method) {
  const segs = segmentsOf(path);
  if (!segs) return 'owner';
  const write = isWrite(method);
  for (const r of ROUTES) {
    if (r.path.length !== segs.length) continue;
    let match = true;
    for (let i = 0; i < r.path.length; i++) {
      if (r.path[i] === 'id') { if (!segs[i]) { match = false; break; } continue; }
      if (r.path[i] !== segs[i]) { match = false; break; }
    }
    if (!match) continue;
    if (Object.prototype.hasOwnProperty.call(r, 'any')) return r.any;
    const s = write ? r.write : r.read;
    return s || 'owner';   // a direction the route does not offer a phone
  }
  return 'owner';
}

function allows(role, path, method) {
  const who = ROLES.indexOf(role) !== -1 ? role : 'viewer';
  const required = requiredScope(path, method);
  if (who === 'owner') return { ok: true, required, role: who };
  if (required === null) return { ok: true, required, role: who };
  if (required === 'owner') return { ok: false, required, role: who };
  return { ok: scopesFor(who).indexOf(required) !== -1, required, role: who };
}

/** D-P3: the owner may give any role; a manager up to manager; nobody else any. */
function grantable(approverRole) {
  if (approverRole === 'owner') return ROLES.slice();
  if (approverRole === 'manager') return ['manager', 'operator', 'viewer'];
  return [];
}

/** D-P2: the role the approve sheet starts on. */
const DEFAULT_ROLE = 'operator';

const api = { ROLES, SCOPES, BY_ROLE, DEFAULT_ROLE, ROUTES, roleOf, scopesFor, requiredScope, allows, grantable };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (root) root.KhaytDeviceRoles = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
