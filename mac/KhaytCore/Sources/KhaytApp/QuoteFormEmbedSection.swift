import AppKit
import SwiftUI
import KhaytCore

/// Settings › Online › "Quote form for your store".
///
/// The LINK first: it works on any store, while whether Salla's or Zid's page
/// builders accept an iframe or a script tag is not verified. Every address
/// comes from the cloud's `links`; nothing here builds one.
///
/// Saves itself with its own button, like online storage at the top of the
/// pane; the pane's Save bar is not its business.
struct QuoteFormEmbedSection: View {
    let shop: Shop

    @State private var pane: Shop.QuoteFormPane?
    @State private var enabled = false
    @State private var originsText = ""
    @State private var lang = "ar"
    @State private var theme = "light"
    @State private var busy = false
    @State private var problem: String?
    @State private var copied: String?
    private let preloaded: Bool
    /// The rows in a plain stack, for a photograph: `ImageRenderer` cannot
    /// draw a `Form`.
    private let flat: Bool

    /// `shown` draws this state without asking the cloud: for a photograph.
    init(shop: Shop, shown: Shop.QuoteFormPane? = nil, flat: Bool = false) {
        self.shop = shop
        self.flat = flat
        preloaded = shown != nil
        _pane = State(initialValue: shown)
        // The form's language starts as the shop's own.
        _lang = State(initialValue: shop.words.language == "ar" ? "ar" : "en")
        if case .shown(let s)? = shown {
            _enabled = State(initialValue: s.enabled)
            _originsText = State(initialValue: s.origins.joined(separator: "\n"))
        }
    }

    private var words: Words { shop.words }
    private var canChange: Bool { shop.cloudCanManageEmbed }

    var body: some View {
        Group {
            if flat {
                VStack(alignment: .leading, spacing: 10) {
                    Text(words.callIt("mac.qfe_title")).font(.headline)
                    rows
                }
            } else {
                Section(words.callIt("mac.qfe_title")) { rows }
            }
        }
        .task { if !preloaded { await load() } }
    }

    @ViewBuilder private var rows: some View {
        Text(words.callIt("mac.qfe_desc"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        switch pane {
        case nil:
            ProgressView().controlSize(.small)
        case .needsCloud?:
            Label(words.callIt("mac.qfe_needs_cloud"), systemImage: "icloud.slash")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .notAvailable?:
            // Calm, not an error: the cloud has it switched off on purpose.
            Label(words.callIt("mac.qfe_not_available"), systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .problem(let said)?:
            Text(said).font(.caption).foregroundStyle(Khayt.attention)
                .fixedSize(horizontal: false, vertical: true)
            Button(words.callIt("mac.qfe_try_again")) { Task { await load() } }
                .controlSize(.small)
        case .shown(let state)?:
            shown(state)
        }
    }

    // MARK: - The form, as the cloud has it

    @ViewBuilder private func shown(_ state: QuoteFormEmbed.State) -> some View {
        // SAVES ITSELF. Flipped and left, it looked on and was not.
        Toggle(words.callIt("mac.qfe_enable"), isOn: $enabled).disabled(!canChange || busy)
            .onChange(of: enabled) { _, now in
                if now != state.enabled, canChange { Task { await save() } }
            }
        // WHERE REQUESTS ARRIVE, and the form as a visitor sees it.
        HStack {
            Text(words.callIt("mac.qfe_where")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(words.callIt("mac.qfe_open_requests")) {
                shop.openOnlineOrders()
                NSApp.keyWindow?.performClose(nil)
            }
            .controlSize(.small)
            if let page = state.links?.page, let url = URL(string: QuoteFormEmbed.page(page, lang: lang, theme: theme)) {
                Button(words.callIt("mac.qfe_preview")) { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
        }

        // ── WHAT IT CAN AND CANNOT DO RIGHT NOW ─────────────────────────
        if state.priceAvailable == false {
            Label(words.callIt("mac.qfe_no_price"), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Khayt.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
        if state.keepsFiles == false {
            Label(words.callIt("mac.qfe_no_files"), systemImage: "doc.badge.ellipsis")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let files = state.files, let line = filesLine(files) {
            LabeledContent(words.callIt("mac.qfe_files")) {
                Text(line).font(.caption).monospacedDigit()
            }
        }
        if let month = state.month, month.quotes != nil || month.requests != nil {
            LabeledContent(words.callIt("mac.qfe_month")) {
                Text(words.callIt("mac.qfe_month_line", [
                    "quotes": .number(Double(month.quotes ?? 0)),
                    "requests": .number(Double(month.requests ?? 0)),
                ])).font(.caption).monospacedDigit()
            }
        }

        // ── WHERE IT MAY BE FRAMED ───────────────────────────────────────
        VStack(alignment: .leading, spacing: 4) {
            Text(words.callIt("mac.qfe_origins")).font(.callout)
            // An editor only for a sign-in that may change the list (and
            // never in a photograph, which cannot draw one); everybody else
            // reads it.
            if canChange && !flat {
                TextEditor(text: $originsText)
                    .font(.body.monospaced())
                    .frame(minHeight: 54, maxHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                    .disabled(busy)
            } else {
                Text(verbatim: state.origins.isEmpty ? "—" : state.origins.joined(separator: "\n"))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(words.callIt("mac.qfe_origins_hint", ["n": .number(Double(QuoteFormEmbed.maxOrigins))]))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A PLATFORM'S OWN ADDRESS IS EVERY STORE ON IT. Allowing it lets
            // any Salla or Zid store frame this shop's form.
            ForEach(QuoteFormEmbed.sharedPlatformOrigins(QuoteFormEmbed.tidy(originsText.components(separatedBy: .newlines))), id: \.self) { origin in
                Label(words.callIt("mac.qfe_origins_shared", ["origin": .string(origin)]),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if canChange {
            HStack {
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(words.callIt("mac.qfe_save")) { Task { await save() } }
                    .disabled(busy || !changed(state))
            }
        } else {
            Text(words.callIt("mac.qfe_managers_only")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // ── THE THREE WAYS ON TO A STORE, LINK FIRST ────────────────────
        if let links = state.links, links.page != nil || links.frame != nil || links.script != nil {
            Divider()
            HStack {
                Picker(words.callIt("mac.qfe_lang"), selection: $lang) {
                    Text(verbatim: "العربية").tag("ar")
                    Text(verbatim: "English").tag("en")
                }
                .fixedSize()
                Picker(words.callIt("mac.qfe_theme"), selection: $theme) {
                    Text(words.callIt("mac.qfe_theme_light")).tag("light")
                    Text(words.callIt("mac.qfe_theme_dark")).tag("dark")
                }
                .fixedSize()
            }
            if let page = links.page {
                snippet("mac.qfe_link", hint: "mac.qfe_link_hint",
                        QuoteFormEmbed.page(page, lang: lang, theme: theme))
            }
            if let frame = links.frame {
                snippet("mac.qfe_frame", hint: "mac.qfe_frame_hint",
                        QuoteFormEmbed.frame(frame, title: words.callIt("mac.qfe_title"),
                                             lang: lang, theme: theme))
            }
            if let script = links.script, let shopId = shopId {
                snippet("mac.qfe_script", hint: "mac.qfe_script_hint",
                        QuoteFormEmbed.script(script, shopId: shopId, lang: lang, theme: theme))
            }
        }
    }

    private var shopId: String? {
        guard case .object(let cloud)? = shop.settingsDict["cloud"],
              case .string(let id)? = cloud["shopId"], !id.isEmpty else { return nil }
        return id
    }

    @ViewBuilder private func snippet(_ title: String, hint: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(words.callIt(title)).font(.callout.weight(.medium))
                Spacer()
                Button(copied == text ? words.callIt("mac.qfe_copied") : words.callIt("mac.qfe_copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = text
                }
                .controlSize(.small)
            }
            // An address and markup are not words: kept left-to-right inside
            // an Arabic pane.
            Text(verbatim: text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .leftToRight)
                .fixedSize(horizontal: false, vertical: true)
            Text(words.callIt(hint)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func filesLine(_ f: QuoteFormEmbed.State.Files) -> String? {
        var parts: [String] = []
        if let count = f.count {
            parts.append(f.maxCount.map { words.callIt("mac.qfe_files_count_of", ["n": .number(Double(count)), "max": .number(Double($0))]) }
                         ?? words.counting(count, "mac.qfe_files_count"))
        }
        if let bytes = f.bytes {
            // In the units the form itself says ("up to 32 MB" is 32 MiB),
            // so the pane and the form name the same limit the same way.
            let used = Format.memorySize(Int64(bytes))
            parts.append(f.maxBytes.map { used + " / " + Format.memorySize(Int64($0)) } ?? used)
        }
        if let each = f.maxFileBytes {
            parts.append(words.callIt("mac.qfe_files_each", ["size": .string(Format.memorySize(Int64(each)))]))
        }
        guard !parts.isEmpty else { return nil }
        return parts.map { "\u{2068}" + $0 + "\u{2069}" }.joined(separator: " · ")
    }

    private func changed(_ state: QuoteFormEmbed.State) -> Bool {
        enabled != state.enabled || QuoteFormEmbed.tidy(originsText.components(separatedBy: .newlines)) != state.origins
    }

    // MARK: - Asking the cloud

    private func load() async {
        let read = await shop.readQuoteFormEmbed()
        pane = read
        if case .shown(let s) = read {
            enabled = s.enabled
            originsText = s.origins.joined(separator: "\n")
        }
    }

    private func save() async {
        problem = nil
        let origins = QuoteFormEmbed.tidy(originsText.components(separatedBy: .newlines))
        // The cloud's rule, here first: the same sentence it would send back.
        if let local = QuoteFormEmbed.problem(origins) {
            problem = shop.embedProblem(local)
            return
        }
        busy = true
        defer { busy = false }
        switch await shop.saveQuoteFormEmbed(enabled: enabled, origins: origins) {
        case .success(let state):
            pane = .shown(state)
            enabled = state.enabled
            originsText = state.origins.joined(separator: "\n")
        case .failure(let failure):
            if failure.notAvailable { pane = .notAvailable } else { problem = failure.sentence }
        }
    }
}
