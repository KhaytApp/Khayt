import SwiftUI
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
    @State private var newPart = PartRow()
    /// What those parts cost, priced by the shared rule.
    @State private var pricing: KhaytEngine.ProductPricing?
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
    struct PartRow: Identifiable, Equatable {
        var id = UUID()
        var name = ""
        var spoolId: String?
        var grams = ""
        var hours = ""
        var qty = 1

        var isComplete: Bool { (Double(grams) ?? 0) > 0 || (Double(hours) ?? 0) > 0 }

        /// The record shape a product's `parts` list holds.
        func record(spools: [Spool]) -> JSONValue {
            var o: [String: JSONValue] = [
                "name": .string(name),
                "printWeight": .number(max(0, Double(grams) ?? 0)),
                "supportWeight": .number(0),
                "printTime": .number(max(0, Double(hours) ?? 0)),
                "qty": .number(Double(max(1, qty))),
            ]
            if let spoolId, let spool = spools.first(where: { $0.id == spoolId }) {
                o["filamentId"] = .string(spool.id)
                o["material"] = .string(spool.material)
                o["spoolCost"] = .number(spool.cost ?? 0)
                o["spoolWeight"] = .number(max(1, spool.weight ?? 1000))
            }
            return .object(o)
        }

        @MainActor static func from(_ value: JSONValue) -> PartRow? {
            guard case .object(let o) = value else { return nil }
            var row = PartRow()
            row.name = Shop.plainString(o["name"]) ?? ""
            row.spoolId = Shop.plainString(o["filamentId"])
            row.grams = Money.quantity(Shop.plainNumber(o["printWeight"]) ?? 0)
            row.hours = Money.quantity(Shop.plainNumber(o["printTime"]) ?? 0)
            row.qty = Int(Shop.plainNumber(o["qty"]) ?? 1)
            return row
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt(isNew ? "mac.new_product" : "mac.edit_product"))
                .font(.headline)

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
                GridRow {
                    Text(shop.words.callIt("plib.group")).gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TextField("", text: $draft.group).textFieldStyle(.roundedBorder)
                }
            }

            Divider()
            partsSection

            Divider()
            ProductPictureStrip(shop: shop, productId: draft.id,
                                pictures: $pictures, removed: $removedPictures)

            // What this app is STILL not editing. It was "parts, prices per
            // quantity and documents" — and parts came off that list when this
            // sheet learnt to hold them, because a product with no parts has no
            // price, which made "written down on the Mac" mean "a shell you
            // have to finish in the other app".
            if !isNew {
                Text(shop.words.callIt("mac.product_kept"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                    let rows = parts.map { $0.record(spools: shop.spools) }
                    Task { await shop.saveProduct(saving, pictures: staged,
                                                  unlinking: unlink, parts: rows) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.hasAName)
            }
        }
        .padding(18)
        .frame(width: Self.width)
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
            await reprice()
        }
        // Re-priced when the margin changes, because the margin is above the
        // parts on this sheet and a shop typing one is watching the total.
        .task(id: draft.margin) { await reprice() }
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

            ForEach(parts) { part in
                HStack(spacing: 8) {
                    Text(part.name.isEmpty ? shop.words.callIt("mac.a_part") : part.name)
                        .lineLimit(1)
                    Text("×\(part.qty)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(partSummary(part)).font(.caption)
                        .foregroundStyle(.secondary).monospacedDigit()
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
                Button(shop.words.callIt("mac.add_part")) {
                    parts.append(newPart)
                    newPart = PartRow()
                    Task { await reprice() }
                }
                .disabled(!newPart.isComplete)
            }

            // WHY IT COSTS THAT, not just what. A price with no working shown
            // is a number a shop cannot argue with when a customer does.
            if let pricing {
                if pricing.parts == 0 {
                    Text(shop.words.callIt("mac.no_parts_no_price"))
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                } else if pricing.cost == 0 {
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

    private func partSummary(_ part: PartRow) -> String {
        let g = Double(part.grams) ?? 0, h = Double(part.hours) ?? 0
        var bits: [String] = []
        if g > 0 { bits.append(Money.grams(g) + " g") }
        if h > 0 { bits.append(Money.quantity(h) + " " + shop.words.callIt("common.hours")) }
        return bits.joined(separator: " · ")
    }

    /// Price what is in the list, through the shared rule.
    private func reprice() async {
        pricing = await shop.priceProduct(parts: parts.map { $0.record(spools: shop.spools) },
                                          margin: draft.margin,
                                          components: draft.rest["components"])
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
