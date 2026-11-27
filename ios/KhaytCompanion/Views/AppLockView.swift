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

    /// `locked`: Khayt is locked, as opposed to merely covered on its way
    /// out of the front. Only then does the curtain take the keyboard and
    /// key status: a cover for Control Centre or a permission alert must not
    /// cost an unlocked person the field they were typing in (review of #2691).
    func show(lock: AppLock, settings: ConnectionSettings, shopName: String, interactive: Bool, locked: Bool,
              in ownScene: UIWindowScene? = nil) {
        let view = AnyView(AppLockView(shopName: shopName, interactive: interactive)
            .environmentObject(lock)
            // The app's language and direction: this window is outside the
            // app's own view tree, so it is given them itself.
            .companionLocale(settings)
            .tint(KhaytDesign.accent))
        if let made = window, let host = made.rootViewController as? UIHostingController<AnyView> {
            host.rootView = view
            if locked, !made.isKeyWindow { takeTheKeyboard(made) }
            return
        }
        // The gate's own scene (security LOW-4): with more than one window
        // (iPad), "the active one" may be another window's. Before the gate
        // has found its window (the first frame), the active scene.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = ownScene ?? scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        else { return }
        keyBefore = scene.keyWindow
        let made = UIWindow(windowScene: scene)
        made.windowLevel = .alert + 1
        let host = UIHostingController(rootView: view)
        host.view.accessibilityViewIsModal = true
        made.rootViewController = host
        made.isHidden = false
        window = made
        if locked { takeTheKeyboard(made) }
    }

    /// Locked: a field being typed in gives up the keyboard, and the curtain
    /// becomes the key window so nothing typed reaches the app under it.
    private func takeTheKeyboard(_ made: UIWindow) {
        keyBefore?.endEditing(true)
        made.makeKey()
    }

    func hide() {
        guard let shown = window else { return }
        shown.isHidden = true
        window = nil
        // At a locked cold launch the app's window may not be key yet when
        // the curtain is made, so nothing was kept (L5): give the key back to
        // the scene's own window, so a field takes typing right after Face ID.
        let back = keyBefore ?? shown.windowScene?.windows.first { $0 !== shown && !$0.isHidden }
        back?.makeKey()
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
    @EnvironmentObject private var settings: ConnectionSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var curtain = AppLockCurtain()
    /// The scene this gate's view is shown in, once it has a window.
    @State private var scene: UIWindowScene?

    private func covers(_ phase: ScenePhase) -> Bool {
        lock.locked || (enabled && lock.canLock && phase != .active)
    }

    private func sync(_ phase: ScenePhase) {
        if covers(phase) {
            curtain.show(lock: lock, settings: settings, shopName: shopName, interactive: lock.locked && phase == .active,
                         locked: lock.locked, in: scene)
        } else {
            curtain.hide()
        }
    }

    func body(content: Content) -> some View {
        content
            // Nothing under the lock is read out or reachable by VoiceOver.
            .accessibilityHidden(lock.locked)
            .background(SceneFinder { scene = $0 })
            .overlay {
                if covers(scenePhase) {
                    AppLockView(shopName: shopName, interactive: false, asksByItself: false)
                }
            }
            .onAppear {
                lock.start(enabled: enabled)
                sync(scenePhase)
            }
            // With the lock in force, Spotlight, Siri and Shortcuts keep the
            // jobs but not their customers (Turki, Nov 24).
            .task(id: enabled && lock.canLock) { await JobSearch.lockChanged(inForce: enabled && lock.canLock) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { lock.wentToBackground() }
                if phase == .active { lock.cameBack(enabled: enabled) }
                sync(phase)
            }
            .onChange(of: lock.locked) { _, _ in sync(scenePhase) }
            .onChange(of: enabled) { _, _ in sync(scenePhase) }
    }
}

/// Tells its owner the window scene it is shown in (the curtain's own scene,
/// LOW-4). Draws nothing.
private struct SceneFinder: UIViewRepresentable {
    let found: (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> Finder {
        let view = Finder()
        view.found = found
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Finder, context: Context) { view.found = found }

    final class Finder: UIView {
        var found: ((UIWindowScene?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            DispatchQueue.main.async { [weak self] in self?.found?(scene) }
        }
    }
}
