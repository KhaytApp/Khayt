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

/// An update sent FOR the shop through its own WhatsApp Business account —
/// `lib/whatsapp-message.js cloudMessage`: whether this change owes one, the
/// approved template, the customer's number and the template's parameters.
public struct WhatsAppCloudMessage: Decodable, Sendable, Equatable {
    public struct Template: Decodable, Sendable, Equatable {
        public let name: String
        public let language: String
    }
    public let send: Bool
    /// Why not, when `send` is false. Most are quiet — not set up, no template
    /// for this milestone, the customer has not agreed — and the few worth
    /// saying are the ones `isUnreachable` names.
    public let reason: String
    public let milestone: String
    public let lang: String
    public let template: Template?
    /// The international number, digits only.
    public let to: String
    public let clientId: String
    public let params: [String]
}

/// One HTTPS request `lib/whatsapp-send.js` built, or why it refused to.
public struct WhatsAppCloudRequest: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let reason: String?
    public let url: String?
    public let method: String?
    public let headers: [String: String]?
    public let body: String?

    public init(ok: Bool, reason: String?, url: String?, method: String?,
                headers: [String: String]?, body: String?) {
        self.ok = ok; self.reason = reason; self.url = url; self.method = method
        self.headers = headers; self.body = body
    }
}

/// What Meta's answer meant — `lib/whatsapp-send.js readResponse` or
/// `readCheck`. `messageId` is the `wamid…` the delivery reports name.
public struct WhatsAppCloudResult: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let reason: String?
    public let messageId: String?
    public let code: Int?
    public let title: String?
    public let retryable: Bool?
    /// From a check: the number as WhatsApp shows it, and the business's name.
    public let number: String?
    public let name: String?
}
