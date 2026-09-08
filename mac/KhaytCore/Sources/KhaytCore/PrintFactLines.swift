import Foundation

/// How a model's print settings are put into words.
///
/// ── WHY THIS IS IN KHAYTCORE AND NOT IN THE PANEL THAT SHOWS IT ───────────
///
/// Two things show these facts: the app's library inspector and the Quick Look
/// preview, which is a separate bundle in a separate process that cannot import
/// the app. Written once in each, they would agree today and drift by the third
/// change — and the two places a shop sees the same model would start telling it
/// different things, which is worse than either being wrong on its own.
///
/// The words come in through a lookup rather than a catalogue, because the app
/// has `Words` (which knows the shop's language and is `@MainActor` and owns a
/// live engine) and the extension has a dictionary it fetched once. Both can
/// answer `(String) -> String`.
public enum PrintFactLines {

    /// One row of the panel.
    public struct Line: Sendable, Equatable {
        public let label: String
        public let value: String
        /// Shown quietly: a stated absence, or a count that is context rather
        /// than news.
        public let dim: Bool
        public init(label: String, value: String, dim: Bool) {
            self.label = label; self.value = value; self.dim = dim
        }
    }

    /// The shared-catalogue keys this uses. Declared here so the app can put
    /// them in `Words.borrowed` from one place, and so a key added below cannot
    /// be forgotten there — `HowItPrintsTests` fails if one is missing.
    public static let borrowedKeys = [
        "conv.src_printer", "calc.layer_height", "conv.cp_nozzle",
        "plib.material", "doc.supports", "common.none",
    ]

    /// The keys this counts with. `counting` needs a `<key>_one` for each, and
    /// the app's scan for counted words reads its OWN sources — it cannot see
    /// into KhaytCore, so these are declared rather than found.
    public static let countedKeys = ["mac.objects_n"]

    /// The words Khayt has never needed, in the languages this app speaks.
    ///
    /// `calc.infill` is "Infill (%)" and this column already carries the `%`;
    /// nothing in the shared catalogue says a plate disagrees with itself.
    /// Kept here rather than added to the shared locale files because that
    /// catalogue is nine languages wide and guarded for completeness.
    public static let ownWords: [String: [String: String]] = [
        "mac.how_it_prints":  ["en": "How it prints",  "ar": "كيف تُطبع"],
        "mac.infill":         ["en": "Infill",         "ar": "نسبة الملء"],
        "mac.varies_by_part": ["en": "varies by part", "ar": "تختلف حسب القطعة"],
        "mac.mixed_nozzles":  ["en": "mixed nozzles",  "ar": "فوهات مختلفة"],
        "mac.on_the_plate":   ["en": "On the plate",   "ar": "على الصينية"],
        "mac.no_settings":    ["en": "No slicer settings in this file.",
                               "ar": "لا توجد إعدادات تقطيع في هذا الملف."],
        // `counting` puts the number in front, so these are bare nouns.
        "mac.objects_n":      ["en": "objects",        "ar": "قطع"],
        "mac.objects_n_one":  ["en": "object",         "ar": "قطعة"],
    ]

    /// One line per thing the file actually said.
    ///
    /// This is the part that can be wrong. It decides that a support STYLE is
    /// shown only when support is on, that a plate whose parts disagree says so
    /// rather than picking one, and that a fact the file did not state gets no
    /// row at all rather than a dash — a dash means "we looked and found
    /// nothing", which is not the same as the file having no such idea.
    ///
    /// - Parameters:
    ///   - word: a key to the reader's language.
    ///   - counting: `(3, "mac.objects_n") -> "3 objects"`. Passed in because
    ///     the app's version knows about singulars and Arabic's number shapes,
    ///     and reimplementing that here is how the two panels start to differ.
    public static func lines(from facts: KhaytEngine.PrintFacts?,
                             word: (String) -> String,
                             counting: (Int, String) -> String) -> [Line] {
        guard let f = facts, !f.isEmpty else { return [] }
        var out: [Line] = []
        if let printer = f.printer, !printer.isEmpty {
            out.append(Line(label: word("conv.src_printer"), value: printer, dim: false))
        }
        // THE UNIT IS IN THE LABEL — "Layer height (mm)", "الفوهة (مم)" —
        // because a bare " mm" appended in Swift is an English word sitting in a
        // right-to-left panel, which is the mistake this app has already shipped
        // once, as "3 h 06 m".
        if let layer = f.layerHeight {
            out.append(Line(label: word("calc.layer_height"),
                            value: number(layer), dim: false))
        }
        if let nozzle = f.nozzle {
            out.append(Line(label: word("conv.cp_nozzle"),
                            value: f.nozzleVaries ? word("mac.mixed_nozzles") : number(nozzle),
                            dim: f.nozzleVaries))
        }
        if !f.materials.isEmpty {
            out.append(Line(label: word("plib.material"),
                            value: f.materials.joined(separator: " · "), dim: false))
        }
        if f.infillVaries {
            out.append(Line(label: word("mac.infill"),
                            value: word("mac.varies_by_part"), dim: true))
        } else if let infill = f.infill {
            out.append(Line(label: word("mac.infill"), value: infill, dim: false))
        }
        if let support = f.support {
            // The style shows only when support is ON. Every one of these files
            // carries a `support_type` whether or not it is used, and "tree
            // (auto)" beside a model that prints without support is the most
            // misleading thing this panel could say. `lib/print-facts.js` is
            // what stops it arriving; this is what would put it back.
            out.append(Line(label: word("doc.supports"),
                            value: support ? (f.supportStyle ?? "✓") : word("common.none"),
                            dim: !support))
        }
        if let objects = f.objects, objects > 1 {
            out.append(Line(label: word("mac.on_the_plate"),
                            value: counting(objects, "mac.objects_n"), dim: true))
        }
        return out
    }

    /// A measurement with no trailing zero pretending to be precision: 0.12 and
    /// 0.4, never 0.120 and 0.40. The unit belongs to the label.
    public static func number(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
