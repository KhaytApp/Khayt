import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Pairing by number's screens and floor mode (frames 254:2, signed off
/// Nov 22): what each role may do is the shared rule's, the number reads as
/// the Mac shows it, and a floor phone's Today lines carry no money.
final class FloorModeTests: XCTestCase {

    private struct Vectors: Decodable { let scopesFor: [String: [String]] }

    /// `DeviceRole.allows` is `scopesFor` in lib/device-roles.js, scope for
    /// scope, and fails closed below the owner.
    func testEachRoleHoldsExactlyTheSharedScopes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "test/fixtures/device-roles-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        let every = Set(v.scopesFor.values.flatMap { $0 }).union(["book:write", "made:up"])
        for (role, scopes) in v.scopesFor {
            for scope in every {
                XCTAssertEqual(DeviceRole.allows(role, scope), scopes.contains(scope), "\(role) \(scope)")
            }
        }
        XCTAssertTrue(DeviceRole.allows("owner", "made:up"), "the owner holds everything")
        XCTAssertFalse(DeviceRole.allows("intruder", "orders:write"), "an unknown role is a viewer")
        XCTAssertTrue(DeviceRole.isFloor("operator"))
        XCTAssertTrue(DeviceRole.isFloor("viewer"))
        XCTAssertFalse(DeviceRole.isFloor("manager"))
        XCTAssertFalse(DeviceRole.isFloor("owner"))
    }

    func testTheCheckNumberReadsAsTheMacShowsIt() {
        XCTAssertEqual(PairingView.grouped("481207"), "481 207")
        XCTAssertEqual(PairingView.grouped("12345"), "12345", "anything but six digits is shown as it came")
    }

    /// Every role and every reason the screens name has words in each language.
    func testEveryPairingAndFloorWordIsTranslated() throws {
        var keys = ["pair.code.title", "pair.code.body", "pair.code.device", "pair.code.waiting", "pair.code.starting",
                    "pair.code.foot", "pair.code.use_pin", "pair.code.cancel", "pair.approved.title",
                    "pair.approved.body", "pair.approved.foot", "pair.approved.continue", "pair.not.title",
                    "pair.not.again", "pair.older.title", "pair.older.body", "pair.older.foot", "pair.older.pair",
                    "floor.today.banner.operator", "floor.today.banner.viewer", "floor.job.banner.operator",
                    "floor.job.banner.viewer", "floor.printers.banner.viewer", "floor.printers.no_controls"]
        for role in DeviceRole.ladder { keys += ["role.\(role)", "role.\(role).can"] }
        for why: PairingView.NotPaired in [.denied, .expired, .busy, .refused, .unreachable] {
            keys += ["pair.not.\(PairingView.key(why)).title", "pair.not.\(PairingView.key(why)).body"]
        }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/Resources")
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let url = resources.appending(path: "\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys { XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang): \(key)") }
            XCTAssertEqual(table["role.operator.can"]?.components(separatedBy: "\n").count, 5,
                           "\(lang): the operator's five lines, as the frame")
        }
    }

    private func live(_ name: String, progress: Int?, left: Int?, file: String? = nil) -> MachineLiveStatus {
        MachineLiveStatus(id: name, name: name, hasPrinterApi: true, state: "printing", progress: progress,
                          filename: file, timeRemaining: left, tempNozzle: nil, tempBed: nil, error: nil,
                          lastUpdated: nil, apiType: "moonraker")
    }

    func testTodaysLinesCarryTheJobAndNoMoney() {
        let job = QueueOrder(id: "J1", project: "Coffee dallah", client: "Acme Trading", status: "printing",
                             machine: "Snapmaker U1", machineId: "U1", dueDate: nil, priority: nil)
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let line = FloorTodayView.printingLine(live("Snapmaker U1", progress: 64, left: 3600), job: job, now: now)
        XCTAssertTrue(line.hasPrefix("Snapmaker U1 · Coffee dallah · 64%"), line)
        XCTAssertFalse(line.contains("Acme"), "no client on a floor phone's Today")
        let noJob = FloorTodayView.printingLine(live("MK4", progress: 21, left: nil, file: "stand.gcode"), job: nil, now: now)
        XCTAssertEqual(noJob, "MK4 · stand.gcode · 21%")

        var next = QueueOrder(id: "ORD-01042", project: "Bracket set", client: "Acme Trading", status: "pending",
                              machine: nil, machineId: nil, dueDate: nil, priority: nil)
        XCTAssertEqual(FloorTodayView.queueLine(next), "ORD-01042 Bracket set")
        next = QueueOrder(id: "ORD-01042", project: "Bracket set", client: "Acme Trading", status: "pending",
                          machine: nil, machineId: nil, dueDate: "2026-11-26", priority: nil)
        XCTAssertFalse(FloorTodayView.queueLine(next).contains("Acme"))
        XCTAssertTrue(FloorTodayView.queueLine(next).contains(" · "), "the due day follows")
    }

    /// A floor phone is offered no money step on the job page.
    func testMoneyStepsAreNamed() {
        XCTAssertEqual(OrderDetailPage.moneySteps, ["send_quote", "take_job", "record_payment", "hand_over", "ship"])
    }
}
