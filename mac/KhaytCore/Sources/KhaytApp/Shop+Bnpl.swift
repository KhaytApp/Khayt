import Foundation
import AppKit
import KhaytCore

/// Tabby and Tamara pay-later links: made from a job, and finished on their own.
///
/// ── WHAT THE DESKTOP DOES, AND THIS DOES THE SAME ─────────────────────────
///
/// A link is made from the job (`renderer/integrations.js openBnplModal`): the
/// job's price, its document number as the reference, the customer's name,
/// phone and email. The provider's id for it is remembered on the job as
/// `order.bnplLinks[]` (`lib/bnpl-confirm.js linkRecord` / `addLink`).
///
/// Neither provider can tell Khayt the customer has paid — Khayt has no public
/// address — so while the app is open it ASKS (`renderer/bnpl-watch.js`):
/// every open link younger than 30 days is checked, the step the provider is
/// waiting for is taken (Tamara's authorise, due within 72 hours of approval;
/// Tabby's capture, without which nothing is settled), and a paid link is
/// recorded on its job through the payment rule, with the receipt email and
/// webhooks the Record Payment sheet would send. A Tamara order Khayt
/// authorised is then captured once its job has shipped or been handed over.
///
/// The requests themselves are `lib/bnpl-requests.js`, carried by
/// `BnplClient`; the record-keeping is the shared rules', called through the
/// engine. Nothing here decides what "paid" means.
///
/// ── HOW OFTEN ─────────────────────────────────────────────────────────────
///
/// Every ten minutes, as the desktop does, and when the app comes to the front
/// — at most once a minute. A provider that answers 429 holds the watch off for
/// an hour. A link that cannot be checked is left open and asked about again
/// next time, quietly; only a STEP that failed (an authorise or a capture
/// refused) is said, because that is money waiting on the shop.
extension Shop {

    static let bnplWatchEvery: Duration = .seconds(10 * 60)
    static let bnplWatchMinGap: TimeInterval = 60
    static let bnplWatchBackOff: TimeInterval = 60 * 60
    static let bnplProviders = ["tabby", "tamara"]

    /// The real round trip; a test puts a stub here. No test reaches a provider.
    nonisolated(unsafe) static var bnplFetch: BnplClient.Fetch = { r in try await URLSession.shared.data(for: r) }

    // MARK: - Settings

    /// `settings.bnpl[provider]`, as stored.
    func bnplConfig(_ provider: String) -> [String: JSONValue] {
        guard case .object(let b)? = settingsDict["bnpl"], case .object(let row)? = b[provider] else { return [:] }
        return row
    }

    /// Switched on (`bnplWatchEnabled`).
    func bnplEnabled(_ provider: String) -> Bool {
        Self.plainBool(bnplConfig(provider)["enabled"]) == true
    }

    /// The providers a link can be made with now: switched on AND holding a
    /// key — the desktop's pay-later dialog lists exactly these.
    var bnplProvidersOffered: [String] {
        Self.bnplProviders.filter { bnplEnabled($0) && !(Self.plainString(bnplConfig($0)["apiKey"]) ?? "").isEmpty }
    }

    /// Whether a job offers "Pay later link": Tabby or Tamara switched on, as
    /// the desktop's card button is offered on any job then.
    func offersBnpl(_ job: Order?) -> Bool {
        job != nil && Self.bnplProviders.contains(where: bnplEnabled)
    }

    /// The shop's key for a provider, opened from the book — never what a
    /// field holds.
    private func bnplKey(_ provider: String) async throws -> String {
        try await Secrets.open(Self.plainString(bnplConfig(provider)["apiKey"]) ?? "", for: source)
    }

    // MARK: - Making a link

    /// What making a link came to: the link, or the provider's own words.
    struct BnplLinkOutcome: Equatable {
        var url: String?
        var problem: String?
        /// False when the provider gave a link but no id to follow, so this
        /// app cannot finish the payment by itself.
        var watched = false
    }

    /// Make a checkout link for job `id`, and remember it on the job so the
    /// watch can finish the payment.
    func makeBnplLink(_ id: Order.ID, provider: String) async -> BnplLinkOutcome {
        guard permitted("invoicing", "edit") else {
            return BnplLinkOutcome(problem: words.callIt(needsSignIn ? "mac.lock_sign_in_first" : "mac.lock_not_allowed"))
        }
        guard Self.bnplProviders.contains(provider) else { return BnplLinkOutcome(problem: "Unknown provider") }
        guard source.build != nil else { return BnplLinkOutcome(problem: words.callIt("mac.move_sample")) }
        guard let engine, let raw = portalRecord(id) else { return BnplLinkOutcome(problem: words.callIt("mac.move_gone")) }
        let result: BnplResult
        let args: JSONValue
        do {
            let order = JSONValue.object(raw)
            args = try await engine.bnplCheckoutArgs(
                order: order, provider: provider, settings: settingsDict, clients: clientRows,
                buyerName: Self.emailClientName(for: raw, in: clientRows))
            let key = try await bnplKey(provider)
            result = try await BnplClient.run("checkout", args: args, key: key, engine: engine, fetch: Self.bnplFetch)
        } catch {
            return BnplLinkOutcome(problem: said(error))
        }
        guard result.ok, let url = result.url, !url.isEmpty else {
            return BnplLinkOutcome(problem: result.error ?? "Failed")
        }
        // Remembered on the job, as the desktop does it — only for a link the
        // provider actually made. Not on Undo: taking the record back would
        // leave a customer's payment nobody finishes.
        let amount: Double = {
            if case .object(let a) = args { return Self.plainNumber(a["amount"]) ?? 0 }
            return 0
        }()
        let currency = Self.plainString(bnplConfig(provider)["currency"]).flatMap { $0.isEmpty ? nil : $0 } ?? "SAR"
        var watched = false
        await writeToOneOrder(id, named: words.callIt("mac.bnpl_title"), as: .person("invoicing", "edit"),
                              undoable: false) { order, engine, _ in
            guard let next = try await engine.bnplAddLink(
                order: order, provider: provider, created: result, amount: amount, currency: currency,
                at: ISO8601DateFormatter.bnpl.string(from: Date())) else { return OneOrderEdit(order: order) }
            watched = true
            return OneOrderEdit(order: next)
        }
        return BnplLinkOutcome(url: url, problem: nil, watched: watched)
    }

    // MARK: - The watch

    func startWatchingBnpl() {
        guard bnplWatchTask == nil else { return }
        bnplWatchTask = Task { [weak self] in
            // After the window has settled, as the desktop waits 20 s.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.checkBnplNow()
                try? await Task.sleep(for: Self.bnplWatchEvery)
            }
        }
        if bnplWatchObserver == nil {
            bnplWatchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.checkBnplNow() }
                }
            }
        }
    }

    func stopWatchingBnpl() {
        bnplWatchTask?.cancel()
        bnplWatchTask = nil
        if let token = bnplWatchObserver { NotificationCenter.default.removeObserver(token) }
        bnplWatchObserver = nil
    }

    /// One look at every open link: never two at a time, and one failing link
    /// never stops the rest (`checkBnplLinks`).
    func checkBnplNow(now: Date = Date()) async {
        guard !bnplWatchBusy, let engine, source.build != nil else { return }
        guard Self.bnplProviders.contains(where: bnplEnabled) else { return }
        if let notBefore = bnplWatchNotBefore, now < notBefore { return }
        if let last = bnplWatchedAt, now.timeIntervalSince(last) < Self.bnplWatchMinGap { return }
        bnplWatchBusy = true
        defer { bnplWatchBusy = false }
        bnplWatchedAt = now
        let at = ISO8601DateFormatter.bnpl.string(from: now)
        // lock: system — a payment the customer made at their provider, finished and recorded; no person acts here.
        let due = (try? await engine.bnplLinksToCheck(orders: orderRows, now: at)) ?? []
        for link in due {
            let r: BnplResult
            do {
                let key = try await bnplKey(link.provider)
                r = try await BnplClient.run("check", args: .object([
                    "provider": .string(link.provider), "id": .string(link.id),
                    "currency": link.currency.map(JSONValue.string) ?? .null,
                ]), key: key, engine: engine, fetch: Self.bnplFetch)
            } catch {
                continue   // the Keychain, or the engine: quietly, and again next time
            }
            if r.status == 429 { bnplWatchNotBefore = now.addingTimeInterval(Self.bnplWatchBackOff); break }
            await recordBnplCheck(link, result: r, at: at)
        }
        await captureShippedTamara(now: now)
    }

    /// Write what one check found onto its job — as `checkBnplLinks` does,
    /// against the job as it is NOW (it may have changed while the provider
    /// was being asked).
    func recordBnplCheck(_ link: KhaytEngine.BnplDue, result r: BnplResult, at: String) async {
        guard let engine, let raw = portalRecord(link.orderId) else { return }
        let today = Self.localDay()
        // A look before the write: most checks find nothing new, and a write
        // that changes nothing still takes the book's lock.
        guard let peek = try? await engine.bnplApplyCheck(
            order: .object(raw), provider: link.provider, id: link.id, result: r, today: today, at: at)
        else { return }
        let name = link.provider == "tamara" ? "Tamara" : "Tabby"
        let project = Self.plainString(raw["project"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.plainString(raw["jobNumber"]) ?? link.orderId
        switch peek.outcome {
        case "failed":
            if peek.stepFailed == true {
                moveNotices.append(words.callIt("bnpl.confirm_failed", [
                    "service": .string(name), "project": .string(project), "error": .string(r.error ?? "")]))
            }
            return
        case "gone", "same":
            return
        default:
            break
        }

        let keptProblem = moveProblem
        let keptNotices = moveNotices
        var outcome = ""
        var owed: [KhaytEngine.WebhookDelivery] = []
        var mail: OrderEmail?
        // Not on Undo: putting the link back to open would have the next look
        // record the same payment again.
        let wrote = await writeToOneOrder(link.orderId, named: words.callIt("pay.modal_title"),
                                          as: .system("a pay-later payment the provider confirmed"),
                                          undoable: false) { order, engine, root in
            let settings = Self.settings(root)
            let clients = Self.rows(root, "clients")
            let checked = try await engine.bnplApplyCheck(
                order: order, provider: link.provider, id: link.id, result: r, today: today, at: at)
            outcome = checked.outcome
            guard checked.outcome == "paid", let pay = checked.payment else {
                return OneOrderEdit(order: checked.order)
            }
            // The same question `recordPayment` asks before keeping money.
            let reaches = (try? await engine.paymentOutbound(
                order: checked.order, settings: settings, clients: clients)) ?? []
            let cannotSend = await Self.channelsThisAppCannotSend(reaches, settings: settings, engine: engine)
            if !cannotSend.isEmpty {
                throw MoveRefused(sentence: self.words.outboundRefusal(cannotSend))
            }
            let done = try await engine.recordPayment(
                order: checked.order, amount: pay.amount, method: pay.method,
                paidAt: pay.paidAt ?? today, today: today, settings: settings)
            if let asked = done.webhookEffects, !asked.isEmpty {
                owed = (try? await engine.webhookDeliveries(
                    order: done.order, effects: asked, settings: settings,
                    shopName: Self.plainString(settings["bizEn"])
                        ?? Self.plainString(settings["bizAr"]) ?? "Khayt",
                    clientName: Self.emailClientName(for: Self.asObject(done.order) ?? [:], in: clients),
                    currency: Self.shopCurrencyOf(settings),
                    at: ISO8601DateFormatter().string(from: Date()),
                    nowMs: Date().timeIntervalSince1970 * 1000)) ?? []
            }
            mail = await Self.paymentEmail(
                after: done, settings: settings, clients: clients, engine: engine,
                statusLabel: self.words.callIt("mac.payment_received_label"))
            return OneOrderEdit(order: done.order)
        }
        // Quiet: a refused write (a channel this app cannot send on) leaves the
        // link open and is asked about again; the shop's own banner is theirs.
        guard wrote else { moveProblem = keptProblem; moveNotices = keptNotices; return }
        moveNotices = keptNotices
        guard outcome == "paid" else { return }
        moveNotices.append(words.callIt("bnpl.confirmed", ["service": .string(name), "project": .string(project)]))
        if let mail { await post(mail) }
        if !owed.isEmpty { await fire(owed) }
        await republishPortalIfPublished(link.orderId)
    }

    /// Tamara: capture each authorised order whose job has gone out
    /// (`captureShippedTamara`, rule `linksToCapture`).
    func captureShippedTamara(now: Date = Date()) async {
        guard let engine, source.build != nil, bnplEnabled("tamara") else { return }
        if let notBefore = bnplWatchNotBefore, now < notBefore { return }
        let at = ISO8601DateFormatter.bnpl.string(from: now)
        let due = (try? await engine.bnplLinksToCapture(orders: orderRows, now: at)) ?? []
        for link in due {
            let r: BnplResult
            do {
                let key = try await bnplKey("tamara")
                r = try await BnplClient.run("capture", args: .object([
                    "provider": .string("tamara"), "id": .string(link.id), "shipping": link.shipping ?? .null,
                ]), key: key, engine: engine, fetch: Self.bnplFetch)
            } catch { continue }
            if r.status == 429 { bnplWatchNotBefore = now.addingTimeInterval(Self.bnplWatchBackOff); break }
            guard let raw = portalRecord(link.orderId),
                  let peek = try? await engine.bnplApplyCapture(order: .object(raw), id: link.id, result: r, at: at),
                  peek.changed else { continue }
            let keptProblem = moveProblem
            let keptNotices = moveNotices
            var say: String?
            // lock: system — Tamara told the shipment the shop already made; no person acts here.
            let wrote = await writeToOneOrder(link.orderId, named: words.callIt("pay.modal_title"),
                                              as: .system("Tamara told a shipment the shop made"),
                                              undoable: false) { order, engine, _ in
                let out = try await engine.bnplApplyCapture(order: order, id: link.id, result: r, at: at)
                say = out.sayFailure ? out.error : nil
                return OneOrderEdit(order: out.order)
            }
            moveProblem = keptProblem
            moveNotices = keptNotices
            if wrote, let err = say {
                let project = Self.plainString(raw["project"]).flatMap { $0.isEmpty ? nil : $0 }
                    ?? Self.plainString(raw["jobNumber"]) ?? link.orderId
                moveNotices.append(words.callIt("bnpl.capture_failed", [
                    "project": .string(project), "error": .string(err)]))
            }
        }
    }
}

extension ISO8601DateFormatter {
    /// `new Date().toISOString()`: UTC, with milliseconds.
    static var bnpl: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}
