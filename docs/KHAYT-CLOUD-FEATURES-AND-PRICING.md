# Khayt Cloud — what exists, what to add, and what can actually be charged for

Research pass, 2026-08-11. **Priced 2026-08-12** — §4 now carries figures, and
§5 records which decisions closed. Every "exists" claim below was checked against
code or a live endpoint, and the evidence is named so it can be re-checked rather
than trusted. One of them did not survive re-checking a day later: see the
correction at the head of §3. It extends [§7 of the roadmap](./KHAYT-3.0-ROADMAP.md#7-business-model-because-cloud-is-a-service-not-just-code),
which sketched the business model and left one item explicitly open:

> **Still genuinely open (need the user, later)** — Subscription pricing per shop
> — *before Phase 1 launch*.

**Phase 1 launched.** [CLOUD-STATUS](./KHAYT-3.0-CLOUD-STATUS.md) records it as
done, and `cloud.khaytapp.com` is serving build `d9ffd8be69ad`. So that decision
is not upcoming, it is overdue.

**The headline finding: billing is already half-built, and nobody has to design
the metering from scratch.** The second finding is the harder one — end-to-end
encryption removes most of the dimensions a SaaS would normally price on, and
that constraint is not negotiable without giving up the privacy promise.

---

## 1. What is already built

### Billing — scaffolded, dormant

`GET /v1/billing/me` already returns a plan for a shop:

```js
// lib/cloud-client.js:501
/** GET /v1/billing/me → the shop's plan + limits (or { billingEnabled:false }). */
```

The desktop already **reads and renders it** — `showCloudPlan()` in
[renderer/settings.js:1660](../renderer/settings.js) paints
`Plan: <label> · up to <N> MB` into the cloud card, greys it when `active` is
false, and stays silent when `billingEnabled` is false. Which it currently is:
the endpoint answers `401` without a token, and no shop sees a plan today.

So the shape already committed to, in code, is:

| field | meaning |
|---|---|
| `plan` / `label` | tier id and its display name |
| `active` | subscription in good standing |
| `limits.maxStoreBytes` | **the metered dimension that already exists** |

That last row matters more than it looks — but not in the direction it first
suggests. Storage-in-bytes is already the unit the server tracks and the desktop
displays, so a storage-tiered plan looks like it needs no new concept, only a
number. **§2 and [COST-PER-SHOP §3](./KHAYT-CLOUD-COST-PER-SHOP.md) show it meters
the wrong resource**: bandwidth binds three to four orders of magnitude sooner, so
`up to N MB` is a limit no shop will ever reach. The pricing in §4 therefore does
not use it, and the recommendation is to **stop displaying it** rather than tune
it. The useful part of this row is the `plan` / `active` pair, which is the whole
entitlement mechanism and does not need changing.

### Shipped and live

Taken from the export list of `lib/cloud-client.js` — the definitive list of what
the desktop can ask the cloud to do.

| Capability | Endpoints / functions |
|---|---|
| **Identity** | `register`, `signup`, `login`, `verifyEmail`, `requestVerify`, `requestReset`, `resetPassword` |
| **E2E encrypted store sync** | `backendFor`, keyset put/get, `unlockWithPassphrase`, `unlockWithRecovery`, `changePassphrase` |
| **Team accounts** (several people, ONE shop) | `inviteMember`, `acceptInvite`, `listMembers`, `removeMember`, with roles |
| **Customer portal** | `publishPortal`, `unpublishPortal`, `listPublished`, `portalMessages`, `portalReply` |
| **Storefront** | `putCatalog`, `getCatalog`, `storefrontStats` (views / carts / orders), `getReviewSummary` |
| **Order intake** | `listIntake`, `deleteIntake` — customers submitting work |
| **Marketplace links** | per-platform import webhook + product feed URLs (Shopify, Etsy, Salla, Zid, WooCommerce…), CSV/XML/JSON per platform, with product images served as real URLs — see [STOREFRONT-SYNC.md](./STOREFRONT-SYNC.md) |
| **Cameras** | `/v1/cameras`, `/v1/cameras/snap` |
| **Organisations** | `getOrg`, `putOrg`, `createOrgInvite`, `joinOrgRemote`, `listOrgMembers`, `getOrgKeysets`, `getBranchStore`, plus org keyset crypto |
| **Billing** | `billingMe` |

### Not built — Phase 3

Per [CLOUD-STATUS](./KHAYT-3.0-CLOUD-STATUS.md), all four pillars of multi-shop
tenancy are unbuilt: no `org_id` in the schema (19 tables key on `shop_id`), no
HQ aggregate dashboard, no shared inventory, and sync is still **blob-first** —
one ciphertext per shop.

The easy mistake here, and the doc calls it out: **team accounts already exist
and look like multi-shop.** They are multi-*user* within one shop. Phase 3 is one
owner running several branches, and it changes the sync protocol rather than
adding endpoints.

**One asset is further along than the status table suggests.** The delta engine
is real, tested, and already used on the *pull* side: `KhaytSync.applyDeltas` is
what merges an incoming payload in
[renderer/cloud-sync.js:148](../renderer/cloud-sync.js), and
`test/phase3-delta-roundtrip.test.js` proves two stores converge byte-identically
through it with no server and no crypto. What is blob-only is the **push**. So
Phase 3's hardest-sounding prerequisite is mostly plumbing, not research.

---

## 2. The constraint that shapes pricing

**Khayt cannot see a shop's business.** The store is end-to-end encrypted, so the
server holds ciphertext and its length. That rules out the pricing models a
vertical SaaS would normally reach for first:

- ❌ **Per order / per job** — the server cannot count orders.
- ❌ **Percentage of revenue** — it cannot see revenue.
- ❌ **Per invoice** — it cannot see invoices.

This is not an implementation gap to close; it is the privacy promise working as
designed. Roadmap decision #2 anticipates a way round it — an *owner-consented
aggregate* pushed alongside the ciphertext for the HQ dashboard — but that is
opt-in by construction, so it can inform a dashboard and can never be a reliable
billing meter.

What the server **can** observe, today, without weakening anything:

| Dimension | Already tracked? |
|---|---|
| Stored bytes per shop | **Yes** — `limits.maxStoreBytes` |
| Team members per shop | **Yes** — `listMembers` |
| Shops / branches per owner | Once Phase 3 lands |
| Portal + storefront traffic | **Yes** — `storefrontStats` |
| Intake submissions | **Yes** — `listIntake` |
| AI proxy tokens | Only if a Khayt-billed proxy is built |

**Everything priceable is a platform dimension, not a business-volume one.** That
is a genuinely good position to be in: a shop's bill does not rise because it had
a good month, which is an easy promise to make and a rare one in this category.

---

## 3. Worth adding

Ordered by leverage, not size. Each names what it builds on.

> **Correction, 2026-08-12.** The original #1 on this list — off-site encrypted
> backup — **is already built, end to end.** Server `/v1/shops/{id}/snapshots`
> (listed in [CLOUD-STATUS](./KHAYT-3.0-CLOUD-STATUS.md) under Phase 2), backend
> `listSnapshots` / `getSnapshot` ([lib/cloud-backend.js:75](../lib/cloud-backend.js)),
> IPC `cloudSnapshotsList` / `cloudSnapshotGet` ([preload.js:230](../preload.js)),
> and restore UI at [renderer/settings.js:4422](../renderer/settings.js). It was
> listed as the highest-leverage thing to add while shipping. That is worth more
> than the embarrassment: **the single most saleable cloud feature already
> exists, so the free tier can offer it on day one at hobbyist bandwidth cost —
> 6.9 MB/month.**

> **Second pass, 2026-08-14.** Items 1 and 2 have both moved a long way since
> this list was written, and one of them is no longer an engineering task at all.
> Re-ranked below, with what is left of each.

1. ~~**Entity-level push.**~~ **Built and waiting, not unbuilt.** The desktop
   reads a chain, announces itself, asks for slices and now keeps its view across
   restarts; the server stores chains, serves `?since=`, and refuses a delta push
   for any shop with a blob-only device attached. `DELTA_WRITES` is still `false`
   and what it waits on is **adoption of a released build** — a stable one, since
   a beta does not satisfy it ([DELTA-SYNC §3](./KHAYT-CLOUD-DELTA-SYNC.md)).

   So the ~1,900× saving is no longer bought with engineering. It is bought with
   a release and the patience to let it land, and the one thing that would make
   the decision evidence-based is **being able to see which shops are eligible**
   — the server knows (it has the per-device capability record); nothing surfaces
   it. That is a small khayt-cloud endpoint plus a line in the cloud card, and it
   is the highest-leverage item on this list *because of what it unblocks*.
2. **The HQ surface, not the HQ dashboard.** Organisations shipped in 3.5.0 and
   *Across the branches* in 3.5.1, so the Branches tier is no longer selling
   something that does not exist — but what it sells is thin. The overview
   reports counts and last activity, and [`lib/branch-summary.js`](../lib/branch-summary.js)
   deliberately omits the two things a chain owner asks for first:

   - **Money.** Refused on purpose, and for a good reason: revenue is not "sum of
     price" once voided invoices, refunds and credit notes are in, and a second
     implementation that looked right would produce a chain total no branch could
     reconcile against its own reporting. The way to add it is to reuse the
     branch's own reporting code, which is the work — not the arithmetic.
   - **Dates.** "Due today" needs a calendar day, and branches may sit in
     different timezones from the person reading. The summary returns raw ISO
     and lets the renderer's locale-aware helpers decide.

   Both are desktop-only, need no server change, and are what the $29 tier is
   actually promising. This is the best ratio of willingness-to-pay to work on
   the list.
3. ~~**Portal trial expiry.**~~ **Built** — [`lib/portal-trial.js`](../lib/portal-trial.js),
   dormant until billing goes live. Two rules shaped it, and both are the kind
   that are obvious in hindsight and expensive to retrofit:

   - **The clock does not run during beta.** Every plan is free, so counting
     down would take away something shops already have — which §4 forbids in
     the same breath as it sets the prices.
   - **Beta use does not burn the trial.** A shop that published portals through
     a year of beta must not find its trial already spent on the day billing
     starts. That is precisely the "discovered a price after committing" this
     pricing exists to avoid, and it would have been the default behaviour of
     any implementation that started the clock at first publish without asking
     whether billing was live.

   The clock starts at the first published link by a live free shop, not at
   signup: a shop that connects the cloud and never publishes has not used the
   thing it would be paying for.
4. **Cloud-side scheduling.** Promoted above payments on the second pass. Every
   automation today is a renderer `setInterval`, so quote follow-ups, payment
   reminders and the email digest only run while the app is open — which is
   precisely when the shop did not need reminding. Firing them with the laptop
   shut is the kind of difference a shop notices in week one, and unlike the
   items below it needs no new commercial machinery, only a server-side job.
   Lives in khayt-cloud.
5. **Portal payments.** Rails (Stripe/Tabby/Tamara) are already integrated
   locally; taking a deposit through the portal closes the quote→cash loop. Wants
   the portal trial (built, §3.3) to be live first, so it sits behind a decision
   rather than behind code.
6. **Khayt-billed AI.** Roadmap decision #3 defers this until "Cloud billing
   exists". It half-exists — `/v1/billing/me` reports a plan, nothing collects —
   and §5.7 defers collection deliberately, so this is blocked on that decision
   and not on engineering. BYO-key remains the free path.
7. **Shared inventory across branches.** The last unbuilt Phase 3 pillar and the
   spec's own "deferred hard part": two branches drawing from one pool is the
   case blob-first single-writer sync cannot express. Correctly last — it is the
   only item here that needs the sync protocol to change, and it should not be
   started until `DELTA_WRITES` is actually on.

---

## 4. Pricing

Consistent with §0 of the roadmap: **the desktop stays 100% functional with no
account, no internet, forever.** Nothing below moves an existing local feature
behind a paywall — that would break the principle and the trust that comes with
it.

The 2026-08-11 revision gave a tier *shape* and deliberately left every figure
out, because [COST-PER-SHOP](./KHAYT-CLOUD-COST-PER-SHOP.md) said one heavy shop could exceed
a whole hosting plan on its own. **Compression shipped in beta.18 and that is no
longer true** — the heaviest modelled shop now costs $5.00 of a $25 plan, and the
median costs cents. See [COST-PER-SHOP §5](./KHAYT-CLOUD-COST-PER-SHOP.md) for
why that, and not the 12,000× spread, was the real blocker.

**What the field charges**, from [COMPETITIVE-ROADMAP §4](./KHAYT-COMPETITIVE-ROADMAP.md)
— vendor pages read July 2026, so an anchor rather than a benchmark:

| product | model |
|---|---|
| **FoxTrack** — the only directly comparable shop manager with public numbers | **free / $9 / $29 per month** |
| Layers — file→quote→order, closest whole-product match | free tier, "full access to core features" |
| 3DPBOSS — CRM + scheduling, Notion-based | one-time $49 / $99 / $139 |
| MeshVault / Meshory — library tools | one-time $19.99 / $34.99 |

So the paid band for this category is **$9–$29/month**, and the file→quote
pipeline is given away by at least two products. Khayt should not try to charge
for that pipeline; it should charge for the hosting it does on a shop's behalf.

| | **Free** | **Cloud** | **Branches** |
|---|---|---|---|
| **Price** | **$0** | **$9/mo · 35 SAR** | **$29/mo · 109 SAR** |
| | forever | $90/yr (2 months free) | $290/yr |
| Local app, LAN, BYO-key AI | ✅ everything | ✅ | ✅ |
| Off-site encrypted backup + restore | ✅ **1 device** | ✅ | ✅ |
| Multi-device sync | — | ✅ | ✅ |
| Customer portal + storefront | **30-day trial** | ✅ | ✅ |
| Team members | — | up to 3 | up to 10 |
| Multi-branch + HQ dashboard | — | — | ✅ *(Phase 3 — unbuilt)* |
| Snapshot history retained | 7 days | 90 days | 90 days |

Rounding note: SAR is pegged at 3.75/USD, so $9 → 33.75 and $29 → 108.75. Both
are rounded **up** to 35 and 109 rather than to 34 and 108, because a price that
ends in 5 or 9 reads as a price and one that ends in 4 reads as a conversion.

**What that leaves per shop**, against measured hosting cost:

| profile | hosting cost/mo | at $9 | margin |
|---|---|---|---|
| Hobbyist | $0.00 | $9 | ~100% |
| Side shop | $0.02 | $9 | 99.8% |
| Busy shop | $0.50 | $9 | 94% |
| Small farm | $5.00 | $9 | 44% |

Even the pathological case is profitable, which is the test a flat price has to
pass. And the farm is the profile that entity deltas take to **$0.01** — the
engineering fix is worth roughly $5/month per heavy shop, forever.

Four deliberate choices in that table:

- **Free is the whole product, not a trial.** It is what the app is today and it
  keeps working forever with no account. The paid line begins where Khayt starts
  paying for hosting on the shop's behalf.
- **Free includes off-site backup, on one device.** It costs 6.9 MB/month, it
  already exists, and it converts a free user into a protected user — so the
  upgrade moment is the shop's *second machine*, which is a real event in a
  growing business rather than an artificial wall.
- **The portal is a 30-day trial, not a permanent giveaway.** It is what a shop's
  own customers see, so a shop should experience it working before deciding. This
  is the one item in the table with no implementation behind it — see §3.3.
- **Priced per shop, not per order.** Forced by §2, and worth saying out loud in
  the marketing: **the bill does not grow because business was good.** In a
  category where the alternative is a percentage of revenue, that is the strongest
  line available.

**Fair use, not a meter.** One profile — the small farm, 84 GB/month — is the only
one that could hurt a plan, and entity deltas remove it entirely. So the terms
carry a fair-use clause and the server watches for outliers; **no enforcement
machinery gets built.** Building a bandwidth meter now would be work thrown away
by the very next change to the sync protocol. Note also that the meter that *does*
exist, `limits.maxStoreBytes`, measures the wrong resource — it should stop being
displayed rather than be tuned.

### Bed Ready — a separate, cheaper line

Bed Ready is commerce-free by design ([BEDREADY-APP](./BEDREADY-APP.md)) and ships
from its own repo on its own 1.0.0 line. An enthusiast has one machine and a
library, not a business, so the Khayt tiers are the wrong shape and the wrong
price.

| | **Bed Ready Free** | **Bed Ready Cloud** |
|---|---|---|
| **Price** | $0 | **$3/mo · $30/yr** |
| Local app, library, HueForge, Filament Care | ✅ | ✅ |
| Off-site encrypted backup | ✅ 1 device | ✅ |
| Multi-device sync | — | ✅ |

No portal, no storefront, no team — none of it exists in that flavor. $3 is set
against the one-time $19.99–$34.99 the library tools charge: an annual price of
$30 is the same order of magnitude as those, which is the comparison an enthusiast
will actually make.

---

## 5. Decisions — closed 2026-08-12, and what is still open

Closed by the owner:

1. ~~**A currency and a figure per tier.**~~ **$0 / $9 / $29 monthly, USD and SAR,
   annual at ten months.** Bed Ready on its own $3 line.
2. ~~**Free-tier sync: none, or one device?**~~ **One device — backup, not sync.**
3. ~~**Does the free tier get the customer portal?**~~ **A 30-day trial**, rather
   than free forever or paid-only.
4. ~~**Bed Ready cloud?**~~ **Sync and backup only, priced separately.**

Still genuinely open:

5. **Regional hosting for ZATCA shops** (roadmap decision #4) is a cost the KSA
   tier carries. Is it a price difference or absorbed? Unchanged from the previous
   revision — it needs a hosting quote, not a decision.
6. **The real Hostinger plan figures.** Every cost number above uses the script's
   placeholder plan (25 USD / 500 GB / 100 GB). The *shape* of the conclusion is
   robust — the heaviest shop is ~17% of plan bandwidth, whatever the plan costs —
   but the margin table moves with the real figures:

   ```bash
   node scripts/cloud-cost-model.mjs --plan-price <real> --bandwidth-gb <real> --storage-gb <real>
   ```

7. **Nothing above is billable until payment collection exists.** `/v1/billing/me`
   reports a plan; nothing charges for one. That is the gap between this document
   and revenue — **deliberately deferred** (owner, 2026-08-13): nobody is being
   charged for now, so collection can come later. Every tier is free in the
   meantime and the app says so, which is what makes deferring it honest rather
   than merely convenient.

   Note what that decision implies: `BETA_FREE` and the portal trial's dormancy
   are the *same* decision expressed twice. Flipping either without the other
   would either charge shops with no way to pay or expire trials while everything
   is still free.
