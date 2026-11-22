import Foundation

/// Saving an edit without rewriting what the shop did not touch.
///
/// ── WHY A SHEET CANNOT BE TRUSTED TO READ BACK WHAT IT WROTE ─────────────
///
/// Every Mac editor reads a record into a draft and writes the draft back. A
/// draft is narrower than a book: a book is written by the other app, by older
/// builds, by the iOS companion, by cloud sync and by imports, and it holds
/// `2026-07-05T08:00:00.000Z` where a date picker writes `2026-07-05`, `"150"`
/// where a number field writes `150`, `null` where a text field writes `""`,
/// a `lifeUnit` this build has no menu item for, a colour name no swatch can
/// show. Whatever the draft could not hold, it wrote back as what it COULD —
/// and a shop that opened a printer and pressed Save lost a maintenance window
/// (Sep 2026, #1670).
///
/// Making every reader wide enough is necessary and never finished. What is
/// finished is this: an editor knows what it would have saved had nobody
/// touched anything — the BASELINE, the record put through its own open→save
/// mapping. Whatever the edit still has equal to the baseline was not edited,
/// so the stored value goes back, byte for byte. Only what the shop actually
/// changed is written in the editor's shape.
///
/// Applied per key, into nested objects, and into lists row by row, so
/// changing one field of a depreciation block does not re-spell the purchase
/// date beside it, and adding one price agreement does not re-spell the rest.
public enum RoundTrip {

    /// `written` with every value the editor did not change put back as
    /// `stored` holds it.
    ///
    /// - `written`: what the editor is about to save.
    /// - `baseline`: what the same editor saves for the stored record when
    ///   nothing is edited.
    /// - `stored`: the record as the book holds it.
    ///
    /// A key the edit and the baseline both leave out, but the book has, is
    /// the book's and goes back too: leaving it out was the editor's habit,
    /// not the shop's decision. A key the baseline has and the edit does not
    /// was taken away by the edit, and stays away.
    ///
    /// `fillingGaps`: a key the book does not have at all is written as the
    /// edit has it even when untouched. For the settings, whose shared rule
    /// fills a missing key with the default every reader assumes anyway (and
    /// marks the book as set up); never for a record, where a default the
    /// sheet invented — a 200 g reorder point, a 10-minute plug delay — is a
    /// figure the shop never gave.
    public static func keepUntouched(written: [String: JSONValue],
                                     baseline: [String: JSONValue],
                                     stored: [String: JSONValue],
                                     fillingGaps: Bool = false) -> [String: JSONValue] {
        var out = written
        for (key, value) in written {
            if fillingGaps, stored[key] == nil { continue }
            out[key] = merge(value, baseline: baseline[key], stored: stored[key], fillingGaps: fillingGaps)
        }
        for (key, value) in stored where written[key] == nil && baseline[key] == nil {
            out[key] = value
        }
        // `merge` hands back nil for a value that was absent from the book and
        // is unchanged by the edit; Swift's dictionary assignment of nil has
        // already removed it, which is what "absent" means.
        return out
    }

    /// The same, for any value. Nil means "not there" — the key is removed.
    public static func merge(_ written: JSONValue, baseline: JSONValue?,
                             stored: JSONValue?, fillingGaps: Bool = false) -> JSONValue? {
        guard let baseline else { return written }
        if written == baseline { return stored ?? (fillingGaps ? written : nil) }
        guard let stored else { return written }
        switch (written, baseline, stored) {
        case (.object(let w), .object(let b), .object(let s)):
            return .object(keepUntouched(written: w, baseline: b, stored: s, fillingGaps: fillingGaps))
        case (.array(let w), .array(let b), .array(let s)):
            return .array(rows(w, baseline: b, stored: s))
        default:
            return written
        }
    }

    /// A list, row by row.
    ///
    /// Rows carry no ids here as often as they do (a price agreement has none),
    /// so a row is matched by being EQUAL to a baseline row: a row the edit
    /// still has exactly as the editor would have written it untouched is the
    /// stored row it came from. That survives a row added or removed around
    /// it. Where the baseline dropped or merged rows the book has (a blank row
    /// the editor filters out), the baseline and the book no longer line up
    /// row for row, and the edited list is written as the editor made it.
    static func rows(_ written: [JSONValue], baseline: [JSONValue],
                     stored: [JSONValue]) -> [JSONValue] {
        guard baseline.count == stored.count else { return written }
        var used = Set<Int>()
        var out: [JSONValue] = []
        out.reserveCapacity(written.count)
        for (i, row) in written.enumerated() {
            if let j = baseline.indices.first(where: { !used.contains($0) && baseline[$0] == row }) {
                used.insert(j)
                out.append(stored[j])
                continue
            }
            // Same position, same length list: a row edited in place. Its
            // untouched fields go back.
            if written.count == baseline.count, !used.contains(i),
               case .object = row, case .object = baseline[i], case .object = stored[i],
               let merged = merge(row, baseline: baseline[i], stored: stored[i]) {
                used.insert(i)
                out.append(merged)
                continue
            }
            out.append(row)
        }
        return out
    }

    /// The input an edit hands a shared rule, narrowed to what was changed.
    ///
    /// For a rule that treats an absent key as "leave it alone" — the machine,
    /// spool and consumable editors, the settings panes — a key whose value is
    /// what the editor opened with is simply not sent.
    public static func changed(_ input: [String: JSONValue],
                               from opened: [String: JSONValue]) -> [String: JSONValue] {
        input.filter { key, value in opened[key] != value }
    }
}
