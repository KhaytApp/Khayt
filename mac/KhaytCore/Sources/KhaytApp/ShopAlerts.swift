import Foundation
import KhaytCore

/// The shop's phones told what needs doing: late work and today's work each
/// morning, and stock the moment it runs low.
///
/// Shop events of kind `overdue`, `due-today` and `low-stock`, posted like
/// `print-finished` (`ShopEventPublisher`) and relayed by Khayt Cloud to the
/// phones as pushes; the iPhone app carries the words and the tap routing.
/// One event per digest, never one per job: the shop has sixty events an
/// hour, shared with every print that finishes.
///
/// - `overdue` / `due-today`: once a day, at the first check after 08:00 on
///   this Mac's clock, and only when there is something to say. Sealed
///   `{count, ids}`.
/// - `low-stock`: when a spool or consumable FIRST drops under its threshold
///   (`lowSpools`, the shelf's own rule, and `Consumable.isLow`). An item that
///   recovers and drops again is told again. Sealed `{count, names}`.
///
/// What was sent is remembered on THIS Mac (`UserDefaults`, per shop), not in
/// the book: the book syncs, and a second Mac must not decide from it that the
/// first already told the phones. A shop with two Macs open can therefore get
/// the morning digest twice; one with none open gets none.
@MainActor
final class ShopAlerts {
    nonisolated static let digestHour = 8
    /// At most this many names in a low-stock event (the payload is 3 KB).
    nonisolated static let namedAtMost = 10
    /// At most this many job ids in a digest; the count stays whole.
    nonisolated static let idsAtMost = 40

    var defaults: UserDefaults = .standard
    var send: ((_ kind: String, _ payload: [String: JSONValue]) async -> Bool)?

    private func key(_ shopId: String, _ what: String) -> String { "khayt.alerts.\(shopId).\(what)" }

    /// What the morning digests would say about `orders` on `day`. Pure.
    nonisolated static func digest(_ orders: [Order], today: Date, now: Date)
        -> (overdue: [String], dueToday: [String]) {
        var late: [String] = [], due: [String] = []
        let open: Set<Stage> = [.pending, .on_hold, .printing, .post, .qc]
        for o in orders {
            guard let stage = Stage.of(o), open.contains(stage) else { continue }
            let dueDay = Order.day(o.dueDate)
            // The attention engine's answer where it has one (the dashboard's
            // Late tile); otherwise open work due before today. Not
            // `isOverdue`'s fallback, which asks about payment.
            if o.isLateResolved ?? (dueDay.map { $0 < today } ?? false) { late.append(o.id) }
            else if let dueDay, dueDay == today { due.append(o.id) }
        }
        return (late, due)
    }

    /// Which items are newly low: low now and not told before. Pure.
    nonisolated static func newlyLow(_ lowNow: [String: String], told: Set<String>) -> [(id: String, name: String)] {
        lowNow.filter { !told.contains($0.key) }.sorted { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    /// Run on every load and printer sweep; cheap when there is nothing due.
    func check(shop: Shop, now: Date = Date()) async {
        guard let shopId = shop.cloudShopIdForAlerts, shop.cloudRoleCanWrite, shop.cloudDek != nil,
              let send else { return }
        // ── STOCK ────────────────────────────────────────────────────────
        var lowNow: [String: String] = [:]
        for s in shop.spools where shop.lowSpools.contains(s.id) {
            let variant = s.colourVariant ?? ""
            lowNow["spool:" + s.id] = variant.isEmpty ? s.material : s.material + " · " + variant
        }
        for c in shop.consumables where c.isLow { lowNow["item:" + c.id] = c.name ?? c.id }
        let toldKey = key(shopId, "lowTold")
        var told = Set(defaults.stringArray(forKey: toldKey) ?? [])
        let fresh = Self.newlyLow(lowNow, told: told)
        if !fresh.isEmpty {
            let names = fresh.prefix(Self.namedAtMost).map { JSONValue.string($0.name) }
            // Told after one attempt, sent or not — like the morning digest. A
            // cloud refusing it would otherwise be asked again on every sweep.
            _ = await send("low-stock", ["count": .number(Double(fresh.count)), "names": .array(Array(names))])
            told.formUnion(fresh.map(\.id))
        }
        // Recovered items are forgotten, so the next drop is told again.
        told.formIntersection(lowNow.keys)
        defaults.set(Array(told).sorted(), forKey: toldKey)

        // ── THE MORNING ──────────────────────────────────────────────────
        let calendar = Calendar.book
        guard calendar.component(.hour, from: now) >= Self.digestHour else { return }
        let day = calendar.dayString(now)
        let dayKey = key(shopId, "digestDay")
        guard defaults.string(forKey: dayKey) != day else { return }
        // Marked before sending: a send that fails is not retried all day,
        // the way the Telegram low-stock warning is not.
        defaults.set(day, forKey: dayKey)
        let (late, due) = Self.digest(shop.orders, today: calendar.startOfDay(for: now), now: now)
        if !late.isEmpty {
            _ = await send("overdue", ["count": .number(Double(late.count)),
                                       "ids": .array(late.prefix(Self.idsAtMost).map(JSONValue.string))])
        }
        if !due.isEmpty {
            _ = await send("due-today", ["count": .number(Double(due.count)),
                                         "ids": .array(due.prefix(Self.idsAtMost).map(JSONValue.string))])
        }
    }
}

extension Shop {
    /// The phones' alerts, if any are due — on every load and printer sweep.
    func checkShopAlerts() async {
        guard case .store = source else { return }
        if shopAlerts.send == nil {
            shopAlerts.send = { [weak self] kind, payload in await self?.postShopAlert(kind, payload) ?? false }
        }
        await shopAlerts.check(shop: self)
    }

    /// The cloud shop id, for keying what this Mac has told the phones.
    var cloudShopIdForAlerts: String? {
        guard case .object(let cloud)? = settingsDict["cloud"],
              case .string(let id)? = cloud["shopId"], !id.isEmpty else { return nil }
        return id
    }

    /// Seal and post one shop alert. True when the cloud took it.
    func postShopAlert(_ kind: String, _ payload: [String: JSONValue]) async -> Bool {
        guard case .store(let build) = source, let dek = cloudDek,
              let connection = try? CloudReader.connection(settingsDict),
              let token = try? await Secrets.open(connection.storedToken, for: build), !token.isEmpty else { return false }
        let outcome = try? await ShopEventPublisher.send(
            connection, token: token, dek: dek, kind: kind, at: ShopEventPublisher.stamp(Date()),
            payload: payload, fetch: { try await URLSession.shared.data(for: $0) })
        if outcome != .sent {
            FileHandle.standardError.write(Data("khayt: \(kind) event — \(String(describing: outcome))\n".utf8))
        }
        return outcome == .sent
    }
}
