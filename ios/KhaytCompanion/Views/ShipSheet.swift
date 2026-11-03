import SwiftUI
import KhaytCore
import Vision

/// Who took the parcel, and under what number — the Mac's Ship sheet on the
/// phone, where the courier's receipt is. The fields are `lib/shipment.js`'s,
/// so a parcel sent from the phone reads the same on the Mac and on the
/// customer's page.
struct ShipSheet: View {
    let orderId: String
    let carriers: [KhaytEngine.CarrierChoice]
    var onShipped: () async -> Void = {}

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var carrier = "manual"
    @State private var service = ""
    @State private var tracking = ""
    @State private var scanning = false
    @State private var saving = false
    @State private var problem: String?

    private var language: String { L10n.usesArabicLayout ? "ar" : "en" }
    private var chosen: KhaytEngine.CarrierChoice? { carriers.first { $0.id == carrier } }

    var body: some View {
        NavigationStack {
            Form {
                Picker(L10n.tr("ship.carrier"), selection: $carrier) {
                    ForEach(carriers) { Text($0.name(language)).tag($0.id) }
                }
                if let services = chosen?.services, !services.isEmpty {
                    Picker(L10n.tr("ship.service"), selection: $service) {
                        Text("—").tag("")
                        ForEach(services, id: \.id) { Text($0.label).tag($0.id) }
                    }
                }
                Section {
                    HStack {
                        TextField(L10n.tr("ship.tracking"), text: $tracking)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .environment(\.layoutDirection, .leftToRight)
                        Button { scanning = true } label: {
                            Image(systemName: "barcode.viewfinder")
                        }
                        .accessibilityLabel(L10n.tr("ship.scan"))
                    }
                } footer: {
                    Text(problem ?? L10n.tr("ship.hint"))
                        .foregroundStyle(problem == nil ? KhaytDesign.note : KhaytDesign.late)
                }
            }
            .navigationTitle(L10n.tr("ship.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("ship.create")) { Task { await save() } }.disabled(saving)
                }
            }
            .sheet(isPresented: $scanning) {
                LabelScanner(title: L10n.tr("ship.scan"), hint: L10n.tr("ship.scan.hint"),
                             symbologies: [.code128, .code39, .qr, .dataMatrix, .ean13, .pdf417]) { code in
                    tracking = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    scanning = false
                }
            }
            .onAppear {
                if !carriers.contains(where: { $0.id == carrier }), let first = carriers.last { carrier = first.id }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await api.ship(orderId: orderId, carrier: carrier, service: service.isEmpty ? nil : service,
                               tracking: tracking)
            CompanionHaptics.success()
            await onShipped()
            dismiss()
        } catch {
            problem = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}
