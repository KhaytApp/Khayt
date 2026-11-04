import Foundation

/// The reference a PERSON reads for a job.
///
/// Since ids became unique across computers (lib/order-new.js `mintOrderId`),
/// a new job's id is `INV-2026-0042-k7qx`: the readable number and a random
/// tag that only exists so two computers can never key two jobs alike. The
/// readable half is stored as `jobNumber`, and that is what every screen,
/// list and page shows. A job made before has no `jobNumber`; its id IS its
/// number. The id stays the key for every lookup, link and write.
///
/// The desktop's rule is `jobRef` (lib/order-new.js); this is the same rule.
public enum JobReference {
    public static func of(_ row: [String: JSONValue]) -> String {
        if case .string(let n)? = row["jobNumber"], !n.isEmpty { return n }
        if case .string(let id)? = row["id"] { return id }
        return ""
    }
    public static func of(_ row: JSONValue) -> String {
        if case .object(let o) = row { return of(o) }
        return ""
    }
}
