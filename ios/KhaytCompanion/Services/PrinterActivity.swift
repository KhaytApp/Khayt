import Foundation
import KhaytCore

/// What a printer is doing, in the shared closed sets (C2, #2590):
///
///   link      unpaired | connecting | online | reconnecting | offline | unauthorized
///   activity  printing | paused | idle | finished | error | unknown   (nil unless online)
///
/// `lib/printer-activity.js` `machineStatus` decides it from the word the
/// printer last reported, the same file the Mac and the desktop run. The phone
/// used to decide with `state.contains("print")`, which read a PAUSED printer
/// as free and a PrusaLink "ATTENTION" or a Duet "halted" as idle.
struct PrinterStatus: Codable, Equatable, Sendable {
    let link: String
    let activity: String?
    var manual: Bool?
    var word: String?
    var cls: String?

    var isOnline: Bool { link == "online" }
    /// Working: the bed is not free. Paused is busy too, never free.
    var isBusy: Bool { activity == "printing" || activity == "paused" }
    /// Needs a person before the printer is free (error, failed, attention, halted).
    var needsPerson: Bool { activity == "error" }
    /// Not linked now (a failing poll, or a word that says so), as opposed to
    /// never paired.
    var isUnlinked: Bool { ["connecting", "reconnecting", "offline", "unauthorized"].contains(link) }
}

enum PrinterActivity {
    /// One small context holding only the shared rule. `machineStatus` is
    /// pure and quick, so a card can ask it synchronously; the lock is because
    /// a JSContext must be touched from one thread at a time.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var runtime: JSRuntime? = try? JSRuntime(modules: ["printer-activity"])

    /// `machine` and `entry` in the shapes the rule reads: the machine record
    /// (`printerApi.type`, `isOffline`) and its poll-cache entry
    /// (`state`, `progress`, `error`). Nil only when the rule did not load.
    static func status(machine: [String: JSONValue], entry: [String: JSONValue]?) -> PrinterStatus? {
        lock.lock(); defer { lock.unlock() }
        guard let runtime else { return nil }
        return try? runtime.call2("KhaytPrinterActivity.machineStatus(ARG0, ARG1)",
                                  [.object(machine), entry.map(JSONValue.object) ?? .null], as: PrinterStatus.self)
    }

    /// A reading as the Mac or the cloud sends it. A reading with no state and
    /// no error is a printer the Mac has not heard from (its poll failed), so
    /// it goes to the rule with no entry: `connecting`, never "stopped".
    static func status(hasPrinterApi: Bool, apiType: String?, state: String?, progress: Int?,
                       error: String?) -> PrinterStatus? {
        let type = apiType.flatMap { $0.isEmpty ? nil : $0 } ?? (hasPrinterApi ? "polled" : "none")
        let machine: [String: JSONValue] = ["printerApi": .object(["type": .string(type)])]
        let err = error.flatMap { $0.isEmpty ? nil : $0 }
        guard state != nil || err != nil else { return status(machine: machine, entry: nil) }
        var entry: [String: JSONValue] = [:]
        if let state { entry["state"] = .string(state) }
        if let progress { entry["progress"] = .number(Double(progress)) }
        if let err { entry["error"] = .string(err) }
        return status(machine: machine, entry: entry)
    }
}

extension ConnectionHealthState {
    /// The phone's own link to the shop, in C2's link set. While the phone
    /// cannot reach the shop it cannot vouch for any printer either, so a
    /// screen that shows a printer's link shows the worse of the two
    /// (`PrinterStatus.seen(through:)`).
    var link: String {
        switch self {
        case .unknown: return "connecting"
        case .connected: return "online"
        case .unreachable: return "offline"
        case .unauthorized, .pinTooShort: return "unauthorized"
        }
    }
}

extension PrinterStatus {
    /// The printer's status as the phone can know it: its own when the phone
    /// is linked to the shop, else the phone's link with no activity (the last
    /// word heard is history, not a state).
    func seen(through phone: ConnectionHealthState) -> PrinterStatus {
        phone == .connected ? self : PrinterStatus(link: phone.link, activity: nil)
    }
}

extension MachineLiveStatus {
    /// The shared state set for this reading (C2). Asked each time: the rule
    /// is a table lookup in a small context, and keeping it out of the model
    /// keeps `KhaytModels.swift` free of KhaytCore.
    var status: PrinterStatus? {
        PrinterActivity.status(hasPrinterApi: hasPrinterApi, apiType: apiType, state: state,
                               progress: progress, error: error)
    }

    /// Printing, by the shared rule (C2): every busy word each protocol
    /// writes ("Printing from SD", "BUSY", "processing", …), not only words
    /// that contain "print". A word in no table keeps the old reading.
    var isPrinting: Bool {
        if let s = status, s.isOnline, s.activity != "unknown" { return s.activity == "printing" }
        return (state ?? "").lowercased().contains("print") && !isPaused
    }
    /// Paused is a print still on the bed, not an ending — a pause raised a
    /// "Print finished" alert while `isPrinting` was the only question asked.
    /// It is busy: never offered as free (C2).
    var isPaused: Bool {
        if let s = status, s.isOnline, s.activity != "unknown" { return s.activity == "paused" }
        return (state ?? "").lowercased().contains("pause")
    }
    /// Working (printing or paused): the bed is not free.
    var isBusy: Bool { isPrinting || isPaused }
    /// A printer that needs a person before it is free, by its own word
    /// (error, failed, attention, halted), with or without an error message.
    var needsPerson: Bool { hasError || status?.needsPerson == true }
    /// A word that says the printer is not linked (OctoPrint "Offline",
    /// "Connecting", Duet "off"), read as the shared rule reads it.
    var saysUnlinked: Bool { status?.cls == "unlinked" }
}

extension ISO8601DateFormatter {
    /// The Mac's stamp, with or without fractional seconds.
    static func khaytLenient(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
