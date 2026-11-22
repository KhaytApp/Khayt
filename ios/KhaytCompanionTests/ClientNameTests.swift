import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * A client list that read CLI-8A5045 down the page.
 *
 * Which of a customer's names a reader sees is `lib/content-languages.js`'s
 * decision, made against the shop's own content languages — a shop that keeps
 * its books in Turkish has Turkish customers, and an English interface does not
 * turn them into a stale `nameEn` left over from setup.
 *
 * `/api/clients` applies that rule before it sends a name, and — where a shop
 * writes neither `nameEn` nor `nameAr` — copies the resolved name into `nameEn`
 * so that even a companion which only knows those two keys shows something.
 *
 * Reading the book gets none of that. The record holds `nameTr`, this app knew
 * two keys, and `displayName` fell through to the customer's id.
 */
final class ClientNameTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "names-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAShopThatWritesInTurkishKeepsItsCustomersNames() async throws {
        // A shop whose content language is Turkish. Its clients have `nameTr`
        // and nothing this app used to know how to read.
        try book.replace(with: [
            "settings": .object(["shopName": .string("Atölye"),
                                 "contentLangs": .array([.string("tr")]),
                                 "lang": .string("tr")]),
            "clients": .array([
                // The store's key for a non-en/ar language is `name_tr`, not `nameTr`:
                // `fieldKey` special-cases English and Arabic to the camelCase
                // spellings this app already knew, and uses `name_<lang>` for the rest.
                .object(["id": .string("CLI-8A5045"), "name_tr": .string("Mehmet Yılmaz")]),
            ]),
        ], scope: nil)

        let clients = try await reader.clients()
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients[0].displayName, "Mehmet Yılmaz", """
            the client list is showing the customer's id instead of their name.
            The shop writes in Turkish; the resolution is content-languages' job
            and the book does not come with it done.
            """)
        XCTAssertNotEqual(clients[0].displayName, "CLI-8A5045")
    }

    func testAnArabicShopIsUnaffected() async throws {
        try book.replace(with: [
            "settings": .object(["contentLangs": .array([.string("ar")]), "lang": .string("ar")]),
            "clients": .array([
                .object(["id": .string("C-1"), "nameAr": .string("مختبر النماذج"),
                         "nameEn": .string("Prototyping Lab")]),
            ]),
        ], scope: nil)

        let clients = try await reader.clients()
        // Whichever it picks, it is a name and not an id — the point is that the
        // shop's own languages decide, not this app.
        XCTAssertTrue(["مختبر النماذج", "Prototyping Lab"].contains(clients[0].displayName),
                      "got \(clients[0].displayName)")
    }

    func testAClientWithNoNameAtAllStillShowsSomething() async throws {
        try book.replace(with: [
            "settings": .object([:]),
            "clients": .array([.object(["id": .string("C-9")])]),
        ], scope: nil)

        let clients = try await reader.clients()
        // The id is the right answer HERE: there is no name to show, and a blank
        // row is worse than an identifier somebody can look up.
        XCTAssertEqual(clients[0].displayName, "C-9")
    }

    func testTheWiresResolvedNameIsPreferred() throws {
        // What `/api/clients` sends. The app used to ignore `name` entirely.
        let json = #"{"id":"C-1","name":"Mehmet Yılmaz","nameEn":"","nameAr":null}"#
        let client = try JSONDecoder().decode(Client.self, from: Data(json.utf8))
        XCTAssertEqual(client.displayName, "Mehmet Yılmaz")
    }

    func testTheShopsRealClientsAreUnchanged() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "mac/KhaytCore/Sources/KhaytApp/Resources/sample-shop.json")
        let shop = try JSONDecoder().decode([String: JSONValue].self, from: try Data(contentsOf: url))
        try book.replace(with: shop, scope: nil)

        let clients = try await reader.clients()
        XCTAssertEqual(clients.count, 31)
        for client in clients {
            XCTAssertNotEqual(client.displayName, client.id,
                              "client \(client.id) is being shown as its own id")
        }
    }
}
