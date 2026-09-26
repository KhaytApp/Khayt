import Foundation

/// A WhatsApp update for one job, as `lib/whatsapp-message.js` builds it.
///
/// Portable on purpose: the phone can offer the same button, and a rule that
/// lands in `KhaytApp` is one the phone would have to ask the Mac for.
public struct WhatsAppUpdate: Decodable, Sendable, Equatable {
    /// Whether WhatsApp can be opened — a usable number and a milestone.
    public let ok: Bool
    /// Why not: `no_milestone`, `no_customer`, `no_phone`, or one of the
    /// number's own reasons (`too_short`, `no_country_code`, …). Empty when ok.
    public let reason: String
    public let milestone: String
    public let lang: String
    /// The message, filled in. Present even when `ok` is false.
    public let text: String
    /// The shop's template it came from, or nil for Khayt's default words.
    public let templateId: String?
    public let isDefault: Bool
    /// `+9665XXXXXXXX`, for showing to a person.
    public let e164: String
    public let digits: String
    public let link: String
}

/// A number made ready for `wa.me`, or the reason it cannot be.
public struct WhatsAppChat: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let reason: String
    public let e164: String
    public let digits: String
    public let link: String

    /// Spelled out because a public struct's memberwise initialiser is
    /// internal, and a host refusing before it asks the rule — no customer
    /// record at all — needs to say so in the same shape.
    public init(ok: Bool, reason: String, e164: String, digits: String, link: String) {
        self.ok = ok; self.reason = reason; self.e164 = e164; self.digits = digits; self.link = link
    }
}
