import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The alpha.62 security review of the staff lock, finding by finding.
@Suite(.serialized) @MainActor
struct LockReviewTests {

    static func shop() async -> Shop { await OperatorLockTests.shop() }

    static let refusals: Set<String> = ["mac.lock_not_allowed", "mac.lock_sign_in_first"]
    static func refused(_ shop: Shop) -> Bool {
        guard let said = shop.moveProblem else { return false }
        return refusals.map { shop.words.callIt($0) }.contains(said)
    }

    /// One representative writer per area the review named, each with the
    /// rbac question it must ask.
    static func writers(_ shop: Shop) -> [(name: String, area: String, action: String, run: () async -> Void)] {
        let job = shop.orders.first?.id ?? ""
        return [
            ("issueGiftCard", "invoicing", "create", { _ = await shop.issueGiftCard(code: "GC-T", balance: 500, issuedTo: nil, expires: nil) }),
            ("clearPayment", "invoicing", "edit", { await shop.clearPayment(job) }),
            ("addExpense", "invoicing", "create", { await shop.addExpense([:]) }),
            ("signInToCloud", "cloud", "edit", {
                await shop.signInToCloud(url: "https://evil.example", email: "a@b.c", password: "x", passphrase: "y")
            }),
            ("pullFromCloud", "cloud", "edit", { await shop.pullFromCloud() }),
            ("logWaste", "inventory", "create", { await shop.logWaste([:]) }),
            ("markNotBusiness", "orders", "edit", { await shop.markNotBusiness([job]) }),
        ]
    }

    @Test("every writer refuses nobody signed in, a viewer always, an operator where the matrix says")
    func matrixOverWriters() async throws {
        let shop = await Self.shop()
        let rbac = try #require(shop.rbac)
        for who in [nil, ("OP-v", "4444", "viewer"), ("OP-x", "3333", "operator"), ("OP-o", "1111", "owner")] as [(String, String, String)?] {
            shop.lockNow()
            if let who { #expect(await shop.signIn(who.0, pin: who.1) == .ok) }
            for w in Self.writers(shop) {
                shop.moveProblem = nil
                await w.run()
                let allowed = who.map { rbac.can(role: $0.2, area: w.area, action: w.action, lockEnabled: true) } ?? false
                #expect(Self.refused(shop) == !allowed,
                        Comment(rawValue: "\(who?.2 ?? "nobody") / \(w.name) [\(w.area)/\(w.action)]: \(shop.moveProblem ?? "-")"))
            }
        }
    }

    @Test("the undo stack does not survive Lock or a change of person")
    func undoIsThePersons() async {
        let shop = await Self.shop()
        let undo = UndoManager()
        undo.groupsByEvent = false
        shop.undoManager = undo
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: shop) { _ in }
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        shop.lockNow()
        #expect(!undo.canUndo, "an owner's undo was left for whoever walked up")
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: shop) { _ in }
        undo.endUndoGrouping()
        #expect(await shop.signIn("OP-x", pin: "3333") == .ok)
        #expect(!undo.canUndo)
    }

    @Test("the last owner cannot be demoted, deactivated or removed while the lock is on")
    func lastOwnerStays() async throws {
        let shop = await Self.shop()
        #expect(await shop.signIn("OP-o", pin: "1111") == .ok)
        let noura = try #require(shop.shopOperator("OP-o"))
        #expect(shop.leavesNoOwner("OP-o", stillOwner: false))
        #expect(!shop.leavesNoOwner("OP-o", stillOwner: true))
        #expect(!shop.leavesNoOwner("OP-m", stillOwner: false), "a manager is not the last owner")
        var demoted = noura.fields
        demoted.roleKey = "manager"
        await shop.saveOperator(id: "OP-o", demoted, opened: noura.fields)
        #expect(shop.moveProblem == shop.words.callIt("mac.lock_last_owner"))
        var inactive = noura.fields
        inactive.active = false
        await shop.saveOperator(id: "OP-o", inactive, opened: noura.fields)
        #expect(shop.moveProblem == shop.words.callIt("mac.lock_last_owner"))
        _ = await shop.deleteOperator("OP-o")
        #expect(shop.moveProblem == shop.words.callIt("mac.lock_last_owner"))
        #expect(shop.lockInForce)
    }

    @Test("wrong PINs count in a row: nine a minute for hours still closes the pad")
    func throttleIsConsecutive() async {
        let shop = await Self.shop()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        // Nine wrong, a pause longer than any cooldown, nine wrong, …
        var closed = false
        for _ in 0..<3 {
            for _ in 0..<9 {
                if case .coolingDown = await shop.signIn("OP-x", pin: "0000", now: now) { closed = true }
                now += 1
            }
            now += 3600
        }
        #expect(closed, "the windowed bucket let 9 guesses a minute through for ever")
        // A right PIN, once open again, clears the count.
        now += 3600
        #expect(await shop.signIn("OP-x", pin: "3333", now: now) == .ok)
        #expect(shop.lockFailures().count == 0)
    }

    @Test("switched on but not yet read is closed, not open")
    func failsClosed() async {
        let shop = await Self.shop()
        #expect(shop.lockSwitchedOn)
        shop.lockReady = false
        #expect(shop.lockInForce)
        #expect(shop.needsSignIn)
        #expect(!shop.lockAllows("orders", "view"))
    }

    @Test("a PBKDF2 hash that cannot verify is not a PIN that is set")
    func strictHashFormat() {
        let good = "p2$1000$" + String(repeating: "ab", count: 16) + "$" + String(repeating: "cd", count: 32)
        #expect(PinHash.isPbkdf2(good))
        for bad in ["p2$200000$aa$b", "p2$200000$aa$", "p2$200000$a$cd", "p2$1000$ＡＢ$cd", "p2$x$aa$cd"] {
            #expect(!PinHash.isPbkdf2(bad), Comment(rawValue: bad))
        }
    }
}
