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
        // Only purposes this Mac knows: a phone sends back the list it was
        // shown, and an id from a newer app would be refused as `bad-keep`.
        let known = Set(Self.phoneKeepable.map(\.rawValue))
        let keep: [JSONValue] = { if case .array(let a)? = n["keep"] { return a.filter { if case .string(let s) = $0 { known.contains(s) } else { false } } }; return [] }()
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
                      Self.phoneKeepable.contains(purpose) else { return refuse(400, "bad-keep") }
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
        // The kept list the phone was showing, when it sends one: `changedAt`
        // moves only when the switch itself is flipped, so a Keep ticked at
        // the Mac meanwhile is invisible to `seen` and would be wiped.
        var seenKeep: Set<String>?
        switch asked["seenKeep"] {
        case nil, .null?: seenKeep = nil
        case .array(let list)?:
            var out = Set<String>()
            for item in list { guard case .string(let id) = item else { return refuse(400, "bad-body") }; out.insert(id) }
            seenKeep = out
        default: return refuse(400, "bad-body")
        }
        guard engine != nil else { return refuse(503, "busy") }
        // The sample book has no switch to change.
        guard source.build != nil || networkBookForTests != nil else { return refuse(409, "read-only") }

        // What the person was LOOKING at when they tapped. If the book has
        // moved since, nothing is changed and the phone is shown what is true
        // now: two people flipping it at once never overwrite each other blind.
        let stale = answer(409, ["ok": .bool(false), "reason": .string("changed"), "network": networkForPhone()])
        if let seen {
            // Compared as INSTANTS: a phone that read the stamp into a date and
            // wrote it back without its milliseconds is saying the same moment.
            // A stamp that is not one is compared as the text it is.
            let current: String? = { if case .string(let s)? = networkSettings["changedAt"] { return s }; return nil }()
            let same: Bool = {
                guard let current else { return false }
                if let a = NetworkSwitch.date(current), let b = NetworkSwitch.date(seen) { return a == b }
                return current == seen
            }()
            if !same { return stale }
        }
        if let seenKeep {
            let current: Set<String> = { if case .object(let n) = networkForPhone(), case .array(let a)? = n["keep"] {
                return Set(a.compactMap { if case .string(let s) = $0 { s } else { nil } }) }; return [] }()
            if current != seenKeep { return stale }
        }
        // A name is chosen on the phone at pairing and is now written where
        // other computers show it: no control or direction-changing
        // characters, and a bound in bytes as well as characters.
        var name = String(String.UnicodeScalarView(deviceName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        })).trimmingCharacters(in: .whitespaces)
        name = String(name.prefix(80))
        while name.utf8.count > 240 { name.removeLast() }
        // A failure here is the PHONE's to hear, in its answer. Whoever is at
        // the Mac did nothing, and is not shown an error for it.
        let shownHere = moveProblem
        let changed = await changeOutboundOffline(offline, by: name.isEmpty ? nil : name, keep: keep, now: now)
        if !changed { moveProblem = shownHere }
        guard changed else {
            // Another change is in flight, or the write was refused (another
            // computer holds the book): said, with what is true now.
            return answer(409, ["ok": .bool(false), "reason": .string("not-saved"), "network": networkForPhone()])
        }
        return answer(200, ["ok": .bool(true), "network": networkForPhone()])
    }
}
