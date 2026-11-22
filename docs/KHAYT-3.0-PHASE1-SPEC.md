# Phase 1 — Khayt Cloud: identity + single-shop sync

**Scope:** the first backend. Account/identity, one org = one shop, and **opt-in** sync of the local store to Khayt Cloud, with the desktop as the **single writer** (tenancy 1, per [roadmap](./KHAYT-3.0-ROADMAP.md) §3.3). **No mobile-over-internet, no customer portal, no multi-shop** — those are Phase 2/3. Builds directly on the [Phase 0 sync foundation](./KHAYT-3.0-PHASE0-SPEC.md).

**Governing principle (unchanged):** cloud is **opt-in**. With it off, the app is byte-for-byte the Phase 0 app. Connecting is an explicit, visible action; nothing uploads until the user connects.

**What the user gets:** their shop is securely backed up off-device and reachable by their account — the basis Phase 2 builds mobile + portal on.

---

## 1. Architecture

```
Desktop (source of truth)                    Khayt Cloud
  store.json ── Phase0 stamper ──┐             ┌────────────────────────┐
  KhaytSync.setBackend(Cloud) ───┼── HTTPS ───▶│ API (REST) · Postgres   │
  CloudBackend.push/pull         │  JWT        │ orgs/users/shops/blobs  │
  Settings: "Connect to Cloud"   └────────────▶│ ciphertext only (E2E)   │
```

- `CloudBackend` **implements the Phase 0 `SyncBackend` interface** — Phase 0 already shaped the app for this; Phase 1 swaps the `local` no-op for `cloud`.
- **Blob-first sync** (roadmap decision §8.1): push/pull the **whole encrypted store** with an optimistic `rev` guard. Single writer → safe and simple. Entity-level deltas deferred to tenancy 2.
- **End-to-end encrypted:** the desktop encrypts the payload before upload; **Khayt stores only ciphertext** and cannot read shop data. Preserves the privacy promise.

---

## 2. Identity & tenancy

```
User (email)
  └── Organization (1)          ← Phase 1: exactly one org per user
        └── Shop (1)            ← Phase 1: exactly one shop per org
              └── Device(s)     ← desktop(s) registered to the shop
```

- **Auth:** email + **magic link** (passwordless) as primary; optional password later. Short-lived **access JWT** (15 min) + rotating **refresh token**. JWT carries `userId, orgId, shopId, deviceId`.
- **Device registration:** on connect, the desktop registers a device (name, platform) and receives a device token. Lets the user see/revoke devices.
- **Tenant isolation:** `orgId` (and `shopId`) on **every** row and **every** query — non-negotiable. No cross-tenant query path exists.

---

## 3. Encryption & key management  *(the central decision)*

E2E means the user holds a key Khayt never sees. Recommended model:

- On connect, the user sets a **sync passphrase**. Derive a data key with **scrypt/Argon2** (high cost params); encrypt the store payload with **AES-256-GCM** (or libsodium secretbox).
- Show a **one-time recovery key** (random 256-bit, base32) the user must save. Losing both passphrase and recovery key = unrecoverable cloud copy (the local store is unaffected — it's still the source of truth).
- Server stores: ciphertext, nonce, KDF params, key-check token — **never** the passphrase or plaintext.
- Account login (magic link) controls *access*; the sync passphrase controls *decryption*. Deliberately separate so a compromised inbox can't read shop data.

**Trade-off flagged:** full E2E blocks server-side HQ aggregation (Phase 3). Resolution (roadmap §8.2): the *operational payload* is E2E; later, the desktop pushes a **small, owner-consented plaintext aggregate** for HQ. Phase 1 ships **E2E only** (no aggregate yet).

---

## 4. API surface (REST, all under `/v1`, TLS only)

| Method · path | Purpose |
|---|---|
| `POST /auth/magic-link` | Request a sign-in link for an email |
| `POST /auth/verify` | Exchange link token → access + refresh JWT |
| `POST /auth/refresh` | Rotate access token |
| `POST /orgs` | Create org + shop (first connect) |
| `POST /devices` | Register this desktop → device token |
| `GET /devices` / `DELETE /devices/:id` | List / revoke devices |
| `GET /shops/:id/store` | Pull: returns `{ ciphertext, rev, updatedAt }` (or 204 if none) |
| `PUT /shops/:id/store` | Push: body `{ ciphertext, baseRev }`; **409** if `baseRev` ≠ server rev (stale) |
| `GET /shops/:id/sync-log` | Audit: who pushed when (device, rev, size, ts) |

Every shop-scoped route validates the JWT's `shopId` matches `:id`. Rate-limited per device/IP (reuse the LAN-server rate-limit pattern).

---

## 5. Sync protocol (blob-first, single writer)

**Push** (after a debounced local save, when connected):
```
1. payload = encrypt(buildStoreSnapshot + _syncMeta)   // E2E, §3
2. PUT /shops/:id/store { ciphertext, baseRev = lastKnownServerRev }
3. 200 → store newServerRev locally
   409 (stale) → another device pushed:
        pull, merge per Phase 0 §3.2 (rev guard), re-stamp, retry once
```
**Pull** (on connect, app focus, and a periodic poll — SSE/WebSocket is Phase 4):
```
GET /shops/:id/store → decrypt → applyDeltas/replace per conflict policy → update lastKnownServerRev
```
- **Single-writer reality:** with one desktop, 409s are rare (only multi-desktop). The 409→merge path is the safety net, not the common case.
- **Offline queue:** changes saved while offline just sit in the local store (the source of truth); on reconnect a single push reconciles. No separate queue needed for blob-first.
- **Concurrency:** server uses a per-shop row lock / `rev` compare-and-set so two pushes can't interleave.

---

## 6. Desktop integration

- **Settings → "Connect to Khayt Cloud"** (new section, mirrors the LAN API toggle): sign in (magic link), set sync passphrase, see status, see/revoke devices, **Disconnect** (stops sync; local store untouched).
- **Status surface:** `off | idle | syncing | error | offline` indicator (small, unobtrusive — like the LAN badge).
- **`CloudBackend`** implements `push/pull/status`; wired via `KhaytSync.setBackend('cloud')` only when connected. Disconnect → back to `local` no-op.
- **Secrets:** account/refresh tokens + passphrase-derived key handling reuse the existing encrypted-secret pattern; never written in plaintext to `store.json`.

---

## 7. Server data model (Postgres, every row carries `org_id`)

> **As built (2026-07-27):** MySQL, not Postgres, and rows key on `shop_id` —
> `org_id` arrives with Phase 3 tenancy, which is not started. See
> [CLOUD-STATUS](./KHAYT-3.0-CLOUD-STATUS.md).

```
users(id, email, created_at)
orgs(id, owner_user_id, name, region, created_at)
shops(id, org_id, name)
devices(id, shop_id, name, platform, last_seen_at, revoked_at)
store_blobs(shop_id PK, rev, ciphertext, nonce, kdf_params, updated_at, updated_by_device)
sync_log(id, shop_id, device_id, rev, size_bytes, created_at)
auth_tokens(...)   // magic-link + refresh, hashed
```
`store_blobs` is one row per shop (blob-first). Tenant isolation enforced in a query layer that *requires* `org_id`/`shop_id` — no raw cross-tenant access.

---

## 8. Security & compliance

- TLS everywhere; HSTS. JWT scoped to `shopId`; refresh rotation + revocation.
- **KSA-region hosting** option for ZATCA customers (roadmap §8.4); document data residency before onboarding.
- Tenant isolation tested adversarially (one shop's JWT must never read another's blob → automated test).
- Rate limiting, request size caps (blob ceiling, e.g. 25 MB → chunking is a 3.x optimization), audit log.
- Abuse: magic-link throttling, device cap per shop.

---

## 9. Failure modes

| Case | Behavior |
|------|----------|
| Offline | App fully works; sync resumes on reconnect (local is truth) |
| Stale push (409) | Pull → merge (rev guard) → retry once → surface conflict only if unresolved |
| Lost passphrase + recovery key | Cloud copy unrecoverable; **local store unaffected** — user can re-connect with a new key (re-uploads) |
| Auth expiry | Silent refresh; if refresh fails, status → error, prompts re-sign-in; **no data loss** |
| Partial/failed upload | `rev` not advanced server-side (atomic CAS); client retries |
| Blob too large | Reject with clear error; chunking deferred (3.x) |

---

## 10. Open decisions (need the user before launch)

1. **Hosting provider + KSA region** — and whether a self-hosted Cloud option ships for enterprises (lean: defer to tenancy 3).
2. **Subscription pricing** per shop (Cloud is the paid tier; local stays free forever).
3. **Recovery-key UX** — one-time display vs downloadable file vs both (lean: both, with a "I saved it" confirm).
4. **Sync cadence** — on-save (debounced) + focus + N-minute poll? (lean: yes; real-time SSE is Phase 4.)

---

## 11. Test plan & definition of done

- **Isolation (critical):** shop A's JWT → `GET /shops/B/store` returns 403; fuzz `org_id`/`shop_id` mismatches.
- **Round-trip:** connect → push → wipe local → pull → decrypt → store matches (golden compare).
- **E2E:** server payload is opaque ciphertext; with no passphrase the server cannot decrypt (assert by construction + test).
- **409 path:** simulate two devices; stale push triggers pull-merge-retry; no data loss; higher `rev` wins per policy.
- **Disconnect:** sync stops; local store byte-identical; reconnect resumes.
- **Auth:** magic-link verify, refresh rotation, revoked device rejected.
- **Offline:** edits offline → reconnect → single reconciling push.

**DoD:** a connected single-shop user has an E2E-encrypted, restorable cloud copy that round-trips losslessly; tenant isolation is adversarially tested; a disconnected/cloud-off user sees **zero** change from Phase 0. No mobile/portal/multi-shop code.
