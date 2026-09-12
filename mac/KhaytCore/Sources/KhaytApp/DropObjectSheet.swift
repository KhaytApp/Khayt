import SwiftUI
import KhaytCore

/// Dropping one object from a print that is already running.
///
/// A plate of twelve where one has come loose finishes with eleven good parts
/// and a ball of spaghetti. Klipper can skip what is left of one named object
/// and carry on with the rest.
///
/// ── THE WHOLE SHEET IS THE WARNING ────────────────────────────────────────
///
/// Klipper has no way to put an object back: the layers skipped while it was
/// dropped are not reprinted, so an object dropped by mistake is scrap and the
/// shop finds out at the end. That is why this is a sheet naming the object and
/// not a menu item, and why the button says what it does rather than "OK".
struct DropObjectSheet: View {
    let shop: Shop
    let machine: Machine

    @State private var plate: KhaytEngine.Plate?
    @State private var chosen: String?
    @State private var asked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.drop_object")).font(.headline)
            Text(machine.name).font(.callout).foregroundStyle(.secondary)

            if let plate {
                if !plate.supported {
                    // A setting to change, which is a different sentence from
                    // "nothing is printing".
                    Text(shop.words.callIt("mac.drop_unsupported"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if plate.remaining.isEmpty {
                    Text(shop.words.callIt("mac.drop_nothing"))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    List(plate.remaining, id: \.self, selection: $chosen) { name in
                        HStack {
                            Text(name).lineLimit(1).truncationMode(.middle)
                            if name == plate.current {
                                Text(shop.words.callIt("mac.drop_printing_now"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(name)
                    }
                    .frame(height: 160)

                    Label(shop.words.callIt("mac.drop_forever"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.droppingFrom = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.drop_it")) {
                    guard let chosen else { return }
                    Task {
                        await shop.drop(chosen, on: machine)
                        shop.droppingFrom = nil
                    }
                }
                // NOT `.defaultAction`: Return must not drop a part. Somebody
                // dismissing a sheet by habit would scrap one.
                .disabled(chosen == nil)
                .foregroundStyle(Khayt.late)
            }
        }
        .padding(18)
        .frame(width: 420)
        .task {
            guard !asked else { return }
            asked = true
            plate = await shop.plate(of: machine)
        }
    }
}
