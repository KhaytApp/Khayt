# Entity-level delta sync — the contract, and the hazard that sets its rollout

Blob-first sync costs `store size × saves`, so a shop pays for its entire history
on every card it drags and its bill grows quadratically with age.
[COST-PER-SHOP §4](./KHAYT-CLOUD-COST-PER-SHOP.md) measures what that is worth:
the heaviest modelled shop drops from **84 GB/month to 13.6 MB**, and the spread
between the lightest and heaviest shop collapses from **12,151× to 80×** — the
ratio of how *active* two shops are, which is all it should ever have been.

Compression (beta.18) lowered the bill by 6.17× but left it quadratic, because a
uniform multiplier cannot change a shape. This is the change that does.

**Status:** the desktop **reader** is built and tested, and the **server is live**
— KhaytApp/khayt-cloud#16 implements the contract in both backends, and production
is serving it. Verified rather than assumed, using the build marker the README
documents for exactly this:

```
shasum -a 256 index.php | cut -c1-12                       # 2cda2d3dbf8c
curl -s https://cloud.khaytapp.com/v1/health               # "build":"2cda2d3dbf8c"
curl -s -o /dev/null -w '%{http_code}' -X POST \
  https://cloud.khaytapp.com/v1/shops/probe/deltas         # 401, not 404
```

The 401 is the point: an unknown route answers 404 there, so "missing bearer
token" means the route exists and is guarded.

**`DELTA_WRITES` in [`lib/cloud-backend.js`](../lib/cloud-backend.js) is now
`true`.** It shipped `false` for the whole readers-first half of the rollout, and
§3 is why. The condition it waited on was never "the field is fully updated" — it
was a server that refuses a delta push for a shop with a blob-only device
attached. That is khayt-cloud#16, and it refuses with **404**, the status the
client already falls back on, so a shop that is not yet eligible keeps
blob-syncing with no error and no action from its owner. The pull half is
finished on both counts — the desktop asks for `?since=` and folds onto a
retained server view, and that view survives a restart (§7), so launch is warm
too.

---

## 1. The wire contract

Validated against a reference server in
[`test/cloud-delta-push.test.js`](../test/cloud-delta-push.test.js) before being
written in PHP, because it is far cheaper to find the shape wrong there than in
two server implementations that `test/route-parity.test.js` pins together.

```
POST /v1/shops/{shopId}/deltas
     body { ciphertext, baseRev }
     200 { rev, deltaCount }      appended; rev is the new head
     409 { rev }                  baseRev is not the head — pull, merge, retry
     404 / 405                    server is blob-only

GET  /v1/shops/{shopId}/store[?since={rev}]
     200 { ciphertext?, rev, deltas: [{ rev, ciphertext }] }
     204                          nothing stored yet

     Without `since`: the base plus the whole chain — what a cold device needs.
     With `since`:    only entries newer than that rev; `ciphertext` is omitted
                      unless the caller is behind the current base.
```

**`?since=` is a requirement, not an optimisation.** Without it every launch
re-downloads the base *and* the entire chain, which makes pulls **worse** than
blob-only and can wipe out the push saving on its own. A warm client that already
holds rev N must be able to ask for N+1 onward.

- **The server never decrypts anything.** A delta is its own ciphertext; the
  server learns that something changed and how big it was, which is what it
  already learns from a blob push.
- **One base plus an ordered chain.** `PUT /store` replaces the base and
  **compacts** the chain to empty. That is the only compaction mechanism, and it
  is also the fallback for anything a delta cannot express.
- **`settings` is not an array collection**, so a settings change is not covered
  by a delta and needs a full push. Worth knowing before assuming deltas cover
  every save.
- **Old clients need no flag and no negotiation.** A Phase 1 server answers 404
  to `POST /deltas`; the client remembers that and sends blobs for the rest of
  the session, one wasted round trip per session rather than per save.

## 2. The desktop side, and one thing that had to change

`extractDeltas(snapshot, cursor)` looked like the obvious way to ask "what has
changed since my last push". **It cannot answer that question**, and the reason
is worth recording because it is not visible from the function's signature.

`rev` is a **per-record** counter, not a global sequence. `maxCursor` returns the
largest rev in the store. So in a store whose records sit at rev 1, a brand-new
record also arrives at rev 1, and `rec.rev > since.rev` is `1 > 1` — false. The
new record is invisible and never ships.

Every existing test extracts from `{rev: 0}`, which selects everything and never
exercises the comparison, so nothing caught it.

The backend therefore keeps a **push index** — `collection:id -> rev` of what it
last sent — rather than a cursor. It asks "is this the version they have?", which
is the actual question and needs nothing global. The engine is untouched.

## 3. The hazard, and why `DELTA_WRITES` was off until 2026-08-21

**A blob-only desktop silently destroys every delta.** Pinned by the last test in
`test/cloud-delta-push.test.js`, which is written to fail if this ever stops
being true.

The old client is not broken and cannot tell anything is wrong. It pulls, gets a
`200` with a base blob, ignores the `deltas` field it has never heard of, merges
into it, and pushes a well-formed full store with a **correct** `baseRev`.
Nothing rejects it. The newer edits are simply gone.

This is worse than the compression rollout it otherwise resembles. A beta.16
client meeting a gzipped blob **stops syncing, loudly**. This one keeps working
and eats data.

So the order is:

1. ~~**Ship the reader.**~~ Done — this change. A desktop that can fold
   `base + deltas`, and that refuses a delta response it cannot fold rather than
   returning a store missing its newest edits.
2. **Let it reach the field.** Same adoption wait the portal read gate is in
   ([PORTAL read gate](./KHAYT-3.0-CLOUD-STATUS.md)); a beta-only release does
   not satisfy it.
3. ~~**Build the server**, including the gate in §4~~ — done and deployed
   (KhaytApp/khayt-cloud#16). Without the gate step 4 would be unsafe no matter
   how long step 2 waits, which is why it shipped in the same change.
4. ~~**Flip `DELTA_WRITES`**~~ — **done 2026-08-21.** It was never really
   blocked on step 2, which took until the gate was read rather than assumed to
   become clear: step 3's gate refuses with 404, so an un-adopted shop falls
   through to the blob push it was already making. Adoption decides how much of
   the saving is realised, not whether the flip is safe.

   It is not blocked on §7, which is now finished on both counts: a client asks
   for a slice and folds it onto its own retained view, and that view survives a
   restart, so the launch pull is a slice too. Nor is it blocked
   on §8: the gate holds every `/m` shop to blob sync on its own, so the flip is
   safe with the PWA exactly as it is. §8 decides how *far* the saving reaches,
   not whether flipping is safe.

Step 2 is now the long pole. The gate cannot open for a shop until every device
that reads its store has announced itself, and only builds carrying
KhaytApp/Khayt#697 do that — so adoption is what decides when any shop becomes
eligible, exactly as intended.

## 4. What the server has to do that this repo cannot

**The desktop cannot make this decision.** A client knows its own version; it
cannot know what other devices a shop has attached, so the refusal has to live
server-side:

> The server must refuse `POST /deltas` for a shop that still has a device
> capable only of blob reads.

That needs a per-device record of delta capability — sent at token
rotation or login — and a per-shop derived flag. Devices already register and
rotate tokens, so this is a column and a check rather than a new concept.

The conservative default matters: a shop whose devices have **not** all reported
capability is blob-only. Unknown must not mean permitted, or the first shop to
sync from an un-upgraded laptop is the one that loses data.

**And "refuse" has to name a status code, which this section never did.** The
desktop treats only **404 and 405** as "this server cannot take deltas" and falls
back to a whole-store push; every other status throws, so a gate refusing with
403 would turn every save on a not-yet-eligible shop into a sync error. Both
branches are pinned at the end of `test/cloud-delta-push.test.js`.

**Checked 2026-08-21: khayt-cloud#16 refuses with 404**, identically in both
backends. So step 4 below **does not need full adoption** — a gated shop simply
keeps blob-syncing. There is also a backstop the other way, a **412** on a full
push from a device that never announced capability while a chain exists, which
the desktop already surfaces by its sentence rather than its number. Both are
written up in [the adoption endpoint spec](./KHAYT-CLOUD-ADOPTION-ENDPOINT.md) §5.

## 5. What is left

| Piece | Where | Status |
|---|---|---|
| Fold `base + deltas` on pull | desktop | **done** |
| Push index (not a cursor) | desktop | **done** |
| Contract proven against a reference server | desktop tests | **done** |
| `POST /deltas` + chain storage | khayt-cloud (PHP **and** Node) | **done** — KhaytApp/khayt-cloud#16 |
| `?since=` on `GET /store` | khayt-cloud | **done** — same PR |
| Per-device capability + per-shop gate | khayt-cloud | **done** — same PR |
| Announce `X-Delta-Capable` | desktop | **done** |
| Fold a branch's chain in the org roll-up | desktop | **done** |
| Compaction policy (when to force a full push) | desktop | **done** — §6 |
| Ask for `?since=` on pull | desktop | **done** — §7 |
| Persist the server view across restarts (warm launch) | desktop | **done** — §7 |
| Fold a chain in the remote-mobile PWA | khayt-cloud `mobile/` | **not started** — see §8 |
| Surface adoption so the flip can be decided | khayt-cloud | **specified, not built** — [KHAYT-CLOUD-ADOPTION-ENDPOINT.md](./KHAYT-CLOUD-ADOPTION-ENDPOINT.md) |
| Gated-shop refusal is 404/405, not 403 | khayt-cloud | **verified 404** — both backends; pinned desktop-side |
| Flip `DELTA_WRITES` | desktop | **done** — 2026-08-21; the 404 refusal makes a gated shop blob-sync quietly, so adoption sets how much is saved rather than whether it is safe. §8 bounds its reach |

The claim that what remained was "entirely server-side" was **wrong on one point**,
and §7 is that point. Everything else server-side is built and merged-pending.

The warm launch was listed separately on purpose: `?since=` being sent is what
makes the pull half *correct*, and persisting the view is what makes it *pay*.
Both are now done, and what is left on this desktop is the flip itself.

## 7. The pull half — warm within a session, still cold at launch

`pull()` in [`lib/cloud-backend.js`](../lib/cloud-backend.js) now sends
`?since=lastServerRev` whenever it holds a **retained server view**: the store as
of that rev, kept apart from local state. A warm reply carries no base, so the
chain folds onto the view and the base never crosses the wire. Measured against
the real `index.php` on a 300-record store: **331 B warm against 3,602 B cold.**

The obvious target to fold onto — the local store — is the wrong one, and quietly
so. Records arrive by reference (`applyDeltas` does `arr[i] = incoming`), and the
local store carries edits the server has never seen; folding onto it and then
calling `markAllPushed` marks those local-only records as already sent, so they
never ship. That is a data-loss bug wearing the costume of an optimisation, and
it is silent — the store looks right on the device that lost the edit. The view
is therefore its own copy, **cloned on the way in and on the way out**, and the
last test in `test/cloud-delta-push.test.js` is written to fail if a local-only
edit ever stops surviving a warm pull.

The invariant that makes it safe is that **the view and the rev move together, or
neither moves**: a full push adopts the pushed snapshot, a delta push mirrors the
same payload it sent (not the whole snapshot — `settings` is not delta-covered,
so the server's copy is unchanged and the view's must be too), and moving the rev
by hand drops the view. A view lagging its rev is worse than no view: `?since=`
would ask for a slice the server rightly considers empty, and the fold would hand
back a store missing everything in between.

One thing a warm reply cannot show is the whole chain — only what is newer than
`since` — so its length **adds to** the chain counters rather than replacing them.
Adopting the slice length would undercount every time and let a chain run past
both compaction bounds, visible only as cold pulls that grew steadily dearer.

### Launch is warm too now, and the guard is the feature

`cloudBackend` is rebuilt on every unlock, so the view used to start empty and
the first pull of a session — the dearest one — always fetched base + chain.
[`lib/cloud-view-cache.js`](../lib/cloud-view-cache.js) keeps the pair on disk
between sessions, and `hub:cloud-unlock` hands it to the backend.

It is a **cache in the strict sense**: every failure path returns null and null
means a cold pull, which is correct and merely dearer. It is written as
`encryptStore` ciphertext under the DEK, so it is no weaker than the sync it
accelerates — and a keyset rotation invalidates it for free, because the new key
cannot read the old file.

**The reason this was a feature and not a flag is the guard**, `viewSafeForLocal`
in `cloud-backend.js`. A retained view claims the server holds certain records at
certain revs, and everything newer than that claim is what gets pushed. Inside a
session the claim cannot rot dangerously, because local state only moves forward.
Across a restart it can: a store restored from a backup, healed from `.prev`, or
copied in from another machine is **older** than the view, and adopting it would
push those older records over the newer ones — for every device, silently. A cold
pull never does that, because the merge engine keeps the higher rev.

So a cached view is adopted only when every record it says the server holds is
present locally at the same rev or newer, or is locally tombstoned — a deletion
travelling forward rather than local state travelling backward. Anything else,
including *no local store to check against*, deletes the cache and launches cold.
A false refusal costs one cold pull; a false acceptance costs a shop its data,
and the asymmetry decides every judgement call in there.

Two things ride along with the view because they cannot be re-learned warm:
`baseWireBytes` and the chain counters. They are only ever set by a cold reply or
by this device's own full push, and a device that launches warm sees neither — so
dropping them would quietly retire the byte half of the compaction policy (§6)
and leave only `MAX_CHAIN_DELTAS`, visible to nobody but a cold pull that grew
dearer every month.

**What the guard compares is the store on DISK**, and the push sends the
renderer's snapshot — which is not quite the same object. `hub:save-store` runs
`normalizeStoreSnapshot` first, and that is an allowlist: an invalid record is
dropped on the way to disk while the push has already sent it. Such a shop then
holds a view naming a record its own store does not have, and launches cold
forever. Not a correctness problem — cold is the old behaviour — but it is the
way this feature would go quietly missing, and it is worth checking for before
concluding the cache is broken. Found by driving the real app, where an invalid
fixture order did exactly this.

**The mid-session restore, and the door the guard does not stand in.**
`viewSafeForLocal` runs at CONSTRUCTION — unlock and launch — against the store
on disk. A restore performed *while the app is running* walks straight past it:
the backend is not rebuilt, so the view, the rev and the pushed-revs cursor all
outlive the one event that moves local state backwards. This predates the cache
(the in-memory retained view shipped in #703); the guard only gave it a name.

The dangerous half is the **cursor**, not the view. `changesSincePush` ships
whatever disagrees with `pushedRevs`, which after a restore is every rolled-back
record. On the blob path — which is still what an un-eligible shop takes, and
what every shop took before the flip — it is worse than that: a full push whose
`baseRev` the server accepts *replaces* the base outright, so the older store
lands on every device, silently.

So `forgetServerView()` drops all five pieces and the rev with them, and
`hub:cloud-forget-view` lets the renderer call it — the restore path is
renderer-side, `hub:restore-backup` only reads and decrypts the file. It is
wired into the three paths that replace local state wholesale: restoring a dated
backup, restoring a named restore point, and importing a backup file. Each calls
it **before** applying the snapshot, because the window between the two is small
but not empty — a sync debounced from an earlier save can fire inside it.

`lastServerRev = 0` is the load-bearing part. It makes the next push a blob
guarded on rev 0, which any shop that has ever pushed refuses with a 409 — and a
409 is pull → merge → re-push, where the merge engine keeps the higher rev. The
restore then costs one cold pull and *repairs*, instead of succeeding quietly and
destroying. Note this is strictly more than `_setServerRev` does: that drops the
view and the cache file but leaves `pushedRevs` behind, which is the half that
still ships the rolled-back records.

Two restores deliberately do **not** call it. *Restore from cloud* applies the
store the backend just pulled, so the view already describes it exactly and
forgetting would buy a cold pull and a spurious conflict for nothing. *Cloud
snapshot history* is a deliberate rollback that means to become the new head, and
it relies on keeping the rev to push without a false conflict — resetting there
would have the merge undo the restore the owner just asked for. That path has its
own unfinished business under delta writes (an older record pushed as a delta is
skipped by every peer's LWW, so the restore would not propagate at all), and it
wants full-push semantics rather than this.

So the shape of the bill: pushes drop by the full factor, and pulls are slices
from the first one of the session onwards. A cold pull still costs up to `1 + R`
(3× at R = 2) of a blob pull and still happens — after a compaction, after a
rotation, after a restore, and on a device's genuine first run.

---

## 6. Compaction, derived rather than picked

A chain has to be reset by a full push, or a cold device pays for the base plus
every delta ever appended — each of which is a decrypt. Let **R** be the ratio at
which the client compacts: chain bytes ≤ R × base bytes. Per cycle a shop sends
`R × base / delta` deltas and then one base, so

```
push bytes/month = saves × delta × (1 + 1/R)
```

**The store size cancels.** That is the useful result: R alone fixes the push cost
as a multiple of the ideal delta cost — the same multiple for a hobbyist and a
farm — and what it trades against is the cold pull, bounded by `base × (1 + R)`.

| R | push vs ideal | cold pull vs blob |
|---|---|---|
| 0.5 | 3.00× | 1.5× |
| 1 | 2.00× | 2.0× |
| **2** | **1.50×** | **3.0×** |
| 4 | 1.25× | 5.0× |
| 10 | 1.10× | 11.0× |

**R = 2** is the knee. R = 10 saves a further 0.4× on push and costs 11× on a cold
pull, which is a bad trade for a rare-but-painful event.

The ratio self-scales by store size, which is right for bytes and wrong for
**time**: at R = 2 a busy shop reaches ~3,850 deltas, i.e. 3,850 decrypts on a
cold pull. So an absolute **`MAX_CHAIN_DELTAS = 1000`** bounds that latency for
every shop. For a small shop the ratio binds first and the cap never applies,
which is the intended division of labour.

Reproduce the table with `node scripts/cloud-cost-model.mjs`.

**One property fell out of this that is worth stating, because it makes the
policy safe to enable everywhere.** A delta and a whole *small* store are
dominated by the same ~1.1 KB crypto/base64 envelope, so for a tiny shop a delta
buys nothing — and the ratio notices without being told, because a single delta
already exceeds `R ×` a tiny base. Such a shop simply keeps sending blobs. The
saving scales with store size, and where there is no saving the client falls back
on its own. Pinned by a test; it was found by a test failing for what looked like
the wrong reason.

---

## 8. The mobile PWA is a blob-only client, and the gate is right to say so

`mobile/app.js` in khayt-cloud pulls `{ ciphertext, rev }` and pushes a whole
store. It has no merge engine, so it cannot fold a chain — and if it pushed a full
store over one it would flatten it, which is the §3 hazard exactly.

The gate therefore does the correct thing and holds any shop that uses `/m` to
blob sync forever. **That is not a bug to route around; it is the design working.**
But it has a consequence worth stating before anyone plans the flip:

> A shop whose owner uses the remote-mobile PWA will never get deltas, no matter
> how long adoption runs.

So §3 step 2 is not purely a waiting game. Adoption gets every *desktop* onto a
build that announces itself; it does nothing for `/m`, because there is no version
of `/m` that can fold a chain yet. Whatever share of shops use it is a share the
saving does not reach.

Making it capable means giving the PWA a merge engine. `renderer/sync.js` is pure
logic with no DOM — `lib/lan-server.js` already reaches across for
`calculator-cost.js`, and `lib/cloud-client.js` loads the same file into the main
process for exactly this reason — so the shape is known. It is still a real piece
of work in a client that handles end-to-end-encrypted data, and it cannot be
exercised end-to-end until `DELTA_WRITES` is on, which is why it is written down
here rather than half-built. `DELTA_WRITES` being on as of 2026-08-21 does not
change that: the PWA never announces capability, so a shop that uses it is held
to blob sync by the gate and this stays unexercised until the PWA can fold.
