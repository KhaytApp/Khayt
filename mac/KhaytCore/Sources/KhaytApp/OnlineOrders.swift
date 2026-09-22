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

            var id: String { name + "×" + String(qty) + (productId ?? "") }
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
                read.append(OnlineOrder(
                    item: item,
                    reading: try await engine.shelfSaleReading(payload: item.payload,
                                                              products: productRows,
                                                              stock: stock)))
            }
            onlineOrders = read
        } catch {
            onlineOrders = []
            onlineProblem = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
    }

    /// `settings.storefront.stockQty`, or an empty map.
    static func stockCounts(_ settings: [String: JSONValue]) -> JSONValue {
        guard case .object(let store)? = settings["storefront"],
              case .object(let counts)? = store["stockQty"] else { return .object([:]) }
        return .object(counts)
    }

    private static let overTheNetwork: CloudIntake.Fetch = { request in
        try await URLSession(configuration: .ephemeral).data(for: request)
    }

    // MARK: - Recording one

    /// Write the order into the book, take what it used off the shelf, and
    /// only then drop it from the queue.
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
        guard case .store(let build) = source, let engine else { return }
        onlineProblem = nil
        onlineBusy = true
        defer { onlineBusy = false }

        let now = Date()
        let effects = (try? await engine.shelfSaleEffects(order.reading, at: now)) ?? []
        let deductions = Self.deductions(effects)

        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                let orders = Self.rows(root, "printLog")
                let out = try await engine.newOrder(
                    await onlineJobInput(order), orders: orders,
                    settings: Self.settings(root), now: now,
                    tokens: (tracking: Self.randomBytes(16),
                             quoteApproval: Self.randomBytes(16)))
                guard case .object(var record) = out.order else { return }
                if order.allFromShelf {
                    // Nothing about this waits on a machine. A shelf sale
                    // under Pending is a job somebody goes looking for a free
                    // printer to start.
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
                root["printLog"] = .array([.object(record)] + orders)

                // ONE settings write, and it starts from `out.settings`.
                //
                // `newOrder` advances the shop's invoice or quote counter and
                // hands the settings back with it advanced; the shelf is a
                // different corner of the same object. Writing the shelf first
                // and the counter second put the shelf back as it was, because
                // `out.settings` was read before the deduction — a bug that
                // costs a customer-visible number and nothing else notices.
                var settings = out.settings
                for (productId, taken) in deductions {
                    // Against the count THE BOOK holds now, not the one the
                    // screen was drawn from — see `deductions`. Never below
                    // nothing, and a product that has stopped being counted at
                    // all is left uncounted rather than invented at zero.
                    guard let onShelf = Self.stockCount(of: productId,
                                                        in: .object(settings)) else { continue }
                    // Re-dated even when the figure lands where it already
                    // was: a count carries the date it was taken, and this one
                    // is current as of now.
                    Self.putStockCount(max(0, onShelf - taken), for: productId,
                                       into: &settings, at: now)
                }
                root["settings"] = .object(settings)
            }
        } catch {
            onlineProblem = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            return
        }

        // Written. Now, and only now, take it out of the queue.
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            try await CloudIntake.drain(connection, token: token, id: order.id,
                                        fetch: fetch ?? Self.overTheNetwork)
            onlineOrders.removeAll { $0.id == order.id }
        } catch {
            onlineProblem = words.callIt("mac.online_kept_in_queue") + " "
                + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        await reload()
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
    /// ── AND THE STOREFRONT'S FIGURE IS NOT USED ──────────────────────────
    ///
    /// Deliberately, and it is not even in the payload: khayt-cloud's
    /// `mapPlatformOrder` does not carry money across. It would be the wrong
    /// number anyway — the storefront's total is after its own tax, shipping
    /// and whatever discount it was running, in whatever currency it charges.
    /// The shop's book is kept in the shop's money, and the price the shop
    /// would charge for this work is the one its catalogue already says.
    ///
    /// A line that names nothing this shop sells is a part with the customer's
    /// own words and no cost, which is what a request is. It prices at zero
    /// because it genuinely is not priced yet, and the screen said so before
    /// the shop pressed the button.
    func onlineJobInput(_ order: OnlineOrder) async -> [String: JSONValue] {
        var drafts: [NewJobSheet.Draft] = []
        var margin = defaultMargin
        var onlyProduct: Product?
        var products = 0

        for line in order.lines {
            guard let id = line.productId,
                  let product = await productForEditing(id) else {
                var unpriced = NewJobSheet.Draft()
                unpriced.name = line.name
                unpriced.qty = max(1, line.qty)
                drafts.append(unpriced)
                continue
            }
            products += 1
            onlyProduct = products == 1 ? product : nil
            if products == 1 { margin = product.margin ?? defaultMargin }
            for var part in await jobParts(from: product) {
                // The product's part count is PER ONE. Six hoods is six times
                // each of a hood's parts.
                part.qty = max(1, part.qty) * max(1, line.qty)
                drafts.append(part)
            }
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
            rule: onlyProduct.map(Self.priceRule(of:)) ?? PriceRule())

        input["source"] = .string(order.source.isEmpty ? "online" : order.source)
        input["notes"] = .string(order.item.text("description") ?? "")
        // The platform's own reference, structured rather than only quoted in
        // the notes — it is the identity a retried delivery shares with its
        // first attempt. Same field `lib/lan-server.js` writes.
        if !order.item.reference.isEmpty {
            input["sourceOrderId"] = .string(order.item.reference)
        }
        if order.allFromShelf { input["fromStock"] = .bool(true) }
        return input
    }
}
