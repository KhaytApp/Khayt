import SwiftUI
import KhaytCore

/// The calculator's weight and time, filled from a model in the library.
///
/// A tester (Oct 2026) loaded a multi-plate 3MF and found the calculator
/// costing one plate. On this Mac the calculator could not load a model at
/// all — only the catalogue could — so a shop checking a price had to read
/// the figures off the file and type them. This fills them through the SAME
/// rule the catalogue's "from the library" uses (`Shop.partFields(from:plate:)`),
/// so a model costed here and the product made from it start from one figure.
///
/// A project sliced as several plates starts on the WHOLE project — every
/// plate's time and plastic — and any one plate can be costed instead.
///
/// The grams and time are always `partFields`' figures. On top of them,
/// `CalculatorModel.fill` splits the grams into one filament line per colour
/// the slicer weighed (each on the colour planner's spool, else the closest
/// colour on the shelf) and brings the model's consumables.
struct CalculatorFromModel: View {
    @Bindable var shop: Shop
    let calc: CalculatorModel

    @State private var picking = false
    @State private var model: LibraryFile?
    /// Nil is the whole project.
    @State private var plate: Int?

    init(shop: Shop, calc: CalculatorModel, model: LibraryFile? = nil, plate: Int? = nil) {
        self.shop = shop
        self.calc = calc
        _model = State(initialValue: model)
        _plate = State(initialValue: plate)
    }
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            // Where the figures above came from, while they still are the
            // model's: a slice, or the mesh. Gone once the shop types over
            // them — the label must not claim a file for typed numbers.
            if let source = calc.figureSource {
                FigureSourceLabel(shop: shop, source: source, note: calc.filled?.note)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Button(shop.words.callIt("mac.calc_from_model")) { picking = true }
                .controlSize(.small)
            if let model {
                Text(model.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                let plates = shop.plates(of: model)
                if !plates.isEmpty {
                    Picker("", selection: $plate) {
                        Text(shop.words.callIt("mac.calc_whole_project",
                                               ["plates": .string(shop.words.counting(plates.count, "mac.n_plates"))]))
                            .tag(Int?.none)
                        ForEach(plates, id: \.index) { p in
                            Text(p.name.map { shop.words.callIt("mac.plate_named", ["n": .number(Double(p.index)), "name": .string($0)]) }
                                 ?? shop.words.callIt("mac.plate_n", ["n": .number(Double(p.index))]))
                                .tag(Int?.some(p.index))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .shopSheet(isPresented: $picking) {
            PickModelSheet(shop: shop) { file in
                model = file
                plate = nil
                Task { await fill() }
            }
        }
        .onChange(of: plate) { _, _ in Task { await fill() } }
    }

    /// The chosen model's (or plate's) figures into the two fields.
    ///
    /// Through `CalculatorModel.fillFromModel`, the one way a model's figures
    /// reach a calculator — the library's "Quote this model…" uses it too, so
    /// the two cannot start from different figures.
    private func fill() async {
        guard let model else { return }
        problem = await calc.fillFromModel(model, plate: plate, shop: shop)
    }
}
