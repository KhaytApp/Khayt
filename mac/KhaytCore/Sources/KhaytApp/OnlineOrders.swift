import Foundation
import KhaytCore

/// The orders a storefront has already sent, and what the shelf can answer.
///
/// ── WHAT THIS IS FOR ──────────────────────────────────────────────────────
///
/// The Integrations screen hands a shop the address its storefront posts orders
/// to. Every one of those orders is sitting in a queue in Khayt Cloud right
/// now, and until this the Mac had no way to look at it — `CloudIntake` is the
/// reading, this is what the shop does about it.
///
/// And it does one thing the desktop's Order requests screen does not: it looks
/// at the shelf first. A shop that keeps a stock of finished pieces sells them
/// online, and an order for something already printed is a SALE. Filed as a
/// pending job it goes to a machine that has nothing to make.
///
/// ── WHAT IT WILL NOT DO ───────────────────────────────────────────────────
///
/// It will not decide. Every incoming order is shown with what it matched and
/// what it did not, and nothing is written until the shop says so — because a
/// deduction is invisible once made: the number it leaves behind looks exactly
/// like a number somebody counted. `lib/shelf-sale.js` matches on the whole
/// name and refuses a near miss for the same reason.
@MainActor
extension Shop {

    /// One order off the queue, with the shelf already read against it.
    struct OnlineOrder: Identifiable, Sendable {
        let item: CloudIntake.Item
        let reading: JSONValue
        /// Whether it may become a job by itself, and why not — nil for an
        /// order read before this existed, or when the rule could not answer.
        var decision: KhaytEngine.WebStoreDecision? = nil

        var id: String { item.id }
        var title: String { item.title }
        var customer: String { item.customer }
        var source: String { item.source }

        var lines: [Line] {
            guard case .object(let fields) = reading,
                  case .array(let rows)? = fields["lines"] else { return [] }
            return rows.compactMap(Line.init(_:))
        }
        var fromShelf: Int { number("fromShelf") }
        var toPrint: Int { number("toPrint") }
        var unmatched: Int { number("unmatched") }
        /// Everything this order asked for is already made.
        var allFromShelf: Bool {
            guard case .object(let fields) = reading,
                  case .bool(let all)? = fields["allFromShelf"] else { return false }
            return all
        }

        private func number(_ key: String) -> Int {
            guard case .object(let fields) = reading,
                  case .number(let value)? = fields[key] else { return 0 }
            return Int(value)
        }

        struct Line: Identifiable, Sendable {
            let name: String
            let qty: Int
            let productId: String?
            let onShelf: Int
            let fromShelf: Int
            let toPrint: Int
            /// What the customer chose — `Colour: Red` — sorted by name, so a
            /// line reads the same every time it is drawn.
            let options: [(String, String)]

            var id: String { name + "×" + String(qty) + (productId ?? "") + optionText }
            /// `Colour: Red, Size: L`, or empty.
            var optionText: String {
                options.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
            }
            /// A line naming nothing this shop sells. Reported, never guessed.
            var unmatched: Bool { productId == nil }

            init?(_ value: JSONValue) {
                guard case .object(let f) = value,
                      case .string(let name)? = f["name"] else { return nil }
                self.name = name
                self.qty = Self.int(f["qty"])
                self.productId = { if case .string(let id)? = f["productId"] { return id }
                                   return nil }()
                self.onShelf = Self.int(f["onShelf"])
                self.fromShelf = Self.int(f["fromShelf"])
                self.toPrint = Self.int(f["toPrint"])
                if case .object(let chosen)? = f["options"] {
                    self.options = chosen.keys.sorted().compactMap { key in
                        if case .string(let value)? = chosen[key] { return (key, value) }
                        return nil
                    }
                } else {
                    self.options = []
                }
            }
            private static func int(_ value: JSONValue?) -> Int {
                if case .number(let n)? = value { return Int(n) }
                return 0
            }
        }
    }

    // MARK: - Looking

    /// Ask the cloud what has arrived, and read each order against the shelf.
    ///
    /// Answers on `onlineOrders`. A cloud that is not connected is not an
    /// error and says nothing: a shop with no storefront should never be told
    /// about a queue it does not have.
    func readOnlineOrders(fetch: CloudIntake.Fetch? = nil) async {
        onlineProblem = nil
        // ASKED NOTHING, CHANGED NOTHING. A book with no cloud has no queue
        // and is told so by there being no button — clearing the list here as
        // well would mean this screen's content depended on a call that never
        // happened, which is how the photograph of it came back blank.
        guard cloudConnected, let build = source.build, let engine else { return }
        onlineBusy = true
        defer { onlineBusy = false }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudIntake.Failure.notConnected }
            let items = try await CloudIntake.list(connection, token: token,
                                                   fetch: fetch ?? Self.overTheNetwork)
            let stock = Self.stockCounts(settingsDict)
            var read: [OnlineOrder] = []
            for item in items {
                read.append(try await Self.onlineOrder(item, products: productRows,
                                                       stock: stock, engine: engine))
            }
            onlineOrders = read
        } catch {
            onlineOrders = []
            onlineProblem = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
    }

    /// One queue item, read against the shelf and against the rule that says
    /// whether it may become a job by itself.
    static func onlineOrder(_ item: CloudIntake.Item, products: [JSONValue], stock: JSONValue,
                            engine: KhaytEngine) async throws -> OnlineOrder {
        var order = OnlineOrder(
            item: item,
            reading: try await engine.shelfSaleReading(payload: item.payload,
                                                      products: products, stock: stock))
        order.decision = try? await engine.webStoreDecision(item.payload)
        return order
    }

    /// `settings.storefront.stockQty`, or an empty map.
    static func stockCounts(_ settings: [String: JSONValue]) -> JSONValue {
        guard case .object(let store)? = settings["storefront"],
              case .object(let counts)? = store["stockQty"] else { return .object([:]) }
        return .object(counts)
    }

    private static let overTheNetwork: CloudIntake.Fetch = { request in
        try await CloudReader.session.data(for: request)
    }

    // MARK: - Recording one

    /// What writing one order into the book did.
    enum Recorded: Equatable, Sendable {
        /// A new job, and the customer it was put on.
        case made(jobId: String, clientId: String?, newCustomer: Bool, paid: Bool)
        /// The book already held it: by the platform's reference, or by this
        /// queue item. Nothing was written.
        case alreadyThere
    }

    /// Write the order into the book, take what it used off the shelf, and
    /// only then drop it from the queue. The button on the Online orders sheet.
    ///
    /// ── THE ORDER OF THE THREE STEPS IS THE WHOLE DESIGN ──────────────────
    ///
    /// The queue in the cloud is the only copy of this order that exists. So
    /// the book is written FIRST and the queue is drained last: a failure
    /// between them leaves the order in both places, which a shop can see and
    /// fix, while the other order leaves it in neither.
    ///
    /// A drain that fails is reported and the write stands. It is not retried
    /// silently — see `never loop a destructive probe`.
    func recordOnlineOrder(_ order: OnlineOrder, fetch: CloudIntake.Fetch? = nil) async {
        guard case .store = source else { return }
        onlineProblem = nil
        onlineBusy = true
        defer { onlineBusy = false }

        // Paid only when the store says so (or cannot place an unpaid order):
        // a button press is not a payment.
        let paid = order.decision?.paid ?? false
        switch await writeOnlineOrder(order, paid: paid) {
        case .failure(let problem):
            onlineProblem = problem.sentence
            return
        case .success(.alreadyThere):
            onlineProblem = words.callIt("mac.online_already_recorded")
        case .success(.made(let jobId, _, _, _)):
            webStoreArrived.append(WebStoreArrival(
                intakeId: order.id, reference: order.item.reference, jobId: jobId,
                customer: order.customer, automatic: false))
        }
        if let problem = await drainOnlineOrder(order, fetch: fetch) {
            onlineProblem = problem
        }
        await reload()
    }

    /// Take a recorded order out of the cloud's queue. Nil when it went, or
    /// the sentence to show when it did not.
    ///
    /// Only after the write — for an order already in the book, this is the
    /// step that failed last time.
    func drainOnlineOrder(_ order: OnlineOrder, fetch: CloudIntake.Fetch? = nil) async -> String? {
        guard let build = source.build else { return nil }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            try await CloudIntake.drain(connection, token: token, id: order.id,
                                        fetch: fetch ?? Self.overTheNetwork)
            onlineOrders.removeAll { $0.id == order.id }
            return nil
        } catch {
            return words.callIt("mac.online_kept_in_queue") + " "
                + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    /// The write, for the button and for the automatic pass alike, so an
    /// order that arrives by itself is recorded exactly as one a person
    /// pressed for. Does not reload and does not drain; the caller does both.
    func writeOnlineOrder(_ order: OnlineOrder, paid: Bool,
                          now: Date = Date()) async -> Result<Recorded, OnlineWriteFailure> {
        guard case .store(let build) = source, let engine else {
            return .failure(OnlineWriteFailure(words.callIt("mac.move_sample")))
        }
        let input = await onlineJobInput(order)
        var outcome: Recorded = .alreadyThere
        var owed: [KhaytEngine.WebhookDelivery] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let put = try await Self.putOnlineOrder(order, input: input, paid: paid,
                                                        into: &root, engine: engine, now: now)
                outcome = put.recorded
                owed = put.webhooks
            }
        } catch {
            return .failure(OnlineWriteFailure((error as? LocalizedError)?.errorDescription
                                               ?? String(describing: error)))
        }
        // After the write, like a payment's: a delivery that went out for a
        // payment the book then refused to keep would be a lie told outward.
        if !owed.isEmpty { await fire(owed) }
        return .success(outcome)
    }

    /// A write that did not happen, in the shop's words.
    struct OnlineWriteFailure: Error, Equatable {
        let sentence: String
        init(_ sentence: String) { self.sentence = sentence }
    }

    /// What `putOnlineOrder` did, and the webhooks a payment it recorded owes.
    struct PutOnline {
        let recorded: Recorded
        var webhooks: [KhaytEngine.WebhookDelivery] = []
    }

    /// The order, into a book already open for writing. INSIDE the chain,
    /// because every question it asks — is it already here, who is this
    /// customer, how many are on the shelf — has to be asked of the book as it
    /// is now, not as it was when the queue was read.
    ///
    /// Static and handed the book, so a test can run it against a file.
    ///
    /// ── IDEMPOTENT ────────────────────────────────────────────────────────
    ///
    /// Asked first, before anything is made: an order the book already holds
    /// — by the platform's own reference, or by the queue item this Mac
    /// recorded it from — changes nothing at all. That is what lets the
    /// automatic pass run every couple of minutes, and a failed drain be
    /// retried by simply running again, without a second job or a second
    /// deduction from the shelf.
    static func putOnlineOrder(_ order: OnlineOrder, input: [String: JSONValue], paid: Bool,
                               into root: inout [String: JSONValue],
                               engine: KhaytEngine, now: Date) async throws -> PutOnline {
        let orders = rows(root, "printLog")
        let source = order.source.isEmpty ? "online" : order.source
        if await alreadyInBook(order, source: source, orders: orders, engine: engine) {
            return PutOnline(recorded: .alreadyThere)
        }

        // ── THE SHELF, COUNTED AGAIN, HERE ─────────────────────────────────
        //
        // `order.reading` was taken when the queue was read — minutes ago, or
        // longer for an order left on the sheet. Since then a piece can have
        // gone over the counter, a recount or another Mac's sync can have
        // landed. Trusting the old reading marked an order "all from the
        // shelf" — completed, nothing to print — when the shelf no longer held
        // it: the customer's pieces were never made. So the order is read
        // against the book as it is INSIDE this write, and whatever the shelf
        // cannot cover now goes to a machine.
        let fresh = OnlineOrder(
            item: order.item,
            reading: try await engine.shelfSaleReading(
                payload: order.item.payload, products: Self.rows(root, "products"),
                stock: Self.stockCounts(Self.settings(root))))
        let deductions = Self.deductions(try await engine.shelfSaleEffects(fresh.reading, at: now))
        let allFromShelf = fresh.allFromShelf

        // ── THE CUSTOMER ───────────────────────────────────────────────────
        //
        // The same email or phone is the same customer; anybody else is a new
        // one, filed as having come from online. `lib/webstore-order.js`
        // decides, as the desktop's Order requests screen always has.
        var input = printOnly(input, reading: fresh)
        if allFromShelf { input["fromStock"] = .bool(true) } else { input.removeValue(forKey: "fromStock") }
        var clients = rows(root, "clients")
        var clientId: String?
        var newCustomer = false
        if let who = try await engine.webStoreCustomer(order.item.payload, clients: clients) {
            clientId = who.clientId
            if clientId == nil, case .object(var record)? = who.create {
                let id = uid("CLI")
                record["id"] = .string(id)
                record["createdAt"] = .string(localDay(now))
                StoreWriter.stamp(&record)
                clients.append(.object(record))
                clientId = id
                newCustomer = true
            }
            if let clientId {
                input["clientId"] = .string(clientId)
                input["client"] = .string(who.name)
            }
        }

        let out = try await engine.newOrder(
            input, orders: orders, settings: settings(root), now: now,
            tokens: (tracking: randomBytes(16), quoteApproval: randomBytes(16)))
        guard case .object(var record) = out.order,
              case .string(let jobId)? = record["id"] else {
            return PutOnline(recorded: .alreadyThere)
        }
        // Which queue item this came from, so a second pass finds it.
        record["intakeId"] = .string(order.id)
        // AND WHICH PLATFORM ORDER. `lib/order-new.js` builds the record from
        // a fixed list of fields and keeps neither `source` nor
        // `sourceOrderId`, so until this they were handed in and dropped: the
        // reference check above could never match a job this Mac had made,
        // and a store retry filed under a new queue item became a second job.
        // Written on the record itself, the field the webhook path writes.
        record["source"] = .string(source)
        if !order.item.reference.isEmpty {
            record["sourceOrderId"] = .string(order.item.reference)
        }
        if allFromShelf {
            // Nothing about this waits on a machine. A shelf sale under
            // Pending is a job somebody goes looking for a free printer to
            // start.
            let at = StoreWriter.iso(now)
            record["status"] = .string("completed")
            record["completedAt"] = .string(at)
            record["statusHistory"] = .array([
                .object(["status": .string("completed"), "at": .string(at)]),
            ])
            record["queuePos"] = .null
            record["machineId"] = .null
            record["dueDate"] = .null
        }

        // ── PAID ONLINE ────────────────────────────────────────────────────
        //
        // The customer paid the store, so the job is recorded as paid in full
        // through the shared payment rule — not by setting a flag, which is
        // how a book ends up with a job that says paid and a balance that
        // says owed. `other`, because the store did not say which card.
        var job: JSONValue = .object(record)
        var webhooks: [KhaytEngine.WebhookDelivery] = []
        let price = plainNumber(record["price"]) ?? 0
        // WHAT THE CUSTOMER PAID, where the platform said — a keyed import
        // carries each line's price — else the job's own price. The platform's
        // figure is the money that moved; a job priced differently (a discount
        // the store ran, a price changed since it was published) is left with
        // the honest balance either way rather than recorded as settled.
        let platformPaid = (try? await engine.webStorePaidTotal(order.item.payload)) ?? nil
        let amount = platformPaid ?? price
        let settingsNow = out.settings
        if paid, amount > 0 {
            let day = localDay(now)
            let done = try await engine.recordPayment(order: job, amount: amount, method: "other",
                                                      paidAt: day, today: day)
            job = done.order
            if let asked = done.webhookEffects, !asked.isEmpty, case .object(let o) = job {
                webhooks = (try? await engine.webhookDeliveries(
                    order: job, effects: asked, settings: settingsNow,
                    shopName: plainString(settingsNow["bizEn"])
                        ?? plainString(settingsNow["bizAr"]) ?? "Khayt",
                    clientName: emailClientName(for: o, in: clients),
                    currency: shopCurrencyOf(settingsNow),
                    at: ISO8601DateFormatter().string(from: now),
                    nowMs: now.timeIntervalSince1970 * 1000)) ?? []
            }
        }
        root["printLog"] = .array([job] + orders)
        if newCustomer { root["clients"] = .array(clients) }

        // ONE settings write, and it starts from `out.settings`.
        //
        // `newOrder` advances the shop's invoice or quote counter and hands
        // the settings back with it advanced; the shelf is a different corner
        // of the same object. Writing the shelf first and the counter second
        // put the shelf back as it was, because `out.settings` was read before
        // the deduction — a bug that costs a customer-visible number and
        // nothing else notices.
        var settings = settingsNow
        for (productId, taken) in deductions {
            // Against the count THE BOOK holds now, not the one the screen was
            // drawn from — see `deductions`. Never below nothing, and a
            // product that has stopped being counted at all is left uncounted
            // rather than invented at zero.
            guard let onShelf = stockCount(of: productId, in: .object(settings)) else { continue }
            // Re-dated even when the figure lands where it already was: a
            // count carries the date it was taken, and this one is current as
            // of now.
            putStockCount(max(0, onShelf - taken), for: productId, into: &settings, at: now)
        }
        root["settings"] = .object(settings)
        return PutOnline(recorded: .made(jobId: jobId, clientId: clientId,
                                         newCustomer: newCustomer, paid: paid && amount > 0),
                         webhooks: webhooks)
    }

    /// Is this queue item's order already a job in the book? By the
    /// platform's reference (the shared rule, so a webhook delivery and a
    /// queue item for the same order are one), or by the queue item's own id.
    static func alreadyInBook(_ order: OnlineOrder, source: String, orders: [JSONValue],
                              engine: KhaytEngine) async -> Bool {
        if !order.item.reference.isEmpty,
           (try? await engine.storefrontOrderRecorded(printLog: .array(orders), source: source,
                                                      sourceOrderId: order.item.reference)) == true {
            return true
        }
        return orders.contains { row in
            guard case .object(let o) = row, case .string(let id)? = o["intakeId"] else { return false }
            return id == order.id
        }
    }

    /// Product id to HOW MANY this order takes, out of the effects list.
    ///
    /// ── `taken`, NOT `to`, AND THAT IS THE WHOLE POINT ───────────────────
    ///
    /// The effects list carries both: `taken` is how many came off, `to` is
    /// what would be left. `to` is an absolute figure worked out from the
    /// count as it was WHEN THE QUEUE WAS READ — which can be minutes ago, and
    /// a shop can have sold one over the counter, recounted, or had a sync
    /// arrive from another Mac since. Writing that figure would put the shelf
    /// back to a number that was true then and is not now, silently.
    ///
    /// The relative figure is applied against whatever the book says inside
    /// the write chain, which is the only place the current count can be read
    /// honestly. Same reason `lib/lan-server.js` does its deduction inside
    /// `updateStoreOnDisk` rather than before it.
    static func deductions(_ effects: [JSONValue]) -> [(String, Int)] {
        effects.compactMap { effect in
            guard case .object(let f) = effect,
                  case .string("deduct")? = f["type"],
                  case .string(let productId)? = f["productId"],
                  case .number(let taken)? = f["taken"], taken > 0 else { return nil }
            return (productId, Int(taken))
        }
    }

    /// Each line of the order at its price, by the shared rule — nil only when
    /// the rule could not be asked.
    func onlinePricing(_ order: OnlineOrder) async -> KhaytEngine.WebStorePricing? {
        guard let engine else { return nil }
        let lines: [JSONValue] = order.lines.map { line in
            var row: [String: JSONValue] = ["qty": .number(Double(max(1, line.qty)))]
            if let id = line.productId { row["productId"] = .string(id) }
            return .object(row)
        }
        // What this app's catalogue prices each product at — the fallback for a
        // product the storefront was never given a price for. Only a real
        // figure: a product with nothing to price it is not free.
        var computed: [String: Double] = [:]
        for row in catalogueRows where row.final > 0 && computed[row.id] == nil {
            computed[row.id] = row.final
        }
        return try? await engine.webStoreLinePrices(lines: lines, products: productRows,
                                                    settings: settingsValue, computed: computed)
    }

    /// The job this order becomes, COSTED.
    ///
    /// ── THE BUG THIS EXISTS TO NOT REPEAT ────────────────────────────────
    ///
    /// The first cut handed `newOrder` a list of parts carrying a name and a
    /// quantity and nothing else. A part with no grams and no hours costs
    /// nothing, so every online order Khayt recorded would have landed in the
    /// book priced at **zero** — in the column the whole business is measured
    /// in, without throwing anywhere. That is not hypothetical: it is exactly
    /// what `lib/storefront-orders.js` was written for, where a Salla total
    /// read from a field that does not exist became `0` for every order the
    /// shop ever imported.
    ///
    /// So a line that names a product brings that product's OWN parts, at the
    /// rates the catalogue priced them with — the same `jobParts(from:)` the
    /// counter sale and the new-job sheet use — multiplied by how many were
    /// ordered.
    ///
    /// ── PRICED AT WHAT THE CATALOGUE PUBLISHED ───────────────────────────
    ///
    /// Each line at the price the shop's catalogue published for it, times the
    /// quantity (`onlinePricing`). The parts carry the COST; the price is the
    /// figure the customer was shown. What the platform says was actually
    /// PAID — a keyed import carries each line's price — is the payment
    /// recorded, in `putOnlineOrder`; it is not the job's price, because it is
    /// after whatever discount the store was running.
    ///
    /// A line that names nothing this shop sells is a part with the customer's
    /// own words and no cost, which is what a request is. It prices at zero
    /// because it genuinely is not priced yet, and the screen said so before
    /// the shop pressed the button.
    func onlineJobInput(_ order: OnlineOrder) async -> [String: JSONValue] {
        var drafts: [NewJobSheet.Draft] = []
        // For each draft: the line it came from and its count per ONE piece,
        // so `printOnly` can size it to what the shelf cannot cover.
        var origin: [(line: Int, perPiece: Int)?] = []
        var margin = defaultMargin
        var onlyProduct: Product?
        var products = 0

        for (index, line) in order.lines.enumerated() {
            guard let id = line.productId,
                  let product = await productForEditing(id) else {
                var unpriced = NewJobSheet.Draft()
                unpriced.name = line.name
                unpriced.qty = max(1, line.qty)
                drafts.append(unpriced)
                origin.append(nil)
                continue
            }
            products += 1
            onlyProduct = products == 1 ? product : nil
            if products == 1 { margin = product.margin ?? defaultMargin }
            for var part in await jobParts(from: product) {
                // The product's part count is PER ONE. Six hoods is six times
                // each of a hood's parts.
                let perPiece = max(1, part.qty)
                part.qty = perPiece * max(1, line.qty)
                drafts.append(part)
                origin.append((index, perPiece))
            }
        }

        // ── EACH LINE AT ITS OWN PRICE, TIMES HOW MANY ────────────────────
        //
        // The parts above were multiplied by the quantity; the PRICE was not.
        // Handed the one product's rule, a product with a typed price brought
        // that price in as the whole job's total — three of a 50 product was a
        // job of 50, recorded as paid 50 — and a basket of two products lost
        // both typed prices and was priced at the first one's margin.
        //
        // So every line is priced by the shared rule
        // (`KhaytWebstoreOrder.linePrices`) at what the catalogue PUBLISHED for
        // it — the figure the customer was shown — else the product's typed
        // price, else what this app's catalogue computes it at; times the
        // line's quantity. The job's total is their sum, and travels as the
        // job's typed price so nothing re-derives it from a margin.
        var rule = onlyProduct.map(Self.priceRule(of:)) ?? PriceRule()
        if let pricing = await onlinePricing(order), pricing.priced {
            rule = PriceRule(override: pricing.total)
        }

        var input = newJobInput(
            parts: drafts, project: order.title, clientId: nil,
            margin: margin, discountPct: 0, shippingCost: 0, deposit: 0,
            rush: false, asQuote: false,
            // Only when the whole order IS that product. A basket of three
            // different things is not one of them, and stamping it with a
            // productId would report the sale against the wrong catalogue row
            // — and bring that product's packaging and assembly with it.
            fromProduct: onlyProduct,
            rule: rule)
        // The product's components are PER ONE assembled piece, and the shared
        // deduction draws `qtyPerUnit × assemblyQty`. Six hoods take six sets
        // of magnets, not one.
        if let onlyProduct {
            let ordered = order.lines.filter { $0.productId == onlyProduct.id }
                .reduce(0) { $0 + max(1, $1.qty) }
            if ordered > 1 {
                let perOne = Self.plainNumber(onlyProduct.rest["assemblyQty"]).map { max(1, $0) } ?? 1
                input["assemblyQty"] = .number(perOne * Double(ordered))
            }
        }

        input["source"] = .string(order.source.isEmpty ? "online" : order.source)
        // WHAT THE CUSTOMER CHOSE, where the person at the printer reads. A
        // product's parts say what to print; only the order says it was the
        // red one. Said after the description, one line per chosen line.
        let chosen = order.lines.filter { !$0.options.isEmpty }
            .map { "\($0.name) × \($0.qty) — \($0.optionText)" }
        input["notes"] = .string(([order.item.text("description") ?? ""] + chosen)
            .filter { !$0.isEmpty }.joined(separator: "\n"))
        // The platform's own reference, structured rather than only quoted in
        // the notes — it is the identity a retried delivery shares with its
        // first attempt. Same field `lib/lan-server.js` writes.
        if !order.item.reference.isEmpty {
            input["sourceOrderId"] = .string(order.item.reference)
        }
        // Whether it all comes off the shelf is decided again inside the write
        // (`putOnlineOrder`), against the count the book holds then; this is
        // what the screen showed.
        if order.allFromShelf { input["fromStock"] = .bool(true) }
        // Each product part remembers its line and its count per piece, so the
        // write can print only what the shelf does not cover (`printOnly`).
        if case .array(var rows)? = input["parts"], rows.count == origin.count {
            for (i, from) in origin.enumerated() {
                guard let from, case .object(var row) = rows[i] else { continue }
                row[Self.lineKey] = .number(Double(from.line))
                row[Self.perPieceKey] = .number(Double(from.perPiece))
                rows[i] = .object(row)
            }
            input["parts"] = .array(rows)
        }
        return input
    }

    static let lineKey = "_onlineLine"
    static let perPieceKey = "_onlinePerPiece"

    /// The job's parts sized to what the shelf does NOT cover.
    ///
    /// A mixed order — two from the shelf, one to print — took the shelf's two
    /// AND got parts for all three, so the shop printed (and the completion
    /// deducted filament for) pieces it had already handed out of stock. Each
    /// product line now prints `toPrint` pieces, as the reading taken INSIDE
    /// the write counts them; a line the shelf covers whole prints nothing. An
    /// order the shelf covers entirely keeps its parts — that job is recorded
    /// finished from stock, and its parts are what it cost.
    ///
    /// The markers are removed either way: they are this app's bookkeeping,
    /// not the book's.
    static func printOnly(_ input: [String: JSONValue], reading fresh: OnlineOrder) -> [String: JSONValue] {
        guard case .array(let rows)? = input["parts"] else { return input }
        var out = input
        var kept: [JSONValue] = []
        let lines = fresh.lines
        var scaledLines: [Int: (ordered: Int, toPrint: Int)] = [:]
        for row in rows {
            guard case .object(var part) = row else { kept.append(row); continue }
            let line = plainNumber(part[lineKey]).map { Int($0) }
            let perPiece = plainNumber(part[perPieceKey]).map { Int($0) }
            part.removeValue(forKey: lineKey)
            part.removeValue(forKey: perPieceKey)
            if !fresh.allFromShelf, let line, let perPiece, lines.indices.contains(line) {
                let l = lines[line]
                let ordered = max(1, l.qty)
                let toPrint = max(0, min(ordered, l.toPrint))
                scaledLines[line] = (ordered, toPrint)
                if toPrint == 0 { continue }
                let qty = Double(perPiece * toPrint)
                part["qty"] = .number(qty)
                if let unit = plainNumber(part["unitCost"]) { part["baseCost"] = .number(unit * qty) }
            }
            kept.append(.object(part))
        }
        out["parts"] = .array(kept)
        // The assembly count goes with it: a set of magnets per piece MADE.
        if scaledLines.count == 1, let only = scaledLines.values.first,
           let assembly = plainNumber(out["assemblyQty"]), only.toPrint < only.ordered {
            let perOne = max(1, assembly / Double(only.ordered))
            out["assemblyQty"] = .number(perOne * Double(max(1, only.toPrint)))
        }
        return out
    }
}
