import SwiftUI
import KhaytCore

/// Who took the parcel, and under what number.
///
/// This app could stamp a job shipped and never say who took it, so a Mac
/// shop's customer had a "shipped" with nothing to follow, and a carrier's
/// status webhook had no tracking number to find the job by. The fields, and
/// how a status moves without going backwards, are `lib/shipment.js` — the
/// Electron Ship dialog's own rule, so a parcel sent from either app reads the
/// same in both.
///
/// Two faces, as the dialog has: a job not yet sent picks a carrier and a
/// service; a parcel already sent keeps its carrier and takes a corrected
/// tracking number or a status picked by hand. Nothing here calls a carrier's
/// API — that is proxied through the other app's main process and not made
/// from this one — so the number is typed from the courier's receipt.
struct ShipSheet: View {
    /// A constant for the same reason `PaymentSheet.width` is one: snapshots
    /// photograph the sheet at a size of their own.
    static let width: CGFloat = 400

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var carriers: [KhaytEngine.CarrierChoice] = []
    @State private var statuses: [String] = []
    @State private var carrier = "manual"
    @State private var service = ""
    @State private var tracking = ""
    @State private var status = ""
    @State private var started = false
    @FocusState private var focused: Bool

    private var job: Order? { shop.orders.first { $0.id == subject.id } }
    /// Sent already — by this sheet, the other app's dialog, or a shop that
    /// only stamped the date (which has a date and no carrier).
    private var alreadyShipped: Bool { job?.shippingStatus != nil }
    private var chosen: KhaytEngine.CarrierChoice? { carriers.first { $0.id == carrier } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt(alreadyShipped ? "ship.manage_title" : "ship.title")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("ship.carrier")).foregroundStyle(.secondary)
                    Picker("", selection: $carrier) {
                        ForEach(carriers) { c in Text(c.name(shop.words.language)).tag(c.id) }
                    }
                    .labelsHidden()
                    // The carrier a parcel went with is a fact about the past.
                    .disabled(alreadyShipped)
                }
                if let services = chosen?.services, !services.isEmpty, !alreadyShipped {
                    GridRow {
                        Text(shop.words.callIt("ship.service")).foregroundStyle(.secondary)
                        Picker("", selection: $service) {
                            ForEach(services, id: \.id) { s in Text(s.label).tag(s.id) }
                        }
                        .labelsHidden()
                    }
                }
                GridRow {
                    Text(shop.words.callIt("ship.tracking")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("ship.tracking_ph"), text: $tracking)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(commit)
                }
                if alreadyShipped {
                    GridRow {
                        Text(shop.words.callIt("ship.status")).foregroundStyle(.secondary)
                        Picker("", selection: $status) {
                            ForEach(statuses, id: \.self) { s in Text(shop.words.callIt("ship.st." + s)).tag(s) }
                        }
                        .labelsHidden()
                    }
                }
            }

            Text(shop.words.callIt("mac.ship_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt(alreadyShipped ? "common.save" : "ship.create"), action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .task {
            guard !started else { return }
            started = true
            carriers = await shop.carriersToShipWith()
            statuses = (try? await shop.engine?.shippingStatuses()) ?? []
            // Opens on what is already recorded: the usual edit to a parcel is
            // "it moved", and a sheet that starts blank makes that a retype.
            if let had = job?.carrier, carriers.contains(where: { $0.id == had }) { carrier = had }
            else { carrier = carriers.first?.id ?? "manual" }
            service = job?.shippingService ?? chosen?.services.first?.id ?? ""
            tracking = job?.trackingNumber ?? ""
            status = job?.shippingStatus ?? statuses.first ?? ""
            focused = true
        }
        .onChange(of: carrier) { _, _ in
            if !(chosen?.services.contains { $0.id == service } ?? false) {
                service = chosen?.services.first?.id ?? ""
            }
        }
    }

    private func commit() {
        let id = subject.id
        let number = tracking.trimmingCharacters(in: .whitespaces)
        if alreadyShipped {
            let picked = status
            shop.clearQuestion()
            Task { await shop.updateShipment(id, status: picked.isEmpty ? nil : picked, trackingNumber: number) }
        } else {
            let who = carrier
            let how = service.isEmpty ? nil : service
            shop.clearQuestion()
            Task { await shop.ship(id, carrier: who, service: how, trackingNumber: number) }
        }
    }
}
