# Xcode setup (paid Apple Developer account)

For **Apple Developer Program** members (Individual or Organization). Free Personal Teams: use empty `KhaytCompanion.entitlements` — see git history or omit NFC capability.

## 1. Pull latest project

```bash
cd ~/Khayt
git pull origin cursor/ios-companion-app-2e93
open ios/KhaytCompanion.xcodeproj
```

## 2. Signing (one time)

1. **KhaytCompanion** target → **Signing & Capabilities**
2. **Team:** your paid team (your name — **not** “Personal Team” if that’s the free one)
3. **Bundle Identifier:** e.g. `com.yourname.khayt.companion` (must be unique in your account)
4. **Automatically manage signing:** ON

Xcode should show a green checkmark. If not, click **Try Again** or **Register Device**.

## 3. Register your iPhone (fixes “no devices” error)

1. Connect iPhone with USB, unlock, tap **Trust This Computer**
2. **Window → Devices and Simulators** — phone should appear without a warning
3. Top bar → select **your iPhone** as run destination (not “Any iOS Device”)

First install: iPhone → **Settings → General → VPN & Device Management** → trust your developer certificate.

## 4. NFC capability

The project includes **Near Field Communication Tag Reading** in `KhaytCompanion.entitlements`.

If Xcode doesn’t show it:

1. **Signing & Capabilities** → **+ Capability**
2. Add **Near Field Communication Tag Reading**
3. Check formats **NDEF** and **TAG**

Paid accounts can use NFC on a **physical iPhone** (not Simulator).

## 5. Build and run

1. Select your **iPhone** (for NFC) or **Simulator** (queue/inventory only)
2. **Product → Clean Build Folder** (⇧⌘K)
3. **⌘R**

## 6. Test with Khayt desktop

Same Wi‑Fi as your Mac running Khayt:

- LAN API **on**, **all interfaces**, **owner PIN** set
- Mac IP: `ipconfig getifaddr en0`
- Companion app → pair → Queue / Scan NFC

## Common paid-account issues

| Issue | Fix |
|-------|-----|
| Wrong team selected | Use the **paid** team (Program membership), not free Personal Team |
| Provisioning failed | Unique bundle ID; connect phone; Register Device in Xcode |
| NFC session fails at runtime | Run on **device**, enable NFC capability, use entitlements file with NDEF+TAG |
| Build still fails | **⌘9** → copy first red error line |

## Optional: Simulator only

Simulator does not need device registration. NFC will not work; use iPhone for spool scanning.
