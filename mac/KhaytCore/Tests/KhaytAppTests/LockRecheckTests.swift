import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The alpha.62 adversarial re-check of the staff lock, route by route.
@Suite(.serialized) @MainActor
struct LockRecheckTests {

    static func shop(_ operators: [JSONValue] = OperatorLockTests.staff()) async -> Shop {
        await OperatorLockTests.shop(operators)
    }
    static func notAllowed(_ shop: Shop) -> String { shop.words.callIt("mac.lock_not_allowed") }
    static func signInFirst(_ shop: Shop) -> String { shop.words.callIt("mac.lock_sign_in_first") }

    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // N1
    @Test("both shells draw the sign-in screen: the classic detail goes through the same gate")
    func bothShellsLock() async throws {
        let shop = await Self.shop()
        #expect(ShopWindow.gate(for: shop) == .signIn)
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)
        shop.shelf = .reports
        #expect(ShopWindow.gate(for: shop) == .notAllowed)
        shop.shelf = .dashboard
        #expect(ShopWindow.gate(for: shop) == .content)
        // And both shells' detail columns are drawn through `lockedOr`.
        let window = try Self.source("ShopWindow.swift")
        let classic = try #require(window.range(of: "private var classic: some View {"))
        let classicBody = window[classic.upperBound...].prefix(2500)
        #expect(classicBody.contains("lockedOr {"), "the classic shell draws its screens around the lock")
        let screen = try #require(window.range(of: "@ViewBuilder private var screen: some View {"))
        #expect(window[screen.upperBound...].prefix(300).contains("lockedOr {"))
        #expect(window.contains("if !shop.needsSignIn { classicToolbar }"))
    }

    // N2
    @Test("a sheet open when the person changes is put away")
    func sheetsCloseAtLock() async throws {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        shop.takingAJob = true
        shop.checkingCloud = true
        shop.schedulingWork = true
        shop.sendingFeedback = true
        let job = try #require(shop.orders.first)
        shop.pendingSend = Shop.PendingHold(id: job.id, project: job.project)
        shop.confirmingCancel = shop.machines.first
        shop.lockNow()
        #expect(!shop.takingAJob && !shop.checkingCloud && !shop.schedulingWork && !shop.sendingFeedback)
        #expect(shop.pendingSend == nil && shop.confirmingCancel == nil)
    }

    @Test("every Shop flag a sheet or dialog is bound to is put away at Lock")
    func everySheetFlagIsDismissed() throws {
        let lock = try Self.source("OperatorLock.swift")
        let dismiss = try #require(lock.range(of: "func dismissEverySheet() {"))
        let body = String(lock[dismiss.upperBound...].prefix(4000))
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        var missing: Set<String> = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appending(path: name), encoding: .utf8)
            for match in text.matches(of: /(?:isPresented|item): \$shop\.([A-Za-z]+)/) {
                let flag = String(match.output.1)
                if !body.contains(flag + " = ") { missing.insert(flag) }
            }
        }
        #expect(missing.isEmpty, Comment(rawValue: "not put away at Lock: \(missing.sorted())"))
    }

    @Test("the title strip offers nothing behind the lock or on a screen the person may not open")
    func screenActionsEmpty() throws {
        let s = try Self.source("ScreenActions.swift")
        #expect(s.contains("if shop.needsSignIn || !shop.canShow(shop.shelf) {"))
    }

    // N4
    @Test("a viewer cannot pause, cancel, send to, drop on or power a printer")
    func printerControl() async throws {
        let shop = await Self.shop()
        let machine = try #require(shop.machines.first)
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)
        await shop.tell(machine, .pause)
        #expect(shop.printerProblem[machine.id] == Self.notAllowed(shop))
        await shop.drop("obj", on: machine)
        #expect(shop.printerProblem[machine.id] == Self.notAllowed(shop))
        await shop.sendToPrinter(URL(fileURLWithPath: "/tmp/x.gcode"), machineId: machine.id, startPrint: true)
        #expect(shop.printerProblem[machine.id] == Self.notAllowed(shop))
        await shop.switchPlug(machine, on: false)
        #expect(shop.plugProblem[machine.id] == Self.notAllowed(shop))
        #expect(!shop.canMoveJobs, "a viewer is shown no edit buttons")
    }

    // N5, N6, N8
    @Test("web store, customer links and the cloud ask the lock")
    func webStoreLinksCloud() async throws {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)   // operator
        shop.moveProblem = nil
        await shop.publishWebStore()
        #expect(shop.moveProblem == Self.notAllowed(shop))
        shop.moveProblem = nil
        await shop.unpublishWebStore()
        #expect(shop.moveProblem == Self.notAllowed(shop))
        shop.moveProblem = nil
        await shop.sendToCloud()
        #expect(shop.cloudProblem == Self.notAllowed(shop))
        shop.cloudProblem = nil
        await shop.sendToCloud(byPerson: false)
        #expect(shop.cloudProblem != Self.notAllowed(shop), "auto-sync is the owner's standing choice")
        await shop.checkCloud(passphrase: "x")
        #expect(shop.cloudProblem == Self.notAllowed(shop))
        shop.lockNow()
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)   // viewer
        let job = try #require(shop.orders.first)
        #expect(await shop.quoteLink(for: job.id) == nil)
        #expect(shop.moveProblem == Self.notAllowed(shop))
    }

    // N3
    @Test("adding models to the library asks the lock")
    func libraryImport() async {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)
        await shop.addModelsToLibrary([URL(fileURLWithPath: "/tmp/none.stl")])
        #expect(shop.importProblem == Self.notAllowed(shop))
        shop.importProblem = nil
        await shop.addModelToLibrary()
        #expect(shop.importProblem == Self.notAllowed(shop))
    }

    // N9
    @Test("renaming a legacy 'Admin' who is the last owner is refused — the title is their level")
    func legacyLastOwner() async throws {
        let hash = OperatorLockTests.hash("1111")
        let staff: [JSONValue] = [
            .object(["id": .string("OP-a"), "name": .string("Old"), "role": .string("Admin"),
                     "active": .bool(true), "pinHash": .string(hash)]),
            OperatorLockTests.op("OP-x", "Reem", roleKey: "operator", pin: "3333"),
        ]
        let shop = await Self.shop(staff)
        #expect(shop.lockInForce, "a legacy Admin with a PIN is an owner under the lock")
        #expect(await shop.signIn("OP-a", pin: "1111") == .ok)
        let old = try #require(shop.shopOperator("OP-a"))
        var renamed = old.fields
        renamed.role = "Technician"
        await shop.saveOperator(id: "OP-a", renamed, opened: old.fields)
        #expect(shop.moveProblem == shop.words.callIt("mac.lock_last_owner"))
        // Picking an explicit level is read as that level.
        #expect(await shop.lockLevelAfterSave("OP-a", renamed, opened: old.fields) == "operator")
        var promoted = old.fields
        promoted.role = "Technician"; promoted.roleKey = "owner"
        if old.fields.roleKey != "owner" {
            #expect(await shop.lockLevelAfterSave("OP-a", promoted, opened: old.fields) == "owner")
        }
    }

    // N7
    @Test("the feedback sheet offers the book only to somebody who may export it")
    func feedbackBook() throws {
        let s = try Self.source("FeedbackSheet.swift")
        #expect(s.contains("if shop.lockAllows(\"settings\", \"view\") {"))
        #expect(s.contains("if book, shop.lockAllows(\"settings\", \"view\") {"))
    }

    // N10
    @Test("with the lock on, Siri says how many are printing and names nothing")
    func intentsWhileLocked() async {
        let shop = await Self.shop()
        let words = shop.words
        var root: [String: JSONValue] = [
            "machines": .array([.object(["id": .string("m1"), "name": .string("U1")])]),
            "printLog": .array([.object(["id": .string("J1"), "project": .string("Museum replica"),
                                         "status": .string("printing"), "machineId": .string("m1")])]),
        ]
        #expect(Ask.printing(in: root, words: words).contains("Museum replica"))
        root["settings"] = .object(["operatorLockEnabled": .bool(true)])
        let locked = Ask.printing(in: root, words: words)
        #expect(!locked.contains("Museum replica") && !locked.contains("U1"), Comment(rawValue: locked))
    }
}
