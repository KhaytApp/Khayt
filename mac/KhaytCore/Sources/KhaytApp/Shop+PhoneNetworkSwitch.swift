import Foundation
import KhaytCore

/// An owner's phone turning the shop's "Make no internet calls" on or off
/// (iPhone frame 1B, decided Nov 22; `POST /api/network/switch`).
///
/// The route takes a SIGNED, enrolled phone whose ROLE is owner
/// (`LanServer`: the shared rule answers `owner` for a route its table does
/// not name). What happens then is the Mac's own change, by the same path
/// (`changeOutboundOffline`): the same monotonic stamp (`stampAfter`), the
/// same "tell my other computers" call, the same write, and this Mac's gate
/// told at once. Nothing here is a second way to flip the switch.
extension Shop {
    /// The switch as a phone is told it: `{ offline, keep, changedAt, changedBy }`.
    func networkForPhone() -> JSONValue {
        let n = networkSettings
        let keep: [JSONValue] = { if case .array(let a)? = n["keep"] { return a.filter { if case .string = $0 { true } else { false } } }; return [] }()
        return .object(["offline": .bool(Self.offlineOf(.object(n))), "keep": .array(keep),
                        "changedAt": n["changedAt"] ?? .null, "changedBy": n["changedBy"] ?? .null])
    }

    /// The phone's request, already let through by the route. The answer is
    /// an HTTP status and a JSON body:
    /// `{"ok":true,"network":{…}}`, or `{"ok":false,"reason":…}` with
    /// `network` too on a 409.
    func phoneSetOutbound(body: Data, deviceName: String, now: Date = Date()) async -> (Int, String) {
        // lock: system — an owner's paired phone flipping the shop's switch; the LAN route takes a signed enrolled device whose role is owner, and the change is the Mac's own (changeOutboundOffline)
        func answer(_ status: Int, _ fields: [String: JSONValue]) -> (Int, String) {
            (status, (try? String(decoding: JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self)) ?? #"{"ok":false,"reason":"encode"}"#)
        }
        func refuse(_ status: Int, _ reason: String) -> (Int, String) { answer(status, ["ok": .bool(false), "reason": .string(reason)]) }

        // Exactly the shape asked for, or nothing is changed.
        guard body.count <= 4096, case .object(let asked)? = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .bool(let offline)? = asked["offline"] else { return refuse(400, "bad-body") }
        var keep: [OutboundPurpose]?
        switch asked["keep"] {
        case nil, .null?: keep = nil            // leave what is kept as it is
        case .array(let list)?:
            var out: [OutboundPurpose] = []
            for item in list {
                // An entry this Mac does not know is REFUSED, not dropped, so a
                // phone with a newer list learns it is talking to an older Mac.
                guard case .string(let id) = item, let purpose = OutboundPurpose(rawValue: id),
                      Self.keepable.contains(purpose), !NetworkSwitch.neverKept.contains(id) else { return refuse(400, "bad-keep") }
                out.append(purpose)
            }
            keep = out
        default: return refuse(400, "bad-body")
        }
        var seen: String?
        switch asked["seen"] {
        case nil, .null?: seen = nil
        case .string(let s)?: seen = s
        default: return refuse(400, "bad-body")
        }
        guard engine != nil else { return refuse(503, "busy") }
        // The sample book has no switch to change.
        guard source.build != nil || networkBookForTests != nil else { return refuse(409, "read-only") }

        // What the person was LOOKING at when they tapped. If the book has
        // moved since, nothing is changed and the phone is shown what is true
        // now: two people flipping it at once never overwrite each other blind.
        if let seen {
            let current: String? = { if case .string(let s)? = networkSettings["changedAt"] { return s }; return nil }()
            if current != seen { return answer(409, ["ok": .bool(false), "reason": .string("changed"), "network": networkForPhone()]) }
        }
        let name = String(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard await changeOutboundOffline(offline, by: name.isEmpty ? nil : name, keep: keep, now: now) else {
            // Another change is in flight, or the write was refused (another
            // computer holds the book): said, with what is true now.
            return answer(409, ["ok": .bool(false), "reason": .string("not-saved"), "network": networkForPhone()])
        }
        return answer(200, ["ok": .bool(true), "network": networkForPhone()])
    }
}
