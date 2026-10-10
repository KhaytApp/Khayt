import SwiftUI
import KhaytCore

/// The one-time ask (#1789): a card across the top of the window, never a
/// modal, never in front of anything. It offers crash reports, usage counts
/// as an extra, and "Not now" — and whichever is pressed, this Mac does not
/// ask again (`Telemetry.asked`). Settings ▸ Preferences keeps the two
/// switches for good.
///
/// Laid out to fit the narrowest window the app allows (900pt, less the
/// sidebar) in either language: the sentence wraps, and the buttons drop under
/// the note when they no longer fit beside it.
struct TelemetryCard: View {
    let shop: Shop
    /// For a photograph: the card as it looks to a shop that has not answered.
    var shown = false
    @State private var alsoUsage = false
    @State private var busy = false

    var body: some View {
        if shown || Telemetry.shared.shouldAsk(shop) {
            VStack(alignment: .leading, spacing: 8) {
                Label(shop.words.callIt("mac.tel_card_title"), systemImage: "hand.raised")
                    .font(.headline)
                Text(shop.words.callIt("mac.tel_card_body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $alsoUsage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shop.words.callIt("mac.tel_card_usage"))
                        Text(shop.words.callIt("tel.usage_hint"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        note
                        Spacer(minLength: 8)
                        buttons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        note
                        HStack(spacing: 12) { Spacer(minLength: 0); buttons }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary)
            .disabled(busy)
        }
    }

    private var note: some View {
        Text(shop.words.callIt("mac.tel_card_later"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var buttons: some View {
        Button(shop.words.callIt("mac.tel_card_not_now")) { Telemetry.shared.markAsked() }
        Button(shop.words.callIt("mac.tel_card_share")) {
            busy = true
            Task {
                await shop.setTelemetry(crash: true, usage: alsoUsage)
                busy = false
            }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
}

/// The permanent switches, in Settings ▸ Preferences. Saved the moment they
/// change, like the mode picker, because the consent is the shop's choice and
/// not part of the pane's draft.
struct TelemetrySettings: View {
    let shop: Shop

    var body: some View {
        let consent = shop.telemetryConsent
        Section(shop.words.callIt("tel.section")) {
            Text(shop.words.callIt("tel.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(get: { consent.crash }, set: { on in
                Task { await shop.setTelemetry(crash: on, usage: consent.usage) }
            })) {
                labelled("tel.crash", "tel.crash_hint")
            }
            Toggle(isOn: Binding(get: { consent.usage }, set: { on in
                Task { await shop.setTelemetry(crash: consent.crash, usage: on) }
            })) {
                labelled("tel.usage", "tel.usage_hint")
            }
            DisclosureGroup(shop.words.callIt("tel.view")) {
                collected(consent)
            }
        }
        .disabled(!shop.canWrite || !shop.source.isReal)
    }

    private func labelled(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(shop.words.callIt(title))
            Text(shop.words.callIt(hint))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Exactly what is queued, as it would go — the payloads the scrubber
    /// built, and nothing else. The spec's "View what's collected".
    @ViewBuilder private func collected(_ consent: TelemetryConsent) -> some View {
        if !consent.any {
            Text(shop.words.callIt("tel.nothing")).font(.caption).foregroundStyle(.secondary)
        } else if let file = Telemetry.file(for: shop), let json = Telemetry.shared.pending(file: file) {
            Text(shop.words.callIt("tel.view_hint")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // JSON reads left to right in either language.
                    .environment(\.layoutDirection, .leftToRight)
            }
            .frame(maxHeight: 220)
        } else {
            Text(shop.words.callIt("mac.tel_queue_empty")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The card's words, merged into `Words.own`. A table of its own, as
/// `ReviewWords` is, so a key here cannot collide inside `Words.base`'s
/// literal — where a repeat traps at launch (`DuplicateWordKeyTests`).
/// The Settings switches use Khayt's own `tel.*` words, so both apps name
/// them the same.
enum TelemetryWords {
    nonisolated static let table: [String: [String: String]] = [
        "mac.tel_card_title": ["en": "Help make Khayt better?",
                               "ar": "هل تساعدنا في تحسين خيط؟"],
        "mac.tel_card_body": ["en": "Khayt sends nothing unless you allow it. A crash report tells us what went wrong, with names, numbers and file paths taken out. Never your orders, customers, prices or files.",
                              "ar": "لا يرسل خيط شيئًا ما لم تسمح بذلك. يخبرنا تقرير العطل بما حدث بعد حذف الأسماء والأرقام ومسارات الملفات، ولا يتضمن أبدًا طلباتك أو عملاءك أو أسعارك أو ملفاتك."],
        "mac.tel_card_usage": ["en": "Also share usage counts",
                               "ar": "مشاركة أعداد الاستخدام أيضًا"],
        "mac.tel_card_share": ["en": "Share Crash Reports",
                               "ar": "مشاركة تقارير الأعطال"],
        "mac.tel_card_not_now": ["en": "Not Now",
                                 "ar": "ليس الآن"],
        "mac.tel_card_later": ["en": "You can change this any time in Settings, under Preferences.",
                               "ar": "يمكنك تغيير ذلك في أي وقت من الإعدادات، ضمن التفضيلات."],
        "mac.tel_queue_empty": ["en": "Nothing is waiting to be sent.",
                                "ar": "لا شيء بانتظار الإرسال."],
    ]
}
