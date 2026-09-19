import SwiftUI
import KhaytCore

/// Who a message would reach, and what it would say to each of them.
///
/// ── WHY THIS SHEET DOES NOT SEND ──────────────────────────────────────────
///
/// A campaign is the one thing in this app that leaves the building in bulk.
/// The question a shop actually has first is not "send this" but "who is on
/// this list, and does the message read right to them" — and until now this
/// app could not answer either: `lib/campaigns.js` has segmented customers
/// since 3.0 and only the other window ever asked.
///
/// So this is the half that can be got wrong safely. Sending follows once a
/// shop can see exactly what sending would do, which is the same order the
/// purchase-order screens were built in.
///
/// WHO IS IN THE LIST IS NOT THIS APP'S OPINION. The spend, the days since the
/// last order, the tag, the tier, and — the one that matters — that a customer
/// who opted out of marketing is never in it, are all the rule's. A host that
/// filtered on its own side would be a second opinion about consent.
struct CampaignSheet: View {
    /// See `NewJobSheet.width`.
    static let width: CGFloat = 560

    @Bindable var shop: Shop

    @State private var segment = Shop.Segment()
    @State private var body_ = ""
    @State private var recipients: [KhaytEngine.Recipient] = []
    @State private var preview = ""
    @State private var minSpendText = ""
    @State private var noOrderText = ""

    var body: some View {
        SheetFrame(width: Self.width) {
            Text(shop.words.callIt("camp.title")).font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("camp.channel")).foregroundStyle(.secondary)
                    Picker("", selection: $segment.channel) {
                        ForEach(Shop.Segment.channels, id: \.self) { channel in
                            Text(shop.words.callIt(channel == "email"
                                                   ? "camp.ch_email" : "mac.whatsapp")).tag(channel)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
                GridRow {
                    Text(shop.words.callIt("camp.min_spend")).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField(shop.words.callIt("camp.any"), text: $minSpendText)
                            .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                        Text(Money.mark(shop.currency)).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("camp.no_order_days")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("camp.any"), text: $noOrderText)
                        .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                }
                GridRow {
                    Text(shop.words.callIt("camp.tag")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("camp.any"), text: $segment.tag)
                        .textFieldStyle(.roundedBorder).frame(width: 190)
                }
                // Only where the shop runs the programme at all: a tier filter
                // on a shop with no tiers narrows every list to nobody, which
                // reads as a broken screen rather than as a switched-off
                // feature.
                if shop.loyaltyOn {
                    GridRow {
                        Text(shop.words.callIt("camp.tier")).foregroundStyle(.secondary)
                        TextField(shop.words.callIt("camp.any"), text: $segment.tier)
                            .textFieldStyle(.roundedBorder).frame(width: 190)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(shop.words.callIt("camp.message")).foregroundStyle(.secondary)
                TextField(shop.words.callIt("camp.body_ph"), text: $body_, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                Text(shop.words.callIt("camp.merge_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ── WHO, AND WHAT THEY WOULD READ ─────────────────────────────
            //
            // The count alone is not the answer. A shop about to write to
            // forty people wants to see that the greeting fills in, and the
            // only way to see that is on a real recipient — `{{name}}` going
            // out empty is the fault this rule's own comments are about.
            VStack(alignment: .leading, spacing: 8) {
                Text(shop.words.counting(recipients.count, "mac.campaign_reach"))
                    .font(.callout)
                    .foregroundStyle(recipients.isEmpty ? Khayt.attention : Role.text)

                if recipients.isEmpty {
                    Text(shop.words.callIt("camp.none"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if !preview.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            CapsLabel(shop.words.callIt("camp.preview"), tint: Role.text3, size: 9)
                            Text(preview)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .card(padding: 0)
                    }
                    // The first few by name, so a shop recognises the list
                    // rather than trusting a number.
                    Text(recipients.prefix(6).map(\.contact).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } footer: {
            HStack {
                // SAID, NOT HIDDEN. Sending is not built yet, and a sheet that
                // simply had no Send button would read as one that had lost it.
                Text(shop.words.callIt("mac.campaign_no_send"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.planningCampaign = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onChange(of: minSpendText) { _, typed in
            segment.minSpend = Self.number(typed)
        }
        .onChange(of: noOrderText) { _, typed in
            segment.noOrderDays = Self.number(typed)
        }
        .task(id: segment) { await refresh() }
        .task(id: body_) { await refreshPreview() }
    }

    /// An empty box is NO FILTER, not a filter of zero. The rule reads
    /// `!= null`, so a zero means "spent at least nothing", which is everybody
    /// — a different list from the one the shop meant.
    private static func number(_ typed: String) -> Double? {
        let cleaned = typed.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    private func refresh() async {
        recipients = await shop.campaignRecipients(segment)
        await refreshPreview()
    }

    private func refreshPreview() async {
        guard let first = recipients.first, !body_.isEmpty else { preview = ""; return }
        preview = await shop.campaignPreview(body_, for: first)
    }
}
