import SwiftUI
import KhaytCore

/// A job's or a customer's connectors: their buttons, and the fields they
/// add, with what is in them. Draws nothing when no connector is installed
/// (or while connectors are switched off, `ConnectorsSwitch`).
struct ConnectorSection: View {
    let shop: Shop
    /// "order" for a job, "customer" for a customer.
    let attach: String
    let recordId: String
    /// A job's customer, when the press is on a job.
    var jobId: String? { attach == "order" ? recordId : nil }

    @State private var buttons: [ConnectorButton] = []
    @State private var fields: [ConnectorFieldRow] = []
    @State private var typed: [String: String] = [:]
    @State private var busy: String?
    @State private var said: (ok: Bool, text: String)?

    private var collection: String { attach == "order" ? "printLog" : "clients" }

    var body: some View {
        Group {
            if !buttons.isEmpty || !fields.isEmpty {
                DetailSection(shop.words.callIt("plg.title")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(fields) { row in
                            HStack(spacing: 8) {
                                Text(row.label).foregroundStyle(.secondary)
                                Spacer()
                                if row.editable && shop.canWrite {
                                    TextField(row.label, text: binding(row))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 220)
                                        .onSubmit { Task { await save(row) } }
                                } else {
                                    Text(row.value).textSelection(.enabled)
                                }
                            }
                        }
                        if !buttons.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(buttons) { button in
                                    Button(button.label) { Task { await press(button) } }
                                        .disabled(busy != nil || !shop.canWrite)
                                }
                                if busy != nil { ProgressView().controlSize(.small) }
                            }
                        }
                        if let said, !said.text.isEmpty {
                            Text(said.text).font(.callout)
                                .foregroundStyle(said.ok ? Khayt.done : Khayt.late)
                        }
                    }
                }
            }
        }
        .task(id: recordId) { await reload() }
    }

    private func binding(_ row: ConnectorFieldRow) -> Binding<String> {
        Binding(get: { typed[row.id] ?? row.value }, set: { typed[row.id] = $0 })
    }

    private func reload() async {
        buttons = await shop.connectorButtons(placement: attach)
        let plugins = await shop.connectorValues(collection: collection, id: recordId)
        fields = await shop.connectorFields(attach: attach, plugins: plugins)
        typed = [:]
    }

    private func save(_ row: ConnectorFieldRow) async {
        guard let value = typed[row.id], value != row.value else { return }
        let ok = await shop.saveConnectorFields(entryId: row.entryId, attach: attach, recordId: recordId,
                                                values: [row.key: value])
        said = ok ? nil : (false, shop.settingsProblem ?? shop.moveProblem ?? "")
        await reload()
    }

    private func press(_ button: ConnectorButton) async {
        busy = button.id
        defer { busy = nil }
        let answer = await shop.pressConnector(button, jobId: jobId, clientId: attach == "customer" ? recordId : nil)
        said = (answer.ok, answer.message)
        await reload()
    }
}
