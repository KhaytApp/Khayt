import Foundation

/// How much of a shop's book a phone actually carries.
///
/// ── WHY NOT ALL OF IT ──────────────────────────────────────────────────────
///
/// The first version of the companion's book was the whole store, and on the
/// sample shop that looks harmless: 163 KB. The sample is a demo with 42 orders
/// in it. The shape is what matters, and the shape is that `printLog` is 51% of
/// that book and `printFiles` another 24% — three quarters of it is HISTORY. At
/// roughly 2 KB an order, a shop doing twenty a week is carrying several
/// megabytes of it after three years, against the 50 MB ceiling every backup is
/// built to hold.
///
/// None of that history is on a phone screen. The companion reads six things —
/// the queue, recent orders, clients, inventory, machines and the waiting list —
/// and that is not a guess about what it might want: it is the complete list of
/// what `KhaytAPIClient` has ever asked the desktop for. It has never fetched a
/// print file, a product, an expense or an audit line, and a phone at the
/// machines needs today's queue, not 2023's invoices.
///
/// So the phone takes a working set and leaves the rest on the Mac, where it
/// already lives and is already backed up.
///
/// ── THE RULE IS DECLARED ONCE ──────────────────────────────────────────────
///
/// This type is in KhaytCore because both ends need it and they must not
/// disagree. The Mac reads it to decide what to send; the phone reads it to know
/// what it is supposed to have. Two lists would drift, and the way that failure
/// shows up is a screen that is quietly missing rows on one device only.
public enum BookScope {

    /// An order stops being work and becomes history at one of these. Anything
    /// else is live and travels whatever its age — a job that has been stuck in
    /// QC for two months is still in the shop, and a phone that dropped it
    /// because it was old would be hiding the very thing somebody is chasing.
    ///
    /// `cancelled` is here and is NOT in the desktop's `STATUSES` list in
    /// `renderer/analytics.js`; it is in shipping books all the same. Treating
    /// an unknown status as live is the safe direction — it travels when it did
    /// not have to, rather than vanishing when it mattered.
    public static let finished: Set<String> = ["completed", "shipped", "delivered", "cancelled"]

    /// How much of one collection travels.
    public enum Slice: Sendable, Equatable {
        /// Every record, up to a ceiling that exists only so a pathological book
        /// cannot hand a phone something it has no business holding.
        case whole(cap: Int)
        /// Every unfinished order, plus the newest `n` finished ones.
        case openPlusNewest(Int)
    }

    /// What a phone carries, and nothing else.
    ///
    /// The numbers are ceilings rather than targets. `printLog` at 200 finished
    /// orders is roughly 400 KB on the measurements above and comfortably more
    /// history than the Orders screen shows — it pages at 40.
    public static let workingSet: [(collection: String, slice: Slice)] = [
        ("printLog", .openPlusNewest(200)),
        ("clients", .whole(cap: 5_000)),
        ("inventory", .whole(cap: 5_000)),
        ("machines", .whole(cap: 500)),
        ("waitingList", .whole(cap: 1_000)),
    ]

    /// What a pull actually contained.
    ///
    /// Sent with the records, and kept by the phone beside its book, because a
    /// partial book that cannot say it is partial is worse than no book: a
    /// screen counting 200 orders would report a three-year-old shop as having
    /// done 200, and a sync that saw a record it did not hold could take its
    /// absence for a deletion.
    public struct Taken: Codable, Sendable, Equatable {
        public struct Held: Codable, Sendable, Equatable {
            /// True when the phone has every record the Mac has.
            public let whole: Bool
            public let sent: Int
            /// Present when `whole` is false: how many the Mac actually holds,
            /// so the phone can say "200 of 3,140" rather than "200".
            public let available: Int?

            public init(whole: Bool, sent: Int, available: Int?) {
                self.whole = whole; self.sent = sent; self.available = available
            }
        }

        public let collections: [String: Held]
        /// Named out loud rather than left to be inferred from absence. A phone
        /// asking "do I have expenses?" must get "no, they were not sent",
        /// never "no, there are none".
        public let omitted: [String]
        public let takenAt: String

        public init(collections: [String: Held], omitted: [String], takenAt: String) {
            self.collections = collections; self.omitted = omitted; self.takenAt = takenAt
        }

        /// Does this phone hold every record of `collection`?
        public func isWhole(_ collection: String) -> Bool {
            collections[collection]?.whole ?? false
        }
    }

    /// Cut a working set out of a whole book.
    ///
    /// `settings` always travels and is never counted as a collection: it is one
    /// object, not a list of records, and every figure the phone works out — the
    /// tax profile first — is computed from it. A book without it is a book the
    /// engine cannot price anything from.
    public static func take(from store: [String: JSONValue],
                            now: Date = Date()) -> (store: [String: JSONValue], taken: Taken) {
        var out: [String: JSONValue] = [:]
        var held: [String: Taken.Held] = [:]

        if let settings = store["settings"] { out["settings"] = settings }

        for (collection, slice) in workingSet {
            guard case .array(let rows)? = store[collection] else {
                // Absent on the Mac is not the same as withheld. Recording it as
                // whole-and-empty is the truth: the phone has everything there is.
                held[collection] = .init(whole: true, sent: 0, available: 0)
                out[collection] = .array([])
                continue
            }
            let kept: [JSONValue]
            switch slice {
            case .whole(let cap):
                kept = Array(rows.prefix(cap))
            case .openPlusNewest(let n):
                let open = rows.filter { !isFinished($0) }
                let closed = rows.filter { isFinished($0) }
                    .sorted { recency($0) > recency($1) }
                    .prefix(n)
                kept = open + closed
            }
            held[collection] = .init(whole: kept.count == rows.count,
                                     sent: kept.count,
                                     available: kept.count == rows.count ? nil : rows.count)
            out[collection] = .array(kept)
        }

        // Every collection the book has that the phone is not getting.
        let omitted = store.keys
            .filter { $0 != "settings" && held[$0] == nil }
            .sorted()

        return (out, Taken(collections: held, omitted: omitted, takenAt: StoreWriter.iso(now)))
    }

    static func isFinished(_ row: JSONValue) -> Bool {
        guard case .object(let o) = row, case .string(let status)? = o["status"] else { return false }
        return finished.contains(status)
    }

    /// What sorts "newest" — the shop's own day stamp, with `updatedAt` behind
    /// it for a record that has none. Both are ISO-ish and compare as strings;
    /// `date` is "2026-07-02" and `updatedAt` is the full timestamp, so they are
    /// never compared against each other, only within their own kind.
    static func recency(_ row: JSONValue) -> String {
        guard case .object(let o) = row else { return "" }
        if case .string(let date)? = o["date"] { return date }
        if case .string(let updated)? = o["updatedAt"] { return String(updated.prefix(10)) }
        return ""
    }
}
