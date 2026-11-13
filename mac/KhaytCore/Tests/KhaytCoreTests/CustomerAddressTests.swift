import Foundation
import Testing
@testable import KhaytCore

/// The Mac reaches the shared address rule (`lib/customer-address.js`,
/// Turki's request of Nov 10). test/customer-address.test.js has the full
/// case list; this proves the module is in the Mac's engine and answers the
/// same, including the rule that keeps every row the old desktop can save.
struct CustomerAddressTests {

    @Test("a Saudi address reads as the National Address, and saving writes the text old builds read")
    func nationalAddress() async throws {
        let engine = try KhaytEngine()
        let row = try await engine.applyAddressFields(
            .object(["id": .string("ADDR-1"), "courierRef": .string("x")]),
            fields: ["buildingNumber": "٨٢٢٨", "line1": "Imam Abdullah Ibn Saud Rd", "district": "Al Mursalat",
                     "city": "Riyadh", "postalCode": "12345", "additionalNumber": "6789", "shortAddress": "rrrd 2929"],
            shopCountry: "SA")
        let text = "8228 Imam Abdullah Ibn Saud Rd\nAl Mursalat\nRiyadh 12345-6789\nRRRD2929"
        guard case .object(let o) = row else { Issue.record("not a row"); return }
        #expect(o["address"] == .string(text))
        #expect(o["textOf"] == .string(text))
        #expect(o["label"] == .string(""), "the old desktop's save throws on a row without a label")
        #expect(o["courierRef"] == .string("x"))
        #expect(try await engine.addressText(row, shopCountry: "SA") == text)
        #expect(try await engine.addressState(row) == "structured")
    }

    @Test("free text is never split, and an old build's edit to the text wins")
    func textWins() async throws {
        let engine = try KhaytEngine()
        let plain: JSONValue = .object(["id": .string("a"), "label": .string(""), "address": .string("King Fahd Rd")])
        #expect(try await engine.addressState(plain) == "unstructured")
        let split = try await engine.applyAddressFields(plain, fields: ["line1": "Olaya St", "city": "Riyadh"],
                                                       shopCountry: "SA")
        guard case .object(var o) = split else { Issue.record("not a row"); return }
        o["address"] = .string("Tahlia St, Jeddah")
        #expect(try await engine.addressState(.object(o)) == "edited_elsewhere")
        #expect(try await engine.addressText(.object(o), shopCountry: "SA") == "Tahlia St, Jeddah")
    }

    @Test("rows are made readable by the old desktop, and a job's address falls back in order")
    func oldBuildsAndShipping() async throws {
        let engine = try KhaytEngine()
        let rows = try await engine.addressRowsForOldBuilds([.null, .object(["id": .string("r"), "address": .string("x")])])
        #expect(rows == [.object(["id": .string("r"), "label": .string(""), "address": .string("x")])])
        let client: JSONValue = .object(["addresses": .array([
            .object(["id": .string("a"), "label": .string(""), "address": .string("Default row")])])])
        #expect(try await engine.shipAddress(order: .object([:]), client: client, shopCountry: "SA") == "Default row")
        #expect(try await engine.shipAddress(order: .object(["deliveryAddress": .string("Typed")]),
                                             client: client, shopCountry: "SA") == "Typed")
        let snap = try await engine.shipTo(row: .object(["line1": .string("x")]), client: nil, shopCountry: "AE")
        guard case .object(let s)? = snap else { Issue.record("no snapshot"); return }
        #expect(s["country"] == .string("AE"))
    }

    @Test("for display, the postcode after an Arabic city stays one left-to-right number")
    func displayKeepsThePostcodeInOrder() async throws {
        let engine = try KhaytEngine()
        let row = try await engine.applyAddressFields(
            .object(["id": .string("r"), "label": .string("")]),
            fields: ["city": "الرياض", "postalCode": "12345", "additionalNumber": "6789", "country": "SA"],
            shopCountry: "SA")
        let stored = try await engine.addressText(row, shopCountry: "SA")
        #expect(stored == "الرياض 12345-6789")
        let shown = try await engine.addressText(row, shopCountry: "SA", display: true)
        #expect(shown == "الرياض \u{200E}12345-6789")
    }
}
