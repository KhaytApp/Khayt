import Foundation
import Testing
@testable import KhaytApp
@testable import KhaytCore

/// What Khayt says when the system asks it a question.
///
/// These sentences are spoken by Siri, shown in Spotlight and read by an
/// automation nobody is watching. They are the one part of the app whose output
/// a person may never see on a screen, so they are the part most worth pinning.
@MainActor
struct AskTests {

    static func book(_ json: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }

    static let shop = """
    {"machines":[{"id":"M-1","name":"Bambu X1C"},{"id":"M-2","name":"Snapmaker U1"}],
     "printLog":[
       {"id":"O-1","status":"printing","project":"Falcon hood","machineId":"M-1"},
       {"id":"O-2","status":"printing","project":"Ramadan lantern","machineId":"M-2"},
       {"id":"O-3","status":"pending","project":"Oud bridge jig","machineId":"M-2"},
       {"id":"O-4","status":"pending","project":"Souq stall sign"},
       {"id":"O-5","status":"queued","project":"Dental model set","machineId":null},
       {"id":"O-6","status":"delivered","project":"Shelf brackets"},
       {"id":"O-7","status":"quote","project":"Turbine bracket"}]}
    """

    @Test("it names the job and the printer it is on")
    func printing() throws {
        let said = Ask.printing(in: try Self.book(Self.shop), words: Words())
        #expect(said.contains("2 printing"))
        #expect(said.contains("Falcon hood"))
        #expect(said.contains("Bambu X1C"))
        #expect(said.contains("Ramadan lantern"))
        #expect(said.contains("Snapmaker U1"))
        // Not the delivered one, and not the quote.
        #expect(!said.contains("Shelf brackets"))
        #expect(!said.contains("Turbine bracket"))
    }

    @Test("a job whose printer is gone still gets named")
    func orphaned() throws {
        let said = Ask.printing(in: try Self.book("""
        {"machines":[],"printLog":[{"id":"O-1","status":"printing","project":"Falcon hood",
          "machineId":"M-DELETED"}]}
        """), words: Words())
        // The machine was removed from the book; the job did not stop existing.
        #expect(said.contains("Falcon hood"))
        #expect(said.contains("1 printing"))
    }

    @Test("nothing printing says so rather than saying nothing")
    func quiet() throws {
        let said = Ask.printing(in: try Self.book("""
        {"machines":[{"id":"M-1","name":"X1C"}],
         "printLog":[{"id":"O-1","status":"delivered","project":"Done"}]}
        """), words: Words())
        #expect(said == Words().callIt("mac.nothing_printing"))
        #expect(!said.isEmpty)
    }

    @Test("waiting work counts queued as well, and says how much has no printer")
    func waiting() throws {
        let said = Ask.waiting(in: try Self.book(Self.shop), words: Words())
        // O-3 (pending), O-4 (pending, no machine), O-5 (queued, machineId null)
        #expect(said.contains("3 waiting"))
        // O-4 has no machineId at all; O-5's is null. Both count.
        #expect(said.contains("2"))
    }

    @Test("an empty queue is a sentence, not a blank")
    func nothingWaiting() throws {
        let said = Ask.waiting(in: try Self.book("""
        {"printLog":[{"id":"O-1","status":"printing","project":"On it"}]}
        """), words: Words())
        #expect(said == Words().callIt("mac.nothing_waiting"))
    }

    /// A book that is not there, or is nonsense, must not throw at Siri.
    @Test("a missing or empty book answers instead of failing")
    func noBook() throws {
        #expect(Ask.printing(in: [:], words: Words()) == Words().callIt("mac.nothing_printing"))
        #expect(Ask.waiting(in: [:], words: Words()) == Words().callIt("mac.nothing_waiting"))
        #expect(Ask.rows([:], "printLog").isEmpty)
    }
}
