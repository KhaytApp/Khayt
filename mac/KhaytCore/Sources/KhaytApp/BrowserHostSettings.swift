import AppKit
import SwiftUI
import KhaytWebSave

/// Settings ▸ Preferences ▸ Browser extension: one row per browser on this
/// Mac that Save to Khayt can run in besides Safari.
///
/// Each row says whether that browser can reach Khayt, and its button writes
/// or deletes the host manifest (`BrowserHosts`) — on the shop's click only.
/// Khayt never writes one on its own, and Remove deletes only the file Khayt
/// wrote. A browser that is not installed has no row.
struct BrowserHostRows: View {
    let shop: Shop
    @State private var statuses: [BrowserHosts.Browser: BrowserHosts.Status] = [:]
    @State private var installed: [BrowserHosts.Browser] = []
    @State private var problem: String?

    /// What a snapshot shows instead of this Mac's browsers and files.
    struct Pretend {
        var installed: [BrowserHosts.Browser]
        var statuses: [BrowserHosts.Browser: BrowserHosts.Status]
        var hostPath: String?
        var chromiumIds: [String]
    }
    nonisolated(unsafe) static var pretend: Pretend?

    // MARK: - This Mac

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The host inside this copy of Khayt, or nil — a development run from
    /// `swift run` has none, and a manifest pointing nowhere is not written.
    static var hostPath: String? {
        if let pretend { return pretend.hostPath }
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(BrowserHosts.executableName)")
        return Bundle.main.bundleURL.pathExtension == "app" && FileManager.default.isExecutableFile(atPath: url.path)
            ? url.path : nil
    }

    static var chromiumIds: [String] {
        if let pretend { return pretend.chromiumIds }
        return BrowserHosts.chromiumIds(dev: UserDefaults.standard.stringArray(forKey: BrowserHosts.devIdsKey) ?? [])
    }

    static func installedBrowsers() -> [BrowserHosts.Browser] {
        if let pretend { return pretend.installed }
        return BrowserHosts.Browser.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        }
    }

    private func refresh() {
        installed = Self.installedBrowsers()
        if let pretend = Self.pretend { statuses = pretend.statuses; return }
        let path = Self.hostPath ?? ""
        statuses = Dictionary(uniqueKeysWithValues: installed.map {
            ($0, BrowserHosts.status($0, home: Self.home, hostPath: path, chromiumIds: Self.chromiumIds))
        })
    }

    // MARK: - The rows

    var body: some View {
        let w = shop.words
        Group {
            if installed.isEmpty {
                Text(w.callIt("mac.sfw_host_none"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(installed) { browser in
                LabeledContent(browser.displayName) {
                    HStack(spacing: 8) {
                        Text(w.callIt(statusKey(browser)))
                            .foregroundStyle(statuses[browser] == .on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .multilineTextAlignment(.trailing)
                        buttons(browser)
                    }
                }
            }
            if !installed.isEmpty {
                Text(w.callIt(Self.hostPath == nil ? "mac.sfw_host_no_program" : "mac.sfw_host_note"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(w.callIt("mac.sfw_downloads_note"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func waitingForStore(_ browser: BrowserHosts.Browser) -> Bool {
        browser.isChromium && Self.chromiumIds.isEmpty
    }

    private func statusKey(_ browser: BrowserHosts.Browser) -> String {
        switch statuses[browser] ?? .off {
        case .on: "mac.sfw_host_on"
        case .stale: "mac.sfw_host_stale"
        case .foreign: "mac.sfw_host_foreign"
        case .off: waitingForStore(browser) ? "mac.sfw_host_waiting" : "mac.sfw_host_off"
        }
    }

    @ViewBuilder
    private func buttons(_ browser: BrowserHosts.Browser) -> some View {
        let w = shop.words
        let status = statuses[browser] ?? .off
        if status == .off || status == .stale {
            Button(w.callIt(status == .stale ? "mac.sfw_host_update" : "mac.sfw_host_install")) { install(browser) }
                .controlSize(.small)
                .disabled(Self.hostPath == nil || waitingForStore(browser))
        }
        if status == .on || status == .stale {
            Button(w.callIt("mac.sfw_host_remove")) { remove(browser) }
                .controlSize(.small)
        }
    }

    private func install(_ browser: BrowserHosts.Browser) {
        problem = nil
        guard Self.pretend == nil, let path = Self.hostPath else { return }
        do {
            try BrowserHosts.install(browser, home: Self.home, hostPath: path, chromiumIds: Self.chromiumIds)
        } catch {
            problem = said(error, browser)
        }
        refresh()
    }

    private func remove(_ browser: BrowserHosts.Browser) {
        problem = nil
        guard Self.pretend == nil else { return }
        do { try BrowserHosts.remove(browser, home: Self.home) } catch { problem = said(error, browser) }
        refresh()
    }

    private func said(_ error: BrowserHosts.Failure, _ browser: BrowserHosts.Browser) -> String {
        let w = shop.words
        return switch error {
        case .foreign: w.callIt("mac.sfw_host_foreign")
        case .noExtensionId: w.callIt("mac.sfw_host_waiting")
        case .write(let why): w.callIt("mac.sfw_host_failed", ["browser": .string(browser.displayName), "why": .string(why)])
        }
    }
}

/// The words of the browser rows, in both languages. Merged into `Words.own`.
enum BrowserHostWords {
    nonisolated static let table: [String: [String: String]] = [
        "mac.sfw_host_on": ["en": "Connected", "ar": "متصل"],
        "mac.sfw_host_off": ["en": "Not connected", "ar": "غير متصل"],
        "mac.sfw_host_stale": ["en": "Needs updating", "ar": "يحتاج إلى تحديث"],
        "mac.sfw_host_foreign": ["en": "Another program's file is there — left alone",
                                 "ar": "يوجد ملف لبرنامج آخر — تُرك كما هو"],
        "mac.sfw_host_waiting": ["en": "Waiting for the store listing", "ar": "بانتظار نشرها في المتجر"],
        "mac.sfw_host_install": ["en": "Install", "ar": "تثبيت"],
        "mac.sfw_host_update": ["en": "Update", "ar": "تحديث"],
        "mac.sfw_host_remove": ["en": "Remove", "ar": "إزالة"],
        "mac.sfw_host_none": ["en": "No Chrome, Edge, Brave, Vivaldi or Firefox on this Mac.",
                              "ar": "لا يوجد Chrome أو Edge أو Brave أو Vivaldi أو Firefox على هذا الجهاز."],
        "mac.sfw_host_note": ["en": "Install puts one small file in that browser's folder so Save to Khayt in it can reach Khayt. Remove deletes only that file.",
                              "ar": "يضع «تثبيت» ملفًا صغيرًا في مجلد ذلك المتصفح ليتمكن «احفظ في خيط» فيه من الوصول إلى خيط. ولا يحذف «إزالة» إلا ذلك الملف."],
        "mac.sfw_host_no_program": ["en": "This copy of Khayt has no browser host (a development build). Use a build from khaytapp.com.",
                                    "ar": "هذه النسخة من خيط لا تحتوي على برنامج الاتصال بالمتصفح (نسخة تطوير). استخدم نسخة من khaytapp.com."],
        "mac.sfw_host_failed": ["en": "Could not change {browser}: {why}", "ar": "تعذّر تغيير {browser}: {why}"],
        "mac.sfw_downloads_note": ["en": "After you save a page, a model you download from it within 10 minutes is offered to that model — Khayt asks before adding it, and the download stays where it is. In Safari, Khayt looks in your Downloads folder for those 10 minutes only.",
                                   "ar": "بعد حفظ صفحة، يُعرض عليك أي نموذج تنزّله منها خلال 10 دقائق لإضافته إلى ذلك النموذج — يسألك خيط قبل الإضافة، ويبقى الملف المُنزَّل في مكانه. في Safari، ينظر خيط في مجلد التنزيلات خلال هذه الدقائق العشر فقط."],
    ]
}
