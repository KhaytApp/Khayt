import Foundation
import SwiftUI

/// One job in the shop's book.
///
/// Decoded leniently on purpose. This store is written by the Electron app, and
/// a newer build will put fields here that this app has never heard of; a
/// stricter decoder would drop whole orders over a field it does not use. It is
/// also genuinely loose data: `clientId`, `dueDate` and `paymentMethod` are all
/// null across every order in the seed store, `price` arrives as an integer
/// where `costBasis` arrives as a double, and `priority` is a bool.
extension DateFormatter {
    /// Today, as the SHOP would write it: `yyyy-MM-dd` in the machine's own
    /// time zone.
    ///
    /// Not UTC. A projection made at one in the morning in Riyadh is dated
    /// today, not yesterday — the same trap that once put a purchase on the
    /// wrong day, and the reason `Order.dayFormatter` beside this one is
    /// deliberately UTC: it PARSES a stored date, which is written in UTC,
    /// while this one WRITES a date a person will read.
    static let shopDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

struct Order: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let date: String
    let status: String
    let project: String
    let client: String
    let currency: String
    let price: Double
    let paidAmount: Double
    let costBasis: Double
    let paymentStatus: String
    /// How the last payment arrived. Optional because an unpaid job has no
    /// answer, and "cash" is a claim rather than a default.
    let paymentMethod: String?
    let printTime: Double
    let priority: Bool
    /// 'normal' | 'high' | 'urgent'. Optional because an older record carries
    /// only the boolean above — `Shop.priorityOf` reads the pair.
    let priorityLevel: String?
    let notes: String
    let machineId: String?
    /// The customer's row in `clients`, when the job was linked to one. Absent
    /// on a job taken for a walk-in, and on every job in a shop that has never
    /// used the customer screen.
    let clientId: String?
    /// The catalogue product this job is for, when it was taken from one.
    ///
    /// What the catalogue counts to say a product has been made 14 times and
    /// earned 6,300 — and what `lib/product-docs.js` follows to put the right
    /// assembly sheet in the box. Absent on a job somebody typed out.
    let productId: String?
    let completedAt: String?
    let deliveredAt: String?
    /// When the parcel left the shop. A shipped job is still `completed`;
    /// see `Stage.of` and `lib/order-status.js`.
    let shippedAt: String?
    let dueDate: String?
    let parts: [Part]
    /// The payment plan written on this job, in the order it is collected.
    /// Empty on the great majority of jobs — a plan is something a shop sets up
    /// deliberately, for a customer paying over months.
    let instalments: [PlanRow]
    /// The cash the order held when the plan was generated. See
    /// `collectionTotals` in `lib/payment-plan.js`: without it, collecting a
    /// row either destroys the deposit or leaves it outstanding forever.
    /// Absent on a hand-built plan, and on every plan made before Sep 2026.
    let instalmentBase: Double?

    private enum CodingKeys: String, CodingKey {
        case id, date, status, project, client, currency, price, paidAmount, costBasis
        case paymentStatus, paymentMethod, printTime, priority, priorityLevel, notes
        case machineId, clientId, productId, completedAt, deliveredAt, shippedAt, dueDate, parts
        case instalments, instalmentBase
    }

    /// THREE FIELDS A NEW JOB HAS NOT GOT YET.
    ///
    /// `client` is the customer's name denormalised onto the order, and Khayt's
    /// own calculator never writes it — only the paths that already know the
    /// name do. `currency` is absent when the job is in the shop's own. And
    /// `costBasis` is not fixed until the job is COMPLETED, which is the whole
    /// point of it: what a job cost is settled once, when it is finished.
    ///
    /// Decoded strictly, every job Khayt's calculator created was skipped by
    /// this app — silently, because a row that will not decode is counted and
    /// not shown. It never surfaced because this Mac's own book was written
    /// entirely by Bed Ready's job creator, which does set `client`.
    ///
    /// So they are defaulted rather than required. Everything else stays strict:
    /// a row missing an `id` or a `price` is a row this app should refuse rather
    /// than guess at.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        status = try c.decode(String.self, forKey: .status)
        project = try c.decode(String.self, forKey: .project)
        client = try c.decodeIfPresent(String.self, forKey: .client) ?? ""
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? ""
        price = try c.decode(Double.self, forKey: .price)
        paidAmount = try c.decode(Double.self, forKey: .paidAmount)
        costBasis = try c.decodeIfPresent(Double.self, forKey: .costBasis) ?? 0
        paymentStatus = try c.decode(String.self, forKey: .paymentStatus)
        paymentMethod = try c.decodeIfPresent(String.self, forKey: .paymentMethod)
        printTime = try c.decode(Double.self, forKey: .printTime)
        priority = try c.decode(Bool.self, forKey: .priority)
        priorityLevel = try c.decodeIfPresent(String.self, forKey: .priorityLevel)
        notes = try c.decode(String.self, forKey: .notes)
        machineId = try c.decodeIfPresent(String.self, forKey: .machineId)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
        productId = try c.decodeIfPresent(String.self, forKey: .productId)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        deliveredAt = try c.decodeIfPresent(String.self, forKey: .deliveredAt)
        shippedAt = try c.decodeIfPresent(String.self, forKey: .shippedAt)
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
        instalments = try c.decodeIfPresent([PlanRow].self, forKey: .instalments) ?? []
        instalmentBase = try c.decodeIfPresent(Double.self, forKey: .instalmentBase)
    }

    /// One payment of a plan, as Khayt writes it.
    ///
    /// `paid` is the flag the shop sets and every reader honours; `paidAt` is
    /// the day it was collected, and is a RECORD rather than the truth — a row
    /// with `paid` false and a `paidAt` on it is not collected. Written this way
    /// by `renderer/order-flows.js`, which is why it is read this way here.
    struct PlanRow: Decodable, Hashable, Identifiable, Sendable {
        /// Minted by whichever app created the plan. Defaulted because a row
        /// typed into an older build has none, and a plan that will not decode
        /// is a plan this app would silently drop on the next save.
        let id: String
        let amount: Double
        /// 'YYYY-MM-DD'. Empty on a row a shop added and has not dated yet.
        let dueDate: String
        let note: String
        let paid: Bool
        let paidAt: String?

        private enum CodingKeys: String, CodingKey { case id, amount, dueDate, note, paid, paidAt }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
            dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            paid = try c.decodeIfPresent(Bool.self, forKey: .paid) ?? false
            paidAt = try c.decodeIfPresent(String.self, forKey: .paidAt)
        }

        init(id: String, amount: Double, dueDate: String, note: String = "",
             paid: Bool = false, paidAt: String? = nil) {
            self.id = id; self.amount = amount; self.dueDate = dueDate
            self.note = note; self.paid = paid; self.paidAt = paidAt
        }
    }

    struct Part: Decodable, Hashable, Identifiable, Sendable {
        /// A part written by Khayt's calculator HAS NO ID — `snapshotPartFromForm`
        /// does not mint one, and only the paths that build parts some other way
        /// do. Every part in this Mac's own book has one, which is why requiring
        /// it never surfaced: the book was written by Bed Ready's job creator.
        ///
        /// Defaulted rather than required, and the list that draws them is keyed
        /// by position so a fresh value on each read cannot churn the rows.
        let id: String
        let name: String
        let material: String
        let qty: Int
        let printWeight: Double
        let unitCost: Double
        let colour: String
        /// The library model this part was printed from, when the job was made
        /// by picking one. Absent on a job auto-logged from a printer's own
        /// history, which knows a filename and nothing about the library.
        let printFileId: String?
        /// THE NAME THE PRINTER KNOWS THIS PART BY.
        ///
        /// A machine's completion carries a gcode filename and nothing else, so
        /// this is the only honest link between an order and the figures a
        /// printer reported for it — `renderer/order-flows.js` matches on
        /// exactly this field. Absent on a job that was never sent to a
        /// machine, which is why the caller falls back to the newest completion
        /// and the sheet names which print it is offering.
        let fileRef: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, material, qty, printWeight, unitCost, colour, printFileId, fileRef
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            material = try c.decodeIfPresent(String.self, forKey: .material) ?? ""
            qty = try c.decodeIfPresent(Int.self, forKey: .qty) ?? 1
            printWeight = try c.decodeIfPresent(Double.self, forKey: .printWeight) ?? 0
            unitCost = try c.decodeIfPresent(Double.self, forKey: .unitCost) ?? 0
            colour = try c.decodeIfPresent(String.self, forKey: .colour) ?? ""
            printFileId = try c.decodeIfPresent(String.self, forKey: .printFileId)
            fileRef = try c.decodeIfPresent(String.self, forKey: .fileRef)
        }
    }

    /// What the shop is still owed — `lib/order-money.js`'s answer, resolved
    /// once per load by `Shop` and stored here so a table can sort on it.
    ///
    /// This USED to be the Swift subtraction below, and the comment above it
    /// claimed money was not a Swift opinion while being exactly that. It is
    /// short by a credit note and by a gift card: a job priced at 1,000 with a
    /// 300 credit note read as 1,000 still owed on the Mac and 700 in Khayt,
    /// in the title bar, the customers table and on the card. Neither book on
    /// this machine has either field, which is why nothing showed.
    var owedResolved: Double?

    /// The shared answer when there is one, and a subtraction when there is
    /// not. A dead engine must not blank the money column — but it is the LAST
    /// resort, and it is wrong in the two ways above.
    var owed: Double { owedResolved ?? max(0, price - paidAmount) }

    var isSettled: Bool { owed < 0.005 }

    /// Whether the attention engine calls this job late, resolved once per
    /// load by `Shop` — the same answer the dashboard's Late tile shows.
    var isLateResolved: Bool?

    /// Late, as the badges and the title bar report it.
    ///
    /// The fallback below was the whole rule until now: "not settled and past
    /// its due date". That is a DIFFERENT QUESTION — a job completed and
    /// delivered is not late because its invoice is unpaid, and a quote has no
    /// deadline to miss — and it answers much larger. On the sample book it
    /// said eleven where `attention` says two, and both numbers were on screen
    /// at once: the badges from this, the dashboard's tile from the engine.
    ///
    /// Kept only for a dead engine. Absent, unparseable and future dates all
    /// mean "not overdue" there: a red badge on a job that is fine is worse
    /// than no badge at all.
    func isOverdue(now: Date = Date()) -> Bool {
        if let isLateResolved { return isLateResolved }
        guard !isSettled, let due = Self.day(dueDate) else { return false }
        return due < now
    }

    var day: Date? { Self.day(date) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        // Both shapes are in the store: "2026-08-08" and a full ISO timestamp.
        if let d = dayFormatter.date(from: String(s.prefix(10))) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}

/// The statuses Khayt uses, in the order a job moves through them.
///
/// Taken from `lib/order-progress.js`, which is bundled into KhaytCore — the
/// sidebar's order is the pipeline's order, not alphabetical and not whatever
/// the data happened to contain.
enum Stage: String, CaseIterable, Identifiable, Sendable {
    // In the order work moves through them, which is also the order the board
    // and the sidebar draw. `on_hold` sits between pending and printing because
    // that is where a job stops: nothing is held before it is accepted.
    case quote, pending, on_hold, printing, post, qc, completed, shipped, delivered, cancelled

    var id: String { rawValue }

    /// Khayt's own word for each stage, so the two apps call one thing one
    /// thing. `cancelled` is the exception: the shared catalogue has no word for
    /// it, so the Mac app's own is used and marked as such in `Words.own`.
    var key: String {
        switch self {
        case .quote: "queue.quote"
        case .pending: "queue.pending"
        case .on_hold: "queue.on_hold"
        case .printing: "queue.printing"
        case .post: "queue.post"
        case .qc: "queue.qc"
        case .completed: "queue.completed"
        case .shipped: "queue.shipped"
        case .delivered: "queue.delivered"
        case .cancelled: "mac.cancelled"
        }
    }

    /// The stages a job can be sent to from a menu, in the order work moves
    /// through them.
    ///
    /// `on_hold` is not among them because it asks a question first, and
    /// `delivered` is not because it is not a stage: handing a job over stamps
    /// a date on a completed one. Both have their own item wherever this list
    /// is offered.
    ///
    /// One list, read by the Job menu in the menu bar, the right-click menu on
    /// the orders table, and the right-click menu on a board card. Which of
    /// them a move was started from must not change where a job can go.
    static let destinations: [Stage] = [.quote, .pending, .printing, .post, .qc, .completed]

    /// SF Symbols, not emoji. The Electron app puts a coloured emoji next to
    /// almost every label, and it is a large part of why it reads as a web page:
    /// emoji do not take the text colour, do not thin at small sizes, and do not
    /// match the rest of the system.
    var symbol: String {
        switch self {
        case .quote: "doc.text"
        case .pending: "clock"
        case .on_hold: "pause.circle"
        case .printing: "printer"
        // Washing, curing, sanding — the work after the printer stops.
        case .post: "sparkles"
        // Inspection, not approval: a job in QC is being looked at.
        case .qc: "magnifyingglass"
        case .completed: "checkmark.circle"
        // In the post: the parcel is moving, and that is the whole difference
        // between this and the box sitting finished on the bench.
        case .shipped: "box.truck"
        case .delivered: "shippingbox"
        case .cancelled: "xmark.circle"
        }
    }

    /// The colour of this stage, where the palette already has a word for it.
    ///
    /// ── WHY MOST STAGES RETURN NIL ────────────────────────────────────────
    ///
    /// Nine stages given nine colours is a rainbow, and a rainbow is what a
    /// colour scheme looks like when it has stopped meaning anything — the
    /// same mistake, from the opposite direction, as the amber that was on
    /// forty-eight unrelated things before `Palette.swift` was written.
    ///
    /// So only the four that `Palette.swift` already defines in words get one,
    /// and they get exactly the colour that definition names. Quote, pending,
    /// post-processing and QC are the ordinary course of a job — nothing about
    /// them is news, and they stay the colour of ordinary text. If a stage
    /// here ever needs a fifth colour, the question to answer first is which
    /// sentence in the palette it is an instance of.
    var tint: Color? {
        switch self {
        // "Something is being made right now" — the drop of filament in the
        // app's own icon, and the one state worth looking up at.
        case .printing: Khayt.hot
        // "Wants a person, and will keep working if it does not get one" — a
        // held job is precisely that, and nothing else on this list is.
        case .on_hold: Khayt.attention
        // "Finished, paid, sent, agreed." — the palette's own sentence names
        // sent, so a shipped job belongs here rather than in a fifth colour.
        case .completed, .shipped, .delivered: Khayt.done
        // "Late, failed, refused."
        case .cancelled: Khayt.late
        case .quote, .pending, .post, .qc: nil
        }
    }

    /// The columns the board draws, in the order work moves through them.
    ///
    /// Here rather than inside the view because `board` is keyed by EVERY stage
    /// — the dictionary is the whole book grouped, and the screen chooses. Two
    /// places deciding which stages are "on the board" is how a test comes to
    /// agree with a list nobody is looking at.
    ///
    /// Delivered and cancelled are off it on purpose: they are where work goes
    /// to stop being work, and a column of two hundred delivered jobs buries the
    /// four that need doing.
    ///
    /// SHIPPED IS ON IT, and the difference is whether anyone might still have
    /// to do something. A parcel in the post can go missing, sit at a depot, or
    /// need chasing; a delivered one is finished with. The board is for work in
    /// flight, and a job with a courier still is.
    static let boardColumns: [Stage] = [.quote, .pending, .on_hold, .printing, .post, .qc, .completed, .shipped]

    /// The way work actually goes, for "move it along" and "move it back".
    ///
    /// `boardColumns` WITHOUT `on_hold`, and that is the whole point of having
    /// a second list: hold sits between pending and printing on the board
    /// because that is where a held job is easiest to find, but it is a
    /// detour, not a step. A shop pressing "move along" on a pending job means
    /// "start printing it", and stepping it into hold instead would be the app
    /// misreading a plain instruction.
    ///
    /// A job that IS on hold has no "along" here on purpose — where it goes
    /// back to is a decision, and the same menu lists every stage by name.
    static let progression: [Stage] = boardColumns.filter { $0 != .on_hold }

    /// The next stage along, or nil at either end — and nil for a job on hold.
    func stepped(by delta: Int) -> Stage? {
        guard let at = Self.progression.firstIndex(of: self) else { return nil }
        let next = at + delta
        guard next >= 0, next < Self.progression.count else { return nil }
        return Self.progression[next]
    }

    /// The stage a job is in, or nil for a status this app has no column for.
    ///
    /// DELIVERED IS NOT A STATUS. A handed-over job stays `completed` and
    /// carries a `deliveredAt`; that pair is what Khayt's own board reads, and
    /// reading `status` alone filed every delivered job under Completed here.
    /// The rule is `KhaytOrderStatus.stageOf` — mirrored rather than called
    /// because it is two comparisons on a decoded row and this runs per cell,
    /// and `StageParityTests` runs the shared one against it.
    ///
    /// Nil is not "no stage" — it is a job that will not appear on the board, so
    /// every caller has to decide what to do about it rather than filtering it
    /// away. `split` reaches here: a parent order replaced by the sub-orders
    /// that carry its price between them.
    static func of(_ order: Order) -> Stage? {
        // Delivered first: it is the later of the two, so a parcel that has
        // arrived is delivered rather than still in the post.
        if order.status == "completed", order.deliveredAt != nil { return .delivered }
        if order.status == "completed", order.shippedAt != nil { return .shipped }
        return Stage(rawValue: order.status)
    }
}
