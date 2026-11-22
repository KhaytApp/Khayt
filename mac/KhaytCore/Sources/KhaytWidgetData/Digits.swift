import Foundation
import Observation

/// Which digits Khayt writes a number in: 0–9, unless this Mac's owner asked
/// for the Mac's own.
///
/// ── THE ONE PLACE ─────────────────────────────────────────────────────────
///
/// Every figure a person reads — money, counts, dates, times, percentages,
/// durations, the widgets — is formatted in a locale that came through
/// `Digits.locale`. A formatter left alone takes the Mac's locale, and on a Mac
/// whose region writes Arabic-Indic digits that put ١٢٣ into the ENGLISH app
/// while the Arabic one, built on a bare `ar`, wrote 123. The language decided
/// nothing; whichever formatter happened to be asked did.
///
/// Western digits are the default in both languages: Saudi products ship them
/// on essentially every financial figure (see `Money.digits`), and so does the
/// Electron app. "Use the Mac's number format" (Settings ▸ On this Mac) brings
/// back the digits the Mac's Language & Region pane says, in either language.
///
/// ── PER MAC, NOT PER BOOK ─────────────────────────────────────────────────
///
/// A display preference of this Mac, kept in its own defaults beside the menu
/// bar and Spotlight switches — not in the book, which would carry one Mac's
/// reading habit to every device the shop opens it on. The widget extension
/// cannot read the app's defaults, so the snapshot carries it
/// (`ShopWidgetSnapshot.macDigits`).
///
/// ── WHAT IS NOT ROUTED HERE ───────────────────────────────────────────────
///
/// The book's own data — ISO stamps, `yyyy-MM-dd`, backup names, CSV numbers —
/// stays pinned to `en_US_POSIX`. Those are not read by a person but by the
/// next program, and must be the same bytes whatever this says.
@Observable
public final class Digits: @unchecked Sendable {

    /// The defaults key on this Mac. Off (absent) means Western digits.
    public static let defaultsKey = "mac.macDigits"

    /// This Mac's choice. Observable, so a view that formatted a figure while
    /// drawing is drawn again when it changes.
    public static let shared = Digits()

    /// Whether figures follow the Mac's own number format.
    public var followsMac: Bool {
        didSet {
            guard followsMac != oldValue, let defaults else { return }
            defaults.set(followsMac, forKey: Self.defaultsKey)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults?

    /// The app's own, read from and written to `defaults`. The widget
    /// extension makes one too; it reads its own (empty) defaults and is never
    /// asked, because the snapshot says.
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        self.followsMac = defaults?.bool(forKey: Self.defaultsKey) ?? false
    }

    /// The choice and the Mac, as a test pins them: a task-local, so a test
    /// that asks "what would an Arabic-Indic Mac show" changes nothing for a
    /// test running beside it.
    public struct Pin: Sendable {
        public var followsMac: Bool
        public var mac: Locale
        public init(followsMac: Bool, mac: Locale) {
            self.followsMac = followsMac
            self.mac = mac
        }
    }

    @TaskLocal public static var pinned: Pin?

    /// Whether figures follow the Mac, as of this moment (a pin first).
    public static var followingMac: Bool { pinned?.followsMac ?? shared.followsMac }

    /// The Mac's own locale (a pin first). Read with `Digits.locale` around it,
    /// never alone for something a person reads.
    public static var mac: Locale { pinned?.mac ?? .autoupdatingCurrent }

    /// The Western numbering system, by name.
    public static let western = Locale.NumberingSystem("latn")

    /// `base`, with the digits chosen: Western, or the Mac's own when asked.
    ///
    /// Only the numbering system moves. The language, region, calendar and
    /// currency of `base` are kept, so the riyal still sits where the region
    /// puts it and an Arabic month is still Arabic.
    public static func locale(_ base: Locale, followsMac: Bool? = nil) -> Locale {
        var parts = Locale.Components(locale: base)
        parts.numberingSystem = (followsMac ?? followingMac) ? mac.numberingSystem : western
        return Locale(components: parts)
    }

    /// The app's language (`en`, `ar`), with the digits chosen.
    public static func locale(language: String, followsMac: Bool? = nil) -> Locale {
        locale(Locale(identifier: language), followsMac: followsMac)
    }

    /// This Mac's locale — its region, its currency placement — with the
    /// digits chosen. For the few formatters that want the Mac's conventions
    /// and not the app's language (a currency's symbol side).
    public static var macLocale: Locale { locale(mac) }
}
