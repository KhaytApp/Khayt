import Foundation
import KhaytCore

/// How this Mac's book compares with what Khayt Cloud holds.
///
/// The question the sidebar's warning raises and could not answer: this app
/// does not sync, so *how far apart are they?* Counting is not merging — it
/// writes nothing on either side, and it turns "changes here reach the cloud
/// when Khayt next runs" into a number.
///
/// Compared BY ID and by `rev`, which is what sync itself compares. A record
/// with the same id and a higher rev here is an edit the cloud has not seen; a
/// higher rev there is one this Mac has not.
enum CloudCompare {

    struct Line: Identifiable, Hashable {
        var id: String { collection }
        let collection: String
        let here: Int
        let there: Int
        /// Records this Mac has that the cloud does not.
        let onlyHere: Int
        /// Records the cloud has that this Mac does not.
        let onlyThere: Int
        /// Same record, newer on this Mac.
        let newerHere: Int
        /// Same record, newer in the cloud.
        let newerThere: Int

        var agrees: Bool { onlyHere == 0 && onlyThere == 0 && newerHere == 0 && newerThere == 0 }
    }

    struct Result {
        let lines: [Line]
        /// The head revision the cloud reported.
        let cloudRev: Int
        /// How many encrypted changes came after the base, and how many records
        /// they wrote — shown, because "nineteen jobs are newer here" means one
        /// thing if the chain was folded and another entirely if it was not.
        var chain: Int = 0
        var applied: Int = 0
        var differing: [Line] { lines.filter { !$0.agrees } }
        var agrees: Bool { differing.isEmpty }
        /// Records this Mac could send: the ones the cloud has never seen, plus
        /// the ones it holds an older copy of. Deliberately NOT the whole
        /// difference — a record that is newer in the cloud is one this Mac is
        /// behind on, and behind is not something you send.
        var sendable: Int { lines.reduce(0) { $0 + $1.onlyHere + $1.newerHere } }
    }

    /// Every collection worth comparing — `ARRAY_COLLECTIONS` from
    /// `lib/store-validate.js`, read from the engine rather than listed again.
    static func compare(here: [String: JSONValue], there: [String: JSONValue],
                        collections: [String], cloudRev: Int,
                        chain: Int = 0, applied: Int = 0) -> Result {
        var lines: [Line] = []
        for name in collections {
            let mine = index(here[name], keyedByCollection: name == "tombstones")
            let theirs = index(there[name], keyedByCollection: name == "tombstones")
            // A collection neither side has is not a difference, and a line of
            // zeroes for each of thirty-one collections is a screen nobody
            // reads.
            if mine.isEmpty && theirs.isEmpty { continue }

            var onlyHere = 0, onlyThere = 0, newerHere = 0, newerThere = 0
            for (id, myRev) in mine {
                guard let theirRev = theirs[id] else { onlyHere += 1; continue }
                if myRev > theirRev { newerHere += 1 }
                else if theirRev > myRev { newerThere += 1 }
            }
            for id in theirs.keys where mine[id] == nil { onlyThere += 1 }

            lines.append(Line(collection: name, here: mine.count, there: theirs.count,
                              onlyHere: onlyHere, onlyThere: onlyThere,
                              newerHere: newerHere, newerThere: newerThere))
        }
        return Result(lines: lines, cloudRev: cloudRev, chain: chain, applied: applied)
    }

    /// `id` → `rev`, for one collection.
    ///
    /// A row with no id cannot be compared with anything and is skipped rather
    /// than counted as a difference — sync itself keys on the id, so a row
    /// without one was never going to travel.
    private static func index(_ value: JSONValue?,
                              keyedByCollection: Bool = false) -> [String: Double] {
        guard case .array(let rows)? = value else { return [:] }
        var out: [String: Double] = [:]
        for row in rows {
            guard case .object(let record) = row,
                  case .string(let id)? = record["id"], !id.isEmpty else { continue }
            // A TOMBSTONE'S ID IS NOT UNIQUE ON ITS OWN. It is the id of the
            // record that was deleted, so two tombstones for different
            // collections can share one — `keyOf` in lib/sync.js keys them
            // `collection:id` for exactly that reason, and keying on the id
            // alone would silently collapse two deletions into one.
            var key = id
            if keyedByCollection, case .string(let collection)? = record["collection"] {
                key = collection + ":" + id
            }
            var rev: Double = 0
            if case .number(let n)? = record["rev"] { rev = n }
            out[key] = rev
        }
        return out
    }
}
