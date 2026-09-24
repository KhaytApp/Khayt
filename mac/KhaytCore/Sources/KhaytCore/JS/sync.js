/**
 * Sync foundation (Phase 0) — local change-tracking, deltas, and the Sync Engine
 * interface. See docs/KHAYT-3.0-PHASE0-SPEC.md.
 *
 * Cloud-independent by construction: with the default LocalBackend (no-op) this
 * only stamps per-record change metadata (`rev` + `updatedAt`), records
 * tombstones for deletes, and can extract/apply deltas — enabling incremental
 * backups today and cloud sync later. No cloud code lives here.
 *
 * The change-stamper runs at the single save choke point (`_doSave`) and mutates
 * records in place; because the snapshot shares record references with live
 * state, stamping the snapshot stamps the persisted records.
 */
(function (global) {
  'use strict';

  const SCHEMA = 1;
  // Collections that are NOT stamped/tombstoned (meta collections we manage).
  const META_COLLECTIONS = new Set(['tombstones']);
  // Reserved fields excluded from a record's content fingerprint, so stamping
  // them never counts as a content change (the critical idempotency property).
  const RESERVED = new Set(['rev', 'updatedAt']);

  /**
   * One change-index per shop — "collection:id" -> {fp, rev}.
   *
   * This used to be a single Map for the whole process, which is correct only
   * while a process holds exactly one store. `stampChanges` calls a record
   * deleted when it is in the index but absent from the snapshot in front of it,
   * so stamping shop B right after shop A marked every one of A's records as
   * deleted and wrote tombstones for them into B — and tombstones win
   * unconditionally, so those go on to remove live records. Proven in
   * test/phase3-delta-roundtrip.test.js before this existed.
   *
   * That is precisely the shape Phase 3 needs (one device, several branches,
   * merged locally), so the index is keyed by scope. Callers that pass no scope
   * share DEFAULT_SCOPE and behave exactly as before — single-shop users are
   * unaffected, which is asserted rather than assumed.
   */
  const DEFAULT_SCOPE = 'default';
  const indexes = new Map();   // scope -> Map("collection:id" -> {fp, rev})

  /**
   * The scope used when a caller names none — which is every caller in the app.
   *
   * The alternative was to thread a shop id through the three call sites
   * (`_doSave`, load, and the post-merge reseed). Two of them seed the index and
   * one reads it, so any disagreement between them silently empties the index,
   * and an empty index makes `stampChanges` treat every record as new: it bumps
   * every rev, and this device then wins every conflict on the next merge,
   * discarding whatever another device legitimately changed. Holding the scope in
   * one place makes the three agree by construction instead of by review.
   */
  let currentScope = DEFAULT_SCOPE;

  function indexFor(scope) {
    const key = scope || currentScope;
    let m = indexes.get(key);
    if (!m) { m = new Map(); indexes.set(key, m); }
    return m;
  }
  function setIndexFor(scope, m) { indexes.set(scope || currentScope, m); }

  function getScope() { return currentScope; }

  /**
   * Point the index at a shop. Pass a falsy id for "no shop" (cloud off).
   *
   * @returns {{ scope: string, seeded: boolean }} — `seeded:false` means the new
   *   scope has no fingerprints yet and the caller MUST seed it before the next
   *   save, for the reason given above. Reported rather than done here because
   *   this module is deliberately given no way to read the store.
   */
  function setScope(scope) {
    const next = scope || DEFAULT_SCOPE;
    if (next !== currentScope) {
      // Learning (or forgetting) what the current store is called is a RENAME,
      // not a switch to another store: connecting a standalone shop to the cloud
      // gives it an id, disconnecting takes it away, and the records on disk are
      // the same records either way. Carrying the fingerprints across keeps the
      // next save from re-stamping the entire store for a change of label.
      //
      // Moving between two real shop ids is a genuine store switch — that is the
      // cross-shop contamination this scoping exists to stop — so nothing is
      // carried, and `seeded:false` tells the caller to seed from the new store.
      const isRename = currentScope === DEFAULT_SCOPE || next === DEFAULT_SCOPE;
      if (isRename && indexes.has(currentScope) && !indexes.has(next)) {
        indexes.set(next, indexes.get(currentScope));
        indexes.delete(currentScope);
      }
      currentScope = next;
    }
    return { scope: currentScope, seeded: indexes.has(currentScope) };
  }

  let backend = null;          // null => LocalBackend (cloud off)
  let statusVal = 'off';

  function nowIso() { return new Date().toISOString(); }

  /** Deterministic, key-sorted serialization (stable across key insertion order). */
  function stableStringify(value) {
    if (value === null || typeof value !== 'object') return JSON.stringify(value);
    if (Array.isArray(value)) return '[' + value.map(stableStringify).join(',') + ']';
    const keys = Object.keys(value).sort();
    return '{' + keys.map((k) => JSON.stringify(k) + ':' + stableStringify(value[k])).join(',') + '}';
  }

  /** Content fingerprint of a record, excluding the reserved change-metadata fields. */
  function fingerprint(rec) {
    const o = {};
    for (const k of Object.keys(rec)) {
      if (RESERVED.has(k)) continue;
      o[k] = rec[k];
    }
    return stableStringify(o);
  }

  /** Array collections in a snapshot, excluding meta collections (e.g. tombstones). */
  function arrayCollections(snapshot) {
    const out = [];
    for (const k of Object.keys(snapshot)) {
      if (META_COLLECTIONS.has(k)) continue;
      if (Array.isArray(snapshot[k])) out.push(k);
    }
    return out;
  }

  /** A record's revision, treating anything missing or malformed as 0. */
  function revOf(rec) {
    return (rec && typeof rec.rev === 'number' && rec.rev > 0) ? rec.rev : 0;
  }

  function ensureId(rec, coll) {
    if (typeof rec.id === 'string' && rec.id) return rec.id;
    const prefix = String(coll).slice(0, 3).toUpperCase() || 'REC';
    rec.id = (typeof global.uid === 'function')
      ? global.uid(prefix)
      : prefix + '-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 5).toUpperCase();
    return rec.id;
  }

  /**
   * Seed the in-memory index from current state WITHOUT bumping anything.
   * Call after load so the next save doesn't see every record as "new".
   */
  function seedIndex(snapshot, scope) {
    const prior = indexFor(scope);
    const idx = new Map();
    for (const coll of arrayCollections(snapshot)) {
      for (const rec of snapshot[coll]) {
        if (!rec || typeof rec !== 'object') continue;
        ensureId(rec, coll);
        const key = coll + ':' + rec.id;
        // {fp, rev}: the rev is needed later to stamp a tombstone with the
        // version being deleted, so a stale delete can't outrank a newer edit.
        // syncedRev is carried across a reseed — pullMerge reseeds right after
        // every merge, and wiping it there would throw away the one fact the
        // merge had just established about each record.
        const was = prior && prior.get(key);
        const e = { fp: fingerprint(rec), rev: revOf(rec) };
        if (was && typeof was.syncedRev === 'number') e.syncedRev = was.syncedRev;
        idx.set(key, e);
      }
    }
    setIndexFor(scope, idx);
    return idx.size;
  }

  /**
   * The rev at which this device last agreed with the server about a record, or
   * null when that is not known.
   *
   * Deliberately NOT a field on the record. syncedRev is per-DEVICE state — what
   * *this* machine has exchanged — so storing it on a record that then syncs
   * makes two devices holding the identical record disagree byte for byte. The
   * multishop convergence test catches exactly that, and caught it here.
   *
   * null is the backward-compatible default and means "say nothing": a device
   * that has not pushed or merged since launch has no baseline, and treating
   * unknown as 0 would call every record an unpushed local edit and report a
   * conflict for the whole store. A missed report is acceptable; a false one
   * teaches the shop to ignore the message.
   */
  function syncedRevOf(coll, id, scope) {
    const idx = indexFor(scope);
    const e = idx && idx.get(coll + ':' + id);
    return (e && typeof e.syncedRev === 'number') ? e.syncedRev : null;
  }

  /** Note that the server now holds this device's current version of everything. */
  function markSynced(snapshot, scope) {
    const idx = indexFor(scope);
    if (!idx) return 0;
    let n = 0;
    for (const coll of arrayCollections(snapshot)) {
      for (const rec of snapshot[coll]) {
        if (!rec || typeof rec !== 'object' || typeof rec.id !== 'string') continue;
        const key = coll + ':' + rec.id;
        const e = idx.get(key) || { fp: fingerprint(rec), rev: revOf(rec) };
        if (e.syncedRev !== revOf(rec)) { e.syncedRev = revOf(rec); n++; }
        idx.set(key, e);
      }
    }
    return n;
  }

  /** Record that a version accepted from the server is now the shared baseline. */
  function noteSynced(coll, rec, scope) {
    const idx = indexFor(scope);
    if (!idx || !rec || typeof rec.id !== 'string') return;
    const key = coll + ':' + rec.id;
    const e = idx.get(key) || { fp: fingerprint(rec), rev: revOf(rec) };
    e.syncedRev = revOf(rec);
    idx.set(key, e);
  }

  /**
   * One-time backfill (idempotent): give every record a stable id, and records
   * lacking change metadata `rev:1` + `updatedAt`. Safe to run on every load.
   * Returns the count of records that gained a `rev`.
   */
  function backfill(snapshot, exportedAt) {
    const ts = (typeof exportedAt === 'string' && exportedAt) ? exportedAt : nowIso();
    let n = 0;
    for (const coll of arrayCollections(snapshot)) {
      for (const rec of snapshot[coll]) {
        if (!rec || typeof rec !== 'object') continue;
        ensureId(rec, coll);
        if (typeof rec.rev !== 'number' || rec.rev < 1) { rec.rev = 1; n++; }
        if (typeof rec.updatedAt !== 'string') rec.updatedAt = ts;
      }
    }
    return n;
  }

  /**
   * Stamp content changes at save time. Mutates records in place: new/changed
   * records get a bumped `rev` + fresh `updatedAt`; disappeared records become
   * tombstones (pushed into snapshot.tombstones when present). Returns a summary
   * of {created, changed, deleted} for downstream consumers (e.g. audit log).
   */
  function stampChanges(snapshot, scope) {
    const now = nowIso();
    const lastIndex = indexFor(scope);
    const next = new Map();
    const summary = { created: [], changed: [], deleted: [] };

    for (const coll of arrayCollections(snapshot)) {
      for (const rec of snapshot[coll]) {
        if (!rec || typeof rec !== 'object') continue;
        ensureId(rec, coll);
        const key = coll + ':' + rec.id;
        const fp = fingerprint(rec);
        const prev = lastIndex.get(key);
        if (prev === undefined) {
          rec.rev = (typeof rec.rev === 'number' ? rec.rev : 0) + 1;
          rec.updatedAt = now;
          summary.created.push({ collection: coll, id: rec.id });
        } else if (prev.fp !== fp) {
          rec.rev = (typeof rec.rev === 'number' ? rec.rev : 0) + 1;
          rec.updatedAt = now;
          summary.changed.push({ collection: coll, id: rec.id });
        }
        // Carry the synced baseline across the rebuild. stampChanges runs on EVERY
        // save, so dropping it here would erase the baseline the moment the shop
        // made the very local edit we want to be able to report as lost.
        const e = { fp, rev: revOf(rec) }; // fp excludes reserved fields — stable post-stamp
        if (prev && typeof prev.syncedRev === 'number') e.syncedRev = prev.syncedRev;
        next.set(key, e);
      }
    }

    const tomb = Array.isArray(snapshot.tombstones) ? snapshot.tombstones : null;
    for (const key of lastIndex.keys()) {
      if (next.has(key)) continue;
      const sep = key.indexOf(':');
      const coll = key.slice(0, sep);
      const id = key.slice(sep + 1);
      summary.deleted.push({ collection: coll, id });
      if (tomb && !tomb.some((t) => t && t.id === id && t.collection === coll)) {
        // Carry the rev that was deleted. Without it a delete outranks every
        // later edit: a tombstone from rev 2 would remove a record another
        // device had since edited to rev 9, and the edit was gone silently.
        const gone = lastIndex.get(key);
        tomb.push({ id, collection: coll, rev: gone ? gone.rev : 0, deletedAt: now });
      }
    }

    capTombstones(tomb);

    setIndexFor(scope, next);
    return summary;
  }

  /**
   * Bound tombstone growth. They are transient delete-markers for sync; once
   * every device has seen a delete they are dead weight. Keeps the most recent
   * set (they are appended oldest-first) so the array cannot grow without limit
   * and bloat every save and every sync blob.
   *
   * Applied on both paths that add tombstones — the local delete in stampChanges
   * and the propagated one in applyDeltas. Leaving applyDeltas to rely on the
   * next save for trimming would have made the bound a property of the caller
   * rather than of this module.
   */
  const TOMB_CAP = 5000;
  function capTombstones(tomb) {
    if (Array.isArray(tomb) && tomb.length > TOMB_CAP) tomb.splice(0, tomb.length - TOMB_CAP);
  }

  /** High-water cursor across the snapshot (rev authoritative; updatedAt advisory). */
  function maxCursor(snapshot) {
    let rev = 0;
    let ts = '';
    for (const coll of arrayCollections(snapshot)) {
      for (const rec of snapshot[coll]) {
        if (!rec || typeof rec !== 'object') continue;
        if (typeof rec.rev === 'number' && rec.rev > rev) rev = rec.rev;
        if (typeof rec.updatedAt === 'string' && rec.updatedAt > ts) ts = rec.updatedAt;
      }
    }
    return { rev, ts };
  }

  /**
   * Extract everything changed since a cursor — the wire format for incremental
   * backup today and cloud sync later. Returns { deltas, tombstones, cursor }.
   */
  function extractDeltas(snapshot, cursor) {
    const since = cursor || { rev: 0, ts: '' };
    const deltas = [];
    for (const coll of arrayCollections(snapshot)) {
      for (const rec of snapshot[coll]) {
        if (!rec || typeof rec !== 'object') continue;
        if (typeof rec.rev === 'number' && rec.rev > (since.rev || 0)) {
          deltas.push({ collection: coll, record: rec });
        }
      }
    }
    const tombstones = (Array.isArray(snapshot.tombstones) ? snapshot.tombstones : [])
      .filter((t) => t && (!since.ts || (t.deletedAt || '') > since.ts));
    return { deltas, tombstones, cursor: maxCursor(snapshot) };
  }

  /**
   * Apply incoming deltas into a target snapshot (mutates it) per the Phase 0
   * conflict policy: LWW by `rev` (rev authoritative); append-only collections
   * never overwrite; tombstones remove. Returns {applied, skipped, removed}.
   */
  /* ── WHAT A DELTA MAY WRITE ─────────────────────────────────────────────
   *
   * A delta names its collection, and the name came from a phone, a cloud or a
   * peer. `if (!Array.isArray(snapshot[coll])) snapshot[coll] = []` turned
   * whatever was there into a list, so one delta naming `settings` replaced the
   * shop's whole settings object (every sealed credential with it) and was
   * written to disk. A security scan found it. A collection is a list of
   * records, or a name the book does not have yet; never an object it has. */
  const NOT_RECORDS = new Set(['settings', 'tombstones', '__proto__', 'constructor', 'prototype']);
  function isRecordCollection(snapshot, coll) {
    if (typeof coll !== 'string' || !/^_?[A-Za-z][A-Za-z0-9_]{0,63}$/.test(coll) || NOT_RECORDS.has(coll)) return false;
    return snapshot[coll] === undefined || Array.isArray(snapshot[coll]);
  }

  /* ── A MASKED SECRET NEVER OVERWRITES A REAL ONE ───────────────────────
   *
   * Phones are sent the book with every credential replaced by the mask
   * (lib/store.js). A phone that edits a machine and sends it back sends the
   * mask too, and a higher rev took it over the real sealed key, so the next
   * poll of that printer failed with a key of "__KHAYT_MASKED__". Anywhere the
   * incoming record holds the mask, the stored value is kept. */
  const SECRET_MASK = '__KHAYT_MASKED__';
  function keepSecrets(existing, incoming) {
    if (incoming === SECRET_MASK) return existing === undefined ? incoming : existing;
    if (!incoming || typeof incoming !== 'object' || !existing || typeof existing !== 'object') return incoming;
    if (Array.isArray(incoming)) {
      return incoming.map((v, k) => keepSecrets(Array.isArray(existing) ? existing[k] : undefined, v));
    }
    const out = {};
    for (const k of Object.keys(incoming)) out[k] = keepSecrets(existing[k], incoming[k]);
    return out;
  }

  function applyDeltas(snapshot, payload, opts) {
    opts = opts || {};
    const appendOnly = new Set(opts.appendOnly || []);
    const scope = opts.scope;
    const result = { applied: 0, skipped: 0, removed: 0, conflicts: [] };

    // Deletes this side already knows about. The tombstone rule below ("a delete
    // must not be undone by a stale delta re-adding the record") only ever
    // covered tombstones arriving IN the payload — never the ones the target
    // already holds. So a record deleted here and not yet seen by the peer came
    // straight back through the unseen-record branch: pullMerge() on unlock or
    // after a 409 re-added every client, order or spool the shop had just
    // deleted, and the next save persisted the resurrection.
    const localTombs = new Map();
    for (const t of (Array.isArray(snapshot.tombstones) ? snapshot.tombstones : [])) {
      if (t && t.collection && t.id) localTombs.set(t.collection + ':' + t.id, t);
    }

    for (const d of (payload && payload.deltas) || []) {
      const coll = d && d.collection;
      const incoming = d && d.record;
      if (!coll || !incoming || typeof incoming.id !== 'string') { result.skipped++; continue; }
      if (!isRecordCollection(snapshot, coll)) { result.skipped++; continue; }
      if (!Array.isArray(snapshot[coll])) snapshot[coll] = [];
      const arr = snapshot[coll];
      const i = arr.findIndex((r) => r && r.id === incoming.id);
      if (i === -1) {
        const tomb = localTombs.get(coll + ':' + incoming.id);
        if (tomb) {
          // Deleted here. Stay deleted — symmetrical with the incoming-tombstone
          // rule, so both devices converge on "gone" instead of one resurrecting
          // it forever. Announce it only when a real edit is being discarded: an
          // incoming rev at or below the one the delete saw is just the peer
          // echoing back a record it has not yet learned is gone.
          if (revOf(incoming) > revOf(tomb)) {
            result.conflicts.push({
              collection: coll, id: incoming.id, kind: 'delete_over_edit',
              tombRev: revOf(tomb), localRev: revOf(incoming), discarded: incoming,
            });
          }
          result.skipped++;
          continue;
        }
        arr.push(incoming); result.applied++; noteSynced(coll, incoming, scope); continue;
      }
      if (appendOnly.has(coll)) { result.skipped++; continue; }
      const curRev = revOf(arr[i]);
      const inRev = revOf(incoming);
      if (inRev > curRev) {
        // A higher rev wins — that has always been the rule and it does not change
        // here. What changes is that we notice when winning costs something.
        //
        // `rev` is a per-record counter, not a causal clock, so "higher" does not
        // mean "descended from". A peer that edited the same record twice arrives
        // at rev 7 while this device sits at its own rev 6 from a single edit, and
        // that edit was overwritten with nothing said anywhere. The shop's
        // corrected phone number simply stopped existing, on one machine.
        //
        // syncedRev is the version the server last had from us. If the local rev
        // has moved past it, this record holds work the incoming version cannot
        // contain. Same outcome, but the discarded copy is handed to the host so
        // someone can be told. An unknown baseline says nothing: see syncedRevOf.
        const base = syncedRevOf(coll, incoming.id, scope);
        if (base !== null && curRev > base && fingerprint(incoming) !== fingerprint(arr[i])) {
          result.conflicts.push({
            collection: coll, id: incoming.id, kind: 'remote_over_local_edit',
            localRev: curRev, incomingRev: inRev, syncedRev: base,
            discarded: arr[i], tookIncoming: true,
          });
        }
        arr[i] = keepSecrets(arr[i], incoming); result.applied++;
        noteSynced(coll, incoming, scope);
      }
      else if (inRev < curRev) { result.skipped++; }
      else {
        // Same rev, different content: two devices edited independently from the
        // same base. Skipping used to mean each device kept its own copy and
        // they diverged permanently, with nothing to tell anyone.
        //
        // One of the two edits is lost either way — `rev` is a per-record counter,
        // not a causal clock, so there is no information here to merge on. What
        // this does buy is CONVERGENCE: every device applies the same rule and
        // ends up with the same record, instead of each believing it is right.
        // Tie-break on updatedAt, then on a stable fingerprint compare so the
        // outcome never depends on who pulled first.
        if (fingerprint(incoming) !== fingerprint(arr[i])) {
          const curT = String(arr[i].updatedAt || '');
          const inT = String(incoming.updatedAt || '');
          const takeIncoming = inT !== curT
            ? inT > curT
            : fingerprint(incoming) > fingerprint(arr[i]);
          if (takeIncoming) { arr[i] = keepSecrets(arr[i], incoming); result.applied++; noteSynced(coll, incoming, scope); }
          else { result.skipped++; }
          result.conflicts.push({ collection: coll, id: incoming.id, rev: inRev, tookIncoming: takeIncoming });
        } else {
          result.skipped++;   // identical content — not a conflict, just a re-send
        }
      }
    }

    for (const t of (payload && payload.tombstones) || []) {
      if (!t || !t.collection || !t.id) continue;

      // Keep the tombstone, not just its effect.
      //
      // This loop used to delete the record and move on, so the receiving device
      // carried out the delete without ever learning that a delete had happened.
      // A third device still holding the record then pushed it straight back —
      // accepted, because with no local tombstone the unseen-record branch above
      // has nothing to refuse it with — while the device that pressed delete does
      // hold the tombstone and stays deleted. Two devices disagree, permanently,
      // and neither has any way to notice. Reproduced with three devices before
      // this existed; see test/tombstone-propagation.test.js.
      //
      // The earlier fix made the DELETING device immune. Recording the tombstone
      // here is what extends that to every device the delete reaches, which is
      // what makes the local-tombstone defence above worth anything.
      //
      // Recorded even when this side has no such record: a device that is simply
      // behind is the one that most needs to know, and dropping the tombstone was
      // how it stayed behind.
      const key = t.collection + ':' + t.id;
      if (!Array.isArray(snapshot.tombstones)) snapshot.tombstones = [];
      const known = localTombs.get(key);
      if (!known) {
        const copy = { id: t.id, collection: t.collection, rev: revOf(t), deletedAt: t.deletedAt };
        snapshot.tombstones.push(copy);
        localTombs.set(key, copy);
      } else if (revOf(t) > revOf(known)) {
        // Same id deleted at a higher rev elsewhere. Keep the higher one, so the
        // delete_over_edit report stays accurate rather than under-reporting.
        known.rev = revOf(t);
      }
      capTombstones(snapshot.tombstones);

      if (!Array.isArray(snapshot[t.collection])) continue;
      const arr = snapshot[t.collection];
      const i = arr.findIndex((r) => r && r.id === t.id);
      if (i === -1) continue;
      // Tombstones win unconditionally, on purpose: a delete must not be undone
      // by a stale delta re-adding the record (see sync-foundation.test.js).
      //
      // The cost is that a delete also outranks a genuinely newer edit made on
      // another device — delete at rev 2 removes a record edited to rev 9. Both
      // cannot be fixed with `rev` alone, because a counter cannot tell "stale
      // delete" from "stale re-add"; that needs a causal clock. The tombstone
      // carries the rev it deleted (see stampChanges), which lets us at least
      // KNOW when a delete is discarding a newer edit.
      const removed = arr[i];
      const localRev = revOf(removed);
      const tombRev = revOf(t);
      arr.splice(i, 1); result.removed++;
      // Delete still wins — reversing that silently would resurrect deleted
      // records — but it is no longer silent. When the record here was edited
      // (localRev) after the delete saw it (tombRev), report the discarded edit
      // so a shop learns an order it just changed was removed on another device,
      // instead of the change vanishing without a trace. A one-click cross-device
      // "restore" is deliberately not offered: the tombstone wins on every other
      // device too, so a restored record would just be deleted again on the next
      // sync — an honest "this was lost" beats a button that quietly fails.
      if (localRev > tombRev) {
        result.conflicts.push({
          collection: t.collection, id: t.id, kind: 'delete_over_edit',
          tombRev, localRev, discarded: removed,
        });
      }
    }
    return result;
  }

  // ---- Sync Engine backend interface (LocalBackend = no-op; cloud is opt-in) ----
  const LocalBackend = {
    name: 'local',
    pushDeltas() { return Promise.resolve({ newCursor: null }); },
    pullDeltas() { return Promise.resolve({ deltas: [], tombstones: [], newCursor: null }); },
    status() { return 'off'; },
  };

  function setBackend(b) { backend = b || null; statusVal = backend ? 'idle' : 'off'; }
  function getBackend() { return backend; }
  function status() { return backend ? statusVal : 'off'; }

  /**
   * Reduce a merge's conflicts to what the UI needs to announce a delete that
   * discarded a local edit. Pure — no DOM, no i18n — so the message logic is
   * testable away from the renderer glue that calls toast()/t().
   * @returns {{count:number, firstName:string}} count 0 means nothing to show.
   */
  function summarizeDiscardedEdits(conflicts) {
    const discarded = (conflicts || []).filter((c) => c && c.kind === 'delete_over_edit');
    if (!discarded.length) return { count: 0, firstName: '' };
    const r = discarded[0].discarded || {};
    const firstName = String(r.project || r.name || r.title || discarded[0].id || '').slice(0, 40);
    return { count: discarded.length, firstName };
  }

  /**
   * Local edits that a newer version from another device wrote over.
   *
   * Kept separate from summarizeDiscardedEdits because the cause and the advice
   * differ: a delete_over_edit record is gone everywhere and there is nothing to
   * look at; this one still exists, showing the other machine's version, so the
   * useful advice is "look at it again". Same shape so the host can treat them
   * alike.
   * @returns {{count:number, firstName:string}} count 0 means nothing to show.
   */
  function summarizeOverwrittenEdits(conflicts) {
    const lost = (conflicts || []).filter((c) => c && c.kind === 'remote_over_local_edit');
    if (!lost.length) return { count: 0, firstName: '' };
    const r = lost[0].discarded || {};
    const firstName = String(r.project || r.name || r.title || lost[0].id || '').slice(0, 40);
    return { count: lost.length, firstName };
  }

  /**
   * Find records that are present despite having been deleted.
   *
   * Until the tombstone fix, `applyDeltas` honoured "a delete must not be undone
   * by a stale delta" only for tombstones arriving in the payload, never those
   * the store already held — so a record deleted here, whose delete the server
   * had not yet seen, was pushed back in by the next pull and persisted by the
   * next save. That shipped in v3.3.0 and every 3.4 beta. Fixing it stops new
   * cases; it cannot un-resurrect the ones already written to disk.
   *
   * The state is self-evident once you look for it: the store holds BOTH a
   * tombstone for an id AND a live record with that id. That cannot happen any
   * other way — ids are never derived from external data (`ensureId` and
   * `uniqueLanId` are both timestamp+random), so a deleted id is never reused,
   * and there is no undo-delete or merging restore anywhere in the app.
   *
   * Deliberately REPORT-ONLY. Re-deleting automatically would be a second silent
   * data change on top of the first, and the shop may well have worked on the
   * record in the weeks since it came back. Naming it lets the owner decide.
   *
   * Best-effort by construction: tombstones are capped at 5000 and pruned
   * oldest-first, so a resurrection whose tombstone has since aged out is
   * invisible here. It under-reports; it does not invent.
   */
  function findResurrected(snapshot) {
    const out = [];
    if (!snapshot || typeof snapshot !== 'object') return out;
    const tombs = Array.isArray(snapshot.tombstones) ? snapshot.tombstones : [];
    for (const t of tombs) {
      if (!t || !t.collection || !t.id) continue;
      const arr = snapshot[t.collection];
      if (!Array.isArray(arr)) continue;
      const rec = arr.find((r) => r && r.id === t.id);
      if (rec) out.push({ collection: t.collection, id: t.id, deletedAt: t.deletedAt || '', record: rec });
    }
    return out;
  }

  /**
   * Reduce findResurrected() to what the UI needs to announce it. Pure — no DOM,
   * no i18n — mirroring summarizeDiscardedEdits.
   * @returns {{count:number, firstName:string}} count 0 means nothing to show.
   */
  function summarizeResurrected(found) {
    const list = found || [];
    if (!list.length) return { count: 0, firstName: '' };
    const r = list[0].record || {};
    const firstName = String(r.project || r.name || r.nameEn || r.title || list[0].id || '').slice(0, 40);
    return { count: list.length, firstName };
  }

  const api = {
    SCHEMA,
    fingerprint,
    seedIndex,
    backfill,
    findResurrected,
    summarizeResurrected,
    stampChanges,
    extractDeltas,
    applyDeltas,
    markSynced,
    summarizeOverwrittenEdits,
    syncedRevOf,
    summarizeDiscardedEdits,
    maxCursor,
    setBackend,
    getBackend,
    status,
    LocalBackend,
    setScope,
    getScope,
    DEFAULT_SCOPE,
    // test-only helpers. With no scope they span every shop, which is what a
    // test asking for a clean slate means; pass one to touch a single shop.
    _resetIndex(scope) {
      if (scope === undefined) { indexes.clear(); currentScope = DEFAULT_SCOPE; }
      else indexes.delete(scope || currentScope);
    },
    _indexSize(scope) {
      if (scope === undefined) {
        let n = 0;
        for (const m of indexes.values()) n += m.size;
        return n;
      }
      return indexFor(scope).size;
    },
    _scopes() { return [...indexes.keys()]; },
  };

  Object.assign(global, { KhaytSync: api });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
