import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// `GET /api/devices` and `GET /api/devices/connectors`: the owner's phone
/// reading which phones are paired and whether prices show in the slicer.
/// Read only, owner only, and never a key.
@MainActor
@Suite(.serialized)
struct LanOwnerViewsTests {

    static func ask(_ bench: LanServerTests.Bench, _ peer: LanConnectorRoutesTests.Peer, _ path: String)
        async throws -> (status: Int, json: [String: Any], text: String, signed: Bool) {
        let headers = peer.headers("GET", path)
        let reply = try await bench.send("GET", path, body: nil, headers: headers, timeout: 30)
        let mac = LanServer.replyMac(key: peer.key, nonce: headers["x-khayt-nonce"] ?? "", status: reply.status, body: reply.body)
        return (reply.status, reply.json, reply.text, reply.headers["x-khayt-reply-mac"] == mac)
    }

    @Test("the owner's phone reads the paired phones: name, role, how each was paired, when it was last seen, and which one is asking")
    func phones() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let owner = try PhoneRolesTests.codePaired(bench.devices, role: "owner", name: "Sara's iPhone")
        let floor = try PhoneRolesTests.codePaired(bench.devices, role: "operator", name: "Floor phone")
        let legacy = try LanConnectorRoutesTests.enrol(bench, kind: nil, name: "Old phone")
        _ = try LanConnectorRoutesTests.enrol(bench, name: "OrcaSlicer on the PC")
        let got = try await Self.ask(bench, owner, "/api/devices")
        #expect(got.status == 200 && got.signed && got.json["ok"] as? Bool == true)
        let rows = try #require(got.json["devices"] as? [[String: Any]])
        // Phones only: the slicer is not one.
        #expect(Set(rows.compactMap { $0["name"] as? String }) == ["Sara's iPhone", "Floor phone", "Old phone"])
        func row(_ id: String) throws -> [String: Any] { try #require(rows.first { $0["deviceId"] as? String == id }) }
        let mine = try row(owner.id)
        #expect(mine["role"] as? String == "owner" && mine["pairedBy"] as? String == "code" && mine["self"] as? Bool == true)
        let theirs = try row(floor.id)
        #expect(theirs["role"] as? String == "operator" && theirs["self"] == nil)
        // Paired with the PIN before roles: the owner, as the rule reads it.
        let old = try row(legacy.id)
        #expect(old["role"] as? String == "owner" && old["pairedBy"] as? String == "pin")
        #expect((mine["lastSeenAt"] as? String ?? "").hasSuffix("Z"))
        // Exactly these fields, and nothing that could enrol or impersonate a phone.
        for r in rows { #expect(Set(r.keys).isSubset(of: ["deviceId", "name", "role", "pairedBy", "lastSeenAt", "self"]), Comment(rawValue: "\(r.keys)")) }
        for secret in ["key", "pinTag", "pin_tag", "secret", "createdAt"] { #expect(!got.text.contains("\"\(secret)\""), Comment(rawValue: secret)) }
        #expect(!got.text.contains(owner.key.base64EncodedString()) && !got.text.contains(floor.key.base64EncodedString()))
    }

    @Test("the owner's phone reads the slicers and the shop's switch; nobody else reads either")
    func slicersAndWho() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let owner = try PhoneRolesTests.codePaired(bench.devices, role: "owner", name: "Owner")
        let slicer = try LanConnectorRoutesTests.enrol(bench, name: "OrcaSlicer on the PC")
        let other = try LanConnectorRoutesTests.enrol(bench, name: "Second slicer")
        bench.devices.setPriceGrant(slicer.id, "cost")
        let got = try await Self.ask(bench, owner, "/api/devices/connectors")
        #expect(got.status == 200 && got.signed)
        #expect(got.json["slicerPrices"] as? Bool == false, "the bench's switch is off")
        let rows = try #require(got.json["connectors"] as? [[String: Any]])
        #expect(rows.count == 2, "a phone was listed as a slicer")
        let granted = try #require(rows.first { $0["deviceId"] as? String == slicer.id })
        #expect(granted["priceGrant"] as? Bool == true && granted["grant"] as? String == "cost" && granted["name"] as? String == "OrcaSlicer on the PC")
        let hidden = try #require(rows.first { $0["deviceId"] as? String == other.id })
        #expect(hidden["priceGrant"] as? Bool == false && hidden["grant"] is NSNull)
        #expect(!got.text.contains("\"key\"") && !got.text.contains(slicer.key.base64EncodedString()))

        // Everyone else, on both paths.
        for role in ["manager", "operator", "viewer"] {
            let phone = try PhoneRolesTests.codePaired(bench.devices, role: role, name: role)
            for path in ["/api/devices", "/api/devices/connectors"] {
                let refused = try await Self.ask(bench, phone, path)
                #expect(refused.status == 403 && refused.json["reason"] as? String == "role-scope" && refused.json["required"] as? String == "owner",
                        Comment(rawValue: "\(role) \(path)"))
                #expect(refused.signed && refused.json["devices"] == nil && refused.json["connectors"] == nil, Comment(rawValue: role))
            }
            // And the phone is not told it can.
            let me = try await Self.ask(bench, phone, "/api/devices/self")
            let can = (me.json["can"] as? [String]) ?? []
            #expect(!can.contains("devices") && !can.contains("slicer-prices"), Comment(rawValue: role))
        }
        let ownerCan = ((try await Self.ask(bench, owner, "/api/devices/self")).json["can"] as? [String]) ?? []
        #expect(ownerCan.contains("devices") && ownerCan.contains("slicer-prices"))
        // The PIN alone; nothing at all; a paired slicer asking about the others.
        for path in ["/api/devices", "/api/devices/connectors"] {
            let pin = try await bench.get(path, headers: ["x-khayt-pin": LanDeviceKeysTests.pin])
            #expect(pin.status == 403 && pin.text.contains("device-key-required") && pin.headers["x-khayt-reply-mac"] == nil, Comment(rawValue: path))
            #expect(try await bench.get(path).status == 401, Comment(rawValue: path))
            let fromSlicer = try await Self.ask(bench, slicer, path)
            #expect(fromSlicer.status == 401 || fromSlicer.status == 403, Comment(rawValue: path))
            #expect(fromSlicer.json["devices"] == nil && fromSlicer.json["connectors"] == nil)
        }
    }

    @Test("read only: no other verb on these paths does anything new, and the rule itself calls both the owner's")
    func readOnly() async throws {
        let bench = try await PhoneRolesTests.bench()
        defer { bench.stop() }
        let owner = try PhoneRolesTests.codePaired(bench.devices, role: "owner", name: "Owner")
        let before = bench.devices.list()
        for method in ["PUT", "PATCH", "DELETE"] {
            for path in ["/api/devices", "/api/devices/connectors"] {
                let (status, _) = try await PhoneRolesTests.status(bench, owner, method, path)
                #expect(status == 404 || status == 405, Comment(rawValue: "\(method) \(path) \(status)"))
            }
        }
        // POST /api/devices is enrolment, behind its own window, exactly as before: closed here.
        #expect(try await PhoneRolesTests.status(bench, owner, "POST", "/api/devices/connectors").0 == 404)
        #expect(bench.devices.list() == before)
        let engine = OperatorLockTests.sharedEngine
        for role in ["viewer", "operator", "manager", "owner"] {
            for path in ["/api/devices", "/api/devices/connectors"] {
                let a = try await engine.deviceAllows(.object(["role": .string(role), "rolesVersion": .number(1)]), path: path, method: "GET")
                #expect(a.ok == (role == "owner") && a.required == "owner", Comment(rawValue: "\(role) \(path)"))
            }
        }
        // `/api/devices/self` is still anyone's who is paired.
        let me = try await engine.deviceAllows(.object(["role": .string("viewer"), "rolesVersion": .number(1)]), path: "/api/devices/self", method: "GET")
        #expect(me.ok && me.required == nil)
        let docs = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "docs/LAN_API.md"), encoding: .utf8)
        #expect(docs.contains("### `GET /api/devices`") && docs.contains("### `GET /api/devices/connectors`"))
    }
}
