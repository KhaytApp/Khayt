# Khayt Cloud — what is actually built

The five phase specs describe what the cloud *should* do. None of them records
what it *does*, so "what is left" has been guesswork. This is the reconciliation:
every claim below was checked against code or a passing test on 2026-07-27, and
the evidence is named so the next person can re-check rather than trust it.

**Verify this file rather than believe it.** Where it says a thing is covered, a
named test covers it; where it says something is not built, the grep that found
nothing is stated too.

| Phase | Scope | Status |
|-------|-------|--------|
| 0 | Sync foundation (local change-tracking, deltas) | **Done** |
| 1 | Identity + single-shop E2E sync | **Done** |
| 2 | Remote mobile + customer portal | **Done**, beyond spec |
| 3 | Multi-shop tenancy | **Part built** — organisations and a cross-branch view shipped; see below |
| 4 | Franchise / separate shops | Not started (outline only) |

> **Re-checked 2026-08-14.** Two rows below had gone stale in the direction that
> matters — they said "not built" about things that ship today, which is the way
> a status file causes work to be skipped rather than merely misread. Both are
> corrected in place with the evidence that settled them.

---

## Phase 0 — sync foundation

Definition of done, item by item:

| Requirement | Evidence |
|---|---|
| Saves stamp `rev`/`updatedAt` | `test/cloud-sync.test.js` |
| Deletes write tombstones | `test/cloud-sync.test.js` |
| `KhaytSync` interface + `LocalBackend`, no cloud code | `test/sync-foundation.test.js` |
| Cloud-off users see zero behaviour change | golden-snapshot test in `test/sync-foundation.test.js` |

42 tests across `test/sync*.test.js`, all passing.

## Phase 1 — identity + single-shop sync

| Requirement | Evidence |
|---|---|
| Tenant isolation: shop A's token cannot read shop B | `contract.test.js` — "tenant isolation" |
| Round-trip: push → pull → decrypt matches | `contract.test.js` — "full contract" |
| Server payload is opaque ciphertext | `contract.test.js`, asserted by construction |
| 409 stale push → pull-merge-retry | `contract.test.js` — rev-guard |
| Auth: verify, rotation, revoked device rejected | `contract.test.js` — "removal revokes the token immediately" |
| Disconnect leaves the local store byte-identical | desktop `test/cloud-sync.test.js` |
| Offline edits → one reconciling push | desktop `test/cloud-sync.test.js` |

Live at `cloud.khaytapp.com`. Since 2026-07-27 the contract suite runs against
the **PHP** backend in CI as well as Node — before that only Node, which is not
deployed, was ever tested.

## Phase 2 — remote mobile + customer portal

Built, and past what the spec asked for:

| Feature | Where |
|---|---|
| iOS companion over the internet | `mobile/` PWA, served at `/m` |
| Customer portal (track / approve / pay) | `/v1/portal/*`, `/v1/p/{token}` |
| Per-order public projection (consented) | `/v1/p/{token}` — only the projection is public; the bulk store stays E2E |
| Web push notifications | `/v1/push/*` + VAPID |
| Portal messaging (shop ↔ customer) | customer: `/v1/p/{token}/messages` · shop: `/v1/shops/{id}/published/{token}/messages` (read) and `/message` (reply) — the owner side is authenticated, so the customer route can be gated on their portal session |
| Storefront + catalog feed + order import | `/v1/shops/{id}/catalog`, `/feed/{platform}`, `/import/{platform}` |
| Reviews | `/v1/shops/{id}/reviews` |
| Snapshot history + restore | `/v1/shops/{id}/snapshots` |
| Billing plans + storage caps | `/v1/billing/*`, `/v1/admin/set-plan` |

## Phase 3 — multi-shop tenancy: **part built**

A design that reconciles the spec with the code, and states the choices it needs,
is in [PHASE3-DESIGN](./KHAYT-3.0-PHASE3-DESIGN.md).

The spec's four pillars, as of 2026-08-14:

| Pillar | Status |
|---|---|
| Org → many shops | **Built, by a different mechanism than the spec assumed.** Not `org_id` on every row: an org has its own keyset (the Org Data Key, [ORG-DATA-KEY](./KHAYT-3.0-ORG-DATA-KEY.md)) that opens every branch's DEK, and branches are joined by invite. `hub:org-create-keyset` / `-unlock` / `-enrol-shop` / `-invite` / `-join` / `-members` / `-leave` in main.js; `getOrg`, `putOrg`, `createOrgInvite`, `joinOrgRemote`, `getOrgKeysets`, `getBranchStore` in cloud-client. Shipped in **3.5.0** |
| HQ aggregate dashboard | **Built at the "counts" level** — `hub:org-overview` reads every branch's store, decrypts each with the org key, and returns per-branch summaries plus a chain total; the UI is *Across the branches* ([renderer/settings.js](../renderer/settings.js), `openOrgOverview`). Shipped in **3.5.1**. What it deliberately omits is money and dates, and [`lib/branch-summary.js`](../lib/branch-summary.js) explains why — that omission is the gap worth closing next, not the dashboard itself |
| Shared inventory with concurrent-draw merge | **Not built** — the spec's own "deferred hard part" |
| Entity-level deltas (vs one blob per shop) | **Reader built, writer off.** Desktop folds `base + deltas`, announces `X-Delta-Capable`, asks `?since=`, and keeps its view across restarts; the server implements the chain, the slice and the per-shop gate (khayt-cloud#16, live). **`DELTA_WRITES` is `true` as of 2026-08-21** — an un-eligible shop is refused with 404 and keeps blob-syncing, so the flip never needed full adoption; adoption now sets only how much is saved — [DELTA-SYNC §3](./KHAYT-CLOUD-DELTA-SYNC.md), [adoption endpoint](./KHAYT-CLOUD-ADOPTION-ENDPOINT.md) |

Still worth keeping straight, because it trips everyone: **team accounts** —
several people inside ONE shop (`/v1/shops/{id}/members`, invite / list / remove,
with roles) — are multi-USER. Organisations are multi-SHOP. Both now exist, and
they are different features.

What remains of Phase 3 is the part that changes the storage model: blob-first
single-writer sync cannot express two branches editing different records
concurrently, which is why the spec calls conflict resolution "the deferred hard
part". Shared inventory is that problem in its sharpest form — two branches
drawing from one pool — and it is the one pillar with nothing behind it.

---

## Where the specs are now wrong

- **The infra spec prescribes Node/Fastify + PostgreSQL + Redis.** Production is
  **PHP 8.3 + MySQL on shared hosting (Hostinger/LiteSpeed)**, with the Node
  implementation kept as a VPS option. The pragmatic choice looks right — PHP
  runs per request, so there is no process to keep alive — but the spec now
  misleads anyone reading it as a description of the system.

- **Phase 1 §7 says "Postgres, every row carries `org_id`".** Neither is true:
  MySQL, and no `org_id` until Phase 3.

## Decisions that were open, and how they closed (2026-07-28)

- **Registration is open — deliberately now.** It used to be open by *omission*:
  the gate read "allowed unless `register_secret` happens to be set", so a config
  that never mentioned registration handed a shop and a token to anyone who
  asked. It now refuses unless the operator has chosen — a secret to require, or
  `open_registration => true` to invite anyone. Production is set to open, which
  is the same behaviour as before but for the opposite reason.

- **A shop can be deleted.** `DELETE /v1/admin/shops/{shopId}`, admin-gated,
  removes the 13 shop-keyed tables plus the owner's reset and verify tokens. It
  deliberately leaves customer portal sessions (keyed on the customer's email
  with no shop link — deleting would sign them out of a shop that still exists)
  and IP rate events (clearing them would hand a spammer a fresh allowance).
