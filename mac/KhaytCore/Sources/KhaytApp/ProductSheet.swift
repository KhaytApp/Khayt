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
    @FocusState private var focused: Bool

    init(shop: Shop, existing: Product) {
        self.shop = shop
        self.existing = existing
        _draft = State(initialValue: existing)
    }

    private var isNew: Bool { shop.productIds.contains(existing.id) == false }

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
                    Text(shop.words.callIt("cat.title")).gridColumnAlignment(.trailing)
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

            // What this app is NOT editing, said plainly. The alternative is a
            // shop assuming the parts and the photo were dropped on save.
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
                    Task { await shop.saveProduct(saving) }
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
