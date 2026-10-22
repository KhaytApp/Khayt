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
/// were held shut a minute ago. The window is not a free run at the PIN: after
/// `maxWrong` wrong PINs from anyone, it closes, and the Mac says why.
///
/// Phones that already enrolled sign their requests and never come here.
@MainActor @Observable
final class LanPairingWindow {

    /// About two minutes: long enough to pick up a phone, open Khayt and type
    /// the PIN; short enough that a guesser has little time to try.
    static let length: TimeInterval = 120
    /// Wrong PINs, from anyone, that close the window early.
    static let maxWrong = 10

    /// Why the window last closed. Nil: it has not been opened since launch.
    enum Closed: Equatable {
        case paired(name: String)
        case timedOut
        case byOwner
        case tooManyWrong
    }

    /// When the open window shuts by itself; nil when closed.
    private(set) var until: Date?
    private(set) var lastClosed: Closed?
    /// Wrong PINs in the window now open.
    private(set) var wrong = 0

    @ObservationIgnored let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Open it (again) for `length` from now, with a fresh count.
    func open() {
        until = now().addingTimeInterval(Self.length)
        wrong = 0
    }

    /// Whether a phone may enrol now. Past the deadline, this closes it.
    func isOpen() -> Bool {
        guard let until else { return false }
        if now() >= until {
            shut(.timedOut)
            return false
        }
        return true
    }

    /// Seconds left, rounded up; nil when closed. Reads the clock only, so a
    /// view may call it as often as it draws.
    func remaining(at date: Date? = nil) -> Int? {
        guard let until else { return nil }
        let left = until.timeIntervalSince(date ?? now())
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    /// The owner closed it.
    func close() {
        guard until != nil else { return }
        shut(.byOwner)
    }

    /// A phone paired: the window has done its job.
    func paired(name: String) {
        shut(.paired(name: name))
    }

    /// One wrong PIN while open. Returns true when that closed the window.
    @discardableResult
    func noteWrong() -> Bool {
        guard until != nil else { return false }
        wrong += 1
        if wrong >= Self.maxWrong {
            shut(.tooManyWrong)
            return true
        }
        return false
    }

    private func shut(_ why: Closed) {
        until = nil
        wrong = 0
        lastClosed = why
    }

    /// The 403 body outside the window. A `reason` the phone keys on, and a
    /// sentence for a client that only shows `error`.
    nonisolated static let closedBody =
        #"{"reason":"pairing-closed","error":"On the Mac, click Pair a phone, then try again"}"#
}
