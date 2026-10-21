import Foundation
import UniformTypeIdentifiers
import AppKit
import KhaytCore

/// The question before a customer is erased: who, and what the full erase
/// would touch. Frozen when asked, like `RecordDeleteRequest`, so the counts
/// the shop read are the ones it confirmed against — the write plans again
/// anyway, on the book as it is then.
struct CustomerEraseRequest: Identifiable, Equatable {
    let id = UUID()
    let clientId: String
    let name: String
    /// The FULL plan: its counts are what the sheet states, and with Unlink
    /// the intake and communications simply stay.
    let plan: KhaytEngine.ErasurePlan
}

/// What an erase took out of the book, for Undo to put back.
struct ErasedCustomer: Sendable, Equatable {
    struct Job: Sendable, Equatable {
        let id: String
        /// The name the job carried, when the erase blanked it.
        let blankedName: JSONValue?
    }
    let clientId: String
    let client: JSONValue
    let index: Int
    let jobs: [Job]
    let intake: [JSONValue]
    let intakeHistory: [JSONValue]
    /// The tracking tokens of this customer's jobs whose pages a full erase
    /// takes down from Khayt Cloud. Undo does not put a page back.
    var takenDown: [String] = []
    /// The gift cards a full erase took the holder off, as they were.
    var giftCards: [JSONValue] = []
    /// The loyalty-ledger rows whose link a full erase blanked, as they were.
    var loyaltyLedger: [JSONValue] = []
}

/// A customer's rights over their own data (PDPL): to have it, and to have it
/// erased.
///
/// ── THE RULE IS `lib/privacy.js`, THE ONE THE DESKTOP ASKS ───────────────
///
/// `buildClientDataExport` decides what "their data" is, and
/// `planClientErasure` what an erase takes. This file only reads the book for
/// the first and applies the second, so a Mac-only shop answers a customer's
/// request exactly as a desktop shop does (`renderer/clients.js`
/// `exportClientData` and `deleteClient`).
///
/// ── TWO KINDS OF ERASE ───────────────────────────────────────────────────
///
/// Unlink (recommended) removes the customer record and the link from their
/// jobs; the jobs keep their name for the shop's financial and ZATCA records.
/// Full erase also blanks the name on the jobs that have no invoice and no
/// payment, and purges their intake rows. An invoiced or paid job keeps its
/// buyer: a tax invoice is kept as issued (`mustKeepBuyer`). Either way the
/// communications log goes, because it lives on the record.
///
/// Plain Delete (`Shop+Delete.swift`) stays as it was, for a customer with no
/// jobs and no gift cards.
extension Shop {

    /// The collections the privacy rule reads, out of a book.
    nonisolated static func privacyCollections(_ root: [String: JSONValue]) -> [String: JSONValue] {
        ["clients": .array(rows(root, "clients")),
         "printLog": .array(rows(root, "printLog")),
         "waitingList": .array(rows(root, "waitingList")),
         "waitingListHistory": .array(rows(root, "waitingListHistory")),
         "giftCards": .array(rows(root, "giftCards")),
         "loyaltyLedger": .array(rows(root, "loyaltyLedger"))]
    }

    /// The desktop's file name: `khayt-customer-data-<name>-<day>.json`, the
    /// name stripped to letters, digits, Arabic, spaces and dashes.
    nonisolated static func customerDataFilename(name: String, clientId: String, now: Date = Date()) -> String {
        // The desktop's `[^\w\u0600-\u06FF -]`: JavaScript's `\w` is ASCII only.
        let kept = String(String.UnicodeScalarView(name.unicodeScalars.filter { s in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "_" || s == " " || s == "-"))
                || (0x0600...0x06FF).contains(s.value)
        })).trimmingCharacters(in: .whitespaces)
        return "khayt-customer-data-\(kept.isEmpty ? clientId : kept)-\(localDay(now)).json"
    }

    /// The export, as the file holds it: indented, keys in a fixed order.
    nonisolated static func customerDataJSON(_ payload: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    // MARK: - Access

    /// Write everything the book holds about this customer to a file the shop
    /// chooses. Reads the book; writes nothing to it.
    ///
    /// Asks `clients`/`edit`, not `view`: seeing a customer on screen is not
    /// the same as handing their whole record out as a file, and the roles
    /// that may only look at customers are the ones that should not.
    func exportCustomerData(_ person: Customer) async {
        moveProblem = nil
        moveNotices = []
        guard permitted("clients", "edit") else { return }
        guard let clientId = person.record?.id else { return }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return }
        do {
            let root = try StoreReader(build: build).raw
            let payload = try await engine.clientDataExport(clientId: clientId,
                                                            collections: Self.privacyCollections(root))
            let data = try Self.customerDataJSON(payload)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = Self.customerDataFilename(name: person.name, clientId: clientId)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            // One person's whole record: readable by this Mac's user only,
            // wherever the shop put it (alpha.82 review).
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var orders = 0
            if case .object(let o) = payload, case .object(let counts)? = o["counts"],
               case .number(let n)? = counts["orders"] { orders = Int(n) }
            moveNotices = [words.callIt("priv.exported", ["n": .number(Double(orders))])]
        } catch {
            moveProblem = words.callIt("mac.export_failed") + " " + String(describing: error)
        }
    }

    // MARK: - Erasure

    /// Ask how to erase this customer: the sheet states the counts and offers
    /// Unlink and Full erase.
    func askToEraseCustomer(_ person: Customer) async {
        moveProblem = nil
        guard canMoveJobs else { moveProblem = lockedReason; return }
        guard permitted("clients", "delete") else { return }
        guard let clientId = person.record?.id else { return }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return }
        do {
            let root = try StoreReader(build: build).raw
            let plan = try await engine.planClientErasure(clientId: clientId,
                                                          collections: Self.privacyCollections(root), full: true)
            erasingCustomer = CustomerEraseRequest(clientId: clientId, name: person.name, plan: plan)
        } catch {
            moveProblem = String(describing: error)
        }
    }

    /// The erase, inside the store write: the plan is made again from `root`,
    /// so it is the book as it is now that is erased, not the one the sheet
    /// was opened on. Nil when the customer is already gone.
    ///
    /// The record goes (and its communications log with it), and every job's
    /// link to it is nulled. A full erase also blanks the name on the jobs the
    /// plan allows and drops the intake rows it names — nothing else.
    static func applyCustomerErase(to root: inout [String: JSONValue], clientId: String,
                                    full: Bool, engine: KhaytEngine) async throws -> ErasedCustomer? {
        let plan = try await engine.planClientErasure(clientId: clientId,
                                                      collections: privacyCollections(root), full: full)
        var clients = rows(root, "clients")
        guard let index = clients.firstIndex(where: {
            if case .object(let o) = $0, case .string(let id)? = o["id"] { return id == clientId }
            return false
        }) else { return nil }
        let client = clients.remove(at: index)
        root["clients"] = .array(clients)

        let blank = Set(full ? plan.blankNameOrderIds : [])
        var jobs: [ErasedCustomer.Job] = []
        var takenDown: [String] = []
        var log = rows(root, "printLog")
        let erasedAt = JSONValue.string(ISO8601DateFormatter().string(from: Date()))
        for i in log.indices {
            guard case .object(var o) = log[i], case .string(let link)? = o["clientId"], link == clientId,
                  case .string(let id)? = o["id"] else { continue }
            o["clientId"] = .null
            // Marked, so a job that keeps the name is never matched BY that
            // name to another customer who shares it (`Customer.swift`).
            o["clientErasedAt"] = erasedAt
            var was: JSONValue?
            if blank.contains(id) { was = o["client"] ?? .null; o["client"] = .string("") }
            // A published job's page lives on Khayt Cloud, linked to the
            // customer's email and holding their messages and photos. A full
            // erase takes every one down, invoiced and paid jobs included: the
            // invoice stays in the book, the tracking page was a convenience.
            // The mark goes in this write, so nothing on this Mac republishes
            // the page; the DELETE follows the write (`eraseCustomer`).
            if full, o["cloudPublished"] == .bool(true),
               case .string(let token)? = o["trackingToken"], !token.isEmpty {
                takenDown.append(token)
                o["cloudPublished"] = .bool(false)
            }
            jobs.append(.init(id: id, blankedName: was))
            log[i] = .object(o)
        }
        if !jobs.isEmpty { root["printLog"] = .array(log) }

        func purge(_ collection: String, _ ids: [String]) -> [JSONValue] {
            let gone = Set(ids)
            guard !gone.isEmpty else { return [] }
            var kept: [JSONValue] = [], taken: [JSONValue] = []
            for row in rows(root, collection) {
                if case .object(let o) = row, case .string(let id)? = o["id"], gone.contains(id) {
                    taken.append(row)
                } else {
                    kept.append(row)
                }
            }
            if !taken.isEmpty { root[collection] = .array(kept) }
            return taken
        }
        let intake = full ? purge("waitingList", plan.purgeIntakeIds) : []
        let history = full ? purge("waitingListHistory", plan.purgeIntakeHistoryIds) : []

        // A spent gift card loses its holder; one with a balance keeps it,
        // because that balance is money the shop owes them (the plan decides).
        var cardsWere: [JSONValue] = []
        let spent = Set(full ? plan.unlinkGiftCardIds : [])
        if !spent.isEmpty {
            var cards = rows(root, "giftCards")
            for i in cards.indices {
                guard case .object(var g) = cards[i], case .string(let id)? = g["id"], spent.contains(id) else { continue }
                cardsWere.append(cards[i])
                g["issuedTo"] = .null
                g["issuedToName"] = .string("")
                cards[i] = .object(g)
            }
            if !cardsWere.isEmpty { root["giftCards"] = .array(cards) }
        }
        // The loyalty ledger keeps its points and credit, for the shop's sums,
        // and loses the link to the person.
        var ledgerWas: [JSONValue] = []
        if full && plan.unlinkLoyaltyLedger {
            var ledger = rows(root, "loyaltyLedger")
            for i in ledger.indices {
                guard case .object(var r) = ledger[i], case .string(let link)? = r["clientId"], link == clientId
                else { continue }
                ledgerWas.append(ledger[i])
                r["clientId"] = .string("")
                ledger[i] = .object(r)
            }
            if !ledgerWas.isEmpty { root["loyaltyLedger"] = .array(ledger) }
        }
        return ErasedCustomer(clientId: clientId, client: client, index: index, jobs: jobs,
                              intake: intake, intakeHistory: history, takenDown: takenDown,
                              giftCards: cardsWere, loyaltyLedger: ledgerWas)
    }

    /// Undo's half: the record back where it was, the jobs relinked (and
    /// renamed where the erase blanked them and nothing has named them since),
    /// the intake rows back. The write chain gives each a fresh id and moves
    /// the links with it (`StoreWriter.reviveUnderNewIds`).
    nonisolated static func applyCustomerUnerase(to root: inout [String: JSONValue], _ erased: ErasedCustomer) {
        func has(_ rows: [JSONValue], _ row: JSONValue) -> Bool {
            guard case .object(let r) = row, case .string(let id)? = r["id"] else { return false }
            return rows.contains { if case .object(let o) = $0, case .string(let other)? = o["id"] { other == id } else { false } }
        }
        var clients = rows(root, "clients")
        if !has(clients, erased.client) {
            clients.insert(erased.client, at: max(0, min(erased.index, clients.count)))
            root["clients"] = .array(clients)
        }
        let byId = Dictionary(erased.jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var log = rows(root, "printLog")
        for i in log.indices {
            guard case .object(var o) = log[i], case .string(let id)? = o["id"], let job = byId[id] else { continue }
            switch o["clientId"] { case nil, .null?: break; default: continue }
            o["clientId"] = .string(erased.clientId)
            o.removeValue(forKey: "clientErasedAt")
            if let name = job.blankedName, o["client"] == .string("") { o["client"] = name }
            log[i] = .object(o)
        }
        root["printLog"] = .array(log)
        // The cards' holders back, where nobody has named another since.
        if !erased.giftCards.isEmpty {
            let was = Dictionary(erased.giftCards.compactMap { row -> (String, [String: JSONValue])? in
                guard case .object(let g) = row, case .string(let id)? = g["id"] else { return nil }
                return (id, g)
            }, uniquingKeysWith: { a, _ in a })
            var cards = rows(root, "giftCards")
            for i in cards.indices {
                guard case .object(var g) = cards[i], case .string(let id)? = g["id"], let before = was[id],
                      g["issuedTo"] == nil || g["issuedTo"] == .null else { continue }
                g["issuedTo"] = before["issuedTo"] ?? .null
                g["issuedToName"] = before["issuedToName"] ?? .string("")
                cards[i] = .object(g)
            }
            root["giftCards"] = .array(cards)
        }
        // The ledger rows relinked: each blanked row, found by its content —
        // a row may have no id, and the write stamped it since.
        if !erased.loyaltyLedger.isEmpty {
            func content(_ o: [String: JSONValue]) -> [String: JSONValue] {
                var c = o
                for key in ["clientId", "rev", "updatedAt"] { c.removeValue(forKey: key) }
                return c
            }
            var ledger = rows(root, "loyaltyLedger")
            for case .object(let before) in erased.loyaltyLedger {
                let wanted = content(before)
                guard let i = ledger.firstIndex(where: {
                    if case .object(let r) = $0 { return r["clientId"] == .string("") && content(r) == wanted }
                    return false
                }), case .object(var r) = ledger[i] else { continue }
                r["clientId"] = .string(erased.clientId)
                ledger[i] = .object(r)
            }
            root["loyaltyLedger"] = .array(ledger)
        }
        for (collection, taken) in [("waitingList", erased.intake), ("waitingListHistory", erased.intakeHistory)]
        where !taken.isEmpty {
            var rowsNow = rows(root, collection)
            for row in taken where !has(rowsNow, row) { rowsNow.append(row) }
            root[collection] = .array(rowsNow)
        }
    }

    /// Erase the customer the shop confirmed, as it chose.
    func eraseCustomer(_ clientId: String, full: Bool) async {
        moveProblem = nil
        moveNotices = []
        guard permitted("clients", "delete") else { return }
        guard let build = source.build else { moveProblem = words.callIt("mac.move_sample"); return }
        guard let engine else { moveProblem = words.callIt("mac.move_no_engine"); return }
        let pending: PendingUndo<[ErasedCustomer]> =
            pendingUndo(named: words.callIt("priv.erase_title")) { shop, erased in
                shop.putBackErasedCustomer(erased, in: build)
            }
        defer { pending.drop() }
        var outcome: ErasedCustomer?
        do {
            try await StoreWriter.updateAsync(build) { root in
                outcome = try await Self.applyCustomerErase(to: &root, clientId: clientId, full: full, engine: engine)
            }
            guard let outcome else { return }
            pending.keepUnlessEmpty([outcome])
            if customerSelection == clientId { customerSelection = nil }
            customerSelections.remove(clientId)
            await load(source)
            moveNotices = [words.callIt(full ? "priv.erased_full" : "ce.deleted")]
            await customersChangedOnCloud()
            // After the write, as a job delete does: the book is erased either
            // way, and a page that would not come down is said, not swallowed.
            await takeDownLinks(outcome.takenDown, engine: engine)
        } catch {
            moveProblem = self.said(error)
        }
    }

    /// Put an erased customer back, through Undo.
    private func putBackErasedCustomer(_ erased: [ErasedCustomer], in build: StoreReader.Build) {
        guard permitted("clients", "edit") else { return }
        let shop = self
        Task { do {
            try await StoreWriter.updateAsync(build) { root in
                for one in erased.reversed() { Self.applyCustomerUnerase(to: &root, one) }
            }
            await shop.load(shop.source)
            await shop.customersChangedOnCloud()
        } catch {
            shop.moveProblem = shop.said(error)
        } }
    }
}

extension Shop {
    /// The customer list changed by a person's hand — an erase, a delete, or
    /// the Undo of either: the cloud's customer-records copy is brought into
    /// line NOW, not on the next ten-minute look. An erased customer's email,
    /// phone and orders stayed readable on Khayt Cloud until then, and until
    /// the 30-day prune if this Mac was closed first (Khayt Cloud review, Oct
    /// 2026). Off, with nothing of this Mac's published, this does nothing;
    /// the shared rule decides put or none as it always does.
    func customersChangedOnCloud() async {
        await publishCustomerRecords(urgent: true)
    }
}
