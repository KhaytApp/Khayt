import Foundation
import KhaytCore

/// A copy of the book to give somebody else.
///
/// Not a backup. A backup stays on this Mac and carries the shop's credentials
/// so that restoring it puts a working shop back; an export is a file that
/// leaves — to an accountant, to a spreadsheet, to a support thread — and a
/// credential in it is a credential in somebody's Downloads folder forever.
///
/// So there is exactly one way to build one here, and it redacts. The list of
/// what counts as a credential is `lib/store.js`'s, not a Swift copy: it is
/// data-driven over the shipping and BNPL providers precisely so that adding a
/// carrier does not silently export the next one's key, and a hand-kept second
/// list would lose that the first time somebody added a provider.
///
/// Two things are then done that the Electron app has no need to do, because
/// what this app holds is not what the renderer holds:
///
/// - **Main-owned keys are dropped.** `printerCompletions` is on disk here and
///   never reaches the renderer, so a Khayt export does not contain it. It is
///   the printer poll's own working history and belongs to this machine.
/// - **Anything still encrypted is masked.** The store's secrets are `__enc__`
///   ciphertext rather than plaintext, so a field the redaction list has not
///   heard of leaves as ciphertext rather than as a key. That is far better
///   than plaintext and still not good enough to hand over, and it is the one
///   check that does not depend on a list being complete.
@MainActor
enum Export {

    /// Khayt's own name for the file: the shop's date, and nothing else.
    static func filename(_ day: Date = Date()) -> String {
        "khayt-" + Shop.today(day) + ".json"
    }

    /// Build the file. Returns the bytes; writing them is the caller's.
    static func payload(from store: [String: JSONValue], engine: KhaytEngine) async throws -> Data {
        var source = store
        for key in Restore.mainOwnedKeys { source[key] = nil }
        let redacted = try await engine.redactedExport(source)
        let encoder = JSONEncoder()
        // Two spaces and a stable key order, which is `JSON.stringify(x, null, 2)`
        // plus the ordering a Swift dictionary cannot promise on its own. A file
        // a person is going to open in a text editor.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(masked(redacted))
    }

    /// Replace every value that is still `__enc__` ciphertext with the mask.
    ///
    /// The backstop. `redactSettingsForExport` knows the fields it knows; this
    /// knows the SHAPE of a secret at rest, so a credential added to the store
    /// and not yet to that list leaves as `__KHAYT_MASKED__` rather than as
    /// ciphertext with the shop's Keychain one bad day away from opening it.
    static func masked(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s):
            return s.hasPrefix("__enc__") ? .string(Restore.secretMask) : value
        case .object(let o):
            return .object(o.mapValues(masked))
        case .array(let a):
            return .array(a.map(masked))
        default:
            return value
        }
    }

    static func masked(_ object: [String: JSONValue]) -> [String: JSONValue] {
        object.mapValues(masked)
    }
}
