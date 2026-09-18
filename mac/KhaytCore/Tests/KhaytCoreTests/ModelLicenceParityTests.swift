import Foundation
import Testing
@testable import KhaytCore

/// What a model's licence permits, against the JavaScript it came from.
///
/// The answer a shop acts on is a THREE-valued one — yes, no, and nobody has
/// said — so most of these cases are about the third.
@MainActor
struct ModelLicenceParityTests {

    private func js() throws -> JSModule { try JSModule(["model-licence"]) }

    private func theirStanding(_ js: JSModule, source: String, licence: String)
        throws -> ModelLicence.Standing {
        let v = try js.value("KhaytModelLicence.standing({source: ARG0, licence: ARG1})",
                             [.string(source), .string(licence)])
        guard case .object(let o) = v else {
            Issue.record("not an object"); throw CancellationError()
        }
        func flag(_ k: String) -> Bool { if case .bool(let b)? = o[k] { return b }; return false }
        func maybe(_ k: String) -> Bool? { if case .bool(let b)? = o[k] { return b }; return nil }
        func text(_ k: String) -> String { if case .string(let s)? = o[k] { return s }; return "" }
        return .init(known: flag("known"), licence: text("licence"), source: text("source"),
                     sellable: maybe("sellable"), attribution: flag("attribution"),
                     derivatives: maybe("derivatives"), share: flag("share"))
    }

    /// Every id the module knows, plus the ways a record can say nothing.
    private let inputs = [
        "own", "cc0", "cc-by", "cc-by-sa", "cc-by-nd",
        "cc-by-nc", "cc-by-nc-sa", "cc-by-nc-nd", "commercial",
        "", "  ", "CC-BY", "  cc-by-nc  ", "CC0", "Commercial",
        "cc", "cc-by-nc-sa-4.0", "mit", "gpl", "cc_by", "ccby",
        "cc-by ", "nc", "own ", "OWN", "unknown", "null", "0", "false",
    ]

    @Test("the standing of every licence, and of every way of saying nothing")
    func standingMatches() throws {
        let js = try js()
        for licence in inputs {
            for source in ["", "printables", "  Thingiverse  ", "a designer"] {
                let mine = ModelLicence.standing(source: source, licence: licence)
                let theirs = try theirStanding(js, source: source, licence: licence)
                #expect(mine == theirs, Comment(rawValue: "\(licence.debugDescription) from \(source.debugDescription)"))
            }
        }
    }

    @Test("unknown is not no")
    func unknownIsNotNo() throws {
        // The whole point of the module: a shop that has filled nothing in is
        // told nothing, not told no.
        #expect(ModelLicence.sellable(nil) == nil)
        #expect(ModelLicence.sellable("") == nil)
        #expect(ModelLicence.sellable("mit") == nil)
        #expect(ModelLicence.allowsDerivatives("") == nil)
        #expect(ModelLicence.sellable("cc-by-nc") == false)
        #expect(ModelLicence.standing(source: nil, licence: nil).known == false)
    }

    @Test("the three one-question answers match")
    func answersMatch() throws {
        let js = try js()
        for licence in inputs {
            let sellable = try js.value("KhaytModelLicence.sellable(ARG0)", [.string(licence)])
            let attribution = try js.value("KhaytModelLicence.needsAttribution(ARG0)", [.string(licence)])
            let derivatives = try js.value("KhaytModelLicence.allowsDerivatives(ARG0)", [.string(licence)])
            func maybe(_ v: JSONValue) -> Bool? { if case .bool(let b) = v { return b }; return nil }
            #expect(ModelLicence.sellable(licence) == maybe(sellable),
                    Comment(rawValue: "sellable \(licence.debugDescription)"))
            #expect(ModelLicence.needsAttribution(licence) == (maybe(attribution) ?? false),
                    Comment(rawValue: "attribution \(licence.debugDescription)"))
            #expect(ModelLicence.allowsDerivatives(licence) == maybe(derivatives),
                    Comment(rawValue: "derivatives \(licence.debugDescription)"))
        }
    }

    @Test("the menu is the same list in the same order")
    func listMatches() throws {
        let js = try js()
        let v = try js.value("KhaytModelLicence.list()", [])
        guard case .array(let rows) = v else { Issue.record("not an array"); return }
        #expect(rows.count == ModelLicence.all.count)
        for (row, mine) in zip(rows, ModelLicence.all) {
            guard case .object(let o) = row else { Issue.record("row is not an object"); continue }
            func flag(_ k: String) -> Bool { if case .bool(let b)? = o[k] { return b }; return false }
            var id = ""; if case .string(let s)? = o["id"] { id = s }
            #expect(id == mine.id)
            #expect(flag("commercial") == mine.commercial, Comment(rawValue: "commercial of \(id)"))
            #expect(flag("attribution") == mine.attribution, Comment(rawValue: "attribution of \(id)"))
            #expect(flag("derivatives") == mine.derivatives, Comment(rawValue: "derivatives of \(id)"))
            #expect(flag("share") == mine.share, Comment(rawValue: "share of \(id)"))
        }
    }

    @Test("only what is recorded as non-commercial is withheld")
    func notForSaleMatches() throws {
        let js = try js()
        let library: [JSONValue] = [
            .object(["id": .string("a"), "licence": .string("cc-by-nc")]),
            .object(["id": .string("b"), "licence": .string("cc0")]),
            .object(["id": .string("c")]),
            .object(["id": .string("d"), "licence": .string("")]),
            .object(["id": .string("e"), "licence": .string("CC-BY-NC-ND")]),
            .object(["id": .string("f"), "licence": .string("mit")]),
            .object(["id": .string("g"), "licence": .number(3)]),
            .object(["id": .string("h"), "licence": .null]),
            .null, .string("x"), .number(1), .bool(true), .array([]),
        ]
        let mine = ModelLicence.notForSale(library)
        let theirs = try js.value("KhaytModelLicence.notForSale(ARG0)", [.array(library)])
        #expect(theirs == .array(mine))
        // A library nobody has filled in warns about nothing at all.
        #expect(ModelLicence.notForSale([.object(["id": .string("a")]),
                                         .object(["id": .string("b")])]).isEmpty)
    }
}
