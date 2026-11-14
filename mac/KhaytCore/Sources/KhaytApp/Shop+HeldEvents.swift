import Foundation
import KhaytCore

/// Held shop alerts survive a quit, SEALED.
///
/// `pendingEvents` (Shop+Photos.swift) is what could not reach the phones when
/// it happened: the cloud was locked here, or the post failed. It lived in
/// memory only, so quitting the app — or an update relaunching it — dropped a
/// print-finished alert that had been waiting for the Wi-Fi to come back
/// (push review, Nov 13: "keep them across quit, sealed").
///
/// A held alert carries a job's title, a customer's name and a file name, so
/// it is never written in the clear: the list is sealed with the book's own
/// Keychain key (`Secrets.seal`, OSCrypt, the same as any credential in the
/// book) and kept in this Mac's UserDefaults under the book's path. A list
/// that cannot be sealed is NOT written — the alerts stay in memory for this
/// run, which is what they did before. The sample book keeps nothing.
///
/// Read back when that book is watched again; anything past the six-hour
/// limit is dropped on the way in, and the limits (`pendingLimit`,
/// `pendingFor`) and the duplicate check are `queueEvent`'s.
@MainActor
extension Shop {

    static let heldEventsKey = "mac.heldShopEvents"

    /// One held alert, as it is sealed.
    struct HeldEvent: Codable, Equatable {
        var kind: String
        var at: String
        var payload: [String: JSONValue]
        var since: Date
        var id: String?

        init(_ e: PendingEvent) {
            kind = e.kind; at = e.at; payload = e.payload; since = e.since; id = e.id
        }
        var pending: PendingEvent { PendingEvent(kind: kind, at: at, payload: payload, since: since, id: id) }
    }

    /// The plaintext that gets sealed: the book it belongs to, and the list.
    struct HeldEvents: Codable, Equatable {
        var book: String
        var events: [HeldEvent]
    }

    /// Write what is held now, sealed. Called on every change to the list;
    /// a later call supersedes an earlier one still sealing.
    func keepHeldEvents() {
        guard let build = source.build, let defaults = heldEventsDefaults else { return }
        heldEventsGeneration += 1
        let generation = heldEventsGeneration
        let book = build.storeURL.path
        let held = HeldEvents(book: book, events: pendingEvents.map(HeldEvent.init))
        Task { @MainActor [weak self] in
            let sealed: String? = held.events.isEmpty ? nil : await Self.sealHeld(held, build: build)
            guard let self, generation == self.heldEventsGeneration else { return }
            var all = defaults.dictionary(forKey: Self.heldEventsKey) as? [String: String] ?? [:]
            // Nothing held, or nothing that could be sealed: nothing on disk.
            if let sealed { all[book] = sealed } else { all.removeValue(forKey: book) }
            defaults.set(all, forKey: Self.heldEventsKey)
        }
    }

    /// Read back what this book held when the app last ran, and hold it again.
    func restoreHeldEvents(now: Date = Date()) async {
        guard let build = source.build, let defaults = heldEventsDefaults else { return }
        let book = build.storeURL.path
        guard let all = defaults.dictionary(forKey: Self.heldEventsKey) as? [String: String],
              let sealed = all[book],
              let held = await Self.openHeld(sealed, build: build),
              held.book == book else { return }
        for e in held.events where now.timeIntervalSince(e.since) <= Self.pendingFor {
            queueEvent(e.pending)
        }
        flushPendingEvents(force: true, now: now)
    }

    nonisolated static func sealHeld(_ held: HeldEvents, build: StoreReader.Build) async -> String? {
        guard let data = try? JSONEncoder().encode(held),
              let text = String(data: data, encoding: .utf8),
              let sealed = try? await Secrets.seal(text, for: build),
              sealed.hasPrefix(SafeStorage.marker) else { return nil }
        return sealed
    }

    nonisolated static func openHeld(_ sealed: String, build: StoreReader.Build) async -> HeldEvents? {
        // Only ever a sealed value: anything else was not written by this app.
        guard sealed.hasPrefix(SafeStorage.marker),
              let text = try? await Secrets.open(sealed, for: build) else { return nil }
        return try? JSONDecoder().decode(HeldEvents.self, from: Data(text.utf8))
    }
}
