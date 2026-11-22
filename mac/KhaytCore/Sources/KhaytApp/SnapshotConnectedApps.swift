import AppKit
import SwiftUI
import KhaytCore

/// ── THE CONNECTED APPS SECTION, ON THE SAMPLE, IN MEMORY ─────────────────
///
/// Figma Qqxg4imtKVgC3TfNGcRGOk page 16: the screen with two paired slicers
/// and three files waiting (B), nothing paired (C), the Settings pointer (E),
/// and the sidebar row (A), in whichever appearance and language the run was
/// started in. The sample has no slicers and no inbox, so both are made up
/// here, in memory: nothing is paired, nothing is written, and the flag is set
/// for this run only.
///
/// `KHAYT_SNAPSHOT_APPS=1` runs only these.
extension Snapshot {

    static func captureConnectedApps(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = (dark ? "-dark" : "-light") + "-" + shop.words.language
        await shop.load(.sample)
        LanConnectorPairing.enabledForTests = true
        // As on a Mac whose LAN server listens on the network: Pair a slicer enabled.
        PairAPhone.pretendReachable = true
        defer {
            PairAPhone.pretendReachable = false
            LanConnectorPairing.enabledForTests = false
            shop.slicerUploads = []
            shop.connectedApps = []
        }
        await settle()
        let rtl = Direction.rtlLanguages.contains(shop.words.language)
        func shot(_ name: String, width: CGFloat, _ view: some View) {
            captureView(named: "apps-\(name)\(tag)",
                        view.frame(width: width, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
        }

        // C: nothing paired, nothing waiting.
        shot("c-empty", width: 960, ConnectedAppsScreen(shop: shop, refreshes: false, scrolls: false))

        // B: the frame's sample — two slicers, three files (two from a plugin, one by OctoPrint).
        let now = Date()
        let studio = "dev_SampleStudioPC0001", bench = "dev_SampleBenchiMac001"
        shop.connectedApps = [
            LanDevices.Listed(id: studio, name: "OrcaSlicer on Studio PC", createdAt: now.addingTimeInterval(-86400 * 3),
                              lastSeenAt: now, kind: LanDevices.kindConnector),
            LanDevices.Listed(id: bench, name: "OrcaSlicer on Bench iMac", createdAt: now.addingTimeInterval(-86400 * 9),
                              lastSeenAt: now.addingTimeInterval(-86400 * 2), kind: LanDevices.kindConnector),
        ]
        func file(_ id: String, _ name: String, grams: Double, minutes: Double, material: String,
                  from: String?, intent: String?, machine: String? = nil) -> SlicerUpload {
            var u = SlicerUpload(id: id, name: name, arrived: now.addingTimeInterval(-Double(id.count) * 300),
                                 bytes: 2_400_000, grams: grams, minutes: minutes, material: material,
                                 slicer: "OrcaSlicer")
            if let from {
                u.source = "connector"; u.connectorId = from; u.connectorName = "OrcaSlicer on Studio PC"
                var s: [String: JSONValue] = ["intent": .string(intent ?? "inbox")]
                if let machine { s["machineId"] = .string(machine) }
                u.suggested = .object(s)
            }
            return u
        }
        shop.slicerUploads = [
            file("su-a", "Bracket_PLA.gcode", grams: 12.3, minutes: 62, material: "PLA", from: studio, intent: "quote"),
            file("su-bb", "Hinge_PETG_0.2mm.gcode", grams: 38, minutes: 161, material: "PETG", from: studio,
                 intent: "print", machine: "m_1"),
            file("su-ccc", "Plate_3.gcode.3mf", grams: 57, minutes: 250, material: "PLA", from: nil, intent: nil),
        ]
        await settle()
        shot("b-screen", width: 960, ConnectedAppsScreen(shop: shop, refreshes: false, scrolls: false))

        // Page 24: the same screen with "Show prices in OrcaSlicer" off (as
        // above, B), then on with a grant per slicer.
        shop.connectorPricesOn = true
        shop.connectedApps[0].priceGrant = "price"
        await settle()
        shot("f-prices-on", width: 960, ConnectedAppsScreen(shop: shop, refreshes: false, scrolls: false))
        shop.connectedApps[0].priceGrant = "cost"
        await settle()
        shot("g-prices-cost", width: 960, ConnectedAppsScreen(shop: shop, refreshes: false, scrolls: false))
        shop.connectedApps[0].priceGrant = nil
        shop.connectorPricesOn = false
        await settle()

        // E: Settings ▸ Online keeps only a pointer.
        shot("e-pointer", width: 560, Form { ConnectedAppsPointer(shop: shop) }.formStyle(.grouped).frame(height: 90))

        // D: the same screen in Arabic, right to left (Figma frame D).
        if shop.words.language != "ar" {
            let was = shop.words.language
            await shop.words.load("ar", engine: shop.engine)
            await settle()
            captureView(named: "apps-d-screen\(dark ? "-dark" : "-light")-ar",
                        ConnectedAppsScreen(shop: shop, refreshes: false, scrolls: false)
                            .frame(width: 960, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, .rightToLeft)
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
            await shop.words.load(was, engine: shop.engine)
        }

        // A: the sidebar, with the row and its count. Selecting the shelf
        // shows the real screen in the live window, which reads the sample's
        // (empty) slicers and inbox: the in-memory ones go back after it.
        let apps = shop.connectedApps, uploads = shop.slicerUploads
        shop.shelf = .connectedApps
        await settle()
        shop.connectedApps = apps
        shop.slicerUploads = uploads
        shot("a-sidebar", width: Wide.sidebar, ShellSidebar(shop: shop).frame(height: 760))
        shop.shelf = .jobs(nil)
    }
}
