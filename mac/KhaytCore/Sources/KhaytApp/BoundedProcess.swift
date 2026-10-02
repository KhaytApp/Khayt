import Foundation

/// Running a program this app does not control — a slicer, `bsdtar` — and
/// getting control back whatever it does.
///
/// ── WHY ONE PLACE ─────────────────────────────────────────────────────────
///
/// Three callers each wrote their own and each got a different part wrong.
/// `SlicerRun` read stderr to the end BEFORE its deadline loop, so a slicer
/// that hung hung the caller with it, and nobody drained stdout at all — a
/// slicer that printed more than a pipe holds (64 KB) blocked on the write and
/// never exited. `ModelInfo` drained stdout but not stderr, the mirror image.
/// `ArchiveImport` read `bsdtar`'s complaints only after it had exited, so an
/// archive with ten thousand bad members filled that pipe the same way.
///
/// Here: BOTH pipes are drained as the program writes (by dispatch, not by a
/// blocking read), the deadline is enforced on the program rather than on our
/// own read, and a program that ignores SIGTERM gets SIGKILL. What it wrote is
/// kept up to a cap — the head of stdout, the tail of stderr — and the rest is
/// read and thrown away so the program never stalls on a full pipe.
///
/// BLOCKING. It waits on the calling thread, so it must never be called on
/// the main thread: a caller on the main actor goes through `Task.detached`.
enum BoundedProcess {

    struct Outcome: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        /// The deadline passed and the program was stopped.
        var timedOut: Bool
        /// The caller's `watch` asked for it to be stopped.
        var stopped: Bool
    }

    /// How long a program gets between SIGTERM and SIGKILL, and how long its
    /// pipes get to reach end-of-file once it has gone (a grandchild can hold
    /// them open; we do not wait for that).
    static let grace: TimeInterval = 2

    /// Run `path` with `arguments`, no shell, stdin closed.
    ///
    /// `watch` is asked every `every` seconds while the program runs; `true`
    /// stops it (an archive that has unpacked past its budget).
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval,
                    keepOut: Int = 4 << 20, keepErr: Int = 64 << 10,
                    every: TimeInterval = 0.25,
                    watch: (@Sendable () -> Bool)? = nil) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let out = Sink(keep: keepOut, tail: false)
        let err = Sink(keep: keepErr, tail: true)
        out.attach(outPipe.fileHandleForReading)
        err.attach(errPipe.fileHandleForReading)

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            out.detach(); err.detach()
            throw error
        }
        // `Process` closes our copies of the write ends once the program is
        // launched, so end-of-file arrives when the program (and anything it
        // spawned) lets go of theirs. Closing them again here could close an
        // unrelated descriptor that has since reused the number.

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false, stopped = false
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { timedOut = true; break }
            if exited.wait(timeout: .now() + min(left, every)) == .success { break }
            if let watch, watch() { stopped = true; break }
        }
        if timedOut || stopped {
            process.terminate()
            if exited.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + grace)
            }
        }

        out.waitForEnd(grace)
        err.waitForEnd(grace)
        out.detach(); err.detach()
        return Outcome(status: process.isRunning ? -1 : process.terminationStatus,
                       stdout: out.data, stderr: err.data,
                       timedOut: timedOut, stopped: stopped)
    }

    /// One pipe's reader. Appends what arrives, up to `keep`; past that keeps
    /// the head (stdout, where a program's answer starts) or the tail (stderr,
    /// where its last complaint is) and drops the rest — still reading it.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private let keep: Int
        private let tail: Bool
        private let ended = DispatchSemaphore(value: 0)
        private var handle: FileHandle?

        init(keep: Int, tail: Bool) { self.keep = keep; self.tail = tail }

        func attach(_ h: FileHandle) {
            handle = h
            h.readabilityHandler = { [self] h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    ended.signal()
                    return
                }
                lock.lock(); defer { lock.unlock() }
                if tail {
                    bytes.append(chunk)
                    if bytes.count > keep { bytes.removeFirst(bytes.count - keep) }
                } else if bytes.count < keep {
                    bytes.append(chunk.prefix(keep - bytes.count))
                }
            }
        }

        func waitForEnd(_ seconds: TimeInterval) { _ = ended.wait(timeout: .now() + seconds) }

        /// Stop reading. Not closed by hand: a handler already running holds
        /// the handle, and it closes when the last reference goes — closing it
        /// under that handler would have `availableData` raise.
        func detach() {
            handle?.readabilityHandler = nil
            handle = nil
        }

        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
}
