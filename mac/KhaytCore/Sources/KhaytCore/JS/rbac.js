'use strict';
(function () {

/**
 * RBAC permission core for Khayt. See docs/KHAYT-3.0-RBAC-SPEC.md.
 *
 * Pure logic only — no fs, no renderer, no DOM, no i18n. This is the single
 * declarative source of truth that both UI gating (discoverability) and action
 * gating (authority) consult through `can()`. It promotes the legacy free-text
 * operator `role` + operator-lock into a structured, locale-independent role
 * set without changing behavior for an owner who never used operator-lock.
 *
 * Governing principle (spec §1): roles are local-first and additive. With the
 * operator-lock OFF, RBAC must be byte-for-byte today's behavior — i.e. full
 * access for everyone. That backward-compat path is `opts.lockEnabled === false`
 * in `can()`, which short-circuits to `true` regardless of role. Cloud
 * multi-user is an additive layer that maps a cloud user onto one of these
 * `roleKey`s; it is never required for local RBAC to work.
 *
 * Machine keys (`roleKey`) are NEVER localized — the old bug was using an
 * i18n display string (`op.role_admin`, …) as a permission key, which broke
 * across locales. The free-text `role` survives only as a cosmetic display
 * label; permission logic reads `roleKey` exclusively.
 */

/**
 * Canonical role keys, ordered MOST privileged → LEAST privileged. The index in
 * this array is the rank used by `isAtLeast()` (lower index = more privilege).
 * @type {ReadonlyArray<'owner'|'manager'|'operator'|'viewer'>}
 */
const ROLES = ['owner', 'manager', 'operator', 'viewer'];

/** The least-privileged role — the safe default for any unknown/missing role. */
const LEAST_PRIVILEGED = 'viewer';

/** App areas the matrix governs. */
const AREAS = [
  'orders',      // orders / quotes
  'inventory',   // inventory / suppliers / purchase orders
  'clients',     // client records
  'invoicing',   // invoicing / ZATCA submit (submission is a mutating action)
  'analytics',   // analytics / reports
  'settings',    // general settings
  'security',    // settings → security / roles administration
  'cloud',       // cloud connect / billing admin
  'destructive', // wipe, bulk delete, restore (always ALSO gated by verifyDestructiveGate)
  'logs',        // operator / time logs (own)
];

/** Actions checked against the matrix. */
const ACTIONS = ['view', 'create', 'edit', 'delete'];

// Shorthand permission sets, mapping the spec's CRUD letters onto our
// {view,create,edit,delete} action model (R→view, C→create, U→edit, D→delete).
const NONE  = { view: false, create: false, edit: false, delete: false };
const R     = { view: true,  create: false, edit: false, delete: false };
const CRU   = { view: true,  create: true,  edit: true,  delete: false };
const CRUD  = { view: true,  create: true,  edit: true,  delete: true  };

/**
 * Permission MATRIX: roleKey → area → { view, create, edit, delete }.
 *
 * Derived directly from docs/KHAYT-3.0-RBAC-SPEC.md §3 / §4:
 *   - owner:    everything (destructive create is additionally gated at runtime).
 *   - manager:  full operations + analytics + clients + logs; invoicing is
 *               create/edit but NOT delete; NO settings-write, NO security,
 *               NO cloud/billing, NO destructive.
 *   - operator: orders / inventory / logs are view+create+edit (no delete);
 *               clients view-only; invoicing view-only; no analytics, settings,
 *               security, cloud or destructive.
 *   - viewer:   view-only everywhere it can see; never mutates.
 *
 * Frozen so the single source of truth cannot be mutated at runtime.
 */
const MATRIX = Object.freeze({
  owner: Object.freeze({
    orders:      CRUD,
    inventory:   CRUD,
    clients:     CRUD,
    invoicing:   CRUD,
    analytics:   R,
    settings:    CRUD,
    security:    CRUD,
    cloud:       CRUD,
    destructive: { view: true, create: true, edit: false, delete: false }, // C (gated)
    logs:        CRUD,
  }),
  manager: Object.freeze({
    orders:      CRUD,
    inventory:   CRUD,
    clients:     CRUD,
    invoicing:   CRU,   // can create/edit invoices, but not delete; no ZATCA admin
    analytics:   R,
    settings:    R,     // read general settings, cannot change them
    security:    NONE,
    cloud:       NONE,
    destructive: NONE,
    logs:        CRUD,
  }),
  operator: Object.freeze({
    orders:      CRU,
    inventory:   CRU,
    clients:     R,
    invoicing:   R,
    analytics:   NONE,
    settings:    NONE,
    security:    NONE,
    cloud:       NONE,
    destructive: NONE,
    logs:        CRU,
  }),
  viewer: Object.freeze({
    orders:      R,
    inventory:   R,
    clients:     R,
    invoicing:   R,
    analytics:   NONE,  // analytics is hidden from operator/viewer per spec §3
    settings:    NONE,
    security:    NONE,
    cloud:       NONE,
    destructive: NONE,
    logs:        R,
  }),
});

/** Normalize an arbitrary roleKey to a known one, defaulting to least privilege. */
function normalizeRole(roleKey) {
  const key = String(roleKey || '').toLowerCase();
  return Object.prototype.hasOwnProperty.call(MATRIX, key) ? key : LEAST_PRIVILEGED;
}

/**
 * Core check: may `roleKey` perform `action` in `area`?
 *
 * @param {string} roleKey  one of ROLES; anything unknown → viewer (least privilege).
 * @param {string} area     one of AREAS; unknown area → denied.
 * @param {string} action   one of ACTIONS ('view'|'create'|'edit'|'delete'); unknown → denied.
 * @param {{lockEnabled?: boolean}} [opts]
 *        When `lockEnabled === false`, the operator-lock is OFF → unrestricted,
 *        the backward-compat "full access" path (spec §4/§9 lock-off parity).
 *        Any other value (including omitted) enforces the matrix.
 * @returns {boolean}
 */
function can(roleKey, area, action, opts = {}) {
  // Operator-lock OFF ⇒ today's behavior: everything is allowed for everyone.
  if (opts && opts.lockEnabled === false) return true;

  const role = normalizeRole(roleKey);
  const areaPerms = MATRIX[role][String(area || '').toLowerCase()];
  if (!areaPerms) return false; // unknown area → deny
  return areaPerms[String(action || '').toLowerCase()] === true;
}

/**
 * Map a legacy free-text `role` string onto a structured roleKey (spec §2/§7).
 *
 * Mapping:
 *   - contains 'admin'            → 'owner'   (today's admin held security + destructive)
 *   - contains 'manager'          → 'manager'
 *   - contains 'sales'            → 'operator' (front-line; per spec sales folds into operator)
 *   - contains 'tech'/'technician'→ 'operator'
 *   - contains 'view'/'read'      → 'viewer'
 *   - empty / whitespace          → 'owner' when there is no operator-lock
 *                                    (the single-operator default), else 'operator'
 *   - anything else recognized    → 'operator' (safe front-line default per §7)
 *
 * @param {string} roleString  the legacy display role.
 * @param {{hasLock?: boolean}} [opts]  whether operator-lock is configured;
 *        controls the empty-role default (empty → owner only when no lock).
 * @returns {'owner'|'manager'|'operator'|'viewer'}
 */
function roleFromLegacy(roleString, opts = {}) {
  const s = String(roleString || '').trim().toLowerCase();
  if (!s) return opts && opts.hasLock ? 'operator' : 'owner';
  if (s.includes('admin')) return 'owner';
  if (s.includes('manager')) return 'manager';
  if (s.includes('sales')) return 'operator';
  if (s.includes('tech')) return 'operator';
  if (s.includes('view') || s.includes('read')) return 'viewer';
  return 'operator';
}

/**
 * Rank comparison: does `roleKey` hold at least the privilege of `minRoleKey`?
 * Owner is highest. Unknown roles normalize to viewer (lowest), so an unknown
 * role only satisfies a viewer floor.
 *
 * @returns {boolean}
 */
function isAtLeast(roleKey, minRoleKey) {
  const rank = ROLES.indexOf(normalizeRole(roleKey));      // lower = more privileged
  const minRank = ROLES.indexOf(normalizeRole(minRoleKey));
  return rank <= minRank;
}

const api = {
  ROLES,
  AREAS,
  ACTIONS,
  MATRIX,
  can,
  roleFromLegacy,
  isAtLeast,
  normalizeRole,
};

// Dual export: CommonJS (node tests) + global (renderer <script>, like quote-followup).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytRbac = api;

})();
