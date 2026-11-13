import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The phone's two routes the Mac did not serve (the Nov 10 2026 review):
/// an expense with its receipt, and the "ask the Mac" quote.
struct PhoneExpenseTests {

    @Test("a receipt is what its first bytes say it is")
    func kinds() {
        #expect(ExpenseReceipt.kind(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
        #expect(ExpenseReceipt.kind(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "png")
        #expect(ExpenseReceipt.kind(of: Data("%PDF-1.7".utf8)) == "pdf")
        #expect(ExpenseReceipt.kind(of: Data("<html>".utf8)) == nil)
        #expect(ExpenseReceipt.kind(of: Data()) == nil)
    }

    @Test("a receipt's name stays in its folder, and its path is only ever read inside receipts/")
    func paths() throws {
        let name = ExpenseReceipt.filename("jpg")
        #expect(name.hasPrefix("receipt-") && name.hasSuffix(".jpg") && !name.contains("/"))
        #expect(ExpenseReceipt.filename("jpg") != name)

        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-receipts-\(UUID().uuidString)")
        let receipts = dir.appending(path: "receipts")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        try Data([0xFF, 0xD8, 0xFF]).write(to: receipts.appending(path: "a.jpg"))
        try Data("secret".utf8).write(to: dir.appending(path: "other.txt"))

        #expect(ExpenseReceipt.file(for: "receipts/a.jpg", storeURL: store) != nil)
        #expect(ExpenseReceipt.file(for: "receipts/missing.jpg", storeURL: store) == nil)
        #expect(ExpenseReceipt.file(for: "receipts/../other.txt", storeURL: store) == nil, "never up out of the folder")
        #expect(ExpenseReceipt.file(for: "other.txt", storeURL: store) == nil)
        #expect(ExpenseReceipt.file(for: "", storeURL: store) == nil)
        // The desktop writes the whole path for a phone's photo; it opens when it is on this computer.
        #expect(ExpenseReceipt.file(for: receipts.appending(path: "a.jpg").path, storeURL: store) != nil)

        // THE PATH COMES FROM THE BOOK, WHICH A PHONE CAN WRITE. The paperclip
        // opens the file, so only a picture or a PDF, really a file, inside a
        // folder named `receipts` (beta.34 pre-release review).
        let fm = FileManager.default
        #expect(ExpenseReceipt.file(for: dir.appending(path: "other.txt").path, storeURL: store) == nil, "a whole path outside receipts/")
        #expect(ExpenseReceipt.file(for: "/Applications/Calculator.app", storeURL: store) == nil)
        #expect(ExpenseReceipt.file(for: "/System/Applications/Utilities/Terminal.app", storeURL: store) == nil)
        try Data("#!/bin/sh\n".utf8).write(to: receipts.appending(path: "run.command"))
        #expect(ExpenseReceipt.file(for: "receipts/run.command", storeURL: store) == nil, "not a receipt's kind")
        #expect(ExpenseReceipt.file(for: receipts.appending(path: "run.command").path, storeURL: store) == nil)
        try fm.createDirectory(at: receipts.appending(path: "folder.pdf"), withIntermediateDirectories: true)
        #expect(ExpenseReceipt.file(for: "receipts/folder.pdf", storeURL: store) == nil, "a folder named like a PDF")
        // A link is judged by what it points at.
        try fm.createSymbolicLink(at: receipts.appending(path: "link.jpg"), withDestinationURL: dir.appending(path: "other.txt"))
        #expect(ExpenseReceipt.file(for: "receipts/link.jpg", storeURL: store) == nil)
        try Data("%PDF-1.4".utf8).write(to: receipts.appending(path: "bill.PDF"))
        #expect(ExpenseReceipt.file(for: "receipts/bill.PDF", storeURL: store) != nil, "the extension's case does not matter")
    }

    @Test("an API token never reaches the phone-only photo route, whatever header it carries")
    func tokenIsNotAPhone() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/LanServer.swift")
        let server = try String(contentsOf: url, encoding: .utf8)
        #expect(server.contains("guard !request.tokenScoped, LanDevices.isSigned(request.headers) else {"))
    }

    @Test("the expense route is recognised from the request line, under either name")
    func route() {
        #expect(LanServer.isExpenseUpload(method: "POST", target: "/api/expense"))
        #expect(LanServer.isExpenseUpload(method: "post", target: "/v1/expense/?x=1"))
        #expect(!LanServer.isExpenseUpload(method: "GET", target: "/api/expense"))
        #expect(!LanServer.isExpenseUpload(method: "POST", target: "/api/expenses"))
        #expect(ExpenseReceipt.maxBody > ExpenseReceipt.maxBytes * 4 / 3)
    }

    @Test("the Mac's engine answers the phone's quote by the shared rule")
    func quote() async throws {
        let engine = try KhaytEngine()
        let store: JSONValue = .object(["settings": .object(["currency": .string("SAR")]), "inventory": .array([])])
        let part: JSONValue = .object(["spoolCost": .number(80), "spoolWeight": .number(1000),
                                       "printWeight": .number(100), "qty": .number(2), "margin": .number(50)])
        let out = try await engine.lanRest("quotePart", store: store,
                                           args: [part, .object(["today": .string("2026-11-10"), "overheadPerHour": .number(0)])])
        #expect(out.status == 200)
        guard case .object(let body) = out.body, case .number(let total)? = body["totalCost"] else {
            Issue.record("no body"); return
        }
        #expect(total > 0)
        #expect(body["currency"] == .string("SAR"))
        let bad = try await engine.lanRest("quotePart", store: store, args: [.null, .object([:])])
        #expect(bad.status == 400)
    }

    @Test("New Job warns under the shop's minimum order, and only then")
    @MainActor func minimumOrder() {
        let settings: [String: JSONValue] = ["minOrderAmount": .number(50)]
        #expect(NewJobSheet.belowMinimum(total: 30, settings: settings) == 50)
        #expect(NewJobSheet.belowMinimum(total: 50, settings: settings) == nil)
        #expect(NewJobSheet.belowMinimum(total: 80, settings: settings) == nil)
        #expect(NewJobSheet.belowMinimum(total: 30, settings: [:]) == nil, "no minimum set, nothing said")
        #expect(NewJobSheet.belowMinimum(total: 0, settings: settings) == nil, "no price yet is not a price under the minimum")
    }

    @Test("Require inspector asks on the Mac, when there is somebody to ask about")
    func inspectorRule() {
        let on: [String: JSONValue] = ["qc": .object(["enabled": .bool(true), "requireInspector": .bool(true)])]
        let optional: [String: JSONValue] = ["qc": .object(["enabled": .bool(true)])]
        #expect(QcInspector.asks(settings: on, operators: 2))
        #expect(QcInspector.missing(settings: on, operators: 2, chosen: ""))
        #expect(!QcInspector.missing(settings: on, operators: 2, chosen: "OP-1"))
        #expect(!QcInspector.missing(settings: optional, operators: 2, chosen: ""), "asked, not required")
        #expect(!QcInspector.asks(settings: on, operators: 0), "no operators: nobody to name, and nothing blocks")
        #expect(!QcInspector.missing(settings: on, operators: 0, chosen: ""))
        #expect(!QcInspector.asks(settings: ["qc": .object(["enabled": .bool(false), "requireInspector": .bool(true)])], operators: 2))
    }

    @Test("a QC pass carries its inspector onto the job")
    func inspectorOnThePass() async throws {
        let engine = try KhaytEngine()
        let job: JSONValue = .object(["id": .string("J1"), "status": .string("qc"), "project": .string("Vase"),
                                      "price": .number(10), "rev": .number(1)])
        let move = try await engine.moveJob(order: job, to: "completed", orders: [job], settings: [:],
                                            inventory: [], consumables: [], machines: [],
                                            now: Date(), today: "2026-11-10", qcNotes: "fine", qcInspector: "OP-7")
        guard move.ok, case .object(let o)? = move.order else { Issue.record("the move was refused"); return }
        #expect(o["inspector"] == .string("OP-7"))
        #expect(o["qcStatus"] == .string("pass"))
    }

    @Test("a phone that edited from an older copy says so, and the Mac keeps what it replaced")
    func staleBase() {
        let mine: [String: JSONValue] = ["id": .string("J1"), "rev": .number(8), "paidAmount": .number(500)]
        let theirs: [String: JSONValue] = ["id": .string("J1"), "rev": .number(9), "paidAmount": .number(0)]
        let before: [String: JSONValue] = ["printLog": .array([.object(mine)])]
        let after: [String: JSONValue] = ["printLog": .array([.object(theirs)])]
        func payload(_ base: JSONValue?) -> [String: JSONValue] {
            var delta: [String: JSONValue] = ["collection": .string("printLog"), "record": .object(theirs)]
            if let base { delta["baseRev"] = base }
            return ["deltas": .array([.object(delta)])]
        }
        let stale = SyncLosses.staleReplacements(before: before, after: after, payload: payload(.number(7)), already: [])
        #expect(stale.count == 1)
        #expect(stale.first?.record == .object(mine), "the copy with the payment on it is the one kept")
        #expect(SyncLosses.staleReplacements(before: before, after: after, payload: payload(.number(8)), already: []).isEmpty,
                "based on what is here: an ordinary edit")
        #expect(SyncLosses.staleReplacements(before: before, after: after, payload: payload(nil), already: []).isEmpty,
                "an older phone says nothing, and is treated as before")
        #expect(SyncLosses.staleReplacements(before: before, after: before, payload: payload(.number(7)), already: []).isEmpty,
                "skipped by the rule: nothing was replaced")
        #expect(SyncLosses.staleReplacements(before: before, after: after, payload: payload(.number(7)),
                                             already: ["printLog:J1"]).isEmpty, "not kept twice")
    }

    // MARK: - Everyday use (section C)

    @Test("the Stage column sorts by where a job is in the work, not by the stored word")
    func stageOrder() {
        #expect(Stage.quote.rank < Stage.pending.rank)
        #expect(Stage.pending.rank < Stage.printing.rank)
        #expect(Stage.printing.rank < Stage.qc.rank)
        #expect(Stage.qc.rank < Stage.completed.rank)
        #expect(Stage.completed.rank < Stage.cancelled.rank, "alphabetical put cancelled first")
    }

    @Test("Edit Job renames only when the name was changed to something")
    @MainActor func renaming() {
        #expect(EditJobSheet.renamed(from: "Vaze", to: " Vase ") == "Vase")
        #expect(EditJobSheet.renamed(from: "Vase", to: "Vase") == nil)
        #expect(EditJobSheet.renamed(from: "Vase", to: "   ") == nil, "emptied is \"leave it\", never a nameless job")
    }

    @Test("Cancel on New Job asks only when there is work to lose")
    @MainActor func discardGuard() {
        #expect(!NewJobSheet.worthAsking(parts: 0, pending: false))
        #expect(NewJobSheet.worthAsking(parts: 1, pending: false))
        #expect(NewJobSheet.worthAsking(parts: 0, pending: true))
    }

    @Test("letter-spacing is nothing in Arabic, whose letters join")
    func spacing() {
        #expect(Words.spaced(0.6, joined: false) == 0.6)
        #expect(Words.spaced(0.6, joined: true) == 0)
    }
}
