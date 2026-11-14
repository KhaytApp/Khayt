import Foundation

/// A job's due date on the job page: how late it is, and whether what it owes
/// is overdue. The next step itself is the shared rule's (`JobSteps`).
enum JobDue {
    /// Whole calendar days a due date has gone by, on the Gregorian calendar;
    /// nil when it has not (or there is none).
    static func daysLate(due: String?, today: Date = Date()) -> Int? {
        guard let raw = due, let day = DueDateParser.parse(raw) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: day), to: cal.startOfDay(for: today)).day ?? 0
        return n > 0 ? n : nil
    }

    /// Owing is red only when it is overdue: money still owed on a job whose
    /// due date has gone by.
    static func owingIsOverdue(owed: Double, due: String?, today: Date = Date()) -> Bool {
        owed > 0.005 && daysLate(due: due, today: today) != nil
    }
}
