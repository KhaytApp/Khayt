import Foundation
import KhaytCore

/// How much of Khayt this shop sees on the phone: Simple or Professional.
///
/// ── THE PHONE FOLLOWS, IT DOES NOT CHOOSE ─────────────────────────────────
///
/// The mode is the shop's, set on the Mac and kept in the book as
/// `settings.mode`. The phone has no switch: it reads what the book says and
/// passes it on as it is, unnormalised, so the rule that reads it (KhaytCore's
/// `simpleSurface`) is the only place that decides what "enthusiast" or an
/// unknown word means. No book (paired live to an older desktop) and no mode
/// are Professional: everything shows, as it did before modes existed.
///
/// ── THE DECISION IS THE SHARED MAP'S ──────────────────────────────────────
///
/// What Simple gets of each surface is `lib/feature-tiers.js` `SIMPLE_MAP`,
/// one row per surface, agreed for the Mac, the iPhone and the desktop. This
/// keeps no copy of it. It asks the engine about the rows the phone draws
/// (`askedKeys`), once per book, and the screens read the answers. A key the
/// map does not have is answered nil by the engine and read here as `.full`
/// — showing everything is the safe failure — and `ShopModeTests` holds every
/// key here to the map's own list, so a renamed row fails a test instead.
struct ShopMode: Equatable, Sendable {

    /// `settings.mode` as the book holds it; nil when it holds none.
    let mode: String?
    private let surfaces: [String: KhaytEngine.SimpleSurface]

    /// No book, or a book with no mode: everything, as before.
    static let professional = ShopMode(mode: nil, surfaces: [:])

    /// The rows of the map the phone has a screen for.
    static let askedKeys = ["queue", "expenses", "machineUpkeep", "modeBadge",
                            "money", "inventory", "customers", "gatedLink"]

    /// Is the shop Simple? The engine's reading of the mode, not the phone's.
    var isSimple: Bool { KhaytEngine.isSimple(mode) }

    /// What this shop gets of one surface. `.full` for a key never asked or
    /// unknown to the map.
    func surface(_ key: String) -> KhaytEngine.SimpleSurface { surfaces[key] ?? .full }

    /// Is this surface drawn in its smaller form?
    func isReduced(_ key: String) -> Bool { surface(key) == .reduced }

    /// Is this surface Professional's alone (a link to it shows the gated card)?
    func isProfessionalOnly(_ key: String) -> Bool { surface(key) == .professionalOnly }

    /// The words for the badge beside the shop name.
    var badgeKey: String { isSimple ? "mode.simple" : "mode.professional" }

    /// The book's `settings.mode`, as it is: a string, or nil.
    static func mode(in book: [String: JSONValue]) -> String? {
        guard case .object(let settings)? = book["settings"],
              case .string(let mode)? = settings["mode"] else { return nil }
        return mode
    }

    /// Every asked row, answered by the engine for this mode.
    static func decide(mode: String?, engine: KhaytEngine) async -> ShopMode {
        var answers: [String: KhaytEngine.SimpleSurface] = [:]
        for key in askedKeys {
            // nil (no such row) and a failed call are both `.full`.
            if let answer = (try? await engine.simpleSurface(key, mode: mode)) ?? nil { answers[key] = answer }
        }
        return ShopMode(mode: mode, surfaces: answers)
    }
}

extension BookReader {
    /// The shop's mode and what it means for each screen; Professional when
    /// this phone holds no book.
    func shopMode() async -> ShopMode {
        guard holdsAnyBook, let store = try? wholeBook(), let engine = try? sharedEngine() else { return .professional }
        return await ShopMode.decide(mode: ShopMode.mode(in: store), engine: engine)
    }
}

/// Simple's four stages on the Orders board (SIMPLE_MAP `queue`: "4 stages:
/// Quote · Queued · Printing · Ready; on hold / QC / shipped shown as a note
/// on the card"). The phone calls Queued "Pending", the word its stage chips
/// and the Mac's board already use.
///
/// The filing is the board rule of the desktop's Simple board (`lib/order-status.js`
/// `simpleStageOf`, #2428, not yet on main) — a job's stage is not changed,
/// only which of the four it is filed under and the finer stage the card
/// notes. When that rule is on main and KhaytCore bridges it, this table
/// should become a call to it; `SimpleBoardTests` pins it to the same table.
enum SimpleBoard {
    enum Column: String, CaseIterable, Sendable {
        case quote, queued, printing, ready
    }

    struct Filing: Equatable, Sendable {
        let column: Column
        /// The real stage, when it is finer than the column: `on_hold`,
        /// `post`, `qc`, `shipped` or `delivered`. The card says it in a note.
        let note: String?
    }

    /// The stage a job is really at: a completed job with a delivery or
    /// shipping stamp is delivered or shipped (`lib/order-status.js` `stageOf`).
    static func stage(status: String, shipped: Bool, delivered: Bool) -> String {
        if status == "completed" && delivered { return "delivered" }
        if status == "completed" && shipped { return "shipped" }
        return status
    }

    /// Which column a job is filed under, or nil when it is not on the board
    /// (cancelled, failed, unknown) — as in Professional.
    static func filing(status: String, shipped: Bool = false, delivered: Bool = false) -> Filing? {
        switch stage(status: status, shipped: shipped, delivered: delivered) {
        case "quote": return Filing(column: .quote, note: nil)
        case "pending", "split": return Filing(column: .queued, note: nil)
        case "on_hold": return Filing(column: .queued, note: "on_hold")
        case "printing": return Filing(column: .printing, note: nil)
        case "post": return Filing(column: .printing, note: "post")
        case "qc": return Filing(column: .printing, note: "qc")
        case "completed": return Filing(column: .ready, note: nil)
        case "shipped": return Filing(column: .ready, note: "shipped")
        case "delivered": return Filing(column: .ready, note: "delivered")
        default: return nil
        }
    }

    /// One card on the board: the job, and where it is filed.
    struct Row: Identifiable, Equatable, Sendable {
        let order: QueueOrder
        let filing: Filing
        var id: String { order.id }
        static func == (a: Row, b: Row) -> Bool { a.order.id == b.order.id && a.filing == b.filing }
    }

    /// The most Ready cards drawn, newest first (the desktop's
    /// `SIMPLE_COLUMN_CAP`, the Mac's `Kanban.columnCap`).
    static let readyCap = 120

    /// The board: every job this phone holds that one of the four columns
    /// files, Quote, Pending, Printing then Ready. Live work keeps the
    /// queue's own order and record (`queue`, the shared queue rule's), so a
    /// card is the same card Professional draws; the rest come from the book,
    /// newest first. A voided job is finished and on no board.
    static func rows(queue: [QueueOrder], book: [OrderLogEntry]) -> [Row] {
        var seen = Set<String>()
        var byColumn: [Column: [Row]] = [:]
        for order in queue {
            guard let f = filing(status: order.status), seen.insert(order.id).inserted else { continue }
            byColumn[f.column, default: []].append(Row(order: order, filing: f))
        }
        let newest = book.enumerated().sorted { a, b in
            let da = a.element.date ?? "", db = b.element.date ?? ""
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
        for entry in newest where !entry.isVoided {
            guard let f = filing(status: entry.status, shipped: entry.shippedAt?.present == true,
                                 delivered: entry.deliveredAt?.present == true),
                  seen.insert(entry.id).inserted else { continue }
            byColumn[f.column, default: []].append(Row(order: QueueOrder(entry: entry), filing: f))
        }
        if let ready = byColumn[.ready], ready.count > readyCap { byColumn[.ready] = Array(ready.prefix(readyCap)) }
        return Column.allCases.flatMap { byColumn[$0] ?? [] }
    }

    /// A column's word: the stage words the phone already uses, and "Ready".
    static func title(_ column: Column) -> String {
        column == .ready ? L10n.tr("simple.stage.ready") : L10n.tr("stage.short.\(toneStatus(column))")
    }

    /// The finer stage a card notes ("In QC", "On hold", "Shipped").
    static func noteText(_ note: String) -> String { L10n.tr("simple.note.\(note)") }

    /// The status a column's colour and icon are drawn from.
    static func toneStatus(_ column: Column) -> String {
        switch column {
        case .quote: return "quote"
        case .queued: return "pending"
        case .printing: return "printing"
        case .ready: return "completed"
        }
    }
}

/// This month's spending, for the line under the Expense sheet in Simple
/// (SIMPLE_MAP `expenses`: "a short list: add an expense, this month's total").
enum MonthSpend {
    struct Total: Equatable, Sendable {
        let amount: Double
        let count: Int
    }

    /// The expenses dated in `now`'s Gregorian month, summed NET of the tax a
    /// registered shop reclaims — `ExpenseCategories.byCategory`, the rule the
    /// P&L and the category chart share. Nil when the book holds no
    /// `expenses` at all: a line saying 0 would be a claim the phone cannot make.
    static func total(in store: [String: JSONValue], reclaimsTax: Bool, now: Date = Date(),
                      calendar: Calendar = .gregorianHere) -> Total? {
        guard case .array(let rows)? = store["expenses"] else { return nil }
        let parts = calendar.dateComponents([.year, .month], from: now)
        guard let year = parts.year, let month = parts.month else { return nil }
        let prefix = String(format: "%04d-%02d-", year, month)
        let these = rows.filter {
            guard case .object(let e) = $0, case .string(let day)? = e["date"] else { return false }
            return day.hasPrefix(prefix)
        }
        return Total(amount: ExpenseCategories.byCategory(these, reclaimsTax: reclaimsTax).total, count: these.count)
    }
}

extension Calendar {
    /// Gregorian, in this phone's time zone: the shop's month as its wall
    /// calendar has it, whatever calendar the phone is set to.
    static var gregorianHere: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }
}
