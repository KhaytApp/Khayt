import Foundation
import KhaytCore

/// The shop's books, read for an assistant to ask about.
///
/// ── EVERY FIGURE IS A SHARED RULE'S ───────────────────────────────────────
///
/// Open orders, what is owed, what is running out, the P&L and a quote: the
/// app's screens already answer all five, through `lib/` running in
/// JavaScriptCore. This asks the SAME rules through the same `KhaytEngine`,
/// handed the same collections the screens hand them, so "what does the shop
/// owe me" here and on the Reports screen are one sum and cannot drift. The
/// Swift below gathers inputs, picks fields, sorts and caps. It does not add
/// up money.
///
/// ── READ-ONLY, AND MASKED BEFORE ANYTHING READS IT ───────────────────────
///
/// The book is read from disk and never written: there is no write path in
/// this target, not even a temporary file beside the store. What is read is
/// passed through `KhaytCloudOutbox.forPhone` first — the rule the LAN server
/// hands a phone — so every credential, every sealed `__enc__` value and the
/// staff PIN hashes are masked before a tool sees the book. The tools then
/// lift only the fields they name: a customer's NAME, never a phone, an email
/// or an address — and the name only when the shop has said it may go
/// (`CustomerNames`): by default an assistant reads "Customer 3".
///
/// ── FRESH ON EVERY QUESTION ──────────────────────────────────────────────
///
/// A host keeps this server running for a whole conversation, and "who owes
/// me" is a question about now. So the book is re-read per call (see
/// `main.swift`), not once at launch like the library.
struct Books: Sendable {
    /// The whole store, masked.
    let book: [String: JSONValue]
    let engine: KhaytEngine
    /// Whose names may be said, and what to say instead — from this same
    /// book, so a label means the same customer in every tool.
    let names: CustomerNames

    init(book: [String: JSONValue], engine: KhaytEngine) {
        self.book = book
        self.engine = engine
        self.names = CustomerNames(book: book)
    }

    /// Read a store's bytes and mask them. Throws on a book that is not JSON.
    static func open(_ data: Data, engine: KhaytEngine) async throws -> Books {
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return Books(book: try await engine.storeForPhone(raw), engine: engine)
    }

    // MARK: - The collections, as the app's `Shop` reads them

    func rows(_ key: String) -> [JSONValue] {
        if case .array(let rows)? = book[key] { return rows }
        return []
    }

    var settings: [String: JSONValue] {
        if case .object(let s)? = book["settings"] { return s }
        return [:]
    }

    /// `settings.lang`, the language the shop keeps its book in — the one the
    /// app reads names in. Anything it does not speak is English.
    var language: String {
        if case .string(let l)? = settings["lang"], ["en", "ar"].contains(l) { return l }
        return "en"
    }

    /// The currency table every screen formats and converts against.
    func currencyTable() async -> [String: JSONValue] {
        let all = (try? await engine.currencies()) ?? [:]
        return all.mapValues {
            .object(["symbol": .string($0.symbol), "label": .string($0.label), "pos": .string($0.pos)])
        }
    }

    func baseCurrency() async -> String {
        (try? await engine.baseCurrency(settings: settings)) ?? ""
    }

    // MARK: - Open orders

    func openOrders(_ args: [String: Any], now: Date) async throws -> [String: Any] {
        let jobs = try await engine.openOrders(
            orders: rows("printLog"), clients: rows("clients"), settings: settings,
            currencies: await currencyTable(), language: language, now: now,
            includeQuotes: args["include_quotes"] as? Bool == true)
        var shown = jobs
        if args["late_only"] as? Bool == true { shown = shown.filter { $0.daysLate != nil } }
        // What a shop chases first: the latest job, then the soonest promise.
        shown.sort { a, b in
            if (a.daysLate ?? -1) != (b.daysLate ?? -1) { return (a.daysLate ?? -1) > (b.daysLate ?? -1) }
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.date ?? "", a.id) < (b.date ?? "", b.id)
            }
        }
        let page = Page(shown, args)
        return [
            "as_of": Calendar.book.dayString(now),
            "count": shown.count,
            "late": jobs.count { $0.daysLate != nil },
            "truncated": page.truncated,
            "orders": page.items.map { o -> [String: Any] in
                var row: [String: Any] = [
                    "id": o.id, "project": names.scrub(o.project),
                    "client": names.client(order: o.id, named: o.client), "status": o.status,
                    "currency": o.currency, "price": Self.money(o.price),
                    "due": Self.money(o.due), "owed": Self.money(o.owed),
                    "pay_status": o.payStatus,
                ]
                if let v = o.stage, v != o.status { row["stage"] = v }
                if let v = o.date { row["date"] = v }
                if let v = o.dueDate { row["due_date"] = v }
                if let v = o.daysLate { row["days_late"] = v }
                return row
            },
        ]
    }

    // MARK: - Receivables

    func receivables(_ args: [String: Any], now: Date) async throws -> [String: Any] {
        let orders = rows("printLog")
        // Exactly the Reports screen's call: every job, the shop's language.
        let aged = try await engine.receivables(
            orders: orders, settings: settings, clients: rows("clients"),
            currencies: await currencyTable(), language: language, now: now)
        let pastDue = try await engine.daysPastDue(orders: orders, now: now)
        var dueDates: [String: String] = [:]
        for case .object(let o) in orders {
            if case .string(let id)? = o["id"], case .string(let due)? = o["dueDate"], !due.isEmpty {
                dueDates[id] = due
            }
        }
        func daysPast(_ r: Receivables.Row) -> Int? { r.instalment ? nil : pastDue[r.id] }
        var shown = aged.rows
        if args["overdue_only"] as? Bool == true {
            // Past a date somebody promised: the order's due date, or — for a
            // plan — the instalment's own, which is what `days` counts from.
            shown = shown.filter { r in r.instalment ? r.days > 0 : (daysPast(r) ?? 0) > 0 }
        }
        let page = Page(shown, args)
        return [
            "as_of": Calendar.book.dayString(now),
            "currency": await baseCurrency(),
            "total_owed": Self.money(aged.total),
            "buckets": aged.buckets.map {
                ["label": $0.label, "count": $0.count, "total": Self.money($0.total)] as [String: Any]
            },
            "count": shown.count,
            "truncated": page.truncated,
            // The rule's order: oldest first, which is what a shop chases.
            "rows": page.items.map { r -> [String: Any] in
                var row: [String: Any] = [
                    "id": r.id, "project": names.scrub(r.project),
                    "client": names.client(order: r.id, named: r.client),
                    "owed": Self.money(r.owed), "days_outstanding": r.days,
                    "bucket": r.bucket, "pay_status": r.payStatus, "instalment": r.instalment,
                ]
                if !r.instalment, let due = dueDates[r.id] { row["due_date"] = due }
                if let d = daysPast(r) { row["days_past_due"] = d }
                return row
            },
        ]
    }

    // MARK: - Stock runway

    func stockRunway(_ args: [String: Any], now: Date) async throws -> [String: Any] {
        let within = Int(max(1, min(Self.number(args["within_days"]) ?? 14, 365)))
        var items = try await engine.stockRunway(
            spools: rows("inventory"), consumables: rows("consumables"),
            orders: rows("printLog"), purchaseOrders: rows("purchaseOrders"),
            settings: settings, now: now, leadDays: within)
        // The reorder rule's own urgency order, across both shelves: soonest
        // empty first, an unknown future last, low before not-low.
        items.sort { a, b in
            let da = a.daysLeft ?? .infinity, db = b.daysLeft ?? .infinity
            if da != db { return da < db }
            return a.low && !b.low
        }
        let page = Page(items, args)
        return [
            "as_of": Calendar.book.dayString(now),
            "within_days": within,
            "count": items.count,
            "truncated": page.truncated,
            "items": page.items.map { s -> [String: Any] in
                var row: [String: Any] = [
                    "id": s.id, "kind": s.kind, "label": names.scrub(s.label), "unit": s.unit,
                    "low": s.low, "on_hand": Self.money(s.stock),
                    "used_per_day": Self.money(s.perDay),
                    "suggest_order": Self.money(s.suggest), "needs_ordering": s.needsOrdering,
                ]
                if let v = s.material { row["material"] = v }
                if let v = s.color { row["color"] = v }
                if let v = s.committed { row["reserved"] = Self.money(v) }
                if let v = s.available { row["available"] = Self.money(v) }
                if let v = s.daysLeft { row["days_left"] = v }
                return row
            },
        ]
    }

    // MARK: - P&L

    func profitAndLoss(_ args: [String: Any], now: Date) async throws -> [String: Any] {
        let wanted = (args["period"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        // A named period says its own granularity: "2026-Q3" or "2026-09".
        var granularity = (args["granularity"] as? String) == "month" ? "month" : "quarter"
        if wanted.contains("-Q") { granularity = "quarter" }
        else if wanted.count == 7 { granularity = "month" }

        let machines = rows("machines"), orders = rows("printLog")
        // The Reports screen's inputs, every one: the machines' recent hours
        // feed the depreciation line exactly as they do there.
        let values = (try? await engine.machineValues(
            machines: machines, orders: orders, today: Calendar.book.dayString(now))) ?? [:]
        let periods = try await engine.pnlByPeriod(
            orders: orders, expenses: rows("expenses"), settings: settings,
            clients: rows("clients"), currencies: await currencyTable(), now: now,
            granularity: granularity, wasteLog: rows("wasteLog"),
            inventory: rows("inventory"), machines: machines,
            recentMonthlyHours: values.compactMapValues { $0.recentMonthlyHours },
            timeEntries: rows("timeEntries"))
        var shown = periods.sorted { $0.period > $1.period }
        if !wanted.isEmpty { shown = shown.filter { $0.period == wanted } }
        let page = Page(shown, args, standard: 4, most: 24)
        var out: [String: Any] = [
            "currency": await baseCurrency(),
            "granularity": granularity,
            "count": shown.count,
            "truncated": page.truncated,
            "note": """
                Revenue is net of VAT, as on the Reports screen; the VAT is \
                vat_collected. Filament bought is stock (inventory_bought), not \
                an expense — it reaches the P&L as cost of goods when a job uses it.
                """,
            "periods": page.items.map(Self.period),
        ]
        if !wanted.isEmpty, shown.isEmpty {
            out["error"] = "no \(granularity) \(wanted) in the book"
        }
        return out
    }

    static func period(_ p: PnlPeriod) -> [String: Any] {
        var row: [String: Any] = [
            "period": p.period, "orders": p.orders,
            "revenue_net_of_vat": money(p.revenue), "shipping": money(p.shipping),
            "expenses": money(p.expenses), "fixed_overhead": money(p.fixed),
            "vat_collected": money(p.vatCollected), "vat_reclaimable": money(p.vatReclaimable),
            "vat_due": money(p.vatDue), "net": money(p.net),
        ]
        if let v = p.cogs { row["cost_of_goods"] = money(v) }
        if let v = p.marginPct { row["margin_pct"] = money(v) }
        if let v = p.unpriced, v > 0 { row["unpriced_jobs"] = v }
        if let v = p.inventory { row["inventory_bought"] = money(v) }
        if let v = p.waste { row["waste"] = money(v) }
        if let v = p.depreciation { row["depreciation"] = money(v) }
        if let v = p.labour { row["labour"] = money(v) }
        if p.labourOverlap == true { row["labour_overlap"] = true }
        return row
    }

    // MARK: - A quote draft

    /// Cost a part and price it the way the Mac calculator does, and save
    /// nothing. Two crossings the calculator makes (`costPart`, then
    /// `quoteTotal` over cost × quantity) and the tax split the invoice would
    /// print.
    func quoteDraft(_ args: [String: Any]) async throws -> [String: Any] {
        guard let grams = Self.number(args["grams"]), grams.isFinite, grams >= 0,
              let hours = Self.number(args["hours"]), hours.isFinite, hours >= 0 else {
            return ["error": "grams and hours are required, as numbers of zero or more"]
        }
        let qty = Int(max(1, min(Self.number(args["qty"]) ?? 1, 1000)))
        let inventory = rows("inventory")

        // The part, in the shape `Shop.costInput` hands the cost model.
        var part: [String: JSONValue] = [
            "printWeight": .number(grams), "printTime": .number(hours), "qty": .number(Double(qty)),
        ]
        var spoolLabel: String?
        if let id = args["spool_id"] as? String, !id.isEmpty {
            guard let spool = Self.record(id, in: inventory) else {
                return ["error": "no spool with id \(id)"]
            }
            part["filamentId"] = .string(id)
            if case .string(let m)? = spool["material"] { part["material"] = .string(m) }
            part["spoolCost"] = .number(Self.plain(spool["cost"]) ?? 0)
            part["spoolWeight"] = .number(max(1, Self.plain(spool["spoolWeight"]) ?? 1000))
            spoolLabel = [spool["material"], spool["color"]].compactMap {
                if case .string(let s)? = $0, !s.isEmpty { return s } else { return nil }
            }.joined(separator: " ")
        }
        var machine: JSONValue?
        if let id = args["machine_id"] as? String, !id.isEmpty {
            guard let m = Self.record(id, in: rows("machines")) else {
                return ["error": "no machine with id \(id)"]
            }
            machine = .object(m)
        }
        var preset: JSONValue?
        if let id = args["preset_id"] as? String, !id.isEmpty {
            guard let p = Self.record(id, in: rows("printers")) else {
                return ["error": "no printer preset with id \(id)"]
            }
            preset = .object(p)
        }

        let costed = try await engine.costPart(
            .object(part), inventory: inventory, settings: settings,
            machine: machine, preset: preset, consumables: rows("consumables"))

        // The calculator's defaults: the shop's own margin, else thirty; the
        // shop's own rush percentage, else twenty-five (`Shop.previewQuote`).
        let margin = Self.number(args["margin_pct"]) ?? Self.plain(settings["defaultMargin"]) ?? 30
        let rush = args["rush"] as? Bool == true
        var input: [String: JSONValue] = [
            "baseCost": .number(costed.cost * Double(qty)), "qty": .number(1),
            "margin": .number(margin),
            "discountPct": .number(Self.number(args["discount_pct"]) ?? 0),
            "shippingCost": .number(Self.number(args["shipping_cost"]) ?? 0),
            "rushEnabled": .bool(rush), "business": .bool(true), "agreedAmount": .number(0),
        ]
        if rush { input["rushPct"] = .number(Self.plain(settings["rushFeePct"]) ?? 25) }
        let quote = try await engine.quoteTotal(input)
        let tax = try await engine.taxed(quote.total, settings: settings)

        var inputs: [String: Any] = ["grams": grams, "hours": hours, "qty": qty,
                                     "margin_pct": margin, "rush": rush]
        if let v = spoolLabel { inputs["spool"] = names.scrub(v) }
        if machine != nil { inputs["machine_id"] = args["machine_id"] }
        if preset != nil { inputs["preset_id"] = args["preset_id"] }
        return [
            "draft": true,
            "saved": false,
            "note": """
                A draft worked out by the shop's own calculator rules. Nothing \
                was saved: no job, no quote, no customer. Open Khayt to make it \
                a quote.
                """,
            "currency": await baseCurrency(),
            "inputs": inputs,
            "cost": [
                "per_unit": Self.money(costed.cost),
                "material": Self.money(costed.parts.material),
                "machine": Self.money(costed.parts.machine),
                "labour": Self.money(costed.parts.labor),
                "failure_allowance": Self.money(costed.parts.buffer),
            ],
            "price": [
                "before_discount": Self.money(quote.priceBeforeDiscount),
                "discount": Self.money(quote.discountAmount),
                "subtotal": Self.money(quote.subtotal),
                "rush_fee": Self.money(quote.rushFee),
                "total": Self.money(quote.total),
            ],
            "tax": [
                "mode": tax.mode, "net": Self.money(tax.subtotal),
                "tax": Self.money(tax.taxTotal), "invoice_total": Self.money(tax.total),
            ],
        ]
    }

    // MARK: - Small things

    /// Money as a screen prints it: to the cent. Only how the rule's figure is
    /// SAID — a decimal, because `JSONSerialization` writes a `Double` at full
    /// precision and 541.23 went out as 541.23000000000002.
    static func money(_ x: Double) -> NSDecimalNumber {
        guard x.isFinite else { return .zero }
        return NSDecimalNumber(string: String(format: "%.2f", x), locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A number an assistant sent, whether as an integer or not. A boolean is
    /// not a number, even though JSON hands both over as `NSNumber`.
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func plain(_ v: JSONValue?) -> Double? {
        if case .number(let n)? = v, n.isFinite { return n }
        return nil
    }

    static func record(_ id: String, in rows: [JSONValue]) -> [String: JSONValue]? {
        for case .object(let o) in rows where o["id"] == .string(id) { return o }
        return nil
    }
}

/// A page of results. An assistant's context is small, so every list is capped
/// and says when it was.
struct Page<T> {
    let items: [T]
    let truncated: Bool

    init(_ all: [T], _ args: [String: Any], standard: Int = 25, most: Int = 100) {
        let asked = Books.number(args["limit"]).map { Int(max(1, min($0, Double(most)))) }
        let limit = asked ?? standard
        items = Array(all.prefix(limit))
        truncated = all.count > limit
    }
}
