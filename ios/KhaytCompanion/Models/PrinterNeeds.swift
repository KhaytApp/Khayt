import Foundation

/// What a printer needs from a person, in the shared closed sets the apps
/// translate (#2612, #2613). The Mac works them out (`lib/printer-problems.js`
/// `problemsFor`, `lib/waiting-at-machine.js` `waiting`) and, once it serves
/// them on the live printer route, the phone reads them here. Nothing here
/// decides anything: the phone never re-derives a problem from raw printer
/// words, so it can never disagree with the Mac.
///
/// Screens for these are drawn in the iPhone Figma file ("Printer states ·
/// iPhone (Nov 21)") and wait for Turki's sign-off.

/// One problem, worst first: `problem.<code>` and `problem.action.<action>`
/// are the words.
struct PrinterProblem: Codable, Equatable, Sendable {
    let code: String
    let severity: String
    let action: String
    let source: String?
    /// The head (tool) a filament problem is on, when the printer said which.
    let head: Int?
    /// The printer's own message, control characters stripped, 200 characters at most.
    let message: String?
    /// A code to look the fault up by, when the catalogue has no meaning for it.
    let ref: String?

    static let severities = ["fatal", "serious", "common", "info"]
    var isBlocking: Bool { severity == "fatal" || severity == "serious" }
}

/// A reason the printer is waiting for a person, most urgent first.
struct WaitingReason: Codable, Equatable, Sendable {
    /// `filament-runout`, `printer-attention`, `print-to-take-off` or `bed-to-clear`.
    let reason: String
    /// Epoch milliseconds, as the rule gives it.
    let since: Double?

    static let reasons = ["filament-runout", "printer-attention", "print-to-take-off", "bed-to-clear"]
    var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// One row of a list from the wire, kept only when it decodes: a bad row
/// never empties the list, and never throws the whole printer away (the
/// lesson of `lastUpdated`'s two spellings).
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    func lossyList<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}
