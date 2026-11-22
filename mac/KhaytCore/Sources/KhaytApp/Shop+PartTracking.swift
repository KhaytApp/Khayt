import Foundation
import KhaytCore

/// Two things a shop records about one PART of a job while the job is still
/// open, both the desktop's (`renderer/order-flows.js`):
///
/// - **Partial delivery** — which parts have already gone to the customer
///   (`parts[i].delivered`, `openPartialDeliveryModal`).
/// - **Spool switch** — a part's print ran out and finished on another roll
///   (`parts[i].additionalSpools`, `openSpoolSwitchModal`). The grams come off
///   that roll NOW, with a usage line; `lib/order-deduction.js` `claimsFor`
///   then leaves them off the part's own spool at completion, and `cost` and
///   the refund paths read the same list.
///
/// The record edits are pure statics, so the tests drive them on a plain
/// dictionary; the writes go through the same swap and undo as every other
/// job edit.
@MainActor
extension Shop {

    // MARK: - Partial delivery

    /// Mark which parts have gone to the customer. `delivered` is one flag per
    /// part, in the book's order, as the sheet opened them.
    @discardableResult
    func setPartsDelivered(_ id: Order.ID, delivered: [Bool]) async -> Bool {
        guard permitted("orders", "edit") else { return false }
        let gone = words.callIt("mac.move_gone")
        return await writeToOneOrder(id, named: words.callIt("ord.partial_delivery"),
                                     as: .person("orders", "edit")) { order, _, _ in
            guard case .object(var record) = order,
                  Self.applyPartsDelivered(&record, delivered: delivered) else {
                throw MoveRefused(sentence: gone)
            }
            return OneOrderEdit(order: .object(record))
        }
    }

    /// Tick `parts[i].delivered` as asked: `true` where ticked, and the key
    /// REMOVED where not — the book holds `true` or nothing, as the desktop's
    /// readers (`p.delivered` truthiness) expect. False when the job's parts
    /// are not the ones the sheet was showing (a different count), so a list
    /// edited elsewhere since is not ticked by position against the wrong part.
    nonisolated static func applyPartsDelivered(_ record: inout [String: JSONValue],
                                                delivered: [Bool]) -> Bool {
        guard case .array(var parts)? = record["parts"], parts.count == delivered.count else { return false }
        for i in parts.indices {
            guard case .object(var part) = parts[i] else { continue }
            part["delivered"] = delivered[i] ? .bool(true) : nil
            parts[i] = .object(part)
        }
        record["parts"] = .array(parts)
        return true
    }

    /// How many of a job's parts are marked delivered — what the inspector's
    /// "N of M parts delivered" line counts.
    nonisolated static func partsDelivered(_ job: Order) -> Int {
        job.parts.filter(\.delivered).count
    }

    /// Whether a job offers partial delivery: still open, more than one part.
    /// The desktop's menu condition (`renderer/logs.js`).
    static func offersPartialDelivery(_ job: Order) -> Bool {
        !finishedStatuses.contains(job.status) && job.status != "cancelled" && job.parts.count > 1
    }

    // MARK: - Spool switch

    /// Whether a job offers a spool switch: still open work.
    static func offersSpoolSwitch(_ job: Order) -> Bool {
        !finishedStatuses.contains(job.status) && job.status != "cancelled" && !job.parts.isEmpty
    }

    /// Spools a switch can draw from: anything with stock left on it.
    func spoolsForSwitch() -> [Spool] {
        spools.filter { ($0.weight ?? 0) > 0 }
    }

    /// Record that part `partIndex` of a job also printed `grams` from
    /// `spoolId`, and take those grams off that spool — the job and the spool
    /// in ONE write, so neither can land without the other, and one undo puts
    /// both back (the grams by delta, the usage line taken out again).
    ///
    /// Gated as stock: the shelf is what this changes for the shop, and a
    /// person who may not adjust stock may not draw it this way either. The
    /// job edit is asked as well, since the job's record changes too.
    @discardableResult
    func addSpoolSwitch(_ id: Order.ID, partIndex: Int, partCount: Int,
                        spoolId: String, grams: Double) async -> Bool {
        moveProblem = nil
        guard permitted("inventory", "edit"), permitted("orders", "edit") else { return false }
        guard grams > 0, grams.isFinite else { return false }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.move_sample"); return false
        }
        guard let engine else {
            moveProblem = words.callIt("mac.move_no_engine"); return false
        }
        let gone = words.callIt("mac.move_gone")
        var undo: [ChangedRecord] = []
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                // Reset each time: the book moved and this runs again, one
                // undo entry rather than two.
                undo = try await Self.writeSpoolSwitch(
                    into: &root, orderId: id, partIndex: partIndex, partCount: partCount,
                    spoolId: spoolId, grams: grams, today: Self.localDay(),
                    engine: engine, gone: gone)
            }
            registerMoveUndo(undo, named: words.callIt("ord.spool_switch"))
            await load(source)
            return true
        } catch let refusal as MoveRefused {
            moveProblem = refusal.sentence
        } catch {
            moveProblem = self.said(error)
        }
        return false
    }

    /// The spool switch's write, on a book in memory — the job and the spool
    /// changed and stamped together. Returns the undo. Static so a test drives
    /// it against a book on disk through the same `StoreWriter` swap.
    static func writeSpoolSwitch(into root: inout [String: JSONValue], orderId: String,
                                 partIndex: Int, partCount: Int, spoolId: String, grams: Double,
                                 today: String, engine: KhaytEngine,
                                 gone: String) async throws -> [ChangedRecord] {
        let orders = rows(root, "printLog")
        let shelf = rows(root, "inventory")
        guard let jobRow = orders.first(where: { recordId($0) == orderId }),
              case .object(var job) = jobRow,
              let spoolRow = shelf.first(where: { recordId($0) == spoolId }),
              case .object(var spool) = spoolRow else {
            throw MoveRefused(sentence: gone)
        }
        // The lot as it is NOW, inside the write — a lot edited since the
        // sheet opened is the lot this filament came from.
        let stamp = try await engine.lotStamp(spoolRow)
        guard applySpoolSwitch(order: &job, spool: &spool, partIndex: partIndex,
                               partCount: partCount, grams: grams,
                               today: today, lotStamp: stamp) else {
            throw MoveRefused(sentence: gone)
        }
        var undo: [ChangedRecord] = []
        write(&root, "printLog", changed: [.object(job)], before: orders, into: &undo)
        write(&root, "inventory", changed: [.object(spool)], before: shelf, into: &undo)
        return undo
    }

    /// The most lines a spool's usage history keeps — `USAGE_CAP` in
    /// `lib/order-deduction.js`, the cap every draw is written under.
    nonisolated static let usageHistoryCap = 200

    /// The spool switch on a job and a spool in memory, exactly as
    /// `openSpoolSwitchModal` writes it:
    ///
    /// - `parts[partIndex].additionalSpools` gains `{spoolId, weight}`;
    /// - the spool's `weight` drops by `grams`, floored at 0;
    /// - its `usageHistory` gains, at the TOP, `{orderId, project, weightUsed,
    ///   date}` plus the lot stamp, and is cut to 200 lines.
    ///
    /// False — and nothing changed — when the part is not there, the job's
    /// parts are not the list the sheet showed, or the grams are not positive.
    nonisolated static func applySpoolSwitch(order: inout [String: JSONValue],
                                             spool: inout [String: JSONValue],
                                             partIndex: Int, partCount: Int, grams: Double,
                                             today: String,
                                             lotStamp: [String: JSONValue]) -> Bool {
        guard grams > 0, grams.isFinite,
              case .array(var parts)? = order["parts"], parts.count == partCount,
              parts.indices.contains(partIndex),
              case .object(var part) = parts[partIndex],
              let spoolId = plainString(spool["id"]) else { return false }

        var extra: [JSONValue] = []
        if case .array(let had)? = part["additionalSpools"] { extra = had }
        extra.append(.object(["spoolId": .string(spoolId), "weight": .number(grams)]))
        part["additionalSpools"] = .array(extra)
        parts[partIndex] = .object(part)
        order["parts"] = .array(parts)

        let left = plainNumber(spool["weight"]) ?? 0
        spool["weight"] = .number(max(0, left - grams))
        var line: [String: JSONValue] = [
            "orderId": order["id"] ?? .null,
            "project": .string(plainString(order["project"]) ?? ""),
            "weightUsed": .number(grams),
            "date": .string(today),
        ]
        for (k, v) in lotStamp { line[k] = v }
        var history: [JSONValue] = []
        if case .array(let had)? = spool["usageHistory"] { history = had }
        history.insert(.object(line), at: 0)
        if history.count > usageHistoryCap { history = Array(history.prefix(usageHistoryCap)) }
        spool["usageHistory"] = .array(history)
        return true
    }
}
