import Foundation
import Testing
@testable import KhaytCore

/// Will it go on that bed, against the JavaScript it came from.
///
/// The converter answers the same question from the same rule, so a model this
/// screen calls too big must not be one the conversion report waves through.
/// The cases here are the ones where a plain comparison of six numbers gives a
/// different answer.
@MainActor
struct PrintFitParityTests {

    private func js() throws -> JSModule { try JSModule(["print-fit"]) }

    private func box(_ x: Double?, _ y: Double?, _ z: Double?) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if let x { o["x"] = .number(x) }
        if let y { o["y"] = .number(y) }
        if let z { o["z"] = .number(z) }
        return .object(o)
    }

    private func checkOne(_ bounds: JSONValue?, _ bed: JSONValue?, _ what: String,
                          _ js: JSModule) throws {
        let mine = PrintFit.check(bounds: bounds, bed: bed)
        let v = try js.value("KhaytPrintFit.check(ARG0, ARG1)",
                             [bounds ?? .null, bed ?? .null])
        guard case .object(let o) = v else { Issue.record("not an object"); return }
        func flag(_ k: String) -> Bool { if case .bool(let b)? = o[k] { return b }; return false }
        var over = PrintFit.Over(x: -1, y: -1, z: -1)
        if case .object(let r)? = o["over"] {
            over = .init(x: JSSemantics.number(r["x"]), y: JSSemantics.number(r["y"]),
                         z: JSSemantics.number(r["z"]))
        }
        let theirs = PrintFit.Verdict(known: flag("known"), ok: flag("ok"),
                                      footprint: flag("footprint"), height: flag("height"),
                                      rotated: flag("rotated"), over: over)
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine)
              js    \(theirs)
            """))
    }

    @Test("a model that does not fit as it lies but fits turned a quarter turn")
    func rotationIsAdvice() throws {
        // Saying WHICH is more use than refusing: the converter's own advice
        // has always been "rotate or rescale in your slicer".
        let js = try js()
        try checkOne(box(300, 200, 100), box(250, 250, 250), "300x200 on 250x250", js)
        try checkOne(box(300, 300, 100), box(250, 250, 250), "too big either way", js)
        try checkOne(box(200, 200, 100), box(250, 250, 250), "fits as it lies", js)
        // Rotation does not rescue a model that is too TALL.
        try checkOne(box(300, 200, 400), box(250, 250, 250), "tall and wide", js)
    }

    @Test("a millimetre of slack, because a bed size is nominal")
    func slackIsOneMillimetre() throws {
        let js = try js()
        for x in [249.0, 250, 250.5, 251, 251.0001, 252, 270.0001] {
            try checkOne(box(x, 100, 10), box(250, 250, 250), "\(x) wide", js)
        }
        #expect(PrintFit.slack == 1, "the converter's own tolerance moved")
    }

    @Test("a bed with no height recorded cannot refuse one")
    func noHeightCannotRefuse() throws {
        let js = try js()
        try checkOne(box(100, 100, 9000), box(250, 250, 0), "no bed height", js)
        try checkOne(box(100, 100, 9000), box(250, 250, nil), "no bed height at all", js)
        try checkOne(box(100, 100, 9000), box(250, 250, 250), "a real bed height", js)
    }

    @Test("an unmeasured model is not a model that does not fit")
    func unknownIsNotRefusal() throws {
        // …and must never be shown as one.
        let js = try js()
        for (bounds, bed, what) in [
            (JSONValue?.none, JSONValue?.some(box(250, 250, 250)), "no model"),
            (.some(box(100, 100, 100)), JSONValue?.none, "no bed"),
            (.some(box(0, 100, 100)), .some(box(250, 250, 250)), "a model with no width"),
            (.some(box(100, 0, 100)), .some(box(250, 250, 250)), "a model with no depth"),
            (.some(box(100, 100, 100)), .some(box(0, 250, 250)), "a bed with no width"),
            (.some(box(100, 100, 100)), .some(box(250, 0, 250)), "a bed with no depth"),
            (.some(.object([:])), .some(box(250, 250, 250)), "an empty model"),
            (.some(box(100, 100, 100)), .some(.object([:])), "an empty bed"),
            (.some(.string("x")), .some(box(250, 250, 250)), "a model that is a string"),
            (.some(.null), .some(box(250, 250, 250)), "a null model"),
        ] {
            try checkOne(bounds, bed, what, js)
            let mine = PrintFit.check(bounds: bounds, bed: bed)
            #expect(mine.ok, Comment(rawValue: "\(what) was reported as not fitting"))
            #expect(!mine.known)
        }
    }

    @Test("the best of the machines a shop owns, in the order a maker would try them")
    func bestFitMatches() throws {
        let js = try js()
        func machine(_ id: String, _ bed: JSONValue?) -> JSONValue {
            var m: [String: JSONValue] = ["id": .string(id), "name": .string(id)]
            if let bed { m["bed"] = bed }
            return .object(m)
        }
        let cases: [(JSONValue, [JSONValue], String)] = [
            (box(300, 200, 100),
             [machine("A", box(250, 250, 250)), machine("B", box(400, 400, 400))],
             "one rotates, a later one fits"),
            (box(300, 200, 100),
             [machine("A", box(250, 250, 250)), machine("C", box(260, 260, 260))],
             "two rotate — the first wins"),
            (box(900, 900, 900),
             [machine("A", box(250, 250, 250))], "nothing fits"),
            (box(100, 100, 100),
             [machine("A", nil), machine("B", box(250, 250, 250))],
             "a machine with no bed is skipped"),
            (box(100, 100, 100), [], "no machines at all"),
            (box(300, 200, 400),
             [machine("A", box(250, 250, 250))], "rotates but too tall"),
            (box(100, 100, 100),
             [.null, .string("x"), machine("B", box(250, 250, 250))], "a mess"),
        ]
        for (bounds, machines, what) in cases {
            let mine = PrintFit.bestFit(bounds: bounds, machines: machines)
            let v = try js.value("KhaytPrintFit.bestFit(ARG0, ARG1)",
                                 [bounds, .array(machines)])
            guard case .object(let o) = v else { Issue.record("not an object"); continue }
            let verdict = JSSemantics.text(o["verdict"])
            let checked = Int(JSSemantics.number(o["checked"]))
            var theirId: String?
            if case .object(let m)? = o["machine"], case .string(let id)? = m["id"] {
                theirId = id
            }
            var mineId: String?
            if let i = mine.machineIndex, case .object(let m) = machines[i],
               case .string(let id)? = m["id"] { mineId = id }
            #expect(mine.verdict.rawValue == verdict, Comment(rawValue: "\(what): verdict"))
            #expect(mine.checked == checked, Comment(rawValue: "\(what): checked"))
            #expect(mineId == theirId, Comment(rawValue: "\(what): which machine"))
        }
    }
}
