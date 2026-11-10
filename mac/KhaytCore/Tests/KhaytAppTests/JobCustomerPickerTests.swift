import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The order editor's customer picker (Turki's option C, Nov 10): shut only
/// when the job is locked AND has a customer; a change is handed to the save
/// only when the shop made one; another currency is warned about.
@MainActor
struct JobCustomerPickerTests {

    @Test("the picker is shut only for a locked job that has a customer")
    func shut() {
        #expect(OrderDetailsSheet.customerShut(lock: "paid", openedWith: "C1"))
        #expect(!OrderDetailsSheet.customerShut(lock: "paid", openedWith: ""), "no customer → can always be given one")
        #expect(!OrderDetailsSheet.customerShut(lock: nil, openedWith: "C1"))
    }

    @Test("only a changed customer is handed to the save, and blank means none")
    func handed() {
        var a = OrderDetailsSheet.Form(); a.clientId = "C1"
        var b = a
        #expect(OrderDetailsSheet.customerChange(opened: a, now: b) == .none)
        b.clientId = "C2"
        #expect(OrderDetailsSheet.customerChange(opened: a, now: b) == .some("C2"))
        b.clientId = ""
        #expect(OrderDetailsSheet.customerChange(opened: a, now: b) == .some(nil))
        // The customer is not one of applyDetails' fields.
        #expect(OrderDetailsSheet.fields(opened: a, now: b)["clientId"] == nil)
    }

    @Test("another currency is flagged; blank is the shop's")
    func currency() {
        #expect(OrderDetailsSheet.currencyDiffers(job: "", shop: "SAR", client: "EUR"))
        #expect(!OrderDetailsSheet.currencyDiffers(job: "", shop: "SAR", client: ""))
        #expect(!OrderDetailsSheet.currencyDiffers(job: "EUR", shop: "SAR", client: "EUR"))
        #expect(!OrderDetailsSheet.currencyDiffers(job: "", shop: "SAR", client: nil))
    }

    @Test("the job's own customer stays offered even when it is not in the book")
    func keepsCurrent() {
        #expect(OrderDetailsSheet.customerChoices([], current: "C9").map(\.id) == ["C9"])
        #expect(OrderDetailsSheet.customerChoices([], current: "").isEmpty)
    }
}
