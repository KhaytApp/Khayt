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
/// (October 2026: the phone's calculator and receipt scanner added the presets,
/// the consumables shelf, the suppliers and the RECENT expenses — each named
/// beside its entry in `workingSet` with the screen that reads it.)
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
        /// Every unfinished order, every finished one that may still owe money
        /// (`mayOwe`), plus the newest `n` of the rest.
        case openPlusNewest(Int)
        /// The newest `n` by the record's own day (`recency`), wherever in the
        /// list they sit. Newest-first is only a convention: a row folded in
        /// from a phone or an import can land anywhere, and a plain prefix
        /// would then miss a recent one.
        case newest(Int)
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
        // The shop's own WhatsApp wording. The phone's job update reads it
        // when present and falls back to Khayt's default words otherwise — so
        // without this a shop's templates never reached the phone (iOS
        // handoff, Oct 2026). Text only; nothing in it is a secret.
        ("waTemplates", .whole(cap: 200)),
        // The phone's calculator (Oct 2026): the shop's saved presets — the
        // seven figures a part is costed at — and the consumables shelf, so a
        // price worked out on the phone is the one the Mac would give.
        ("printers", .whole(cap: 200)),
        ("consumables", .whole(cap: 2_000)),
        // The phone's receipt scanner (`lib/zatca-qr.js`): suppliers to match
        // a receipt's seller by VAT number, and recent expenses so the same
        // receipt is not filed twice (`receiptRef`). Recent, not all: a
        // duplicate is a receipt scanned again soon after, and three years of
        // expenses is history no phone screen shows.
        ("suppliers", .whole(cap: 1_000)),
        ("expenses", .newest(1_000)),
        // The phone's Catalogue screen (Oct 2026): what the shop sells, at the
        // price the Mac shows (`KhaytEngine.catalogue`), with the small picture
        // each record carries as a data URI. A product is a few KB plus its
        // pictures' thumbnails; a shop's catalogue is hundreds, not thousands.
        // The full-size photos stay on the Mac, as files beside the book.
        ("products", .whole(cap: 2_000)),
        // The phone's printer care (Nov 2026): each machine's recurring
        // maintenance tasks (`lib/maintenance.js`), so the phone can say what
        // is due and tick it off. A shop has a dozen per printer, not thousands.
        ("machMaintTasks", .whole(cap: 2_000)),
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
            /// Present when an `openPlusNewest` cut left finished records
            /// behind: the latest `recency` of any record it left. Every
            /// record left behind is this old or older, so a period that starts
            /// after this day is held in full. Optional, so a scope from an
            /// older Mac still decodes (and then no period is known whole).
            public let keptAfter: String?

            public init(whole: Bool, sent: Int, available: Int?, keptAfter: String? = nil) {
                self.whole = whole; self.sent = sent; self.available = available
                self.keptAfter = keptAfter
            }
        }

        public let collections: [String: Held]
        /// Named out loud rather than left to be inferred from absence. A phone
        /// asking "do I have expenses?" must get "no, they were not sent",
        /// never "no, there are none".
        public let omitted: [String]
        public let takenAt: String
        /// Each machine's hours meter over the WHOLE book, by machine id —
        /// present only when `printLog` was cut. Maintenance is measured
        /// against the hours of every finished job (`hoursMeter` in
        /// `lib/maintenance.js`), and a phone holding the newest 200 would
        /// count fewer: a task would read less due than it is, and one ticked
        /// off there would record a meter so low the Mac shows it overdue again
        /// at once. Optional, so a scope from an older Mac still decodes.
        public let meters: [String: Double]?
        /// The same count over the jobs the cut HOLDS, at the same moment —
        /// present beside `meters`. The phone's meter is `meters` plus what its
        /// own count has grown by since: its count now less this. Measured
        /// against the baseline instead, a finished job that arrived by cloud
        /// change landed in both and never moved the meter. Optional, so a
        /// scope from an older Mac still decodes.
        public let metersHeld: [String: Double]?

        public init(collections: [String: Held], omitted: [String], takenAt: String,
                    meters: [String: Double]? = nil, metersHeld: [String: Double]? = nil) {
            self.collections = collections; self.omitted = omitted; self.takenAt = takenAt
            self.meters = meters
            self.metersHeld = metersHeld
        }

        /// Does this phone hold every record of `collection`?
        public func isWhole(_ collection: String) -> Bool {
            collections[collection]?.whole ?? false
        }
    }

    /// Fields a phone has no use for, taken off a record before it travels.
    ///
    /// A product's pictures and documents are FILES on the Mac (`products/`
    /// beside the book), and their paths name the Mac's user. The phone
    /// shows the small picture the record carries as a data URI, so
    /// `imagePath`, each image's `path` and `docs` stay behind. Applied by
    /// `take` and by the phone to every record a cloud change folds in, so
    /// a path never arrives by the side door either.
    public static let leftBehind: [String: Set<String>] = ["products": ["imagePath", "docs"]]

    public static func trimmed(_ record: JSONValue, in collection: String) -> JSONValue {
        guard collection == "products", case .object(var o) = record else { return record }
        for key in leftBehind[collection] ?? [] { o.removeValue(forKey: key) }
        if case .array(let images)? = o["images"] {
            o["images"] = .array(images.map { image in
                guard case .object(var i) = image else { return image }
                i.removeValue(forKey: "path")
                return .object(i)
            })
        }
        return .object(o)
    }

    /// `trimmed` over a whole book's working-set collections.
    public static func trimmed(_ store: [String: JSONValue]) -> [String: JSONValue] {
        var out = store
        for collection in leftBehind.keys {
            if case .array(let rows)? = store[collection] {
                out[collection] = .array(rows.map { trimmed($0, in: collection) })
            }
        }
        return out
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
            var keptAfter: String?
            switch slice {
            case .whole(let cap):
                kept = Array(rows.prefix(cap))
            case .openPlusNewest(let n):
                // Open work, and finished work that may still owe — whatever
                // its age. A customer's Owed on the phone is summed over the
                // jobs it holds; one old unpaid job left on the Mac made it
                // short with nothing on screen to say so.
                //
                // The owing set has its own ceiling: a shop that never records
                // payments has every finished job "may owe", and without one
                // the phone got the whole book. When it bites, the newest
                // owing jobs travel and keptAfter says the rest are older.
                let open = rows.filter { !isFinished($0) }
                let owing = rows.filter { isFinished($0) && mayOwe($0) }
                    .sorted { recency($0) > recency($1) }
                let closed = rows.filter { isFinished($0) && !mayOwe($0) }
                    .sorted { recency($0) > recency($1) }
                var leftNewest: [String] = []
                if owing.count > owingCap { leftNewest.append(recency(owing[owingCap])) }
                if closed.count > n { leftNewest.append(recency(closed[n])) }
                keptAfter = leftNewest.max()
                kept = open + owing.prefix(owingCap) + closed.prefix(n)
            case .newest(let n):
                kept = Array(rows.sorted { recency($0) > recency($1) }.prefix(n))
            }
            held[collection] = .init(whole: kept.count == rows.count,
                                     sent: kept.count,
                                     available: kept.count == rows.count ? nil : rows.count,
                                     keptAfter: kept.count == rows.count ? nil : keptAfter)
            out[collection] = .array(kept.map { trimmed($0, in: collection) })
        }

        // Every collection the book has that the phone is not getting.
        let omitted = store.keys
            .filter { $0 != "settings" && held[$0] == nil }
            .sorted()

        // The meters, only when the jobs were cut: a phone holding them all
        // counts them itself.
        var meters: [String: Double]?
        var metersHeld: [String: Double]?
        if held["printLog"]?.whole == false, case .array(let rows)? = store["printLog"] {
            meters = hoursByMachine(rows)
            if case .array(let kept)? = out["printLog"] { metersHeld = hoursByMachine(kept) }
        }

        return (out, Taken(collections: held, omitted: omitted, takenAt: StoreWriter.iso(now),
                           meters: meters, metersHeld: metersHeld))
    }

    /// `KhaytMaintenance.hoursMeter` for every machine at once: the print time
    /// of each finished job (`completed`, or the legacy `delivered`), summed
    /// per machine, never below zero. The phone's parity test runs this
    /// against the JavaScript.
    public static func hoursByMachine(_ rows: [JSONValue]) -> [String: Double] {
        var sums: [String: Double] = [:]
        for case .object(let o) in rows {
            guard case .string(let machine)? = o["machineId"],
                  o["status"] == .string("completed") || o["status"] == .string("delivered") else { continue }
            var t = 0.0
            switch o["printTime"] {
            case .number(let n)?: t = n.isFinite ? n : 0
            case .string(let s)?:
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                t = trimmed.isEmpty ? 0 : (Double(trimmed).flatMap { $0.isFinite ? $0 : nil } ?? 0)
            case .bool(let b)?: t = b ? 1 : 0
            default: t = 0
            }
            sums[machine, default: 0] += t
        }
        return sums.mapValues { max(0, $0) }
    }

    static func isFinished(_ row: JSONValue) -> Bool {
        guard case .object(let o) = row, case .string(let status)? = o["status"] else { return false }
        return finished.contains(status)
    }

    /// How many finished-but-may-owe jobs travel beyond the open ones.
    public static let owingCap = 1_000
    /// The highest sales-tax rate `mayOwe` allows for when a job has no
    /// stored payment status (KSA is 15%).
    public static let maxTaxOnTop = 0.25

    /// Could this finished job still owe the shop money?
    ///
    /// The shared rule decides what a job owes (`KhaytOrderMoney`), and it
    /// needs the engine, the settings and the currencies — none of which a cut
    /// has. So this errs towards keeping: a job that cannot owe at all
    /// (`PaymentTerms.owesAtAll`: a quote, a cancelled job, a voided or
    /// credited invoice) or that charges nothing does not, and a job owes
    /// nothing only when its own figures say it is paid in full AND its stored
    /// `paymentStatus` (`lib/order-payment.js` `statusOf`, which counts tax and
    /// credit notes) does not say otherwise. Anything else travels — up to
    /// `owingCap`, newest first. A heuristic: it can over-send, and past the
    /// cap it under-sends (and the scope says so through `keptAfter`).
    public static func mayOwe(_ row: JSONValue) -> Bool {
        guard case .object(let o) = row, PaymentTerms.owesAtAll(o) else { return false }
        func number(_ v: JSONValue?) -> Double {
            switch v {
            case .number(let n)?: return n.isFinite ? n : 0
            case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
            default: return 0
            }
        }
        let price = number(o["price"])
        guard price > 0.005 else { return false }
        let paid = number(o["paidAmount"]) + number(o["giftCardDiscount"])
        // The stored status was worked out against what was BILLED (tax and
        // credit notes included), so it decides when present — except a
        // "paid" that its own figures contradict (a price raised after the
        // status was stamped), which travels.
        if case .string(let status)? = o["paymentStatus"] {
            if status == "unpaid" || status == "partial" { return true }
            if status == "paid" { return paid + 0.005 < price }
        }
        // No status: compare against the price with room for tax on top. A
        // tax-on-top shop paid exactly `price` still owes the tax, and a cut
        // has no settings to know the rate, so this errs towards sending.
        return paid + 0.005 < price * (1 + maxTaxOnTop)
    }

    /// What sorts "newest": the latest of the job's own day (`date`) and the
    /// moments it was completed, delivered and last changed. A job booked in
    /// 2021 and finished last week is recent history, and ranking it by its
    /// booking day alone cut it first. A day ("2026-07-02") and a timestamp
    /// ("2026-07-02T09:00:00.000Z") compare as strings by day first, so the
    /// latest of them is the latest day.
    static func recency(_ row: JSONValue) -> String {
        guard case .object(let o) = row else { return "" }
        var latest = ""
        for key in ["date", "completedAt", "deliveredAt", "updatedAt"] {
            if case .string(let stamp)? = o[key], stamp > latest { latest = stamp }
        }
        return latest
    }
}
