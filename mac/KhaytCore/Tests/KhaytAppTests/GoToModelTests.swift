import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// ⌘K's palette state, driven without a window, against the sample book.
///
/// The bug these hold down (Oct 2026, built from 303e93c5): ⌘K, "dent" typed
/// fast, and the palette showed every SCREEN under the headings of the real
/// answer — "Library" over Dashboard and Jobs, "Catalogue" over Board — and
/// never drew "Dental model set". Nothing here asserts a latency: the only
/// wait is a hang guard.
@MainActor
struct GoToModelTests {

    static func sample() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    static func titles(_ model: GoToModel, _ kind: GoToIndex.Kind) -> [String] {
        model.sections.first { $0.kind == kind }?.rows.map(\.entry.title) ?? []
    }

    /// Every heading sits over rows of its own kind, under its own words; the
    /// rows are numbered in the order they are drawn; nothing is drawn twice.
    static func expectAligned(_ model: GoToModel, _ shop: Shop, sourceLocation: SourceLocation = #_sourceLocation) {
        var next = 0
        var ids = Set<String>()
        #expect(Set(model.sections.map(\.id)).count == model.sections.count, "two headings share an identity",
                sourceLocation: sourceLocation)
        for section in model.sections {
            #expect(section.title == shop.words.callIt("mac.goto_group_" + section.kind.rawValue),
                    sourceLocation: sourceLocation)
            #expect(!section.rows.isEmpty, "a heading with nothing under it", sourceLocation: sourceLocation)
            for row in section.rows {
                #expect(row.entry.kind == section.kind,
                        "\(row.entry.title) (\(row.entry.kind)) is under the \(section.kind) heading",
                        sourceLocation: sourceLocation)
                #expect(row.index == next, "rows are not numbered in the order drawn", sourceLocation: sourceLocation)
                #expect(ids.insert(row.id).inserted, "\(row.id) drawn twice", sourceLocation: sourceLocation)
                next += 1
            }
        }
        #expect(model.rows.count == next, sourceLocation: sourceLocation)
    }

    @Test("typing d, de, den, dent finds Dental model set and no Dashboard; dash finds Dashboard")
    func typingDent() async {
        let shop = await Self.sample()
        let model = GoToModel(shop: shop)
        await model.load()
        #expect(!model.loading)
        // Nothing typed: every screen, one heading.
        #expect(model.sections.map(\.kind) == [.screen])
        #expect(Self.titles(model, .screen).contains("Dashboard"))
        Self.expectAligned(model, shop)

        // Each keystroke in turn — the narrowing path, each query extending
        // the last.
        for q in ["d", "de", "den", "dent"] {
            model.query = q
            await model.search()
            #expect(model.answer.query == q)
            Self.expectAligned(model, shop)
        }
        #expect(Self.titles(model, .job).contains("Dental model set"))
        #expect(!Self.titles(model, .screen).contains("Dashboard"), "a screen that does not match \"dent\" was listed")
        #expect(model.sections.first?.kind != .screen)
        #expect(model.cursor == 0)

        // The same answer as one search from nothing, without the narrowing.
        let fresh = GoToModel(shop: shop)
        await fresh.load()
        fresh.query = "dent"
        await fresh.search()
        #expect(fresh.answer == model.answer)

        model.query = "dash"
        await model.search()
        #expect(model.sections.first?.kind == .screen)
        #expect(Self.titles(model, .screen).first == "Dashboard")
        #expect(!Self.titles(model, .screen).contains("Board"))
        Self.expectAligned(model, shop)
    }

    @Test("a query typed before the index is built is answered once it is")
    func queryBeforeIndex() async {
        let shop = await Self.sample()
        #expect(shop.goToCache == nil, "the test needs the index still to build")
        let model = GoToModel(shop: shop)

        // The keystroke's search runs before the index exists: the screens
        // answer alone, the palette says it is loading, and "nothing matches"
        // is not what it says.
        model.query = "dent"
        await model.search()
        #expect(model.loading)
        #expect(model.answer.query == "dent")
        #expect(model.sections.isEmpty, "no screen holds \"dent\"")

        // The index arrives — and answers the query in the field.
        await model.load()
        #expect(!model.loading)
        #expect(model.answer.query == "dent")
        #expect(Self.titles(model, .job).contains("Dental model set"))
        #expect(!Self.titles(model, .screen).contains("Dashboard"))
        Self.expectAligned(model, shop)
    }

    @Test("the field changed while the index was building: the newest query is answered")
    func queryChangedDuringBuild() async {
        let shop = await Self.sample()
        let model = GoToModel(shop: shop)
        let building = Task { await model.load() }
        model.query = "dent"
        await building.value
        #expect(model.answer.query == "dent")
        #expect(Self.titles(model, .job).contains("Dental model set"))
        Self.expectAligned(model, shop)
    }

    @Test("a burst of searches in flight together: only the newest query's answer stays")
    func staleAnswersDropped() async throws {
        let shop = await Self.sample()
        let model = GoToModel(shop: shop)
        await model.load()
        var inFlight: [Task<Void, Never>] = []
        for q in ["d", "de", "den", "dent"] {
            model.query = q
            inFlight.append(Task { await model.search() })
            await Task.yield()
        }
        // A hang guard, not a latency check.
        try await withThrowingTaskGroup(of: Void.self) { group in
            let tasks = inFlight
            group.addTask { for t in tasks { await t.value } }
            group.addTask { try await Task.sleep(for: .seconds(600)); throw CancellationError() }
            try await group.next()
            group.cancelAll()
        }
        #expect(model.answer.query == "dent")
        #expect(Self.titles(model, .job).contains("Dental model set"))
        #expect(!Self.titles(model, .screen).contains("Dashboard"))
        Self.expectAligned(model, shop)
    }

    @Test("the cursor walks the rows in the order drawn and opens what it is on")
    func cursorOpens() async throws {
        let shop = await Self.sample()
        let model = GoToModel(shop: shop)
        await model.load()
        model.query = "dent"
        await model.search()
        let rows = model.rows
        let job = try #require(rows.first { $0.entry.kind == .job && $0.entry.title == "Dental model set" })
        model.move(job.index)
        #expect(model.selected == job)
        model.move(-1000)
        #expect(model.cursor == 0)
        model.move(1000)
        #expect(model.cursor == rows.count - 1)
        shop.goingTo = true
        model.open(job)
        #expect(shop.shelf == .jobs(nil))
        #expect(shop.selection == job.entry.id)
        #expect(!shop.goingTo)
    }

    @Test("the headings are built from the answer they head")
    func headingsTravelWithRows() {
        let screens = GoToIndex([
            .init(kind: .screen, id: "screen:dashboard", title: "Dashboard", fields: ["Dashboard"]),
            .init(kind: .screen, id: "screen:library", title: "Library", fields: ["Library"]),
        ])
        let book = GoToIndex([
            .init(kind: .model, id: "m1", title: "Dental upper", fields: ["Dental upper"]),
            .init(kind: .model, id: "m2", title: "Dental lower", fields: ["Dental lower"]),
            .init(kind: .product, id: "p1", title: "Dental set", fields: ["Dental set"]),
            .init(kind: .job, id: "j1", title: "Dental model set", fields: ["Dental model set"]),
            .init(kind: .customer, id: "j1", title: "Dental studio", fields: ["Dental studio"]),
        ])
        let kinds = Set(GoToIndex.Kind.allCases)
        let answer = GoToModel.answer("dent", screens: screens, book: book.search("dent", kinds: kinds),
                                      kinds: kinds, bookReady: true, perGroup: 8, title: { "H:" + $0.rawValue })
        #expect(!answer.loading)
        for section in answer.sections {
            #expect(section.title == "H:" + section.kind.rawValue)
            #expect(section.rows.allSatisfy { $0.entry.kind == section.kind })
        }
        #expect(answer.sections.flatMap(\.rows).map(\.index) == Array(0..<5))
        // A job and a customer that share an id are still two rows.
        #expect(Set(answer.sections.flatMap(\.rows).map(\.id)).count == 5)
        #expect(!answer.sections.contains { $0.kind == .screen })

        // Before the book is ready: the screens' own matches, and loading.
        let early = GoToModel.answer("lib", screens: screens, book: nil, kinds: kinds,
                                     bookReady: false, perGroup: 8, title: { $0.rawValue })
        #expect(early.loading)
        #expect(early.sections.map { $0.rows.map(\.entry.title) } == [["Library"]])
        // Nothing typed is never "loading": the screens are the whole answer.
        #expect(!GoToModel.answer("", screens: screens, book: nil, kinds: kinds,
                                  bookReady: false, perGroup: 8, title: { $0.rawValue }).loading)
    }
}
