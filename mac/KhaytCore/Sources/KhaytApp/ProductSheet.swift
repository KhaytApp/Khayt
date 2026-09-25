import SwiftUI
import UniformTypeIdentifiers
import KhaytCore

/// Writing a product down.
///
/// The catalogue could be read on this Mac and not added to: a shop that wanted
/// a new product had to go to the other app for it. This is that gap.
///
/// ── ONE TAB PER LANGUAGE THE SHOP CARRIES ─────────────────────────────────
///
/// Not two fields called "English" and "Arabic". The shop chooses its catalogue
/// languages in settings and `lib/content-languages.js` decides the key for
/// each; a shop selling in German gets a German tab here and `name_de` on the
/// record. Asking the engine what the languages are — rather than hard-coding
/// the pair this app happens to be translated into — is what keeps the two
/// apps writing the same product.
///
/// The tab for a language that has nothing written in it is MARKED, because a
/// half-translated catalogue is invisible otherwise: the storefront falls back
/// to another language and the row looks finished from here.
struct ProductSheet: View {
    /// As `CustomerSheet.width`, and for the reason written there: the snapshot
    /// runner photographs this at a size of its own, and a number typed in two
    /// places drifts into a cropped picture with no failure.
    static let width: CGFloat = 480

    let shop: Shop
    let existing: Product

    @State private var draft: Product
    @State private var language: String = "en"
    @State private var started = false
    /// The pictures as the sheet has them — loaded from the record on open and
    /// only written back on save. See `StagedPicture`.
    /// The parts this product is made of — where its price comes from.
    @State private var parts: [PartRow] = []

    /// The named margins this product can be quoted at.
    @State private var tiers: [TierRow] = []

    /// The papers that travel with it, and the ones to unlink once it saves.
    @State private var docs: [ProductDocs.Attached] = []
    @State private var removedDocs: [String] = []
    @State private var docProblem: String?
    @State private var newPart = PartRow()
    /// The list position of a part taken back into the fields to be changed,
    /// or nil when the fields hold a new part.
    @State private var editingAt: Int?
    /// The part as it was before the pencil took it, for Cancel.
    @State private var editingOriginal: PartRow?
    /// A Plates change is under way; the row waits for it.
    @State private var platesBusy = false
    /// `lib/print-rates.js`'s own starting figures, so a part added here
    /// arrives costed the way the other app's calculator would cost it.
    @State private var rateDefaults: [String: String] = [:]
    @State private var showRates = false
    /// The library picker for the part being added — see `PickModelSheet`.
    @State private var pickingModel = false
    /// What the chosen model could and could not answer for, from
    /// `Shop.partFields(from:)`. Shown until the part is added or replaced.
    @State private var pickNote: String?
    /// What those parts cost, priced by the shared rule.
    @State private var pricing: KhaytEngine.ProductPricing?
    /// The shop's own rounding and typed price for this product — the two
    /// fields `lib/product-price.js` reads. Held here and written into the
    /// draft's record as they change, so the preview and the save agree.
    @State private var rule = Shop.PriceRule()
    @State private var overrideText = ""
    @State private var pictures: [StagedPicture] = []
    /// Files to unlink, acted on only if this sheet is saved.
    @State private var removedPictures: [String] = []
    @FocusState private var focused: Bool

    init(shop: Shop, existing: Product) {
        self.shop = shop
        self.existing = existing
        _draft = State(initialValue: existing)
    }

    private var isNew: Bool { shop.productIds.contains(existing.id) == false }

    /// One printed part of a product.
    ///
    /// The same five things a job's part is described by, because it is the
    /// same kind of thing and the calculator prices it the same way.
    /// One named margin, as this sheet collects it.
    ///
    /// A MARGIN AND NOT A PRICE. "Wholesale 20%" is the whole record, and the
    /// price follows from the parts — so a tier stays right when filament gets
    /// dearer, which a stored price would not. `renderer/inventory.js` writes
    /// the same two fields.
    struct TierRow: Identifiable, Equatable {
        let id = UUID()
        var label = ""
        var margin: Double = 20

        /// Nothing for a row with no name: an unnamed tier is a chip with no
        /// label on the job sheet, which nobody can pick on purpose.
        var record: JSONValue? {
            let name = label.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return .object(["label": .string(name), "margin": .number(max(0, margin))])
        }
    }

    struct PartRow: Identifiable, Equatable {
        var id = UUID()
        var name = ""
        var spoolId: String?
        var grams = ""
        var hours = ""
        var qty = 1
        /// The library model this part is printed from, when it came from one.
        /// The real join — what lets "how far out is my estimate for THIS
        /// part" be answered later. Kept through a save, or the link a shop
        /// made by choosing a model is gone the first time it edits the price.
        var printFileId: String?
        /// The part AS THE BOOK HOLDS IT, every field. This sheet edits five of
        /// them; the other app's editor writes a dozen more — the labour rate,
        /// prep and post time, power draw, wear and failure rate the cost is
        /// built from, the slicer profile, the file it was sliced from. A save
        /// that rebuilt the part from the five dropped all of those, and a
        /// portrait that cost 35.91 to make came back costing 10.57 — material
        /// only — and re-priced itself from 50 to 13.74 on the shop's own
        /// catalogue. What this sheet does not edit, it keeps.
        var raw: [String: JSONValue] = [:]
        /// The seven figures the part is COSTED at, as text.
        ///
        /// Text and not numbers because BLANK IS NOT ZERO: a part that never
        /// carried a labour rate must not quietly gain one of nought, and a
        /// shop that clears a field means "not this", not "none of it".
        ///
        /// Until now this sheet wrote none of them, and `product-pricing.js`
        /// injects none on purpose — so every product made on the Mac was
        /// priced at MATERIAL COST AND NOTHING ELSE. On the shop's own
        /// portrait that is 10.57 where the full cost is 35.91: the labour,
        /// the power, the wear and the failure allowance are seven tenths of
        /// what it costs to make, and they were simply missing.
        var rates: [String: String] = [:]
        static let rateKeys = ["laborRate", "prepTime", "postTime",
                               "wearRate", "powerDraw", "elecRate", "failureRate"]

        /// Whether this part is costed at anything beyond its filament.
        var hasRates: Bool { Self.rateKeys.contains { !(rates[$0] ?? "").isEmpty } }

        var isComplete: Bool { (Double(grams) ?? 0) > 0 || (Double(hours) ?? 0) > 0 }

        /// Which plate of a multi-plate file this part is, when it is one.
        var plate: Int? { if case .number(let n)? = raw["plate"] { Int(n) } else { nil } }

        /// The record shape a product's `parts` list holds: what was there,
        /// with this sheet's five fields written over it.
        func record(spools: [Spool]) -> JSONValue {
            var o = raw
            o["name"] = .string(name)
            o["printWeight"] = .number(max(0, Double(grams) ?? 0))
            if o["supportWeight"] == nil { o["supportWeight"] = .number(0) }
            o["printTime"] = .number(max(0, Double(hours) ?? 0))
            o["qty"] = .number(Double(max(1, qty)))
            if let spoolId, let spool = spools.first(where: { $0.id == spoolId }) {
                o["filamentId"] = .string(spool.id)
                o["material"] = .string(spool.material)
                o["spoolCost"] = .number(spool.cost ?? 0)
                o["spoolWeight"] = .number(max(1, spool.weight ?? 1000))
            } else if spoolId == nil {
                // The shop took the filament off: the part is not made of it any more.
                for key in ["filamentId", "material", "spoolCost", "spoolWeight"] { o.removeValue(forKey: key) }
            }
            if let printFileId, !printFileId.isEmpty { o["printFileId"] = .string(printFileId) }
            else { o.removeValue(forKey: "printFileId") }
            for key in Self.rateKeys {
                let typed = (rates[key] ?? "").replacingOccurrences(of: ",", with: "")
                    .trimmingCharacters(in: .whitespaces)
                // Cleared means gone, not nought — see `rates`.
                if typed.isEmpty { o.removeValue(forKey: key) }
                else { o[key] = .number(max(0, Double(typed) ?? 0)) }
            }
            return .object(o)
        }

        @MainActor static func from(_ value: JSONValue) -> PartRow? {
            guard case .object(let o) = value else { return nil }
            var row = PartRow()
            row.raw = o
            row.name = Shop.plainString(o["name"]) ?? ""
            row.spoolId = Shop.plainString(o["filamentId"])
            // `fieldValue`, NOT `quantity`: a part of a kilo or more read
            // back as nothing, and opening a product then saving it rounded
            // every figure in it. See `Money.fieldValue`.
            row.grams = Money.fieldValue(Shop.plainNumber(o["printWeight"]))
            row.hours = Money.fieldValue(Shop.plainNumber(o["printTime"]))
            row.qty = Int(Shop.plainNumber(o["qty"]) ?? 1)
            row.printFileId = Shop.plainString(o["printFileId"])
            for key in rateKeys {
                if let value = Shop.plainNumber(o[key]) { row.rates[key] = Money.fieldValue(value) }
            }
            return row
        }
    }

    var body: some View {
        // Scrolls, and keeps Cancel and Save reachable on any screen — a sheet
        // cannot be moved, so one taller than the display hides its own
        // buttons. See `SheetFrame`.
        SheetFrame(width: Self.width) {
            Text(shop.words.callIt(isNew ? "mac.new_product" : "mac.edit_product"))
                .font(.headline)
            // A product is a promise to sell it, so a model it is built from
            // that may not be sold is said here, where the promise is made.
            let problems = shop.saleProblems(parts.compactMap(\.printFileId))
            if !problems.isEmpty {
                LicenceWarning(shop: shop, problems: problems)
            }

            if shop.catalogueLanguages.count > 1 {
                Picker("", selection: $language) {
                    ForEach(shop.catalogueLanguages) { key in
                        // A dot on a language with nothing in it. The tab label
                        // is the only place this can be said before somebody
                        // saves and wonders why the storefront shows English.
                        Text(written(key.language) ? key.title : "\(key.title) •")
                            .tag(key.language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    // `pe.name`, not `cat.title`. The latter is the SCREEN's
                    // name — "Product Catalog" — and it was the label on the
                    // field where a shop types the product's name. Correct in
                    // the sidebar, where it names the screen, and nonsense
                    // here. Found by photographing this sheet, which nothing in
                    // the harness had ever done.
                    Text(shop.words.callIt("pe.name")).gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TextField("", text: name(language)).textFieldStyle(.roundedBorder)
                        .focused($focused)
                        // Arabic belongs right to left whatever the app is set
                        // to — as the customer sheet's name field already does.
                        .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
                }
                GridRow {
                    Text(shop.words.callIt("pe.description")).gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TextField("", text: description(language), axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
                }
                GridRow {
                    Text(shop.words.callIt("mac.margin")).gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        // EMPTY IS NOT ZERO. A product with no margin takes the
                        // shop's default; one with a margin of 0 is sold at
                        // cost. A number field that turns blank into 0 would
                        // quietly reprice the catalogue.
                        TextField(percent(shop.defaultMargin), text: marginText)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("%").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                // ── THE PRICE THE SHOP ACTUALLY CHARGES ───────────────────
                //
                // Cost plus margin is where a product's price starts. The other
                // app's editor lets the shop round it to a step or type its own
                // figure, and the book already carried both — but this sheet
                // showed neither, so a shop that had set "round up to 5" and a
                // price of 50 watched a save here drop them to 13.74 with no
                // way back. The same two controls, the same two fields.
                GridRow {
                    Text(shop.words.callIt("pe.round_to")).gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Picker("", selection: $rule.step) {
                            ForEach(Shop.PriceRule.steps, id: \.self) { step in
                                Text(step == 0 ? shop.words.callIt("pe.round_off") : Money.quantity(step)).tag(step)
                            }
                        }
                        .labelsHidden().frame(width: 110)
                        if rule.step > 0 {
                            Picker("", selection: $rule.mode) {
                                ForEach(Shop.PriceRule.modes, id: \.self) { mode in
                                    Text(shop.words.callIt("pe.round_\(mode)")).tag(mode)
                                }
                            }
                            .labelsHidden().frame(width: 120)
                        }
                        Spacer()
                    }
                }
                GridRow {
                    Text(shop.words.callIt("pe.price_override")).gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField(shop.words.callIt("pe.price_override_ph"), text: $overrideText)
                            .textFieldStyle(.roundedBorder).frame(width: 110).monospacedDigit()
                            .onChange(of: overrideText) { _, typed in
                                let cleaned = typed.replacingOccurrences(of: ",", with: "")
                                    .trimmingCharacters(in: .whitespaces)
                                rule.override = cleaned.isEmpty ? nil : max(0, Double(cleaned) ?? 0)
                            }
                        Text(shop.currency).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                GridRow {
                    Text(shop.words.callIt("plib.group")).gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TextField("", text: $draft.group).textFieldStyle(.roundedBorder)
                }
                // A category files it with the rest on the web store. It
                // could be set in bulk from the catalogue and not here, where
                // a product is written.
                GridRow {
                    Text(shop.words.callIt("mac.category")).gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TextField("", text: $draft.category).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(shop.words.callIt("mac.ws_state")).gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    Toggle(shop.words.callIt("mac.ws_show"), isOn: $draft.onWebStore)
                }
            }

            Divider()
            partsSection

            Divider()
            ProductPictureStrip(shop: shop, productId: draft.id,
                                pictures: $pictures, removed: $removedPictures)

            Divider()
            tiersSection

            Divider()
            docsSection
        } footer: {
            HStack {
                if !draft.hasAName {
                    Text(shop.words.callIt("mac.product_need_name"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.editingProduct = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) {
                    let saving = draft
                    let staged = pictures
                    let unlink = removedPictures
                    let rows = effectiveParts.map { $0.record(spools: shop.spools) }
                    let tierRows = tiers.compactMap { $0.record }
                    let docRows = docs.map { $0.record }
                    let dropped = removedDocs
                    Task { await shop.saveProduct(saving, pictures: staged,
                                                  unlinking: unlink, parts: rows,
                                                  tiers: tierRows, docs: docRows,
                                                  unlinkingDocs: dropped) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.hasAName)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            // The shop's own first catalogue language, not "en" — a Riyadh shop
            // opening on an English tab is being asked the wrong question first.
            language = shop.catalogueLanguages.first?.language ?? "en"
            focused = true
        }
        // THROUGH THE SHARED RULE, not by reading `images` off the record. A
        // product can arrive carrying the legacy `imagePath`/`thumbnail` pair,
        // the array, or both because an older build edited it after a newer one
        // saved it — and "the array wins except when it is empty" is the
        // migration this sheet must not have its own opinion about.
        .task(id: existing.id) { pictures = await shop.pictures(of: existing.id) }
        // The parts it already has, and what they come to. A product edited
        // here must not lose the parts it was made with — this sheet could not
        // hold them at all until now, and `rest` is what carried them through.
        .task(id: existing.id) {
            if case .array(let list)? = existing.rest["parts"] {
                parts = list.compactMap(PartRow.from)
            }
            rule = Shop.priceRule(of: existing)
            overrideText = rule.override.map { Money.fieldValue($0) } ?? ""
            if let defaults = await shop.printRateDefaults() {
                rateDefaults = defaults
                // Only the part being composed. An existing part keeps what it
                // has, blanks included: filling those in here would move the
                // price of a product the shop only opened to look at.
                if !newPart.hasRates { newPart.rates = defaults }
            }
            tiers = Shop.tiers(of: existing).map { TierRow(label: $0.label, margin: $0.margin) }
            if case .array(let list)? = existing.rest["docs"] {
                docs = list.compactMap(ProductDocs.Attached.from)
            }
            await reprice()
        }
        // Re-priced when the margin changes, because the margin is above the
        // parts on this sheet and a shop typing one is watching the total.
        .task(id: draft.margin) { await reprice() }
        // As the shop types — a weight, a time, a rate, a spool, a quantity.
        .onChange(of: newPart) { Task { await reprice() } }
        .onChange(of: parts) { Task { await reprice() } }
        // And when the rounding or the typed price changes — written into the
        // record at the same moment, so what the preview says is what saves.
        .task(id: rule) {
            // `null`, not absent: a save merges every key the sheet did not
            // write forward from the record that was there, so clearing a
            // typed price by removing the key would resurrect it. Khayt's own
            // editor writes null for both, and so does this.
            draft.rest["priceOverride"] = rule.override.map { JSONValue.number($0) } ?? .null
            draft.rest["priceRound"] = rule.step > 0
                ? .object(["step": .number(rule.step), "mode": .string(rule.mode)]) : .null
            await reprice()
        }
        .sheet(isPresented: $pickingModel) {
            PickModelSheet(shop: shop) { file in
                Task {
                    guard let filled = await shop.partFields(from: file) else { return }
                    // A different model: nothing of the part it replaces
                    // (its plate, its setup, its file reference) comes along.
                    newPart.raw = [:]
                    newPart.name = Shop.plainString(filled.part["name"]) ?? file.title
                    newPart.grams = Money.fieldValue(Shop.plainNumber(filled.part["printWeight"]))
                    newPart.hours = Money.fieldValue(Shop.plainNumber(filled.part["printTime"]))
                    newPart.printFileId = file.id
                    // The model's own filament, when the library knows one the
                    // shop stocks; otherwise the picker is left for the shop.
                    if let spool = Shop.plainString(filled.part["filamentId"]),
                       shop.spools.contains(where: { $0.id == spool }) {
                        newPart.spoolId = spool
                    }
                    pickNote = filled.note
                }
            }
        }
    }

    /// The prices this product can be quoted at.
    ///
    /// They are offered on the job sheet as chips beside the margin field —
    /// which is the only thing a tier changes. Editable here because the pair
    /// only works if both halves are: a tier nobody can add is a feature a shop
    /// reads about and cannot use, and until now adding one meant opening the
    /// other app.
    private var tiersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shop.words.callIt("cat.tiers_section"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(shop.words.callIt("mac.add_tier")) {
                    tiers.append(TierRow(label: shop.words.callIt("mac.wholesale"), margin: 20))
                }
            }
            if tiers.isEmpty {
                Text(shop.words.callIt("cat.no_tiers"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach($tiers) { $tier in
                    HStack(spacing: 8) {
                        TextField(shop.words.callIt("cat.tier_label"), text: $tier.label)
                            .textFieldStyle(.roundedBorder)
                        TextField("", value: $tier.margin, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60).multilineTextAlignment(.trailing)
                        Text("%").foregroundStyle(.secondary)
                        Button {
                            tiers.removeAll { $0.id == tier.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(shop.words.callIt("common.delete"))
                    }
                }
                Text(shop.words.callIt("cat.tiers_hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The papers that go with it.
    ///
    /// A copy is taken, so the shop's own file can be moved or renamed
    /// afterwards without the product losing its instructions. Removing one
    /// only unlinks the file once the product is SAVED — a document deleted
    /// here and then a cancelled sheet must leave the file where it was.
    private var docsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shop.words.callIt("pdoc.title")).font(.subheadline.weight(.semibold))
                Spacer()
                Button(shop.words.callIt("pdoc.add") + "\u{2026}") { attach() }
            }
            if docs.isEmpty {
                Text(shop.words.callIt("pdoc.none"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach($docs) { $doc in
                    HStack(spacing: 8) {
                        Text(doc.originalName).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        // Absent means yes, and the box says so plainly: this
                        // decides whether the sheet goes in the customer's box
                        // or stays on the floor's work order.
                        Toggle(shop.words.callIt("pdoc.pack"), isOn: $doc.packWithOrder)
                            .toggleStyle(.checkbox).font(.caption)
                        Button(shop.words.callIt("common.open")) {
                            if let build = shop.source.build {
                                ProductDocs.open(doc.filename, in: build)
                            }
                        }
                        .buttonStyle(.borderless)
                        Button {
                            removedDocs.append(doc.filename)
                            docs.removeAll { $0.filename == doc.filename }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(shop.words.callIt("common.delete"))
                    }
                }
                Text(shop.words.callIt("pdoc.hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let docProblem {
                Text(docProblem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func attach() {
        guard let build = shop.source.build else {
            docProblem = shop.words.callIt("mac.move_sample"); return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // The kinds the other app's dialog offers, and then anything — which
        // is also what it does, because a shop's drawing can be in a format
        // nobody thought to list.
        panel.allowedContentTypes = ProductDocs.kinds.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.prompt = shop.words.callIt("pdoc.add")
        guard panel.runModal() == .OK else { return }
        docProblem = nil
        for url in panel.urls {
            do {
                docs.append(try ProductDocs.attach(url, productId: draft.id, in: build))
            } catch {
                docProblem = shop.words.callIt("pdoc.attach_failed") + " " + url.lastPathComponent
            }
        }
    }

    /// What the product is made of, and therefore what it costs.
    ///
    /// ── A PRODUCT WITH NO PARTS HAS NO PRICE ──────────────────────────────
    ///
    /// Its price is not typed anywhere. It is the calculator's per-part cost
    /// summed over these, plus the margin above, plus the shop's rounding. So
    /// a sheet that could not hold parts could only ever write a shell — and
    /// that is exactly what it wrote: a product added here came back priced
    /// 0.00, no hours, no grams, until somebody opened the other app.
    ///
    /// The total is shown as it is built, because a margin typed above a cost
    /// nobody can see is a number chosen blind.
    private var partsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("mac.parts")).font(.subheadline.weight(.semibold))
            platesRows

            ForEach(parts) { part in
                HStack(spacing: 8) {
                    Text(part.name.isEmpty ? shop.words.callIt("mac.a_part") : part.name)
                        .lineLimit(1)
                    Text("×\(part.qty)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(partSummary(part)).font(.caption)
                        .foregroundStyle(.secondary).monospacedDigit()
                    // Back into the fields to be changed — a part that came from
                    // the library could only be removed, never corrected.
                    Button {
                        guard let at = parts.firstIndex(where: { $0.id == part.id }) else { return }
                        newPart = parts.remove(at: at)
                        editingOriginal = newPart
                        editingAt = at
                        showRates = true
                    } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .help(shop.words.callIt("common.edit"))
                        // Not over a part being typed — it would be overwritten.
                        .disabled(editingAt != nil || newPart.isComplete || !newPart.name.isEmpty
                                  || newPart.spoolId != nil)
                    Button {
                        parts.removeAll { $0.id == part.id }
                        Task { await reprice() }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .help(shop.words.callIt("common.delete"))
                }
            }

            HStack(spacing: 8) {
                TextField(shop.words.callIt("mac.a_part"), text: $newPart.name)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $newPart.spoolId) {
                    Text(shop.words.callIt("mac.filament")).tag(String?.none)
                    ForEach(shop.spools) { spool in
                        Text(spool.label(shop.words, unit: shop.unit(of: spool)))
                            .tag(String?.some(spool.id))
                    }
                }
                .labelsHidden().frame(width: 150)
            }
            HStack(spacing: 8) {
                TextField(shop.words.callIt("mac.grams"), text: $newPart.grams)
                    .textFieldStyle(.roundedBorder).frame(width: 80).monospacedDigit()
                TextField(shop.words.callIt("mac.hours"), text: $newPart.hours)
                    .textFieldStyle(.roundedBorder).frame(width: 80).monospacedDigit()
                Stepper("× \(newPart.qty)", value: $newPart.qty, in: 1...999)
                    .monospacedDigit().fixedSize()
                Spacer(minLength: 8)
                // Fill the part from a model the shop already has, instead of
                // typing what the library already knows. See `PickModelSheet`.
                Button(shop.words.callIt("link.from_library") + "\u{2026}") { pickingModel = true }
                    .disabled(shop.files.isEmpty)
                if editingAt != nil {
                    Button(shop.words.callIt("common.cancel")) {
                        if let original = editingOriginal {
                            parts.insert(original, at: min(editingAt ?? parts.count, parts.count))
                        }
                        editingAt = nil
                        editingOriginal = nil
                        var next = PartRow()
                        next.rates = rateDefaults
                        newPart = next
                    }
                }
                Button(shop.words.callIt(editingAt == nil ? "mac.add_part" : "mac.update_part")) {
                    parts.insert(newPart, at: min(editingAt ?? parts.count, parts.count))
                    editingAt = nil
                    editingOriginal = nil
                    var next = PartRow()
                    next.rates = rateDefaults
                    newPart = next
                    pickNote = nil
                    Task { await reprice() }
                }
                .disabled(!newPart.isComplete && editingAt == nil)
            }
            // ── WHAT THE PART COSTS BESIDES ITS FILAMENT ──────────────────
            //
            // Folded away because seven figures are the last thing a shop
            // wants between naming a part and adding it, and folded away
            // rather than absent because they are most of what it costs.
            DisclosureGroup(isExpanded: $showRates) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    rateRow("calc.labor.rate", "laborRate", unit: shop.currency)
                    rateRow("calc.labor.prep", "prepTime", unit: shop.words.callIt("common.hours"))
                    rateRow("calc.labor.post", "postTime", unit: shop.words.callIt("common.hours"))
                    rateRow("calc.machine.wear", "wearRate", unit: shop.currency)
                    rateRow("calc.machine.power", "powerDraw", unit: shop.words.callIt("calc.machine.watts"))
                    rateRow("calc.machine.elec", "elecRate", unit: shop.words.callIt("calc.machine.per_kwh"))
                    rateRow("calc.labor.failure", "failureRate", unit: "%")
                }
                .padding(.top, 4)
            } label: {
                Text(shop.words.callIt("mac.part_rates")).font(.caption)
            }
            // A part already in the list that carries none of them is costed
            // at its filament and nothing else, and says so — the same shape
            // as the two notices below, and for the same reason.
            if parts.contains(where: { !$0.hasRates }) {
                Text(shop.words.callIt("mac.part_no_rates"))
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ── WHAT THE FIGURES ARE, WHEN THEY CAME FROM A MODEL ────────────
            //
            // `productNote` and `productProblem` were set by `productFromFile`
            // and read by nothing: a product made from an unsliced model
            // carried an ESTIMATED weight, and the sentence saying so went
            // nowhere. Both are shown here, with the picker's own note.
            if let line = pickNote ?? shop.productNote {
                Text(line).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = shop.productProblem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // WHY IT COSTS THAT, not just what. A price with no working shown
            // is a number a shop cannot argue with when a customer does.
            if let pricing {
                if pricing.parts == 0 {
                    Text(shop.words.callIt("mac.no_parts_no_price"))
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                } else if pricing.cost == 0 && rule.override == nil {
                    // ── THE ONE THAT COULD COST A SHOP ITS PRICE ──────────
                    //
                    // A part with no filament bound costs nothing, so this
                    // product prices to zero — and saving WRITES that over
                    // whatever price the record already had. The other app
                    // overwrites unconditionally too, so this is not a
                    // divergence to fix but a consequence to SHOW: the sample
                    // book has a product recorded at 104.98 whose only part
                    // has no spool, and opening and saving it anywhere would
                    // take it to zero.
                    Text(shop.words.callIt("mac.parts_cost_nothing"))
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        Text(shop.words.callIt("mac.cost") + " "
                             + Money.text(pricing.cost, shop.currency))
                        Text("·").foregroundStyle(.tertiary)
                        Text(shop.words.callIt("mac.price") + " "
                             + Money.text(pricing.price, shop.currency))
                            .fontWeight(.medium)
                        Spacer()
                        Text(Money.quantity(pricing.hours) + " "
                             + shop.words.callIt("common.hours")
                             + " · " + Money.grams(pricing.grams) + " g")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption).monospacedDigit()
                }
            }
        }
        .card(padding: 10)
    }

    // ── WHICH PLATES OF A MULTI-PLATE FILE ────────────────────────────────
    //
    // "If it's a 3MF with multiple plates I should be able to pick which plate
    // to price, all or specific ones" (the shop, Sep 2026). A model whose file
    // the slicer cut into plates shows each as a switch — its time and weight
    // beside it — and All. A plate switched on is a part of this product, priced
    // from that plate's own figures; switched off, the part goes. A part that
    // stood for the whole file is split into its plates the first time one is
    // chosen, and parts already there keep whatever was edited on them.
    private var multiPlateFiles: [LibraryFile] {
        var seen: [String] = []
        for part in parts { if let id = part.printFileId, !seen.contains(id) { seen.append(id) } }
        return seen.compactMap { id in shop.files.first { $0.id == id } }
            .filter { !shop.plates(of: $0).isEmpty }
    }

    @ViewBuilder private var platesRows: some View {
        ForEach(multiPlateFiles) { file in
            let plates = shop.plates(of: file)
            let chosen = chosenPlates(of: file, among: plates)
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("mac.plates") + " — " + file.title)
                    .font(.caption.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(plates, id: \.index) { plate in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(plate.index) },
                            set: { on in
                                // From the parts as they are NOW, not as they
                                // were when this row was last drawn.
                                var next = chosenPlates(of: file, among: plates)
                                if on { next.insert(plate.index) } else { next.remove(plate.index) }
                                Task { await setPlates(of: file, to: next, all: plates) }
                            })) {
                            Text(shop.words.callIt("mac.plate_chip", [
                                "n": .number(Double(plate.index)),
                                "time": .string(Money.quantity((plate.minutes / 60 * 100).rounded() / 100) + " "
                                                + shop.words.callIt("common.hours")),
                                "grams": .string(Money.grams(plate.grams))]))
                                .font(.caption).monospacedDigit()
                        }
                        .toggleStyle(.button)
                        // Not the last one: with no plate on, the model — and
                        // this row with it — would leave the product.
                        .disabled(chosen == [plate.index])
                    }
                    Button(shop.words.callIt("mac.plates_all")) {
                        Task { await setPlates(of: file, to: Set(plates.map(\.index)), all: plates) }
                    }
                    .controlSize(.small)
                    .disabled(chosen.count == plates.count)
                    Spacer()
                }
                // One change at a time, and none while a part is being edited
                // (it is out of the list then, and would be added twice).
                .disabled(platesBusy || editingAt != nil)
            }
        }
    }

    /// The plates of this file on the product; a whole-file part counts as all.
    private func chosenPlates(of file: LibraryFile, among plates: [Shop.Plate]) -> Set<Int> {
        let mine = parts.filter { $0.printFileId == file.id }
        if mine.contains(where: { $0.plate == nil }) { return Set(plates.map(\.index)) }
        return Set(mine.compactMap(\.plate))
    }

    private func setPlates(of file: LibraryFile, to wanted: Set<Int>, all plates: [Shop.Plate]) async {
        guard !platesBusy, !wanted.isEmpty else { return }
        platesBusy = true
        defer { platesBusy = false }
        let at = parts.firstIndex { $0.printFileId == file.id } ?? parts.count
        // A whole-file part becomes its plates — CARRYING what the shop set on
        // it: quantity, spool, rates and anything else it holds. Only the
        // name and the plate's own figures are the plate's.
        let whole = parts.first { $0.printFileId == file.id && $0.plate == nil }
        if whole != nil {
            parts.removeAll { $0.printFileId == file.id && $0.plate == nil }
        }
        parts.removeAll { $0.printFileId == file.id && !wanted.contains($0.plate ?? -1) }
        let have = Set(parts.filter { $0.printFileId == file.id }.compactMap(\.plate))
        var insertAt = min(at, parts.count)
        for plate in plates.map(\.index).sorted() where wanted.contains(plate) {
            if have.contains(plate) {
                if let i = parts.firstIndex(where: { $0.printFileId == file.id && $0.plate == plate }) { insertAt = i + 1 }
                continue
            }
            guard let filled = await shop.partFields(from: file, plate: plate),
                  var row = PartRow.from(.object(filled.part)) else { continue }
            if let whole {
                var carried = whole
                carried.id = UUID()
                carried.raw = whole.raw.merging(filled.part) { $1 }
                carried.name = row.name
                carried.grams = row.grams
                carried.hours = row.hours
                row = carried
            }
            // Never twice: another change may have put it back meanwhile.
            guard !parts.contains(where: { $0.printFileId == file.id && $0.plate == plate }) else { continue }
            parts.insert(row, at: min(insertAt, parts.count))
            insertAt += 1
        }
        await reprice()
    }

    /// One rate, labelled in the other app's own words and carrying its unit.
    private func rateRow(_ key: String, _ field: String, unit: String) -> some View {
        GridRow {
            Text(shop.words.callIt(key)).gridColumnAlignment(.trailing)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("", text: Binding(
                    get: { newPart.rates[field] ?? "" },
                    set: { newPart.rates[field] = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 70).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    private func partSummary(_ part: PartRow) -> String {
        let g = Double(part.grams) ?? 0, h = Double(part.hours) ?? 0
        var bits: [String] = []
        if g > 0 { bits.append(Money.grams(g) + " g") }
        if h > 0 { bits.append(Money.quantity(h) + " " + shop.words.callIt("common.hours")) }
        return bits.joined(separator: " · ")
    }

    /// What prices and what saves: the list, and the part in the fields once
    /// it has a weight or a time. "The price does not update when I make
    /// changes" (the shop, Sep 2026): the fields were counted only after Add
    /// part, so every figure typed there moved nothing — and a part filled in
    /// but never added was dropped by Save. What the sheet shows is what saves.
    private var effectiveParts: [PartRow] {
        Self.pricedParts(parts, pending: newPart, editingAt: editingAt)
    }

    /// The list, with the part in the fields put back where it came from (or
    /// at the end, for a new one) once it has a weight or a time.
    static func pricedParts(_ parts: [PartRow], pending: PartRow, editingAt: Int?) -> [PartRow] {
        // A part taken back to be edited is still the product's, figures or
        // not: clearing its grams to retype them must not drop it on Save.
        guard pending.isComplete || editingAt != nil else { return parts }
        var out = parts
        out.insert(pending, at: min(editingAt ?? out.count, out.count))
        return out
    }

    /// Price what is in the list, through the shared rule.
    private func reprice() async {
        pricing = await shop.priceProduct(parts: effectiveParts.map { $0.record(spools: shop.spools) },
                                          margin: draft.margin,
                                          components: draft.rest["components"],
                                          rule: rule)
    }

    private func written(_ code: String) -> Bool {
        !(draft.names[code] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func name(_ code: String) -> Binding<String> {
        Binding(get: { draft.names[code] ?? "" }, set: { draft.names[code] = $0 })
    }

    private func description(_ code: String) -> Binding<String> {
        Binding(get: { draft.descriptions[code] ?? "" }, set: { draft.descriptions[code] = $0 })
    }

    /// Text, not a number, so "no margin" survives being typed and cleared.
    private var marginText: Binding<String> {
        Binding(
            get: { draft.margin.map { Self.trim($0) } ?? "" },
            set: { typed in
                let cleaned = typed.trimmingCharacters(in: .whitespaces)
                draft.margin = cleaned.isEmpty ? nil : Double(cleaned)
            }
        )
    }

    private func percent(_ value: Double) -> String { Self.trim(value) }

    /// 30 rather than 30.0, and 27.5 kept.
    static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
