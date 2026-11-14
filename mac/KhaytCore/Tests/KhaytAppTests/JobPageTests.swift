import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Jobs ▸ List and the job page (S1 B1, Figma 90:768): the third view, the
/// pinned next step from `lib/order-next-step.js`, and the stamp that says a
/// quote has gone out.
@MainActor
struct JobPageTests {

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    @Test("three views; a window saved as \"list\" is still the Table")
    func layouts() {
        #expect(Shop.JobsLayout.allCases == [.board, .page, .list], "Board · List · Table")
        #expect(Shop.JobsLayout(rawValue: "list") == .list)
        #expect(Shop.JobsLayout.list.titleKey == "mac.view_table")
        #expect(Shop.JobsLayout.page.titleKey == "mac.view_list")
        #expect(Shop.JobsLayout(rawValue: "page") == .page)
        // New windows still open on the Table: nothing defaults to List yet.
        #expect(Shop().jobsLayout == .list)
        #expect(MenuCoverageTests.source("ShopWindow.swift")
            .contains("@SceneStorage(\"jobs.layout\") private var storedJobsLayout = Shop.JobsLayout.list.rawValue"))
    }

    @Test("the List shows the page, any stage, and has no side panel beside it")
    func showing() async {
        let shop = await Self.shop()
        shop.shelf = .jobs(nil)
        #expect(!shop.showingJobPage)
        shop.chooseJobsLayout(.page)
        #expect(shop.showingJobPage && !shop.showingBoard)
        shop.shelf = .jobs(.printing)
        #expect(shop.showingJobPage, "a stage filters the list, as it filters the table")
        shop.shelf = .customers
        #expect(!shop.showingJobPage)
        let window = MenuCoverageTests.source("ShopWindow.swift")
        #expect(window.contains("&& !shop.showingJobPage"))
        #expect(window.contains("JobsList(shop: shop)"))
    }

    @Test("every step the rule can name has a word, in every language the Mac speaks")
    func words() async {
        let shop = await Self.shop()
        let codes = ["send_quote", "take_job", "start_printing", "mark_printed", "send_to_check", "mark_ready",
                     "resume", "hand_over", "record_payment", "hold", "ship", "fail_check"]
        for code in codes {
            let key = try? #require(Shop.stepTitleKey(code), "\(code)")
            guard let key else { continue }
            let said = shop.words.callIt(key)
            #expect(said != key && !said.isEmpty, "\(code): \(key)")
        }
        #expect(Shop.stepTitleKey("something_newer") == nil, "an unknown code is not shown raw")
        // Every code the sample book's rule answers with is one of these.
        for steps in shop.nextSteps.values {
            for step in [steps.primary].compactMap({ $0 }) + steps.secondary {
                #expect(Shop.stepTitleKey(step.code) != nil, "\(step.code)")
            }
        }
    }

    @Test("a step that cannot be done says why; one that can, says nothing")
    func refusals() async throws {
        let shop = await Self.shop()
        defer { shop.pretendsControl = false }
        let printing = try #require(shop.orders.first { Stage.of($0) == .printing })
        let step = try #require(shop.pageSteps(for: printing)?.primary)
        #expect(step.code == "mark_printed")
        // The sample is not a book this Mac may change.
        #expect(shop.stepRefusal(step) == shop.words.callIt("mac.jp_read_only"))
        shop.pretendsControl = true
        #expect(shop.stepRefusal(step) == nil)
        // The gate's refusal, in the gate's own words.
        let paused = KhaytEngine.NextSteps.Step(code: "start_printing", to: "printing", asks: nil,
                                                blocked: .init(code: "production_paused", params: [:]))
        #expect(shop.stepRefusal(paused) == shop.words.callIt("prod.paused_block"))
        // An answer for a stage the job has left is not used.
        let pending = try #require(shop.orders.first { Stage.of($0) == .pending })
        shop.nextSteps[printing.id] = shop.nextSteps[pending.id]
        #expect(shop.pageSteps(for: printing) == nil)
    }

    @Test("steps that open a sheet open it; a refused step does nothing")
    func taking() async throws {
        let shop = await Self.shop()
        defer { shop.pretendsControl = false; shop.pendingPayment = nil; shop.pendingInvoice = nil }
        let job = try #require(shop.orders.first { Stage.of($0) == .printing })
        let pay = KhaytEngine.NextSteps.Step(code: "record_payment", to: nil, asks: "payment", blocked: nil)
        shop.takeStep(pay, on: job)
        #expect(shop.pendingPayment == nil, "the sample may not be changed")
        shop.pretendsControl = true
        shop.takeStep(pay, on: job)
        #expect(shop.pendingPayment?.id == job.id)
        let send = KhaytEngine.NextSteps.Step(code: "send_quote", to: nil, asks: "send", blocked: nil)
        shop.takeStep(send, on: job)
        #expect(shop.pendingInvoice?.id == job.id)
        // Blocked by the gate: nothing opens.
        shop.pendingPayment = nil
        let blocked = KhaytEngine.NextSteps.Step(code: "record_payment", to: nil, asks: nil,
                                                 blocked: .init(code: "read_only", params: [:]))
        shop.takeStep(blocked, on: job)
        #expect(shop.pendingPayment == nil)
    }

    @Test("a quote is stamped as shared wherever it really goes out")
    func quoteSharedIsWired() async throws {
        let portal = MenuCoverageTests.source("PortalSheets.swift")
        #expect(portal.components(separatedBy: "await shop.noteQuoteShared(job.id)").count - 1 == 5,
                "publish, WhatsApp (app and copied fallback), email, copy")
        #expect(MenuCoverageTests.source("InvoiceSheet.swift").contains("await shop.noteQuoteShared(subject.id)"))
        #expect(MenuCoverageTests.source("Shop+Quotes.swift").contains("await noteQuoteShared(id)"))
        // Only a quote, only once, and never on the sample: no write is tried.
        let shop = await Self.shop()
        let quote = try #require(shop.orders.first { $0.status == "quote" })
        await shop.noteQuoteShared(quote.id)
        #expect(shop.writeProblem == nil || shop.source.build == nil)
        let code = MenuCoverageTests.source("Shop+JobPage.swift")
        #expect(code.contains("o[\"status\"] == .string(\"quote\")"))
        #expect(code.contains("Self.plainString(o[\"quoteSharedAt\"]) == nil"))
        #expect(code.contains("write(as: .person(\"orders\", \"edit\"))"))
    }

    @Test("the page reuses the inspector's sections, and the next step is never hidden")
    func pageIsBuiltFromTheSameParts() {
        let page = MenuCoverageTests.source("JobPage.swift")
        #expect(page.contains("JobDetail(job: job, shop: shop, split: split, embedded: true)"))
        #expect(page.contains("NextStepBar(job: job, steps: steps, shop: shop)"))
        #expect(page.contains("mac.jp_nothing_next"))
        #expect(page.contains(".disabled(shop.stepRefusal(step) != nil)"))
        let inspector = MenuCoverageTests.source("OrderInspector.swift")
        #expect(inspector.contains("if !embedded { header }"))
        #expect(inspector.contains("shop.nextStep(for: job.id)"), "the inspector's own button is unchanged")
    }

    @Test("the list leads with open work; finished and cancelled jobs follow, newest first")
    func listOrder() async {
        let shop = await Self.shop()
        let rows = JobsList.ordered(shop.orders)
        #expect(rows.count == shop.orders.count)
        let over: Set<Stage> = [.completed, .shipped, .delivered, .cancelled]
        let firstOver = rows.firstIndex { Stage.of($0).map(over.contains) ?? false } ?? rows.count
        #expect(rows[..<firstOver].allSatisfy { !(Stage.of($0).map(over.contains) ?? false) })
        #expect(rows[firstOver...].allSatisfy { Stage.of($0).map(over.contains) ?? false }, "no open job below a finished one")
        #expect(firstOver > 0, "the sample has open work")
    }
}
