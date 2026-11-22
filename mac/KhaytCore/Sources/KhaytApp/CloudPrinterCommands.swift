import Foundation
import KhaytCore

/// A phone away from the shop's Wi-Fi pausing, resuming or stopping a print,
/// through Khayt Cloud.
///
/// The LAN route (`POST /api/printer/…`, `Shop.phonePrinterCommand`) needs the
/// phone on the same network. Away from it, the phone posts a shop event of
/// kind `cmd-printer` (khayt-cloud docs/api-contract.md, "Shop events" → the
/// `cmd-*` relay, #154): sealed with the shop's key, so the cloud sees only the
/// kind, and silent, so no phone is woken by it. This Mac reads them with
/// `GET /events`, runs each through the very same `phonePrinterCommand`, and
/// answers with a sealed `cmd-result` carrying the LAN reply's body and the
/// command's `id`.
///
/// ── A STOP RUNS ONCE, AND ONLY WHILE IT IS FRESH ─────────────────────────
///
/// The cloud keeps a shop's last 50 events for a day, and `GET /events` hands
/// back whatever is newer than `since`, so a restarted Mac would otherwise
/// see every command again. A command is run only when both the event's `at`
/// and the phone's own `at` are within `maxAge` of now (and not from the
/// future beyond a small skew), and only once per command `id`: a replayed,
/// backfilled or doubly-delivered event never stops a second print. The first
/// poll after launch starts `maxAge` ago, so nothing older is even fetched.
///
/// Who may command: whoever can post a shop event (the cloud asks for a write
/// role) AND holds the shop's key (or the ciphertext does not open). This Mac
/// also needs a write role itself, to answer.
@MainActor
final class CloudPrinterCommands {
    /// How often `GET /events` is asked, at most. The printer sweep that calls
    /// this runs about every ten seconds.
    nonisolated static let interval: TimeInterval = 15
    /// A command older than this is not run (the iPhone lane's two minutes).
    nonisolated static let maxAge: TimeInterval = 120
    /// How far ahead of this Mac's clock a command may be stamped and still be
    /// believed.
    nonisolated static let skew: TimeInterval = 30

    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    private(set) var since: Date?
    private var lastPoll: Date?
    private var inFlight = false
    /// Command ids already run (or refused as stale), with when. Kept in the
    /// defaults as well, so a Mac restarted inside `maxAge` of a stop does not
    /// see that stop as new and run it on the next print.
    private(set) var handled: [String: Date] = [:]
    nonisolated static let handledKey = "cloud.printerCommandsHandled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: Self.handledKey) as? [String: Double] {
            handled = stored.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    private func remember() {
        defaults.set(handled.mapValues(\.timeIntervalSince1970), forKey: Self.handledKey)
    }

    struct Event: Decodable {
        let id: String?
        let kind: String
        let at: String
        let ciphertext: SyncCrypto.Blob?
    }
    private struct Events: Decodable { let events: [Event] }

    struct Command: Equatable {
        let id: String
        let machineId: String
        let verb: PrinterVerb
    }

    /// The commands in `events` that should run now: `cmd-printer`, opened
    /// with the shop key, fresh, of a known verb, and not already handled.
    /// Pure, for the tests.
    nonisolated static func commands(_ events: [Event], dek: Data, now: Date,
                                     handled: Set<String>) -> [Command] {
        var out: [Command] = []
        var seen = handled
        for event in events where event.kind == "cmd-printer" {
            guard let blob = event.ciphertext,
                  let plain = try? SyncCrypto.openStore(blob, dek: dek),
                  case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: plain),
                  case .string(let id)? = o["id"], !id.isEmpty, !seen.contains(id),
                  case .string(let machineId)? = o["machineId"], !machineId.isEmpty,
                  case .string(let word)? = o["verb"] else { continue }
            let verb: PrinterVerb
            switch word {
            case "pause": verb = .pause
            case "resume": verb = .resume
            case "stop": verb = .cancel
            default: continue
            }
            guard fresh(event.at, now: now) else { continue }
            if case .string(let said)? = o["at"], !fresh(said, now: now) { continue }
            seen.insert(id)
            out.append(Command(id: id, machineId: machineId, verb: verb))
        }
        return out
    }

    nonisolated static func fresh(_ stamp: String, now: Date) -> Bool {
        guard let at = Calendar.instant(stamp) else { return false }
        let age = now.timeIntervalSince(at)
        return age <= maxAge && age >= -skew
    }

    /// Ask the cloud for new events, run the fresh printer commands, answer
    /// each. Best effort: a failure here is the phone not hearing back, which
    /// it shows as no answer.
    func pollIfDue(shop: Shop, now: Date = Date()) async {
        guard !inFlight, shop.cloudRoleCanWrite, let dek = shop.cloudDek,
              case .store(let build) = shop.source,
              let connection = try? CloudReader.connection(shop.settingsDict) else { return }
        if let lastPoll, now.timeIntervalSince(lastPoll) < Self.interval { return }
        inFlight = true
        defer { inFlight = false }
        lastPoll = now
        guard let token = try? await Secrets.open(connection.storedToken, for: build), !token.isEmpty else { return }
        let from = since ?? now.addingTimeInterval(-Self.maxAge)
        let tail = "/events?since=" + ShopEventPublisher.stamp(from)
        guard var request = try? CloudReader.request(connection, token: token, method: "GET", tail: tail) else { return }
        request.timeoutInterval = 15
        guard let (data, response) = try? await fetch(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(Events.self, from: data) else { return }
        // `since` is "after", at second precision: step back one second so a
        // second event in the same second as the last is not skipped. The
        // handled ids keep it from running twice.
        // Capped at now + skew: one event stamped in the future (a wrong
        // clock anywhere in the shop) must not move `since` past every later
        // command and silence the relay until the app restarts.
        if let newest = list.events.compactMap({ Calendar.instant($0.at) }).max() {
            since = max(from, min(newest, now.addingTimeInterval(Self.skew)).addingTimeInterval(-1))
        } else {
            since = from
        }
        handled = handled.filter { now.timeIntervalSince($0.value) < Self.maxAge * 5 }
        let toRun = Self.commands(list.events, dek: dek, now: now, handled: Set(handled.keys))
        for command in toRun { handled[command.id] = now }
        remember()
        for command in toRun {
            let (_, body) = await shop.phonePrinterCommand(command.machineId, command.verb)
            var answer: [String: JSONValue] = [:]
            if case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)) { answer = o }
            // Not this Mac's printer to answer for: with two Macs in a shop the
            // phone keeps the first answer, and "not connected" from the Mac
            // that cannot see the printer must not beat "stopped" from the one
            // that can. Stay quiet and let the other answer.
            if case .string(let reason)? = answer["reason"],
               ["not-found", "not-connected", "not-watched"].contains(reason) { continue }
            answer["id"] = .string(command.id)
            _ = try? await ShopEventPublisher.send(connection, token: token, dek: dek, kind: "cmd-result",
                                                   at: ShopEventPublisher.stamp(Date()), payload: answer,
                                                   fetch: fetch)
        }
    }
}
