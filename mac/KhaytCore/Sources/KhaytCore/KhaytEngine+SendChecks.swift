import Foundation

/// What to tell a shop before a file goes to a printer (C8):
/// `lib/send-checks.js sendChecks`, the closed list of findings, worst first.
extension KhaytEngine {

    public struct SendFinding: Decodable, Sendable, Equatable, Identifiable {
        public struct Want: Decodable, Sendable, Equatable {
            public let type: String?
            public let colour: String?
        }
        public struct Have: Decodable, Sendable, Equatable {
            public let material: String?
            public let colour: String?
        }
        public struct Size: Decodable, Sendable, Equatable {
            public let x: Double?
            public let y: Double?
            public let z: Double?
            public init(x: Double?, y: Double?, z: Double?) { self.x = x; self.y = y; self.z = z }
        }
        /// One of `KhaytSendChecks.CODES`.
        public let code: String
        /// `block` (the send is held), `warn` or `info`.
        public let severity: String
        /// The file's filament number (1-based), for the per-head findings.
        public let slot: Int?
        public let want: Want?
        public let have: Have?
        /// `sliced-for-other`: the printer and bed the file names.
        public let model: String?
        public let bed: Size?
        public let over: Size?
        public var id: String { code + ":" + String(slot ?? 0) }
        public var blocks: Bool { severity == "block" }
    }

    /// The findings for one file and one printer, and the size the bed rows
    /// were judged on.
    public struct SendCheck: Decodable, Sendable, Equatable {
        public let findings: [SendFinding]
        /// The models' placed size, when the file said: `x`, `y`, and `z` when
        /// it gave a height. Nil when nothing measured them.
        public let bounds: SendFinding.Size?
        /// `placed-extents` (the slicer's own object outlines: may hold the
        /// send) or `toolpath` (the moves, skirt and purge included: warns
        /// only). Nil with no bounds.
        public let boundsSource: String?
        public init(findings: [SendFinding] = [], bounds: SendFinding.Size? = nil, boundsSource: String? = nil) {
            self.findings = findings; self.bounds = bounds; self.boundsSource = boundsSource
        }
    }

    /// The findings for one file and one printer.
    ///
    /// `gcodeText` is the part of the file its slicer wrote its comments in
    /// (the head and the tail are enough); nil for a file whose text was not
    /// read, which then has no filament, sliced-for or bed findings.
    /// `wholeFile` says the text is the WHOLE file: only then may the bed be
    /// judged from the moves (`toolpath`), because half a file's moves are
    /// half a footprint. The slicer's own object list is read from whatever
    /// text there is. `bounds` overrides the reader (a test's measured size).
    /// `loaded` is the machine's loaded filaments (`loaded-colours` shape);
    /// nil or empty gives no filament findings. A missing input never
    /// invents a finding.
    public func sendCheck(fileName: String, gcodeText: String?, wholeFile: Bool = false, bounds: JSONValue? = nil,
                          machine: JSONValue, loaded: JSONValue?) throws -> SendCheck {
        try runtime.call2("""
            (function (name, text, bounds, machine, loaded, whole) {
              var G = globalThis.KhaytGcodeParse;
              var file = { name: name };
              var has = typeof text === 'string' && text.length > 0;
              if (has) {
                file.filaments = G.parseFilaments(text);
                file.header = G.parsePrinterHeader(text);
              }
              if (bounds) file.bounds = bounds;
              else if (has) {
                var b = globalThis.KhaytGcodePlacedExtents.placedExtents(text);
                if (b && (b.source === 'placed-extents' || whole === true)) file.bounds = b;
              }
              var fb = file.bounds || null;
              return {
                findings: globalThis.KhaytSendChecks.sendChecks(file, machine, Array.isArray(loaded) ? loaded : undefined),
                bounds: fb ? { x: fb.x, y: fb.y, z: fb.z == null ? null : fb.z } : null,
                boundsSource: fb && typeof fb.source === 'string' ? fb.source : null,
              };
            })(ARG0, ARG1, ARG2, ARG3, ARG4, ARG5)
            """, [.string(fileName), gcodeText.map(JSONValue.string) ?? .null, bounds ?? .null, machine, loaded ?? .null, .bool(wholeFile)],
            as: SendCheck.self)
    }

    /// The findings alone.
    public func sendChecks(fileName: String, gcodeText: String?, bounds: JSONValue?,
                           machine: JSONValue, loaded: JSONValue?) throws -> [SendFinding] {
        try sendCheck(fileName: fileName, gcodeText: gcodeText, bounds: bounds, machine: machine, loaded: loaded).findings
    }

    /// The vectors' own call, for the parity test: the file as the fixture
    /// gives it (`headerText` read by `parsePrinterHeader`), and a U1's
    /// `print_task_config` through `fromPrintTaskConfig`.
    /// `live` and `opts` are the bed-not-cleared vectors' (#2606): the poll's
    /// entry for the machine, and the send's options; absent, no bed finding.
    public func sendChecksVector(file: JSONValue, machine: JSONValue, loaded: JSONValue?,
                                 live: JSONValue? = nil, opts: JSONValue? = nil) throws -> JSONValue {
        try runtime.call2("""
            (function (c, machine, l, live, opts) {
              var f = Object.assign({}, c);
              if (f.headerText) f.header = globalThis.KhaytGcodeParse.parsePrinterHeader(f.headerText);
              var LC = globalThis.KhaytLoadedColours;
              return globalThis.KhaytSendChecks.sendChecks(f, machine, l ? (l.ptc ? LC.fromPrintTaskConfig(l.ptc) : l.loaded) : undefined,
                live === null ? undefined : live, opts === null ? undefined : opts);
            })(ARG0, ARG1, ARG2, ARG3, ARG4)
            """, [file, machine, loaded ?? .null, live ?? .null, opts ?? .null], as: JSONValue.self)
    }
}
