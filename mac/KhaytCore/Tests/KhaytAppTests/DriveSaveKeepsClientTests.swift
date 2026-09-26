import Foundation
import Testing
@testable import KhaytApp

/// Saving the Google Drive settings keeps the client id the shop typed, and
/// the pane says when Drive is not connected yet.
@MainActor
struct DriveSaveKeepsClientTests {
    @Test("Save passes the typed client id and secret on, and they are written")
    func saveKeepsClient() throws {
        let pane = try QuoteSheetStatusTests.source("CloudLibrarySettings.swift")
        #expect(pane.contains("clientId: draft.driveClientId, typedSecret: draft.driveSecret)"))
        #expect(pane.contains("mac.gdrive_not_connected"))
        let lib = try QuoteSheetStatusTests.source("CloudLibrary.swift")
        let save = try #require(lib.range(of: "func saveDriveLibrary("))
        let body = lib[save.lowerBound...].prefix(4000)
        #expect(body.contains("try await writeDrive(clientId: id"), "Save drops the client id again")
        #expect(body.contains("mac.gdrive_saved_connect"))
    }
}
