# Multi-shop shared data (cloud sync) — product design sketch

**Status:** Proposal — not implemented. Khayt today is **one shop, one encrypted store file, one computer** (optional **Locations** = branches inside that same store, not separate shops).

This document captures what “multiple shops share data” means and how we could build it without breaking offline-first users.

---

## What exists today

| Capability | Scope |
|------------|--------|
| **Local store** | All orders, clients, inventory, settings in `store.json` on disk |
| **Locations** | Multiple branches **inside one store** (filter queue/analytics by `locationId`) |
| **LAN / Online (PR #63)** | Customer intake on **your Wi‑Fi**; data still lands in **this** machine’s store |
| **Import / export** | Manual JSON backup — no live sync between shops |
| **iCloud backup** | macOS copy of backup file — not a shared operational database |

There is **no** Khayt-hosted API, org account, or sync between two different shop owners’ installs.

---

## What you asked for

An **online system** where **multiple shops** can **share data** — for example:

- A print farm with 3 sites sees one combined queue and inventory
- A franchisor sees all franchisee sales
- Two partners run Khayt on different PCs but share clients and orders

That requires **central storage + identity + sync rules**, which is a new platform layer (working name: **Khayt Cloud** or **Khayt Hub**).

---

## Architecture options

### A — Cloud hub + desktop sync (recommended for Khayt)

- **Khayt Cloud**: HTTPS API + Postgres (or similar), multi-tenant (`orgId`, `shopId`).
- **Desktop app** (current Electron): keeps local store for offline; **sync engine** pushes/pulls changes when online.
- **Conflict policy**: per-entity (e.g. last-write-wins for notes; server merge for inventory deltas; orders never deleted without explicit action).

**Pros:** Matches current product; shops work offline; gradual rollout.  
**Cons:** Build sync, auth, billing, ops.

### B — Web app only (SaaS)

- Browser-only Khayt; no local `store.json` as source of truth.

**Pros:** Simpler sync (one client).  
**Cons:** Loses “data never leaves your machine” positioning; large rewrite.

### C — Shared network drive / NAS

- Store file on SMB/NFS; one file, many PCs.

**Pros:** Small change.  
**Cons:** Corruption risk, no real multi-shop security, poor offline on laptops.

### D — Manual export hub

- Scheduled JSON upload to S3/Google Drive; HQ merges in a dashboard.

**Pros:** Fast experiment.  
**Cons:** Not real-time; not true shared editing.

**Recommendation:** **A** for production; optional **D** as a pilot for one franchise.

---

## Tenancy model (draft)

```
Organization (billing, owners)
  └── Shop A (Riyadh)     ─┐
  └── Shop B (Jeddah)      ├── share policy defined per org
  └── Shop C (Dammam)     ─┘
```

**Share policies** (org admin chooses):

| Policy | Clients | Orders | Inventory | Settings |
|--------|---------|--------|-----------|----------|
| **Unified** | Shared | Shared + `shopId` tag | Shared pool | Org template, shop overrides |
| **Federated** | Shared | Per-shop only | Per-shop | Per-shop |
| **HQ view** | Read-all | Read-all | Read-all | Shops write locally; HQ read-only dashboard |

Start with **Federated + HQ read-only dashboard** (lowest conflict risk), then add **Unified inventory** if needed.

---

## Minimum viable cloud (MVP) — phases

### Phase 1 — Identity & org (4–6 weeks engineering)

- Sign up / sign in (email + magic link or OAuth)
- Create org, invite users, assign `shopId`
- No sync yet — cloud only stores org metadata

### Phase 2 — Read-only HQ dashboard (4–6 weeks)

- Shops push **aggregated snapshots** (hourly): revenue, open orders count, low stock
- Web dashboard for org owners
- Desktop unchanged except “Connect to Khayt Cloud” in Settings

### Phase 3 — Selective sync (8–12 weeks)

- Sync **clients** and **orders** (create/update) with `shopId` + `updatedAt`
- Encrypted transport; optional E2E for sensitive fields (harder — defer)
- Desktop: conflict UI (“server version / your version”)

### Phase 4 — Real-time & mobile

- WebSocket or SSE for queue updates across shops
- iOS companion talks to **cloud** instead of only LAN

---

## Security & compliance (must-have)

- TLS everywhere; tenant isolation in API (`orgId` on every query)
- Per-shop API keys or user JWT scoped to `shopId`
- Audit log for cross-shop reads (HQ)
- Saudi data: clarify where cloud is hosted (e.g. AWS Bahrain / KSA region) for ZATCA customers
- **No** mixing tenant data in one DB row without `orgId` filter

---

## Impact on current “Online” (LAN intake)

PR **#63** (LAN `/intake`) stays **per shop** — customers hit **that shop’s** PC.

With Khayt Cloud, intake could later post to:

`POST /orgs/{orgId}/shops/{shopId}/intake` → syncs to that shop’s desktop.

Same UX for the customer; different backend when cloud is enabled.

---

## What we need from you to start Phase 1

1. **Who shares with whom?** One owner / multiple branches, or separate legal entities (franchisees)?
2. **What must be shared?** Orders only, or also clients, inventory, machines, ZATCA settings?
3. **Real-time or daily summary** enough for v1?
4. **Hosting preference?** Khayt-hosted only, or self-hosted option for enterprises?
5. **Still offline at each shop?** (assumed yes)

---

## Suggested roadmap placement

- **2.3.x / 2.4.x:** LAN online intake (#63), update-check fix (#62), desktop polish  
- **2.5.0 or 3.0.0:** Khayt Cloud Phase 1–2 (org + HQ dashboard)  
- **3.x:** Full selective sync (Phase 3)

---

## Open PR note

- **#63** — “Online” = local network intake (not multi-shop cloud).  
- Multi-shop cloud is a **separate, larger** track documented here.
