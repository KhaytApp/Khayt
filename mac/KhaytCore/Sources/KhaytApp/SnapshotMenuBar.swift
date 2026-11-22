import AppKit
import SwiftUI
import KhaytCore

/// ── THE MENU BAR ITEM AND ITS FLEET PANEL, ON THE SAMPLE ─────────────────
///
/// `KHAYT_SNAPSHOT_MENUBAR=1`: the status item's label in its four states —
/// nothing printing, one print, several, and a machine that wants somebody —
/// in each of the three styles, and the fleet popover with every rank on it
/// (a runout, a bed to clear, two prints, a quiet machine, one not answering).
///
/// The status item itself lives in the system's menu bar, which no offscreen
/// capture can see, so its label is drawn here from the same pieces the item
/// is given (`StatusGlyph.image`, `StatusGlyph.font`, `FloorRead.label`) on a
/// strip the colour of a menu bar, plain and tinted.
///
/// EVERYTHING IS IN MEMORY: the readings go where the poller would put them
/// (the sample starts no poller and asks no printer), the bed-clear verdict is
/// a dispatch plan built in place, and both are cleared at the end.
extension Snapshot {

    static func captureMenuBar(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        await settle()
        defer { shop.printers.clearReadingsForTesting(); shop.dispatch = nil }

        // A midday clock, so a finish time is not pushed past midnight by when
        // the run happens to start.
        let now = Calendar.book.date(bySettingHour: 13, minute: 5, second: 0, of: Date()) ?? Date()

        for scene in MenuBarScene.allCases {
            plant(scene, on: shop)
            await settle()
            let lines = FloorRead.lines(shop)
            let strips = MenuBarStyle.allCases.map { style in
                (style, FloorRead.label(lines, style: style, words: shop.words))
            }
            captureView(named: "mb-label-\(scene.rawValue)\(tag)",
                        StatusLabelSheet(strips: strips, words: shop.words, dark: dark)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
            if scene == .attention || scene == .several {
                let jobs = await FloorRead.jobs(shop, lines: lines)
                captureView(named: "mb-popover-\(scene.rawValue)\(tag)",
                            FloorPanel(shop: shop, jobs: jobs, now: now)
                                .background(dark ? Color(white: 0.17) : Color(white: 0.96))
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .environment(\.layoutDirection, Direction.rtlLanguages.contains(shop.words.language)
                                             ? .rightToLeft : .leftToRight)
                                .modifier(ShopsLocale(words: shop.words)),
                            into: dir)
            }
        }
    }

    enum MenuBarScene: String, CaseIterable {
        case idle, one, several, attention
    }

    /// Put one scene's readings in place, replacing the last scene's.
    static func plant(_ scene: MenuBarScene, on shop: Shop) {
        shop.printers.clearReadingsForTesting()
        shop.dispatch = nil
        func reading(_ status: KhaytEngine.PrinterStatus) -> PrinterWatch.Reading {
            PrinterWatch.Reading(status: status, problem: nil, at: Date(), lastGood: status)
        }
        let kings = KhaytEngine.PrinterStatus(
            state: "printing", progress: 64, progressSource: "layers", filename: "museum-kings-relief.3mf",
            timeRemaining: 62 * 60 + 10, tempNozzle: 220, tempBed: 60, type: "bambu")
        let brackets = KhaytEngine.PrinterStatus(
            state: "printing", progress: 88, progressSource: "layers", filename: "shelf-brackets-x24.gcode",
            timeRemaining: 25 * 60, tempNozzle: 230, tempBed: 85, type: "prusalink")
        let replica = KhaytEngine.PrinterStatus(
            state: "printing", progress: 31, progressSource: "layers", filename: "najd-tower-replica.gcode",
            timeRemaining: 4 * 3600 + 10 * 60, tempNozzle: 215, tempBed: 60, type: "moonraker")
        switch scene {
        case .idle:
            break
        case .one:
            shop.printers.setReadingForTesting("MACH-x1c", reading(kings))
        case .several:
            shop.printers.setReadingForTesting("MACH-x1c", reading(kings))
            shop.printers.setReadingForTesting("MACH-core-one", reading(brackets))
            shop.printers.setReadingForTesting("MACH-u1", reading(replica))
        case .attention:
            shop.printers.setReadingForTesting("MACH-x1c", reading(kings))
            shop.printers.setReadingForTesting("MACH-core-one", reading(brackets))
            var runout = KhaytEngine.PrinterStatus(
                state: "paused", progress: 48, progressSource: "layers", filename: "najd-tower-replica.gcode",
                timeRemaining: 2.6 * 3600, tempNozzle: 215, tempBed: 60, type: "moonraker")
            runout.filamentOut = true
            shop.printers.setReadingForTesting("MACH-u1", reading(runout))
            // Idle with the last print still on the plate.
            shop.printers.setReadingForTesting("MACH-LASER", reading(KhaytEngine.PrinterStatus(
                state: "standby", progress: 0, progressSource: nil, filename: "",
                timeRemaining: nil, tempNozzle: nil, tempBed: nil, type: "moonraker")))
            shop.dispatch = try? JSONDecoder().decode(KhaytEngine.DispatchPlan.self, from: Data(
                #"{"proposals":[],"idle":[],"waiting":[{"machineId":"MACH-LASER","blocked":"ad.bed_not_clear"}]}"#.utf8))
            // Asked three times and silent.
            shop.printers.setReadingForTesting("MACH-UVFLAT", PrinterWatch.Reading(
                status: nil, problem: shop.words.callIt("mac.attn_state_offline"), at: Date(),
                consecutiveFailures: 3))
        }
    }
}

/// The status item's label as the menu bar would draw it, one strip per style:
/// plain, and tinted the way a selected or accent-tinted menu bar draws a
/// template image.
private struct StatusLabelSheet: View {
    let strips: [(MenuBarStyle, FloorRead.Label)]
    let words: Words
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(strips, id: \.0.rawValue) { style, label in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: words.callIt(style.wordKey))
                        .font(.caption2).foregroundStyle(dark ? Color.white.opacity(0.6) : Color.black.opacity(0.55))
                    HStack(spacing: 10) {
                        StatusLabel(label: label, ink: dark ? .white : .black)
                            .background(dark ? Color(white: 0.13) : Color(white: 0.90))
                        // Selected: the system inverts a template image.
                        StatusLabel(label: label, ink: dark ? .black : .white)
                            .background(dark ? Color(white: 0.85) : Color(white: 0.35))
                        StatusLabel(label: label, ink: .white)
                            .background(Color(red: 0.16, green: 0.36, blue: 0.68))
                    }
                }
            }
        }
        .padding(12)
        .background(dark ? Color(white: 0.08) : Color.white)
        .environment(\.layoutDirection, Direction.rtlLanguages.contains(words.language) ? .rightToLeft : .leftToRight)
    }
}

/// One status item: the template glyph and the text beside it, in the item's
/// own font, at the menu bar's 24 pt height.
private struct StatusLabel: View {
    let label: FloorRead.Label
    let ink: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: StatusGlyph.image(ring: label.ring, attention: label.attention))
                .renderingMode(.template)
            if !label.text.isEmpty {
                Text(verbatim: label.text).font(Font(StatusGlyph.font))
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .frame(height: 24)
    }
}
