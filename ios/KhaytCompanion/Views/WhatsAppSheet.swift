import SwiftUI
import KhaytCore

/// The order page's WhatsApp line: which update the customer is due, and
/// whether it already went.
struct WhatsAppCard: View {
    let offer: KhaytAPIClient.WhatsAppOffer
    let onOpen: () -> Void

    private var milestoneName: String { L10n.tr("wa.m.\(offer.milestone)") }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.tr("wa.update").uppercased())
                .font(.khayt(10.5, .bold, relativeTo: .caption2))
                .tracking(1.05)
                .foregroundStyle(KhaytDesign.note)
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "message.fill").foregroundStyle(KhaytDesign.done)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.format("wa.update_due", milestoneName))
                            .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(KhaytDesign.ink)
                        if let sent = offer.sentAt, let day = DueDateParser.parse(sent) {
                            Text(L10n.format("wa.update_sent", milestoneName,
                                             day.formatted(.dateTime.day().month().locale(L10n.locale))))
                                .font(.khayt(12, relativeTo: .caption))
                                .foregroundStyle(KhaytDesign.note)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward").flipsForRightToLeftLayoutDirection(true)
                        .font(.caption).foregroundStyle(KhaytDesign.note)
                }
                .padding(14)
                .card()
            }
            .buttonStyle(.plain)
        }
    }
}

/// The message, editable, and the button that opens WhatsApp with it.
struct WhatsAppSheet: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let orderId: String

    @State private var update: WhatsAppUpdate?
    @State private var text = ""
    @State private var lang = "ar"
    @State private var problem: String?
    @State private var opening = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.tr("wa.language"), selection: $lang) {
                        Text(L10n.tr("wa.lang.ar")).tag("ar")
                        Text(L10n.tr("wa.lang.en")).tag("en")
                    }
                    .pickerStyle(.segmented)
                    TextEditor(text: $text)
                        .font(.khayt(15, relativeTo: .body))
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .card()
                        // The message is in the CUSTOMER's language, whatever the app's.
                        .environment(\.layoutDirection, lang == "ar" ? .rightToLeft : .leftToRight)
                    recipient
                    if update?.isDefault == true { V2Note(text: L10n.tr("wa.default_words")) }
                    if let problem { V2Note(text: problem, tone: KhaytDesign.late) }
                    V2PrimaryButton(title: L10n.tr("wa.open"), busy: opening,
                                    disabled: update?.ok != true || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        Task { await open() }
                    }
                }
                .padding(16)
            }
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("wa.update"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common.close")) { dismiss() } }
            }
            .task { await fill(lang: nil) }
            .onChange(of: lang) { _, new in
                // Only a language CHANGE refills; the first fill sets `lang` itself.
                if update?.lang != new { Task { await fill(lang: new) } }
            }
        }
    }

    @ViewBuilder private var recipient: some View {
        if let update {
            if update.ok {
                VStack(alignment: .leading, spacing: 3) {
                    // Isolated left-to-right, or an Arabic line moves the `+` to the wrong end.
                    Label(L10n.format("wa.to", "\u{2066}" + update.e164 + "\u{2069}"), systemImage: "phone")
                        .font(.khayt(13.5, .medium, relativeTo: .subheadline))
                    Text(L10n.tr("wa.logged_note"))
                        .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                }
            } else {
                V2Note(text: Self.reason(update.reason), tone: KhaytDesign.attention)
            }
        }
    }

    static func reason(_ r: String) -> String {
        let known = ["no_customer", "too_short", "too_long", "no_country_code", "bad_saudi_number", "no_milestone"]
        return known.contains(r) ? L10n.tr("wa.reason.\(r)") : L10n.tr("wa.reason.no_phone")
    }

    private func fill(lang: String?) async {
        update = await api.whatsAppUpdate(orderId: orderId, lang: lang)
        text = update?.text ?? ""
        if let l = update?.lang, ["ar", "en"].contains(l) { self.lang = l }
    }

    private func open() async {
        opening = true
        defer { opening = false }
        let link = await api.whatsAppLink(orderId: orderId, text: text)
        guard let url = link.url else { problem = Self.reason(link.reason); return }
        openURL(url)
        await api.logWhatsApp(orderId: orderId, text: text, milestone: update?.milestone, lang: lang)
        dismiss()
    }
}
