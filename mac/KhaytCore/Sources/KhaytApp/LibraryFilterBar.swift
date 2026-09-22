import SwiftUI
import KhaytCore

/// Narrowing a library of hundreds down to what somebody is looking for.
///
/// ── WHAT IS HERE AND WHY ──────────────────────────────────────────────────
///
/// Three axes, and they are not the same kind of question:
///
///   UNFILED  — models in no project at all. The answer to "what have I not
///              filed yet", which is the useful one on a library that has just
///              been imported: eighty-three of a hundred and fifty-two files
///              here are in no project, and there was no way to find them.
///   CATEGORY — what a thing IS. Wall art, functional parts, dental.
///   TAG      — everything that is neither, many per model.
///
/// The GROUP axis is deliberately absent: a group is a folder in the grid now,
/// and opening one is navigating rather than filtering. Unfiled is the
/// exception, because there is no folder to open for models that are in none.
///
/// The row itself — the chips, the rule under it, and the hiding when there is
/// nothing to offer — is `FilterBar`, which the catalogue uses too. What is
/// here is only what the chips MEAN.
struct LibraryFilterBar: View {
    @Bindable var shop: Shop

    /// Counts come from the shared rule, which FOLDS SPELLINGS: a shop that
    /// typed "Wall art" once and "wall art" twice gets one chip holding all
    /// three, not two chips each holding part. `Shop.libraryFacets` carries the
    /// rest of the argument — why they follow the shelf, the search and each
    /// other.
    private var facets: Shop.LibraryFacets { shop.libraryFacets }

    private var chips: [FilterChipModel] {
        var out: [FilterChipModel] = []
        // A chip that is ON stays on the row even at zero. Its count can fall to
        // nothing when another chip narrows past it, and a filter that vanishes
        // while still narrowing the screen leaves a shop looking at an empty
        // grid with nothing on it to explain why.
        if facets.unfiled > 0 || shop.libraryUnfiledOnly {
            out.append(FilterChipModel(id: "unfiled",
                                       label: shop.words.callIt("plib.unfiled"),
                                       count: facets.unfiled,
                                       on: shop.libraryUnfiledOnly) {
                shop.libraryUnfiledOnly.toggle()
            })
        }
        // WHAT THIS SHOP HAS COLLECTED AND NEVER MADE. Beside Unfiled because
        // it is the same kind of question — a property of the model rather than
        // a name somebody gave it — and because both are the ones worth asking
        // of a library that has just grown by a hundred files.
        //
        // Khayt counts real prints, so this chip is a FACT. The other tools in
        // this category carry a status somebody ticks, which answers "did I
        // mean to print this" rather than "did I".
        if facets.neverPrinted > 0 || shop.libraryNeverPrintedOnly {
            out.append(FilterChipModel(id: "never-printed",
                                       label: shop.words.callIt("mac.never_printed"),
                                       count: facets.neverPrinted,
                                       on: shop.libraryNeverPrintedOnly) {
                shop.libraryNeverPrintedOnly.toggle()
            })
        }
        for row in Self.withActive(facets.categories, shop.libraryCategory) {
            out.append(FilterChipModel(id: "category:" + row.name, label: row.name,
                                       count: row.count,
                                       on: shop.libraryCategory == .named(row.name)) {
                shop.libraryCategory =
                    shop.libraryCategory == .named(row.name) ? nil : .named(row.name)
            })
        }
        for row in Self.withActive(facets.tags, shop.libraryTag.map { Shop.FilterChoice.named($0) }) {
            // A tag is marked as one. The library's categories and its tags are
            // different kinds of answer and a shop should not have to remember
            // which half of the row it is looking at.
            out.append(FilterChipModel(id: "tag:" + row.name, label: "#" + row.name,
                                       count: row.count,
                                       on: shop.libraryTag?.lowercased() == row.name.lowercased()) {
                shop.libraryTag =
                    shop.libraryTag?.lowercased() == row.name.lowercased() ? nil : row.name
            })
        }
        return out
    }

    /// Keep the chosen value on the row even when the other axes have narrowed
    /// it to nothing, at the count it actually has.
    static func withActive(_ rows: [KhaytEngine.GroupCount],
                           _ chosen: Shop.FilterChoice?) -> [KhaytEngine.GroupCount] {
        guard case .named(let name)? = chosen,
              !rows.contains(where: { $0.name.lowercased() == name.lowercased() })
        else { return rows }
        return rows + [KhaytEngine.GroupCount(name: name, count: 0)]
    }

    var body: some View {
        FilterBar(chips: chips,
                  showingClear: shop.libraryFilterOn,
                  clearLabel: shop.words.callIt("log.clear_filters")) {
            shop.clearLibraryFilter()
        }
    }
}
