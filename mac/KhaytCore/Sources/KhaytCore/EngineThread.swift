import Foundation

/// The threads a `KhaytEngine`'s JavaScriptCore ever runs on.
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
/// So an engine runs on a long-lived thread with an 8 MB stack and a run loop
/// of its own:
///
/// - the `JSContext` is created ON it, so its timers fire on it and never on
///   the main thread;
/// - every engine call runs on it, as the actor's executor, so the VM is only
///   ever entered from that one thread (and the thread has the stack the JS
///   parser and the rules' own recursion are written for);
/// - the context is let go on it too (see `KhaytEngine.deinit`);
/// - jobs run in the order they arrive, as an actor's do.
///
/// ── AND WHY THE THREADS ARE SHARED, A FEW FOR THE WHOLE PROCESS ───────────
///
/// The first version (#1867) gave EVERY engine a thread of its own, started in
/// `init` and stopped in `deinit`. Nothing leaked — a dropped engine's thread
/// did end — but the number of threads became the number of live engines, and
/// nothing bounds that. The test bundle keeps hundreds alive at once (a test
/// holds its engine while it queues for the main actor): measured on a full
/// `swift test`, the process peaked at 1,449 threads (one sample: 621 of 759
/// were `khayt.engine`). Every engine call that used to share the cooperative
/// pool's few threads had a runnable thread of its own, so on CI's three cores
/// hundreds of them competed with the main thread. And the main thread blocks
/// in `sync` while its engine's context is built, on a semaphore that lends
/// that thread none of its priority: in one local run those waits added up to
/// 113 s, the longest 3.7 s. The LAN server answers through the main actor,
/// and its tests started getting no answer after twenty minutes on CI
/// (Oct 15 2026). With the shared threads, the same run peaked at 587 threads
/// and the longest wait was 0.2 s.
///
/// So engines share a fixed set of `poolSize` threads, made the first time
/// they are wanted and kept for the life of the process. A new engine joins
/// the one with the least waiting work. Each thread is serial and FIFO, so an
/// engine's calls still run one at a time and in order; engines on the same
/// thread simply take turns, as they did on the cooperative pool. Several VMs
/// on one thread is a configuration JavaScriptCore supports: each VM has its
/// own lock and its timers on the run loop it was made on, which is this one.
///
/// Portable: `Thread` and `CFRunLoop` are the same on iOS.
final class EngineThread: SerialExecutor, @unchecked Sendable {

    /// 8 MB, the main thread's size. A pool thread's 512 KB is enough for
    /// today's inputs (JavaScriptCore throws cleanly near the bottom), but the
    /// rules recurse over a shop's data, and a book only grows.
    static let stackBytes = 8 << 20

    /// How many threads every engine in the process shares. Never more than
    /// four (the app itself has two or three engines), never fewer than two,
    /// and no more than the machine has cores — CI's runner has three, which
    /// is as many as the cooperative pool gave the engines before #1867.
    static let poolSize = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))

    /// The thread a new engine should live on: the current one when it is
    /// being made ON an engine thread (so `sync` runs inline and two threads
    /// can never wait on each other), else the one with the least waiting.
    static func forNewEngine() -> EngineThread {
        if let here = current { return here }
        return pool.lightest()
    }

    /// The engine thread the caller is running on, if it is one.
    static var current: EngineThread? {
        Thread.current.threadDictionary[currentKey] as? EngineThread
    }

    /// Every thread made so far, for the test that holds the count down.
    static var made: Int { pool.count }

    private static let currentKey = "khayt.engine.thread"
    private static let pool = Pool()

    /// The fixed set, made lazily. Never shrinks: an idle thread is parked in
    /// its run loop and costs nothing but its (virtual) stack.
    private final class Pool: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [EngineThread] = []

        var count: Int { lock.lock(); defer { lock.unlock() }; return threads.count }

        func lightest() -> EngineThread {
            lock.lock()
            // A new thread only while every one made so far has work waiting.
            if threads.count < EngineThread.poolSize, threads.allSatisfy({ $0.waiting > 0 }) {
                let made = EngineThread(name: "khayt.engine.\(threads.count)")
                threads.append(made)
                lock.unlock()
                return made
            }
            let chosen = threads.min { $0.waiting < $1.waiting }!
            lock.unlock()
            return chosen
        }
    }

    /// What the thread reads: its loop, set once before `init` returns.
    private final class Loop: @unchecked Sendable {
        var loop: CFRunLoop?
    }

    private let state = Loop()
    private let thread: Thread
    private let counter = NSLock()
    private var queued = 0

    /// Blocks handed to the thread and not yet finished.
    var waiting: Int { counter.lock(); defer { counter.unlock() }; return queued }

    private init(name: String) {
        let started = DispatchSemaphore(value: 0)
        let state = state
        // Not `self`: the thread outlives nothing, but it should hold nothing
        // either. `EngineThread` instances live in the pool for good.
        let box = WeakBox()
        thread = Thread {
            state.loop = CFRunLoopGetCurrent()
            if let me = box.thread { Thread.current.threadDictionary[EngineThread.currentKey] = me }
            // A port, so the loop has a source and does not return at once
            // while no JavaScriptCore timer is scheduled.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            started.signal()
            while true {
                autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 60, false) }
            }
        }
        box.thread = self
        thread.name = name
        thread.stackSize = Self.stackBytes
        thread.qualityOfService = .userInitiated
        thread.start()
        started.wait()
    }

    private final class WeakBox: @unchecked Sendable { weak var thread: EngineThread? }

    /// Run `block` on the thread, in order after everything already queued.
    func perform(_ block: @escaping @Sendable () -> Void) {
        guard let loop = state.loop else { return }
        counter.lock(); queued += 1; counter.unlock()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            block()
            counter.lock(); queued -= 1; counter.unlock()
        }
        CFRunLoopWakeUp(loop)
    }

    /// Run `body` on the thread and wait for it. For the engine's own
    /// initialiser. Already ON the thread (an engine made from inside another
    /// engine's call, which `forNewEngine` puts on the same thread), it runs
    /// in place: waiting for a block queued behind the running one would
    /// never return.
    func sync<T>(_ body: @escaping () throws -> T) throws -> T {
        if isCurrent { return try body() }
        // An engine thread never waits on another one, so two can never wait
        // on each other.
        precondition(EngineThread.current == nil, "EngineThread.sync from another engine thread")
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

    // MARK: SerialExecutor

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let me = asUnownedSerialExecutor()
        perform { job.runSynchronously(on: me) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// True on this engine thread.
    var isCurrent: Bool { Thread.current == thread }
}
