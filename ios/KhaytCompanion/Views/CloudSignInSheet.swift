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
    /// The sign-in worked, but its first pull was refused: the shop is not
    /// the book's, or its copy is empty. Signed in, and nothing adopted.
    @State private var refusal: CloudSync.Refusal?
    @State private var confirmAdopt = false

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
                if let refusal {
                    refusedSection(refusal)
                } else {
                    if let problem {
                        Section { Text(problem).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.danger) }
                    }
                    signInSection
                }
            }
            .khaytForm()
            .navigationTitle(L10n.tr("cloud.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
            }
            .confirmationDialog(L10n.tr("cloud.adopt.title"), isPresented: $confirmAdopt, titleVisibility: .visible) {
                Button(L10n.tr("cloud.adopt.confirm"), role: .destructive) { Task { await adoptThisShop() } }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("cloud.adopt.message"))
            }
        }
    }

    /// The sign-in stands, the book is untouched. The way out is the right
    /// account; with no Mac paired, this shop may replace the book instead.
    @ViewBuilder
    private func refusedSection(_ refusal: CloudSync.Refusal) -> some View {
        Section {
            Text(KhaytAPIClient.refusalText(refusal))
                .font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.danger)
            Button(L10n.tr("cloud.sign_out"), role: .destructive) {
                api.signOutOfCloud()
                self.refusal = nil
                password = ""
                passphrase = ""
            }
            .disabled(busy)
            if case .wrongShop = refusal, api.mayAdoptOtherShop {
                Button(L10n.tr("cloud.adopt.action")) { confirmAdopt = true }
                    .disabled(busy)
            }
        }
    }

    private var signInSection: some View {
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

    /// "Use this shop instead", confirmed: the next whole pull adopts it, once.
    private func adoptThisShop() async {
        guard api.useThisCloudShop() else { return }
        busy = true
        defer { busy = false }
        if case .refused(let why)? = await api.syncThroughCloud() {
            refusal = why
            CompanionHaptics.warning()
        } else {
            refusal = nil
            // Held back at sign-in while the shop was in question.
            await api.registerForPush()
            CompanionHaptics.success()
            dismiss()
        }
    }

    private func signIn() async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            if let refused = try await api.signInToCloud(url: server.trimmingCharacters(in: .whitespaces),
                                                         email: email.trimmingCharacters(in: .whitespaces),
                                                         password: password, passphrase: passphrase) {
                refusal = refused
                CompanionHaptics.warning()
                return
            }
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
