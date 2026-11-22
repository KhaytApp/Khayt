# What one shop actually costs to host

Measured 2026-08-11, to replace [CLOUD-INFRA-SPEC §10](./KHAYT-3.0-CLOUD-INFRA-SPEC.md),
whose cost envelope prices a Node + Postgres + Redis stack that production does
not run. Production is PHP 8.3 + MySQL on shared hosting.

**Re-measured 2026-08-12, after compression shipped in v3.6.0-beta.18.** That
revision corrected a claim this document made in its own §5 — see §7.

Re-run it yourself — the model is a script, not a table, and its constants come
from a second script that measures rather than assumes:

```bash
node scripts/measure-push-cost.mjs
node scripts/cloud-cost-model.mjs --plan-price 25 --bandwidth-gb 500 --storage-gb 100
```

**The finding, before the numbers: bandwidth is the binding resource, and it is
the one thing not metered.** `limits.maxStoreBytes` — the limit already built
into `/v1/billing/me` and already displayed by the desktop — meters storage,
which by measurement will never be what runs out. On a 100 GB / 500 GB plan,
storage holds about **9,890** busy shops; bandwidth holds **50**.

---

## 1. What was measured, and what was assumed

Measured from a real store:

| | bytes |
|---|---|
| per order (`printLog`) | **1,557** |
| per print file | 658 |
| per inventory item | 111 |
| settings (fixed) | 4,877 |

Measured from the protocol (`lib/cloud-backend.js`, `lib/sync-crypto.js`) by
pushing a real store through the shipped code path — `scripts/measure-push-cost.mjs`:

- **Blob-first.** `push()` encrypts and sends the **whole store**, every time. So
  bandwidth is store size × how often a shop saves, not the size of the change.
- **Compression is now on** (`COMPRESS_ON_WRITE = true`, beta.18). One push of a
  44,305 B store:

  | | wire bytes | × plaintext |
  |---|---|---|
  | compression **off** (≤ beta.17) | 59,175 | 1.336 |
  | compression **on** (≥ beta.18) | **9,590** | **0.216** |

  **6.17× like-for-like.** State it that way and no other: comparing plaintext to
  compressed wire bytes mixes two units and flatters the result, which is how the
  cost model came to carry a `GZIP_RATIO` implying 7×.
- **One changed record costs 1,134 B** on the wire, compressed — a `printLog`
  entry pushed on its own. It is dominated by the crypto/base64 envelope, not by
  the record, so it does **not** grow as the store grows. That single number is
  what makes §5 answerable.

Measured in the running app: **one save per user action.** Logging an order,
moving a kanban card, and receiving stock each produce exactly one `saveAll()`,
so "saves per day" is simply meaningful actions per day rather than a mystery
multiplier. That was the model's one soft input, and it is now grounded.

---

## 2. Per shop, per month

| profile | orders held | store | per push | was (≤ beta.17) | **bandwidth/mo now** | if deltas shipped |
|---|---|---|---|---|---|---|
| Hobbyist | 120 | 213 KB | 46 KB | 42.7 MB | **6.9 MB** | 170 KB |
| Side shop | 960 | 1.7 MB | 358 KB | 2.00 GB | **323 MB** | 1.0 MB |
| Busy shop | 6,000 | 10.1 MB | 2.2 MB | 60.8 GB | **9.8 GB** | 5.1 MB |
| Small farm | 19,200 | 32.4 MB | 7.0 MB | **519 GB** | **84 GB** | 13.6 MB |

**The one change that mattered for pricing: before compression a single "small
farm" exceeded a 500 GB plan on its own. It now fits five times over.** That —
not the spread — is the condition that gated putting a number on a tier, and it
is now met.

**The spread between the lightest and heaviest shop is still about 12,000×**, and
they still pay the same subscription. See §5; this is the part that compression
did *not* fix.

---

## 3. Why storage is a red herring

On a 100 GB storage / 500 GB bandwidth plan:

| profile | fits by bandwidth | fits by storage | binding |
|---|---|---|---|
| Hobbyist | 72,357 | 468,876 | bandwidth |
| Side shop | 1,549 | 60,256 | bandwidth |
| Busy shop | 50 | 9,889 | bandwidth |
| Small farm | 5 | 3,087 | bandwidth |

Bandwidth binds in every profile, by three to four orders of magnitude — and
compression did not change which resource binds, only how much headroom there is
before it does. **The meter that exists measures the resource that does not run
out**, which means the plan limit a shop sees today (`up to N MB`) is not the
limit that will actually stop them.

---

## 4. The number is dominated by an implementation choice, not by shops

Because sync is blob-first, a shop's bandwidth is `store size × edits`. Both grow
over time, so **cost per shop grows quadratically with age** — a three-year-old
shop pays for three years of history on every card it drags. Compression divided
that by 6.17 but left it quadratic.

| change | effect | status |
|---|---|---|
| **gzip before encrypting** | 6.17× less bandwidth, measured | **shipped, beta.18** |
| **entity-level deltas on push** | bandwidth stops scaling with store size at all | not shipped |

The second is closer than it looks: `KhaytSync.applyDeltas` already merges on
the **pull** side ([renderer/cloud-sync.js:148](../renderer/cloud-sync.js)) and
`test/phase3-delta-roundtrip.test.js` proves two stores converge byte-identically
through it. Only the push is blob-only.

---

## 5. The correction: compression is a uniform multiplier

**This document's original §5 said compression and deltas together "collapse the
12,000× spread". Compression does not collapse it at all.** It divides the
hobbyist and the farm by the same 6.17×, so the ratio between them is arithmetically
unchanged — 12,151× before, 12,151× after. The model prints both so the claim
cannot quietly drift again.

What compression actually bought is **headroom**, and headroom was in fact the
binding constraint on pricing:

| | before beta.18 | after beta.18 |
|---|---|---|
| heaviest shop, bandwidth/mo | 519 GB | 84 GB |
| …as a share of a 500 GB plan | **104% — one shop** | 17% |
| hosting cost of the heaviest shop | the entire plan | **$5.00** |
| spread, lightest → heaviest | 12,151× | 12,151× |

So the original conclusion — *do not price yet* — was right, but for a reason it
misidentified. The blocker was never the spread; a 12,000× spread is perfectly
priceable when the worst case costs $5 against a $9 subscription. The blocker was
that the worst case cost **more than the whole plan**, and compression fixed
exactly that.

**Deltas remain worth doing, and they are what makes the spread go away**: cost
becomes `1,134 B × saves`, independent of store size, so the spread collapses to
80× — the ratio of how *active* two shops are, which is all it should ever have
been. The farm drops from 84 GB/month to 13.6 MB.

Revised order, with the first two now done:

1. ~~**gzip the store before encrypting.**~~ **Shipped.** Readers landed in
   **v3.6.0-beta.17**; writers were switched on in **v3.6.0-beta.18** by flipping
   `COMPRESS_ON_WRITE`.

   The rollout gap was hours rather than weeks, so a shop running two machines
   where one is still on beta.16 or earlier will see that machine stop syncing
   until it updates. It cannot lose data — the optimistic `baseRev` guard means a
   client that cannot pull cannot push over the top — and the beta.18 release
   notes say so plainly rather than leaving it to be discovered.
2. **Put a number on the tiers** — now unblocked, and done in
   [KHAYT-CLOUD-FEATURES-AND-PRICING.md §4](./KHAYT-CLOUD-FEATURES-AND-PRICING.md).
   Carry a **fair-use clause, not a meter**: the only profile that exceeds a
   sane ceiling is the farm, and building enforcement machinery would be wasted
   work if step 3 lands first.
3. **Entity deltas on push.** Removes the size × frequency coupling, retires the
   fair-use clause, and is the same work Phase 3 needs anyway.
4. **Then stop metering entirely.** Having done 3, there is nothing left worth
   metering, and one flat price with no caps is a much better product than any
   tiered allowance.

---

## 6. What is still an input

The plan's price and caps are parameters, not findings — the defaults in the
script (25 USD, 500 GB, 100 GB) are placeholders chosen to make the arithmetic
legible. Supply the real Hostinger figures and every table above recomputes:

```bash
node scripts/cloud-cost-model.mjs --plan-price <real> --bandwidth-gb <real> --storage-gb <real>
```

Also unmeasured, and worth checking before launch: whether shared hosting caps
**entry processes or concurrent requests** tightly enough to bind before
bandwidth does. That is a plan-specific limit and cannot be derived from the
desktop code.

---

## 7. What changed on 2026-08-12, and why it is worth recording

Three claims in the 2026-08-11 revision were wrong or stale. All three came from
the same habit — carrying a compression number around instead of measuring one —
so `scripts/measure-push-cost.mjs` now exists to make the measurement the cheap
option.

| claim | was | is |
|---|---|---|
| gzip saving | "~7×", `GZIP_RATIO = 0.136` | **6.17×**, measured like-for-like |
| effect on the spread | "collapses it" | **leaves it exactly unchanged** |
| what gated pricing | the spread | the **worst case exceeding a whole plan** |

The `GZIP_RATIO` error is instructive: `0.136` was a real measurement of *gzipped
plaintext ÷ raw plaintext*, but the model applied it to *wire* bytes, which
already carry the 1.336× base64 envelope. Right number, wrong denominator, ~19%
too generous. A ratio is only meaningful with its denominator attached, and the
model now names both.

The spread error is the one that mattered, because it pointed the work in the
wrong direction: it implied compression was progress toward a flat price, so the
next step looked like "more of the same". It was not progress toward that at all
— it was progress toward *affordability of the tail*, which happened to be the
real blocker. Deltas are still the thing that fixes the shape.
