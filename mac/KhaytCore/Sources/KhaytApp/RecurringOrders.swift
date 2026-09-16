import Foundation
import KhaytCore

/// A customer's standing order, produced on this Mac.
///
/// The RULE — which schedules are due, what the job looks like — is
/// `lib/recurring-orders.js`, and both apps run it. This is the wiring for one
/// of them: read the three collections out of the book INSIDE the write, ask
/// the rule, put back what changed, stamped so it syncs, with a line in the
/// activity log for every job made. `Shop.createRecurringIfDue` calls it once
/// per book per launch, off the sample book, only while this app owns the
/// book.
///
/// Inside the write rather than on the in-memory copy, because a change
/// computed from a stale copy puts the stale copy back — see `StoreWriter`.
@MainActor
enum RecurringOrders {

    struct Outcome: Sendable {
        /// The ids of the jobs made, newest first.
        let created: [String]
        /// Whether ANYTHING moved — a schedule past its end date is switched
        /// off without making a job, and that is still worth writing down.
        let changed: Bool
    }

    /// Thrown to abandon a write that would change nothing.
    struct NothingDue: Error {}

    static func run(_ root: inout [String: JSONValue], engine: KhaytEngine,
                    now: Date = Date()) async throws -> Outcome {
        let clients = Shop.rows(root, "clients")
        let orders = Shop.rows(root, "printLog")
        let settings = Shop.settings(root)
        let out = try await engine.recurringOrders(clients: clients, orders: orders,
                                                   settings: settings, now: now)

        // Stamp what changed and only that: the jobs the rule made, and the
        // schedules it moved. A record stamped without a change is a sync
        // conflict for nothing; one changed without a stamp never syncs.
        let made = Set(out.created)
        let orderRows: [JSONValue] = out.orders.map { row in
            guard case .object(var o) = row, let id = Shop.recordId(row), made.contains(id) else { return row }
            StoreWriter.stamp(&o)
            return .object(o)
        }
        var clientChanged = false
        let clientRows: [JSONValue] = out.clients.enumerated().map { i, row in
            guard i < clients.count, row != clients[i], case .object(var o) = row else { return row }
            clientChanged = true
            StoreWriter.stamp(&o)
            return .object(o)
        }
        guard !made.isEmpty || clientChanged else { return Outcome(created: [], changed: false) }

        root["printLog"] = .array(orderRows)
        root["clients"] = .array(clientRows)
        root["settings"] = .object(out.settings)
        for id in out.created {
            let project = orderRows.first { Shop.recordId($0) == id }.flatMap {
                if case .object(let o) = $0 { return Shop.plainString(o["project"]) } else { return nil }
            } ?? ""
            let snapshot = root
            Shop.appendActivity(&root, text: id + (project.isEmpty ? "" : " · \(project)"),
                                ref: id, settings: out.settings, root: snapshot,
                                action: "order_created")
        }
        return Outcome(created: out.created, changed: true)
    }
}
