import Foundation

/// A report a shop named and wants back.
///
/// The report builder lets a shop pick columns, stages and a date range; a shop
/// that runs the same question every month should not have to rebuild it every
/// month. The answer is a short list on `settings.savedReports`, and this owns
/// its shape so the two apps cannot disagree about it.
///
/// ── WHY THIS IS A RULE AND NOT FIVE LINES IN A CLICK HANDLER ──────────────
///
/// It WAS five lines in a click handler, with two faults that only show up
/// after a shop has used the feature for a while: saving twice under one name
/// appended twice, so a shop tweaking a report ended up with six entries called
/// "Monthly VAT" and no way to tell them apart; and there was no way to remove
/// one, so the list only ever grew.
public enum SavedReports {

    public struct Report: Sendable, Equatable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let fields: [String]
        public let statusIn: [String]
        public let from: String
        public let to: String

        public init(id: String, name: String, fields: [String], statusIn: [String],
                    from: String, to: String) {
            self.id = id; self.name = name; self.fields = fields
            self.statusIn = statusIn; self.from = from; self.to = to
        }
    }

    /// `String(v == null ? '' : v).trim()` — null and a missing field are the
    /// empty string, and everything else is spelled the way JavaScript spells
    /// it.
    static func text(_ value: JSONValue?) -> String {
        JSSemantics.text(value).trimmingCharacters(in: TelegramBot.jsWhitespace)
    }

    /// `slice(0, 10)` counts UTF-16 code units, so a date key is cut in the
    /// same place on both sides.
    static func tenUnits(_ value: String) -> String {
        String(decoding: Array(value.utf16.prefix(10)), as: UTF16.self)
    }

    /// One stored report, or nil if it is not one.
    ///
    /// A store edited by hand, or written by an older build, can hold anything.
    /// A screen that renders `settings.savedReports` straight would draw a
    /// button with no name on it and load a report with no columns.
    public static func clean(_ row: JSONValue?) -> Report? {
        // `typeof row === 'object'` is true for an ARRAY too — but an array has
        // no `id`, so it falls out at the next line either way.
        guard case .object(let r)? = row else { return nil }
        let id = text(r["id"]), name = text(r["name"])
        guard !id.isEmpty, !name.isEmpty else { return nil }
        func list(_ key: String) -> [String] {
            guard case .array(let items)? = r[key] else { return [] }
            return items.map(text).filter { !$0.isEmpty }
        }
        return Report(id: id, name: name, fields: list("fields"), statusIn: list("statusIn"),
                      from: tenUnits(text(r["from"])), to: tenUnits(text(r["to"])))
    }

    /// What is really on the settings, with the junk dropped and the first of
    /// any repeated id kept.
    public static func all(settings: [String: JSONValue]) -> [Report] {
        guard case .array(let rows)? = settings["savedReports"] else { return [] }
        var out: [Report] = []
        var seen: Set<String> = []
        for row in rows {
            guard let r = clean(row), !seen.contains(r.id) else { continue }
            seen.insert(r.id)
            out.append(r)
        }
        return out
    }

    /// Keep a report under a name.
    ///
    /// Saving under a name the shop already used REPLACES it, in place, keeping
    /// its id and its position. That is what "save" means to the person doing
    /// it — they are correcting the report they just ran, not filing a second
    /// one — and it is the difference between a list a shop prunes and a list a
    /// shop abandons.
    ///
    /// `id` is used only if this is a new one; callers own uniqueness.
    public static func add(_ list: [JSONValue], spec: [String: JSONValue],
                           id: String) -> [Report] {
        let current = list.compactMap(clean)
        let name = text(spec["name"])
        guard !name.isEmpty else { return current }
        // `.toLowerCase()` on both sides, so "Monthly VAT" and "monthly vat"
        // are one report rather than two.
        let at = current.firstIndex { $0.name.lowercased() == name.lowercased() }

        // `clean({ id, name, ...spec })` — THE SPREAD COMES LAST, so an `id` or
        // a `name` inside the spec wins over the two computed above. Worth
        // keeping rather than tidying: a caller that passes an id in the spec
        // is choosing one, and the two apps must choose the same way.
        var fields: [String: JSONValue] = [
            "id": .string(at == nil ? text(.string(id)) : current[at!].id),
            "name": .string(name),
        ]
        for (key, value) in spec { fields[key] = value }
        guard let row = clean(.object(fields)) else { return current }

        guard let at else { return current + [row] }
        var next = current
        next[at] = row
        return next
    }

    /// Drop one. An unknown id is not an error — two windows can remove the
    /// same report.
    public static func remove(_ list: [JSONValue], id: String) -> [Report] {
        let wanted = text(.string(id))
        return list.compactMap(clean).filter { $0.id != wanted }
    }

    /// Find one to load back into the builder.
    public static func find(_ list: [JSONValue], id: String) -> Report? {
        let wanted = text(.string(id))
        return list.compactMap(clean).first { $0.id == wanted }
    }

    /// A report as the book stores it, for handing back to `add`/`remove`.
    public static func encode(_ report: Report) -> JSONValue {
        .object(["id": .string(report.id), "name": .string(report.name),
                 "fields": .array(report.fields.map(JSONValue.string)),
                 "statusIn": .array(report.statusIn.map(JSONValue.string)),
                 "from": .string(report.from), "to": .string(report.to)])
    }
}
