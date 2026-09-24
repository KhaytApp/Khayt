import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's Q3 margin read −495.8%: nineteen test prints charged nothing,
/// and the Mac had no way to say they were not business.
@MainActor
struct NonBusinessTests {

    static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
    }

    @Test("the shared setter marks a job and takes the mark away, as the other app writes it")
    func setter() async throws {
        let engine = try KhaytEngine()
        let job: JSONValue = .object(["id": .string("j1"), "price": .number(0)])
        let marked = try await engine.setNonBusiness(job, on: true)
        guard case .object(let m) = marked else { Issue.record("not an object"); return }
        #expect(m["nonBusiness"] == .bool(true))
        let unmarked = try await engine.setNonBusiness(marked, on: false)
        guard case .object(let u) = unmarked else { Issue.record("not an object"); return }
        #expect(u["nonBusiness"] == nil, "cleared by removing the field, not by writing false")
    }

    @Test("a job can be marked from its right-click menu and from Edit job")
    func reachable() throws {
        #expect(try Self.source("OrdersTable.swift").contains("await shop.setNonBusiness(job.id, on)"))
        #expect(try Self.source("EditJobSheet.swift").contains("await shop.setNonBusiness(id, nowNonBusiness)"))
        #expect(try Self.source("Reports.swift").contains("mac.pnl_unpriced"),
                "the P&L no longer says why a margin is negative")
    }
}
