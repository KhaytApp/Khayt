import Foundation
import KhaytCore

/// Two things the owner's phone can LOOK at and never change (signed frames,
/// Turki, Nov 24; the Mac's routes, #2707): the shop's paired phones, and
/// which slicers may see prices. The Mac stays the place where a phone is
/// approved, removed or given a role, and where slicer prices are set.
///
/// Both answers are believed only when the Mac signed them, and both routes
/// are the owner's: any other role is refused by the Mac, and shown nothing.
struct PairedPhone: Decodable, Equatable, Identifiable, Sendable {
    let deviceId: String
    let name: String?
    /// The role the phone holds; text, so a role this build does not know still shows as itself is never guessed.
    let role: String?
    /// `pin` or `code`.
    let pairedBy: String?
    let lastSeenAt: String?
    /// Only on the phone that asked.
    let isSelf: Bool

    var id: String { deviceId }

    private enum CodingKeys: String, CodingKey { case deviceId, name, role, pairedBy, lastSeenAt, isSelf = "self" }

    init(deviceId: String, name: String?, role: String?, pairedBy: String?, lastSeenAt: String?, isSelf: Bool) {
        self.deviceId = deviceId; self.name = name; self.role = role; self.pairedBy = pairedBy
        self.lastSeenAt = lastSeenAt; self.isSelf = isSelf
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        pairedBy = try? c.decodeIfPresent(String.self, forKey: .pairedBy)
        lastSeenAt = try? c.decodeIfPresent(String.self, forKey: .lastSeenAt)
        isSelf = ((try? c.decodeIfPresent(Bool.self, forKey: .isSelf)) ?? nil) ?? false
    }
}

struct SlicerPrices: Equatable, Sendable {
    struct Slicer: Decodable, Equatable, Identifiable, Sendable {
        let deviceId: String
        let name: String?
        let priceGrant: Bool
        var id: String { deviceId }

        private enum CodingKeys: String, CodingKey { case deviceId, name, priceGrant }

        init(deviceId: String, name: String?, priceGrant: Bool) {
            self.deviceId = deviceId; self.name = name; self.priceGrant = priceGrant
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            deviceId = try c.decode(String.self, forKey: .deviceId)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            // Anything but a plain `true` is "hidden": never a grant by mistake.
            priceGrant = ((try? c.decodeIfPresent(Bool.self, forKey: .priceGrant)) ?? nil) ?? false
        }
    }

    /// The shop's switch on that Mac.
    let shown: Bool
    let slicers: [Slicer]
}

enum OwnerViews {
    static let phonesCapability = "devices"
    static let pricesCapability = "slicer-prices"

    /// Asked only by a phone that acts as the owner, in reach of the Mac,
    /// never on the sample shop. The Mac checks the role itself.
    static func asks(role: String, macInReach: Bool, sampleShop: Bool) -> Bool {
        role == "owner" && macInReach && !sampleShop
    }

    /// The paired phones of a `GET /api/devices` answer, as the Mac ordered
    /// them (most recently seen first). Nil unless it is a signed 200 that
    /// says ok: nothing is shown on anything less.
    static func phones(status: Int, body: Data, signed: Bool) -> [PairedPhone]? {
        struct Answer: Decodable {
            let ok: Bool
            let devices: [PairedPhone]
            private enum CodingKeys: String, CodingKey { case ok, devices }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
                devices = c.lossyList(PairedPhone.self, forKey: .devices)
            }
        }
        guard signed, status == 200, let answer = try? JSONDecoder().decode(Answer.self, from: body), answer.ok else { return nil }
        return answer.devices
    }

    /// The slicers of a `GET /api/devices/connectors` answer, on the same terms.
    static func prices(status: Int, body: Data, signed: Bool) -> SlicerPrices? {
        struct Answer: Decodable {
            let ok: Bool
            let slicerPrices: Bool
            let connectors: [SlicerPrices.Slicer]
            private enum CodingKeys: String, CodingKey { case ok, slicerPrices, connectors }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
                slicerPrices = (try? c.decode(Bool.self, forKey: .slicerPrices)) ?? false
                connectors = c.lossyList(SlicerPrices.Slicer.self, forKey: .connectors)
            }
        }
        guard signed, status == 200, let answer = try? JSONDecoder().decode(Answer.self, from: body), answer.ok else { return nil }
        return SlicerPrices(shown: answer.slicerPrices, slicers: answer.connectors)
    }

    /// "Paired with the PIN · last seen 14:12".
    static func detail(_ phone: PairedPhone, now: Date = Date()) -> String {
        var parts: [String] = []
        switch phone.pairedBy {
        case "pin": parts.append(L10n.tr("owner.phones.by_pin"))
        case "code": parts.append(L10n.tr("owner.phones.by_code"))
        default: break
        }
        if let seen = lastSeen(phone.lastSeenAt, now: now) { parts.append(L10n.format("owner.phones.seen", seen)) }
        return parts.joined(separator: " · ")
    }

    /// "now", "14:12", "yesterday" or a date, in the app's language.
    static func lastSeen(_ iso: String?, now: Date = Date(), calendar: Calendar = bookCalendar) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let at = fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        if abs(now.timeIntervalSince(at)) < 600 { return L10n.tr("owner.phones.now") }
        // Shown in the same calendar the day was worked out in: "Nov 10",
        // never "Jmd. I 30, 1448 AH" on a phone whose region is Umm al-Qura.
        let shown = { (date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) in
            at.formatted(Date.FormatStyle(date: date, time: time, locale: L10n.locale,
                                          calendar: calendar, timeZone: calendar.timeZone))
        }
        if calendar.isDate(at, inSameDayAs: now) {
            return shown(.omitted, .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: yesterday) {
            return L10n.tr("owner.phones.yesterday")
        }
        return shown(.abbreviated, .omitted)
    }

    /// The book's calendar: Gregorian, in this phone's time zone, whatever
    /// calendar the phone's region uses (a Saudi phone's is Umm al-Qura).
    static var bookCalendar: Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        return gregorian
    }

    /// The role's word; a role this build does not know shows no word, never a guess.
    static func roleWords(_ role: String?) -> String {
        guard let role, DeviceRole.ladder.contains(role) else { return "" }
        return L10n.tr("owner.role." + role)
    }
}

extension KhaytAPIClient {
    /// The shop's paired phones, or nil (not the owner, no route, no answer,
    /// or an answer the Mac did not sign).
    func pairedPhones() async -> [PairedPhone]? {
        guard let answer = await signedLanAnswer(path: "/api/devices", method: "GET") else { return nil }
        return OwnerViews.phones(status: answer.status, body: answer.body, signed: answer.signed)
    }

    /// Which slicers may see prices, on the same terms.
    func slicerPrices() async -> SlicerPrices? {
        guard let answer = await signedLanAnswer(path: "/api/devices/connectors", method: "GET") else { return nil }
        return OwnerViews.prices(status: answer.status, body: answer.body, signed: answer.signed)
    }
}
