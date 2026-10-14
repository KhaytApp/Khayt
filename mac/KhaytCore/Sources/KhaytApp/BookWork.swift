import Foundation

/// Blocking work on the whole book — decoding 15 MB of JSON, ten thousand
/// library records, a folder to the Trash — off the main thread.
///
/// A shop's book with 9,802 models is 15 MB, and decoding it took the main
/// thread for one to three seconds every time anything reloaded it: a delete
/// froze the window while it was read back (`LibraryEditPerfTests`).
///
/// A dispatch queue and a continuation, NOT `Task.detached`: this blocks for
/// whole seconds, and blocking on the cooperative pool starves it — three
/// threads on a CI runner, and every `await` in the process waits (see
/// `PinWork`, and the swift-pool-starvation note in the tests).
enum BookWork {
    static let queue = DispatchQueue(label: "khayt.book-work", qos: .userInitiated,
                                     attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            queue.async {
                do { done.resume(returning: try work()) } catch { done.resume(throwing: error) }
            }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: work()) }
        }
    }
}
