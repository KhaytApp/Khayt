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
        // THE LIST THE SHOP KEEPS of what to print next — first, because it is
        // the one opened on purpose rather than found by narrowing.
        if facets.printNext > 0 || shop.libraryPrintNextOnly {
            out.append(FilterChipModel(id: "print-next", label: shop.words.callIt("mac.print_next"),
                                       count: facets.printNext, on: shop.libraryPrintNextOnly) {
                shop.libraryPrintNextOnly.toggle()
            })
        }
        // Copies nobody could see: the same file, or the same mesh re-saved.
        if facets.duplicates > 0 || shop.libraryDuplicatesOnly {
            out.append(FilterChipModel(id: "duplicates", label: shop.words.callIt("mac.duplicates"),
                                       count: facets.duplicates, on: shop.libraryDuplicatesOnly) {
                shop.libraryDuplicatesOnly.toggle()
            })
        }
        // THE ARCHIVED VIEW: what has been put aside, by hand or by a
        // conversion, and the one place it can be restored from. Offered only
        // when there is something in it, or while it is open.
        if facets.archived > 0 || shop.libraryShowArchived {
            out.append(FilterChipModel(id: "archived", label: shop.words.callIt("mac.lib_archived"),
                                       count: facets.archived, on: shop.libraryShowArchived) {
                shop.libraryShowArchived.toggle()
            })
        }
        // WHERE THE BYTES ARE (`LibrarySyncIndex`): a pair, one on at a time.
        for (id, filter, key) in [("online-only", LibraryStorageFilter.onlineOnly, "mac.lib_online_only"),
                                  ("this-mac-only", LibraryStorageFilter.thisMacOnly, "mac.lib_this_mac_only")] {
            let count = filter == .onlineOnly ? facets.onlineOnly : facets.thisMacOnly
            if count > 0 || shop.libraryStorage == filter {
                out.append(FilterChipModel(id: id, label: shop.words.callIt(key), count: count,
                                           on: shop.libraryStorage == filter) {
                    shop.libraryStorage = shop.libraryStorage == filter ? nil : filter
                })
            }
        }
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
        // NOTHING TO PRICE FROM, and WHAT THE SHOP SELLS — the two questions
        // the smart folders added (`LibrarySmartFolder`). Counted like the
        // rest, over what the other axes leave.
        if facets.noFigures > 0 || shop.libraryNoFiguresOnly {
            out.append(FilterChipModel(id: "no-figures", label: shop.words.callIt("mac.ls_no_figures"),
                                       count: facets.noFigures, on: shop.libraryNoFiguresOnly) {
                shop.libraryNoFiguresOnly.toggle()
            })
        }
        if facets.inCatalogue > 0 || shop.libraryInCatalogueOnly {
            out.append(FilterChipModel(id: "in-catalogue", label: shop.words.callIt("mac.ls_in_catalogue"),
                                       count: facets.inCatalogue, on: shop.libraryInCatalogueOnly) {
                shop.libraryInCatalogueOnly.toggle()
            })
        }
        // Any machine at all — the "Ready to print" smart folder, typed into
        // the Ready on menu as its first item. One or the other: choosing a
        // machine takes "any" off, and the other way round.
        if facets.readyAnywhere > 0 || shop.libraryReadyAnywhere {
            out.append(FilterChipModel(id: "ready:*", label: shop.words.callIt("mac.ls_ready_any"),
                                       count: facets.readyAnywhere, on: shop.libraryReadyAnywhere) {
                shop.libraryReadyAnywhere.toggle()
                if shop.libraryReadyAnywhere { shop.libraryReadyOn = nil }
            })
        }
        // WHAT CAN START NOW, on each machine that says what it has loaded:
        // every colour the model needs is in a head, in a material that fits.
        // Beside the other facts, because it is the question asked before every
        // job — and only for a machine that reports its spools, since a count
        // made from a guess would send a shop to a printer to find it wrong.
        for row in facets.ready where row.count > 0 || shop.libraryReadyOn == row.machineId {
            out.append(FilterChipModel(id: "ready:" + row.machineId,
                                       label: shop.words.callIt("mac.ready_on", ["name": .string(row.machineName)]),
                                       count: row.count,
                                       on: shop.libraryReadyOn == row.machineId) {
                shop.libraryReadyOn = shop.libraryReadyOn == row.machineId ? nil : row.machineId
                if shop.libraryReadyOn != nil { shop.libraryReadyAnywhere = false }
            })
        }
        // WHO MADE IT — the busiest eight, and the one chosen whatever its count.
        var creators = Array(facets.creators.prefix(8))
        if let chosen = shop.libraryCreator,
           !creators.contains(where: { $0.name.lowercased() == chosen.lowercased() }) {
            creators.append(facets.creators.first { $0.name.lowercased() == chosen.lowercased() }
                            ?? .init(name: chosen, count: 0))
        }
        for row in creators {
            out.append(FilterChipModel(id: "creator:" + row.name,
                                       label: shop.words.callIt("mac.by_creator", ["name": .string(row.name)]),
                                       count: row.count,
                                       on: shop.libraryCreator?.lowercased() == row.name.lowercased()) {
                shop.libraryCreator =
                    shop.libraryCreator?.lowercased() == row.name.lowercased() ? nil : row.name
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

    // ── MENUS, NOT A STRIP OF BUBBLES ──────────────────────────────────────
    //
    // Every creator, category and tag used to be its own chip in one row, so
    // the row grew with the library and ran off the window: the shop called
    // it "too many bubbles to go through". Each axis is now one menu that
    // says what it is set to and holds any number of choices, with counts.
    // The rules behind them (what counts, the folding of spellings, a chosen
    // value kept even at zero) are unchanged: `chips` above is what the menus
    // are built from, so the two cannot disagree.
    var body: some View {
        let all = chips
        HStack(spacing: 8) {
            // ── NEVER A CHIP CUT IN HALF ────────────────────────────────────
            //
            // The row first scrolled sideways under a fade, and at 1320
            // points the Tag menu sat half-hidden behind the model count as
            // "Ta" — a label cut mid-word reads as broken. Now the row is
            // drawn with as many axis menus as fit WHOLE, and the rest go
            // into one More menu: every axis, all five, five to none inline.
            ViewThatFits(in: .horizontal) {
                ForEach((0...Self.axes.count).reversed(), id: \.self) { inline in
                    filters(all, inline: inline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // ── HOW IT IS SHOWN, ON THE TRAILING SIDE OF THE SAME ROW ──────
            //
            // The order was a menu in the title strip, beside three menus
            // that EDITED the selection and looked exactly like filters; the
            // density and the list did not exist. What narrows the grid is on
            // the leading side and how it is laid out on the trailing side,
            // with the count of what is left between them — one row, read
            // left to right (right to left in Arabic) as one sentence.
            LibraryViewControls(shop: shop)
                .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, Metric.screen)
        .padding(.vertical, 8)
    }

    /// The leading half of the row with the first `inline` axes drawn as
    /// menus and any others folded into More.
    private func filters(_ all: [FilterChipModel], inline: Int) -> some View {
        HStack(spacing: 8) {
            // Only at the top. Inside an open group both choices draw that
            // group's own levels (`Shop.libraryEntries`), so the switch was
            // on screen and did nothing — a control that changes nothing
            // reads as broken.
            if Self.offersViewSwitch(shop.shelf) {
                Picker("", selection: $shop.libraryFlat) {
                    Text(shop.words.callIt("mac.lib_view_models")).tag(true)
                    Text(shop.words.callIt("mac.lib_view_groups")).tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help(shop.words.callIt("mac.lib_view_help"))
            }

            // WHAT THE SEARCH BOX IS FILTERING ON, one chip per token, each
            // with the way to take it off. Read from the box itself
            // (`LibrarySearch`), so a chip and the text cannot disagree.
            ForEach(Array(LibrarySearch.parse(shop.search).tokens.enumerated()), id: \.offset) { _, token in
                TokenChip(token: token, words: shop.words) {
                    shop.search = LibrarySearch.removing(token, from: shop.search)
                }
            }

            ForEach(Array(Self.axes.prefix(inline).enumerated()), id: \.offset) { _, axis in
                menu(all, axis)
            }
            if inline < Self.axes.count {
                more(all, Array(Self.axes.dropFirst(inline)))
            }

            // The ranges: one button, always there, with a popover — five
            // figures do not fit in a menu, and a range typed into a menu
            // item is not a thing a Mac does.
            LibraryRangesButton(shop: shop)

            if shop.libraryFilterOn {
                Button(shop.words.callIt("log.clear_filters")) { shop.clearLibraryFilter() }
                    .buttonStyle(.link)
                    .fixedSize()
            }
            // Keep what is on screen as a smart folder in the sidebar. Only
            // while something narrows: an empty search is the library itself.
            if shop.libraryQueryActive {
                LibrarySaveSearchButton(shop: shop, compact: inline == 0)
            }
        }
        .fixedSize()
        .padding(.vertical, 1)
    }

    /// Is the All models / Groups switch drawn? Only with no group open.
    static func offersViewSwitch(_ shelf: Shop.Shelf) -> Bool {
        if case .library(let open?) = shelf, !open.isEmpty { return false }
        return true
    }

    /// One filter axis: its name, and which chips belong to it.
    struct Axis {
        let key: String
        var prefix: String? = nil
        var ids: [String] = []

        func holds(_ chip: FilterChipModel) -> Bool {
            if let prefix { return chip.id.hasPrefix(prefix) }
            return ids.contains(chip.id)
        }
    }

    /// The axes the row draws, in order — every one of them, always.
    static let axes: [Axis] = [
        Axis(key: "mac.lib_show", ids: ["print-next", "duplicates", "unfiled", "never-printed", "archived",
                                        "no-figures", "in-catalogue", "online-only", "this-mac-only"]),
        Axis(key: "mac.lib_printer", prefix: "ready:"),
        Axis(key: "mac.lib_creator", prefix: "creator:"),
        Axis(key: "mac.category", prefix: "category:"),
        Axis(key: "mac.lib_tag", prefix: "tag:"),
    ]

    /// ── A MENU WITH NOTHING IN IT IS GREYED, NOT GONE ─────────────────────
    ///
    /// Each axis vanished when its count reached zero, so the row changed
    /// shape as the shop typed: "Ready on" disappeared on a library with no
    /// printer reporting its spools, Creator on one nobody had attributed,
    /// and a shop could not learn the axes existed until its book happened
    /// to fill them. Now every axis is always drawn, disabled when it has
    /// nothing to offer, with the reason on hover.
    static func menuEnabled(rows: Int) -> Bool { rows > 0 }

    /// The title an axis wears: its name, and what it is set to.
    private func title(_ axis: Axis, on: [FilterChipModel]) -> String {
        on.isEmpty ? shop.words.callIt(axis.key)
            : shop.words.callIt(axis.key) + ": " + (on.count == 1 ? on[0].label : shop.words.numeral(on.count))
    }

    @ViewBuilder private func items(_ rows: [FilterChipModel]) -> some View {
        ForEach(rows) { chip in
            Button { chip.press() } label: {
                if chip.on { Label(chip.label + "  (\(chip.count))", systemImage: "checkmark") }
                else { Text(chip.label + "  (\(chip.count))") }
            }
        }
    }

    /// One axis as a menu. Disabled — never hidden — when it has nothing to offer.
    @ViewBuilder
    private func menu(_ all: [FilterChipModel], _ axis: Axis) -> some View {
        let rows = all.filter(axis.holds)
        if !Self.menuEnabled(rows: rows.count) {
            Menu {
                EmptyView()
            } label: {
                Text(shop.words.callIt(axis.key)).lineLimit(1)
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(true)
            .help(shop.words.callIt("mac.lg_filter_empty", ["name": .string(shop.words.callIt(axis.key))]))
        } else {
            let on = rows.filter(\.on)
            Menu {
                items(rows)
            } label: {
                // ONE Text. A macOS button-style menu draws its label as a
                // single title, and of an HStack of two it kept only the
                // first: "Show" with Archived on read "Show" (Oct 2026
                // capture), and every axis lost what it was set to.
                Text(title(axis, on: on)).lineLimit(1)
            }
            .menuStyle(.button)
            .fixedSize()
            // Rebuilt when what it is set to changes, so the button behind
            // it takes the new title rather than keeping the first one.
            .id(axis.key + "|" + on.map(\.id).joined(separator: ","))
        }
    }

    /// The axes that did not fit, as submenus of one More menu — each still
    /// there, greyed when empty, and the More title says how many of them
    /// are narrowing the grid.
    private func more(_ all: [FilterChipModel], _ hidden: [Axis]) -> some View {
        let active = hidden.reduce(0) { $0 + all.filter($1.holds).filter(\.on).count }
        return Menu {
            ForEach(Array(hidden.enumerated()), id: \.offset) { _, axis in
                let rows = all.filter(axis.holds)
                Menu(title(axis, on: rows.filter(\.on))) { items(rows) }
                    .disabled(!Self.menuEnabled(rows: rows.count))
            }
        } label: {
            Text(active == 0 ? shop.words.callIt("mac.lg_more_filters")
                 : shop.words.callIt("mac.lg_more_filters") + ": " + shop.words.numeral(active))
                .lineLimit(1)
        }
        .menuStyle(.button)
        .fixedSize()
        .id("more|\(hidden.count)|\(active)")
    }
}

/// One search token as a chip: "Tag: dragon ⓧ". The whole chip removes it —
/// a target the size of a word rather than of the cross.
private struct TokenChip: View {
    let token: LibrarySearch.Token
    let words: Words
    let remove: () -> Void

    /// The value cut at 28 characters: a chip sizes to its words, and one
    /// pasted paragraph must not push the menus off the row.
    private var label: String {
        let value = token.value.count > 28 ? String(token.value.prefix(27)) + "\u{2026}" : token.value
        return words.callIt(token.field.wordKey) + ": " + value
    }

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(label).lineLimit(1).truncationMode(.tail)
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Khayt.brand.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Its own size, never stretched: a flexible chip took a share of the
        // row's spare width and the chips stood apart (Oct 2026 capture).
        .fixedSize()
        .help(words.callIt("mac.lib_token_remove", ["name": .string(label)]))
        .accessibilityLabel(words.callIt("mac.lib_token_remove", ["name": .string(label)]))
    }
}
