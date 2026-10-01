import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A job the other app reads, this app reads — and opening it changes nothing.
///
/// ── THE FAULT THIS GUARDS ──────────────────────────────────────────────────
///
/// `Order` required `date`, `status`, `project`, `price`, `paidAmount`,
/// `paymentStatus`, `printTime`, `priority` and `notes`, each of its own JSON
/// type. A job missing any one of them, or holding `"price": "120"`, was
/// SKIPPED by `Shop.decodeOrders`: counted in the sidebar's "could not be
/// read" line and absent from every screen, while Khayt and every `lib/` rule
/// read it with `+o.price || 0` and `o.project || ''`.
///
/// They are read with those same defaults now. And because a default shown is
/// not a value stored, an untouched open and save of each job must leave its
/// record byte-identical: the default must never reach the book.
@MainActor
struct LenientOrderReadTests {

    /// A complete job, as Khayt writes one.
    static let whole: [String: JSONValue] = [
        "id": .string("J-FULL"), "date": .string("2026-09-01"), "status": .string("pending"),
        "project": .string("Vase"), "price": .number(120), "paidAmount": .number(20),
        "paymentStatus": .string("partial"), "printTime": .number(2.5),
        "priority": .bool(true), "notes": .string("blue please"),
        "parts": .array([.object(["id": .string("PT-1"), "name": .string("Body"),
                                  "printWeight": .number(12), "qty": .number(1)])]),
    ]

    /// The nine fields that used to be required, and what `lib/` reads each as
    /// when it is absent.
    static let missingDefaults: [(field: String, check: (Order) -> Bool)] = [
        ("date", { $0.date == "" && $0.day == nil }),
        ("status", { $0.status == "" && Stage.of($0) == nil }),
        ("project", { $0.project == "" }),
        ("price", { $0.price == 0 }),
        ("paidAmount", { $0.paidAmount == 0 }),
        ("paymentStatus", { $0.paymentStatus == "" }),
        ("printTime", { $0.printTime == 0 }),
        ("priority", { $0.priority == false }),
        ("notes", { $0.notes == "" }),
    ]

    /// One job per missing field, then the awkward spellings.
    static let book: [JSONValue] = {
        var rows: [JSONValue] = []
        for (field, _) in missingDefaults {
            var row = whole
            row["id"] = .string("J-NO-\(field)")
            row.removeValue(forKey: field)
            rows.append(.object(row))
        }
        var strings = whole
        strings["id"] = .string("J-STRINGS")
        strings["price"] = .string("120")
        strings["paidAmount"] = .string(" 50 ")
        strings["printTime"] = .string("2.5")
        strings["priority"] = .number(1)
        rows.append(.object(strings))
        var blanks = whole
        blanks["id"] = .string("J-BLANKS")
        blanks["price"] = .string("")
        blanks["paidAmount"] = .null
        blanks["printTime"] = .string("about two hours")
        blanks["priority"] = .string("")
        blanks["notes"] = .null
        blanks["project"] = .number(42)
        rows.append(.object(blanks))
        return rows
    }()

    static func raw(_ id: String) -> [String: JSONValue] {
        for case .object(let o) in book where o["id"] == .string(id) { return o }
        return [:]
    }

    static func bytes(_ v: [String: JSONValue]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(JSONValue.object(v))
    }

    @Test("a job missing any one of the nine fields is read, with the shared default")
    func missingFieldsRead() throws {
        let decoded = try Shop.decodeOrders(["printLog": .array(Self.book)])
        #expect(decoded.skipped.isEmpty, "skipped \(decoded.skipped)")
        #expect(decoded.items.count == Self.book.count)
        for (field, check) in Self.missingDefaults {
            let job = try #require(decoded.items.first { $0.id == "J-NO-\(field)" })
            #expect(check(job), "J-NO-\(field) read \(field) wrongly")
            // Only the missing field defaults; the rest read as written.
            if field != "price" { #expect(job.price == 120) }
            if field != "project" { #expect(job.project == "Vase") }
        }
    }

    @Test("numbers as strings read as their numbers; blank and junk read as nought")
    func textNumbersRead() throws {
        let decoded = try Shop.decodeOrders(["printLog": .array(Self.book)])
        let strings = try #require(decoded.items.first { $0.id == "J-STRINGS" })
        #expect(strings.price == 120)
        #expect(strings.paidAmount == 50)
        #expect(strings.printTime == 2.5)
        #expect(strings.priority == true)
        #expect(strings.owed == 70)
        let blanks = try #require(decoded.items.first { $0.id == "J-BLANKS" })
        #expect(blanks.price == 0)
        #expect(blanks.paidAmount == 0)
        #expect(blanks.printTime == 0)
        #expect(blanks.priority == false)
        #expect(blanks.notes == "")
        #expect(blanks.project == "42")
    }

    @Test("a job without a status sits where the shared rule puts it: in no column")
    func missingStatusMatchesStageOf() async throws {
        let engine = try KhaytEngine()
        let shared = try await engine.raw("KhaytOrderStatus.stageOf({ id: 'J' })", as: String?.self)
        let job = try #require(try Shop.decodeOrders(["printLog": .array(Self.book)])
            .items.first { $0.id == "J-NO-status" })
        #expect(shared == nil)
        #expect(Stage.of(job) == nil)
    }

    @Test("opening each lenient job and saving it untouched leaves the record byte-identical")
    func untouchedSaveIsIdentical() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let jobs = try Shop.decodeOrders(["printLog": .array(Self.book)]).items
        #expect(jobs.count == Self.book.count)
        for job in jobs {
            let raw = Self.raw(job.id)
            let before = try Self.bytes(raw)

            // The edit sheet: opened and saved with nothing changed sends nothing.
            let opened = EditJobSheet.opening(job, priority: shop.priorityOf(job))
            let fields = EditJobSheet.fields(opened: opened, hasDueDate: opened.hasDueDate,
                                             dueDate: opened.dueDate ?? Date(),
                                             priority: opened.priority, price: nil)
            #expect(fields.isEmpty, "\(job.id) sent \(fields.keys.sorted())")
            let out = try await engine.editJob(order: .object(raw), fields: fields,
                                               now: Date(), editId: "e1")
            #expect(out.changed == false, "\(job.id) was changed by an untouched save")
            guard case .object(let after) = out.order else {
                Issue.record("\(job.id): the rule returned something that is not a job"); continue
            }
            #expect(try Self.bytes(after) == before, "\(job.id) was re-spelled by an untouched save")

            // The part sheet: the job's part opened and saved untouched.
            if case .array(let parts)? = raw["parts"], case .object(let rawPart) = parts[0] {
                let part = EditPartSheet.opening(job.parts[0], raw: rawPart, spools: [])
                let same = Shop.orderWithPartEdited(.object(raw), partId: "PT-1", part, opened: part,
                                                    spool: nil, costed: nil)
                guard case .object(let afterPart) = same else {
                    Issue.record("\(job.id): no job back from the part save"); continue
                }
                #expect(try Self.bytes(afterPart) == before, "\(job.id): untouched part save changed the job")
            }
        }
    }

    @Test("a job with no id, or a row that is not a job, is still skipped and counted")
    func unreadableStillSkipped() throws {
        var noId = Self.whole
        noId.removeValue(forKey: "id")
        var nullId = Self.whole
        nullId["id"] = .null
        let decoded = try Shop.decodeOrders(["printLog": .array([
            .object(noId), .object(nullId), .string("not a job"), .object(Self.whole),
        ])])
        #expect(decoded.items.map(\.id) == ["J-FULL"])
        #expect(decoded.skipped == ["(no id)", "(no id)", "(no id)"])
    }
}
