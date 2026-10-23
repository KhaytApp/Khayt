import AppKit
import SwiftUI
import KhaytCore

/// ── THE BETA.5 SCREENS, ON THE SAMPLE, IN MEMORY ────────────────────────
///
/// Live printer cards (a runout, a Bambu's controls, a protocol with none),
/// the camera on the machine sheet and a finished job's timelapse, the "Pair a
/// phone" window, and the VAT card with filed returns. None of it is reachable
/// from the sample on its own: it has no printer addresses, no camera, no LAN
/// server and no filed period.
///
/// EVERYTHING FAKED HERE IS IN MEMORY AND LASTS ONE SCENE. A machine gets an
/// address in the array the screen draws from, never in the file; a reading is
/// put in the printer cache the poller would fill; a filed period is written
/// to the settings the screen holds, through the same rule the real write
/// uses, and never to a store. The sample has no build, so every write still
/// refuses, nothing is fetched (it starts no poller and no camera), and the
/// sample is loaded again at the end of each scene.
///
/// `KHAYT_SNAPSHOT_B5=1` runs only these, in whichever appearance and language
/// the run was started in.
extension Snapshot {

    static func captureBeta5(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        shop.pretendsWritable = true
        defer {
            shop.pretendsWritable = false
            shop.pretendVatDialog = nil
            shop.pretendsControl = false
            PairAPhone.pretendReachable = false
            MachineSheet.pretendOffer = nil
            MachineSheet.pretendNote = nil
            VatSummaryCard.pretendSummary = nil
            Timelapse.pretend = [:]
            shop.printers.clearReadingsForTesting()
        }
        await machinesScene(shop, into: dir, tag: tag)
        await cameraScene(shop, into: dir, tag: tag)
        await vatScene(shop, into: dir, tag: tag)
        await settingsScene(shop, into: dir, tag: tag)
        await shop.load(.sample)
        await settle()
    }

    // MARK: - 1. The machines screen with live cards

    private static func machinesScene(_ shop: Shop, into dir: URL, tag: String) async {
        await shop.load(.sample)
        shop.pretendsWritable = true
        // Addresses in memory. The sample starts no poller (it has no build),
        // so nothing here is ever asked.
        shop.pretendMachine("MACH-u1", ["printerApi": .object([
            "type": .string("moonraker"), "host": .string("192.168.1.40"), "port": .number(7125)])])
        shop.pretendMachine("MACH-x1c", ["printerApi": .object([
            "type": .string("bambu"), "host": .string("192.168.1.52"),
            "serial": .string("01S00A000000000")])])
        // An SDCP printer with no mainboard id: the shared table says it cannot
        // be told anything, so its card says so instead of drawing buttons.
        // (Repetier is no use for this: it can cancel, so it draws Cancel.)
        shop.pretendMachine("MACH-core-one", ["printerApi": .object([
            "type": .string("sdcp"), "host": .string("192.168.1.60")])])
        shop.pretendsControl = true
        shop.shelf = .machines

        // A Klipper printer PAUSED ON A RUNOUT, with the printer's own words.
        var klipper = KhaytEngine.PrinterStatus(
            state: "paused", progress: 48, progressSource: "layers", filename: "falcon-hood-v4.gcode",
            timeRemaining: 2.6 * 3600, tempNozzle: 215, tempBed: 60, type: "moonraker")
        klipper.targetNozzle = 245; klipper.targetBed = 60
        klipper.layer = 361; klipper.totalLayers = 750
        klipper.fanPart = 0
        klipper.filamentOut = true
        klipper.message = "Filament runout on e1"
        // A Bambu PRINTING: speed preset and light menus, the reworked row.
        var bambu = KhaytEngine.PrinterStatus(
            state: "printing", progress: 62, progressSource: "layers", filename: "bracket-v3.3mf",
            timeRemaining: 1.4 * 3600, tempNozzle: 250, tempBed: 80, type: "bambu")
        bambu.targetNozzle = 250; bambu.targetBed = 80; bambu.tempChamber = 38
        bambu.layer = 212; bambu.totalLayers = 340
        bambu.fanPart = 80; bambu.speedFactor = 124
        // A printer with no control: the card draws its controls row only for
        // a job that is running or held, so an idle one draws no row at all —
        // this one is printing.
        var repetier = KhaytEngine.PrinterStatus(
            state: "printing", progress: 31, progressSource: "time", filename: "vase-spiral.gcode",
            timeRemaining: 3.1 * 3600, tempNozzle: 210, tempBed: 60, type: "sdcp")
        repetier.targetNozzle = 210; repetier.targetBed = 60
        for (id, status) in [("MACH-u1", klipper), ("MACH-x1c", bambu), ("MACH-core-one", repetier)] {
            shop.printers.setReadingForTesting(id, PrinterWatch.Reading(status: status, problem: nil, at: Date()))
        }
        // The alert the poller would have raised for the runout.
        shop.printers.notices.recordForTesting(PrinterNotice.Notice(
            machineId: "MACH-u1", machine: "Snapmaker U1", kind: "runout",
            title: shop.words.callIt("mac.alert_runout", ["machine": .string("Snapmaker U1")]),
            body: "Filament runout on e1", at: Date()))
        for type in ["moonraker", "bambu", "sdcp"] { await shop.learnPrinterVerbs(type) }
        // NO PROTOCOL THE APP SPEAKS LACKS EVERY VERB (`KhaytPrinterCommands.supports`
        // answers yes to something for all seven), so "Khayt cannot pause or cancel
        // this printer yet" is never reached by a real printer. An empty set is
        // put in place for this one card so the text can be looked at.
        shop.printerVerbs["sdcp"] = []
        await settle()
        try? await Task.sleep(for: .milliseconds(1200))
        // The cards sit in a lazy grid below the band, and a lazy grid draws
        // only what is on screen — a pane shot of the whole column leaves them
        // blank. So the window is scrolled to them and photographed as it is.
        scrollMain(to: 1.0)
        await settle()
        try? await Task.sleep(for: .milliseconds(900))
        capture(named: "b5-1-machines-live" + tag, into: dir)
        scrollMain(to: 0.62)
        await settle()
        try? await Task.sleep(for: .milliseconds(600))
        capture(named: "b5-1a-machines-live-upper" + tag, into: dir)
        scrollMain(to: 0)

        // Where the alert is kept: the dashboard's "Printer trouble".
        shop.shelf = .dashboard
        await settle()
        try? await Task.sleep(for: .milliseconds(600))
        capture(named: "b5-1b-dashboard-alert" + tag, into: dir)
        shop.printers.clearReadingsForTesting()
    }

    // MARK: - 2. The camera

    private static func cameraScene(_ shop: Shop, into dir: URL, tag: String) async {
        await shop.load(.sample)
        shop.pretendsWritable = true
        shop.pretendMachine("MACH-u1", [
            "printerApi": .object(["type": .string("moonraker"), "host": .string("192.168.1.40"),
                                   "port": .number(7125)]),
            "webcam": .object(["enabled": .bool(true),
                               "snapshotUrl": .string("http://192.168.1.40/webcam/?action=snapshot")])])
        shop.pretendsControl = true
        shop.shelf = .machines
        // A paused still: the last frame, dimmed and labelled. A generated
        // picture, never fetched.
        shop.cameras.setFrameForTesting("MACH-u1", .paused(placeholderStill()))
        await settle()
        try? await Task.sleep(for: .milliseconds(900))
        scrollMain(to: 1.0)
        await settle()
        try? await Task.sleep(for: .milliseconds(900))
        capture(named: "b5-2a-camera-paused" + tag, into: dir)
        scrollMain(to: 0)
        // The tile on its own, drawn by the renderer: the window shot cannot
        // show the label, which sits on a material the offscreen draw skips.
        captureView(named: "b5-2e-camera-tile-paused" + tag,
                    CameraTile(frame: .paused(placeholderStill()), webcam: nil, words: shop.words)
                        .frame(width: 380).padding(16)
                        .background(Khayt.ground)
                        .environment(\.colorScheme, tag.isEmpty ? .light : .dark)
                        .environment(\.layoutDirection, shop.words.isRTL ? .rightToLeft : .leftToRight),
                    into: dir)
        shop.cameras.setFrameForTesting("MACH-u1", .none)

        // The sheet's camera section with the offer a look would have made.
        guard let machine = shop.machines.first(where: { $0.id == "MACH-u1" }) else { return }
        MachineSheet.opensOn = "connection"
        MachineSheet.pretendOffer = CameraOffer(url: "http://192.168.1.40/webcam/?action=snapshot",
                                                kind: "new", answer: .live)
        shop.editingMachine = machine
        await settle()
        try? await Task.sleep(for: .milliseconds(600))
        scrollSheetToBottom()
        try? await Task.sleep(for: .milliseconds(400))
        captureSheet(named: "b5-2b-camera-offer" + tag, into: dir)
        shop.editingMachine = nil
        await settle()
        // The same, replacing a saved address that did not answer, and paused.
        MachineSheet.pretendOffer = CameraOffer(url: "http://192.168.1.40:8080/snapshot.jpg",
                                                kind: "replace", answer: .paused)
        shop.editingMachine = machine
        await settle()
        try? await Task.sleep(for: .milliseconds(600))
        scrollSheetToBottom()
        try? await Task.sleep(for: .milliseconds(400))
        captureSheet(named: "b5-2c-camera-offer-paused" + tag, into: dir)
        shop.editingMachine = nil
        MachineSheet.pretendOffer = nil
        MachineSheet.opensOn = "printer"
        await settle()

        // A finished job's timelapse, on the printer.
        shop.shelf = .jobs(nil)
        await settle()
        if let job = shop.shown.first(where: { Shop.finishedStatuses.contains($0.status) }),
           let link = try? JSONDecoder().decode(KhaytEngine.TimelapseLink.self, from: Data("""
            {"machineId":"\(job.machineId ?? "MACH-u1")","videoUrl":"http://192.168.1.40/server/files/timelapse/falcon-hood.mp4",
             "coverUrl":null,"bytes":59000000}
            """.utf8)) {
            Timelapse.pretend[job.id] = link
            shop.selection = job.id
            await settle()
            try? await Task.sleep(for: .milliseconds(900))
            capture(named: "b5-2d-timelapse" + tag, into: dir)
            capturePanes(named: "b5-2d-timelapse" + tag, into: dir)
            shop.selection = nil
            Timelapse.pretend = [:]
        }
    }

    /// The main window's tallest scroll view, to a fraction of its length.
    private static func scrollMain(to fraction: CGFloat, window: NSWindow? = nil) {
        guard let root = (window ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }))?.contentView else { return }
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView,
               doc.bounds.height > (best?.documentView?.bounds.height ?? 0), doc.bounds.width > 500 { best = s }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let s = best, let doc = s.documentView else { return }
        let room = max(0, doc.bounds.height - s.contentView.bounds.height)
        let y = doc.isFlipped ? room * fraction : room * (1 - fraction)
        s.contentView.scroll(to: NSPoint(x: 0, y: y))
        s.reflectScrolledClipView(s.contentView)
    }

    /// The Reports window's narrow right-hand column, to a point offset.
    private static func scrollColumn(to y: CGFloat) {
        guard let root = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView else { return }
        var found: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView, doc.bounds.width < 400, doc.bounds.height > 600 { found = s }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let s = found, let doc = s.documentView else { return }
        let room = max(0, doc.bounds.height - s.contentView.bounds.height)
        s.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? min(y, room) : max(0, room - y)))
        s.reflectScrolledClipView(s.contentView)
    }

    /// The sheet's own scroll view, to the end: the camera section is last.
    private static func scrollSheetToBottom() {
        guard let host = NSApp.windows.first(where: { $0.isVisible && $0.attachedSheet != nil }),
              let root = host.attachedSheet?.contentView else { return }
        var scrolls: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { scrolls.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        for s in scrolls {
            guard let doc = s.documentView else { continue }
            let y = s.documentView?.isFlipped == true ? max(0, doc.bounds.height - s.contentView.bounds.height) : 0
            s.contentView.scroll(to: NSPoint(x: 0, y: y))
            s.reflectScrolledClipView(s.contentView)
        }
    }

    /// A 640 x 360 picture of a plate with a print on it, drawn here.
    private static func placeholderStill() -> Data {
        let size = NSSize(width: 640, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.70, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 640, height: 110).fill()
        NSColor(calibratedRed: 0.78, green: 0.55, blue: 0.2, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 230, y: 95, width: 180, height: 120), xRadius: 14, yRadius: 14).fill()
        NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 300, width: 640, height: 10).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    // MARK: - 4. VAT filed periods

    private static func vatScene(_ shop: Shop, into dir: URL, tag: String) async {
        await shop.load(.sample)
        shop.pretendsWritable = true
        shop.pretendVat()
        guard let engine = shop.engine else { return }
        shop.shelf = .reports
        shop.reportPage = .profit
        let ended = await shop.vatFilingPeriods()
        guard ended.count >= 2 else {
            FileHandle.standardError.write(Data("vat: fewer than two ended periods\n".utf8))
            return
        }
        // Oldest of the two first: a later period may be filed after, not before.
        let older = ended[1].period, newer = ended[0].period

        func refresh() async {
            shop.shelf = .dashboard
            await settle()
            shop.shelf = .reports
            shop.reportPage = .profit
            await settle()
            try? await Task.sleep(for: .seconds(1))
        }
        func mark(_ period: String, filed: Bool) async throws {
            var root: [String: JSONValue] = ["settings": .object(shop.settingsDict),
                                             "printLog": .array(shop.orderRows),
                                             "clients": .array(shop.clientRows)]
            try await Shop.applyVatFiled(to: &root, period: period, filed: filed,
                                         currencies: Invoice.currencyTable(shop), engine: engine, now: Date())
            if let settings = root["settings"] { shop.settingsValue = settings }
        }

        // (a) One quarter marked filed.
        try? await mark(older, filed: true)
        await refresh()
        scrollColumn(to: 700)
        await settle()
        capture(named: "b5-4a-vat-filed" + tag, into: dir)
        capturePanes(named: "b5-4a-vat-filed" + tag, into: dir)

        // (b) The un-file question, on the quarter just filed.
        shop.pretendVatDialog = "unfile"
        await settle()
        try? await Task.sleep(for: .milliseconds(700))
        captureSheet(named: "b5-4b-vat-unfile" + tag, into: dir)
        capture(named: "b5-4b-vat-unfile-window" + tag, into: dir)
        shop.pretendVatDialog = nil
        await settle()

        // (c) A later quarter filed, then the older one refused its un-file.
        try? await mark(newer, filed: true)
        do {
            try await mark(older, filed: false)
        } catch let later as Shop.VatFiledLater {
            shop.vatFiledProblem = shop.words.callIt("mac.vat_filed_later", [
                "period": .string(MonthLabel.period(older, words: shop.words)),
                "later": .string(MonthLabel.period(later.later, words: shop.words))])
        } catch {
            FileHandle.standardError.write(Data("vat: un-file did not refuse: \(error)\n".utf8))
        }
        await refresh()
        scrollColumn(to: 700)
        await settle()
        capture(named: "b5-4c-vat-later-filed" + tag, into: dir)
        capturePanes(named: "b5-4c-vat-later-filed" + tag, into: dir)
        shop.vatFiledProblem = nil

        // (d) A reversal after filing: an invoice cancelled today lands in the
        // first open period as an adjustment. Tried on the sample's own jobs
        // first; a stand-in summary only if none of them lands one.
        let today = Calendar.book.dayString(Date())
        var found = false
        let original = shop.orderRows
        for (i, row) in original.enumerated() where !found {
            guard case .object(var o) = row, case .string(let status)? = o["status"],
                  Shop.finishedStatuses.contains(status), o["voidedAt"] == nil else { continue }
            o["status"] = .string("cancelled")
            o["cancelledAt"] = .string(today)
            o["voidedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
            var trial = original
            trial[i] = .object(o)
            shop.orderRows = trial
            if let statement = await shop.pnlStatement(), statement.vat.hasAdjustment { found = true }
            if !found { shop.orderRows = original }
            if i > 40 { break }
        }
        if !found {
            shop.orderRows = original
            FileHandle.standardError.write(Data("vat: no sample job lands an adjustment; stand-in summary\n".utf8))
            VatSummaryCard.pretendSummary = try? JSONDecoder().decode(VatSummary.self, from: Data("""
            {"applies":true,"name":"VAT","mode":"inclusive","rates":[{"label":"VAT","percent":15}],
             "sales":18420.0,"output":2402.61,"input":611.4,"net":1791.21,"position":"payable",
             "expensesWithVat":6,"expensesWithoutVat":1,
             "adjustment":-34.78,"salesAdjustment":-230.0,"adjustments":1}
            """.utf8))
        }
        await refresh()
        scrollColumn(to: 700)
        await settle()
        capture(named: "b5-4d-vat-adjustment" + tag, into: dir)
        capturePanes(named: "b5-4d-vat-adjustment" + tag, into: dir)
        VatSummaryCard.pretendSummary = nil
        shop.orderRows = original
        // The refile question, the other dialog of the card.
        shop.pretendVatDialog = "refile"
        await settle()
        try? await Task.sleep(for: .milliseconds(500))
        captureSheet(named: "b5-4e-vat-refile" + tag, into: dir)
        shop.pretendVatDialog = nil
        await settle()
    }

    // MARK: - 3 + 5. Settings: the invoice/VAT pane, and Pair a phone

    private static func settingsScene(_ shop: Shop, into dir: URL, tag: String) async {
        await shop.load(.sample)
        shop.pretendsWritable = true
        shop.pretendVat()
        shop.shelf = .dashboard
        await settle()
        let main = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        func settingsWindow() -> NSWindow? {
            NSApp.windows.first {
                $0.isVisible && $0 !== main && $0.contentView != nil
                    && $0.frame.width >= 300 && $0.frame.height >= 300
            }
        }
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
            NSApp.sendAction(item.action ?? #selector(NSApplication.terminate(_:)), to: item.target, from: item)
        }
        await settle()
        try? await Task.sleep(for: .seconds(1))
        FileHandle.standardError.write(Data("b5: enableVat in the held settings = \(SettingsReader(settings: shop.settingsDict).flag("enableVat"))\n".utf8))
        guard let settings = settingsWindow() else {
            FileHandle.standardError.write(Data("b5: no settings window\n".utf8))
            return
        }
        shop.settingsPane = .invoice
        await settle()
        capture(named: "b5-5-settings-invoice" + tag, window: settings, into: dir)
        capturePanes(named: "b5-5-settings-invoice" + tag, window: settings, into: dir)

        // Pair a phone: reachable, window shut, then open with its countdown,
        // then with a device locked out of it.
        PairAPhone.pretendReachable = true
        shop.settingsPane = .online
        await settle()
        scrollMain(to: 1.0, window: settings)
        await settle()
        capture(named: "b5-3a-pair-closed" + tag, window: settings, into: dir)
        shop.openPairing()
        await settle()
        try? await Task.sleep(for: .milliseconds(1200))
        scrollMain(to: 1.0, window: settings)
        await settle()
        capture(named: "b5-3b-pair-open" + tag, window: settings, into: dir)
        for _ in 0..<LanPairingWindow.perAddress { shop.lanPairing.noteWrong(from: "192.168.1.77") }
        await settle()
        try? await Task.sleep(for: .milliseconds(600))
        scrollMain(to: 1.0, window: settings)
        await settle()
        capture(named: "b5-3c-pair-locked" + tag, window: settings, into: dir)
        shop.closePairing()
        PairAPhone.pretendReachable = false
        settings.close()
        await settle()
    }
}

extension Shop {
    /// Merge fields into one machine, in memory: the array the screens draw
    /// from and the rows the rules are handed, decoded the way the store is.
    func pretendMachine(_ id: String, _ fields: [String: JSONValue]) {
        guard let at = machineRows.firstIndex(where: { Self.recordId($0) == id }),
              case .object(var row) = machineRows[at] else { return }
        for (key, value) in fields { row[key] = value }
        let merged = JSONValue.object(row)
        guard let data = try? JSONEncoder().encode(merged),
              let machine = try? JSONDecoder().decode(Machine.self, from: data),
              let slot = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[slot] = machine
        machineRows[at] = merged
    }

    /// VAT on, quarterly, in the settings this screen holds. Not written.
    func pretendVat() {
        var held = settingsDict
        held["enableVat"] = .bool(true)
        held["vatRate"] = .number(15)
        held["vatFilingFrequency"] = .string("quarterly")
        settingsValue = .object(held)
    }
}
