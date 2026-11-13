import AppKit
import SwiftUI
import KhaytCore

/// ── THE MENU BAR ITEM AND ITS FLEET PANEL, ON THE SAMPLE ─────────────────
///
/// `KHAYT_SNAPSHOT_MENUBAR=1`: the status item's label in every state —
/// nothing printing, one print, several, a machine that wants somebody, just
/// finished — in each of the three styles, and the panel in every state it
/// has: the hero with one print and with several, a runout and a pause as the
/// hero, an old reading (the estimate), the finish moment and the row it
/// settles to (each with "Mark printed", and the row without it), and the
/// empty floor with a job waiting, one overdue, one due later, and none. Run it
/// three times for light, dark (`KHAYT_SNAPSHOT_DARK=1`) and Arabic
/// (`KHAYT_LANG=ar`).
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
        defer {
            shop.printers.clearReadingsForTesting(); shop.dispatch = nil
            shop.lastPrintEnded = [:]; shop.lastPrintEndedAt = [:]
            shop.pretendsControl = false
        }

        // A midday clock, so a finish time is not pushed past midnight by when
        // the run happens to start.
        let now = Calendar.book.date(bySettingHour: 13, minute: 5, second: 0, of: Date()) ?? Date()

        // SO THE ACTIONS CAN BE LOOKED AT. The sample's machines have no
        // connection, so no card would ever draw Pause or Camera. In memory
        // only, as the beta.5 scenes do it: a protocol whose verbs the shared
        // table knows, and a camera's address nothing is ever fetched from
        // (the panel's Camera button opens the machine; it draws no still).
        // NOTHING IS SENT: a capture run presses no button.
        for id in ["MACH-x1c", "MACH-u1", "MACH-core-one"] {
            shop.pretendMachine(id, [
                "printerApi": .object(["type": .string("moonraker"), "host": .string("192.168.1.40"),
                                       "port": .number(7125)]),
                "webcam": .object(["enabled": .bool(id != "MACH-core-one"),
                                   "snapshotUrl": .string("http://192.168.1.40/webcam/?action=snapshot")])])
        }
        shop.pretendsControl = true
        await shop.learnPrinterVerbs("moonraker")

        func panel(_ name: String, jobs: [String: Order], holds: [String: Date] = [:], queue: [Order]? = nil) {
            captureView(named: "mb-panel-\(name)\(tag)",
                        FloorPanel(shop: shop, jobs: jobs, now: now, holds: holds, queue: queue)
                            .background(dark ? Color(white: 0.17) : Color(white: 0.96))
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, Direction.rtlLanguages.contains(shop.words.language)
                                         ? .rightToLeft : .leftToRight)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
        }

        for scene in MenuBarScene.allCases {
            plant(scene, on: shop, at: now)
            await settle()
            let lines = FloorRead.lines(shop)
            let strips = MenuBarStyle.allCases.map { style in
                (style, FloorRead.label(lines, style: style, words: shop.words))
            }
            captureView(named: "mb-label-\(scene.rawValue)\(tag)",
                        StatusLabelSheet(strips: strips, words: shop.words, dark: dark)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
            let jobs = await FloorRead.jobs(shop, lines: lines)
            panel(scene.rawValue, jobs: jobs)
            if scene == .free {
                // The same floor with nothing waiting.
                panel("free-nothing-queued", jobs: jobs, queue: [])
                // And with the next job late, and not late: the sample's dates
                // move with the calendar, so each is picked by what it is.
                let waiting = shop.orders.filter { $0.status == "pending" || $0.status == "queued" }
                let start = Calendar.book.startOfDay(for: now)
                let late = waiting.filter { Order.day($0.dueDate).map { $0 < start } ?? false }
                let ahead = waiting.filter { Order.day($0.dueDate).map { $0 >= start } ?? false }
                if !late.isEmpty { panel("free-overdue", jobs: jobs, queue: late) }
                if !ahead.isEmpty { panel("free-due-later", jobs: jobs, queue: ahead) }
            }
        }

        // THE FINISH MOMENT. Two were printing and one has just finished: the
        // seam has said so (`lastPrintEnded`), the printer reads complete, and
        // the panel is holding its green. Then the same floor once the hold
        // has run out: an ordinary "Finished" row.
        plant(.several, on: shop, at: now)
        shop.printers.setReadingForTesting("MACH-core-one", PrinterWatch.Reading(
            status: KhaytEngine.PrinterStatus(
                state: "complete", progress: 100, progressSource: "layers", filename: "shelf-brackets-x24.gcode",
                timeRemaining: nil, tempNozzle: 40, tempBed: 30, type: "moonraker"),
            problem: nil, at: now))
        shop.lastPrintEnded["MACH-core-one"] = FinishCamera.Ended(
            machineId: "MACH-core-one", machineName: "Prusa CORE One", orderId: "ORD-01014",
            outcome: "finished", durationS: 3 * 3600 + 120, photoTaken: false, filename: "shelf-brackets-x24.gcode")
        shop.lastPrintEndedAt["MACH-core-one"] = now.addingTimeInterval(-4)
        await settle()
        let lines = FloorRead.lines(shop)
        let jobs = await FloorRead.jobs(shop, lines: lines)
        panel("finish-moment", jobs: jobs, holds: ["MACH-core-one": now.addingTimeInterval(FloorRead.cardHold)])
        panel("finish-settled", jobs: jobs)
        // The same row for somebody who may not move jobs: no "Mark printed".
        shop.pretendsControl = false
        panel("finish-settled-no-button", jobs: jobs)
        shop.pretendsControl = true
        // And the item for that short while: the closed ring with its tick.
        let ticked = MenuBarStyle.allCases.map { style in
            (style, FloorRead.label(lines, style: style, words: shop.words,
                                    tickUntil: now.addingTimeInterval(FloorRead.iconHold), now: now))
        }
        captureView(named: "mb-label-finished\(tag)",
                    StatusLabelSheet(strips: ticked, words: shop.words, dark: dark)
                        .modifier(ShopsLocale(words: shop.words)),
                    into: dir)
    }

    enum MenuBarScene: String, CaseIterable {
        case idle, one, several, attention
        /// A print stopped by a runout, alone: the hero leads with Resume.
        case runout
        /// A print somebody paused, alone.
        case paused
        /// One print whose reading is old: the time left is an estimate.
        case stale
        /// Every machine answering and empty: "All 5 plates are free".
        case free
    }

    /// Put one scene's readings in place, replacing the last scene's. `at` is
    /// when the readings were taken: the snapshot's fixed clock, so the time
    /// left is not counted down by however long ago midday was.
    static func plant(_ scene: MenuBarScene, on shop: Shop, at: Date = Date()) {
        shop.printers.clearReadingsForTesting()
        shop.dispatch = nil
        shop.lastPrintEnded = [:]
        shop.lastPrintEndedAt = [:]
        func reading(_ status: KhaytEngine.PrinterStatus, age: TimeInterval = 0) -> PrinterWatch.Reading {
            PrinterWatch.Reading(status: status, problem: nil, at: at.addingTimeInterval(-age), lastGood: status)
        }
        var kings = KhaytEngine.PrinterStatus(
            state: "printing", progress: 64, progressSource: "layers", filename: "museum-kings-relief.3mf",
            timeRemaining: 62 * 60 + 10, tempNozzle: 220, tempBed: 60, type: "bambu",
            loaded: [.init(slot: 0, hex: "#C8A97E", material: "PLA"), .init(slot: 1, hex: "#EDE3D2", material: "PLA"),
                     .init(slot: 2, hex: "#3B2F22", material: "PLA")])
        kings.layer = 212; kings.totalLayers = 330
        let brackets = KhaytEngine.PrinterStatus(
            state: "printing", progress: 88, progressSource: "layers", filename: "shelf-brackets-x24.gcode",
            timeRemaining: 25 * 60, tempNozzle: 230, tempBed: 85, type: "prusalink")
        let replica = KhaytEngine.PrinterStatus(
            state: "printing", progress: 31, progressSource: "layers", filename: "najd-tower-replica.gcode",
            timeRemaining: 4 * 3600 + 10 * 60, tempNozzle: 215, tempBed: 60, type: "moonraker")
        let standby = KhaytEngine.PrinterStatus(
            state: "standby", progress: 0, progressSource: nil, filename: "",
            timeRemaining: nil, tempNozzle: nil, tempBed: nil, type: "moonraker")
        switch scene {
        case .idle:
            break
        case .one:
            shop.printers.setReadingForTesting("MACH-x1c", reading(kings))
        case .stale:
            // Read 45 seconds ago: four polls have gone by without an answer
            // being recorded, so the minutes are this Mac's own subtraction.
            shop.printers.setReadingForTesting("MACH-x1c", reading(kings, age: 45))
        case .several:
            shop.printers.setReadingForTesting("MACH-x1c", reading(kings))
            shop.printers.setReadingForTesting("MACH-core-one", reading(brackets))
            shop.printers.setReadingForTesting("MACH-u1", reading(replica))
        case .runout, .paused:
            var held = KhaytEngine.PrinterStatus(
                state: "paused", progress: 48, progressSource: "layers", filename: "najd-tower-replica.gcode",
                timeRemaining: 2.6 * 3600, tempNozzle: 215, tempBed: 60, type: "moonraker")
            held.layer = 361; held.totalLayers = 750
            if scene == .runout { held.filamentOut = true }
            shop.printers.setReadingForTesting("MACH-u1", reading(held))
            shop.printers.setReadingForTesting("MACH-x1c", reading(standby))
            shop.printers.setReadingForTesting("MACH-core-one", reading(standby))
        case .free:
            for machine in shop.machinesInUse {
                shop.printers.setReadingForTesting(machine.id, reading(standby))
            }
        case .attention:
            shop.printers.setReadingForTesting("MACH-x1c", reading(kings))
            shop.printers.setReadingForTesting("MACH-core-one", reading(brackets))
            var runout = KhaytEngine.PrinterStatus(
                state: "paused", progress: 48, progressSource: "layers", filename: "najd-tower-replica.gcode",
                timeRemaining: 2.6 * 3600, tempNozzle: 215, tempBed: 60, type: "moonraker")
            runout.filamentOut = true
            shop.printers.setReadingForTesting("MACH-u1", reading(runout))
            // Idle with the last print still on the plate.
            shop.printers.setReadingForTesting("MACH-LASER", reading(standby))
            shop.dispatch = try? JSONDecoder().decode(KhaytEngine.DispatchPlan.self, from: Data(
                #"{"proposals":[],"idle":[],"waiting":[{"machineId":"MACH-LASER","blocked":"ad.bed_not_clear"}]}"#.utf8))
            // Asked three times and silent.
            shop.printers.setReadingForTesting("MACH-UVFLAT", PrinterWatch.Reading(
                status: nil, problem: shop.words.callIt("mac.attn_state_offline"), at: at,
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
            Image(nsImage: StatusGlyph.image(ring: label.ring, attention: label.attention, tick: label.tick))
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
