import SwiftUI

/// What the window says across the top of every screen.
///
/// These lived in `Kanban.swift` because a drag is where a refusal is most
/// often earned. They belong to the WINDOW: ⇧⌘H, the Job menu and the jobs
/// table's context menu all move a job without a board in sight, and there a
/// refusal appeared nowhere at all.
/// Not a sheet: a modal would have to be dismissed before the next card could
/// be dragged, which turns "move four jobs" into eight gestures. This is read
/// where it is noticed and ignored where it is not, and the next move replaces
/// it.
struct MoveBanners: View {
    let shop: Shop

    var body: some View {
        if let problem = shop.moveProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: Khayt.attention)
        }
        // What adding a model had to say. A refusal — a duplicate, a kind Khayt
        // does not read — is the common case and is not an error.
        if let problem = shop.importProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: Khayt.attention)
        }
        if let note = shop.importNote {
            Banner(text: note, symbol: "checkmark.circle", tint: Khayt.done)
        }
        if shop.importing {
            // A batch says where it has got to and offers a way out. Three
            // thousand models is minutes of work, and a progress line with no
            // Stop on it is a window somebody force-quits — which, mid-import,
            // is the one moment this app is holding a file it has not yet
            // written a record for.
            if let p = shop.importProgress {
                Banner(text: shop.words.callIt("mac.import_progress", [
                            "done": .number(Double(p.done)),
                            "total": .number(Double(p.total)),
                            "name": .string(p.name)]),
                       symbol: "gearshape.arrow.trianglehead.2.clockwise.rotate.90",
                       tint: Khayt.cyan) {
                    // A BAR AS WELL AS THE NUMBERS. Five hundred models is
                    // minutes, and "137 of 490" has to be read and divided
                    // before it means anything; a bar is understood without
                    // being read. Determinate, because the total is known —
                    // a spinner here would say only that the app is alive.
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Button(shop.words.callIt("mac.stop")) { shop.importCancelled = true }
                        .disabled(shop.importCancelled)
                }
            } else {
                Banner(text: shop.words.callIt("mac.adding_model"),
                       symbol: "gearshape.arrow.trianglehead.2.clockwise.rotate.90",
                       tint: Khayt.cyan)
            }
        }
        // A conversion: what it saved, or why it would not. Beside the slicer
        // banner because it is the same gesture — a model, a menu, an answer
        // with nowhere else to appear.
        if let problem = shop.convertProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: Khayt.attention)
        }
        if let note = shop.convertNote {
            Banner(text: note, symbol: "checkmark.circle", tint: Khayt.done)
        }
        if shop.converting {
            Banner(text: shop.words.callIt("mac.converting"),
                   symbol: "gearshape.arrow.trianglehead.2.clockwise.rotate.90",
                   tint: Khayt.cyan)
        }
        // A slicer that would not open. It belongs here for the same reason a
        // refused move does: the gesture was a menu item on a model, and there
        // is nowhere on that menu for an answer to appear.
        if let problem = shop.slicerProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: Khayt.attention)
        }
        // By position, not by text: two spools running low can produce the same
        // sentence, and a ForEach with two identical ids draws one.
        ForEach(Array(shop.moveNotices.enumerated()), id: \.offset) { _, notice in
            Banner(text: notice, symbol: "info.circle", tint: .secondary)
        }
    }
}

struct Banner<Accessory: View>: View {
    let text: String
    let symbol: String
    let tint: Color
    /// A button belonging to what the banner is announcing — Stop, on a running
    /// import. Most banners are a sentence and nothing else, so the common
    /// spelling below omits it entirely.
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
                .font(.callout)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.quinary)
    }
}

extension Banner where Accessory == EmptyView {
    init(text: String, symbol: String, tint: Color) {
        self.init(text: text, symbol: symbol, tint: tint, accessory: { EmptyView() })
    }
}


/// The one that means nothing else on screen can be trusted.
///
/// If the shared rules did not load there is no engine, so every figure this
/// app shows is absent or zero — an empty dashboard, a blank P&L, no attention
/// list — and each of those looks exactly like a quiet shop. It was said in one
/// caption at the FOOT OF THE SIDEBAR, which is the one place the HIG says not
/// to put critical information: "people often relocate a window in a way that
/// hides its bottom edge".
///
/// So it is said here as well, where the figures are. The sidebar keeps its
/// line — that one is the persistent record, and this is the alarm.
struct EngineBanner: View {
    let shop: Shop

    var body: some View {
        if let problem = shop.engineProblem {
            Banner(text: shop.words.callIt("mac.engine_failed") + " \u{2014} " + problem,
                   symbol: "exclamationmark.octagon", tint: Khayt.attention)
        }
    }
}
