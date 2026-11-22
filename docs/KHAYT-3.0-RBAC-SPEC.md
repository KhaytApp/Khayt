# RBAC / team roles — structured per-user roles and permissions

**Scope:** promote the existing free-text operator `role` + operator-lock into a **structured role set with an explicit permission matrix**, enforced in one place, that works **locally today** and maps cleanly onto Phase 1 Cloud users tomorrow. We **expand** `app-security.js` / `applyOperatorPermissions()` — we do not replace them.

**Governing principle (unchanged):** roles are **local-first and additive**. With Cloud off, RBAC is exactly today's operator-lock with a tidier model — an owner who never assigns roles is byte-for-byte unaffected. Cloud multi-user (Phase 1) is an **additive layer** that maps a cloud user onto a local role; it is never a requirement for RBAC to work.

---

## 1. Today (what we build on)

- Operators live in the `operators` collection (`app-state.js`, key `hub_operators_v1`). Each has a **free-text `role`** string (`op.role_admin`/`technician`/`sales`).
- `settings.operatorLockEnabled` + `settings.activeOperatorId` gate the app; `applyOperatorPermissions()` (`ops-locations.js`) hides tabs by **string-matching** the role (`includes('admin')`, `includes('tech')`, …).
- `app-security.js` owns PIN/recovery and destructive-action gates: `securityIsEnabled()`, `getAdminOperator()` (matches `role` containing `admin`), `verifyAdminPin()`, `verifyDestructiveGate()`.
- `setupAdminSecurity()` seeds the first operator with `role: t('op.role_admin')`.

**Problems:** role is an i18n display string used as a permission key (brittle across locales), permissions are scattered ad-hoc tab toggles, and there is no concept the Cloud `users` table can bind to.

---

## 2. Role set (small, practical — do not over-engineer)

Four roles, stable machine keys (never localized for logic):

| Key | Label | Intent |
|---|---|---|
| `owner` | Owner | Full control incl. security, billing, destructive ops. Exactly one+ required. |
| `manager` | Manager | Runs the shop: full operations + analytics + clients; no security/billing/destructive. |
| `operator` | Operator | Front-line: create/edit orders, manage inventory, read clients. (Today's Technician/Sales fold here.) |
| `viewer` | Viewer | Read-only across operational areas; cannot mutate. |

Legacy free-text roles migrate (§7): `admin`→`owner`, `tech`/`technician`+`sales`→`operator`, empty→`owner` (single-operator default).

---

## 3. Permission matrix (role × app-area → actions)

Actions: **C**reate · **R**ead · **U**pdate · **D**elete · **—** none.

| App area | owner | manager | operator | viewer |
|---|---|---|---|---|
| Orders / quotes | CRUD | CRUD | CRU | R |
| Inventory / suppliers / POs | CRUD | CRUD | CRU | R |
| Clients | CRUD | CRUD | R | R |
| Invoicing / ZATCA submit | CRUD | CRU | R | R |
| Analytics / reports | R | R | — | — |
| Settings (general) | CRUD | R | — | — |
| **Settings → Security/roles** | CRUD | — | — | — |
| **Cloud connect / billing** | CRUD | — | — | — |
| Destructive (wipe, bulk delete, restore) | C (gated) | — | — | — |
| Operator/time logs (own) | CRUD | CRUD | CRU | R |

Notes: ZATCA *submission* is a state-changing action gated separately from invoice viewing. Destructive ops always additionally pass `verifyDestructiveGate()` (type-to-confirm + PIN/recovery) regardless of role.

---

## 4. Data model

- **Operator record** gains a structured `roleKey` (`owner|manager|operator|viewer`). The existing `role` string is **kept as a free-text display label** (e.g. "Senior Technician") — decoupled from permission logic. Migration sets `roleKey` from the old string.
- **Permission matrix** is a single declarative constant in `app-security.js`:
  ```
  const ROLE_PERMS = {
    owner:    { orders:'CRUD', inventory:'CRUD', clients:'CRUD', invoicing:'CRUD',
                analytics:'R', settings:'CRUD', security:'CRUD', cloud:'CRUD', destructive:'C' },
    manager:  { orders:'CRUD', inventory:'CRUD', clients:'CRUD', invoicing:'CRU',
                analytics:'R', settings:'R', security:'', cloud:'', destructive:'' },
    operator: { orders:'CRU', inventory:'CRU', clients:'R', invoicing:'R',
                analytics:'', settings:'', security:'', cloud:'', destructive:'' },
    viewer:   { orders:'R', inventory:'R', clients:'R', invoicing:'R',
                analytics:'', settings:'', security:'', cloud:'', destructive:'' },
  };
  ```
- **Check primitive** (new, in `app-security.js`):
  ```
  can(area, action /* 'C'|'R'|'U'|'D' */) → boolean
  ```
  Resolves the active operator's `roleKey` (falls back to `owner` when lock disabled, preserving today's "all accessible" behavior), looks up `ROLE_PERMS`, returns whether `action` is granted. No string-matching of localized labels anywhere.

---

## 5. Enforcement

Single source of truth in `app-security.js`; callers ask `can()`. Two layers:

1. **UI gating (discoverability).** `applyOperatorPermissions()` is rewritten to drive **all** tab/control visibility from `can(area,'R')` / `can(area,'C')` instead of the current `isAdmin/isTech/isSales` branches. Mutating buttons (save, delete, submit) get `disabled` + `restricted-blur` when `!can(area, action)`. The Settings→Security panel and Cloud panel render only when `can('security','U')` / `can('cloud','U')`.
2. **Action gating (authority).** Every mutating handler calls `can(area, action)` and bails (toast `rbac.denied`) before writing. UI gating alone is not trust; the check at the write path is. Destructive paths keep their existing `verifyDestructiveGate()` on top.

`getAdminOperator()` is redefined to prefer `roleKey === 'owner'` (with the legacy `includes('admin')` kept as a fallback during migration). `securityIsEnabled()` is unchanged.

---

## 6. Cloud alignment (Phase 1)

Per [Phase 1 spec](./KHAYT-3.0-PHASE1-SPEC.md), identity is `users → org(1) → shop(1) → devices`, JWT scoped to `shopId`. RBAC binds as follows:

- Add `role` (= our `roleKey`) to the server `users`/membership row — a property of **(user, shop)**, set by the Owner.
- On Cloud connect, the signed-in cloud user maps to a **local operator** carrying that `roleKey`; `applyOperatorPermissions()` consumes it identically to a local operator. The desktop stays the **single writer** (Phase 1 §1) — RBAC governs *who, on this device, may act*, orthogonal to E2E sync.
- The **org owner** (`orgs.owner_user_id`) is always `roleKey: owner` and cannot be demoted below the last-owner rule (§8).
- Cloud-off: no change — `roleKey` comes purely from the local operator record. RBAC never depends on a JWT being present.

---

## 7. Migration from operatorLock

One-time, idempotent, on store load (alongside existing migrations):

1. For each operator without `roleKey`: derive it from `role` — `admin`→`owner`, `tech`/`technician`/`sales`→`operator`, anything else→`operator`, **empty/sole operator**→`owner`.
2. Preserve the original `role` string verbatim as the display label.
3. If no operator resolves to `owner`, promote `getAdminOperator()`'s result (or the first PIN-holder) to `owner` (last-owner guarantee).
4. `operatorLockEnabled`, `activeOperatorId`, `securityEnabled`, `recoveryCodeHash` are untouched. An owner who never used operator-lock: `lock disabled → can()` returns owner-level true for everything → zero behavior change.

---

## 8. Edge cases

- **Last-owner protection:** the role editor refuses to demote or delete the final `roleKey: owner`. Same rule server-side for the org owner. Always ≥1 owner.
- **Offline:** RBAC is fully local (matrix + operator record); never blocks on network. A cached cloud user keeps its last-known `roleKey` while offline; revocation applies on next successful pull.
- **Role downgrade mid-session:** re-run `applyOperatorPermissions()` whenever roles change or active operator switches; in-flight mutating handlers re-check `can()` at submit time, so a downgrade takes effect on the next action, not just on tab reload.
- **Active operator deleted / role removed:** treat as locked → `activeOperatorId = null` → prompt switch (existing lock flow).
- **Localized labels as keys:** eliminated — logic uses `roleKey` only; `role` is cosmetic.

---

## 9. Test plan & definition of done

- **Matrix coverage:** for each role × area × action, `can()` returns the matrix value (table-driven test).
- **Lock-off parity:** with `operatorLockEnabled=false`, `can()` is true everywhere → identical to today (golden behavior).
- **Migration:** legacy operators (`admin`/`technician`/`sales`/empty) map to expected `roleKey`; display `role` preserved; ≥1 owner guaranteed; idempotent on re-run.
- **Enforcement is real:** a viewer/operator calling a guarded mutation handler directly is rejected (not just UI-hidden).
- **Last owner:** demote/delete the sole owner is blocked locally and server-side.
- **Destructive still gated:** owner still passes `verifyDestructiveGate()`; non-owners cannot reach destructive actions at all.
- **Cloud mapping:** connected cloud user's server role yields the matching local `roleKey`; offline retains last-known role; demote-then-pull updates permissions.

**DoD:** a single declarative matrix in `app-security.js` drives both UI and action gating via `can()`; legacy operator-lock data migrates losslessly; a lock-off owner sees **zero** change; a cloud user maps onto a local role with last-owner protection enforced both sides. No new always-on requirement and no Cloud dependency for local RBAC.
