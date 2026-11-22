# Phase 3 — the decisions to make before writing any code

The [Phase 3 spec](./KHAYT-3.0-PHASE3-SPEC.md) says what multi-shop should do.
This says what it would take **against the code that exists on 2026-07-28**, and
names the choices that have to be made first. Nothing here is built.

Read with [CLOUD-STATUS](./KHAYT-3.0-CLOUD-STATUS.md), which records that Phase 3
has not been started.

---

## The one thing that reframes the estimate

**The hard half is already built, and it is not the half people expect.**

Phase 0 shipped a complete entity-level change-tracking engine in
`renderer/sync.js`: per-record `rev` and `updatedAt` stamping, tombstones for
deletes, `extractDeltas` / `applyDeltas`, cursors, and a `SyncBackend` interface
with `pushDeltas` / `pullDeltas`. It is tested (42 tests) and it runs today for
every user, because it is what makes backups incremental.

And then `lib/cloud-backend.js` implements that interface like this:

```js
async function push(snapshot) {
  const ciphertext = crypto.encryptStore(snapshot, getDek());   // the WHOLE store
  await transport({ method: 'PUT', path: `/v1/shops/${shopId}/store`, ... });
}
```

It satisfies the delta-shaped interface by ignoring the deltas and shipping the
entire store as one opaque blob. That was the right call for Phase 1 — one
writer, one shop, simplest thing that works — but it means:

> Phase 3 is not "add entity sync to the desktop". The desktop can already do it.
> It is "teach the server to store entities instead of a blob", plus a key model
> that lets two shops read the same record.

That is a smaller desktop change and a larger server change than the spec's
framing suggests.

---

## What actually has to be built

| Piece | Where | Size | Note |
|---|---|---|---|
| `org_id` tenancy | server | medium | None of the 19 tables has one; every query and index changes |
| Per-entity storage + delta endpoints | server | **large** | Replaces one-blob-per-shop; the real work |
| Org Data Key wrap/unwrap + rotation | both | **large** | Security-critical; see below |
| Delta-op log for shared pools | both | medium | Inventory and gift cards only |
| Conflict surfacing UI | desktop | small | "server version / your version" |
| HQ aggregate | server + desktop | medium | Consented plaintext, separate from the ODK |
| Wire `cloud-backend` to real deltas | desktop | **small** | The engine is already there |

---

## Decision 1 — does the server keep storing opaque blobs?

The whole product promise is that the server cannot read shop data. Entity-level
sync strains that: the server has to know *which record* changed to merge two
shops' edits, even if it cannot read the contents.

**Three options.**

**(a) Encrypted per-entity rows.** Each record is its own ciphertext, keyed by
`(org_id, shop_id, collection, record_id, rev)`. The server sees the shape of
your data — how many clients, how often each changes — but never the contents.

**(b) Keep one blob per shop, merge on the desktop.** Server stays exactly as it
is. Each shop pushes its own blob; a device that belongs to several shops pulls
all of them and merges locally. No server work at all, and the server learns
nothing new.

**(c) Encrypted delta log.** Append-only encrypted ops per org; every device
folds the log. Most faithful to the delta-op design the spec wants for shared
inventory, and the most new machinery.

**Recommendation: (b) for the first release, (c) later if shared inventory
demands it.**

Option (b) is not the obvious answer, which is why it is worth stating plainly:
it gets multi-shop working with *no server storage change at all*, keeps the
"we see nothing" property exactly as strong as it is today, and defers the hard
part until there is a real shop asking for shared inventory. Its ceiling is real
— every device downloads every branch's whole store, so it stops scaling
somewhere around a handful of branches — but "a handful of branches" is what
Phase 3 is for. Tenancy 3 (franchises) is a different phase and can justify (c)
on its own evidence.

Option (a) is the middle road that gets the worst of both: server work *and* a
weaker privacy story, for a scaling ceiling nobody has hit.

## Decision 2 — how does Branch B read Branch A's clients?

Phase 1 derives the key from one shop's passphrase, so today it simply cannot.
The spec's answer is an Org Data Key held by each device and wrapped to that
device's public key.

This is the security-critical piece, and it is worth being blunt: **it is the
part most likely to go wrong**, because a mistake is silent. A bug in delta
merging shows up as a wrong number someone notices. A bug in key wrapping shows
up as data nobody can decrypt, or data the server can.

Sub-decisions that cannot be deferred:

- **Rotation on revoke.** Removing a device should rotate the ODK, or the removed
  device keeps reading anything it already synced. Rotation means re-encrypting
  everything under the new key — expensive, and it has to be resumable.
- **Who authorises a device.** Owner-only is simplest and matches the current
  role model.
- **Recovery.** If every device is lost, the ODK is gone and so is the data. The
  existing recovery-code file is per-shop; it would have to cover the ODK too.

The design, threat model and build order are in [ORG-DATA-KEY](./KHAYT-3.0-ORG-DATA-KEY.md).
Its headline: the existing envelope in `lib/sync-crypto.js` already does almost
all of this, so the ODK is a third wrapping slot rather than a new key system.

**Recommendation:** build the ODK against option (b) first, where it only has to
wrap and unwrap. Defer rotation-on-revoke to a follow-up, and say so in the UI
rather than implying revocation is instant when it is not.

## Decision 3 — is shared inventory in the first release?

It is the only part that genuinely needs more than last-write-wins. Two branches
drawing from one spool must **sum** their draws, not clobber each other, which
means an append-only op log keyed by op-id.

**Recommendation: no, not in the first release.** Ship multi-shop with per-shop
inventory, which needs no merge at all, and add the shared pool when a real shop
asks. Per the spec's own table, orders are per-shop-owned anyway, and clients and
products are LWW — none of which needs the op log. Shipping the op log for a
feature nobody has requested is how the schedule goes.

## Decision 4 — what counts as done?

The spec's DoD includes the HQ dashboard and shared inventory. On the
recommendations above, a first release would be:

> An owner runs two or more branches from one account. Clients, products and
> templates are shared and merge by LWW with conflicts surfaced, never silently
> dropped. Orders stay owned by their branch. Bulk data stays E2E under an org
> key the server never sees. Single-shop and cloud-off users are unaffected —
> asserted, not assumed.

HQ aggregate and shared inventory become Phase 3.1.

---

## What I would do first, if this is approved

Not code. **Prove the desktop can already do it**: point two local stores at each
other through the existing delta engine, with no server involved, and see whether
`extractDeltas`/`applyDeltas` genuinely round-trip two-way merges with tombstones
and concurrent edits. That is a day's work with the engine that exists, it needs
no server and no crypto, and it either de-risks the whole phase or tells us the
Phase 0 foundation has a gap — which is much cheaper to learn now than after the
server work.

If it holds, option (b) becomes a small amount of desktop plumbing plus the ODK,
and Phase 3 stops being the scary one.

---

## That proof has now been run (2026-07-28)

`test/phase3-delta-roundtrip.test.js` — two local stores, no server, no crypto.
It found one shipping bug and one Phase 3 blocker, which is what it was for.

**It mostly holds.** Independent creates converge, tied concurrent edits converge
(both branches discard the *same* edit, which is the property that matters —
`rev` is a counter, not a causal clock, so an edit is always lost; what cannot
happen is the two branches losing different ones), and a second exchange is a
no-op, so the merge reaches a fixed point instead of ping-ponging.

**Finding 1 — deletes were resurrected. Shipping bug, now fixed.**
`applyDeltas` enforced "a delete must not be undone by a stale delta" only for
tombstones arriving *in the payload*, never for the ones the target already held.
So a record deleted here, whose delete the peer had not yet seen, came back
through the unseen-record branch. This was not theoretical and not Phase 3 only:
`pullMerge()` runs on unlock, on launch, and inside 409 resolution, so two
devices reached it easily — A deletes, B pushes first, A's push 409s, A pulls,
and A's own delete is undone, then persisted by the next save.

Fixed in `renderer/sync.js` by consulting the target's own tombstones, with the
existing `delete_over_edit` reporting reused so a genuinely newer discarded edit
is still announced and a stale echo stays silent. Guarded by three tests in
`test/cloud-sync.test.js` — the shipping path, not just the research file — and
mutation-verified: restoring the old behaviour kills exactly those three.

**Finding 2 — one device could not hold two shops. Now fixed.**
`stampChanges` decides a record was deleted when it is in the change-index but
absent from the snapshot in front of it, and that index was one module-level map
per process. Stamping shop B right after shop A therefore marked every one of A's
records as deleted and wrote tombstones for them into B's store — and tombstones
win unconditionally, so once those synced they deleted live records.

This sat directly on the recommended option (b), whose whole shape is *"a device
that belongs to several shops pulls all of them and merges locally"* — one
process, several stores.

It turned out to be an isolation problem rather than a logic one, so the fix is
small: `seedIndex` and `stampChanges` take an optional **scope**, and the engine
keeps one index per scope. Two shops on one device pass their shop ids and stop
colliding. Nothing about the conflict policy changed.

Every shipping caller (`app-state.js`, `cloud-sync.js`) passes no scope and lands
on a shared default, so single-shop users are unaffected — asserted by a test,
not assumed, including that an implicit scope and an explicit `'default'` are the
same index rather than two. Mutation-verified: collapsing every scope back to one
index kills exactly the two isolation tests.

**So the first Phase 3 task is now done ahead of the phase**, and what remains for
multi-shop on the desktop is passing a real shop id at those three call sites.
The weight moves to the ODK key model, which was always the risky half.
