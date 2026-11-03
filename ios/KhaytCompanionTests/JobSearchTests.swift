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
}
