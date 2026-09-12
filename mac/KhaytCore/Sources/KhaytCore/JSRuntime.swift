import Foundation
import JavaScriptCore

/// Errors the JavaScript side can raise into Swift.
public enum KhaytJSError: Error, CustomStringConvertible {
    case moduleMissing(String)
    case evaluationFailed(String)
    case unexpectedResult(String)

    public var description: String {
        switch self {
        case .moduleMissing(let m):      return "KhaytCore: bundled module missing: \(m)"
        case .evaluationFailed(let m):   return "KhaytCore: \(m)"
        case .unexpectedResult(let m):   return "KhaytCore: unexpected result: \(m)"
        }
    }
}

/// One JavaScriptCore context holding Khayt's shared business logic.
///
/// The modules are IIFEs that assign themselves onto `globalThis` — `KhaytTax`,
/// `KhaytPricing`, `KhaytPaymentPlan` and so on — which is exactly how the
/// renderer loads them from `<script>` tags. Nothing about them is changed to
/// run here.
///
/// NOT thread-safe on its own: a `JSContext` must be used from one thread at a
/// time. `KhaytEngine` owns the serialisation; this type is deliberately the
/// thin, testable part.
public final class JSRuntime {
    private let context: JSContext
    private var lastException: String?

    /// Load `modules` in order, then `locales`, from `bundle`'s `JS` resource
    /// directory.
    ///
    /// `bundle` is optional rather than defaulted to `.module`: SPM generates
    /// that accessor as internal, so it cannot appear in a public signature.
    /// Nil means `BundledResources.javaScript`, which is a LOOKUP — where an
    /// assembled app actually keeps its resources — rather than the two
    /// hard-coded paths `Bundle.module` compiles down to. One of those is the
    /// build directory of the machine that compiled it, which is how both
    /// shipped 4.0 alphas crashed on launch everywhere but here.
    ///
    /// Locale files are loaded separately because they break the naming rule
    /// every other module follows: nine files all assign onto one global,
    /// `KhaytLocales`, keyed by language. They are Khayt's own translations,
    /// bundled rather than retyped so the two apps call the same thing by the
    /// same name — an app that invents its own word for "Owed" has invented a
    /// second vocabulary for one shop.
    public init(modules: [String], locales: [String] = [], bundle: Bundle? = nil) throws {
        let bundle = bundle ?? BundledResources.javaScript
        guard let context = JSContext() else {
            throw KhaytJSError.evaluationFailed("could not create a JavaScript context")
        }
        self.context = context
        context.exceptionHandler = { [weak self] _, value in
            self?.lastException = value?.toString() ?? "unknown JavaScript exception"
        }

        // ── JAVASCRIPTCORE HAS NO `URL`, AND A SHARED RULE NEEDS ONE ──────
        //
        // `URL` is a host object, not part of ECMAScript, so a plain `JSContext`
        // does not have it — Node and every browser do, which is why nothing
        // noticed until a module that uses it was bundled here.
        //
        // `lib/webcam.js` reads a host with `new URL(u).hostname` inside its
        // SSRF guard, and its `try/catch` turns the missing global into
        // `hostname === ''` — so `assertWebcamHostAllowed` refused every address
        // ever put to it. That fails CLOSED, which is the right direction and
        // still means no camera on this Mac would ever have drawn.
        //
        // THE PARSING IS FOUNDATION'S, NOT A SHIM'S. A hand-rolled URL parser is
        // a security component: `http://evil.com@192.168.1.50/` has to resolve
        // the way a browser resolves it, and getting that subtly wrong inside
        // the one guard that stops an SSRF is worse than not having it. So this
        // exposes `URLComponents` and the JS side only reads fields off it.
        let hostOf: @convention(block) (String) -> [String: Any]? = { raw in
            guard let parts = URLComponents(string: raw), let scheme = parts.scheme else { return nil }
            let host = (parts.host ?? "").lowercased()
            let proto = scheme.lowercased() + ":"
            let port = parts.port.map(String.init) ?? ""
            return ["hostname": host,
                    "protocol": proto,
                    "port": port,
                    "pathname": parts.path,
                    // CREDENTIALS, because `lib/base-url.js` refuses an address
                    // carrying them — they would be sent to, and logged by, the
                    // far end. Without these the check read `undefined ||
                    // undefined`, was always false, and silently passed every
                    // `https://user:pass@host` a shop could type.
                    "username": parts.user ?? "",
                    "password": parts.password ?? "",
                    // And `origin`, which the same module RETURNS as the
                    // normalised address. Absent, it returned the literal
                    // string "undefined" with the path glued to it, so a shop
                    // with its own endpoint would have had every request sent
                    // to a nonsense URL.
                    "origin": proto + "//" + host + (port.isEmpty ? "" : ":" + port)]
        }
        context.setObject(hostOf, forKeyedSubscript: "__khaytParseURL" as NSString)
        context.evaluateScript(#"""
        (function () {
          if (typeof globalThis.URL !== 'undefined') return;
          // Enough of the interface for what the shared modules read, and no
          // more. A field nobody uses is a field nobody has checked — and the
          // converse bit: bundling `base-url.js` added three readers
          // (`username`, `password`, `origin`) that were not here, so its
          // credentials check passed everything and its return value was the
          // string "undefined" with a path on the end. Add the field when the
          // reader arrives.
          function KhaytURL(input) {
            if (!(this instanceof KhaytURL)) return new KhaytURL(input);
            var parts = globalThis.__khaytParseURL(String(input));
            if (!parts || !parts.hostname) throw new TypeError('Invalid URL: ' + input);
            this.hostname = parts.hostname;
            this.protocol = parts.protocol;
            this.port = parts.port;
            this.pathname = parts.pathname;
            this.host = parts.port ? parts.hostname + ':' + parts.port : parts.hostname;
            this.href = String(input);
            this.username = parts.username || '';
            this.password = parts.password || '';
            this.origin = parts.origin || '';
          }
          KhaytURL.prototype.toString = function () { return this.href; };
          globalThis.URL = KhaytURL;
        })();
        """#)
        if let problem = lastException {
            throw KhaytJSError.evaluationFailed("installing URL: \(problem)")
        }

        for module in modules {
            guard let url = bundle.url(forResource: module, withExtension: "js", subdirectory: "JS") else {
                throw KhaytJSError.moduleMissing("\(module).js")
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            lastException = nil
            context.evaluateScript(source, withSourceURL: url)
            if let problem = lastException {
                throw KhaytJSError.evaluationFailed("loading \(module).js: \(problem)")
            }
            // A module that loaded without throwing but defined nothing is a
            // packaging mistake, and it would otherwise surface much later as a
            // confusing "undefined is not an object" from a call site.
            guard context.objectForKeyedSubscript(Self.globalName(for: module))?.isUndefined == false else {
                throw KhaytJSError.moduleMissing("\(module).js loaded but defined no global")
            }
        }

        for language in locales {
            let name = "locale-\(language)"
            guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "JS") else {
                throw KhaytJSError.moduleMissing("\(name).js")
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            lastException = nil
            context.evaluateScript(source, withSourceURL: url)
            if let problem = lastException {
                throw KhaytJSError.evaluationFailed("loading \(name).js: \(problem)")
            }
            guard let all = context.objectForKeyedSubscript("KhaytLocales"),
                  all.objectForKeyedSubscript(language)?.isUndefined == false else {
                throw KhaytJSError.moduleMissing("\(name).js loaded but defined no strings for \(language)")
            }
        }
    }

    /// `lib/payment-plan.js` → `KhaytPaymentPlan`. Mirrors each module's own
    /// `global.X = api` line; a module whose global does not follow the pattern
    /// is listed here explicitly rather than guessed at.
    static func globalName(for module: String) -> String {
        // A module whose file is named for what it produces rather than for
        // the global it assigns. Both of these predate the convention; a NEW
        // module should be named for its global instead, because this check is
        // the only thing that catches a module that loads and defines nothing.
        let exceptions = [// `print-file-parts.js` publishes `KhaytPrintParts` — the
                          // file says which parts, the global does not. Caught
                          // by this check the moment it was bundled, which is
                          // what the check is for.
                          "print-file-parts": "KhaytPrintParts",
                          // `stl-estimate.js` publishes `KhaytStl` — the file
                          // is named for the estimating, the global for the
                          // format. Caught by this check the moment it was
                          // bundled, which is what the check is for; the tests
                          // that needed it all failed at once and said why.
                          "stl-estimate": "KhaytStl",
                          "store-validate": "KhaytStoreValidate",
                          "pnl-report": "KhaytPnl",
                          // `thumbnail-extract.js` publishes `KhaytThumb`. Same
                          // shape as the two above and caught the same way: the
                          // module loaded, defined its global under another
                          // name, and every engine in the test suite refused to
                          // start — 214 failures from one missing entry, which
                          // is exactly the loud failure this check is for.
                          "thumbnail-extract": "KhaytThumb",
                          // `quote-followup.js` publishes `KhaytQuoteFollowUp`
                          // — a capital U that the hyphen does not carry, so
                          // the derived name misses by one letter.
                          "quote-followup": "KhaytQuoteFollowUp",
                          // `color-mix.js` publishes `KhaytColor` — the file is
                          // named for the mixing, the global for the subject.
                          "color-mix": "KhaytColor",
                          // `printer-poll-cache.js` publishes `KhaytPollCache` —
                          // the file says whose cache it is, the global does not.
                          "printer-poll-cache": "KhaytPollCache",
                          // `machine-pl.js` publishes `KhaytMachinePL` — the
                          // derived name capitalises only the first letter of
                          // each hyphenated part, so it misses the second L.
                          "machine-pl": "KhaytMachinePL",
                          // The converter's chain. Three of these are named for
                          // what they produce rather than for their global, and
                          // one of them — `mf-mesh` — is read under a THIRD name
                          // by two of its own callers, which had never mattered
                          // because both reached it through `require`.
                          "filament-mixer": "filamentMixer",
                          "full-spectrum": "fullSpectrum"]
        if let known = exceptions[module] { return known }
        let camel = module.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return "Khayt\(camel)"
    }

    /// Evaluate an expression and hand back the raw value.
    @discardableResult
    public func evaluate(_ script: String) throws -> JSValue {
        lastException = nil
        let value = context.evaluateScript(script)
        if let problem = lastException { throw KhaytJSError.evaluationFailed(problem) }
        guard let value else { throw KhaytJSError.unexpectedResult("no value") }
        return value
    }

    /// Call `object.method(args…)` and decode the result as `T`.
    ///
    /// Arguments and results cross as JSON, not as bridged objects. It is
    /// slower, and it means a shape change on either side is a decoding error
    /// here rather than a silently missing field somewhere downstream — which
    /// is the failure this codebase keeps having.
    public func call<T: Decodable>(_ object: String, _ method: String, _ args: [Encodable] = [], as type: T.Type) throws -> T {
        let encoder = JSONEncoder()
        let encoded = try args.map { arg -> String in
            let data = try encoder.encode(AnyEncodable(arg))
            return String(data: data, encoding: .utf8) ?? "null"
        }
        let call = "JSON.stringify(\(object).\(method)(\(encoded.joined(separator: ", "))))"
        let value = try evaluate(call)
        guard let json = value.toString(), json != "undefined", let data = json.data(using: .utf8) else {
            throw KhaytJSError.unexpectedResult("\(object).\(method) returned undefined")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Evaluate an expression with arguments substituted for `ARG0`, `ARG1`, …
    ///
    /// For the modules whose entry point takes one options object rather than
    /// positional arguments — `dashboardFacts({orders, machines, settings})` —
    /// and for the one that needs another MODULE passed in. Same JSON crossing
    /// as `call`, so a shape change is still a decoding error here.
    public func call2<T: Decodable>(_ expression: String, _ args: [JSONValue] = [],
                                    as type: T.Type) throws -> T {
        let encoder = JSONEncoder()
        var script = expression
        // HIGHEST INDEX FIRST. "ARG1" is a prefix of "ARG10", so substituting in
        // order turns ARG10 into the first argument's JSON followed by a stray
        // "0" — which reaches JavaScriptCore as `SyntaxError: Unexpected number
        // '0'`, from a script that reads perfectly well in the source. It sat
        // here unnoticed while no expression had ten arguments.
        for (i, arg) in args.enumerated().reversed() {
            let data = try encoder.encode(arg)
            script = script.replacingOccurrences(of: "ARG\(i)",
                                                 with: String(data: data, encoding: .utf8) ?? "null")
        }
        let value = try evaluate("JSON.stringify(\(script))")
        guard let json = value.toString(), json != "undefined", let data = json.data(using: .utf8) else {
            throw KhaytJSError.unexpectedResult(expression)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Read `object.property` and decode it as `T`. Same JSON crossing as
    /// `call`, for the modules that export data rather than functions.
    public func value<T: Decodable>(_ object: String, _ property: String, as type: T.Type) throws -> T {
        let js = try evaluate("JSON.stringify(\(object).\(property))")
        guard let json = js.toString(), json != "undefined", let data = json.data(using: .utf8) else {
            throw KhaytJSError.unexpectedResult("\(object).\(property) is undefined")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Type-erasing wrapper so heterogeneous arguments can be JSON-encoded.
struct AnyEncodable: Encodable {
    private let encodeTo: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeTo = wrapped.encode(to:) }
    func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}
