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

| Mechanism | Details |
|-----------|---------|
| Header | `x-khayt-pin: <owner-pin>` (preferred for native clients) |
| Query | `?pin=<owner-pin>` (used by some PWA links) |

**Owner PIN** is `settings.lanApi.pin` in the store — same as kiosk / queue API.

### PIN rules

- If an owner PIN **is configured**, sensitive `GET` routes and all mutating routes require a matching PIN.
- If **no** owner PIN is configured, sensitive `GET` routes return **401** (queue/inventory/machines are unavailable until a PIN is set).
- **Writes** without a configured PIN return **403**.
- **Brute force:** 10 failed attempts per client IP → **429** for 1 minute.

### Public routes (no owner PIN)

- `GET /api/status`
- `GET /order/:id` (customer portal)
- Quote approval, intake (separate intake PIN/token), webhooks, static PWA assets

Companion apps should call `GET /api/status` first (reachability), then `GET /api/queue` with PIN to confirm pairing.

## Companion v1 endpoints

### `GET /api/status`

Public aggregate counts for the active queue.

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

The native Mac app advertises itself over Bonjour whenever its LAN API is bound
to the network, so a client does not have to be told an address.

| | |
|---|---|
| Service type | `_khayt._tcp` |
| Service name | the shop's own name (`settings.shopName`), truncated to 63 **bytes** |
| `TXT v` | the LAN API version — `1` |
| `TXT store` | `1` when this server implements `GET /api/store`; absent means no |

**Only when bound to the LAN.** A loopback-only server is not advertised, because
a client that found it could never connect to it.

`TXT store` is the one thing worth knowing before pairing: it separates a Mac that
can hand over the book — so the client keeps working away from the desk — from one
that cannot. The Electron desktop does not advertise at all.

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
| `clients`, `inventory`, `machines`, `waitingList` | in full, up to a ceiling |
| everything else | stays on the Mac |

An order is finished at `completed`, `shipped`, `delivered` or `cancelled`.
Anything else travels however old it is — a job stuck in QC for two months is
still in the shop.

`?scope=whole` returns the entire store instead, for a restore or a person with
`curl`. The companion never asks for it.

**Secrets are masked** either way. The store passes through
`KhaytCloudOutbox.forCloud(store)` — the same rule the cloud push uses — so every
path named in `lib/store-secret-paths.js` (printer access codes, API keys, bot
tokens, refresh tokens) arrives as `"__KHAYT_MASKED__"`. A device on the LAN is
trusted with exactly what the cloud is trusted with, and no more.

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
    "omitted": ["auditLog", "expenses", "printFiles", "products"],
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

### `POST /api/store/deltas`

A paired client's changes, folded into the shop's book. **Requires owner PIN.**

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

**Response 200:** `{ "ok": true }`  
**Response 404:** order not found  
**Response 400:** invalid status

**Desktop side effect:** `lan-order-updated` IPC → renderer updates `printLog` and UI.

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
           "rushFee": 16.44, "shipping": 25, "extras": 12.5, "total": 119.71 }
```

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

**Body:** `{ "status": "reminded" }` or `{ "status": "declined" }`  
Declining moves the item to `waitingListHistory` on desktop.

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

**Response 201:** `{ "ok": true, "order": { ... } }`  
**Desktop side effect:** `lan-order-created` IPC.

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

### `GET /api/machines`

Machine list glance. **Requires owner PIN.**

**Response 200** — array:

```json
[
  { "id": "m1", "name": "P1S", "type": "fdm", "status": "printing", "hasPrinterApi": true }
]
```

### `GET /api/machines/live`

Live printer telemetry from desktop API polling (OctoPrint, Moonraker, PrusaLink, Bambu). **Requires owner PIN.**

**Response 200** — array per machine with `state`, `progress`, `tempNozzle`, `tempBed`, `timeRemaining`, `filename`, `error`, `lastUpdated`.

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

The carrier (`/api/webhook/smsa|aramex|spl`) and printer
(`/api/webhook/printer/:id`) webhooks are **served by the Windows and Linux app
only.**

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
