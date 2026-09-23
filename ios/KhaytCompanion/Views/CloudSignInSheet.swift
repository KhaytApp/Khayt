import SwiftUI
import KhaytCore

/// Sign this phone in to the shop's Khayt Cloud, so it keeps in step when the
/// Mac is not on the same Wi-Fi.
///
/// Three things are asked for, and the third is the one people do not expect:
/// the email and password get this phone a device token, and the shop's
/// PASSPHRASE opens the key the cloud copy is encrypted with. The server never
/// sees that key or the passphrase; without it the phone would hold a token to
/// a box it cannot open.
struct CloudSignInSheet: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var passphrase = ""
    @State private var server = CloudSession.defaultURL
    @State private var busy = false
    @State private var problem: String?

    private var ready: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !passphrase.isEmpty && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(L10n.tr("cloud.signin.account_footer"))) {
                    TextField(L10n.tr("cloud.signin.email"), text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L10n.tr("cloud.signin.password"), text: $password)
                        .textContentType(.password)
                }
                Section(footer: Text(L10n.tr("cloud.signin.passphrase_footer"))) {
                    SecureField(L10n.tr("cloud.signin.passphrase"), text: $passphrase)
                }
                Section {
                    DisclosureGroup(L10n.tr("cloud.signin.advanced")) {
                        TextField(L10n.tr("cloud.signin.server"), text: $server)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if let problem {
                    Section { Text(problem).font(.footnote).foregroundStyle(KhaytDesign.danger) }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        if busy {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(L10n.tr("cloud.signin.action")).frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!ready)
                }
            }
            .navigationTitle(L10n.tr("cloud.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
            }
        }
    }

    private func signIn() async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            try await api.signInToCloud(url: server.trimmingCharacters(in: .whitespaces),
                                        email: email.trimmingCharacters(in: .whitespaces),
                                        password: password, passphrase: passphrase)
            CompanionHaptics.success()
            dismiss()
        } catch {
            // A wrong passphrase stretches to a wrong key, and the key-wrap
            // says so as `wrongKey`. Say it as the thing a person got wrong.
            if case SyncCrypto.Failure.wrongKey = error {
                problem = L10n.tr("cloud.signin.wrong_passphrase")
            } else {
                problem = error.localizedDescription
            }
            CompanionHaptics.warning()
        }
    }
}
