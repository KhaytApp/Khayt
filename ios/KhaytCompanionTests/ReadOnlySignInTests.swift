import XCTest
@testable import KhaytCompanion
import KhaytCore

/// A viewer's cloud sign-in with no Mac paired edits nothing: the cloud takes
/// no writes from a viewer, so an edit kept on the phone was lost at the next
/// pull while the screen said it was done.
final class ReadOnlySignInTests: XCTestCase {

    override func tearDown() { CompanionBook.editsRefused = nil }

    func testOnlyAViewerWithNoMacIsReadOnly() {
        XCTAssertFalse(KhaytAPIClient.mayEdit(cloudRole: "viewer", macPaired: false, sample: false))
        XCTAssertTrue(KhaytAPIClient.mayEdit(cloudRole: "viewer", macPaired: true, sample: false),
                      "a paired Mac takes the phone's edits whatever the cloud role")
        XCTAssertTrue(KhaytAPIClient.mayEdit(cloudRole: "owner", macPaired: false, sample: false))
        XCTAssertTrue(KhaytAPIClient.mayEdit(cloudRole: "staff", macPaired: false, sample: false))
        XCTAssertTrue(KhaytAPIClient.mayEdit(cloudRole: nil, macPaired: false, sample: false))
        XCTAssertTrue(KhaytAPIClient.mayEdit(cloudRole: "viewer", macPaired: false, sample: true))
    }

    func testTheBookRefusesEveryEditWhileReadOnlyAndSaysWhy() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = CompanionBook(directory: dir)
        try book.replace(with: ["inventory": .array([])], scope: nil)

        CompanionBook.editsRefused = L10n.tr("cloud.read_only.refused")
        let spool: [String: JSONValue] = ["id": .string("s1"), "material": .string("PLA")]
        XCTAssertThrowsError(try book.appendRecord(collection: "inventory", record: spool)) { error in
            XCTAssertEqual(error.localizedDescription, L10n.tr("cloud.read_only.refused"))
        }
        XCTAssertThrowsError(try book.update { $0["x"] = .string("y") })
        XCTAssertThrowsError(try book.insertRecord(collection: "inventory", atFront: true) { _ in spool })
        XCTAssertThrowsError(try book.updateRecord(collection: "inventory", id: "s1") { $0["material"] = .string("PETG") })
        guard case .array(let rows)? = try book.read()["inventory"] else { return XCTFail() }
        XCTAssertTrue(rows.isEmpty, "nothing was kept to be lost later")

        // A pull is not an edit.
        XCTAssertNoThrow(try book.replace(with: ["inventory": .array([.object(spool)])], scope: nil))

        CompanionBook.editsRefused = nil
        XCTAssertNoThrow(try book.appendRecord(collection: "inventory",
                                              record: ["id": .string("s2"), "material": .string("PLA")]))
    }
}
