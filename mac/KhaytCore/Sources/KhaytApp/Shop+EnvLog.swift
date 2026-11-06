import Foundation
import KhaytCore

/// The workshop's temperature and humidity log (`envLogs`).
///
/// ── THE DESKTOP'S SHAPE, FIELD FOR FIELD ──────────────────────────────────
///
/// `{ id, timestamp, temperature, humidity, machineId, notes }`, written by
/// `lib/env-log.js entry` — the same call the desktop's Log button makes — so
/// a reading taken here is indistinguishable from one taken there, and sync
/// merges them record by record. The desktop lane froze that shape; nothing
/// here names a field of its own.
///
/// Settings › Operations holds it, gated as Settings is (`settings`/`edit`):
/// the desktop keeps it on its Settings page, so whoever may not change
/// Settings there may not log here either.
///
/// A delete is a delete of the record. The write chain leaves the tombstone
/// (`StoreWriter.recordDeletions`), so the reading does not come back with the
/// next sync. The desktop has no delete; a reading deleted here is gone there
/// too.
extension Shop {

    /// Whoever is here may add to or remove from the log.
    var mayEditEnvLog: Bool { canWrite && lockAllows("settings", "edit") }

    /// Log one reading. Returns the refusal's sentence, or nil when it landed.
    func logEnvironment(temperature: String, humidity: String, machineId: String?,
                        notes: String) async -> String? {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard source.build != nil else { return words.callIt("mac.move_sample") }
        do {
            if let refused = try await engine.envLogCheck(temperature: temperature, humidity: humidity) {
                return words.callIt(refused)
            }
            let record = try await engine.envLogEntry(temperature: temperature, humidity: humidity,
                                                      machineId: machineId, notes: notes,
                                                      id: Self.uid("ENV"), now: Date())
            guard case .object = record else { return words.callIt("env.need_value") }
            await write(as: .person("settings", "edit")) { root in
                var rows = Self.rows(root, "envLogs")
                rows.append(record)
                root["envLogs"] = .array(rows)
            }
            return writeProblem
        } catch {
            return said(error)
        }
    }

    /// Take one reading out of the log.
    func deleteEnvReading(_ id: String) async {
        guard !id.isEmpty else { return }
        await write(as: .person("settings", "edit")) { root in
            let rows = Self.rows(root, "envLogs")
            root["envLogs"] = .array(rows.filter { Self.recordId($0) != id })
        }
    }
}
