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

    /// Whether a BOUGHT licence has run out on `today` (`YYYY-MM-DD`). See
    /// `lib/model-licence.js` — held to it by `ModelLicenceParityTests`.
    public static func expired(_ record: JSONValue?, today: String) -> Bool {
        guard case .object(let o)? = record else { return false }
        guard str(o["licence"]).lowercased() == "commercial" else { return false }
        let until = str(o["licenceExpires"])
        let day = today.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDay(until), isDay(day) else { return false }
        return until < day
    }

    /// `sellable`, and a lapsed bought licence is a no. Nil when nobody has said.
    public static func sellableOn(_ record: JSONValue?, today: String) -> Bool? {
        var licence = ""
        if case .object(let o)? = record { licence = str(o["licence"]) }
        let yes = sellable(licence)
        return yes == true && expired(record, today: today) ? false : yes
    }

    /// One model behind a sale that may not be sold today.
    public struct SaleProblem: Equatable, Sendable {
        public let id: String
        public let name: String
        public let licence: String
        /// `not-commercial` or `expired`.
        public let reason: String
        public let until: String
    }

    /// The models behind a sale that may not be sold today, in the order asked.
    /// Unknown licences are not problems — unknown is not no.
    public static func saleProblems(_ ids: [String], records: [JSONValue], today: String) -> [SaleProblem] {
        var seen = Set<String>()
        var out: [SaleProblem] = []
        for raw in ids {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            guard let record = records.first(where: {
                if case .object(let o) = $0 { return str(o["id"]) == key } else { return false }
            }), case .object(let o) = record else { continue }
            var name = str(o["name"])
            if name.isEmpty { name = str(o["originalName"]) }
            let plain = sellable(str(o["licence"]))
            if plain == false {
                out.append(.init(id: key, name: name, licence: str(o["licence"]).lowercased(),
                                 reason: "not-commercial", until: ""))
            } else if plain == true, expired(record, today: today) {
                out.append(.init(id: key, name: name, licence: "commercial", reason: "expired",
                                 until: str(o["licenceExpires"])))
            }
        }
        return out
    }

    private static func isDay(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

extension ModelLicence {

    /// The licence a MODEL FILE claims, translated — or nothing.
    ///
    /// ── IT REFUSES FAR MORE OFTEN THAN IT AGREES, ON PURPOSE ──────────────
    ///
    /// `find` matches this module's own ids and nothing else, which is right
    /// for a value a person chose from a menu and useless for one a slicer
    /// wrote. A 3MF says `BY-NC-SA`, not `cc-by-nc-sa`.
    ///
    /// Measured on a real shop's ninety files, the licence strings that
    /// actually turn up are: `BY-NC-SA`, `Standard Digital File License` and
    /// `MakerWorld Exclusive License`. Only the first is a licence this module
    /// can reason about. The other two are a platform's own terms — they are
    /// not Creative Commons, they are not "commercial", and deciding either
    /// way would be this app inventing a legal opinion.
    ///
    /// So they come back nil, and nil means NOBODY HAS SAID — which the rest
    /// of this module is careful to keep distinct from "no". The alternative
    /// is worse in both directions: guessing permissive tells a shop it may
    /// sell something it may not, and guessing restrictive tells a shop it may
    /// not sell its own work.
    public static func fromFile(_ said: String?) -> Licence? {
        let raw = (said ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        // The id itself, first: a file that already spells it this module's
        // way needs no table.
        if let exact = byId(raw) { return exact }
        // `CC BY-NC-SA 4.0`, `cc-by-nc-sa`, `BY-NC-SA` — one shape.
        var tidy = raw.replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        while tidy.contains("--") { tidy = tidy.replacingOccurrences(of: "--", with: "-") }
        for version in ["-4.0", "-3.0", "-2.0", "-1.0", "-international", "-intl"] {
            if tidy.hasSuffix(version) { tidy = String(tidy.dropLast(version.count)) }
        }
        if tidy.hasPrefix("cc-") { tidy = String(tidy.dropFirst(3)) }
        if tidy == "cc0" || tidy == "zero" || tidy == "public-domain" { return byId("cc0") }
        // What is left must be exactly a Creative Commons clause list. Anything
        // else — a platform's own terms, a sentence, a URL — is not translated.
        // A stray separator means it is not a clean clause list — `-BY-` is
        // not `BY`. Swift drops empty pieces when splitting, so without this
        // the stray one is simply absorbed.
        guard !tidy.hasPrefix("-"), !tidy.hasSuffix("-") else { return nil }
        let clauses = tidy.split(separator: "-").map(String.init)
        let known: Set<String> = ["by", "nc", "sa", "nd"]
        guard !clauses.isEmpty, clauses.first == "by",
              clauses.allSatisfy({ known.contains($0) }),
              Set(clauses).count == clauses.count else { return nil }
        return byId("cc-" + clauses.joined(separator: "-"))
    }
}
