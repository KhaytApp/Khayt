import SwiftUI
import KhaytCore

/// Signing this Mac in to the shop's cloud.
///
/// Four fields, and the fourth is the one that needs explaining. The server
/// address, the account and its password are an ordinary sign-in; the sync
/// passphrase is not a second password but the key to the shop's own data, and
/// it is asked for HERE rather than afterwards so that a passphrase that does
/// not fit fails before anything is written. A token saved beside a key that
/// cannot be opened leaves a shop connected and unable to read a word of its
/// own cloud.
///
/// The passphrase is used and not kept — `Shop.signInToCloud` unwraps with it
/// and lets it go, the way `CloudCheckSheet` does.
struct CloudSignInSheet: View {
    let shop: Shop
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var email = ""
    @State private var password = ""
    @State private var passphrase = ""
    @State private var resetting = false
    @State private var code = ""
    @State private var newPassword = ""
    @FocusState private var focused: Field?

    private enum Field { case url, email, password, passphrase, code, newPassword }

    /// Everything except the passwords is already in the book when a shop has
    /// synced before — which is the case this sheet exists for, a book carried
    /// to a new Mac. Filling them in means the shop confirms an address rather
    /// than retyping one.
    private func prefill() {
        guard case .object(let cloud)? = shop.settingsDict["cloud"] else { return }
        if url.isEmpty, case .string(let u)? = cloud["url"] { url = u }
        if email.isEmpty, case .string(let e)? = cloud["email"] { email = e }
        focused = email.isEmpty ? .email : .password
    }

    private var ready: Bool {
        !url.isEmpty && !email.isEmpty && !password.isEmpty
            && !passphrase.isEmpty && !shop.cloudBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.cloud_sign_in")).font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(shop.words.callIt("mac.cloud_server"))
                    TextField("", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .url)
                }
                GridRow {
                    Text(shop.words.callIt("mac.cloud_email"))
                    TextField("", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .email)
                }
                GridRow {
                    Text(shop.words.callIt("mac.cloud_password"))
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .password)
                }
                GridRow {
                    Text(shop.words.callIt("mac.cloud_passphrase"))
                    SecureField("", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .passphrase)
                }
            }

            Text(shop.words.callIt("mac.cloud_passphrase_why"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The way out of the one failure that stops everything else, and it
            // is HERE rather than in a menu: a shop that cannot remember its
            // password is looking at this sheet when it finds out.
            Button(shop.words.callIt("mac.cloud_forgot")) { resetting = true }
                .buttonStyle(.link)

            if let problem = shop.cloudProblem {
                Text(problem)
                    .font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.cloud_sign_in")) {
                    Task {
                        await shop.signInToCloud(url: url, email: email,
                                                 password: password, passphrase: passphrase)
                        // Only on success: a sheet that closes on a refusal
                        // takes the reason with it.
                        if shop.cloudProblem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear(perform: prefill)
        .sheet(isPresented: $resetting) { reset }
    }

    /// Resetting the account password, with the emailed code.
    ///
    /// Two steps in one sheet, because they are minutes apart and a shop should
    /// not have to find its way back: ask for the code, then type it with the
    /// new password. The note is above both, where it is read BEFORE anything
    /// is typed — it is the sentence that stops somebody resetting the wrong
    /// thing when what they have lost is the sync passphrase, which no reset
    /// can recover.
    private var reset: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.cloud_reset_title")).font(.headline)

            Text(shop.words.callIt("mac.cloud_reset_note"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(shop.words.callIt("mac.cloud_email"))
                TextField("", text: $email).textFieldStyle(.roundedBorder)
                Button(shop.words.callIt("mac.cloud_reset_send")) {
                    Task { await shop.requestPasswordReset(url: url, email: email) }
                }
                .disabled(url.isEmpty || email.isEmpty || shop.cloudBusy)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(shop.words.callIt("mac.cloud_reset_code"))
                    TextField("", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .code)
                }
                GridRow {
                    Text(shop.words.callIt("mac.cloud_reset_newpw"))
                    SecureField("", text: $newPassword)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .newPassword)
                }
            }

            if let said = shop.moveNotices.first {
                Text(said).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = shop.cloudProblem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { resetting = false }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.cloud_reset_do")) {
                    Task {
                        await shop.resetCloudPassword(
                            url: url, email: email,
                            // The codes are shown in capitals and typed in
                            // whatever the keyboard was doing, exactly as the
                            // other app's modal folds them.
                            code: code.trimmingCharacters(in: .whitespaces).uppercased(),
                            newPassword: newPassword)
                        if shop.cloudProblem == nil {
                            // Back to signing in, with the new password to type:
                            // a reset that closed everything would leave a shop
                            // where it started.
                            resetting = false
                            password = ""
                            focused = .password
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                // Eight is the server's minimum, said here so it is refused
                // before a round trip rather than after one.
                .disabled(code.isEmpty || newPassword.count < 8 || shop.cloudBusy)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
