import SwiftUI
import UniformTypeIdentifiers
import KhaytCore

// The desktop's order-flow screens on the Mac — the rules are in
// `Shop+OrderFlow.swift` and `lib/csv-import.js`; these only draw them.

/// May whoever is here change the shop's settings lists?
@MainActor private func mayEditLists(_ shop: Shop) -> Bool {
    shop.canWrite && shop.lockAllows("settings", "edit")
}

// MARK: - Settings: three lists the desktop edits in place

/// One list of labelled entries with an add field — the post-processing
/// checklist and the custom order fields, which the desktop draws alike.
private struct LabelListSection: View {
    let shop: Shop
    let list: Shop.SettingsList
    let titleKey: String
    let hintKey: String
    let emptyKey: String
    let placeholderKey: String
    let make: (String) -> [String: JSONValue]?
    /// The small grey word after a label — a custom field's type.
    var detail: (([String: JSONValue]) -> String?)? = nil
    @State private var typed = ""

    var body: some View {
        let words = shop.words
        let rows = shop.settingsList(list)
        Section {
            if rows.isEmpty {
                Text(words.callIt(emptyKey)).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack {
                    Text(Shop.plainString(row["label"]) ?? "")
                    Spacer()
                    if let d = detail?(row) {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await shop.editSettingsList(list, .remove(index: i, record: row)) }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help(words.callIt("common.delete"))
                    .accessibilityLabel(words.callIt("common.delete"))
                    .disabled(!mayEditLists(shop))
                }
            }
            HStack {
                TextField("", text: $typed, prompt: Text(words.callIt(placeholderKey)))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(words.callIt("common.add"), action: add)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || !mayEditLists(shop))
            }
        } header: {
            Text(words.callIt(titleKey))
        } footer: {
            Text(words.callIt(hintKey))
        }
    }

    private func add() {
        guard mayEditLists(shop), let record = make(typed) else { return }
        typed = ""
        Task { await shop.editSettingsList(list, .add(record)) }
    }
}

/// Settings ▸ Operations: the post-processing checklist (`settings.postChecklist`).
struct PostChecklistSettingsSection: View {
    let shop: Shop
    var body: some View {
        LabelListSection(shop: shop, list: .postChecklist, titleKey: "post.settings_title",
                         hintKey: "post.settings_hint", emptyKey: "post.empty",
                         placeholderKey: "post.step_ph", make: Shop.newPostCheck)
    }
}

/// Settings ▸ Operations: the shop's own order fields (`settings.customFields`).
struct CustomFieldsSettingsSection: View {
    let shop: Shop
    var body: some View {
        LabelListSection(shop: shop, list: .customFields, titleKey: "set.custom_fields_title",
                         hintKey: "set.custom_fields_hint", emptyKey: "set.custom_fields_empty",
                         placeholderKey: "set.custom_field_ph", make: Shop.newCustomField,
                         detail: { Shop.plainString($0["type"]) ?? "text" })
    }
}

/// Settings ▸ Operations: post-process presets (`settings.postProcessPresets`)
/// — a named charge the order editor adds as an extra line in one click.
struct PostPresetsSettingsSection: View {
    let shop: Shop
    @State private var name = ""
    @State private var amount = 0.0

    var body: some View {
        let words = shop.words
        let rows = shop.settingsList(.postProcessPresets)
        Section(words.callIt("set.post_process_presets")) {
            if rows.isEmpty {
                Text(words.callIt("set.no_presets")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack {
                    Text(Shop.plainString(row["name"]) ?? "")
                    Spacer()
                    Text(Money.text(Shop.plainNumber(row["amount"]) ?? 0, shop.currency))
                        .monospacedDigit().foregroundStyle(Khayt.done)
                    Button {
                        Task { await shop.editSettingsList(.postProcessPresets, .remove(index: i, record: row)) }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help(words.callIt("common.delete"))
                    .accessibilityLabel(words.callIt("common.delete"))
                    .disabled(!mayEditLists(shop))
                }
            }
            HStack {
                TextField("", text: $name, prompt: Text(words.callIt("common.name")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                // The word as a PROMPT, with the label hidden: as a title it
                // was drawn beside the 90-point field and wrapped "Amou / nt".
                TextField("", value: $amount,
                          format: .number.locale(Money.digits).precision(.fractionLength(0...2)),
                          prompt: Text(words.callIt("common.amount")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                Button(words.callIt("common.add")) {
                    guard let record = Shop.newPostPreset(name, amount: amount) else { return }
                    name = ""; amount = 0
                    Task { await shop.editSettingsList(.postProcessPresets, .add(record)) }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !mayEditLists(shop))
            }
        }
    }
}

// MARK: - The job inspector

/// The post-processing steps on a job in Post, ticked here as on the
/// desktop's card. Only in Post, as the desktop shows it.
struct JobPostChecklist: View {
    let shop: Shop
    let job: Order

    static func shows(_ shop: Shop, _ job: Order) -> Bool {
        job.status == "post" && !shop.settingsList(.postChecklist).isEmpty
    }

    var body: some View {
        let steps = shop.settingsList(.postChecklist)
        let checks = Shop.postChecks(shop.orderFields(job.id))
        let done = steps.filter { checks[Shop.plainString($0["id"]) ?? ""] == true }.count
        let head: String = shop.words.callIt("post.checklist")
        let count: String = shop.words.numeral(done) + "/" + shop.words.numeral(steps.count)
        let title: String = [head, count].joined(separator: " \u{00B7} ")
        DetailSection(title) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    let id = Shop.plainString(step["id"]) ?? ""
                    Toggle(isOn: Binding(
                        get: { checks[id] == true },
                        set: { on in Task { await shop.editPostCheck(job.id, step: id, done: on) } }
                    )) {
                        Text(Shop.plainString(step["label"]) ?? "")
                            .strikethrough(checks[id] == true)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(id.isEmpty || !shop.canMoveJobs)
                }
            }
        }
    }
}

/// The shop's own order fields that have a value on this job.
struct JobCustomFields: View {
    let shop: Shop
    let job: Order

    static func rows(_ shop: Shop, _ job: Order) -> [(label: String, value: String)] {
        guard case .object(let data)? = shop.orderFields(job.id)["customData"] else { return [] }
        return shop.settingsList(.customFields).compactMap { f in
            guard let id = Shop.plainString(f["id"]), let v = Shop.plainString(data[id]), !v.isEmpty else { return nil }
            return (Shop.plainString(f["label"]) ?? id, v)
        }
    }

    var body: some View {
        DetailSection(shop.words.callIt("set.custom_fields_title")) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(Self.rows(shop, job).enumerated()), id: \.offset) { _, row in
                    LabeledContent(row.label) { Text(row.value).textSelection(.enabled) }
                }
            }
        }
    }
}

// MARK: - Saved job filters

/// Go ▸ Saved Filters: the desktop's saved log filters, on the jobs list.
struct SavedFiltersMenu: View {
    @Environment(Shop.self) private var shop

    var body: some View {
        let saved = shop.savedFilters
        Menu(Words.upfront("mac.saved_filters")) {
            ForEach(saved) { f in
                Button(f.name) { shop.applyFilterPreset(f) }
            }
            if !saved.isEmpty { Divider() }
            Button(Words.upfront("mac.save_filter") + "\u{2026}") { shop.namingFilter = true }
                .disabled(!shop.canWrite || !shop.lockAllows("settings", "edit"))
            if !saved.isEmpty {
                Menu(Words.upfront("mac.delete_saved_filter")) {
                    ForEach(saved) { f in
                        Button(f.name) {
                            Task { await shop.editSettingsList(.savedFilters, .remove(index: f.index, record: f.raw)) }
                        }
                    }
                }
                .disabled(!shop.canWrite || !shop.lockAllows("settings", "edit"))
            }
        }
    }
}

/// The name for the jobs list's stage and search, saved as a filter.
struct SaveFilterSheet: View {
    let shop: Shop
    @State private var name = ""

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 12) {
            Text(words.callIt("mac.save_filter")).font(.headline)
            TextField(words.callIt("mac.filter_name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { shop.namingFilter = false }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("common.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func save() {
        let n = name
        guard !n.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        shop.namingFilter = false
        Task { await shop.saveFilterPreset(name: n) }
    }
}

// MARK: - File ▸ Import CSV…

/// Choose a file, match its columns, see what would be added, then import.
struct CsvImportSheet: View {
    let shop: Shop
    let kind: Shop.CsvKind

    @State private var choosing = false
    @State private var fileName = ""
    @State private var read: KhaytEngine.CsvRead?
    @State private var mapping: [String: Int] = [:]
    @State private var plan: KhaytEngine.CsvPlan?
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 12) {
            Text(words.callIt(kind.titleKey)).font(.headline)
            HStack {
                Button(words.callIt("csv.choose_file") + "\u{2026}") { choosing = true }
                Text(fileName.isEmpty ? words.callIt("csv.no_file") : fileName)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let read {
                mappingGrid(read)
                Divider()
                preview
            }
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { shop.importingCsv = nil }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("csv.import_btn"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled((plan?.imported ?? 0) == 0 || working || !shop.canWrite)
            }
        }
        .padding(18)
        .frame(width: 620)
        .fileImporter(isPresented: $choosing,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            guard case .success(let url) = result else { return }
            Task { await open(url) }
        }
        .task(id: mapping) { await replan() }
    }

    @ViewBuilder private func mappingGrid(_ read: KhaytEngine.CsvRead) -> some View {
        let words = shop.words
        let skip: String = "(" + words.callIt("csv.skip") + ")"
        Text(words.callIt("mac.csv_found", ["n": .number(Double(read.rows.count))]))
            .font(.callout).foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text(words.callIt("csv.field"))
                Text(words.callIt("csv.column"))
                Text(words.callIt("csv.preview"))
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(read.fields) { f in
                GridRow {
                    Text(label(f)).fontWeight(f.isRequired ? .semibold : .regular)
                    Picker("", selection: Binding(get: { mapping[f.key] ?? -1 },
                                                  set: { mapping[f.key] = $0 })) {
                        Text(skip).tag(-1)
                        ForEach(Array(read.headers.enumerated()), id: \.offset) { i, h in
                            Text(h.isEmpty ? "#\(i + 1)" : h).tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Text(sample(read, f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        let words = shop.words
        if let plan {
            Text(summary(plan)).font(.callout.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(plan.objects.enumerated()), id: \.offset) { i, obj in
                        let isNew = plan.rows.indices.contains(i) && plan.rows[i].verdict == "new"
                        HStack {
                            Text(rowTitle(obj)).lineLimit(1)
                            Spacer()
                            Text(words.callIt(isNew ? "mac.csv_new" : "mac.csv_duplicate"))
                                .font(.caption)
                                .foregroundStyle(isNew ? Khayt.done : Color.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private func label(_ f: KhaytEngine.CsvField) -> String {
        let said = shop.words.callIt(f.labelKey)
        let name = (said.isEmpty || said == f.labelKey) ? f.label : said
        return f.isRequired ? name + " *" : name
    }

    private func sample(_ read: KhaytEngine.CsvRead, _ f: KhaytEngine.CsvField) -> String {
        guard let i = mapping[f.key], i >= 0, let first = read.rows.first, first.indices.contains(i) else { return "\u{2014}" }
        return first[i].isEmpty ? "\u{2014}" : first[i]
    }

    private func rowTitle(_ obj: [String: JSONValue]) -> String {
        let keys = kind == .spools ? ["material", "brand", "color"] : ["nameEn", "phone", "sku"]
        return keys.compactMap { Shop.plainString(obj[$0]) }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    private func summary(_ plan: KhaytEngine.CsvPlan) -> String {
        let words = shop.words
        let a = words.numeral(plan.imported) + " " + words.callIt("csv.rows_to_import")
        guard plan.skipped > 0 else { return a }
        return a + " \u{00B7} " + words.numeral(plan.skipped) + " " + words.callIt("csv.skipped")
    }

    private func open(_ url: URL) async {
        problem = nil
        working = true
        defer { working = false }
        guard let text = await Self.readText(url) else {
            problem = shop.words.callIt("mac.csv_read_failed"); return
        }
        fileName = url.lastPathComponent
        guard let engine = shop.engine else { problem = shop.words.callIt("mac.move_no_engine"); return }
        var labels: [String: String] = [:]
        if let fields = try? await engine.csvRead(kind: kind.rawValue, text: "", labels: [:]).fields {
            for f in fields { let l = shop.words.callIt(f.labelKey); if l != f.labelKey { labels[f.key] = l } }
        }
        do {
            let r = try await engine.csvRead(kind: kind.rawValue, text: text, labels: labels)
            read = r
            plan = nil
            mapping = r.mapping
            await replan()
        } catch {
            problem = shop.words.callIt("mac.csv_read_failed")
        }
    }

    private func replan() async {
        guard let read, let engine = shop.engine else { plan = nil; return }
        plan = try? await engine.csvPlan(
            kind: kind.rawValue, rows: read.rows, mapping: mapping, existing: shop.csvExisting(kind),
            today: Shop.today(), settings: shop.settingsDict,
            ids: (0..<read.rows.count).map { "preview-\($0)" })
    }

    private func commit() {
        guard let read else { return }
        let rows = read.rows, map = mapping
        working = true
        Task {
            let done = await shop.saveCsvImport(kind, rows: rows, mapping: map)
            working = false
            if let done {
                shop.importingCsv = nil
                shop.moveNotices = [shop.words.callIt("mac.csv_done", ["n": .number(Double(done.imported)),
                                                                      "m": .number(Double(done.skipped))])]
            } else {
                problem = shop.moveProblem
            }
        }
    }

    /// The file's text, read off the main thread (UTF-8, falling back to the
    /// file's own guess) — and through the security scope the panel granted.
    static func readText(_ url: URL) async -> String? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { done.resume(returning: nil); return }
                if let s = String(data: data, encoding: .utf8) {
                    // A spreadsheet's byte-order mark is not part of the first header.
                    done.resume(returning: s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s)
                    return
                }
                var guessed: NSString?
                var lossy: ObjCBool = false
                let enc = NSString.stringEncoding(for: data, encodingOptions: nil,
                                                  convertedString: &guessed, usedLossyConversion: &lossy)
                let text: String? = guessed.map { String($0) }
                done.resume(returning: enc != 0 ? text : nil)
            }
        }
    }
}

// MARK: - Words

/// The Mac's own words for these screens. Everything else on them is the
/// desktop's own (`Words.borrowed`).
enum OrderFlowWords {
    nonisolated static let table: [String: [String: String]] = [
        "mac.saved_filters": ["en": "Saved Filters", "ar": "الفلاتر المحفوظة"],
        "mac.save_filter": ["en": "Save Current Filter", "ar": "حفظ الفلتر الحالي"],
        "mac.filter_name": ["en": "Filter name", "ar": "اسم الفلتر"],
        "mac.delete_saved_filter": ["en": "Delete Saved Filter", "ar": "حذف فلتر محفوظ"],
        "mac.filter_narrows_more": ["en": "This saved filter also narrows by payment, tag, dates or staff in Khayt for Windows and Linux. Here it applies its stage and search.",
                                    "ar": "يضيّق هذا الفلتر المحفوظ أيضًا حسب الدفع أو الوسم أو التواريخ أو الموظف في خيط لويندوز ولينكس. هنا يطبّق المرحلة والبحث فقط."],
        "mac.import_csv": ["en": "Import CSV", "ar": "استيراد CSV"],
        "mac.csv_new": ["en": "New", "ar": "جديد"],
        "mac.csv_duplicate": ["en": "Already in the book", "ar": "موجود في الدفتر"],
        "mac.csv_read_failed": ["en": "This file could not be read as text.", "ar": "تعذّرت قراءة هذا الملف كنص."],
        "mac.csv_found": ["en": "{n} rows found. Match each field to a column.",
                          "ar": "وُجد {n} صفًا. طابق كل حقل مع عمود."],
        "mac.csv_done": ["en": "{n} imported, {m} skipped as already in the book.",
                         "ar": "استُورد {n}، وتُخطّي {m} لوجوده في الدفتر."],
    ]
}
