import AppKit
import KhaytCore

/// Capture passes for the job page (S1) and for Simple mode (S4), on the
/// sample book, in memory. Nothing is written and no button is pressed.
///
///   KHAYT_SNAPSHOT_JOBPAGE=1   Jobs ▸ List with a printing job, a job on
///                              hold and a quote chosen.
///   KHAYT_SNAPSHOT_SIMPLE=1    the sample as a Simple shop: the four-column
///                              board and the short customer form.
///
/// The ordinary run draws the sample only as a Professional shop, and the
/// test renderer leaves a ScrollView blank — so neither could show these.
extension Snapshot {

    static func captureJobPage(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        await settle()
        defer { shop.pretendsControl = false; shop.jobsLayout = .list }
        // So the steps draw enabled, as they are in a book this Mac holds.
        shop.pretendsControl = true
        shop.shelf = .jobs(nil)
        shop.jobsLayout = .page
        for (name, stage) in [("printing", Stage.printing), ("on-hold", .on_hold), ("quote", .quote),
                              ("completed", .completed)] {
            guard let job = shop.orders.first(where: { Stage.of($0) == stage }) else { continue }
            shop.selectJobs([job.id])
            await settle()
            capture(named: "s1-job-page-\(name)\(tag)", into: dir)
        }
    }

    static func captureSimple(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        defer { shop.pretendMode(nil); shop.jobsLayout = .list; shop.editingCustomer = nil }
        shop.pretendMode("simple")
        await shop.readFeatures()
        await shop.readSimpleFiling()
        shop.shelf = .jobs(nil)
        shop.jobsLayout = .board
        await settle()
        capture(named: "s4-simple-board\(tag)", into: dir)
        if let someone = shop.clients.first {
            shop.shelf = .customers
            shop.editingCustomer = someone
            await settle()
            captureSheet(named: "s4-simple-customer\(tag)", into: dir)
        }
    }
}
