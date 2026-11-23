import AppKit
import SwiftUI
import KhaytCore

/// ── PRINTER BATCH 1, ON THE SAMPLE, IN MEMORY ─────────────────────────────
///
/// Figma Qqxg4imtKVgC3TfNGcRGOk page 23: the seven state chips (frame 3), the
/// send sheet's checks with a warning, a head not reported and the stop case
/// (frames 1 and 1b), and Roles ▸ PRINTERS (frame 2). Sample findings, made
/// up here: nothing is sent to a printer and nothing is written.
///
/// `KHAYT_SNAPSHOT_BATCH1=1` runs only these.
extension Snapshot {

    static func captureBatch1(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = (dark ? "-dark" : "-light") + "-" + shop.words.language
        await shop.load(.sample)
        await settle()
        let rtl = Direction.rtlLanguages.contains(shop.words.language)
        func shot(_ name: String, width: CGFloat, _ view: some View) {
            captureView(named: "batch1-\(name)\(tag)",
                        view.padding(20).frame(width: width, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
        }
        func finding(_ json: String) -> KhaytEngine.SendFinding? {
            try? JSONDecoder().decode(KhaytEngine.SendFinding.self, from: Data(json.utf8))
        }

        // Frame 3: the seven chips, in the frame's order.
        shot("chips", width: 620, HStack(spacing: 8) {
            ForEach(KhaytEngine.MachineChip.allCases, id: \.self) { MachineStateChip(chip: $0, words: shop.words) }
        })

        // Frame 1: a fit, a wrong material and a head the printer did not report.
        let bed = KhaytEngine.SendFinding.Size(x: 270, y: 270, z: 270)
        let warned = [
            finding(##"{"code":"material-mismatch","severity":"warn","slot":2,"want":{"type":"PLA","colour":"#000000"},"have":{"material":"PETG","colour":"#FFFFFF"}}"##),
            finding(#"{"code":"head-not-reported","severity":"info","slot":4}"#),
        ].compactMap { $0 }
        shot("send-checks", width: 560,
             SendChecksRows(findings: warned, fits: nil, printer: "Workshop U1", bounds: nil, bed: bed, words: shop.words))

        // Frame 1b: the stop case.
        let stop = [finding(#"{"code":"bed-footprint","severity":"block","over":{"x":30,"y":0,"z":0}}"#)].compactMap { $0 }
        shot("send-stop", width: 560,
             SendChecksRows(findings: stop, fits: nil, printer: "Workshop U1",
                            bounds: .init(x: 300, y: 210, z: 40), bed: bed, words: shop.words))

        // Frame 2: Roles ▸ PRINTERS.
        shot("roles", width: 620, PrinterRolesSheet(shop: shop))
    }
}
