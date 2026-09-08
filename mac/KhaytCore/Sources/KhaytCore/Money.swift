import Foundation

/// A shop's tax setup, as `lib/tax.js` models it.
///
/// Thirty country presets, in two modes. `inclusive` means the price a shop
/// types already contains the tax — true in the Gulf and most of Europe;
/// `exclusive` means it is added on top, as in the US and Canada. Getting that
/// backwards understates the tax due on every American and Canadian shop, so it
/// is a first-class part of the type rather than a flag someone might miss.
public struct TaxProfile: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case inclusive, exclusive }

    public struct Rate: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let percent: Double
        public let compound: Bool?
        public init(id: String, label: String, percent: Double, compound: Bool? = nil) {
            self.id = id; self.label = label; self.percent = percent; self.compound = compound
        }
    }

    public let name: String
    public let mode: Mode
    public let registration: String
    public let rates: [Rate]

    /// Memberwise, so a screen can build the profile a draft describes and ask
    /// what a price of 100 would be invoiced as before anything is saved.
    public init(name: String, mode: Mode, registration: String, rates: [Rate]) {
        self.name = name; self.mode = mode; self.registration = registration; self.rates = rates
    }

    /// The combined percentage across every rate.
    public var totalPercent: Double { rates.reduce(0) { $0 + $1.percent } }
    /// A shop with no rate is not registered, whatever else is configured.
    public var isRegistered: Bool { totalPercent > 0 }
}

/// A price split into what the shop keeps and what it merely collects.
public struct TaxSplit: Codable, Sendable, Equatable {
    public let subtotal: Double
    public let taxTotal: Double
}

/// One dated instalment.
public struct Installment: Codable, Sendable, Equatable {
    public let dueDate: String
    public let amount: Double
    public let paidAt: String?
}

/// The money a job's price, deposit and credit notes divide into when it is
/// split across machines.
public struct SplitShare: Codable, Sendable, Equatable {
    public let price: Double
    public let paidAmount: Double
    public let credited: Double
}

/// Everything a quote resolves to.
public struct QuoteTotal: Codable, Sendable, Equatable {
    public let priceBeforeDiscount: Double
    public let discountAmount: Double
    public let subtotal: Double
    public let rushFee: Double
    public let total: Double
}


// MARK: - The dashboard

/// What `lib/dashboard-facts.js` says about a shop right now.
///
/// Decoded loosely on purpose: this module answers six different themes and
/// carries fields the Mac app has no screen for. A stricter decoder would fail
/// the whole dashboard over a key it never reads.
public struct DashboardFacts: Decodable, Sendable {
    public let showsMoney: Bool
    public let activeCount: Int
    public let printingCount: Int
    public let lateCount: Int
    public let owed: Double?
    public let fleet: Fleet
    public let attn: Attention

    public struct Fleet: Decodable, Sendable {
        public let total: Int
        public let live: Int
        public let offline: Int
        public let idle: Int
    }

    public struct Attention: Decodable, Sendable {
        public let count: Int
        public let items: [Item]
    }

    /// One thing that needs looking at. `kind` is `order`, `machine` or
    /// `nozzle`; `severity` is the module's word, not a colour chosen here.
    public struct Item: Decodable, Sendable, Identifiable, Hashable {
        public let severity: String
        public let kind: String
        public let id: String
        public let name: String?
        public let dueDate: String?
        public let daysLate: Int?
    }
}

/// A filament ranked by how close its colour is to one the shop wants.
///
/// `deltaE` is CIEDE2000 from `lib/color-mix.js` — perceptual distance, not a
/// difference between hex triples. Under about 1 nobody can tell them apart;
/// around 2-3 is a good match on a printed part; past 10 they are two colours.
public struct ColourMatch: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let material: String?
    public let colourVariant: String?
    public let color: String?
    public let weight: Double?
    public let deltaE: Double
}

/// Something to chase: an invoice past its due date, or a quote about to run
/// out. `lib/payment-reminder.js` and `lib/quote-followup.js` decide WHICH —
/// each has its own grace period, cooldown and cap, and neither is a filter
/// this app is allowed to guess at.
public struct Chase: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    /// Days PAST the due date for an invoice; days UNTIL expiry for a quote.
    /// Both come from the module that selected the row.
    public let days: Int?

    public init(id: String, name: String?, days: Int?) {
        self.id = id; self.name = name; self.days = days
    }
}


// MARK: - The shop floor

/// What `lib/nozzle-wear.js` says about a machine's nozzle.
public struct NozzleWear: Decodable, Sendable {
    /// Grams printed since the nozzle went in.
    public let grams: Double
    /// Wear in "abrasive-equivalent" grams — the module's own weighting, since
    /// a kilo of carbon fibre is not a kilo of PLA as far as brass is concerned.
    public let wear: Double
    public let threshold: Double
    /// 0–100. The module rounds it; this does not round it again.
    public let pct: Double
    public let over: Bool
    public let abrasive: Bool
}

/// The figures `lib/kpi.js` computes, from rows `lib/kpi-rows.js` selected and
/// `lib/order-money.js` priced. Not recomputed in Swift: the margin a shop is
/// shown here is the margin its other app shows.
public struct Kpis: Decodable, Sendable {
    public let orderCount: Int
    public let completedCount: Int
    public let revenue: Double
    public let cost: Double
    public let grossProfit: Double
    public let grossMargin: Double
    public let avgOrderValue: Double
    public let onTimePct: Double?
    public let onTimeTotal: Int
    public let outstanding: Double
}

/// Whether a job may move to a stage, as `lib/order-status.js` decides it.
///
/// A refusal names its reason as a CODE, never a sentence. The module does not
/// know which language the shop reads, and the two apps have to refuse for the
/// same reason even when they say it differently — which is the whole point of
/// the rules living in one place.
///
/// `warn` survives a `block`: being told the column is full AND the assembly is
/// unfinished is more use than being told one of the two.
public struct StatusGate: Decodable, Sendable, Equatable {
    /// Why a move was refused, or why it is a squeeze.
    public struct Reason: Decodable, Sendable, Equatable {
        /// `production_paused`, `wip_blocked`, `wip_reached`,
        /// `assembly_not_assembled`, `assembly_parts`.
        public let code: String
        /// Whatever the sentence needs — the column and its limit, or the parts
        /// still outstanding. Heterogeneous by code, so it stays untyped.
        public let params: [String: JSONValue]
    }

    public let ok: Bool
    public let block: Reason?
    public let warn: Reason?
    /// Completing a job is the moment the shop learns what it really cost, so
    /// it is also the moment worth asking for the actual time and grams.
    public let needsActuals: Bool
}

/// Something the person should be told, named by code rather than sentence.
///
/// The shared modules do not know which language the shop reads, so they hand
/// back a code and whatever the sentence needs. `Words` turns it into words.
public struct Notice: Decodable, Sendable, Equatable {
    public let code: String
    public let params: [String: JSONValue]
}

/// One of the places a status change reaches outside the shop's own book.
///
/// A webhook to somebody's ERP, a Telegram message, an email to the customer, a
/// refresh of the link they are watching. None of it is undoable and none of it
/// is repeatable — so an app that cannot send them must not make the move and
/// quietly skip them.
public struct Outbound: Decodable, Sendable, Equatable {
    /// `webhooks`, `event_webhook`, `telegram`, `email`, `portal`.
    public let channel: String
    /// Why it applies: `enabled`, `published`, or the status that triggers it.
    public let why: String
}

/// A job moved from one stage to another, and everything that moved with it.
///
/// The three collections come back CHANGED rather than as a patch, because the
/// shared modules mutate what they are handed and the caller's job is to write
/// the result down. `unhandled` is the safety net: an effect type this app does
/// not classify is reported rather than dropped, so a new effect in
/// `lib/order-status.js` surfaces as a visible gap instead of a silent one.
public struct JobMove: Decodable, Sendable {
    public let ok: Bool
    /// Present and refusing when `ok` is false.
    public let gate: StatusGate
    public let order: JSONValue?
    public let inventory: [JSONValue]?
    public let consumables: [JSONValue]?
    public let notices: [Notice]?
    /// What the move should be called in the activity log, if anything.
    public let activity: String?
    /// Effect types this app performed, cosmetically skipped, that would have
    /// left the shop (and reached nobody, or the move would have been refused),
    /// or that it does not know at all.
    public let performed: [String]?
    public let cosmetic: [String]?
    public let outbound: [String]?
    public let unhandled: [String]?
}

/// An order after money was recorded against it, and what that asked for.
///
/// `effects` are named but not detailed, because a payment's are simpler than a
/// move's: saving, redrawing, and the notifications a shop with integrations
/// would send — which the caller has already refused the move over if it has
/// any of them.
public struct PaymentRecorded: Decodable, Sendable {
    public let order: JSONValue
    public let effects: [String]
}

/// A job handed over, or a job that was not ready to be.
public struct Handover: Decodable, Sendable {
    public let ok: Bool
    public let order: JSONValue?
}

/// A job after its details were changed, and whether anything actually moved.
public struct JobEdited: Decodable, Sendable {
    public let order: JSONValue
    public let changed: Bool
}

/// A job that failed inspection, and the waste row it produced.
public struct QcFailure: Decodable, Sendable {
    public let order: JSONValue
    public let waste: JSONValue
    /// The shelf as the failed print left it. A failure takes its filament off
    /// the spools it was printing from, so this has to be written with the
    /// order and the waste row — three records that land together or not at all.
    public let inventory: [JSONValue]
    /// What actually came off, and which spools it came off.
    public let deducted: Double
    public let spools: [String]
}

/// A new job, and the shop's counters as taking it left them.
///
/// Both, because they must be written together: the order carries an invoice
/// number the settings have just consumed, and saving one without the other
/// either loses the job or hands its number to the next one.
public struct NewOrder: Decodable, Sendable {
    public let order: JSONValue
    public let settings: [String: JSONValue]
}

/// What a shop's Telegram bot is about to say.
public struct TelegramMessage: Decodable, Sendable, Equatable {
    public let botToken: String
    public let chatId: String
    public let message: String
}

/// A machine as a rule left it, or the reason it would not.
public struct MachineWritten: Decodable, Sendable {
    public let machine: JSONValue?
    public let refused: String?
}

/// A nozzle fitment, as `lib/nozzle-wear-data.js` describes it.
public struct NozzleMaterial: Decodable, Sendable, Identifiable, Equatable {
    public let key: String
    public let label: String
    /// What it is expected to last, in grams.
    public let grams: Double
    public var id: String { key }
}

/// One printer in Khayt's catalogue, as a picker offers it.
public struct CatalogPrinter: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let vendor: String?
    /// The bed, the nozzle, the colours, the power — what the catalogue has
    /// checked, and by its absence what it has not.
    public let specs: String
}

/// A new spool, or the reason there is not one.
public struct SpoolWritten: Decodable, Sendable {
    public let spool: JSONValue?
    public let refused: String?
}

/// A corrected spool, and the settings as its colour library left them.
public struct SpoolEdited: Decodable, Sendable {
    public let spool: JSONValue
    public let settings: [String: JSONValue]
    public let refused: String?
    public let colourAdded: String?
}

/// What the shop is owed, aged.
public struct Receivables: Decodable, Sendable, Equatable {
    public let rows: [Row]
    public let buckets: [Bucket]
    public let total: Double

    /// One unpaid amount: a whole order, or one instalment of a plan.
    public struct Row: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let project: String
        public let client: String
        public let owed: Double
        /// Whole days outstanding — from the instalment's own due date where
        /// there is one, so a plan is not read as overdue since the order.
        public let days: Int
        public let bucket: String
        public let payStatus: String
        public let instalment: Bool
    }

    /// One of the four ages a shop reads.
    public struct Bucket: Decodable, Sendable, Equatable, Identifiable {
        public let label: String
        public let count: Int
        public let total: Double
        public var id: String { label }
    }
}

/// One quarter of the shop's P&L.
public struct PnlPeriod: Decodable, Sendable, Identifiable, Equatable {
    /// "2026-Q3".
    public let period: String
    public let orders: Int
    public let revenue: Double
    public let shipping: Double
    public let expenses: Double
    /// The fixed overhead charged to this period — pro-rated for the quarter
    /// in progress, so it is not billed a full quarter's rent on day three.
    public let fixed: Double
    /// Tax charged on this quarter's sales — money held for the authority, and
    /// the reason `revenue` above is net of it.
    public let vatCollected: Double
    /// Tax the shop paid on its purchases and can reclaim. Only the expenses
    /// that recorded one contribute; an expense entered before Khayt asked
    /// carries none and reclaims nothing.
    public let vatReclaimable: Double
    /// What is actually owed for the quarter: charged less paid. NEGATIVE is a
    /// real position — the quarter a shop buys a printer, the authority owes it.
    public let vatDue: Double
    public let net: Double
    public var id: String { period }
}

/// A record the shared rule built, or the reason it would not.
///
/// Both halves optional because exactly one is present: a rule that refuses
/// returns a reason and no record, and the caller must not be able to read a
/// record that was never made.
public struct Written: Decodable, Sendable {
    public let expense: JSONValue?
    public let refused: String?
}

/// A waste entry, and the shelf as deducting from it left it.
public struct WasteWritten: Decodable, Sendable {
    public let entry: JSONValue?
    public let refused: String?
    public let inventory: [JSONValue]
}

/// A waste entry taken out, and both collections as that left them.
public struct WasteRemoved: Decodable, Sendable {
    public let removed: Bool
    public let wasteLog: [JSONValue]
    public let inventory: [JSONValue]
}

/// A category that has gone past its monthly budget.
public struct Overspend: Decodable, Sendable, Equatable {
    public let spent: Double
    public let budget: Double
}

/// Budget against actual for one category.
public struct BudgetRow: Decodable, Sendable, Identifiable, Equatable {
    public let category: String
    public let budget: Double
    public let spent: Double
    public let remaining: Double
    /// Capped at 100, for a bar.
    public let pct: Double
    public let over: Bool
    public var id: String { category }
}

/// A currency a shop can price in, as `lib/currencies.js` describes it.
public struct Currency: Codable, Sendable, Equatable {
    public let symbol: String
    public let label: String
    /// Where the symbol goes: "before" the figure ($12) or "after" it (12 SAR).
    public let pos: String
}

/// An invoice, ready to be shown or printed.
public struct InvoiceDocument: Decodable, Sendable {
    public let html: String
    /// True when the shop reads Arabic-Indic digits. A string cannot rewrite
    /// the text of elements that have not been laid out yet, so the app does it
    /// once the document is in a view.
    public let arabicNumerals: Bool
    /// The elements that pass applies to.
    public let selector: String

    /// Memberwise, so a test can hand `page` a document without running the
    /// whole rule set to get one — the wrapping is its own question.
    public init(html: String, arabicNumerals: Bool, selector: String) {
        self.html = html
        self.arabicNumerals = arabicNumerals
        self.selector = selector
    }
}
