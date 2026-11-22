import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Moving a job back from Shipped to Completed.
///
/// Shipped is a stamp on a job that stays `completed`, so the move asked for
/// completed → completed — and got a second completion: the sheet overwrote
/// the job's actuals, Telegram, `status_changed`, the order webhook and
/// `order_delivered` all fired again, and `shippedAt` stayed, so the card did
/// not even move. It is now the stamp coming off and nothing else.
@MainActor
struct UnshipTests {

    static func book() -> [String: JSONValue] {
        [
            "printLog": .array([.object([
                "id": .string("J1"), "project": .string("Lamp"), "status": .string("completed"),
                "completedAt": .string("2026-09-01T10:00:00.000Z"),
                "shippedAt": .string("2026-09-02T10:00:00.000Z"),
                "materialDeducted": .bool(true), "actualWeight": .number(120),
                "price": .number(100), "parts": .array([]),
            ])]),
            "inventory": .array([]), "consumables": .array([]), "machines": .array([]),
            "clients": .array([]),
            "settings": .object([
                "autoDeduct": .bool(true),
                "webhooks": .object(["enabled": .bool(true), "secret": .string("s"),
                                     "events": .object([
                                        "status_changed": .string("https://example.test/hook"),
                                        "order_delivered": .string("https://example.test/hook"),
                                     ])]),
                "telegram": .object(["botToken": .string("123:abc"), "chatId": .string("42"),
                                     "notifyOnComplete": .bool(true)]),
            ]),
        ]
    }

    @Test("moving a shipped job back to Completed un-ships it and tells nobody")
    func unship() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        var root = Self.book()
        let out = try await Shop.applyMove(
            to: &root, id: "J1", stage: .completed, engine: engine, words: words,
            actuals: Shop.Actuals(hours: 9, grams: 999, timeSource: "manual", weightSource: "manual"))
        guard case .array(let rows)? = root["printLog"], case .object(let job)? = rows.first else {
            Issue.record("the job is gone"); return
        }
        #expect(job["shippedAt"] == nil, "the stamp stayed, so the card did not move")
        #expect(job["actualWeight"] == .number(120), "the completion sheet overwrote what it really took")
        #expect(job["status"] == .string("completed"))
        #expect(out.webhooks.isEmpty, "the completion webhooks fired a second time")
        #expect(out.telegram == nil, "the customer was told their finished job was finished again")
        #expect(out.email == nil)
    }
}
