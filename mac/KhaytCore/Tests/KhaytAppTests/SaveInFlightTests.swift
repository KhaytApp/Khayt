import Foundation
import Testing

/// A sheet whose save no longer holds the window must not take a second click.
///
/// While a save wrote the book synchronously, the click that started it held
/// the main thread until the sheet had already been told to close, so a second
/// click never reached a live Save button. Written on the chain (#1866), the
/// window keeps drawing for the whole write and the reload after it — and a
/// second click on Save for a NEW message template wrote a second template
/// under another id (`saveTemplate` mints the id per call). The pause sheet's
/// Return wrote the pause twice, the second over the first's `pausedAt`.
/// A new location, operator or supplier mints its id inside the save, so a
/// second click there made a second record too.
///
/// A view cannot be clicked from here, so this reads the source: each of these
/// sheets keeps a `saving` flag, refuses a second start while it is set, and
/// greys its button out.
struct SaveInFlightTests {

    static func source(_ file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(file)"), encoding: .utf8)
    }

    @Test("a sheet whose save is off the main thread takes one save at a time",
          arguments: ["TemplateSheet.swift", "PauseSheet.swift", "LocationsSection.swift",
                     "Operators.swift", "SupplierSheet.swift"])
    func oneSaveAtATime(file: String) throws {
        let text = try Self.source(file)
        #expect(text.contains("@State private var saving = false"), "\(file) has no in-flight flag")
        #expect(text.contains("guard !saving else { return }"), "\(file) starts a second save")
        #expect(text.contains(".disabled(saving"), "\(file) leaves its button live during the save")
        // Cleared once the write is back, success or not, or a failed save
        // leaves the sheet with a button that never comes back.
        #expect(text.contains("saving = false"), "\(file) never lets the button back")
    }
}
