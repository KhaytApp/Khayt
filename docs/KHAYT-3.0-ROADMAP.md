# Khayt 3.0 — Platform roadmap

**Status:** Planning. This is the design north-star for the 3.0 major update; phases land incrementally across 3.x.

> **Vision:** *Run your shop from anywhere, with an assistant* — without ever being forced into the cloud.

3.0 is a change in **kind**, not amount. Khayt is already a deep *local* shop manager; 3.0 takes it from "one computer" to a **cloud-optional platform** with four pillars: **Cloud sync**, **remote mobile**, **AI assist**, and an **internet customer portal**.

---

## 0. The non-negotiable principle — cloud is optional

**The desktop app must remain 100% functional with zero cloud account, zero internet, forever.** This is a hard constraint, not a preference. It shapes every design decision below:

- **Local `store.json` stays the source of truth** — exactly as today. Cloud is a *sync peer*, never the authority.
- **Every cloud feature is opt-in** behind a Settings toggle (the same pattern as the existing LAN API toggle). Off by default.
- **Graceful degradation everywhere** — no key / no connection / no account → the feature hides or disables; the app never blocks.
- **No telemetry or silent upload.** Connecting to Khayt Cloud is an explicit, visible action.
- Privacy positioning evolves from *"data never leaves your machine"* → *"data leaves only when you say so, end-to-end encrypted."*

This principle is also a gift to engineering: it lets us build the **sync foundation entirely locally first** (Phase 0) with no backend, no auth, no ops.

---

## 1. The four pillars

| Pillar | What | Cloud-required? |
|--------|------|-----------------|
| **Cloud sync** | Opt-in offline-first sync of the local store to Khayt Cloud | The backbone (opt-in) |
| **Remote mobile** | iOS companion works over the internet, not just LAN | Yes (rides on sync) |
| **AI assist** | Quote-from-description, AR/EN message drafting, NL analytics | **No** — BYO API key, works fully offline-of-cloud |
| **Customer portal** | Customers track orders / approve quotes / pay from a link | Yes (inherently online) |

AI assist is deliberately **cloud-independent** so it can ship first and prove value without any platform investment.

### Additional feature specs (ship across 3.x, mostly cloud-independent)
Beyond the four pillars, these features are spec'd and grounded in the current code:

| Feature | Spec | Notes |
|---------|------|-------|
| Print-file mgmt + gcode parsing | [PRINTFILES-SPEC](./KHAYT-3.0-PRINTFILES-SPEC.md) | Finishes wiring an *existing* partial gcode parser; auto-fills calculator + inventory |
| Shipping & fulfillment | [SHIPPING-SPEC](./KHAYT-3.0-SHIPPING-SPEC.md) | Saudi carriers (SMSA/Aramex/SPL); pluggable adapter; manual fallback |
| Print-farm scheduling | [SCHEDULING-SPEC](./KHAYT-3.0-SCHEDULING-SPEC.md) | Assistive, deterministic; reuses queue/assignment; optional AI tuning |
| RBAC / team roles | [RBAC-SPEC](./KHAYT-3.0-RBAC-SPEC.md) | Expands the existing operator-lock; aligns with Cloud users |
| Global sales channels | [CHANNELS-SPEC](./KHAYT-3.0-CHANNELS-SPEC.md) | Shopify/Woo/Etsy; mirrors the Salla/Zid webhook pattern |
| Accounting export | [ACCOUNTING-SPEC](./KHAYT-3.0-ACCOUNTING-SPEC.md) | File-first (offline), optional API push; VAT/ZATCA-aware |
| Maintenance scheduler | [MAINTENANCE-SPEC](./KHAYT-3.0-MAINTENANCE-SPEC.md) | Generalizes the existing single-service PM into N recurring tasks |
| QC, reprint & RMA | [QC-SPEC](./KHAYT-3.0-QC-SPEC.md) | Promotes the existing `qc` stage/badge into pass/fail + defects + linked reprints; material-accounting-safe |
| Webcam & timelapse | [WEBCAM-SPEC](./KHAYT-3.0-WEBCAM-SPEC.md) | LAN-first camera/snapshot via printer host; opt-in Cloud relay; per-print timelapse |
| Marketing & campaigns | [MARKETING-SPEC](./KHAYT-3.0-MARKETING-SPEC.md) | Segmented promo / abandoned-quote recovery over existing WhatsApp/email/Telegram + quote-followup |
| Activity log / audit | [AUDIT-SPEC](./KHAYT-3.0-AUDIT-SPEC.md) | Append-only, hash-chained who-did-what; reuses the Phase 0 save choke point; required by RBAC + security |
| Customer storefront | [STOREFRONT-SPEC](./KHAYT-3.0-STOREFRONT-SPEC.md) | Public catalog ordering; sibling of the portal under the same projection/token rules; orders via single-writer relay |
| Subscriptions / recurring | [SUBSCRIPTIONS-SPEC](./KHAYT-3.0-SUBSCRIPTIONS-SPEC.md) | Standing orders auto-generated via the quote-followup timer pattern; supersedes the weak existing `processRecurringOrders` |
| Deposits & payment plans | [PAYMENTS-SPEC](./KHAYT-3.0-PAYMENTS-SPEC.md) | Unifies deposit/milestone/installment/BNPL into one `paymentPlan`; `payStatus` stays the source of truth |
| Loyalty & store credit | [LOYALTY-SPEC](./KHAYT-3.0-LOYALTY-SPEC.md) | Builds on existing tiers + gift cards; redeems via the `giftCardDiscount` rail so payment math can't regress |
| Assembly / BOM | [BOM-SPEC](./KHAYT-3.0-BOM-SPEC.md) | Formalizes the existing `parts[]` + consumables into multi-part assemblies with cost/material rollup |
| Public API + webhooks + automation | [PUBLIC-API-SPEC](./KHAYT-3.0-PUBLIC-API-SPEC.md) | Formalizes the existing LAN API + `fireWebhook`; scoped tokens; Zapier/Make; opt-in cloud relay |
| Privacy & PDPL compliance | [PRIVACY-COMPLIANCE-SPEC](./KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md) | Maps Saudi PDPL/GDPR obligations to features; reuses export/redaction + delete-client; consent at intake |
| Reporting builder & scheduled reports | [REPORTING-SPEC](./KHAYT-3.0-REPORTING-SPEC.md) | Saved report definitions over existing analytics compute; extends the existing email digest |
| Onboarding & data import | [ONBOARDING-SPEC](./KHAYT-3.0-ONBOARDING-SPEC.md) | Extends the existing setup wizard + CSV importers; adds order import + safe merge |

---

### Engineering & readiness specs (cross-cutting, before/during build)
| Concern | Spec |
|---------|------|
| Schema migration & versioning | [MIGRATION-SPEC](./KHAYT-3.0-MIGRATION-SPEC.md) — one ordered step registry; composes with Phase 0 stamping |
| Testing strategy | [TESTING-SPEC](./KHAYT-3.0-TESTING-SPEC.md) — unifies the per-phase test plans; cloud-off golden invariant |
| Feature flags & rollout | [FEATURE-FLAGS-SPEC](./KHAYT-3.0-FEATURE-FLAGS-SPEC.md) — local off-by-default flags; cloud kill-switch is subtractive only |
| Telemetry & error reporting | [TELEMETRY-SPEC](./KHAYT-3.0-TELEMETRY-SPEC.md) — opt-in, no PII ever, off by default |

> **Cross-spec note (from migration analysis):** the QC/shipping/scheduling specs say "no migration needed (lazy-on-read)", but any field that participates in **sync/export/audit** must be backfilled so it gets a `rev`/`updatedAt`. The migration spec resolves this with explicit backfill steps; purely-UI defaults stay lazy.

## 2. Architecture — offline-first, cloud-as-peer

```
        ┌─────────────────────────────────────────┐
        │  Desktop (Electron) — SOURCE OF TRUTH     │
        │  store.json  ◀─────────  app (unchanged)  │
        │       ▲                                    │
        │       │  Sync Engine (opt-in)              │
        └───────┼────────────────────────────────────┘
                │  encrypted deltas, only when enabled
                ▼
        ┌─────────────────────────────────────────┐
        │  Khayt Cloud (optional)                   │
        │  HTTPS API · Postgres · multi-tenant      │
        │  orgId / shopId · JWT scoped per shop     │
        └───────┬───────────────────────┬───────────┘
                ▼                        ▼
          iOS companion          Customer portal (web)
          (over internet)        (track / approve / pay)
```

- **Sync Engine** is a desktop module with a pluggable backend. Backend `local` = no-op (today's behavior). Backend `cloud` = push/pull. Same interface either way, so the app is sync-shaped even when cloud is off.
- Confirmed direction from `MULTI-SHOP-CLOUD.md`: **Option A** (cloud hub + offline-first desktop sync). This doc supersedes its phasing; that doc keeps the deeper multi-shop tenancy detail.

---

## 3. Data-model foundation (Phase 0 — all local, no cloud)

The prerequisite for *any* sync, built and shipped with **no backend**. Grounded in the real store (audited against `renderer/app-state.js` / `renderer/store.js`):

**What exists today (the good news):**
- **One serialization hook** — `buildStoreSnapshot()` → `KhaytStore.buildSnapshot(collectStoreCollections())`. Every persist flows through it.
- **One save path** — `saveAll()` (debounced 300 ms) → `_doSave(snapshot)`, plus `flushSave()` for immediate writes. **A single choke point to instrument.**
- **25 collections** (24 arrays + `settings` object): `printLog, inventory, templates, products, clients, printers, expenses, machines, waTemplates, wasteLog, machMaintLog, consumables, suppliers, purchaseOrders, testPrints, locations, operators, waitingList, waitingListHistory, timeEntries, shiftLogs, giftCards, slicerProfiles, envLogs, settings`.
- **Stable ids already exist** — `uid(prefix)` = `prefix-<base36 time>-<random>`, unique enough for sync (no global coordination needed).

**What's missing:** change metadata — `updatedAt` appears only ~4× in the whole codebase. Records carry no version/rev.

### The key design decision — stamp at the save boundary, not at every mutation
Mutations happen in *every* renderer module (each edits its collection then calls `saveAll()`). Instrumenting hundreds of mutation sites with `updatedAt = now()` would be huge and leak-prone. **Instead, derive change metadata centrally at the save choke point:**

- Keep the **last-saved snapshot** in memory. On each `_doSave`, **diff each record by `id` against its previous version**; for changed/new records, set `updatedAt` and bump `rev`. Records present before but absent now → emit a **tombstone** (`{id, collection, deletedAt}`).
- This touches **one file**, needs **zero changes to mutation sites**, and is inherently correct (it reflects what actually changed on disk). Cost: one structural diff per save (cheap at this data scale; the save is already debounced).

This is the single biggest effort/risk reduction in the whole plan and it falls straight out of the single-save-path architecture.

### Phase 0 deliverables
- Central **change-stamper** at `_doSave` (above): `updatedAt` + `rev` per record, tombstone log.
- **Delta format** — "changes since cursor `(updatedAt|rev)`" extractor + applier. Doubles as faster incremental backups *today* and the sync wire format *later*.
- **Sync Engine interface** with a `local` no-op backend (see §3.1), wired behind `saveAll`/`loadAll`.
- **Conflict-policy table** per real entity (§3.2).

Ships in a 2.x point release as "internal plumbing + incremental backups." Zero user-visible cloud. De-risks everything after.

### 3.1 Sync Engine interface (sketch)
```
interface SyncBackend {
  pushDeltas(deltas, tombstones, cursor) -> { newCursor }
  pullDeltas(cursor) -> { deltas, tombstones, newCursor }
  status() -> 'off' | 'idle' | 'syncing' | 'error'
}
// Phase 0 ships LocalBackend = no-op (returns empty). Phase 1 adds CloudBackend.
// The app calls engine.onSaved(snapshot) after _doSave and engine.merge(remote) on pull.
```

### 3.2 Conflict policy (per real entity)
| Entity | Policy | Why |
|--------|--------|-----|
| `printLog` (orders) | Record-level **LWW with `rev` guard**; never auto-delete; surface true conflicts | The heart of the shop — correctness > convenience |
| `inventory`, `giftCards` | **Delta-merge** (apply weight/balance *changes*, not absolutes) | Two devices deducting the same spool must not clobber |
| `clients`, `products`, `templates`, `machines`, `suppliers`, `locations`, `operators` | LWW per record | Low concurrent-edit risk |
| `settings` | **Per-key LWW** (reuse the 2.7 deep-merge) | Already merge-aware |
| `timeEntries`, `shiftLogs`, `envLogs`, `waitingListHistory`, `machMaintLog` | **Append-only union** | Logs never conflict |

### 3.3 The v1 simplification — desktop stays the single writer
For **tenancy 1 (single shop)**, the desktop store remains the **authoritative single writer**, exactly as today: the iOS companion already routes writes *through* the desktop (LAN API). Cloud in Phase 1 is a **backup + relay**, not a second writer. That means **true multi-writer conflict resolution (delta-merge) is only required at tenancy 2 (multi-shop)** — Phase 1/2 can ship with LWW + `rev` guard and defer the hard merge. Make this explicit so we don't over-build early.

---

## 4. Phasing

Tenancy grows **1 → 2 → 3** per your call (single shop first).

Rough sizing is **t-shirt** (S/M/L/XL), not commitments — to compare phases, not to schedule.

### Phase 0 — Sync foundation (local only) · **M**
Data-model changes above (central change-stamper, tombstones, delta format, Sync Engine interface + `local` backend). No cloud. **Cloud-independent by construction.** *Risk: low — one file, behind existing save path, unit-testable with the new harness.*

### Phase 1 — Identity + single-shop cloud  *(tenancy 1)* · **XL**
*Full spec: [KHAYT-3.0-PHASE1-SPEC.md](./KHAYT-3.0-PHASE1-SPEC.md).*
- Khayt Cloud API: sign up / sign in (email + magic link), one org = one shop.
- Desktop **"Connect to Khayt Cloud"** toggle in Settings (opt-in, encrypted credentials).
- Sync the store: **start with an encrypted full-store blob + `rev` guard** (desktop = single writer, §3.3), refine to deltas later.
- **Deliverable for the user:** their shop's data is securely backed up + reachable — the basis for mobile and portal.
- *Risk: high — this is the first real backend (auth, hosting, ops, billing). The biggest single step; everything after reuses it.*

### Phase 2 — Remote mobile + customer portal · **L**
*Full spec: [KHAYT-3.0-PHASE2-SPEC.md](./KHAYT-3.0-PHASE2-SPEC.md).*
- iOS companion gains a **"Cloud" connection mode** alongside LAN — same app, reaches the shop from anywhere.
- Customer portal web app: order tracking, quote approval, online payment (extends today's LAN quote-approval tokens to internet URLs; reuse Stripe/Tabby/Tamara rails).
- *Risk: medium — mostly client work + a public web surface; backend already exists from Phase 1.*

### Phase 3 — Multiple branches, one owner  *(tenancy 2)* · **L**
*Full spec (incl. Phase 4 outline): [KHAYT-3.0-PHASE3-SPEC.md](./KHAYT-3.0-PHASE3-SPEC.md).*
- Org with several shops; shared clients/inventory pool; **HQ read-only dashboard** (revenue, queue, low-stock across shops).
- Per-shop `shopId` tagging on synced records.
- **First point where true multi-writer delta-merge is required** (§3.2/§3.3) — the deferred hard part lands here.

### Phase 4 — Separate shops / franchise  *(tenancy 3)* · **L**
- Hard tenant isolation, per-tenant billing, franchisor HQ with audit log on cross-shop reads.

---

## 5. AI assist track (parallel, cloud-independent)

Ships independently of Cloud. **BYO Anthropic API key** in Settings (encrypted like other secrets); no key → features hidden, app unaffected. *Full flagship spec: [KHAYT-3.0-AI-SPEC.md](./KHAYT-3.0-AI-SPEC.md).*

1. **Quote from a description/photo** *(flagship)* — natural-language or image request → AI proposes material, print time, and price by driving the **existing calculator**. Owner reviews/edits before sending.
   - **Contract:** AI extracts structured fields (qty, material, color, dimensions/complexity, deadline) → those feed `calculator-cost.js` (deterministic pricing), **not** an AI-invented price. AI fills the form; the existing math computes the number.
   - **Guardrails:** always owner-reviewed before sending; AI never finalizes a quote or touches the store directly; show the AI's assumptions inline so they're correctable.
2. **Customer message drafting (AR/EN)** — quote / follow-up / ready-for-pickup messages in the shop's voice. Plugs into the existing quote-follow-up automation.
3. **Natural-language analytics** — "how did June compare to May, and why?" over already-computed metrics.
4. **Smart reorder & demand forecast** — from order history + spool burn-down.

Model default: latest Claude (e.g. Opus/Sonnet 4.x). Cost model: **BYO-key first** (zero liability/cost to Khayt); a Khayt-billed option can come later with Cloud.

---

## 6. Security & KSA compliance

*Full cross-cutting threat model: [KHAYT-3.0-SECURITY-MODEL.md](./KHAYT-3.0-SECURITY-MODEL.md).*

- TLS everywhere; **tenant isolation** — `orgId` on every query, JWT scoped to `shopId`.
- **End-to-end encryption** of synced payloads where feasible (preserves the privacy promise; complicates server-side HQ aggregation — design per-field).
- **KSA-region hosting** option for ZATCA customers (e.g. AWS Bahrain / a KSA region); clarify data residency before onboarding ZATCA users.
- Encrypted secrets at rest on desktop (reuse the existing secret-masking pattern).
- Audit log for cross-shop (HQ) reads.

---

## 7. Business model (because Cloud is a *service*, not just code)

*Infrastructure, hosting, CI/CD, ops & DR: [KHAYT-3.0-CLOUD-INFRA-SPEC.md](./KHAYT-3.0-CLOUD-INFRA-SPEC.md).*

> **Taken further in [KHAYT-CLOUD-FEATURES-AND-PRICING.md](./KHAYT-CLOUD-FEATURES-AND-PRICING.md)** (2026-08-11):
> an audit of what the cloud actually does today, what is worth adding, and a
> tier table to react to. Two findings change this section rather than extend it —
> billing is already scaffolded and metering **stored bytes**, and end-to-end
> encryption rules out per-order or revenue-share pricing outright, because the
> server cannot see either. The "pricing per shop" item left open below is
> therefore **overdue, not upcoming**: it was due before Phase 1 launch, and
> Phase 1 has launched.

Cloud introduces ongoing hosting, auth, billing, support, and region-hosting cost. Honest framing:

- **Free, forever:** the full local desktop app + LAN + BYO-key AI. The product stands alone.
- **Paid (Khayt Cloud):** sync, remote mobile, customer portal, multi-shop HQ — recurring subscription, likely per-shop.
- This keeps the open, offline product intact while funding the platform.

---

## 8. Decisions — recommendations

Resolved enough to build against; revisit only if an assumption breaks.

1. **Sync granularity v1 → blob-first.** Encrypted full-store blob + `rev` guard in Phase 1 (desktop is the single writer, so a blob is safe and simple). Move to entity-level deltas when tenancy 2 introduces multi-writer. The Phase 0 delta format is built either way (for incremental backups).
2. **E2E vs server-readable → hybrid.** End-to-end encrypt the operational payload (orders/clients/inventory) so Khayt can't read shop data; have the desktop also push a **small, owner-consented aggregate** (revenue, counts, low-stock) for the HQ dashboard. Decide the aggregate's exact fields with the user before Phase 3.
3. **AI hosting → BYO-key only at first.** Zero cost/liability to Khayt, ships with no Cloud. A Khayt-billed proxy can follow once Cloud billing exists.
4. **Hosting/region → Khayt-hosted, KSA region for ZATCA customers** (e.g. a Saudi/Bahrain region). Self-hosted Cloud: defer to an enterprise ask (tenancy 3).
5. **Portal payments → reuse Stripe/Tabby/Tamara** over the internet (rails already integrated).

### Still genuinely open (need the user, later)
- Exact HQ aggregate fields (privacy vs usefulness) — before Phase 3.
- Subscription pricing per shop — before Phase 1 launch.
- Whether the customer portal is per-shop-branded or generic Khayt-branded.

---

## 9. Immediate next step

**Phase 0 — the sync foundation — is the right first move:** it's cloud-independent, ships value now (incremental backups, change tracking), and de-risks the entire platform. The audit is done (§3); the design is grounded. **Full implementation spec: [KHAYT-3.0-PHASE0-SPEC.md](./KHAYT-3.0-PHASE0-SPEC.md)** (hook point, data shapes, stamper algorithm, edge cases, migration, test plan). Concrete start:

1. **Central change-stamper** at `_doSave` — keep the last-saved snapshot, diff each record by `id`, stamp `updatedAt` + bump `rev` on change, emit tombstones for deletes. One file; no mutation-site changes.
2. **Delta extractor/applier** ("changes since cursor") — used immediately for incremental backups; later as the sync wire format.
3. **Sync Engine interface** (§3.1) + `local` no-op backend, wired behind `saveAll`/`loadAll`.
4. Tests via the new jsdom/`node:test` harness — no user-visible cloud yet.

A natural parallel track: **AI flagship (quote-from-description, BYO-key)** — fully cloud-independent, fastest visible win. After Phase 0 proves out, stand up Khayt Cloud Phase 1 (identity + single-shop sync).
