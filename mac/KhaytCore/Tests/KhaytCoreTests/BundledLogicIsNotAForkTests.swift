import Foundation
import Testing
@testable import KhaytCore

/// The bundled JavaScript must be `lib/` byte for byte.
///
/// KhaytCore ships copies of Khayt's pure business modules so the Mac app can
/// load them as bundle resources. A copy is a fork waiting to happen: `lib/`
/// gets a fix, the copy does not, and the Mac app quietly computes last month's
/// VAT. Nothing about that would be visible — both would run, both would return
/// a number.
///
/// So the copies are compared to their originals here, and `mac/sync-js.sh`
/// re-copies them. If this fails, run that; do not edit the copy.
struct BundledLogicIsNotAForkTests {

    /// The repository root, from this file's location.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/mac/KhaytCore/Tests/KhaytCoreTests/x.swift
            .deletingLastPathComponent()          // KhaytCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // KhaytCore
            .deletingLastPathComponent()          // mac
            .deletingLastPathComponent()          // repo root
    }

    @Test("every bundled module is identical to lib/")
    func bundledMatchesLib() throws {
        for module in KhaytEngine.modules {
            let original = Self.repoRoot.appending(path: "lib/\(module).js")
            let copy = Self.repoRoot.appending(path: "mac/KhaytCore/Sources/KhaytCore/JS/\(module).js")

            let originalBytes = try Data(contentsOf: original)
            let copyBytes = try Data(contentsOf: copy)

            #expect(originalBytes == copyBytes, """
                mac/KhaytCore/Sources/KhaytCore/JS/\(module).js has drifted from lib/\(module).js.
                The Mac app would compute different numbers from the Electron app.
                Run mac/sync-js.sh — do not edit the copy.
                """)
        }
    }

    @Test("a bundled module cannot need Node")
    func bundledModulesArePure() throws {
        // These run in JavaScriptCore, which has no `require`, no `fs`, no
        // `Buffer`. A module that grew a Node dependency in lib/ would load
        // here and then throw at its first call — from inside a screen.
        for module in KhaytEngine.modules {
            let source = try String(contentsOf: Self.repoRoot.appending(path: "lib/\(module).js"), encoding: .utf8)
            // ANCHORED PER LINE, or the `//` stripper does nothing at all:
            // without it `$` is the end of the whole file, so a line comment is
            // never matched and only block comments were being removed. Two
            // modules joined the list carrying the word "process." in ordinary
            // prose — "hang the main process." — and the guard read them as
            // Node dependencies. It has been blind to line comments since it
            // was written; nothing had tripped it before.
            let stripped = source
                .replacing(#/\/\*[\s\S]*?\*\//#, with: "")
                .replacing(#/(^|[^:])\/\/[^\n]*/#, with: "$1")
            #expect(!stripped.contains("require('fs')"), "\(module).js now requires fs")
            #expect(!stripped.contains("require('path')"), "\(module).js now requires path")
            #expect(!stripped.contains("require('crypto')"), "\(module).js now requires crypto")
            #expect(!stripped.contains("process."), "\(module).js now reads `process`, which does not exist here")
        }
    }

    @Test("every bundled locale is identical to the renderer's")
    func localesAreNotAFork() throws {
        // Same argument as the modules, with a sharper edge: a stale copy here
        // does not compute a wrong number, it shows a shop a word its other app
        // stopped using. Translations are corrected far more often than tax
        // rules, so this drifts sooner.
        for language in KhaytEngine.locales {
            let source = Self.repoRoot.appending(path: "renderer/locales/\(language).js")
            let copy = Self.repoRoot.appending(path: "mac/KhaytCore/Sources/KhaytCore/JS/locale-\(language).js")
            let a = try String(contentsOf: source, encoding: .utf8)
            let b = try String(contentsOf: copy, encoding: .utf8)
            #expect(a == b, "locale-\(language).js has drifted from renderer/locales — run mac/sync-js.sh")
        }
    }

    @Test("the module list and the bundled folder agree")
    func noStragglers() throws {
        let dir = Self.repoRoot.appending(path: "mac/KhaytCore/Sources/KhaytCore/JS")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".js") }
            .map { String($0.dropLast(3)) }
            .sorted()
        let expected = (KhaytEngine.modules + KhaytEngine.locales.map { "locale-\($0)" }).sorted()
        #expect(onDisk == expected, """
            The bundled folder and KhaytEngine's lists disagree. A file nobody loads is
            dead weight; a module or locale in a list with no file fails at startup.
            """)
    }
}
