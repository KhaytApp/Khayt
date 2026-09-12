import SwiftUI
import KhaytCore

/// What is on this network.
///
/// Adding a machine meant knowing its address and typing it. A shop that has
/// just plugged a printer in does not know it, and the number in the printer's
/// own menu is the one thing nobody wants to copy by hand across the room.
///
/// The scan is OWNER-INITIATED and time-boxed — never on a timer. It is also
/// the first thing in this app that asks macOS for the local network, and the
/// sentence in that prompt is in `make-app.sh`'s Info.plist.
struct FindPrintersSheet: View {
    @Bindable var shop: Shop

    @State private var found: [KhaytEngine.FoundPrinter] = []
    @State private var looking = true
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.find_printers")).font(.headline)

            if looking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(shop.words.callIt("mac.find_looking")).foregroundStyle(.secondary)
                }
            } else if found.isEmpty {
                // Not "no printers" — this app cannot tell an empty network from
                // a refused permission, and saying the first when it is the
                // second sends somebody hunting for a fault in the printer.
                Text(shop.words.callIt("mac.find_none"))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }

            if !found.isEmpty {
                List(found) { printer in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(printer.name).fontWeight(.medium)
                            HStack(spacing: 6) {
                                Text(printer.host).monospacedDigit()
                                if let vendor = printer.vendor, !vendor.isEmpty {
                                    Text(vendor)
                                }
                                // A printer Khayt can see and cannot speak to
                                // says so, rather than being added as if it
                                // were ready to answer.
                                if printer.connection == nil {
                                    Text(shop.words.callIt("mac.find_unsupported"))
                                        .foregroundStyle(Khayt.attention)
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(shop.words.callIt("mac.find_add")) {
                            Task { await shop.addFound(printer) }
                        }
                        .disabled(!shop.canMoveJobs)
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 200)
            }

            HStack {
                Button(shop.words.callIt("mac.find_again")) { Task { await scan() } }
                    .disabled(looking)
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.findingPrinters = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task {
            guard !started else { return }
            started = true
            await scan()
        }
    }

    private func scan() async {
        looking = true
        found = await shop.findPrinters()
        looking = false
    }
}
