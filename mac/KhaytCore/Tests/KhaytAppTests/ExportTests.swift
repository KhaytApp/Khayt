import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The copy of the book that leaves this Mac.
///
/// A backup stays here and carries the shop's credentials, which is what makes
/// restoring one put a working shop back. An export goes to an accountant, a
/// spreadsheet, a support thread — and a credential in it is a credential in
/// somebody's Downloads folder forever. There is one way to build one, and it
/// redacts.
@MainActor
struct ExportTests {

    /// A store as this app finds one: secrets already `__enc__`, and carrying
    /// the printer completion history the main process owns.
    static let book: [String: JSONValue] = {
        let json = """
        {"version":10,
         "printLog":[{"id":"P-1"}],
         "clients":[{"id":"C-1","nameEn":"Aisha"}],
         "machines":[{"id":"M-1","printerApi":{"apiKey":"__enc__REAL","accessCode":"__enc__CODE","host":"10.0.0.4"}}],
         "settings":{"bizEn":"The Shop",
                     "telegram":{"botToken":"__enc__TOKEN","chatId":"@theshop"},
                     "cloud":{"token":"__enc__CLOUD"},
                     "newIntegration":{"apiKey":"__enc__FUTURE"},
                     "shipping":{"defaultCarrier":"aramex",
                                 "aramex":{"accountNumber":"123","apiKey":"__enc__ARAMEX"},
                                 "brandNew":{"secret":"__enc__NEWONE"}}},
         "printerCompletions":{"PRN-1":{"completions":[{"at":1}]}}}
        """
        return try! JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }()

    static func exported() async throws -> [String: JSONValue] {
        let data = try await Export.payload(from: book, engine: try KhaytEngine())
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    @Test("no credential leaves, in any form")
    func nothingLeaks() async throws {
        let out = try await Self.exported()
        let text = String(decoding: try JSONEncoder().encode(out), as: UTF8.self)
        #expect(!text.contains("__enc__"),
                "a value left as ciphertext — better than plaintext, and still not a file to hand over")
        #expect(!text.contains("REAL") && !text.contains("TOKEN") && !text.contains("CLOUD"))
        // `settings.newIntegration.apiKey` is in NO list — it is the setting
        // somebody adds next. The redaction cannot know about it; the backstop
        // does not have to, because it knows the shape of a secret at rest.
        #expect(Restore.value(at: ["settings", "newIntegration", "apiKey"], in: out)
                == .string(Restore.secretMask))
    }

    @Test("the named credentials are masked, not deleted")
    func masksRatherThanDrops() async throws {
        // A field that vanishes reads as a shop that never configured it. The
        // mask says "there is one, and you are not getting it".
        let out = try await Self.exported()
        #expect(Restore.value(at: ["settings", "telegram", "botToken"], in: out) == .string(Restore.secretMask))
        #expect(Restore.value(at: ["settings", "cloud", "token"], in: out) == .string(Restore.secretMask))
        guard case .array(let machines)? = out["machines"], case .object(let m) = machines[0] else {
            Issue.record("machines missing"); return
        }
        #expect(Restore.value(at: ["printerApi", "apiKey"], in: m) == .string(Restore.secretMask))
        #expect(Restore.value(at: ["printerApi", "accessCode"], in: m) == .string(Restore.secretMask))
    }

    @Test("a carrier nobody has heard of has its key taken too")
    func dataDrivenCarriers() async throws {
        // The reason the redaction is not a hand-kept list of provider ids:
        // adding a carrier would otherwise export the next one's credentials in
        // the clear, and nobody would know until it was in a support thread.
        let out = try await Self.exported()
        #expect(Restore.value(at: ["settings", "shipping", "brandNew", "secret"], in: out)
                == .string(Restore.secretMask))
    }

    @Test("everything that is not a credential is still there")
    func keepsTheBook() async throws {
        let out = try await Self.exported()
        #expect(Restore.value(at: ["settings", "bizEn"], in: out) == .string("The Shop"))
        #expect(Restore.value(at: ["settings", "telegram", "chatId"], in: out) == .string("@theshop"))
        #expect(Restore.value(at: ["settings", "shipping", "aramex", "accountNumber"], in: out) == .string("123"))
        guard case .array(let machines)? = out["machines"], case .object(let m) = machines[0] else {
            Issue.record("machines missing"); return
        }
        #expect(Restore.value(at: ["printerApi", "host"], in: m) == .string("10.0.0.4"))
        guard case .array(let clients)? = out["clients"] else { Issue.record("clients missing"); return }
        #expect(clients.count == 1)
    }

    @Test("the printer poll's own history does not go with it")
    func dropsMainOwnedKeys() async throws {
        // Khayt's export does not contain it — the renderer never sees it — so
        // an export from here that did would not be the same document. It is
        // this machine's working history, not the shop's book.
        let out = try await Self.exported()
        #expect(out["printerCompletions"] == nil)
    }

    @Test("it says when it was made, and which schema it is")
    func carriesItsOwnMetadata() async throws {
        let out = try await Self.exported()
        #expect(out["version"] == .number(10))
        if case .string(let at)? = out["exportedAt"] { #expect(at.hasSuffix("Z")) }
        else { Issue.record("an export with no date on it") }
    }

    @Test("the file is called what Khayt calls it")
    func naming() {
        let day = Date(timeIntervalSince1970: 1_756_944_000)
        #expect(Export.filename(day) == "khayt-" + Shop.today(day) + ".json")
    }

    @Test("the backstop masks ciphertext wherever it is, however deep")
    func backstopIsThorough() {
        let nested: JSONValue = .object([
            "a": .array([.object(["k": .string("__enc__X")]), .string("__enc__Y")]),
            "b": .string("plain"),
            "c": .number(3),
        ])
        let out = Export.masked(nested)
        let text = String(decoding: try! JSONEncoder().encode(out), as: UTF8.self)
        #expect(!text.contains("__enc__"))
        #expect(text.contains("plain"))
    }
}
