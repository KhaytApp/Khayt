import SwiftUI
import UniformTypeIdentifiers
import KhaytCore

/// A shop's own question, asked of its own book.
///
/// Pick the columns, narrow by status and by date, read the table, take the
/// CSV. Every other report in this app answers a question somebody chose in
/// advance — what a quarter made, who owes, which machine earns. This is the
/// one that answers a question nobody anticipated, which is why a shop asks for
/// it and why it is worth having.
///
/// ── NOTHING HERE COMPUTES ─────────────────────────────────────────────────
///
/// `report-records.js` turns orders into rows and `report-builder.js` selects,
/// filters and orders them; both are shared and both are tested. The flattening
/// used to be inline in the other app's renderer — twenty lines, three of which
/// are money rules — so this feature could not exist here without a second
/// opinion about what a shop is owed. It was lifted rather than copied.
///
/// The CSV is the module's too. A cell beginning `=` is a formula to a
/// spreadsheet, and project names are exactly the free text that contains a
/// comma, a quote or a newline.
struct CustomReportPage: View {
    let shop: Shop

    @State private var fields: [KhaytEngine.ReportField] = []
    @State private var chosen: Set<String> = []
    @State private var statuses: Set<String> = []
    @State private var from = ""
    @State private var to = ""
    @State private var report: KhaytEngine.Report?
    @State private var exporting = false
    @State private var csv = ""
    @State private var saved: [KhaytEngine.SavedReport] = []
    @State private var naming = false
    @State private var newName = ""

    /// The stages an order can be in, from `Stage` rather than a list written
    /// out here. A second list would be a list that drifts: the board would
    /// grow a stage and this screen would quietly stop being able to ask about
    /// it, with nothing failing to say so.
    private static let allStatuses = Stage.allCases

    var body: some View {
        let words = shop.words
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // ── THE QUESTIONS THIS SHOP ALREADY ASKS ──────────────────
                //
                // Only once there is one. An empty "Saved reports" heading
                // teaches a shop the feature is broken before it has used it.
                if !saved.isEmpty {
                    DetailSection(words.callIt("rb.saved")) {
                        FlowChips(items: saved.map { ($0.id, $0.name) },
                                  isOn: { _ in false },
                                  toggle: { id in recall(id) },
                                  remove: { id in Task { await drop(id) } },
                                  removeHelp: words.callIt("rb.remove"))
                    }
                }

                // ── WHAT TO ASK ───────────────────────────────────────────
                DetailSection(words.callIt("rb.fields")) {
                    FlowChips(items: fields.map { ($0.key, label(for: $0)) },
                              isOn: { chosen.contains($0) },
                              toggle: { key in
                                  if chosen.contains(key) { chosen.remove(key) } else { chosen.insert(key) }
                              })
                }

                DetailSection(words.callIt("rb.statuses")) {
                    FlowChips(items: Self.allStatuses.map { ($0.rawValue, words.callIt($0.key)) },
                              isOn: { statuses.contains($0) },
                              toggle: { s in
                                  if statuses.contains(s) { statuses.remove(s) } else { statuses.insert(s) }
                              })
                }

                HStack(spacing: 14) {
                    DayField(title: words.callIt("rb.from"), hint: words.callIt("mac.date_hint"), text: $from)
                    DayField(title: words.callIt("rb.to"), hint: words.callIt("mac.date_hint"), text: $to)
                    Spacer()
                    if let report {
                        Text(words.callIt("rb.matches", ["n": .number(Double(report.total))]))
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button(words.callIt("rb.save")) { newName = ""; naming = true }
                        .disabled(chosen.isEmpty)
                    Button(words.callIt("rb.export")) { export() }
                        .disabled((report?.rows.isEmpty ?? true))
                }

                // ── AND THE ANSWER ────────────────────────────────────────
                if let report, !report.rows.isEmpty {
                    ReportTable(report: report, currency: shop.currency, words: words)
                } else {
                    // Not "no data". A shop reaches this by asking something
                    // its book has no answer to, which it can change by asking
                    // something else — so the screen says which lever to pull.
                    EmptyHere(title: words.callIt("rb.empty"),
                              message: words.callIt("mac.rb_empty_why"), mark: .reports)
                        .frame(maxHeight: .infinity)
                }
            }
            .padding(Metric.screen)
        }
        .background(Khayt.ground)
        .task { await load() }
        .alert(words.callIt("rb.name_prompt"), isPresented: $naming) {
            TextField(words.callIt("rb.saved"), text: $newName)
            Button(words.callIt("rb.save")) { Task { await keep() } }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(words.callIt("common.cancel"), role: .cancel) { }
        }
        // Recomputed on every turn of a knob. The whole report is one engine
        // call over the book already in memory; debouncing it would be solving
        // a problem this does not have.
        .task(id: signature) { await rebuild() }
        .fileExporter(isPresented: $exporting,
                      document: CsvFile(text: csv),
                      contentType: .commaSeparatedText,
                      defaultFilename: "khayt-report") { _ in }
    }

    private var signature: String {
        chosen.sorted().joined(separator: ",") + "|"
            + statuses.sorted().joined(separator: ",") + "|\(from)|\(to)|\(shop.orderRows.count)"
    }

    private func label(for field: KhaytEngine.ReportField) -> String {
        Self.label(for: field, shop.words)
    }

    /// The shop's own language where the catalogue has the column, and the
    /// module's English where it does not — a header reading `rb.f_tags` is
    /// worse than one reading "Tags" in the wrong language.
    ///
    /// Static so the snapshot harness can ask the SAME question. Its first
    /// version used `field.label` directly, which renders the module's English
    /// in every language — a convincing picture of an app that does not exist,
    /// which is the failure that harness has a comment about already.
    static func label(for field: KhaytEngine.ReportField, _ words: Words) -> String {
        let key = "rb.f_" + field.key
        let said = words.callIt(key)
        return said == key ? field.label : said
    }

    private func load() async {
        guard let engine = shop.engine else { return }
        fields = (try? await engine.reportFields()) ?? []
        if chosen.isEmpty {
            chosen = Set((try? await engine.reportDefaultFields()) ?? [])
        }
        saved = (try? await engine.savedReports(settings: shop.settingsDict)) ?? []
    }

    /// Put a saved report back in the controls. The table follows on its own —
    /// `signature` changes, so the `.task` that rebuilds it fires.
    private func recall(_ id: String) {
        guard let r = saved.first(where: { $0.id == id }) else { return }
        chosen = Set(r.fields)
        statuses = Set(r.statusIn)
        from = r.from
        to = r.to
    }

    private func keep() async {
        guard let engine = shop.engine else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let ordered = fields.map(\.key).filter { chosen.contains($0) }
        // The id is only used if the name is new; `addReport` keeps the
        // existing one when a shop re-saves under a name it already used.
        guard let next = try? await engine.addSavedReport(
            saved, name: name, fields: ordered, statusIn: statuses.sorted(),
            from: from, to: to, id: "RPT-" + UUID().uuidString.prefix(8)) else { return }
        saved = next
        await shop.saveReports(next)
    }

    private func drop(_ id: String) async {
        guard let engine = shop.engine,
              let next = try? await engine.removeSavedReport(saved, id: id) else { return }
        saved = next
        await shop.saveReports(next)
    }

    private func rebuild() async {
        guard let engine = shop.engine, !chosen.isEmpty else { report = nil; return }
        // The module wants them in ITS order, not the order they were ticked:
        // a report whose columns move when you toggle an unrelated one reads as
        // a table that cannot make up its mind.
        let ordered = fields.map(\.key).filter { chosen.contains($0) }
        var labels: [String: JSONValue] = [:]
        for field in fields { labels[field.key] = .string(label(for: field)) }
        report = try? await engine.buildReport(
            orders: shop.orderRows, clients: shop.clientRows, machines: shop.machineRows,
            settings: shop.settingsDict, language: shop.words.language,
            fields: ordered, statusIn: statuses.sorted(),
            from: from, to: to, labels: labels)
    }

    private func export() {
        guard let report else { return }
        Task {
            guard let engine = shop.engine else { return }
            csv = (try? await engine.reportToCsv(headers: report.headers, rows: report.rows)) ?? ""
            if !csv.isEmpty { exporting = true }
        }
    }
}

/// The table, outside a `ScrollView` of its own so the harness can photograph
/// it — `ImageRenderer` draws nothing inside one and does not say so.
struct ReportTable: View {
    let report: KhaytEngine.Report
    /// The shop's currency, so a money column reads as money. The CSV does
    /// NOT get this treatment and should not: a spreadsheet wants 13615, and a
    /// cell reading "\u{20C1} 13,615.00" is text it cannot sum.
    var currency: String = ""
    var words: Words = Words()

    /// The columns that hold an amount. `report-builder` hands every cell
    /// across as a bare number — right for the export, wrong for a person, who
    /// then reads 13615 and 288 in the same column and has to count digits.
    private static let money: Set<String> = ["price", "paidAmount", "balance"]

    private static let gutter: CGFloat = 14

    /// The shop's word for a stored status.
    ///
    /// `report-builder` hands the stored value across — "on_hold" — which is
    /// what the CSV should carry and is not what a person should read. Turned
    /// here rather than in the module for exactly that reason: the export stays
    /// the value, the screen becomes the word.
    private func say(_ column: Int, _ cell: String) -> String {
        switch key(column) {
        case "status":
            guard let stage = Stage(rawValue: cell) else { return cell }
            return words.callIt(stage.key)
        case "paymentStatus":
            // `flow.*` is the vocabulary both apps already use for these, so
            // they are not translated a second time here. It happens to be
            // lower case and the stage words happen to be Title Case; opening
            // the word rather than adding three more keys keeps one vocabulary
            // and still leaves the two columns reading as one table. A no-op in
            // Arabic, which has no case.
            guard let key = Self.payment[cell] else { return cell }
            return Self.opened(words.callIt(key))
        default:
            return cell
        }
    }

    /// `order-payment` answers with one of four words; a voided order is not in
    /// a report at all, so three of them can appear here.
    private static let payment = ["paid": "flow.paid", "unpaid": "flow.unpaid",
                                  "partial": "flow.part_paid"]

    private static func opened(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private func key(_ column: Int) -> String {
        column < report.keys.count ? report.keys[column] : ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // A GUTTER, BECAUSE ONE COLUMN IS TRAILING-ALIGNED.
            //
            // With `spacing: 0` the right edge of the money column touched the
            // left edge of the one after it, and "70.00 ⃁" followed by "paid"
            // rendered as a single run of text. Nothing was overlapping; there
            // was simply no space where a reader needs one.
            HStack(spacing: Self.gutter) {
                ForEach(Array(report.headers.enumerated()), id: \.offset) { column, head in
                    Text(head).font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity,
                               alignment: Self.money.contains(key(column)) ? .trailing : .leading)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ForEach(Array(report.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: Self.gutter) {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        let isMoney = Self.money.contains(key(column))
                        Text(isMoney ? Money.text(Double(cell) ?? 0, currency) : say(column, cell))
                            .font(.callout).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: isMoney ? .trailing : .leading)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                // Ruled, not striped, and it had better BE ruled.
                //
                // This drew `Khayt.surface` on every other row — on a card
                // whose background is `Khayt.surface`. The comment said striped
                // and the code painted nothing, which is the worse of the two
                // failures: it reads as a decision in the source and is absent
                // on screen. A rule between rows is what the rest of the app
                // does and is what a table of figures needs.
                if index < report.rows.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Khayt.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Khayt.hairline, lineWidth: 1))
    }
}

/// Chips that wrap. `LazyVGrid(.adaptive)` is the other way and is one of the
/// two shapes that has hung this app's layout; a wrapping `HStack` of fixed
/// content is not.
struct FlowChips: View {
    let items: [(String, String)]
    let isOn: (String) -> Bool
    let toggle: (String) -> Void
    /// Saved reports can be thrown away; columns and stages cannot. The other
    /// app has no remove at all, so its list only ever grew.
    var remove: ((String) -> Void)?
    var removeHelp: String = ""

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(items, id: \.0) { key, title in
                HStack(spacing: 4) {
                    Button { toggle(key) } label: { Text(title).font(.callout) }
                        .buttonStyle(.plain)
                    if let remove {
                        Button { remove(key) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(removeHelp)
                        .accessibilityLabel(removeHelp)
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(isOn(key) ? Khayt.cyan : Khayt.recessed, in: Capsule())
                .foregroundStyle(isOn(key) ? Color.white : Color.primary)
            }
        }
    }
}

/// A day, typed. `DatePicker` would be the obvious control and is the wrong
/// one: both ends are OPTIONAL here — an empty box means "no bound" — and a
/// date picker has no way to be empty.
private struct DayField: View {
    let title: String
    let hint: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(hint, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .monospacedDigit()
        }
    }
}

/// What `fileExporter` hands the save panel.
struct CsvFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Chips that wrap onto as many rows as they need.
///
/// WRITTEN RATHER THAN REACHED FOR. The obvious answer is
/// `LazyVGrid(.adaptive(...))`, and an adaptive `LazyVGrid` is one of the two
/// shapes that has hung this app's layout — see the note on `CardHeight` and
/// the machines grid. A `Layout` that measures each child once and places it is
/// not that shape: it asks nothing to resize in response to its own result.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
