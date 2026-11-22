import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The publish body carries the intake request the job came from, so the
/// cloud can email the customer their link once (khayt-cloud 2026-11-03).
@MainActor
struct PortalIntakeIdTests {
    @Test("the publish body carries intakeId top level, only when the job has one")
    func intakeIdTopLevel() {
        let payload: JSONValue = .object(["ref": .string("J1")])
        let with = PortalRefresh(kind: "quote", pubToken: "t", payload: payload,
                                 customerEmail: "a@x.com", intakeId: "in_9")
        let body = PortalClient.publishBody(with)
        #expect(body["intakeId"] == .string("in_9"))
        #expect(body["customerEmail"] == .string("a@x.com"))
        if case .object(let p)? = body["payload"] { #expect(p["intakeId"] == nil) }

        for none in [PortalRefresh(kind: "order", pubToken: "t", payload: payload, customerEmail: ""),
                     PortalRefresh(kind: "order", pubToken: "t", payload: payload, customerEmail: "", intakeId: "")] {
            let b = PortalClient.publishBody(none)
            #expect(b["intakeId"] == nil && b["customerEmail"] == nil)
            #expect(Set(b.keys) == ["kind", "payload"])
        }
    }

    @Test("the shared builder returns intakeId from the job")
    func builderReturnsIt() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object(["id": .string("J1"), "status": .string("printing"),
                                        "trackingToken": .string("trk"), "intakeId": .string("in_7")])
        let r = try await engine.portalPayload(order: order, settings: [:], clients: [], shopName: "S",
                                               shopAddress: "", stages: [])
        #expect(r?.intakeId == "in_7")
    }
}
