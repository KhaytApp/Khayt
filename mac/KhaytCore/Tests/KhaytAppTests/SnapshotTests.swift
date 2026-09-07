import Testing
import SwiftUI
import AppKit
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

    func render(_ view: some View, _ name: String, size: CGSize) throws {
        guard let dir = Self.outputDir else { return }
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .light)
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
    private func expectInkInTheMiddle(_ rep: NSBitmapImageRep, _ name: String) {
        let top = rep.pixelsHigh / 4, bottom = rep.pixelsHigh * 3 / 4
        var ink = 0, seen = 0
        // Every fourth pixel each way: enough to find a line of text, and a
        // sixteenth of the work on a 2x bitmap.
        for y in stride(from: top, to: bottom, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                seen += 1
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                if a > 0.1, min(r, min(g, b)) < 0.92 { ink += 1 }
            }
        }
        guard seen > 0 else { return }
        let fraction = Double(ink) / Double(seen)
        #expect(fraction > 0.002,
                "\(name) is blank down the middle — \(ink) of \(seen) sampled pixels have anything in them")
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

}
