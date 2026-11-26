import Foundation
import KhaytCore

/// Two read-only views for the OWNER's phone (iPhone frames 268:7 and 268:28):
///
///     GET /api/devices             the shop's paired phones
///     GET /api/devices/connectors  the paired slicers, and whether prices show in them
///
/// READ ONLY, AND OWNER ONLY. A signed, enrolled phone whose role is owner:
/// not the PIN alone, not an API token, not a manager. Neither path is in the
/// role table (`lib/device-roles.js`), and a route the table does not name is
/// the owner's, so the gate refuses everyone else before this runs; the role
/// is asked again here by name, so a row added to the table one day cannot
/// open these by accident.
///
/// WHAT IS NEVER IN THE ANSWER: a device's key, its PIN tag, or anything else
/// that could enrol or impersonate one. A name, a role, how it was paired,
/// when it was last seen. `LanDevices.list()` is the Settings list, which
/// never held a key.
///
/// Both answers are signed for the phone that asked.
extension LanServer {

    static let devicesPath = "/api/devices"
    static let slicersPath = "/api/devices/connectors"

    func ownerViewRoute(_ request: Request, path: String) async -> Response? {
        guard request.method == "GET", path == Self.devicesPath || path == Self.slicersPath else { return nil }
        if let refused = await pinGate(request) { return refused }
        guard !request.tokenScoped, LanDevices.isSigned(request.headers), let me = request.headers["x-khayt-device"] else {
            return .json(403, #"{"ok":false,"reason":"device-key-required"}"#)
        }
        guard let role = await roleHeld(by: me), role == "owner" else {
            return signedForPhone(.json(403, #"{"ok":false,"reason":"role-scope","required":"owner"}"#), request)
        }
        let listed = host.devices.list()
        var answer: [String: JSONValue] = ["ok": .bool(true)]
        if path == Self.devicesPath {
            var rows: [JSONValue] = []
            for device in listed where device.kind == nil {
                var row: [String: JSONValue] = [
                    "deviceId": .string(device.id), "name": .string(device.name),
                    "role": .string(await roleHeld(by: device.id) ?? "viewer"),
                    "pairedBy": .string(device.codePaired ? "code" : "pin"),
                    "lastSeenAt": .string(StoreWriter.iso(device.lastSeenAt)),
                ]
                if device.id == me { row["self"] = .bool(true) }
                rows.append(.object(row))
            }
            answer["devices"] = .array(rows)
        } else {
            answer["slicerPrices"] = .bool(host.connectorPrices())
            answer["connectors"] = .array(listed.filter { $0.kind == LanDevices.kindConnector }.map { device in
                .object(["deviceId": .string(device.id), "name": .string(device.name),
                         // What it may see when the shop's switch is on: nothing, the price, or price, cost and margin.
                         "priceGrant": .bool(device.priceGrant != nil),
                         "grant": device.priceGrant.map(JSONValue.string) ?? .null,
                         "lastSeenAt": .string(StoreWriter.iso(device.lastSeenAt))])
            })
        }
        let body = (try? String(decoding: JSONEncoder().encode(JSONValue.object(answer)), as: UTF8.self)) ?? #"{"ok":false,"reason":"encode"}"#
        return signedForPhone(.json(200, body), request)
    }

    /// The role a paired device holds, as the shared rule reads its stored
    /// record (a phone paired with the owner PIN before roles is the owner).
    /// Nil for an id nobody enrolled.
    func roleHeld(by id: String) async -> String? {
        guard let stored = host.devices.rulesRecord(id) else { return nil }
        let device = KhaytEngine.deviceRecord(kind: stored["kind"], role: stored["role"], rolesVersion: stored["rolesVersion"].flatMap(Int.init))
        return try? await host.engine.deviceRole(device)
    }
}
