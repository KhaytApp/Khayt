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
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 8) {
            Button(shop.words.callIt("mac.calc_from_model")) { picking = true }
                .controlSize(.small)
            if let model {
                Text(model.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                let plates = shop.plates(of: model)
                if !plates.isEmpty {
                    Picker("", selection: $plate) {
                        Text(shop.words.callIt("mac.calc_whole_project", ["n": .number(Double(plates.count))]))
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
        .sheet(isPresented: $picking) {
            PickModelSheet(shop: shop) { file in
                model = file
                plate = nil
                Task { await fill() }
            }
        }
        .onChange(of: plate) { _, _ in Task { await fill() } }
    }

    /// The chosen model's (or plate's) figures into the two fields.
    private func fill() async {
        guard let model else { return }
        problem = nil
        guard let made = await shop.partFields(from: model, plate: plate) else {
            problem = shop.productProblem; return
        }
        let g = Shop.plainNumber(made.part["printWeight"]) ?? 0
        let h = Shop.plainNumber(made.part["printTime"]) ?? 0
        guard g > 0 || h > 0 else { problem = shop.words.callIt("mac.calc_model_none"); return }
        calc.fill(from: model, plate: plate, grams: g, hours: h, shop: shop)
    }
}
