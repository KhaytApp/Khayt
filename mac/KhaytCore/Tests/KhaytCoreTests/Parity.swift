import Foundation
import JavaScriptCore
import Testing
@testable import KhaytCore

/// Running a ported rule and the JavaScript it came from over the same input,
/// and refusing to let them disagree.
///
/// ── WHY THE PORT HAS THIS BEFORE IT HAS ANY MODULES ───────────────────────
///
/// Two implementations of one rule is the failure this codebase has spent most
/// of its effort on: a chart that summed gross under a net P&L, a utilisation
/// figure capped in one place and not another, a status the phone had no word
/// for. Every one of those was two pieces of code that were each correct and
/// did not agree.
///
/// A port makes a second implementation of everything on purpose. The only
/// thing that makes that safe is refusing to accept one until it has been shown
/// to agree with the original — not on a handful of cases somebody thought of,
/// but on generated input including the values nobody thinks of: zero, a
/// negative half, a string where a number was expected, a missing field.
///
/// So this is the harness, and the rule for the whole port is: **a module is
/// not ported until its parity test passes, and the JavaScript stays in the
/// repository as the specification.**
///
/// The JavaScript is loaded FROM `lib/` rather than from the app's bundle, so
/// a module can be un-bundled from the shipping app — which is the point of
/// porting it — while the original remains available to test against.
enum Parity {

    /// A JavaScript context with one `lib/` module loaded into it.
    ///
    /// Bare `JSContext` rather than `KhaytEngine`, deliberately: the engine
    /// loads what the APP ships, and the whole purpose of a port is that the
    /// app stops shipping this. Reading the file keeps the specification
    /// available after the module leaves the bundle.
    static func context(loading modules: [String]) throws -> JSContext {
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, value in
            failure = value.map { "\($0)" } ?? "unknown JavaScript error"
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .deletingLastPathComponent()   // …/mac
            .deletingLastPathComponent()   // the repository root
            .appending(path: "lib")
        for name in modules {
            let url = root.appending(path: "\(name).js")
            let source = try String(contentsOf: url, encoding: .utf8)
            context.evaluateScript(source)
            if let failure { throw Failure.script(name, failure) }
        }
        return context
    }

    enum Failure: Error, CustomStringConvertible {
        case script(String, String)
        case noAnswer(String)
        var description: String {
            switch self {
            case .script(let m, let why): return "\(m).js would not load: \(why)"
            case .noAnswer(let e): return "no answer from: \(e)"
            }
        }
    }

    /// Evaluate an expression against the loaded modules and return what it
    /// produced, as the same `JSONValue` a Swift port would return.
    ///
    /// `args` are bound as `ARG0`, `ARG1`, … to match how `KhaytEngine` calls
    /// its own rules, so a parity expression reads like the engine binding it
    /// is replacing.
    static func run(_ context: JSContext, _ expression: String,
                    _ args: [JSONValue] = []) throws -> JSONValue {
        for (i, arg) in args.enumerated() {
            let data = try JSONEncoder().encode(arg)
            let json = String(decoding: data, as: UTF8.self)
            context.evaluateScript("var ARG\(i) = \(json);")
        }
        // Through JSON both ways: it is what crosses the bridge in the app, so
        // a difference JSON cannot carry is not a difference that matters.
        let wrapped = "JSON.stringify({ v: (\(expression)) })"
        guard let value = context.evaluateScript(wrapped),
              let text = value.toString(), text != "undefined" else {
            throw Failure.noAnswer(expression)
        }
        struct Box: Decodable { let v: JSONValue? }
        let box = try JSONDecoder().decode(Box.self, from: Data(text.utf8))
        return box.v ?? .null
    }
}

/// Numbers chosen because they are where two implementations part company.
enum Awkward {
    /// Halves, negatives, zeroes, and the sizes a real model reaches.
    static let numbers: [Double] = [
        0, -0, 1, -1, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5,
        0.005, -0.005, 0.015, 0.025, 0.045,       // rounding at the second place
        1.005, 2.675, 8.325,                      // the classic float-rounding traps
        1_142_945.9, 163.53, 167.58, 55.21,       // from this shop's own library
        1e-7, 1e-6, 1e20, 1e21, 123_456_789.987,
        1.0 / 3.0, 2.0 / 3.0,
        Double.leastNormalMagnitude, Double.greatestFiniteMagnitude,
    ]

    /// Values that are not numbers at all, because `Number()` accepts most of
    /// them and a Swift port that only takes a JSON number would not.
    static let notNumbers: [JSONValue] = [
        .null, .string(""), .string("  "), .string("12"), .string("12.5"),
        .string("1e3"), .string("nope"), .string("0x10"), .string("Infinity"),
        .bool(true), .bool(false), .array([]), .object([:]),
    ]
}

/// One `lib/` module, loaded once, with the calls a parity test needs.
///
/// A small box per module rather than raw expressions at every call site: the
/// expression is the thing being held constant between the two, so it belongs
/// in one place.
@MainActor
final class JSContextBox {
    private let context: JSContext

    init(_ modules: [String]) throws {
        context = try Parity.context(loading: modules)
    }

    func key(of geometry: JSONValue) throws -> String? {
        let answer = try Parity.run(context, "globalThis.KhaytGeometryKey.geometryKey(ARG0)", [geometry])
        if case .string(let s) = answer { return s }
        return nil
    }

    func needsRemeasure(_ record: JSONValue) throws -> Bool {
        let answer = try Parity.run(context, "globalThis.KhaytGeometryKey.needsRemeasure(ARG0)", [record])
        if case .bool(let b) = answer { return b }
        return false
    }

    func reader() throws -> Int {
        let answer = try Parity.run(context, "globalThis.KhaytGeometryKey.READER")
        if case .number(let n) = answer { return Int(n) }
        return -1
    }
}

/// Any module, any expression — for ports whose surface is small enough that a
/// bespoke box would be more ceremony than it is worth.
@MainActor
final class JSModule {
    private let context: JSContext
    init(_ modules: [String]) throws { context = try Parity.context(loading: modules) }
    func value(_ expression: String, _ args: [JSONValue] = []) throws -> JSONValue {
        try Parity.run(context, expression, args)
    }
    func int(_ expression: String, _ args: [JSONValue] = []) throws -> Int? {
        if case .number(let n) = try value(expression, args) { return Int(n) }
        return nil
    }
    func bool(_ expression: String, _ args: [JSONValue] = []) throws -> Bool? {
        if case .bool(let b) = try value(expression, args) { return b }
        return nil
    }
    func strings(_ expression: String, _ args: [JSONValue] = []) throws -> [String] {
        guard case .array(let items) = try value(expression, args) else { return [] }
        return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
}
