import Foundation

/// What a Bambu printer says it is doing — ported to Swift.
///
/// The transport is each app's own: Node sockets there, `NWConnection` here.
/// The MEANING was the shared part, because a printer reported as Idle in one
/// app and Printing in the other is the bug shared rules exist to prevent —
/// and now it is one rule held to the other by a parity test instead.
public enum BambuReport {

    /// Bambu's `gcode_state`, as a label matching the other printer types.
    ///
    /// An unknown state falls back to the raw word rather than to "Unknown": a
    /// firmware that invents a state is telling the shop something, and
    /// swallowing it would report a printer as fine when it is not. An EMPTY
    /// state becomes "Connected", which is the honest reading of a printer
    /// that answered without saying what it is doing.
    public static func stateLabel(_ state: String?) -> String {
        if case .string(let s) = label(of: state.map(JSONValue.string) ?? .null) { return s }
        return state ?? ""
    }

    private static let labels = ["IDLE": "Idle", "PREPARE": "Preparing", "RUNNING": "Printing",
                                 "PAUSE": "Paused", "FINISH": "Finished", "FAILED": "Failed",
                                 "SLICING": "Slicing"]

    /// The same, over whatever the printer actually sent.
    ///
    /// ── AND IT CAN COME BACK NOT-A-STRING ─────────────────────────────────
    ///
    /// `map[String(s || '').toUpperCase()] || (s || 'Connected')` — so a
    /// `gcode_state` of `123` misses the map and the expression yields the
    /// NUMBER 123, which is then what `state` holds. A Swift port that always
    /// returned a `String` would differ from the app's own behaviour, where
    /// `PrinterStatus.state` is a `String` and a numeric one fails the decode
    /// and blanks the printer entirely.
    ///
    /// Reproduced rather than tidied: whether that decode should be made
    /// forgiving is a question about the status shape, not something to settle
    /// silently inside a port. The parity test pins it.
    private static func label(of raw: JSONValue?) -> JSONValue {
        let key = JSSemantics.truthy(raw) ? JSSemantics.text(raw).uppercased() : ""
        if let known = labels[key] { return .string(known) }
        return JSSemantics.truthy(raw) ? (raw ?? .string("Connected")) : .string("Connected")
    }

    /// One `device/{serial}/report` payload, as the common status shape.
    ///
    /// Nil for anything that is not a full snapshot. Bambu sends partial
    /// deltas constantly, and only a "pushall" carries the fields a screen is
    /// drawn from — a delta read as a report would blank the progress bar
    /// several times a second.
    public static func parse(_ payload: String) -> JSONValue? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONValue.decode(JSONValue.self, from: data) else { return nil }
        return parse(value: root)
    }

    /// The same, over a report already parsed — the held state a persistent
    /// connection keeps (`merge`).
    public static func parse(value root: JSONValue) -> JSONValue? {
        guard case .object(let obj) = root,
              case .object(let print)? = obj["print"]
        else { return nil }
        // A snapshot says at least one of these. A delta says none of them.
        guard print["gcode_state"] != nil || print["mc_percent"] != nil
                || print["subtask_name"] != nil else { return nil }

        var out: [String: JSONValue] = [
            "ok": .bool(true),
            "state": label(of: print["gcode_state"]),
            // Only a NUMBER counts. A string "50" is not a percentage this
            // app will draw, and the original checks the type rather than
            // coercing — so a firmware sending text reads as zero, visibly,
            // instead of as a plausible figure nobody questions.
            "progress": .number(number(print["mc_percent"]) ?? 0),
            // `a || b || ''` — the VALUE, not a string. A `subtask_name` of 5
            // comes back as the number 5, for the same reason `state` can.
            "filename": firstTruthy(print["subtask_name"], print["gcode_file"]),
            "type": .string("bambu"),
        ]
        // Minutes on the wire, seconds everywhere in this app.
        out["timeRemaining"] = number(print["mc_remaining_time"]).map { .number($0 * 60) } ?? .null
        out["tempNozzle"] = number(print["nozzle_temper"]).map(JSONValue.number) ?? .null
        out["tempBed"] = number(print["bed_temper"]).map(JSONValue.number) ?? .null
        out["layer"] = number(print["layer_num"]).map(JSONValue.number) ?? .null
        out["totalLayers"] = number(print["total_layer_num"]).map(JSONValue.number) ?? .null
        return .object(out)
    }

    // MARK: - Holding the state across deltas

    /// `lib/bambu-report.js` `MERGE_DEPTH`.
    public static let mergeDepth = 32
    private static let forbiddenKeys: Set<String> = ["__proto__", "constructor", "prototype"]

    /// Fold one report into the state held from the reports before it —
    /// `mergeReport` in `lib/bambu-report.js`, whose header has the reasons.
    ///
    /// A P1 sends only what changed (OpenBambuAPI `mqtt.md`, `pushing.pushall`),
    /// so a connection held open has to remember the last full report and lay
    /// each delta over it, as ha-bambulab does (`models.py` `print_update`).
    /// Only `print` merges; objects merge by key, arrays and everything else
    /// are replaced; a message with no `print` object returns `held` as it was.
    /// `BambuReportParityTests` holds this to the JavaScript.
    public static func merge(_ held: JSONValue?, _ payload: String) -> JSONValue? {
        guard let data = payload.data(using: .utf8),
              let message = try? JSONValue.decode(JSONValue.self, from: data)
        else { return held }
        return merge(held, message: message)
    }

    public static func merge(_ held: JSONValue?, message: JSONValue) -> JSONValue? {
        guard case .object(let obj) = message, case .object(let delta)? = obj["print"] else { return held }
        var base: [String: JSONValue] = [:]
        if case .object(let h)? = held, case .object(let p)? = h["print"] { base = p }
        return .object(["print": .object(mergeInto(base, delta, depth: 1))])
    }

    private static func mergeInto(_ base: [String: JSONValue], _ delta: [String: JSONValue],
                                  depth: Int) -> [String: JSONValue] {
        var out = base.filter { !forbiddenKeys.contains($0.key) }
        for (key, next) in delta where !forbiddenKeys.contains(key) {
            if depth < mergeDepth, case .object(let n) = next, case .object(let was)? = out[key] {
                out[key] = .object(mergeInto(was, n, depth: depth + 1))
            } else {
                out[key] = next
            }
        }
        return out
    }

    /// `typeof x === 'number'` — the type, not a coercion.
    private static func number(_ value: JSONValue?) -> Double? {
        if case .number(let n)? = value { return n }
        return nil
    }

    /// The original's `a || b || ''` chain, keeping whatever type wins it.
    private static func firstTruthy(_ a: JSONValue?, _ b: JSONValue?) -> JSONValue {
        if JSSemantics.truthy(a) { return a ?? .string("") }
        if JSSemantics.truthy(b) { return b ?? .string("") }
        return .string("")
    }
}
