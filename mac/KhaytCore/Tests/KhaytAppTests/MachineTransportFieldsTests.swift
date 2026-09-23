import Foundation
import Testing
@testable import KhaytApp

/// A Bambu, an Elegoo and a Repetier-Server printer can be set up on the Mac.
///
/// The Mac could poll all three, and its machine sheet had no field for what
/// each is addressed by — a Bambu's serial and access code, an Elegoo's
/// mainboard id, a Repetier printer's slug — so a Mac-only shop could pick the
/// protocol and never make it work. The shared rule is held by
/// `test/machine-edit.test.js`; this holds the sheet to sending the fields, and
/// to sealing the access code rather than writing it in the clear.
@MainActor
struct MachineTransportFieldsTests {

    static var sheet: String { MenuCoverageTests.source("MachineSheet.swift") }

    @Test("the sheet sends the serial and the slug for the protocols that use them")
    func sendsIdentifiers() {
        #expect(Self.sheet.contains(#"if ["bambu", "sdcp"].contains(apiType) { api["serial"] = .string(serial) }"#))
        #expect(Self.sheet.contains(#"if apiType == "repetier" { api["printerSlug"] = .string(slug) }"#))
    }

    @Test("the access code is sealed before it is written, or refused")
    func sealsTheCode() {
        let s = Self.sheet
        #expect(s.contains(#"api["accessCode"] = .string(try await Secrets.seal(typedCode, for: build))"#),
                "a Bambu access code is being written without being sealed")
        #expect(!s.contains(#"api["accessCode"] = .string(typedCode)"#), "the access code is written in the clear")
    }

    @Test("the fields are drawn for the protocols that need them, and the key field is not")
    func drawsTheFields() {
        let s = Self.sheet
        #expect(s.contains(#""mac.mach_serial""#) && s.contains(#""mac.mach_mainboard""#))
        #expect(s.contains(#""mac.mach_access_code""#) && s.contains(#""mac.mach_slug""#))
        #expect(s.contains(#"if type != "bambu" && type != "sdcp" {"#),
                "a Bambu or Elegoo is offered an API key it does not take")
        #expect(PrinterWatch.spoken.isSuperset(of: ["bambu", "sdcp", "repetier"]),
                "the protocol menu no longer offers a protocol these fields are for")
    }
}
