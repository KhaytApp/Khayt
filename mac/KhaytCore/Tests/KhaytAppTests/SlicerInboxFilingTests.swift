import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Filing into the "From slicer" inbox is one read-decide-write at a time
/// (beta.40 review): the duplicate check and the 100-item cap read the folder,
/// the filing writes it, and two uploads arriving together must not both pass.
struct SlicerInboxFilingTests {

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "khayt-inbox-filing-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// `n` files under `dir`, each holding `body(i)`.
    static func files(_ n: Int, in dir: URL, body: (Int) -> String) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<n).map { i in
            let url = dir.appending(path: "upload-\(i).gcode")
            try Data(body(i).utf8).write(to: url)
            return url
        }
    }

    final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var filed = 0, duplicates = 0, full = 0, other = 0
        func note(_ r: Result<SlicerUpload, Error>) {
            lock.lock(); defer { lock.unlock() }
            switch r {
            case .success: filed += 1
            case .failure(let e) where e is SlicerInbox.Duplicate: duplicates += 1
            case .failure(let e) where e is SlicerInbox.Full: full += 1
            case .failure: other += 1
            }
        }
    }

    @Test("identical uploads arriving together: one is filed, the rest are told it is already there")
    func identicalTogether() throws {
        let root = Self.scratch(), incoming = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: incoming) }
        let uploads = try Self.files(8, in: incoming) { _ in "; same plate\nG28\nG1 X10 Y10\n" }
        let outcomes = Outcomes()
        DispatchQueue.concurrentPerform(iterations: uploads.count) { i in
            outcomes.note(Result { try SlicerInbox.file(uploads[i], name: "Bracket_PLA.gcode", figures: nil, root: root) })
        }
        #expect(outcomes.filed == 1)
        #expect(outcomes.duplicates == uploads.count - 1)
        #expect(outcomes.other == 0)
        #expect(SlicerInbox.list(root: root).count == 1)
    }

    @Test("the 100-item cap holds when uploads race for the last places")
    func capUnderRace() throws {
        let root = Self.scratch(), incoming = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: incoming) }
        let first = try Self.files(SlicerInbox.maxWaiting - 2, in: incoming) { "; file \($0)\nG28\n" }
        for (i, url) in first.enumerated() {
            _ = try SlicerInbox.file(url, name: "f\(i).gcode", figures: nil, root: root)
        }
        let racing = try Self.files(10, in: incoming.appending(path: "race")) { "; racing \($0)\nG28\n" }
        let outcomes = Outcomes()
        DispatchQueue.concurrentPerform(iterations: racing.count) { i in
            outcomes.note(Result { try SlicerInbox.file(racing[i], name: "r\(i).gcode", figures: nil, root: root) })
        }
        #expect(outcomes.filed == 2, "only the two places left")
        #expect(outcomes.full == racing.count - 2)
        #expect(SlicerInbox.list(root: root).count == SlicerInbox.maxWaiting)
    }
}
