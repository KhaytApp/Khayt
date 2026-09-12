import Testing
import SwiftUI
import AppKit
import KhaytCore
@testable import KhaytApp

/// Renders the interface to PNGs so it can be looked at.
///
/// Not assertions about pixels — a screenshot test that fails on a one-pixel
/// shift is a chore, not a guard. This exists because judging a design by
/// reading its source is guessing, and `screencapture` needs a screen-recording
/// grant this process does not have.
///
/// Writes to KHAYT_SNAPSHOT_DIR when set, and does nothing otherwise, so it
/// costs nothing on a normal run.
///
/// WITH the directory set, the process crashes on the way out — "no current
/// update to enqueue action to", from inside SwiftUI, after every test has
/// passed and every picture is written. It predates the sheet renders below
/// and CI never sets the variable. Read the PNGs, not the exit code.
@Suite @MainActor struct SnapshotTests {

    static var outputDir: URL? {
        ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func renderDark(_ view: some View, _ name: String, size: CGSize) throws {
        try render(view.environment(\.colorScheme, .dark)
                       .background(Khayt.ground)
                       .environment(\.colorScheme, .dark),
                   name, size: size)
    }

    func render(_ view: some View, _ name: String, size: CGSize) throws {
        guard let dir = Self.outputDir else { return }
        // ── AND THE WRITING DIRECTION, WHICH THIS DID NOT SET ─────────────
        //
        // `KHAYT_LANG=ar` switched the WORDS and nothing else, so every Arabic
        // picture this harness has ever written showed Arabic text in a
        // left-to-right layout: the title still on the left, the trailing
        // figure still on the right, an `HStack` of buttons still in English
        // order. That is not a picture of the Arabic app, and it is a
        // convincing one — the words are right, so nothing looks wrong.
        //
        // `Direction` already owns the question for the real window; this asks
        // it the same way rather than testing the variable a second time.
        let rtl = Direction.rtlLanguages.contains(Direction.shopLanguage())
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .light)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("could not render \(name)")
            return
        }
        try png.write(to: dir.appending(path: name + ".png"))
        expectInkInTheMiddle(rep, name)
        expectItRendered(rep, name)
    }

    /// Did `ImageRenderer` actually render this, or refuse it?
    ///
    /// What it draws for a view it cannot host is a flat yellow field with a
    /// red "no entry" sign across it — and `01-shop` was that, edge to edge,
    /// for as long as this file has existed: `ImageRenderer` will not host a
    /// `NavigationSplitView`, so the picture of the whole window was a picture
    /// of nothing, and it passed every run because writing a PNG cannot fail on
    /// what is not in it. The placeholder is a specific colour, so say so.
    private func expectItRendered(_ rep: NSBitmapImageRep, _ name: String) {
        var placeholder = 0, seen = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen += 1
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                // The field is around #FFCC00 and the sign around #F5333F.
                if a > 0.5, r > 0.9, b < 0.35, g > 0.7 || (g < 0.35 && r > 0.9) { placeholder += 1 }
            }
        }
        guard seen > 0 else { return }
        let fraction = Double(placeholder) / Double(seen)
        #expect(fraction < 0.5,
                "\(name) is mostly ImageRenderer's refusal — \(Int(fraction * 100))% of it is the placeholder, so it is a picture of nothing")
    }

    /// Is there anything on the middle of the page?
    ///
    /// The one assertion this file makes, and it is not about pixels shifting.
    /// `ImageRenderer` draws nothing inside a `ScrollView`, so the New Job
    /// sheet rendered as a title, two rules and three buttons over an empty
    /// page — and the test passed, every time, because writing a PNG cannot
    /// fail on what is not in it. A blank band down the middle of a sheet is
    /// never right, and it is the shape every "rendered nothing" bug takes.
    ///
    /// ── AND IT WAS NOT CATCHING THEM ──────────────────────────────────────
    ///
    /// It asked whether a pixel was darker than 0.92 in its weakest channel.
    /// `Khayt.ground` is a warm off-white — near enough #EFEBE6 — whose weakest
    /// channel is 0.90, so EVERY PIXEL OF AN EMPTY PAGE counted as ink and the
    /// fraction came out at 1.0. On the dark ground it is worse: every pixel is
    /// far below 0.92, so the check could not fail there either. A picture of
    /// the board rendered edge-to-edge blank and passed.
    ///
    /// It asks a different question now: how much of this page is NOT the
    /// colour most of it is? That needs to know nothing about the palette, it
    /// works the same in both appearances, and a page of one flat colour scores
    /// zero however light or dark that colour happens to be.
    private func expectInkInTheMiddle(_ rep: NSBitmapImageRep, _ name: String) {
        let top = rep.pixelsHigh / 4, bottom = rep.pixelsHigh * 3 / 4
        // Every fourth pixel each way: enough to find a line of text, and a
        // sixteenth of the work on a 2x bitmap.
        var samples: [(CGFloat, CGFloat, CGFloat)] = []
        var histogram: [Int: Int] = [:]
        /// Quantised to 32 levels a channel, so antialiasing along one edge of
        /// one glyph does not become thirty different "backgrounds".
        func bucket(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Int {
            (Int(r * 31) << 10) | (Int(g * 31) << 5) | Int(b * 31)
        }
        for y in stride(from: top, to: bottom, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                guard a > 0.1 else { continue }
                samples.append((r, g, b))
                histogram[bucket(r, g, b), default: 0] += 1
            }
        }
        // NO OPAQUE PIXELS AT ALL is the blankest a page can be, and returning
        // early on it — which this did — skips the one assertion in the file on
        // exactly the case it exists for. A view `ImageRenderer` will not host
        // comes back fully transparent and reads as white only because whatever
        // opens the PNG composites it onto white.
        guard !samples.isEmpty else {
            Issue.record("\(name) rendered nothing at all — every sampled pixel is transparent")
            return
        }
        guard let ground = histogram.max(by: { $0.value < $1.value })?.key else { return }
        let gr = CGFloat((ground >> 10) & 31) / 31
        let gg = CGFloat((ground >> 5) & 31) / 31
        let gb = CGFloat(ground & 31) / 31
        // Far enough from the ground to be something drawn, loose enough that a
        // one-level rounding difference is not.
        let ink = samples.filter { max(abs($0.0 - gr), max(abs($0.1 - gg), abs($0.2 - gb))) > 0.08 }.count
        let fraction = Double(ink) / Double(samples.count)
        #expect(fraction > 0.002,
                "\(name) is blank down the middle — \(ink) of \(samples.count) sampled pixels are anything other than the background")
    }

    @Test("the sample shop loads and renders")
    func shopWindow() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.orders.count == 42, "the sample shop did not load")
        #expect(shop.problem == nil)
        #expect(shop.owed > 0, "a sample with nothing owed cannot show the design working")
        #expect(shop.taxSummary != nil, "the tax line comes from lib/tax.js and is the proof the core is live")

        // NO PICTURES HERE, and that is the finding rather than a gap.
        //
        // This test rendered the whole window three times and every one of the
        // three was `ImageRenderer`'s yellow refusal, edge to edge, because it
        // will not host a `NavigationSplitView`. Rendering the halves instead
        // gets the same refusal for the sidebar, which is a `List`, and a
        // blank page for the dashboard, which is a `ScrollView`. What
        // `ImageRenderer` can draw is plain SwiftUI layout — the sheets below
        // — and the window belongs to the app's own capture, which draws
        // AppKit views properly. The assertions above are what this test is
        // for; they check the sample shop is worth photographing at all.
        shop.selection = shop.shown.first { !$0.isSettled }?.id
        shop.shelf = .jobs(.printing)

        #expect(!shop.files.isEmpty, "the sample shop has no models, so the library cannot be judged")
        #expect(shop.groups.contains("Saudi Kings"), "the grouped-models case must be in the sample")
        #expect(shop.ungroupedCount > 0, "so must the ungrouped one")
        shop.shelf = .library(nil)
        #expect(shop.shownFiles.count == shop.files.count)
    }

    /// The sheets, with their words in them.
    ///
    /// `ImageRenderer` renders SwiftUI properly; the running app's own capture
    /// cannot (see `Snapshot.captureSheet`), so every sheet photographed from
    /// the app is missing every label on it. What `ImageRenderer` CANNOT do is
    /// host a WKWebView, so the invoice's paper comes out blank here and is
    /// photographed from the app instead. Between the two there is a picture of
    /// the whole of each sheet.
    @Test("the sheets render, with their words")
    func sheets() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first { !$0.parts.isEmpty } ?? shop.orders.first)
        let subject = Shop.PendingHold(id: job.id, project: job.project)

        // The WIDTH comes from the sheet, never from a number typed here. A
        // sheet that grew was photographed at its old width and the picture
        // came back cropped through the middle, which no test noticed because
        // a snapshot has nothing to assert. The height is this test's own
        // choice — the sheets size themselves vertically to their contents.
        try render(PaymentSheet(shop: shop, subject: subject),
                   "20-payment-words", size: CGSize(width: PaymentSheet.width, height: 281))
        try render(EditJobSheet(shop: shop, subject: subject),
                   "21-edit-job-words", size: CGSize(width: EditJobSheet.width, height: 276))
        try render(QcFailSheet(shop: shop, subject: subject),
                   "22-qc-fail-words", size: CGSize(width: QcFailSheet.width, height: 228))
        // The paper rather than the whole sheet: `ImageRenderer` draws nothing
        // inside the ScrollView the sheet wraps it in, so photographing the
        // sheet here gave a title and three buttons over an empty page. The
        // chrome around it is in the app's own capture, `14-new-job`.
        try render(NewJobSheet(shop: shop).paper,
                   "23-new-job-words", size: CGSize(width: NewJobSheet.width, height: 420))
        try render(CustomerSheet(shop: shop, existing: Shop.newCustomer()),
                   "24-new-customer-words", size: CGSize(width: CustomerSheet.width, height: 350))
        try render(ExpenseSheet(shop: shop),
                   "26-expense-words", size: CGSize(width: ExpenseSheet.width, height: 380))
        try render(WasteSheet(shop: shop),
                   "27-waste-words", size: CGSize(width: WasteSheet.width, height: 460))
        try render(SpoolSheet(shop: shop, existing: shop.spools.first),
                   "28-spool-words", size: CGSize(width: SpoolSheet.width, height: 520))
        try render(MachineSheet(shop: shop, existing: shop.machines.first),
                   "29-machine-words", size: CGSize(width: MachineSheet.width, height: 560))
    }
    /// The import banner, which nobody had looked at.
    ///
    /// A batch of five hundred models is minutes of work behind one line of
    /// text, so that line and its Stop button are most of what a shop sees of
    /// this feature. `Banner` is plain SwiftUI, so `ImageRenderer` can host it —
    /// unlike the window it sits in.
    @Test("the import banner, running and finished")
    func importBanners() throws {
        let shop = Shop()
        try render(VStack(spacing: 0) {
            Banner(text: "Importing 137 of 490 — Fallen AT-AT Remote Holder.stl",
                   symbol: "gearshape.arrow.trianglehead.2.clockwise.rotate.90",
                   tint: Khayt.cyan) {
                // THE YELLOW BLOCK IN THIS PICTURE IS NOT A BUG. A linear
                // `ProgressView` is an `NSProgressIndicator`, and
                // `ImageRenderer` draws every AppKit-backed control as that
                // placeholder — the same refusal `expectItRendered` looks for,
                // which only fires when it covers the whole view. Kept in the
                // shot rather than left out, so the layout around it is the
                // real one and nobody removes the bar to make the picture tidy.
                // What the bar looks like has to be judged in the running app.
                ProgressView(value: 137, total: 490)
                    .progressViewStyle(.linear).frame(width: 120)
                Button("Stop") {}
            }
            Banner(text: "471 moved in · 18 already there · 1 failed.",
                   symbol: "checkmark.circle", tint: Khayt.done)
            Banner(text: "universal-filament-clip-v2.stl: could not be read",
                   symbol: "exclamationmark.triangle", tint: Khayt.attention)
            Banner(text: "Moved Turbine bracket into the library — 13,754 triangles.",
                   symbol: "checkmark.circle", tint: Khayt.done)
        }.frame(width: 720), "30-import-banners", size: CGSize(width: 720, height: 160))
        _ = shop
    }

    /// The state a search leaves behind, on the two screens that reach it
    /// differently — a shelf, where the word is the only filter, and the jobs
    /// table, where the sidebar's stage is narrowing too.
    ///
    /// Drawn beside the ORDINARY empty state on purpose. The whole claim of the
    /// absent mark is that a shop can tell "no spools yet" from "no spool
    /// called petg", and that claim can only be judged in a picture with both
    /// in it.
    @Test("a search that matched nothing, beside a screen with nothing on it")
    func searchedIntoNothing() async throws {
        // THE SAMPLE BOOK IS LOADED, and that is not incidental. A stage's
        // name comes from the shared Khayt catalogue, which an unopened `Shop`
        // has not read — so the first version of this picture said "…showing
        // only queue.delivered", the raw key, and nothing in the source could
        // have told me. A screen that names a filter has to be photographed
        // with the words that name it.
        let shop = Shop()
        await shop.load(.sample)
        shop.search = "petg"
        try render(HStack(spacing: 0) {
            NothingMatched(shop: shop, mark: .filament)
            Divider()
            EmptyHere(title: "No spools yet", message: "Add one at the shelf.", mark: .filament)
        }.frame(width: 900), "32-nothing-matched", size: CGSize(width: 900, height: 300))

        let jobs = Shop()
        await jobs.load(.sample)
        jobs.search = "bracket"
        jobs.shelf = .jobs(.delivered)
        #expect(jobs.words.callIt(Stage.delivered.key) != Stage.delivered.key,
                "the stage would be named by its raw key on this screen")
        try render(NothingMatched(shop: jobs, mark: .jobs).frame(width: 560),
                   "33-nothing-matched-stage", size: CGSize(width: 560, height: 300))
        // And on the dark ground. `render` forces light, because a picture
        // taken in whatever appearance the machine happens to be in is not a
        // picture of anything — so dark has to be asked for.
        try renderDark(NothingMatched(shop: jobs, mark: .jobs).frame(width: 560),
                       "34-nothing-matched-dark", size: CGSize(width: 560, height: 300))
    }

    /// What the shop's models really cost against what it quotes for them.
    ///
    /// The whole page, from the sample book — which had to be given actuals
    /// before this could be drawn at all: all 42 of its jobs carried estimates
    /// and not one an actual, so the panel and every other measured-actuals
    /// feature drew nothing whatever book you opened.
    @Test("what a model really costs, against the quote")
    func quotingPanel() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let rows = try await engine.estimateVariance(orders: shop.orderRows, minSamples: 1)
        #expect(!rows.isEmpty, "the sample cannot reach this screen — nothing to look at")
        var said: [String: KhaytEngine.VarianceAdvice] = [:]
        for row in rows {
            if let one = try await engine.varianceAdvice(row) { said[row.printFileId] = one }
        }
        #expect(!said.isEmpty, "no row earned a sentence, so the sentence is undrawn")
        // `.list`, not the screen: `ImageRenderer` draws nothing inside a
        // `ScrollView` and returns a fully transparent bitmap for it.
        try render(Quoting(shop: shop, rows: rows, said: said).list
                    .frame(width: 640).background(Khayt.ground),
                   "35-quoting", size: CGSize(width: 640, height: 620))
    }

    /// The sheet a finished job now opens, both with and without QC notes.
    ///
    /// Its whole job is to be dismissed quickly by a shop whose print ran as
    /// quoted, and to make correcting a figure obvious to one whose did not —
    /// which is a thing to look at rather than reason about.
    @Test("what did it take, with and without the QC question")
    func completionSheet() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let finishing = Shop.PendingCompletion(id: "ORD-01008", project: "Falcon hood — Najd Architects",
                                               estHours: 23.86, estGrams: 184.6, leavingQC: false)
        try render(CompletionSheet(shop: shop, subject: finishing),
                   "36-completion", size: CGSize(width: 420, height: 300))
        var fromQC = finishing
        fromQC = Shop.PendingCompletion(id: finishing.id, project: finishing.project,
                                        estHours: finishing.estHours, estGrams: finishing.estGrams,
                                        leavingQC: true)
        try render(CompletionSheet(shop: shop, subject: fromQC),
                   "37-completion-qc", size: CGSize(width: 420, height: 400))

        // AND WITH THE PRINTER'S OWN FIGURES, which is the state the whole
        // chain exists for and the one a shop with a linked machine sees. A
        // mixed answer on purpose: PrusaLink reports a duration and never
        // filament, so one axis is measured and the other is not, and the sheet
        // has to say which without making the other look wrong.
        func prefill(_ json: String) throws -> KhaytEngine.ActualsPrefill {
            try JSONDecoder().decode(KhaytEngine.ActualsPrefill.self, from: Data(json.utf8))
        }
        var measured = finishing
        measured.measured = try prefill(#"{"timeH":26.5,"weightG":184.6,"timeMeasured":true,"weightMeasured":false,"measured":true,"source":"prusalink","filename":"falcon-hood-v4.bgcode","staleReason":null}"#)
        try render(CompletionSheet(shop: shop, subject: measured),
                   "38-completion-measured", size: CGSize(width: 420, height: 360))
    }

    /// The camera tile, in the four states a shop actually sees.
    ///
    /// The picture case is a drawn image rather than a real JPEG so the shot
    /// does not depend on a printer being on this Mac's network — what is being
    /// looked at is the frame, the corner note and the rounding, not the photo.
    @Test("a camera tile: a picture, warming up, failed, and none")
    func cameraTiles() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let cam = Machine.Webcam(enabled: true, snapshotUrl: "http://x/1.jpg",
                                 streamUrl: "", rotate: 0, flipH: false, flipV: false)
        // A plate-ish rectangle, so the tile has something with edges in it.
        let drawn = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            NSColor(red: 0.24, green: 0.35, blue: 0.44, alpha: 1).setFill(); rect.fill()
            NSColor(red: 0.94, green: 0.92, blue: 0.90, alpha: 1).setFill()
            NSRect(x: 60, y: 30, width: 200, height: 120).fill()
            return true
        }
        let bytes: Data = drawn.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }
            .flatMap { $0.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) } ?? Data()

        try render(VStack(spacing: 10) {
            CameraTile(frame: .picture(bytes), webcam: cam, words: shop.words)
            CameraTile(frame: .waiting, webcam: cam, words: shop.words)
            CameraTile(frame: .failed("unreachable"), webcam: cam, words: shop.words)
        }.frame(width: 320).padding(Metric.screen).background(Khayt.ground),
                   "39-camera-tiles", size: CGSize(width: 320, height: 430))
    }

    /// The band with a machine booked out for maintenance in it.
    ///
    /// `downtimeBlocks` had been editable in Khayt for releases and nothing
    /// that plans work read them, so this state has never been drawn anywhere.
    /// What is being looked at: that the window is visible without reading like
    /// a fault, and that the queue behind it starts AFTER it rather than
    /// through it.
    @Test("a band with a maintenance window")
    func bandWithDowntime() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        // A WHOLE SECOND. `ISO8601DateFormatter` drops the fraction, so a
        // `Date()` with sub-second precision comes back a hair different and
        // the window measures 359.99999999999994 minutes — a fixture artefact
        // that reads exactly like an off-by-one in the module.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970).rounded())
        let iso = ISO8601DateFormatter()
        // Two machines: one out of action this afternoon with work queued
        // behind it, one ordinary, so the two read side by side.
        let machines: [JSONValue] = [
            .object(["id": .string("M1"), "name": .string("Prusa CORE One"),
                     "downtimeBlocks": .array([.object([
                        "from": .string(iso.string(from: now.addingTimeInterval(3 * 3600))),
                        "to": .string(iso.string(from: now.addingTimeInterval(9 * 3600))),
                        "note": .string("Belt change"),
                     ])])]),
            .object(["id": .string("M2"), "name": .string("Bambu X1C")]),
        ]
        let orders: [JSONValue] = [
            .object(["id": .string("A"), "status": .string("pending"),
                     "machineId": .string("M1"), "printTime": .number(5),
                     "project": .string("Falcon hood"), "parts": .array([])]),
            .object(["id": .string("B"), "status": .string("pending"),
                     "machineId": .string("M2"), "printTime": .number(7),
                     "project": .string("Ramadan lantern"), "parts": .array([])]),
        ]
        let band = try await engine.machineBand(
            machines: machines, orders: orders, inventory: [],
            live: ["M1": .object([:]), "M2": .object([:])],
            now: now, hours: 48)
        let down = try #require(band.rows.first).downMinutes
        #expect(down == 360, "the window is on the band as \(down) minutes, not 360")

        try render(MachineBandView(shop: shop, band: band).frame(width: 820),
                   "40-band-downtime", size: CGSize(width: 820, height: 260))
    }

    /// What a machine is due for, in all four states at once.
    ///
    /// The sample book reaches every one of them (see `SampleShopTests`), which
    /// is the only reason there is anything to look at. What is being judged
    /// here is whether the row can be READ at a glance: whether "overdue" is
    /// distinguishable from "due" without reading the word, and whether the
    /// remaining figure — negative once it is late — says which of two late
    /// machines to service first.
    ///
    /// THE "DONE" BUTTON DOES NOT PHOTOGRAPH, and that is the renderer rather
    /// than the row: `ImageRenderer` draws a yellow prohibition sign for any
    /// `Button` at all, verified with a bare `Button("Done") {}` beside this
    /// one. What the picture is for is the four rows either side of it.
    /// The other shelf: what is about to run out that is not filament.
    ///
    /// Four rows, four different reasons to be on the list — out of stock,
    /// below minimum, forecast to run out inside the lead time, and one the
    /// rule refuses to put a number against. What is being judged is whether
    /// those four read as different situations rather than one repeated.
    /// What a print is known to work at, and what it exists as.
    ///
    /// Three verdicts on one file, and beside it a file where nothing has
    /// worked — which is the case the panel exists for, because the answer
    /// there is "change something" rather than the least broken setup. What is
    /// being judged is whether an untried setup reads as untried rather than as
    /// a score of nought.
    @Test("what a print is known to work at")
    func setupsPanel() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)

        let bracket = try #require(shop.fileRows.first {
            if case .object(let f) = $0, case .string(let n)? = f["name"] {
                return n.contains("Turbine bracket")
            }
            return false
        })
        let gripper = try #require(shop.fileRows.first {
            if case .object(let f) = $0, case .string(let n)? = f["name"] {
                return n.contains("Robot gripper")
            }
            return false
        })
        let lantern = try #require(shop.fileRows.first {
            if case .object(let f) = $0, case .string(let n)? = f["name"] {
                return n.contains("Ramadan lantern")
            }
            return false
        })

        let works = try await engine.printSetups(bracket)
        let broken = try await engine.printSetups(gripper)
        let sizes = try await engine.printVersions(lantern)
        #expect(works.recommendedId != nil)
        #expect(broken.recommendedId == nil, "the nothing-works case must be in the picture")
        #expect(sizes.many)

        try render(
            VStack(alignment: .leading, spacing: 18) {
                SetupsSection(setups: works, shop: shop)
                SetupsSection(setups: broken, shop: shop)
                VersionsSection(versions: sizes, shop: shop)
            }
            .padding(16)
            .frame(width: 460),
            "43-setups", size: CGSize(width: 460, height: 430))
    }

    @Test("what is about to run out that is not filament")
    func consumablesCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        // Pinned for the same reason the sample guard pins it: the rate is
        // measured over a trailing window.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-05T00:00:00Z"))
        let needs = try await engine.consumableNeeds(
            consumables: shop.consumableRows, orders: shop.orderRows, now: now)
        #expect(needs.count >= 4, "not enough on the shelf to judge the card")

        try render(
            ConsumablesCard(needs: needs, shop: shop)
                .padding(14)
                .frame(width: 440),
            "42-consumables", size: CGSize(width: 440, height: 210))
    }

    @Test("what each machine is due for")
    func maintenanceRows() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let machine = try #require(shop.machines.first { $0.id == "MACH-x1c" })

        // Every status on one card, so they are compared rather than described.
        // The intervals are chosen against the sample's own meter.
        let hours = 96.5
        let tasks: [JSONValue] = [
            .object(["id": .string("A"), "machineId": .string(machine.id),
                     "name": .string("Lubricate linear rails"),
                     "intervalHours": .number(400), "lastDoneHours": .number(0)]),
            .object(["id": .string("B"), "machineId": .string(machine.id),
                     "name": .string("Replace nozzle"),
                     "intervalHours": .number(100), "lastDoneHours": .number(0)]),
            .object(["id": .string("C"), "machineId": .string(machine.id),
                     "name": .string("Check belt tension"),
                     "intervalHours": .number(90), "lastDoneHours": .number(0)]),
            .object(["id": .string("D"), "machineId": .string(machine.id),
                     "name": .string("Clean build plate"),
                     "intervalHours": .number(50), "lastDoneHours": .number(0)]),
        ]
        let jobs: [JSONValue] = [.object([
            "id": .string("J"), "machineId": .string(machine.id),
            "status": .string("completed"), "printTime": .number(hours),
        ])]
        let card = try await engine.maintenance(
            machineId: machine.id, tasks: tasks, jobs: jobs,
            machine: .object(["id": .string(machine.id)]), now: Date())
        #expect(Set(card.tasks.map(\.status)) == ["ok", "warning", "due", "overdue"],
                "the four states have to be side by side or there is nothing to compare")

        try render(
            VStack(alignment: .leading, spacing: 7) {
                ForEach(card.tasks) { Upkeep(task: $0, machine: machine, shop: shop) }
            }
            .padding(14)
            .frame(width: 420),
            "41-maintenance", size: CGSize(width: 420, height: 190))
    }

    /// What each machine earned, from the sample book.
    ///
    /// The arithmetic has its own tests. What is being looked at here is
    /// whether the row can be FOLLOWED — revenue, then the three things taken
    /// off it, then the net — rather than trusted, and whether a machine that
    /// earned nothing reads as having no margin rather than as breaking even.
    @Test("what each machine earned")
    func machineProfitPage() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let done = shop.orderRows.filter {
            if case .object(let o) = $0, case .string(let s)? = o["status"] { return s == "completed" }
            return false
        }
        let report = try await engine.machineProfit(
            machines: shop.machineRows, completed: done,
            expenses: [], maintenance: [
                // One serviced machine, so the column is not a row of dashes —
                // the sample keeps no maintenance log.
                // A REAL ID. The first version used "MACH-1", which no sample
                // machine has, so the 420 landed nowhere and the column drew
                // 0.00 on every row — a fixture that demonstrated nothing and
                // looked like it had.
                .object(["machineId": .string("MACH-core-one"), "cost": .number(420)]),
            ],
            settings: shop.settingsDict, clients: shop.clientRows,
            unassigned: shop.words.callIt("dash.unassigned"))
        #expect(!report.rows.isEmpty, "the sample cannot reach this page")

        // `.rows`, not the page: `ImageRenderer` returns a fully transparent
        // bitmap for a `ScrollView`, which the ink check now catches.
        try render(MachineProfitPage(shop: shop, report: report).rows(report)
                    .frame(width: 900).background(Khayt.ground),
                   "41-machine-profit", size: CGSize(width: 900, height: 560))
    }

    /// Where a model came from, both ways round.
    ///
    /// The line a shop is looking for is "may not be sold", and it has to read
    /// as a fact rather than an alarm — and the model beside it, the shop's own
    /// work, must not look like it is missing something. Drawn together because
    /// that is how they are judged.
    @Test("provenance: a downloaded model and the shop's own")
    func provenanceRows() throws {
        try render(VStack(alignment: .leading, spacing: 18) {
            DetailSection("Where it came from") {
                DetailLine("Source", "https://www.printables.com/model/remb-forest-dragon")
                DetailLine("Licence", "CC BY-NC — not for sale", warn: true)
            }
            DetailSection("Where it came from") {
                DetailLine("Source", "Commissioned — Athar Tuwaiq")
                DetailLine("Licence", "My own design")
            }
        }.frame(width: 380), "31-provenance", size: CGSize(width: 380, height: 300))
    }

    /// The report builder, in the two pieces that can be laid out wrongly.
    ///
    /// The chips wrap through a `Layout` written for this screen, and the
    /// alternative — an adaptive `LazyVGrid` — is one of the two shapes that
    /// has hung this app. A hang does not show up in a passing test; it shows
    /// up here, as a render that never returns.
    @Test("a report a shop asked for, and the chips it asked with")
    func reportBuilder() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let fields = try await engine.reportFields()
        var chosen: Set<String> = ["id", "date", "client", "status", "price", "paymentStatus"]
        // Through the screen's own label rule, not `field.label` — the module's
        // English headers would render in every language and the Arabic picture
        // would be a picture of an app that does not exist.
        var labels: [String: JSONValue] = [:]
        for f in fields { labels[f.key] = .string(CustomReportPage.label(for: f, shop.words)) }
        let report = try await engine.buildReport(
            orders: shop.orderRows, clients: shop.clientRows, machines: shop.machineRows,
            settings: shop.settingsDict, language: shop.words.language,
            fields: fields.map(\.key).filter { chosen.contains($0) },
            statusIn: [], from: "", to: "", labels: labels)
        #expect(!report.rows.isEmpty, "the sample cannot reach this page")

        let saved = try await engine.addSavedReport(
            [], name: "August, finished", fields: ["id", "price"],
            statusIn: ["completed"], from: "", to: "", id: "RPT-1")

        try render(VStack(alignment: .leading, spacing: 16) {
            // A saved report, which is the row that carries a second control
            // inside the chip — the one place the shape can go wrong.
            FlowChips(items: saved.map { ($0.id, $0.name) },
                      isOn: { _ in false }, toggle: { _ in },
                      remove: { _ in }, removeHelp: "Remove")
            // Every column on offer, which is the widest the chips ever get —
            // the row that wraps is the one worth photographing.
            FlowChips(items: fields.map { ($0.key, CustomReportPage.label(for: $0, shop.words)) },
                      isOn: { chosen.contains($0) }, toggle: { _ in })
            // The first rows only. The sample's book is longer than any frame
            // this can be rendered at, and a `VStack` taller than its frame
            // CENTRES — so photographing the whole table photographs its
            // middle, with the controls above it cropped off the top.
            ReportTable(report: KhaytEngine.Report(
                headers: report.headers, keys: report.keys,
                rows: Array(report.rows.prefix(8)), total: report.total),
                        currency: shop.currency, words: shop.words)
            Spacer(minLength: 0)
        }
        .padding(Metric.screen)
        .frame(width: 900).background(Khayt.ground),
                   "42-report-builder", size: CGSize(width: 900, height: 620))
    }

    /// What the shop must bill before any of it is profit.
    ///
    /// Rendered in both states the sample can reach — a month still short of
    /// the line and a month past it — because the card changes colour, wording
    /// and direction between them, and a screen only reviewed on one side of a
    /// threshold has only half been reviewed.
    @Test("the break-even card, short of the line and past it")
    func breakEvenCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let completed = shop.orderRows.filter {
            if case .object(let o) = $0, case .string(let s)? = o["status"] { return s == "completed" }
            return false
        }
        var costs: [JSONValue] = []
        if case .array(let stored)? = shop.settingsDict["fixedCosts"] { costs = stored }
        #expect(!costs.isEmpty, "the sample shop cannot reach this card")

        // The sample's own book has a month on each side of the line, so both
        // are drawn from real arithmetic rather than from a doctored figure:
        // September billed 1,081 against a target near 7,100, and June billed
        // 10,191. The first draft of this used August and September — two quiet
        // months — and drew the same red card twice while claiming to show both
        // states.
        let short = try await engine.breakEven(
            fixedCosts: costs, completed: completed, since: "2026-01-01",
            month: "2026-09", settings: shop.settingsDict, clients: shop.clientRows)
        let ahead = try await engine.breakEven(
            fixedCosts: costs, completed: completed, since: "2026-01-01",
            month: "2026-06", settings: shop.settingsDict, clients: shop.clientRows)
        #expect((short.surplus ?? 0) < 0 && (ahead.surplus ?? 0) > 0,
                "both cards are the same state, so only one has been reviewed")

        try render(HStack(alignment: .top, spacing: 16) {
            BreakEvenCard(shop: shop, report: short)
                .card(rail: (short.surplus ?? 0) < 0 ? Khayt.late : Khayt.cyan, padding: 14)
            BreakEvenCard(shop: shop, report: ahead)
                .card(rail: (ahead.surplus ?? 0) < 0 ? Khayt.late : Khayt.cyan, padding: 14)
            // And the state a shop starts in, which is the one it sees first.
            BreakEvenCard(shop: shop, report: nil)
                .card(rail: Khayt.cyan, padding: 14)
        }
        .frame(width: 900).padding(Metric.screen).background(Khayt.ground),
                   "43-break-even", size: CGSize(width: 940, height: 420))
    }

    /// What reached the bank, against what was earned.
    ///
    /// In above the line and out below it, on one shared scale — the thing to
    /// look at is whether a month with a tall green column also has a tall red
    /// one, which is the month a shop was busy and no better off.
    @Test("cash in and cash out, on one baseline")
    func cashFlowChart() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let flow = try await engine.cashFlow(
            orders: shop.orderRows, expenses: shop.expenseRows,
            endMonth: "2026-09", months: 6,
            settings: shop.settingsDict, clients: shop.clientRows)
        #expect(flow.totals.anyMovement, "the sample cannot reach this chart")

        try render(VStack(spacing: 16) {
            CashFlowChart(shop: shop, flow: flow)
                .card(rail: Khayt.cyan, padding: 14)
            // And the state a quiet shop sees, which is the one it sees first.
            CashFlowChart(shop: shop, flow: nil)
                .card(rail: Khayt.cyan, padding: 14)
        }
        .frame(width: 620).padding(Metric.screen).background(Khayt.ground),
                   "44-cash-flow", size: CGSize(width: 660, height: 480))
    }

    /// Which customers are worth keeping.
    ///
    /// The sentence above the table is the part worth looking at — a ranked
    /// list is something a shop already knows, and how much of the business
    /// rests on the first row is not.
    @Test("what each customer has been worth, and who has stopped coming back")
    func clientValueTable() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let worth = try await engine.clientValue(
            clients: shop.clientRows, orders: shop.orderRows,
            now: Date(timeIntervalSince1970: 1_789_084_800),   // 2026-09-11
            quietDays: 90, limit: 8,
            settings: shop.settingsDict, language: shop.words.language)
        #expect(!worth.rows.isEmpty, "the sample cannot reach this table")
        // A screen only reviewed with every row in one state has half been
        // reviewed: the amber line only appears on a customer that stopped.
        #expect(worth.totals.quiet > 0, "no quiet customer, so that row is undrawn")

        try render(ClientValueTable(shop: shop, report: worth)
                    .card(rail: Khayt.cyan, padding: 14)
                    .frame(width: 560).padding(Metric.screen).background(Khayt.ground),
                   "45-client-value", size: CGSize(width: 600, height: 560))
    }

    /// Can the shop take this job, and when would it start?
    ///
    /// Drawn in the two states that matter and are easy to confuse: a machine
    /// with room, and a machine three weeks behind. The other app drew those
    /// identically, because it clamped the load at 100%.
    @Test("capacity, with room and overbooked")
    func capacityCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)

        let real = try await engine.capacity(
            machines: shop.machineRows, orders: shop.orderRows, days: 7,
            unassigned: shop.words.callIt("dash.unassigned"))
        #expect(!real.rows.isEmpty, "the sample cannot reach this card")
        #expect(!real.totals.noTargets,
                "no sample machine has a daily target, so only the empty state is ever drawn")

        // And the state the sample cannot reach on its own. Built from the
        // sample's OWN machines rather than invented ones, so the row still
        // carries a real name and colour.
        let piled = shop.machineRows.enumerated().map { index, row -> JSONValue in
            guard case .object(var m) = row else { return row }
            // A short day on every machine, so the SHOP is behind and not just
            // one printer — the card colours its rail off the total, and a
            // first draft that only overbooked one machine drew a calm rail
            // above a red row.
            m["targetHoursPerDay"] = .number(index == 0 ? 4 : 2)
            return .object(m)
        }
        let heavy = try await engine.capacity(
            machines: piled,
            orders: piled.prefix(1).flatMap { row -> [JSONValue] in
                guard case .object(let m) = row, case .string(let id)? = m["id"] else { return [] }
                return (1...6).map { n in
                    .object(["id": .string("Q\(n)"), "machineId": .string(id),
                             "status": .string("pending"), "printTime": .number(22)])
                }
            },
            days: 7, unassigned: shop.words.callIt("dash.unassigned"))
        #expect(heavy.totals.overbooked, "the overbooked state is undrawn")
        #expect(heavy.rows.contains { $0.overbooked }, "no row is drawn overbooked")

        try render(VStack(spacing: 16) {
            CapacityCard(shop: shop, report: real)
                .card(rail: Khayt.cyan, padding: 14)
            CapacityCard(shop: shop, report: heavy)
                .card(rail: Khayt.late, padding: 14)
        }
        .frame(width: 560).padding(Metric.screen).background(Khayt.ground),
                   "46-capacity", size: CGSize(width: 600, height: 620))
    }

    /// How many quotes turn into work, and how much of the money does.
    ///
    /// The two rates side by side are the thing to look at: when they are far
    /// apart, the gap IS the finding.
    @Test("the quote funnel, both rates and the open ones")
    func quoteFunnelCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let funnel = try await engine.quoteFunnel(
            orders: shop.orderRows,
            now: Date(timeIntervalSince1970: 1_789_084_800),   // 2026-09-11
            settings: shop.settingsDict, clients: shop.clientRows)
        #expect(funnel.totals.winRateByCount != nil, "the sample cannot reach this card")

        try render(VStack(spacing: 16) {
            QuoteFunnelCard(shop: shop, report: funnel)
                .card(rail: Khayt.cyan, padding: 14)
            // And the state a shop that has never quoted sees.
            QuoteFunnelCard(shop: shop, report: nil)
                .card(rail: Khayt.cyan, padding: 14)
        }
        .frame(width: 560).padding(Metric.screen).background(Khayt.ground),
                   "47-quote-funnel", size: CGSize(width: 600, height: 540))
    }

    /// Which of the things the shop sells actually earns.
    ///
    /// The sentence at the top is the point: the best use of a machine hour is
    /// usually NOT the top row, and a reader scanning down the table will not
    /// find it.
    @Test("what earns, ranked by profit rather than by revenue")
    func productProfitTable() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let earns = try await engine.productProfit(
            orders: shop.orderRows, products: shop.productRows,
            expenses: shop.expenseRows, untagged: shop.words.callIt("an.untagged"),
            settings: shop.settingsDict, clients: shop.clientRows,
            language: shop.words.language)
        #expect(earns.rows.count > 1, "the sample cannot reach this table")

        // The first rows only. The sample sells twenty things and a `VStack`
        // taller than its frame CENTRES — so photographing all of them
        // photographs the middle, with the heading cropped off the top, which
        // is exactly what the first version of this did.
        let top = KhaytEngine.ProductProfit(rows: Array(earns.rows.prefix(7)),
                                            totals: earns.totals)
        try render(VStack {
            ProductProfitTable(shop: shop, report: top)
                .card(rail: Khayt.cyan, padding: 14)
            Spacer(minLength: 0)
        }
        .frame(width: 560).padding(Metric.screen).background(Khayt.ground),
                   "48-product-profit", size: CGSize(width: 600, height: 520))
    }

    /// Growing, or serving the same people?
    @Test("where the work comes from, new against returning")
    func customerMixCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let mix = try await engine.customerMix(
            orders: shop.orderRows, from: "", to: "",
            settings: shop.settingsDict, clients: shop.clientRows)
        #expect(mix.fresh.jobs > 0 && mix.returning.jobs > 0,
                "the sample reaches only one half, so the card is half reviewed")

        try render(VStack(spacing: 16) {
            CustomerMixCard(shop: shop, report: mix)
                .card(rail: Khayt.cyan, padding: 14)
            CustomerMixCard(shop: shop, report: nil)
                .card(rail: Khayt.cyan, padding: 14)
            Spacer(minLength: 0)
        }
        .frame(width: 520).padding(Metric.screen).background(Khayt.ground),
                   "49-customer-mix", size: CGSize(width: 560, height: 400))
    }

    /// Which machine is costing the shop, and what it keeps doing wrong.
    @Test("what gets scrapped, by machine")
    func machineReliabilityCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let scrap = try await engine.machineReliability(
            machines: shop.machineRows, orders: shop.orderRows, waste: shop.wasteRows,
            from: "", to: "", unassigned: shop.words.callIt("dash.unassigned"))
        #expect(scrap.rows.filter { $0.scraps > 0 }.count > 1,
                "only one machine scraps, so the ranking shows nothing")

        try render(VStack(spacing: 16) {
            MachineReliabilityCard(shop: shop, report: scrap)
                .card(rail: Khayt.cyan, padding: 14)
            Spacer(minLength: 0)
        }
        .frame(width: 560).padding(Metric.screen).background(Khayt.ground),
                   "50-machine-scrap", size: CGSize(width: 600, height: 400))
    }

    /// When the shop actually finishes work.
    ///
    /// The findings are above the grid on purpose: at the volume a small shop
    /// generates, a 168-cell grid of mostly-empty cells looks exactly like a
    /// pattern, and a reader will find one in it.
    @Test("when work finishes, and how much of it on a closed day")
    func throughputCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let open = try await engine.openDays(settings: shop.settingsDict)
        let when = try await engine.throughput(
            orders: shop.orderRows, openDays: open, minimum: 10)
        #expect(when.totals.enough, "the sample only draws the thin state")

        // And the thin state, which is what a shop sees in its first month.
        let thin = try await engine.throughput(
            orders: Array(shop.orderRows.prefix(3)), openDays: open, minimum: 10)

        try render(VStack(spacing: 16) {
            ThroughputCard(shop: shop, report: when)
                .card(rail: Khayt.cyan, padding: 14)
            ThroughputCard(shop: shop, report: thin)
                .card(rail: Khayt.cyan, padding: 14)
            Spacer(minLength: 0)
        }
        .frame(width: 620).padding(Metric.screen).background(Khayt.ground),
                   "51-throughput", size: CGSize(width: 660, height: 520))
    }

    /// What the shelf costs, and whether that has moved.
    @Test("what materials cost, in their own units")
    func materialCostCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let prices = try await engine.materialCost(inventory: shop.inventoryRows, minimum: 2)
        #expect(prices.totals.anyChangeKnown, "no price change is drawn")

        try render(VStack(spacing: 16) {
            MaterialCostCard(shop: shop, report: prices)
                .card(rail: Khayt.cyan, padding: 14)
            Spacer(minLength: 0)
        }
        .frame(width: 520).padding(Metric.screen).background(Khayt.ground),
                   "52-material-cost", size: CGSize(width: 560, height: 620))
    }

    /// How much passes inspection, and how much first time.
    ///
    /// The two rates side by side are the point: a shop that reprints until it
    /// passes has a pass rate near 100% and a quality problem, and only the
    /// first figure says so.
    @Test("quality, in the two rates that disagree")
    func qualityCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let quality = try await engine.qcMetrics(orders: shop.orderRows)
        #expect(quality.qcd > 0, "the sample cannot reach this card")
        #expect(try #require(quality.firstPassYield) < #require(quality.passRate),
                "the two rates agree, so the gap that is the point is undrawn")

        try render(VStack(spacing: 16) {
            QualityCard(shop: shop, report: quality)
                .card(rail: Khayt.cyan, padding: 14)
            // And the state a shop sees before it has inspected anything.
            QualityCard(shop: shop, report: nil)
                .card(rail: Khayt.cyan, padding: 14)
            Spacer(minLength: 0)
        }
        .frame(width: 520).padding(Metric.screen).background(Khayt.ground),
                   "53-quality", size: CGSize(width: 560, height: 420))
    }

}
