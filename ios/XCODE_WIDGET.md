# Khayt home screen widget

The **Khayt Queue** widget is built into the app — the Widget Extension target
(`KhaytWidgetExtension`) is already configured in `KhaytCompanion.xcodeproj`, so
it ships automatically when you build and run. No manual Xcode setup is needed.

## Add it to your home screen

1. Build & run the app on your device and pair it with the desktop (Settings → LAN).
2. Long-press an empty area of the home screen → tap **+** (top-left).
3. Search for **Khayt** and pick a size:
   - **Small** — queue / printing / done counts, or the top print's progress.
   - **Medium** — counts plus the active prints with progress bars and ETA.
   - **Lock screen (rectangular)** — the top print's progress and ETA.
4. Tap **Add Widget**.

The widget reads a shared snapshot (App Group `group.com.khaytapp.companion`)
that the app writes whenever it's open and on each LAN health refresh: shop name,
pipeline counts, connection state, and live printer progress from
`/api/machines/live`. Open the app on your shop Wi‑Fi to refresh it.

## How it's wired (for maintainers)

- Source: `ios/KhaytWidget/KhaytQueueWidget.swift` (+ `Info.plist`, `KhaytWidget.entitlements`).
- The app writes the snapshot via `WidgetSnapshotStore` (`KhaytCompanion/Services/`).
- Both targets carry the `group.com.khaytapp.companion` App Group entitlement.
