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
    /// Printers earlier scans found and this one did not (page 28, frame A).
    @State private var earlier: [EarlierFind] = []
    @State private var looking = true
    @State private var started = false

    var body: some View {
        // The house frame: the sheet never grows past the screen, and its
        // buttons stay put while what is above them scrolls.
        SheetFrame(width: 460) {
            Text(shop.words.callIt("mac.find_printers")).font(.headline)

            if looking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(shop.words.callIt("mac.find_looking")).foregroundStyle(.secondary)
                }
            } else if found.isEmpty, earlier.isEmpty {
                // Not "no printers" — this app cannot tell an empty network from
                // a refused permission, and saying the first when it is the
                // second sends somebody hunting for a fault in the printer.
                Text(shop.words.callIt("mac.find_none"))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }

            if !found.isEmpty || !earlier.isEmpty {
                List {
                    // With nothing seen earlier the sheet is what it always
                    // was: one list, no headings.
                    if earlier.isEmpty {
                        ForEach(found) { row($0, when: nil, primary: true) }
                    } else {
                        if !found.isEmpty {
                            Section(shop.words.callIt("mac.find_now")) {
                                ForEach(found) { row($0, when: nil, primary: true) }
                            }
                        }
                        Section(shop.words.callIt("mac.find_earlier")) {
                            ForEach(earlier) { find in
                                row(find.printer, when: FindPrintersSheet.seen(find, now: Date(), words: shop.words), primary: false)
                            }
                        }
                    }
                }
                .frame(height: earlier.isEmpty ? 200 : 280)
            }

            // Where the second list comes from, and that it goes nowhere.
            if !earlier.isEmpty {
                Text(shop.words.callIt("mac.find_kept_here")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Why "Add" is off, where it is off — rather than a row of grey
            // buttons that look broken.
            if let why = Shop.findPrintersCaveat(shop) {
                Text(why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        } footer: {
            HStack {
                // Asks nothing: it empties this computer's own list, and the
                // next scan starts it again.
                if !earlier.isEmpty {
                    Button(shop.words.callIt("mac.find_forget")) {
                        shop.forgetFoundPrinters()
                        earlier = []
                    }
                }
                Spacer()
                Button(shop.words.callIt("mac.find_again")) { Task { await scan() } }
                    .disabled(looking)
                Button(shop.words.callIt("common.done")) { shop.findingPrinters = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .task {
            guard !started else { return }
            started = true
            await scan()
        }
    }

    private func scan() async {
        looking = true
        found = await shop.findPrinters()
        // After the scan, which has just added what it saw to the list: what
        // is left is what THIS scan missed.
        earlier = await shop.earlierFinds(notIn: found)
        looking = false
    }

    /// One printer: its name, where it is, and Add. An earlier find says when
    /// it was last seen, and its Add is the quieter button (frame A): it may
    /// not answer, and the form says so as it does for any address.
    @ViewBuilder private func row(_ printer: KhaytEngine.FoundPrinter, when: String?, primary: Bool) -> some View {
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
                if let when {
                    Text(when).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if primary {
                Button(shop.words.callIt("mac.find_add")) { Task { await shop.addFound(printer) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!shop.canMoveJobs)
                    .help(Shop.findPrintersCaveat(shop) ?? "")
            } else {
                Button(shop.words.callIt("mac.find_add")) { Task { await shop.addFound(printer) } }
                    .buttonStyle(.bordered)
                    .disabled(!shop.canMoveJobs)
                    .help(Shop.findPrintersCaveat(shop) ?? "")
            }
        }
        .padding(.vertical, 2)
    }

    /// "Seen 2 hours ago. It may be asleep or busy." or, for a printer whose
    /// address moved, "Seen yesterday, at another address before: 192.168.1.50".
    @MainActor static func seen(_ find: EarlierFind, now: Date, words: Words) -> String {
        // How long ago, as of `now`, said from the present: a relative style
        // has no "as of", so the same span is laid back from this instant.
        // Never "in 3 seconds": a clock that moved does not put a sighting in the future.
        let ago = max(0, now.timeIntervalSince(find.lastSeen))
        let when = Date().addingTimeInterval(-ago)
            .formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide).locale(words.locale))
        if let was = find.previousHost {
            return words.callIt("mac.find_seen_moved", ["when": .string(when), "host": .string(was)])
        }
        return words.callIt("mac.find_seen", ["when": .string(when)])
    }
}

extension Shop {
    /// Why a printer found on the network cannot be added to this book, or nil
    /// when it can. The search itself always runs — it only looks.
    @MainActor static func findPrintersCaveat(_ shop: Shop) -> String? {
        if shop.canMoveJobs { return nil }
        return shop.words.callIt(shop.source.isReal ? "mac.find_cant_add_locked" : "mac.find_cant_add_sample")
    }
}
