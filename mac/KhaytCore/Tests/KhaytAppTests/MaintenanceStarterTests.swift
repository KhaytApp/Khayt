import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The new-task sheet offers the shared starter list (lib/maintenance.js), and
/// every task in it has a name in all nine languages.
struct MaintenanceStarterTests {
    @Test("the Mac reads the shared starter list, by machine kind")
    func readsTheSharedList() async throws {
        let engine = try KhaytEngine()
        let fdm = try await engine.maintenanceStarters(kind: "fdm").map(\.id)
        let resin = try await engine.maintenanceStarters(kind: "resin").map(\.id)
        #expect(fdm.contains("nozzle") && !fdm.contains("fep"))
        #expect(resin.contains("fep") && !resin.contains("nozzle"))
        #expect(try await engine.maintenanceStarters(kind: "laser").isEmpty)
    }

    @Test("every starter task has a Mac name")
    @MainActor func everyStarterIsNamed() async throws {
        let engine = try KhaytEngine()
        let all = Set(try await engine.maintenanceStarters(kind: "fdm").map(\.id)
                      + engine.maintenanceStarters(kind: "resin").map(\.id))
        for id in all {
            #expect(Words.own["mac.mt_t_" + id] != nil, "mac.mt_t_\(id) has no words")
        }
    }
}
