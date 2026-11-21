import Foundation

/// What each printer's state chip shows (C2): `lib/printer-activity.js`
/// `chip`, the six values every screen reads with `paused` told apart.
extension KhaytEngine {

    /// The seven chip states, in the frame's order.
    public enum MachineChip: String, CaseIterable, Sendable {
        case printing, paused, idle, reconnecting, unknown, error, offline

        /// Busy means never offered as free: a paused printer is busy.
        public var busy: Bool { self == .printing || self == .paused }
    }

    /// machine id → chip, for every machine Khayt polls. A machine with no
    /// connection (`unpaired`) has no chip: nothing was asked, so nothing is
    /// claimed. A value outside the closed set is left out, not guessed.
    public func machineChips(machines: [JSONValue], cache: [String: JSONValue]) throws -> [String: MachineChip] {
        let raw = try runtime.call2("""
            (function (machines, cache) {
              var PA = KhaytPrinterActivity, out = {};
              (machines || []).forEach(function (m) {
                if (!m || !m.id) return;
                var entry = cache ? cache[m.id] : undefined;
                var status = PA.machineStatus(m, entry);
                if (status.link === 'unpaired') return;
                out[m.id] = PA.chip(status, entry);
              });
              return out;
            })(ARG0, ARG1)
            """, [.array(machines), .object(cache)], as: [String: String].self)
        return raw.compactMapValues(MachineChip.init(rawValue:))
    }
}
