import Foundation
import UserNotifications

// Shared by the app and the KhaytAlerts notification service extension — one
// description of a print ending, one rule for its button, one wording — so an
// alert reads the same whether the app noticed the ending or Apple woke the
// extension with it. Nothing here may reach for the app's singletons: the
// extension has none of them. Text comes in through `tr`.

/// A print that has just stopped, as the Mac's `print-finished` event
/// describes it (payload v1, agreed with the Mac and Cloud lanes). The same
/// shape is built on the phone from the live readings, so there is one kind
/// of alert whichever way it was noticed.
struct PrintFinished: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case finished, failed, cancelled
        /// The print stopped and the Mac cannot tell how (Mac lane, Nov 14):
        /// said neutrally, "check the printer". Also what any outcome this
        /// build does not know becomes, so a new word from a newer Mac shows
        /// a sensible alert instead of failing the whole decode.
        case ended

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Outcome(rawValue: raw) ?? .ended
        }
    }

    var v: Int = 1
    var kind: String = "print-finished"
    var at: String
    var machineId: String
    var machineName: String?
    var orderId: String?
    var project: String?
    var client: String?
    var filename: String?
    var durationS: Double?
    var outcome: Outcome
    var photo: Bool = false
    /// The stage the Mac moved the job to on this edge, if it did — so the
    /// phone never moves it a second time. Nil today: the Mac records the
    /// end, it does not advance the job.
    var advancedTo: String?
}

extension PrintFinished {
    /// Read what the Mac sent, forgivingly: a missing `photo`, `v` or `kind`
    /// (or `outcome`) gives a plainer alert, never a failed decode, which
    /// lost the alert's job and button. Only the time and the machine are
    /// needed. In an extension, so the memberwise initialiser stays.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        // This type is only ever a print ending; that is the only kind it holds.
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "print-finished"
        at = try c.decode(String.self, forKey: .at)
        machineId = try c.decode(String.self, forKey: .machineId)
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName)
        orderId = try c.decodeIfPresent(String.self, forKey: .orderId)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        durationS = try c.decodeIfPresent(Double.self, forKey: .durationS)
        outcome = try c.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .ended
        photo = try c.decodeIfPresent(Bool.self, forKey: .photo) ?? false
        advancedTo = try c.decodeIfPresent(String.self, forKey: .advancedTo)
    }
}

/// What an alert offers, and the one move each makes.
///
/// Agreed with the Mac lane, and deliberately narrow:
/// - a print that FINISHED can go on to post-processing — the next stage;
/// - one that FAILED or was CANCELLED can be re-queued (back to pending);
/// - an order already COMPLETED can be marked shipped — `markShipped` works
///   from completed only, and a print that has just finished is not that.
/// A reprint of a print that came out fine is another copy of the job, not a
/// move of this one, and is not offered.
enum PrintAlertAction: String, CaseIterable {
    case moveToPost = "khayt.print.post"
    case reprint = "khayt.print.reprint"
    case markShipped = "khayt.print.shipped"

    var titleKey: String {
        switch self {
        case .moveToPost: return "alert.print.move_post"
        case .reprint: return "alert.print.reprint"
        case .markShipped: return "alert.print.mark_shipped"
        }
    }

    /// The category an alert carries decides its buttons.
    var category: String { rawValue + ".category" }

    static let infoCategory = "khayt.print.info"

    /// Which button, if any, for this ending of this job.
    static func offered(for event: PrintFinished, orderStatus: String?) -> PrintAlertAction? {
        guard event.orderId != nil, let status = orderStatus else { return nil }
        switch event.outcome {
        case .finished:
            if status == "completed" { return .markShipped }
            // Already moved (by the Mac, or by hand since): nothing to offer.
            if let advanced = event.advancedTo, advanced != "printing" { return nil }
            return status == "printing" ? .moveToPost : nil
        case .failed, .cancelled:
            return status == "printing" ? .reprint : nil
        case .ended:
            // How it ended is not known, so neither move is offered.
            return nil
        }
    }

    /// Registered by the app; the extension only names one.
    static func categories(tr: (String) -> String) -> Set<UNNotificationCategory> {
        var out = Set(allCases.map { action in
            UNNotificationCategory(
                identifier: action.category,
                actions: [UNNotificationAction(identifier: action.rawValue, title: tr(action.titleKey),
                                               // It writes to the shop's book: not from a locked phone.
                                               options: [.authenticationRequired])],
                intentIdentifiers: [])
        })
        out.insert(UNNotificationCategory(identifier: infoCategory, actions: [], intentIdentifiers: []))
        return out
    }
}


/// What kind of news a notification is — its `filterCriteria`, which a Focus
/// filter (`ShopFocusFilter`) lets through or holds back. Shared by the app and
/// the notification service extension, so a push and an in-app alert about the
/// same print are filtered alike.
enum NotificationKind {
    /// A print finished, failed or was cancelled.
    static let print = "print"
    /// A new order request reached the shop.
    static let intake = "intake"
    /// The queue moved, a job is late, filament is low, the Mac went away.
    static let shop = "shop"
    static let all = [print, intake, shop]

    /// From a push's payload (`k.kind`), for a push shown as Apple delivered it.
    static func of(_ info: [AnyHashable: Any]) -> String {
        guard let k = info["k"] as? [String: Any], let kind = k["kind"] as? String else { return shop }
        switch kind {
        case "print-finished": return print
        case "intake": return intake
        default: return shop
        }
    }
}

/// The words of a print alert.
enum PrintAlertText {
    static func content(for event: PrintFinished, orderStatus: String?,
                        locale: Locale = AlertDigits.locale(), shopId: String? = nil,
                        now: Date = Date(), timeZone: TimeZone = .current,
                        tr: (String) -> String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.filterCriteria = NotificationKind.print
        switch event.outcome {
        case .finished: c.title = tr("alert.print.finished")
        case .failed: c.title = tr("alert.print.failed")
        case .cancelled: c.title = tr("alert.print.cancelled")
        case .ended: c.title = tr("alert.print.ended")
        }
        let what = event.project ?? event.filename ?? tr("alert.print.a_job")
        var parts = [what]
        if let machine = event.machineName, !machine.isEmpty { parts.append(machine) }
        if let s = event.durationS, s >= 60 {
            // Western digits and the Gregorian calendar, as everywhere in the
            // app (khayt-ios-calendar-and-digits): the formatter's own default
            // was the SYSTEM locale, so a Saudi phone wrote "٢ س ١٥ د".
            let f = DateComponentsFormatter()
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            f.calendar = calendar
            f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute]
            f.unitsStyle = .abbreviated
            if let t = f.string(from: s) { parts.append(t) }
        }
        if let ended = endedLabel(at: event.at, now: now, locale: locale, timeZone: timeZone) { parts.append(ended) }
        c.body = parts.joined(separator: " · ")
        c.sound = .default
        c.threadIdentifier = "khayt.prints"
        // A failed or cancelled print is worth breaking through Focus for;
        // a finished one is not (Dev Hub, Nov 13). The app carries the
        // time-sensitive entitlement (on for the App ID since Nov 13).
        // An ending of unknown kind is said plainly, not through Focus.
        c.interruptionLevel = (event.outcome == .finished || event.outcome == .ended) ? .active : .timeSensitive
        let action = PrintAlertAction.offered(for: event, orderStatus: orderStatus)
        c.categoryIdentifier = action?.category ?? PrintAlertAction.infoCategory
        var info: [String: Any] = ["machineId": event.machineId, "outcome": event.outcome.rawValue]
        if let order = event.orderId { info["orderId"] = order }
        // Which shop it is about, so a tap never opens a job of another shop.
        if let shopId { info["shopId"] = shopId }
        c.userInfo = info
        return c
    }

    /// Every key the alert uses — the extension carries its own copy of these,
    /// and a test holds the two copies to the same words.
    static let keys = ["alert.print.finished", "alert.print.failed", "alert.print.cancelled", "alert.print.ended",
                       "alert.print.a_job", "alert.print.move_post", "alert.print.reprint",
                       "alert.print.mark_shipped", "PUSH_TITLE", "PUSH_PRINT_FINISHED", "PUSH_INTAKE",
                       "PUSH_OVERDUE", "PUSH_LOW_STOCK", "PUSH_DUE_TODAY", "PUSH_QUOTE_DECISION",
                       "PUSH_QUOTE_APPROVED", "PUSH_QUOTE_DECLINED", "PUSH_MESSAGE", "PUSH_PAYMENT", "PUSH_GENERIC"]
}


extension PrintAlertText {
    /// Up to this old, an ending is "now" and needs no time on it.
    static let justNow: TimeInterval = 2 * 60

    /// When the print ENDED, for an alert that arrives late — the Mac sends
    /// an ending noticed while it slept at its next wake, and retries a failed
    /// post for hours, with `at` the time the print ended (Mac lane, Nov 13).
    /// Nil within `justNow`; the time of day the same day; the day and time
    /// after that. Gregorian, the app's language, Western digits.
    static func endedLabel(at: String, now: Date, locale: Locale, timeZone: TimeZone) -> String? {
        let iso = ISO8601DateFormatter()
        var date = iso.date(from: at)
        if date == nil { iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; date = iso.date(from: at) }
        guard let date, now.timeIntervalSince(date) > justNow else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let sameDay = calendar.isDate(date, inSameDayAs: now)
        var style = Date.FormatStyle(date: sameDay ? .omitted : .abbreviated, time: .shortened,
                                     locale: locale, calendar: calendar, timeZone: timeZone)
        style.capitalizationContext = .middleOfSentence
        return date.formatted(style)
    }
}

// MARK: - Digits

/// The locale an alert's figures are written in: the app's language with
/// Western digits (`numberingSystem = latn`), as `L10n.locale` is in the app.
/// The extension has no `L10n`, so it takes the language the system chose for
/// its own bundle.
enum AlertDigits {
    static func locale(language: String? = Bundle.main.preferredLocalizations.first) -> Locale {
        Locale(identifier: (language ?? "en") + "@numbers=latn")
    }
}

// MARK: - The alert index

/// What the notification extension needs from the book, and nothing else:
/// each job's id and its stage, a few KB.
///
/// The extension used to decode the WHOLE book (`khayt-store.json`) to look
/// up one job's stage. A real shop's book is 26 MB, a notification service
/// extension may use about 24 MB, so iOS killed it and the phone showed the
/// server's plain text without the job or its button (push review P1, Nov 13).
/// The app writes this index beside the book whenever the book changes; the
/// extension reads only this.
enum AlertIndex {
    static let fileName = "alert-index.json"
    /// More jobs than any phone needs to answer an alert about; newest kept.
    static let maxJobs = 2000

    /// Job id → stage, from a book's `printLog` (newest last kept on a cap).
    static func build(from printLog: [[String: Any]]) -> [String: String] {
        var out: [String: String] = [:]
        for row in printLog.suffix(maxJobs) {
            guard let id = row["id"] as? String, !id.isEmpty, let status = row["status"] as? String else { continue }
            if row["voidedAt"] != nil, !(row["voidedAt"] is NSNull) { continue }
            out[id] = status
        }
        return out
    }

    static func url(in directory: URL) -> URL { directory.appending(path: fileName) }

    /// The file: `{"jobs": {id: stage}, "badge": n}`. The app writes `jobs`
    /// on every book change and `badge` whenever it works out Home's "Needs
    /// you" count; each write keeps the other half. One process writes it (the
    /// app), so a lock is enough.
    private static let lock = NSLock()

    private static func read(_ directory: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return doc
    }

    private static func change(_ directory: URL, _ edit: (inout [String: Any]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var doc = read(directory)
        edit(&doc)
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return }
        try? data.write(to: url(in: directory), options: [.atomic])
    }

    static func write(_ index: [String: String], to directory: URL) {
        change(directory) { $0["jobs"] = index }
    }

    /// The stage of one job, read from the index alone.
    static func status(of orderId: String, in directory: URL) -> String? {
        (read(directory)["jobs"] as? [String: String])?[orderId]
    }

    /// Home's "Needs you" count as the app last worked it out — the number
    /// the extension puts on the app icon. Nil before the app has said.
    static func badge(in directory: URL) -> Int? {
        read(directory)["badge"] as? Int
    }

    static func setBadge(_ count: Int, in directory: URL) {
        change(directory) { $0["badge"] = max(0, count) }
    }
}

// MARK: - Pushes the phone does not know

/// The kinds of push this build has words for, by the key Cloud sends as
/// `loc-key` (khayt-cloud's push list). Anything else is shown as
/// `PUSH_GENERIC`, never as a raw key (push review C8, Nov 13).
enum KnownPush {
    static let keys: Set<String> = ["PUSH_TITLE", "PUSH_PRINT_FINISHED", "PUSH_INTAKE", "PUSH_OVERDUE",
                                    "PUSH_LOW_STOCK", "PUSH_DUE_TODAY", "PUSH_QUOTE_DECISION",
                                    "PUSH_QUOTE_APPROVED", "PUSH_QUOTE_DECLINED", "PUSH_MESSAGE",
                                    "PUSH_PAYMENT", "PUSH_GENERIC"]

    /// True when `text` is a key iOS could not translate (it shows the key
    /// itself) rather than words.
    static func isRawKey(_ text: String) -> Bool {
        text.range(of: #"^[A-Z][A-Z0-9_]{3,}$"#, options: .regularExpression) != nil
    }

    /// Kinds the phone treats as needing attention through Focus.
    static func isTimeSensitive(kind: String) -> Bool { kind == "payment" }
}
