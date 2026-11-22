import Foundation
import KhaytCore

/// WhatsApp updates SENT for the shop, through its own WhatsApp Business
/// account.
///
/// ── WHAT THIS IS ──────────────────────────────────────────────────────────
///
/// `WhatsApp.swift` opens WhatsApp with the message typed and a person presses
/// send. A shop that connects its own WhatsApp Business account (Meta's Cloud
/// API, Settings › Integrations) can have the update sent instead, the moment
/// a job steps into a milestone — received, ready, shipped, delivered — to a
/// customer who agreed to updates on WhatsApp.
///
/// AUTOMATIC, NOT QUEUED. The doc this follows left open whether a person
/// should approve each one first. They do not, because the rule that a message
/// in the shop's name is read before it goes is already kept: what is sent is
/// a TEMPLATE the shop wrote and Meta approved, word for word, filled with the
/// customer's name, the order number, the carrier and the tracking number.
/// Nothing Khayt composes reaches a customer this way. A queue would add a
/// click to every finished job for a message the shop has already read.
///
/// The RULES are shared: `lib/whatsapp-message.js` decides whether a change
/// owes a message and with what (`cloudMessage`), `lib/whatsapp-send.js`
/// builds the request and reads Meta's answer. This file only opens the
/// token, performs the request and writes the customer's log.
///
/// ── THE TOKEN STAYS ON THIS MAC ───────────────────────────────────────────
///
/// `settings.smsConfig.token` is a registered secret: sealed on disk, masked
/// before a book goes to a phone, and opened here at the point of use. It
/// goes in one request header to graph.facebook.com and nowhere else — the
/// privacy policy says so (khaytapp.com/privacy, #secrets).
///
/// ── DELIVERY ──────────────────────────────────────────────────────────────
///
/// The log line carries Meta's message id, and `WhatsAppReports.swift`
/// already moves it on to delivered and read as the reports arrive.
enum WhatsAppCloud {

    /// Meta could not be reached at all.
    struct Unreachable: Error { let detail: String }

    /// The session every send goes through — `.shared`, or a stub a test
    /// installs so no test reaches Meta. The one seam, like
    /// `StoreReader.Build.supportFolderForTests`.
    nonisolated(unsafe) static var sessionForTests: URLSession?

    /// Perform one request the shared rule built. Only to graph.facebook.com
    /// over HTTPS: the URL is the rule's, and this is the last place to make
    /// sure a token never travels anywhere else.
    static func perform(_ req: WhatsAppCloudRequest,
                        session: URLSession? = nil) async throws -> (status: Int, body: JSONValue) {
        let session = session ?? sessionForTests ?? .shared
        guard req.ok, let text = req.url, let url = URL(string: text),
              url.scheme == "https", url.host == "graph.facebook.com" else {
            throw Unreachable(detail: req.reason ?? "bad_request")
        }
        var request = URLRequest(url: url)
        request.httpMethod = req.method ?? "POST"
        // Fifteen seconds, the other app's figure for its SMS providers. A
        // shop finishing a job should not wait on a network that is not there.
        request.timeoutInterval = 15
        for (name, value) in req.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        if let body = req.body, !body.isEmpty { request.httpBody = Data(body.utf8) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Unreachable(detail: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        return (status, body)
    }
}

extension Shop {

    /// The account as stored: the phone number id and the SEALED token.
    func whatsAppBusinessAccount() -> (phoneNumberId: String, sealedToken: String)? {
        guard case .object(let c)? = settingsDict["smsConfig"],
              Self.plainString(c["provider"]) == "whatsapp_cloud" else { return nil }
        let id = Self.plainString(c["phoneNumberId"]) ?? ""
        let token = Self.plainString(c["token"]) ?? ""
        guard !id.isEmpty, !token.isEmpty else { return nil }
        return (id, token)
    }

    /// What a change to this job owes its customer through WhatsApp Business,
    /// worked out against the book as it now is. `before` nil and `now` true
    /// for a send a person asked for from the job.
    func whatsAppBusinessMessage(before: JSONValue?, jobId: Order.ID,
                                 now: Bool = false) async -> WhatsAppCloudMessage? {
        guard let engine, let after = orderRow(jobId),
              let job = orders.first(where: { $0.id == jobId }) else { return nil }
        return try? await engine.whatsAppCloudMessage(
            before: before, after: after, settings: settingsDict, clients: clientRows,
            shopLang: words.language, values: whatsAppValues(for: job), now: now)
    }

    /// Send one update and write it to the customer's log. Nil when Meta took
    /// it; otherwise what to tell the shop.
    ///
    /// The line is written only for a message Meta ACCEPTED, with its id. A
    /// send that failed writes nothing, so the job goes on offering the update
    /// — by WhatsApp Business again, or typed by hand.
    func sendWhatsAppBusiness(_ message: WhatsAppCloudMessage, jobId: Order.ID) async -> String? {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard permitted("orders", "edit") else { return words.callIt("mac.lock_not_allowed") }
        guard message.send, let template = message.template else {
            return whatsAppBusinessReason(message.reason)
        }
        guard let account = whatsAppBusinessAccount() else { return whatsAppBusinessReason("not_set_up") }
        let sending = jobId + "|" + message.milestone
        guard !whatsAppSending.contains(sending) else { return whatsAppBusinessReason("already_sent") }
        whatsAppSending.insert(sending)
        // Kept for the run once Meta has taken it, so it is never offered twice;
        // released on any failure, so the job goes on offering it.
        var accepted = false
        defer { if !accepted { whatsAppSending.remove(sending) } }
        let token: String
        do { token = try await Secrets.open(account.sealedToken, for: source) }
        catch { return whatsAppBusinessReason("token_locked") }
        guard let request = try? await engine.whatsAppCloudRequest(
            phoneNumberId: account.phoneNumberId, token: token, message: message) else {
            return words.callIt("mac.move_no_engine")
        }
        guard request.ok else { return whatsAppBusinessReason(request.reason ?? "failed") }
        let answer: WhatsAppCloudResult
        do {
            let (status, body) = try await WhatsAppCloud.perform(request)
            guard let read = try? await engine.whatsAppCloudResult(status: status, body: body) else {
                return words.callIt("mac.move_no_engine")
            }
            answer = read
        } catch {
            return whatsAppBusinessReason("unreachable")
        }
        guard answer.ok, let messageId = answer.messageId else {
            var said = whatsAppBusinessReason(answer.reason ?? "failed")
            // Meta's own words where there are any, and its code: "Message
            // Undeliverable" or "(#132001)" is what a shop pastes into a
            // search, and the sentence alone is not.
            if let title = answer.title, !title.isEmpty { said += " — " + title }
            if let code = answer.code { said += " (#\(code))" }
            return said
        }
        accepted = true
        let note = words.callIt("mac.wab_note", [
            "name": .string(template.name),
            "params": .string(message.params.joined(separator: " · ")),
        ])
        // Meta has it. A log line that cannot be written is SAID: without it
        // nothing records that this went, and after a relaunch it would be
        // offered again (beta.6 review).
        guard case .object(let raw)? = try? await engine.whatsAppCommEntry(
            id: Self.uid("CMM"), at: Date(), text: note, orderId: jobId,
            milestone: message.milestone, lang: message.lang,
            messageId: messageId, template: template.name),
            await addCommunication(CommEntry(raw: raw), to: message.clientId, gate: ("orders", "edit")) else {
            return words.callIt("mac.wab_sent_not_logged", ["id": .string(messageId)])
        }
        return nil
    }

    /// After a change to a job has been WRITTEN: send what it owes the
    /// customer through WhatsApp Business, and say what did not go.
    ///
    /// Not fatal, like a Telegram message or an email that failed: the job IS
    /// moved, and undoing a correct write because Meta was down would be the
    /// wrong trade. The shop is told, and the job keeps offering the update.
    ///
    /// Called BEFORE the move's other deliveries report: writing the log line
    /// starts from a clean `moveProblem`, and a problem said before it would be
    /// wiped.
    func sendOwedWhatsApp(before: JSONValue?, jobId: Order.ID) async {
        guard whatsAppBusinessAccount() != nil,
              let message = await whatsAppBusinessMessage(before: before, jobId: jobId) else { return }
        let milestone = whatsAppMilestoneName(message.milestone)
        guard message.send else {
            // Most reasons are quiet — no template for this step, a customer
            // who has not agreed. One who agreed and has no usable number is
            // a customer who will not be told, and that is worth a sentence.
            if let engine, (try? await engine.whatsAppIsUnreachable(message.reason)) == true {
                moveProblem = words.callIt("mac.wab_not_sent", ["m": .string(milestone)])
                    + " " + whatsAppReason(message.reason)
            }
            return
        }
        if let problem = await sendWhatsAppBusiness(message, jobId: jobId) {
            moveProblem = words.callIt("mac.wab_not_sent", ["m": .string(milestone)]) + " " + problem
        } else {
            moveNotices.append(words.callIt("mac.wab_sent", ["m": .string(milestone)]))
        }
    }

    /// Why a WhatsApp Business send did not happen, in the shop's words.
    func whatsAppBusinessReason(_ reason: String) -> String {
        words.callIt("mac.wab_r_" + reason, fallback: words.callIt("mac.wab_r_failed"))
    }

    /// Check the number id and token with Meta, writing to nobody: what the
    /// settings pane's Check button says.
    func checkWhatsAppBusiness() async -> String {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard let account = whatsAppBusinessAccount() else { return whatsAppBusinessReason("not_set_up") }
        do {
            let token = try await Secrets.open(account.sealedToken, for: source)
            let request = try await engine.whatsAppCheckRequest(phoneNumberId: account.phoneNumberId, token: token)
            guard request.ok else { return whatsAppBusinessReason(request.reason ?? "failed") }
            let (status, body) = try await WhatsAppCloud.perform(request)
            let answer = try await engine.whatsAppCloudResult(status: status, body: body, check: true)
            if answer.ok {
                return "✓ " + words.callIt("mac.wab_check_ok", [
                    "number": .string(answer.number ?? ""), "name": .string(answer.name ?? ""),
                ])
            }
            var said = whatsAppBusinessReason(answer.reason ?? "failed")
            if let title = answer.title, !title.isEmpty { said += " — " + title }
            return said
        } catch is Secrets.Failure {
            return whatsAppBusinessReason("token_locked")
        } catch is WhatsAppCloud.Unreachable {
            return whatsAppBusinessReason("unreachable")
        } catch {
            return whatsAppBusinessReason("failed")
        }
    }
}
