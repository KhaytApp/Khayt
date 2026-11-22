import Foundation

/// How far along an order is, for the page a CUSTOMER sees — ported to Swift.
///
/// The JavaScript exists because two copies of this list had drifted: `qc` and
/// `delivered` were missing from both, `indexOf` returned -1, every step
/// compared `-1 >= step` and came out false — so a customer who had already
/// RECEIVED their print opened the tracker and saw a job that had not started.
///
/// Which makes it a pointed thing to port: the fault it exists to prevent is
/// exactly the fault a port can reintroduce. `OrderProgressParityTests` runs
/// both over every status either side knows, and over the names that only break
/// one of them.
public enum OrderProgress {

    /// The stages a customer is shown, in order.
    ///
    /// `on_hold` and `qc` are deliberately not stages of their own: a job on
    /// hold has still reached whatever it reached, and QC is part of finishing.
    public static let steps = ["quote", "pending", "printing", "post", "completed"]

    /// Which step each status counts as having reached.
    public static let progressOf: [String: Int] = [
        "quote": 0,
        "pending": 1,
        "on_hold": 1,      // held, but it got as far as it got
        "queued": 1,
        "printing": 2,
        "post": 3,
        "qc": 3,           // checking the finished print is part of finishing it
        "completed": 4,
        "delivered": 4,    // completed and handed over
        "split": 1,        // the parent is superseded; its children carry the work
    ]

    /// How many steps this order has reached.
    ///
    /// An unknown status reads as "at least started" rather than "nothing has
    /// happened" — failing forward, because a tracker that under-reports is the
    /// one that makes a customer think their order was lost.
    ///
    /// The JavaScript guards this lookup with `hasOwnProperty`, which matters:
    /// a status called `constructor` or `toString` would otherwise find
    /// something on the prototype and return a function where a number was
    /// expected. A Swift dictionary has no prototype, so the guard is free
    /// here — and the parity test asks for those names anyway, because "free
    /// here" is a claim worth checking rather than asserting.
    public static func index(of status: String?) -> Int {
        progressOf[status ?? ""] ?? 1
    }

    /// Is `step` reached by an order at `status`?
    public static func reached(_ status: String?, step: Int) -> Bool {
        index(of: status) >= step
    }
}
