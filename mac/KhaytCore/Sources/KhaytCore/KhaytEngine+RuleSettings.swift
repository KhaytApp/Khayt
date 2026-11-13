import Foundation

/// The shop's settings, as a rule that never looks at the big blocks gets them.
///
/// ── WHY ───────────────────────────────────────────────────────────────────
///
/// Nearly every rule takes `settings`, and settings holds three things that
/// are large and that almost no rule reads:
///
///   - `bizLogo`: the shop's logo as a data URL. 0.7 MB on the shop measured.
///   - `printLibrary`: where the library lives and its linked folders, the
///     Drive and vault state. 0.37 MB there.
///   - `libraryGroups`: the Mac's own record of group kinds and covers.
///
/// Every call turns its arguments into JSON text and JavaScript parses it
/// back, so a reload that asks 54 rules handed the logo across 54 times:
/// 60 MB of text per reload, 75 to 92 ms per call in a debug build, for
/// rules that work out a tax rate or count late jobs
/// (`mac-measurements-nov11`, D2). Without the three, the same crossing takes
/// a tenth of a millisecond.
///
/// ── WHICH RULES GET THIS, AND HOW THAT WAS DECIDED ────────────────────────
///
/// Only a rule that was SHOWN not to read them, by reading its JavaScript and
/// everything that JavaScript calls:
///
///   1. none of the modules it can reach names `bizLogo`, `printLibrary` or
///      `libraryGroups` (in the whole bundle only `settings-edit`, `store`
///      and `store-secret-paths` do);
///   2. none of them walks, copies or prints the settings object as a whole
///      (`Object.keys`, a spread, `Object.assign`, `JSON.stringify`,
///      `for…in`, a computed key), because a copy handed back and saved
///      would save the settings WITHOUT the logo;
///   3. the rule's answer is not settings to be written back.
///
/// Every other rule still gets the whole thing: anything that draws a
/// document, anything that edits or returns settings, and anything nobody
/// has read yet. `RuleSettingsGuardTests` lists every engine function that
/// takes settings under one heading or the other, so a new one has to
/// choose, and `RuleSettingsProbeTests` reloads a book with a watch on the
/// three keys and fails if a trimmed rule so much as asks for one.
extension KhaytEngine {

    /// What `ruleSettings` leaves out.
    public nonisolated static let heavySettings = ["bizLogo", "printLibrary", "libraryGroups"]

    /// Set by `ruleSettings` instead of trimming, when a test is watching.
    public nonisolated static let probeMark = "__khaytRuleSettings"

    /// `settings` without the logo and the library blocks. Only for a rule on
    /// the trimmed list above.
    func ruleSettings(_ settings: [String: JSONValue]) -> [String: JSONValue] {
        var out = settings
        if probesRuleSettings {
            // Left whole and marked, so the test's watch can tell whether
            // the rule reaches for what would have been taken away.
            out[Self.probeMark] = .bool(true)
            return out
        }
        for key in Self.heavySettings { out[key] = nil }
        return out
    }

    /// The same, for a rule handed settings as a loose value.
    func ruleSettings(_ settings: JSONValue) -> JSONValue {
        guard case .object(let s) = settings else { return settings }
        return .object(ruleSettings(s))
    }

    /// For `RuleSettingsProbeTests` only: hand trimmed rules the whole
    /// settings, marked, so a watch inside JavaScript can see what they read.
    public func probeRuleSettings(_ on: Bool) { probesRuleSettings = on }
}

extension KhaytEngine {
    /// What a trimmed rule is handed, for the test that says what that is.
    public func ruleSettingsForTesting(_ settings: [String: JSONValue]) -> [String: JSONValue] {
        ruleSettings(settings)
    }
}
