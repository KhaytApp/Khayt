# Schema migration & versioning strategy: implementation spec

**Scope:** one unified migration pipeline for every field, settings key, and collection the 3.0 specs add — orders (QC/shipping/scheduling), machines, clients (marketing), settings, and new collections (`_auditLog`, `K.CAMPAIGNS`, `K.CAMPAIGN_LOG`). Today each feature spec decides independently whether to "lazy-default on read" (QC, shipping, scheduling, print-files, RBAC) or bump `STORE_VERSION` (Phase 0 does 5→6; Audit says "bump" without a number). That divergence is the problem: revs creep, two features race for "6," and lazy-on-read fields never get stamped a `rev`/`updatedAt` until first edit. This spec replaces ad-hoc decisions with a registry. Implements the schema-discipline clause of [KHAYT-3.0-ROADMAP.md](./KHAYT-3.0-ROADMAP.md); **composes with** [KHAYT-3.0-PHASE0-SPEC.md](./KHAYT-3.0-PHASE0-SPEC.md).

**Governing principle:** the store has exactly **one** version, `STORE_VERSION`, advanced **only** by appending an ordered migration step. A feature never bumps the number itself and never writes a bespoke one-time migration inside `loadAll` (the dedupe / kanban / lanApi / designTheme blocks are the legacy pattern we are retiring). Every step is **idempotent, additive, forward-only, and lossless**: re-running it is a no-op, it only adds fields/collections (never renames-in-place or deletes), it never reverts, and it never drops a record. A store opened by a newer app upgrades cleanly on first `loadAll`; a newer export opened by an older app degrades gracefully (unknown keys ignored — `store-validate.js` already allows them).

---

## 1. Where it hooks

`loadAll` (`renderer/app-state.js`) is the single entry point. Today it calls `applyStoreFromSnapshot` then runs three inline one-time blocks. We insert the pipeline **after** `applyStoreFromSnapshot` (so collections are loaded, filtered, settings-merged) and **before** the Phase 0 stamper rebuilds `_lastSavedIndex`:

```
loadAll():
  store = loadStore() || migrateFromLocalStorage()
  applyStoreFromSnapshot(store)              // existing: validate + filter + merge settings
  KhaytMigrate.run(store?.version ?? 0)      // ← NEW: ordered vN→vN+1 pipeline, mutates live state
  KhaytSync.rebuildIndex()                   // Phase 0: build _lastSavedIndex from migrated state
  saveAll()  // only if any step reported changed
```

Ordering with Phase 0 is load-bearing: migrations run **before** the index is built, so a backfilled field is part of the baseline fingerprint and does **not** spuriously bump `rev` on the next save. Phase 0's own 5→6 backfill (id/rev/updatedAt/tombstones/`_syncMeta`) becomes **step 6** in this registry — it is no longer special-cased.

---

## 2. Migration framework

### 2.1 The step registry
A migration is `{ to, name, run(state) -> boolean }` where `to` is the target version it produces, `name` is a stable machine key (for logs/audit), and `run` mutates the live collections in place, returning `true` if it changed anything.

```js
// renderer/store-migrate.js
const STEPS = [
  { to: 6,  name: 'sync-foundation',   run: migrate_sync },        // Phase 0 (was inline)
  { to: 7,  name: 'change-tombstones', run: migrate_tombstoneMeta },
  // … 3.0 steps, §4
];
STEPS.sort((a, b) => a.to - b.to);                 // ordered, no gaps, strictly increasing
const TARGET_VERSION = STEPS[STEPS.length - 1].to; // === KhaytStore.VERSION
```

`STORE_VERSION` in `renderer/store.js` and `lib/store-validate.js` is **derived from / asserted equal to** `TARGET_VERSION` — a unit test fails the build if they drift (§7).

### 2.2 run-on-load
```js
function run(fromVersion) {
  let changed = false;
  for (const step of STEPS) {
    if (step.to <= fromVersion) continue;          // already applied → skip (forward-only)
    const did = step.run(liveState);               // idempotent even if version stamp lied
    changed = changed || did;
  }
  settings.__storeVersion = TARGET_VERSION;         // stamp; persisted in settings, not just export
  return changed;
}
```

`fromVersion` is `store.version` if the export carried one, else `settings.__storeVersion`, else `0` (legacy disk snapshots never carried a version → treat as pre-everything, all steps run; idempotency makes that safe).

### 2.3 Idempotency rule (the one invariant every step must hold)
Each `run` guards every write with "is it already there?" and only then writes — never assumes the version stamp is accurate. Canonical forms:
- **field backfill:** `if (rec.x === undefined) rec.x = default;` (never overwrite an existing value).
- **collection init:** `if (!Array.isArray(state.foo)) state.foo = [];`
- **derive-from-legacy:** compute target only when target absent **and** legacy present; leave legacy field in place (additive — never delete the old field).

A step must be safe to run twice in a row with no further change. This is the single property the test plan asserts hardest, because a corrupt/missing version stamp must never cause data churn or a `rev` storm.

---

## 3. Versioning policy

- **Bump `STORE_VERSION` ⇔ append exactly one step.** No other reason. A PR that adds a field touches `STEPS` (a new entry) and the validator allowlist (§5); it does **not** edit the integer by hand.
- **One step per feature batch, not per field.** A feature adding three order fields registers **one** step that backfills all three. Multiple features merging in the same release each get their own `to`, assigned by merge order (rebase resolves conflicts on `TARGET_VERSION` trivially since steps are append-only).
- **Lazy-on-read is still allowed for UI defaults**, but any field that participates in sync/export/audit **must** also be backfilled by a step, so it has a `rev`/`updatedAt` from day one rather than only after first edit. (This is the gap in the current QC/shipping/scheduling specs — they default on read but never stamp.)
- **No renames, no type changes in place.** To rename `role`→`roleKey`, add `roleKey` (derive from `role`), keep `role`. Removal, if ever, is a far-future step after a full release of dual-write.

---

## 4. The 3.0 migration sequence

Concrete ordered steps. Each is small, idempotent, additive. `to: 6` is Phase 0, already specified there; the rest are new.

| `to` | name | backfills (only when absent) |
|------|------|------------------------------|
| 6 | `sync-foundation` | Phase 0: per-record `id`/`rev`/`updatedAt`; init `_tombstones=[]`, `_syncMeta`. |
| 7 | `audit-log` | init `_auditLog=[]`; `_syncMeta.auditHead={seq:0,hash:''}`, `_syncMeta.auditPrunedThrough`; append one genesis entry `store.migrated` (`hashPrev:''`). (AUDIT-SPEC §10.) |
| 8 | `rbac-rolekey` | per `operators[]`: `roleKey` derived from legacy `role` (`admin→owner`; `tech/technician/sales→operator`; else `owner`); **guarantee ≥1 `owner`**; keep `role`. (RBAC-SPEC §7.) |
| 9 | `qc-fields` | per `printLog[]`: `qcStatus=null`, `defects=[]`, `inspector=null`; `settings.qc={enabled:false,requireInspector:false,warrantyDays:30,requirePhotoOnFail:false}`. Reprint/RMA fields stay lazy (write-on-action). |
| 10 | `shipping-fields` | per `printLog[]`: `carrier=null`, `shippedAt=null`, `shippingStatus=null`, `shippingHistory=[]`, `shipmentMeta=null`; `settings.shipping={}` (per-carrier subkeys lazy). |
| 11 | `scheduling-fields` | per `machines[]`: `buildVolume=null`; per `printLog[]`: `dimensionsMm=null`, `requiredNozzleMm=null`. (Null = unconstrained.) |
| 12 | `marketing` | init `campaigns=[]`, `campaignLog=[]` (new `K.CAMPAIGNS`/`K.CAMPAIGN_LOG`); per `clients[]`: `marketing={consent:'unknown',tags:[],optOutAt:null,lastContacted:null}`; `settings.marketing={enabled:false,quietStart,quietEnd,throttle:{}}`. |
| 13 | `printfiles` | `settings.autoFillFromGcode=true`, `settings.gcodeSupportInWeight=true`. (Per-part `printFileRef`/`parsedTimeMins`/`parsedGrams` stay lazy — parts are nested in orders and written on calc; no backfill needed.) |

Reserved-but-empty steps are never created; a future feature simply appends `to:14`. New collections (`_auditLog`, `campaigns`, `campaignLog`) must also be wired into `collectStoreCollections`, `replaceStoreFromSnapshot`, `applyStoreFromSnapshot`, `ARRAY_COLLECTIONS`, and `COLLECTION_FILTERS` in the **same** PR as their step — the migration creates them on existing stores; the wiring persists/loads/exports them.

---

## 5. Validation alignment

`store-validate.js` (and its `lib/` re-export) is the load/import gatekeeper. Per step that adds a collection, the **same PR** updates the allowlist so the new collection survives `normalizeStoreSnapshot`:

- **New array collection** → add its key to `ARRAY_COLLECTIONS` and a filter to `COLLECTION_FILTERS` (`campaigns`/`campaignLog` → `isValidRecord`; `_auditLog` → a dedicated `isValidAuditEntry` checking `id`+`seq`+`hash`). Underscore-prefixed sync/audit collections (`_tombstones`, `_auditLog`) are allowlisted explicitly — they are not user records but must pass through load/export untouched.
- **New fields on existing records** → no validator change. `store-validate` is allow-by-default for unknown keys on records (PRINTFILES-SPEC confirms), so additive fields need nothing. Only add a `COLLECTION_FILTERS` predicate when a field becomes a **required** identity key (none in 3.0).
- **`MAX_EXPORT_VERSION`** tracks `TARGET_VERSION` automatically (derived, §2.1), so a v13 export validates without warning while a hypothetical v14 export on a v13 app surfaces the existing "newer than supported" warning (non-fatal — §6).

Validator and migration share `isValid*` predicates from `KhaytStoreValidate`; no duplicate definitions.

---

## 6. Import / downgrade handling

- **Old export into new app (upgrade):** `replaceStoreFromSnapshot` → `applyStoreFromSnapshot` → then `loadAll` calls `KhaytMigrate.run(import.version ?? 0)`. The full pipeline runs against the imported state exactly as a disk load would; backfills add the missing fields; the result is stamped `TARGET_VERSION` and saved. After import, Phase 0 resets `_lastSavedIndex` from the migrated snapshot and does **not** mass-bump revs (PHASE0-SPEC §5).
- **New export into old app (downgrade):** the older app's `validateStoreSnapshot` warns (`version > MAX_EXPORT_VERSION`) but **salvages** — it keeps every collection it recognizes and silently ignores unknown ones (`_auditLog`, `campaigns`, new fields). No data is destroyed; the user just can't see the newer features. This is why forward-only + additive matters: a downgrade is lossy *to view*, never *to disk corruption*. We do not attempt down-migrations.
- **Mid-version export** (e.g. a v9 export opened on a v13 app): `run(9)` skips steps 6–9, applies 10–13. The version-stamp-may-lie guard (§2.3) means even a hand-edited/wrong stamp self-heals because each step is idempotent.

---

## 7. Test plan (node:test + jsdom harness)

New `test/store-migrate.test.js`:

- **registry integrity** — `STEPS` strictly increasing `to`, no gaps, no dup names; `TARGET_VERSION === KhaytStore.VERSION === store-validate STORE_VERSION === lib re-export` (the build-drift guard).
- **idempotency (per step)** — run step twice on the same fixture → second run returns `false`, byte-identical state. Run the **whole pipeline** twice → second pass no-op.
- **forward-only** — `run(13)` on a v13 store changes nothing; `run(0)` on a legacy unversioned snapshot applies all steps.
- **additive / lossless** — a record with an existing `qcStatus='pass'` is **not** overwritten by `qc-fields`; a record with no fields gets defaults; record count unchanged across the pipeline.
- **rbac derive** — `role:'admin'`→`roleKey:'owner'`; all-viewers store ends with ≥1 owner; legacy `role` preserved.
- **new-collection wiring** — after `marketing`/`audit-log`, the collection round-trips through `buildExportPayload` → `applyStoreFromSnapshot` and survives `normalizeStoreSnapshot` (not dropped).
- **Phase 0 composition (critical)** — after migration + `rebuildIndex`, the **first** `saveAll` bumps **no** revs (backfilled fields are in the baseline fingerprint). This is the regression guard against migration-induced rev storms.
- **import upgrade** — a captured v5 export imported into the v13 app upgrades cleanly, no data loss, ends stamped 13.
- **downgrade salvage** — a v13 export normalized by the v5 validator keeps all v5 collections, drops only unknown keys, warns (not errors).

## 8. Definition of done

- Single ordered `STEPS` registry in `renderer/store-migrate.js`; `loadAll` calls `KhaytMigrate.run` and the three legacy inline blocks (dedupe/kanban/lanApi/designTheme) are folded into steps or left as-is **only** if pre-`STORE_VERSION`-1 (documented as grandfathered).
- `STORE_VERSION` advanced only via an appended step; drift test green across the three definitions.
- Every 3.0 feature field/collection lands as a registered step + matching validator allowlist entry in the same PR; no feature edits the integer by hand.
- Full suite green incl. new migration tests and the Phase 0 golden-snapshot test; a cloud-disabled user sees zero behavior change beyond the (additive, invisible) backfilled fields.
