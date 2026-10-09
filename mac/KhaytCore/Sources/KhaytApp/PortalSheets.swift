import AppKit
import SwiftUI
import KhaytCore

/// The customer's cloud link, in the job inspector: publish it, copy it, ask
/// what the customer said, read and answer their messages, take it down.
///
/// Only when the shop is connected to Khayt Cloud — the LAN links above it
/// point at this Mac and are a different thing. Write actions hide for a
/// cloud member whose role is `viewer` (the cloud would answer 403); reading
/// the thread does not.
struct CustomerLinkSection: View {
    let shop: Shop
    let job: Order
    @State private var asking = false
    @State private var talking = false
    @State private var busy = false
    @State private var said: String?
    @State private var confirmingUnpublish = false

    /// May this person, here, change what the customer sees? The cloud role
    /// AND the staff lock: a lock viewer was shown the buttons and refused on
    /// the click (alpha.62 review).
    private var mayWrite: Bool { shop.cloudRoleCanWrite && shop.lockAllows("orders", "edit") }

    var body: some View {
        if shop.portalReachable, shop.canMoveJobs {
            VStack(alignment: .leading, spacing: 4) {
                if shop.isPortalPublished(job.id) {
                    Button(shop.words.callIt("mac.portal_copy")) { Task { await copy() } }
                    if job.status == "quote" {
                        Button(shop.words.callIt("cloud.portal_check")) { Task { await check() } }
                            .disabled(busy)
                    }
                    Button(shop.words.callIt("mac.portal_messages")) { talking = true }
                    if mayWrite {
                        // ASKED FIRST: one misclick beside "Copy customer link"
                        // broke a link the customer already had.
                        Button(shop.words.callIt("cloud.portal_unpublish"), role: .destructive) {
                            confirmingUnpublish = true
                        }
                        .disabled(busy)
                    }
                } else if mayWrite {
                    Button(shop.words.callIt(job.status == "quote" ? "mac.portal_publish_quote" : "mac.portal_publish")) {
                        if job.status == "quote" { asking = true } else { Task { await publish(nil, nil) } }
                    }
                    .disabled(busy)
                }
                if let said {
                    Text(said).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .sheet(isPresented: $asking) {
                QuoteLinkSheet(shop: shop, job: job) { deposit, payUrl in
                    Task { await publish(deposit, payUrl) }
                }
            }
            .sheet(isPresented: $talking) { PortalMessagesSheet(shop: shop, job: job) }
            .confirmationDialog(
                shop.words.callIt("mac.portal_unpublish_q", ["job": .string(shop.shownTitle(of: job))]),
                isPresented: $confirmingUnpublish, titleVisibility: .visible
            ) {
                Button(shop.words.callIt("cloud.portal_unpublish"), role: .destructive) {
                    Task { busy = true; await shop.unpublishPortal(job.id); busy = false; said = nil }
                }
                Button(shop.words.callIt("common.cancel"), role: .cancel) {}
            } message: {
                Text(shop.words.callIt("mac.portal_unpublish_why"))
            }
        }
    }

    private func publish(_ deposit: String?, _ payUrl: String?) async {
        busy = true
        defer { busy = false }
        if let link = await shop.publishPortal(job.id, deposit: deposit, payUrl: payUrl) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            said = shop.words.callIt("mac.portal_published_copied")
        } else {
            said = shop.moveProblem
        }
    }

    private func copy() async {
        guard let link = await shop.portalLink(for: job.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        said = shop.words.callIt("mac.tracking_link_copied")
    }

    private func check() async {
        busy = true
        defer { busy = false }
        guard let r = await shop.checkPortalResponse(job.id) else { said = shop.moveProblem; return }
        let words = shop.words
        var line: String
        switch r.response {
        case "approved":
            line = words.callIt(r.advance ? "cloud.portal_approved_advanced" : "cloud.portal_approved")
        case "declined": line = words.callIt("cloud.portal_declined")
        default: line = words.callIt(r.paid ? "cloud.portal_deposit_paid" : "cloud.portal_no_response")
        }
        if r.paid, r.response != "none" { line += " · " + words.callIt("cloud.portal_deposit_paid") }
        said = line
    }
}

/// A quote's link, with an optional deposit and the shop's own pay link.
///
/// In a `SheetFrame`, as every sheet here: it fits a small screen, and it can
/// be photographed — a `Form` or a `ScrollView` draws blank in a picture.
struct QuoteLinkSheet: View {
    let shop: Shop
    let job: Order
    let publish: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var deposit = ""
    @State private var payUrl = ""

    var body: some View {
        let words = shop.words
        SheetFrame(width: 420) {
            Text(words.callIt("cloud.portal_quote_title")).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text(words.callIt("cloud.deposit_amount"))
                PortalField(placeholder: "", text: $deposit)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(words.callIt("cloud.deposit_payurl"))
                PortalField(placeholder: "https://", text: $payUrl)
                    .environment(\.layoutDirection, .leftToRight)   // an address reads left to right
            }
            Text(words.callIt("mac.deposit_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("cloud.deposit_publish")) {
                    publish(deposit, payUrl)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            let record = shop.portalRecord(job.id)
            if case .number(let n)? = record?["cloudDeposit"], n > 0 { deposit = Money.quantity(n, decimals: 2) }
            var cloud: [String: JSONValue] = [:]
            if case .object(let c)? = shop.settingsDict["cloud"] { cloud = c }
            payUrl = Shop.plainString(record?["cloudPayUrl"]) ?? Shop.plainString(cloud["lastPayUrl"]) ?? ""
        }
    }
}

/// The conversation behind a published link: the customer's messages and the
/// shop's replies, oldest first. The reply field is hidden for a viewer, who
/// the cloud would refuse.
struct PortalMessagesSheet: View {
    let shop: Shop
    let job: Order
    /// A thread to show instead of asking the cloud — for a photograph, which
    /// must never reach a real server.
    var preview: [KhaytEngine.PortalMessage]? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var thread: [KhaytEngine.PortalMessage] = []
    @State private var problem: String?
    @State private var loaded = false
    @State private var draft = ""
    @State private var sending = false

    init(shop: Shop, job: Order, preview: [KhaytEngine.PortalMessage]? = nil) {
        self.shop = shop; self.job = job; self.preview = preview
        // Seeded here, not in `.task`: a photograph never runs a task, and the
        // thread is what the picture is of.
        if let preview { _thread = State(initialValue: preview); _loaded = State(initialValue: true) }
    }

    var body: some View {
        let words = shop.words
        SheetFrame(width: 440) {
            Text(words.callIt("mac.portal_messages") + " · " + Figure.isolated(job.id)).font(.headline)
            if let problem {
                Text(problem).foregroundStyle(Khayt.late).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if loaded && thread.isEmpty {
                Text(words.callIt("pm.empty")).foregroundStyle(.secondary).font(.callout)
            }
            // The sheet's own scroll (SheetFrame) carries a long thread; a
            // second scroll view inside it would draw blank in a picture.
            ForEach(Array(thread.enumerated()), id: \.offset) { _, m in
                let mine = m.from == "shop"
                HStack {
                    if mine { Spacer(minLength: 40) }
                    Text(m.text)
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(mine ? Color.white : Color.primary)
                        // The DEEP step in both modes: the brand's dark-mode
                        // light blue put white text at about 3.2:1; this is
                        // about 7.7:1 (alpha.62 review).
                        .background(mine ? Color(nsColor: NSColor(hex: 0x0B54AD)) : Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !mine { Spacer(minLength: 40) }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 10) {
                if shop.cloudRoleCanWrite && shop.lockAllows("orders", "edit") {
                    HStack {
                        PortalField(placeholder: words.callIt("pm.reply_ph"), text: $draft) {
                            Task { await send() }
                        }
                        Button(words.callIt("pm.send")) { Task { await send() } }
                            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack {
                    Spacer()
                    Button(words.callIt("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        if let preview { thread = preview; loaded = true; return }
        do {
            thread = try await shop.portalThread(job.id)
            problem = nil
        } catch {
            problem = shop.portalSentence(error)
        }
        loaded = true
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await shop.replyOnPortal(job.id, text: draft)
            draft = ""
            await reload()
        } catch {
            problem = shop.portalSentence(error)
        }
    }
}

/// A text field that can be photographed. `ImageRenderer` cannot host the
/// AppKit field behind a `TextField` and draws a no-entry placeholder, so a
/// picture gets the same box with the text (or the placeholder) laid in it —
/// `FeedbackSheet`'s answer to the same thing.
struct PortalField: View {
    let placeholder: String
    @Binding var text: String
    var submit: (() -> Void)? = nil
    @Environment(\.photographFlat) private var flat

    var body: some View {
        if flat {
            Text(text.isEmpty ? placeholder : text)
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit?() }
        }
    }
}
