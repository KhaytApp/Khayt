import SwiftUI
import KhaytCore

/// Settings › Khayt Cloud: the account, the plan, and the backups, in one pane.
///
/// ── WHY IT EXISTS ─────────────────────────────────────────────────────────
///
/// Signing in, checking, locking and signing out were reachable only from the
/// Book menu and a right-click on the sidebar's save line — and the right-click
/// only once a shop was already connected. A shop owner who looked for the
/// cloud under Settings found a plan section that said "Sign in to Khayt Cloud
/// to see your plan." with no way to do it (Nov 2026 review; Turki: "can't find
/// cloud under settings"). Every account action is here now; the menu and the
/// sidebar keep theirs and call the same `Shop` methods.
///
/// The sheets are presented from THIS window, with their own state: the shop
/// window presents the same sheets from `shop.signingIntoCloud` and friends,
/// and a sheet bound to the same state from two windows presents itself twice.
///
/// Gated as the sidebar is: the cloud is the owner's (`cloud` in lib/rbac.js).
struct CloudPane: View {
    @Bindable var shop: Shop
    @State private var signingIn = false
    @State private var resetFirst = false
    @State private var checking = false
    @State private var confirmingSignOut = false

    private var mayAct: Bool { shop.lockAllows("cloud", "edit") }

    var body: some View {
        let words = shop.words
        Form {
            Section(words.callIt("mac.cloud_account")) {
                if shop.cloudConnected {
                    LabeledContent(words.callIt("mac.cloud_email")) {
                        Text(verbatim: account("email")).textSelection(.enabled)
                    }
                    LabeledContent(words.callIt("mac.cloud_server")) {
                        Text(verbatim: account("url")).textSelection(.enabled)
                    }
                    Label(shop.syncLine.text, systemImage: shop.syncLine.symbol)
                    HStack(spacing: 8) {
                        if shop.cloudUnlocked {
                            Button(words.callIt("mac.check_cloud") + "\u{2026}") { checking = true }
                        } else {
                            // Connected but locked: a book carried to a new Mac,
                            // or a key that was not remembered. Signing in again
                            // is how it unlocks.
                            Button(words.callIt("mac.cloud_sign_in") + "\u{2026}") { resetFirst = false; signingIn = true }
                        }
                        Button(words.callIt("mac.lock_cloud")) { shop.forgetCloudKey() }
                            .disabled(!shop.cloudUnlocked)
                        Spacer()
                        Button(words.callIt("mac.cloud_sign_out") + "\u{2026}") { confirmingSignOut = true }
                    }
                    .disabled(!mayAct)
                } else {
                    Text(words.callIt("mac.cloud_not_connected"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(words.callIt("mac.cloud_sign_in") + "\u{2026}") { resetFirst = false; signingIn = true }
                            .buttonStyle(.borderedProminent)
                        Button(words.callIt("mac.cloud_forgot")) { resetFirst = true; signingIn = true }
                            .buttonStyle(.link)
                    }
                    .disabled(!mayAct)
                }
            }
            CloudPlanSettings(shop: shop)
            OffsiteBackupSettings(shop: shop)
        }
        .formStyle(.grouped)
        .shopSheet(isPresented: $signingIn) { CloudSignInSheet(shop: shop, startInReset: resetFirst) }
        .shopSheet(isPresented: $checking) { CloudCheckSheet(shop: shop) }
        .confirmationDialog(words.callIt("mac.cloud_sign_out_q"), isPresented: $confirmingSignOut,
                            titleVisibility: .visible) {
            Button(words.callIt("mac.cloud_sign_out_do")) { Task { await shop.signOutOfCloud() } }
            Button(words.callIt("common.cancel"), role: .cancel) {}
        }
    }

    /// A plain field of `settings.cloud` — the address and the account, never
    /// the token or the keyset.
    private func account(_ key: String) -> String {
        guard case .object(let cloud)? = shop.settingsDict["cloud"],
              case .string(let v)? = cloud[key] else { return "" }
        return v
    }
}
