# Phase 3 — Multi-shop (tenancy 2), with a Phase 4 outline (tenancy 3)

**Scope:** the org grows from one shop to **several shops under one owner** (branches / a print farm), with an **HQ dashboard** and **shared data**. This is where the deferred hard parts land: **multi-writer sync** (entity-level deltas replace the Phase 1 blob) and the **HQ aggregate**. Implements [roadmap](./KHAYT-3.0-ROADMAP.md) Phase 3; turns the [MULTI-SHOP-CLOUD.md](./MULTI-SHOP-CLOUD.md) product sketch into a build-from spec. Phase 4 (separate legal entities / franchise) is outlined at the end.

**Governing principle (unchanged):** still opt-in; a single-shop or cloud-off user is unaffected. Multi-shop is purely additive.

**Prerequisite:** Phases 0–1. Phase 2 (mobile/portal) is independent and may or may not precede this.

---

## 1. What changes vs Phase 1

| Dimension | Phase 1 (tenancy 1) | Phase 3 (tenancy 2) |
|-----------|---------------------|---------------------|
| Writers | Desktop = single writer | **Many shops write concurrently** |
| Sync unit | Encrypted full-store **blob** | **Entity-level deltas** (Phase 0 delta format goes on the wire) |
| Org shape | 1 org = 1 shop | 1 org = **N shops**, share policy per org |
| Encryption key | Per-shop **sync passphrase** | **Org-scoped shared key** (branches must decrypt shared data) |
| HQ view | — | **Read-only aggregate dashboard** |

The two big new builds: **entity-delta merge** and the **org key model**.

---

## 2. Tenancy & share policies

```
Organization (owner, billing, region)
  ├── Shop A (Riyadh)   ┐
  ├── Shop B (Jeddah)   ├─ share policy (org admin)
  └── Shop C (Dammam)   ┘
```

Concrete policies (from MULTI-SHOP-CLOUD.md, sequenced safest-first):

| Policy | Clients | Orders | Inventory | Ship first? |
|--------|---------|--------|-----------|-------------|
| **Federated + HQ read** | shared | per-shop (`shopId`) | per-shop | **Yes — v1 of Phase 3** (lowest conflict) |
| **Unified** | shared | shared, `shopId`-tagged | **shared pool** | later (needs robust inventory delta-merge) |

Start **Federated + HQ read-only**: shops own their own orders/inventory; clients are shared; HQ sees an aggregate. Add **Unified shared inventory** only once delta-merge is proven.

---

## 3. Data model: `shopId` + entity deltas

- Every synced record gains **`shopId`** (the originating shop). Existing single-shop data migrates to the org's first `shopId`.
- **Sync moves from blob → entity deltas** (the Phase 0 `extractDeltas/applyDeltas` format, now over the wire):
  - Each shop pushes/pulls **per-entity deltas** scoped by share policy (its own `shopId` for per-shop entities; the org pool for shared entities).
  - Server keys deltas by `(orgId, collection, id)` with `rev`; `org_id` on every row (Phase 1 §7) still absolute.
- **Cursor** becomes per-(shop, collection) high-water marks rather than one blob `rev`.

---

## 4. Conflict resolution (multi-writer — the deferred hard part)

Per the Phase 0 policy table (§3.2), now actually exercised:

| Entity | Multi-writer rule |
|--------|-------------------|
| `clients`, `products`, `templates`, `machines`, … | **LWW by `rev`**, then `updatedAt` tiebreak; conflicts logged, never silently dropped |
| **`inventory`, `giftCards`** (shared pool) | **Delta-merge** — sync **deltas of quantity** (spool grams drawn, balance spent), not absolutes, so two shops drawing the same pool **sum** instead of clobbering. Requires recording each mutation as a signed delta op with an op-id (idempotent apply). |
| `printLog` (orders) | Per-shop ownership (Federated) → no cross-shop conflict in v1. Under Unified, LWW by `rev` + never auto-delete. |
| Append logs (`timeEntries`, `shiftLogs`, …) | **Union by id** — inherently conflict-free |

**Ordering:** `rev` (per record) is authoritative; wall-clock is advisory (clock skew across shops is real). For the shared inventory pool, the **delta-op log** (append-only, idempotent by op-id) is the source of truth, and the absolute quantity is a fold over it — this is the one place that genuinely needs more than LWW.

**Conflict surfacing:** unresolved LWW collisions (same record, concurrent edits, neither a clear winner) raise a desktop "review" prompt (server-version / your-version), never a silent overwrite.

---

## 5. Encryption with sharing (key model evolution)

Phase 1's per-shop passphrase can't let Branch B decrypt Branch A's shared clients. Resolution:

- **Org data key (ODK):** one symmetric key per org, used to encrypt shared/operational data. Each member's device holds the ODK, wrapped by that **device/user key** (so the server still never sees the ODK).
- **Onboarding a shop/device:** the org owner authorizes it; the ODK is delivered **wrapped to the new device's public key** (no plaintext key on the server). Revocation removes a device's access; rotate the ODK on owner-initiated revoke for forward secrecy.
- **HQ aggregate stays separate** (see §6) — it's a small **plaintext, consented** push, not under the ODK, so the server can aggregate it.

This keeps **bulk data E2E** while enabling sharing. The ODK wrap/unwrap + rotation is the security-critical new code (threat-modeled in [SECURITY-MODEL](./KHAYT-3.0-SECURITY-MODEL.md)).

---

## 6. HQ read-only dashboard

- Each shop's desktop pushes a **small, owner-consented plaintext aggregate** (hourly + on demand): revenue, open-order count, completed today, low-stock count, machine-busy count — **no** PII, **no** line items, **no** cost/margin detail.
- The aggregate's exact fields are an **owner-approved allowlist** (roadmap open decision) shown before first push.
- Web HQ dashboard (org owner): per-shop tiles + org rollups, all from the aggregate. **Read-only** — HQ does not write into shops in tenancy 2.
- **Audit:** every cross-shop/HQ read is logged (who, which shop, when).

---

## 7. Migration (Phase 1 → Phase 3)

1. Org gains the ability to hold >1 shop; existing data tagged with the first `shopId`.
2. Switch the sync engine from blob to entity-delta backend (the desktop already produces deltas since Phase 0; the cloud gains delta endpoints).
3. Derive + distribute the ODK; migrate the per-shop passphrase-encrypted blob to ODK-encrypted entities (one-time re-encrypt, owner-initiated).
4. Backward compatible: a single-shop org keeps working throughout; blob mode remains until the org explicitly adds a second shop.

---

## 8. Phase 4 outline — separate shops / franchise (tenancy 3)

Larger, later; sketch only:
- **Hard tenant isolation** between *legal entities* (a franchisor + independent franchisees) — stricter than branches of one owner; separate ODKs per franchisee, franchisor gets **only** the consented aggregate (never franchisee operational data).
- **Per-tenant billing** and quotas.
- **Franchisor HQ** with cross-tenant **read** of aggregates + a mandatory **audit log** on every cross-tenant access.
- **Data residency** per franchisee (KSA region for ZATCA), possibly **self-hosted Cloud** for enterprise franchisors.
- Governance: data-processing terms, per-franchisee consent for what the franchisor sees.

---

## 9. Test plan & DoD

- **Federated isolation:** Shop B cannot read Shop A's per-shop orders/inventory; only shared clients + the aggregate cross over (adversarial test).
- **Delta-merge:** two shops draw 100 g + 150 g from a shared spool concurrently → pool reflects **−250 g** (sum), not last-write; replaying a delta op is idempotent (no double-apply).
- **LWW + surface:** concurrent edits to a shared client → higher `rev` wins; a true tie raises a review prompt, never a silent drop.
- **ODK:** a new device decrypts shared data only after owner authorization; a revoked device cannot decrypt post-rotation; server never holds a plaintext ODK (by construction + test).
- **HQ aggregate:** dashboard shows only allowlisted fields; no PII/line-items/margins present (assert); every HQ read audited.
- **Migration:** 1-shop org → add 2nd shop → blob re-encrypts to ODK entities losslessly; a never-multi-shop org is untouched.
- **Cloud-off / single-shop:** behavior identical to Phase 1.

**DoD:** an owner runs multiple branches with shared clients and an HQ aggregate dashboard; shared inventory (when enabled) merges concurrent draws correctly; bulk data stays E2E under an org key the server never sees; single-shop and cloud-off users are unaffected.
