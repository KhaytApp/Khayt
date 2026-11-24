import SwiftUI

/// The locked screen (frames L1 and L2): the app's mark, the shop's name, and
/// the two ways in. It is also what the app switcher shows while the lock is
/// on, so a shop's book is never in the switcher's picture.
struct AppLockView: View {
    let shopName: String
    /// False for the switcher's cover: the mark alone, no buttons.
    var interactive = true
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
            if interactive, !lock.failed { await lock.unlock(biometricsOnly: lock.biometryName != nil) }
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

/// Puts the lock over the app: locked, the locked screen; on its way to the
/// background with the lock on, the same screen without buttons.
struct AppLockGate: ViewModifier {
    let enabled: Bool
    let shopName: String
    @EnvironmentObject private var lock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay {
                if lock.locked {
                    AppLockView(shopName: shopName, interactive: scenePhase == .active)
                } else if enabled, lock.canLock, scenePhase != .active {
                    AppLockView(shopName: shopName, interactive: false)
                }
            }
            .onAppear { lock.start(enabled: enabled) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { lock.cameBack(enabled: enabled) } else { lock.wentAway() }
            }
            .onChange(of: enabled) { _, on in if !on { lock.lockTurnedOff() } }
    }
}
