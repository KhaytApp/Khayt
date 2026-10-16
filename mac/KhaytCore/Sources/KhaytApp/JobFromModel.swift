import Foundation
import KhaytCore

/// A model in the library, or the calculator's answer for one, as a quote or a
/// job — without typing the grams and the hours a second time.
///
/// ── ONE PRICE, NOT TWO ────────────────────────────────────────────────────
///
/// The job sheet prices its cart with `Shop.previewQuote` over the parts'
/// frozen costs, and `lib/order-new.js` saves the job with the same
/// `quoteTotal`. The calculator prices its part with `Shop.costedPart` and the
/// same `previewQuote`. So nothing here works a price out: the calculator's
/// COSTED part — its cost, its buckets, the rates it was costed at — becomes
/// one cart line, and the margin, discount and rush travel beside it. The
/// sheet then asks the shared rule exactly what the calculator asked, and the
/// two totals are the same halalah (`JobFromModelTests.samePrice`).
///
/// A model picked in the LIBRARY goes through the calculator's own model — the
/// same fill, the same colour lines, the same consumables — so "Quote this
/// model…" in the library and "Make quote" in the calculator start from one
/// figure, not two that happen to agree today.
///
/// ── SLICED OR ESTIMATED, SAID ON THE LINE ─────────────────────────────────
///
/// A model nobody has sliced has no weight and no time, and `Shop.modelPart`
/// fills them from the mesh. That is a figure this app stands behind, but it is
/// not a slicer's, and a quote built on it has to say so where the shop reads
/// the cart — see `ModelFigureSource`.

/// Where a model's weight and time came from.
enum ModelFigureSource: Equatable, Sendable {
    /// Both read off the slice.
    case sliced
    /// Both measured from the mesh: nothing has sliced this model yet.
    case estimated
    /// One of each.
    case partlyEstimated

    /// `estimated` is `Shop.ModelPart.estimated` — the part's field names.
    static func of(estimated: Set<String>) -> ModelFigureSource {
        let weight = estimated.contains("printWeight"), time = estimated.contains("printTime")
        switch (weight, time) {
        case (false, false): return .sliced
        case (true, true): return .estimated
        default: return .partlyEstimated
        }
    }

    var key: String {
        switch self {
        case .sliced: return "mac.figures_sliced"
        case .estimated: return "mac.figures_estimated"
        case .partlyEstimated: return "mac.figures_part_estimated"
        }
    }

    var symbol: String {
        switch self {
        case .sliced: return "checkmark.seal"
        case .estimated, .partlyEstimated: return "ruler"
        }
    }

    /// An estimate is the one a shop should look at twice before it quotes.
    var wantsAttention: Bool { self != .sliced }
}

/// What the calculator's "From a model…" took from a model, so a quote made
/// from it can link the file and say where the figures came from.
struct ModelFill: Equatable {
    /// The part's name: the model's title, or "Title — plate 2".
    var name: String
    /// `printFileId`, `plate`, `fileRef`, `setupId` — what joins a job's part
    /// to the file it prints (`lib/order-file-link.js`).
    var link: [String: JSONValue]
    var source: ModelFigureSource
    /// `Shop.modelPart`'s sentence, for the hover.
    var note: String?
    /// The figures as filled. Typing over any of them makes them the shop's,
    /// and the label stops claiming the file for them.
    var signature: String

    /// The fields of a model's part that say WHICH file it is.
    static let linkKeys = ["printFileId", "plate", "fileRef", "setupId"]

    static func link(from part: [String: JSONValue]) -> [String: JSONValue] {
        part.filter { linkKeys.contains($0.key) }
    }
}

extension CalculatorModel {
    /// The figures a fill writes, as one value — see `ModelFill.signature`.
    var figuresSignature: String {
        lines.map(\.grams).joined(separator: ";") + "|" + hours
    }

    /// Where the figures on screen came from, while they are still the
    /// model's. Nil once the shop has typed over them, or with no model.
    var figureSource: ModelFigureSource? {
        guard let filled, filled.signature == figuresSignature else { return nil }
        return filled.source
    }

    /// The calculator's part as the job sheet holds a part — the same input
    /// `recompute` costed, and the answer it got.
    ///
    /// Pure: a test hands it a part and a costing and reads the line back.
    /// `input` is `costInput`'s object; its measured fields become the line's
    /// figures and the rest (colours, purge, consumables, typed rates) rides
    /// in `raw`, which `Shop.partRows` writes onto the saved part.
    static func jobDraft(input: JSONValue, costed: KhaytEngine.CostedPart, qty: Int,
                         name: String, fill: ModelFill?, source: ModelFigureSource?) -> NewJobSheet.Draft {
        var draft = NewJobSheet.Draft()
        var raw: [String: JSONValue] = [:]
        if case .object(let o) = input { raw = o }
        for (key, value) in fill?.link ?? [:] { raw[key] = value }
        draft.raw = raw
        draft.name = name
        draft.spoolId = Shop.plainString(raw["filamentId"])
        draft.grams = Money.fieldValue(Shop.plainNumber(raw["printWeight"]) ?? 0)
        draft.hours = Money.fieldValue(Shop.plainNumber(raw["printTime"]) ?? 0)
        // NOT clamped to the sheet's stepper. The calculator priced this many,
        // and a line silently cut to 999 is a cheaper job than the one quoted.
        draft.qty = max(1, qty)
        draft.cost = costed.cost
        draft.parts = costed.parts
        draft.rates = costed.rates
        draft.source = source
        draft.sourceNote = source == nil ? nil : fill?.note
        return draft
    }

    /// The screen's part, ready for the job sheet. Nil until it has been
    /// costed — there is nothing to quote before then.
    func jobDraft(_ shop: Shop) -> NewJobSheet.Draft? {
        guard let costed, hasInput else { return nil }
        return Self.jobDraft(input: partInput(shop), costed: costed, qty: qty,
                             name: filled?.name ?? "", fill: filled, source: figureSource)
    }

    /// The job sheet's opening state for this calculator: its one part, and
    /// the margin, discount and rush it was priced with.
    func jobSeed(_ shop: Shop, asQuote: Bool) -> Shop.JobFromModel? {
        guard let draft = jobDraft(shop) else { return nil }
        return Shop.JobFromModel(project: draft.name, parts: [draft], margin: margin,
                                 discountPct: discount, rush: rush, asQuote: asQuote)
    }
}

extension Shop {
    /// What the job sheet opens on when it was asked for from a model.
    struct JobFromModel {
        var project: String
        var parts: [NewJobSheet.Draft]
        var margin: Double
        var discountPct: Double = 0
        var rush = false
        /// Which of the sheet's two buttons is the default one.
        var asQuote: Bool
        /// Who it is for — set by a COPY of a job (File ▸ Duplicate), which
        /// is the same work for the same customer. Nil from a model.
        var clientId: String? = nil
        var shippingCost: Double = 0
        var extraLines: [ExtraLine] = []
        /// Record fields a copy carries as they were — its notes, the product
        /// it was taken from, the components and how many assemblies — handed
        /// to `newJobInput` beside what the sheet itself collects. Which fields
        /// those are is `lib/record-duplicate.js`'s to say, not this sheet's.
        var carried: [String: JSONValue] = [:]
    }

    /// Open the job sheet on `seed`.
    func takeJob(_ seed: JobFromModel) {
        jobFromModel = seed
        takingAJob = true
    }

    /// What a job made of several models is called before the shop names it:
    /// their titles, while that still reads as a name.
    static func projectName(for titles: [String]) -> String {
        let named = titles.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return named.count <= 3 ? named.joined(separator: " + ") : ""
    }

    /// A job — or a quote — made of these library models, one line each.
    ///
    /// Each model goes through a `CalculatorModel` exactly as "From a model…"
    /// fills one: `modelPart`'s grams and hours, the slicer's colours on the
    /// shop's spools, the model's consumables, costed at the shop's margin. A
    /// model with no figures at all is left out and named in
    /// `productProblem`, rather than arriving as a line that costs nothing.
    func jobFromModels(_ files: [LibraryFile], asQuote: Bool) async -> JobFromModel? {
        var parts: [NewJobSheet.Draft] = []
        var skipped: [String] = []
        for file in files {
            guard let calc = await calculator(for: file, plate: nil),
                  let draft = calc.jobDraft(self) else { skipped.append(file.title); continue }
            parts.append(draft)
        }
        productProblem = skipped.isEmpty ? nil
            : words.callIt("mac.quote_model_none", ["names": .string(skipped.joined(separator: ", "))])
        guard !parts.isEmpty else { return nil }
        return JobFromModel(project: Self.projectName(for: parts.map(\.name)), parts: parts,
                            margin: defaultMargin, asQuote: asQuote)
    }

    /// Start a job or a quote from library models. Says why when it cannot.
    func startJob(fromModels files: [LibraryFile], asQuote: Bool) async {
        guard canMoveJobs else { moveProblem = words.callIt("mac.move_sample"); return }
        if let seed = await jobFromModels(files, asQuote: asQuote) {
            // Some of a selection had nothing to quote: the sheet opens on
            // the rest, and the ones left out are named rather than dropped.
            if let skipped = productProblem { moveProblem = skipped }
            takeJob(seed)
        } else {
            moveProblem = productProblem ?? words.callIt("mac.calc_model_none")
        }
    }

    /// A calculator filled from one model, and costed — what the calculator
    /// screen shows after "From a model…". Nil when the model has no figures.
    func calculator(for file: LibraryFile, plate: Int?) async -> CalculatorModel? {
        let calc = CalculatorModel()
        calc.margin = defaultMargin
        guard await calc.fillFromModel(file, plate: plate, shop: self) == nil else { return nil }
        await calc.recompute(self)
        return calc.costed == nil ? nil : calc
    }
}

extension CalculatorModel {
    /// Fill from a library model through `Shop.modelPart`, and remember what
    /// was filled. Returns the problem to show, or nil when it filled.
    ///
    /// The ONE way a model's figures reach a calculator: the screen's "From a
    /// model…" row and the library's "Quote this model…" both call this.
    func fillFromModel(_ file: LibraryFile, plate: Int?, shop: Shop) async -> String? {
        guard let made = await shop.modelPart(from: file, plate: plate) else {
            return shop.productProblem ?? shop.words.callIt("mac.calc_model_none")
        }
        let g = Shop.plainNumber(made.part["printWeight"]) ?? 0
        let h = Shop.plainNumber(made.part["printTime"]) ?? 0
        guard g > 0 || h > 0 else { return shop.words.callIt("mac.calc_model_none") }
        // The spool the catalogue would cost this model with — the shop's
        // spool of the material it was sliced for. ALWAYS, not only on an
        // empty screen: the calculator opens on the shelf's first spool, and
        // keeping that would cost a PETG model as PLA here and as PETG from
        // the library — two prices for one model. A colour line from the
        // file still goes to its planned spool (`fill`).
        if !lines.isEmpty, let spool = Shop.plainString(made.part["filamentId"]) {
            lines[0].spoolId = spool
        }
        fill(from: file, plate: plate, grams: g, hours: h, shop: shop)
        filled = ModelFill(name: Shop.plainString(made.part["name"]) ?? file.title,
                           link: ModelFill.link(from: made.part),
                           source: .of(estimated: made.estimated),
                           note: made.note, signature: figuresSignature)
        return nil
    }
}
