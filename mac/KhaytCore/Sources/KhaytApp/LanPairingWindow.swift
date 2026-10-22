import Foundation
import Observation

/// The short window the owner opens on the Mac for a new phone to pair.
///
/// ── WHY A WINDOW ──────────────────────────────────────────────────────────
///
/// Enrolment (`POST /api/devices`) took the PIN at any time, behind the same
/// wrong-PIN lockout as every other route. So somebody on the shop's Wi-Fi who
/// kept guessing held that lockout shut, and the shop's own new phone was told
/// "too many attempts" — a stranger could stop the shop pairing a phone at all
/// (beta.1 security review, Oct 2026).
///
/// Now a phone enrols only while the owner has clicked "Pair a phone" in
/// Settings ▸ Online: for `length` seconds, until one phone has paired, or
/// until the owner closes it. Outside it the route answers `pairing-closed`
/// at once — before the PIN is read, so it counts towards no lockout and says
/// nothing about whether the PIN was right.
///
/// While it is open, a PIN sent by a caller without a device key is judged
/// against THIS window's own count, not the lockout a guesser outside it built
/// up — so the phone in the owner's hand gets through even if the counters
/// were held shut a minute ago.
///
/// ── COUNTED PER ADDRESS, SO A GUESSER CANNOT SHUT IT FOR EVERYONE ────────
///
/// Wrong PINs inside the window are counted per address (the server's
/// `pinThrottleKey`: an IPv4 address, or an IPv6 /64). After `perAddress` of
/// them that address is out of THIS window, and every other address can still
/// pair. A first cut closed the whole window after 10 wrong PINs from anyone,
/// which handed the guesser the very denial of service the window removes:
/// close every window the owner opens.
///
/// The window closes for everyone only at `maxWrong` wrong PINs in all, which
/// takes `maxWrong / perAddress` = 10 different addresses (or /64s). That total
/// is what bounds guessing: a PIN is at least `LanServer.minimumPin` = 8
/// characters and the phone types digits, so 10^8 PINs, and one window gives at
/// most 50 wrong tries — 50 in 10^8, 1 in 2 million, per window. A shop that
/// opened a window ten times a day for a year with a guesser present every time
/// would face 3,650 windows: under 0.2% in all. A longer PIN divides that by 10
/// per digit.
///
/// The cost: a guesser sharing the new phone's address (the same IPv6 /64, or
/// the same IPv4 behind a NAT) locks that phone out of the window too. On a
/// shop's Wi-Fi, IPv4 addresses are per device, and the phone pairs over IPv4
/// unless the Mac was reached by an IPv6 address.
///
/// ── A MONOTONIC DEADLINE ──────────────────────────────────────────────────
///
/// The deadline is read off a clock that only goes forward and keeps counting
/// while the Mac sleeps (`CLOCK_MONOTONIC`, mach continuous time), never the
/// wall clock: setting the Mac's date back must not keep the window open.
/// The server and the pane both ask `remaining()`, so they agree.
///
/// Phones that already enrolled sign their requests and never come here.
@MainActor @Observable
final class LanPairingWindow {

    /// About two minutes: long enough to pick up a phone, open Khayt and type
    /// the PIN; short enough that a guesser has little time to try.
    static let length: TimeInterval = 120
    /// Wrong PINs from one address before that address is out of the window.
    static let perAddress = 5
    /// Wrong PINs, from every address together, that close the window.
    static let maxWrong = 50

    /// Why the window last closed. Nil: it has not been opened since launch.
    enum Closed: Equatable {
        case paired(name: String)
        case timedOut
        case byOwner
        case tooManyWrong
        /// The LAN server stopped, or came back up where no phone can reach it.
        case serverStopped
    }

    /// When the open window shuts by itself, in `clock` seconds; nil when closed.
    private(set) var deadline: TimeInterval?
    var isOpenNow: Bool { deadline != nil }
    private(set) var lastClosed: Closed?
    /// Wrong PINs in the window now open, from every address.
    private(set) var wrong = 0
    /// Wrong PINs in the window now open, by address (`pinThrottleKey`).
    private(set) var wrongBy: [String: Int] = [:]
    /// Addresses out of the window now open, for the pane to mention.
    var lockedAddresses: Int { wrongBy.values.filter { $0 >= Self.perAddress }.count }

    /// Seconds on a monotonic clock. Injectable so a test can move it.
    @ObservationIgnored let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = LanPairingWindow.monotonic) {
        self.clock = clock
    }

    /// `CLOCK_MONOTONIC`: forward only, untouched by a date change, and still
    /// counting while the Mac sleeps (unlike `systemUptime`).
    nonisolated static func monotonic() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// Open it (again) for `length` from now, with a fresh count.
    func open() {
        deadline = clock() + Self.length
        wrong = 0
        wrongBy = [:]
    }

    /// Whether a phone may enrol now. Past the deadline, this closes it.
    func isOpen() -> Bool {
        guard let deadline else { return false }
        if clock() >= deadline {
            shut(.timedOut)
            return false
        }
        return true
    }

    /// Whether `address` has spent its wrong PINs in this window.
    func lockedOut(_ address: String) -> Bool {
        (wrongBy[address] ?? 0) >= Self.perAddress
    }

    /// Seconds left; nil when closed or run out. Reads the clock only, so a
    /// view may call it as often as it draws.
    func remaining() -> TimeInterval? {
        guard let deadline else { return nil }
        let left = deadline - clock()
        return left > 0 ? left : nil
    }

    /// The owner closed it.
    func close() {
        guard deadline != nil else { return }
        shut(.byOwner)
    }

    /// The server went down, or is up where no phone can reach it.
    func serverStopped() {
        guard deadline != nil else { return }
        shut(.serverStopped)
    }

    /// A phone paired: the window has done its job.
    func paired(name: String) {
        shut(.paired(name: name))
    }

    /// One wrong PIN from `address` while open. Returns true when that closed
    /// the window for everyone.
    @discardableResult
    func noteWrong(from address: String) -> Bool {
        guard deadline != nil else { return false }
        wrong += 1
        wrongBy[address, default: 0] += 1
        if wrong >= Self.maxWrong {
            shut(.tooManyWrong)
            return true
        }
        return false
    }

    private func shut(_ why: Closed) {
        deadline = nil
        wrong = 0
        wrongBy = [:]
        lastClosed = why
    }

    /// The 403 body outside the window. A `reason` the phone keys on, and a
    /// sentence for a client that only shows `error`.
    nonisolated static let closedBody =
        #"{"reason":"pairing-closed","error":"On the Mac, click Pair a phone, then try again"}"#
    /// The 429 body for an address that has spent its wrong PINs in this window.
    nonisolated static let lockedBody =
        #"{"reason":"pairing-locked","error":"Too many wrong PINs from this device. It can't pair until you click Pair a phone again on the Mac"}"#
}
