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

    /// A module's source with template-literal TEXT removed and its `${…}`
    /// interpolations kept — the part JavaScriptCore actually evaluates.
    static func runnable(_ source: String) -> String {
        var out = ""
        var rest = source[...]
        while let open = rest.firstIndex(of: "`") {
            out += rest[..<open]
            var i = rest.index(after: open)
            var template = ""
            while i < rest.endIndex, rest[i] != "`" {
                if rest[i] == "\\", rest.index(after: i) < rest.endIndex {
                    i = rest.index(i, offsetBy: 2)
                    continue
                }
                template.append(rest[i])
                i = rest.index(after: i)
            }
            // Only the interpolations, which are evaluated; the rest is text
            // this module is writing out for something else to run.
            for part in template.matches(of: #/\$\{[\s\S]*?\}/#) {
                out += " " + part.output.description
            }
            rest = i < rest.endIndex ? rest[rest.index(after: i)...] : rest[rest.endIndex...]
        }
        return out + rest
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
            //
            // ── AND CODE A MODULE WRITES IS NOT CODE IT RUNS ──────────────
            //
            // `medusa-subscriber.js` EMITS TypeScript for the shop's own Medusa
            // project, and that file reads `process.env.MEDUSA_ADMIN_URL` — in
            // Node, on the shop's server, where `process` exists. Read flat,
            // the module "contains process." and this refused to bundle it.
            //
            // So the TEXT inside a template literal is dropped and its `${…}`
            // interpolations are kept: those are the only part of a template
            // this runtime evaluates. A module genuinely reaching for
            // `process.env` inside one is still caught — checked by putting it
            // there and watching this fail, not assumed.
            //
            // The same narrowing is in `test/mac-core-is-not-a-fork.test.js`,
            // which is the Node half of this guard. Both, because a guard that
            // exists twice and agrees in only one place is worse than one that
            // exists once.
            // ORDER MATTERS, AND GETTING IT WRONG LOOKS LIKE THE FEATURE
            // WORKING. Block comments first — they hold most of the backticks
            // in this repo, as prose. Then TEMPLATES, then line comments: the
            // emitted subscriber opens with `` `// ${SUBSCRIBER_PATH} `` and a
            // line-comment stripper run first eats that and leaves an
            // unterminated backtick, so the template scanner then swallows the
            // wrong half of the file. That was the first version of this, and
            // it failed loudly rather than quietly, which is the only reason it
            // took minutes instead of a release.
            let stripped = Self.runnable(
                source.replacing(#/\/\*[\s\S]*?\*\//#, with: "")
            ).replacing(#/(^|[^:])\/\/[^\n]*/#, with: "$1")
            #expect(!stripped.contains("require('fs')"), "\(module).js now requires fs")
            #expect(!stripped.contains("require('path')"), "\(module).js now requires path")
            #expect(!stripped.contains("require('crypto')"), "\(module).js now requires crypto")
            #expect(!stripped.contains("process."), "\(module).js now reads `process`, which does not exist here")

            // ── AND `module` ITSELF ───────────────────────────────────────
            //
            // JavaScriptCore has no `module` either, and this guard did not
            // look for it. `printer-commands.js` was written Node-only — bare
            // top-level bindings and a closing `module.exports` — and the day
            // it was bundled it failed on its first line with
            // `Can't find variable: module`, leaving the Mac app unable to tell
            // a printer anything.
            //
            // The GUARDED form is what every shared module ends with and is
            // fine: `typeof module !== 'undefined' && module.exports`. What is
            // refused is reaching for it bare.
            // TWO guarded shapes, and both have to go before what is left can
            // be called a bare reach.
            //
            // The export — removing only its `typeof` test leaves the
            // assignment behind, and the check then fails on all 190 modules
            // that do it correctly:
            //
            //     if (typeof module !== 'undefined' && module.exports) module.exports = api;
            //
            // And the IMPORT, which two modules use to pick between `require`
            // and the global — also correct, and also caught by a first draft
            // that only knew about exports:
            //
            //     const units = (typeof module !== 'undefined' && module.exports)
            //       ? require('./inventory-units.js') : globalThis.KhaytInventoryUnits;
            let guarded = stripped
                .replacing(#/if\s*\(\s*typeof\s+module\s*!==\s*['"]undefined['"]\s*&&\s*module\.exports\s*\)\s*module\.exports\s*=\s*[A-Za-z_$][A-Za-z0-9_$]*\s*;?/#,
                           with: "")
                .replacing(#/typeof\s+module\s*!==\s*['"]undefined['"]\s*&&\s*module\.exports/#,
                           with: "")
            #expect(!guarded.contains("module.exports"), """
                \(module).js assigns module.exports without guarding on `typeof module`.
                JavaScriptCore has no `module`, so it throws on its first line.
                """)
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

    /// `Bundle.module` is a loaded gun, and it has gone off twice.
    ///
    /// SwiftPM compiles it, per target, into exactly two hard-coded paths: the
    /// bundle ROOT (where codesign forbids putting anything, so an assembled
    /// `.app` never has it) and the absolute path of the `.build` directory on
    /// the machine that compiled it. So it works on the build machine and
    /// nowhere else — the one failure mode a developer cannot see. 4.0.0-alpha.1
    /// and alpha.2 both shipped an app that died on its first line:
    ///
    ///     Fatal error: could not load resource bundle: from
    ///     /Applications/Khayt.app/KhaytCore_KhaytCore.bundle or
    ///     /Users/runner/work/Khayt/Khayt/mac/KhaytCore/.build/…
    ///
    /// `BundledResources` looks in `Contents/Resources`, where `make-app.sh`
    /// actually puts them. This is why nothing may go back to asking SwiftPM.
    ///
    /// Scoped to first-party sources: `BundledResources` and `AppResources`
    /// name it deliberately, as the last-resort fallback for `swift test`, and
    /// SwiftPM's own generated accessor under `.build` is not ours to police.
    @Test("no target reaches for Bundle.module directly")
    func bundleModuleIsNeverUsedDirectly() throws {
        let sources = Self.repoRoot.appending(path: "mac/KhaytCore/Sources")
        let allowed: Set<String> = ["BundledResources.swift", "AppResources.swift"]
        var offenders: [String] = []

        let walker = FileManager.default.enumerator(at: sources,
                                                    includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  !allowed.contains(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Prose about the trap is the point of half these files, so a
                // comment line is not an offence — only code that calls it.
                let code = line.drop { $0 == " " || $0 == "\t" }
                if code.hasPrefix("//") || code.hasPrefix("///") || code.hasPrefix("*") { continue }
                if line.contains("Bundle.module") {
                    offenders.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }

        #expect(offenders.isEmpty, """
            \(offenders.joined(separator: ", ")) calls Bundle.module. It resolves to the
            build directory of whichever machine compiled it, so it works here and
            crashes on every Mac a shop downloads it to. Use BundledResources.
            """)
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
