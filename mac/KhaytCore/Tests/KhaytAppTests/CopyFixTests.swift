import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Words the beta.1 review found the shop reading wrong: store keys on
/// screen, "(s)" plurals, an Arabic comma in English, counts that never
/// asked Arabic how many.
@MainActor
struct CopyFixTests {

    static func arabic() async throws -> Words {
        let words = Words()
        await words.load("ar", engine: try KhaytEngine())
        return words
    }

    static func sampleCollections() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let book = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        return book.compactMap { $0.value is [Any] ? $0.key : nil }.sorted()
    }

    // MARK: - What sync took: a word, not the store's key

    @Test("every collection in a book is named by a word in both languages; an unknown one is a record")
    func lossKinds() async throws {
        let en = Words()
        let ar = try await Self.arabic()
        let collections = try Self.sampleCollections()
        #expect(collections.count > 10)
        for collection in collections {
            let key = SyncLossesSheet.kindKey(collection)
            #expect(key != "mac.losses_kind_record", "\(collection) has no word of its own")
            for words in [en, ar] {
                let said = words.callIt(key)
                #expect(said != key && said != collection, "\(collection) reads \(said)")
            }
        }
        #expect(en.callIt(SyncLossesSheet.kindKey("printLog")) == "Job")
        #expect(ar.callIt(SyncLossesSheet.kindKey("clients")) == "عميل")
        #expect(en.callIt(SyncLossesSheet.kindKey("somethingNew")) == "Record")
        #expect(ar.callIt(SyncLossesSheet.kindKey("somethingNew")) == "سجل")
    }

    // MARK: - Lists

    @Test("the outbound refusal lists channels the shop's language's way")
    func outboundList() async throws {
        let reaches = try JSONDecoder().decode([Outbound].self, from: Data("""
            [{"channel":"telegram","why":"enabled"},{"channel":"email","why":"enabled"},
             {"channel":"portal","why":"published"}]
            """.utf8))
        let en = Words().outboundRefusal(reaches)
        #expect(en.contains("a Telegram message, an email, and the customer's tracking link")
                || en.contains("a Telegram message, an email and the customer's tracking link"), "\(en)")
        #expect(!en.contains("،"), "an Arabic comma in English: \(en)")
        let ar = try await Self.arabic().outboundRefusal(reaches)
        #expect(ar.contains("و"), "\(ar)")
    }

    // MARK: - Plurals that decided

    @Test("what sync took: one clause per non-zero count, each its own plural")
    func lossBanner() async throws {
        func loss(_ kind: SyncLoss.Kind, _ id: String) -> SyncLoss {
            SyncLoss(kind: kind, collection: "printLog", recordId: id, record: .object([:]), replacedBy: nil)
        }
        let one = SyncLossNotice(files: [], losses: [loss(.replaced, "a")])
        let mixed = SyncLossNotice(files: [], losses: [loss(.replaced, "a"), loss(.keptDeleted, "b"),
                                                       loss(.removed, "c")])
        let en = Words()
        #expect(SyncLossBanner.said(one, en) == "Sync replaced 1 record changed on this Mac. A copy of each was kept.")
        #expect(SyncLossBanner.said(mixed, en)
                == "Sync replaced 2 records changed on this Mac and removed 1 record. A copy of each was kept.")
        let ar = try await Self.arabic()
        let said = SyncLossBanner.said(mixed, ar)
        #expect(said.contains("سجلّين") && said.contains("سجلًا واحدًا"), "\(said)")
        #expect(!said.contains("{"), "\(said)")
    }

    @Test("no English word in the Mac's own table says (s)")
    func noMaybePlurals() {
        let offenders = Words.own.compactMap { key, value -> String? in
            (value["en"] ?? "").contains("(s)") ? key : nil
        }
        #expect(offenders.isEmpty, "count it with counting(): \(offenders.sorted())")
    }

    @Test("webhooks told and discarded edits count in both languages")
    func countedSentences() async throws {
        let en = Words()
        #expect(en.counting(1, "mac.webhooks_sent") == "Told 1 other system.")
        #expect(en.counting(3, "mac.webhooks_sent") == "Told 3 other systems.")
        #expect(en.counting(1, "mac.cloud_lost_edits").hasPrefix("1 change made here was discarded"))
        #expect(en.counting(1, "mac.losses_dismiss_body").hasPrefix("1 record sync took has not"))
        let ar = try await Self.arabic()
        #expect(ar.counting(2, "mac.webhooks_sent") == "أُبلغ نظامان آخران.")
        #expect(ar.counting(5, "mac.cloud_lost_edits").hasPrefix("أُلغيت 5 تغييرات"))
    }
}
