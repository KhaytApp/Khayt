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
    ///
    /// - `lastRun`, `acceptedFor`: this Mac's record; nil when it has none.
    /// - `hasBook`: a shop's book exists (an update, not a first install).
    /// - `floor`: where a Mac with a book and no record counts as coming
    ///   from: the last version that shipped without this sheet.
    /// - `gates`: the gate file's text; nil reads the bundled copy.
    public func launchGatePending(current: String, lastRun: String?, acceptedFor: String?, hasBook: Bool,
                                  floor: String, gates: String? = nil) throws -> [GatedRelease] {
        guard let text = gates ?? Self.bundledReleaseGates() else { return [] }
        var seen: [String: JSONValue] = [:]
        if let lastRun, !lastRun.isEmpty { seen["lastRun"] = .string(lastRun) }
        if let acceptedFor, !acceptedFor.isEmpty { seen["acceptedFor"] = .string(acceptedFor) }
        return try runtime.call2("""
            (function (current, seen, hasBook, floor, text) {
              var G; try { G = JSON.parse(text); } catch (e) { return []; }
              var mac = G && G.mac && typeof G.mac === 'object' ? G.mac : {};
              var L = globalThis.KhaytLaunchGate;
              var r = L.pending({ current: current, seen: seen, gates: mac, hasBook: hasBook, isNewer: L.isNewer, floor: floor });
              var said = {}, out = [];
              r.versions.slice().reverse().forEach(function (v) {
                var items = (Array.isArray(mac[v]) ? mac[v] : []).map(String).filter(function (x) {
                  if (said[x]) return false; said[x] = true; return true;
                });
                if (items.length) out.push({ version: v, items: items });
              });
              return out;
            })(ARG0, ARG1, ARG2, ARG3, ARG4)
            """, [.string(current), seen.isEmpty ? .null : .object(seen), .bool(hasBook), .string(floor), .string(text)],
            as: [GatedRelease].self)
    }
}
