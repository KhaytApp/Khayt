import AppIntents
import Foundation

/// The button on a finished or failed print's Live Activity: move the job
/// on to post-processing, or put it back in the queue to print again — the
/// print alert's two buttons, on the Lock Screen.
///
/// Compiled into both the widget (which draws the button) and the app
/// (where a `LiveActivityIntent` runs). The move itself needs the app's
/// book and rules, so the app hands its handler in as it starts; in the
/// widget's process the handler is never set and never needed.
struct PrintActivityMoveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Move a finished print on"
    static let isDiscoverable = false

    @Parameter(title: "Machine") var machineId: String
    /// "post" or "reprint".
    @Parameter(title: "Move") var move: String

    init() {}
    init(machineId: String, move: String) {
        self.machineId = machineId
        self.move = move
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await PrintActivityActions.handler?(machineId, move)
        return .result()
    }
}

@MainActor
enum PrintActivityActions {
    /// Set by the app: make the move for the one job printing on a machine.
    static var handler: ((_ machineId: String, _ move: String) async -> Void)?
}
