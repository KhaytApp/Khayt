import Foundation
import Testing
@testable import KhaytCore

/// Reading a supplier's receipt QR gives the same answer in the app's
/// JavaScriptCore as in Node, where `test/zatca-receipt.test.js` pins it.
///
/// The decoder leans on the places the two engines are most likely to part:
/// hand-rolled base64 and UTF-8 (JavaScriptCore has no `atob`/`TextDecoder`),
/// Unicode normalisation for a supplier's name, and `Date` parsing for the
/// local day. Each vector below reaches one of them.
struct ReceiptQrParityTests {

    /// TLV bytes → base64, the same hand-builder the Node test uses.
    static let PACK = """
    (function(fields){var b=[];fields.forEach(function(f){var v=Array.isArray(f[1])?f[1]:KhaytZatcaQr.utf8(f[1]);\
    if(v.length>255)b.push(f[0],0x82,(v.length>>8)&255,v.length&255);else if(v.length>127)b.push(f[0],0x81,v.length);\
    else b.push(f[0],v.length);for(var i=0;i<v.length;i++)b.push(v[i]);});return KhaytZatcaQr.base64(b);})
    """
    static let FIVE = "[1,'Tuwaiq Filament Supply'],[2,'310122393500003'],[3,'2026-10-09T14:30:00Z'],[4,'115.00'],[5,'15.00']"
    static let BUILD = "KhaytZatcaQr.buildTLV({sellerName:'مؤسسة الخيط للطباعة',vatNumber:'310122393500003',"
        + "timestamp:'2026-10-09T14:30:00Z',total:'115.00',vatAmount:'15.00'},{})"

    static let DECODE_CASES: [String] = [
        "KhaytZatcaQr.decodeTLV(\(BUILD))",
        "KhaytZatcaQr.decodeTLV(KhaytZatcaQr.buildTLV({sellerName:'شركة '.repeat(40),vatNumber:'300000000000003',"
            + "timestamp:'2026-10-09T14:30:00+03:00',total:'1150',vatAmount:'150'},{}))",
        // Phase 2: the signature tags are skipped, not refused.
        "KhaytZatcaQr.decodeTLV(\(PACK)([\(FIVE),[6,new Array(32).fill(7)],[7,new Array(72).fill(9)],[8,new Array(88).fill(1)],[9,new Array(70).fill(2)]]))",
        // URL-safe alphabet, a line break inside.
        "KhaytZatcaQr.decodeTLV((function(q){q=q.replace(/\\+/g,'-').replace(/\\//g,'_');return q.slice(0,20)+'\\n'+q.slice(20);})(\(BUILD)))",
        // A 4-byte character (outside the BMP) in the seller's name.
        "KhaytZatcaQr.decodeTLV(\(PACK)([[1,'Print 🖨️ Co'],[2,'310122393500003'],[3,'2026-10-09'],[4,'10'],[5,'1.30']]))",
        // Every refusal.
        "KhaytZatcaQr.decodeTLV('')",
        "KhaytZatcaQr.decodeTLV('A'.repeat(20000))",
        "KhaytZatcaQr.decodeTLV('not base64 at all!')",
        "KhaytZatcaQr.decodeTLV(KhaytZatcaQr.base64([1,50,65]))",
        "KhaytZatcaQr.decodeTLV(KhaytZatcaQr.base64([1,0x83,0,0,1]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([\(FIVE),[1,'again']]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([\(FIVE),[42,'x']]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([[1,[0xc3,0x28]],[2,'310122393500003'],[3,'2026-10-09'],[4,'1'],[5,'0']]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([[1,[0xe0,0x80,0xaf]],[2,'310122393500003'],[3,'2026-10-09'],[4,'1'],[5,'0']]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([[1,[0xed,0xa0,0x80]],[2,'310122393500003'],[3,'2026-10-09'],[4,'1'],[5,'0']]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([[1,'X'],[2,'310122393500003'],[3,'2026-10-09'],[4,'1']]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([[1,'X'],[2,'123456789012345'],[3,'2026-10-09'],[4,'1'],[5,'0']]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([[1,'X'],[2,'310122393500003'],[3,'2026-10-09'],[4,'1e3'],[5,'0']]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([[1,'X'],[2,'310122393500003'],[3,'2026-10-09'],[4,'10'],[5,'20']]))",
        "KhaytZatcaQr.decodeTLV(\(PACK)([[1,'X'],[2,'310122393500003'],[3,'yesterday'],[4,'10'],[5,'1']]))",
    ]

    static let DRAFT_CASES: [String] = [
        "KhaytZatcaQr.receiptToExpenseDraft(KhaytZatcaQr.decodeTLV(\(BUILD)).receipt,{suppliers:[],expenses:[],reclaimsTax:true})",
        "KhaytZatcaQr.receiptToExpenseDraft(KhaytZatcaQr.decodeTLV(\(BUILD)).receipt,{reclaimsTax:false})",
        // The VAT number outranks the name; a full-width name still matches by NFKC.
        "KhaytZatcaQr.receiptToExpenseDraft(KhaytZatcaQr.decodeTLV(\(PACK)([\(FIVE)])).receipt,"
            + "{suppliers:[{id:'S1',name:'tuwaiq filament supply'},{id:'S2',name:'Other',vat:'310122393500003'}]})",
        "KhaytZatcaQr.receiptToExpenseDraft(KhaytZatcaQr.decodeTLV(\(PACK)([\(FIVE)])).receipt,"
            + "{suppliers:[{id:'S1',name:'ＴＵＷＡＩＱ Filament-Supply'}]})",
        "KhaytZatcaQr.receiptToExpenseDraft(KhaytZatcaQr.decodeTLV(\(BUILD)).receipt,"
            + "{expenses:[{id:'E9',receiptRef:'zatca:310122393500003:2026-10-09T14:30:00Z:115'}]})",
        "[KhaytZatcaQr.receiptDay('2026-10-09'),KhaytZatcaQr.receiptDay('2026-10-09T23:30:00Z'),"
            + "KhaytZatcaQr.receiptDay('2026-10-09T23:30:00'),KhaytZatcaQr.receiptDay('2026-10-09T23:30:00+03:00'),"
            + "KhaytZatcaQr.receiptDay('garbage')]",
    ]

    @Test("the app and Node read a receipt QR the same way, refusals included")
    func decodeParity() async throws {
        let engine = try KhaytEngine()
        var reasons = Set<String>()
        for expression in Self.DECODE_CASES {
            let fromNode = try InvoiceParityTests.node(expression)
            let fromSwift = try await engine.raw(expression, as: JSONValue.self)
            #expect(fromSwift == fromNode, "diverged for: \(expression)")
            if case .object(let o) = fromSwift, case .string(let r)? = o["reason"] { reasons.insert(r) }
        }
        // Every reason the decoder has is reached here, so none is untested.
        #expect(reasons == ["empty", "too_long", "not_base64", "truncated", "bad_tag", "not_utf8",
                            "missing_tag", "bad_vat_number", "bad_amount", "vat_over_total", "bad_timestamp"],
                "\(reasons.sorted())")
    }

    @Test("the app and Node turn a receipt into the same expense draft")
    func draftParity() async throws {
        let engine = try KhaytEngine()
        for expression in Self.DRAFT_CASES {
            let fromNode = try InvoiceParityTests.node(expression)
            let fromSwift = try await engine.raw(expression, as: JSONValue.self)
            #expect(fromSwift == fromNode, "diverged for: \(expression)")
        }
    }

    @Test("the typed bindings decode what the rule says")
    func bindings() async throws {
        let engine = try KhaytEngine()
        let qr = try await engine.zatcaPayload(sellerName: "Tuwaiq Filament Supply", vatNumber: "310122393500003",
                                               timestamp: "2026-10-09T14:30:00Z", total: "115.00", vatAmount: "15.00")
        let read = try await engine.readReceiptQr(qr)
        #expect(read.ok)
        #expect(read.receipt?.total == 115)
        #expect(read.receipt?.vatAmount == 15)
        #expect(try await engine.readReceiptQr("https://example.com").reason == "not_base64")

        let supplier: JSONValue = .object(["id": .string("S2"), "name": .string("Other"), "vat": .string("310122393500003")])
        let draft = try #require(try await engine.receiptDraft(qr, suppliers: [supplier], expenses: [], reclaimsTax: true))
        #expect(draft.supplier?.id == "S2")
        #expect(draft.draft.amount == 115 && draft.draft.vatAmount == 15)
        #expect(draft.duplicateOf == nil)
        let filed: JSONValue = .object(["id": .string("E1"), "receiptRef": .string(draft.draft.receiptRef)])
        #expect(try await engine.receiptDraft(qr, suppliers: [], expenses: [filed], reclaimsTax: true)?.duplicateOf == "E1")
        #expect(try await engine.receiptDraft(qr, suppliers: [], expenses: [], reclaimsTax: false)?.draft.vatAmount == 0)
        #expect(try await engine.receiptDraft("nonsense", suppliers: [], expenses: [], reclaimsTax: true) == nil)
    }
}
