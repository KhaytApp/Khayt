import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// The tier usage rule is ONE rule: what the Electron app computes and what
/// the Mac computes, over the same book, agree — because they are the same
/// function.
///
/// #1706 gave the Mac a Swift copy of "when was this model last used, and does
/// an open job need it" (`CloudLibrary.usage`), and #1716 gave Electron
/// `usageFromBook` in `lib/print-library-tier.js`. Two copies of a rule that
/// decides which models may leave this Mac is the "tested copy vs shipped
/// copy" risk: one gets a fix, the other keeps offering a model an open job
/// needs. The Swift copy is gone; this runs `lib/` under node exactly as
/// `main.js` calls it (with `print-library-location.js`'s `itemDirName`) and
/// through the Mac's engine, and compares.
@MainActor
struct TierUsageParityTests {

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The sample book's library and jobs, plus the cases the rule exists
    /// for: an id that is not a plain folder name, an open job, a cancelled
    /// one, a job naming a model the library does not have, a part with no
    /// model.
    static func book() throws -> (files: [JSONValue], orders: [JSONValue]) {
        let url = try #require(AppResources.bundle.url(forResource: "sample-shop", withExtension: "json"))
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        var files = Shop.rows(root, "printFiles")
        var orders = Shop.rows(root, "printLog")
        files += [
            .object(["id": .string("PF odd/ä✓𝄞"), "createdAt": .string("2025-01-02T03:04:05Z")]),
            .object(["id": .string("PF-printed"), "createdAt": .string("2024-01-01"), "lastPrinted": .string("2026-09-10")]),
        ]
        orders += [
            .object(["id": .string("J-open"), "status": .string("printing"), "date": .string("2023-05-05"),
                     "parts": .array([.object(["printFileId": .string("PF odd/ä✓𝄞")]), .object(["name": .string("x")])])]),
            .object(["id": .string("J-x"), "status": .string("cancelled"), "date": .string("2026-09-20"),
                     "completedAt": .string("2026-09-21T10:00:00Z"),
                     "parts": .array([.object(["printFileId": .string("PF-printed")])])]),
            .object(["id": .string("J-ghost"), "status": .string("pending"), "date": .string("2026-01-01"),
                     "parts": .array([.object(["printFileId": .string("PF-not-in-library")])])]),
        ]
        return (files, orders)
    }

    @Test("the Mac's tier usage is the module's, as Electron calls it")
    func sameAsElectron() async throws {
        let (files, orders) = try Self.book()
        let engine = try KhaytEngine()
        let mac = try await engine.tierUsage(printFiles: files, orders: orders,
                                             dirNames: CloudLibrary.dirNames(printFiles: files, orders: orders))
        #expect(mac[LibraryLocation.itemDirName("PF odd/ä✓𝄞")]?.inUse == true)
        #expect(mac["PF-not-in-library"]?.inUse == true)
        #expect(mac["PF-printed"]?.inUse == false)
        #expect(mac.count > 5, "the sample book reached nothing")

        // Electron's answer: main.js's call, over the same rows.
        let script = """
        const T=require(process.argv[1]+"/lib/print-library-tier.js"),L=require(process.argv[1]+"/lib/print-library-location.js");
        const b=JSON.parse(require("fs").readFileSync(0,"utf8"));
        process.stdout.write(JSON.stringify(T.usageFromBook({printFiles:b.files,orders:b.orders,itemDirName:L.itemDirName})));
        """
        let node = Process()
        node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        node.arguments = ["node", "-e", script, "--", Self.repo.path]
        let input = Pipe(), output = Pipe()
        node.standardInput = input
        node.standardOutput = output
        node.standardError = FileHandle.nullDevice
        try node.run()
        input.fileHandleForWriting.write(try JSONEncoder().encode(
            JSONValue.object(["files": .array(files), "orders": .array(orders)])))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        node.waitUntilExit()
        // No node on this machine (127 from env): nothing to compare against.
        guard node.terminationStatus != 127 else { return }
        #expect(node.terminationStatus == 0)
        let electron = try JSONDecoder().decode([String: KhaytEngine.TierUsage].self, from: data)
        #expect(electron == mac, Comment(rawValue: "keys only in one: \(Set(electron.keys).symmetricDifference(mac.keys))"))
    }

    @Test("annotate folds the usage into the listing, newest date winning, and leaves an unknown file alone")
    func annotateIsTheModules() async throws {
        let engine = try KhaytEngine()
        let files: [JSONValue] = [.object(["id": .string("PF-a"), "createdAt": .string("2026-09-01")])]
        let orders: [JSONValue] = [.object(["status": .string("pending"), "date": .string("2026-01-01"),
                                            "parts": .array([.object(["printFileId": .string("PF-a")])])])]
        let listed: [KhaytEngine.TierFile] = [
            .init(filename: "a.3mf", fullPath: "/l/PF-a/a.3mf", size: 1, mtimeMs: 5, id: "PF-a",
                  lastUsedMs: 9_999_999_999_999),
            .init(filename: "b.3mf", fullPath: "/l/PF-b/b.3mf", size: 1, mtimeMs: 5, id: "PF-b"),
        ]
        let out = try await CloudLibrary.annotated(listed, engine: engine, printFiles: files, orders: orders)
        #expect(out[0].inUse == true)
        #expect(out[0].lastUsedMs == 9_999_999_999_999, "the newer of the listing's and the book's lost")
        #expect(out[1] == listed[1])
    }

    @Test("the Swift copy of the rule is gone, and the shop plans through the engine")
    func noSwiftCopy() throws {
        let src = try String(contentsOf: Self.repo.appending(path: "mac/KhaytCore/Sources/KhaytApp/CloudLibrary.swift"),
                             encoding: .utf8)
        #expect(!src.contains("static func usage("))
        #expect(!src.contains("doneStatuses"))
        #expect(src.contains("CloudLibrary.annotated(listed, engine: engine,"))
    }
}
