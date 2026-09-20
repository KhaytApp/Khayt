import SwiftUI
import KhaytCore

/// Who a message would reach, and what it would say to each of them.
///
/// ── WHO, THEN WHAT IT SAYS, THEN SEND ─────────────────────────────────────
///
/// A campaign is the one thing in this app that leaves the building in bulk,
/// so the sheet is built in the order a shop actually asks: who is on this
/// list, does the message read right to them, and only then send. The count
/// is in the question the confirmation asks, because "Send" on a screen that
/// does not say forty is a button nobody can weigh.
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
    /// The one line a customer reads before deciding whether to open it.
    @State private var subject = ""
    @State private var recipients: [KhaytEngine.Recipient] = []
    @State private var preview = ""
    @State private var minSpendText = ""
    @State private var noOrderText = ""
    @State private var confirming = false
    @State private var sending = false
    @State private var result = ""
    /// Whether the shop's mail provider is one this app can post to. Held in
    /// state because the answer is the engine's and a view cannot ask an actor
    /// a question while it is drawing.
    @State private var canSend = false

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

            // ── THE SUBJECT ──────────────────────────────────────────────
            //
            // A campaign this app sent went out under the shop's name as its
            // subject and nothing else, because there was nowhere to type one.
            // The other window has had this field since the feature existed,
            // and it is the line that decides whether any of the rest is read.
            //
            // `{{name}}` works here exactly as it does in the message — "A
            // note from your printer, Layla" — so it is filled per recipient
            // rather than sent as literal braces. Left empty, the shop's own
            // name is used.
            VStack(alignment: .leading, spacing: 6) {
                Text(shop.words.callIt("camp.subject")).foregroundStyle(.secondary)
                TextField(shop.words.callIt("camp.subject_ph"), text: $subject)
                    .textFieldStyle(.roundedBorder)
                    // The other app's cap, kept: a subject longer than this is
                    // cut by the mail client anyway, and one app truncating
                    // where the other does not is two different emails.
                    .onChange(of: subject) {
                        if subject.count > 160 { subject = String(subject.prefix(160)) }
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(shop.words.callIt("camp.message")).foregroundStyle(.secondary)
                TextField(shop.words.callIt("camp.body_ph"), text: $body_, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                Text(shop.words.callIt("camp.merge_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ── AND WHAT HAS ALREADY GONE OUT ────────────────────────────
            //
            // Both apps have written `settings.campaignLog` since campaigns
            // existed and neither has ever shown it: grep the repository and
            // every hit is a write. A record an app keeps and cannot show is
            // the same defect as a field it reads and cannot set.
            //
            // "Did that go?" is the first question after mailing forty people,
            // and the answer was already on disk. Three runs, because this is
            // a reminder rather than a report — a shop that wants the whole
            // history has it in its own book.
            if !shop.campaignRuns.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.words.callIt("mac.campaign_log")).foregroundStyle(.secondary)
                    ForEach(shop.campaignRuns.prefix(3)) { run in
                        HStack(spacing: 6) {
                            Text(run.day).monospacedDigit()
                            Text("·")
                            Text(shop.words.callIt("camp.done") + " " + String(run.sent))
                                .monospacedDigit()
                            // Only when there were any. "0 failed" on every
                            // line teaches a shop to stop reading the line.
                            if run.failed > 0 {
                                Text("· " + String(run.failed) + " "
                                     + shop.words.callIt("camp.failed"))
                                    .monospacedDigit().foregroundStyle(Khayt.attention)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
                if !result.isEmpty {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !canSend {
                    // SAID, NOT HIDDEN. A shop on SMTP has a Send button that
                    // would always fail; it is told why, by name, rather than
                    // shown a control that does nothing.
                    Text(shop.words.callIt("mac.campaign_needs_http"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.planningCampaign = false }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("camp.send")) { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || !canSend || recipients.isEmpty
                              || body_.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        // THE COUNT IS IN THE QUESTION. "Send this?" is a question nobody can
        // answer; "Send this to 38 customers?" is one they can.
        // The question is the OTHER APP'S, `camp.confirm`, which carries it in
        // nine languages. The Mac-only phrasing this used to have was written
        // in two, so a German shop was asked in English before sending to its
        // whole customer list — the one moment to be sure it is understood.
        .confirmationDialog(
            shop.words.callIt("camp.confirm",
                              ["n": .number(Double(recipients.count))]),
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button(shop.words.callIt("camp.send")) { send() }
            Button(shop.words.callIt("common.cancel"), role: .cancel) {}
        } message: {
            Text(shop.words.callIt("mac.campaign_confirm_hint"))
        }
        .onChange(of: minSpendText) { _, typed in
            segment.minSpend = Self.number(typed)
        }
        .onChange(of: noOrderText) { _, typed in
            segment.noOrderDays = Self.number(typed)
        }
        .task { canSend = await shop.canSendCampaign() }
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

    private func send() {
        let text = body_
        let line = subject
        let list = recipients
        sending = true
        Task {
            result = await shop.sendCampaign(text, subject: line, to: list)
            sending = false
        }
    }

    private func refreshPreview() async {
        guard let first = recipients.first, !body_.isEmpty else { preview = ""; return }
        preview = await shop.campaignPreview(body_, for: first)
    }
}
