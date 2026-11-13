import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A printer that is switched off must not hold up the reading of one that
/// is on.
///
/// The sweep asked the machines one after another, so every printer waited
/// out the timeout of every dead one before it: ten seconds plus five for
/// each printer that was off, between two readings of a healthy one. Now each
/// host is asked at the same time as the others.
///
/// No network: the printers here are closures stood in at `PrinterWatch.asking`.
@MainActor
struct PrinterSweepTogetherTests {

    static func machine(_ id: String, host: String, port: Int = 7125) throws -> Machine {
        try MachineLifeTests.machine(MachineLifeTests.record(id, [
            "printerApi": .object(["type": .string("moonraker"), "host": .string(host),
                                   "port": .number(Double(port))]),
        ]))
    }

    /// A door a fake printer waits at until the test opens it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { c in
                lock.lock()
                if open { lock.unlock(); c.resume() } else { waiting.append(c); lock.unlock() }
            }
        }
        func release() {
            lock.lock()
            open = true
            let all = waiting
            waiting = []
            lock.unlock()
            for c in all { c.resume() }
        }
    }

    struct Dead: Error {}

    /// A sample shop whose own watch is stopped, with these machines in it.
    static func shop(_ machines: [Machine]) async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.printers.stop()
        shop.machines = machines
        return shop
    }

    static func until(_ what: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if what() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return what()
    }

    @Test("a printer that never answers does not delay the reading of one that does")
    func deadDoesNotDelayLive() async throws {
        // The dead one is FIRST in the book: asked one after another, the live
        // one would not be asked until the dead one gave up.
        let shop = await Self.shop([try Self.machine("M-DEAD", host: "192.168.1.31"),
                                    try Self.machine("M-LIVE", host: "192.168.1.32")])
        let watch = shop.printers
        let gate = Gate()
        let status = try LiveActivityPushTests.status("printing")
        watch.asking = { machine, _, _, _ in
            if machine.id == "M-DEAD" {
                // Stands for the five seconds a switched-off printer takes to
                // time out; held until the test has looked.
                await gate.wait()
                throw Dead()
            }
            return status
        }
        let sweep = Task { await watch.sweep(shop: shop) }
        let heard = await Self.until { watch.readings["M-LIVE"]?.status != nil }
        #expect(heard, "the live printer's reading waited for the dead one")
        #expect(watch.readings["M-DEAD"] == nil, "the dead printer has not given up yet")
        gate.release()
        await sweep.value
        // And the dead one is still written down as a failed poll.
        #expect(watch.readings["M-DEAD"]?.status == nil)
        #expect(watch.readings["M-DEAD"]?.consecutiveFailures == 1)
        #expect(watch.readings["M-LIVE"]?.consecutiveFailures == 0)
    }

    @Test("two machines at one address are still asked one after the other")
    func oneHostStaysInOrder() async throws {
        // Two Klipper instances on one board, and a third printer elsewhere.
        let shop = await Self.shop([try Self.machine("M-1", host: "192.168.1.40", port: 7125),
                                    try Self.machine("M-2", host: " 192.168.1.40 ", port: 7126),
                                    try Self.machine("M-3", host: "192.168.1.41")])
        let watch = shop.printers
        let status = try LiveActivityPushTests.status("printing")
        var inFlight: [String: Int] = [:]      // host -> requests under way
        var worstPerHost = 0
        var worstOverall = 0
        var order: [String] = []
        watch.asking = { machine, _, _, _ in
            let host = (machine.printerApi?.host ?? "").trimmingCharacters(in: .whitespaces)
            // On the main actor, like the watch that calls it.
            inFlight[host, default: 0] += 1
            worstPerHost = max(worstPerHost, inFlight[host] ?? 0)
            worstOverall = max(worstOverall, inFlight.values.reduce(0, +))
            order.append(machine.id)
            try? await Task.sleep(for: .milliseconds(60))
            inFlight[host, default: 0] -= 1
            return status
        }
        await watch.sweep(shop: shop)
        #expect(worstPerHost == 1, "one host was asked twice at the same moment")
        #expect(worstOverall == 2, "different hosts were not asked at the same time")
        #expect(order.firstIndex(of: "M-1")! < order.firstIndex(of: "M-2")!, "book order within a host")
        #expect(Set(watch.readings.keys) == ["M-1", "M-2", "M-3"])
    }

    @Test("lanes: one per host, in book order, whatever the port or the spelling")
    func lanes() throws {
        let a = try Self.machine("A", host: "printer.local")
        let b = try Self.machine("B", host: "192.168.1.9")
        let c = try Self.machine("C", host: "PRINTER.local ", port: 7126)
        let d = try Self.machine("D", host: "")
        let lanes = PrinterWatch.lanes([a, b, c, d]).map { $0.map(\.id) }
        #expect(lanes == [["A", "C"], ["B"], ["D"]])
        #expect(PrinterWatch.lanes([]).isEmpty)
    }

    @Test("the sweep puts no blocking work on the shared pool")
    func noDetachedWork() throws {
        // Blocking work in `Task.detached` has deadlocked this suite on CI
        // before; the sweep waits on async calls only.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/PrinterWatch.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "func sweep(shop: Shop) async {"))
        let end = try #require(source.range(of: "func forgetUnwatched(shop: Shop)"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        #expect(body.contains("withTaskGroup"))
        #expect(!body.contains("Task.detached"))
        #expect(!body.contains("DispatchSemaphore"))
        #expect(!body.contains(".wait()"))
    }
}
