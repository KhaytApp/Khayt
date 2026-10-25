import AppKit
import SafariServices
import SwiftUI
import KhaytCore
import KhaytWebSave

// ── SAVE TO KHAYT, ON SCREEN ──────────────────────────────────────────────
//
// Two places: the model's page in the library says where a saved page came
// from (and opens it), and Settings ▸ Preferences says whether this Mac takes
// saves from the browser and how the extension is switched on.

/// "From the web", on a saved model's page.
struct WebSourceSection: View {
    let shop: Shop
    let file: LibraryFile

    var body: some View {
        let w = shop.words
        VStack(alignment: .leading, spacing: 8) {
            DetailSection(w.callIt("mac.sfw_the_page")) {
                DetailLine(w.callIt("mac.sfw_site"), Self.siteName(file))
                if let at = file.savedFromWebAt.flatMap(Calendar.instant) {
                    DetailLine(w.callIt("mac.sfw_saved_on"), w.say(at, Date.FormatStyle(date: .abbreviated, time: .omitted)))
                }
                // The page's own words only when Khayt could not name the
                // licence: a translated one is already under Where it came from.
                if let text = file.sourceLicenceText, !text.isEmpty, ModelLicence.find(file.licence) == nil {
                    DetailLine(w.callIt("mac.sfw_page_licence"), text)
                }
                if let links = file.sourceFiles, !links.isEmpty {
                    DetailLine(w.callIt("mac.sfw_files_on_page"),
                               links.compactMap(\.name).filter { !$0.isEmpty }.prefix(4).joined(separator: ", "))
                }
            }
            if let note = file.sourceNote, !note.isEmpty {
                Text(note)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if file.sourceUrl.flatMap(WebSave.https) != nil {
                Button { shop.openWebSource(file) } label: {
                    Label(w.callIt("mac.sfw_open_page"), systemImage: "safari")
                }
                .controlSize(.small)
                .help(file.sourceUrl ?? "")
            }
        }
    }

    /// The site's own name, or the page's host for any other site.
    static func siteName(_ file: LibraryFile) -> String {
        let site = WebSave.Site(rawValue: file.sourceSite ?? "") ?? .web
        if site != .web { return site.displayName }
        var host = file.sourceUrl.flatMap { URL(string: $0)?.host() } ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// Settings ▸ Preferences ▸ Browser extension.
///
/// Mac-local, like the rest of "On this Mac": whether THIS Mac takes pages
/// from the browser is about this Mac's browser, not the shop's book. The
/// Safari half is switched on in Safari itself — an app can open that page
/// and report what Safari says, never flip it — so this shows the state and
/// the door to it.
struct BrowserExtensionSettings: View {
    let shop: Shop
    @Bindable var inbox = WebSaveInbox.shared
    @State private var safari: SafariState = .checking

    enum SafariState { case checking, on, off, notFound }

    /// The Safari extension's bundle identifier (`make-app.sh`).
    static let safariExtensionId = "app.khayt.mac.safari"

    var body: some View {
        let w = shop.words
        Section(w.callIt("mac.sfw_settings")) {
            Text(w.callIt("mac.sfw_settings_note"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(w.callIt("mac.sfw_accept"), isOn: $inbox.accepting)
                .disabled(!inbox.available)
            if inbox.available {
                LabeledContent(w.callIt("mac.sfw_safari")) {
                    HStack(spacing: 8) {
                        Text(w.callIt(safariKey))
                            .foregroundStyle(safari == .on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        Button(w.callIt("mac.sfw_safari_open")) { Self.openSafariSettings() }
                            .controlSize(.small)
                    }
                }
                // Chrome, Edge, Brave, Vivaldi, Firefox: the host manifest,
                // written and removed only on a click here.
                BrowserHostRows(shop: shop)
            } else {
                Text(w.callIt("mac.sfw_no_group"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let last = inbox.lastSaved {
                Text(w.callIt("mac.sfw_last", ["title": .string(last.title)]))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let added = inbox.lastAttached {
                Text(w.callIt("mac.sfw_last_attached", ["name": .string(added.name)]))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(w.callIt("mac.sfw_privacy"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { safari = await Self.safariState() }
        // Coming back from Safari's settings: ask again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { safari = await Self.safariState() }
        }
    }

    private var safariKey: String {
        switch safari {
        case .checking: "mac.sfw_safari_checking"
        case .on: "mac.sfw_safari_on"
        case .off: "mac.sfw_safari_off"
        case .notFound: "mac.sfw_safari_not_found"
        }
    }

    /// What Safari says about the extension. Pretended in a snapshot.
    static func safariState() async -> SafariState {
        if let pretend = pretendSafari { return pretend }
        return await withCheckedContinuation { done in
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: safariExtensionId) { state, error in
                done.resume(returning: error != nil ? .notFound : (state?.isEnabled == true ? .on : .off))
            }
        }
    }

    nonisolated(unsafe) static var pretendSafari: SafariState?

    static func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: safariExtensionId) { _ in }
    }
}

/// The words of Save to Khayt, in both languages. Merged into `Words.own`.
enum WebSaveWords {
    nonisolated static let table: [String: [String: String]] = [
        "mac.sfw_saved_from_web": ["en": "Saved from web", "ar": "محفوظ من الويب"],
        "mac.sfw_sec_web": ["en": "From the web", "ar": "من الويب"],
        "mac.sfw_the_page": ["en": "The page", "ar": "الصفحة"],
        "mac.sfw_not_downloaded": ["en": "Not downloaded yet", "ar": "لم يُنزَّل بعد"],
        "mac.sfw_open_page": ["en": "Open Page", "ar": "فتح الصفحة"],
        "mac.sfw_site": ["en": "Site", "ar": "الموقع"],
        "mac.sfw_saved_on": ["en": "Saved", "ar": "تاريخ الحفظ"],
        "mac.sfw_page_licence": ["en": "Licence on the page", "ar": "الترخيص في الصفحة"],
        "mac.sfw_files_on_page": ["en": "Files on the page", "ar": "الملفات في الصفحة"],
        "mac.sfw_download_hint": ["en": "Download the model from its page, then add the file to the library to print it.",
                                 "ar": "نزّل النموذج من صفحته، ثم أضف الملف إلى المكتبة لطباعته."],
        "mac.sfw_settings": ["en": "Browser extension", "ar": "إضافة المتصفح"],
        "mac.sfw_settings_note": ["en": "Save to Khayt adds a model's page from Printables, MakerWorld, Thingiverse and other sites to your library — its link, creator, licence, tags and picture — on the Print next list.",
                                 "ar": "تضيف «احفظ في خيط» صفحة نموذج من Printables وMakerWorld وThingiverse وغيرها إلى مكتبتك — رابطه ومصممه وترخيصه ووسومه وصورته — في قائمة «للطباعة لاحقًا»."],
        "mac.sfw_accept": ["en": "Accept pages saved from the browser", "ar": "قبول الصفحات المحفوظة من المتصفح"],
        "mac.sfw_safari": ["en": "Safari", "ar": "متصفح Safari"],
        "mac.sfw_safari_checking": ["en": "Checking…", "ar": "جارٍ التحقق…"],
        "mac.sfw_safari_on": ["en": "On", "ar": "مفعّلة"],
        "mac.sfw_safari_off": ["en": "Off — turn it on in Safari's settings", "ar": "متوقفة — فعّلها من إعدادات Safari"],
        "mac.sfw_safari_not_found": ["en": "Not found — open Khayt from Applications once, then try again",
                                    "ar": "غير موجودة — افتح خيط من مجلد التطبيقات مرة، ثم حاول مجددًا"],
        "mac.sfw_safari_open": ["en": "Open Safari Settings…", "ar": "فتح إعدادات Safari…"],
        "mac.sfw_no_group": ["en": "This build of Khayt was not signed by a developer team, so it has no folder to share with the extension. Use a build from khaytapp.com.",
                            "ar": "هذه النسخة من خيط غير موقّعة من فريق مطوّر، لذا لا تملك مجلدًا مشتركًا مع الإضافة. استخدم نسخة من khaytapp.com."],
        "mac.sfw_last": ["en": "Last saved: {title}", "ar": "آخر ما حُفظ: {title}"],
        "mac.sfw_privacy": ["en": "Page details go to Khayt on this Mac and nowhere else. Khayt fetches only the page's picture, from the site itself.",
                           "ar": "تذهب تفاصيل الصفحة إلى خيط على هذا الجهاز فقط ولا تُرسل إلى أي مكان آخر. لا يجلب خيط إلا صورة الصفحة، من الموقع نفسه."],
    ]
}
