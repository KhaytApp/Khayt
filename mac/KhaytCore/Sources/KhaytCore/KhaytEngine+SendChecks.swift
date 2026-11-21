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

    /// The findings for one file and one printer.
    ///
    /// `gcodeText` is the part of the file its slicer wrote its comments in
    /// (the head and the tail are enough); nil for a file whose text was not
    /// read, which then has no filament or sliced-for findings. `bounds` is
    /// `{x, y, z, source}` when somebody measured the model; nil says nothing
    /// about the bed, as the rule requires. `loaded` is the machine's loaded
    /// filaments (`loaded-colours` shape); nil or empty gives no filament
    /// findings. A missing input never invents a finding.
    public func sendChecks(fileName: String, gcodeText: String?, bounds: JSONValue?,
                           machine: JSONValue, loaded: JSONValue?) throws -> [SendFinding] {
        try runtime.call2("""
            (function (name, text, bounds, machine, loaded) {
              var G = globalThis.KhaytGcodeParse;
              var file = { name: name };
              if (typeof text === 'string' && text) {
                file.filaments = G.parseFilaments(text);
                file.header = G.parsePrinterHeader(text);
              }
              if (bounds) file.bounds = bounds;
              return globalThis.KhaytSendChecks.sendChecks(file, machine, Array.isArray(loaded) ? loaded : undefined);
            })(ARG0, ARG1, ARG2, ARG3, ARG4)
            """, [.string(fileName), gcodeText.map(JSONValue.string) ?? .null, bounds ?? .null, machine, loaded ?? .null],
            as: [SendFinding].self)
    }

    /// The vectors' own call, for the parity test: the file as the fixture
    /// gives it (`headerText` read by `parsePrinterHeader`), and a U1's
    /// `print_task_config` through `fromPrintTaskConfig`.
    public func sendChecksVector(file: JSONValue, machine: JSONValue, loaded: JSONValue?) throws -> JSONValue {
        try runtime.call2("""
            (function (c, machine, l) {
              var f = Object.assign({}, c);
              if (f.headerText) f.header = globalThis.KhaytGcodeParse.parsePrinterHeader(f.headerText);
              var LC = globalThis.KhaytLoadedColours;
              return globalThis.KhaytSendChecks.sendChecks(f, machine, l ? (l.ptc ? LC.fromPrintTaskConfig(l.ptc) : l.loaded) : undefined);
            })(ARG0, ARG1, ARG2)
            """, [file, machine, loaded ?? .null], as: JSONValue.self)
    }
}
