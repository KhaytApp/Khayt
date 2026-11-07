import SwiftUI
import UIKit

/// "Pair again": the Mac proved it no longer knows this phone, or the person
/// moved it to an address that could not prove it is their Mac. The phone
/// never answers either with a PIN of its own — it asks for one here, sends
/// it to pair, and lets it go once the phone is enrolled.
struct PairAgainSheet: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var health: ConnectionHealth
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var busy = false
    @State private var problem: String?

    private var ready: Bool { pin.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 && !busy }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(L10n.tr("pair.again.body"))) {
                    Text(settings.shopLabel.isEmpty ? settings.displayURL : "\(settings.shopLabel) · \(settings.displayURL)")
                        .font(.khayt(13, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                    SecureField(L10n.tr("pair.pin.title"), text: $pin)
                        .pinEntry()
                }
                Section(footer: Text(L10n.tr("pair.phone_name.foot"))) {
                    TextField(L10n.tr("pair.phone_name"), text: $settings.phoneName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                if let problem {
                    Section { Text(problem).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.danger) }
                }
                Section {
                    Button {
                        Task { await pairAgain() }
                    } label: {
                        if busy {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(L10n.tr("pair.again.button")).frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!ready)
                }
            }
            .khaytForm()
            .navigationTitle(L10n.tr("pair.again.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
            }
        }
    }

    private func pairAgain() async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            let result = try await api.pairAgain(pin: pin, name: settings.nameToSend)
            if result == .closed || result == .locked {
                problem = L10n.tr(result == .closed ? "pair.window_closed" : "pair.window_locked")
                CompanionHaptics.warning()
                return
            }
            CompanionHaptics.success()
            await health.refresh()
            dismiss()
        } catch KhaytAPIError.unauthorized {
            problem = L10n.tr("pair.pin.wrong")
            CompanionHaptics.warning()
        } catch {
            problem = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}

extension View {
    /// An owner PIN field. The Mac takes any PIN of 8 characters or more,
    /// letters included, so the keyboard is the full one — never corrected,
    /// never capitalised, and kept a secure entry by its `SecureField`.
    func pinEntry() -> some View {
        self
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
    }
}
