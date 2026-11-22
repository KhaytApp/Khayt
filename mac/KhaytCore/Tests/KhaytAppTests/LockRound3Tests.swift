import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The alpha.62 re-check of the staff lock, round 3.
@Suite(.serialized) @MainActor
struct LockRound3Tests {

    static func shop() async -> Shop { await OperatorLockTests.shop() }
    static func notAllowed(_ shop: Shop) -> String { shop.words.callIt("mac.lock_not_allowed") }
    static func signInFirst(_ shop: Shop) -> String { shop.words.callIt("mac.lock_sign_in_first") }
    static func source(_ file: String) throws -> String { try LockRecheckTests.source(file) }

    /// The text of `func name(` to its closing brace, as the ratchet reads it.
    static func body(_ name: String, in file: String) throws -> String {
        let src = WritersAreGatedTests.parse(file, try source(file))
        return try #require(src.functions.first { $0.name == name }).text
    }

    // 1
    @Test("the once-a-minute auto-off runs with the lock on and nobody signed in; a person's switch still asks")
    func plugAutoOffUnderTheLock() async throws {
        let shop = await Self.shop()
        #expect(shop.needsSignIn)
        let machine = try #require(shop.machines.first)
        // The shop's own rule: not refused — it goes on to the plug (which the
        // sample book has none of, so it stops there, saying nothing).
        await shop.performPlugSwitch(machine, on: false)
        #expect(shop.plugProblem[machine.id] == nil)
        // A person at the Mac, nobody signed in: refused, and told why.
        await shop.switchPlug(machine, on: false)
        #expect(shop.plugProblem[machine.id] == Self.signInFirst(shop))
        // And the timer uses that, not the gated switch.
        let tick = try Self.body("plugTick", in: "Shop.swift")
        #expect(tick.contains("performPlugSwitch(machine, on: false)"))
        #expect(!tick.contains("switchPlug("))
        let perform = try Self.body("performPlugSwitch", in: "Shop.swift")
        #expect(!WritersAreGatedTests.asksTheLock(perform))
        #expect(try Self.body("switchPlug", in: "Shop.swift").contains("permitted(\"orders\", \"edit\")"))
    }

    // 2
    @Test("listing a product on the web store from its sheet asks what the web store switch asks")
    func productListingAsksSettings() async throws {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)   // operator: inventory/edit, no settings/edit
        var product = Product(id: "PROD-r3", names: ["en": "Dallah stand"], descriptions: [:],
                              margin: 35, group: "", category: "", createdAt: "2026-09-01", rest: [:])
        product.onWebStore = false
        await shop.saveProduct(product)
        #expect(shop.moveProblem == Self.notAllowed(shop))
        // Unchanged listing: past the lock (to the sample book's own refusal).
        product.onWebStore = true
        await shop.saveProduct(product)
        #expect(shop.moveProblem == shop.words.callIt("mac.move_sample"))
        #expect(try Self.source("ProductSheet.swift")
            .contains(".disabled(!shop.lockAllows(\"settings\", \"edit\"))"))
    }

    // 3
    @Test("the shop's money is not shown to anybody without analytics: masthead, ledger, owed, Ask the Book")
    func moneyNeedsAnalytics() async throws {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        #expect(!shop.lockAllows("analytics", "view"))
        #expect(Triage.shownMode(.ledger, shop: shop) == .triage)
        shop.askingTheBook = true
        await shop.ask("how much did we make?")
        #expect(shop.asked.isEmpty && !shop.askingTheBook)
        await #expect(throws: (any Error).self) { _ = try await AiClient.ask("revenue?", history: [], shop: shop) }

        shop.lockNow()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        #expect(Triage.shownMode(.ledger, shop: shop) == .ledger)

        let triage = try Self.source("Triage.swift")
        let masthead = try #require(triage.range(of: "MoneyMasthead("))
        #expect(triage[..<masthead.lowerBound].suffix(200).contains("lockAllows(\"analytics\", \"view\")"))
        let window = try Self.source("ShopWindow.swift")
        let owed = try #require(window.range(of: "OwedSummary(shop: shop)"))
        #expect(window[..<owed.lowerBound].suffix(200).contains("lockAllows(\"analytics\", \"view\")"))
        let menus = try Self.source("Menus.swift")
        let ask = try #require(menus.range(of: "mac.ask_the_book"))
        #expect(menus[ask.upperBound...].prefix(200).contains(".disabled(!shop.lockAllows(\"analytics\", \"view\"))"))
    }

    // 5
    @Test("the kiosk scene adds no Window-menu item that would open it past the lock")
    func kioskSceneHasNoCommands() throws {
        let app = try Self.source("KhaytApp.swift")
        let kiosk = try #require(app.range(of: "id: KioskWindow.id) {"))
        // The scene's own modifiers: up to the next scene.
        let scene = app[kiosk.upperBound...].prefix(900)
        #expect(scene.contains(".commandsRemoved()"))
        #expect(try Self.source("Kiosk.swift").contains("(`.commandsRemoved()` in KhaytApp.swift)"),
                "the kiosk's header says how a new one is kept behind the lock")
    }

    // 6
    @Test("Spotlight holds nothing while the lock is switched on")
    func spotlightEmptyUnderTheLock() async throws {
        let shop = await Self.shop()
        // The sample is never indexed; the rule is the lock, on a real book.
        #expect(Spotlight.indexable(source: .sample, files: shop.files, wanted: true, lockOn: false) == nil)
        let real = Shop.Source.store(.shipped)
        #expect(Spotlight.indexable(source: real, files: shop.files, wanted: true, lockOn: true) == nil)
        #expect(Spotlight.indexable(source: real, files: shop.files, wanted: true, lockOn: false) != nil)
        #expect(try Self.source("Spotlight.swift").contains("lockOn: shop.lockSwitchedOn"))
    }

    // classic sidebar
    @Test("the classic sidebar shows no counts or group names behind the lock")
    func classicSidebarEmpty() throws {
        let body = try Self.source("Sidebar.swift")
        let start = try #require(body.range(of: "struct Sidebar: View {"))
        let head = body[start.upperBound...].prefix(700)
        #expect(head.contains("if shop.needsSignIn {"))
        #expect(head.contains("List { EmptyView() }"))
    }

    // 4: the person paths the ratchet now reaches
    @Test("Rescan and Free Up Space ask the lock; the load-time rescan is the system's")
    func libraryHousekeepingAsks() async throws {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)   // viewer
        await shop.rescanLinkedFolders()
        #expect(shop.moveProblem == Self.notAllowed(shop))
        await shop.freeUpSpace(only: [])
        #expect(shop.cloudLibraryProblem == Self.notAllowed(shop))
        #expect(try Self.source("Shop.swift").contains("rescanLinkedFolders(byPerson: false)"))
    }
}
