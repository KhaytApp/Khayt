import KhaytCore
import SwiftUI

/// The library's two filter menus, Colour and File type (Figma R9W19 174:3,
/// 174:50, 174:137). The rules are `LibraryFilter`; this only draws them.
enum LibraryFilterMenu: String, Identifiable, Sendable {
    case colour, type
    var id: String { rawValue }

    var title: String { L10n.tr(self == .colour ? "library.filter.colour" : "library.filter.type") }
    var keys: [String] { self == .colour ? LibraryFilter.colourKeys : LibraryFilter.typeKeys }
    /// The row after which a divider sets the last ones apart.
    var dividerBefore: String { self == .colour ? ColourFamily.multi : ModelFileType.noFile.rawValue }

    func picks(_ filter: LibraryFilter) -> Set<String> { self == .colour ? filter.colours : filter.types }
    func ordered(_ filter: LibraryFilter) -> [String] { self == .colour ? filter.orderedColours : filter.orderedTypes }

    func counts(_ facets: LibraryFacets) -> [String: Int] { self == .colour ? facets.colour : facets.type }

    func set(_ picks: Set<String>, in filter: inout LibraryFilter) {
        if self == .colour { filter = LibraryFilter(colours: picks, types: filter.types) }
        else { filter = LibraryFilter(colours: filter.colours, types: picks) }
    }

    /// A row's name in the app's language.
    func name(_ key: String) -> String {
        switch (self, key) {
        case (.colour, ColourFamily.multi): L10n.tr("library.filter.multi")
        case (.colour, ColourFamily.noInfo): L10n.tr("library.filter.none")
        case (.colour, _): L10n.tr("colour.\(key)")
        case (.type, _): L10n.tr("library.type.\(key)")
        }
    }
}

/// The two buttons under the search field, and — when something is picked —
/// the line saying what is applied.
struct LibraryFilterBar: View {
    @Binding var filter: LibraryFilter
    let facets: LibraryFacets
    /// Models found with the filters, and before them when that is known.
    let shown: Int
    let of: Int?
    @Binding var open: LibraryFilterMenu?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                button(.colour)
                button(.type)
                Spacer(minLength: 0)
            }
            if !filter.isEmpty { applied }
        }
    }

    private func button(_ menu: LibraryFilterMenu) -> some View {
        let n = menu.picks(filter).count
        return Button { open = menu } label: {
            HStack(spacing: 6) {
                Text(menu.title).font(.khayt(14, .semibold, relativeTo: .subheadline)).foregroundStyle(KhaytDesign.ink)
                if n > 0 {
                    Text(n.formatted(.number.locale(L10n.locale)))
                        .font(.khaytMono(13, .semibold, relativeTo: .subheadline)).foregroundStyle(KhaytDesign.attention)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(KhaytDesign.note)
            }
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(n > 0 ? KhaytDesign.threadWash : KhaytDesign.sunk, in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(item: Binding(get: { open == menu ? menu : nil }, set: { open = $0 }), arrowEdge: .top) { m in
            LibraryFilterMenuView(menu: m, filter: $filter, counts: m.counts(facets))
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(n > 0 ? L10n.format("library.filter.chosen", menu.title, n) : menu.title)
        .accessibilityAddTraits(.isButton)
    }

    private var applied: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text(of.map { L10n.format("library.filter.n_of_m", shown, $0) } ?? L10n.format("library.found", shown))
                        .font(.khayt(12.5, relativeTo: .footnote).monospacedDigit()).foregroundStyle(KhaytDesign.note)
                        .fixedSize()
                    ForEach([LibraryFilterMenu.colour, .type]) { menu in
                        let keys = menu.ordered(filter)
                        if !keys.isEmpty { pill(menu, keys) }
                    }
                }
            }
            // Always in reach, however many pills there are.
            Button(L10n.tr("common.clear")) { filter = LibraryFilter() }
                .font(.khayt(13.5, .semibold, relativeTo: .footnote)).foregroundStyle(KhaytDesign.brand)
                .buttonStyle(.plain)
                .fixedSize()
                .tapTarget()
        }
    }

    private func pill(_ menu: LibraryFilterMenu, _ keys: [String]) -> some View {
        let text = L10n.format("library.filter.pill", menu.title,
                               keys.map(menu.name).formatted(.list(type: .and, width: .narrow).locale(L10n.locale)))
        return Button { menu.set([], in: &filter) } label: {
            HStack(spacing: 6) {
                Text(text).font(.khayt(12, .semibold, relativeTo: .footnote)).foregroundStyle(KhaytDesign.ink)
                    .lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(KhaytDesign.note)
            }
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(KhaytDesign.sunk, in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("library.filter.remove", text))
    }
}

/// One menu's rows: tick, swatch, name, count; a divider before the last
/// group; a line under them. A row nothing would match is greyed, not
/// removed — it can still be unticked.
struct LibraryFilterMenuView: View {
    let menu: LibraryFilterMenu
    @Binding var filter: LibraryFilter
    let counts: [String: Int]

    var body: some View {
        // Its ideal height is the rows', so the popover is as tall as they
        // are and scrolls only where the screen is shorter (large type).
        ScrollView { content }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 340)
        .background(KhaytDesign.surface)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(menu.keys, id: \.self) { key in
                if key == menu.dividerBefore { Divider().padding(.vertical, 2) }
                row(key)
            }
            Text(L10n.tr(menu == .colour ? "library.filter.colour_hint" : "library.filter.counts_hint"))
                .font(.khayt(11.5, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)
        }
        .padding(.top, 2)
    }

    private func row(_ key: String) -> some View {
        let on = menu.picks(filter).contains(key)
        let n = counts[key] ?? 0
        return Button {
            var picks = menu.picks(filter)
            if on { picks.remove(key) } else { picks.insert(key) }
            menu.set(picks, in: &filter)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KhaytDesign.brand).opacity(on ? 1 : 0).frame(width: 14)
                if menu == .colour { LibraryFilterSwatch(key: key) }
                Text(menu.name(key)).font(.khayt(15, relativeTo: .body)).foregroundStyle(KhaytDesign.ink)
                Spacer(minLength: 8)
                Text(n.formatted(.number.locale(L10n.locale)))
                    .font(.khaytMono(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            }
            .padding(.horizontal, 14).frame(minHeight: 40).contentShape(Rectangle())
            .opacity(n == 0 && !on ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("library.filter.row", menu.name(key), n))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// A Colour row's swatch: the family's colour with a thin ring (so white
/// shows on white), a pie of colours for Multicolour, and a dashed ring for
/// No colour info.
struct LibraryFilterSwatch: View {
    let key: String
    var side: CGFloat = 14

    var body: some View {
        Group {
            if let family = ColourFamily(rawValue: key) {
                Circle().fill(Color(modelHex: family.swatchHex) ?? .gray)
                    .overlay(Circle().strokeBorder(KhaytDesign.note.opacity(0.45), lineWidth: 1))
            } else if key == ColourFamily.multi {
                Circle().fill(AngularGradient(colors: Self.multi, center: .center))
                    .overlay(Circle().strokeBorder(KhaytDesign.note.opacity(0.45), lineWidth: 1))
            } else {
                Circle().strokeBorder(KhaytDesign.note, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private static let multi: [Color] = [ColourFamily.red, .yellow, .green, .blue, .purple, .red]
        .compactMap { Color(modelHex: $0.swatchHex) }
}

extension Color {
    /// A colour as a model's record holds it, read by the same rule the
    /// filter reads it with (`ColourFamily.rgb`: 3, 4, 6 or 8 digits).
    init?(modelHex: String) {
        guard let c = ColourFamily.rgb(ofHex: modelHex) else { return nil }
        self.init(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}
