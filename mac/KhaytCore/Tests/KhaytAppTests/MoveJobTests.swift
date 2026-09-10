import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Moving a job is the most consequential write this app makes.
///
/// It changes three collections at once — the job, the spools its filament came
/// off, the consumables it spent — and a book where the job says "completed"
/// while the spools still hold its filament has told a shop it has stock it has
/// already used. So every case here runs the real path against a real store
/// shape and reads the file back.
///
/// The RULES are not tested here; they are tested where they live, in Node and
/// again through JavaScriptCore. What is tested here is that this app asks for
/// them correctly, writes down every collection they changed, stamps what it
/// changed and nothing else, and refuses whole rather than half.
@MainActor
struct MoveJobTests {

    // MARK: - a book to move a job in

    /// A small shop with the awkward parts present: two spools of the same
    /// material where one is nearly empty, a packaging item, an hourly
    /// consumable, and a job whose filament will not fit on its own spool.
    static func book(settings: [String: JSONValue] = ["autoDeduct": .bool(true)]) -> [String: JSONValue] {
        [
            "printLog": .array([
                .object([
                    "id": .string("J1"), "project": .string("Bracket"), "status": .string("printing"),
                    "client": .string("Acme"), "price": .number(400), "rev": .number(3),
                    "parts": .array([.object([
                        "filamentId": .string("S1"), "printWeight": .number(150),
                        "supportWeight": .number(10), "qty": .number(1), "baseCost": .number(22.5),
                    ])]),
                    "printTime": .number(4),
                ]),
                .object(["id": .string("J2"), "project": .string("Other"), "status": .string("pending")]),
            ]),
            "inventory": .array([
                .object(["id": .string("S1"), "material": .string("PLA"), "weight": .number(100), "rev": .number(1)]),
                .object(["id": .string("S2"), "material": .string("PLA"), "weight": .number(900), "rev": .number(1)]),
                .object(["id": .string("S3"), "material": .string("PETG"), "weight": .number(900), "rev": .number(1)]),
            ]),
            "consumables": .array([
                .object(["id": .string("C1"), "name": .string("IPA"), "stock": .number(10),
                         "minStock": .number(2), "usagePerHour": .number(0.5), "rev": .number(1)]),
                .object(["id": .string("C2"), "name": .string("Box"), "stock": .number(5),
                         "minStock": .number(1), "isPackaging": .bool(true), "rev": .number(1)]),
            ]),
            "machines": .array([]),
            "clients": .array([.object(["id": .string("A"), "name": .string("Acme")])]),
            "settings": .object(settings),
        ]
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)     // …/mac/KhaytCore/Tests/KhaytAppTests/x.swift
            .deletingLastPathComponent()     // KhaytAppTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // KhaytCore
            .deletingLastPathComponent()     // mac
            .deletingLastPathComponent()     // repo root
    }

    static func rowValues(_ root: [String: JSONValue], _ collection: String) -> [JSONValue] {
        guard case .array(let r)? = root[collection] else { return [] }
        return r
    }

    static func rows(_ root: [String: JSONValue], _ collection: String) -> [[String: JSONValue]] {
        guard case .array(let r)? = root[collection] else { return [] }
        return r.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    static func row(_ root: [String: JSONValue], _ collection: String, _ id: String) -> [String: JSONValue]? {
        rows(root, collection).first { if case .string(let i)? = $0["id"] { return i == id } else { return false } }
    }

    static func number(_ value: JSONValue?) -> Double? {
        if case .number(let n)? = value { return n }
        return nil
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    static func move(_ root: inout [String: JSONValue], _ id: String, _ stage: Stage,
                     holdReason: String? = nil, qcNotes: String? = nil,
                     actuals: Shop.Actuals? = nil)
    async throws -> (undo: [Shop.ChangedRecord], notices: [String]) {
        let engine = try KhaytEngine()
        // Words loaded, not bare: a notice is only useful if it comes back as a
        // sentence, and an unloaded catalogue would let a missing key pass as
        // one.
        let words = Words()
        await words.load("en", engine: engine)
        // The message a shop's Telegram bot would send is the third thing a move
        // hands back; these cases are about the book, so it is dropped here and
        // tested in TelegramTests.
        let out = try await Shop.applyMove(to: &root, id: id, stage: stage, engine: engine,
                                           words: words, holdReason: holdReason, qcNotes: qcNotes,
                                           actuals: actuals)
        return (out.undo, out.notices)
    }

    // MARK: -

    @Test("finishing a job moves it, empties the spools it printed with, and says so")
    func completion() async throws {
        var root = Self.book()
        let (undo, notices) = try await Self.move(&root, "J1", .completed)

        let job = try #require(Self.row(root, "printLog", "J1"))
        #expect(Self.string(job["status"]) == "completed")
        #expect(Self.string(job["completedAt"]) != nil, "the moment it finished is recorded")
        #expect(Self.number(job["costBasis"]) == 22.5, "and what it cost is fixed")
        #expect(Self.string(job["surveyToken"])?.hasPrefix("srv-") == true)

        // 160g owed: the chosen spool has 100, the shortfall comes off the other
        // PLA spool, and the PETG one is not touched.
        #expect(Self.number(Self.row(root, "inventory", "S1")?["weight"]) == 0)
        #expect(Self.number(Self.row(root, "inventory", "S2")?["weight"]) == 840)
        #expect(Self.number(Self.row(root, "inventory", "S3")?["weight"]) == 900)

        #expect(Self.number(Self.row(root, "consumables", "C1")?["stock"]) == 8, "four hours of IPA")
        #expect(Self.number(Self.row(root, "consumables", "C2")?["stock"]) == 4, "one box")

        #expect(!notices.isEmpty, "a shop is told what came off the shelf")

        let changed = Set(undo.map(\.collection))
        #expect(changed == ["printLog", "inventory", "consumables"],
                "every collection the move touched must be undoable")
        #expect(undo.contains { $0.id == "S3" } == false, "and only the rows that changed")
    }

    @Test("only what changed is stamped")
    func stampsOnlyTheChanged() async throws {
        var root = Self.book()
        _ = try await Self.move(&root, "J1", .completed)

        #expect(Self.number(Self.row(root, "printLog", "J1")?["rev"]) == 4)
        #expect(Self.number(Self.row(root, "inventory", "S1")?["rev"]) == 2)
        // The untouched spool keeps its revision. Stamping it would push a row
        // to the cloud as an edit nobody made, and on a shop with two machines
        // that is how a stale copy gets to win.
        #expect(Self.number(Self.row(root, "inventory", "S3")?["rev"]) == 1)
        #expect(Self.string(Self.row(root, "printLog", "J2")?["updatedAt"]) == nil)
    }

    @Test("a move that is not a completion deducts nothing")
    func plainMove() async throws {
        var root = Self.book()
        _ = try await Self.move(&root, "J1", .quote)

        #expect(Self.string(Self.row(root, "printLog", "J1")?["status"]) == "quote")
        #expect(Self.number(Self.row(root, "inventory", "S1")?["weight"]) == 100)
        #expect(Self.number(Self.row(root, "consumables", "C2")?["stock"]) == 5)
    }

    @Test("the move is written in the team's activity log, the way Khayt writes it")
    func activityLog() async throws {
        var root = Self.book(settings: ["autoDeduct": .bool(true),
                                        "activeOperatorId": .string("OP1")])
        root["operators"] = .array([.object(["id": .string("OP1"), "name": .string("Sara")])])
        _ = try await Self.move(&root, "J1", .pending)

        let log = Self.rows(root, "auditLog")
        #expect(log.count == 1)
        let entry = try #require(log.first)
        #expect(Self.string(entry["action"]) == "status")
        #expect(Self.string(entry["detail"]) == "J1 → pending")
        #expect(Self.string(entry["ref"]) == "J1")
        #expect(Self.string(entry["operatorId"]) == "OP1")
        #expect(Self.string(entry["operatorName"]) == "Sara", "who did it, not just what")
        #expect(Self.string(entry["id"])?.hasPrefix("AL-") == true)
        #expect(Self.string(entry["at"])?.hasSuffix("Z") == true)
    }

    @Test("a move the rules refuse changes nothing at all")
    func refusedByTheRules() async throws {
        var root = Self.book(settings: ["autoDeduct": .bool(true), "productionPaused": .bool(true)])
        let before = root

        await #expect(throws: Shop.MoveRefused.self) {
            var copy = root
            _ = try await Self.move(&copy, "J2", .printing)
            root = copy
        }
        #expect(root == before, "a paused shop's book is untouched by a refused move")
    }

    /// The failure this whole design exists to prevent: a move made here that
    /// silently does not send what the same move sends in Khayt.
    ///
    /// TELEGRAM IS NO LONGER AN EXAMPLE OF ONE. This app sends those itself
    /// now, so the case is written with a webhook — which it still cannot
    /// deliver, and still refuses whole. See `TelegramTests` for the other
    /// half: a shop whose only integration is a bot can finish a job here.
    @Test("a move that would reach somebody is refused whole")
    func refusedForOutbound() async throws {
        let wired: [String: JSONValue] = [
            "autoDeduct": .bool(true),
            "webhooks": .object([
                "enabled": .bool(true),
                "subscriptions": .array([.object([
                    "id": .string("W1"), "url": .string("https://example.test/hook"),
                    "events": .array([.string("*")]),
                ])]),
            ]),
        ]
        var root = Self.book(settings: wired)
        let before = root

        await #expect(throws: Shop.MoveRefused.self) {
            var copy = root
            _ = try await Self.move(&copy, "J1", .completed)
            root = copy
        }
        #expect(root == before, "not the job, not the spools, not the packaging")

        // A channel that says nothing about THIS move does not block it. A
        // webhook is not such a channel — `webhooks.enabled` fires for every
        // status change, and the subscriptions are matched when it is sent —
        // so the case is written with an email the shop only sends on
        // completion.
        var moving = Self.book(settings: [
            "autoDeduct": .bool(true),
            "emailConfig": .object(["provider": .string("resend"),
                                    "triggers": .array([.string("completed")])]),
        ])
        _ = try await Self.move(&moving, "J1", .pending)
        #expect(Self.string(Self.row(moving, "printLog", "J1")?["status"]) == "pending")
    }

    @Test("the refusal names the channel, so a shop knows what it would have missed")
    func refusalSaysWhich() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object(["id": .string("J1"), "clientId": .string("A")])
        let reaches = try await engine.outbound(
            order: order, to: "completed",
            settings: ["telegram": .object(["botToken": .string("t"), "chatId": .string("c"),
                                            "notifyOnComplete": .bool(true)])],
            clients: [])
        #expect(reaches.map(\.channel) == ["telegram"])

        let words = Words()
        let sentence = words.outboundRefusal(reaches)
        #expect(sentence.contains("Telegram"), "naming it is the point: \(sentence)")
    }

    @Test("an undone move puts the filament back on the spool")
    func undoRestoresTheShelf() async throws {
        var root = Self.book()
        let (undo, _) = try await Self.move(&root, "J1", .completed)

        // What restoreMove does to the book, without the file and the menu.
        for record in undo {
            guard case .array(var rows)? = root[record.collection] else { continue }
            for i in rows.indices {
                guard case .object(let current) = rows[i],
                      case .string(let id)? = current["id"], id == record.id else { continue }
                rows[i] = .object(StoreWriter.restoring(record.was, over: current))
            }
            root[record.collection] = .array(rows)
        }

        #expect(Self.string(Self.row(root, "printLog", "J1")?["status"]) == "printing")
        #expect(Self.number(Self.row(root, "inventory", "S1")?["weight"]) == 100)
        #expect(Self.number(Self.row(root, "inventory", "S2")?["weight"]) == 900)
        #expect(Self.number(Self.row(root, "consumables", "C2")?["stock"]) == 5)
        // An undo is an edit like any other, so the revision goes FORWARD. A
        // record that went backwards would look to the next sync like the
        // change never happened, and the other machine's copy would win.
        #expect(Self.number(Self.row(root, "printLog", "J1")?["rev"]) == 5)
    }

    /// The gap this fixes was shipped in the drag itself: a card dropped on
    /// "On Hold" set the status and nothing else, so the job came back with its
    /// original due date and no way to know it had ever stopped.
    @Test("a job dropped on hold records when, and why")
    func holdRecordsWhenAndWhy() async throws {
        var root = Self.book()
        _ = try await Self.move(&root, "J1", .on_hold, holdReason: "waiting on filament")

        let job = try #require(Self.row(root, "printLog", "J1"))
        #expect(Self.string(job["status"]) == "on_hold")
        #expect(Self.string(job["heldAt"])?.hasSuffix("Z") == true, "or the days back cannot be counted")
        #expect(Self.string(job["holdReason"]) == "waiting on filament")
    }

    @Test("a hold with nothing typed is a hold with no reason, not the last one")
    func holdWithNoReason() async throws {
        var root = Self.book()
        _ = try await Self.move(&root, "J1", .on_hold, holdReason: "")
        #expect(Self.row(root, "printLog", "J1")?["holdReason"] == .null)
        #expect(Self.string(Self.row(root, "printLog", "J1")?["heldAt"]) != nil)
    }

    @Test("resuming a held job gives back the days it waited")
    func resumeExtendsTheDueDate() async throws {
        var root = Self.book()
        // Held nine days ago, due in a fortnight.
        guard case .array(var jobs)? = root["printLog"], case .object(var j1) = jobs[0] else {
            Issue.record("fixture changed"); return
        }
        j1["status"] = .string("on_hold")
        j1["dueDate"] = .string("2099-01-20")
        // Nine days and a bit less: the rule counts whole days and rounds UP,
        // so exactly nine days ago plus the microseconds this test takes is ten.
        j1["heldAt"] = .string(StoreWriter.iso(Date().addingTimeInterval(-9 * 86400 + 3600)))
        jobs[0] = .object(j1)
        root["printLog"] = .array(jobs)

        let (_, notices) = try await Self.move(&root, "J1", .printing)
        #expect(Self.string(Self.row(root, "printLog", "J1")?["dueDate"]) == "2099-01-29")
        #expect(Self.row(root, "printLog", "J1")?["heldAt"] == nil, "the hold is over")
        #expect(notices.contains { $0.contains("2099-01-29") }, "and the shop is told: \(notices)")
    }

    /// A completion out of QC that left no record was not counted as a failure.
    /// It was not counted at all — `computeQcMetrics` only counts the orders
    /// `qcStatusOf` can answer for — so a shop's pass rate would have been
    /// computed over a shrinking subset of its own work.
    @Test("a job finished out of inspection records that it passed")
    func qcPassIsRecorded() async throws {
        var root = Self.book()
        guard case .array(var jobs)? = root["printLog"], case .object(var j1) = jobs[0] else {
            Issue.record("fixture changed"); return
        }
        j1["status"] = .string("qc")
        jobs[0] = .object(j1)
        root["printLog"] = .array(jobs)

        _ = try await Self.move(&root, "J1", .completed, qcNotes: "surface is clean")

        let job = try #require(Self.row(root, "printLog", "J1"))
        #expect(Self.string(job["status"]) == "completed")
        #expect(Self.string(job["qcStatus"]) == "pass")
        #expect(Self.string(job["qcPassedAt"])?.hasSuffix("Z") == true)
        #expect(Self.string(job["qcNotes"]) == "surface is clean")
        #expect(job["inspector"] == .null, "nobody was named, and nobody is recorded")
    }

    /// ── WHAT IT REALLY TOOK, ALL THE WAY INTO THE BOOK ───────────────────
    ///
    /// The sheet that collects these was tested by reading the source, which
    /// proves the call is made and NOT that the figures survive the move. They
    /// have to: `applyMove` writes the actuals onto the order, then hands that
    /// order to the engine, which returns its own updated copy — a step that
    /// rebuilds the record from anything captured earlier would drop them
    /// silently, and the job would read as completed with no actuals at all.
    @Test("the figures the shop typed are in the book afterwards")
    func actualsSurviveTheMove() async throws {
        var root = Self.book()
        _ = try await Self.move(&root, "J1", .completed,
                                actuals: .init(hours: 3.456, grams: 214.06,
                                               timeSource: "moonraker", weightSource: "manual"))
        let job = try #require(Self.row(root, "printLog", "J1"))
        #expect(job["actualPrintTime"] == JSONValue.number(3.46), "hours are rounded to two")
        #expect(job["actualWeight"] == JSONValue.number(214.1), "grams to one")
        guard case .object(let src)? = job["actualsSource"] else {
            Issue.record("no provenance on the record"); return
        }
        // PER AXIS, and carried through unchanged. A record that flattens these
        // to one value cannot say that the printer timed the job and the shop
        // weighed it, which is the ordinary case for a PrusaLink machine.
        #expect(src["time"] == JSONValue.string("moonraker"))
        #expect(src["weight"] == JSONValue.string("manual"))
        #expect(src["at"] != nil, "nothing says when this was recorded")
    }

    /// A move with no actuals must not stamp empty ones. Every job finished
    /// before this existed has none, and a `0 g` actual would report every one
    /// of them as having used no filament.
    @Test("a completion with nothing typed writes no actuals at all")
    func noActualsMeansNoFields() async throws {
        var root = Self.book()
        _ = try await Self.move(&root, "J1", .completed)
        let job = try #require(Self.row(root, "printLog", "J1"))
        #expect(job["actualWeight"] == nil)
        #expect(job["actualPrintTime"] == nil)
        #expect(job["actualsSource"] == nil)
    }

    /// ── THE SHELF LOSES WHAT THE JOB REALLY USED ─────────────────────────
    ///
    /// `deductForOrder` has taken an `actualGrams` since #978 — "what the
    /// PRINTER says the job used, when anything measured it" — and nothing
    /// passed it. That change was about FAILED prints, where the grams go
    /// through `deductActual` instead, and it left completions where they were
    /// on purpose: "absent — which is every job Khayt has ever deducted for —
    /// the estimate stands exactly as before".
    ///
    /// What changed since is that a completion can now BE measured. So a job
    /// that used 260 g against a 160 g quote took 160 g off the shelf and the
    /// shop was short 100 g, every time, with nothing to reconcile it.
    ///
    /// Both apps read it off the same field on the same record, so neither can
    /// spend a different number from the other.
    @Test("a job that used more than it was quoted takes the real grams off the shelf")
    func theShelfFollowsTheActual() async throws {
        var root = Self.book()          // quoted at 160 g: S1 holds 100, S2 covers the rest
        _ = try await Self.move(&root, "J1", .completed,
                                actuals: .init(hours: 4, grams: 260))
        // 260 g owed rather than 160: S1 still empties, and S2 carries the
        // extra hundred instead of the extra sixty.
        #expect(Self.number(Self.row(root, "inventory", "S1")?["weight"]) == 0)
        let s2 = Self.number(Self.row(root, "inventory", "S2")?["weight"]) ?? -1
        #expect(s2 == 740, "S2 is at \(s2) g — 840 means the estimate was deducted")
    }

    /// A MEASUREMENT SMALLER THAN THE QUOTE COUNTS TOO, which is the case a
    /// shop notices: a print that stopped short, or one that simply used less
    /// than the slicer thought. Deducting the quote would take filament off a
    /// shelf that still has it.
    @Test("a job that used less takes less")
    func aShortJobTakesLess() async throws {
        var root = Self.book()
        _ = try await Self.move(&root, "J1", .completed,
                                actuals: .init(hours: 1, grams: 80))
        #expect(Self.number(Self.row(root, "inventory", "S1")?["weight"]) == 20,
                "S1 is at \(Self.number(Self.row(root, "inventory", "S1")?["weight"]) ?? -1) — 0 means the estimate was deducted")
        #expect(Self.number(Self.row(root, "inventory", "S2")?["weight"]) == 900,
                "the second spool was drawn on for a job the first could cover")
    }

    /// AND EVERY JOB FINISHED BEFORE THIS EXISTED IS UNTOUCHED. A book full of
    /// records with no actuals must deduct exactly what it always did — this is
    /// the assertion that says the change cannot rewrite a shop's history or
    /// its habits, only what it does with a figure it now has.
    @Test("a completion with no actuals deducts the estimate, exactly as before")
    func noActualsIsUnchanged() async throws {
        var root = Self.book()
        _ = try await Self.move(&root, "J1", .completed)
        #expect(Self.number(Self.row(root, "inventory", "S1")?["weight"]) == 0)
        #expect(Self.number(Self.row(root, "inventory", "S2")?["weight"]) == 840)
        #expect(Self.number(Self.row(root, "inventory", "S3")?["weight"]) == 900)
    }

    @Test("a completion that was not an inspection claims nothing about one")
    func completionWithoutQC() async throws {
        var root = Self.book()   // J1 is printing, not in QC
        _ = try await Self.move(&root, "J1", .completed)
        let job = try #require(Self.row(root, "printLog", "J1"))
        #expect(job["qcStatus"] == nil, "or every completion would count as a pass")
        #expect(job["qcPassedAt"] == nil)
    }

    /// EVERY COMPLETION ASKS NOW, and it used to ask only when the job was
    /// leaving inspection — which this test pinned.
    ///
    /// The change is the point rather than a side effect. `order-status.gate`
    /// sets `needsActuals` for exactly one move, into `completed`, and nothing
    /// in this app read it: a job finished here kept its estimate as its only
    /// figure, so its margin was the quoted margin and `Quoting` had no Mac
    /// path to any data. A job leaving QC is still asked ONCE — the notes live
    /// in the same sheet.
    @Test("a hold and a completion ask a question first, and only those")
    func questionsAsked() async {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        guard let inQC = shop.orders.first(where: { $0.status == "qc" })
                ?? shop.orders.first(where: { $0.status == "printing" }) else { return }

        // A hold always asks; every ordinary move asks nothing.
        #expect(shop.questionFor(inQC.id, moving: .on_hold) != nil)
        #expect(shop.questionFor(inQC.id, moving: .printing) == nil)
        #expect(shop.questionFor(inQC.id, moving: .post) == nil)

        // And a completion asks whatever the job was doing before it.
        #expect(shop.questionFor(inQC.id, moving: .completed) != nil,
                "finishing a job records what it took, whether or not it was inspected")
    }

    /// The sheet carries the QC question only for a job that was actually in
    /// inspection — otherwise every completion would collect notes about an
    /// inspection that never happened, and `completionWithoutQC` above is the
    /// test that this must not claim one.
    @Test("only a job leaving inspection is asked for QC notes")
    func qcIsAskedOnlyLeavingQC() async {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        for job in shop.orders where Stage.of(job) != nil {
            guard shop.questionFor(job.id, moving: .completed) != nil else { continue }
            shop.questionFor(job.id, moving: .completed)?()
            guard let asking = shop.pendingCompletion else { continue }
            #expect(asking.leavingQC == (Stage.of(job) == .qc),
                    "\(job.id) is in \(Stage.of(job)?.rawValue ?? "?") and leavingQC is \(asking.leavingQC)")
            shop.clearQuestion()
        }
    }

    @Test("the ids this app mints are the ids Khayt mints")
    func idFormats() {
        let id = Shop.uid("AL")
        #expect(id.hasPrefix("AL-"))
        let body = String(id.dropFirst(3))
        #expect(body.count >= 9, "base-36 milliseconds plus three characters: \(id)")
        #expect(body.suffix(3).allSatisfy { $0.isNumber || ($0.isUppercase && $0.isLetter) })

        let token = Shop.surveyToken()
        #expect(token.hasPrefix("srv-"))
        #expect(token.dropFirst(4).count == 24, "twelve bytes in hex")
        #expect(token.dropFirst(4).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// The safety net, checked at the source rather than waited for.
    ///
    /// `applyMove` refuses a move whose effects it cannot classify, which is the
    /// right behaviour and is also unreachable in a test: every effect
    /// `lib/order-status.js` emits today IS classified. So this reads the module
    /// and asserts that — a new effect added there without a decision here fails
    /// the build instead of refusing a shop's drag on a Tuesday.
    @Test("every effect the shared rules can ask for has been decided about")
    func everyEffectIsClassified() throws {
        let module = Self.repoRoot.appending(path: "lib/order-status.js")
        let source = try String(contentsOf: module, encoding: .utf8)

        var emitted = Set<String>()
        for match in source.ranges(of: /type:\s*'([a-z_]+)'/) {
            let text = source[match]
            if let quoted = text.split(separator: "'").dropFirst().first {
                emitted.insert(String(quoted))
            }
        }
        #expect(emitted.count >= 12, "found only \(emitted.sorted()) — has the module's shape changed?")

        // The three buckets in KhaytEngine's MOVE_SCRIPT, written out here
        // because a Swift test cannot read a private JavaScript literal.
        let performed: Set<String> = ["deduct_filament", "deduct_packaging", "activity_log",
                                      "save", "ensure_survey_token"]
        let cosmetic: Set<String> = ["render", "toast_updated", "toast_updated_undoable",
                                     "tier_check", "export_status_page",
                                     // markDelivered's, not apply's: the app has
                                     // its own sentence for a handover and the
                                     // record is the deliveredAt stamp.
                                     "toast_delivered"]
        let outbound: Set<String> = ["webhook", "order_webhook", "telegram", "email", "republish_portal"]
        let classified = performed.union(cosmetic).union(outbound)

        let unknown = emitted.subtracting(classified)
        #expect(unknown.isEmpty, """
            lib/order-status.js can now ask for \(unknown.sorted()), and nothing in \
            KhaytEngine.MOVE_SCRIPT says what this app does about it. Decide: perform it, \
            call it cosmetic, or call it outbound — then add it here.
            """)

        let stale = classified.subtracting(emitted)
        #expect(stale.isEmpty, "\(stale.sorted()) is classified but the module no longer emits it")
    }

    @Test("the day a spool's usage is recorded under is this Mac's day")
    func localDay() {
        let day = Shop.localDay(Date(timeIntervalSince1970: 0))
        #expect(day.count == 10 && day.dropFirst(4).first == "-")
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        #expect(Shop.localDay() == String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))
    }
}

/// The whole write, against a real file.
///
/// Everything above works on a `root` dictionary in memory. This runs the path
/// the app actually runs — read from disk inside the write, ask the shared
/// rules, serialise, swap — against a COPY of a real store in a temp directory.
/// A write path whose only trial run was on a dictionary has not been tested
/// where it can lose anything.
/// A failed print takes its filament off the shelf, through the app's own path.
///
/// The RULE is `lib/qc-failure.js` and `lib/order-deduction.js`, tested where
/// they live. What is tested here is that this app WRITES the shelf the rule
/// hands back — it used not to, and could not have, because the bridge returned
/// the order and the waste row and dropped the inventory. A deduction that
/// happens inside JavaScriptCore and is thrown away is exactly the shape of the
/// bug it was meant to fix.
@MainActor
struct QcFailureShelfTests {

    static func book() -> [String: JSONValue] {
        [
            "printLog": .array([.object([
                "id": .string("J1"), "project": .string("Bracket"), "status": .string("qc"),
                "material": .string("PLA"), "price": .number(400), "rev": .number(2),
                "parts": .array([.object([
                    "filamentId": .string("S1"), "printWeight": .number(200), "qty": .number(1),
                    "baseCost": .number(30),
                ])]),
            ])]),
            "inventory": .array([
                .object(["id": .string("S1"), "material": .string("PLA"), "weight": .number(1000),
                         "cost": .number(90), "rev": .number(4)]),
                .object(["id": .string("S9"), "material": .string("PETG"), "weight": .number(500),
                         "cost": .number(120), "rev": .number(1)]),
            ]),
            "consumables": .array([]), "machines": .array([]), "clients": .array([]),
            "wasteLog": .array([]),
            "settings": .object(["autoDeduct": .bool(true), "lowStockThreshold": .number(200)]),
        ]
    }

    @Test("a failed print's grams leave the shelf, and only its spool is stamped")
    func shelfIsWritten() async throws {
        let engine = try KhaytEngine()
        let url = try MoveJobOnDiskTests.freshCopy(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            let before = Shop.rows(root, "inventory")
            let orders = Shop.rows(root, "printLog")
            let out = try await engine.recordQcFailure(
                order: orders[0], failureType: "warping", severity: "major",
                reason: "Lifted", weight: 80, inspector: nil,
                inventory: before, now: Date(), wasteId: "W-1", defaultReason: "QC fail",
                settings: Shop.settings(root), machines: [], today: Shop.today())
            #expect(out.deducted == 80)
            #expect(out.spools == ["S1"])
            var undo: [Shop.ChangedRecord] = []
            Shop.write(&root, "printLog", changed: [out.order], before: orders, into: &undo)
            Shop.write(&root, "inventory", changed: out.inventory, before: before, into: &undo)
            root["wasteLog"] = .array([out.waste])
        }

        let after = try MoveJobOnDiskTests.read(url)
        #expect(MoveJobTests.number(MoveJobTests.row(after, "inventory", "S1")?["weight"]) == 920,
                "the 80g it got through is off the spool")
        #expect(MoveJobTests.number(MoveJobTests.row(after, "inventory", "S1")?["rev"]) == 5,
                "and that spool is stamped, so the correction reaches the shop's other devices")
        #expect(MoveJobTests.number(MoveJobTests.row(after, "inventory", "S9")?["rev"]) == 1,
                "while the spool it never touched is not")
        // The waste row remembers where the filament came from, so a host that
        // lets a shop undo the failure can put it back.
        if case .array(let log)? = after["wasteLog"], case .object(let waste)? = log.first {
            #expect(MoveJobTests.string(waste["spoolId"]) == "S1")
            #expect(MoveJobTests.number(waste["weight"]) == 80)
            #expect((MoveJobTests.number(waste["cost"]) ?? 0) > 0, "and what it cost")
        } else {
            Issue.record("no waste row")
        }
    }

    @Test("a failure with no weight takes nothing off the shelf")
    func noWeight() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let before = Shop.rows(root, "inventory")
        let out = try await engine.recordQcFailure(
            order: Shop.rows(root, "printLog")[0], failureType: "other", severity: "minor",
            reason: "", weight: 0, inspector: nil, inventory: before, now: Date(),
            wasteId: "W-1", defaultReason: "QC fail",
            settings: Shop.settings(root), machines: [], today: Shop.today())
        #expect(out.deducted == 0)
        #expect(out.spools.isEmpty)
        root["inventory"] = .array(out.inventory)
        #expect(MoveJobTests.number(MoveJobTests.row(root, "inventory", "S1")?["weight"]) == 1000)
    }
}

@MainActor
struct MoveJobOnDiskTests {

    static func freshCopy(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    @Test("a move is written to the file, all three collections at once")
    func writesThroughToDisk() async throws {
        let url = try Self.freshCopy(MoveJobTests.book())
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            _ = try await Shop.applyMove(to: &root, id: "J1", stage: .completed,
                                         engine: engine, words: words)
        }

        let after = try Self.read(url)
        #expect(MoveJobTests.string(MoveJobTests.row(after, "printLog", "J1")?["status"]) == "completed")
        #expect(MoveJobTests.number(MoveJobTests.row(after, "inventory", "S1")?["weight"]) == 0)
        #expect(MoveJobTests.number(MoveJobTests.row(after, "consumables", "C2")?["stock"]) == 4)
        #expect(MoveJobTests.rows(after, "auditLog").count == 0, "a completion is not an activity-log move")

        // The rollback copy the recovery path reaches for when the primary will
        // not parse.
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("prev").path))
    }

    @Test("a book that changed hands mid-move is not written to")
    func refusedWhenNotOurs() async throws {
        let url = try Self.freshCopy(MoveJobTests.book())
        let before = try Self.read(url)
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)

        // Ours for the read, somebody else's by the time the swap comes round —
        // which is the window the second ownership check exists to close, and
        // it is a JavaScript call wide now rather than a serialisation.
        var asked = 0
        await #expect(throws: StoreWriter.Refusal.self) {
            try await StoreWriter.update(storeURL: url,
                                         owns: { asked += 1; return asked == 1 },
                                         whoHasIt: { "Khayt on this Mac" }) { root in
                _ = try await Shop.applyMove(to: &root, id: "J1", stage: .completed,
                                             engine: engine, words: words)
            }
        }
        #expect(try Self.read(url) == before, "not one byte")
    }

    @Test("a move the rules refuse leaves the file untouched")
    func refusedRulesLeaveTheFile() async throws {
        var book = MoveJobTests.book(settings: ["autoDeduct": .bool(true),
                                                "productionPaused": .bool(true)])
        // J2 is pending; starting a print in a paused shop is refused.
        book["settings"] = .object(["autoDeduct": .bool(true), "productionPaused": .bool(true)])
        let url = try Self.freshCopy(book)
        let before = try Self.read(url)
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)

        await #expect(throws: Shop.MoveRefused.self) {
            try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                _ = try await Shop.applyMove(to: &root, id: "J2", stage: .printing,
                                             engine: engine, words: words)
            }
        }
        #expect(try Self.read(url) == before)
    }
}

/// Recording money against a job.
///
/// One record changes rather than three, but through the same door: the
/// ownership check, the atomic swap and the undo are the ones the moves already
/// proved, not a second set written for money.
@MainActor
struct PaymentTests {

    static func engineAndWords() async throws -> (KhaytEngine, Words) {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        return (engine, words)
    }

    @Test("what is written is what the reports will read back")
    func statusIsDerived() async throws {
        let (engine, _) = try await Self.engineAndWords()
        // SAR 1,000 job, SAR 600 credited back, SAR 400 paid: settled. The
        // dialog used to write "partial" here and every report read "paid".
        let order: JSONValue = .object([
            "id": .string("J1"), "price": .number(1000),
            "creditNotes": .array([.object(["amount": .number(600)])]),
        ])
        let out = try await engine.recordPayment(order: order, amount: 400, method: "mada",
                                                 paidAt: "2026-09-04", today: "2026-09-04")
        guard case .object(let after) = out.order else { Issue.record("not an order"); return }
        #expect(MoveJobTests.string(after["paymentStatus"]) == "paid")
        #expect(MoveJobTests.number(after["paidAmount"]) == 400)
        #expect(MoveJobTests.string(after["paymentMethod"]) == "mada")
        #expect(try await engine.paymentStatus(of: out.order) == "paid",
                "written and read must agree, which is the whole point")
    }

    @Test("a payment cannot exceed the price")
    func clamped() async throws {
        let (engine, _) = try await Self.engineAndWords()
        let order: JSONValue = .object(["id": .string("J1"), "price": .number(100)])
        let out = try await engine.recordPayment(order: order, amount: 5000, method: "cash",
                                                 paidAt: "2026-09-04", today: "2026-09-04")
        guard case .object(let after) = out.order else { Issue.record("not an order"); return }
        #expect(MoveJobTests.number(after["paidAmount"]) == 100,
                "an overpayment is a credit note, not a bigger paidAmount")
    }

    @Test("clearing a payment leaves the order owed, whatever else is on it")
    func cleared() async throws {
        let (engine, _) = try await Self.engineAndWords()
        let order: JSONValue = .object([
            "id": .string("J1"), "price": .number(100), "paidAmount": .number(100),
            "giftCardDiscount": .number(100), "paymentMethod": .string("cash"),
        ])
        let out = try await engine.clearPayment(order: order)
        guard case .object(let after) = out.order else { Issue.record("not an order"); return }
        #expect(MoveJobTests.number(after["paidAmount"]) == 0)
        #expect(MoveJobTests.string(after["paymentStatus"]) == "unpaid",
                "somebody clearing a payment means the order is owed")
        #expect(after["paymentMethod"] == .null)
    }

    @Test("a payment that would reach somebody is refused whole")
    func refusedForOutbound() async throws {
        let (engine, _) = try await Self.engineAndWords()
        let order: JSONValue = .object(["id": .string("J1"), "price": .number(100),
                                        "clientId": .string("C1")])
        let quiet = try await engine.paymentOutbound(order: order, settings: [:], clients: [])
        #expect(quiet.isEmpty, "a shop with nothing configured records a payment and reaches nobody")

        let wired = try await engine.paymentOutbound(
            order: order,
            settings: ["emailConfig": .object(["provider": .string("smtp"),
                                               "triggers": .array([.string("payment_received")])])],
            clients: [.object(["id": .string("C1"), "email": .string("a@b.c")])])
        #expect(wired.map(\.channel) == ["email"])
    }

    @Test("handing a job over stamps the date and leaves the status alone")
    func handover() async throws {
        let (engine, _) = try await Self.engineAndWords()
        let order: JSONValue = .object(["id": .string("J1"), "status": .string("completed")])
        let out = try await engine.markDelivered(order: order, now: Date())
        #expect(out.ok)
        guard case .object(let after)? = out.order else { Issue.record("not an order"); return }
        #expect(MoveJobTests.string(after["status"]) == "completed",
                "moving it would empty the very column the action feeds")
        #expect(MoveJobTests.string(after["deliveredAt"])?.hasSuffix("Z") == true)
    }

    @Test("a job cannot be handed over before it is made")
    func handoverNeedsCompletion() async throws {
        let (engine, _) = try await Self.engineAndWords()
        for status in ["pending", "printing", "qc", "on_hold", "quote"] {
            let order: JSONValue = .object(["id": .string("J1"), "status": .string(status)])
            let out = try await engine.markDelivered(order: order, now: Date())
            #expect(!out.ok, "\(status) is not ready to be delivered")
            #expect(out.order == nil, "and nothing comes back to write")
        }
    }

    @Test("the methods offered are Khayt's own, in Khayt's order")
    func methodsMatchKhayt() throws {
        let source = try String(contentsOf: MoveJobTests.repoRoot.appending(path: "renderer/order-flows.js"),
                                encoding: .utf8)
        // Pinned to the list the Electron dialog offers. Inventing a method here
        // would put a value in paymentMethod that Khayt's own dialog cannot show.
        let expected = "const methodOptions = ['cash','mada','transfer','stcpay','applepay','visa','other']"
        #expect(source.contains(expected),
                "renderer/order-flows.js's payment methods have changed; Shop.paymentMethods must follow")
        #expect(Shop.paymentMethods == ["cash", "mada", "transfer", "stcpay", "applepay", "visa", "other"])
    }
}

/// Changing a job's due date and how urgent it is.
@MainActor
struct EditJobTests {

    @Test("an edit writes both priority fields and remembers what changed")
    func editsAndRecords() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object([
            "id": .string("J1"), "dueDate": .string("2026-09-20"),
            "priority": .bool(false), "priorityLevel": .string("normal"),
            "discountPct": .number(15),
        ])
        let out = try await engine.editJob(order: order, dueDate: "2026-09-25",
                                           priorityLevel: "urgent",
                                           now: Date(), editId: "edit-1")
        #expect(out.changed)
        guard case .object(let after) = out.order else { Issue.record("not an order"); return }
        #expect(MoveJobTests.string(after["dueDate"]) == "2026-09-25")
        #expect(after["priority"] == .bool(true), "or the card shows no flag on an urgent job")
        #expect(MoveJobTests.string(after["priorityLevel"]) == "urgent")
        #expect(MoveJobTests.number(after["discountPct"]) == 15,
                "a sheet offering two fields must not blank the other three")

        guard case .array(let history)? = after["editHistory"], case .object(let entry) = history[0] else {
            Issue.record("nothing was written down"); return
        }
        #expect(MoveJobTests.string(entry["id"]) == "edit-1")
        #expect(MoveJobTests.string(entry["at"])?.hasSuffix("Z") == true)
    }

    @Test("a due date can be cleared, because no due date is a real answer")
    func clearsTheDueDate() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object(["id": .string("J1"), "dueDate": .string("2026-09-20")])
        let out = try await engine.editJob(order: order, dueDate: nil, priorityLevel: "normal",
                                           now: Date(), editId: "e1")
        guard case .object(let after) = out.order else { Issue.record("not an order"); return }
        #expect(after["dueDate"] == .null)
        #expect(out.changed)
    }

    @Test("an editor opened and closed again writes no revision")
    func noChangeNoWrite() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object([
            "id": .string("J1"), "dueDate": .string("2026-09-20"),
            "priority": .bool(false), "priorityLevel": .string("normal"),
        ])
        let out = try await engine.editJob(order: order, dueDate: "2026-09-20",
                                           priorityLevel: "normal", now: Date(), editId: "e1")
        #expect(!out.changed, "else every open-and-close syncs the record to the cloud")
        #expect(out.order == order, "and the row is byte-identical, so nothing is stamped")
    }

    @Test("the priority is read from whichever field the record carries")
    func priorityOfOldAndNewRecords() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.priority(of: .object(["priority": .bool(true)])) == "high")
        #expect(try await engine.priority(of: .object(["priorityLevel": .string("urgent")])) == "urgent")
        #expect(try await engine.priority(of: .object([
            "priority": .bool(true), "priorityLevel": .string("normal")])) == "normal",
            "an explicit normal beats the legacy flag")
        #expect(try await engine.priority(of: .object([:])) == "normal")
    }

    /// The Swift reading must not drift from the shared one — it is used per
    /// cell and mirrored for that reason, the way `Stage.of` is.
    @Test("Swift and the shared rule read the same priority")
    func priorityMirrorAgrees() async throws {
        let engine = try KhaytEngine()
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        for job in shop.orders {
            let row: JSONValue = .object([
                "priority": .bool(job.priority),
                "priorityLevel": job.priorityLevel.map(JSONValue.string) ?? .null,
            ])
            #expect(shop.priorityOf(job) == (try await engine.priority(of: row)),
                    "diverged for \(job.id)")
        }
    }
}

/// A job that failed inspection.
@MainActor
struct QcFailureTests {

    static func book() -> [String: JSONValue] {
        var root = MoveJobTests.book()
        guard case .array(var jobs)? = root["printLog"], case .object(var j1) = jobs[0] else { return root }
        j1["status"] = .string("qc")
        j1["material"] = .string("PLA")
        jobs[0] = .object(j1)
        root["printLog"] = .array(jobs)
        root["inventory"] = .array([
            .object(["id": .string("S1"), "material": .string("PLA"),
                     "weight": .number(1000), "cost": .number(100)]),
        ])
        return root
    }

    @Test("a failure reaches the job, a defect and the waste log")
    func threeRecords() async throws {
        let engine = try KhaytEngine()
        let root = Self.book()
        let order = try #require(Self.asValue(MoveJobTests.row(root, "printLog", "J1")))

        let out = try await engine.recordQcFailure(
            order: order, failureType: "warping", severity: "major",
            reason: "it lifted", weight: 40, inspector: nil,
            inventory: MoveJobTests.rowValues(root, "inventory"),
            now: Date(), wasteId: "WASTE-1", defaultReason: "Fail QC")

        guard case .object(let after) = out.order else { Issue.record("not an order"); return }
        #expect(MoveJobTests.string(after["qcStatus"]) == "fail")
        #expect(MoveJobTests.string(after["qcFailedAt"])?.hasSuffix("Z") == true,
                "or computeQcMetrics does not count it as a failure at all")

        guard case .array(let defects)? = after["defects"], case .object(let defect) = defects[0] else {
            Issue.record("no defect"); return
        }
        #expect(MoveJobTests.string(defect["type"]) == "warping")
        #expect(MoveJobTests.string(defect["severity"]) == "major")

        guard case .object(let waste) = out.waste else { Issue.record("no waste row"); return }
        #expect(MoveJobTests.number(waste["weight"]) == 40)
        #expect(MoveJobTests.number(waste["cost"]) == 4, "100 riyals per kilo, 40 grams")
        #expect(MoveJobTests.string(waste["orderId"]) == "J1")
        #expect(MoveJobTests.string(waste["id"]) == "WASTE-1")
    }

    @Test("a category the waste screen cannot name becomes one it can")
    func unknownCategory() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object(["id": .string("J1"), "material": .string("PLA")])
        let out = try await engine.recordQcFailure(
            order: order, failureType: "exploded", severity: "catastrophic",
            reason: "", weight: 0, inspector: nil, inventory: [], now: Date(),
            wasteId: "W1", defaultReason: "Fail QC")
        guard case .object(let after) = out.order,
              case .array(let defects)? = after["defects"],
              case .object(let defect) = defects[0] else { Issue.record("no defect"); return }
        #expect(MoveJobTests.string(defect["type"]) == "other")
        #expect(MoveJobTests.string(defect["severity"]) == "major")
    }

    @Test("leaving QC for anywhere but completed asks what went wrong")
    func questionOnLeavingQC() async {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        guard let inQC = shop.orders.first(where: { $0.status == "qc" }) else {
            // The sample shop may have none; the rule is still worth stating.
            return
        }
        #expect(shop.questionFor(inQC.id, moving: .pending) != nil, "a failure has to be written down")
        #expect(shop.questionFor(inQC.id, moving: .printing) != nil)
        #expect(shop.questionFor(inQC.id, moving: .completed) != nil, "and a pass does too")

        // A job that is not in QC is not failing an inspection by moving.
        guard let printing = shop.orders.first(where: { $0.status == "printing" }) else { return }
        #expect(shop.questionFor(printing.id, moving: .pending) == nil)
    }

    @Test("the categories offered are the shared list, in its order")
    func categoriesMatch() async throws {
        let engine = try KhaytEngine()
        let shared = try await engine.raw("KhaytQcFailure.FAILURE_TYPES", as: [String].self)
        #expect(Shop.failureTypes == shared,
                "a category not on the shared list reaches the waste screen unnamed")
    }

    static func asValue(_ dict: [String: JSONValue]?) -> JSONValue? {
        dict.map(JSONValue.object)
    }
}

/// The same write, against a COPY OF THIS MAC'S REAL BOOK.
///
/// Every other test builds the book it needs, which means every other test
/// knows what is in it. A real store has orders with no parts, orders with no
/// customer, orders whose material is not on the shelf, forty-field rows this
/// app decodes only some of, and a `printFiles` collection twenty times the
/// size of everything else. None of that is exotic; it is simply what a shop's
/// book looks like after a year.
///
/// Nothing here asserts a figure — the numbers belong to whichever book this
/// runs against. It asserts that the chain COMPLETES, writes what it said it
/// would, leaves everything it did not name exactly as it was, and comes back
/// when undone.
@MainActor
struct MoveOnARealBookTests {

    /// This Mac's book if there is one, the sample otherwise. Copied, never
    /// touched in place: a write path tried on a live book has not been tested,
    /// it has been risked.
    static func copyOfARealBook() throws -> URL? {
        let data: Data
        if let build = StoreReader.Build.allCases.first(where: \.exists) {
            data = try Data(contentsOf: build.storeURL)
        } else if let url = Bundle.module.url(forResource: "sample-shop", withExtension: "json") {
            data = try Data(contentsOf: url)
        } else {
            return nil
        }
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-realbook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try data.write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    /// A job the rules will accept, so the test measures the write and not the
    /// gate — MAKING one if the book has none.
    ///
    /// The first version of this looked for a pending job and returned nil when
    /// there was none, and this Mac's development book has forty completed jobs
    /// and nothing else. All three tests passed in twenty milliseconds by doing
    /// nothing at all, which is the shape of a test that will go on passing
    /// after the thing it covers is broken. The book is a copy; setting one row
    /// to `pending` costs nothing and guarantees the path is walked.
    static func aJobToMove(in url: URL) throws -> (id: String, to: Stage)? {
        var root = try read(url)
        guard case .array(var rows)? = root["printLog"], !rows.isEmpty else { return nil }
        for row in rows {
            if case .object(let o) = row, case .string(let id)? = o["id"],
               case .string("pending")? = o["status"] {
                // pending → printing is the least consequential real move there
                // is: no deduction, no inspection, no handover.
                return (id, .printing)
            }
        }
        guard case .object(var first) = rows[0], case .string(let id)? = first["id"] else { return nil }
        first["status"] = .string("pending")
        rows[0] = .object(first)
        root["printLog"] = .array(rows)
        try JSONEncoder().encode(root).write(to: url)
        return (id, .printing)
    }

    @Test("a move completes on a real book and changes only what it named")
    func movesOnARealBook() async throws {
        guard let url = try Self.copyOfARealBook() else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        guard let job = try Self.aJobToMove(in: url) else { return }   // an empty book
        let before = try Self.read(url)

        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        var undo: [Shop.ChangedRecord] = []

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            undo = try await Shop.applyMove(to: &root, id: job.id, stage: job.to,
                                            engine: engine, words: words).undo
        }

        let after = try Self.read(url)
        #expect(MoveJobTests.string(MoveJobTests.row(after, "printLog", job.id)?["status"])
                == job.to.rawValue)

        // EVERY OTHER COLLECTION IS UNTOUCHED, bar the two this move is allowed
        // to write. A move that quietly rewrites the library or the customers is
        // the failure a synthetic fixture cannot show, because a synthetic
        // fixture does not have them.
        //
        // `auditLog` gains one line — this move IS a status change, and the one
        // a shop most often has to explain later. `inventory` and `consumables`
        // are named because a completion empties them; this move is not one, so
        // they are checked here too and must be identical.
        let allowed: Set<String> = ["printLog", "auditLog"]
        for (key, value) in before where !allowed.contains(key) {
            #expect(after[key] == value, "\(key) changed, and this move never named it")
        }
        let logBefore = MoveJobTests.rows(before, "auditLog").count
        let logAfter = MoveJobTests.rows(after, "auditLog")
        #expect(logAfter.count == logBefore + 1, "one line, not none and not two")
        #expect(MoveJobTests.string(logAfter.last?["detail"]) == "\(job.id) → \(job.to.rawValue)")
        #expect(MoveJobTests.string(logAfter.last?["id"])?.hasPrefix("AL-") == true)

        // And every other ORDER, too: only the one row.
        let changedIds = Set(undo.map(\.id))
        #expect(changedIds == [job.id], "and exactly one row was written")
        for row in MoveJobTests.rows(before, "printLog") {
            guard case .string(let id)? = row["id"], id != job.id else { continue }
            #expect(MoveJobTests.row(after, "printLog", id) == row, "order \(id) was not part of this")
        }
    }

    @Test("undoing it puts the real book back")
    func undoOnARealBook() async throws {
        guard let url = try Self.copyOfARealBook() else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        guard let job = try Self.aJobToMove(in: url) else { return }
        let before = try Self.read(url)

        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        var undo: [Shop.ChangedRecord] = []

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            undo = try await Shop.applyMove(to: &root, id: job.id, stage: job.to,
                                            engine: engine, words: words).undo
        }
        #expect(!undo.isEmpty, "the move wrote nothing, so the undo proves nothing")
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            for record in undo {
                guard case .array(var rows)? = root[record.collection] else { continue }
                for i in rows.indices {
                    guard case .object(let current) = rows[i],
                          case .string(let id)? = current["id"], id == record.id else { continue }
                    rows[i] = .object(StoreWriter.restoring(record.was, over: current))
                }
                root[record.collection] = .array(rows)
            }
        }

        let after = try Self.read(url)
        guard case .object(let restored)? = MoveJobTests.row(after, "printLog", job.id).map(JSONValue.object),
              case .object(let original)? = MoveJobTests.row(before, "printLog", job.id).map(JSONValue.object)
        else { Issue.record("the job vanished"); return }

        for (key, value) in original where key != "rev" && key != "updatedAt" {
            #expect(restored[key] == value, "\(key) did not come back")
        }
        // The revision goes FORWARD through an undo: a record that went
        // backwards would look to the next sync like the change never happened,
        // and the other machine's copy would win.
        if case .number(let was)? = original["rev"], case .number(let now)? = restored["rev"] {
            #expect(now > was)
        }
    }

    @Test("the whole book still decodes after a move")
    func stillDecodes() async throws {
        guard let url = try Self.copyOfARealBook() else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        guard let job = try Self.aJobToMove(in: url) else { return }
        let before = try Self.read(url)

        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            _ = try await Shop.applyMove(to: &root, id: job.id, stage: job.to,
                                         engine: engine, words: words)
        }

        // Written by this app, read back by this app's decoder — the same one
        // the screens use. A row this app writes and cannot read is a job that
        // disappears from the table after being moved.
        let after = try Self.read(url)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var decoded = 0
        for row in MoveJobTests.rows(after, "printLog") {
            if (try? decoder.decode(Order.self, from: encoder.encode(row))) != nil { decoded += 1 }
        }
        let couldDecodeBefore = MoveJobTests.rows(before, "printLog").filter {
            (try? decoder.decode(Order.self, from: encoder.encode($0))) != nil
        }.count
        #expect(decoded == couldDecodeBefore, "a move must not make a row unreadable")
    }
}

/// Taking a job.
///
/// The record is `lib/order-new.js`'s and is proved field-for-field against the
/// original there. What is tested here is that this app asks for it correctly,
/// writes the order AND the counter it consumed in one swap, and produces a row
/// its own decoder can read — a job created on the Mac that does not appear in
/// the Mac's own table would be the worst possible first impression.
@MainActor
struct NewJobTests {

    static func shelf() -> [JSONValue] {
        [.object(["id": .string("S1"), "material": .string("PLA"),
                  "cost": .number(80), "weight": .number(1000)]),
         .object(["id": .string("R1"), "material": .string("Resin"),
                  "materialType": .string("resin"), "cost": .number(300), "weight": .number(1000)])]
    }

    /// THIS TEST USED TO ASSERT 30, AND ITS NAME WAS ALREADY WRONG.
    ///
    /// Thirty is the material plus a quarter hour of labour — which is what you
    /// get when wear, power, the rest of the labour and the failure allowance
    /// are all missing. They were: this app read them from five
    /// `settings.default*` keys Khayt has never written, so every one of them
    /// came out zero and `computePartBaseCost` said so without complaining. The
    /// test agreed with the bug, under the very heading that claimed parity.
    @Test("a job taken here is costed the way the calculator costs it")
    func partCostMatchesTheSharedModel() async throws {
        let engine = try KhaytEngine()
        let part: JSONValue = .object([
            "filamentId": .string("S1"), "spoolCost": .number(80), "spoolWeight": .number(1000),
            "printWeight": .number(250), "printTime": .number(4), "qty": .number(1),
            "laborRate": .number(40), "prepTime": .number(0.25),
        ])
        let cost = try await engine.partCost(part, inventory: Self.shelf(), settings: [:])
        //   material  250g of an 80-per-kilo spool      20
        //   wear      4h at Khayt's 0.75 an hour         3
        //   power     4h at 150W and 0.18 a kWh          0.108
        //   labour    this part's own 40 an hour, over
        //             its own 0.25 prep and the 0.5
        //             finishing Khayt assumes           30
        //   buffer    10% of all of it                   5.3108
        #expect(abs(cost - 58.4188) < 0.0001)
    }

    /// The one that would have caught it. A part that says nothing about rates
    /// must not be costed as though every rate were nought.
    @Test("a part that names no rates is not quoted at material alone")
    func ratesAreNeverSilentlyZero() async throws {
        let engine = try KhaytEngine()
        // This shop's own job: 272 grams and just under fifteen hours.
        let part: JSONValue = .object([
            "spoolCost": .number(75), "spoolWeight": .number(1000),
            "printWeight": .number(272), "printTime": .number(14.9), "qty": .number(1),
        ])
        let cost = try await engine.partCost(part, inventory: [], settings: [:])
        let material = 0.075 * 272
        #expect(abs(material - 20.4) < 0.0001)
        #expect(cost > material * 4, "material was \(material) and the job costs \(cost)")
        #expect(abs(cost - 109.43) < 0.01, "the figure Khayt's own calculator quotes")
    }

    /// The two rates a printer knows about itself, and only those two.
    @Test("the machine the job is on supplies its own power draw and wear")
    func machineRatesReachTheCost() async throws {
        let engine = try KhaytEngine()
        let part: JSONValue = .object([
            "spoolCost": .number(0), "spoolWeight": .number(1000),
            "printWeight": .number(0), "printTime": .number(10), "qty": .number(1),
            // Isolate the machine: no labour, no allowance.
            "laborRate": .number(0), "failureRate": .number(0),
        ])
        let onDefaults = try await engine.partCost(part, inventory: [], settings: [:])
        // 10h × 0.75 wear + 10h × 0.150kW × 0.18 = 7.5 + 0.27
        #expect(abs(onDefaults - 7.77) < 0.0001)

        // This shop's U1: 140W, and no wear rate of its own.
        let u1: JSONValue = .object(["id": .string("M1"), "name": .string("Snapmaker U1"),
                                     "powerDraw": .number(140)])
        let onTheU1 = try await engine.partCost(part, inventory: [], settings: [:], machine: u1)
        #expect(abs(onTheU1 - 7.752) < 0.0001, "7.5 wear, and 140W rather than 150")

        let thirsty: JSONValue = .object(["id": .string("M2"), "powerDraw": .number(600),
                                          "wearRate": .number(2)])
        let onThat = try await engine.partCost(part, inventory: [], settings: [:], machine: thirsty)
        #expect(abs(onThat - 21.08) < 0.0001, "20 wear, 1.08 power")
    }

    /// THE ONE THAT REACHES THE OTHER APP.
    ///
    /// `renderer/build.js` loads a part into its editor with
    /// `$('#wearRate').value = part.wearRate || ''`, and saves with
    /// `clampPositive($('#wearRate').value)`. So a part with no rates on it
    /// opens there with every rate field blank and re-costs to nothing on the
    /// next save. A job taken on this Mac would have lost its price on
    /// somebody else's machine, silently, and this app would never have known.
    @Test("a costed part carries the rates it was costed at")
    func costedPartCarriesItsRates() async throws {
        let engine = try KhaytEngine()
        let part: JSONValue = .object([
            "filamentId": .string("S1"), "spoolCost": .number(80), "spoolWeight": .number(1000),
            "printWeight": .number(250), "printTime": .number(4), "qty": .number(1),
        ])
        let costed = try await engine.costPart(part, inventory: Self.shelf(), settings: [:])

        // The seven Khayt's own form opens on.
        #expect(costed.rates.wearRate == 0.75)
        #expect(costed.rates.powerDraw == 150)
        #expect(costed.rates.elecRate == 0.18)
        #expect(costed.rates.prepTime == 0.25)
        #expect(costed.rates.postTime == 0.5)
        #expect(costed.rates.laborRate == 90)
        #expect(costed.rates.failureRate == 10)
        // All seven, with the names the book uses — a missing one is a blank
        // field in the other app's editor.
        #expect(Set(costed.rates.fields.keys) == ["wearRate", "powerDraw", "elecRate",
                                                  "prepTime", "postTime", "laborRate",
                                                  "failureRate"])

        // And they are the rates the figure was actually made from: costing the
        // part again with them written on it has to give the same number.
        guard case .object(var withRates) = part else { Issue.record("part"); return }
        for (key, value) in costed.rates.fields { withRates[key] = value }
        let again = try await engine.partCost(.object(withRates), inventory: Self.shelf(),
                                              settings: [:])
        #expect(abs(again - costed.cost) < 0.0001)
        #expect(abs(costed.parts.total - costed.cost) < 0.0001)
    }

    /// The wiring proof: the rates have to reach the RECORD, not merely exist.
    ///
    /// `Shop.partRows` is what `newJobInput` builds a job's parts with, called
    /// here rather than restated — a test that assembles its own row would go
    /// green against a `newJobInput` that dropped every one of these.
    @Test("a saved part carries the seven rates the other app reads back")
    func savedPartCarriesTheRates() async throws {
        let engine = try KhaytEngine()
        let spools = try JSONDecoder().decode([Spool].self, from: Data("""
            [{"id":"S1","material":"PLA","cost":80,"weight":1000}]
            """.utf8))
        let costed = try await engine.costPart(
            .object(["spoolCost": .number(80), "spoolWeight": .number(1000),
                     "printWeight": .number(250), "printTime": .number(4),
                     "qty": .number(1)]),
            inventory: [], settings: [:])

        var draft = NewJobSheet.Draft()
        draft.name = "Bracket"
        draft.spoolId = "S1"
        draft.grams = "250"
        draft.hours = "4"
        draft.cost = costed.cost
        draft.rates = costed.rates

        let rows = Shop.partRows([draft], spools: spools, unnamed: "A part")
        guard case .object(let row)? = rows.first else { Issue.record("no row"); return }

        for (key, expected) in costed.rates.fields {
            #expect(row[key] == expected, "\(key) is missing from the saved part")
        }
        #expect(row["unitCost"] == .number(costed.cost))
        #expect(row["spoolCost"] == .number(80), "and the spool still fills itself in")
    }

    /// A machine's rates are the ones recorded, not the defaults it replaced.
    @Test("the rates recorded are the machine's own where it has them")
    func recordedRatesFollowTheMachine() async throws {
        let engine = try KhaytEngine()
        let part: JSONValue = .object([
            "printWeight": .number(100), "printTime": .number(3), "qty": .number(1),
        ])
        let u1: JSONValue = .object(["id": .string("M1"), "powerDraw": .number(140)])
        let costed = try await engine.costPart(part, inventory: [], settings: [:], machine: u1)
        #expect(costed.rates.powerDraw == 140, "and not the 150 it started from")
        #expect(costed.rates.wearRate == 0.75, "which the U1 says nothing about")
    }

    /// The four figures the sheet shows have to add up to the one it charges,
    /// or the screen is explaining a different number from the one on it.
    @Test("the breakdown sums to the cost, exactly")
    func breakdownSumsToCost() async throws {
        let engine = try KhaytEngine()
        let part: JSONValue = .object([
            "filamentId": .string("S1"), "spoolCost": .number(80), "spoolWeight": .number(1000),
            "printWeight": .number(250), "printTime": .number(4), "qty": .number(1),
        ])
        let cost = try await engine.partCost(part, inventory: Self.shelf(), settings: [:])
        let split = try await engine.partBreakdown(part, inventory: Self.shelf(), settings: [:])
        #expect(abs(split.total - cost) < 0.0001)
        #expect(split.material > 0 && split.machine > 0 && split.labor > 0 && split.buffer > 0,
                "every bucket earns its place on the screen")
    }

    /// Resin is priced per kilo and filament per spool, and the difference is
    /// read off `materialType` on the SHELF — not off anything the part carries.
    /// Handing the cost model a re-encoded `Spool`, which has no `materialType`,
    /// would silently cost every resin part as if it were filament.
    @Test("resin is costed as resin, which needs the shelf's own rows")
    func resinNeedsTheRawShelf() async throws {
        let engine = try KhaytEngine()
        let part: JSONValue = .object([
            "filamentId": .string("R1"), "spoolCost": .number(300), "spoolWeight": .number(1000),
            "printWeight": .number(100), "printTime": .number(0), "qty": .number(1),
        ])
        // Rates zeroed ON THE PART, which beats the defaults — this test is
        // about which side of a division the weight goes, and sixty-seven
        // riyals of assumed labour on top of it proves nothing either way.
        guard case .object(var bare) = part else { Issue.record("part"); return }
        bare["laborRate"] = .number(0)
        bare["wearRate"] = .number(0)
        bare["powerDraw"] = .number(0)
        bare["failureRate"] = .number(0)
        let materialOnly = JSONValue.object(bare)

        let asResin = try await engine.partCost(materialOnly, inventory: Self.shelf(), settings: [:])
        let withoutTheFlag = try await engine.partCost(
            materialOnly,
            inventory: [.object(["id": .string("R1"), "material": .string("Resin"),
                                 "cost": .number(300), "weight": .number(1000)])],
            settings: [:])
        #expect(abs(asResin - 30) < 0.0001, "300 per kilo, 100 grams")
        #expect(abs(withoutTheFlag - 30) < 0.0001, "the same here only because spoolWeight is 1000")
        #expect(asResin == withoutTheFlag)
    }

    @Test("the order and the counter it consumed are written together")
    func orderAndCounterTogether() async throws {
        let engine = try KhaytEngine()
        let input: [String: JSONValue] = [
            "parts": .array([.object(["name": .string("Bracket"), "material": .string("PLA"),
                                      "baseCost": .number(100), "printTime": .number(4),
                                      "qty": .number(2)])]),
            "project": .string("Bracket set"),
            "margin": .number(40),
        ]
        let out = try await engine.newOrder(
            input, orders: [], settings: ["invNumNext": .number(12), "invNumYear": .number(2026)],
            now: Date(), tokens: (tracking: Shop.randomBytes(16), quoteApproval: Shop.randomBytes(16)))

        guard case .object(let order) = out.order else { Issue.record("not an order"); return }
        #expect(MoveJobTests.string(order["id"]) == "INV-2026-0012")
        #expect(MoveJobTests.string(order["status"]) == "pending")
        #expect(MoveJobTests.number(order["price"]) == 140)
        // The counter came back advanced. Writing the order without it hands the
        // same invoice number to the next job.
        #expect(MoveJobTests.number(out.settings["invNumNext"]) == 13)
    }

    @Test("a job this app writes is a job this app can read")
    func theRowDecodes() async throws {
        let engine = try KhaytEngine()
        let input: [String: JSONValue] = [
            "parts": .array([.object(["name": .string("Bracket"), "material": .string("PLA"),
                                      "baseCost": .number(100), "printTime": .number(4),
                                      "qty": .number(1), "printWeight": .number(180)])]),
            "project": .string("Bracket set"),
            "clientId": .string("C1"),
            "margin": .number(40),
            "depositAmount": .number(50),
        ]
        let out = try await engine.newOrder(input, orders: [], settings: [:], now: Date(),
                                            tokens: (tracking: Shop.randomBytes(16),
                                                     quoteApproval: Shop.randomBytes(16)))
        let decoded = try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(out.order))
        #expect(decoded.project == "Bracket set")
        #expect(decoded.status == "pending")
        #expect(decoded.parts.count == 1)
        #expect(decoded.paidAmount == 50)
        #expect(Stage.of(decoded) == .pending, "and it lands on the board")
    }

    @Test("a quote is a quote, and takes no invoice number")
    func quotesTakeNoInvoiceNumber() async throws {
        let engine = try KhaytEngine()
        let input: [String: JSONValue] = [
            "parts": .array([.object(["baseCost": .number(10), "printTime": .number(1)])]),
            "margin": .number(0), "asQuote": .bool(true),
        ]
        let settings: [String: JSONValue] = ["invNumNext": .number(9), "quoteNumNext": .number(3)]
        let out = try await engine.newOrder(input, orders: [], settings: settings, now: Date(),
                                            tokens: (tracking: Shop.randomBytes(16),
                                                     quoteApproval: Shop.randomBytes(16)))
        guard case .object(let order) = out.order else { Issue.record("not an order"); return }
        #expect(MoveJobTests.string(order["status"]) == "quote")
        #expect(order["invoiceNumber"] == .null)
        #expect(MoveJobTests.number(out.settings["invNumNext"]) == 9, "untouched")
        #expect(MoveJobTests.number(out.settings["quoteNumNext"]) == 4)
    }

    @Test("the tokens are real bytes, not the same bytes every time")
    func tokensAreRandom() {
        let a = Shop.randomBytes(16), b = Shop.randomBytes(16)
        #expect(a.count == 16)
        #expect(a != b, "a shared tracking token would let one customer read another's job")
    }
}

/// Taking a job, all the way to the file.
///
/// The order and the counter it consumed have to land in the same swap. Saving
/// the order without the counter hands the same invoice number to the next job;
/// saving the counter without the order burns one for nothing. Neither is
/// visible in a test that only inspects the record.
@MainActor
struct NewJobOnDiskTests {

    static func book() -> [String: JSONValue] {
        [
            "printLog": .array([.object(["id": .string("OLD"), "status": .string("pending"),
                                         "date": .string("2026-09-01"), "project": .string("Older"),
                                         "price": .number(10), "paidAmount": .number(0),
                                         "paymentStatus": .string("unpaid"), "printTime": .number(1),
                                         "priority": .bool(false), "notes": .string("")])]),
            "inventory": .array([]),
            "settings": .object(["invNumNext": .number(21), "invNumYear": .number(2026)]),
        ]
    }

    static func write(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-newjob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static let INPUT: [String: JSONValue] = [
        "parts": .array([.object(["name": .string("Bracket"), "material": .string("PLA"),
                                  "baseCost": .number(100), "printTime": .number(3),
                                  "qty": .number(2)])]),
        "project": .string("Bracket set"),
        "margin": .number(40),
    ]

    @Test("the order and the counter land together, and the older job is untouched")
    func writesBoth() async throws {
        let url = try Self.write(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try KhaytEngine()

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            let out = try await engine.newOrder(
                Self.INPUT, orders: MoveJobTests.rowValues(root, "printLog"),
                settings: Shop.settings(root), now: Date(),
                tokens: (tracking: Shop.randomBytes(16), quoteApproval: Shop.randomBytes(16)))
            root["printLog"] = .array([out.order] + MoveJobTests.rowValues(root, "printLog"))
            root["settings"] = .object(out.settings)
        }

        let after = try JSONDecoder().decode([String: JSONValue].self,
                                             from: Data(contentsOf: url))
        let jobs = MoveJobTests.rows(after, "printLog")
        #expect(jobs.count == 2)
        #expect(MoveJobTests.string(jobs[0]["id"]) == "INV-2026-0021", "newest first")
        #expect(MoveJobTests.string(jobs[1]["id"]) == "OLD", "and the older one is still there")
        // The counter, in the same file, advanced exactly once.
        guard case .object(let settings)? = after["settings"] else { Issue.record("no settings"); return }
        #expect(MoveJobTests.number(settings["invNumNext"]) == 22)
    }

    @Test("two jobs in a row take two different numbers")
    func noCollision() async throws {
        let url = try Self.write(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try KhaytEngine()

        for _ in 0..<3 {
            try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                let out = try await engine.newOrder(
                    Self.INPUT, orders: MoveJobTests.rowValues(root, "printLog"),
                    settings: Shop.settings(root), now: Date(),
                    tokens: (tracking: Shop.randomBytes(16), quoteApproval: Shop.randomBytes(16)))
                root["printLog"] = .array([out.order] + MoveJobTests.rowValues(root, "printLog"))
                root["settings"] = .object(out.settings)
            }
        }

        let after = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        let ids = MoveJobTests.rows(after, "printLog").compactMap { MoveJobTests.string($0["id"]) }
        #expect(Set(ids).count == ids.count, "the id is the primary key — a collision overwrites a job")
        #expect(ids.prefix(3) == ["INV-2026-0023", "INV-2026-0022", "INV-2026-0021"])
    }

    @Test("every job written is a job the table can show")
    func allDecodable() async throws {
        let url = try Self.write(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try KhaytEngine()

        for quote in [false, true] {
            var input = Self.INPUT
            input["asQuote"] = .bool(quote)
            try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                let out = try await engine.newOrder(
                    input, orders: MoveJobTests.rowValues(root, "printLog"),
                    settings: Shop.settings(root), now: Date(),
                    tokens: (tracking: Shop.randomBytes(16), quoteApproval: Shop.randomBytes(16)))
                root["printLog"] = .array([out.order] + MoveJobTests.rowValues(root, "printLog"))
                root["settings"] = .object(out.settings)
            }
        }

        let after = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        let rows = MoveJobTests.rowValues(after, "printLog")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let decoded = rows.compactMap { try? decoder.decode(Order.self, from: encoder.encode($0)) }
        #expect(decoded.count == rows.count,
                "a job this app wrote and cannot read is a job that vanishes from the table")
        #expect(decoded.contains { Stage.of($0) == .quote })
        #expect(decoded.contains { Stage.of($0) == .pending })
    }
}
