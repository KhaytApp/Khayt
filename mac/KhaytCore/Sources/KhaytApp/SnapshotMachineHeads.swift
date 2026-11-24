import AppKit
import SwiftUI
import KhaytCore

/// `KHAYT_SNAPSHOT_HEADS=1`: the machine sheet's "Loaded on this printer" and
/// "Tool N — which spool is this?" (Figma page 25, frames 1 and 2). Made-up
/// tags and spools in memory, matched by the real rule; nothing is read from
/// a printer or written to a book.
extension Snapshot {

    static func captureMachineHeads(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = (dark ? "-dark" : "-light") + "-" + shop.words.language
        await shop.load(.sample)
        await settle()
        let rtl = Direction.rtlLanguages.contains(shop.words.language)
        func shot(_ name: String, width: CGFloat, _ view: some View) {
            captureView(named: "heads-\(name)\(tag)",
                        view.frame(width: width, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
        }

        guard let engine = shop.engine else { return }
        func spoolTag(_ type: String, _ sub: String, _ rgb: Int, grams: Int) -> JSONValue {
            .object(["VERSION": .number(1), "VENDOR": .string("Snapmaker"), "MANUFACTURER": .string("Snapmaker"), "MAIN_TYPE": .string(type),
                     "SUB_TYPE": .string(sub), "COLOR_NUMS": .number(1), "RGB_1": .number(Double(rgb)), "DIAMETER": .number(175),
                     "WEIGHT": .number(Double(grams)), "LENGTH": .number(330), "SKU": .number(1), "OFFICIAL": .bool(true)])
        }
        let none: JSONValue = .object(["VERSION": .number(0), "VENDOR": .string("NONE"), "MANUFACTURER": .string("NONE"), "MAIN_TYPE": .string("NONE"),
                                       "SUB_TYPE": .string("NONE"), "RGB_1": .number(16777215)])
        let detect: JSONValue = .object(["info": .array([spoolTag("PLA", "NONE", 0x111111, grams: 1000), spoolTag("PETG", "NONE", 0xF5F5F5, grams: 1000), none, none])])
        func spool(_ id: String, _ brand: String, _ material: String, _ colour: String, _ left: Double) -> JSONValue {
            .object(["id": .string(id), "brand": .string(brand), "material": .string(material), "color": .string(colour), "weight": .number(left)])
        }
        // Frame 1: tool 1 linked, tool 2 like nothing on the shelf, tool 3 set on the printer, tool 4 empty.
        let shelf1 = [spool("S2", "Snapmaker", "PLA", "#111111", 640), spool("S5", "", "ABS", "#FF3B30", 300)]
        shop.trayBookForTests = ["inventory": .array(shelf1), "machines": .array([])]
        let loaded: JSONValue = .array([.object(["slot": .number(2), "hex": .string("#FF3B30"), "material": .string("PLA")])])
        if let rows = try? await engine.machineHeads(filamentDetect: detect, loaded: loaded, spools: shelf1, linked: .object(["0": .string("S2")])) {
            shot("1-loaded", width: 680, MachineHeadsSection(shop: shop, machineId: "snapshot", pretend: rows).padding(20))
        }
        // Frame 2: tool 2's tag, a best match and a near one, and "Add as a new spool".
        let shelf2 = shelf1 + [spool("S7", "Snapmaker", "PETG", "#F5F5F5", 1000), spool("S9", "Other", "PETG", "#F5F5F5", 220)]
        shop.trayBookForTests = ["inventory": .array(shelf2), "machines": .array([])]
        if let rows = try? await engine.machineHeads(filamentDetect: detect, loaded: loaded, spools: shelf2, linked: .object(["0": .string("S2")])),
           rows.count > 1 {
            // The sheet sets its own width (its content's 520 and its margins); the camera only gives it room.
            shot("2-link", width: 600, LinkHeadSheet(shop: shop, machineId: "snapshot", row: rows[1], adding: false) {})
        }
        shop.trayBookForTests = nil
    }
}
