import Foundation

/// Whether a job's time-lapse can be kept with the job, and under what name
/// (`lib/timelapse-attach.js timelapseAttach`, the rule the Windows/Linux
/// app's "Keep as proof" uses).
///
/// The rule decides; it never downloads. The copy is the app's
/// (`Shop.keepTimelapse`), which stops at `maxBytes` whatever the printer
/// said the size was.
extension KhaytEngine {

    public struct TimelapsePlan: Decodable, Sendable, Equatable {
        /// `attach` (copy it), `link` (keep it on the printer: too big, or of
        /// no stated size), `already` (it is one of the job's files), `none`.
        public let action: String
        /// attach: the file's name in `order-files/`. already: the kept file's.
        public let filename: String?
        /// attach: the `attachedFiles` entry, to be written with the size
        /// that was really read.
        public let row: JSONValue?
        /// attach, link: the most that may be kept.
        public let maxBytes: Double?
        /// link: `over-budget` or `size-unknown`.
        public let reason: String?
        /// What the printer says the video weighs (attach, link), or what was
        /// kept (already). The printer's word is a claim, not a limit.
        public let bytes: Double?
        /// The printer and the file in its camera folder; "" with no record.
        public let machineId: String?
        public let video: String?
    }

    /// - `order`: the job's record. Its `printerTimelapse` names the video.
    /// - `stamp`: names the copy; letters and digits (the caller's clock, in base 36).
    /// - `maxBytes`: nil for the rule's own ceiling (150 MB).
    public func timelapseKeepPlan(order: JSONValue, stamp: String, maxBytes: Double? = nil) throws -> TimelapsePlan {
        try runtime.call2("""
            (function (order, stamp, max) {
              var A = globalThis.KhaytTimelapseAttach;
              var o = order && typeof order === 'object' && !Array.isArray(order) ? order : {};
              var rec = o.printerTimelapse && typeof o.printerTimelapse === 'object' && !Array.isArray(o.printerTimelapse) ? o.printerTimelapse : null;
              if (!rec) return { action: 'none', machineId: '', video: '' };
              var opts = { machineId: rec.machineId, stamp: stamp };
              if (typeof max === 'number' && max > 0) opts.maxBytes = max;
              var p = A.timelapseAttach(o, rec, opts);
              var out = { action: p.action, machineId: rec.machineId == null ? '' : String(rec.machineId), video: rec.video == null ? '' : String(rec.video) };
              if (p.action === 'attach') { out.row = p.row; out.filename = p.row.filename; out.maxBytes = p.maxBytes; out.bytes = p.row.size; }
              if (p.action === 'link') {
                out.reason = p.reason;
                out.bytes = typeof p.bytes === 'number' ? p.bytes : null;
                out.maxBytes = typeof p.maxBytes === 'number' ? p.maxBytes : (typeof max === 'number' && max > 0 ? max : A.MAX_BYTES);
              }
              if (p.action === 'already') {
                var f = Array.isArray(o.attachedFiles) ? o.attachedFiles[p.index] : null;
                out.filename = f && typeof f.filename === 'string' ? f.filename : null;
                out.bytes = f && typeof f.size === 'number' ? f.size : null;
              }
              return out;
            })(ARG0, ARG1, ARG2)
            """, [order, .string(stamp), maxBytes.map(JSONValue.number) ?? .null], as: TimelapsePlan.self)
    }
}
