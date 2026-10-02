import Foundation
import Network
import Testing
import SwiftUI
import AppKit
import KhaytCore
@testable import KhaytApp

/// The eleven fixes of the "polish D" review: new customer, worded strip
/// actions, the cloud hint, Find printers, the LAN error, the Arabic inventory,
/// the two price cards, expected life, the status face, capacity's plurals and
/// the empty Expenses/Waste screens.
@Suite @MainActor
struct UIPolishDTests {

    private func words(_ lang: String) async throws -> Words {
        let w = Words()
        await w.load(lang, engine: try KhaytEngine())
        return w
    }

    // ── 1. A customer can be added before their first job ─────────────────

    @Test("the customers screen offers New customer, and the menu item waits on a writable book")
    func newCustomer() {
        let actions = MenuCoverageTests.source("ScreenActions.swift")
        #expect(actions.contains("} else if shop.showingCustomers {"), "no customers branch on the strip")
        #expect(actions.contains("plus(\"mac.new_customer\", enabled: shop.canMoveJobs)"))
        let table = MenuCoverageTests.source("CustomersTable.swift")
        #expect(table.contains("Button(shop.words.callIt(\"mac.add_customer\"))"), "no button on the empty state")
        let menus = MenuCoverageTests.source("Menus.swift")
        if let item = menus.range(of: "Button(Words.upfront(\"mac.new_customer\"))") {
            let after = menus[item.upperBound...].prefix(160)
            #expect(after.contains(".disabled(!shop.canMoveJobs)"), "File ▸ New Customer opens on a book it cannot save to")
        }
    }

    // ── 2. The primary action says its word ───────────────────────────────

    @Test("a primary strip action is worded, a secondary one is a symbol")
    func wordedActions() {
        let primary = NavyAction(label: "+ Add Printer", symbol: "plus", titled: true) {}
        #expect(primary.word == "Add Printer", "the word repeats the symbol's plus")
        #expect(NavyAction(label: "New Job", symbol: "plus") {}.word == "New Job")
        let src = MenuCoverageTests.source("ScreenActions.swift")
        #expect(src.contains("NavyAction(label: shop.words.callIt(key), symbol: \"plus\", enabled: enabled, titled: true, act: act)"))
        #expect(src.contains("ViewThatFits(in: .horizontal)"), "a narrow window has no way to drop the word")
    }

    // ── 3. The cloud hint names a place this Mac has ──────────────────────

    @Test("the integrations hint names the Book menu, not a Cloud pane", arguments: ["en", "ar"])
    func cloudHint(lang: String) async throws {
        let w = try await words(lang)
        let said = IntegrationsPane.cloudHint(w)
        #expect(said.contains(w.callIt("mac.menu_book")))
        #expect(said.contains(w.callIt("mac.cloud_sign_in")))
        #expect(!said.contains("Settings → Cloud") && !said.contains("الإعدادات ← السحابة"))
        #expect(!said.contains("{where}"))
    }

    // ── 4. Find printers is never grey without a reason ───────────────────

    @Test("Find printers runs on any book, and says why Add is off")
    func findPrinters() async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.words.load("en", engine: try KhaytEngine())
        #expect(!shop.canMoveJobs)
        let why = try #require(Shop.findPrintersCaveat(shop))
        #expect(why.contains("sample"))
        let floor = MenuCoverageTests.source("ShopFloor.swift")
        let button = try #require(floor.range(of: "shop.findingPrinters = true"))
        #expect(!floor[button.upperBound...].prefix(400).contains(".disabled(!shop.canMoveJobs)"),
                "Find printers is greyed out again")
    }

    // ── 5. The LAN failure is a sentence ──────────────────────────────────

    @Test("a busy port is said as a sentence with the port in it", arguments: ["en", "ar"])
    func lanFailure(lang: String) async throws {
        let w = try await words(lang)
        let busy = Shop.lanFailure(NWError.posix(.EADDRINUSE), port: 8787, words: w)
        #expect(busy.contains("8787"))
        #expect(!busy.contains("POSIX") && !busy.contains("rawValue"), Comment(rawValue: busy))
        let denied = Shop.lanFailure(NWError.posix(.EACCES), port: 80, words: w)
        #expect(denied.contains("80") && denied != busy)
        let other = Shop.lanFailure(NWError.posix(.ENETDOWN), port: 8787, words: w)
        #expect(!other.contains("POSIXErrorCode"), Comment(rawValue: other))
        #expect(LanServer.plain(NWError.posix(.EADDRINUSE)) == "Address already in use")
    }

    // ── 6. Units and shelves in the shop's language ───────────────────────

    @Test("Arabic says the units and shelves; English keeps the shop's own spelling")
    func unitsAndShelves() async throws {
        let ar = try await words("ar")
        #expect(ar.unitWord("L") == "لتر")
        #expect(ar.unitWord("roll") == "لفة")
        #expect(ar.unitWord("each") == "حبة")
        #expect(ar.unitWord("kg") == "كغ")
        #expect(ar.unitWord("widgets") == "widgets", "an unknown unit is the shop's own word")
        #expect(ar.shelfWord("Cleaning") == "تنظيف")
        #expect(ar.shelfWord(" spares ") == "قطع غيار")
        #expect(ar.shelfWord("Packaging") == ar.callIt("cons.packaging_badge"),
                "the shelf and the badge must fold to one word, or both chips draw")
        #expect(ar.shelfWord("Magnets") == "Magnets")
        let amount = ar.amount("3", "L")
        #expect(amount.hasPrefix("\u{2068}") && amount.hasSuffix("\u{2069}"), "not isolated")
        #expect(amount.contains("3 لتر"))

        let en = try await words("en")
        #expect(en.unitWord("Rolls") == "Rolls")
        #expect(en.shelfWord("Cleaning") == "Cleaning")
    }

    @Test("the stored unit and category are never rewritten")
    func storedValuesUntouched() async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.words.load("ar", engine: try KhaytEngine())
        let units = Set(shop.consumables.compactMap(\.unit))
        #expect(units.isSubset(of: ["L", "each", "roll"]), "\(units)")
        let shelves = Set(shop.consumables.compactMap(\.category))
        #expect(shelves.isSubset(of: ["Cleaning", "Packaging", "Spares"]), "\(shelves)")
    }

    // ── 7. The two price cards say which price they are ───────────────────

    @Test("the shelf's price and the log's price are named apart, in one unit wording", arguments: ["en", "ar"])
    func priceCards(lang: String) async throws {
        let w = try await words(lang)
        #expect(w.callIt("mac.mc_title") != w.callIt("mac.price_history"))
        #expect(!w.callIt("mac.mc_sub").isEmpty && !w.callIt("mac.price_history_sub").isEmpty)
        let shelf = MenuCoverageTests.source("MaterialCost.swift")
        let log = MenuCoverageTests.source("SupplierPrices.swift")
        #expect(shelf.contains("\"mac.mc_per\", [\"unit\": .string(words.unitWord(row.rate))]"))
        #expect(log.contains("\"mac.mc_per\", [\"unit\": .string(shop.words.unitWord(group.unit))]"))
        #expect(!shelf.contains("\\(row.spoolCount)×"), "the bare × that scrambled in Arabic is back")
        #expect(w.counting(3, "mac.mc_spools").contains(lang == "ar" ? "بكرات" : "spools"))
    }

    // ── 8. Expected life opens in the unit it was saved in ────────────────

    @Test("a machine from first-run setup reopens in print hours; one saved in years reopens in years")
    func expectedLife() throws {
        var setup = ShopSetup()
        setup.printer = ShopSetup.Printer()
        setup.printer?.name = "U1"
        setup.printer?.price = 3000
        let form = try #require(setup.machineForm)
        guard case .object(let dep) = form.depreciation else { Issue.record("no depreciation"); return }
        #expect(dep["lifeUnit"] == .string("hours"))
        #expect(dep["life"] == .number(ShopSetup.defaultLifeHours))

        for unit in ["hours", "years"] {
            let json = """
            {"id":"M1","name":"U1","depreciation":{"price":3000,"life":5,"lifeUnit":"\(unit)"}}
            """
            let machine = try JSONDecoder().decode(Machine.self, from: Data(json.utf8))
            #expect(MachineSheet.Form.opening(machine, kind: "fdm").depUnit == unit)
        }
    }

    // ── 9. The status line is words, in the words' face ───────────────────

    @Test("the strip's status is drawn in the body face, not the figure face")
    func statusFace() {
        let shell = MenuCoverageTests.source("Shell.swift")
        #expect(shell.contains("Text(shop.lastSavedLabel)"))
        if let status = shell.range(of: "Text(shop.lastSavedLabel)") {
            let after = shell[status.upperBound...].prefix(1200)
            #expect(after.contains("TypeScale.body(10.5).monospacedDigit()"))
            #expect(!after.contains("TypeScale.figure("), "Arabic words in a monospaced face again")
        }
    }

    // ── 10. Capacity counts its days ──────────────────────────────────────

    @Test("days behind and days to clear take Arabic's number forms")
    func capacityPlurals() async throws {
        let ar = try await words("ar")
        #expect(ar.counting(1, "mac.cap_over") == "متأخر بيوم واحد", Comment(rawValue: ar.counting(1, "mac.cap_over")))
        #expect(ar.counting(2, "mac.cap_over") == "متأخر بيومين")
        #expect(ar.counting(1, "mac.cap_clear_days") == "يخلو خلال يوم واحد")
        #expect(ar.counting(3, "mac.cap_over").hasSuffix("أيام"))
        #expect(ar.counting(12, "mac.cap_over").hasSuffix("يومًا"))
        #expect(ar.counting(4, "mac.cap_clear_days").hasSuffix("أيام"))
        let en = try await words("en")
        #expect(en.counting(1, "mac.cap_over") == "1 day behind")
        #expect(en.counting(3, "mac.cap_over") == "3 days behind")
    }

    // ── 11. An empty log is one state ─────────────────────────────────────

    @Test("an empty expenses or waste log is one empty state, not a split")
    func emptyLogs() {
        let src = MenuCoverageTests.source("Spending.swift")
        #expect(src.contains("if shop.expenses.isEmpty {"))
        #expect(src.contains("if shop.wasteRows.isEmpty {"))
    }

    @Test("every new word exists in English and Arabic")
    func wordsExist() async throws {
        let keys = [
            "mac.add_customer", "mac.integ_cloud_hint", "mac.find_cant_add_sample", "mac.find_cant_add_locked",
            "mac.lan_port_busy", "mac.lan_port_denied", "mac.lan_no_address", "mac.mc_sub", "mac.mc_spools",
            "mac.price_history_sub", "mac.cap_over_one", "mac.cap_over_two", "mac.cap_over_few",
            "mac.cap_clear_days_one", "mac.cap_clear_days_two", "mac.cap_clear_days_few",
        ] + Array(Set(Words.unitKeys.values)) + Array(Set(Words.shelfKeys.values))
        for lang in ["en", "ar"] {
            let w = try await words(lang)
            for key in keys {
                #expect(w.callIt(key) != key, "\(key) has no \(lang) word")
            }
        }
    }
}

/// Pictures of every screen the fixes touch, en/ar × light/dark, through a
/// real `NSHostingView` — `ImageRenderer` cannot host a `Table` or a split
/// view, and the empty customers screen is a table. Writes only when
/// `KHAYT_SNAPSHOT_DIR` is set.
@Suite(.serialized) @MainActor
struct UIPolishDSnapshots {

    private func capture(_ view: some View, _ name: String, _ size: CGSize, lang: String, dark: Bool) {
        guard let dir = SnapshotTests.outputDir else { return }
        let rtl = lang == "ar"
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Khayt.ground))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.userInterfaceLayoutDirection = rtl ? .rightToLeft : .leftToRight
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appending(path: "\(name)-\(lang)-\(dark ? "dark" : "light").png"))
    }

    private func each(_ name: String, _ size: CGSize, _ make: (Shop, String) -> AnyView,
                      sample: Bool = true, prepare: ((Shop) async -> Void)? = nil) async throws {
        guard SnapshotTests.outputDir != nil else { return }
        for lang in ["en", "ar"] {
            let shop = Shop()
            if sample { await shop.load(.sample) }
            await shop.words.load(lang, engine: try KhaytEngine())
            if let prepare { await prepare(shop) }
            for dark in [false, true] {
                capture(make(shop, lang), name, size, lang: lang, dark: dark)
            }
        }
    }

    @Test("the strip on each screen, at 1100 and at the 900 minimum")
    func strips() async throws {
        let screens: [(String, Shop.Shelf)] = [
            ("jobs", .jobs(nil)), ("customers", .customers), ("catalogue", .catalogue),
            ("inventory", .inventory), ("machines", .machines), ("library", .library(nil)),
            ("expenses", .expenses),
        ]
        for (name, shelf) in screens {
            for width in [1100.0, 900.0] {
                try await each("d1-strip-\(name)-\(Int(width))", CGSize(width: width, height: 40), { shop, _ in
                    shop.shelf = shelf
                    return AnyView(ShellTitleBar(shop: shop, searchWanted: .constant(false)))
                })
            }
        }
    }

    @Test("customers, expenses and waste with nothing in them")
    func empties() async throws {
        try await each("d1-customers-empty", CGSize(width: 900, height: 480), { shop, _ in
            AnyView(CustomersTable(shop: shop))
        }, sample: false)
        try await each("d1-expenses-empty", CGSize(width: 900, height: 480), { shop, _ in
            AnyView(Expenses(shop: shop))
        }, sample: false)
        try await each("d1-waste-empty", CGSize(width: 900, height: 480), { shop, _ in
            AnyView(Waste(shop: shop))
        }, sample: false)
    }

    @Test("integrations, online with a busy port, the inventory cards, machines and capacity")
    func panes() async throws {
        try await each("d1-integrations", CGSize(width: 640, height: 520), { shop, _ in
            AnyView(IntegrationsPane(shop: shop))
        })
        try await each("d1-online-busy-port", CGSize(width: 640, height: 900), { shop, _ in
            shop.lanProblem = Shop.lanFailure(NWError.posix(.EADDRINUSE), port: 8787, words: shop.words)
            return AnyView(OnlinePane(shop: shop))
        })
        try await each("d1-consumables", CGSize(width: 720, height: 360), { shop, _ in
            AnyView(ConsumablesCard(needs: [], shop: shop).card(padding: 14).padding(16))
        })
        var cost: KhaytEngine.MaterialCost?
        var paid: [KhaytEngine.PriceGroup] = []
        try await each("d1-price-cards", CGSize(width: 720, height: 640), { shop, _ in
            AnyView(VStack(spacing: 14) {
                MaterialCostCard(shop: shop, report: cost).card(rail: Khayt.brand, padding: 14)
                if !paid.isEmpty {
                    SupplierPricesCard(shop: shop, groups: paid).card(rail: Khayt.brand, padding: 14)
                }
                Spacer(minLength: 0)
            }.padding(16))
        }, prepare: { shop in
            cost = await shop.materialCost()
            paid = await shop.supplierPrices()
        })
        var load: KhaytEngine.Capacity?
        try await each("d1-capacity", CGSize(width: 720, height: 300), { shop, _ in
            AnyView(CapacityCard(shop: shop, report: load).card(rail: Khayt.brand, padding: 14).padding(16))
        }, prepare: { shop in load = await shop.capacity() })
        try await each("d1-machines", CGSize(width: 1000, height: 700), { shop, _ in
            AnyView(Machines(shop: shop).environment(shop.cameras))
        })
    }

    @Test("the machine's Value tab for a machine first-run setup wrote")
    func valueTab() async throws {
        MachineSheet.opensOn = "value"
        defer { MachineSheet.opensOn = "printer" }
        try await each("d1-value-tab-setup", CGSize(width: MachineSheet.width, height: 560), { shop, _ in
            let json = """
            {"id":"M9","name":"U1","depreciation":{"price":3000,"life":5000,"lifeUnit":"hours","method":"perHour"}}
            """
            let machine = try! JSONDecoder().decode(Machine.self, from: Data(json.utf8))
            return AnyView(MachineSheet(shop: shop, existing: machine))
        })
    }
}
