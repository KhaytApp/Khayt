import SwiftUI
import UIKit

/// The locked screen (frames L1 and L2): the app's mark, the shop's name, and
/// the two ways in. It is also what the app switcher shows while the lock is
/// on, so a shop's book is never in the switcher's picture.
struct AppLockView: View {
    let shopName: String
    /// False for the switcher's cover: the mark alone, no buttons.
    var interactive = true
    /// Whether this copy asks Face ID by itself when it comes to the front.
    /// Only the lock's own window does; the in-app cover under it never asks.
    var asksByItself = true
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            KhaytDesign.ground.ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(KhaytDesign.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityHidden(true)
                Text(verbatim: "خيط Khayt")
                    .font(.khayt(28, .bold, relativeTo: .title))
                    .foregroundStyle(KhaytDesign.ink)
                if !shopName.isEmpty {
                    Text(shopName)
                        .font(.khayt(15, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                }
                if interactive {
                    Text(lock.failed ? failedWords : L10n.tr("lock.locked"))
                        .font(.khayt(14, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)
                        .padding(.top, 6)
                }
                Spacer()
                if interactive { actions }
            }
            .frame(maxWidth: 480)
        }
        .task(id: interactive) {
            // Ask as soon as the locked screen is in front, as the iPhone's
            // own apps do; a failure leaves the two buttons.
            if interactive, asksByItself, !lock.failed { await lock.unlock(biometricsOnly: lock.biometryName != nil) }
        }
    }

    private var failedWords: String {
        lock.biometryName.map { L10n.format("lock.failed", $0) } ?? L10n.tr("lock.failed.passcode")
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await lock.unlock(biometricsOnly: lock.biometryName != nil) }
            } label: {
                Text(primaryLabel)
                    .font(.khayt(16, .semibold, relativeTo: .body))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(KhaytDesign.brand)
            if lock.biometryName != nil {
                Button(L10n.tr("lock.use_passcode")) { Task { await lock.unlock(biometricsOnly: false) } }
                    .font(.khayt(15, .semibold, relativeTo: .subheadline))
                    .frame(minHeight: 44)
            }
        }
        .disabled(lock.checking)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    private var primaryLabel: String {
        guard let name = lock.biometryName else { return L10n.tr("lock.unlock") }
        return L10n.format(lock.failed ? "lock.try_again" : "lock.unlock_with", name)
    }
}

/// The lock's own window, above everything the app can present.
///
/// A SwiftUI `.overlay` covers only the view it is on: a sheet, a full-screen
/// cover or an alert is presented in a layer above it, so a sheet left open
/// (or a job opened from a notification at a locked launch) stayed readable
/// and usable over the "locked" screen, and the keyboard stayed up (review of
/// #2691). A window above `.alert` covers all of them; made key, it takes the
/// keyboard away, and as a modal accessibility view it is all VoiceOver reads.
@MainActor
final class AppLockCurtain {
    private var window: UIWindow?
    private weak var keyBefore: UIWindow?

    func show(lock: AppLock, shopName: String, interactive: Bool) {
        let view = AnyView(AppLockView(shopName: shopName, interactive: interactive)
            .environmentObject(lock)
            .tint(KhaytDesign.accent))
        if let host = window?.rootViewController as? UIHostingController<AnyView> {
            host.rootView = view
            return
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        keyBefore = scene.keyWindow
        // A field being typed in gives up the keyboard before it is covered.
        keyBefore?.endEditing(true)
        let made = UIWindow(windowScene: scene)
        made.windowLevel = .alert + 1
        let host = UIHostingController(rootView: view)
        host.view.accessibilityViewIsModal = true
        made.rootViewController = host
        made.makeKeyAndVisible()
        window = made
    }

    func hide() {
        guard let shown = window else { return }
        shown.isHidden = true
        window = nil
        keyBefore?.makeKey()
    }

    var isShown: Bool { window != nil }
}

/// Puts the lock over the app: locked, the locked screen; on its way out of
/// the front with the lock on, the same screen without buttons. The curtain
/// window is what covers; the in-app cover under it is there from the very
/// first frame, before a window can be made.
struct AppLockGate: ViewModifier {
    let enabled: Bool
    let shopName: String
    @EnvironmentObject private var lock: AppLock
    @Environment(\.scenePhase) private var scenePhase
    @State private var curtain = AppLockCurtain()

    private func covers(_ phase: ScenePhase) -> Bool {
        lock.locked || (enabled && lock.canLock && phase != .active)
    }

    private func sync(_ phase: ScenePhase) {
        if covers(phase) {
            curtain.show(lock: lock, shopName: shopName, interactive: lock.locked && phase == .active)
        } else {
            curtain.hide()
        }
    }

    func body(content: Content) -> some View {
        content
            // Nothing under the lock is read out or reachable by VoiceOver.
            .accessibilityHidden(lock.locked)
            .overlay {
                if covers(scenePhase) {
                    AppLockView(shopName: shopName, interactive: false, asksByItself: false)
                }
            }
            .onAppear {
                lock.start(enabled: enabled)
                sync(scenePhase)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { lock.wentToBackground() }
                if phase == .active { lock.cameBack(enabled: enabled) }
                sync(phase)
            }
            .onChange(of: lock.locked) { _, _ in sync(scenePhase) }
            .onChange(of: enabled) { _, _ in sync(scenePhase) }
    }
}
