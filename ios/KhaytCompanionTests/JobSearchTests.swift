import XCTest
@testable import KhaytCompanion

/// A job found in Spotlight reads as one: its project, its number and who it
/// is for, so "#1042" or a customer's name finds it.
final class JobSearchTests: XCTestCase {
    func testAFoundJobSaysWhatAndWhoAndWhich() {
        let job = JobSearchEntity(id: "KH-1042", title: "Planter", client: "Maya Chen", stage: "Printing")
        XCTAssertEqual(job.attributeSet.title, "Planter")
        XCTAssertEqual(job.attributeSet.keywords, ["KH-1042", "Maya Chen"])
        XCTAssertEqual(job.attributeSet.contentDescription, "Maya Chen · Printing")
    }

    /// Re-indexing clears what was indexed before, so a job cut from the book
    /// — or the sample shop's, once a real one is paired — leaves Spotlight.
    @MainActor
    func testReindexingDeletesTheOldJobsFirst() async {
        let spotlight = FakeIndex()
        let job = JobSearchEntity(id: "KH-1", title: "Planter", client: "", stage: "")
        await JobSearch.reindex([job], into: spotlight)
        XCTAssertEqual(spotlight.calls, ["delete", "index KH-1"])
        await JobSearch.reindex([], into: spotlight)
        XCTAssertEqual(spotlight.calls.suffix(1), ["delete"], "an empty book empties Spotlight too")
    }
}

/// Spotlight, as the calls made to it.
final class FakeIndex: JobIndex, @unchecked Sendable {
    var calls: [String] = []
    func deleteJobs() async throws { calls.append("delete") }
    func indexJobs(_ jobs: [JobSearchEntity]) async throws { calls.append("index " + jobs.map(\.id).joined(separator: ",")) }
}
