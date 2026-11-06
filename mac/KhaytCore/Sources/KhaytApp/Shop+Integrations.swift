import Foundation
import KhaytCore

/// Integrations sent from this Mac: texts through the shop's SMS provider,
/// webhook deliveries with their log and retries, paid invoices pushed to the
/// accounting system, and the shop's own scheduled KPI email.
///
/// ── THE RULES ARE SHARED, THE SENDING IS HERE ─────────────────────────────
///
/// Each of these the desktop has done for a long time, from the same book.
/// What is decided — which request a provider gets, when an invoice is owed a
/// push, when the digest is due and what it says, how a failed delivery is
/// retried — is `lib/` (`sms-request.js`, `accounting-push.js`,
/// `email-digest.js`, `webhook-bus.js`), asked through `KhaytEngine`. This file
/// opens the sealed secrets at the point of use, posts, and writes down what
/// happened, in the fields the desktop writes.
///
/// ── NEVER TWICE, NEVER ON THE MAIN THREAD ─────────────────────────────────
///
/// Every send goes through `WebhookClient.post` (Network.framework, off the
/// main thread, both SSRF guards, no redirects) and is held in an in-flight
/// set for as long as it is out, so a second click or an overlapping pass
/// cannot send it again. What records a send — `accountingPushedAt`, the
/// digest's `lastSentDate`, the delivery log — is what stops the next pass
/// and the other app from sending it again.
///
/// ── OFF UNTIL SWITCHED ON ─────────────────────────────────────────────────
///
/// Nothing here sends unless the book's own switch is on: a provider other
/// than `none`, `webhooks.enabled`, `eventWebhooks.enabled`,
/// `accountingSync.enabled`, `emailDigest.enabled`. Every one defaults off.
/// And only on the Mac HOLDING the book: another machine with it open
/// read-only must not send for it.
@MainActor
extension Shop {

    // MARK: - The pass

    static let integrationsFirst: Duration = .seconds(45)
    static let integrationsEvery: Duration = .seconds(300)

    func startIntegrationsPass() {
        guard integrationsTask == nil else { return }
        integrationsTask = Task { [weak self] in
            try? await Task.sleep(for: Shop.integrationsFirst)
            while !Task.isCancelled {
                await self?.runIntegrationsPass()
                try? await Task.sleep(for: Shop.integrationsEvery)
            }
        }
    }

    func stopIntegrationsPass() {
        integrationsTask?.cancel()
        integrationsTask = nil
    }

    /// What is due now, in one pass. Quiet: a background send that fails is
    /// written to its own record (the delivery log, the order, nothing for the
    /// digest — it is tried again next hour), never thrown at whatever the
    /// shop is doing on screen.
    func runIntegrationsPass() async {
        guard let build = source.build, StoreLock.weOwnIt(build) else { return }
        await retryDueWebhooks()
        await retryFailedAccountingPushes()
        await sendDigestIfDue()
    }

    /// The book's writes in this file go through here: one read-modify-write
    /// of the settings block, on the book as it is on disk.
    private func updateSettingsOnDisk(_ change: @escaping (inout [String: JSONValue]) async throws -> Void) async -> Bool {
        guard let build = source.build else { return false }
        do {
            // lock: callers — recordWebhookAttempts, dropWebhookRetries, sendDigestIfDue
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                try await change(&settings)
                root["settings"] = .object(settings)
            }
            await load(source)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Webhooks: sending, the log and retries

    /// One attempt at one delivery, and what came of it. The secret is opened
    /// here and goes into the signature and nowhere else.
    struct WebhookTry: Sendable {
        let delivery: KhaytEngine.WebhookDelivery
        let status: Int?
        let error: String?
        var ok: Bool { error == nil && status.map { (200..<300).contains($0) } == true }
    }

    func attemptWebhook(_ one: KhaytEngine.WebhookDelivery) async -> WebhookTry {
        guard let engine else { return WebhookTry(delivery: one, status: nil, error: words.callIt("mac.move_no_engine")) }
        guard let url = URL(string: one.url) else {
            return WebhookTry(delivery: one, status: nil, error: words.callIt("mac.webhook_bad_url"))
        }
        guard !webhookInFlight.contains(one.deliveryId) else {
            return WebhookTry(delivery: one, status: nil, error: words.callIt("mac.hook_in_flight"))
        }
        webhookInFlight.insert(one.deliveryId)
        defer { webhookInFlight.remove(one.deliveryId) }
        do {
            // SEALED SECRETS ARE OPENED AT THE POINT OF USE (see `fire`).
            let secret = try await Secrets.open(one.secret, for: source)
            let status = try await WebhookClient.deliver(one.body, to: url, secret: secret,
                                                         event: one.event, engine: engine)
            return WebhookTry(delivery: one, status: status,
                              error: (200..<300).contains(status) ? nil : "HTTP \(status)")
        } catch {
            return WebhookTry(delivery: one, status: nil,
                              error: (error as? LocalizedError)?.errorDescription ?? self.said(error))
        }
    }

    /// Write attempts into the delivery log, queue the retries they are owed,
    /// and wake up for the soonest. Only deliveries with a subscription are
    /// logged — a test ping is not a delivery, as on the desktop.
    func recordWebhookAttempts(_ tries: [WebhookTry]) async {
        // lock: system — the log of deliveries the shop's own action already made, and their retries
        let logged = tries.filter { !($0.delivery.subscriptionId ?? "").isEmpty }
        guard !logged.isEmpty, let engine else { return }
        var soonest: Double?
        let at = ISO8601DateFormatter().string(from: Date())
        let nowMs = Date().timeIntervalSince1970 * 1000
        _ = await updateSettingsOnDisk() { settings in
            var wh = settings["webhooks"] ?? .object([:])
            for t in logged {
                let next = try await engine.webhookAttempt(webhooks: wh, delivery: t.delivery, status: t.status,
                                                           error: t.ok ? nil : t.error, nowMs: nowMs, at: at)
                wh = next.webhooks
                if next.retry { soonest = min(soonest ?? next.afterMs, next.afterMs) }
            }
            settings["webhooks"] = wh
        }
        // The ladder's early rungs (30 s, 2 min) are sooner than the pass; a
        // one-off wake keeps them. The queue is on disk either way.
        if let soonest, soonest <= 600_000 {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(soonest) + 500))
                await self?.retryDueWebhooks()
            }
        }
    }

    /// Send every queued retry whose time has come, including ones that came
    /// due while the app was closed. A retry for a subscription the shop has
    /// since removed or switched off is dropped, never sent.
    func retryDueWebhooks() async {
        guard let engine, let build = source.build, StoreLock.weOwnIt(build) else { return }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let at = ISO8601DateFormatter().string(from: Date())
        guard let due = try? await engine.webhookDue(settingsDict["webhooks"] ?? .null, nowMs: nowMs),
              !due.isEmpty else { return }
        var send: [KhaytEngine.WebhookDelivery] = []
        var drop: [String] = []
        for entry in due {
            guard case .object(let e) = entry, let id = Self.plainString(e["id"]) else { continue }
            if webhookInFlight.contains(id) { continue }
            if let one = try? await engine.webhookRedelivery(entry, settings: settingsDict, resend: false,
                                                             nowMs: nowMs, at: at) {
                send.append(one)
            } else {
                drop.append(id)
            }
        }
        if !drop.isEmpty { await dropWebhookRetries(drop) }
        var tries: [WebhookTry] = []
        for one in send { tries.append(await attemptWebhook(one)) }
        await recordWebhookAttempts(tries)
    }

    private func dropWebhookRetries(_ ids: [String]) async {
        // lock: system — forgets retries for subscriptions the shop already removed
        guard let engine else { return }
        _ = await updateSettingsOnDisk() { settings in
            settings["webhooks"] = try await engine.webhookDropPending(settings["webhooks"] ?? .null, ids: ids)
        }
    }

    /// The delivery log, newest first, as the settings screen lists it.
    struct WebhookLogLine: Identifiable, Hashable, Sendable {
        let id: String
        let subscriptionId: String
        let event: String
        let at: String
        let status: String
        let httpStatus: Int?
        let attempts: Int
        let error: String?
    }

    var webhookLog: [WebhookLogLine] { Self.webhookLog(in: settingsDict) }

    static func webhookLog(in settings: [String: JSONValue]) -> [WebhookLogLine] {
        guard case .object(let wh)? = settings["webhooks"], case .array(let rows)? = wh["deliveries"] else { return [] }
        var seen = Set<String>()
        return rows.reversed().compactMap { row -> WebhookLogLine? in
            guard case .object(let o) = row, let id = plainString(o["id"]), !id.isEmpty else { return nil }
            // A retry writes a line under the same id; the newest is the answer.
            let key = id + "|" + (plainString(o["at"]) ?? "")
            guard seen.insert(key).inserted else { return nil }
            return WebhookLogLine(
                id: key, subscriptionId: plainString(o["subscriptionId"]) ?? "",
                event: plainString(o["event"]) ?? "", at: plainString(o["at"]) ?? "",
                status: plainString(o["status"]) ?? "failed",
                httpStatus: plainNumber(o["httpStatus"]).map { Int($0) },
                attempts: plainNumber(o["attempts"]).map { Int($0) } ?? 1,
                error: plainString(o["error"]))
        }
    }

    /// Send a logged delivery again, as the desktop's Resend does: a fresh
    /// id, the same payload, to the subscription as it is now. Returns what
    /// to tell the shop.
    func resendWebhook(_ line: WebhookLogLine) async -> String {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard lockAllows("settings", "edit") else { return words.callIt("mac.lock_not_allowed") }
        guard case .object(let wh)? = settingsDict["webhooks"], case .array(let rows)? = wh["deliveries"],
              let record = rows.last(where: { row in
                  guard case .object(let o) = row else { return false }
                  return (Self.plainString(o["id"]) ?? "") + "|" + (Self.plainString(o["at"]) ?? "") == line.id
              }) else { return words.callIt("mac.hook_resend_gone") }
        let nowMs = Date().timeIntervalSince1970 * 1000
        guard let one = try? await engine.webhookRedelivery(record, settings: settingsDict, resend: true, nowMs: nowMs,
                                                            at: ISO8601DateFormatter().string(from: Date())) else {
            return words.callIt("mac.hook_resend_gone")
        }
        let tried = await attemptWebhook(one)
        await recordWebhookAttempts([tried])
        return tried.ok ? "✓ " + words.callIt("hook.delivered") : "✗ " + (tried.error ?? "")
    }

    /// The desktop's "Test (send ping)": one ping to this address, signed with
    /// the shop's signing secret. Not logged — a test is not a delivery.
    func testWebhook(url: String) async -> String {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard lockAllows("settings", "edit") else { return words.callIt("mac.lock_not_allowed") }
        var secret = ""
        if case .object(let wh)? = settingsDict["webhooks"] { secret = Self.plainString(wh["secret"]) ?? "" }
        guard let one = try? await engine.webhookPing(url: url, secret: secret,
                                                      nowMs: Date().timeIntervalSince1970 * 1000) else {
            return words.callIt("mac.move_no_engine")
        }
        let tried = await attemptWebhook(one)
        return tried.ok ? "✓ " + words.callIt("hook.delivered") : "✗ " + (tried.error ?? "")
    }

    /// The desktop's "Test (send sample)" for the signed event webhook.
    func testEventWebhook() async -> String {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard lockAllows("settings", "edit") else { return words.callIt("mac.lock_not_allowed") }
        guard case .object(let ew)? = settingsDict["eventWebhooks"],
              let url = Self.plainString(ew["url"]), url.lowercased().hasPrefix("https://") else {
            return words.callIt("ewh.enter_url")
        }
        guard let one = try? await engine.eventWebhookSample(
            url: url, secret: Self.plainString(ew["secret"]) ?? "", shopName: shopName,
            currency: currency, at: ISO8601DateFormatter().string(from: Date()),
            nowMs: Date().timeIntervalSince1970 * 1000) else { return words.callIt("mac.move_no_engine") }
        let tried = await attemptWebhook(one)
        return tried.ok ? "✓ " + words.callIt("hook.delivered") : "✗ " + (tried.error ?? "")
    }

    // MARK: - SMS

    /// The provider the shop set up for texts, when it is one this app sends
    /// through — Twilio, Unifonic, or its own webhook. WhatsApp Business is
    /// `WhatsAppCloud.swift`, with approved templates.
    var smsProvider: String? {
        guard case .object(let c)? = settingsDict["smsConfig"],
              let p = Self.plainString(c["provider"]), ["twilio", "unifonic", "webhook"].contains(p) else { return nil }
        return p
    }

    /// Send one text. Nil when the provider took it; otherwise what to tell
    /// the shop. The secrets are opened here, put in the request and dropped.
    func sendText(_ message: String, to phone: String, channel: String? = nil) async -> String? {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard let account = try? await engine.smsAccount(settings: settingsDict) else {
            return words.callIt("mac.move_no_engine")
        }
        guard account.ok else { return words.callIt("mac.sms_r_" + account.reason, fallback: words.callIt("mac.sms_r_not_set_up")) }
        guard case .object(var cfg)? = settingsDict["smsConfig"] else { return words.callIt("mac.sms_r_not_set_up") }
        do {
            for key in ["authToken", "appSid", "secret", "token"] {
                let stored = Self.plainString(cfg[key]) ?? ""
                if !stored.isEmpty { cfg[key] = .string(try await Secrets.open(stored, for: source)) }
            }
        } catch {
            return words.callIt("mac.sms_r_locked")
        }
        guard let req = try? await engine.smsRequest(provider: account.provider, config: cfg, to: phone,
                                                     message: message, channel: channel ?? account.channel) else {
            return words.callIt("mac.move_no_engine")
        }
        if let refused = req.error { return refused }
        guard let text = req.url, let url = URL(string: text), let body = req.body else {
            return words.callIt("mac.sms_r_not_set_up")
        }
        var headers: [(String, String)] = [("Content-Type", req.contentType ?? "application/json")]
        for (k, v) in (req.headers ?? [:]).sorted(by: { $0.key < $1.key }) { headers.append((k, v)) }
        do {
            let status = try await WebhookClient.post(Data(body.utf8), to: url, headers: headers, engine: engine)
            let read = try await engine.smsResult(status: status, text: "")
            return read.ok ? nil : (read.error ?? "HTTP \(status)")
        } catch let failure as WebhookClient.Failure {
            return failure.errorDescription ?? words.callIt("mac.sms_r_failed")
        } catch {
            return self.said(error)
        }
    }

    /// The settings' "Send test": a text to the shop's own phone, the
    /// desktop's message.
    func testText() async -> String {
        guard lockAllows("settings", "edit") else { return words.callIt("mac.lock_not_allowed") }
        let phone = (Self.plainString(settingsDict["phone"]) ?? "").trimmingCharacters(in: .whitespaces)
        guard !phone.isEmpty else { return "✗ " + words.callIt("sms.need_phone") }
        if let problem = await sendText(words.callIt("mac.sms_test_message"), to: phone) {
            return "✗ " + problem
        }
        return "✓ " + words.callIt("sms.test_sent")
    }

    /// When this job's update at its milestone was last texted, or nil.
    func smsSentAt(for job: Order, milestone: String) async -> String? {
        guard let engine else { return nil }
        let log = clientRecord(for: job)?.client.commLog.map { JSONValue.object($0.raw) } ?? []
        return (try? await engine.smsSentAt(commLog: log, orderId: job.id, milestone: milestone)) ?? nil
    }

    /// Text the job's customer its update — the same words the WhatsApp
    /// button opens with — and write it to the customer's log. Nil when it
    /// went; otherwise what to tell the shop. A person's action, from the
    /// job's inspector: nothing is texted on its own (see the PR's question).
    func sendSmsUpdate(for job: Order) async -> String? {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard permitted("orders", "edit") else { return moveProblem ?? words.callIt("mac.lock_not_allowed") }
        guard let provider = smsProvider else { return words.callIt("mac.sms_r_not_set_up") }
        guard let record = clientRecord(for: job) else { return whatsAppReason("no_customer") }
        guard let update = await whatsAppUpdate(for: job), !update.milestone.isEmpty else {
            return words.callIt("mac.sms_no_update")
        }
        let phone = record.client.phone.trimmingCharacters(in: .whitespaces)
        guard !phone.isEmpty else { return whatsAppReason("no_phone") }
        let key = job.id + "|" + update.milestone
        guard !smsSending.contains(key) else { return words.callIt("mac.sms_in_flight") }
        smsSending.insert(key)
        defer { smsSending.remove(key) }
        if let problem = await sendText(update.text, to: phone, channel: "sms") { return problem }
        guard case .object(let raw)? = try? await engine.smsCommEntry(
            id: Self.uid("CMM"), at: Date(), text: update.text, orderId: job.id,
            milestone: update.milestone, provider: provider),
            await addCommunication(CommEntry(raw: raw), to: record.client.id, gate: ("orders", "edit")) else {
            return words.callIt("mac.sms_sent_not_logged")
        }
        return nil
    }

    // MARK: - Accounting push

    /// Push this order's invoice if it is owed one — straight after a payment
    /// that made it paid, as the desktop does from its payment dialog. Quiet
    /// when nothing is owed; a failure is said, and written on the order so
    /// the next pass tries it again.
    func pushAccountingIfOwed(_ id: Order.ID) async {
        guard let engine, let order = orderRow(id),
              let decision = try? await engine.accountingWouldPush(order: order, settings: settingsDict),
              decision.push else { return }
        if let problem = await pushAccounting(id) {
            moveProblem = words.callIt("acct.push_failed") + " — " + problem
        }
    }

    /// Send every invoice whose last push failed — only those, so switching
    /// sync on does not push the shop's whole history.
    func retryFailedAccountingPushes() async {
        guard let engine, let build = source.build, StoreLock.weOwnIt(build) else { return }
        guard let ids = try? await engine.accountingRetryable(orders: orderRows, settings: settingsDict) else { return }
        for id in ids { _ = await pushAccounting(id) }
    }

    /// One push, and the order's record of it. Nil when the system took it.
    private func pushAccounting(_ id: Order.ID) async -> String? {
        guard let engine, let build = source.build, let order = orderRow(id) else { return nil }
        guard !accountingPushing.contains(id) else { return nil }
        accountingPushing.insert(id)
        defer { accountingPushing.remove(id) }
        // Asked again, on the order as it is now: a push the last pass made
        // while this one waited is not made twice.
        guard let decision = try? await engine.accountingWouldPush(order: order, settings: settingsDict),
              decision.push else { return nil }
        guard let payload = try? await engine.accountingPayload(
            order: order, settings: settingsDict, clients: clientRows, language: words.language,
            currencies: Invoice.currencyTable(self)) else { return nil }
        let problem = await postAccounting(payload)
        let at = ISO8601DateFormatter().string(from: Date())
        guard let outcome = try? await engine.accountingOutcome(ok: problem == nil, at: at, error: problem) else {
            return problem
        }
        do {
            // lock: system — records a push already made; the payment that owed it asked the lock
            try await StoreWriter.updateRecordOffMain(build, collection: "printLog", id: id, forceStamp: true) { r in
                for (k, v) in outcome.set { r[k] = v }
                for k in outcome.clear { r.removeValue(forKey: k) }
            }
            await load(source)
        } catch {
            // The system has the invoice; the stamp is what is missing, and
            // the idempotency key makes the next attempt harmless.
        }
        return problem
    }

    /// Post one payload to the shop's accounting webhook, its secret opened
    /// at the point of use. Nil when the system took it.
    private func postAccounting(_ payload: JSONValue) async -> String? {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard case .object(let cfg)? = settingsDict["accountingSync"],
              let text = Self.plainString(cfg["webhookUrl"]), let url = URL(string: text) else {
            return words.callIt("acct.need_url")
        }
        // https ONLY (the desktop's transport says the same): the request
        // carries the shop's secret in a header.
        guard url.scheme?.lowercased() == "https" else { return words.callIt("mac.acct_https_only") }
        do {
            let secret = try await Secrets.open(Self.plainString(cfg["secret"]) ?? "", for: source)
            let req = try await engine.accountingRequest(payload: payload, secret: secret)
            let headers = req.headers.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
            let status = try await WebhookClient.post(Data(req.body.utf8), to: url, headers: headers, engine: engine)
            return (200..<300).contains(status) ? nil : "HTTP \(status)"
        } catch let failure as WebhookClient.Failure {
            return failure.errorDescription ?? "failed"
        } catch let locked as Secrets.Failure {
            return locked.description
        } catch {
            return self.said(error)
        }
    }

    /// The settings' "Send test": the desktop's test payload.
    func testAccountingSync() async -> String {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard lockAllows("settings", "edit") else { return words.callIt("mac.lock_not_allowed") }
        guard let payload = try? await engine.accountingTestPayload(
            settings: settingsDict, nowMs: (Date().timeIntervalSince1970 * 1000).rounded()) else {
            return words.callIt("mac.move_no_engine")
        }
        if let problem = await postAccounting(payload) { return "✗ " + problem }
        return "✓ " + words.callIt("acct.test_sent")
    }

    /// Invoices whose last push failed, with why — what the settings list.
    struct StuckInvoice: Identifiable, Hashable, Sendable {
        let id: String
        let failedAt: String
        let error: String
    }

    var stuckAccountingPushes: [StuckInvoice] {
        orderRows.compactMap { row in
            guard case .object(let o) = row, let id = Self.recordId(row),
                  Self.plainString(o["paymentStatus"]) == "paid",
                  (Self.plainString(o["accountingPushedAt"]) ?? "").isEmpty,
                  let failed = Self.plainString(o["accountingPushFailedAt"]), !failed.isEmpty else { return nil }
            return StuckInvoice(id: id, failedAt: failed, error: Self.plainString(o["accountingPushError"]) ?? "")
        }
    }

    // MARK: - The local KPI email

    /// The email, built from the book as it is now.
    private func digestEmail(test: Bool, to recipient: String? = nil) async -> KhaytEngine.DigestEmail? {
        guard let engine else { return nil }
        return try? await engine.digestEmail(
            orders: orderRows, inventory: inventoryRows, waitingList: Self.rows(lanBook, "waitingList"),
            clients: clientRows, settings: settingsDict, shopName: shopName,
            localeTag: words.locale.identifier(.bcp47), nowMs: Date().timeIntervalSince1970 * 1000,
            test: test, recipient: recipient)
    }

    /// Send the digest if this is its hour and its period has not had one —
    /// the period key goes into the book BEFORE the send is reported, and the
    /// key is what stops either app sending it again.
    func sendDigestIfDue() async {
        // lock: system — the scheduled email the shop switched on; records only which period went
        guard !digestSending, let engine, let build = source.build, StoreLock.weOwnIt(build) else { return }
        guard await canEmailThrough(emailProvider) else { return }
        guard let due = try? await engine.digestDue(settings: settingsDict, nowMs: Date().timeIntervalSince1970 * 1000),
              due.due, let mail = await digestEmail(test: false) else { return }
        digestSending = true
        defer { digestSending = false }
        guard await sendDigestMail(mail) == nil else { return }
        _ = await updateSettingsOnDisk() { settings in
            settings["emailDigest"] = try await engine.digestSent(settings: settings, periodKey: due.periodKey)
        }
    }

    /// The settings' "Send test now". Nothing is recorded.
    func sendDigestTest(to recipient: String) async -> String {
        guard lockAllows("settings", "edit") else { return words.callIt("mac.lock_not_allowed") }
        guard await canEmailThrough(emailProvider) else { return "✗ " + words.callIt("mac.digest_needs_email") }
        let to = recipient.trimmingCharacters(in: .whitespaces)
        guard let mail = await digestEmail(test: true, to: to.isEmpty ? nil : to), !mail.to.isEmpty else {
            return "✗ " + words.callIt("mac.digest_no_recipient")
        }
        if let problem = await sendDigestMail(mail) { return "✗ " + problem }
        return "✓ " + words.callIt("mac.digest_test_sent")
    }

    /// Through the Mac's own mail path (`post`): SMTP, SendGrid or Mailgun.
    private func sendDigestMail(_ mail: KhaytEngine.DigestEmail) async -> String? {
        let saved = moveProblem
        moveProblem = nil
        await post(OrderEmail(to: mail.to, subject: mail.subject, html: mail.html, provider: emailProvider))
        let problem = moveProblem
        moveProblem = saved
        // `post` says "sent" through `moveNotices`; a digest is not a move.
        if problem == nil, let last = moveNotices.last, last == words.callIt("mac.email_sent") { moveNotices.removeLast() }
        return problem
    }
}
