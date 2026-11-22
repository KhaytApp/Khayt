# Activity log / audit trail — tamper-evident record of who did what

**Scope:** a local, append-only, hash-chained log of high-value actions (order/payment/inventory/settings/security/auth changes — who, when, what changed) that syncs append-only when Cloud is connected. Closes the audit gap required by [KHAYT-3.0-RBAC-SPEC.md](./KHAYT-3.0-RBAC-SPEC.md) and [KHAYT-3.0-SECURITY-MODEL.md](./KHAYT-3.0-SECURITY-MODEL.md) §3 ("Audit · Repudiation → append-only log") and §7.

**Governing principle:** **local-first, append-only, privacy-preserving.** The log is a normal persisted collection that works with Cloud off; it is never deleted or rewritten, only appended; and it records *what field changed and who changed it* — **never the secret/PII values themselves**. An owner who never enables operator-lock sees a single-actor log of their own actions and nothing changes about how the app behaves.

---

## 1. What we build on

- **Save choke point** (`renderer/app-state.js`): `saveAll()` debounces → `_doSave(buildStoreSnapshot())`; `flushSave()` is the immediate path. [Phase 0](./KHAYT-3.0-PHASE0-SPEC.md) inserts `KhaytSync.stampChanges(snapshot)` inside `_doSave` *before* `hubAPI.saveStore` — it already computes, per record, **whether content changed** (`fingerprint` vs `_lastSavedIndex`), bumps `rev`, and emits **tombstones** for deletes. The audit log is a **consumer of that exact diff**: it asks Phase 0 "what changed this save?" instead of re-diffing.
- **Operator identity** (`renderer/app-security.js`): `settings.activeOperatorId` + `operators[]`; `securityIsEnabled()`; RBAC's `roleKey` (`owner|manager|operator|viewer`). Attribution = the active operator at save time (already resolved this way in `integrations.js`, `ops-locations.js`, `settings.js`).
- **The mutating actions worth auditing** live in `order-flows.js` (`updateStatus`, `openPaymentModal`/`clearPayment`), `invoicing.js` (credit notes ~L1101, ZATCA submit), `inventory.js` (`openStockAdjustModal`), and the security flows in `app-security.js`.

---

## 2. Data model

New persisted collection `_auditLog` (array; carried in the snapshot like any collection, but **append-only** — never spliced/edited). Each entry:

| Field | Type | Meaning |
|-------|------|---------|
| `id` | string | `uid()` — stable entry id |
| `seq` | integer ≥ 1 | Monotonic local sequence (chain ordering; authoritative over `ts`) |
| `ts` | ISO string | Wall-clock at capture (advisory/display only) |
| `actor` | `{ operatorId, name, roleKey }` | Active operator at the time; `{operatorId:null, roleKey:'owner'}` when lock is off (mirrors RBAC's "lock-off = owner" fallback) |
| `action` | string | Machine key from the allowlist (§3), e.g. `order.status_changed` |
| `entity` | `{ collection, id }` | What was acted on (`printLog`/`inventory`/`settings`/`auth`…) |
| `summary` | string | Short human label (localized at render, **not** stored localized) |
| `changes` | `[{ field, from?, to? }]` | **Field names + change descriptors, never raw sensitive values** (§4) |
| `rev` | integer | The Phase 0 `rev` of the record after the change (ties the log entry to the synced record version) |
| `hashPrev` | string (hex) | SHA-256 of the **previous** entry's `hash` (chain link; `""` for the genesis entry) |
| `hash` | string (hex) | SHA-256 over the canonical serialization of this entry **excluding `hash`** (includes `hashPrev`) |

`settings` is the single pseudo-record (Phase 0 §2.1) → audited as `entity:{collection:'settings', id:'settings'}`.

---

## 3. What's audited (allowlist — not every keystroke)

Audit is an **explicit allowlist of high-value events**, not a firehose. Default detail level is opt-in, **but the security-critical subset is always logged whenever operator-lock/RBAC is on**, regardless of the detail setting.

| Category | Actions (machine keys) | Always-on when locked? |
|---|---|---|
| Orders/quotes | `order.created`, `order.status_changed`, `order.deleted`, `quote.converted` | deletes: yes |
| Payments | `payment.recorded`, `payment.cleared`, `creditnote.issued` | yes |
| Invoicing | `invoice.zatca_submitted`, `invoice.voided` | yes |
| Inventory | `inventory.stock_adjusted`, `inventory.item_deleted` | deletes: yes |
| Clients | `client.created`, `client.deleted` | deletes: yes |
| Settings | `settings.changed` (field-level), `settings.imported` | yes |
| Security/roles | `security.enabled/disabled`, `operator.role_changed`, `operator.created/deleted`, `recovery.regenerated`, `destructive.gate_passed` | **always** |
| Auth | `auth.operator_switched`, `auth.lock_unlocked`, `auth.pin_failed` | **always** |
| Data | `store.wiped`, `store.restored`, `store.imported` | **always** |

Detail levels: `off` (no log — only when lock is also off), `key-events` (the always-on rows above), `detailed` (all rows + per-field `changes`). When lock/RBAC is on, the floor is `key-events`; it cannot be lowered to `off`.

---

## 4. Capture approach

Two complementary capture paths, both feeding one `appendAudit(entry)` primitive that computes `seq`, `hashPrev`, `hash` and pushes to `_auditLog`:

1. **Entity changes — hook the save choke point.** After `KhaytSync.stampChanges(snapshot)` runs in `_doSave`, the stamper returns the set of changed/created/deleted records for this save (it already knows — it just compared fingerprints and emitted tombstones). An `auditFromStamp(changedSet)` step maps each changed record to its allowlisted `action` via a small **collection→action resolver** and emits one entry per audited change, with `changes` derived from the Phase 0 fingerprint diff (the field list, not values). This means **we capture WHAT changed from the same source of truth that decides what syncs** — no second diff, no drift.
2. **Security/auth events — explicit calls.** Auth and security actions don't always go through a record save (e.g. a failed PIN, an operator switch). These call `appendAudit(...)` directly at the site: `verifyDestructiveGate` (gate passed), the lock/unlock + operator-switch flows (`ops-locations.js`, `settings.js`), `setupAdminSecurity`/recovery regen (`app-security.js`). Each then triggers a normal `saveAll()` so the entry persists with the rest of the store.

**Privacy rule (enforced in `appendAudit`):** `changes[].from/to` carry raw values **only** for non-sensitive scalar fields (status, amount-on-an-order, quantity). For any field on the secret/PII denylist (PINs, recovery codes, API keys, payment creds, ZATCA certs, client phone/email, addresses) we record the **field name and a redaction marker** (`{field:'pinHash', changed:true}`) — never the value. The denylist reuses the existing export-redaction field set (security model §1.6) so there is one list to maintain.

---

## 5. Tamper-evidence (hash chain)

Each entry's `hash = SHA256(canonical(entry-without-hash))` and `hashPrev` points at the prior entry's `hash`. Editing or removing any past entry breaks every subsequent `hashPrev` link, which a verifier detects.

- **Append primitive:** `appendAudit` reads the last entry's `hash` into the new `hashPrev`, computes `hash`, assigns `seq = lastSeq + 1`. The chain head (`{seq, hash}`) is also mirrored into `_syncMeta.auditHead` so a truncation that drops the tail (deleting the last N entries) is also detectable.
- **Verifier:** `verifyAuditChain()` walks the log in `seq` order recomputing each `hash` and checking the `hashPrev` link + `auditHead`. Returns `{ok, firstBrokenSeq?}`. Surfaced in the activity view ("Integrity: verified ✓ / broken at #N") and runnable headless in tests.
- **Honest scope:** this is **tamper-evident, not tamper-proof.** A local attacker with write access can recompute the whole chain. The chain detects accidental corruption and casual edits; the strong guarantee comes when Cloud is connected and the **server-side append-only log** holds an independent copy (security model §3 "append-only sync/access log"). We document this limitation rather than overclaiming.

---

## 6. Retention & viewing

- **Viewing:** a filterable Activity view (actor, category, entity, date range, free-text on summary), newest-first, paginated. Each row links to the affected entity where one still exists. An integrity banner shows `verifyAuditChain()` result.
- **Export:** export the (filtered) log to CSV/JSON for the owner's records. Export runs the same redaction denylist (§4) — no secrets leak via export, consistent with security model §1.6.
- **Retention:** append-only, so we **never edit** entries; we prune from the **tail** (oldest first) by policy — default keep 2 years / last 50,000 entries, configurable, with the always-on security/auth subset kept longer. Pruning advances a `_syncMeta.auditPrunedThrough = {seq, hash}` marker so the chain remains verifiable from the new base (the new oldest entry's `hashPrev` is checked against the pruned marker). In Cloud mode, prune locally only after the backend has acknowledged the entries (mirrors Phase 0 tombstone pruning §2.2).

---

## 7. Cloud sync (append-only union)

`_auditLog` is **not** last-writer-wins. Per the security model it is **append-only across devices**: `applyDeltas` for `_auditLog` performs a **union by `id`** (never overwrite, never delete an existing entry), then re-sorts by `(ts, seq, deviceId)` for display. Because two devices generate independent local `seq`/chains offline, the server treats device chains as **per-device segments**; the union is the audit of record and the server-side log is the durable, independent copy. Entries are E2E-encrypted at rest like all operational data (security model §1.2); the server sees ciphertext + minimal metadata only. No values bypass the §4 redaction on the wire.

---

## 8. Integration points (exact)

- `renderer/app-state.js` — in `_doSave`, after `KhaytSync.stampChanges(snapshot)`, call `KhaytAudit.auditFromStamp(stampResult)`. Add `_auditLog` to the collection set (`collectStoreCollections`/`applyStoreFromSnapshot`/`replaceStoreFromSnapshot`) and reset it on import like other collections. Bump `STORE_VERSION` (migration §9).
- `renderer/sync` (Phase 0 `KhaytSync.stampChanges`) — return the changed/created/deleted record set so audit can consume it without re-diffing; add `_auditLog` union handling to `applyDeltas`.
- `renderer/app-security.js` — `appendAudit`/`verifyAuditChain` primitives live here (owns identity + the redaction denylist); explicit calls from `verifyDestructiveGate`, `setupAdminSecurity`, recovery regen, PIN-fail path.
- `renderer/ops-locations.js`, `renderer/settings.js` — explicit `appendAudit` on operator switch, lock/unlock, role change, security toggle.
- `renderer/order-flows.js` / `invoicing.js` / `inventory.js` — mostly covered automatically via the save hook; add explicit calls only where the action isn't a plain record save (e.g. ZATCA submit success).
- New `renderer/audit.js` (the `KhaytAudit` module + resolver) and an Activity view in the appropriate tab gated by RBAC `can('settings','R')` (owner/manager).

---

## 9. Edge cases

- **Clock skew / `ts` backwards:** `seq` + `hashPrev` are authoritative for ordering and integrity; `ts` is display-only (same stance as Phase 0 §5).
- **Large diffs / bulk operations:** cap `changes` to N fields with an overflow marker (`+K more fields`); a bulk action emits one summary entry, not one per record, to avoid log explosion.
- **Log of the log:** mutations to `_auditLog` itself are **never** audited (no recursion); the stamper/resolver explicitly skips `_auditLog`, `_tombstones`, `_syncMeta`.
- **Lock off:** with `operatorLockEnabled=false`, detail may be `off` (no entries) or owner can opt in; `actor` is the lock-off owner fallback. Turning lock on raises the floor to `key-events` going forward (no retroactive entries).
- **Import / full replace:** an imported store may carry its own `_auditLog`; on import we **append our own** `store.imported` entry rather than trusting the imported chain as authoritative — and re-verify. We do not mass-generate entries for pre-existing records (parallels Phase 0 "don't mass-bump revs on import").
- **Migration first run:** existing stores have no history; we start the chain at the migration with a genesis `store.migrated` entry (`hashPrev:""`). No back-dating.
- **Save failure:** the entry is in the snapshot; if `hubAPI.saveStore` fails, the entry retries with the next save (it lives in memory until persisted) — same durability as every other record.

---

## 10. Migration (STORE_VERSION bump)

On load of a pre-audit store: initialize `_auditLog = []`, set `_syncMeta.auditHead`/`auditPrunedThrough`, append a single genesis entry, persist at the new version. Idempotent; purely additive; no data loss; zero behavior change for a lock-off owner who leaves audit `off`.

---

## 11. Test plan (node:test + jsdom)

New `test/audit-log.test.js`:

- **append + chain:** N appends produce strictly increasing `seq`, each `hashPrev` == prior `hash`; `verifyAuditChain().ok === true`.
- **tamper detection:** mutate a middle entry's `summary` → `verifyAuditChain()` returns `ok:false, firstBrokenSeq`= that entry; drop the tail → caught via `auditHead`.
- **save-hook capture:** changing an order's status via the normal save path emits exactly one `order.status_changed` with the right `entity`, `actor`, and `rev` from the stamp.
- **redaction:** a settings change to an API key / a client phone edit logs the **field name + redaction marker**, never the value (assert value absent from entry and from CSV/JSON export).
- **always-on floor:** with lock on and detail set to `off`, security/auth/delete events are still logged; with lock off + detail `off`, nothing is logged.
- **attribution:** active-operator switch is reflected in subsequent entries' `actor`; lock-off entries carry the owner fallback.
- **no recursion:** mutating `_auditLog`/`_tombstones`/`_syncMeta` produces no audit entries.
- **cloud union:** `applyDeltas` merges two device segments by `id` without overwrite/delete; existing entries never mutated; sorted deterministically.
- **prune:** tail prune advances `auditPrunedThrough` and the post-prune chain still verifies from the new base.
- **migration:** pre-audit store gains an empty log + genesis entry; second load is a no-op (idempotent).

## 12. Definition of done

- `_auditLog` exists as an append-only, hash-chained collection captured from the Phase 0 stamp (entity changes) + explicit calls (security/auth), with attribution from the active operator/`roleKey`.
- The allowlisted security/auth/delete subset is **always** logged when lock/RBAC is on; no secret or PII value is ever stored or exported (redaction reuses the export denylist).
- `verifyAuditChain()` detects edits, reordering, and tail truncation; the Activity view shows integrity status, filters, and export.
- Cloud sync merges logs append-only (union, no overwrite/delete), E2E-encrypted, per the security model.
- A lock-off owner who leaves audit `off` sees **zero** behavior change (golden-snapshot test); full suite green.
