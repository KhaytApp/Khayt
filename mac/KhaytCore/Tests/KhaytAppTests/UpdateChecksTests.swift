import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Sparkle under "make no internet calls": every check, scheduled or by hand,
/// asks the gate through Sparkle's own hook before any feed is fetched.
@Suite(.serialized) @MainActor
struct UpdateChecksTests {

    static func gate(_ settings: JSONValue?) -> OutboundGate {
        let gate = OutboundGate()
        gate.update(book: settings.map(OutboundGate.Book.settings) ?? .unread)
        return gate
    }

    @Test("allowed as today; refused while the shop is offline, counted on the updates row, with a sentence for Sparkle to show")
    func refusedWhileOffline() throws {
        let probe = LaunchProbe()
        try OutboundGate.$scoped.withValue(Self.gate(.object([:]))) { try probe.mayCheck() }
        let offline = Self.gate(.object(["network": .object(["offline": .bool(true)])]))
        OutboundGate.$scoped.withValue(offline) {
            do { try probe.mayCheck(); Issue.record("a check went ahead while the shop is offline") }
            catch {
                let ns = error as NSError
                #expect(ns.domain == "app.khayt.outbound")
                #expect(!ns.localizedDescription.isEmpty)
            }
        }
        #expect(offline.blocked(.updates)?.count == 1)
        #expect(!probe.waitsForBook, "the shop said no: nothing to make up later")
    }

    @Test("kept: a shop that keeps updates still gets them while offline")
    func keptGoesThrough() throws {
        let kept = Self.gate(.object(["network": .object(["offline": .bool(true), "keep": .array([.string("updates")])])]))
        try OutboundGate.$scoped.withValue(kept) { try LaunchProbe().mayCheck() }
        #expect(kept.blocked(.updates) == nil)
    }

    @Test("before the book is read the launch check waits, and is remembered so it can be made once the settings are known")
    func waitsForTheBook() async throws {
        let probe = LaunchProbe()
        OutboundGate.$scoped.withValue(Self.gate(nil)) {
            #expect(throws: (any Error).self) { try probe.mayCheck() }
        }
        // The flag is set on the next main-queue turn.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(probe.waitsForBook)
    }

    @Test("the app says the book is unread before AppKit starts, and never puts a loaded shop back to starting")
    func launchOrder() throws {
        let defaults = UserDefaults(suiteName: "khayt.outbound.test.\(UUID().uuidString)")!
        defaults.set(true, forKey: Shop.offlineHereKey)
        let gate = OutboundGate()
        Shop.outboundBegins(defaults: defaults, gate: gate, inTheApp: true)
        #expect(gate.currentBook == .unread && gate.currentLocal.offline)
        gate.update(book: .settings(.object([:])))
        Shop.outboundBegins(defaults: defaults, gate: gate, inTheApp: true)
        #expect(gate.currentBook == .settings(.object([:])), "a loaded shop is not put back")
        // A development run has no shop feeding the gate: it is never put to "starting".
        let dev = OutboundGate()
        Shop.outboundBegins(defaults: defaults, gate: dev, inTheApp: false)
        #expect(dev.currentBook == .none)
        let main = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/main.swift"), encoding: .utf8)
        let begins = try #require(main.range(of: "Shop.outboundBegins()"))
        #expect(!main[..<begins.lowerBound].contains("NSApplication"), "before AppKit, so before the menu bar builds the updater")
    }
}
