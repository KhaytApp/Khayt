import Foundation
import KhaytCore

/**
 * Printer care on the phone: the rules of `lib/maintenance.js` and the parts
 * list of `lib/care-plans.js`, in Swift.
 *
 * ── WHY A PORT, AND WHAT KEEPS IT HONEST ─────────────────────────────────
 *
 * The phone draws a machine's care card synchronously, on every redraw, and
 * the engine is an actor a view cannot wait on. So the few rules the card
 * needs are written here — pure, `now` passed in, no clock — and
 * `PrinterCareParityTests` runs the REAL `lib/maintenance.js` and
 * `lib/care-plans.js` in JavaScriptCore against this file over fixtures
 * covering every status tier, each clock alone and both together, a
 * deferral active and superseded, and a parts list with several order-by
 * dates. Change the JavaScript and that test says so.
 *
 * Values are read the way the JavaScript reads them (`num`, `str`,
 * `new Date(...)`): a missing number is the fallback, a `null` one is 0, a
 * numeric string is its number.
 *
 * ── ONE DIFFERENCE, ON PURPOSE ────────────────────────────────────────────
 *
 * `partsOf` in `lib/care-plans.js` falls back to the plan's catalogue when a
 * task carries `carePlanId` but no `parts`. The catalogue is not ported: every
 * task a plan adds (`applyPlan`) is written with its `parts`, so the fallback
 * only reaches a record edited by hand. Such a task is left off this phone's
 * list rather than guessed at; the Mac's list still has it.
 */
enum CareRules {

    static let warnFraction = 0.9
    static let dueFraction = 1.0
    static let overdueFraction = 1.5
    static let deferFraction = 0.5
    static let msPerDay = 24.0 * 60 * 60 * 1000

    static let severity: [String: Int] = ["overdue": 3, "due": 2, "warning": 1, "ok": 0]

    // MARK: - Reading values the way the JavaScript does

    /// `num(v, fallback)`: `+v` when finite, else the fallback. `undefined` is
    /// the fallback; `null`, `false` and `""` are 0.
    static func num(_ v: JSONValue?, _ fallback: Double = 0) -> Double {
        switch v {
        case nil: return fallback
        case .null?: return 0
        case .bool(let b)?: return b ? 1 : 0
        case .number(let n)?: return n.isFinite ? n : fallback
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return 0 }
            if let d = Double(t), d.isFinite { return d }
            return fallback
        case .array(let a)?: return a.isEmpty ? 0 : (a.count == 1 ? num(a[0], fallback) : fallback)
        case .object?: return fallback
        }
    }

    /// `String(v == null ? '' : v).trim()`.
    static func str(_ v: JSONValue?) -> String {
        switch v {
        case nil, .null?: return ""
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let n)?: return jsNumberText(n)
        case .bool(let b)?: return b ? "true" : "false"
        case .array?, .object?: return ""
        }
    }

    /// `String(v)` for a record id: `undefined` and `null` spelled as the
    /// JavaScript spells them, so a task with no machine matches none.
    static func idText(_ v: JSONValue?) -> String {
        switch v {
        case nil: return "undefined"
        case .null?: return "null"
        case .string(let s)?: return s
        default: return str(v)
        }
    }

    private static func jsNumberText(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e21 { return String(Int64(n)) }
        return String(n)
    }

    /// `new Date(v).getTime()` for a stored date, or nil when the value is
    /// missing, falsy, or not a date. ISO dates and date-times only — the
    /// shapes Khayt writes. A bare date is UTC midnight and a date-time with
    /// no zone is local time, as in JavaScript.
    static func parseTime(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n)?:
            guard n != 0, n.isFinite, abs(n) <= 8.64e15 else { return nil }
            return n.rounded(.towardZero)
        case .bool(let b)?: return b ? 1 : nil
        case .string(let s)?:
            return s.isEmpty ? nil : parseISO(s)
        default: return nil
        }
    }

    private static let isoPattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}:?\d{2})?)?$"#)

    static func parseISO(_ s: String) -> Double? {
        let text = s.trimmingCharacters(in: .whitespaces)
        guard let m = isoPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        guard let y = Int(group(1)!), let mo = Int(group(2)!), let d = Int(group(3)!),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var parts = DateComponents()
        parts.year = y; parts.month = mo; parts.day = d
        var zone = TimeZone(identifier: "UTC")!
        var fraction = 0.0
        if let hh = group(4).flatMap(Int.init), let mm = group(5).flatMap(Int.init) {
            guard hh <= 24, mm <= 59 else { return nil }
            parts.hour = hh; parts.minute = mm
            parts.second = group(6).flatMap(Int.init) ?? 0
            if let f = group(7) { fraction = Double("0." + f) ?? 0 }
            if let z = group(8) {
                if z != "Z" {
                    let sign = z.hasPrefix("-") ? -1 : 1
                    let digits = z.dropFirst().replacingOccurrences(of: ":", with: "")
                    let h = Int(digits.prefix(2)) ?? 0, mi = Int(digits.suffix(2)) ?? 0
                    zone = TimeZone(secondsFromGMT: sign * (h * 3600 + mi * 60)) ?? zone
                }
            } else {
                zone = .current
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let date = cal.date(from: parts) else { return nil }
        // Whole milliseconds, as a JavaScript Date keeps them.
        return ((date.timeIntervalSince1970 + fraction) * 1000).rounded(.down)
    }

    /// `new Date(ms).toISOString()`: UTC, whole milliseconds, always Z.
    static func iso(ms: Double) -> String {
        let whole = ms.rounded(.towardZero)
        let seconds = (whole / 1000).rounded(.down)
        let millis = Int(whole - seconds * 1000)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: seconds)) + String(format: ".%03dZ", millis)
    }

    /// A Date as the JavaScript's `getTime()`: whole milliseconds.
    static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded(.down) }

    // MARK: - lib/maintenance.js

    private static func classify(_ used: Double, _ interval: Double) -> String {
        guard interval > 0 else { return "ok" }
        if used >= overdueFraction * interval { return "overdue" }
        if used >= dueFraction * interval { return "due" }
        if used >= warnFraction * interval { return "warning" }
        return "ok"
    }

    struct Status: Equatable {
        var status: String
        var hoursRemaining: Double?
        var daysRemaining: Double?
        var deferred: Bool
    }

    struct Deferral: Equatable {
        var untilHours: Double?
        var untilMs: Double?
    }

    /// `activeDeferral`: "inspected, not needed", until a later completion
    /// supersedes it (`lastDoneAt` at or after `inspectedAt`).
    static func activeDeferral(_ task: [String: JSONValue]) -> Deferral? {
        guard let inspected = parseTime(task["inspectedAt"]) else { return nil }
        if let done = parseTime(task["lastDoneAt"]), done >= inspected { return nil }
        var untilHours: Double?
        switch task["deferUntilHours"] {
        case nil, .null?: untilHours = nil
        case .string(let s)? where s.isEmpty: untilHours = nil
        case let v?:
            let n = num(v, .nan)
            untilHours = n.isFinite ? n : nil
        }
        let untilMs = parseTime(task["deferUntilAt"])
        if untilHours == nil && untilMs == nil { return nil }
        return Deferral(untilHours: untilHours, untilMs: untilMs)
    }

    /// `taskStatus`: the worse of the hours clock and the date clock.
    static func taskStatus(_ task: [String: JSONValue], machineHours: Double, nowMs: Double) -> Status {
        let intervalHours = num(task["intervalHours"], 0)
        let intervalDays = num(task["intervalDays"], 0)
        let deferral = activeDeferral(task)
        var status = "ok"
        var hoursRemaining: Double?
        var daysRemaining: Double?

        if intervalHours > 0 {
            var base = num(task["lastDoneHours"], 0)
            if let until = deferral?.untilHours { base = max(base, until - intervalHours) }
            let used = max(0, (machineHours.isFinite ? machineHours : 0) - base)
            hoursRemaining = intervalHours - used
            let s = classify(used, intervalHours)
            if severity[s]! > severity[status]! { status = s }
        }
        if intervalDays > 0 {
            var last = parseTime(task["lastDoneAt"])
            if let until = deferral?.untilMs {
                let moved = until - intervalDays * msPerDay
                last = last.map { max($0, moved) } ?? moved
            }
            if let last {
                let used = max(0, (nowMs - last) / msPerDay)
                daysRemaining = intervalDays - used
                let s = classify(used, intervalDays)
                if severity[s]! > severity[status]! { status = s }
            } else {
                daysRemaining = intervalDays
            }
        }
        return Status(status: status, hoursRemaining: hoursRemaining, daysRemaining: daysRemaining,
                      deferred: deferral != nil)
    }

    static func taskStatus(_ task: [String: JSONValue], machineHours: Double, now: Date) -> Status {
        taskStatus(task, machineHours: machineHours, nowMs: ms(now))
    }

    /// `markDone`: the two fields a completion writes. The deferral fields are
    /// left as they are — a `lastDoneAt` after `inspectedAt` supersedes them.
    static func markDone(machineHours: Double, nowIso: String) -> [String: JSONValue] {
        ["lastDoneHours": .number(machineHours.isFinite ? machineHours : 0), "lastDoneAt": .string(nowIso)]
    }

    /// `deferTask` with the default push (half of each active interval,
    /// counted from the inspection, never earlier than the task was due).
    static func deferTask(_ task: [String: JSONValue], machineHours: Double, nowIso: String) -> [String: JSONValue] {
        let meter = max(0, machineHours.isFinite ? machineHours : 0)
        let intervalHours = num(task["intervalHours"], 0)
        let intervalDays = num(task["intervalDays"], 0)
        let nowMs = parseISO(nowIso)
        let st = taskStatus(task, machineHours: meter, nowMs: nowMs ?? .nan)
        var untilHours: JSONValue = .null
        if intervalHours > 0 {
            let push = deferFraction * intervalHours
            let wasDueAt = meter + (st.hoursRemaining ?? 0)
            untilHours = .number(max(meter + push, wasDueAt))
        }
        var untilAt: JSONValue = .null
        if intervalDays > 0, let nowMs {
            let push = deferFraction * intervalDays
            let left = st.daysRemaining.map { $0.isFinite ? $0 : 0 } ?? 0
            let wasDueMs = nowMs + left * msPerDay
            untilAt = .string(iso(ms: max(nowMs + push * msPerDay, wasDueMs)))
        }
        return ["inspectedAt": .string(nowIso), "inspectedHours": .number(meter),
                "deferUntilHours": untilHours, "deferUntilAt": untilAt]
    }

    private static func isFinished(_ job: [String: JSONValue]) -> Bool {
        job["status"] == .string("completed") || job["status"] == .string("delivered")
    }

    /// `hoursMeter`: the print time of every finished job on the machine.
    static func hoursMeter(_ jobs: [JSONValue], machineId: String) -> Double {
        var hours = 0.0
        for case .object(let job) in jobs {
            guard job["machineId"] == .string(machineId), isFinished(job) else { continue }
            hours += num(job["printTime"], 0)
        }
        return max(0, hours)
    }

    /// `hoursPerDay`: finished hours over the window ending now, averaged over
    /// the days since the first job when the machine is newer than that.
    static func hoursPerDay(_ jobs: [JSONValue], machineId: String, nowMs: Double, windowDays: Double = 30) -> Double {
        let win = windowDays > 0 ? windowDays : 30
        guard nowMs.isFinite else { return 0 }
        let start = nowMs - win * msPerDay
        var hours = 0.0
        var first: Double?
        for case .object(let job) in jobs {
            guard job["machineId"] == .string(machineId), isFinished(job) else { continue }
            let when: JSONValue? = isTruthy(job["completedAt"]) ? job["completedAt"] : job["date"]
            guard let at = parseTime(when), at <= nowMs else { continue }
            if first == nil || at < first! { first = at }
            if at > start { hours += max(0, num(job["printTime"], 0)) }
        }
        guard let first else { return 0 }
        let days = first > start ? max(1, (nowMs - first) / msPerDay) : win
        return hours / days
    }

    private static func isTruthy(_ v: JSONValue?) -> Bool {
        switch v {
        case nil, .null?: return false
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0 && !n.isNaN
        case .string(let s)?: return !s.isEmpty
        default: return true
        }
    }

    struct Projection: Equatable {
        var dueMs: Double?
        var clock: String?
        var status: String
        var deferred: Bool
        var dueAt: String? { dueMs.map { CareRules.iso(ms: $0) } }
    }

    /// `projectDue`: when the task falls due, from the meter and the rate the
    /// machine has been running at; whichever clock comes first.
    static func projectDue(_ task: [String: JSONValue], meter: Double, rate: Double, nowMs: Double) -> Projection {
        let st = taskStatus(task, machineHours: meter, nowMs: nowMs)
        var dueMs: Double?
        var clock: String?
        if let h = st.hoursRemaining {
            if h <= 0 { dueMs = nowMs; clock = "hours" }
            else if rate > 0 { dueMs = nowMs + (h / rate) * msPerDay; clock = "hours" }
        }
        if let d = st.daysRemaining {
            let at = nowMs + max(0, d) * msPerDay
            if dueMs == nil || at < dueMs! { dueMs = at; clock = "days" }
        }
        return Projection(dueMs: dueMs, clock: clock, status: st.status, deferred: st.deferred)
    }

    /// `remainingFraction` from `dueTasks`: the most-overdue clock's share of
    /// its interval left, for ranking tasks of the same status.
    static func remainingFraction(_ task: [String: JSONValue], _ st: Status) -> Double {
        var vals: [Double] = []
        let ih = num(task["intervalHours"], 0), id = num(task["intervalDays"], 0)
        if let h = st.hoursRemaining, ih > 0 { vals.append(h / ih) }
        if let d = st.daysRemaining, id > 0 { vals.append(d / id) }
        return vals.min() ?? 0
    }

    // MARK: - lib/care-plans.js

    struct Part: Equatable {
        let id: String
        let unit: String
        let leadDays: Double
    }

    /// `KhaytCarePlans.PARTS`, in its order: id, what one counts, lead days.
    /// The parity test compares them.
    static let parts: [Part] = ([
        ("nozzle", "pcs", 7),
        ("ptfe_tube", "pcs", 7),
        ("carbon_filter", "pcs", 14),
        ("air_filter", "pcs", 14),
        ("grease", "tube", 7),
        ("oil", "bottle", 7),
        ("rail_lube", "set", 14),
        ("fep_film", "pcs", 7),
        ("resin_tank", "pcs", 14),
        ("ipa", "l", 3),
    ] as [(String, String, Double)]).map { Part(id: $0.0, unit: $0.1, leadDays: $0.2) }
    static let partById: [String: Part] = Dictionary(uniqueKeysWithValues: parts.map { ($0.id, $0) })

    /// `partsOf`, from the task's own `parts` (see the note at the top).
    static func partsOf(_ task: [String: JSONValue]) -> [(id: String, qty: Double)] {
        guard case .array(let list)? = task["parts"] else { return [] }
        var out: [(id: String, qty: Double)] = []
        for case .object(let x) in list {
            let id = str(x["id"])
            guard partById[id] != nil else { continue }
            let q = max(0, num(x["qty"], 1))
            out.append((id, q == 0 ? 1 : q))
        }
        return out
    }

    struct BuyRow: Equatable, Identifiable {
        var id: String { taskId + "|" + partId }
        let partId: String
        let unit: String
        let qty: Double
        let machineId: String
        let machineName: String
        let taskId: String
        let careTaskId: String?
        let taskName: String
        let dueAt: String
        let orderBy: String
        let orderByMs: Double
        let leadDays: Double
        let late: Bool
        let status: String
        let clock: String?
    }

    private static func isRetired(_ m: [String: JSONValue]) -> Bool {
        m["status"] == .string("retired") || !str(m["retiredAt"]).isEmpty
    }

    /// `partsBuyList`: one row per part per task falling due inside the
    /// horizon, sorted by order-by date, then machine, then part.
    ///
    /// `meters` replaces `hoursMeter` per machine when given — a phone holding
    /// only the newest jobs passes the whole book's meters (`CareBook`). The
    /// JavaScript has no such input; the parity test leaves it nil.
    static func partsBuyList(machines: [JSONValue], tasks: [JSONValue], jobs: [JSONValue], nowMs: Double,
                             horizonDays: Double = 90, windowDays: Double = 30,
                             leadDays: [String: Double] = [:], meters: [String: Double]? = nil) -> [BuyRow] {
        guard nowMs.isFinite else { return [] }
        let horizon = horizonDays > 0 ? horizonDays : 90
        var byId: [String: [String: JSONValue]] = [:]
        for case .object(let m) in machines {
            guard let id = m["id"], id != .null, !isRetired(m) else { continue }
            byId[idText(id)] = m   // a later record of the same id wins, as in a Map
        }
        var cache: [String: (meter: Double, rate: Double)] = [:]
        var rows: [(BuyRow, Int)] = []
        for case .object(let task) in tasks {
            guard let machine = byId[idText(task["machineId"])] else { continue }
            let used = partsOf(task)
            guard !used.isEmpty else { continue }
            let mid = idText(machine["id"])
            if cache[mid] == nil {
                let meter = meters.map { $0[mid] ?? 0 } ?? hoursMeter(jobs, machineId: mid)
                cache[mid] = (meter, hoursPerDay(jobs, machineId: mid, nowMs: nowMs, windowDays: windowDays))
            }
            let (meter, rate) = cache[mid]!
            let due = projectDue(task, meter: meter, rate: rate, nowMs: nowMs)
            guard let dueMs = due.dueMs, dueMs <= nowMs + horizon * msPerDay else { continue }
            for u in used {
                let part = partById[u.id]!
                let lead = max(0, leadDays[u.id] ?? part.leadDays)
                let orderMs = dueMs - lead * msPerDay
                let careTask = str(task["careTaskId"])
                rows.append((BuyRow(partId: u.id, unit: part.unit, qty: u.qty, machineId: mid,
                                    machineName: str(machine["name"]), taskId: str(task["id"]),
                                    careTaskId: careTask.isEmpty ? nil : careTask, taskName: str(task["name"]),
                                    dueAt: iso(ms: dueMs), orderBy: iso(ms: orderMs), orderByMs: orderMs,
                                    leadDays: lead, late: orderMs < nowMs, status: due.status, clock: due.clock),
                             rows.count))
            }
        }
        rows.sort { a, b in
            if a.0.orderByMs != b.0.orderByMs { return a.0.orderByMs < b.0.orderByMs }
            let byName = a.0.machineName.compare(b.0.machineName, locale: Locale(identifier: "en"))
            if byName != .orderedSame { return byName == .orderedAscending }
            let byPart = a.0.partId.compare(b.0.partId, locale: Locale(identifier: "en"))
            if byPart != .orderedSame { return byPart == .orderedAscending }
            return a.1 < b.1
        }
        return rows.map(\.0)
    }
}

// MARK: - The care of one shop, as this phone holds it

/// The tasks, meters and parts list out of the phone's book.
///
/// ── THE HOURS ARE THE WHOLE BOOK'S ───────────────────────────────────────
///
/// A phone usually holds the open jobs and the newest 200 finished ones
/// (`BookScope.workingSet`), and the meter counts EVERY finished job. Counted
/// here alone it would come out low on any shop with a history: tasks would
/// read less due than they are, and one marked done here would record a meter
/// so far below the Mac's that the Mac would show it overdue again at once.
///
/// So, when the jobs were cut, the meter is the one the Mac (or the cloud
/// pull) measured over the whole book (`BookScope.Taken.meters`), plus what
/// the jobs on this phone have added since — the phone's own count less the
/// same count over the jobs it held at that moment (`Taken.metersHeld`). That
/// snapshot does not move afterwards, so a finished job adds its hours however
/// it arrived: finished here, or folded in from a cloud change. (Measured
/// against the baseline, as before, a cloud change landed in the book AND the
/// baseline and never moved the meter.) A scope from a Mac too old to send
/// the snapshot falls back to the baseline. A cut book from a Mac too old to
/// send meters has no meter: its hours are unknown, and the card says so
/// rather than show a number that is wrong.
struct CareBook {
    struct Task: Identifiable {
        var id: String
        var machineId: String
        var name: String
        var careTaskId: String?
        var intervalHours: Double?
        var intervalDays: Double?
        var status: CareRules.Status
        var rank: Double
        /// The hours clock is not known on this phone (see above).
        var hoursUnknown: Bool
        var needsCare: Bool { status.status == "due" || status.status == "overdue" }
    }

    var tasksByMachine: [String: [Task]] = [:]
    var buyList: [CareRules.BuyRow] = []
    /// Meters by machine, or nil for a machine whose hours are unknown here.
    var meters: [String: Double?] = [:]

    func tasks(for machineId: String) -> [Task] { tasksByMachine[machineId] ?? [] }
    func needsCare(_ machineId: String) -> Int { tasks(for: machineId).filter(\.needsCare).count }

    /// The meter a machine's tasks are measured with, or nil when unknown.
    static func meter(machineId: String, store: [String: JSONValue], baseline: [String: JSONValue]?,
                      scope: BookScope.Taken?) -> Double? {
        let local = rows(store, "printLog")
        let here = CareRules.hoursMeter(local, machineId: machineId)
        if scope?.isWhole("printLog") == true { return here }
        guard let measured = scope?.meters else { return nil }
        let arrived: Double
        if let held = scope?.metersHeld {
            arrived = held[machineId] ?? 0
        } else {
            arrived = baseline.map { CareRules.hoursMeter(rows($0, "printLog"), machineId: machineId) } ?? here
        }
        return max(0, (measured[machineId] ?? 0) + here - arrived)
    }

    init() {}

    init(store: [String: JSONValue], baseline: [String: JSONValue]?, scope: BookScope.Taken?, now: Date) {
        let nowMs = CareRules.ms(now)
        let machines = Self.rows(store, "machines")
        let tasks = Self.rows(store, "machMaintTasks")
        var meters: [String: Double?] = [:]
        for case .object(let m) in machines {
            let id = CareRules.idText(m["id"])
            meters[id] = Self.meter(machineId: id, store: store, baseline: baseline, scope: scope)
        }
        self.meters = meters
        var by: [String: [Task]] = [:]
        for case .object(let t) in tasks {
            guard case .string(let id)? = t["id"] else { continue }
            let machineId = CareRules.idText(t["machineId"])
            let known = meters[machineId] ?? nil
            var record = t
            // Hours unknown: the hours clock is left out rather than read
            // against a count that is too low.
            if known == nil { record["intervalHours"] = nil }
            let st = CareRules.taskStatus(record, machineHours: known ?? 0, nowMs: nowMs)
            let ih = CareRules.num(t["intervalHours"], 0), idays = CareRules.num(t["intervalDays"], 0)
            let careTask = CareRules.str(t["careTaskId"])
            by[machineId, default: []].append(Task(
                id: id, machineId: machineId, name: CareRules.str(t["name"]),
                careTaskId: careTask.isEmpty ? nil : careTask,
                intervalHours: ih > 0 ? ih : nil, intervalDays: idays > 0 ? idays : nil,
                status: st, rank: CareRules.remainingFraction(record, st),
                hoursUnknown: known == nil && ih > 0))
        }
        // Worst first, as `dueTasks` orders them; an up-to-date task after.
        for key in by.keys {
            by[key]!.sort { a, b in
                let sa = CareRules.severity[a.status.status]!, sb = CareRules.severity[b.status.status]!
                if sa != sb { return sa > sb }
                if a.rank != b.rank { return a.rank < b.rank }
                return a.id < b.id
            }
        }
        tasksByMachine = by
        // A machine with unknown hours projects by its date clock only.
        let known = meters.compactMapValues { $0 }
        let projectable = tasks.map { row -> JSONValue in
            guard case .object(var t) = row, known[CareRules.idText(t["machineId"])] == nil else { return row }
            t["intervalHours"] = nil
            return .object(t)
        }
        buyList = CareRules.partsBuyList(machines: machines, tasks: projectable, jobs: Self.rows(store, "printLog"),
                                         nowMs: nowMs, meters: known)
    }

    static func rows(_ store: [String: JSONValue], _ collection: String) -> [JSONValue] {
        if case .array(let r)? = store[collection] { return r }
        return []
    }
}
