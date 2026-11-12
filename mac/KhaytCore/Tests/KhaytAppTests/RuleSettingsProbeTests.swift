import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A rule that is handed settings WITHOUT the logo and the library blocks
/// (`KhaytEngine.ruleSettings`) must be a rule that never looks for them.
///
/// That was decided by reading each rule's JavaScript. This checks the
/// reading against the rules actually running: the book is reloaded with the
/// trimmed rules given the WHOLE settings, marked, and a watch put on the
/// marked object inside JavaScript. The watch notes any read of `bizLogo`,
/// `printLibrary` or `libraryGroups`, and anything that walks or copies every
/// key (`Object.keys`, a spread, `Object.assign`, `JSON.stringify`, `for…in`),
/// since a copy would carry them. A trimmed rule that does either is a rule
/// whose answer could change with the trimming, and it fails here by name.
///
/// It proves what the sample book reaches, not every branch of every rule.
/// The reading of the source is the other half; `RuleSettingsGuardTests`
/// holds the list.
@MainActor
struct RuleSettingsProbeTests {

    static var watch: String {
        let heavy = KhaytEngine.heavySettings.map { "'\($0)'" }.joined(separator: ", ")
        return """
        (function () {
          if (globalThis.__ruleSettingsWatch) return 0;
          var seen = { marked: 0, touched: [] };
          var heavy = [\(heavy)];
          var mark = '\(KhaytEngine.probeMark)';
          var parse = JSON.parse;
          function note(what) {
            var where = '';
            try { where = String(new Error().stack || '').split('\\n').slice(2, 8).join(' < '); } catch (e) {}
            if (seen.touched.length < 60) seen.touched.push(what + ' @ ' + where);
          }
          function watched(o) {
            seen.marked++;
            return new Proxy(o, {
              get: function (t, k, r) { if (heavy.indexOf(k) >= 0) note('read ' + String(k)); return Reflect.get(t, k, r); },
              has: function (t, k) { if (heavy.indexOf(k) >= 0) note('asked for ' + String(k)); return Reflect.has(t, k); },
              ownKeys: function (t) { note('walked every key'); return Reflect.ownKeys(t); }
            });
          }
          function isMarked(v) { return !!v && typeof v === 'object' && !Array.isArray(v) && v[mark] === true; }
          // In this engine's own context only; no other test's engine sees it.
          globalThis.JSON.parse = function (text, reviver) {
            var v = parse.call(JSON, text, reviver);
            if (isMarked(v)) return watched(v);
            if (v && typeof v === 'object' && !Array.isArray(v)) {
              for (var k in v) if (isMarked(v[k])) v[k] = watched(v[k]);
            }
            return v;
          };
          globalThis.__ruleSettingsWatch = seen;
          return 1;
        })()
        """
    }

    struct Seen: Decodable { let marked: Int; let touched: [String] }

    @Test("the watch itself sees a read, a walk and a copy")
    func theWatchWorks() async throws {
        // A watch that never fires would pass everything.
        let engine = try KhaytEngine()
        #expect(try await engine.raw(Self.watch, as: Int.self) == 1)
        let said = try await engine.raw("""
            (function () {
              var s = JSON.parse('{"\(KhaytEngine.probeMark)":true,"currency":"SAR","bizLogo":"x"}');
              var inner = JSON.parse('{"settings":{"\(KhaytEngine.probeMark)":true,"currency":"SAR"}}');
              var plain = JSON.parse('{"currency":"SAR","bizLogo":"x"}');
              var before = globalThis.__ruleSettingsWatch.touched.length;
              var quiet = s.currency + inner.settings.currency + plain.bizLogo + Object.keys(plain).length;
              var afterQuiet = globalThis.__ruleSettingsWatch.touched.length - before;
              s.bizLogo; Object.keys(s); ({}).x = Object.assign({}, inner.settings); JSON.stringify(s); 'printLibrary' in s;
              return { quiet: afterQuiet, loud: globalThis.__ruleSettingsWatch.touched.length - before,
                       marked: globalThis.__ruleSettingsWatch.marked, text: quiet };
            })()
            """, as: [String: JSONValue].self)
        #expect(said["quiet"] == .number(0), "reading an ordinary key, or an unmarked object, is not news")
        #expect(said["marked"] == .number(2))
        if case .number(let loud)? = said["loud"] { #expect(loud >= 5) } else { Issue.record("no count") }
    }

    @Test("no trimmed rule reads the logo or the library blocks, or copies settings whole, on a reload")
    func reloadTouchesNothingHeavy() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        await engine.probeRuleSettings(true)
        #expect(try await engine.raw(Self.watch, as: Int.self) == 1)
        // The same engine serves the reload, and what a load starts on the
        // side (the chips, readiness, the dashboard) is given time to ask.
        await shop.load(.sample)
        await shop.dayChanged()
        await shop.readLibraryFacets()
        await shop.readCatalogueFacets()
        try await Task.sleep(for: .seconds(2))
        let seen = try await engine.raw("globalThis.__ruleSettingsWatch", as: Seen.self)
        await engine.probeRuleSettings(false)
        // Enough trimmed calls that the watch was really in the path.
        #expect(seen.marked >= 15, "only \(seen.marked) trimmed calls were watched: is the reload still using ruleSettings?")
        #expect(seen.touched.isEmpty, Comment(rawValue:
            "a rule on the trimmed list reached for what is trimmed away. Take it off the list "
            + "(hand it the whole settings) or change what it reads:\n  "
            + seen.touched.prefix(12).joined(separator: "\n  ")))
    }

    @Test("ruleSettings takes away the three blocks and nothing else")
    func whatIsTrimmed() async throws {
        let engine = try KhaytEngine()
        let settings: [String: JSONValue] = [
            "bizLogo": .string("data:image/png;base64,AAAA"), "printLibrary": .object(["linked": .array([])]),
            "libraryGroups": .object(["kinds": .object([:])]), "currency": .string("SAR"),
            "tax": .object(["rate": .number(15)]), "bizEn": .string("A shop"), "printerCompletions": .object([:]),
        ]
        let trimmed = await engine.ruleSettingsForTesting(settings)
        var expected = settings
        for key in KhaytEngine.heavySettings { expected[key] = nil }
        #expect(trimmed == expected)
        #expect(KhaytEngine.heavySettings == ["bizLogo", "printLibrary", "libraryGroups"])
    }
}
