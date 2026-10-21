import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore
import os

extension Shop {

    // MARK: - Standing orders

    /// Make today's standing orders, once per book per launch.
    ///
    /// The other app does this at boot and every six hours; this one does it
    /// when the book opens, which for a shop is once a morning. The rule is
    /// idempotent — a cycle that already has its job asks for nothing — so a
    /// Mac and a PC opening the same book both run it and one job results.
    /// Nothing for the sample book, and nothing while another app owns the
    /// book: the same jobs are due at the next launch.
    func createRecurringIfDue() {
        guard case .store(let build) = source, let engine,
              !recurringBooks.contains(build.rawValue) else { return }
        recurringBooks.insert(build.rawValue)
        Task { [weak self] in
            guard let self else { return }
            var created: [String] = []
            do {
                // lock: system — background: a recurring order falling due, which the shop set up.
                try await StoreWriter.update(
                    storeURL: build.storeURL,
                    owns: { StoreLock.weOwnIt(build) },
                    whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
                ) { root in
                    let outcome = try await RecurringOrders.run(&root, engine: engine)
                    guard outcome.changed else { throw RecurringOrders.NothingDue() }
                    created = outcome.created
                }
            } catch {
                return
            }
            await load(source)
            if !created.isEmpty {
                importNote = words.callIt("rec.created", ["n": .number(Double(created.count))])
            }
        }
    }

    /// One cycle on from a day, by the shared rule. Nil with no engine.
    func nextCycle(after day: String, interval: String) async -> String? {
        guard let engine else { return nil }
        return try? await engine.nextCycle(after: day, interval: interval)
    }

    // MARK: - A customer's communications log

    /// Write a line in a customer's log NOW, not on Save.
    ///
    /// A note about a phone call is a fact the moment the call ends, and the
    /// other app writes it to the record straight away for the same reason —
    /// so that closing the sheet with the × does not lose it. Only the log is
    /// touched: the rest of the record stays as it is on disk, whatever a
    /// sheet somewhere else is holding.
    /// `gate` is the permission the ACTION needs. A job update sent to a
    /// customer is order work, which staff may do; its log line is part of
    /// that send, not an edit of the customer, so it is written under the
    /// send's own permission rather than refused after WhatsApp has opened.
    func addCommunication(_ entry: CommEntry, to clientId: String,
                          gate: (area: String, action: String) = ("clients", "edit")) async {
        moveProblem = nil
        guard permitted(gate.area, gate.action) else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let raw = entry.raw
            try await StoreWriter.updateRecordOffMain(build, collection: "clients", id: clientId) { record in
                var log: [JSONValue] = []
                if case .array(let had)? = record["commLog"] { log = had }
                log.append(.object(raw))
                // Khayt keeps two hundred. The NEWEST two hundred: the other
                // app's editor appended and then cut the tail, which threw
                // away the note just written the moment the log was full.
                if log.count > 200 { log = Array(log.suffix(200)) }
                record["commLog"] = .array(log)
            }
            await load(source)
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// Take one line out of a customer's log. The FIRST line equal to it: two
    /// identical quick notes are two lines, and deleting one deletes one.
    func removeCommunication(_ entry: CommEntry, from clientId: String) async {
        moveProblem = nil
        guard permitted("clients", "delete") else { return }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let raw = entry.raw
            try await StoreWriter.updateRecordOffMain(build, collection: "clients", id: clientId) { record in
                guard case .array(var log)? = record["commLog"],
                      let at = log.firstIndex(of: .object(raw)) else { return }
                log.remove(at: at)
                record["commLog"] = .array(log)
            }
            await load(source)
        } catch {
            moveProblem = self.said(error)
        }
    }

    // MARK: - What the customer thought

    /// Record what a customer said about a finished job.
    ///
    /// ── WHY THIS HAD TO EXIST ─────────────────────────────────────────────
    ///
    /// A rating could only reach this book one way: a customer opening the
    /// portal on their phone and submitting it. A shop that rings a customer
    /// and hears "yes, five out of five" had nowhere to put it — while the
    /// Reports screen draws a ratings line that, on a Mac-only shop, could
    /// never fill.
    ///
    /// `recordedAt`, NOT `submittedAt`. The customer portal writes
    /// `submittedAt` and this writes `recordedAt`, which is the other app's own
    /// split: one is the customer saying it, the other is the shop writing it
    /// down, and a book that cannot tell them apart has lost the difference.
    func recordRating(_ id: Order.ID, rating: Int, comment: String) async {
        // Bounds from the rule that READS them, so a rating this app writes is
        // one the chart will draw. `RatingTrend.ratingOf` refuses anything
        // outside 1–5, and a rating stored outside it would sit in the book
        // looking recorded and count for nothing.
        guard Double(rating) >= RatingTrend.minRating,
              Double(rating) <= RatingTrend.maxRating else {
            moveProblem = words.callIt("mac.rating_out_of_range"); return
        }
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = ISO8601DateFormatter().string(from: Date())
        await writeToOneOrder(id, named: words.callIt("ord.record_survey"), as: .person("orders", "edit")) { order, _, _ in
            guard case .object(var o) = order else {
                throw MoveRefused(sentence: self.words.callIt("mac.move_refused"))
            }
            // Only a FINISHED job has anything to rate — the other app offers
            // this on finished work alone, and a rating on a job still on the
            // bench would be counted by every reader as the finished job's.
            guard case .string(let status)? = o["status"],
                  RatingTrend.finishedStatuses.contains(status) else {
                throw MoveRefused(sentence: self.words.callIt("mac.not_finished_yet"))
            }
            o["survey"] = .object(["rating": .number(Double(rating)),
                                   "comment": .string(comment),
                                   "recordedAt": .string(now)])
            return OneOrderEdit(order: .object(o),
                                activity: "\(id) rated \(rating)/5")
        }
    }

    /// What a job already carries, for the sheet to open on.
    func ratingOn(_ id: Order.ID) -> (rating: Int, comment: String) {
        guard let row = orderRows.first(where: { Self.recordId($0) == id }),
              case .object(let o) = row, case .object(let survey)? = o["survey"]
        else { return (0, "") }
        // A survey with no rating is NaN here, and Int(NaN) traps.
        let raw = JSSemantics.number(survey["rating"])
        let rating = raw.isFinite ? Int(min(max(raw, 0), 10)) : 0
        var comment = ""
        if case .string(let c)? = survey["comment"] { comment = c }
        return (rating, comment)
    }

    // MARK: - What the customers screen shows

    var customers: [Customer] { Customer.from(orders, clients: clients, names: clientNames) }

    /// The current month's row, or nil.
    ///
    /// The period key is `YYYY-MM` in LOCAL time, built by `DateRange` — the
    /// same construction the rule uses for its own keys, so the lookup cannot
    /// miss by a day at either end of a month for a shop not on UTC.
    static func thisMonthsNet(engine: KhaytEngine?, orders: [JSONValue],
                              expenses: [JSONValue], settings: [String: JSONValue],
                              clients: [JSONValue],
                              currencies: [String: JSONValue],
                              wasteLog: [JSONValue] = [],
                              inventory: [JSONValue] = [],
                              now: Date = Date()) async -> Double? {
        await thisMonthsRow(engine: engine, orders: orders, expenses: expenses,
                            settings: settings, clients: clients,
                            currencies: currencies, wasteLog: wasteLog, inventory: inventory, now: now)?.revenue
    }

    /// The current month's whole P&L row — the net and the gross come from it
    /// together, so they cannot describe different jobs.
    static func thisMonthsRow(engine: KhaytEngine?, orders: [JSONValue],
                              expenses: [JSONValue], settings: [String: JSONValue],
                              clients: [JSONValue],
                              currencies: [String: JSONValue],
                              wasteLog: [JSONValue] = [],
                              inventory: [JSONValue] = [],
                              machines: [JSONValue] = [],
                              recentMonthlyHours: [String: Double] = [:],
                              timeEntries: [JSONValue] = [],
                              now: Date = Date()) async -> PnlPeriod? {
        guard let engine else { return nil }
        // The waste log goes in, as it does for Reports: failed prints are a
        // cost line of the P&L, and a masthead net without them would be the
        // Reports net plus the month's waste. The time log likewise — logged
        // labour is a line of the P&L too.
        let periods = (try? await engine.pnlByPeriod(
            orders: orders, expenses: expenses, settings: settings, clients: clients,
            currencies: currencies, now: now, granularity: "month",
            wasteLog: wasteLog, inventory: inventory, machines: machines,
            recentMonthlyHours: recentMonthlyHours, timeEntries: timeEntries)) ?? []
        return periods.first { $0.period == DateRange.localMonth(now) }
    }

    /// Ask the shared rule when the queue will finish.
    ///
    /// Only the jobs actually ON the floor: a quote nobody has accepted is not
    /// in the queue, and counting it would push every real job's date out and
    /// invent lateness that does not exist. `printTime` is the estimate the job
    /// carries; a job with none contributes nothing but still takes its place
    /// in the order, which is what a real queue does with an unestimated job.
    ///
    /// The start day is the SHOP'S calendar day, not UTC's. A projection made
    /// at one in the morning in Riyadh must not be dated yesterday.
    /// `on` is the day the projection starts from. It defaults to today and is
    /// only ever passed by `SampleBookAgesTests`, which walks the sample book
    /// years forward to prove it cannot age out of the case it covers.
    static func project(orders: [Order], engine: KhaytEngine?,
                        settings: [String: JSONValue],
                        on day: Date = Date()) async -> KhaytEngine.Timeline? {
        guard let engine else { return nil }
        let onTheFloor: Set<String> = ["pending", "printing", "post", "qc", "on_hold"]
        let queued = orders.filter { onTheFloor.contains($0.status) }
        guard !queued.isEmpty else { return nil }
        let jobs: [JSONValue] = queued.map { o in
            .object([
                "id": .string(o.id),
                "machineId": .string(o.machineId ?? ""),
                "hours": .number(o.printTime),
                "dueDate": .string(o.dueDate ?? ""),
                "project": .string(o.project),
                "status": .string(o.status),
            ])
        }
        let daily = (try? await engine.dailyWorkingHours(settings: settings)) ?? 8
        let today = DateFormatter.shopDay.string(from: day)
        return try? await engine.timeline(jobs: jobs, dailyHours: daily, startDate: today)
    }

    /// The jobs projected to miss their due date, soonest due first.
    var willBeLate: [Order] {
        guard let timeline else { return [] }
        var risky: [String: String] = [:]                 // id → its projected date
        for machine in timeline.machines {
            for job in machine.jobs where job.late { risky[job.id] = job.etaDate }
        }
        guard !risky.isEmpty else { return [] }
        // A job that is ALREADY late is not news from a projection — it is in
        // the attention panel, and saying it twice in two different words is
        // how a screen teaches somebody to skim it.
        let already = Set((facts?.attn.items ?? [])
            .filter { $0.kind == "order" }.map(\.id))
        return orders
            .filter { risky[$0.id] != nil && !already.contains($0.id) }
            .sorted { ($0.dueDate ?? "") < ($1.dueDate ?? "") }
    }

    /// The day a job is now expected to be ready, when that is known.
    func readyDate(of id: Order.ID) -> String? {
        guard let timeline else { return nil }
        for machine in timeline.machines {
            if let job = machine.jobs.first(where: { $0.id == id }) { return job.etaDate }
        }
        return nil
    }

    // MARK: - Who a message would reach

    /// What a campaign is narrowed to.
    ///
    /// Every field is OPTIONAL and absent means "do not narrow by this" — the
    /// rule reads `!= null`, so a zero is a real filter (spent at least
    /// nothing, which is everybody) and nil is no filter at all. A form that
    /// sent zeroes for its empty boxes would quietly change what "not ordered
    /// in N days" means the moment somebody cleared the field.
    struct Segment: Equatable, Sendable {
        var channel = "email"
        var minSpend: Double?
        var noOrderDays: Double?
        var activeWithinDays: Double?
        var tag = ""
        var tier = ""

        /// The channels this app can SEND a campaign on. The rule also knows
        /// `sms` and `whatsapp` (both read the phone number), but this app's
        /// only campaign sender is email: offering WhatsApp built a list of
        /// phone numbers and then mailed them.
        static let channels = ["email"]

        var criteria: [String: JSONValue] {
            var out: [String: JSONValue] = [:]
            if let minSpend { out["minSpend"] = .number(minSpend) }
            if let noOrderDays { out["noOrderDays"] = .number(noOrderDays) }
            if let activeWithinDays { out["activeWithinDays"] = .number(activeWithinDays) }
            let cleanTag = tag.trimmingCharacters(in: .whitespaces)
            if !cleanTag.isEmpty { out["tag"] = .string(cleanTag) }
            if !tier.isEmpty { out["tier"] = .string(tier) }
            return out
        }
    }

    /// Who this segment reaches, in the order the rule returns them.
    ///
    /// ── WHAT THIS APP DELIBERATELY DOES NOT DECIDE ────────────────────────
    ///
    /// Who is in and who is out is entirely `lib/campaigns.js`: the spend, the
    /// days since the last order, the tag, the tier, and — the one that
    /// matters — that a customer who has opted out of marketing is never in the
    /// list, whatever the segment says. A host that filtered on its own side
    /// would be a second opinion about consent, and the wrong one eventually.
    ///
    /// The tiers are worked out here only because a Swift closure cannot cross
    /// into JavaScriptCore; they are still `lib/loyalty.js`'s answer.
    func campaignRecipients(_ segment: Segment) async -> [KhaytEngine.Recipient] {
        guard let engine else { return [] }
        var tiers: [String: JSONValue] = [:]
        if loyaltyOn, !segment.tier.isEmpty {
            for row in clientRows {
                guard let id = Self.recordId(row) else { continue }
                if let standing = await loyalty(of: id), let name = standing.tier {
                    tiers[id] = .string(name)
                }
            }
        }
        return (try? await engine.campaignRecipients(
            clients: clientRows, orders: orderRows, criteria: segment.criteria,
            channel: segment.channel, tiers: tiers, now: Date())) ?? []
    }

    /// One message as one customer would read it.
    ///
    /// Shown BEFORE anything is sent, and shown for a real recipient rather
    /// than for a made-up one: `{{name}}` going out empty is the fault this
    /// rule's own comments are about, and the only way to see it is to fill it
    /// in for somebody the list actually contains.
    ///
    /// `html` for the body of an email: the values filled in are escaped, so a
    /// name holding markup reads as the characters it is.
    func campaignPreview(_ body: String, for recipient: KhaytEngine.Recipient,
                         html: Bool = false) async -> String {
        guard let engine else { return body }
        let money = Money.text(recipient.stats.totalSpend, currency)
        var payload: [String: JSONValue] = ["client": recipient.client]
        payload["stats"] = .object([
            "completedCount": .number(Double(recipient.stats.completedCount)),
            "totalSpend": .number(recipient.stats.totalSpend),
            "lastOrderDate": .string(recipient.stats.lastOrderDate),
        ])
        return (try? await engine.fillCampaignTemplate(
            body, recipient: .object(payload), spend: money,
            settings: settingsValue, html: html)) ?? body
    }

    /// The provider the shop configured, or empty.
    var emailProvider: String {
        guard case .object(let config)? = settingsDict["emailConfig"] else { return "" }
        return Self.plainString(config["provider"]) ?? ""
    }

    /// Can this app send a campaign at all?
    ///
    /// ── THIS USED TO ASK A NARROWER QUESTION ──────────────────────────────
    ///
    /// It asked whether the provider was one HTTPS POST, because those were the
    /// only two doors this app had. A shop on its own SMTP relay was told to go
    /// and send the campaign from somewhere else — which is not an answer, it is
    /// a shop with a mailing list it cannot use.
    ///
    /// `SmtpClient` is the third door now, so the question is the one that was
    /// always meant: is a provider configured, and does this app speak it?
    /// `custom` is added to the shared rule's answer rather than replacing it,
    /// so a provider added to the other app still correctly reads as one this
    /// one cannot send through.
    func canSendCampaign() async -> Bool {
        await canEmailThrough(emailProvider)
    }

    /// Can this app carry mail through that provider?
    ///
    /// Asked in two places — a job moving, and a campaign going out — and they
    /// must agree: a shop told its move cannot be made because the customer
    /// could not be emailed, and then offered a campaign button that emails
    /// that same customer, is being told two different things about one relay.
    ///
    /// The HTTPS providers are the shared rule's list, asked rather than
    /// repeated. `custom` is this app's own door and is not in that list, so it
    /// is added here — and only with a host, because a provider set to `custom`
    /// with nothing typed into it is a shop that started configuring and
    /// stopped.
    func canEmailThrough(_ provider: String) async -> Bool {
        guard let engine else { return false }
        return await Shop.canEmailThrough(provider, settings: settingsDict, engine: engine)
    }

    /// The same question asked from inside the write chain.
    ///
    /// STATIC because `applyMove` is: it runs inside `updateStoreOnDisk` with
    /// the settings that are on disk, and the instance's `settingsDict` is the
    /// in-memory copy, which lags every write still in flight. One
    /// implementation, two ways in — a second copy of this rule is how a move
    /// and a campaign come to disagree about one relay.
    static func canEmailThrough(_ provider: String, settings: [String: JSONValue],
                                engine: KhaytEngine) async -> Bool {
        if provider == "custom" {
            guard case .object(let config)? = settings["emailConfig"] else { return false }
            return !(plainString(config["smtpHost"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return (try? await engine.emailProviderIsHttp(provider)) ?? false
    }

    /// The relay the shop typed, or empty. Not the password — that is sealed,
    /// and is opened at the point of use in `post`.
    var smtpHost: String {
        guard case .object(let config)? = settingsDict["emailConfig"] else { return "" }
        return (Self.plainString(config["smtpHost"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Write to everybody the segment reaches.
    ///
    /// ── WHY EMAIL AND NOT "A CHANNEL" ─────────────────────────────────────
    ///
    /// The other app offers SMS and WhatsApp here too, through a provider the
    /// shop configures. This app has no SMS client at all, and a single
    /// WhatsApp message from here opens `wa.me` in a browser — a person
    /// pressing send once, which is not a thing forty of can be done. A button
    /// offering a channel it cannot honour is a button that quietly does
    /// nothing for most of a list, so the sheet offers the one it can do
    /// properly.
    ///
    /// ── AND WHY ONE AT A TIME, SLOWLY ─────────────────────────────────────
    ///
    /// 350 ms between sends, which is the other app's throttle. A provider
    /// handed forty messages at once starts refusing them, and a refusal
    /// halfway through is the worst outcome here: some customers written to,
    /// some not, and nothing to say which. So each send is counted, the count
    /// of both is what comes back, and the whole run goes into the campaign
    /// log the other app keeps — in the same shape, in the same place.
    ///
    /// Returns what to tell the shop.
    func sendCampaign(_ body: String, subject: String = "", channel: String = "email",
                      to recipients: [KhaytEngine.Recipient]) async -> String {
        guard permitted("clients", "edit") else { return moveProblem ?? "" }
        // Every send below is a MAIL. A list built for any other channel holds
        // phone numbers, and posting them as addresses is the bug this stops.
        guard channel == "email" else { return words.callIt("mac.campaign_email_only") }
        guard !recipients.isEmpty else { return words.callIt("camp.none") }
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else {
            return words.callIt("camp.need_body")
        }
        guard await canSendCampaign() else { return words.callIt("mac.campaign_needs_email") }

        let typed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var sent = 0
        var failed = 0
        for recipient in recipients {
            // Cancellable: a shop that closes the sheet halfway has stopped,
            // and the count it is shown afterwards is what actually went.
            if Task.isCancelled { break }
            let filled = await campaignPreview(body, for: recipient, html: true)
            // ── THE SUBJECT IS A TEMPLATE TOO ─────────────────────────────
            //
            // `{{name}}` in a subject line is the whole reason to have one —
            // "A note from your printer, Layla" is opened and "Acme 3D" is
            // not — so it goes through the SAME fill the message does rather
            // than being pasted in raw. Filling the body and not the subject
            // would put the literal characters `{{name}}` in the one line a
            // customer sees before deciding whether to open it.
            //
            // Empty falls back to the shop's name. The other app falls back to
            // the literal word "Khayt", which names the software rather than
            // the sender; a customer has never heard of it.
            let headline = typed.isEmpty ? shopName
                : Self.oneLine(await campaignPreview(typed, for: recipient))
            let mail = OrderEmail(to: recipient.contact, subject: headline,
                                  // The shop's own newlines are the paragraphs
                                  // it meant, and an HTML mail eats them.
                                  html: filled.replacingOccurrences(of: "\n", with: "<br>"),
                                  provider: emailProvider)
            moveProblem = nil
            await post(mail)
            if moveProblem == nil { sent += 1 } else { failed += 1 }
            try? await Task.sleep(for: .milliseconds(350))
        }
        moveProblem = nil
        await recordCampaign(reached: recipients.count, sent: sent, failed: failed)

        var said = words.callIt("camp.done") + ": " + String(sent)
        if failed > 0 { said += " · " + String(failed) + " " + words.callIt("camp.failed") }
        return said
    }

    /// A subject is one line, whatever the fill put in it.
    ///
    /// The newline cannot be TYPED — the field is a single-line one — but it
    /// can arrive through `{{name}}`, because a customer's name is data and
    /// data holds whatever somebody once pasted into it. Neither provider this
    /// app posts to can be injected with it: SendGrid takes JSON and Mailgun a
    /// URL-encoded form, and both escape it. The one that could is SMTP, where
    /// a header ends at a newline and the next line is a new header — and SMTP
    /// is the provider this app does not have YET. Normalising here means the
    /// day it arrives, this is not the thing that was forgotten.
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// One campaign that went out: when, to how many, and how it went.
    struct CampaignRun: Identifiable, Hashable, Sendable {
        let id: String
        /// `YYYY-MM-DD`, the shop's day rather than the timestamp's instant.
        let day: String
        let reached: Int
        let sent: Int
        let failed: Int
    }

    /// The last campaigns, newest first.
    ///
    /// ── WRITTEN BY BOTH APPS AND READ BY NEITHER ──────────────────────────
    ///
    /// `settings.campaignLog` has been written since campaigns existed and
    /// there has never been a screen for it — grepping the repository finds
    /// exactly two hits, and both are writes. A record an app keeps and cannot
    /// show is the same defect as a field it reads and cannot set, which is
    /// what the marketing opt-out was: half a feature, in the other direction.
    ///
    /// It matters more now this app sends. "Did that go?" is the first
    /// question after pressing a button that mails forty people, and the
    /// answer was already on disk.
    var campaignRuns: [CampaignRun] { Self.campaignRuns(in: settingsDict) }

    /// The decode on its own, so it can be driven over a book this app has not
    /// loaded — including the shapes the other app's older writes left behind.
    static func campaignRuns(in settings: [String: JSONValue]) -> [CampaignRun] {
        guard case .array(let rows)? = settings["campaignLog"] else { return [] }
        return rows.compactMap { row in
            guard case .object(let o) = row else { return nil }
            let at = Self.plainString(o["at"]) ?? ""
            guard !at.isEmpty else { return nil }
            return CampaignRun(
                id: at,
                // The day, not the instant: a list of times to the second is a
                // list nobody reads, and the shop asks "did I send this week".
                day: Calendar.localDay(ofInstant: at),
                reached: Int(Self.plainNumber(o["recipients"]) ?? 0),
                sent: Int(Self.plainNumber(o["sent"]) ?? 0),
                failed: Int(Self.plainNumber(o["failed"]) ?? 0))
        }.reversed()
    }

    /// What was sent, when, and how it went.
    ///
    /// The other app keeps the last fifty runs on `settings.campaignLog`; this
    /// writes the same records into the same place. A shop that sends from one
    /// app and looks in the other should find one history, not two.
    private func recordCampaign(reached: Int, sent: Int, failed: Int) async {
        guard let build = source.build else { return }
        do {
            // lock: callers — sendCampaign
            try await StoreWriter.updateOffMain(build) { root in
                var settings: [String: JSONValue] = [:]
                if case .object(let s)? = root["settings"] { settings = s }
                var log: [JSONValue] = []
                if case .array(let existing)? = settings["campaignLog"] { log = existing }
                log.append(.object([
                    "at": .string(ISO8601DateFormatter().string(from: Date())),
                    "channel": .string("email"),
                    "recipients": .number(Double(reached)),
                    "sent": .number(Double(sent)),
                    "failed": .number(Double(failed)),
                ]))
                // FIFTY, as the other app keeps it: this lives on the settings
                // record, which is read on every load.
                if log.count > 50 { log = Array(log.suffix(50)) }
                settings["campaignLog"] = .array(log)
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch {
            // The messages went out. Failing to write the note afterwards is
            // not a reason to tell the shop its campaign failed.
        }
    }

    /// Turn a customer's points into store credit.
    ///
    /// TWO RECORDS, ONE SWAP. The gift card and the ledger row are written
    /// together or not at all: a card written without its row is the same
    /// points spent again next month, and a row written without its card is a
    /// customer told their balance is gone with nothing to show for it.
    ///
    /// Returns nil when it worked, or what to tell the shop.
    func redeemPoints(_ clientId: String) async -> String? {
        guard permitted("invoicing", "edit") else { return moveProblem }
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            return words.callIt("mac.read_only")
        }
        guard let engine, loyaltyOn else { return words.callIt("loyalty.none_to_redeem") }
        guard let standing = await loyalty(of: clientId), standing.available > 0 else {
            return words.callIt("loyalty.none_to_redeem")
        }

        // The shop's own rate, and the rule's default when it has not set one:
        // a hundred points to the unit.
        var rate = 0.01
        if case .number(let set)? = settingsDict["loyaltyRedeemRate"], set > 0 { rate = set }

        let made: KhaytEngine.Redemption
        do {
            made = try await engine.redeemLoyalty(
                clientId: clientId, clientName: clientNames[clientId]?.name ?? "",
                points: standing.available, rate: rate,
                code: Self.uid("LOY"), cardId: Self.uid("GC"),
                entryId: Self.uid("LOY"), now: Self.isoNow())
        } catch {
            return self.said(error)
        }
        guard made.ok, let card = made.card, let entry = made.entry else {
            return words.callIt("loyalty.none_to_redeem")
        }

        // THE STANDING WAS WORKED OUT FROM THE BOOK AS LOADED. Another device
        // or the other app may have redeemed these same points since; issued
        // again, they are store credit twice. So the write refuses when the
        // customer's ledger on disk holds a row this standing never saw.
        let seen = Self.ledgerIds(loyaltyRows, clientId: clientId)
        let changed = words.callIt("mac.loyalty_changed")
        do {
            try await StoreWriter.updateOffMain(build) { root in
                var onDisk: [JSONValue] = []
                if case .array(let rows)? = root["loyaltyLedger"] { onDisk = rows }
                guard Self.ledgerIds(onDisk, clientId: clientId).isSubset(of: seen) else {
                    throw MoveRefused(sentence: changed)
                }
                var cards: [JSONValue] = []
                if case .array(let existing)? = root["giftCards"] { cards = existing }
                cards.append(card)
                root["giftCards"] = .array(cards)

                var ledger: [JSONValue] = []
                if case .array(let existing)? = root["loyaltyLedger"] { ledger = existing }
                ledger.append(entry)
                root["loyaltyLedger"] = .array(ledger)
            }
        } catch let refusal as MoveRefused {
            await load(source)
            return refusal.sentence
        } catch {
            return self.said(error)
        }
        await load(source)
        return nil
    }

    /// The ids of one customer's loyalty ledger rows.
    nonisolated static func ledgerIds(_ rows: [JSONValue], clientId: String) -> Set<String> {
        var out: Set<String> = []
        for case .object(let o) in rows where o["clientId"] == .string(clientId) {
            if case .string(let id)? = o["id"] { out.insert(id) }
        }
        return out
    }

    var shownCustomers: [Customer] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return customers }
        return customers.filter {
            $0.name.lowercased().contains(q) || $0.orders.contains { $0.project.lowercased().contains(q) }
        }
    }

    var selectedCustomer: Customer? { customers.first { $0.id == customerSelection } }

    func count(group: String) -> Int { files.count { $0.groupName == group } }

    /// The record's folder on this Mac, if it is on this Mac at all.
    /// Take a model out of the library — the record, and its files.
    ///
    /// ── THE MAC HAD NO WAY TO DO THIS ───────────────────────────────────────
    ///
    /// Reported from the running app: "I can't delete something from the
    /// library?" — and the answer was that nothing in the Mac app could. The
    /// menu offered Quick Look, Reveal, Open, Convert, Copy name; the model
    /// stayed forever. The Electron app has had this since the library
    /// existed, and a renderer-only feature is a gap to close.
    ///
    /// The rule is `renderer/printfiles.js deletePrintFile`'s, kept in step:
    /// confirmed first, in the same words; every file in the model's own
    /// folder is deleted and the record goes regardless — but a file that
    /// would not go is SAID, because the record was once removed and "File
    /// deleted" shown while the bytes stayed on disk.
    ///
    /// ── TO THE TRASH, NOT OFF THE DISK ────────────────────────────────────
    ///
    /// This used `removeItem`, so a model a shop deleted was gone: no undo in
    /// the app by design, and none outside it either. The codebase argues the
    /// opposite case elsewhere in its own words — a duplicate is refused
    /// rather than overwritten because "a duplicate is recoverable, a deletion
    /// is not" — and then deleted permanently.
    ///
    /// `trashItem` puts it where every other Mac app puts it, so the Finder is
    /// the undo. The record still goes regardless and there is still no undo
    /// inside the app: a record restored without its bytes is a model that
    /// looks present and is not.
    /// To the Trash, falling back to deleting outright.
    ///
    /// A volume with no Trash — a network share, some external disks — refuses
    /// `trashItem`, and a model that could not be deleted because the disk it
    /// is on has no wastebasket would be a worse answer than the old one. The
    /// shop asked for it gone; this only changes WHERE it goes when it can.
    ///
    /// ── NEVER PERMANENTLY, ANY MORE ───────────────────────────────────────
    ///
    /// This fell back to deleting outright on ANY error from the Trash. A
    /// model the Trash will not take (a share with no wastebasket) now stays
    /// where it is and the delete says it was partial — which the caller
    /// already reports — rather than going for good. Found by a file-safety
    /// scan; the Finder can still delete it by hand.
    nonisolated static func trash(_ url: URL) throws {
        // lock: callers — moveStrandedFiles, unlinkFolder, deleteLibraryFiles, removeLocalCopy
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func deleteLibraryFile(_ file: LibraryFile) async {
        guard permitted("inventory", "delete") else { return }
        await deleteLibraryFiles([file])
    }

    /// ── SEVERAL MODELS, FROM THE LIBRARY SCREEN ──────────────────────────
    ///
    /// The door every multi-delete the shop asks for goes through. It refuses
    /// outright when any model chosen is not drawn as a tile on screen right
    /// now — inside a folder tile, behind a search or a filter. The selection
    /// should never hold one (see `selectedFiles`); this is the second lock,
    /// because the first one failing cost a shop a 34-model group (27 Sep
    /// 2026), and a delete is the one library action that cannot be undone.
    ///
    /// Returns the models not on screen; empty means the question was asked.
    @discardableResult
    func askToDeleteFromLibrary(_ chosen: [LibraryFile]) -> [LibraryFile] {
        let hidden = notOnScreen(chosen)
        guard hidden.isEmpty else {
            pendingLibraryDeletes = []
            importProblem = words.counting(hidden.count, "mac.delete_not_on_screen")
            return hidden
        }
        pendingLibraryDeletes = chosen
        return []
    }

    /// The confirmation's Delete: checked again, because a question can sit
    /// open while the library underneath it changes.
    ///
    /// `chosen` is the list as the button saw it, taken SYNCHRONOUSLY in its
    /// action: the dialog empties `pendingLibraryDeletes` as it closes, before
    /// any `Task` the button starts gets to run, so a Delete that read it here
    /// deleted nothing at all (Oct 2026 review).
    func confirmLibraryDeletes(_ chosen: [LibraryFile]? = nil) async {
        let chosen = chosen ?? pendingLibraryDeletes
        let hidden = notOnScreen(chosen)
        guard hidden.isEmpty else {
            pendingLibraryDeletes = []
            importProblem = words.counting(hidden.count, "mac.delete_not_on_screen")
            return
        }
        await deleteLibraryFiles(chosen)
    }

    /// Which of these are not drawn as a model tile right now.
    func notOnScreen(_ chosen: [LibraryFile]) -> [LibraryFile] {
        let visible = Set(visibleFiles.map(\.id))
        return chosen.filter { !visible.contains($0.id) }
    }

    /// What the multi-delete question says: how many, WHICH — the first
    /// eight by name, then how many more — and how many of them are filed in
    /// a group. A count alone is what a shop said yes to on 27 Sep 2026
    /// without seeing that it was a whole group.
    func libraryDeleteMessage(_ chosen: [LibraryFile]) -> String {
        Self.libraryDeleteLines(chosen, words: words).joined(separator: "\n")
    }

    static let deleteNamesShown = 8

    static func libraryDeleteLines(_ chosen: [LibraryFile], words: Words) -> [String] {
        var lines = [words.callIt("mac.delete_n_confirm", ["n": .number(Double(chosen.count))])]
        lines.append("")
        lines += chosen.prefix(deleteNamesShown).map { "\u{2022} " + $0.title }
        if chosen.count > deleteNamesShown {
            lines.append(words.callIt("mac.delete_and_more",
                                      ["n": .number(Double(chosen.count - deleteNamesShown))]))
        }
        let grouped = chosen.filter { !($0.groupName ?? "").isEmpty }
        if !grouped.isEmpty {
            var names: [String] = []
            for g in grouped.compactMap(\.groupName) where !names.contains(g) { names.append(g) }
            lines.append("")
            lines.append(words.callIt("mac.delete_in_groups",
                                      ["n": .number(Double(grouped.count)),
                                       "groups": .string(names.prefix(3).joined(separator: ", ")
                                                         + (names.count > 3 ? "\u{2026}" : ""))]))
        }
        return lines
    }

    /// Delete several models at once: ONE write that takes all their records
    /// out of the book, then — for the records that write took out — every
    /// folder to the Trash.
    ///
    /// The shop could select many models and group or tag them together, but
    /// delete took one at a time ("I tried to delete multiple files from the
    /// library but can't, only one at a time"). One write rather than one per
    /// model, so a delete of fifty is one change to sync and one undo-free
    /// moment rather than fifty.
    ///
    /// ── THE BOOK FIRST, THEN THE TRASH ──────────────────────────────────
    ///
    /// The folders went to the Trash first and the book was written after.
    /// A write then refused (the other app took the book) put every record
    /// back on screen with its files already gone: a model that looks
    /// present and is not. Now nothing leaves the disk until its record has
    /// left the book, and only the records the write actually took out. A
    /// folder the Trash then refuses stays where it is — an orphaned folder
    /// is recoverable; a record whose files went without it is not — and the
    /// delete says it was partial.
    func deleteLibraryFiles(_ files: [LibraryFile]) async {
        guard permitted("inventory", "delete") else { return }
        clearLastOutcome()
        pendingLibraryDelete = nil
        pendingLibraryDeletes = []
        guard !files.isEmpty else { return }
        guard let build = source.build else {
            importProblem = words.callIt("mac.move_sample"); return
        }
        let ids = Set(files.map(\.id))
        let roots = libraryRoots?.roots ?? []
        // A linked folder's model is remembered too: its file stays where the
        // shop keeps it, and the next linked scan would index it again.
        let remembering = roots + linkedFolders
        let base = libraryBase()
        // Off the screen NOW — see `Shop+LibraryWrites.swift`. Everything
        // below is off the main thread until the book is written.
        let pending = beginLibraryChange(ids, change: nil)
        let chosen = files
        let written: LibraryWritten
        let removed: Set<String>
        do {
            (written, removed) = try await StoreWriter.updateOffMain(build) { root -> (LibraryWritten, Set<String>) in
                let before = Self.rows(root, "printFiles")
                var rows = before
                let present = Set(before.compactMap(Self.recordId)).intersection(ids)
                rows.removeAll { Self.recordId($0).map(ids.contains) ?? false }
                root["printFiles"] = .array(rows)
                // A model ADOPTED from the library's own folder, or indexed
                // from a linked one, keeps its file where the shop put it — so
                // remember not to take it in again, or the delete is undone on
                // the next launch (`LibraryStorage`, `rescanLinkedFolders`).
                var settings = Self.settings(root)
                var library: [String: JSONValue] = [:]
                if case .object(let l)? = settings["printLibrary"] { library = l }
                var already: [JSONValue] = []
                if case .array(let a)? = library["notAdopted"] { already = a }
                let next = Self.notAdoptedAfterDeleting(chosen, roots: remembering, already: already)
                if next.count != already.count || next != already {
                    library["notAdopted"] = .array(next)
                    settings["printLibrary"] = .object(library)
                    root["settings"] = .object(settings)
                }
                return (Self.libraryWritten(root, touched: ids, before: before, base: base), present)
            }
        } catch {
            endLibraryChange(pending)
            importProblem = self.said(error)
            // Nothing was written, and nothing went to the Trash: the book
            // still holds them, with their files, so the screen must too.
            await load(source)
            return
        }
        endLibraryChange(pending)
        // One delete, however many models it took.
        Telemetry.feature(.libraryDelete, in: self)
        await showLibraryWritten(written, touched: ids)

        // The folders to the Trash — only of records the write took out —
        // off the main thread: a model on a network share or an online-only
        // cloud folder can hold `trashItem` for seconds.
        let allGone = await BookWork.run { () -> Bool in
            var allGone = true
            for file in chosen where removed.contains(file.id) {
                guard let dir = LibraryLocation.directory(for: file.id, roots: roots) else { continue }
                var thisGone = true
                let contents = (try? FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: nil)) ?? []
                for url in contents {
                    do { try Self.trash(url) } catch {
                        thisGone = false
                        Self.deleteLog.error("""
                            deleted \(file.id, privacy: .public) from the book; its file \
                            \(url.path, privacy: .private) stays: \(error.localizedDescription, privacy: .public)
                            """)
                    }
                }
                if thisGone { try? Self.trash(dir) } else { allGone = false }
            }
            return allGone
        }
        if !allGone {
            importProblem = words.callIt("plib.delete_partial")
        } else if chosen.count == 1 {
            importNote = words.callIt("plib.deleted")
        } else {
            importNote = words.counting(chosen.count, "mac.deleted_n_models")
        }
    }

    /// Where a delete says which files it had to leave behind.
    nonisolated static let deleteLog = Logger(subsystem: "app.khayt.mac", category: "library-delete")

    func directory(for file: LibraryFile) -> URL? {
        guard let roots = libraryRoots else { return nil }
        return LibraryLocation.directory(for: file.id, roots: roots.roots)
    }

    func fileIsPresent(_ file: LibraryFile) -> Bool { directory(for: file) != nil }

    /// The guides sitting beside a model — assembly instructions, a colour
    /// guide, whatever came out of the pack with it.
    ///
    /// READ OFF THE DISK rather than out of the book, which is the whole
    /// reason this needed no new field in the store. A model's folder holds
    /// everything about that model; the PDFs in it are its papers by being
    /// there, and a shop that drops one in by hand gets the same answer as one
    /// that imported a pack. Nothing to migrate, nothing to keep in step, and
    /// nothing for the Electron app to learn.
    func guides(for file: LibraryFile) -> [URL] {
        guard let dir = directory(for: file),
              let found = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return found
            .filter { ArchiveImport.documentKinds.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                      == .orderedAscending }
    }

    /// The model file itself, if it is on this Mac.
    ///
    /// The record names it (`sourceFile.filename`), but a folder that has one
    /// model in it and a differently-named record is a state this app should
    /// survive rather than shrug at, so a single model file in the folder is
    /// taken as the model.
    func modelFile(for file: LibraryFile) -> URL? {
        // A linked model is where the shop keeps it, or not reachable right
        // now (a drive unplugged, a NAS asleep) — never a vault file instead.
        if let path = file.externalPath, !path.isEmpty {
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard let dir = directory(for: file) else { return nil }
        if let named = file.sourceFile?.filename, !named.isEmpty {
            let url = dir.appending(path: named)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil)) ?? []
        return Self.soleModel(in: contents)
    }

    /// The one model file in a record's folder, or nil when there is none or
    /// more than one.
    ///
    /// ONLY WHAT THE LIBRARY FILES AS A MODEL (`LibraryImport.kinds`). This
    /// used to be "anything but a picture or a `.cloud` sidecar" — so a folder
    /// holding a pack's assembly PDF beside a model that had been moved to the
    /// cloud answered with the PDF, and "Open in slicer" handed the slicer a
    /// document. A `.cloud` note is a few hundred bytes of JSON, and a partial
    /// download (`.part-`) is not a file yet.
    static func soleModel(in contents: [URL]) -> URL? {
        let models = contents.filter {
            LibraryImport.kinds.contains($0.pathExtension.lowercased())
                && !$0.lastPathComponent.contains(".part-")
        }
        return models.count == 1 ? models[0] : nil
    }
}
