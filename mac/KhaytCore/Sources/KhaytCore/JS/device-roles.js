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
 *       The device's own `role` when it is exactly a role on the ladder.
 *       A PHONE (no `kind`) enrolled before roles, by the owner PIN, has
 *       neither `role` nor `rolesVersion`, and is the owner, which is what it
 *       is today. Everything else is a viewer: a device paired by code (it
 *       carries `rolesVersion`) whose role is missing, a slicer plugin or any
 *       other `kind`, and a role this build does not know (a newer app's).
 *       Swift: decode `role` as `String?`, never an enum that drops unknown
 *       values, and keep `rolesVersion` (security review of #2625).
 *   allowsDevice(device, path, method) = allows(roleOf(device), path, method)
 *   scopesFor(role)               → the role's scopes (a frozen array)
 *   requiredScope(path, method)   → the scope a request needs: a scope from
 *       SCOPES, null for a route any paired device may use, or 'owner' for a
 *       route this table does not name (fails closed: only the owner).
 *   allows(role, path, method)    → { ok, required, role }
 *       403 `{"reason":"role-scope","required":<required>}` when !ok.
 *   grantable(approverRole)       → the roles that person may give a phone
 *       (D-P3: a manager up to manager, only the owner may grant owner).
 *
 * PASS THE PATH THE ROUTER ROUTES ON (Node: the `pathname` the switch reads;
 * Mac: `request.path` in route()), never the raw request line. Both spellings
 * give the same answer anyway: each segment is percent-decoded here, and a
 * segment that decodes to something containing `/` or `\`, a control
 * character, `.` or `..`, or that does not decode, makes the whole request
 * owner-only. Without that, `POST /api/orders/x%2Fapprove` read as a job
 * update (orders:write) while the Mac, which routes on the decoded path,
 * approved a quote (reviews of #2625). Segments are compared exactly, case
 * included, as the servers route; with or without the `/v1` prefix
 * (`/v1/orders` is `/api/orders`). Methods: GET and HEAD read; POST, PATCH,
 * PUT and DELETE write; anything else is owner-only.
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

const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
function roleOf(device) {
  if (!device || typeof device !== 'object' || Array.isArray(device)) return 'viewer';
  const role = own(device, 'role') ? device.role : undefined;
  if (typeof role === 'string' && ROLES.indexOf(role) !== -1) return role;
  // The legacy owner, and nothing else: a phone (no kind) with no role and no
  // mark of code pairing. A serializer that drops `role` on a code-paired
  // phone leaves `rolesVersion`, and it reads as a viewer, not the owner.
  const kind = own(device, 'kind') ? device.kind : undefined;
  const legacy = (role === undefined || role === null) && (kind === undefined || kind === null)
    && !own(device, 'rolesVersion');
  return legacy ? 'owner' : 'viewer';
}

function scopesFor(role) {
  return Object.prototype.hasOwnProperty.call(BY_ROLE, role) ? BY_ROLE[role] : BY_ROLE.viewer;
}

const MAX_PATH = 2048;
/** 'read' | 'write' | null (a method a phone has no business sending: owner-only). */
function direction(m) {
  const v = String(m == null ? '' : m).toUpperCase();
  if (v === 'GET' || v === 'HEAD') return 'read';
  if (v === 'POST' || v === 'PATCH' || v === 'PUT' || v === 'DELETE') return 'write';
  return null;
}

/** A segment percent-decoded, or null when it must not be routed on. */
function decodeSegment(seg) {
  let d;
  try { d = decodeURIComponent(seg); } catch (_) { return null; }
  if (d === '.' || d === '..') return null;
  for (let i = 0; i < d.length; i++) {
    const c = d.charCodeAt(i);
    if (c === 47 || c === 92 || c < 32 || c === 127) return null;   // '/', '\\', controls
  }
  return d;
}

/** The path's segments after `/api` (or `/v1`), percent-decoded, no query; null when it must not be routed on. */
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
  const out = [];
  for (const raw of segs) {
    const d = decodeSegment(raw);
    if (d === null || d === '') return null;
    out.push(d);
  }
  if (out[0] !== 'api' && out[0] !== 'v1') return null;
  return out.slice(1);
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
  { path: ['devices', 'self'], any: null },   // reserved: served with the pairing PR (design note)
  // The queue and the printers.
  { path: ['queue'], read: 'queue:read' },
  { path: ['machines'], read: 'machines:read' },
  { path: ['machines', 'live'], read: 'machines:read' },
  { path: ['printer', 'id', 'pause'], write: 'machines:control' },
  { path: ['printer', 'id', 'resume'], write: 'machines:control' },
  { path: ['printer', 'id', 'stop'], write: 'machines:control' },
  { path: ['printer', 'id', 'cancel'], write: 'machines:control' },   // the Mac's other word for stop
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
  { path: ['library', 'id', 'thumb'], read: 'quote:write' },
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
  const dir = direction(method);
  if (!dir) return 'owner';
  const write = dir === 'write';
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

function allowsDevice(device, path, method) { return allows(roleOf(device), path, method); }

const api = Object.freeze({ ROLES, SCOPES, BY_ROLE, DEFAULT_ROLE, ROUTES, roleOf, scopesFor, requiredScope, allows, allowsDevice, grantable });
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (root) root.KhaytDeviceRoles = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
