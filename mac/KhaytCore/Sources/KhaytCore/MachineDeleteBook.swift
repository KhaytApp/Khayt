import Foundation

/// The book, cut down to what "may this printer be deleted?" reads.
///
/// ── WHY ───────────────────────────────────────────────────────────────────
///
/// `lib/machine-status.js canDelete` scans every collection in the book for a
/// record that names the machine, so it has to be asked about the whole book.
/// It was also HANDED the whole book: every field of every record, turned
/// into JSON text and parsed again on every reload. On a shop with 14,695
/// library models that was 26 MB and about a quarter of a second, to read one
/// field per record.
///
/// ── WHAT THE RULE READS, FROM ITS SOURCE ──────────────────────────────────
///
/// `canDelete(book, id)` and the `references` and `names` it calls read:
///
///   - `book.machines`, when it is an array: of each row that is an object,
///     `id`. Nothing else of a machine.
///   - every OTHER top-level value that is an array, except `tombstones`: of
///     each row that is an object, `machineId`, and the five nested lists
///     `parts`, `printRuns`, `setups`, `runs`, `attempts` when they are
///     arrays; of each of their rows that is an object, `machineId`.
///   - `book.printerCompletions` and `book.settings.printerCompletions`, when
///     they are objects (and not arrays): only WHETHER a key is there with a
///     value that is not null.
///
/// Nothing else. So this keeps exactly that and nothing more, and keeps the
/// SHAPE the rule tests for: a row that is not an object stays a non-object
/// (null), a row that is one stays one, an array stays an array of the same
/// length, and a value under `machineId` is passed as it is, whatever its
/// type, because the rule turns it into text itself.
///
/// The verdict is the JavaScript's own. This file decides nothing; it only
/// leaves out what the rule does not look at. `MachineDeleteBookTests` runs
/// the real `lib/machine-status.js` on a varied book both ways and fails if
/// one answer differs, so a field added to the rule without being added here
/// is caught there.
public enum MachineDeleteBook {

    /// The lists inside a record that can name a machine of their own
    /// (`NESTED` in the module).
    static let nested = ["parts", "printRuns", "setups", "runs", "attempts"]

    public static func trimmed(_ book: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (name, value) in book {
            switch value {
            case .array(let rows):
                // Skipped by the rule, and often the longest list in the book.
                if name == "tombstones" { continue }
                out[name] = .array(name == "machines" ? rows.map(machine) : rows.map(record))
            case .object(let inner):
                if name == "printerCompletions" {
                    out[name] = .object(presence(inner))
                } else if name == "settings", case .object(let kept)? = inner["printerCompletions"] {
                    out[name] = .object(["printerCompletions": .object(presence(kept))])
                }
            default:
                continue
            }
        }
        return out
    }

    /// A machine: only its id is compared.
    private static func machine(_ row: JSONValue) -> JSONValue {
        guard case .object(let m) = row else { return .null }
        if let id = m["id"] { return .object(["id": id]) }
        return .object([:])
    }

    /// Any other record: the machine it names, and the machines its parts,
    /// runs and setups name.
    private static func record(_ row: JSONValue) -> JSONValue {
        guard case .object(let r) = row else { return .null }
        var out: [String: JSONValue] = [:]
        if let id = r["machineId"] { out["machineId"] = id }
        for list in nested {
            guard case .array(let inner)? = r[list] else { continue }
            out[list] = .array(inner.map { item in
                guard case .object(let i) = item else { return .null }
                if let id = i["machineId"] { return .object(["machineId": id]) }
                return .object([:])
            })
        }
        return .object(out)
    }

    /// The finished-print cache: the rule asks only `o[id] != null`, so each
    /// entry is kept as "there" or as the null it was.
    private static func presence(_ cache: [String: JSONValue]) -> [String: JSONValue] {
        cache.mapValues { $0 == .null ? .null : .bool(true) }
    }
}
