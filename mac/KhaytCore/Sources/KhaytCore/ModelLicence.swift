import Foundation

/// Where a model came from, and what its licence lets a shop do with it.
///
/// A print shop's library holds two very different things: work it made or was
/// commissioned for, and models it downloaded. They look identical in a grid,
/// and the difference decides whether a print can be SOLD — most of what is on
/// the model sites is Creative Commons, and a large share of that is
/// NonCommercial, which is exactly the licence that makes selling a print of it
/// a breach rather than a favour.
///
/// ── UNKNOWN IS NOT NO ─────────────────────────────────────────────────────
///
/// The one decision here that is easy to get wrong. A shop that has not filled
/// this in must not be told it may not sell its own work, and must not be told
/// it may either. `sellable` answers true, false, or **nil** — and nil means
/// nobody has said, which is a different sentence on screen and a different
/// colour beside it.
public enum ModelLicence {

    /// A licence a downloaded model actually carries, and what it permits.
    ///
    /// `commercial` is the shop's question — may a print of this be sold.
    /// `share` is whether a modified version must carry the same licence, which
    /// matters the moment a shop remixes something. `derivatives` is whether it
    /// may be modified at all: an ND model may be printed and sold under some
    /// readings and may not be altered, so it is kept separate rather than
    /// folded into `commercial`.
    public struct Licence: Sendable, Equatable, Identifiable, Hashable {
        public let id: String
        public let commercial: Bool
        public let attribution: Bool
        public let derivatives: Bool
        public let share: Bool
    }

    /// Permissive first — this order is the order of a menu.
    public static let all: [Licence] = [
        .init(id: "own", commercial: true, attribution: false, derivatives: true, share: false),
        .init(id: "cc0", commercial: true, attribution: false, derivatives: true, share: false),
        .init(id: "cc-by", commercial: true, attribution: true, derivatives: true, share: false),
        .init(id: "cc-by-sa", commercial: true, attribution: true, derivatives: true, share: true),
        .init(id: "cc-by-nd", commercial: true, attribution: true, derivatives: false, share: false),
        .init(id: "cc-by-nc", commercial: false, attribution: true, derivatives: true, share: false),
        .init(id: "cc-by-nc-sa", commercial: false, attribution: true, derivatives: true, share: true),
        .init(id: "cc-by-nc-nd", commercial: false, attribution: true, derivatives: false, share: false),
        // Bought from the designer, which overrides whatever the free licence said.
        .init(id: "commercial", commercial: true, attribution: false, derivatives: true, share: false),
    ]

    /// `str()` in the original is trim-if-a-string, so a number, a null or a
    /// missing field all read as the empty string rather than as their text.
    static func str(_ v: JSONValue?) -> String {
        guard case .string(let s)? = v else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `toLowerCase()` in the original, so the id is matched case-insensitively.
    /// Swift's `lowercased()` is the right counterpart because both are
    /// locale-INDEPENDENT: the locale-aware pair (`toLocaleLowerCase`, and
    /// `lowercased(with:)` on `NSString`) would lower "CC-BY" through a Turkish
    /// dotless i and fail to match a licence the shop had recorded.
    static func byId(_ id: String) -> Licence? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == wanted }
    }

    public static func find(_ id: String?) -> Licence? { byId(id ?? "") }

    /// May a shop sell a print of this? Nil when nobody has recorded a licence
    /// — which is not the same as "no", and must not be shown as one.
    public static func sellable(_ licence: String?) -> Bool? { find(licence)?.commercial }

    /// Must the designer be credited when it is shown or sold?
    public static func needsAttribution(_ licence: String?) -> Bool {
        find(licence)?.attribution ?? false
    }

    /// May it be modified — rescaled, remixed, cut up?
    public static func allowsDerivatives(_ licence: String?) -> Bool? {
        find(licence)?.derivatives
    }

    /// What a shop should be told about one model, in facts rather than a
    /// sentence. `known` false means the record says nothing, and every other
    /// field is then a nil the caller must not render as a refusal.
    public struct Standing: Sendable, Equatable {
        public let known: Bool
        public let licence: String
        public let source: String
        public let sellable: Bool?
        public let attribution: Bool
        public let derivatives: Bool?
        public let share: Bool
    }

    public static func standing(_ record: JSONValue?) -> Standing {
        var fields: [String: JSONValue] = [:]
        if case .object(let o)? = record { fields = o }
        let found = byId(str(fields["licence"]))
        return Standing(known: found != nil, licence: found?.id ?? "",
                        source: str(fields["source"]),
                        sellable: found?.commercial,
                        // `attribution` and `share` fall back to FALSE where
                        // `sellable` and `derivatives` fall back to nil. That
                        // asymmetry is the original's, and it is right: an
                        // unknown model owes nobody a credit yet, but whether
                        // it may be sold is genuinely unanswered.
                        attribution: found?.attribution ?? false,
                        derivatives: found?.derivatives,
                        share: found?.share ?? false)
    }

    public static func standing(source: String?, licence: String?) -> Standing {
        standing(.object(["source": .string(source ?? ""), "licence": .string(licence ?? "")]))
    }

    /// The models a shop may NOT sell a print of.
    ///
    /// Only the ones actually recorded as non-commercial. A library where
    /// nothing has been filled in returns an empty list rather than all of it —
    /// a warning about every model is a warning nobody reads.
    public static func notForSale(_ records: [JSONValue]) -> [JSONValue] {
        records.filter { record in
            guard case .object(let o) = record else { return false }
            return sellable(str(o["licence"])) == false
        }
    }
}
