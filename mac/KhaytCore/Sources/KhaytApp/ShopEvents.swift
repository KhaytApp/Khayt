import Foundation
import KhaytCore

/// Telling the shop's people that something happened, through Khayt Cloud.
///
/// `POST /v1/shops/{id}/events` (khayt-cloud docs/api-contract.md, "Shop
/// events"): the cloud relays it to open `/live` streams and as a push to the
/// shop's iPhones, where the companion decrypts it and offers the next step.
/// The kind is in the clear so the cloud can route and rate it; everything
/// else is sealed with the shop's key and the cloud never reads it.
///
/// Best effort, always. A print that finished is not made to wait on a
/// notification, and a notification that could not be sent is not an error
/// anybody at the machine can do anything about — it is logged and dropped.
@MainActor
enum ShopEventPublisher {

    enum Outcome: Equatable {
        case sent
        /// 429: the shop's 60-an-hour allowance is spent. Dropped, not queued.
        case rateLimited
        /// 403: a viewer's sign-in.
        case readOnly
        /// 404: this Khayt Cloud does not take events.
        case notOffered
        /// 413: the sealed payload was over 3 KB.
        case tooLarge
        case failed(Int)
    }

    /// The contract's ceiling on the serialized ciphertext.
    static let maxCiphertextBytes = 3 * 1024

    private struct Body: Encodable {
        let kind: String
        let at: String
        let ciphertext: SyncCrypto.Blob
    }

    /// What the iPhone decrypts for `print-finished` — payload v1, as agreed
    /// with the companion. `advancedTo` is always null: this Mac does not move
    /// a job on the finish edge, and the phone must not assume it did.
    static func printFinishedPayload(_ ended: FinishCamera.Ended, at: String,
                                     project: String?, client: String?) -> [String: JSONValue] {
        func text(_ s: String?) -> JSONValue {
            guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return .null }
            return .string(s)
        }
        return [
            "v": .number(1),
            "kind": .string("print-finished"),
            "at": .string(at),
            "machineId": .string(ended.machineId),
            "machineName": .string(ended.machineName),
            "orderId": text(ended.orderId),
            "project": text(project),
            "client": text(client),
            "filename": text(ended.filename),
            "durationS": ended.durationS.map { .number($0.rounded()) } ?? .null,
            "outcome": .string(ended.outcome),
            "photo": .bool(ended.photoTaken),
            "advancedTo": .null,
        ]
    }

    /// Seal and send one event.
    static func send(_ connection: CloudReader.Connection, token: String, dek: Data,
                     kind: String, at: String, payload: [String: JSONValue],
                     fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Outcome {
        let sealed = try SyncCrypto.seal(payload, dek: dek)
        guard try JSONEncoder().encode(sealed).count <= maxCiphertextBytes else { return .tooLarge }
        var request = try CloudReader.request(connection, token: token, method: "POST", tail: "/events")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(kind: kind, at: at, ciphertext: sealed))
        let (_, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return .sent
        case 403: return .readOnly
        case 404: return .notOffered
        case 413: return .tooLarge
        case 429: return .rateLimited
        case let code: return .failed(code)
        }
    }

    /// `at` as the contract stores it: UTC, second precision.
    static func stamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: false).format(date)
    }
}
