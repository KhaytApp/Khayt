import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Three small edges found by the October 2026 correctness scan: the model a
/// folder answers with, a folder move that would outgrow the 60-character path,
/// and a parcel that left without telling the shop's webhooks.
@MainActor
struct LibraryAndShippingEdgesTests {

    @Test("a folder's sole model is a model, never the pack's PDF")
    func soleModelIsAModel() {
        let dir = URL(fileURLWithPath: "/tmp/model-folder")
        let pdfBesideCloud = [dir.appending(path: "Assembly.pdf"), dir.appending(path: "Bracket.3mf.cloud"),
                              dir.appending(path: "thumb.png")]
        #expect(Shop.soleModel(in: pdfBesideCloud) == nil,
                "the assembly PDF was handed to the slicer as the model")
        let one = [dir.appending(path: "Assembly.pdf"), dir.appending(path: "Bracket.3mf")]
        #expect(Shop.soleModel(in: one)?.lastPathComponent == "Bracket.3mf")
        let two = [dir.appending(path: "a.stl"), dir.appending(path: "b.stl")]
        #expect(Shop.soleModel(in: two) == nil, "two models is not one")
        #expect(Shop.soleModel(in: [dir.appending(path: "a.stl.part-1")]) == nil)
    }

    @Test("a folder move that would write a path past 60 characters is refused")
    func folderMoveWithinSixty() {
        let deep = String(repeating: "x", count: 40)
        let wanted = Shop.folderMoveTargets("Helmet", to: deep + "/Helmet",
                                            files: [("F1", "Helmet/Left visor piece")])
        #expect(wanted["F1"] == deep + "/Helmet/Left visor piece")
        #expect(!Shop.folderMoveFits(wanted),
                "cut at 60 by normalise, the path would merge with another folder")
        #expect(Shop.folderMoveFits(["F1": "Kings/Faisal"]))
    }

    @Test("shipping a job owes order_shipped once, with the carrier and tracking number")
    func shippingFiresOrderShipped() async throws {
        let engine = try KhaytEngine()
        let root: [String: JSONValue] = [
            "settings": .object([
                "currency": .string("SAR"),
                "webhooks": .object(["enabled": .bool(true), "secret": .string("s"),
                                     "events": .object(["order_shipped": .string("https://example.test/hook")])]),
            ]),
            "clients": .array([]),
        ]
        let before: JSONValue = .object(["id": .string("O-1"), "project": .string("Lamp"),
                                         "status": .string("completed")])
        let after: JSONValue = .object(["id": .string("O-1"), "project": .string("Lamp"),
                                        "status": .string("completed"),
                                        "shippedAt": .string("2026-10-02T09:00:00.000Z"),
                                        "carrier": .string("aramex"), "trackingNumber": .string("TRK1")])
        let owed = await Shop.shippedDeliveries(before: before, after: after, root: root, engine: engine)
        #expect(owed.map(\.event) == ["order_shipped"], "the parcel left and no subscriber was told")
        let body = String(describing: owed.first?.body)
        #expect(body.contains("TRK1"))

        // Already in the post: re-stamping is not a second parcel.
        let again = await Shop.shippedDeliveries(before: after, after: after, root: root, engine: engine)
        #expect(again.isEmpty)
    }
}
