import Foundation
import KhaytCore

/// One web-store order that became a job, for the notice and the sheet.
struct WebStoreArrival: Identifiable, Equatable, Sendable {
    /// The cloud's queue item it came from.
    let intakeId: String
    /// The platform's own reference, `medusa:#1042`.
    let reference: String
    let jobId: String
    let customer: String
    /// Made by the automatic pass, not by a button.
    let automatic: Bool

    var id: String { intakeId + "→" + jobId }
}

/// The web store's orders, both ways, with nobody pressing a button.
///
/// ── IN ─────────────────────────────────────────────────────────────────────
///
/// A paid order placed on the shop's storefront reaches Khayt Cloud's intake
/// queue within seconds (the Medusa subscriber, or a platform's own webhook,
/// POSTs it to `/import/{platform}`). Until this, it then sat there until
/// somebody opened Online orders and pressed a button — and a shop that sells
/// online does not open that sheet between customers.
///
/// Now this Mac looks every couple of minutes and records each PAID web-store
/// order itself, through exactly the write the button uses
/// (`writeOnlineOrder`): the job, the customer, the shelf and the payment.
/// What is not certainly a paid web-store order — a typed request, a Salla
/// cash-on-delivery order, one with no reference of its own — is left for a
/// person, and the sheet says why. `lib/webstore-order.js` decides.
///
/// ── NEVER TWICE ────────────────────────────────────────────────────────────
///
/// The write asks, inside the book's write chain, whether the book already
/// holds this platform order (by its reference) or this queue item. So a pass
/// that recorded an order and then failed to drain it simply drains it next
/// time, and two passes that overlap cannot make two jobs.
///
/// ── OUT ────────────────────────────────────────────────────────────────────
///
/// Khayt Cloud has no route for a job's progress yet. `WebStoreStatusPublisher`
/// is the Mac half against the contract in
/// docs/handoffs/webstore-order-status.md, and it goes quiet on the 404 a
/// cloud without the route answers — as the quote sheet did before its route
/// shipped.
@MainActor
extension Shop {

    /// How long after a book opens before the first look, and how often after.
    static let webStoreFirst: Duration = .seconds(20)
    static let webStoreEvery: Duration = .seconds(120)

    func startWatchingWebStoreOrders() {
        guard webStoreOrdersTask == nil else { return }
        webStoreOrdersTask = Task { [weak self] in
            try? await Task.sleep(for: Shop.webStoreFirst)
            while !Task.isCancelled {
                await self?.recordPaidWebStoreOrders()
                await self?.publishWebStoreStatuses()
                try? await Task.sleep(for: Shop.webStoreEvery)
            }
        }
    }

    func stopWatchingWebStoreOrders() {
        webStoreOrdersTask?.cancel()
        webStoreOrdersTask = nil
    }

    // MARK: - In

    /// Record every paid web-store order waiting in the queue. Returns how
    /// many became jobs on this pass.
    ///
    /// Only on the Mac holding the book: another machine that has it open
    /// read-only must not write, and would be refused if it tried.
    @discardableResult
    func recordPaidWebStoreOrders(fetch: CloudIntake.Fetch? = nil) async -> Int {
        guard case .store(let build) = source, cloudConnected, let engine,
              StoreLock.weOwnIt(build), !webStoreAutoBusy else { return 0 }
        webStoreAutoBusy = true
        defer { webStoreAutoBusy = false }

        let items: [CloudIntake.Item]
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { return 0 }
            items = try await CloudIntake.list(connection, token: token,
                                               fetch: fetch ?? Self.webStoreNetwork)
        } catch CloudIntake.Failure.notConnected {
            return 0
        } catch {
            webStoreAutoProblem = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            return 0
        }
        webStoreAutoProblem = nil

        var made = 0
        var changed = false
        for item in items where !webStoreGaveUp.contains(item.id) {
            // Read against the shelf as it is NOW — a previous order on this
            // pass may just have taken the last one.
            guard let order = try? await Self.onlineOrder(
                item, products: productRows, stock: Self.stockCounts(settingsDict), engine: engine),
                  let decision = order.decision, decision.auto else { continue }

            switch await writeOnlineOrder(order, paid: decision.paid) {
            case .failure(let problem):
                // Once per session. A write that fails will fail the same way
                // in two minutes, and the button is still there.
                webStoreGaveUp.insert(item.id)
                webStoreAutoProblem = problem.sentence
                continue
            case .success(.alreadyThere):
                break
            case .success(.made(let jobId, _, _, _)):
                made += 1
                webStoreArrived.append(WebStoreArrival(
                    intakeId: item.id, reference: item.reference, jobId: jobId,
                    customer: order.customer, automatic: true))
            }
            changed = true
            // Recorded, or found recorded: now it may leave the queue. A drain
            // that fails is tried again on the next pass, which finds the job
            // already in the book and writes nothing.
            if let problem = await drainOnlineOrder(order, fetch: fetch) {
                webStoreAutoProblem = problem
            }
            // The shelf and the catalogue the next order is read against.
            await load(source)
        }
        if changed, showingOnlineOrders { await readOnlineOrders(fetch: fetch) }
        return made
    }

    private static let webStoreNetwork: CloudIntake.Fetch = { request in
        try await URLSession(configuration: .ephemeral).data(for: request)
    }

    /// The web-store jobs in the book, newest first — what the Online orders
    /// sheet shows as "became jobs". Read from the book, so it survives a
    /// restart and includes what another Mac or the desktop recorded.
    func webStoreJobs(limit: Int = 8) -> [WebStoreJob] {
        let rows = orderRows.compactMap { row -> WebStoreJob? in
            guard case .object(let o) = row,
                  let id = Self.plainString(o["id"]),
                  let ref = Self.plainString(o["sourceOrderId"]), !ref.isEmpty else { return nil }
            let paid = Self.plainString(o["paymentStatus"]) == "paid"
            return WebStoreJob(
                jobId: id, reference: ref,
                project: Self.plainString(o["project"]) ?? "",
                customer: Self.plainString(o["client"]) ?? "",
                status: Self.plainString(o["status"]) ?? "",
                shipped: Self.plainString(o["shippedAt"]) != nil,
                delivered: Self.plainString(o["deliveredAt"]) != nil,
                paid: paid,
                at: Self.plainString(o["timestamp"]) ?? Self.plainString(o["date"]) ?? "")
        }
        return Array(rows.sorted { $0.at > $1.at }.prefix(limit))
    }

    struct WebStoreJob: Identifiable, Equatable, Sendable {
        let jobId: String
        let reference: String
        let project: String
        let customer: String
        let status: String
        let shipped: Bool
        let delivered: Bool
        let paid: Bool
        let at: String
        var id: String { jobId }

        /// The stage a person reads, as the board names it.
        var stage: Stage? {
            if delivered { return .delivered }
            if shipped { return .shipped }
            return Stage(rawValue: status)
        }
    }

    // MARK: - Out

    /// Tell the store where each web-store job has got to — what changed
    /// since it was last told.
    ///
    /// `sent` is this Mac's memory of what it delivered, per shop. Losing it
    /// costs a resend of every unfinished order's state, which is harmless:
    /// each update is a STATE, and the store applies it idempotently.
    func publishWebStoreStatuses(fetch: CloudIntake.Fetch? = nil,
                                 memory: UserDefaults = .standard) async {
        guard let build = source.build, cloudConnected, let engine,
              !webStoreStatusNotOffered else { return }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let key = Self.webStoreSentKey(connection.shopId)
            var sent = (memory.dictionary(forKey: key) as? [String: String]) ?? [:]
            // Finished business older than a month is not news.
            let notBefore = StoreWriter.iso(Date().addingTimeInterval(-30 * 86_400))
            let owed = try await engine.webStoreStatusesOwed(printLog: orderRows, sent: sent,
                                                             notBefore: notBefore)
            guard !owed.isEmpty else { return }
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { return }
            try await WebStoreStatusPublisher.publish(connection, token: token, updates: owed,
                                                      fetch: fetch ?? Self.webStoreNetwork)
            for update in owed {
                sent[update.ref] = try await engine.webStoreFingerprint(update)
            }
            memory.set(sent, forKey: key)
            webStoreStatusSaid = words.callIt("mac.webstore_status_sent",
                                              ["n": .number(Double(owed.count))])
        } catch CloudReader.Failure.notConnected {
            webStoreStatusSaid = nil
        } catch WebStoreStatusPublisher.Failure.notOffered {
            // Khayt Cloud has not shipped the route. Expected until it does;
            // said once on the sheet, not raised.
            webStoreStatusNotOffered = true
            webStoreStatusSaid = words.callIt("mac.webstore_status_not_offered")
        } catch {
            webStoreStatusSaid = words.callIt("mac.webstore_status_failed") + " "
                + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    static func webStoreSentKey(_ shopId: String) -> String {
        "khayt.webStoreStatusSent." + shopId
    }
}

/// Sending a job's progress to Khayt Cloud, for the store to pick up.
///
/// `POST /v1/shops/{shopId}/order-status` with `{ updates: [...] }` — the
/// contract in docs/handoffs/webstore-order-status.md, which Khayt Cloud has
/// not built yet. Built on `CloudReader.request` for the `x-delta-capable`
/// header every route records (see `CloudIntake`).
@MainActor
enum WebStoreStatusPublisher {
    enum Failure: Error, LocalizedError, Equatable {
        case unauthorised
        case readOnly
        /// The cloud has no such route yet. Expected; said quietly.
        case notOffered
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorised: "Khayt Cloud did not accept this shop's token."
            case .readOnly: "This sign-in can read this shop but not update its orders."
            case .notOffered: "Khayt Cloud does not take order statuses yet."
            case .http(let code, let body):
                "Khayt Cloud answered \(code)" + (body.isEmpty ? "" : ": \(body)")
            }
        }
    }

    private struct Body: Encodable { let updates: [KhaytEngine.WebStoreStatus] }

    static func publish(_ connection: CloudReader.Connection, token: String,
                        updates: [KhaytEngine.WebStoreStatus],
                        fetch: CloudIntake.Fetch) async throws {
        var request = try CloudReader.request(connection, token: token, method: "POST",
                                              tail: "/order-status")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(updates: updates))
        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200, 204: return
        case 401: throw Failure.unauthorised
        case 403: throw Failure.readOnly
        case 404, 405: throw Failure.notOffered
        case let code: throw Failure.http(code, CloudWriter.said(data))
        }
    }
}
