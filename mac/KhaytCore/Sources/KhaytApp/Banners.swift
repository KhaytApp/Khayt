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
        // ORDERS THIS APP DRAFTED BY ITSELF, because the shop asked it to.
        //
        // Drafts only, and the shop reviews them before any is sent — but the
        // book changed while nobody was typing, and an app that alters a
        // shop's records with nothing on screen to say so is the shape of
        // every "where did that come from" question.
        if shop.autoDrafted > 0 {
            Banner(text: shop.words.callIt("reorder.auto_drafted",
                                           ["n": .number(Double(shop.autoDrafted))]),
                   symbol: "doc.badge.plus", tint: Role.text2) {
                // `common.close`, not `common.ok`: there is no `common.ok`
                // in either this app's table or the shared catalogue, so this
                // button read the words "common.ok" — `callIt` ends
                // `return key`, and a key that resolves nowhere renders as
                // itself. Close is the word the catalogue already has, in
                // both languages, for dismissing something.
                Button(shop.words.callIt("common.close")) { shop.autoDrafted = 0 }
            }
        }
        // WEB-STORE ORDERS THAT BECAME JOBS BY THEMSELVES. The same reason as
        // the drafts above: the book changed with nobody at the keyboard, so
        // the window says so until somebody has looked — and offers the look.
        let arrived = shop.webStoreArrived.filter(\.automatic)
        if !arrived.isEmpty {
            Banner(text: shop.words.callIt("mac.webstore_arrived",
                                           ["n": .number(Double(arrived.count))]),
                   symbol: "bag.badge.plus", tint: Khayt.brand) {
                Button(shop.words.callIt("mac.review") + "\u{2026}") {
                    shop.showingOnlineOrders = true
                }
                BannerClose(words: shop.words) { shop.webStoreArrived.removeAll() }
            }
        }
        // MONEY THE BOOK IS UNDERSTATING. Not a move's answer like the rest of
        // these, and it sits at the top for that reason: it is true until
        // somebody acts on it, on every screen, and what it is about is the
        // shop chasing customers for money they have already paid.
        if !shop.erasedDeposits.isEmpty {
            Banner(text: shop.words.callIt("dep.head") + " "
                   + shop.words.callIt("dep.total",
                                       ["n": .string(Money.text(shop.depositsUnaccounted,
                                                                shop.currency))]),
                   symbol: "exclamationmark.triangle", tint: Khayt.attention) {
                Button(shop.words.callIt("mac.review") + "\u{2026}") {
                    shop.reviewingDeposits = true
                }
            }
        }
        // THE OFF-SITE BACKUP HAS BEEN FAILING FOR MORE THAN TWO DAYS. A
        // problem, not a notice: it stays until closed, and comes back on the
        // next launch if it is still true. The settings line says why.
        if shop.offsite.overdue() {
            Banner(text: shop.words.callIt("mac.offsite_overdue"),
                   symbol: "exclamationmark.icloud", tint: Khayt.attention) {
                BannerClose(words: shop.words) { shop.offsite.noticeDismissed = true }
            }
        }
        if let problem = shop.moveProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: Khayt.attention) {
                BannerClose(words: shop.words) { shop.moveProblem = nil }
            }
        }
        // What adding a model had to say. A refusal — a duplicate, a kind Khayt
        // does not read — is the common case and is not an error.
        if let problem = shop.importProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: Khayt.attention) {
                BannerClose(words: shop.words) { shop.importProblem = nil }
            }
        }
        if let note = shop.importNote {
            Banner(text: note, symbol: "checkmark.circle", tint: Khayt.done) {
                BannerClose(words: shop.words) { shop.importNote = nil }
            }
            .task(id: note) {
                try? await Task.sleep(for: Shop.noticeLifetime)
                if !Task.isCancelled, shop.importNote == note { shop.importNote = nil }
            }
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
                       tint: Khayt.brand) {
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
                       tint: Khayt.brand)
            }
        }
        // A conversion: what it saved, or why it would not. Beside the slicer
        // banner because it is the same gesture — a model, a menu, an answer
        // with nowhere else to appear.
        if let problem = shop.convertProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: Khayt.attention) {
                BannerClose(words: shop.words) { shop.convertProblem = nil }
            }
        }
        if let note = shop.convertNote {
            Banner(text: note, symbol: "checkmark.circle", tint: Khayt.done) {
                BannerClose(words: shop.words) { shop.convertNote = nil }
            }
            .task(id: note) {
                try? await Task.sleep(for: Shop.noticeLifetime)
                if !Task.isCancelled, shop.convertNote == note { shop.convertNote = nil }
            }
        }
        if shop.converting {
            Banner(text: shop.words.callIt("mac.converting"),
                   symbol: "gearshape.arrow.trianglehead.2.clockwise.rotate.90",
                   tint: Khayt.brand)
        }
        // A slicer that would not open. It belongs here for the same reason a
        // refused move does: the gesture was a menu item on a model, and there
        // is nowhere on that menu for an answer to appear.
        if let problem = shop.slicerProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: Khayt.attention) {
                BannerClose(words: shop.words) { shop.slicerProblem = nil }
            }
        }
        // By position, not by text: two spools running low can produce the same
        // sentence, and a ForEach with two identical ids draws one.
        //
        // A notice is news, not a state: "Signed in", "Email sent". It used to
        // stay until the next job moved, so a shop that signed in to the cloud
        // and went on working had three success sentences pinned over every
        // screen, reading like warnings nobody could clear. Each has a Close
        // button now, and they all go on their own a while after the last one
        // arrived. Problems are not notices: they stay until closed.
        Group {
            ForEach(Array(shop.moveNotices.enumerated()), id: \.offset) { index, notice in
                Banner(text: notice, symbol: "info.circle", tint: .secondary) {
                    BannerClose(words: shop.words) { shop.dismissNotice(at: index) }
                }
            }
        }
        .task(id: shop.moveNotices) {
            guard !shop.moveNotices.isEmpty else { return }
            try? await Task.sleep(for: Shop.noticeLifetime)
            if !Task.isCancelled { shop.moveNotices = [] }
        }
    }
}

/// The × at the end of a banner. Every banner a shop can be told something
/// in has one: "Signed in" pinned over every screen with no way to close it
/// read as a stuck warning (Turki, Sep 2026), and so does a real warning that
/// has been read and cannot be put away.
struct BannerClose: View {
    let words: Words
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help(words.callIt("common.close"))
        .accessibilityLabel(words.callIt("common.close"))
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
