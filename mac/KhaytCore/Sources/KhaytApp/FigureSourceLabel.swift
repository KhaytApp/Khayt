import SwiftUI
import KhaytCore

/// "From the sliced file" or "Estimated from the model's shape", small, under
/// the figures it is about — the calculator's From a model row and each line
/// of a job taken from a model.
///
/// An estimate is drawn in the attention colour: it is the figure a shop
/// should look at twice before it reaches a customer. The longer sentence
/// `Shop.modelPart` wrote (which fields, at what rate) is the hover.
struct FigureSourceLabel: View {
    let shop: Shop
    let source: ModelFigureSource
    var note: String?

    var body: some View {
        Label(shop.words.callIt(source.key), systemImage: source.symbol)
            .font(.caption)
            .foregroundStyle(source.wantsAttention ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.secondary))
            // One line in a row that is measured: a wrapping label inside a
            // row whose height the window is measuring is the shape that hung
            // this app before (see `SidebarLayoutTests`).
            .lineLimit(1)
            .help(note ?? shop.words.callIt(source.key))
    }
}
