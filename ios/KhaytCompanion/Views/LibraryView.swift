import SwiftUI

/// The shop's library, from the phone: find a model a customer is asking
/// about and price it. The library stays on the Mac — ten thousand models in
/// a real shop — so every search and every folder is a question to it
/// (`GET /api/library`), and the price is measured there too.
struct LibraryView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LibraryFolderPage(folder: "")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common.close")) { dismiss() } }
                }
                .navigationDestination(item: $opened) { LibraryItemPage(item: $0) }
        }
        #if DEBUG
        .onAppear {
            // `-KhaytOpen library:<id>`: straight to a sample model, for screenshots.
            if let v = UserDefaults.standard.string(forKey: "KhaytOpen"), v.hasPrefix("library:") {
                opened = SampleLibrary.items.first { $0.id == v.dropFirst("library:".count) }
            }
        }
        #endif
    }

    @State private var opened: LibraryItem?
}

/// One folder of the library, or — while something is typed — a search of
/// all of it.
struct LibraryFolderPage: View {
    let folder: String
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var query = ""
    @State private var page: LibraryPage?
    @State private var more: [LibraryItem] = []
    @State private var problem: String?
    @State private var loading = false

    private var title: String {
        folder.isEmpty ? L10n.tr("library.title") : (folder.split(separator: "/").last.map(String.init) ?? folder)
    }
    private var items: [LibraryItem] { (page?.items ?? []) + more }

    var body: some View {
        List {
            Section {
                KhaytSearchField(text: $query, prompt: L10n.tr("library.search"))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            if let problem {
                Section { V2Note(text: problem, tone: KhaytDesign.late).listRowBackground(Color.clear) }
            }
            if page?.fromCopy == true {
                Section { V2Note(text: L10n.tr("library.from_copy")).listRowBackground(Color.clear) }
            }
            if let page, !page.folders.isEmpty {
                Section(L10n.tr("library.folders")) {
                    ForEach(page.folders) { f in
                        NavigationLink { LibraryFolderPage(folder: f.path) } label: { folderRow(f) }
                            .listRowBackground(KhaytDesign.surface)
                    }
                }
            }
            if !items.isEmpty {
                Section(query.isEmpty ? L10n.tr("library.models") : L10n.format("library.found", page?.total ?? items.count)) {
                    ForEach(items) { item in
                        NavigationLink { LibraryItemPage(item: item) } label: { LibraryRow(item: item) }
                            .listRowBackground(KhaytDesign.surface)
                    }
                    if let page, items.count < page.total {
                        Button(L10n.tr("library.more")) { Task { await loadMore() } }
                            .disabled(loading)
                            .listRowBackground(KhaytDesign.surface)
                    }
                }
            } else if let page, page.folders.isEmpty, !loading, problem == nil {
                Section {
                    Text(L10n.tr(query.isEmpty ? "library.empty" : "library.no_match"))
                        .font(.khayt(14, relativeTo: .body)).foregroundStyle(KhaytDesign.note)
                        .listRowBackground(Color.clear)
                }
            }
            if loading && page == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .khaytScreen(title: title)
        .navigationBarTitleDisplayMode(folder.isEmpty ? .large : .inline)
        // A short pause while typing, so each letter is not its own question.
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .refreshable { await load() }
    }

    private func folderRow(_ f: LibraryFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KhaytDesign.brand)
                .frame(width: 36, height: 36)
                .background(KhaytDesign.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            Text(f.name).font(.khayt(15, .medium, relativeTo: .body)).foregroundStyle(KhaytDesign.ink).lineLimit(2)
            Spacer(minLength: 4)
            Text(f.count.formatted(.number.locale(L10n.locale)))
                .font(.khayt(13, relativeTo: .footnote).monospacedDigit()).foregroundStyle(KhaytDesign.note)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            page = try await api.fetchLibrary(query: query, folder: query.isEmpty ? folder : "")
            more = []
            problem = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            page = nil
            more = []
            problem = KhaytAPIClient.say(error)
        }
    }

    private func loadMore() async {
        loading = true
        defer { loading = false }
        guard let next = try? await api.fetchLibrary(query: query, folder: query.isEmpty ? folder : "",
                                                    offset: items.count) else { return }
        let seen = Set(items.map(\.id))
        more += next.items.filter { !seen.contains($0.id) }
    }
}

struct LibraryRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 12) {
            LibraryThumb(item: item, side: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if item.favorite {
                        Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(KhaytDesign.attention)
                            .accessibilityLabel(L10n.tr("library.favorite"))
                    }
                    Text(item.name).font(.khayt(15, .medium, relativeTo: .body)).foregroundStyle(KhaytDesign.ink).lineLimit(2)
                }
                if let line = LibraryItemPage.figures(item) {
                    Text(line).font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note).lineLimit(1)
                } else if let folder = item.folder {
                    Text(folder).font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note).lineLimit(1)
                }
            }
        }
    }
}

/// The model's picture from the Mac, or a cube where it has none.
struct LibraryThumb: View {
    let item: LibraryItem
    let side: CGFloat
    @EnvironmentObject private var api: KhaytAPIClient
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side > 100 ? 14 : 9).fill(KhaytDesign.sunk)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "cube").font(.system(size: side * 0.36, weight: .light)).foregroundStyle(KhaytDesign.note)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 100 ? 14 : 9))
        .accessibilityHidden(true)
        .task(id: item.id) {
            guard item.thumb, image == nil, let data = await api.libraryThumb(id: item.id) else { return }
            image = UIImage(data: data)
        }
    }
}

/// One model: what the library knows about it, and its price.
struct LibraryItemPage: View {
    let item: LibraryItem
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var qty = 1
    @State private var plate: Int?
    @State private var answer: KhaytAPIClient.ModelEstimate?
    @State private var problem: String?
    /// A refusal that is not a fault — no Mac to ask — reads calmly.
    @State private var problemIsQuiet = false
    @State private var asking = false
    @State private var makingQuote = false
    @State private var calculating = false
    @State private var machines: [MachineInfo] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    LibraryThumb(item: item, side: 112)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.khayt(19, .semibold, relativeTo: .title3)).foregroundStyle(KhaytDesign.ink)
                        if let folder = item.folder {
                            Text(folder).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                        }
                        if let material = item.material {
                            Text(material).font(.khayt(13, .medium, relativeTo: .footnote)).foregroundStyle(KhaytDesign.ink)
                        }
                        if let n = item.timesPrinted, n > 0 {
                            Text(L10n.format("library.printed", n)).font(.khayt(12.5, relativeTo: .footnote))
                                .foregroundStyle(KhaytDesign.note)
                        }
                    }
                }
                .padding(.bottom, 4)

                V2FieldCard {
                    if item.plates.count > 1 {
                        V2Field(label: L10n.tr("library.plate")) {
                            Picker(L10n.tr("library.plate"), selection: $plate) {
                                Text(L10n.tr("library.plate.all")).tag(Int?.none)
                                ForEach(item.plates) { p in
                                    Text(p.name ?? L10n.format("library.plate.n", p.index)).tag(Optional(p.index))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    V2Field(label: L10n.tr("order.field.quantity"), last: true) {
                        Stepper(value: $qty, in: 1...1000) {
                            Text(qty.formatted(.number.locale(L10n.locale))).monospacedDigit()
                        }
                    }
                }

                if asking {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if let answer, answer.ok, answer.price != nil {
                    EstimateCard(answer: answer)
                    V2PrimaryButton(title: L10n.tr("quote.file.make_quote")) { makingQuote = true }
                }
                if let problem { V2Note(text: problem, tone: problemIsQuiet ? KhaytDesign.note : KhaytDesign.late) }
                if api.holdsBook {
                    Button { calculating = true } label: {
                        Label(L10n.tr("library.calculator"), systemImage: "function")
                            .font(.khayt(15, .semibold, relativeTo: .body))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .tint(KhaytDesign.brand)
                }
                if let notes = item.testedNotes {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("library.notes")).font(.khayt(12, .semibold, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                        Text(notes).font(.khayt(14, relativeTo: .body)).foregroundStyle(KhaytDesign.ink)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
                }
            }
            .padding(16)
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(qty)|\(plate ?? 0)") { await ask() }
        .task { machines = (try? await api.fetchMachines()) ?? [] }
        .sheet(isPresented: $makingQuote) { NewOrderSheet(machines: machines, onCreated: {}, initial: draft) }
        .sheet(isPresented: $calculating) { CalculatorScreen(asSheet: true, seed: seed) }
    }

    /// The figures on one line: time and weight, when a slicer recorded them.
    static func figures(_ item: LibraryItem) -> String? {
        var bits: [String] = []
        if let m = item.printTimeMins {
            bits.append(L10n.format("quote.file.hours", (m / 60).formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))))
        }
        if let g = item.grams { bits.append(L10n.grams(Int(g.rounded()))) }
        if let material = item.material { bits.append(material) }
        return bits.count > (item.material == nil ? 0 : 1) ? bits.joined(separator: " · ") : nil
    }

    /// The calculator's start: the Mac's figures when it gave some, else what
    /// the slicer recorded on the model (or the chosen plate).
    private var seed: CalculatorSeed {
        let chosen = plate.flatMap { p in item.plates.first { $0.index == p } }
        let recordedGrams = chosen?.grams ?? item.grams
        let recordedHours = (chosen?.printTimeMins ?? item.printTimeMins).map { $0 / 60 }
        // Both computers answer grams and hours for one piece; the price is
        // for the quantity.
        return CalculatorSeed(grams: answer?.grams ?? recordedGrams, hours: answer?.hours ?? recordedHours,
                              qty: qty, material: item.material)
    }

    private var draft: NewOrderDraft {
        var d = NewOrderDraft()
        d.project = item.name
        d.isQuote = true
        if let p = answer?.price { d.price = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), p) }
        return d
    }

    private func ask() async {
        problemIsQuiet = true
        guard item.estimable || item.grams != nil else {
            answer = nil
            problem = L10n.tr("library.not_estimable")
            return
        }
        guard !api.isSampleShop else {
            answer = nil
            problem = L10n.tr("library.sample")
            return
        }
        asking = true
        problem = nil
        problemIsQuiet = false
        defer { asking = false }
        do {
            let a = try await api.estimate(libraryId: item.id, qty: qty, plate: plate)
            answer = a
            if !a.ok { problem = Self.reason(a.reason) }
        } catch is CancellationError {
        } catch {
            answer = nil
            problem = KhaytAPIClient.say(error)
        }
    }

    static func reason(_ r: String?) -> String {
        switch r {
        case "no-file": return L10n.tr("library.reason.no-file")
        case "not-found": return L10n.tr("library.reason.not-found")
        case "not-configured": return L10n.tr("library.reason.not-configured")
        default: return QuoteFileSheet.reason(r)
        }
    }
}

/// The Mac's price for a model, with the weight and time it came from.
struct EstimateCard: View {
    let answer: KhaytAPIClient.ModelEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let price = answer.price {
                Text(Money.text(price, answer.currency))
                    .font(.khayt(30, .semibold, relativeTo: .largeTitle).monospacedDigit())
                    .foregroundStyle(KhaytDesign.ink)
            }
            HStack(spacing: 14) {
                if let g = answer.grams { Text(L10n.grams(Int(g.rounded()))) }
                if let h = answer.hours {
                    Text(L10n.format("quote.file.hours", h.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))))
                }
            }
            .font(.khayt(14, relativeTo: .subheadline)).foregroundStyle(KhaytDesign.note)
            Text(L10n.tr(answer.exact == true ? "quote.file.exact" : "quote.file.estimated"))
                .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
            if answer.onPhone == true {
                Text(L10n.tr("library.priced_here"))
                    .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
            }
            if answer.reliable == false {
                Label(L10n.tr("quote.file.unreliable"), systemImage: "exclamationmark.triangle")
                    .font(.khayt(12.5, .medium, relativeTo: .footnote)).foregroundStyle(KhaytDesign.attention)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}
