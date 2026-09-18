# Khayt iOS Companion (v2)

Companion for iPhone/iPad. The desktop is the **book of record** — `khayt-store.json`
on the Mac or PC is what a shop backs up and bills from — but the phone is no longer
a live view of it.

It holds a **working set** of the shop's records and reads from that, so the screens
work with the desktop switched off, and it runs the shop's own business logic through
`mac/KhaytCore` rather than asking for every figure. No cloud sync.

The sentence that used to be here said "no local business database". That stopped
being true; see [docs/IOS_COMPANION.md](../docs/IOS_COMPANION.md) for what replaced it.

## v2 features

| Area | Implementation |
|------|----------------|
| **Pairing** | Pick the shop off the Wi-Fi (Bonjour `_khayt._tcp`), then the owner PIN. Manual address entry kept for desktops that do not advertise |
| **Connection health** | Polls `GET /api/status` + PIN check |
| **Production queue** | View kanban orders, advance or set status, **assign machine** (`PATCH /api/orders/:id`) |
| **New order** | Create orders from the app (`POST /api/orders`) |
| **Live monitoring** | Real-time printer progress / temps (`GET /api/machines/live`) |
| **Inventory** | List, manual/NFC add, **edit remaining / delete spool** (`POST` / `PATCH` / `DELETE /api/inventory`) |
| **Clients** | Client list + history (`GET /api/clients`) |
| **Intake** | Walk-in / waiting-list triage (`GET` / `PATCH /api/waiting-list`) |
| **Machines** | Printer status (`GET /api/machines`) |
| **Widget** | Home Screen queue widget (bundled extension target) |

## Out of scope (v2)

Calculator, ZATCA, invoicing, analytics, full settings, offline-first DB.

Use the **LAN PWA** (Add to Home Screen) for a zero-install alternative; native adds NFC, Keychain, and a future App Store path.

## Desktop setup (v2.2.1+)

1. **Settings → LAN API** → enable API  
2. **Listen on all network interfaces**  
3. Set **Owner LAN PIN** (required for queue/inventory)  
4. Note LAN IP and port (default **3219**)

## Build

```bash
open ios/KhaytCompanion.xcodeproj
```

Set Development Team, run on device (NFC needs hardware).

## API documentation

Canonical reference: **[docs/LAN_API.md](../docs/LAN_API.md)**  
Architecture: **[docs/IOS_COMPANION.md](../docs/IOS_COMPANION.md)**

## Prior work

Draft branch `claude/ios-app-mvwgj` used XcodeGen (`ios/Khayt/`). Current target: `ios/KhaytCompanion/`.
