import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Library Health on the Mac, and the Print next mark it sits beside.
///
/// The groups themselves are `LibraryHealthTests` (KhaytCore). This is the
/// wiring: the facts the app hands the rule, the Remove fix going through the
/// library's own delete question with the exact count, and the Print next
/// write — on the record, gated, and cleared by the job that prints it.
@MainActor
@Suite(.serialized)
struct LibraryHealthAppTests {

    // MARK: - The groups, from the shop

    static func sampleWithProblems() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        let (rows, presence) = Snapshot.healthRows(shop.libraryRows)
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.pretendHealthPresence = presence
        shop.pretendProducts(shop.productRows + [Snapshot.orphanProduct])
        return shop
    }

    @Test("the sample with one of each problem shows every group, and the right models in each")
    func everyGroup() async {
        let shop = await Self.sampleWithProblems()
        await shop.checkLibraryHealth()
        let groups = shop.libraryHealthGroups ?? []
        func ids(_ kind: LibraryHealth.Kind) -> [String] { groups.first { $0.kind == kind }?.modelIds ?? [] }
        #expect(Set(ids(.missing)) == ["PF-sample-king-6", "PF-sample-gripper"])
        #expect(ids(.onlineUnmeasured) == ["PF-snap-vase-online"])
        // The sample's locked member (inside an encrypted 7-Zip) has no
        // figures either: it is never opened.
        #expect(Set(ids(.noFigures)) == ["PF-snap-gripper-raw", "PF-sample-arc-knight"])
        #expect(groups.first { $0.kind == .sameFile }?.clusters == [["PF-sample-falcon", "PF-snap-falcon-again"]])
        #expect(groups.first { $0.kind == .looksSame }?.clusters == [["PF-sample-bracket", "PF-snap-bracket-mirror"]])
        // The laser cutter and the UV flatbed are bigger than a metre; a
        // model that only fits them is still too big to PRINT.
        #expect(ids(.tooBig) == ["PF-sample-king-2"])
        #expect(Set(ids(.unorganised)).isSuperset(of: ["PF-sample-dental-a", "PF-sample-dental-b"]))
        #expect(groups.first { $0.kind == .orphanProducts }?.productIds == ["PRD-snap-orphan"])
        shop.pretendHealthPresence = nil
    }

    @Test("with no library folder, nothing is called missing")
    func sampleIsNotMissing() async {
        let shop = Shop()
        await shop.load(.sample)
        await shop.checkLibraryHealth()
        #expect(shop.libraryHealthGroups?.contains { $0.kind == .missing } == false)
        #expect(Shop.healthPresence(shop.files, roots: nil, online: [], linkedOnline: { _ in false })
            .values.allSatisfy { $0 == .unknown })
    }

    static func record(_ id: String, external: String) throws -> LibraryFile {
        let row: JSONValue = .object(["id": .string(id), "name": .string(id), "title": .string(id),
                                      "externalPath": .string(external)])
        return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(row))
    }

    @Test("a linked folder that is gone (an unplugged drive) is unreachable, not missing, and comes back once it is there")
    func unpluggedIsNotMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-lh-\(UUID().uuidString)")
        let linked = dir.appending(path: "Drive"), vault = dir.appending(path: "Library")
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in [linked, vault] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("solid".utf8).write(to: linked.appending(path: "here.stl"))
        try Data("x".utf8).write(to: vault.appending(path: ".keep"))
        let here = try Self.record("PF-here", external: linked.appending(path: "here.stl").path)
        let gone = try Self.record("PF-gone", external: linked.appending(path: "gone.stl").path)
        func ask() -> [String: LibraryHealth.Presence] {
            Shop.healthPresence([here, gone], roots: [vault.path], online: [], linkedRoots: [linked.path],
                                linkedOnline: { _ in false })
        }
        // Connected: the file that is there is here, the one that is not is missing.
        #expect(ask() == ["PF-here": .here, "PF-gone": .missing])

        // The drive goes away: nothing on it is called missing, and the
        // groups offer no Remove (`.missing` holds none of them).
        let away = dir.appending(path: "Away")
        try FileManager.default.moveItem(at: linked, to: away)
        #expect(ask() == ["PF-here": .unreachable, "PF-gone": .unreachable])
        let groups = LibraryHealth.groups(models: [here, gone].map { Shop.healthModel($0, presence: ask()[$0.id]!) })
        #expect(groups.contains { $0.kind == .missing } == false)
        #expect(Set(groups.first { $0.kind == .unreachable }?.modelIds ?? []) == ["PF-here", "PF-gone"])
        #expect(groups.contains { $0.kind == .noFigures } == false, "an unreachable model was offered Measure")
        // An empty mount point left behind is not the drive either.
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        #expect(ask()["PF-gone"] == .unreachable)

        // Back: as it was.
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.moveItem(at: away, to: linked)
        #expect(ask() == ["PF-here": .here, "PF-gone": .missing])
    }

    @Test("a vault model is unreachable while its library folder is away, and unknown before the sync index loads")
    func vaultRootAway() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-lh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = dir.appending(path: "Library")
        let row: JSONValue = .object(["id": .string("PF-vault"), "name": .string("v"), "title": .string("v")])
        let file = try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(row))
        func ask(pending: Bool = false) -> LibraryHealth.Presence? {
            Shop.healthPresence([file], roots: [vault.path], online: [], indexPending: pending,
                                linkedOnline: { _ in false })["PF-vault"]
        }
        #expect(ask() == .unreachable)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: vault.appending(path: ".keep"))
        #expect(ask() == .missing)
        #expect(ask(pending: true) == .unknown)
    }

    @Test("the unreachable group's words have English and Arabic")
    func unreachableWords() {
        for key in ["mac.lh_unreachable", "mac.lh_unreachable_says"] {
            #expect(Words.own[key]?["en"]?.isEmpty == false)
            #expect(Words.own[key]?["ar"]?.isEmpty == false)
        }
    }

    @Test("a Health Show from a clean library recounts the chips over just the group")
    func showRecountsChips() async throws {
        let shop = await Self.sampleWithProblems()
        shop.shelf = .library(nil)
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        let whole = shop.libraryFacets.neverPrinted
        await shop.checkLibraryHealth()
        let missing = try #require(shop.libraryHealthGroups?.first { $0.kind == .missing })
        shop.showHealthGroup(missing)
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.neverPrinted <= missing.count)
        #expect(shop.libraryFacets.neverPrinted != whole, "the chips kept counting the whole library")
        shop.clearLibraryFilter()
        shop.pretendHealthPresence = nil
    }

    // MARK: - Remove from Library: the existing question, the exact count

    @Test("Remove asks the library's own delete question about exactly the group, models in folders counted")
    func removeCountsExactly() async throws {
        let shop = await Self.sampleWithProblems()
        // The worst case for the 27 Sep 2026 incident: the Groups view, a
        // search typed, another filter on, a different selection.
        shop.shelf = .library(nil)
        shop.libraryFlat = false
        shop.search = "dallah"
        shop.libraryNeverPrintedOnly = true
        shop.fileSelection = ["PF-sample-dallah"]
        await shop.checkLibraryHealth()
        let missing = try #require(shop.libraryHealthGroups?.first { $0.kind == .missing })
        #expect(missing.count == 2)

        let hidden = shop.askToRemoveHealthGroup(missing)
        #expect(hidden.isEmpty, "a model of the group was not on screen: \(hidden.map(\.id))")
        // EXACTLY the group — not the selection, not the folder around one.
        #expect(Set(shop.pendingLibraryDeletes.map(\.id)) == Set(missing.modelIds))
        #expect(shop.pendingLibraryDeletes.count == missing.count)
        // Every one of them drawn as a tile, so the second lock passes too.
        #expect(shop.notOnScreen(shop.pendingLibraryDeletes).isEmpty)
        #expect(shop.libraryShowsFlat, "a group's model could sit folded in a folder tile")
        // The question names the one filed in a group (the King, in Saudi Kings).
        let lines = Shop.libraryDeleteLines(shop.pendingLibraryDeletes, words: shop.words)
        #expect(lines.first == shop.words.callIt("mac.delete_n_confirm", ["n": .number(2)]))
        #expect(lines.contains(shop.words.callIt("mac.delete_in_groups",
                                                 ["n": .number(1), "groups": .string("Saudi Kings")])))
        // Nothing was deleted by asking.
        #expect(shop.files.contains { $0.id == "PF-sample-king-6" })
        shop.pendingLibraryDeletes = []
        shop.clearLibraryFilter()
        shop.pretendHealthPresence = nil
    }

    @Test("only the missing group offers Remove, and an archived model is never in it")
    func removeOnlyMissing() async throws {
        let shop = await Self.sampleWithProblems()
        await shop.checkLibraryHealth()
        let copies = try #require(shop.libraryHealthGroups?.first { $0.kind == .sameFile })
        #expect(shop.askToRemoveHealthGroup(copies).isEmpty)
        #expect(shop.pendingLibraryDeletes.isEmpty, "duplicates were offered for removal in one click")
        // Archive the King: it leaves the group.
        var rows = shop.libraryRows
        if let i = rows.firstIndex(where: { Shop.recordId($0) == "PF-sample-king-6" }), case .object(var o) = rows[i] {
            o["archivedAt"] = .string("2026-09-01T00:00:00.000Z")
            rows[i] = .object(o)
        }
        shop.pretendLibrary(rows)
        await shop.checkLibraryHealth()
        #expect(shop.libraryHealthGroups?.first { $0.kind == .missing }?.modelIds == ["PF-sample-gripper"])
        shop.pretendHealthPresence = nil
    }

    @Test("Show puts exactly the group on the grid, as a Show-menu filter that Clear takes off")
    func showFocus() async throws {
        let shop = await Self.sampleWithProblems()
        await shop.checkLibraryHealth()
        let copies = try #require(shop.libraryHealthGroups?.first { $0.kind == .looksSame })
        shop.openLibraryHealth()
        shop.showHealthGroup(copies)
        #expect(!shop.libraryHealthOpen)
        #expect(shop.visibleFiles.map(\.id) == copies.modelIds, "the copies are not side by side, in order")
        #expect(shop.libraryFilterOn)
        // Through the one matcher, but never into a saved search or its count.
        #expect(shop.libraryQuery == LibraryQuery() || !shop.libraryQuery.filtersOn)
        #expect(shop.libraryCount(LibraryQuery()) > copies.count, "the focus narrowed a smart folder's count")
        shop.clearLibraryFilter()
        #expect(shop.libraryHealthFocus == nil)
        let unorganised = try #require(shop.libraryHealthGroups?.first { $0.kind == .unorganised })
        shop.showHealthGroup(unorganised, select: true)
        #expect(shop.selectedIds == Set(unorganised.modelIds))
        shop.clearLibraryFilter()
        shop.pretendHealthPresence = nil
    }

    @Test("Locate takes only the record's own bytes")
    func locateChecksTheHash() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let file = try #require(shop.files.first { ($0.contentHash ?? "").isEmpty == false })
        #expect(Shop.locatedFileMatches(file, hash: file.contentHash))
        #expect(!Shop.locatedFileMatches(file, hash: "something else"))
        #expect(!Shop.locatedFileMatches(file, hash: nil))
    }

    // MARK: - Print next: the write, the gate, the job that clears it

    static func book() -> [String: JSONValue] {
        ["printFiles": .array([
            .object(["id": .string("PF-1"), "name": .string("Lantern"), "updatedAt": .string("2026-09-01T00:00:00.000Z")]),
            .object(["id": .string("PF-2"), "name": .string("Vase"),
                     "printNextAt": .string("2026-09-02T00:00:00.000Z"), "printNextFor": .string("Fair")]),
        ]), "printLog": .array([]), "settings": .object([:])]
    }

    static func record(_ url: URL, _ id: String) throws -> [String: JSONValue]? {
        for case .object(let o) in try diskRows(url) where o["id"] == .string(id) { return o }
        return nil
    }

    @Test("Print next is refused, and says so, for someone the lock does not allow to edit")
    func printNextGated() async {
        let shop = await OperatorLockTests.shop()
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)
        shop.moveProblem = nil
        let id = shop.files.first?.id ?? "PF-sample-lantern"
        #expect(!shop.setPrintNext([id], on: true))
        #expect(shop.moveProblem == shop.words.callIt("mac.lock_not_allowed"))
        shop.moveProblem = nil
        #expect(!shop.setPrintNextNote("PF-sample-lantern", "x"))
        // The source holds the gate where the write is.
        let source = (try? String(contentsOf: GroupFromRightClickTests.source("Shop+Library.swift"), encoding: .utf8)) ?? ""
        let body = source.range(of: "func setPrintNext(_ ids").map { String(source[$0.upperBound...].prefix(400)) } ?? ""
        #expect(body.contains("editFiles("), "Print next is written around the gated write chain")
    }

    @Test("a JOB clears the mark on the models it prints; a quote leaves it")
    func clearedByTheJob() {
        var root = Self.book()
        let parts: JSONValue = .array([.object(["name": .string("Vase"), "printFileId": .string("PF-2")])])
        var quote = root
        let none = Shop.clearPrintNext(&quote, forJob: ["status": .string("quote"), "parts": parts])
        #expect(none.isEmpty)
        #expect(quote == root, "a quote touched the library")
        let cleared = Shop.clearPrintNext(&root, forJob: ["status": .string("pending"), "parts": parts])
        #expect(cleared == ["PF-2"])
        let rows = Shop.rows(root, "printFiles")
        guard case .object(let vase)? = rows.first(where: { Shop.recordId($0) == "PF-2" }) else {
            Issue.record("the vase went"); return
        }
        #expect(vase["printNextAt"] == nil && vase["printNextFor"] == nil)
        #expect(vase["updatedAt"] != nil, "the cleared record was not stamped, so sync would undo it")
        // A model the job does not print is left on the list.
        var other = Self.book()
        #expect(Shop.clearPrintNext(&other, forJob: ["status": .string("pending"),
            "parts": .array([.object(["printFileId": .string("PF-1")])])]).isEmpty)
    }

    @Test("a quote that becomes a job clears the mark; one that stays a quote, or is cancelled, does not")
    func clearedWhenAccepted() {
        let parts: JSONValue = .array([.object(["printFileId": .string("PF-2")])])
        func job(_ status: String, hasQuote: Bool = false) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string("J1"), "status": .string(status), "parts": parts]
            if hasQuote { o["hasQuote"] = .bool(true) }
            return .object(o)
        }
        func cleared(_ before: JSONValue, _ after: JSONValue) -> Set<String> {
            var root = Self.book()
            return Shop.clearPrintNext(&root, acceptedFrom: before, now: after)
        }
        #expect(cleared(job("quote"), job("pending")) == ["PF-2"])
        #expect(cleared(job("on_hold", hasQuote: true), job("pending")) == ["PF-2"], "a quote on hold is a quote")
        #expect(cleared(job("quote"), job("quote")).isEmpty)
        #expect(cleared(job("quote"), job("on_hold", hasQuote: true)).isEmpty)
        #expect(cleared(job("quote"), job("cancelled")).isEmpty)
        #expect(cleared(job("pending"), job("printing")).isEmpty, "not a quote being accepted")
        #expect(cleared(job("quote"), .null).isEmpty)
    }

    @Test("every path from quote to job clears it in its own write")
    func everyAcceptPathIsWired() throws {
        func read(_ name: String) throws -> String {
            try String(contentsOf: GroupFromRightClickTests.source(name), encoding: .utf8)
        }
        let jobs = try read("Shop+Jobs.swift")
        let move = try #require(jobs.range(of: "func moveJob(_ id: Order.ID"))
        #expect(String(jobs[move.upperBound...].prefix(3000)).contains("Self.clearPrintNext(&root, acceptedFrom: wasOrder"),
                "a move out of Quote (board, Job menu, portal approval) no longer clears Print next")
        let lan = try read("LanServer.swift")
        let approve = try #require(lan.range(of: "func approveQuote(_ jobId: String"))
        #expect(String(lan[approve.upperBound...].prefix(1500)).contains("Shop.clearPrintNext(&root, acceptedFrom: before"),
                "the LAN quote page's approval no longer clears Print next")
    }

    @Test("the sample book has two models on Print next, one with a note")
    func sampleMarked() async {
        let shop = Shop()
        await shop.load(.sample)
        let marked = shop.files.filter(\.isPrintNext)
        #expect(Set(marked.map(\.id)) == ["PF-sample-lantern", "PF-sample-gripper"])
        #expect(marked.compactMap(\.printNextNote) == ["The Ramadan stall"])
        shop.clearLibraryFilter()
        shop.shelf = .library(nil)
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.printNext == 2)
    }

    @Test("Print next is offered on the card, the right-click menu, the multi-select pane and ⌘B")
    func everyDoor() throws {
        func read(_ name: String) throws -> String {
            try String(contentsOf: GroupFromRightClickTests.source(name), encoding: .utf8)
        }
        #expect(try read("LibraryInspector.swift").contains("PrintNextRow(shop: shop, file: file)"))
        #expect(try read("FileActions.swift").contains("shop.setPrintNext(marked, on: !allOn)"))
        #expect(try read("GroupMenu.swift").contains("shop.setPrintNext(Set(chosen.map(\\.id)), on: !allOn)"))
        let menus = try read("Menus.swift")
        #expect(menus.contains("shop.togglePrintNextOnSelection()"))
        #expect(menus.components(separatedBy: ".keyboardShortcut(\"b\")").count == 2, "⌘B is claimed twice")
        // One place on the model page, not two: the File section's button went.
        let inspector = try read("LibraryInspector.swift")
        #expect(inspector.components(separatedBy: "shop.setPrintNext([file.id]").count == 2)
    }

    // MARK: - Words

    @Test("every Library health word is in English and Arabic, placeholders kept and isolated")
    func words() throws {
        let keys = Words.own.keys.filter { $0.hasPrefix("mac.lh_") || $0.hasPrefix("mac.print_next_for")
            || $0 == "mac.print_next_help" }
        #expect(keys.count >= 30)
        for key in keys {
            let entry = try #require(Words.own[key])
            let en = entry["en"] ?? "", ar = entry["ar"] ?? ""
            #expect(!en.isEmpty && !ar.isEmpty, "\(key)")
            for name in ["{name}", "{n}"] where en.contains(name) {
                #expect(ar.contains("\u{2068}" + name + "\u{2069}"), "\(key): \(name) not isolated in Arabic")
            }
        }
        for kind in LibraryHealth.Kind.allCases {
            let look = LibraryHealthView.look(kind)
            #expect(Words.own[look.title] != nil && Words.own[look.sentence] != nil, "\(kind)")
        }
    }
}

/// The Print next writes on a real (temporary) book. In `LibraryEditPerfTests`
/// because `withPerfBook` points the app at a temporary support folder for the
/// whole process: run beside another suite doing the same, the two books cross.
extension LibraryEditPerfTests {

    @Test("Print next is written on the record, with its note, and taken off with it")
    func printNextWrite() async throws {
        try await withPerfBook(LibraryHealthAppTests.book()) { shop, url in
            #expect(shop.setPrintNext(["PF-1"], on: true))
            await shop.settleLibraryWrites()
            let on = try #require(try LibraryHealthAppTests.record(url, "PF-1"))
            #expect(on["printNextAt"] != nil)
            #expect(on["updatedAt"] != .string("2026-09-01T00:00:00.000Z"), "not stamped for sync")
            #expect(shop.setPrintNextNote("PF-1", "  Noura's order  "))
            await shop.settleLibraryWrites()
            #expect(try LibraryHealthAppTests.record(url, "PF-1")?["printNextFor"] == .string("Noura's order"))
            #expect(shop.files.first { $0.id == "PF-1" }?.printNextNote == "Noura's order")
            // Marking again keeps its place on the list.
            let at = try LibraryHealthAppTests.record(url, "PF-1")?["printNextAt"]
            #expect(shop.setPrintNext(["PF-1"], on: true))
            await shop.settleLibraryWrites()
            #expect(try LibraryHealthAppTests.record(url, "PF-1")?["printNextAt"] == at)
            // Off takes the note too; a note on a model not on the list is refused.
            #expect(shop.setPrintNext(["PF-1"], on: false))
            await shop.settleLibraryWrites()
            let off = try #require(try LibraryHealthAppTests.record(url, "PF-1"))
            #expect(off["printNextAt"] == nil && off["printNextFor"] == nil)
            #expect(!shop.setPrintNextNote("PF-1", "x"))
        }
    }

    @Test("creating a job clears the mark in the same write, without a question")
    func createJobClears() async throws {
        try await withPerfBook(LibraryHealthAppTests.book()) { shop, url in
            shop.takingAJob = false
            await shop.createJob([
                "parts": .array([.object(["name": .string("Vase"), "printFileId": .string("PF-2"),
                                          "printWeight": .number(40), "printTime": .number(2), "qty": .number(1)])]),
                "project": .string("Vase for the fair"), "margin": .number(30), "discountPct": .number(0),
                "shippingCost": .number(0), "depositAmount": .number(0), "rushEnabled": .bool(false),
                "asQuote": .bool(false),
            ])
            #expect(shop.moveProblem == nil, "\(shop.moveProblem ?? "")")
            #expect(shop.lastCreated != nil, "no job was created")
            let vase = try #require(try LibraryHealthAppTests.record(url, "PF-2"))
            #expect(vase["printNextAt"] == nil, "the job left its model on Print next")
            #expect(shop.files.first { $0.id == "PF-2" }?.isPrintNext == false)
        }
        let source = (try? String(contentsOf: GroupFromRightClickTests.source("Shop+Money.swift"), encoding: .utf8)) ?? ""
        #expect(source.contains("Self.clearPrintNext(&root, forJob: record)"), "createJob no longer clears it in its write")
    }


    @Test("a quote accepted on the Mac, or approved on the LAN page, takes its model off Print next")
    func acceptedQuotesClear() async throws {
        var book = LibraryHealthAppTests.book()
        if case .array(var rows)? = book["printFiles"] {
            rows.append(.object(["id": .string("PF-3"), "name": .string("Bowl"),
                                 "printNextAt": .string("2026-09-03T00:00:00.000Z")]))
            book["printFiles"] = .array(rows)
        }
        try await withPerfBook(book) { shop, url in
            @MainActor func quote(_ file: String) async throws -> String {
                await shop.createJob([
                    "parts": .array([.object(["name": .string(file), "printFileId": .string(file),
                                              "printWeight": .number(40), "printTime": .number(2), "qty": .number(1)])]),
                    "project": .string(file), "margin": .number(30), "discountPct": .number(0),
                    "shippingCost": .number(0), "depositAmount": .number(0), "rushEnabled": .bool(false),
                    "asQuote": .bool(true),
                ])
                return try #require(shop.lastCreated, "no quote was created: \(shop.moveProblem ?? "")")
            }
            // A quote leaves the mark.
            let first = try await quote("PF-2")
            #expect(try LibraryHealthAppTests.record(url, "PF-2")?["printNextAt"] != nil, "a quote cleared the mark")
            // Accepted on the Mac: a move out of Quote.
            await shop.moveJob(first, to: .pending)
            #expect(shop.moveProblem == nil, "\(shop.moveProblem ?? "")")
            #expect(try LibraryHealthAppTests.record(url, "PF-2")?["printNextAt"] == nil,
                    "a quote accepted on the Mac left its model on Print next")
            // Approved by the customer on the LAN quote page.
            let second = try await quote("PF-3")
            let approved = try await shop.approveQuote(second, nowIso: StoreWriter.iso(Date()))
            #expect(approved != nil, "the LAN approval was refused")
            #expect(try LibraryHealthAppTests.record(url, "PF-3")?["printNextAt"] == nil,
                    "a quote approved on the LAN page left its model on Print next")
        }
    }
}
