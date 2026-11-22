# Phase 0 — Sync foundation: implementation spec

**Scope:** local-only change tracking + delta format + Sync Engine interface. **No backend, no cloud, no UI for cloud.** Ships as 2.x "internal plumbing + incremental backups." Implements §3 of [KHAYT-3.0-ROADMAP.md](./KHAYT-3.0-ROADMAP.md).

**Governing principle:** the app must behave **identically** with this change for a user who never touches cloud. The only user-visible effect is faster/incremental backups.

---

## 1. Where it hooks

The store has one choke point (audited in `renderer/app-state.js` / `renderer/store.js`):

```
saveAll()  ──debounce 300ms──▶  _doSave(buildStoreSnapshot())  ──▶  hubAPI.saveStore(snapshot)
flushSave() ─immediate────────▶  _doSave(buildStoreSnapshot())  ──▶  hubAPI.saveStore(snapshot)
```

- `buildStoreSnapshot()` returns `{ ...collections }` — a **shallow** object whose arrays/records are the **same references** as the live in-memory state. **Stamping a record in the snapshot stamps the live record** (and thus what gets persisted). This is the property the whole design relies on.
- **Hook point:** a new `stampChanges(snapshot)` called inside `_doSave` *before* `hubAPI.saveStore`, so it covers both `saveAll` and `flushSave` with one insertion.

```js
function _doSave(snapshot) {
  if (!window.hubAPI?.saveStore) return Promise.resolve();
  KhaytSync.stampChanges(snapshot);          // ← Phase 0: stamp + tombstones, mutates in place
  _saveChain = _saveChain.then(() => window.hubAPI.saveStore(snapshot)). /* …unchanged… */
}
```

---

## 2. Data shapes

### 2.1 Per-record change metadata
Two reserved fields added to every record in the 24 array collections:

| Field | Type | Meaning |
|-------|------|---------|
| `updatedAt` | ISO string | Wall-clock of last *content* change (set by the stamper) |
| `rev` | integer ≥ 1 | Monotonic per-record version; bumped on each content change |

`settings` is a single object, not a record list → tracked as one pseudo-record with id `"settings"` in a dedicated meta entry (its own `rev`/`updatedAt`).

### 2.2 Tombstones (persisted)
Deletes must propagate, so they survive restarts until synced. New persisted collection `_tombstones`:

```js
{ id, collection, deletedAt /* ISO */, rev /* of the record when deleted */ }
```
Pruned by retention (e.g. keep 90 days / last 5000) in local mode; in cloud mode, pruned once the backend acknowledges the cursor past `deletedAt`.

### 2.3 Sync meta (persisted)
```js
_syncMeta = {
  schema: 1,
  cursor: { rev: <max rev seen>, updatedAt: <max> },  // high-water mark
  lastStampAt: <ISO>,
}
```

Bump `STORE_VERSION` 5 → 6; `loadAll` migration backfills (see §6).

---

## 3. The change-stamper algorithm

State kept in memory (rebuilt on load): `_lastSavedIndex: Map<"coll:id", fingerprint>`.

```
stampChanges(snapshot):
  now = ISO()
  nextIndex = new Map()
  for each [coll, arr] in snapshot (array collections):
    for each rec in arr:
      ensureId(rec, coll)                      // backfill uid() if missing (see §5)
      fp = fingerprint(rec)                     // canonical hash EXCLUDING updatedAt, rev
      key = `${coll}:${rec.id}`
      prev = _lastSavedIndex.get(key)
      if prev === undefined OR prev !== fp:      // new or content-changed
        rec.rev = (rec.rev || 0) + 1
        rec.updatedAt = now
      nextIndex.set(key, fingerprint(rec))       // fp is identical (excludes the stamped fields)
  // tombstones: keys present last save, absent now
  for each key in _lastSavedIndex not in nextIndex:
    [coll, id] = split(key); push _tombstones {id, coll, deletedAt: now, rev: …}
  handleSettings(snapshot.settings, now)         // per-key or whole-object rev
  _lastSavedIndex = nextIndex
  _syncMeta.cursor = recomputeHighWater()
```

**`fingerprint(rec)`** — stable serialization that **excludes** `updatedAt`, `rev`, and a per-collection list of **volatile/derived fields** (e.g. transient UI flags, cached computed values). Key-sorted `JSON.stringify`. The exclude-list is the one place that needs care; default to "include everything except the two reserved fields" and add exclusions only where a field is provably derived.

**Cost:** one fingerprint per record per save. At realistic scale (thousands of records) this is sub-millisecond-to-low-ms and the save is already debounced 300 ms. If it ever matters, fingerprint lazily / cache by reference identity.

---

## 4. Delta format + engine

### 4.1 Delta extract/apply
```
extractDeltas(sinceCursor) -> {
  deltas:    [{ collection, record }],     // records with rev/updatedAt > cursor
  tombstones:[{ id, collection, deletedAt }],
  cursor:    <new high-water>,
}
applyDeltas({deltas, tombstones}) -> merges into live collections per §3.2 conflict policy
```
Used **immediately** for incremental backups (write only what changed since last backup); later as the sync wire format.

### 4.2 Sync Engine interface
```js
const KhaytSync = {
  stampChanges(snapshot),            // §3 — always on (local)
  extractDeltas(cursor),             // §4.1
  applyDeltas(payload),              // §4.1
  setBackend(backend),               // 'local' (default no-op) | CloudBackend (Phase 1)
  status(),                          // 'off' | 'idle' | 'syncing' | 'error'
};
// LocalBackend.push/pull are no-ops; the app is fully sync-shaped with zero cloud.
```

---

## 5. Edge cases

- **ID-less records** (some append logs — `shiftLogs`/`envLogs`/`timeEntries` may lack `id`). `ensureId` backfills `uid()` on first stamp. One-time; persists thereafter.
- **`settings` object** — not a list. Track whole-object `rev`/`updatedAt` in `_syncMeta` (per-key only if/when needed for merge). Respect **secret redaction**: the stamper runs on the live snapshot (secrets intact); redaction stays at the *export* boundary, unchanged.
- **Clock skew / `updatedAt` going backwards** — `rev` is the authoritative monotonic ordering; `updatedAt` is advisory/display. Never trust wall-clock for conflict ordering.
- **Large/blob fields** (photos, NFC dumps as data URLs) — fingerprint may be large; hash them (e.g. cheap rolling hash) rather than embedding in the fingerprint string.
- **Import / `replaceStoreFromSnapshot`** — after a full import, reset `_lastSavedIndex` from the imported snapshot and **do not** mass-bump revs (imported records keep their rev; missing ones backfill to 1).
- **First run after upgrade** — see §6.

---

## 6. Migration (STORE_VERSION 5 → 6)

On `loadAll` of a v5 store:
1. Backfill `id` where missing; set `rev = 1`, `updatedAt = exportedAt || now` for every record (single pass).
2. Initialize `_tombstones = []`, `_syncMeta`.
3. Build `_lastSavedIndex` from the loaded state (so the *next* save doesn't see everything as changed).
4. Persist as v6.

Idempotent; safe to re-run. No data loss; purely additive fields.

---

## 7. Test plan (node:test + jsdom harness)

New `test/sync-foundation.test.js`:

- **stamp: new record** → gets `rev:1` + `updatedAt`.
- **stamp: unchanged record across two saves** → `rev` does **not** bump (fingerprint excludes reserved fields — this is the critical regression guard).
- **stamp: content change** → `rev` bumps by exactly 1, `updatedAt` advances.
- **delete** → tombstone emitted with correct `{id, collection}`; record not resurrected by a later `applyDeltas`.
- **extractDeltas(cursor)** → returns only records past the cursor; empty when nothing changed.
- **applyDeltas** → LWW honors higher `rev`; lower-`rev` incoming is rejected; append-only collections union.
- **id backfill** → id-less log record gets a stable id, unchanged on next save.
- **settings** → secret fields never altered by the stamper; redaction still applies only at export.
- **migration v5→v6** → backfills without bumping revs spuriously; second load is a no-op.
- **LocalBackend** → push/pull no-ops; `status() === 'off'`; app save/load behavior byte-identical to pre-Phase-0 (golden snapshot compare).

---

## 8. Definition of done

- All saves stamp `rev`/`updatedAt`; deletes tombstone; nothing user-visible changes except backups can be incremental.
- `KhaytSync` interface in place with `LocalBackend`; **no** cloud code.
- Full suite green incl. the new tests; e2e theme shells unaffected.
- A user with cloud disabled (everyone, in 2.x) sees zero behavior change — verified by the golden-snapshot test.
