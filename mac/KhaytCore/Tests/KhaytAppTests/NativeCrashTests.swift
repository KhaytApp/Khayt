import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Swift traps reported through MetricKit (`NativeCrashes.swift`), and the
/// Settings test report. The scrubber is the real `lib/telemetry-scrub.js`.
@Suite(.serialized) @MainActor
struct NativeCrashTests {

    /// `MXCallStackTree.jsonRepresentation()`'s shape: the crashing frame at
    /// the root, each caller its one sub-frame.
    static let tree = Data("""
        {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [
            {"binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 4096, "address": 1, "sampleCount": 1}]},
          {"threadAttributed": true, "callStackRootFrames": [
            {"binaryName": "libswiftCore.dylib", "binaryUUID": "A1", "offsetIntoBinaryTextSegment": 1447276,
             "address": 6876000000, "sampleCount": 1, "subFrames": [
              {"binaryName": "SwiftUICore", "offsetIntoBinaryTextSegment": 10236100, "address": 2, "sampleCount": 1,
               "subFrames": [
                {"binaryName": "Khayt", "offsetIntoBinaryTextSegment": 9404, "address": 3, "sampleCount": 1}]}]}]}]}
        """.utf8)

    static let crash = NativeCrash(exceptionType: 6, signal: 5, build: "77",
                                   terminationReason: "Namespace SIGNAL, Code 5, Trace trap",
                                   frames: NativeCrash.frames(fromCallStackJSON: tree))

    @Test("the crashing thread's frames, crashing frame first, offsets in hex")
    func frames() {
        #expect(NativeCrash.frames(fromCallStackJSON: Self.tree) == [
            "libswiftCore.dylib +0x16156c", "SwiftUICore +0x9c30c4", "Khayt +0x24bc"])
        #expect(NativeCrash.frames(fromCallStackJSON: Self.tree, limit: 2).count == 2)
        #expect(NativeCrash.frames(fromCallStackJSON: Data("not json".utf8)).isEmpty)
        #expect(NativeCrash.frames(fromCallStackJSON: Data("{}".utf8)).isEmpty)
    }

    @Test("a Swift trap survives the scrubber: signal, exception, build and frames")
    func scrubbed() async throws {
        let raw = TelemetryRaw.crash(native: Self.crash, TelemetryTests.context)
        let report = try #require(try await TelemetryTests.engine.telemetryCrashReport(raw))
        #expect(report["name"] == .string("SIGTRAP"))
        #expect(report["message"] == .string("EXC_BREAKPOINT, build 77, Namespace SIGNAL, Code 5, Trace trap"))
        // Hex, because nine decimal digits read as a card number and are taken out.
        #expect(report["stack"] == .string("libswiftCore.dylib +0x16156c\nSwiftUICore +0x9c30c4\nKhayt +0x24bc"))
        #expect(report["osFamily"] == .string("macOS"))
    }

    @Test("a path in the system's reason does not leave the Mac")
    func reasonScrubbed() async throws {
        var crash = Self.crash
        crash.terminationReason = "dyld: Library not loaded: /Users/noura/Library/Khayt.framework"
        let report = try #require(try await TelemetryTests.engine.telemetryCrashReport(
            TelemetryRaw.crash(native: crash, TelemetryTests.context)))
        guard case .string(let message)? = report["message"] else { Issue.record("no message"); return }
        #expect(!message.contains("noura"))
    }

    @Test("only the head of macOS's reason is kept: the rest quotes paths")
    func reasonHead() {
        #expect(NativeCrash.reasonHead("Namespace SIGNAL, Code 5 Trace/BPT trap: 5") == "Namespace SIGNAL, Code 5")
        #expect(NativeCrash.reasonHead("Namespace DYLD, Code 1 Library missing | Library not loaded: @rpath/X.framework | Referenced from: /Users/Turki Alballaa/Applications/Khayt.app")
                == "Namespace DYLD, Code 1")
        #expect(NativeCrash.reasonHead("/Users/Turki Alballaa/secret") == nil)
        #expect(NativeCrash.reasonHead(nil) == nil)
    }

    @Test("names for the exceptions and signals a Mac app dies of")
    func names() {
        #expect(NativeCrash.exceptionName(1) == "EXC_BAD_ACCESS" && NativeCrash.signalName(11) == "SIGSEGV")
        #expect(NativeCrash.exceptionName(99) == "EXC_99" && NativeCrash.signalName(nil) == nil)
        let raw = TelemetryRaw.crash(native: NativeCrash(frames: []), TelemetryTests.context)
        #expect(raw["name"] == .string("NativeCrash") && raw["message"] == .string(""))
    }

    @Test("MetricKit's crashes wait for the book, twenty at most")
    func held() {
        let telemetry = Telemetry(defaults: UserDefaults(suiteName: "khayt.native.\(UUID().uuidString)")!)
        telemetry.received(Array(repeating: Self.crash, count: 15))
        telemetry.received(Array(repeating: NativeCrash(signal: 11, frames: []), count: 15))
        #expect(telemetry.nativeCrashes.count == 20)
        #expect(telemetry.nativeCrashes.last?.signal == 11)
    }

    @Test("the test report is queued and sent, and says what it is")
    func testReport() async throws {
        let rig = TelemetryTests.Rig()
        let raw = TelemetryRaw.testCrash(TelemetryTests.context)
        #expect(await rig.telemetry.enqueue(.crash, raw, consent: TelemetryTests.both,
                                            engine: TelemetryTests.engine, file: rig.file))
        let reason = await rig.telemetry.flush(consent: TelemetryTests.both, engine: TelemetryTests.engine,
                                               file: rig.file)
        #expect(reason == "accepted")
        let events = try rig.sentEvents()
        let payload = try #require(events.first?["payload"] as? [String: Any])
        #expect(payload["name"] as? String == "TestReport")
        #expect(rig.file.read().isEmpty)
        #expect(TelemetrySettings.resultKey(reason) == "mac.tel_test_sent")
        #expect(TelemetrySettings.resultKey("unreachable") == "mac.tel_test_later")
        #expect(TelemetrySettings.resultKey("not-enabled") == "mac.tel_test_later")
        #expect(TelemetrySettings.resultKey("refused") == "mac.tel_test_failed")
    }
}
