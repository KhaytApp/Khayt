import Foundation

/// Run BLOCKING work — a socket read, a semaphore — on dispatch's threads and
/// await the answer, without ever occupying a cooperative-pool thread.
///
/// `Task.detached { blockingRead() }` looks like the same thing and is not:
/// it blocks one of the pool's threads, and the pool is one thread per core.
/// On a three-core CI runner three such blocks are the whole pool, and from
/// then on nothing in the test process that awaits can resume — including
/// the test that would have unblocked them. That is how #1713 hung "Mac app
/// tests" for six hours with no failure to read. Oct 2026.
func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { done in
        DispatchQueue.global(qos: .utility).async { done.resume(returning: work()) }
    }
}

/// The label of the dispatch queue the caller is running on.
func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}
