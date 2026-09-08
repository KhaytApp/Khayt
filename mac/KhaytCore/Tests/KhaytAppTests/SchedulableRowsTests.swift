import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// Which jobs a scheduler is allowed to place.
@MainActor
struct SchedulableRowsTests {

    static func rows(_ json: String) throws -> [JSONValue] {
        guard case .array(let r) = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        else { throw KhaytJSError.evaluationFailed("not an array") }
        return r
    }

    /// What is handed to the scheduler seeds each machine's load, so a
    /// finished job in that set books a printer that is standing free.
    @Test("only unfinished work is handed to the scheduler")
    func whatItIsGiven() throws {
        let book = try Self.rows("""
        [{"id":"A","status":"pending","machineId":null},
         {"id":"B","status":"printing","machineId":"MACH-1"},
         {"id":"C","status":"queued","machineId":null},
         {"id":"D","status":"completed","machineId":"MACH-1"},
         {"id":"E","status":"delivered","machineId":"MACH-1"},
         {"id":"F","status":"quote","machineId":null},
         {"id":"G","status":"cancelled","machineId":"MACH-1"}]
        """)
        let given = Shop.stillToHappen(book).compactMap { row -> String? in
            guard case .object(let o) = row else { return nil }
            return Shop.plainString(o["id"])
        }
        // The printing job is in: it is what makes MACH-1 busy. The completed,
        // delivered and cancelled ones are out, or a printer that has done a
        // hundred jobs would read as booked for a month.
        #expect(given == ["A", "B", "C"])
    }

    @Test("waiting work with no printer is schedulable, however the book spells it")
    func theFilter() throws {
        let book = try Self.rows("""
        [{"id":"A","status":"pending","machineId":null},
         {"id":"B","status":"pending"},
         {"id":"C","status":"pending","machineId":""},
         {"id":"D","status":"queued","machineId":null},
         {"id":"E","status":"pending","machineId":"MACH-1"},
         {"id":"F","status":"printing","machineId":null},
         {"id":"G","status":"quote","machineId":null},
         {"id":"H","status":"delivered"}]
        """)
        let picked = Shop.schedulable(book).compactMap { row -> String? in
            guard case .object(let o) = row else { return nil }
            return Shop.plainString(o["id"])
        }
        // A: explicit null. B: absent. C: empty string. D: queued counts too.
        #expect(picked == ["A", "B", "C", "D"])
    }
}
