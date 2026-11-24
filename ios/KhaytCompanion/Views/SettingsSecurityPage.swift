import SwiftUI

/// Settings › Security (frames L3, L3b and L4 of the signed app-lock page):
/// the lock when Khayt opens, how long it may sit in the background first,
/// and "Hide job names on the lock screen".
struct SettingsSecurityPage: View {
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var names: LockScreenNames

    private var hasShop: Bool { ContentView.hasAShop(settings: settings, signedInToCloud: api.cloud != nil) }
    private var enabled: Bool {
        AppLockRule.enabled(choice: lock.choice, hasShop: hasShop, sampleShop: settings.isSampleShop,
                            holdsBook: settings.mayHoldBook)
    }
    /// A floor phone that has not chosen a lock: frame L4.
    private var floorWithoutLock: Bool { settings.isFloorPhone && lock.choice == nil }
    private var biometry: String { lock.biometryName ?? L10n.tr("lock.passcode") }

    var body: some View {
        SettingsPage {
            if floorWithoutLock {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("lock.floor.title"))
                        .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.ink)
                    Text(L10n.tr("lock.floor.body"))
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .card()
                .padding(.top, 12)
            } else {
                VStack(spacing: 0) {
                    SettingsPieces.toggle(L10n.format("lock.toggle", biometry),
                                          Binding(get: { enabled }, set: { lock.choice = $0 }), last: !enabled)
                        .disabled(!lock.canLock)
                    if enabled {
                        SettingsPieces.row(L10n.tr("lock.after"), last: true) {
                            SettingsPieces.value(L10n.tr(lock.after.labelKey))
                        }
                    }
                }
                .card()
                .padding(.top, 12)
                SettingsPieces.foot(L10n.tr(lock.canLock ? "lock.foot" : "lock.no_passcode"))
                if enabled {
                    SettingsPieces.eyebrow(L10n.tr("lock.after"))
                    VStack(spacing: 0) {
                        ForEach(AppLockRule.After.allCases) { choice in
                            Button { lock.after = choice } label: {
                                SettingsPieces.row(L10n.tr(choice.labelKey), last: choice == AppLockRule.After.allCases.last) {
                                    if lock.after == choice {
                                        Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                                            .foregroundStyle(KhaytDesign.brand)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(lock.after == choice ? .isSelected : [])
                        }
                    }
                    .card()
                }
            }
            // L3b: Turki's decision (Nov 22), off by default.
            VStack(spacing: 0) {
                SettingsPieces.toggle(L10n.tr("lock.hide_names"), $names.hidden, last: true)
            }
            .card()
            .padding(.top, 20)
            SettingsPieces.foot(L10n.tr("lock.hide_names.foot"))
        }
        .settingsPageTitle(L10n.tr("lock.title"))
    }
}
