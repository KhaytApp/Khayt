import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Writing the messages a shop sends its customers.
///
/// `MessageSheet` has always READ `waTemplates` and this Mac could not write
/// one, so a book carrying none opened the sheet to an empty picker with
/// nothing to explain it.
@MainActor
struct MessageTemplateEditTests {

    @Test("the placeholders offered are the ones the rule replaces")
    func placeholdersAreTheRule() {
        // A placeholder this app offers that `fill` does not replace reaches a
        // customer as its own text. So the sheet draws the rule's list rather
        // than one typed beside it.
        let filled = WaTemplate.fill(
            WaTemplate.placeholders.map { "{{\($0)}}" }.joined(separator: "|"),
            values: Dictionary(uniqueKeysWithValues: WaTemplate.placeholders.map { ($0, "X") }))
        #expect(!filled.contains("{{"), Comment(rawValue: "left unreplaced: \(filled)"))
        #expect(filled == Array(repeating: "X", count: WaTemplate.placeholders.count)
            .joined(separator: "|"))
    }

    @Test("both fields are required, in the other app's own words")
    func bothFieldsRequired() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // The sample book refuses every write; what is pinned here is that the
        // refusal for a blank field is the FIELD's refusal, not the book's.
        shop.saveTemplate(id: nil, name: "  ", body: "hello")
        #expect(shop.writeProblem == shop.words.callIt("wa.tpl_need_name"))
        shop.saveTemplate(id: nil, name: "Ready", body: "   ")
        #expect(shop.writeProblem == shop.words.callIt("wa.tpl_need_body"))
    }

    @Test("the sample shop is told it cannot, rather than failing quietly")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let before = shop.messageTemplates.count
        shop.saveTemplate(id: nil, name: "Ready", body: "Your order {{id}} is ready")
        #expect(shop.writeProblem == shop.words.callIt("mac.move_sample"))
        #expect(shop.messageTemplates.count == before, "the sample took a template")
    }

    @Test("a new template gets an id in the other app's shape")
    func idShape() {
        // `uid('WATPL')` — a template made here has to look like one made
        // there to anything that sorts or dedupes ids.
        let id = Shop.uid("WATPL")
        #expect(id.hasPrefix("WATPL-"), Comment(rawValue: id))
        #expect(Shop.uid("WATPL") != Shop.uid("WATPL"))
    }

    @Test("the sample book's own templates read back through the rule")
    func sampleTemplatesLoad() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(!shop.messageTemplates.isEmpty,
                "the sample book carries templates and none was read")
        for template in shop.messageTemplates {
            #expect(!template.id.isEmpty)
            #expect(!template.body.isEmpty, "a template that sends nothing is on the list")
        }
    }

    @Test("the editor and the empty state are on the shells that ship")
    func wiredIn() throws {
        // The recurring Mac bug is a view added only to the retired shell, and
        // the recurring bug everywhere is a correct rule with no caller.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        func read(_ name: String) throws -> String {
            try String(contentsOf: sources.appending(path: name), encoding: .utf8)
        }
        #expect(try read("SettingsWindow.swift").contains("TemplateSheet(shop: shop"),
                "nothing raises the template editor")
        #expect(try read("Integrations.swift").contains("TemplatesSection(shop: shop)"),
                "nothing draws the template list")
        #expect(try read("MessageSheet.swift").contains("wa.no_templates"),
                "the empty picker still says nothing")
    }
}
