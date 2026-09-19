import Foundation
import KhaytCore

/// A customer, assembled from the jobs done for them.
///
/// Khayt has a `clients` collection, and on this shop's book it is empty: every
/// order carries a `client` name and a `clientId` that is null throughout. So
/// the people here are derived from the work, which is also the honest reading —
/// a customer a shop has never billed is not yet a customer.
///
/// Grouped by name, case- and whitespace-insensitively. "Nouf Al-Dossari" and
/// "nouf al-dossari " are one person who has been typed in twice, and showing
/// them as two hides exactly the total someone opened this screen to find.
struct Customer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let orders: [Order]

    var jobCount: Int { orders.count }
    var billed: Double { orders.reduce(0) { $0 + $1.price } }
    var paid: Double { orders.reduce(0) { $0 + $1.paidAmount } }
    var owed: Double { orders.filter { !$0.isSettled }.reduce(0) { $0 + $1.owed } }
    var overdueCount: Int { orders.count { $0.isOverdue() } }
    var isSettled: Bool { owed < 0.005 }

    /// Whether anything this customer's work was ever priced at.
    ///
    /// `isSettled` is `owed < 0.005`, which is equally true of a customer whose
    /// jobs were never priced — and a shop that uses Khayt as a print log has
    /// a whole book like that. Saying "settled" about them is the app claiming
    /// money changed hands. See `OrdersTable.Owed`, which had the same fault
    /// one row at a time.
    var hasAPrice: Bool { billed > 0.005 }

    /// The most recent job, by date. What "last seen" means for a shop.
    var lastJob: Date? { orders.compactMap(\.day).max() }

    /// Live work — anything not delivered or cancelled. The number that decides
    /// whether this person is expecting a call from you.
    var openCount: Int {
        orders.count {
            guard let stage = Stage.of($0) else { return true }
            return stage != .delivered && stage != .cancelled
        }
    }

    /// The customer's row in the `clients` collection, when they have one.
    ///
    /// Nil for someone who exists only as a name denormalised onto old orders.
    /// EVERYTHING THAT FOLLOWS A CUSTOMER THROUGH THE APP reads `clientId`, so
    /// a job created against a customer with no record must carry no id at all
    /// rather than one invented from their name.
    let clientId: String?

    /// The shop's own record of them: phone, email, VAT. Nil where there is none.
    let record: Client?

    /// Everyone the shop knows: the ones written down, and the ones who exist
    /// only as a name on a job.
    ///
    /// The written-down ones come first and keep their id, because that id is
    /// what a new job will point at. A name-only customer is still shown —
    /// dropping them would hide most of the history of a shop that has never
    /// used the customer screen — but has no id to give.
    /// - Parameter names: what the shop calls each customer, keyed by id —
    ///   `KhaytContentLanguages`' answer, resolved once by `Shop` when the book
    ///   loads. Empty when the engine could not be asked, and only then is
    ///   `anyName` used: it is English-first, which is the shape the repo's own
    ///   content-language guard forbids, and an Arabic shop saw its customers
    ///   listed in English here while the Best page listed them in Arabic.
    static func from(_ orders: [Order], clients: [Client] = [],
                     names: [String: KhaytEngine.Named] = [:]) -> [Customer] {
        var out: [Customer] = []
        var claimed = Set<String>()          // order ids already attributed

        for client in clients {
            let resolved = names[client.id]?.name ?? ""
            let name = resolved.isEmpty ? client.anyName : resolved
            let byId = orders.filter { $0.clientId == client.id }
            // A shop that has never linked a job to a client record still has
            // the name on the order, so match on that too rather than showing
            // an established customer with no history.
            // Already-claimed jobs are skipped, so two records sharing a name
            // do not each count the same job — which would report a shop twice
            // the customers and twice the revenue it has. The first record in
            // the collection wins, which is stable because the collection is.
            let byName = orders.filter {
                $0.clientId == nil && !name.isEmpty && !claimed.contains($0.id)
                    && $0.client.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        == name.lowercased()
            }
            let mine = byId + byName
            claimed.formUnion(mine.map(\.id))
            out.append(Customer(id: client.id, name: name, orders: mine,
                                clientId: client.id, record: client))
        }

        var buckets: [String: (name: String, orders: [Order])] = [:]
        for order in orders where !claimed.contains(order.id) {
            let name = order.client.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            // The first spelling seen wins the display name, so the screen does
            // not change what it calls someone as jobs are added.
            buckets[key, default: (name, [])].orders.append(order)
        }
        out += buckets.map {
            Customer(id: $0.key, name: $0.value.name, orders: $0.value.orders,
                     clientId: nil, record: nil)
        }
        return out
    }
}
