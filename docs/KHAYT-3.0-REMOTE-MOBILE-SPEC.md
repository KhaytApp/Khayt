# Khayt 3.0 — Remote Mobile (spec)

**Status:** phase started. Foundation (browser E2E decrypt) built + tested
(`lib/sync-crypto-web.js`, `test/sync-crypto-web.test.js`). Remaining phases below.

## Goal

Let a shop owner check their shop from a phone, anywhere, **without breaking
end-to-end encryption**. The existing iOS/LAN companion only works on the same
network; this works over the internet via Khayt Cloud.

## The constraint that shapes everything

Khayt Cloud is **E2E-encrypted** — the server only ever holds ciphertext and the
(also-encrypted) keyset. So the server **cannot** render the owner's data. The
only correct design is a **client that decrypts in the browser**:

1. **Log in** (`POST /v1/login`) → access token + the encrypted keyset.
2. **Unlock** — the user enters their **sync passphrase**; the browser derives the
   KEK (scrypt) and unwraps the DEK locally. The passphrase never leaves the device.
3. **Pull + decrypt** (`GET /v1/shops/{id}/store`) → decrypt the blob with the DEK
   → render read-only screens.

This mirrors the desktop exactly; `lib/sync-crypto-web.js` is the byte-compatible
decrypt path (WebCrypto AES-GCM + an injected scrypt).

## Delivery as a PWA, served by the cloud

A static **PWA** lives in the `khayt-cloud` repo and is served at
`cloud.khaytapp.com/m` (front-controller route → app shell). Installable,
offline-capable later. No new backend — it reuses the existing cloud API
(`/v1/login`, `/v1/shops/{id}/store`, `/v1/shops/{id}/keyset`).

## Crypto-compat plan (the crux — DONE for decrypt)

- **AES-256-GCM:** WebCrypto `crypto.subtle` (ct‖tag concatenation; base64
  envelope matches `lib/sync-crypto.js`). ✅ proven in tests.
- **scrypt KDF** (N=32768, r=8, p=1, keyLen=32): WebCrypto has no scrypt, so the
  PWA bundles a JS scrypt (e.g. `scrypt-js`) and injects it into
  `KhaytSyncWeb.unlockDek({ scrypt })`. Same params + salt ⇒ identical KEK. ✅
  validated against Node `scryptSync` in tests.
- Recovery-key unlock can be added the same way (base32 decode → same path).

## Phases

1. **Browser E2E decrypt foundation** — `lib/sync-crypto-web.js` + tests. ✅ done.
2. **PWA shell + auth** — `/m` app shell (HTML/CSS/JS) served by the cloud;
   login form → token + keyset; passphrase prompt → `unlockDek` → DEK held in
   memory only (never persisted). Bundle scrypt-js.
3. **Read-only screens** — pull + decrypt the store; render Dashboard (today's
   queue, counts, low stock), Orders list, Order detail. Reuse the desktop's
   pure compute helpers where portable.
4. **PWA polish** — manifest + service worker (offline shell), install prompt,
   RTL/i18n parity (en/ar), session lock on idle.
5. **Limited writes (later)** — e.g. advance an order's status from the phone:
   re-encrypt + push via the blob protocol with the optimistic-rev guard and the
   Phase-0 merge engine. Highest-risk; gated behind the read-only release.

## Security notes

- Passphrase + DEK live **in memory only** (optionally a short-lived in-memory
  cache); never `localStorage`. Re-prompt on reload.
- HTTPS only; the access token may sit in `sessionStorage` (cleared on tab close).
- Auto-lock after idle; explicit "lock" clears the DEK.
- Read-only first deliberately limits blast radius while the flow is proven.

## Open product decisions (for later)

- Which screens beyond Dashboard/Orders matter most on mobile?
- Do we want push notifications (quote approved, low stock) — needs a web-push
  channel and is a separate build.
