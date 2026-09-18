# iOS Companion (v2)

Native iPhone client. The desktop remains the **book of record** — `khayt-store.json`
lives there, and that is the copy a shop backs up and bills from — but the phone is
no longer a live view of it.

## How it actually works now

Three things changed the shape of this app, and anything written before them is
misleading:

1. **The phone runs the shop's own business logic.** `mac/KhaytCore` builds for
   iOS and the companion links it, so the tax engine, pricing and money rules are
   the same code the Mac computes with — running in JavaScriptCore on the phone,
   with nothing bundled and no second implementation. See the `KhaytCore` section
   of [CLAUDE.md](../CLAUDE.md).

2. **The phone keeps a working set of the shop's records.** Not the whole book:
   `printLog` is about half of a real store and `printFiles` another quarter, all
   of it history no companion screen has ever shown. What travels is
   `BookScope.workingSet` — the settings, every *unfinished* order whatever its
   age, the newest 200 finished ones, and the clients, spools, machines and
   waiting list. The phone reads from that, so the screens work with the Mac
   switched off.

   It is **partial, and it knows it.** A scope file beside the book records which
   collections are complete and which are windowed, so a screen can say "200 of
   3,140" rather than reporting a three-year-old shop as having done 200. A phone
   that does not know what it is missing answers "no" to "may I total this".

3. **The phone finds the Mac by itself.** The Mac advertises `_khayt._tcp` under
   the shop's own name, so pairing is a list to tap rather than an IP to type.
   Typing an address by hand is still there, demoted, because the Electron
   desktop does not advertise and some networks block Bonjour.

**The two desktops do not serve the same routes.** `lib/lan-server.js` (Electron)
serves the full surface. The native Mac's `LanServer.swift` serves `/api/status`,
`/api/queue`, `/api/store` and the customer-facing intake — and nothing else. Five
of the companion's screens have no endpoint on it at all, which is why they read
from the book rather than the wire. [LAN_API.md](./LAN_API.md) marks which is
which; do not assume a route exists on both.

## Feature set

| Area | Features |
|------|----------|
| **Pairing** | Pick the shop off the Wi-Fi (Bonjour `_khayt._tcp`), then the owner PIN. Manual address entry kept for desktops that do not advertise |
| **Home** | Queue stats, kanban strip, completed today, low-stock & overdue alerts, quick actions, order preview |
| **Orders** | Active queue + filters (status, overdue) + recent history; detail sheet; advance / set status; **assign machine**; haptics |
| **New order** | Create an order from the app (client, item, material, qty, due date) — posts to the queue |
| **Live monitoring** | Real-time printer status (progress %, current job, nozzle/bed temps) from connected machines |
| **Inventory** | List, search, low-stock filter, sort, spool detail (SKU, lot, temps); **edit remaining grams**; **delete spool**; add spool (photo OCR / NFC / manual), **write NFC tag** (OpenSpool / OpenTag3D / OpenPrintTag) |
| **Clients** | Client list with order history and contact details |
| **Intake** | Walk-in / waiting-list triage — review incoming requests, advance or dismiss |
| **Machines** | Printer list + live status |
| **Settings** | Connection, language (EN / AR / system), notification toggles, widget guide, unpair |
| **Connection** | Polling health, top banner when offline/wrong PIN, badge in toolbar |
| **Notifications** | Local alerts: queue changes, LAN disconnect, overdue orders, low filament |
| **Widget** | Home Screen queue widget (bundled extension target — see [ios/XCODE_WIDGET.md](../ios/XCODE_WIDGET.md)) |
| **Shortcuts** | Siri / Shortcuts: open queue, open inventory |
| **Localization** | English + Arabic strings, RTL layout for Arabic |

## LAN API

Endpoints, and **which desktop serves them** — see [LAN_API.md](./LAN_API.md) for
the full reference.

| Feature | Endpoint | Native Mac | Electron |
|---------|----------|:---:|:---:|
| The shop's records, as a working set | `GET /api/store` | ✅ | — |
| Discovery | `_khayt._tcp` (Bonjour) | ✅ | — |
| Status | `GET /api/status` | ✅ | ✅ |
| Queue | `GET /api/queue` | ✅ | ✅ |
| Orders, inventory, clients, machines, waiting list | see below | — | ✅ |

| Feature | Endpoint |
|---------|----------|
| Status | `GET /api/status` |
| Queue | `GET /api/queue` |
| Orders | `GET /api/orders?limit=`, `POST /api/orders`, `PATCH /api/orders/:id` |
| Inventory | `GET /api/inventory`, `POST /api/inventory`, `PATCH /api/inventory/:id`, `DELETE /api/inventory/:id` |
| Machines | `GET /api/machines`, `GET /api/machines/live` |
| Clients | `GET /api/clients` |
| Waiting list | `GET /api/waiting-list`, `PATCH /api/waiting-list/:id` |

See [LAN_API.md](./LAN_API.md).

## NFC write

After reading a filament tag, scanning a label, or reviewing spool details, use **Write to NFC tag** to encode data onto a blank writable NTAG sticker.

| Standard | MIME type | Printers / firmware |
|----------|-----------|---------------------|
| **OpenSpool** | `application/json` | Snapmaker U1 **extended firmware** (community), Bambu via OpenSpool reader |
| **OpenTag3D** | `application/opentag3d` | Bambu Lab, Creality, generic |
| **OpenPrintTag** | `application/vnd.openprinttag` | Prusa MK4 / XL / MINI |

Encoding mirrors desktop `renderer/inventory.js` parsers (`NFCParser` / `NFCEncoder`). Requires a physical iPhone with NFC and paid Apple Developer entitlements (`NDEF` + `TAG`).

### Who can use NFC write?

Any individual with an **iPhone + blank NTAG tags** can write tags from the app. Whether the **printer recognizes** the tag depends on firmware:

| Setup | NFC write from Khayt | Printer reads tag |
|-------|----------------------|-------------------|
| **Bambu / Creality / generic** | Yes — pick **OpenTag3D** | If printer/firmware supports OpenTag3D |
| **Prusa** | Yes — pick **OpenPrintTag** | Prusa with OpenPrintTag support |
| **Snapmaker U1 stock firmware** | Tags can be written, but printer **won’t** read them | Official Snapmaker Mifare Classic tags only |
| **Snapmaker U1 extended firmware** | Yes — pick **OpenSpool** (NTAG215/216 recommended) | Yes, via [paxx12 extended firmware](https://snapmakeru1-extended-firmware.pages.dev/rfid_support) |

**Important:** Snapmaker U1 extended firmware is **not** issued by Snapmaker. It is **community/third-party** firmware (e.g. paxx12). Stock U1 firmware only reads proprietary Snapmaker tags. Installing extended firmware is optional and at your own risk.

## Out of scope (v2)

Calculator, ZATCA, invoicing, full desktop settings, cloud sync, remote push server.

**No longer out of scope, and once was:** a local business database. The phone
holds one — see "How it actually works now" above. Anything in this repo that
still describes the companion as having no local store, or as a live view of the
desktop, predates that and is wrong.

**Still true:** the phone cannot delete records, and does not write offline. A
deletion needs a tombstone and nothing on the phone writes one, so deleting stays
a desktop action. Offline writes are a protocol question rather than a missing
button — see `BookReader.pendingChanges` and `POST /api/store/deltas`.

## UI redesign

Copy the prompt in [IOS_UI_REDESIGN_PROMPT.md](./IOS_UI_REDESIGN_PROMPT.md) into a design AI.

## Repo layout

```
ios/KhaytCompanion/          SwiftUI app
ios/KhaytWidget/             Widget extension source (target bundled in project)
ios/KhaytCompanion.xcodeproj
docs/LAN_API.md
```

## Security

- Owner PIN in iOS Keychain  
- HTTP on trusted LAN only  
- App Group `group.com.khaytapp.companion` for widget snapshot
