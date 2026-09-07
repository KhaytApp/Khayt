import SwiftUI
import KhaytCore

/// Issuing a gift card.
///
/// Every refusal here is `lib/gift-card.js`'s, which is the point of the sheet
/// being this thin: the app next door refuses the same codes for the same
/// reasons, and a card Khayt accepts on one Mac cannot be one the other calls
/// a duplicate. The module answers with a KEY and the window says it in the
/// shop's own language — a rule that returned English would be a rule the
/// Arabic app could not use.
struct GiftCardSheet: View {
    /// A CONSTANT, because `SnapshotTests` photographs the sheet at a size of
    /// its own and the two silently disagree otherwise.
    static let width: CGFloat = 420

    let shop: Shop
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var balance: Double = 50
    @State private var issuedTo: String?
    @State private var expires: Date?
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(shop.words.callIt("issueGiftCard"))
                .font(.headline).padding(.bottom, 12)

            Form {
                LabeledContent(shop.words.callIt("giftCardCode")) {
                    TextField("", text: $code)
                        .textFieldStyle(.roundedBorder).monospaced()
                        .focused($focused)
                        // Shouted, because the code gets read down a telephone.
                        .onChange(of: code) { _, new in
                            let up = new.uppercased()
                            if up != new { code = up }
                        }
                }
                LabeledContent(shop.words.callIt("giftCardInitialBalance")) {
                    HStack(spacing: 4) {
                        TextField("", value: $balance,
                                  format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                        Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(shop.words.callIt("giftCardIssuedTo")) {
                    Picker("", selection: $issuedTo) {
                        Text(shop.words.callIt("common.none")).tag(String?.none)
                        ForEach(shop.clients) { client in
                            Text(shop.clientNames[client.id]?.name ?? client.id)
                                .tag(String?.some(client.id))
                        }
                    }
                    .labelsHidden()
                }
                LabeledContent(shop.words.callIt("giftCardExpiry")) {
                    // Optional, and it has to stay optional: a card with no
                    // expiry never expires, and a date picker that cannot be
                    // empty would quietly give every card one.
                    OptionalDate(date: $expires, shop: shop)
                }
            }
            .formStyle(.grouped)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Khayt.attention)
                    .padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) { issue() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: Self.width)
        .onAppear {
            code = Shop.giftCardCode()
            focused = true
        }
    }

    private func issue() {
        problem = nil
        Task {
            if let why = await shop.issueGiftCard(code: code, balance: balance,
                                                  issuedTo: issuedTo, expires: expires) {
                problem = why
            } else {
                dismiss()
            }
        }
    }
}

/// A date that is allowed to be absent.
///
/// `DatePicker` has no empty state, so a card with no expiry would be given
/// today's — an expiry date nobody chose, on a card that was meant never to
/// expire. The toggle is the honest way to say "there isn't one".
struct OptionalDate: View {
    @Binding var date: Date?
    let shop: Shop

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { date != nil },
                set: { date = $0 ? (date ?? Date()) : nil }
            ))
            .labelsHidden()
            if let bound = Binding($date) {
                DatePicker("", selection: bound, displayedComponents: .date)
                    .labelsHidden()
            } else {
                Text(shop.words.callIt("common.none")).foregroundStyle(.tertiary)
            }
        }
    }
}
