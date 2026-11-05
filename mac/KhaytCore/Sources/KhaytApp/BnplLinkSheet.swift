import SwiftUI
import AppKit
import KhaytCore

/// "Pay later link": a Tabby or Tamara checkout for one job, to copy or share
/// with the customer.
///
/// The desktop's pay-later dialog (`openBnplModal`), for the two providers this
/// app finishes payments for: one row per provider that is switched on with a
/// key, a button that makes the link, then the link with Copy and Share. The
/// amount is the job's price, as the desktop sends it. Once made, the link is
/// remembered on the job and the app finishes the payment by itself when the
/// customer has paid (`Shop+Bnpl.swift`).
struct BnplLinkSheet: View {
    static let width: CGFloat = 420

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var busy: String?
    @State private var made: [String: Shop.BnplLinkOutcome] = [:]
    @State private var copied: String?

    private var job: Order? { shop.orders.first { $0.id == subject.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.bnpl_title")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if let job {
                HStack {
                    Text(shop.words.callIt("bnpl.amount_label")).foregroundStyle(.secondary)
                    Text(Money.text(job.price, job.currency)).monospacedDigit()
                }
            }
            let offered = shop.bnplProvidersOffered
            if offered.isEmpty {
                Text(shop.words.callIt("mac.bnpl_none"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Two at most: the providers this app makes links for.
            ForEach(Shop.bnplProviders.filter(offered.contains), id: \.self) { provider in
                row(provider)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: Self.width)
    }

    @ViewBuilder
    private func row(_ provider: String) -> some View {
        let name = provider == "tamara" ? "Tamara" : "Tabby"
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: name).font(.body.weight(.semibold))
                Spacer()
                if busy == provider { ProgressView().controlSize(.small) }
                Button(shop.words.callIt(busy == provider ? "bnpl.generating" : "bnpl.generate")) {
                    Task { await make(provider) }
                }
                .disabled(busy != nil || !shop.permitted("invoicing", "edit"))
            }
            if let out = made[provider] {
                if let url = out.url {
                    Text(verbatim: url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(shop.words.callIt(copied == provider ? "bnpl.link_copied" : "bnpl.copy_link")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            copied = provider
                        }
                        if let link = URL(string: url) {
                            ShareLink(item: link) { Text(shop.words.callIt("mac.share")) }
                        }
                    }
                    if out.watched {
                        Text(shop.words.callIt("mac.bnpl_watching"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let problem = out.problem {
                    Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func make(_ provider: String) async {
        busy = provider
        defer { busy = nil }
        made[provider] = await shop.makeBnplLink(subject.id, provider: provider)
        copied = nil
    }
}
