# Khayt LAN REST API

Reference for the embedded HTTP server in `lib/lan-server.js`. Used by the **LAN PWA**, **kiosk**, and **iOS Companion** — not a public cloud API.

**Source of truth:** `khayt-store.json` on the desktop (Mac/PC). All writes persist to disk and notify the Electron renderer via IPC.

## Enable on desktop

1. Khayt → **Settings** → **LAN API**
2. Enable **LAN REST API**
3. **Listen on all network interfaces** (required for phone/tablet on Wi‑Fi)
4. Set **Owner LAN PIN** (required for companion queue/inventory; max 256 chars)
5. Default port **3219** (configurable)

Base URL: `http://<desktop-lan-ip>:<port>`

## Versioned surface: `/v1`

Every data route below is also served under **`/v1`** — the documented, stable surface for
automation (`GET /v1/orders`, `PATCH /v1/orders/:id`, `GET /v1/inventory`, …). The original
`/api/*` paths remain a **permanent alias** for the iOS Companion, PWA and kiosk; nothing
about them changes. Within `/v1`, changes are additive only — new fields and endpoints never
break existing clients.

## Authentication

### Scoped API tokens (automation)

For scripts and automation platforms, mint a **scoped bearer token** in
**Settings → API Tokens**:

```
Authorization: Bearer khayt_<random>
```

* A token is shown **once** at creation — only a SHA-256 hash is stored, so it cannot be
  recovered later. Lost it? Revoke and mint a new one.
* A token carries an explicit **scope set** and gets nothing else:
  `orders:read`, `orders:write`, `clients:read`, `clients:write`,
  `inventory:read`, `inventory:write`, `machines:read`.
* Using a token outside its scopes returns **403** `{"error":"insufficient_scope","required":"orders:write"}` —
  never a silent no-op. A read token can never write.
* An unknown or revoked token returns **401** `{"error":"invalid_token"}`. Revocation takes
  effect immediately (the hash is deleted; nothing is cached).
* Repeated bad tokens hit the same per-IP lockout as bad PINs (10/min → **429**).
* Tokens are an **addition** to the owner PIN, not a replacement — `x-khayt-pin` keeps
  working exactly as before for humans and the iOS app.
* **Both apps** (Nov 2026). The native Mac mints and revokes them in **Settings → Online →
  API Tokens** (the owner only, under the staff lock), stores the same record
  (`settings.lanApi.apiTokens[]`: `id`, `label`, `scopes`, `createdAt`, `lastUsedAt`, and the
  SHA-256 `hash`), and its LAN server checks them with the same rules
  (`lib/api-tokens.js requiredScope`). A token minted on either computer verifies on the other.
* **Only the owner** creates or revokes a token on the desktop too (Nov 2026): rbac
  `security` `edit`, as on the Mac. Under the staff lock anyone else sees the list and no
  buttons; main refuses a mint (`not_allowed`) and puts back the token list of a save from
  any other role (`lib/api-tokens.js mayManageTokens`, `guardTokenSave`).
* `lastUsedAt` is stamped by the desktop's LAN server when a token is used, **at most once an
  hour** per token (`lib/api-tokens.js markUsed`), so a busy integration is not a store write
  per request. A save from the window keeps the later of its copy and the disk's.
* The hash never reaches a phone: `/api/store` masks `settings.lanApi.apiTokens[].hash`
  (`lib/store-secret-paths.js` PHONE_PRIVATE), and an export drops it.

| Mechanism | Details |
|-----------|---------|
| Header | `x-khayt-pin: <owner-pin>` (preferred for native clients) |
| Query | **Not accepted** on any API route, read or write, by either app (it put the PIN in every link's address, in clear over plain HTTP). The one exception is the queue page's old `/?pin=` bookmark, which is traded once for a `khayt_lan` session cookie and a redirect to a clean `/`; the page with no PIN shows a form that posts it to `/session` |

**Owner PIN** is `settings.lanApi.pin` in the store — same as kiosk / queue API.

### PIN rules

- If an owner PIN **is configured**, sensitive `GET` routes and all mutating routes require a matching PIN.
- If **no** owner PIN is configured, sensitive `GET` routes return **401** (queue/inventory/machines are unavailable until a PIN is set).
- **Writes** without a configured PIN return **403**.
- **Brute force:** 10 failed attempts per client IP → **429** for 1 minute (the native Mac app counts an IPv6 client from outside the shop's network per /64, and a link-local, unique-local or same-network IPv6 client by its own address).
- **Both apps:** an owner PIN shorter than 8 characters opens nothing — owner routes answer **401** with `{"reason":"pin-too-short", "error": …}` until the shop sets a new one (clients should key on `reason`, not the sentence). `/calendar.ics` takes the calendar token only, never the owner PIN.
- **Both apps:** a PIN-gated route asked under a `Host` that is not an IP address, `localhost` or a `.local` name answers **421** `{"error":"host-not-local"}` (DNS rebinding). The desktop also accepts its tunnel's own hostname while the tunnel runs.

### Public routes (no owner PIN)

- `GET /api/status`
- `GET /order/:id` (customer portal)
- Quote approval, intake (separate intake PIN/token), webhooks, static PWA assets
- **Mac only (Oct 2026):** `POST /api/intake/estimate` also accepts the
  **owner PIN** (`x-khayt-pin`), so the shop's own phone can price a file a
  customer sent it. Without a PIN it is decided exactly as before (intake
  session or intake token); a wrong PIN counts towards the owner-PIN lockout.
  `POST /api/intake` does NOT: a submission records the customer's own PDPL
  consent, which the shop cannot give for them. The Node server does neither.

Companion apps should call `GET /api/status` first (reachability), then `GET /api/queue` with PIN to confirm pairing.

## Companion v1 endpoints

### `GET /api/status`

Public aggregate counts for the active queue.

**For a paired phone (Mac only).** When the request carries a paired device's signature that verifies, the answer also has `"network": {"offline": true|false, "keep": ["updates", …]}`: the shop's "make no internet calls" switch and the purposes kept while it is on, as `lib/outbound.js` reads the book (`isOffline`, `keptOf`). The answer is signed with `x-khayt-reply-mac`, as `/api/devices/self` is. A phone in a floor role has no copy of the book and learns the switch here. An unsigned request, the PIN, or a signature that does not verify gets the public counts only, with no `network` and no reply MAC. **A phone that signed its request and gets an answer with no `network`, or one whose reply MAC does not verify, must read that as "unknown" and keep the last state it verified (failing closed), never as "online":** something on the network can strip the block, and a revoked device or a clock that is off gets the same plain answer. This Mac's own "Also on this Mac only" switch is not included.

**Response 200**

```json
{
  "queued": 12,
  "pending": 4,
  "printing": 3,
  "post": 2,
  "qc": 3,
  "completed_today": 7,
  "waiting": 2
}
```

`waiting` — active job intake / waiting-list entries (excludes declined).

### `GET /api/identity` and `GET /api/proof` — is this the paired computer?

Both apps (Mac #1942, desktop). A phone can check that whatever answers to the
shop's Bonjour name holds the key it paired with, **before** sending the PIN.

- `GET /api/identity` (owner PIN) → `{"alg":"ed25519","publicKey":"<base64 of the raw 32-byte key>"}`.
  The phone keeps it at pairing.
- `GET /api/proof?nonce=<32–128 hex>` (open) → `{"alg":"ed25519","sig":"<base64>"}`, an
  Ed25519 signature over the ASCII bytes `khayt-proof:` + the nonce in lower case.
  Any other nonce → **400** `{"error":"nonce"}`.

The key is made once per computer and kept out of the book (sealed by the
keychain), so a restored backup or a second computer does not claim to be this
one. Nothing on the open route depends on the PIN.

### `POST /api/devices` and signed requests — the PIN crosses the network once

The LAN is plain http, so a PIN sent on every request can be read by anything
on the same Wi-Fi. A phone that has paired with the PIN enrols once and then
**signs** each request with a key of its own instead. Nothing it sends after
that can be replayed or turned back into the PIN.

**Enrolment** — `POST /api/devices` (owner PIN, the last time it is sent):

```json
{ "publicKey": "<base64 of a fresh raw 32-byte X25519 public key>", "name": "Turki's iPhone" }
```

**200** → `{"deviceId":"dev_…","publicKey":"<base64 X25519, the computer's, fresh per enrolment>","sig":"<base64>"}`

- `deviceId`: made by the computer, `dev_` + 12–40 of `[A-Za-z0-9_-]`.
- `sig`: Ed25519, by the `/api/identity` key, over the ASCII bytes
  `khayt-enrol:` + deviceId + `:` + the computer's publicKey + `:` + the phone's
  publicKey (both base64 exactly as they appear in the JSON). The phone refuses
  an enrolment whose signature does not check against the key it pinned.
- Both sides then hold `key = HKDF-SHA256(ikm: X25519(shared), salt: "khayt-device-v1",
  info: deviceId, length: 32)`. The computer keeps `{deviceId, name, key,
  createdAt, lastSeenAt}` with its identity key — sealed, out of the book, so a
  backup or a synced second computer never carries it — and forgets its
  X25519 private key straight away.
- `name` is trimmed to 60 characters. At most 32 devices; a 33rd replaces the
  one seen longest ago.
- **Changing the PIN removes every device.** The phone also drops its enrolment
  when the PIN is edited on it, when it is unpaired, and when the identity key
  it pinned changes.
- **404/405** → a computer that predates this; the phone keeps sending the PIN and asks
  again a day later. **503** (no identity key) → the same.
- **Native Mac only: a pairing window.** The Mac takes an enrolment only while its
  owner has clicked **Pair a phone** (Settings ▸ Online): for 120 seconds on a
  monotonic clock (a date change cannot extend it), until one phone has enrolled,
  until the owner closes it, or until the LAN server stops. The button is off while
  the server listens on loopback only. Outside the window, **403**
  `{"reason":"pairing-closed","error":"On the Mac, click Pair a phone, then try again"}`
  comes back before the PIN is read, so it counts towards no lockout and says nothing
  about the PIN. While the window is open, a PIN sent without a device key (on any
  route) is judged by the window's own count instead of the per-address and
  whole-server lockouts, so guesses made before it cannot hold the new phone out.
  That count is per address (an IPv4 address, or an IPv6 /64): after 5 wrong PINs an
  address gets **429** `{"reason":"pairing-locked","error":"Too many wrong PINs from
  this device. It can't pair until you click Pair a phone again on the Mac"}` for the
  rest of the window, right PIN or not, while other addresses can still pair. The
  window closes for everyone at 50 wrong PINs in all.
- **What the 50 is, and is not.** It raises the bar from one device to ten
  addresses; it is not a barrier against someone deliberate. One machine on the LAN
  can take ten addresses (`ifconfig … alias`), and the 403 above tells a poller the
  moment a window opens, so a determined guesser gets about 50 tries per window the
  owner opens. Against an 8-digit PIN that is 50 in 10^8 (1 in 2 million) per window;
  what actually protects the shop is the PIN's length and how rarely the window is
  open. A guesser who closes the window early is seen: the Mac says so. The desktop
  (`lib/lan-server.js`) has no window yet.

**A signed request** carries, in place of `x-khayt-pin`:

| Header | Value |
|---|---|
| `x-khayt-device` | the `deviceId` |
| `x-khayt-time` | Unix seconds, an integer |
| `x-khayt-nonce` | 32 lower-case hex, fresh per request |
| `x-khayt-mac` | base64 HMAC-SHA256(key, canonical) |

```
canonical = "khayt-req-v1" \n METHOD \n request-target \n time \n nonce \n hex(SHA-256(body))
```

`METHOD` in upper case; `request-target` exactly as on the request line (path
plus `?query`, still percent-encoded); the hash of the body bytes as sent, the
hash of nothing for a request without one; lower-case hex; `\n` a single LF.

A valid signature is accepted **wherever the owner PIN is**, and only there. The
computer refuses, with **401**:

| Body | When | The phone |
|---|---|---|
| `{"reason":"device-unknown"}` | no such device, or removed | forgets it, retries once with the PIN, enrols again |
| `{"reason":"device-revoked"}` | the shop signed this phone out (Mac: Settings → Online → Paired phones; Windows and Linux: Settings → Online → LAN API → Paired phones) | **signed** (its `x-khayt-reply-mac` verifies over the nonce just sent; see "A signed `device-revoked`"): forgets its key, the PIN and its copy of the book, and asks the person to pair again. **Unsigned, or not verified**: wipes nothing; it keeps its key, its enrolment and the PIN, stops showing the book as live and asks the person to pair again. Never enrols by itself either way |
| `{"reason":"device-clock","now":<unix seconds>}` | `time` more than 120 s from the computer's clock | keeps the difference and retries once |
| `{"reason":"device-replay"}` | the nonce was seen for this device in the last 300 s | fails the request |
| `{"reason":"device-auth"}` | anything else: a bad MAC, missing or malformed headers | fails the request |

Compare the MAC in constant time. A request with both `x-khayt-pin` and the
device headers is judged by the device headers alone.

Shared test values for all three implementations are in
[`lan-device-keys.vectors.json`](lan-device-keys.vectors.json): fixed X25519
and Ed25519 keys, the derived key, an enrolment signature and two signed
requests. Each side's tests should reproduce every value in it.

### Signed answers a phone can trust (Windows and Linux, Nov 2026, draft; the Mac's are #2640 and #2643)

Two answers carry `x-khayt-reply-mac` = base64 `HMAC-SHA256(key, "khayt-reply-v1\n" + the request's x-khayt-nonce + "\n" + status + "\n" + hex(sha256(body)))`, the connector's reply MAC (vectors: [`connector-routes.vectors.json`](connector-routes.vectors.json) `reply`). `key` is the device's key. A phone acts on these answers only when the MAC verifies over the nonce it just sent.

- **`GET /api/status?format=json` from a paired phone** (GET only, and only once this computer has read the book: an unread book answers the plain counts, never a signed "online") also answers `"network": {"offline": true|false, "keep": [...]}`, the shop's "make no internet calls" switch as `lib/outbound.js` reads the book (`isOffline(settings, {})`, `keptOf`), with `Cache-Control: no-store`. This happens only when the request's device signature verifies, a LAN PIN of full length is set and the `Host` is local. Anyone else, an unsigned request, or a signature that does not verify gets the public counts only, with no `network` and no MAC.
- **`401 {"reason":"device-revoked"}` is signed** with the key the phone had, when the request's own signature verifies under that key inside the clock skew. A forged request naming the phone's id gets the same 401 unsigned. The old keys are kept for this only (they open nothing), for the 256 most recent sign-outs, with the ids. `device-unknown` (a PIN change, an id never seen) is never signed. A body over the size limit is refused before it is read (413 `too-large`), unsigned.
- **`GET /api/devices/self` and every `role-scope` 403 are signed** the same way (next section).

### A paired phone's role, and pairing a phone by code (both apps, Nov 2026, draft)

> **Served by both apps.** The native Mac (`LanServer.swift`) and `lib/lan-server.js` (Windows/Linux, not on screen yet: the desktop's screens wait for their Figma sign-off; main exposes the window over IPC). The rule is shared: [`lib/device-roles.js`](../lib/device-roles.js). The desktop's window and state machine are [`lib/main/phone-pairing.js`](../lib/main/phone-pairing.js).

A paired phone carries a **role**: owner, manager, operator or viewer. The role is a set of scopes, and the server checks it on **every request the phone signs**, before the route runs. The phone's screens follow its role as a convenience; the server's answer is the check.

- A request the role does not cover is answered **403** `{"reason":"role-scope","required":"<scope>"}`, the shape an API token gets for a scope it lacks. `required` is `owner` for a route the table does not name.
- The check uses the path the server routes on (on the desktop, the parsed URL path: `/v1` read as `/api`, a trailing slash dropped, dot segments already folded by the URL parser, so the rule is asked about the route that will run). A segment that decodes to a slash, a backslash, a dot segment or a control character is owner-only.
- A phone paired with the owner PIN has no role and is the **owner**, as it was. It holds the PIN, so it cannot be given a lesser role: remove it and pair it again by code.
- A phone paired by code whose stored role is missing or not one this build knows is read as a **viewer**, never the owner (`roleOf`).
- A role holds whether the staff lock is on or off. The owner PIN and API tokens are unchanged.
- **Pricing through a job update is `quote:write`.** A write to `/api/orders` or `/api/orders/<id>` that carries a `price`, creates a job as a quote, or sends a `status` for a job that is a quote now needs `quote:write`, whatever the route's own scope.
- **The role answers are signed back** (`x-khayt-reply-mac`, as above), and only when the request's own signature passed.

| Role | Scopes |
|---|---|
| viewer | `queue:read`, `machines:read`, `orders:read`, `inventory:read` |
| operator | viewer + `orders:write`, `inventory:write`, `waste:write`, `machines:control` |
| manager | operator + `clients:read`, `clients:write`, `expense:write`, `quote:write`, `book:read` |
| owner | everything, including `book:write` and every route not listed |

#### `GET /api/devices/self`

Signed by a paired device. Answers `{"deviceId":"dev_…","role":"operator","scopes":["queue:read", …]}`, signed. A request with the owner PIN and no device signature is 403 `{"reason":"device-auth"}`.

#### `POST /api/devices/pair` (pairing by code; **off** until the phone ships it)

The slicer plugin's commit-then-reveal flow (`POST /api/connectors/pair`, below) with the phone's own prefixes: `khayt-phone-commit-v1`, `khayt-enrol-phone-v1` and `khayt-phone-check-v1`. No PIN is sent. Shared vectors: [`phone-pair.vectors.json`](phone-pair.vectors.json).

- **404** `{"error":"not_found"}` while pairing by code is off. On the Mac it is the `phonePairingByCode` defaults switch; on Windows/Linux, main reads `KHAYT_PHONE_PAIRING_BY_CODE=1` from the environment at launch (nothing the window sends can switch it on).
- **421** `{"error":"host-not-local"}` for a `Host` that is not this computer. On the desktop a request through the tunnel is refused too.
- `POST /api/devices/pair` with `{v:2, commit, name, app, version}` → **200** `{pairId, pollSecret, deviceId, publicKey, sig, identity}`. Only while a person has opened the window (120 s on a monotonic clock, at most 3 offers): **403** `{"reason":"pairing-closed",…}` outside it, **409** `{"reason":"pairing-busy",…}` while another request waits, **400** `{"error":"commit"}` for a body without `"v":2` and a 32-byte `commit` (spends no offer).
- `POST /api/devices/pair/<pairId>/reveal` with `{publicKey, nonce}` and `x-khayt-poll` → **200** `{"state":"waiting"}`. A mismatch (constant time), a nonce under 16 bytes, an unusable or all-zero key, or a reveal later than 30 s → **403** `{"state":"expired","reason":"bad-reveal"}`; no number is ever worked out for it. A second reveal **409** `{"reason":"already-revealed"}`; the wrong secret **404** `{"state":"unknown"}` and spends nothing.
- `GET /api/devices/pair/<pairId>` with `x-khayt-poll` → **200** `{"state":"waiting"|"approved"|"denied"|"expired"}`, **404** `{"state":"unknown"}`.
- `DELETE /api/devices/pair/<pairId>` with `x-khayt-poll` → **200** `{"state":"cancelled"}` (a later GET answers `expired`), **409** `{"state":"approved"|"denied"|"expired"}` when already answered, **404** `{"state":"unknown"}`. The offer stays counted.
- A person compares the number, picks a role (Operator by default) and approves the request they were shown. **Who may:** the owner gives any role, a manager up to Manager, anyone else none and may not open the window (`grantable`). On the desktop, who is at the computer is main's own reading of the book (`lib/main/printer-permission.js activeRole`): the lock off, the owner; on, whoever is signed in; nobody, refused. The device is enrolled with that role and no PIN tag.

**Signing out.** A phone paired by code holds no tag of the PIN: a PIN change does not sign it out. The server still needs a LAN PIN of at least 8 characters to answer anyone: with the PIN cleared or too short, a phone paired by code is refused like everyone else until one is set. **Remove** does (`device-revoked`, signed). A phone paired with the owner PIN is still signed out by a PIN change.

### `POST /api/connectors/pair` — a slicer plugin pairs without the PIN (both apps)

> **Served by both apps.** The native Mac (`LanConnectorPairing`, `LanServer+Connector`)
> and `lib/lan-server.js` (Windows/Linux, not on screen yet: main exposes the window over
> IPC, `hub:connector-pair-*`). The desktop's window is the phone's state machine
> ([`lib/main/phone-pairing.js`](../lib/main/phone-pairing.js)) with the connector's
> prefixes ([`lib/main/connector-pairing.js`](../lib/main/connector-pairing.js)); its
> routes are [`lib/main/connector-routes.js`](../lib/main/connector-routes.js).
> **Off by default on both.** On the Mac, the `connectorPairing` defaults switch; on
> Windows/Linux, main reads `KHAYT_CONNECTOR_PAIRING=1` from the environment at launch
> (nothing the window sends can switch it on). While it is off the desktop answers
> every `/api/connectors/*` path, the pairing included, with the ordinary **404**; the
> Mac answers the pairing `403 pairing-closed` and the rest 404.

A **connector** (Khayt for OrcaSlicer) signs its requests exactly as a phone
does, but its key opens `/api/connectors/*` and nothing else: any other route
answers **403** `{"ok":false,"reason":"connector-scope"}` to a request whose
`x-khayt-device` names a connector, signed or not. It never sees the PIN.

**Commit, then reveal (v2).** The plugin commits to its key before it sees
anything of the Mac's, and the Mac draws a fresh key only after that, so a
device in the middle cannot grind its own keys until the two 6-digit numbers
match: one side's number is always a blind 1-in-10^6 guess for it, and a window
gives out at most 3 offers. (v1 sent the plugin's key in the clear and was
withdrawn before release: its number could be ground in about 10^6 tries.)

Every hash input below is the exact UTF-8 bytes of the strings as sent (keys
and the nonce base64, standard and padded, of the raw bytes), joined with
`\n` after a fixed prefix. Vectors: [`connector-pair.vectors.json`](connector-pair.vectors.json)
(commitment, the signed offer message with a signature, and the check, 8 cases).

1. The owner (or a manager) clicks **Pair a slicer** (Mac: Settings → Online →
   Connected apps). The window is open for 120 s and gives out at most **3
   offers**, whatever becomes of them (denied, abandoned, a bad or late
   reveal); after the third the window shuts and the owner must click again.
   Outside it the routes answer **403** `{"reason":"pairing-closed"}`.
2. The plugin draws a fresh X25519 key and a nonce of at least 16 random bytes,
   and sends `POST /api/connectors/pair`
   `{"v":2,"commit":"<base64 SHA-256>","name":"…","app":"OrcaSlicer","version":"2.5.1"}`
   with `commit = SHA-256("khayt-connector-commit-v2\n<plugin publicKey>\n<nonce>")`
   (no PIN, no signature; `Host` must be a local address, else **421**).
   A body without `"v":2` and a `commit` (a v1 plugin) gets **400**
   `{"reason":"pairing-upgrade"}`; a commit that is not 32 bytes is **400**.
   Neither draws a key or uses an offer.
   It gets **200** `{"pairId","pollSecret","deviceId","publicKey","sig","identity"}`:
   a fresh X25519 key drawn for this request, signed by the Mac's identity key over
   `khayt-enrol-commit-v2:<deviceId>:<Mac publicKey>:<commit>`, and that identity
   key (Ed25519, base64 raw), which the plugin pins: it cannot ask
   `/api/identity`, which takes the PIN. One request waits at a time; another
   gets **409** `{"reason":"pairing-busy"}`. No check number exists yet; the Mac
   shows no Approve.
3. The plugin verifies the signature against the identity it was sent and the
   commit it sent. It shows nothing if that fails. Then, within **30 s**, it sends
   `POST /api/connectors/pair/{pairId}/reveal` with `x-khayt-poll: <pollSecret>`
   and `{"publicKey":"<base64 raw X25519>","nonce":"<base64>"}`. The Mac checks the
   commitment in constant time: **200** `{"state":"waiting"}` on a match. A
   mismatch, a nonce under 16 bytes, a key that is not 32 bytes or gives the
   all-zero secret, a malformed body or a late reveal is **403**
   `{"state":"expired","reason":"bad-reveal"}`: the offer is spent and no check
   number is ever worked out for it. A second reveal is **409**; the wrong poll
   secret is **404** and spends nothing. An offer never revealed expires after
   30 s and frees the slot.
4. Only now do both sides show the 6-digit **check number**: SHA-256 of
   `khayt-connector-check-v2\n<deviceId>\n<identity>\n<Mac publicKey>\n<plugin publicKey>\n<nonce>`,
   the first 4 bytes big-endian, modulo 1,000,000, zero-padded. The Mac's
   button reads **Numbers match — approve**. The plugin polls
   `GET /api/connectors/pair/{pairId}` with `x-khayt-poll: <pollSecret>`:
   **200** `{"state":"waiting"|"approved"|"denied"|"expired"}`, or **404**
   `{"state":"unknown"}` for an id it was not given or the wrong secret.
   **Approve** enrols the device with kind `connector` and closes the window;
   **Deny** answers that request and keeps the window open.
5. From then on the plugin signs with the key both derived (HKDF as above,
   info = `deviceId`). **Remove** in Connected apps answers `device-revoked`;
   a change of the LAN PIN signs connectors out with the phones
   (`device-unknown`).

### The connector's own routes — a paired plugin sends its slices (both apps)

All dark (the ordinary 404) while "Pair a slicer" is off. Exact paths, a
connector's signed request only: unsigned is 401, a phone's key, the PIN or an
API token 403 `connector-only`. Every answer to a verified request carries
`x-khayt-reply-mac` = base64 `HMAC-SHA256(K, "khayt-reply-v1\n" + requestNonce +
"\n" + status + "\n" + hex(sha256(body)))`, and the plugin drops one that does not
verify. Per connector: 600 requests, 30 announces and 30 files an hour (429 with
`Retry-After`).

| Route | Body | Answer |
|---|---|---|
| `GET /api/connectors/self` | none | `{connectorId, name, shop:{name}, limits:{maxFileBytes, maxMetaBytes}, scopes}` |
| `DELETE /api/connectors/self` | none | `{ok:true}`; unpaired as Remove does |
| `POST /api/connectors/slices` | sealed capture, ≤ 64 KB | 201 `{sliceId, state:"awaiting-file", uploadBy, dropped, intentHonoured?}`; 200 `{…, duplicate:true}` when the same bytes are waiting; 422 with the shared rule's `reason`/`field`; 409 `inbox-full` |
| `PUT /api/connectors/slices/{sliceId}/file` | the raw file, exact `Content-Length`, `x-khayt-content-sha256` | 201 `{sliceId, state:"in-inbox"}`; 422 `hash-mismatch` (`retry` once) |
| `GET /api/connectors/slices/{sliceId}` | none | `{sliceId, state}`: `awaiting-file`, `in-inbox`, `left-inbox`, `expired` |
| `GET /api/connectors/queue` | none | 200 sealed `{v, at, shop:{name}, jobs:[{id, number, stage, machine, file}], machines:[{id, name, state}], inbox:{waiting}, more?}` with `ETag`; 304 on a matching `If-None-Match`; 1 per 10 s |
| `POST /api/connectors/price` | sealed slice facts, ≤ 8 KB opened: `{v, qty, timeSec, filaments:[{type, colour, grams}], printer:{preset}}` | 200 sealed `{prices:"off"}` when the shop's "Show prices in OrcaSlicer" is off or this device has no grant; `{prices:"on", currency, qty, unit, total, rounded, basis}` for the `price` grant, with `round:{step}` only when `rounded` is true; plus `cost:{unit, total}` and `margin:{pct, pctOnCost, amount}` for `cost` (`pctOnCost` is absent when the cost shows as 0.00; `amount` is `total − cost.total` to the cent); `{prices:"on", unpriced:"no-material"\|"no-currency"\|"bad-facts"}`; 120 an hour |

**Sealed capture.** `{"v":1,"alg":"A256GCM","nonce":b64(12 bytes),"ct":b64(ciphertext ‖ 16-byte tag)}`
under `HKDF-SHA256(K, salt "khayt-connector-seal-v1", info connectorId)`, AAD
`"POST /api/connectors/slices"` (method, one space, path). The capture inside is
checked field by field by `lib/connector-slice.js`.

**The file, judged from its head.** The signature is checked whole before any
body is read: the canonical request's body hash is the `x-khayt-content-sha256`
the head names, which must be the hash the capture declared. Then the slice
(404 unknown or another connector's, 409 `not-awaiting-file`), the length (400
`length-mismatch`, 413 `too-large`), the two upload slots shared with the
OctoPrint path (503), the disk (507); only then `100 Continue`. The bytes are
hashed as they land. **On the LAN the G-code goes in clear**, bound by that
signed hash; a Cloud relay must seal it end to end instead.

**Inbox-first.** The file lands in the "From slicer" inbox with `source:
"connector"`, `connectorId`, `connectorName`, `sha256`, `suggested` (what the
plugin asked: never acted on) and `slots`; the Mac reads the file's own figures.
Nothing in the book is written. One SHA-256 dedupe for both ways in: the same
bytes from the OctoPrint path or a plugin are one item. Every other
`/api/connectors/*` path is 404 for every verb: no pause, resume or stop.
Slice records (id, connector, state, hash, size, times; never a file name)
are kept beside the inbox in `From slicer/.slices/`, swept at launch: a slice
still waiting for its file when the app stopped is `expired`, and the plugin
announces again.
**The queue** is `lib/connector-queue.js`: open jobs from `printLog`, each with
its number, stage, machine name and `file` (only the name of a file THIS
connector sent for that job; null otherwise). Never a title (a title can hold a
client's name), a client, a price or a note. Sealed as the capture is, with AAD
`"GET /api/connectors/queue"`; the ETag covers everything but `at`. It is keyed, because it travels in the clear while the queue is sealed: `HMAC-SHA256(HKDF-SHA256(K, salt "khayt-connector-etag-v1", info connectorId), content)`, first 32 hex digits, quoted. A plugin only echoes it in `If-None-Match`.
**The price** is `lib/connector-price.js priceSlice`: the facts as one new hand
part, priced by the calculator's own code (shop spool by type and colour, the
preset named like the slicer's printer preset, the default margin, overhead by
the print hour). Sealed with AAD `"POST /api/connectors/price"` both ways.
Nothing is stored or logged. The shop's switch is this Mac's own (default off);
the grant is per device (none, `price`, `cost`), and the route passes only an
allow-list of keys for it: the rule always works out the cost and margin, and a
`price` device never sees them. `GET /api/connectors/self` lists `price:read`
(and `cost:read`) only while both hold.
Vectors: `docs/connector-routes.vectors.json`. The desktop (`lib/lan-server.js`,
`lib/main/connector-routes.js`) answers the same routes with the same statuses; its
inbox is `<userData>/From slicer/` ([`lib/main/slicer-inbox.js`](../lib/main/slicer-inbox.js)),
its slice records `From slicer/.slices/` ([`lib/main/connector-slices.js`](../lib/main/connector-slices.js)),
and "Show prices in OrcaSlicer" is this computer's own file in userData, default off
([`lib/main/connector-local.js`](../lib/main/connector-local.js)); a grant is set over
IPC (`hub:connector-grant-set`) by whoever may edit security, `cost` only with
reports. The desktop reads a plain G-code's own figures into the item; a
`.gcode.3mf` or `.bgcode` is filed without them, and no activity row is written.

### `GET /api/library`, its thumbnails, and `POST /api/library/{id}/estimate` — pricing a model from the phone

The shop's library (`printFiles`) stays on the computer: it is a quarter of a
real book and is left out of the phone's working set. These routes let the
phone search it and have a model priced the way the intake form prices a
customer's file, without moving the file. All three need the owner (the PIN
or a signed request).

A model archived on the Mac (`archivedAt` is a non-empty string — by the shop,
or because its Khayt Vault file was trashed) is not in this library: it is left
out of the items, the folder counts and the paging, and its thumbnail and
estimate answer 404 `not-found`. The Mac's own LAN server does the same.

**`GET /api/library?q=&folder=&offset=0&limit=50&colour=&type=`**

- `q` — words matched against `name`, `originalName`, `folder`, `tags` and
  `category`, ignoring case and diacritics; every word must match. With a `q`
  the whole library is searched and `folders` is empty.
- `folder` — without `q`: the models filed directly in that folder path (`""`
  is the top), and in `folders` its immediate sub-folders.
- `limit` 1–200 (default 50). Favourites first, then by `name`.
- `colour`, `type` — the two filter menus, each a comma-separated list of keys
  (since Nov 2026; `lib/lan-library.js narrow`, and natively
  `Shop.libraryNarrow`). Several keys in one list are OR; the two lists narrow
  together and with `q` or `folder`. An unknown key is ignored.
  - colour keys: `red` `orange` `yellow` `green` `blue` `purple` `pink` `brown`
    `black` `grey` `white`, then `multi` (two or more colour families) and
    `none` (no colour stored on the model, which is most of a real library).
    A multicolour model is under each of its families and under `multi`.
  - type keys: `3mf` `stl` `step` `obj` `gcode` `other` `nofile`.

```json
{
  "total": 7, "offset": 0, "matchedTotal": 31, "unfilteredTotal": 31,
  "folders": [ { "path": "Saudi Kings/Large", "name": "Large", "count": 12 } ],
  "facets": { "colour": { "red": 3, "orange": 0, "…": 0, "multi": 2, "none": 41 },
              "type": { "3mf": 30, "stl": 14, "step": 0, "obj": 0, "gcode": 2, "other": 0, "nofile": 3 } },
  "items": [ {
    "id": "PF-sample-lantern", "name": "Lantern", "folder": "Home", "category": "Decor",
    "tags": ["gift"], "material": "PLA Silk", "ext": "3mf", "size": 2400000,
    "favorite": false, "timesPrinted": 6, "lastPrinted": "2026-08-12",
    "thumb": true, "estimable": true,
    "printTimeMins": 318, "grams": 154,
    "plates": [ { "index": 1, "name": "Body", "printTimeMins": 205, "grams": 112 } ],
    "colors": [ { "hex": "#0F5257", "grams": 88 } ],
    "swapCount": 0, "swapsKnown": true,
    "testedNotes": "…"
  } ]
}
```

`facets` counts each menu's rows over everything EXCEPT that menu's own choice
(and with the other menu applied), so choosing Blue does not zero the other
colours. Every key is always present, zeros included; take the menu's order
from the key lists above, not from the object.

**What is counted.** With `q`, the search's results. Without it, the folder
AND everything under it, the same reach as a sub-folder's `count`: at the top
of a library whose red models are all in folders, Red reads their number, not
0. `matchedTotal` and `unfilteredTotal` are counted the same way: the models in
that reach that pass both menus, and all of them (for "26 of 312").

`total` and `items` are the models LISTED here, fully narrowed: in a folder
that is only the ones filed directly in it, so `total` can be 0 while
`matchedTotal` is not (the matches are in sub-folders). `folders` follows the
menus too: a sub-folder is listed for the models under it that pass, at that
count, so a tap never opens a folder the filter has emptied. **A computer from before
this sends no `facets` and ignores the two parameters: a phone hides both
menus when `facets` is absent.**

`swapCount` is how many times the printer changes filament during the print, and
`swapsKnown` whether a slicer counted it (`true` only for a sliced file; `false`
means the colours are known but the swaps are not until the file is sliced).
Both are sent as the record holds them and left out when it holds none. A
computer from before them sends neither, and neither does a record written
before `swapsKnown`: a phone then counts the swaps as known when
`printTimeMins` is set, the rule the desktop and Mac cards use, and shows no
swap number it was not given.

`count` is every model at or under that folder. `printTimeMins`/`grams` are
what a slicer recorded, or null. `estimable` means the computer has the file and
can measure it (`stl`, `obj`, `3mf`, `gcode`). Leave out anything the book does
not have; send null rather than a made-up 0. `timesPrinted`/`lastPrinted` count
the finished jobs made from the model as well as the record's own counter — the
larger of the two, and the later date (`lib/print-history.js`; one job is one
print, whatever its quantity). Both servers answer the same.

**`GET /api/library/{id}/thumb`** → the thumbnail (`image/jpeg`, `image/png` or
`image/webp`) with `Cache-Control: private, max-age=86400`; **404** when there is none.

**`POST /api/library/{id}/estimate?qty=1&plate=`** (no body) → the same answer
as `POST /api/intake/estimate`: `{ok, reason, price, currency, qty, grams,
hours, exact}`, plus optional `reliable` (false when a geometry estimate is
outside the range it is good for — the phone shows a warning) and `missing`.
`price` is for the whole `qty`; `grams` and `hours` are for one piece.

- **The price is the owner's**, not the public intake figure: what the
  computer's own "quote this model" calculator gives — the shop's spools,
  rates, default margin, rounding and overhead. A shop that never set up
  customer quoting still gets one. Where a computer cannot price that way it
  answers 200 `{"ok":false,"reason":"not-configured","missing":"printer"|"material"}`
  rather than a 0.
- Slicer numbers recorded on the model are used as they are, with `exact:
  true`; otherwise the file in the vault is measured.
- `plate=N` prices that plate's recorded figures (`parsed.plates[index == N]`);
  a plate with none is 200 `no-numbers` — the whole file is not measured for one plate.
- On every refusal `price`, `grams` and `hours` are null and `exact` is false.

Refusals: **404** `{"ok":false,"reason":"not-found"}` (no such model or plate),
**409** `"no-file"` (nothing in the vault), **415** `"unsupported"`, **413**
`"too-large"`, **503** `"busy"` with `Retry-After` (estimates share the intake
limit). `{id}` is percent-encoded.

### `GET /api/queue`

Active kanban orders (`pending`, `printing`, `post`, `qc`). **Requires owner PIN** when configured.

**Response 200** — array:

```json
[
  {
    "id": "ord-123",
    "project": "Bracket v2",
    "client": "Acme Co",
    "status": "printing",
    "machine": "P1S-01",
    "dueDate": "2026-06-05",
    "priority": "normal"
  }
]
```

### Discovery — `_khayt._tcp`

Both apps advertise themselves whenever the LAN API is bound to the network, so a
client does not have to be told an address: the native Mac over Bonjour, Windows/Linux
over multicast DNS ([`lib/main/lan-advertise.js`](../lib/main/lan-advertise.js), the
packet [`lib/mdns.js`](../lib/mdns.js) `encodeAdvertisement`), announced at start and
withdrawn with a goodbye (TTL 0) when the server stops.

| | |
|---|---|
| Service type | `_khayt._tcp` |
| Service name | the shop's own name (`settings.shopName`), truncated to 63 **bytes** |
| `TXT v` | the LAN API version — `1` |
| `TXT store` | `1` when this server implements `GET /api/store`; absent means no (the desktop sends none) |

**Only when bound to the LAN.** A loopback-only server is not advertised, because
a client that found it could never connect to it.

`TXT store` is the one thing worth knowing before pairing: it separates a Mac that
can hand over the book — so the client keeps working away from the desk — from one
that cannot. The Electron desktop advertises without it, because it serves no `/api/store`.
Its host record is a name of its own (`<hostname>-khayt.local`), so it never claims the
system's own name, and it does not probe for a clash of instance names as Bonjour does.

**The PIN is deliberately not advertised.** It can change while the server is up,
and a stale "no PIN needed" is a client confidently telling a shop something
untrue. A `401` answers it accurately for the cost of one request.

Bonjour names and TXT records are broadcast in the clear to everything on the
network. Nothing here is private: `/intake` already serves the shop's name to
anyone on the LAN with no PIN, because it is the page customers are meant to open.

On iOS, browsing requires `NSBonjourServices` in `Info.plist` alongside
`NSLocalNetworkUsageDescription` — without it the system returns an empty result
set rather than an error, which reads as "the Mac is not running".

### `GET /api/store`

The working set of the shop's book, for a client that keeps its own copy.
**Requires owner PIN.**

> **Served by the native Mac app only.** `lib/lan-server.js` does not implement
> this route. Every other endpoint on this page answers a *question* — what is in
> the queue, what is on the machines — which assumes the asker is a screen with a
> live connection. This one hands over enough of the book that the asker can stop
> asking, and it exists for the iOS companion's local store.

**It is not the whole book.** `printLog` is about half of a real shop's store and
`printFiles` another quarter — history no companion screen has ever shown. What
travels is `BookScope.workingSet` (declared in `mac/KhaytCore/Sources/KhaytCore/BookScope.swift`,
so the Mac and the phone cannot disagree about it):

| Collection | What travels |
|---|---|
| `settings` | always, in full — nothing can be priced without it |
| `printLog` | every **unfinished** order whatever its age, plus the newest 200 finished |
| `clients`, `inventory`, `machines`, `waitingList`, `waTemplates` | in full, up to a ceiling |
| `printers` (calculator presets), `consumables`, `suppliers` | in full, up to a ceiling — the phone's calculator and receipt scanner |
| `expenses` | the newest 1,000 **by day** (not list position) — the receipt scanner's duplicate check |
| everything else | stays on the Mac |

An order is finished at `completed`, `shipped`, `delivered` or `cancelled`.
Anything else travels however old it is — a job stuck in QC for two months is
still in the shop.

`?scope=whole` returns the entire store instead, for a restore or a person with
`curl`. The companion never asks for it.

**Secrets are masked** either way. The store passes through
`KhaytCloudOutbox.forPhone(store)` — the cloud push's `forCloud`, plus one list
more — so every path named in `lib/store-secret-paths.js` (printer access codes,
API keys, bot tokens, refresh tokens) arrives as `"__KHAYT_MASKED__"`. The list
more is PHONE_PRIVATE: an operator's `pinHash` and `settings.recoveryCodeHash`,
which the shop's other computers need through the cloud and a phone never does.
A device on the LAN is trusted with less than the cloud, never more.

**Customer data is NOT masked**, because it is not a secret — it is the book. The
response carries the shop's clients, orders and prices, which is why the owner PIN
gates it and why the PIN lockout applies.

**Response 200** — an envelope, not a bare store. The records alone cannot say what
was left out, and a partial book that cannot say it is partial is worse than none:
a client would count 200 orders and report a three-year-old shop as having done 200.

```json
{
  "whole": false,
  "scope": {
    "collections": {
      "printLog":  { "whole": false, "sent": 200, "available": 3140 },
      "clients":   { "whole": true,  "sent": 31 },
      "inventory": { "whole": true,  "sent": 13 }
    },
    "omitted": ["auditLog", "printFiles"],
    "takenAt": "2026-09-18T09:00:00.000Z"
  },
  "store": {
    "settings": { "shopName": "Ward", "telegram": { "botToken": "__KHAYT_MASKED__" } },
    "printLog": [ { "id": "ord-123", "client": "Acme Co", "status": "printing" } ],
    "clients":  [ { "id": "c-1", "name": "Sara" } ]
  }
}
```

`omitted` names what was withheld rather than leaving it to be inferred from
absence: a client asking "do I have expenses?" must be told "they were not sent",
never "there are none". A collection the shop simply does not have comes back as
`{"whole": true, "sent": 0}` — the client has everything there is.

**Response 500** — `{"error":"The book could not be prepared to send"}`. Deliberately
not an empty book: a client that accepted `{}` would replace a shop it already had
with nothing.

### `GET /api/store/settings`

The shop's settings on their own, for a client that refreshes its records
elsewhere. **Requires owner PIN.** Also served as `/v1/store/settings`.

> **Served by the native Mac app only.** Cloud deltas never carry `settings`, so
> a phone that refreshes from Khayt Cloud learns of a connector installed on the
> Mac (`settings.plugins`), or a currency or tax mode changed there, only from
> this route. The phone reads it after a refresh round whenever the Mac answers.

**Response 200**

```json
{ "settings": { "shopName": "…", "plugins": [ … ] }, "servedAt": "2026-11-09T14:00:00.000Z" }
```

`settings` is exactly what `GET /api/store` sends as `store.settings`: the same
mask, so every path in `lib/store-secret-paths.js` (connector secrets, PIN hashes,
sealed tokens) is masked or withheld here too.

**Response 401 / 429** — as `GET /api/store`.

**Response 500** — `{"error":"The settings could not be prepared to send"}`, also
when the book has no settings. Never `{}`: the phone replaces its settings with
what this returns.

### `POST /api/store/deltas`

A paired client's changes, folded into the shop's book. **Requires owner PIN.**

A delta may carry **`baseRev`**: the `rev` of the copy the client held before its first
unsent edit to that record (`{"collection":"printLog","record":{…,"rev":9},"baseRev":7}`).
It is read off the delta and never written to the book. The fold itself is unchanged
(`KhaytSync.applyDeltas`: higher `rev` wins, a tie goes to the later `updatedAt`). When the
client's copy replaces one the Mac held at a higher `rev` than `baseRev`, or wins a tie,
the Mac keeps its own copy beside the book and shows the shop a "changed on another
device" notice with **Put back**. A delta without `baseRev` is folded as before.

> **Served by the native Mac app only.** `LanServer.Host.fold` is `nil` by
> default — a build that has not wired it answers `405` and says so, rather than
> failing as though something broke. The shipping Mac app wires it, so the
> companion's offline edits land; `lib/lan-server.js` does not implement this
> route at all.

**Request** — an outbox, the shape `KhaytCloudOutbox.changesToSend` produces and
`KhaytSync.applyDeltas` consumes:

```json
{
  "deltas": [
    { "collection": "clients", "record": { "id": "c-1", "name": "Sara", "rev": 2 } }
  ],
  "tombstones": [],
  "cursor": null
}
```

**Headers** — `x-khayt-pin` (a `?pin=` in the address is ignored on this route) and
`Content-Type: application/json` (anything else is **415**, so a cross-origin page
cannot reach this route with a preflight-free form or `text/plain` POST).

Neither end invents a rule here. The client computes the payload with the same
function the desktop pushes with, and the Mac folds it with the same function
every device pulls with.

**The book is protected by the fold, not by this route.** `applyDeltas` keeps the
higher revision, so a client carrying a stale copy cannot undo work done at the
desk — its record is counted in `skipped` and discarded. The host's writer does
the rest: it reads inside the write and swaps atomically.

**A partial client cannot delete history.** `changesToSend` emits a delta only for
a record it *holds* at a higher rev, and takes tombstones only from the store's
own `tombstones` collection. A phone carrying 200 of 3,140 orders says nothing at
all about the 2,940 it was never given.

**Response 200** — what the fold did:

```json
{ "applied": 1, "skipped": 1, "removed": 0 }
```

`skipped` is normal and not a fault: it counts records the book already held at an
equal or higher revision. An empty outbox answers `200` with all zeros without
writing — a write with no change still rewrites the file and still rolls `.prev`.

**Response 400** — the payload is not `{deltas, tombstones, cursor}` with both
arrays present. Checked before the engine sees it.

**Response 405** — this Mac does not take changes from a client.

**Response 500** — the book could not be written. Nothing was changed, and a
client must not treat this as delivered.

### The REST routes — served by both apps (Nov 2026)

`/api/orders` (GET, POST), `/api/orders/:id` (PATCH), `/api/orders/:id/quote-url` (GET),
`/api/orders/:id/approve` (POST), `/api/machines` (GET), `/api/inventory` (GET, POST),
`/api/inventory/:id` (PATCH, DELETE), `/api/waiting-list` (GET), `/api/waiting-list/:id`
(PATCH), `/api/clients` (GET), `/api/waste` (POST) and `/api/webhook/printer/:id` (POST)
are answered by **both** `lib/lan-server.js` and the native Mac's `LanServer.swift`
(`LanServer+Rest.swift`). What each one reads and writes is one module,
`lib/lan-rest.js`, which both servers run — the Mac in JavaScriptCore — so the bodies
and the records written are the same. Each server decides a write on the book it holds
(a refusal costs no write) and again inside its write chain, and answers from the
second. The same gate on both: the owner PIN (header), or a scoped API token where the
route is in the scope model; `/api/waste` is in no scope and takes the PIN only.

Where the two differ: a write the Mac cannot put on disk is **500** (the desktop says
400), and a body that is not JSON is **400** `{"error":"Invalid JSON"}`. `/api/machines`
answers GET only on the Mac. `POST /api/quote` is served by both, by one rule
(`lib/lan-rest.js quotePart`). `POST /api/expense` is served by both too; on the Mac it
takes a **signed, enrolled phone only** (as a job photo does), files the receipt in
`receipts/` beside the book and stores that relative path, and answers
`{"ok":true,"entry":{…}}` or `{"ok":false,"error":"…"}`.

### `GET /api/orders`

Order log slice. **Requires owner PIN.**

| Query | Description |
|-------|-------------|
| `limit` | Max rows (default 50, cap 200) |
| `status` | Filter by status |

**Response 200** — array with `id`, `project`, `client`, `status`, `material`, `price`, `dueDate`, `date`, `paymentStatus`.

### `PATCH /api/orders/:id`

Update order status. **Requires owner PIN.**

**Body** (at least one field required)

```json
{ "status": "printing" }
```

```json
{ "machineId": "m1" }
```

```json
{ "status": "printing", "machineId": "m1" }
```

Pass `"machineId": null` to unassign a printer.

**Valid status values:** `pending`, `printing`, `post`, `qc`, `completed`, `on_hold`

A status change runs the shared status rule (`lib/order-status.js`), exactly as a move on
the board does, in **both apps** (Nov 2026): `statusHistory` gains one entry, a completion
stamps `completedAt`, a hold remembers when, a quote leaving the quote column is accepted,
and moving back out of completed clears `completedAt`. A quote moved to any other status gets its invoice number inside the same write (the
board's rule; a number it already has is kept), and the advanced counter is in `settingsChanged`. A move to the status the job already
has changes nothing.

**Response 200:** `{ "ok": true, "order": { "id", "status", "machineId", "machine" } }`  
**Response 404:** order not found  
**Response 400:** invalid status  
**Response 409:** the rule refused the move — `{ "error": "Move refused", "code", "params" }`,
with `code` one of `production_paused`, `wip_blocked`, `assembly_not_assembled`,
`assembly_parts`. Nothing is written.

**Desktop side effect:** `lan-order-updated` IPC with `changed` (the fields the move changed),
`removed` and `effects` (the rule's effects, less the toasts and the save) — the window takes
those fields and runs the effects: the filament and packaging deduction, the status webhooks,
the customer's message, the portal. A completion over the LAN is not asked for actual time
and grams; the estimate is booked, as on the phone.

### `GET /api/inventory`

Inventory as spool objects. **Requires owner PIN** (or an `inventory:read` token).

**Response 200:** JSON array of spool objects, **projected** — not the raw store
record. A spool comes back with the fields `POST` accepts (see below) plus `id`,
`remaining`, `addedAt`, `sku`, `printTemp` and `bedTemp`, which the iOS companion
reads.

The rule is symmetry: **the API returns what the API accepts.** Reads used to
return `store.inventory[]` verbatim, which meant any field the desktop added to a
spool was published the moment it existed, without anyone deciding to. Over the
tunnel this endpoint is internet-reachable behind one PIN, so that was the wrong
default even though the caller is the owner.

Fields on the store record but **not** returned: `supplier`, `invoice`,
`costPerGram` — and anything added in future, until it is added to the allowlist
on purpose (`LAN_SPOOL_READ_FIELDS` in `lib/lan-server.js`).

### `POST /api/expense`

Record an expense, with an optional photographed receipt. **Requires owner PIN.**

> **Served by both apps** (the native Mac since Nov 2026). On the Mac the owner PIN
> alone is not enough: it takes a **signed, enrolled phone** (the `x-khayt-device`
> headers, as a job photo does) and answers **403** `{"ok":false,"reason":"device-key-required"}`
> to anything else. An API token never opens it there (the route is in no token scope).

The only endpoint that accepts binary, so most of its behaviour is what it
refuses.

**Body:** `amount` (**required**, > 0), plus optional `category`, `note`,
`orderId`, `locationId`, and `receiptBase64` — a base64 JPEG, PNG or PDF.

**The image is identified by its own first bytes**, never by a declared type or
filename. A caller can claim anything; a file header is harder to fake, and this
writes into a directory the desktop later hands to `shell.openPath`. A non-image
is rejected with **415** even if it arrives named `receipt.jpg`.

**The filename is generated by the desktop** (`receipt-<time>-<random>.<ext>`),
so nothing caller-supplied can traverse out of the directory or overwrite another
receipt. Files live in `userData/receipts/`, alongside the other attachment
directories and inside the allow-list `hub:open-path` will open.

**Limits:** 6 MB decoded, with the transport cap raised for this route alone —
a phone photo does not fit the 1 MB that suits a JSON payload. Oversized bodies
get **413**.

**The receipt is written before the expense record**, so a failed write leaves no
row pointing at a file that does not exist.

**The `date` is set by the desktop** using the shop's calendar day, as everywhere
else.

**Response 201:** `{ "ok": true, "entry": { ... } }`
**Response 400/413/415:** no amount / too large / not an accepted file type.

An open desktop is notified over `lan-expense-added`.

### `POST /api/waste`

Log a failed print. **Requires owner PIN.**

For recording waste at the machine rather than walking back to the desk. Writes
the same record shape the desktop's waste form produces, so both feed one report.

**Body:** `material` (**required** — an entry with no material cannot be costed
or reconciled against a spool, so the desktop refuses it too), plus optional
`failureType`, `weight` (grams), `cost`, `reason`, `notes`, `orderId`,
`machineId`, and `deduct`.

**`deduct: true`** subtracts `weight` from the first spool of that material,
clamped at zero. Opt-in, because the shop may have adjusted stock already. If no
spool matches, the waste is still logged and `deducted` comes back `null` —
losing the record because the spool is gone would be the wrong trade.

**The `date` is set by the desktop**, using the shop's calendar day. Callers do
not send one: a phone in another timezone would otherwise file a failure under
the wrong day, and waste-by-day is the report this record exists to feed.

**Response 201:** `{ "ok": true, "entry": { ... }, "deducted": { "id", "weight" } | null }`
**Response 400:** missing material, or a non-object body.

An open desktop is notified over `lan-waste-logged` and patches its own state, so
the two do not diverge until a reload.

### `POST /api/quote`

Cost a part using the desktop's own maths. **Requires owner PIN.**

> **Served by both apps** (the native Mac since Nov 2026), by one rule:
> `lib/lan-rest.js quotePart`. The public tunnel is the desktop's alone; the Mac
> answers this on the shop's network only.

For quoting a walk-in customer without going back to the desk. The endpoint runs
`lib/calculator-cost.js` against the live store, so a phone can never
produce a different number from the desktop it is paired to — reimplementing the
costing anywhere else would mean two costs for one part, and the wrong one would
be whichever the shop happened to be looking at.

**Body:** a part object, in the same shape the calculator tab builds —
`spoolCost`, `spoolWeight`, `printWeight`, `supportWeight`, `printTime`,
`wearRate`, `powerDraw`, `elecRate`, `prepTime`, `postTime`, `laborRate`,
`failureRate`, `qty`, optional `filamentId`, `extraMaterials`, `priceTiers`.
Missing fields are treated as zero. `qty` is clamped to 1…100000.

**Response 200:**

```json
{
  "ok": true,
  "qty": 2,
  "unitCost": 24.36,
  "totalCost": 48.72,
  "breakdown": { "material": 6, "machine": 2.2, "labor": 15, "buffer": 1.16 },
  "priceTier": { "minQty": 10, "pricePerUnit": 25 },
  "currency": "SAR"
}
```

`breakdown` sums to `unitCost`. `priceTier` is `null` when the part carries no
tiers or `qty` has not reached the lowest one.

**Pricing.** Supply any of `margin` (percent), `discountPct`, `rush` (boolean),
`shippingCost` or `extraLines` and the response gains a `price` block computed by
`lib/pricing.js` — the same function the calculator screen runs, so a quote given
standing next to a customer matches the one on the desk. Rush uses the shop's
configured `rushFeePct`. With no `margin` supplied the price equals the cost,
which is honest rather than a guess at what this shop charges.

```json
"price": { "beforeDiscount": 73.08, "discount": 7.31, "subtotal": 65.77,
           "rushFee": 16.44, "shipping": 25, "extras": 12.5, "overhead": 0, "total": 119.71 }
```

`overhead` is the shop's fixed costs per print hour × the part's print hours ×
`qty`, a cost under the margin like the calculator screen's Overhead line
(`lib/overhead-rate.js`). It is 0 unless the shop turned that on in Settings, and
0 when a price tier applies, because a tier replaces cost-plus-margin.

**VAT is not included** — it is applied at invoicing, not in the calculator, so a
quote total is pre-VAT exactly as the desktop's is.

**Response 400:** empty, non-JSON, or non-object body.
**Response 401:** no owner PIN — what a job costs the shop is not customer-facing.

### `POST /api/inventory`

Append a spool. **Requires owner PIN.**

**Body:** spool object (partial OK). Server sets:

- `id` — `spool-<timestamp>` if omitted
- `addedAt` — ISO timestamp
- `remaining` — from `weightRemaining` or `weightTotal` or `1000`

`barcode` is the product's UPC/EAN, 8–14 digits; anything else is dropped. The
companion looks a scanned box up on the shop's own shelf by this field before it
asks a product database, so the next box of a filament fills the form from the
last one.

**Response 201:** `{ "ok": true, "spool": { ... } }`

**Desktop side effect:** `lan-spool-added` IPC.

### `PATCH /api/inventory/:id`

Update spool remaining weight. **Requires owner PIN.**

**Body**

```json
{ "remaining": 450 }
```

**Response 200:** `{ "ok": true, "spool": { ... } }`  
**Desktop side effect:** `lan-spool-updated` IPC.

### `DELETE /api/inventory/:id`

Remove a spool. **Requires owner PIN.**

**Response 200:** `{ "ok": true, "id": "spool-…" }`  
**Desktop side effect:** `lan-spool-deleted` IPC.

### `GET /api/waiting-list`

Active intake / waiting-list entries (excludes declined). **Requires owner PIN.**

**Response 200:** array of waiting-list objects (`id`, `project`, `clientName`, `notes`, `priority`, `status`, …).

### `PATCH /api/waiting-list/:id`

Update intake item status. **Requires owner PIN.**

**Body:** `{ "status": "active" | "reminded" | "declined", "reminderDate"?: "YYYY-MM-DD" }`  
Declining moves the item to `waitingListHistory`, stamped `declinedAt` (both apps).
`reminderDate` (Nov 2026) is the field the desktop's own waiting-list editor writes: a
calendar day, or `""`/`null` to clear it; absent leaves it alone; anything else is
**400** `{"error":"Invalid reminderDate"}`.

`PATCH /api/orders/:id`: `machineId: null` (or `""`) unassigns; a `machineId` that is
not a string or number is **400** `{"error":"Invalid machineId"}` (Nov 2026; it used to
unassign silently).

**Desktop side effect:** `lan-waiting-updated` IPC.

### `GET /api/clients`

Read-only client list from store. **Requires owner PIN.**

**Response 200:** array with `id`, `name`, `nameEn`, `nameAr`, `phone`, `email`.

Read `name`. It is the client's name resolved through the shop's own content
languages, and a shop may write in any two of nine — so a German-and-French shop
has neither `nameEn` nor `nameAr` filled in, and a client reading only those two
shows a list of blank rows. `nameEn`/`nameAr` are kept because the shipped iOS
Companion decodes them and nothing else.

### `POST /api/orders`

Create a simple job or quote from the companion. **Requires owner PIN.**

**Body**

```json
{
  "project": "Bracket v2",
  "client": "Acme Co",
  "material": "PLA",
  "price": 150,
  "status": "pending",
  "machineId": "MACH-1",
  "dueDate": "2026-06-15",
  "notes": "Rush job"
}
```

Use `"status": "quote"` for a quote (sets expiry from desktop `quoteValidityDays`).

The record is `lib/order-new.js newOrder`'s in **both apps** (Nov 2026) — the one the desk's
calculator makes: numbered from the shop's counter (`INV-2026-0042-…`, `QUO-2026-0007-…`),
with its invoice number, an estimated due date when none is sent, and every field a job
has. `price` is taken as the job's total. The desktop also gives it a tracking token (and a
quote its approval token).

**Response 201:** `{ "ok": true, "order": { ... } }`  
**Desktop side effect:** `lan-order-created` IPC with `{ order, settingsChanged }` — the
window adds the job and takes the counters it advanced. Before Nov 2026 the window had no
handler for this event, and its next save removed the job from the book; the same was true
of `lan-spool-updated`, `lan-spool-deleted` and `lan-waiting-updated`, which it now takes too.

The new order's id uses the shop's own prefix — `${invPrefix}-${year}-…`, the
same one the desktop mints (`INV` unless the shop changed it), or `quotePrefix`
for a quote. It used to read a setting that has never existed and always fell
through to `ORD-`, so an order raised on the phone came out numbered unlike
every order raised at the desk.

### `GET /api/orders/:id/quote-url`

Quote approval links for sharing with customers. **Requires owner PIN.**

**Response 200:**

```json
{
  "quoteUrl": "http://192.168.1.42:3219/order/QUO-2026-123/quote",
  "statusUrl": "http://192.168.1.42:3219/order/QUO-2026-123/status",
  "canApprove": true,
  "expired": false,
  "quoteExpiresAt": "2026-06-10"
}
```

### `POST /api/orders/:id/approve`

Owner approves a quote (same as customer web approval). **Requires owner PIN.**

**Response 200:** `{ "ok": true, "order": { ... } }`

**Response 404** no such order, **409** not awaiting approval, **410** the quote has
expired (`{"error":"Quote has expired"}`). Before Nov 2026 an expired quote answered
200 `ok` and was left unchanged.

### `GET /api/machines`

Machine list glance. **Requires owner PIN.**

**Response 200** — array:

```json
[
  { "id": "m1", "name": "P1S", "type": "fdm", "status": "printing", "hasPrinterApi": true }
]
```

### A paired phone's role (native Mac, Nov 2026, draft)

> **Native Mac only for now.** `lib/lan-server.js` follows in the desktop lane. The rule is shared: `lib/device-roles.js`.

A phone paired with this Mac carries a **role**: owner, manager, operator or viewer. The role is a set of scopes, and the Mac checks it on **every request the phone signs**. The phone's screens follow its role as a convenience; the server's answer is the check.

- A request the role does not cover is answered **403** `{"reason":"role-scope","required":"<scope>"}`, the shape an API token gets for a scope it lacks. `required` is `owner` for a route the table does not name.
- The check uses the path the server routes on. A segment that decodes to a slash, a dot segment or a control character is owner-only.
- A phone paired with the owner PIN before roles existed has no role and is the **owner**, as it was.
- A role holds whether the staff lock is on or off.
- The owner PIN and API tokens are unchanged.
- **Pricing through a job update is `quote:write`.** A write to `/api/orders` or `/api/orders/<id>` that carries a `price`, creates a job as a quote, or sends a `status` for a job that is a quote now (which accepts it) needs `quote:write`, whatever the route's own scope. An operator moves jobs; it does not price them.
- **The role answers are signed back.** `GET /api/devices/self` and every `role-scope` 403 carry `x-khayt-reply-mac` (the connector's: `HMAC(key, "khayt-reply-v1\n" + request nonce + "\n" + status + "\n" + sha256hex(body))`, base64), and only when the request's own signature passed. A phone should act on a role answer only when the MAC checks out. Other routes' answers are not signed yet.
- **A phone paired with the owner PIN is always the owner.** It holds the PIN, so it could send the PIN instead of its key; it cannot be given a lesser role. Remove it and pair it again by code.

| Role | Scopes |
|---|---|
| viewer | `queue:read`, `machines:read`, `orders:read`, `inventory:read` |
| operator | viewer + `orders:write`, `inventory:write`, `waste:write`, `machines:control` |
| manager | operator + `clients:read`, `clients:write`, `expense:write`, `quote:write`, `book:read` |
| owner | everything, including `book:write` and every route not listed |

#### `GET /api/devices/self`

Signed by a paired device. Answers what that device is: `{"deviceId":"dev_…","role":"operator","scopes":["queue:read", …]}`. A request with the owner PIN and no device signature is 403 `device-auth`. A role change takes effect on the next request; nothing is re-keyed.

`can` (Nov 2026): a list of the phone writes this computer serves for THIS device that are not a scope in the role table. Today one value: `"network-switch"`, for an owner's phone, when `POST /api/network/switch` is served. An older computer sends no `can`; a phone reads a missing list as empty and offers none of those controls.

#### A signed `device-revoked` (Mac only)

When the shop signs a phone out, that phone's next signed request is answered `401 {"reason":"device-revoked"}`. **This refusal is signed**: `x-khayt-reply-mac` = `replyMac(key, nonce, status, body)` exactly as `/api/devices/self` answers are, where `key` is the key the phone had, `nonce` is this request's `x-khayt-nonce`, `status` is `401` and `body` is the bytes of the answer. The key is per device, so the MAC is bound to the device id through it.

- The Mac signs it only when the request's own `x-khayt-mac` verifies under the phone's old key and its `x-khayt-time` is within the usual skew. A forged request naming the phone's id gets the same 401 with **no** reply MAC.
- **The phone must drop its key and its book only on a `device-revoked` whose reply MAC verifies over the nonce it just sent.** An unsigned one is not proof of anything.
- The Mac keeps a signed-out phone's old key for this only (it opens nothing), for the 256 most recent sign-outs. A phone signed out longer ago than that, or by an older Mac, gets an unsigned `device-revoked`, as does any connector.
- `device-unknown` (a PIN change, or an id never seen) is not signed: the Mac holds no key for it.
- **A large upload is refused from its headers alone, before its body is read, and that refusal is unsigned** (a receipt or job photo over 1 MB, a large estimate file): the phone's MAC covers the body, so the Mac cannot yet tell that the request is the phone's own. A phone that gets an unsigned `device-revoked` there should ask something small and signed, such as `GET /api/devices/self`, and act on that answer.
- **When no signed one ever comes** (signed out by an older Mac, or longer ago than the Mac remembers) every request keeps answering an unsigned 401. The phone should not wipe on that; it should stop showing the book as live and ask the person to pair again. What it does with the copy it holds is the phone's decision (iPhone #2641).

#### `POST /api/devices/pair` (pairing by code; **off** until the phone ships it)

The slicer plugin's commit-then-reveal flow (`POST /api/connectors/pair`) with the phone's own prefixes: `khayt-phone-commit-v1` (the commitment), `khayt-enrol-phone-v1` (what the Mac's identity signs in its offer) and `khayt-phone-check-v1` (the 6-digit check number). A commitment, an offer or a number made for one kind can never stand for the other. No PIN is sent.

- `POST /api/devices/pair` with `{v:2, commit, name, app, version}` → `{pairId, pollSecret, deviceId, publicKey, sig, identity}`. Only while a person has opened **Pair a phone** (120 s, 3 offers). 404 while the Mac has pairing by code off.
- `POST /api/devices/pair/<pairId>/reveal` with `{publicKey, nonce}` and `x-khayt-poll` → `{"state":"waiting"}`. A mismatch expires the offer; no number is ever shown for it.
- `GET /api/devices/pair/<pairId>` with `x-khayt-poll` → `{"state":"waiting"|"approved"|"denied"|"expired"}`.
- `DELETE /api/devices/pair/<pairId>` with `x-khayt-poll` → `{"state":"cancelled"}`: the phone gives its own request up, and the Mac goes back to waiting. A later `GET` answers `expired`. `409 {"state":"approved"|"denied"|"expired"}` when it was already answered (an approval is not undone here), `404 {"state":"unknown"}` for a wrong id or secret. The offer stays counted.
- Shared vectors: `docs/phone-pair.vectors.json` (the commitment, the signed offer, the check number, the derived key, and the reveals each side must refuse).
- A person at the Mac compares the number, picks a role (Operator by default; only the owner may give Owner, a manager up to Manager) and approves. The device is enrolled with that role.

**Signing out.** A phone paired by code holds no tag of the PIN: a PIN change does not sign it out. The server still needs a LAN PIN of at least 8 characters to answer anyone: with the PIN cleared or too short, a phone paired by code is refused like everyone else until one is set. **Remove** does (`device-revoked`). A phone paired with the owner PIN is still signed out by a PIN change.

### `GET /api/machines/live`

> **Served by both apps.** `lib/lan-server.js` and the native Mac's
> `LanServer.swift` (since Sep 2026) answer the same shape; the Mac builds it
> from `PrinterWatch.readings` in memory, so a request never polls a printer.

Live printer telemetry from the app's own printer polling (OctoPrint, Moonraker, PrusaLink, Bambu, …). **Requires owner PIN.** Cheap enough for a phone to poll every few seconds.

**Response 200** — one entry per `store.machines` row. The native Mac leaves
out a retired printer (`lib/machine-status.js isRetired`); `lib/lan-server.js`
still lists it, and the phone hides it either way:

```json
[{ "id": "M-1", "name": "U1", "hasPrinterApi": true,
   "state": "printing", "progress": 42, "filename": "dragon.gcode",
   "timeRemaining": 3600, "tempNozzle": 215, "tempBed": 59,
   "error": null, "lastUpdated": "2026-09-25T04:20:00.000Z", "apiType": "moonraker" }]
```

`progress`, `timeRemaining` (seconds) and the temperatures are rounded integers. A machine never heard from has its `id`, `name` and `hasPrinterApi`, and `null` for the rest.

**When it last answered, and why it is not answering** (both apps, Nov 2026, draft; the Mac's names):

- `lastOkAt`: when the printer last ANSWERED, ISO 8601, or `null` if it has not since the app started watching it. `lastUpdated` moves on a failed poll too; `lastOkAt` does not.
- `errorCode`: `null` while the printer answers. Otherwise one word that no language changes, to match on instead of `error` (a sentence in the shop's language):

  | `errorCode` | Meaning |
  |---|---|
  | `access-refused` | the printer answered and said no: HTTP 401 or 403, a handshake or an access code turned down |
  | `http` | any other HTTP status; `httpStatus` says which |
  | `not-set-up` | no address, a bad port, or a missing serial or mainboard id: nothing was asked |
  | `certificate` | a Bambu's certificate is not the one expected |
  | `unreadable` | it answered with something that is not its protocol |
  | `unreachable` | no answer: off, asleep, on another network, or it hung up |

  A client must treat a word it does not know as `unreachable`. On the desktop the word comes from `lib/printer-poll-cache.js` `failureCode`, never from `error` (a sentence in the shop's language). Two differences from the Mac: the desktop connects to a Bambu without pinning its certificate, so it never sends `certificate`; and an SDCP (Elegoo) printer that turns the connection down reads `unreachable`, not `access-refused`. A machine that is `not-set-up` is never counted as offline, so it starts no search for a printer that moved.
- `httpStatus`: the HTTP status of the failed poll when there was one, else `null`.

### Khayt Cloud: the same rows away from the shop (`PUT /v1/shops/{shopId}/live/printers`)

> **Published by both apps** (the Mac since Sep 2026, `LivePrinterPublisher.swift`,
> which asks `lib/live-snapshot.js` and seals in `LivePrinters.swift`; Windows/Linux since Nov 2026,
> `lib/main/live-printer-publisher.js` and `lib/live-snapshot.js`). The route is
> khayt-cloud's: its `docs/api-contract.md`, "Live channel & live printers", is
> the source of truth. This is what the two publishers share; where they differ it is said below.

Not a LAN route: the computer sends the `/api/machines/live` rows above to Khayt
Cloud, so a phone or the PWA away from the shop sees the same printers.

- **Request.** `PUT {cloud}/v1/shops/{shopId}/live/printers`,
  `Authorization: Bearer <the shop's cloud token>` (the token saved with the
  Khayt Cloud sign-in), body `{ "ciphertext": <envelope object>, "at": "<ISO 8601>" }`.
  `at` is the computer's time of the snapshot.
- **Sealed.** `ciphertext` is the store's envelope `{ v, z: "gzip", iv, ct, tag }`
  (AES-256-GCM under the shop's data key, the one unlocked with the sync
  passphrase), as an object, not a string of it. The server never reads it.
- **Plaintext.** `{ "v": 1, "at": <same as the request's>, "printers": [rows] }`.
  Each row is the `/api/machines/live` row, with `lastUpdated` and `lastOkAt`
  as epoch **milliseconds** (or `null`), never ISO strings. Every other field,
  `problems`, `waiting`, `errorCode` and `httpStatus` included, is as above;
  readers ignore fields they do not know.
- **Size.** `JSON.stringify(ciphertext)` at most 65,536 characters. Over it, the
  snapshot is sealed again with `filename` and `error` set to `null` on every
  row; if that is still over, nothing is sent. No printer is dropped.
- **Who publishes.** Every unlocked computer of the shop may, and the cloud keeps one snapshot, newest wins. A computer publishes only while it is hearing from the printers: at least one row answered in the last 3 minutes (`lib/live-snapshot.js hasFreshPoll`, asked by both apps; the Mac through its bundled copy). The owner's laptop away from the shop, or a computer whose polling stopped, sends nothing rather than replacing the real picture with "not heard". A shop none of whose machines Khayt can ask therefore publishes nothing.
- **When.** On a change, at most every 2 s (the server's per-shop 429 line);
  with nothing changed, a heartbeat every 45 s, so a viewer can tell idle from
  a computer that is off. "Changed" compares the rows without `lastUpdated` and
  `lastOkAt`: both move on every answered poll, and a healthy printer would
  otherwise mean a snapshot every poll. A printer that stops answering changes
  `error` and `errorCode`, so it is a change. Nothing is sent for a book with
  no printer Khayt polls (no machine with a printer connection).
- **Only while** Khayt Cloud is signed in and unlocked on that computer, for the
  book's own shop, for a role that may write (a viewer's snapshot is a 403),
  and while the "make no internet calls" switch allows Khayt Cloud (purpose
  `cloud`). Locking or signing out stops it; so does quitting.
- **Answers.** `200 { ok, receivedAt }`: sent. `429 { retryAfter }` (and
  `Retry-After`): wait that many seconds, at most 5 minutes on either app (Windows/Linux reads
  only the body; the Mac reads the header, then the body). `403`: stop for this session. `401`: the Mac treats
  it as `403`; Windows/Linux stops until the shop signs in to Khayt Cloud again.
  Anything else (`413`, a `5xx`, a deploy): try again 45 s later. No answer at
  all: try at the next check.

### `POST /api/printer/{machineId}/{pause|resume|stop}`

> **Native Mac only** (Nov 2026). `lib/lan-server.js` does not serve it.

A paired phone pausing, resuming or stopping a print. `stop` cancels the job (`cancel` is accepted too). The body is empty. The command is the Mac printer card's own path (`PrinterControl.send`), so the phone sends the printer exactly what the Mac's button would.

**Requires a signed, enrolled phone** (the `x-khayt-device` headers, see
`LanDevices`). The owner PIN sent bare is refused with
`403 {"ok":false,"reason":"device-key-required"}`: this moves a machine
mid-print. The usual gate runs first, so a non-local `Host` is `421` and an
unset or short PIN is `401`.

**Response 200:** `{"ok":true,"state":"paused"}`. `state` is the printer's own word, read right after a refresh, or `null`.

**Refusals:** `{"ok":false,"reason":…,"message"?:…}`

| Status | `reason` |
|---|---|
| 404 | `not-found`: no machine in use with that id |
| 409 | `not-connected`, `not-watched` (under service / retired / another app's protocol), `unsupported` (this protocol has no such verb), `no-job` |
| 502 | `refused`: the printer said no, and `message` is what it said |
| 503 | `busy`: the app is starting |

### `POST /api/network/switch`

> **Native Mac only** (Nov 2026, draft). `lib/lan-server.js` does not serve it
> yet; the desktop is to match this shape. A phone treats a `404` as "this
> computer cannot do it" and shows the switch read-only.

An **owner's phone** turning the shop's "Make no internet calls" on or off (iPhone frame 1B). It is the same change the owner makes at the Mac, by the same path: the same forward-only stamp (`lib/network-switch.js stampAfter`), the same "tell my other computers" call when that option is on, one write of `settings.network`, and the Mac's own gate told at once.

**Who.** A **signed**, enrolled phone whose role is **owner** (a phone paired with the owner PIN before roles is the owner). The PIN alone is `403 {"ok":false,"reason":"device-key-required"}`. A signed phone in any other role gets the usual `403 {"reason":"role-scope","required":"owner"}`: the route is deliberately not in the role table (`lib/device-roles.js`), and a route the table does not name is the owner's. A paired slicer cannot reach it.

**Body** (JSON, at most 4 KB):

```json
{ "offline": true, "keep": ["cloud"], "seen": "2026-11-22T14:12:00.000Z" }
```

- `offline` (boolean, required): the switch.
- `keep` (array, optional): the purposes kept while it is on, replacing the list. Omitted or `null`: left as it is. Each entry must be a purpose the rule lets a shop keep: any of `lib/outbound.js` `PURPOSES` but `lan` and `switch-sync` (`tunnel` included, which the Windows/Linux app can tick). **An entry this computer does not know is refused (`bad-keep`), not dropped**, so a phone with a newer list learns it is talking to an older computer. A purpose already in the book that this computer does not know is left there: it was never this request's to untick, and the phone is not shown it.
- `seen` (string, optional): the `changedAt` the phone was showing when the person tapped. If the book's is a different moment, nothing is changed and the answer is `409` with the current value, so two people flipping it at once never overwrite each other blind. Compared as instants, so the same moment written without its milliseconds is the same. A phone that has seen no `changedAt` sends none.
- `seenKeep` (array of strings, optional): the `keep` list the phone was showing. `changedAt` moves only when the switch itself is flipped, so a Keep ticked at the computer meanwhile is invisible to `seen`; with `seenKeep`, a list that is no longer what the computer holds is a `409` too, and that tick is not wiped. **A phone that sends `keep` should send `seenKeep`.**

**Answers.** Every answer to a request whose signature verified carries `x-khayt-reply-mac`, as `/api/devices/self` does (the `200`, the `400`s, the `409`s, the `503` and the role `403`): a phone shows "Done" only when the MAC verifies. Before that, the usual gate answers apply and are not signed, except `device-revoked`: `401` (no PIN or a wrong one, `device-auth`, `device-clock`, `device-replay`, `device-revoked`), `421` (a `Host` that is not local), `429`. An API token is not a phone: `403 device-key-required`, whatever headers come with it.

| Status | Body |
|---|---|
| 200 | `{"ok":true,"network":{"offline":true,"keep":["cloud"],"changedAt":"…","changedBy":"Turki's iPhone"}}` |
| 400 | `{"ok":false,"reason":"bad-body"}` or `"bad-keep"` |
| 403 | `device-key-required` (unsigned) or `role-scope` (signed, not the owner) |
| 409 | `{"ok":false,"reason":"changed","network":{…}}`: `seen` is stale. `"not-saved"` with `network`: another change is in flight or this computer cannot save the book now. `"read-only"`: the sample book |
| 503 | `{"ok":false,"reason":"busy"}`: the app is starting |

`changedBy` is the phone's name as the shop sees it in Paired phones, without control or direction-changing characters, cut at 80 characters. `changedAt` is never earlier than the newest stamp this computer has seen, unless that stamp is more than ten minutes ahead of its clock (a mistake already in the book), which is not followed.

**How a phone knows the route is there.** `GET /api/devices/self` carries `"can": ["network-switch"]` for an owner's phone on a computer that serves this route (see below). No `can`, or a list without it: show the switch read-only.

### `GET /api/printer/{machineId}/trays`

> **Native Mac only** (Nov 2026). `lib/lan-server.js` does not serve it.

The spool tags a printer's heads read (a Snapmaker U1), each matched against the shop's spools. Only the Mac holds the printer, so the phone asks and the Mac reads: one read-only `GET` of the printer's `filament_detect`. Nothing else is sent to the printer.

**Requires a signed, enrolled phone.** The owner PIN sent bare, or an API token, is `403 {"ok":false,"reason":"device-key-required"}`: the answer names the shop's spools.

**Role:** `inventory:read` in `lib/device-roles.js`. `GET /api/devices/self` lists `"trays"` in `can` when this Mac serves the routes and the phone's role may read them.

**Response 200:**

```json
{"ok":true,"trays":[
  {"head":1,
   "tag":{"vendor":"Snapmaker","manufacturer":"Polymaker","material":"PLA","sub":"SnapSpeed",
          "colours":["#080A0D"],"weightG":500,"diameterMm":1.75,"official":true},
   "key":"…",
   "match":{"kind":"link","spoolId":"INV-1"},
   "prefill":{"material":"PLA SnapSpeed","color":"#080A0D","brand":"Polymaker","weight":500},
   "linked":null},
  {"head":3,"tag":null,"key":"","match":{"kind":"none"},"prefill":null,"linked":null}
]}
```

- `head` counts from one, in the printer's order. One row per head, tagged or not.
- `tag` is `null` when the head reads no tag. A head with no tag may still hold filament.
- `key` is everything the tag says. Send it back as `seen` when linking. Two identical spools have the same key: the printer reports no number of the tag's own.
- `match.kind` is the shared rule's answer (`lib/rfid-tray.js spoolMatch`): `link` (exactly one spool matches strongly: `spoolId`), `ask` (several, or only near ones: `candidates`, spool ids, best first), `new` (nothing like it on the shelf), `none` (no tag).
- `prefill` is what **Add spool from the tag** would add (`null` with no tag). No price: that is the shop's to set.
- `linked` is the spool already recorded in this head, or `null`. A link to a spool no longer on the shelf is not reported.

**A printer with no tags to read answers `200 {"ok":true}` with no `trays`** (not a Moonraker printer, not connected, or firmware with no `filament_detect`). The phone shows nothing for it.

**Refusals:** `{"ok":false,"reason":…,"message"?:…}`

| Status | `reason` |
|---|---|
| 404 | `not-found`: no machine with that id |
| 502 | `printer-unreachable`: the printer was asked and did not answer; `message` says why |
| 503 | `busy`: the app is starting |

### `POST /api/printer/{machineId}/trays/{head}/spool`

> **Native Mac only** (Nov 2026). `lib/lan-server.js` does not serve it.

Says which of the shop's spools is in a head. `head` counts from one, 1 to 16.

**Body**, exactly one of:

```json
{"seen":"<the row's key>","spoolId":"INV-1"}
{"seen":"<the row's key>","create":true}
```

`seen` is required: the `key` of the row the phone was showing. `create` adds one spool from the tag (its `prefill`) and links it. Any other field, both, or neither is `400 bad-body`.

**What it writes, and nothing else:** `machines[].headSpools[head - 1]` = the spool's id (the record the Windows/Linux app writes, keyed from zero as it keys it), and with `create` one new spool with no price. **An existing spool is never changed.** The printer is told nothing: the Mac reads the tags again before writing, with the same read-only `GET`.

**Requires a signed, enrolled phone**, as above.

**Role:** `inventory:write` in `lib/device-roles.js`: an operator's, a manager's or the owner's phone. That is the computers' own rule for the same acts (adding a spool is inventory/create, linking is printers/edit, and an operator has both). A viewer's phone is refused with `403 {"reason":"role-scope","required":"inventory:write"}`.

**Response 200** (linked) or **201** (a spool was added): `{"ok":true,"head":2,"spoolId":"INV-9","created":true,"spool":{"id":"INV-9","material":"PLA SnapSpeed","color":"#E2DEDB","brand":"Polymaker","weight":500}}`.

**Refusals:** `{"ok":false,"reason":…,"message"?:…,"trays"?:[…]}`

| Status | `reason` |
|---|---|
| 400 | `bad-body` |
| 404 | `not-found` (the machine), `no-head` (the printer has no such head), `no-spool` (no such spool on the shelf) |
| 409 | `changed`: the head's tag is not the one the phone was showing (taken out or swapped since); `trays` holds what is there now, and nothing was written |
| 409 | `no-trays`: this printer has no tags to read |
| 409 | `tag-unusable`: the tag names no material a spool could be made from |
| 409 | `read-only`: this Mac is showing the sample book |
| 500 | `not-saved`: the write failed (another computer holds the book, for one); `message` says why |
| 502 | `printer-unreachable` |
| 503 | `busy`: the app is starting |

Sending the same link twice writes the same link. Sending `create` twice adds two spools: the phone must not retry a `create` whose answer it did not see without reading the trays again (the first one's spool is then `linked`).

### `POST /api/printer/{machineId}/bed-clear`

> **Served by both apps** (Nov 2026, drafts): the native Mac app and
> `lib/lan-server.js` (Windows/Linux), through the shared rule
> `lib/lan-rest.js` `machineBedClear`. The desktop has no sample book, so it
> never answers `409 read-only`.

A paired phone saying a machine's plate is empty: the phone's **"Bed is clear"** (leftovers from a print that ended badly) and **"Taken off"** (a finished print). Both write the same thing, and the same thing as the Mac's own "Bed is clear" button: `bedClearedAt` on the machine, stamped now. The shared rules read it (`lib/auto-dispatch.js`: the printer may be offered again; `lib/waiting-at-machine.js`: `print-to-take-off` and `bed-to-clear` end). The body is empty. The printer itself is told nothing.

**Requires a signed, enrolled phone**, as the commands above do: the owner PIN sent bare is `403 {"ok":false,"reason":"device-key-required"}`.

**Role:** `machines:control` in `lib/device-roles.js` (`allowsRequest`): an operator's, a manager's or the owner's phone. A viewer's phone is refused with the usual `403 {"reason":"role-scope","required":"machines:control"}`, signed back.

**Response 200:** `{"ok":true,"bedClearedAt":"2026-11-22T14:07:05.120Z"}`.

**Refusals:** `{"ok":false,"reason":…,"message"?:…}`

| Status | `reason` |
|---|---|
| 404 | `not-found`: no machine in use with that id (a retired printer is not one) |
| 409 | `read-only`: this Mac is showing the sample book |
| 500 | `not-saved`: the write failed (another computer holds the book, for one), and `message` says why |
| 503 | `busy`: the app is starting |

It is not refused while the printer is printing: a stamp made before a print ends is simply older than that print's end, and the rules ignore it. Sending it twice writes a newer stamp and changes nothing else.

### `POST /api/orders/{id}/photos`

> **Served by both apps** (Nov 2026): the native Mac app and `lib/lan-server.js` (Windows/Linux).

A paired phone adding a photo to a job. The body is the image itself (a JPEG from the phone's camera), not JSON, up to 8 MB, the desktop's own photo cap. The Mac files it exactly as its own Add Photo does (`OrderPhoto`): a 240px thumbnail inline in `printLog[].printPhotos[]`, a 1600px copy in `order-photos/` beside the book, the desktop's `{orderId}-{index}-{base36 ms}.jpg` filename, `"source": "phone"` on the record (the optional field both apps write: `printer`, `shop` or `phone`, missing on older photos), and the file written before the record. Any job status is accepted, as with the printer's own finish photo.

**Requires a signed, enrolled phone**, like the printer route. The owner PIN sent bare, or an API token, is refused with `403 {"ok":false,"reason":"device-key-required"}`. A body over 1 MB is judged from the head before it is read: over 8 MB is `413 {"ok":false,"reason":"too-large"}`, an unsigned head is the 403, and it shares the large-body slots (`503 busy`).

On Windows/Linux the signed body is read whole (up to the signed-body cap) before it is judged, so there is no head check and no `503 busy`; over 8 MB is still `413 too-large`.

**Response 201:** `{"ok":true,"index":0,"filename":"J1-0-mh3k9x2a.jpg"}`, where `index` is the photo's position in `printPhotos`.

**Refusals:** `{"ok":false,"reason":…}`

| Status | `reason` |
|---|---|
| 404 | `not-found`: no job with that id |
| 409 | `read-only`: this Mac cannot write the book (Mac only) |
| 413 | `too-large`: empty, or over 8 MB |
| 415 | `not-an-image`: not a picture this Mac can read |
| 500 | `write-failed`, with `message` |

### `POST /api/webhook/salla` and `POST /api/webhook/zid`

A storefront telling the shop it has an order. **Served by both apps** — the
native Mac app since the storefront rule moved to `lib/storefront-webhook.js`.
Not behind the owner PIN: the storefront proves itself with a signature
instead.

- **Signature:** `X-Salla-Signature` / `X-Zid-Signature`, `sha256=` + the hex
  HMAC-SHA256 of the raw body, keyed with `settings.lanApi.sallaWebhookSecret`
  / `zidWebhookSecret` (set in either app's Online / LAN settings).
- **Answers, in order:** 429 locked out (ten bad signatures from one address,
  per platform — its own bucket, so it never locks the owner's PIN); 403 no
  secret configured; 401 bad signature; 409 a byte-identical replay within ten
  minutes; 200 `{ "ok": true, "duplicate": true }` for an order the book
  already holds (by the platform's own order id, so a retry is never a second
  order); otherwise 200 `{ "ok": true }`.
- **What it writes:** one `printLog` row at the top — `source`,
  `sourceOrderId`, the platform's total as `price` — and, for items the shop
  already has on the shelf, takes them off `settings.storefront.stockQty`. An
  order the shelf covers in full is written `completed` and `fromStock`.
  Each item is matched to a catalogue product by `lib/store-order-job.js` —
  its `sku` against the product's `sku` and its variants' SKUs, then its exact
  normalised name, else unmatched — and the row carries `storeLines` (one per
  item, with `productId` or null), the matched products' `parts` (per-piece
  counts times what is still to print), and `productId` / `components` when
  the whole basket is one product. An unmatched item gets a "Not matched to a
  product" line in `notes` and is left for the shop to place.

### `POST /api/webhook/smsa`, `/aramex`, `/spl`

A carrier saying where a parcel is. **Served by both apps**; the rule is
`lib/carrier-webhook.js`.

- **Signature:** `X-Khayt-Signature` (or `X-Signature`), `sha256=` + the hex
  HMAC-SHA256 of the raw body, keyed with
  `settings.shipping.<carrier>.webhookSecret` (Settings → Shipping, or
  Integrations → Shipping & Fulfillment on the Mac).
- **Answers, in order:** 429 locked out (per carrier, its own bucket); 403 no
  secret; 401 bad signature; 409 replay; **422** a signed payload with no
  tracking number and status Khayt can read (so it shows in the carrier's own
  dashboard); otherwise 200 `{ "ok": true }` — **including** a tracking number
  the shop does not hold, because a different answer would say which parcels it
  has.
- **What it writes:** on the job holding that tracking number, the status moved
  forward (never back; `exception` always), a line of `shippingHistory`, and
  `shippedAt` / `deliveredAt` by `order-status.stampFromShipping`. An event
  that changes nothing is not written.

The printer webhook (`/api/webhook/printer/:id`) is **served by both apps**
(the Mac since Nov 2026): the `x-khayt-webhook-token` header against
`settings.lanApi.webhookToken` (never `?token=`), compared in constant time, ten
wrong ones per address to a one-minute lockout on its own channel. `{topic}`,
`{event}` or `{state}` is read as print started / done / cancelled, and the job on
that machine moves through `lib/order-status.js` (`lib/lan-rest.js printerEvent`).
Answers `{ "ok": true, "event", "advanced" }`.

### `GET /api/version` and `POST /api/files/local` — Khayt as a printer in the slicer

> **Served by both apps**, and only while the shop has switched on "Accept files
> from slicers (OctoPrint upload)": on the Mac, Settings → Online; on Windows/Linux
> (not on screen yet) main's `hub:slicer-upload-set`, kept in userData with the key
> ([`lib/main/connector-local.js`](../lib/main/connector-local.js), sealed with the OS
> keychain). Off (the default), both are the ordinary **404**. The desktop's routes
> are [`lib/main/slicer-upload.js`](../lib/main/slicer-upload.js): the body is parsed as
> it streams and only the file part is written, into the same inbox and the same
> SHA-256 dedupe as a paired plugin's file.

The two OctoPrint routes a slicer's "Send" uses (OrcaSlicer, PrusaSlicer,
Bambu Studio: a physical printer of host type OctoPrint, with the Mac's LAN
address and the API key shown in that pane). They are the server side of the
same shapes `lib/printer-upload.js` sends to a real OctoPrint.

- **Auth:** `X-Api-Key: <key>`. The key is 32 upper-case hex characters,
  minted on this Mac and kept in its login Keychain (not in the book, so it
  never travels in `/api/store`); "Regenerate" replaces it. No key **401**,
  wrong key **403**, ten wrong keys from one visitor **429** for a minute (its
  own bucket — it never locks the owner PIN). Not accepted in the query.
- **`GET /api/version`** → `200 {"api":"0.1","server":"1.10.0","text":"OctoPrint 1.10.0 (Khayt)"}`.
- **On the desktop (Windows/Linux), both routes:**
  - The shop's network only: `421 {"error":"host-not-local"}` through the tunnel or for a `Host` that is not this computer, as the connector routes.
  - At most 30 uploads an hour from one address, then `429` with `Retry-After`.
  - An upload is ended after 60 s with no bytes (the Mac's idle read timeout), never by its total length of time, so a slow 1 GB file from a slicer is not cut off while it still flows. Every other request keeps a 300 s whole-request limit.
  - A failed spool (a full or read-only disk) answers `500` and frees its upload slot.
  - File names are made safe for Windows and ext4: `< > : " | ? *` become `_`, trailing dots and spaces go, a device name (`CON`, `NUL`, `COM1`, …) gets a leading `_`, and a name is cut to 200 UTF-8 bytes, keeping its extension.
- **`POST /api/files/local`** — `multipart/form-data`, the file in the field
  `file`. Taken: `.gcode`, `.gco`, `.g`, `.bgcode`, `.gcode.3mf` (else
  **415**); no file part **400**. The key, the `Content-Length` and the cap are
  judged from the head **before** the body is read; over 1 GiB is **413**; at
  most two uploads at once (**503** `busy`). The body is streamed to disk, not
  memory. `print` and `select` are read and **ignored** — nothing here ever
  starts a printer — and the answer says so. A full inbox (100 files) is
  **409**.
- **201**, `Location` the resource:
  ```json
  {"done":true,"effectivePrint":false,"effectiveSelect":false,
   "files":{"local":{"name":"plate.gcode","display":"plate.gcode","path":"plate.gcode","origin":"local",
     "refs":{"resource":"http://<host>/api/files/local/plate.gcode",
             "download":"http://<host>/downloads/files/local/plate.gcode"}}}}
  ```
- **Where it goes:** the "From slicer" inbox beside the book on the Mac
  (`<book folder>/From slicer/<id>/`; on Windows/Linux `<userData>/From slicer/<id>/`), with the slicer's own grams, time,
  material and slicer name read off the file. The shop adds it to the library,
  or starts a job or a quote from it, in the app.

## Errors

| HTTP | Meaning |
|------|---------|
| 401 | Missing or wrong PIN |
| 403 | Write blocked (no PIN configured on server) |
| 413 | Body &gt; 1 MB |
| 429 | PIN lockout |
| 404 | Unknown path or order |

Body: `{ "error": "message" }`

## Desktop IPC (mobile → UI sync)

Defined in `preload.js`:

| Event | When |
|-------|------|
| `lan-spool-added` | After `POST /api/inventory` |
| `lan-spool-updated` | After `PATCH /api/inventory/:id` |
| `lan-spool-deleted` | After `DELETE /api/inventory/:id` |
| `lan-order-created` | After `POST /api/orders` |
| `lan-order-updated` | After `PATCH /api/orders/:id` or quote approval |
| `lan-waiting-updated` | After `PATCH /api/waiting-list/:id` |
| `lan-kanban-advanced` | Printer webhooks / auto-advance |

Renderer handlers: `renderer/app-boot.js` (`onLanSpoolAdded`, `onLanOrderUpdated`).

## Out of scope for companion v1

Calculator, ZATCA, invoicing, CRM, analytics, settings editor, cloud sync, local offline DB. Use the desktop app or LAN PWA for those flows.

## Related docs

- [IOS_COMPANION.md](./IOS_COMPANION.md) — SwiftUI app architecture
- [ios/README.md](../ios/README.md) — build and run
