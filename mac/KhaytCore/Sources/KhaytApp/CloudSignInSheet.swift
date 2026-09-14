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
    @FocusState private var focused: Field?

    private enum Field { case url, email, password, passphrase }

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
    }
}
