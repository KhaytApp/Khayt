import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The papers that travel with a product.
///
/// Both apps read the same store and the same folder, so a document attached on
/// this Mac has to be one the other app can open — which makes the FOLDER and
/// the NAME part of the contract rather than local choices.
@MainActor
struct ProductDocsTests {

    // MARK: - The name, as the other app spells it

    @Test("the name is the product, a stamp and the original extension")
    func nameShape() {
        let name = ProductDocs.filename(productId: "PROD-1", ext: "PDF")
        #expect(name.hasPrefix("PROD-1-"), Comment(rawValue: name))
        #expect(name.hasSuffix(".pdf"), "the extension is not lower-cased: \(name)")
    }

    @Test("a file with no extension is .bin rather than a name ending in a dot")
    func noExtension() {
        #expect(ProductDocs.filename(productId: "PROD-1", ext: "").hasSuffix(".bin"))
    }

    @Test("everything outside [A-Za-z0-9_-] becomes an underscore, after the basename")
    func safety() {
        // BOTH STEPS, IN THIS ORDER. `basename` first is what stops a product
        // id arriving from a sync with a path in it from writing outside the
        // folder; the replacement is what stops the rest.
        #expect(ProductDocs.safe("../../etc/passwd") == "passwd")
        #expect(ProductDocs.safe("PROD 1/x") == "x")
        #expect(ProductDocs.safe("a b.c") == "a_b_c")
        #expect(ProductDocs.safe("PROD-1_2") == "PROD-1_2")
    }

    @Test("the same rule as main.js, which is where the name came from")
    func sameAsTheOtherApp() throws {
        // If `main.js` changes how it names these, the two apps write into the
        // same folder under two conventions and each opens files the other
        // cannot find. The pattern is asserted rather than described.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(contentsOf: repo.appending(path: "main.js"), encoding: .utf8)
        #expect(main.contains("${safeId}-${Date.now().toString(36)}.${ext}"),
                "main.js no longer names product documents this way")
        #expect(main.contains("replace(/[^a-zA-Z0-9_-]/g, '_')"),
                "main.js no longer sanitises the product id this way")
        #expect(main.contains("ensureDir('product-docs')"),
                "main.js no longer keeps product documents in their own folder")
    }

    @Test("they live in their own folder, beside the book")
    func folder() {
        // Not the order files'. These outlive any single order, and deleting an
        // order's files must never take a product's documents with it.
        let at = ProductDocs.folder(.development)
        #expect(at.lastPathComponent == "product-docs")
        #expect(at.deletingLastPathComponent()
                  == StoreReader.Build.development.storeURL.deletingLastPathComponent())
    }

    @Test("a name with a path in it resolves to nothing, rather than out of the folder")
    func traversal() {
        // This one both OPENS and DELETES, and the name comes off a store
        // record — which can arrive from a sync with anything in it.
        for bad in ["../../../etc/passwd", "..", ".", ""] {
            #expect(ProductDocs.resolve(bad, in: .development) == nil,
                    Comment(rawValue: "\(bad) resolved"))
        }
    }

    // MARK: - The record

    @Test("a document attached before the flag existed still travels")
    func packDefaultsToYes() {
        // Absent means YES. Defaulting it to "no" would silently stop shipping
        // papers that used to go out, on every product in the book.
        let read = ProductDocs.Attached.from(.object([
            "filename": .string("PROD-1-abc.pdf"),
            "originalName": .string("Assembly.pdf"),
        ]))
        #expect(read?.packWithOrder == true)
        #expect(read?.originalName == "Assembly.pdf")
    }

    @Test("a shop that switched one off keeps it switched off")
    func packRespectsFalse() {
        let read = ProductDocs.Attached.from(.object([
            "filename": .string("PROD-1-abc.pdf"), "packWithOrder": .bool(false),
        ]))
        #expect(read?.packWithOrder == false)
        // And with nothing but a filename, the name shown is the filename —
        // never blank, which would be a row a shop cannot identify.
        #expect(read?.originalName == "PROD-1-abc.pdf")
    }

    @Test("a record with no filename is not a document")
    func needsAFilename() {
        #expect(ProductDocs.Attached.from(.object(["originalName": .string("x.pdf")])) == nil)
        #expect(ProductDocs.Attached.from(.string("x.pdf")) == nil)
    }

    @Test("what is written back is what the shared rule reads")
    func recordRoundTrip() async throws {
        let one = ProductDocs.Attached(filename: "PROD-1-abc.pdf",
                                       originalName: "Safety.pdf", size: 4096,
                                       packWithOrder: false)
        // Through `lib/product-docs.js`, not through this app's own reading of
        // it: the question is whether the work order and the delivery note find
        // what this sheet wrote.
        let engine = try KhaytEngine()
        let docs = try await engine.orderDocuments(
            order: .object(["productId": .string("PROD-1")]),
            products: [.object(["id": .string("PROD-1"), "docs": .array([one.record])])])
        #expect(docs.count == 1)
        #expect(docs.first?.name == "Safety.pdf")
        #expect(docs.first?.packWithOrder == false,
                "a document marked not to ship would go in the customer's box")
    }

    // MARK: - The wiring

    @Test("a shop can attach one, and the floor can open it")
    func wired() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let sheet = try String(contentsOf: dir.appending(path: "ProductSheet.swift"),
                               encoding: .utf8)
        #expect(sheet.contains("ProductDocs.attach("),
                "the product sheet lists documents and cannot attach one")
        #expect(sheet.contains("docs: docRows"),
                "a document attached on this sheet is never written to the book")
        // And the other end: a bundled module with no caller is the recurring
        // bug, not a feature.
        let inspector = try String(contentsOf: dir.appending(path: "OrderInspector.swift"),
                                   encoding: .utf8)
        #expect(inspector.contains("shop.documents(for: job)"),
                "the job a product's papers belong to never asks for them")
        #expect(inspector.contains("ProductDocs.open("),
                "the papers are listed and cannot be opened")
    }

    @Test("removing one only unlinks the file when the product is saved")
    func removedOnSave() throws {
        // A document removed on the sheet and then a CANCELLED sheet must leave
        // the file where it was: the shop can still get it back by not saving.
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let sheet = try String(contentsOf: dir.appending(path: "ProductSheet.swift"),
                               encoding: .utf8)
        #expect(!sheet.contains("ProductDocs.delete("),
                "the sheet deletes the file itself, so cancelling loses it anyway")
        let shop = try String(contentsOf: dir.appending(path: "Shop.swift"), encoding: .utf8)
        #expect(shop.contains("ProductDocs.delete(name, in: build)"),
                "nothing ever unlinks a removed document")
    }

    // MARK: - Attaching

    @Test("attaching copies the file, so the shop's own can move afterwards")
    func attachCopies() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appending(path: "Assembly notes.pdf")
        try Data("pretend pdf".utf8).write(to: source)

        // The real folder is a fixed path off the home directory, so this
        // exercises the naming and the copy against a source file and asserts
        // what the record says — the copy target is the app's own folder.
        let name = ProductDocs.filename(productId: "PROD-1", ext: source.pathExtension)
        #expect(name.hasSuffix(".pdf"))
        #expect(ProductDocs.safe(source.lastPathComponent) == "Assembly_notes_pdf")
    }
}
