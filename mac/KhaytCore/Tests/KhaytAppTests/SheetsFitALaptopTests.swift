import Testing
import SwiftUI
import AppKit
import KhaytCore
@testable import KhaytApp

/// Every sheet has to fit the smallest Mac somebody runs this on.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// A macOS sheet is attached to the top of its window and **cannot be moved**.
/// One taller than the display hangs its bottom edge — where Cancel and Save
/// live — off the screen, with no way to drag it into view. A shop reported
/// exactly that: *"I just opened a product to edit and can't close it because
/// the buttons are hidden below and I can't move the window."*
///
/// Nothing here caught it, and nothing here WOULD have. Every screenshot this
/// repo takes is rendered at whatever size the harness is told, on a machine
/// with a large display, and `mac-layout-at-every-display-size` already says
/// the size a thing is built at is the size it is least likely to be wrong at.
///
/// ── WHAT IT MEASURES ──────────────────────────────────────────────────────
///
/// `NSHostingView.fittingSize` — the height SwiftUI would give the view if
/// nothing constrained it. A sheet wrapped in `SheetFrame` reports its cap; one
/// that is not reports whatever its content adds up to. So the check is the
/// same for both and does not care which is which: **does this fit a laptop.**
///
/// The screen is injected rather than read, because the machine running this
/// has a big one — see `SheetMetrics.screenHeight`.
/// See `SheetsFitALaptopTests.laptopScreen`.
private let laptopScreenHeight: CGFloat = 875

@Suite @MainActor struct SheetsFitALaptopTests {

    /// A 13-inch MacBook Air: 1470×956 points, less the menu bar. Rounded down,
    /// because somebody is running this on an older 1440×900 too.
    ///
    /// File scope rather than a static on this @MainActor suite: the seam it is
    /// assigned to is a `@Sendable` closure, which cannot capture actor-isolated
    /// state.
    static var laptopScreen: CGFloat { laptopScreenHeight }

    /// What a sheet may occupy on that screen. `SheetFrame` leaves the same
    /// room, so a capped sheet lands exactly here and an uncapped one that fits
    /// lands under it.
    static var ceiling: CGFloat { laptopScreen - SheetMetrics.chrome }

    static func height(of view: some View, width: CGFloat = 560) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Runs the body with the screen pinned to a laptop's, and puts the real
    /// one back afterwards however the body ends.
    static func onALaptop<T>(_ body: () throws -> T) rethrows -> T {
        let real = SheetMetrics.screenHeight
        SheetMetrics.screenHeight = { laptopScreenHeight }
        defer { SheetMetrics.screenHeight = real }
        return try body()
    }

    @Test("every sheet fits a 13-inch laptop, buttons included")
    func sheetsFit() throws {
        let shop = Shop()
        // These three take the same lightweight subject the snapshot runner
        // builds, not an Order.
        let subject = shop.orders.first.map { Shop.PendingHold(id: $0.id, project: $0.project) }
        let spool = shop.spools.first

        // Measured by NAME so a failure says which one, and so the list itself
        // is the inventory of what has been checked.
        var measured: [(String, CGFloat)] = []
        Self.onALaptop {
            measured.append(("ProductSheet", Self.height(of:
                ProductSheet(shop: shop, existing: shop.newProduct()))))
            measured.append(("SpoolSheet", Self.height(of:
                SpoolSheet(shop: shop, existing: spool))))
            measured.append(("CustomerSheet", Self.height(of:
                CustomerSheet(shop: shop, existing: Shop.newCustomer()))))
            measured.append(("CloudSignInSheet", Self.height(of:
                CloudSignInSheet(shop: shop))))
            measured.append(("CloudCheckSheet", Self.height(of:
                CloudCheckSheet(shop: shop))))
            if let subject {
                measured.append(("PaymentSheet", Self.height(of:
                    PaymentSheet(shop: shop, subject: subject))))
                measured.append(("EditJobSheet", Self.height(of:
                    EditJobSheet(shop: shop, subject: subject))))
                measured.append(("QcFailSheet", Self.height(of:
                    QcFailSheet(shop: shop, subject: subject))))
            }
        }

        let tall = measured.filter { $0.1 > Self.ceiling }
        #expect(tall.isEmpty, Comment(rawValue: """
            \(tall.count) sheet(s) are taller than a 13-inch laptop can show \
            (\(Int(Self.ceiling))pt):

            \(tall.map { "  \($0.0): \(Int($0.1))pt" }.joined(separator: "\n"))

            A sheet CANNOT BE MOVED, so its Cancel and Save would sit below the \
            bottom of the screen with no way to reach them. Wrap the body in \
            `SheetFrame`, which scrolls the content and pins the footer.

            All measured: \(measured.map { "\($0.0) \(Int($0.1))" }.joined(separator: ", "))
            """))
    }

    /// The guard is only worth its runtime if it fails on the real thing, so
    /// this pins the mechanism rather than trusting it: a deliberately enormous
    /// view must be caught, and a capped one must not be.
    @Test("the measurement catches a sheet that would hang off the screen")
    func catchesATallOne() {
        Self.onALaptop {
            let runaway = VStack {
                ForEach(0..<80, id: \.self) { _ in Text("a row").padding(8) }
            }
            #expect(Self.height(of: runaway) > Self.ceiling,
                    "80 padded rows must measure taller than a laptop's sheet")

            let capped = SheetFrame(width: 480) {
                ForEach(0..<80, id: \.self) { _ in Text("a row").padding(8) }
            } footer: {
                Text("buttons live here")
            }
            #expect(Self.height(of: capped) <= Self.ceiling,
                    "SheetFrame must cap to the injected screen, not the real one")
        }
    }

    /// ── THE CHECK THAT WOULD ACTUALLY HAVE CAUGHT IT ──────────────────────
    ///
    /// The measurement above cannot. A product sheet's parts, tiers and papers
    /// arrive in `@State` after the view is made, so a `fittingSize` taken at
    /// init measures an EMPTY product — and an empty product was never the
    /// problem. Measuring the easy case and passing is worse than not checking.
    ///
    /// What IS knowable without running the app: a sheet that renders a list of
    /// the shop's own records grows with how many there are. A `ForEach` over
    /// `shop.something`, or over state loaded from the book, has no ceiling of
    /// its own — so the sheet holding it needs one.
    ///
    /// A `ForEach` inside a `Picker` does not count: it becomes a menu, not
    /// rows in the sheet. Nor does one over a fixed list — `Shop.failureTypes`,
    /// `Shop.paymentMethods`, `Shop.priorityLevels` are as long today as they
    /// will ever be.
    ///
    /// This found `CloudCheckSheet`, which draws ONE ROW PER COLLECTION that
    /// differs from the cloud — up to thirty-three — in a sheet with no cap.
    /// Nobody had reported it; it simply had not drifted far enough yet.
    @Test("a sheet that lists the shop's own records is capped")
    func growingSheetsAreCapped() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("Sheet.swift") }
        #expect(files.count > 10, "the sheets moved — this test is reading the wrong directory")

        var uncapped: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let text = try String(contentsOf: file, encoding: .utf8)
            uncapped += Self.uncappedLists(in: text, named: file.lastPathComponent)
        }

        #expect(uncapped.isEmpty, Comment(rawValue: """
            \(uncapped.count) sheet(s) list records inline with no height cap:

            \(uncapped.joined(separator: "\n"))

            Each of those grows with how much the shop has. A sheet CANNOT BE \
            MOVED, so past the height of the screen its own buttons are \
            unreachable. Wrap the body in `SheetFrame`, or say here why that \
            list is bounded.
            """))
    }

    /// The rule itself, as a function so it can be shown to WORK.
    ///
    /// Returns one line per inline list of shop records in an uncapped sheet.
    /// Empty for a capped sheet, for a fixed list, and for a list inside a
    /// Picker — which becomes a menu rather than rows.
    static func uncappedLists(in text: String, named name: String) -> [String] {
        guard !(text.contains("SheetFrame(") || text.contains("ScrollView")) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var found: [String] = []
        for (n, line) in lines.enumerated() {
            guard let range = line.range(of: "ForEach(") else { continue }
            let subject = String(line[range.upperBound...])
            // A fixed list is bounded: `Shop.failureTypes` and friends are as
            // long today as they will ever be.
            if subject.hasPrefix("Shop.") { continue }
            // A menu, not rows in the sheet.
            let nearby = lines[max(0, n - 3)..<n].joined(separator: " ")
            if nearby.contains("Picker") { continue }
            found.append("\(name):\(n + 1)  ForEach(\(subject.prefix(30))")
        }
        return found
    }

    @Test("the rule flags a growing list and spares a bounded one")
    func theRuleWorks() {
        // Shaped like CloudCheckSheet was: one row per differing collection,
        // inline, in a sheet with no cap. This is the real defect it found.
        let growing = """
        struct ExampleSheet: View {
            var body: some View {
                VStack {
                    ForEach(result.differing) { line in
                        GridRow { Text(line.collection) }
                    }
                }
            }
        }
        """
        #expect(!Self.uncappedLists(in: growing, named: "ExampleSheet.swift").isEmpty,
                "an inline list of records in an uncapped sheet must be flagged")

        // The same list, capped. Nothing to report.
        #expect(Self.uncappedLists(in: growing.replacingOccurrences(of: "VStack {",
                                                                    with: "SheetFrame(width: 520) {"),
                                   named: "ExampleSheet.swift").isEmpty,
                "a capped sheet is fine however long its list gets")

        // A fixed list, and a list inside a Picker: both bounded.
        let bounded = """
        struct ExampleSheet: View {
            var body: some View {
                VStack {
                    ForEach(Shop.paymentMethods, id: \\.self) { Text($0) }
                    Picker("", selection: $pick) {
                        ForEach(shop.clients) { Text($0.name) }
                    }
                }
            }
        }
        """
        #expect(Self.uncappedLists(in: bounded, named: "ExampleSheet.swift").isEmpty,
                "a fixed list and a picker's list are both bounded")
    }
}
