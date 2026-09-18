import SwiftUI
import KhaytCore

/// Where a model came from, and what may be done with it.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// The inspector has always shown a model's licence and this Mac could not SET
/// one. So on a real book the provenance panel was blank on every model, and
/// the only way to fill it in was to open the other app — which is a gap to
/// close, not a difference to write down.
///
/// It matters more than the other two axes. A library holds work the shop made
/// and models it downloaded; they look identical in a grid, and the difference
/// decides whether a print can be SOLD. Most of what is on the model sites is
/// Creative Commons and a good share of that is NonCommercial, which is exactly
/// the licence that makes selling a print of it a breach rather than a favour.
///
/// ── NOT RECORDED IS THE DEFAULT AND MUST STAY REACHABLE ───────────────────
///
/// "Not recorded" is an entry on this menu, not just the starting state. A
/// licence chosen by mistake is worse than no licence: it makes the app tell a
/// shop it may not sell its own work. So there is always a way back to nobody
/// having said.
struct ProvenanceMenu: View {
    @Bindable var shop: Shop
    @State private var typing = false
    @State private var typed = ""

    private var count: Int { shop.fileSelection.count }

    var body: some View {
        Menu {
            if count == 0 {
                Text(shop.words.callIt("mac.pick_a_model"))
            } else {
                ForEach(ModelLicence.all) { licence in
                    Button {
                        Task { await shop.fileSelection(licence: licence.id) }
                    } label: {
                        // A tick against the one they all already carry, so the
                        // menu says where they stand as well as offering to
                        // change it — the same as the group and category menus.
                        if shop.licenceOnSelection == licence.id {
                            Label(name(of: licence.id), systemImage: "checkmark")
                        } else {
                            Text(name(of: licence.id))
                        }
                    }
                }
                Divider()
                Button {
                    Task { await shop.fileSelection(licence: "") }
                } label: {
                    if shop.licenceOnSelection == "" {
                        Label(shop.words.callIt("plib.licence_unknown"), systemImage: "checkmark")
                    } else {
                        Text(shop.words.callIt("plib.licence_unknown"))
                    }
                }
                Divider()
                Button(shop.words.callIt("plib.source") + "\u{2026}") {
                    typed = shop.sourceOnSelection
                    typing = true
                }
            }
        } label: {
            Label(shop.words.callIt("plib.provenance"), systemImage: "signature")
        }
        .disabled(!shop.canWrite || count == 0)
        .help(shop.canWrite
              ? shop.words.callIt("mac.provenance_why")
              : shop.words.callIt("mac.group_locked"))
        .popover(isPresented: $typing, arrowEdge: .bottom) {
            NameIt(words: shop.words, typed: $typed,
                   title: shop.words.callIt("plib.source"),
                   example: shop.words.callIt("plib.source_ph"),
                   note: shop.words.callIt("mac.source_replaced"),
                   confirm: shop.words.callIt("mac.file_it")) { line in
                typing = false
                Task { await shop.setSourceOnSelection(line) }
            }
        }
    }

    /// The licence's own name, in the shop's language — `cc-by-nc` is
    /// `plib.licence_cc_by_nc`, and every language already spells the
    /// NonCommercial ones "… — not for sale", so the warning is in the name.
    private func name(of id: String) -> String {
        shop.words.callIt("plib.licence_" + id.replacingOccurrences(of: "-", with: "_"))
    }
}
