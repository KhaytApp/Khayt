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
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        let consent = shop.telemetryConsent
        Section(shop.words.callIt("tel.section")) {
            Text(shop.words.callIt("tel.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Each switch says only its own stream. The other is read off the
            // book inside the write, never from this draw's `consent`, which
            // a quick second flick would otherwise turn back off.
            Toggle(isOn: Binding(get: { shop.telemetryConsent.crash }, set: { on in
                Task { await shop.setTelemetry(crash: on) }
            })) {
                labelled("tel.crash", "tel.crash_hint")
            }
            if consent.crash { testReport }
            Toggle(isOn: Binding(get: { shop.telemetryConsent.usage }, set: { on in
                Task { await shop.setTelemetry(usage: on) }
            })) {
                labelled("tel.usage", "tel.usage_hint")
            }
            DisclosureGroup(shop.words.callIt("tel.view")) {
                collected(consent)
            }
        }
        .disabled(!shop.canWrite || !shop.source.isReal)
    }

    /// One test crash report, sent now — so a shop asked "are reports
    /// reaching you?" can find out, and so can we.
    private var testReport: some View {
        HStack(spacing: 8) {
            Button(shop.words.callIt("mac.tel_test")) {
                testing = true; testResult = nil
                Task {
                    let reason = await Telemetry.shared.sendTest(shop)
                    testResult = Self.resultKey(reason)
                    testing = false
                }
            }
            .disabled(testing)
            if testing { ProgressView().controlSize(.small) }
            if let testResult {
                Text(shop.words.callIt(testResult)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What a test send came to, as words: `flush`'s reason.
    nonisolated static func resultKey(_ reason: String) -> String {
        switch reason {
        case "accepted": "mac.tel_test_sent"
        case "unreachable", "retry", "rate-limited", "backoff": "mac.tel_test_later"
        case "development-build": "mac.tel_test_dev"
        default: "mac.tel_test_failed"
        }
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
        // What `lib/telemetry-scrub.js` takes out, as the privacy page says
        // it: emails, phone numbers, long numbers (IBANs among them) and file
        // paths. NOT person names — the scrubber has no way to know one.
        "mac.tel_card_body": ["en": "Khayt sends nothing unless you allow it. A crash report tells us what went wrong, with emails, phone numbers, long numbers and file paths taken out. Never your orders, customers, prices or files.",
                              "ar": "لا يرسل خيط شيئًا ما لم تسمح بذلك. يخبرنا تقرير العطل بما حدث بعد حذف عناوين البريد الإلكتروني وأرقام الهواتف والأرقام الطويلة ومسارات الملفات، ولا يتضمن أبدًا طلباتك أو عملاءك أو أسعارك أو ملفاتك."],
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
        "mac.tel_test": ["en": "Send a Test Report",
                         "ar": "إرسال تقرير تجريبي"],
        "mac.tel_test_sent": ["en": "Sent. Crash reports from this Mac are reaching Khayt.",
                              "ar": "تم الإرسال. تقارير الأعطال من هذا الماك تصل إلى خيط."],
        "mac.tel_test_later": ["en": "Could not reach Khayt just now. The report will be sent later.",
                               "ar": "تعذّر الوصول إلى خيط الآن. سيُرسل التقرير لاحقًا."],
        "mac.tel_test_dev": ["en": "A development build sends nothing.",
                             "ar": "نسخة التطوير لا ترسل شيئًا."],
        "mac.tel_test_failed": ["en": "The test report was not sent.",
                                "ar": "لم يُرسل التقرير التجريبي."],
        // The same words in the desktop and iPhone apps and on
        // khaytapp.com/privacy #active-count.
        "mac.active_count": ["en": "Count this install (anonymous)",
                             "ar": "احتساب هذا التثبيت (دون هوية)"],
        "mac.active_count_hint": ["en": "Once a day, sends only the app's platform, version and release channel, and whether this is its first day this week, this month or ever. No id, nothing about your shop.",
                                  "ar": "مرة في اليوم، يُرسل نوع الجهاز وإصدار التطبيق وقناة إصداره فقط، وهل هذا أول يوم له في هذا الأسبوع أو الشهر أو على الإطلاق. لا معرّف، ولا شيء عن مطبعتك."],
    ]
}
