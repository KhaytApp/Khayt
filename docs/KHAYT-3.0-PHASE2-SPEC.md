# Phase 2 — Remote mobile + customer portal

**Scope:** make the shop reachable over the internet. Two deliverables that ride on the [Phase 1](./KHAYT-3.0-PHASE1-SPEC.md) backend: (a) the **iOS companion over the internet** (not just LAN), and (b) a **customer portal** (track / approve / pay from a link). Still **tenancy 1** (single shop, desktop = source of truth). Implements [roadmap](./KHAYT-3.0-ROADMAP.md) Phase 2.

**Governing principle (unchanged):** both features are **opt-in** and require Phase 1 cloud to be connected. Cloud off → LAN-only behaves exactly as today; the desktop app is unaffected.

**Big reuse win:** the customer-facing approve/track flow **already exists on LAN** (`lib/lan-quote-page.js`, `ensureQuoteApprovalToken` / `ensureTrackingToken`, public `GET /order/:id/quote` + `POST /order/:id/approve`, brute-force throttling, quote expiry). Phase 2 makes that flow **internet-reachable via Cloud** — it does not reinvent it.

---

## Part A — iOS companion over the internet

### A1. Connection modes
The companion gains a **Cloud mode** alongside the existing LAN mode:

| Mode | Reaches | When |
|------|---------|------|
| **LAN** (today) | shop PC on same Wi-Fi | in the shop |
| **Cloud** (new) | shop data via Khayt Cloud | anywhere |

- Pairing in Cloud mode = sign in to the **same Khayt Cloud account** (magic link), pick the shop. No IP/PIN.
- The app prefers LAN when both are available (faster, no round-trip); falls back to Cloud off-network. Surface which mode is active.

### A2. Data path (read + the write question)
- **Reads** (queue, inventory, machines, clients): the cloud serves the **decrypted view** the desktop synced. *But E2E (Phase 1 §3) means the server holds ciphertext only* — so the mobile client must hold the **sync passphrase** to decrypt, entered once and stored in the iOS Keychain. This is the key design consequence of E2E: **the phone decrypts, not the server.**
- **Writes** (advance status, edit spool, create/assign order): tenancy 1 keeps the **desktop as the single writer**. Two options:
  - **A (recommended): relay** — the phone submits an *intent* (e.g. "advance order X"); the desktop applies it to the store and the change syncs back. Preserves single-writer; matches today's LAN model where the phone calls the desktop.
  - **B: phone writes the blob** — phone edits, re-encrypts, pushes with `rev` guard. Simpler offline, but makes the phone a second writer (the 409/merge path) earlier than necessary.
  - *Lean A* for Phase 2; revisit when the desktop may be offline while the phone needs to write (then B or a queued-intent store).
- **Offline desktop caveat:** if the desktop is off, relay writes queue in the cloud and apply when it next syncs. Make the "pending until shop online" state visible.

### A3. Reuse
The iOS app already speaks a clean API client (`KhaytAPIClient`). Cloud mode swaps the base URL + auth (JWT instead of LAN PIN) and adds a decrypt step; the view models are unchanged.

---

## Part B — Customer portal (web)

### B1. What it is
A public, link-accessed web app (served by Khayt Cloud) where a customer can:
- **Track** an order's status (the existing tracking-token flow).
- **Approve** a quote (quote → pending — the existing public approve flow).
- **Pay** — online payment via the **already-integrated Stripe / Tabby / Tamara** rails.
- **Reorder** (later) — re-request a past item.

### B2. How it reuses the LAN flow
- **Tokens:** the same `ensureQuoteApprovalToken` / `ensureTrackingToken` per order; the public URL becomes `https://portal.khayt…/order/:id/quote?t=…` instead of `http://<lan-ip>/order/:id/quote`.
- **Page rendering:** `lib/lan-quote-page.js` logic moves/extends to the cloud renderer (or the cloud proxies to a shared renderer) — same HTML, same escaping, same expiry behavior.
- **Approve:** `POST /order/:id/approve` (quote→pending only, public) maps to a cloud endpoint that relays the approval to the shop (single-writer, Part A2-A).

### B3. The E2E tension (important)
The portal needs to show **one order** to a customer, but the store is E2E-encrypted server-side. Resolution: the **desktop publishes a per-order, token-scoped, decrypted snapshot** to the cloud for orders that have an active quote/tracking token (owner-initiated when sharing the link). I.e. the customer-shared fields are deliberately *not* part of the E2E blob — they're a minimal, consented, per-order projection. This keeps the bulk store E2E while making shared orders viewable. Define the projected fields explicitly (status, item, price, due date, pay link — **no** internal cost/margin/notes).

### B4. Payments
- Reuse existing provider config (`bnpl`/`stripe` settings). The portal creates a payment intent via the configured provider; on success, the desktop records payment (relay, single-writer).
- Webhooks (payment confirmation) hit the cloud → relay to desktop → `paidAmount` update syncs.

---

## Security (public surface — higher stakes)

- Tokens are unguessable, **per-order**, **expiring** (reuse existing token + expiry); brute-force throttling (reuse existing per-IP tracking).
- Portal serves **only** the consented per-order projection (B3) — never the store, never other orders.
- Payment provider secrets stay server-side (cloud) / in desktop settings; never exposed to the portal client.
- Standard web hardening: CSP, no inline secrets, rate limits, bot protection on approve/pay.
- Tenant isolation continues to apply to all cloud APIs (Phase 1 §8).

---

## Failure modes

| Case | Behavior |
|------|----------|
| Desktop offline, customer approves/pays | Action accepted + queued in cloud; applies on next desktop sync; customer sees "received" |
| Cloud disconnected (owner) | Portal links inactive; LAN flow still works on-network; app unaffected |
| Phone lacks passphrase | Cloud reads can't decrypt → prompt to enter passphrase (Keychain); LAN mode still works |
| Token expired | Existing "quote expired / contact shop" page |

---

## Test plan & DoD

- **iOS Cloud mode:** sign-in → decrypt with passphrase → queue/inventory render off-network; LAN preferred when present.
- **Relay write:** phone "advance order" → desktop applies → syncs back; with desktop offline, queues and applies on reconnect.
- **Portal track/approve:** token URL renders the per-order projection only; approve flips quote→pending via relay; expired token → expiry page.
- **Projection isolation:** portal response contains only the consented fields — assert cost/margin/notes/other orders never leak.
- **Payment:** intent via existing rails; webhook → relay → `paidAmount` updates and syncs.
- **Cloud-off:** LAN-only behavior identical to today; desktop unaffected.

**DoD:** an owner can run their shop from their phone over the internet and share a working track/approve/pay link with a customer — with the bulk store still E2E and only a consented per-order projection ever public. Cloud off → no change from Phase 1.
