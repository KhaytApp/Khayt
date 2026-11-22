import Foundation
import Testing
@testable import KhaytCore

/// Swift and Node must hand a customer the same document.
///
/// The invoice is the one artefact that leaves the shop and is kept: a tax
/// officer reads the QR, an auditor reads the totals, and a customer keeps the
/// paper. Two apps producing subtly different documents for the same job is the
/// worst version of the problem this whole project is about.
struct InvoiceParityTests {

    static var repoRoot: URL { BundledLogicIsNotAForkTests.repoRoot }

    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        require('./lib/tax.js'); require('./lib/content-languages.js');
        require('./lib/invoice-language.js'); require('./lib/zatca-qr.js');
        require('./lib/invoice-document.js');
        process.stdout.write(String(JSON.stringify(\(expression))));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script]
        process.currentDirectoryURL = repoRoot
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KhaytJSError.evaluationFailed("node exited \(process.terminationStatus) for: \(expression)")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The QR payload, which is the half a tax officer scans.
    static let QR_CASES: [String] = [
        "KhaytZatcaQr.readiness({vat:'300000000000003'}, 'Tuwaiq Additive')",
        "KhaytZatcaQr.readiness({}, '')",
        "KhaytZatcaQr.readiness({vat:'   '}, 'X')",
        "KhaytZatcaQr.buildTLV({sellerName:'Tuwaiq Additive',vatNumber:'300000000000003',"
          + "timestamp:'2026-09-04T09:15:00Z',total:'1150.00',vatAmount:'150.00'}, {})",
        // An Arabic shop name: every character is two bytes, so the BER length
        // goes long-form well before the name looks long.
        "KhaytZatcaQr.buildTLV({sellerName:'\u{062A}'.repeat(80),vatNumber:'V',timestamp:'T',"
          + "total:'1',vatAmount:'0'}, {})",
        "KhaytZatcaQr.buildTLV({sellerName:'',vatNumber:'',timestamp:'',total:'',vatAmount:''}, {})",
    ]

    @Test("Swift and Node build the same ZATCA QR payload")
    func qrParity() async throws {
        let engine = try KhaytEngine()
        for expression in Self.QR_CASES {
            let fromNode = try Self.node(expression)
            let fromSwift = try await engine.raw(expression, as: JSONValue.self)
            #expect(fromSwift == fromNode, "diverged for: \(expression)")
        }
    }

    /// The document itself, for the shapes that reach different branches.
    static func doc(_ settings: String, _ language: String = "en") -> String {
        """
        KhaytInvoiceDocument.invoiceHtml(
          {id:'INV-2026-0021',invoiceNumber:'INV-2026-0021',date:'2026-09-04',
           timestamp:'2026-09-04T09:15:00.000Z',project:'Bracket set',client:'Acme',
           price:1150,paidAmount:0,paymentStatus:'unpaid',printTime:8,currency:'SAR',
           parts:[{name:'Bracket',qty:2,printWeight:180,unitCost:100,material:'PLA'}]},
          {qrSvg:'<svg id="q"></svg>', qrProblem:null, payQrSvg:'',
           total:'1150.00', vatAmount:'150.00', subtotal:'1000.00',
           subtotalShown:'1000.00', vatRate:15, shipping:0,
           settings:\(settings), clients:[], CURRENCIES:{SAR:{symbol:'SAR'}},
           i18n:{current:'\(language)', tIn:function(l,k){return k;}},
           t:function(k){return k;},
           escapeHtml:function(s){return String(s==null?'':s);},
           fmtMoney:function(n){return String(n);},
           formatPrintDate:function(d){return String(d||'');},
           shopField:function(){return 'Tuwaiq Additive';},
           safeBizLogo:function(){return '';},
           safeCssColor:function(v,f){return f;},
           renderClientSub:function(){return '';},
           BRAND_MARK_SVG:'', orderCurrency:null,
           clientCurrency:function(){return 'SAR';},
           payStatus:function(o){return o.paymentStatus||'unpaid';},
           hijriDate:function(){return '';},
           toArabicNumerals:function(s){return String(s);}}).html
        """
    }

    static let SHOP = "{currency:'SAR',vat:'300000000000003',enableVat:true,vatRate:15}"

    @Test("Swift and Node produce the same invoice, character for character")
    func documentParity() async throws {
        let engine = try KhaytEngine()
        for expression in [
            Self.doc(Self.SHOP),
            Self.doc(Self.SHOP, "ar"),
            Self.doc("{currency:'SAR',enableVat:false}"),
            Self.doc("{currency:'SAR',vat:'300000000000003',enableVat:true,vatRate:15,useHijri:true}"),
        ] {
            let fromNode = try Self.node(expression)
            let fromSwift = try await engine.raw(expression, as: JSONValue.self)
            #expect(fromSwift == fromNode, "the two apps would hand out different invoices")
        }
    }

    /// A document with no substance is worse than none: it looks like a receipt.
    @Test("the document that comes back is a document")
    func documentIsNotEmpty() async throws {
        let engine = try KhaytEngine()
        guard case .string(let html) = try await engine.raw(Self.doc(Self.SHOP), as: JSONValue.self) else {
            Issue.record("not a string"); return
        }
        #expect(html.count > 1000)
        #expect(html.contains("INV-2026-0021"))
        #expect(html.contains("300000000000003"))
        #expect(html.contains("1150.00"))
    }
}
