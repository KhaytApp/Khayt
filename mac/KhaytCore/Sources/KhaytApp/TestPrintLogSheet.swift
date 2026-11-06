import SwiftUI
import KhaytCore

/// The test prints run on a spool — temperature towers, retraction tests and
/// the rest — the desktop's Test Prints log, written through the same rule
/// (`lib/test-prints.js`): the row in the desktop's own fields, and a test that
/// used filament taken off the spool with a usage line a recall can find.
struct TestPrintLogSheet: View {
    @Bindable var shop: Shop
    let spool: Spool

    /// `KhaytTestPrints.TEST_TYPES` and `TEST_RESULTS`, in the desktop's
    /// order. `ParityReportsTests` holds these to the module.
    static let types = ["temp_tower", "retraction", "first_layer", "stringing", "overhang", "dimensional", "other"]
    static let results = ["excellent", "good", "fair", "poor"]

    @State private var date = Date()
    @State private var machineId = ""
    @State private var testType = "temp_tower"
    @State private var result = "excellent"
    @State private var printTemp: Double = 0
    @State private var bedTemp: Double = 0
    @State private var speed: Double = 0
    @State private var weight: Double = 0
    @State private var notes = ""
    @State private var problem: String?
    @State private var saving = false
    @State private var deleting: Shop.SpoolLogRow?

    private var log: [Shop.SpoolLogRow] { shop.testPrints(for: spool.id) }

    var body: some View {
        let words = shop.words
        SheetFrame(width: 600) {
            VStack(alignment: .leading, spacing: 4) {
                Text(words.callIt("inv.test_prints")).font(.headline)
                Text(spool.label(words, unit: shop.unit(of: spool))).font(.callout)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            form
            HStack {
                Spacer()
                Button(words.callIt("inv.test_add"), action: add)
                    .disabled(saving || !shop.canMoveJobs)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Khayt.attention).font(.callout)
            }
            Divider()
            if log.isEmpty {
                Text(words.callIt("inv.spool_hist_empty"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(log) { row in
                        line(row)
                            .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        } footer: {
            HStack {
                Spacer()
                Button(words.callIt("common.close")) { shop.testPrintLogFor = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .askFirst($deleting,
                  title: { _ in words.callIt("common.delete") + "?" },
                  message: { $0.date },
                  confirm: words.callIt("common.delete"),
                  cancel: words.callIt("common.cancel")) { row in
            Task { problem = await shop.deleteTestPrint(spool.id, id: row.id) }
        }
    }

    private var form: some View {
        let words = shop.words
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text(words.callIt("common.date")).foregroundStyle(.secondary)
                DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                    .labelsHidden().fixedSize()
                Text(words.callIt("inv.test_machine")).foregroundStyle(.secondary)
                Picker("", selection: $machineId) {
                    Text(words.callIt("mach.unassigned")).tag("")
                    ForEach(shop.machinesInUse) { m in Text(m.name).tag(m.id) }
                }
                .labelsHidden().fixedSize()
            }
            GridRow {
                Text(words.callIt("inv.test_type")).foregroundStyle(.secondary)
                Picker("", selection: $testType) {
                    ForEach(Self.types, id: \.self) { t in Text(words.callIt("inv.test." + t)).tag(t) }
                }
                .labelsHidden().fixedSize()
                Text(words.callIt("inv.test_result")).foregroundStyle(.secondary)
                Picker("", selection: $result) {
                    ForEach(Self.results, id: \.self) { r in Text(words.callIt("inv.test." + r)).tag(r) }
                }
                .labelsHidden().fixedSize()
            }
            GridRow {
                Text(words.callIt("inv.print_temp")).foregroundStyle(.secondary)
                number("210", $printTemp)
                Text(words.callIt("inv.bed_temp")).foregroundStyle(.secondary)
                number("60", $bedTemp)
            }
            GridRow {
                Text(words.callIt("inv.test_speed")).foregroundStyle(.secondary)
                number("60", $speed)
                Text(words.callIt("inv.test_weight_used")).foregroundStyle(.secondary)
                number("5", $weight)
            }
            GridRow {
                Text(words.callIt("common.notes")).foregroundStyle(.secondary)
                TextField(words.callIt("common.optional"), text: $notes)
                    .textFieldStyle(.roundedBorder)
                    .gridCellColumns(3)
            }
        }
    }

    private func number(_ hint: String, _ value: Binding<Double>) -> some View {
        TextField(hint, value: SpoolSheet.blankWhenZero(value),
                  format: .number.locale(Money.digits).precision(.fractionLength(0...1)))
            .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 90)
    }

    private func line(_ row: Shop.SpoolLogRow) -> some View {
        let words = shop.words
        let tone = Self.tone(row.text("result"))
        return HStack(spacing: 10) {
            Text(row.date).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(shop.machines.first { $0.id == row.text("machineId") }?.name ?? "\u{2014}")
                .lineLimit(1).frame(width: 90, alignment: .leading)
            Text(words.callIt("inv.test." + (row.text("testType").isEmpty ? "other" : row.text("testType"))))
                .lineLimit(1).frame(width: 110, alignment: .leading)
            Text(Self.temps(row)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(words.callIt("inv.test." + (row.text("result").isEmpty ? "good" : row.text("result"))))
                .foregroundStyle(tone)
            Text(row.text("notes")).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Text(Self.grams(row, words: words)).monospacedDigit().foregroundStyle(.secondary)
            Button(role: .destructive) { deleting = row } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(words.callIt("common.delete"))
                .disabled(!shop.canMoveJobs)
        }
    }

    /// The result's colour, as the desktop's log reads it
    /// (`KhaytTestPrints.resultTone`): good news, bad news, in between.
    static func tone(_ result: String) -> Color {
        switch result {
        case "excellent", "good": Khayt.done
        case "poor": Khayt.late
        default: Khayt.attention
        }
    }

    /// "210° / 60°", a dash for a figure not given.
    static func temps(_ row: Shop.SpoolLogRow) -> String {
        let print: String = row.number("printTemp").map { Money.quantity($0, decimals: 0) + "\u{00B0}" } ?? "\u{2014}"
        let bed: String = row.number("bedTemp").map { Money.quantity($0, decimals: 0) + "\u{00B0}" } ?? "\u{2014}"
        return print + " / " + bed
    }

    /// The filament the test used, or a dash.
    static func grams(_ row: Shop.SpoolLogRow, words: Words) -> String {
        guard let used = row.number("weightUsed"), used > 0 else { return "\u{2014}" }
        let amount: String = Money.quantity(used, decimals: 0)
        return amount + " " + words.callIt("common.grams")
    }

    private func add() {
        saving = true
        let raw: [String: JSONValue] = [
            "date": .string(Shop.today(date)),
            "machineId": .string(machineId),
            "testType": .string(testType),
            "result": .string(result),
            "printTemp": printTemp > 0 ? .number(printTemp) : .null,
            "bedTemp": bedTemp > 0 ? .number(bedTemp) : .null,
            "speed": speed > 0 ? .number(speed) : .null,
            "notes": .string(notes),
            "weightUsed": weight > 0 ? .number(weight) : .null,
        ]
        Task {
            problem = await shop.addTestPrint(spool.id, raw: raw)
            saving = false
            if problem == nil {
                printTemp = 0; bedTemp = 0; speed = 0; weight = 0; notes = ""
            }
        }
    }
}
