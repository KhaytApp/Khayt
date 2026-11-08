import Foundation

/// Blocking whole-book work — a decode, a cut, a write — off the main actor,
/// so a screen keeps drawing while a shop's book is read or written.
///
/// A global dispatch queue and a continuation, NOT `Task.detached`: blocking
/// work on the cooperative pool starves it (the same rule as KhaytCore's
/// `StoreWriter.updateOffMain`). Whatever comes back is handed to the caller,
/// which makes any change to its own `@MainActor` state itself.
enum OffMain {
    static func run<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                do { done.resume(returning: try work()) } catch { done.resume(throwing: error) }
            }
        }
    }
}
