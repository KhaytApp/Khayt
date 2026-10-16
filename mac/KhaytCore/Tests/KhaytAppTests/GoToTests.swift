import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// ⌘K on a real book: what is indexed, when it is rebuilt, who sees what,
/// which commands are offered, and where a row goes when it is opened.
@MainActor
struct GoToTests {

    static func sample() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    static func first(_ r: GoToIndex.Result, _ kind: GoToIndex.Kind) -> GoToIndex.Entry? {
        r.groups.first { $0.kind == kind }?.hits.first?.entry
    }

    // MARK: - The index

    @Test("the index is built once per change to the book, not per open or per keystroke")
    func builtOncePerChange() async {
        let shop = await Self.sample()
        let builds = shop.goToBuilds
        let one = await shop.goToIndex()
        let two = await shop.goToIndex()
        #expect(shop.goToBuilds == builds + 1, "a second open rebuilt an unchanged index")
        #expect(one.count == two.count && one.count > 0)
        for q in ["k", "ki", "kin", "king"] { _ = two.search(q) }
        #expect(shop.goToBuilds == builds + 1, "typing rebuilt the index")

        // A change to the book is a new index.
        shop.machines = Array(shop.machines.dropLast())
        let three = await shop.goToIndex()
        #expect(shop.goToBuilds == builds + 2)
        #expect(three.count == one.count - 1)
    }

    @Test("jobs by number, invoice or customer; customers; models; machines — from the sample")
    func indexesTheBook() async throws {
        let shop = await Self.sample()
        let index = await shop.goToIndex()
        let job = try #require(shop.orders.first { !$0.client.isEmpty })

        // By the id, by the number in it typed in Arabic-Indic digits, and by
        // the customer's name.
        #expect(Self.first(index.search(job.id), .job)?.id == job.id)
        let number = GoToBook.number(job.id)
        let arabic = String(number.map { c in Character(Unicode.Scalar(c.unicodeScalars.first!.value - 0x30 + 0x0660)!) })
        #expect(index.search(arabic).groups.first { $0.kind == .job }?.hits.contains { $0.entry.id == job.id } == true,
                "\(arabic) did not find \(job.id)")
        #expect(index.search(job.client).groups.contains { $0.kind == .customer })

        let machine = try #require(shop.machines.first)
        #expect(Self.first(index.search(machine.name), .machine)?.id == machine.id)

        let model = try #require(shop.files.first { !$0.isArchived })
        #expect(index.search(model.title).groups.first { $0.kind == .model }?.hits.contains { $0.entry.id == model.id } == true)
    }

    @Test("an invoice number is read under either spelling, and as a number")
    func invoiceNumberDecodes() throws {
        for json in [#"{"id":"A","invoiceNumber":"INV-7"}"#, #"{"id":"A","invoiceNum":"INV-7"}"#] {
            let order = try JSONDecoder().decode(Order.self, from: Data(json.utf8))
            #expect(order.invoiceNumber == "INV-7")
        }
        let numeric = try JSONDecoder().decode(Order.self, from: Data(#"{"id":"A","invoiceNum":42}"#.utf8))
        #expect(numeric.invoiceNumber == "42")
        let none = try JSONDecoder().decode(Order.self, from: Data(#"{"id":"A","invoiceNum":null}"#.utf8))
        #expect(none.invoiceNumber == nil)
        #expect(GoToBook.number("ORD-01002") == "1002")
        #expect(GoToBook.number("INV-2026-0042") == "42")
        #expect(GoToBook.digits("+966 55 123 4567") == "966551234567")
    }

    // MARK: - Going there

    @Test("opening a row goes to its screen and selects it, as the sidebar and dashboard do")
    func navigates() async throws {
        let shop = await Self.sample()
        let index = await shop.goToIndex()
        shop.goingTo = true

        let job = try #require(shop.orders.first)
        shop.search = "something that hides it"
        shop.goTo(try #require(Self.first(index.search(job.id), .job)))
        #expect(shop.shelf == .jobs(nil))
        #expect(shop.selection == job.id)
        #expect(shop.search.isEmpty)
        #expect(!shop.goingTo, "the palette closes when it goes somewhere")

        let customer = try #require(shop.customers.first)
        shop.goTo(try #require(index.entries.first { $0.kind == .customer && $0.id == customer.id }))
        #expect(shop.shelf == .customers)
        #expect(shop.customerSelection == customer.id)

        let model = try #require(shop.files.first { !$0.isArchived })
        shop.goTo(try #require(index.entries.first { $0.kind == .model && $0.id == model.id }))
        #expect(shop.showingLibrary)
        #expect(shop.fileSelection == [model.id])

        if let product = shop.catalogueRows.first {
            shop.goTo(try #require(index.entries.first { $0.kind == .product && $0.id == product.id }))
            #expect(shop.shelf == .catalogue)
            #expect(shop.catalogueSelection == product.id)
        }

        shop.goTo(try #require(index.entries.first { $0.kind == .machine }))
        #expect(shop.shelf == .machines)

        let screens = shop.goToScreens()
        shop.goTo(try #require(screens.entries.first { $0.id == "screen:board" }))
        #expect(shop.shelf == .board)
    }

    // MARK: - Permissions

    @Test("nobody signed in: nothing to search and ⌘K is off")
    func signedOutSeesNothing() async {
        let shop = await OperatorLockTests.shop()
        #expect(shop.needsSignIn)
        #expect(shop.goToKinds.isEmpty)
        #expect(!shop.canGoToAnything)
        #expect(shop.goToScreens().entries.isEmpty)
        let index = await shop.goToIndex()
        #expect(index.search("a", kinds: shop.goToKinds).groups.isEmpty)
        // A row reached anyway — a palette left open as the lock came down —
        // goes nowhere.
        let before = shop.shelf
        if let job = index.entries.first(where: { $0.kind == .job }) { shop.goTo(job) }
        #expect(shop.shelf == before)
    }

    @Test("an operator: jobs and customers yes, Reports no — the sidebar's own gates")
    func operatorGates() async {
        let shop = await OperatorLockTests.shop()
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        #expect(shop.canGoToAnything)
        #expect(shop.goToKinds.isSuperset(of: [.job, .customer, .screen]))
        let ids = Set(shop.goToScreens().entries.map(\.id))
        #expect(!ids.contains("screen:reports"), "an operator may not open Reports")
        #expect(ids.contains("screen:customers"))
        #expect(ids.contains("screen:jobs"))
    }

    @Test("a Simple shop is not offered the screens Simple does not include")
    func modeGates() async {
        let shop = await Self.sample()
        shop.pretendMode("simple")
        await shop.readFeatures()
        let ids = Set(shop.goToScreens().entries.map(\.id))
        #expect(ids.contains("screen:expenses") == shop.canShow(.expenses))
        #expect(ids.contains("screen:reports") == shop.canShow(.reports))
    }

    // MARK: - Commands

    @Test("each command is offered exactly when its menu item is enabled")
    func commandEnablement() {
        typealias F = GoToCommand.Facts
        let none = F(canMoveJobs: false, hasJob: false, importing: false)
        let writable = F(canMoveJobs: true, hasJob: false, importing: false)
        let withJob = F(canMoveJobs: true, hasJob: true, importing: false)
        let importing = F(canMoveJobs: true, hasJob: true, importing: true)

        #expect(GoToCommand.allCases.filter { $0.isEnabled(none) } == [.scan],
                "a read-only book offers only what writes nothing")
        #expect(GoToCommand.newJob.isEnabled(writable))
        #expect(!GoToCommand.recordPayment.isEnabled(writable), "no job selected, nothing to pay")
        #expect(!GoToCommand.editJob.isEnabled(writable))
        #expect(GoToCommand.recordPayment.isEnabled(withJob))
        #expect(GoToCommand.editJob.isEnabled(withJob))
        #expect(!GoToCommand.addModel.isEnabled(importing), "a second import over a running one")
        #expect(GoToCommand.addModel.isEnabled(withJob))
    }

    @Test("the sample is read-only, so the palette offers no write — and running one anyway does nothing")
    func sampleOffersNoWrites() async {
        let shop = await Self.sample()
        #expect(!shop.canMoveJobs)
        let ids = Set(shop.goToScreens().entries.map(\.id))
        #expect(!ids.contains("command:newJob"))
        #expect(!ids.contains("command:recordPayment"))
        #expect(ids.contains("command:scan"))
        GoToCommand.newJob.run(on: shop)
        #expect(!shop.takingAJob)
    }

    @Test("every command and group has words in both languages")
    func wordsExist() {
        var keys = GoToCommand.allCases.map(\.titleKey)
        keys += GoToIndex.Kind.allCases.map { "mac.goto_group_" + $0.rawValue }
        keys += ["mac.goto", "mac.goto_prompt", "mac.goto_screen", "mac.goto_command", "mac.goto_none", "mac.goto_hint"]
        keys += Shop.goToShelves.map(Shop.titleKey(of:))
        for key in keys where key.hasPrefix("mac.goto") {
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key) has no English")
            #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) has no Arabic")
        }
    }

    // MARK: - The menu

    @Test("Go ▸ Go to… is ⌘K and opens the palette; the kiosk keeps ⌃⌘K")
    func menuItem() {
        let menus = MenuCoverageTests.menus
        #expect(menus.contains("Button(Words.upfront(\"mac.goto\") + \"\\u{2026}\") { shop.goingTo = true }"))
        #expect(menus.contains(".keyboardShortcut(\"k\")\n"), "⌘K is not on Go to…")
        #expect(menus.contains(".keyboardShortcut(\"k\", modifiers: [.control, .command])"), "the kiosk lost ⌃⌘K")
        #expect(menus.contains(".disabled(!shop.canGoToAnything)"))
        let window = MenuCoverageTests.source("ShopWindow.swift")
        #expect(window.components(separatedBy: ".overlay { goTo }").count == 3, "the palette is missing from a shell")
        let help = ["en", "ar"].map { MenuCoverageTests.source("Help/\($0)/shortcuts.md") }
        #expect(help.allSatisfy { $0.contains("**⌘K**") }, "the Help shortcuts page does not list ⌘K")
    }

    @Test("the palette is put away with every other sheet when the lock comes down")
    func dismissedOnLock() async {
        let shop = await Self.sample()
        shop.goingTo = true
        shop.dismissEverySheet()
        #expect(!shop.goingTo)
    }
}
