import Foundation
import KhaytCore

/// Pause, resume or stop a print from the phone — the Mac's printer card
/// (`PrinterControl.send`), reached two ways:
///
/// - on the shop's Wi-Fi, the Mac's LAN route
///   `POST /api/printer/{machineId}/{pause|resume|stop}` (docs/LAN_API.md),
///   which takes SIGNED enrolled-device requests only;
/// - away from it, Khayt Cloud's silent relay: a sealed `cmd-printer` event
///   the Mac picks up off its stream, answered by a sealed `cmd-result`
///   with the same id (khayt-cloud's contract, "Shop events" → "cmd- kinds").
///
/// The phone never talks to a printer itself: the Mac holds the printers'
/// keys, and it is the Mac that refuses what cannot be done.
enum PrinterVerb: String, CaseIterable, Sendable {
    case pause, resume, stop
}

/// The Mac's answer, the same body over either road.
struct PrinterReply: Decodable, Equatable, Sendable {
    var ok: Bool
    var state: String?
    var reason: String?
    var message: String?

    /// What to tell the person when it did not happen.
    var sentence: String {
        if ok { return "" }
        if reason == "refused", let message, !message.isEmpty { return L10n.format("printer.refused", message) }
        switch reason {
        case "device-key-required": return L10n.tr("printer.why.device")
        case "not-found": return L10n.tr("printer.why.not_found")
        case "not-connected", "not-watched": return L10n.tr("printer.why.not_connected")
        case "unsupported": return L10n.tr("printer.why.unsupported")
        case "no-job": return L10n.tr("printer.why.no_job")
        case "busy": return L10n.tr("printer.why.busy")
        case "not-offered": return L10n.tr("printer.why.old_mac")
        case "no-answer": return L10n.tr("printer.why.no_answer")
        default: return L10n.tr("printer.why.unreachable")
        }
    }

    static func failed(_ reason: String) -> PrinterReply { PrinterReply(ok: false, reason: reason) }
}

/// Replies coming back over the cloud, matched to the command that asked.
@MainActor
final class PrinterReplies {
    static let shared = PrinterReplies()
    private var waiting: [String: CheckedContinuation<PrinterReply, Never>] = [:]

    /// A `cmd-result` off the stream, opened.
    func receive(_ ciphertext: Data?, dek: Data) {
        guard let ciphertext,
              let blob = try? JSONDecoder().decode(SyncCrypto.Blob.self, from: ciphertext),
              let plain = try? SyncCrypto.openStore(blob, dek: dek) else { return }
        struct Tagged: Decodable { let id: String }
        guard let id = (try? JSONDecoder().decode(Tagged.self, from: plain))?.id,
              let reply = try? JSONDecoder().decode(PrinterReply.self, from: plain),
              let waiter = waiting.removeValue(forKey: id) else { return }
        waiter.resume(returning: reply)
    }

    /// Wait for the answer to `id`, or "no answer" after `seconds`.
    func wait(for id: String, seconds: Double) async -> PrinterReply {
        await withCheckedContinuation { c in
            waiting[id] = c
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                self.settle(id, .failed("no-answer"))
            }
        }
    }

    /// End a wait early — the command never left the phone.
    func settle(_ id: String, _ reply: PrinterReply) {
        waiting.removeValue(forKey: id)?.resume(returning: reply)
    }
}

extension KhaytAPIClient {

    /// Ask the Mac to pause, resume or stop the print on `machineId`.
    func printer(_ verb: PrinterVerb, machineId: String, macInReach: Bool, now: Date = Date()) async -> PrinterReply {
        if macInReach, let lan = await printerOverLAN(verb, machineId: machineId) { return lan }
        if let session = cloud { return await printerOverCloud(verb, machineId: machineId, session: session, now: now) }
        return .failed("unreachable")
    }

    /// Nil when the Mac could not be reached at all, so the cloud is tried.
    private func printerOverLAN(_ verb: PrinterVerb, machineId: String) async -> PrinterReply? {
        let id = machineId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? machineId
        guard let (data, response) = try? await lanRequest(path: "/api/printer/\(id)/\(verb.rawValue)", method: "POST") else {
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let reply = try? JSONDecoder().decode(PrinterReply.self, from: data) { return reply }
        // A Mac from before the route answers 404 with no body of ours.
        return .failed(status == 404 ? "not-offered" : "unreachable")
    }

    private func printerOverCloud(_ verb: PrinterVerb, machineId: String, session: CloudSession,
                                  now: Date) async -> PrinterReply {
        let id = BookWriter.lanId("cmd", now: now)
        let payload: [String: JSONValue] = ["id": .string(id), "machineId": .string(machineId),
                                            "verb": .string(verb.rawValue), "at": .string(StoreWriter.iso(now))]
        struct Body: Encodable { let kind: String; let at: String; let ciphertext: SyncCrypto.Blob }
        guard let sealed = try? SyncCrypto.seal(payload, dek: session.dek),
              var request = try? CloudReader.request(
                CloudReader.Connection(url: session.url, shopId: session.shopId, storedToken: ""),
                token: session.token, method: "POST", tail: "/events"),
              let body = try? JSONEncoder().encode(Body(kind: "cmd-printer", at: StoreWriter.iso(now), ciphertext: sealed))
        else { return .failed("unreachable") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Listening before sending, so a quick answer is not missed.
        let answer = Task { await PrinterReplies.shared.wait(for: id, seconds: 45) }
        await Task.yield()
        let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            PrinterReplies.shared.settle(id, .failed(status == 403 ? "read-only" : "unreachable"))
        }
        return await answer.value
    }
}
