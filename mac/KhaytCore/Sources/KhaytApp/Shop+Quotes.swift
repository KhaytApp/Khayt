import Foundation
import KhaytCore

/// A quote's answers besides Approve: Reject, Revise and its history, and the
/// follow-up nudge — by hand, and automatically when the shop has asked.
///
/// ── THE SAME FIELDS AS THE OTHER APP ──────────────────────────────────────
///
/// * Reject is the DELETE rule (`lib/record-delete.js`), as the desktop's
///   `rejectQuote` is: a quote nobody paid or numbered goes, with Undo; one
///   that took a deposit or a number is refused, and cancelled instead.
/// * Revise keeps what the quote says now in `quoteRevisions[]` and moves
///   `quoteVersion` on one (`lib/quote-revision.js`), then opens the editor.
/// * A follow-up is recorded as `followUpSentAt` and `followUpCount`
///   (`lib/quote-followup.js` `markFollowUpPatch`) — which is what the
///   cooldown and the cap read, on both computers.
extension Shop {

    // MARK: - Reject

    /// Reject a quote: delete it, asking first, or — when the rule refuses
    /// (paid, numbered) — say why, with Cancel Job beside it in the menus.
    func rejectQuote(_ id: Order.ID) {
        moveProblem = nil
        guard let job = orders.first(where: { $0.id == id }), job.status == "quote" else { return }
        guard canMoveJobs else { moveProblem = lockedReason; return }
        if let why = jobDeleteRefusal(id) {
            moveProblem = words.callIt("mac.delete_refused",
                                       ["name": .string(shownTitle(of: job)), "why": .string(why)])
            return
        }
        askToDeleteJobs([id])
    }

    // MARK: - Revise, and the history

    /// The version a quote is on now: 1 before it was ever revised.
    func quoteVersion(_ id: Order.ID) -> Int {
        guard case .object(let o)? = orderRow(id), let n = Self.plainNumber(o["quoteVersion"]), n >= 1 else { return 1 }
        return Int(n)
    }

    /// Whether the quote has kept versions to show.
    func hasQuoteRevisions(_ id: Order.ID) -> Bool {
        guard case .object(let o)? = orderRow(id), case .array(let rows)? = o["quoteRevisions"] else { return false }
        return !rows.isEmpty
    }

    /// Keep what the quote says now as a revision, then open the editor so the
    /// shop can change it — the desktop's Revise.
    func reviseQuote(_ id: Order.ID) async {
        guard let job = orders.first(where: { $0.id == id }), job.status == "quote" else { return }
        let wrote = await writeToOneOrder(id, named: words.callIt("ord.revise_quote"),
                                          as: .person("orders", "edit")) { order, engine, _ in
            OneOrderEdit(order: try await engine.reviseQuote(order: order),
                         activity: "\(id) → " + self.words.callIt("ord.revise_quote"))
        }
        if wrote { pendingEdit = PendingHold(id: id, project: job.project) }
    }

    /// Show a quote's kept versions.
    func showQuoteRevisions(_ id: Order.ID) {
        guard let job = orders.first(where: { $0.id == id }) else { return }
        pendingRevisions = PendingHold(id: id, project: job.project)
    }

    /// A quote's kept versions, newest first.
    func quoteRevisions(_ id: Order.ID) async -> [KhaytEngine.QuoteRevision] {
        guard let engine, let row = orderRow(id) else { return [] }
        return (try? await engine.quoteRevisions(order: row)) ?? []
    }

    // MARK: - Follow-ups

    /// How many follow-ups this quote has had (`followUpCount`).
    func followUpCount(_ id: Order.ID) -> Int {
        guard case .object(let o)? = orderRow(id), let n = Self.plainNumber(o["followUpCount"]) else { return 0 }
        return Int(n)
    }

    /// The follow-up's words: `quote.followup_msg`, the desktop's own.
    func followUpText(for job: Order) -> String {
        var expires = ""
        if case .object(let o)? = orderRow(job.id) { expires = Self.plainString(o["quoteExpiresAt"]) ?? "" }
        let name = job.client.isEmpty ? (job.project.isEmpty ? job.reference : job.project) : job.client
        return words.callIt("quote.followup_msg", [
            "name": .string(name), "id": .string(job.id),
            "project": .string(job.project.isEmpty ? job.reference : job.project),
            "total": .string(Money.text(job.price, job.currency.isEmpty ? currency : job.currency)),
            "expires": .string(expires),
        ])
    }

    /// Follow up on a quote by hand: the message opens in WhatsApp, and the
    /// follow-up is recorded so the cooldown and the cap hold — here and on
    /// the other computer.
    func sendQuoteFollowUp(_ id: Order.ID) async {
        moveProblem = nil
        guard permitted("orders", "edit") else { return }
        guard let job = orders.first(where: { $0.id == id }), job.status == "quote" else {
            moveProblem = words.callIt("mac.move_gone"); return
        }
        guard let phone = clientRecord(for: job)?.client.phone,
              !phone.filter(\.isNumber).isEmpty else {
            moveProblem = words.callIt("quote.followup_no_phone"); return
        }
        if let why = await sendWhatsApp(for: job, text: followUpText(for: job), milestone: nil, lang: nil) {
            moveProblem = why; return
        }
        await recordFollowUps([id])
        await noteQuoteShared(id)
    }

    /// The follow-up on each of these quotes, in one write.
    ///
    /// Inside the write, on the book as it is on disk: a quote the other
    /// computer followed up a moment ago carries its stamp there, and is
    /// stamped once more only if the send really happened here (`by hand`),
    /// never by the automatic pass — which asks the shared rule again first.
    @discardableResult
    func recordFollowUps(_ ids: [Order.ID], onlyIfDue: Bool = false, now: Date = Date()) async -> [Order.ID] {
        guard lockAllows("orders", "edit"), let build = source.build, let engine else { return [] }
        let wanted = Set(ids)
        let label = words.callIt("quote.followup_btn")
        var stamped: [Order.ID] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                stamped = []
                let settings = Self.settings(root)
                var rows = Self.rows(root, "printLog")
                for (i, row) in rows.enumerated() {
                    guard let id = Self.recordId(row), wanted.contains(id) else { continue }
                    if onlyIfDue {
                        let due = try await engine.followUpDue(order: row, settings: settings, now: now)
                        if !due { continue }
                    }
                    guard case .object(var o) = try await engine.markFollowUp(order: row, now: now) else { continue }
                    StoreWriter.stamp(&o)
                    rows[i] = .object(o)
                    stamped.append(id)
                }
                guard !stamped.isEmpty else { throw RecurringOrders.NothingDue() }
                root["printLog"] = .array(rows)
                let snapshot = root
                for id in stamped {
                    Self.appendActivity(&root, text: "\(id) → " + label,
                                        ref: id, settings: settings, root: snapshot, action: "quote_followup")
                }
            }
        } catch {
            return []
        }
        await load(source)
        return stamped
    }

    // MARK: - Automatic: the desktop's six-hourly pass

    /// How often the automatic pass looks again, as the other app's timer.
    static let chaseEvery: TimeInterval = 6 * 60 * 60

    /// The quote follow-ups the shop asked to have sent for it (Settings ▸
    /// Quote follow-ups, OFF by default), as the desktop's
    /// `processQuoteFollowUps` sends them: each quote the shared rule says is
    /// due is recorded, then opened in WhatsApp when its customer has a
    /// number — and recorded all the same when not, so it is nudged once
    /// rather than offered for ever.
    ///
    /// When the book has loaded, at most once every six hours per book, only
    /// on a real book this app owns and only for somebody the staff lock lets
    /// edit jobs. RECORDED FIRST, then sent: a quote is never messaged twice
    /// because a second pass ran before the first had written its stamp.
    func followUpQuotesIfDue(now: Date = Date()) {
        guard case .store(let build) = source, ownership != nil, engine != nil,
              lockAllows("orders", "edit") else { return }
        if let last = chaseRuns[build.rawValue], now.timeIntervalSince(last) < Self.chaseEvery { return }
        guard !quotesToChase.isEmpty else { return }
        chaseRuns[build.rawValue] = now
        let due = quotesToChase.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            let stamped = await self.recordFollowUps(due, onlyIfDue: true, now: now)
            guard !stamped.isEmpty else { return }
            for id in stamped {
                guard let job = self.orders.first(where: { $0.id == id }),
                      let phone = self.clientRecord(for: job)?.client.phone,
                      !phone.filter(\.isNumber).isEmpty else { continue }
                _ = await self.sendWhatsApp(for: job, text: self.followUpText(for: job), milestone: nil, lang: nil)
            }
            self.importNote = self.words.callIt("quote.followup_auto", ["n": .number(Double(stamped.count))])
        }
    }

    /// Overdue invoices, flagged ONCE a session each — the desktop's
    /// `processPaymentReminders`, which only flags: the reminder is the
    /// shop's to send (Today's paper plane, or the job's), and it is recorded
    /// when it goes. Nothing is written and nobody is messaged here.
    func flagOverdueInvoices(_ chase: [Chase]) {
        guard source.isReal else { return }
        let fresh = chase.map(\.id).filter { !flaggedInvoices.contains($0) }
        guard !fresh.isEmpty else { return }
        flaggedInvoices.formUnion(fresh)
        importNote = words.callIt("pay.reminder_auto", ["n": .number(Double(fresh.count))])
    }
}
