import Foundation
import KhaytCore

/// Asking an Elegoo resin printer what it is doing.
///
/// SDCP is a WebSocket on 3030 and a JSON frame — so unlike Bambu there is no
/// protocol to write here, only a socket to open. `lib/sdcp.js` is pure by
/// design and both apps load it; `lib/sdcp-reply.js` decides which frame is the
/// answer and both apps use that too. What is left for this file is the
/// transport, which is `URLSessionWebSocketTask` and about forty lines.
///
/// ── ONE QUESTION, THEN HANG UP ────────────────────────────────────────────
///
/// Deliberately not a long-lived connection, for the same reason the other app
/// gives: Khayt polls every machine on a timer through one shared loop, and a
/// persistent socket per printer means reconnect logic, backoff and a liveness
/// question for every machine — a lot of state for a reading taken twice a
/// minute. A resin print is measured in hours.
///
/// ── AND NO ELEGOO ON THE BENCH ────────────────────────────────────────────
///
/// There is one printer here and it is not this. So what is unproven is narrow
/// and worth naming: whether a real mainboard accepts this frame and answers on
/// the topic the spec says it will. Everything above that line — the address,
/// the request, which frame counts as the answer, and what each failure is
/// called — is reachable from a test and is tested.
actor SdcpSocket {
    private let url: URL
    private let mainboardId: String
    private let timeout: Duration

    init(url: URL, mainboardId: String, timeout: Duration = .seconds(8)) {
        self.url = url
        self.mainboardId = mainboardId
        self.timeout = timeout
    }

    enum Trouble: Error, Equatable {
        /// The printer answered, and its answer was a refusal. NOT silence.
        case refused(String)
        /// Nothing came back in time.
        case silent
        /// Reachable, and it hung up before answering. Worth telling apart from
        /// a timeout: this one means something is listening.
        case closed
        case socket(String)
    }

    /// Send the question and return the first frame that is an answer to it.
    func status(engine: KhaytEngine) async throws -> KhaytEngine.PrinterStatus {
        let request = try await engine.sdcpStatusRequest(mainboardId: mainboardId)

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        try await task.send(.string(request))

        return try await withThrowingTaskGroup(of: KhaytEngine.PrinterStatus.self) { group in
            group.addTask {
                // A mainboard pushes on its own schedule as well as answering,
                // so most of what arrives is not the answer. Reading until one
                // IS, rather than taking the first frame, is the whole reason
                // this loop exists.
                while true {
                    let message: URLSessionWebSocketTask.Message
                    do { message = try await task.receive() }
                    catch {
                        // A cancelled read is this group being torn down after
                        // the other task won or the timeout fired, and must not
                        // be reported as the printer hanging up.
                        if Task.isCancelled { throw CancellationError() }
                        throw Self.readFailed(error)
                    }
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: continue
                    }
                    switch try await engine.sdcpRead(frame: text, mainboardId: self.mainboardId) {
                    case .status(let status): return status
                    case .refused(let why): throw Trouble.refused(why)
                    case nil: continue
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: self.timeout)
                throw Trouble.silent
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// A closed socket and a broken one are different things to a shop.
    private static func readFailed(_ error: any Error) -> Trouble {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain || ns.code == NSURLErrorNetworkConnectionLost {
            return .closed
        }
        return .socket(ns.localizedDescription)
    }
}
