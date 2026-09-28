import Foundation
import KhaytCore

/// What each print drew from the wall, added up from its smart plug.
///
/// ── THE RULES ARE NOT HERE ────────────────────────────────────────────────
///
/// `lib/print-energy.js` owns them: the trapezoid between readings, the gap
/// that is never bridged, the plug shared by two printers that is never
/// metered, and the job a print belongs to (the finish photo's own rule, so a
/// photo and a power bill cannot land on different jobs). This holds the
/// memory the rule is handed back each reading, and keeps it across a restart.
///
/// ── WHEN IT READS ─────────────────────────────────────────────────────────
///
/// On the plug poll (`Shop.plugTick`, every minute), for a watched printer
/// with a plug that reports watts. It never ENDS a print itself: the finish
/// seam (`Shop.printFinished`) does, off the same edge the photo uses, and
/// takes the reading then.
///
/// ── A PRINT SPANNING A RESTART ────────────────────────────────────────────
///
/// The memory is saved after every reading (`save`), by book, so a print that
/// is still running when the app is quit resumes on the next launch. The time
/// the app was closed is a GAP — counted, never invented — and the reading's
/// coverage says how much of the print was metered.
@MainActor
final class EnergyMeter {

    /// `{ [machineId]: meter }` — the rule's own bookkeeping.
    private(set) var memo: JSONValue = .object([:])

    /// A failed or cancelled print's reading, kept for the waste entry the
    /// shop may log against it. In memory only: a failure logged after a
    /// restart is costed at the machine's wattage instead.
    struct Attempt: Equatable, Sendable {
        let orderId: String?
        let reading: KhaytEngine.EnergyReading
        let at: Date
    }
    private(set) var attempts: [String: Attempt] = [:]

    /// Where the memory lives between launches. Seams, so a test can hold it.
    let load: () -> JSONValue?
    let save: (JSONValue) -> Void

    init(load: @escaping () -> JSONValue? = { nil }, save: @escaping (JSONValue) -> Void = { _ in }) {
        self.load = load
        self.save = save
        if let saved = load() { memo = saved }
    }

    /// Persisted in the user defaults, per book — machine ids are a book's own.
    static func defaults(book: URL) -> EnergyMeter {
        let key = "mac.energyMeters." + book.standardizedFileURL.path
        return EnergyMeter(load: {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }, save: { memo in
            if let data = try? JSONEncoder().encode(memo) { UserDefaults.standard.set(data, forKey: key) }
        })
    }

    /// Fold one plug reading in. `live` is the printer's status-cache entry
    /// (state and file); nil — never heard from — reads nothing.
    func observe(_ machineId: String, watts: Double?, live: JSONValue?, shared: Bool,
                 now: Date, engine: KhaytEngine) async {
        guard case .object(let o)? = live else { return }
        let sample: JSONValue = .object([
            "at": .number(now.timeIntervalSince1970 * 1000),
            "watts": watts.map(JSONValue.number) ?? .null,
            "state": o["state"] ?? .string(""),
            "filename": o["filename"] ?? .string(""),
        ])
        guard let t = try? await engine.energyTick(memo: memo, machineId: machineId,
                                                   sample: sample, shared: shared) else { return }
        memo = t.memo
        save(memo)
    }

    /// The end of a print: take its reading out of the memory.
    func take(_ machineId: String, engine: KhaytEngine) async -> KhaytEngine.EnergyReading? {
        guard let t = try? await engine.energyTake(memo: memo, machineId: machineId) else { return nil }
        memo = t.memo
        save(memo)
        return t.reading
    }

    /// Keep a failed attempt's reading for the waste entry.
    func remember(_ machineId: String, _ attempt: Attempt) { attempts[machineId] = attempt }

    /// The failed attempt's reading for this job, if it is recent and its own.
    func attempt(for orderId: String, now: Date = Date()) -> KhaytEngine.EnergyReading? {
        attempts.values.first {
            $0.orderId == orderId && now.timeIntervalSince($0.at) < 24 * 3600
        }?.reading
    }

    /// The attempt has been written onto a waste row: forget it.
    ///
    /// `attempt(for:)` only looks, so a reading used by one waste row was
    /// still there for the next — a print cancelled at 40% (300 Wh) put its
    /// 300 Wh on every failure logged against the job for a day. Called AFTER
    /// the row is saved, because the store write re-runs its change when the
    /// book moved underneath it, and a reading consumed on the first run would
    /// be missing from the second.
    func consumeAttempt(for orderId: String) {
        for (machineId, kept) in attempts where kept.orderId == orderId {
            attempts[machineId] = nil
        }
    }
}
