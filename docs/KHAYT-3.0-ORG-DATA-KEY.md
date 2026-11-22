# The Org Data Key — design before code

Phase 3 lets one owner run several branches. The unavoidable crypto question is
how Branch B reads Branch A's clients when Phase 1 derives the key from one
shop's passphrase.

[PHASE3-DESIGN](./KHAYT-3.0-PHASE3-DESIGN.md) called this "the part most likely
to go wrong, because a mistake is silent". That is the reason this document
exists before any implementation: a bug in delta merging shows up as a wrong
number someone notices; a bug in key wrapping shows up as data nobody can
decrypt, or data the server can read. Neither announces itself.

Everything below is checked against `lib/sync-crypto.js` as it stands on
2026-07-28. Where it says the code does something, the function is named.

---

## What already exists

More than the Phase 3 spec assumes, which changes the recommendation.

`lib/sync-crypto.js` is already a proper envelope scheme:

- A random 256-bit **DEK** encrypts the store (`createKeyset`, `DEK_BYTES`).
- The DEK is wrapped twice with AES-256-GCM — once under a KEK derived from the
  sync passphrase, once under a KEK derived from a one-time recovery key
  (`wrapDek`, `deriveKek`, scrypt N=32768, r=8, p=1).
- The server stores only salts, IVs and wrapped DEKs. GCM's auth tag doubles as
  the wrong-secret check, so there is no verifier token to leak.
- Changing the passphrase re-wraps the DEK; the store blob is untouched, because
  the DEK itself never changes.
- The keyset carries `version` (`KEYSET_VERSION = 1`), so it can be migrated.

**The thing to notice: there are no per-device keys today.** A device gets the
DEK by knowing the passphrase. Nothing is wrapped to a device.

## The decision this forces

The Phase 3 spec says the ODK should be "held by each device and wrapped to that
device's public key". That is a real design, but it is **not the smallest one
that works**, and per-device public keys buy exactly one property:

> revoking a single device without making every other device re-enter a new
> passphrase.

Everything else multi-shop needs — several shops readable by the same owner on
several machines — the existing envelope already does.

### Recommendation: the ODK is a third wrapping slot, not a new key system

An org gets its own random 256-bit key. Each shop's keyset gains a slot:

```
keyset.version = 2
keyset.wrappedByPassphrase   // unchanged — a single-shop owner never notices
keyset.wrappedByRecovery     // unchanged
keyset.wrappedByOrg          // NEW: this shop's DEK, wrapped under the ODK
orgKeyset                    // the ODK itself, wrapped by passphrase + recovery
```

A device unlocks the org passphrase once, unwraps the ODK, and uses it to unwrap
every branch's DEK. Per-shop DEKs stay per-shop, so a branch's blob is still only
decryptable by someone holding a key for that branch.

What this uses: `wrapDek` / `unwrapDek` / `deriveKek`, unchanged. **No new
primitives, no key agreement, no device identity.** The new code is a keyset
migration and one extra unwrap, both of which are testable without a server.

What it does not give you is per-device revocation — see below, where that is
argued to be the honest trade rather than an oversight.

## Rotation on revoke — and why v1 should not pretend

Removing a device today revokes its **token**, so it can no longer reach the
server. It does not remove the key material that device already holds. With an
ODK the same is true, and it is more consequential: a removed device that kept a
copy of the ODK can read every branch, not one.

Truly revoking means rotating the ODK, which means re-encrypting every branch's
blob under a new key. That is expensive, has to be **resumable** (an interrupted
rotation must not leave half the org unreadable), and needs every other device to
learn the new ODK before it can sync again.

**Recommendation: do not ship rotation in the first release, and say so in the
UI in plain words.** "This device can no longer connect" is true. "This device
can no longer read your data" would not be, and implying it is worse than
admitting the limit. The Phase 1 UI already takes this position for token
revocation; the ODK does not change the honesty requirement, it raises the
stakes.

If and when rotation is built, per-device wrapping becomes worth its cost,
because it turns rotation from "everyone re-enters a passphrase" into "drop one
wrapped copy". That is the moment to add device keys — not before.

## Recovery

Today the recovery key is per-shop, produced once by `createKeyset` and shown to
the owner. With an org there are two options and only one is defensible:

- **One recovery key for the org.** Losing it loses everything; keeping it safe
  is a single job the owner can actually do.
- Per-shop recovery keys *plus* an org key — more artefacts, more to lose, and
  the failure mode is a shop that recovers three of its four branches.

**Recommendation: one org recovery key**, and the existing per-shop recovery keys
keep working for shops that never join an org. A single-shop owner's experience
must not change at all.

The migration matters here: an existing shop that later joins an org already has
a recovery key in the owner's hands, possibly printed. It must keep working for
that shop, which the third-slot design preserves — `wrappedByRecovery` is
untouched.

## Threat model, stated plainly

| Actor | Can | Cannot |
|---|---|---|
| The server / anyone who dumps its DB | See how many shops, how big, how often each syncs | Read any shop's contents — it holds only wrapped keys and ciphertext |
| A revoked device (v1, no rotation) | Read anything it synced before removal | Reach the server, or receive anything new |
| A device with the org passphrase | Read every branch | Read another org |
| Someone with one branch's DEK but not the ODK | Read that branch | Read the others — DEKs stay per-shop |

The middle row is the one to be honest about in the UI, because it is the only
row where a user's intuition ("I removed it, so it's cut off") is wrong.

## What to build, in order

The ordering is chosen so the silent-failure risk is retired first.

1. ~~Property tests on the envelope~~ — **already done, and better than assumed.**
   `test/sync-crypto.test.js` and `test/sync-crypto-web.test.js` between them
   cover wrap/unwrap round-trips, recovery-key unlock, wrong passphrase, wrong
   recovery key, wrong DEK, tampered ciphertext, `changePassphrase`, desktop↔web
   interoperation, and that two keysets for the same passphrase yield different
   DEKs. Critically they include **"server-can't-decrypt by construction: the
   keyset carries no usable key"** — the check the whole product rests on, which
   would fail loudly if the envelope were ever inverted. Do not rewrite these;
   extend them.

2. ~~The v1 → v2 keyset migration~~ — **done**, and folded into step 3 rather
   than shipped alone. A version stamp on a keyset that gained no slot would be
   a relabelling, not a migration, so `joinOrg` performs the upgrade: the only
   moment at which v2 means anything is the moment a third slot appears.

   One thing had to be split first. `KEYSET_VERSION` and the store blob's `v`
   were the same constant, so bumping the keyset for org support would silently
   have stamped every store blob as a format that does not exist. They are now
   `KEYSET_VERSION` (2) and `STORE_BLOB_VERSION` (1), and a test asserts they
   differ — if they are ever re-merged, that test fails rather than the data.
   `lib/sync-crypto-web.js` had the same constant under the same wrong name; it
   is now `STORE_BLOB_VERSION` there too, and a cross-file test keeps the phone
   and the desktop stamping the same number.

   What made this safe in both directions: **nothing in the app reads either
   field.** They are written and never compared, so older clients ignore a slot
   they do not know. That tolerance is load-bearing, so it is asserted rather
   than assumed.

3. ~~`wrappedByOrg` plus the org keyset~~ — **done.** `createOrgKeyset`,
   `unlockOrgWithPassphrase` / `WithRecovery`, `changeOrgPassphrase`, `joinOrg`,
   `leaveOrg`, `unlockWithOrg`, over new `wrapWithKey` / `unwrapWithKey`
   primitives — the ODK is already 256 uniform random bits, so wrapping under it
   uses no KDF; scrypt would cost 32 MB and ~100 ms per unwrap to add nothing.
   Entries record `kek: 'direct'`, and each wrapping path now refuses the
   other's entries by shape rather than failing later with a GCM error that
   names nothing.

   `test/sync-crypto-org.test.js` (20 tests) is weighted towards the negative
   cases, since a too-permissive unwrap is the silent failure this document is
   written around: a shop outside the org, another org's ODK, that same ODK with
   the org label forged to match (still refused — the label is a diagnostic, the
   auth tag is the boundary), a tampered slot, and a missing org id. All 13
   guards were mutation-tested — broken one at a time, each confirmed to fail a
   test, then restored.

   The promise to an existing owner is asserted directly: after joining,
   `wrappedByPassphrase` and `wrappedByRecovery` are byte-identical, a recovery
   key printed years earlier still opens the shop, and the DEK never moves, so
   no blob is re-encrypted.

   An `orgId` was added beyond this document's sketch. It is not a secret and
   not a boundary — it exists so that pointing a shop at the wrong org reports
   itself in those words instead of as an unintelligible auth failure.

4. Only then the desktop plumbing that passes a real shop id to the per-shop
   change-index (already built — see `stampChanges(snapshot, scope)` and
   `test/phase3-delta-roundtrip.test.js`).

The useful conclusion from step 1 being already complete: **the risky half is
better defended than the Phase 3 design assumed.** The remaining exposure is not
the primitives, it is the migration and the org-scoped unwrap — both of which are
pure functions over local state, testable with no server and no network.

## What is deliberately not decided here

- **Which passphrase an org uses** — a new org passphrase, or promoting one
  shop's. This is a product question about what the owner types, not a crypto
  one, and it should be answered with the onboarding flow in front of you.
- **Whether HQ aggregate data is under the ODK or separate.** The spec wants
  consented plaintext for aggregates; mixing that into the ODK would weaken the
  "server sees nothing" claim for everything else. It deserves its own key.
