import Foundation
import KhaytCore

/// One file from a printer onto disk, COUNTED AS IT ARRIVES.
///
/// A printer's file listing says how big a video is, and that is a claim. A
/// printer that under-states it, or a thing answering at the printer's
/// address that is not the printer, must not be able to fill the disk: so the
/// limit is on what is READ, the transfer is cut the moment it is passed, and
/// the caller removes whatever was written. A stated length over the limit is
/// refused before a byte is read.
///
/// No redirect is followed (a printer on the LAN has no business sending this
/// Mac somewhere else), only `200` is a file, and thirty seconds without a
/// byte ends it.
final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// Not a `200`: the printer has no such file, or refused.
        case status(Int)
        /// More than `cap`: said up front, or read. The count is what was claimed or read.
        case overBudget(Int)
        case redirected
        /// The file could not be written here.
        case write
    }

    /// TESTS ONLY: a `URLProtocol` standing in for the printer.
    nonisolated(unsafe) static var protocolsForTests: [AnyClass]?
    static let idle: TimeInterval = 30

    private let handle: FileHandle
    private let cap: Int
    private var got = 0
    private var failure: Failure?
    /// Told how much has been written, about every quarter megabyte.
    private var progress: (@Sendable (Int) -> Void)?
    private var told = 0
    private var done: CheckedContinuation<Int, Error>?
    private let lock = NSLock()

    private init(handle: FileHandle, cap: Int) { self.handle = handle; self.cap = cap }

    /// The bytes written to `file`. Throws `Failure`, or the transport's own
    /// error; in every failing case `file` may hold a partial copy, which is
    /// the caller's to remove.
    static func run(_ request: URLRequest, to file: URL, cap: Int, progress: (@Sendable (Int) -> Void)? = nil) async throws -> Int {
        guard let url = request.url, cap > 0 else { throw Failure.status(0) }
        // The switch never blocks the shop's own network, and says so itself.
        try OutboundGate.shared.require(.lan, url: url)
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { throw Failure.write }
        let job = CappedDownload(handle: handle, cap: cap)
        job.progress = progress
        let setup = URLSessionConfiguration.ephemeral
        setup.timeoutIntervalForRequest = idle
        setup.requestCachePolicy = .reloadIgnoringLocalCacheData
        setup.urlCache = nil
        setup.httpCookieStorage = nil
        if let stand = protocolsForTests { setup.protocolClasses = stand }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: setup, delegate: job, delegateQueue: queue)
        let task = session.dataTask(with: request)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Int, Error>) in
                job.lock.lock(); job.done = waiting; job.lock.unlock()
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    private func fail(_ why: Failure, _ task: URLSessionTask) {
        lock.lock(); if failure == nil { failure = why }; lock.unlock()
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        fail(.redirected, task)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            fail(.status((response as? HTTPURLResponse)?.statusCode ?? 0), dataTask)
            return completionHandler(.cancel)
        }
        if http.expectedContentLength > Int64(cap) {
            fail(.overBudget(Int(clamping: http.expectedContentLength)), dataTask)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let stopped = failure != nil
        if !stopped { got += data.count }
        let now = got
        lock.unlock()
        if stopped { return }
        // What is READ is the limit, whatever was said: nothing past it is written.
        if now > cap { return fail(.overBudget(now), dataTask) }
        do { try handle.write(contentsOf: data) } catch { return fail(.write, dataTask) }
        if now - told >= 256 * 1024 { told = now; progress?(now) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle.close()
        lock.lock()
        let waiting = done; done = nil
        let failure = failure, got = got
        lock.unlock()
        if let failure { waiting?.resume(throwing: failure) }
        else if let error { waiting?.resume(throwing: error) }
        else { waiting?.resume(returning: got) }
    }
}
