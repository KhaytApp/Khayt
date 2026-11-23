import Foundation

/// The "Before you update" items this Mac has not read yet, at the first
/// start after a version change (`lib/launch-gate.js pending`, the rule the
/// Windows/Linux app's first-launch gate uses; Mac file page 28, frame B).
///
/// Which versions are gated and what each says is `lib/release-gates.json`,
/// generated from the CHANGELOG at the cut; the Mac's versions are its `mac`
/// map. What this Mac last ran is the caller's to keep: per Mac, never in the
/// book, which syncs.
extension KhaytEngine {

    /// One gated release and what the shop should know about it.
    public struct GatedRelease: Decodable, Sendable, Equatable, Identifiable {
        public let version: String
        public let items: [String]
        public var id: String { version }
        public init(version: String, items: [String]) { self.version = version; self.items = items }
    }

    /// The bundled gate file's text, or nil when the bundle has none.
    public static func bundledReleaseGates(bundle: Bundle? = nil) -> String? {
        let resources = bundle ?? BundledResources.javaScript
        guard let url = resources.url(forResource: "release-gates", withExtension: "json", subdirectory: "JS") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The gated releases after the one this Mac last ran, up to and
    /// including `current`, NEWEST FIRST, each item once (under the newest
    /// release that says it). Empty when there is nothing to read: the same
    /// build, an older one, a new install, or releases with no items.
    /// THROWS when the gate file is missing or not one: that is not "nothing".
    ///
    /// - `lastRun`, `acceptedFor`: this Mac's record; nil when it has none.
    /// - `hasBook`: a shop's book exists (an update, not a first install).
    /// - `floor`: where a Mac with a book and no record counts as coming
    ///   from: the last version that shipped without this sheet.
    /// - `gates`: the gate file's text; nil reads the bundled copy.
    /// - `language`: the shop's language. Each item is said in it when the
    ///   file has it (`i18n.mac`, one array per language, index for index
    ///   with the English), else in English: per item, never all or nothing.
    ///   "Said once" is still judged on the English text.
    public func launchGatePending(current: String, lastRun: String?, acceptedFor: String?, hasBook: Bool,
                                  floor: String, gates: String? = nil, language: String = "en") throws -> [GatedRelease] {
        // No gate file, or one that is not what the writer makes, is an
        // ERROR, not "nothing to read": the caller must not conclude this
        // Mac has read anything.
        guard let text = gates ?? Self.bundledReleaseGates() else { throw KhaytJSError.moduleMissing("release-gates.json") }
        var seen: [String: JSONValue] = [:]
        if let lastRun, !lastRun.isEmpty { seen["lastRun"] = .string(lastRun) }
        if let acceptedFor, !acceptedFor.isEmpty { seen["acceptedFor"] = .string(acceptedFor) }
        return try runtime.call2("""
            (function (current, seen, hasBook, floor, text, lang) {
              var G = JSON.parse(text);
              if (!G || typeof G !== 'object' || !G.mac || typeof G.mac !== 'object' || Array.isArray(G.mac)) throw new Error('release-gates.json has no mac map');
              var mac = G.mac;
              var L = globalThis.KhaytLaunchGate;
              var r = L.pending({ current: current, seen: seen, gates: mac, hasBook: hasBook, isNewer: L.isNewer, floor: floor });
              var words = G.i18n && typeof G.i18n === 'object' && G.i18n.mac && typeof G.i18n.mac === 'object' ? G.i18n.mac : null;
              var said = {}, out = [];
              r.versions.slice().reverse().forEach(function (v) {
                var en = (Array.isArray(mac[v]) ? mac[v] : []).map(String);
                // The rule's own reading of a translation: an array of another length is not trusted at all.
                var tr = words ? L.translated(words, v, lang, en.length) : null;
                var items = [];
                en.forEach(function (x, i) {
                  if (said[x]) return; said[x] = true;
                  items.push(tr && typeof tr[i] === 'string' && tr[i].trim() ? tr[i] : x);
                });
                if (items.length) out.push({ version: v, items: items });
              });
              return out;
            })(ARG0, ARG1, ARG2, ARG3, ARG4, ARG5)
            """, [.string(current), seen.isEmpty ? .null : .object(seen), .bool(hasBook), .string(floor), .string(text),
                  .string(language)],
            as: [GatedRelease].self)
    }

    /// <0, 0 or >0 as `a` is older than, the same as, or newer than `b`
    /// (`KhaytLaunchGate.compareVersions`: beta.9 < beta.10 < the release).
    public func compareVersions(_ a: String, _ b: String) throws -> Int {
        try runtime.call2("globalThis.KhaytLaunchGate.compareVersions(ARG0, ARG1)", [.string(a), .string(b)], as: Int.self)
    }
}
