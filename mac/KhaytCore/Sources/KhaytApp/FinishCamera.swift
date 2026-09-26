import Foundation
import KhaytCore

/// What happens on the edge out of a print: the printer's own photo, and the
/// one event every other consumer of "a print just ended" hangs off.
///
/// ── WHEN, AND WHICH JOB, ARE NOT DECIDED HERE ─────────────────────────────
///
/// `lib/print-finish-photo.js` owns both: the edge out of a job, once per
/// print, and how it ended — finished, failed or cancelled. Only a FINISHED
/// print earns a photo: a cancelled or failed one is a picture of a failure,
/// and it would travel from the job to the portfolio and from there to a
/// storefront. Which job the print belongs to is its rule too, and it answers
/// "none" rather than guess between two jobs on one machine.
///
/// What is here is the memory the rule is handed back each poll, and the order
/// of the steps: which job, then the camera, then the book, then the event.
/// Every step is best-effort: a snapshot that fails leaves the print, the poll
/// and the book exactly as they were.
@MainActor
final class FinishCamera {

    /// `{ [machineId]: { state, progress, filename, durationS } }` — the
    /// rule's own bookkeeping, never read here.
    private var memo: JSONValue = .object([:])

    /// A book closed and reopened has not just finished a print.
    func reset() { memo = .object([:]) }

    /// Fold one answered poll in. The edge when this poll is one — whatever
    /// the outcome — and nil every other time.
    func observe(_ machineId: String, status: JSONValue, engine: KhaytEngine) async -> KhaytEngine.FinishTrack? {
        guard let t = try? await engine.printFinishTrack(memo: memo, machineId: machineId,
                                                         status: status) else { return nil }
        memo = t.memo
        return t.outcome == nil ? nil : t
    }

    /// What happened to the photo, for the tests and for anybody asking why a
    /// print has none. Never said to the shop: none of these is theirs to fix.
    enum Outcome: Equatable, Sendable {
        case attached(String)
        case notFinished
        case noCamera
        case noJob
        case noFrame
        case notWritten
    }

    /// A print ended — the payload of the finish seam (`Shop.printFinished`).
    ///
    /// Exactly what a consumer needs and nothing it would have to re-derive:
    /// the machine, the job ONLY when the book names it unambiguously, how it
    /// ended, how long it ran, and whether the printer's photo made it onto
    /// the job.
    struct Ended: Equatable, Sendable {
        let machineId: String
        let machineName: String
        /// Nil when the book cannot say which job without guessing.
        let orderId: String?
        /// "finished" | "failed" | "cancelled".
        let outcome: String
        /// Seconds, by the printer's own counter; nil when it never said.
        let durationS: Double?
        let photoTaken: Bool
        /// The file the printer was running.
        let filename: String
    }

    /// The last photo outcome per machine.
    static var lastOutcome: [String: Outcome] = [:]

    /// Everything the finish edge does, in order, returning the event.
    ///
    /// The job is found FIRST: it is a lookup in memory, it is what the event
    /// carries whatever the outcome, and a frame with nowhere to go would be a
    /// request made to the printer for nothing. The frame is `Camera.fetch`'s
    /// — the same host pin, credential rule and redirect refusal as the tiles
    /// on the shop floor, with the same `get` seam.
    static func finish(_ machine: Machine, edge: KhaytEngine.FinishTrack, printLog: [JSONValue],
                       shop: Shop,
                       get: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
                       attach: (_ jobId: String, _ data: Data) async -> Bool) async -> (Ended, Outcome) {
        let jobId: String? = if let engine = shop.engine {
            (try? await engine.printFinishJob(printLog: printLog, machineId: machine.id,
                                              filename: edge.filename)) ?? nil
        } else { nil }

        let photo: Outcome
        if !edge.capture {
            photo = .notFinished
        } else if !machine.hasCamera {
            photo = .noCamera
        } else if let jobId {
            if case .picture(let data) = await Camera.fetch(machine, shop: shop, get: get) {
                photo = await attach(jobId, data) ? .attached(jobId) : .notWritten
            } else {
                photo = .noFrame
            }
        } else {
            photo = .noJob
        }

        let ended = Ended(machineId: machine.id, machineName: machine.name, orderId: jobId,
                          outcome: edge.outcome ?? "cancelled", durationS: edge.durationS,
                          photoTaken: { if case .attached = photo { true } else { false } }(),
                          filename: edge.filename)
        return (ended, photo)
    }
}
