import Foundation

/// The one thread a `KhaytEngine`'s JavaScriptCore ever runs on.
///
/// ── WHY THE ENGINE HAS A THREAD OF ITS OWN ────────────────────────────────
///
/// An actor with the default executor runs on Swift's cooperative pool: any of
/// a handful of threads, whichever is free, each with a 512 KB stack. And the
/// `JSContext` was created wherever `KhaytEngine()` was called. In the app that
/// is the main thread, so JavaScriptCore bound the VM's timers to the MAIN run
/// loop. Its garbage-collection and sweeping timers then fired there and took
/// the VM's lock. While the engine was busy on a pool thread with a 10,000-model
/// library, the main thread sat waiting for that lock.
///
/// The crash report that prompted this (Oct 14 2026: SIGSEGV inside
/// `JSON.parse`, under `KhaytEngine.categoryCounts` in `Shop.load`) shows
/// exactly that. The parsing thread is a cooperative pool thread, and thread 0
/// is parked in `JSLock::lock` from `JSRunLoopTimer::Manager::timerDidFireCallback`.
///
/// So the engine now owns one long-lived thread with an 8 MB stack and a run
/// loop of its own:
///
/// - the `JSContext` is created ON it, so its timers fire on it and never on
///   the main thread;
/// - every engine call runs on it, as the actor's executor, so the VM is only
///   ever entered from one thread (and that thread has the stack the JS
///   parser and the rules' own recursion are written for);
/// - jobs run in the order they arrive, as an actor's do.
///
/// Portable: `Thread` and `CFRunLoop` are the same on iOS.
final class EngineThread: SerialExecutor, @unchecked Sendable {

    /// 8 MB, the main thread's size. A pool thread's 512 KB is enough for
    /// today's inputs (JavaScriptCore throws cleanly near the bottom), but the
    /// rules recurse over a shop's data, and a book only grows.
    static let stackBytes = 8 << 20

    /// What the thread reads: its loop, set once before `init` returns, and
    /// `stopped`, set by a block run on the thread itself.
    private final class Loop: @unchecked Sendable {
        var loop: CFRunLoop?
        var stopped = false
    }

    private let state = Loop()
    private let thread: Thread

    init(name: String = "khayt.engine") {
        let started = DispatchSemaphore(value: 0)
        let state = state
        thread = Thread {
            state.loop = CFRunLoopGetCurrent()
            // A port, so the loop has a source and does not return at once
            // while no JavaScriptCore timer is scheduled.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            started.signal()
            while !state.stopped {
                autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 60, false) }
            }
        }
        thread.name = name
        thread.stackSize = Self.stackBytes
        thread.qualityOfService = .userInitiated
        thread.start()
        started.wait()
    }

    /// Run `block` on the thread, in order after everything already queued.
    func perform(_ block: @escaping @Sendable () -> Void) {
        guard let loop = state.loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    /// Run `body` on the thread and wait for it. For the engine's own
    /// initialiser, which is never itself on this thread.
    func sync<T>(_ body: @escaping () throws -> T) throws -> T {
        precondition(!isCurrent, "EngineThread.sync from its own thread")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        nonisolated(unsafe) let work = body
        perform {
            result = Result { try work() }
            done.signal()
        }
        done.wait()
        return try result!.get()
    }

    /// Let the thread finish once what is already queued has run.
    func stop() {
        let state = state
        perform {
            state.stopped = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    // MARK: SerialExecutor

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let me = asUnownedSerialExecutor()
        perform { job.runSynchronously(on: me) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// True on the engine's own thread.
    var isCurrent: Bool { Thread.current == thread }
}
