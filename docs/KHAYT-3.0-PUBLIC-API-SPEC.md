# Public API + outbound webhooks + automation (Zapier/Make)

**Scope:** let a shop automate its own workflows against Khayt without writing a backend. Three layers, all built on code that already ships: (1) a **documented, versioned local API** — the existing `lib/lan-server.js` HTTP server, formalized under `/v1` and extended for write automation; (2) **outbound webhooks** on shop events — the existing `fireWebhook` mechanism, extended into a real event bus with signing, retry, and a delivery log; (3) **Zapier/Make connectors** — thin wrappers over (1) and (2), no new server logic. Implements [roadmap](./KHAYT-3.0-ROADMAP.md) automation; reads on [Phase 1](./KHAYT-3.0-PHASE1-SPEC.md) for the optional cloud relay and the [security model](./KHAYT-3.0-SECURITY-MODEL.md) throughout.

**What the user gets:** "when an order ships, post to Slack / add a row to a Sheet / send a WhatsApp" and "create an order from a Typeform" — configured in Zapier/Make, no code. Power users get a stable documented API to script directly.

**Governing principle (unchanged from `LAN_API.md` and the security model):** the API is the **shop's own LAN server** and works **with cloud off** — it is local-first, byte-for-byte the current app when no integration is connected. The cloud-relayed public API (reachable over the internet) is an **additive, opt-in** layer that rides Phase 1's authenticated tunnel; it never becomes a hard dependency. We **formalize and version** what `lib/lan-server.js` already does — we do not replace it.

---

## 1. Public API — versioned `/v1`

The current routes (`GET /api/status`, `/api/queue`, `/api/orders`, `GET|POST /api/inventory`, `/api/machines`, `/api/clients`, `/api/waiting-list`, `PATCH /api/orders/:id`, etc. — see `docs/LAN_API.md`) become the **frozen `v0` surface** and are mirrored under **`/v1`** with stable, documented shapes. `/api/*` stays as a permanent alias for the iOS `KhaytAPIClient` and existing PWA/kiosk callers (no breakage).

**Read endpoints (formalize existing):** `GET /v1/orders` (filter `status`, `limit≤200`), `GET /v1/orders/:id`, `GET /v1/clients`, `GET /v1/inventory`, `GET /v1/machines`, `GET /v1/machines/live`, `GET /v1/waiting-list`, `GET /v1/status` (public counts).

**Write endpoints for automation (extend):**
- `POST /v1/orders` — already exists (create order/quote); document fully under `/v1`.
- `PATCH /v1/orders/:id` — already exists (status/machine); add `dueDate`, `notes`, `paymentStatus` to the writable set (validated against the same allowlists used in `lan-server.js`).
- `POST /v1/clients`, `PATCH /v1/clients/:id` — **new**, mirroring the inventory write pattern (sanitize via a `pickClientFields` helper; persist via `persistLanStoreUpdate`; emit a `lan-client-*` IPC).
- `POST|PATCH|DELETE /v1/inventory[/:id]` — already exists; document under `/v1`.

Every write reuses the existing body cap (`MAX_BODY` 1 MB), JSON sanitizer (`parseLanJsonBody` + per-field `slice`/clamp), disk persist (`persistLanStoreUpdate`), and renderer IPC notify (`getMainWindow().webContents.send(...)`) so the desktop UI stays in sync. Mutations also feed the outbound event bus (§2).

**Auth — scoped API tokens (new, additive to PIN).** The PIN/`x-khayt-pin` path is untouched for humans and the iOS app. Automation uses **scoped bearer tokens**: `Authorization: Bearer khayt_<base64url-32B>`. Tokens are minted in **Settings → LAN API → API tokens**, stored **hashed** (SHA-256, same encrypted-secret pattern as `lanApi.pin`/`webhookToken`), shown in plaintext **once**. Each token carries a **scope set** — `orders:read`, `orders:write`, `clients:read`, `clients:write`, `inventory:read`, `inventory:write`, `machines:read` — and an optional label, `createdAt`, `lastUsedAt`. A token grants only its scopes; a `orders:read` token gets 403 on any write. Token verification reuses `safeTokenEqual` and slots into the existing auth branch in `lan-server.js` alongside the PIN check.

**Rate limits.** Reuse the existing per-IP brute-force map (`failedAttempts`, 10/min → 429) for auth failures and add a per-token throughput bucket (default **120 req/min/token**, 429 with `Retry-After`). The tunnel-mode global backstop (`globalAuthThrottle`) and `tunnelClientIp` XFF handling apply unchanged. Bodies capped at 1 MB (existing `MAX_BODY`).

---

## 2. Outbound webhooks — event bus

Today `renderer/fireWebhook(event, payload)` looks up a single URL in `settings.webhooks.events[event]` and calls `hub:fire-webhook` (main.js), which POSTs `{ event, payload, timestamp }`, signs with HMAC-SHA256 (`X-Khayt-Signature`), is **https-only**, blocks private/loopback hosts (SSRF), refuses redirects, and times out at 10s. We keep all of that and turn it into a real subscription bus.

**Event catalog (extend existing emit sites — no new emit plumbing where one exists):**

| Event | Emitted at (existing unless noted) |
|---|---|
| `order_created` | `renderer/order-flows.js:143`; also `POST /v1/orders` |
| `status_changed` | `order-flows.js:338`, `logs.js:367` |
| `order_shipped` | **new** — fire alongside the shipping flow ([SHIPPING-SPEC](./KHAYT-3.0-SHIPPING-SPEC.md)) |
| `order_delivered` | `order-flows.js:197`, `logs.js:368` |
| `payment_received` | `order-flows.js:704` |
| `quote_created` / `quote_approved` | `quote_approved` at `app-boot.js:421`; `quote_created` **new** on quote save |
| `low_stock` | **new** — fire from the inventory decrement path when a spool crosses `reorderPoint` |
| `printer_alert` | `integrations.js:1079` |
| `intake_submitted` | **new** — server-side after `POST /api/intake` persists |

**Subscriptions.** Replace the single-URL-per-event map with a list of subscriptions: `{ id, url, events:[…], secret, enabled, createdAt }`. One event can fan out to many endpoints (Zapier + Slack + a Sheet). Migration: an existing `settings.webhooks.events{}` becomes one subscription per distinct URL, preserving `settings.webhooks.secret`.

**Delivery — signing, retry, log.** Each delivery: body `{ id, event, payload, timestamp, shopId? }`; headers `X-Khayt-Event`, `X-Khayt-Delivery` (uuid, idempotency key), `X-Khayt-Signature: sha256=<hmac>` over the **raw body** (matches the inbound Salla/Zid verify style in `lan-server.js`, and is consumer-verifiable).

**Signature V2 (replay-proof, both apps since 2026-10-02).** Every signed delivery also carries `X-Khayt-Timestamp` (Unix seconds at send) and `X-Khayt-Signature-V2`, the **bare hex** HMAC-SHA256 of `"<timestamp>.<raw body>"` with the same secret, the scheme Stripe and Slack use. `X-Khayt-Signature` is unchanged, so existing receivers keep working. As shipped it is bare hex on the per-event bus (`hub:fire-webhook`) and `sha256=<hex>` on the order event webhook (`hub:webhook-post`). A receiver that wants replay protection verifies V2 and refuses a timestamp more than a few minutes old. Delivery goes over https only, to the address Khayt checked (never a private, loopback or metadata address, and not re-resolved at connect time), and redirects are never followed. Implementation: `lib/webhook-send.js` (desktop) and the Mac's webhook sender (#1712), byte-identical. **Retry** with exponential backoff (e.g. 0s, 30s, 2m, 10m, 1h — max 5 attempts) on network error or non-2xx; a 410 disables the subscription. A bounded **delivery log** (last ~200 per subscription: event, status, attempts, last response code, ts) is persisted and shown in Settings, with a manual **Resend**. Firing stays in the main process (keeps the SSRF/redirect guards); the renderer just enqueues.

---

## 3. Automation connectors — Zapier / Make

Both are **thin wrappers over §1 + §2** — zero bespoke server code. Published as a Zapier integration and a Make app.

- **Triggers = webhooks.** Each catalog event (§2) is a trigger. The connector registers itself by creating a subscription (`POST /v1/webhooks`) pointing at the platform's catch hook, and removes it on unsubscribe (REST Hooks pattern). Payloads are the same signed bodies; the connector verifies `X-Khayt-Signature`.
- **Actions = API calls.** "Create order" → `POST /v1/orders`; "Update order status" → `PATCH /v1/orders/:id`; "Create/Update client" → `/v1/clients`; "Adjust inventory" → `PATCH /v1/inventory/:id`; "Add waiting-list entry" → intake.
- **Searches:** "Find order" → `GET /v1/orders?status=…`; "Find client" → `GET /v1/clients`.
- **Auth:** a **scoped API token** (§1) entered once in the connector's connection setup, sent as `Authorization: Bearer`. The connector setup tells the user which scopes to grant. **Base URL** is the cloud-relay host (§4) when cloud is on, or a user-supplied LAN/tunnel URL otherwise — the connector never needs to know which.

---

## 4. Cloud-relayed public API (opt-in, internet-reachable)

With Phase 1 connected, the same `/v1` surface becomes reachable over the internet **without** the user exposing their LAN — additive only; LAN keeps working with cloud off.

- The Phase 1 cloud terminates a public HTTPS endpoint `https://api.khaytapp.com/v1/...` scoped per shop, authenticates the **same scoped API tokens** (validated against the shop's token set), and **relays** the request to the desktop over the existing authenticated channel (Phase 1 device connection / tunnel) — the desktop remains the single writer and source of truth. No shop operational data is stored cloud-side beyond Phase 1's E2E ciphertext.
- Tenant isolation is absolute (`shopId` on every relayed call; security model §1.3). Cloud applies its own per-shop rate limits and a global DoS backstop in front of the desktop's local limits.
- Outbound webhooks can originate from the desktop directly (works offline) **or** be relayed via cloud when the desktop is asleep — owner-selectable per subscription. Replaces the manual `localtunnel` (`hub:start-tunnel`) as the recommended remote path; the weak-PIN/tunnel guards (`weakTunnelPinWarning`) remain for the legacy tunnel.

---

## 5. Versioning & docs

- **`/v1` is stable**; additive changes only within a version (new fields/endpoints never break clients). Breaking changes ⇒ `/v2` with an overlap window; `v0`/`/api/*` aliases preserved for iOS/PWA.
- Update **`docs/LAN_API.md`** in place (it is the source of truth) to cover `/v1`, scoped tokens, and the event catalog; publish an **OpenAPI 3 spec** (`docs/openapi.yaml`) that the connectors and external devs consume. A short tone-matched "Automate Khayt" guide per the [AI spec](./KHAYT-3.0-AI-SPEC.md) style (plain, owner-facing, no jargon).
- Webhook payload schemas versioned alongside (`X-Khayt-Event` + a `version` field in the body).

---

## 6. Integration points (exact files / functions)

- `lib/lan-server.js` — add `/v1` route prefix; add scoped-token auth branch beside the PIN check (`safeTokenEqual`, `failedAttempts`, `globalAuthThrottle`, `tunnelClientIp`); add `POST/PATCH /v1/clients` + `pickClientFields` (mirror `pickLanSpoolFields`); reuse `MAX_BODY`, `parseLanJsonBody`, `persistLanStoreUpdate`, `getMainWindow().webContents.send`. Hook server-side emits (`intake_submitted`, `order_created` via API) into the bus.
- `main.js` — `hub:fire-webhook` becomes `enqueueWebhook` + a delivery queue/retry worker writing the delivery log; keep `isBlockedHost`/`resolvesToBlockedHost`/redirect-manual/https-only/HMAC. New IPC: `hub:list-api-tokens`, `hub:create-api-token`, `hub:revoke-api-token`, `hub:webhook-subscriptions` (CRUD), `hub:webhook-deliveries`, `hub:webhook-resend`.
- `renderer/integrations.js` — `fireWebhook` fans out to all subscriptions matching the event; add settings UI for tokens, subscriptions, scopes, and the delivery log. `renderer/settings.js` test-ping reused per subscription.
- Emit sites already listed (§2) gain `order_shipped`, `low_stock`, `quote_created`.
- `preload.js` — expose the new `hub:*` IPC channels.
- Store: `settings.lanApi.apiTokens[]` (hashed), `settings.webhooks.subscriptions[]`, `settings.webhooks.deliveries[]` — all redacted from export (security model §1.6).
- Phase 1 cloud — relay handler validating scoped tokens per shop and forwarding to the device channel.

---

## 7. Edge cases

- **Token revocation:** revoke = delete the hashed entry; next request 401 immediately (no caching). Revoking a token a connector uses surfaces a clear 401 the connector reports; cloud relay honors revocation within one validation cycle.
- **Scope mismatch:** read-scoped token on a write → **403** (`{error:"insufficient_scope", required:"orders:write"}`), never silently dropped.
- **Rate limit:** per-token bucket exhausted → **429 + Retry-After**; auth brute force → existing 10/min lockout; tunnel/cloud add the global backstop.
- **Webhook retries/failures:** non-2xx/timeout → backoff retries (max 5); persistent failure marks the delivery `failed` in the log and (after N consecutive) auto-disables the subscription with an owner toast; 410 disables immediately. Outbound only fires when an event has ≥1 enabled subscription (no-op otherwise, as today).
- **Replay:** outbound carries `X-Khayt-Delivery` so consumers dedupe; inbound automation writes are **idempotent** via an optional `Idempotency-Key` header (cached result for the window) and the existing replay guard (`isReplayedWebhook`) protects signed inbound webhooks.
- **No PIN / no token configured:** writes return **403** (unchanged); `/v1` write automation simply requires a token to exist first.
- **Secret leakage:** tokens/secrets shown once, stored hashed/encrypted, never logged, never echoed in responses or export; webhook signatures sent in headers (never URL), matching the printer-token rule already in `lan-server.js`.
- **Cloud off:** every §1/§2 capability works LAN-only; §3 connectors point at the LAN/tunnel URL; §4 is simply unavailable, not an error.

---

## 8. Test plan & DoD

**Unit:** scoped-token verify (valid/expired/wrong-scope/revoked) via `safeTokenEqual`; `pickClientFields` sanitization/clamping; subscription fan-out (1 event → N urls); HMAC signing parity with the inbound Salla/Zid verifier; retry/backoff scheduler; delivery-log bounding; per-token rate bucket.
**Integration:** full `/v1` CRUD round-trip with a scoped token (read vs write 403s); body-cap (413) and lockout (429) preserved; webhook delivery to a local test sink incl. signature verification, retry on injected 500, auto-disable on repeated failure, manual resend; migration of legacy `webhooks.events{}` → subscriptions.
**Security (adversarial):** SSRF/private-host block still rejects on outbound; revoked token denied; cross-scope denied; secrets absent from logs/export (extend redaction tests); cloud relay enforces `shopId` isolation; replay/dedupe.
**Connector:** Zapier/Make sandbox — trigger fires on real event with verified signature; each action/search succeeds against `/v1`; subscribe/unsubscribe lifecycle creates/removes a subscription.

**Definition of Done:** `/v1` documented in `LAN_API.md` + `openapi.yaml`; scoped tokens mint/revoke/scope-enforce in Settings; webhook subscriptions with signing + retry + delivery log + resend shipped; all listed events fire (incl. new `order_shipped`/`low_stock`/`quote_created`); legacy webhook config auto-migrates; export redaction covers new secrets; LAN-only path verified with cloud off; cloud relay path gated behind Phase 1 connect; Zapier + Make apps pass sandbox review; security invariants (model §1) hold under adversarial tests.
