import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A program this app launches cannot hang it.
///
/// Each case is a fake slicer — a shell script — doing one of the things a
/// real one did or could: print more than a pipe holds on both streams, sleep
/// past the deadline, ignore SIGTERM. Before `BoundedProcess`, the first hung
/// `SlicerRun` for ever (stdout never drained), and the second hung it until
/// the slicer chose to exit (stderr read to the end before the deadline loop).
struct BoundedProcessTests {

    /// An executable script in a directory of its own, removed by the caller.
    static func script(_ body: String) throws -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-fake-slicer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "slicer")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return (dir, file.path)
    }

    static func slicer(_ path: String) throws -> KhaytEngine.Slicer {
        KhaytEngine.Slicer(id: "F", name: "Fake", path: path)
    }

    /// A placeholder model: `slice` only checks it exists.
    static func model(in dir: URL) throws -> URL {
        let m = dir.appending(path: "m.stl")
        try Data("solid x\nendsolid x\n".utf8).write(to: m)
        return m
    }

    @Test("a slicer that writes megabytes to BOTH streams finishes instead of blocking on a full pipe")
    func chattySlicerFinishes() throws {
        // 2 MB each way — thirty times what a pipe holds.
        let (dir, path) = try Self.script("""
            head -c 2097152 /dev/zero | tr '\\0' 'o'
            head -c 2097152 /dev/zero | tr '\\0' 'e' 1>&2
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date()
        try SlicerRun.slice(try Self.model(in: dir), with: try Self.slicer(path), argv: [],
                            allowed: true, timeout: 30)
        #expect(Date().timeIntervalSince(started) < 20, "the chatty slicer ran into the deadline")
    }

    @Test("what a program wrote is capped: the head of stdout, the tail of stderr")
    func outputIsCapped() throws {
        let (dir, path) = try Self.script("""
            printf 'START'; head -c 1048576 /dev/zero | tr '\\0' 'o'
            head -c 1048576 /dev/zero | tr '\\0' 'e' 1>&2; printf 'LAST' 1>&2
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let o = try BoundedProcess.run(path, [], timeout: 30, keepOut: 1000, keepErr: 1000)
        #expect(o.status == 0 && !o.timedOut)
        #expect(o.stdout.count == 1000)
        #expect(String(decoding: o.stdout.prefix(5), as: UTF8.self) == "START")
        #expect(o.stderr.count == 1000)
        #expect(String(decoding: o.stderr.suffix(4), as: UTF8.self) == "LAST")
    }

    @Test("a slicer that sleeps past the deadline is stopped AT the deadline, not when it pleases")
    func sleeperIsStopped() throws {
        // Writes to stderr first: the old code read stderr to the end before
        // it ever looked at the clock, so this one waited the full 60 s.
        let (dir, path) = try Self.script("echo working 1>&2; sleep 60")
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date()
        #expect(throws: SlicerRun.Failure.tookTooLong("Fake")) {
            try SlicerRun.slice(try Self.model(in: dir), with: try Self.slicer(path), argv: [],
                                allowed: true, timeout: 1)
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a program that ignores SIGTERM is killed")
    func ignoresTerm() throws {
        let (dir, path) = try Self.script("trap '' TERM; while :; do sleep 1; done")
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date()
        let o = try BoundedProcess.run(path, [], timeout: 0.5)
        #expect(o.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a failing slicer's last words are the reason given")
    func failureCarriesStderr() throws {
        let (dir, path) = try Self.script("echo 'cannot read model' 1>&2; exit 3")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SlicerRun.Failure.producedNothing("cannot read model")) {
            try SlicerRun.slice(try Self.model(in: dir), with: try Self.slicer(path), argv: [],
                                allowed: true, timeout: 30)
        }
    }

    @Test("slicing makes no scratch directory of its own to leave behind")
    func noStrayScratch() throws {
        // Writes into its own directory (where `argv` points), as a real one does.
        let (dir, path) = try Self.script("echo '; filament used [g] = 1' > \"$1\"")
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appending(path: "out.gcode")
        // The slice is told where to write and writes there; nothing else in
        // the temporary directory is this call's to clean up, so nothing is made.
        let before = Self.sliceDirs()
        try SlicerRun.slice(try Self.model(in: dir), with: try Self.slicer(path),
                            argv: [output.path], allowed: true, timeout: 30)
        #expect(FileManager.default.fileExists(atPath: output.path))
        // Other tests make (and remove) these concurrently, so this asks only
        // that no NEW one survived — any it saw appear must belong to another.
        let leaked = Self.sliceDirs().subtracting(before).filter {
            ((try? FileManager.default.contentsOfDirectory(atPath:
                FileManager.default.temporaryDirectory.appending(path: $0).path)) ?? ["x"]).isEmpty
        }
        #expect(leaked.isEmpty, "an empty khayt-slice- directory was left: \(leaked)")
    }

    static func sliceDirs() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("khayt-slice-") })
    }

    @Test("measuring drains stderr too, so a slicer warning about everything still answers")
    func measureDrainsBoth() throws {
        let (dir, path) = try Self.script("""
            if [ "$1" = "--help" ]; then echo '  --info  print info'; exit 0; fi
            head -c 1048576 /dev/zero | tr '\\0' 'w' 1>&2
            printf '[m.stl]\\nnumber_of_facets = 12\\nvolume = 1000\\nmin_x = 0\\nmax_x = 10\\n'
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let g = try ModelInfo.measure(try Self.model(in: dir), with: try Self.slicer(path),
                                      allowed: true, timeout: 30)
        #expect(g.triangleCount == 12)
        #expect(g.volumeMm3 == 1000)
    }

    @Test("measuring stops a slicer that never answers")
    func measureTimesOut() throws {
        let (dir, path) = try Self.script("""
            if [ "$1" = "--help" ]; then echo '--info'; exit 0; fi
            sleep 60
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date()
        #expect(throws: ModelInfo.Failure.tookTooLong("Fake")) {
            _ = try ModelInfo.measure(try Self.model(in: dir), with: try Self.slicer(path),
                                      allowed: true, timeout: 1)
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
