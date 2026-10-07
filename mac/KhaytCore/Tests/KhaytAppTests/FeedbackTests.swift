import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// Help ▸ Send Feedback…: what it attaches, and what it must never attach.
///
/// A report is a file a tester emails to a stranger. So the checks are built
/// out of the sample book's own customers, phones and prices and ask that
/// none of them reaches the diagnostics — and out of every path in
/// `lib/store-secret-paths.js`, planted with a value, and ask that each one
/// comes out of the book attachment as the mask.
@Suite @MainActor struct FeedbackTests {

    static let mask = JSONValue.string("__KHAYT_MASKED__")

    func sample() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    @Test("the subject carries the version and the build")
    func subjectCarriesVersionAndBuild() {
        let subject = Feedback.subject(version: "4.0.0-alpha.55", build: "55")
        #expect(subject == "Khayt for Mac feedback — 4.0.0-alpha.55 (55)")
    }

    @Test("the diagnostics carry counts and switches, never a customer, a price or a token")
    func diagnosticsCarryNothingPrivate() async throws {
        let shop = await sample()
        let root = try Feedback.storedBook(shop)

        // What must not appear: every customer's names, phone and email; every
        // job's customer, project, tracking token and a price with pennies.
        var forbidden: Set<String> = []
        func text(_ row: JSONValue, _ key: String) -> String? {
            if case .object(let o) = row, case .string(let s)? = o[key], s.count >= 3 { return s }
            return nil
        }
        if case .array(let clients)? = root["clients"] {
            for c in clients { for k in ["nameEn", "nameAr", "name", "phone", "email"] {
                if let s = text(c, k) { forbidden.insert(s) } } }
        }
        if case .array(let jobs)? = root["printLog"] {
            for j in jobs {
                for k in ["client", "project", "trackingToken", "phone", "email"] {
                    if let s = text(j, k) { forbidden.insert(s) }
                }
                if case .object(let o) = j, case .number(let price)? = o["price"],
                   price != price.rounded() {
                    forbidden.insert(String(price))
                }
            }
        }
        #expect(forbidden.count > 20, "the sample book has no customers to look for")

        // A rule that fails with a customer's name and a token in its script —
        // the case that could carry them into the file.
        let name = try #require(shop.clients.first?.nameEn)
        let runtime = try JSRuntime(modules: [])
        _ = try? runtime.evaluate(
            "KhaytPretendFeedback.fail({\"client\":\"\(name)\",\"token\":\"tok_live_9f8e7d6c\"})")
        forbidden.insert("tok_live_9f8e7d6c")

        let written = Feedback.diagnostics(Feedback.facts(for: shop, windowSize: CGSize(width: 1280, height: 800)))
        for secret in forbidden {
            #expect(!written.contains(secret), "diagnostics.txt carries \(secret)")
        }
        #expect(written.contains("KhaytPretendFeedback.fail"), "the failed rule is not named")
        #expect(written.contains("jobs: \(shop.orders.count)"))
        #expect(written.contains("customers: \(shop.clients.count)"))
        #expect(written.contains("machines: \(shop.machines.count)"))
        #expect(written.contains("spools: \(shop.spools.count)"))
        #expect(written.contains("library files: \(shop.files.count)"))
        #expect(written.contains("window: 1280 × 800"))
        for line in ["cloud sync: ", "Google Drive: ", "LAN server: "] {
            #expect(written.contains(line + "on") || written.contains(line + "off"))
        }
    }

    @Test("a fault's message keeps its kind and nothing of what followed")
    func messagesAreScrubbed() {
        // Quoted data, as JavaScriptCore quotes the expression it evaluated.
        #expect(Feedback.scrubbed(
            "TypeError: undefined is not an object (evaluating 'K.f({\"client\":\"Najd\"}).x')") == "TypeError")
        // UNQUOTED data, as a lib rule's own `throw new Error(`…${name}`)`
        // puts it — what stripping quotes alone let through.
        let said = Feedback.scrubbed("Error: no price for Najd Printing Co, phone 0551234567, total 1234.50")
        #expect(said == "Error")
        for leak in ["Najd", "0551234567", "1234.50"] { #expect(!said.contains(leak)) }
        #expect(Feedback.scrubbed("RangeError: Maximum call stack size exceeded.") == "RangeError")
        // No kind to keep: the whole message is free-form, so none of it goes.
        #expect(Feedback.scrubbed("Najd Printing Co owes 1234.50") == Feedback.withheld)
        #expect(Feedback.scrubbed("order for Najd: no price") == Feedback.withheld)
        #expect(Feedback.scrubbed("") == Feedback.withheld)
    }

    @Test("old report folders are swept from the temporary directory, new ones and others are not")
    func oldDraftsAreSwept() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "feedback-sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        func folder(_ name: String, age: TimeInterval) throws -> URL {
            let url = tmp.appending(path: name, directoryHint: .isDirectory)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url.appending(path: "book.json"))
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let old = try folder("Khayt-feedback-2026-09-01-101010", age: 3 * 86_400)
        let fresh = try folder("Khayt-feedback-2026-10-01-101010", age: 60)
        let other = try folder("Someone-else-2026-09-01", age: 3 * 86_400)
        let file = tmp.appending(path: "Khayt-feedback-2026-09-01.zip")
        try Data([1]).write(to: file)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: file.path)

        Feedback.sweepOldDrafts(in: tmp)
        #expect(!fm.fileExists(atPath: old.path), "a three-day-old report is still there")
        #expect(fm.fileExists(atPath: fresh.path), "a report the mail app may still be reading was removed")
        #expect(fm.fileExists(atPath: other.path), "another app's folder was removed")
        #expect(fm.fileExists(atPath: file.path), "a file, not a report folder, was removed")
    }

    @Test("the book attachment masks every path in store-secret-paths")
    func bookIsMasked() async throws {
        let shop = await sample()
        let engine = try #require(shop.engine)
        var root = try Feedback.storedBook(shop)
        let paths = try await engine.secretPaths()
        #expect(paths.count > 30, "the secret list did not load")

        // A distinct value at every path, and one sealed value at a path no
        // list names — the backstop for a secret nobody registered.
        var planted: [String] = []
        for (index, path) in paths.enumerated() {
            let value = "planted-secret-\(index)-x7"
            planted.append(value)
            Self.plant(&root, path: path, value: .string(value))
        }
        Self.plant(&root, path: "settings.someoneForgot.key", value: .string("__enc__c2VhbGVk"))
        planted.append("__enc__c2VhbGVk")

        // What the cloud mask KEEPS and a stranger must not get: every
        // order's capabilities (the portal link, approving a quote, answering
        // a survey), the LAN API token hashes, a secret-bearing event webhook
        // URL and the wrapped cloud data key.
        guard case .array(let jobs)? = root["printLog"] else {
            Issue.record("the sample book has no jobs"); return
        }
        #expect(jobs.count > 3)
        root["printLog"] = .array(jobs.enumerated().map { index, job in
            guard case .object(var o) = job else { return job }
            o["trackingToken"] = .string("planted-tracking-\(index)-q9")
            o["quoteApprovalToken"] = .string("planted-approval-\(index)-q9")
            o["surveyToken"] = .string("planted-survey-\(index)-q9")
            return .object(o)
        })
        for index in jobs.indices {
            planted += ["planted-tracking-\(index)-q9", "planted-approval-\(index)-q9", "planted-survey-\(index)-q9"]
        }
        Self.plant(&root, path: "settings.lanApi.apiTokens", value: .array([
            .object(["id": .string("tok1"), "label": .string("Zapier"),
                     "hash": .string("planted-api-hash-5b1e"), "scopes": .array([.string("orders:read")])]),
        ]))
        Self.plant(&root, path: "settings.eventWebhooks.url",
                   value: .string("https://hooks.slack.com/services/T000/B000/planted-hook-path-7c"))
        Self.plant(&root, path: "settings.cloud.keyset",
                   value: .object(["wrapped": .string("planted-keyset-wrapped-3d"), "salt": .string("planted-keyset-salt-3d")]))
        planted += ["planted-api-hash-5b1e", "planted-hook-path-7c",
                    "planted-keyset-wrapped-3d", "planted-keyset-salt-3d"]
        // The staff PIN and the recovery code, hashed: a four-digit PIN behind
        // a hash is a lookup for whoever holds the file (PHONE_PRIVATE).
        root["operators"] = .array([.object([
            "id": .string("OP-1"), "name": .string("Noura"), "pinHash": .string("planted-pin-hash-8e"),
        ])])
        Self.plant(&root, path: "settings.recoveryCodeHash", value: .string("planted-recovery-hash-8e"))
        planted += ["planted-pin-hash-8e", "planted-recovery-hash-8e"]

        let data = try #require(await Feedback.maskedBook(root, engine: engine))
        let bytes = try #require(String(data: data, encoding: .utf8))
        for value in planted {
            #expect(!bytes.contains(value), "book.json carries \(value)")
        }
        let back = try JSONDecoder().decode([String: JSONValue].self, from: data)
        for path in paths {
            for found in Self.values(back, path: path) {
                #expect(found == Self.mask, "\(path) is not masked in book.json")
            }
            #expect(!Self.values(back, path: path).isEmpty, "\(path) went missing rather than masked")
        }
        // Gone, not masked: a mask would be adopted AS the token.
        for key in ["trackingToken", "quoteApprovalToken", "surveyToken"] {
            #expect(!bytes.contains("\"\(key)\""), "book.json still has \(key)")
        }
        // Device-private since #1678, so the cloud mask takes it.
        #expect(Self.values(back, path: "settings.eventWebhooks.url") == [Self.mask])
        #expect(Self.values(back, path: "settings.cloud.keyset").isEmpty)
        guard case .array(let tokens)? = Self.values(back, path: "settings.lanApi.apiTokens").first,
              case .object(let token)? = tokens.first else {
            Issue.record("the API token went missing"); return
        }
        #expect(token["hash"] == Self.mask)
        // The token's label survives, so a report can still say which one.
        #expect(bytes.contains("Zapier"))

        // Still the book: its customers are in it — that is why it is opt-in.
        let name = try #require(shop.clients.first?.nameEn)
        #expect(bytes.contains(name))
    }

    @Test("with no engine to mask with, no book is attached")
    func noEngineNoBook() async {
        #expect(await Feedback.maskedBook(["settings": .object([:])], engine: nil) == nil)
    }

    @Test("the fallback zip holds the message and every attachment")
    func fallbackZip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "feedback-zip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let parts = Feedback.Parts(message: "It froze on the board.", diagnostics: "version: x\n",
                                   screenshot: Data([0x89, 0x50]), book: Data("{}".utf8))
        let url = try Feedback.writeZip(parts, into: folder)
        let zip = try Data(contentsOf: url)
        let latin = String(decoding: zip, as: UTF8.self)
        for name in ["what-happened.txt", "diagnostics.txt", "window.png", "book.json"] {
            #expect(latin.contains(name), "the zip has no \(name)")
        }
        #expect(url.lastPathComponent.hasPrefix("Khayt-feedback-") && url.pathExtension == "zip")
    }

    @Test("the sheet renders, with its words")
    func photograph() async throws {
        let shop = await sample()
        // As it is in the app: a picture of the window was taken on the way in.
        shop.feedbackCapture = Feedback.Capture(png: Data([0x89]), size: CGSize(width: 1280, height: 800))
        let renderer = SnapshotTests()
        let size = CGSize(width: SheetMetrics.outerWidth(FeedbackSheet.width), height: 500)
        try renderer.render(FeedbackSheet(shop: shop), "90-feedback", size: size)
        try renderer.renderDark(FeedbackSheet(shop: shop), "90-feedback-dark", size: size)
    }

    // MARK: - Paths

    /// `a.b.c` or `list[].b.c`, the grammar of `store-secret-paths.js`.
    static func plant(_ root: inout [String: JSONValue], path: String, value: JSONValue) {
        if path.contains("[].") {
            let halves = path.components(separatedBy: "[].")
            guard case .array(var rows)? = root[halves[0]] else { return }
            rows = rows.map { row in
                guard case .object(var o) = row else { return row }
                set(&o, halves[1].split(separator: ".").map(String.init)[...], value)
                return .object(o)
            }
            root[halves[0]] = .array(rows)
        } else {
            set(&root, path.split(separator: ".").map(String.init)[...], value)
        }
    }

    static func set(_ object: inout [String: JSONValue], _ keys: ArraySlice<String>, _ value: JSONValue) {
        guard let head = keys.first else { return }
        if keys.count == 1 { object[head] = value; return }
        var child: [String: JSONValue] = [:]
        if case .object(let existing)? = object[head] { child = existing }
        set(&child, keys.dropFirst(), value)
        object[head] = .object(child)
    }

    static func values(_ root: [String: JSONValue], path: String) -> [JSONValue] {
        func walk(_ node: JSONValue?, _ keys: ArraySlice<String>) -> JSONValue? {
            guard let head = keys.first else { return node }
            guard case .object(let o)? = node else { return nil }
            return walk(o[head], keys.dropFirst())
        }
        if path.contains("[].") {
            let halves = path.components(separatedBy: "[].")
            guard case .array(let rows)? = root[halves[0]] else { return [] }
            return rows.compactMap { walk($0, halves[1].split(separator: ".").map(String.init)[...]) }
        }
        return [walk(.object(root), path.split(separator: ".").map(String.init)[...])].compactMap { $0 }
    }
}
