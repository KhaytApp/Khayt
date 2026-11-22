import Foundation
import Testing
@testable import KhaytCore

struct ShopFieldsTests {
    @Test("each field is its English spelling, else its Arabic, else empty — never the name for another field")
    func document() {
        let settings: [String: JSONValue] = [
            "bizEn": .string("Atlas Prints"), "bizAr": .string("أطلس"),
            "addrEn": .string(""), "addrAr": .string("الرياض"),
            "taglineEn": .number(3),
        ]
        let d = ShopFields.document(settings)
        #expect(d["biz"] == .string("Atlas Prints"))
        #expect(d["addr"] == .string("الرياض"))
        #expect(d["tagline"] == .string(""))
        #expect(d["footer"] == .string(""))
        #expect(d.count == 4)
    }
}
