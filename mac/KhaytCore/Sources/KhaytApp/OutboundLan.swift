import Foundation
import Network
import KhaytCore

/// The second half of "is this on the shop's network", for a sender that
/// reaches a host by NAME.
///
/// The rule (`lib/outbound.js`) reads the name alone: `ntfy`, `spoolman.local`
/// and `relay.lan` all read as the shop's own. Its header says the sender must
/// then look the name up and check every answer, because a search domain, a
/// router's DNS or a unicast answer for a `.local` name can send that name
/// anywhere. Printers and cameras already do that and connect to the checked
/// address (`PrinterWatch.pinned`). This is the same check for the senders
/// that had none.
///
/// It only checks; it does not pin. The request that follows looks the name up
/// again, so a name that changes its answer between the two can still get
/// through. That is a narrower hole than trusting the name, and is said on the
/// draft.
enum OutboundLan {

    /// Nothing to do while the switch allows any address. While it does not,
    /// every address the name resolves to must be one the rule allows.
    static func requireResolved(_ host: String?, gate: OutboundGate = .shared,
                                lookUp: @Sendable (String) async -> [String] = { await WebhookClient.addresses(of: $0) })
    async throws {
        guard let host, !host.isEmpty else { return }
        // A public address is allowed: the switch is off, so is this check.
        guard !gate.verdict(.lan, host: "8.8.8.8").allowed else { return }
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return }
        // A name that resolves to nothing fails by itself, with its own error.
        for address in await lookUp(host) {
            try gate.require(.lan, host: address)
        }
    }
}
