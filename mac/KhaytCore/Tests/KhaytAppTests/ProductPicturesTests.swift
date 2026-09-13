import Foundation
import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// A product's pictures — more than one, and each saying what it IS.
///
/// The catalogue held `imagePath` and `thumbnail`: one file and one data URI.
/// A shop selling a printed part had a single slot for a render, a photo of the
/// real thing, a scale shot and a detail of the finish, and had to choose.
///
/// ── WHAT IS ACTUALLY AT RISK ──────────────────────────────────────────────
///
/// Not the list. The MIGRATION. A product can arrive in three states, all of
/// which exist in real stores: saved before this feature (legacy fields only),
/// saved after it (the array), and BOTH, because an older build edited a record
/// a newer one wrote. "The array wins where both disagree, except when it is
/// empty" is the rule — and the exception has teeth, because an empty array
/// beside a set `imagePath` means two opposite things depending on how it got
/// that way.
///
/// The second risk is the FILENAME, which is checked here against the regex in
/// `main.js` rather than against my reading of it. Both apps write into one
/// folder beside one book; spell the name differently and one app records a
/// path the other cannot open.
@MainActor
struct ProductPicturesTests {

    static func product(_ id: String = "PROD-1",
                        images: [[String: JSONValue]]? = nil,
                        imagePath: String? = nil,
                        thumbnail: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "nameEn": .string("Bracket")]
        if let images { o["images"] = .array(images.map { .object($0) }) }
        if let imagePath { o["imagePath"] = .string(imagePath) }
        if let thumbnail { o["thumbnail"] = .string(thumbnail) }
        return .object(o)
    }

    static func image(_ id: String, path: String = "", thumb: String = "data:image/jpeg;base64,AA",
                      kind: String = "render") -> [String: JSONValue] {
        ["id": .string(id), "path": .string(path), "thumbnail": .string(thumb),
         "kind": .string(kind), "caption": .string("")]
    }

    // MARK: - The migration

    @Test("a product saved before this feature keeps its one picture")
    func legacyMigrates() async throws {
        let engine = try KhaytEngine()
        let read = try await engine.productPictures(
            of: Self.product(imagePath: "PROD-1.jpeg", thumbnail: "data:image/jpeg;base64,AA"))
        #expect(read.images.count == 1, "the only picture a shop had was dropped")
        #expect(read.images.first?.path == "PROD-1.jpeg")
        // UNLABELLED arrives as a render, and the rule says why: claiming it
        // shows a real printed part would be inventing a fact about a photo
        // nobody described, and that is the claim that can mislead a customer.
        #expect(read.images.first?.kind == "render")
    }

    @Test("the array wins over the legacy fields when they disagree")
    func arrayWins() async throws {
        // A record an older build touched after a newer one saved it: the
        // legacy pair names the picture that build could see, the array holds
        // all three.
        let engine = try KhaytEngine()
        let read = try await engine.productPictures(of: Self.product(
            images: [Self.image("A", path: "a.jpeg"), Self.image("B", path: "b.jpeg"),
                     Self.image("C", path: "c.jpeg")],
            imagePath: "b.jpeg", thumbnail: "data:image/jpeg;base64,BB"))
        #expect(read.images.count == 3, "the richer record lost to the legacy pair")
        // And the legacy view is rewritten from the array, not left as it was.
        #expect(read.imagePath == "a.jpeg",
                Comment(rawValue: "imagePath is \(read.imagePath), not images[0]"))
    }

    @Test("an EMPTY array beside a legacy path is an unmigrated product, not an empty one")
    func emptyArrayIsNotEmptiness() async throws {
        // The exception with teeth. An older build that drops a picture writes
        // an empty array and leaves imagePath set — so here, "empty" means
        // "this record has not been migrated", and the picture is recovered.
        let engine = try KhaytEngine()
        let read = try await engine.productPictures(
            of: Self.product(images: [], imagePath: "PROD-1.jpeg",
                             thumbnail: "data:image/jpeg;base64,AA"))
        #expect(read.images.count == 1,
                "a product whose array an old build emptied lost its picture for good")
    }

    @Test("a picture with neither a file nor a thumbnail is not a picture")
    func hollowEntriesAreDropped() async throws {
        let engine = try KhaytEngine()
        let read = try await engine.productPictures(of: Self.product(
            images: [Self.image("A", path: "a.jpeg"),
                     ["id": .string("B"), "path": .string(""), "thumbnail": .string("")]]))
        #expect(read.images.count == 1, "an entry pointing at nothing was kept")
    }

    // MARK: - Changing them

    @Test("promoting a picture rewrites what the storefront reads")
    func makePrimaryRewritesTheView() async throws {
        // The first picture is what the grid, the storefront and the invoice
        // use, so promoting one has to move the legacy pair with it — those are
        // the fields those screens actually read.
        let engine = try KhaytEngine()
        let moved = try await engine.makeProductImagePrimary(
            Self.product(images: [Self.image("A", path: "a.jpeg", thumb: "data:image/jpeg;base64,AA"),
                                  Self.image("B", path: "b.jpeg", thumb: "data:image/jpeg;base64,BB")]),
            id: "B")
        let read = try await engine.productPictures(of: moved)
        #expect(read.images.first?.id == "B", "the promoted picture is not first")
        #expect(read.imagePath == "b.jpeg",
                "the storefront would still show the old picture")
        #expect(read.thumbnail == "data:image/jpeg;base64,BB")
        #expect(read.images.count == 2, "promoting a picture lost one")
    }

    @Test("removing the LAST picture does not resurrect it")
    func removingTheLastOne() async throws {
        // THE BUG THIS GUARDS, and the module's own comment calls it
        // catastrophic. `normalise` treats an empty array beside a set
        // imagePath as unmigrated — which is right on load and wrong after a
        // delete, where it would rebuild the array from the field pointing at
        // the file just unlinked. The rule clears the legacy pair in the same
        // breath, and only a test that removes the LAST one can see it: with
        // two pictures, images[0] still exists and papers over the whole thing.
        let engine = try KhaytEngine()
        let out = try await engine.removeProductImage(
            Self.product(images: [Self.image("A", path: "a.jpeg")],
                         imagePath: "a.jpeg", thumbnail: "data:image/jpeg;base64,AA"),
            id: "A")
        #expect(out.removed?.path == "a.jpeg", "the caller was not told which file to unlink")

        let read = try await engine.productPictures(of: out.product)
        #expect(read.images.isEmpty,
                "the deleted picture came back from the legacy field")
        #expect(read.imagePath.isEmpty, "imagePath still names an unlinked file")
    }

    @Test("removing a picture that is not there changes nothing")
    func removingAGhost() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.removeProductImage(
            Self.product(images: [Self.image("A", path: "a.jpeg")]), id: "ZZ")
        #expect(out.removed == nil)
        #expect(try await engine.productPictures(of: out.product).images.count == 1)
    }

    @Test("an unknown kind is refused, and the refusal reaches Swift")
    func unknownKindRefused() async throws {
        // "Unknown kinds are refused rather than stored." A refusal that
        // arrived as silence would look exactly like a picker that did nothing.
        let engine = try KhaytEngine()
        let product = Self.product(images: [Self.image("A", path: "a.jpeg")])

        let bad = try await engine.setProductImageKind(product, id: "A", kind: "photograph")
        #expect(!bad.changed, "an invented kind was accepted")
        #expect(try await engine.productPictures(of: bad.product).images.first?.kind == "render")

        let good = try await engine.setProductImageKind(product, id: "A", kind: "print")
        #expect(good.changed)
        #expect(try await engine.productPictures(of: good.product).images.first?.kind == "print")
    }

    @Test("the kinds come from the rule, with the one that earns the feature in them")
    func kindsCrossOver() async throws {
        let engine = try KhaytEngine()
        let kinds = try await engine.productImageKinds()
        #expect(kinds.count >= 2)
        #expect(kinds.contains { $0.key == "print" },
                "there is no way to say a picture is of the real printed part")
        // A render is first because it is usually what exists first, and an
        // unlabelled picture defaults to the claim that cannot mislead.
        #expect(kinds.first?.key == "render", "the default kind is no longer a render")
        #expect(kinds.allSatisfy { !$0.label.isEmpty && !$0.hint.isEmpty },
                "a kind with no words is a menu item nobody can choose between")
    }

    @Test("does this listing show the real thing?")
    func realPhoto() async throws {
        let engine = try KhaytEngine()
        #expect(!(try await engine.productHasRealPhoto(
            Self.product(images: [Self.image("A", path: "a.jpeg", kind: "render")]))))
        #expect(try await engine.productHasRealPhoto(
            Self.product(images: [Self.image("A", path: "a.jpeg", kind: "render"),
                                  Self.image("B", path: "b.jpeg", kind: "print")])))
    }

    // MARK: - The file on disk

    /// `main.js`, verbatim:
    ///
    ///     const safeId  = path.basename(String(productId || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
    ///     const safeImg = path.basename(String(imageId   || '')).replace(/[^a-zA-Z0-9_-]/g, '_');
    ///     const filename = safeImg ? `${safeId}-${safeImg}.${ext}` : `${safeId}.${ext}`;
    ///
    /// ── THESE ARE NODE'S ANSWERS, NOT A SWIFT RE-IMPLEMENTATION ───────────
    ///
    /// The first version of this test built the expected string with a Swift
    /// copy of the regex above and compared the two — which is a tautology: the
    /// copy and the implementation were the same code, so it passed while both
    /// were wrong. Every string on the right is what `node` printed when the
    /// real function was run on the left.
    ///
    /// It was worth doing. The last two cases FAILED, and the bug was real: a
    /// JavaScript regex replaces per UTF-16 code unit and a Swift `Character`
    /// is a grapheme cluster, so an accented or emoji product name produced a
    /// different filename in each app — one recording a path the other could
    /// not open, in a folder both write to.
    @Test("the filename is spelled exactly as the other app spells it")
    func filenameMatchesElectron() {
        let cases: [(product: String, image: String, expected: String)] = [
            ("PROD-abc123", "PIMG-PRODabc123-0", "PROD-abc123-PIMG-PRODabc123-0.jpeg"),
            // No image id: the shape a single-picture product saved before this
            // feature already has on disk, which must keep working untouched.
            ("PROD-abc123", "", "PROD-abc123.jpeg"),
            ("Coffee dallah stand", "PIMG-x-2", "Coffee_dallah_stand-PIMG-x-2.jpeg"),
            ("PROD.abc", "PIMG-x-4", "PROD_abc-PIMG-x-4.jpeg"),
            // A Saudi shop naming a product in its own language: eleven
            // characters, eleven underscores.
            ("\u{0642}\u{0627}\u{0639}\u{062F}\u{0629} \u{0627}\u{0644}\u{062F}\u{0644}\u{0629}",
             "PIMG-x-1", "___________-PIMG-x-1.jpeg"),
            ("PROD/../../etc/passwd", "PIMG-x-3", "passwd-PIMG-x-3.jpeg"),
            // THE TWO THAT CAUGHT THE BUG. "e" + a combining acute is ONE
            // grapheme and TWO UTF-16 units, so the ASCII "e" survives and only
            // the mark is replaced; an emoji is a surrogate pair and becomes
            // two underscores, not one.
            ("Cafe\u{0301}", "PIMG-1", "Cafe_-PIMG-1.jpeg"),
            ("Part \u{1F525}", "PIMG-1", "Part___-PIMG-1.jpeg"),
        ]
        for c in cases {
            let got = ProductPhotos.filename(productId: c.product, imageId: c.image)
            #expect(got == c.expected,
                    Comment(rawValue: "\(c.product) + \(c.image) → \(got), node says \(c.expected)"))
        }
    }

    @Test("a product id that walks up the tree cannot")
    func noEscapingTheFolder() {
        // `basename` FIRST and then the substitution, in that order. Reversed,
        // "../../x" becomes ".._.._x" — harmless-looking, and a different name
        // from the one the other app writes, which is its own bug.
        let name = ProductPhotos.filename(productId: "../../../etc/passwd", imageId: "PIMG-1")
        #expect(!name.contains("/"), Comment(rawValue: name))
        #expect(!name.contains(".."), Comment(rawValue: name))
        #expect(name == "passwd-PIMG-1.jpeg", Comment(rawValue: name))
    }

    // MARK: - Scaling

    /// A solid colour at a given size, as a source file would arrive.
    static func made(_ w: Int, _ h: Int, alpha: Bool = false) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast
                                               : CGImageAlphaInfo.noneSkipLast).rawValue)
        else { return nil }
        // Transparent where alpha is wanted: the whole point is what happens to
        // it, and JPEG cannot carry it.
        if !alpha {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        return ctx.makeImage()
    }

    @Test("a big picture is scaled down on its longest side")
    func scalesDown() throws {
        let source = try #require(Self.made(2400, 1200))
        let data = try #require(ProductPhotos.jpeg(source, maxDim: 240, quality: 0.85))
        let out = try #require(NSImage(data: data))
        // 2400 is the longest side, so 240/2400 = 0.1 both ways.
        #expect(Int(out.size.width) == 240, Comment(rawValue: "width \(out.size.width)"))
        #expect(Int(out.size.height) == 120, Comment(rawValue: "height \(out.size.height)"))
    }

    @Test("a small picture is NOT blown up")
    func neverEnlarges() throws {
        // `min(1, …)`, as the canvas does. Without it a 200px photo becomes a
        // 1600px one that looks worse than the file the shop handed over, and
        // is eight times the size on disk.
        let source = try #require(Self.made(200, 150))
        let data = try #require(ProductPhotos.jpeg(source, maxDim: 1600, quality: 0.88))
        let out = try #require(NSImage(data: data))
        #expect(Int(out.size.width) == 200, Comment(rawValue: "width \(out.size.width)"))
        #expect(Int(out.size.height) == 150)
    }

    @Test("transparency is flattened onto WHITE, not onto black")
    func alphaBecomesWhite() throws {
        // JPEG has no alpha. A transparent PNG encoded straight comes out on
        // black, which is what the canvas's fillRect prevents and what this
        // has to prevent too — a shop's cut-out product photo arriving as a
        // silhouette on a black square is the visible version of this bug.
        let source = try #require(Self.made(100, 100, alpha: true))
        let data = try #require(ProductPhotos.jpeg(source, maxDim: 100, quality: 0.9))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let corner = try #require(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(corner.redComponent > 0.95 && corner.greenComponent > 0.95
                && corner.blueComponent > 0.95,
                Comment(rawValue: "transparent pixels came out at \(corner)"))
    }

    @Test("a one-pixel picture survives being scaled")
    func neverZeroSized() throws {
        // `max(1, …)`. A 1x400 banner scaled to 240 rounds its short side to 0,
        // and a zero-width CGContext is nil rather than an error you can read.
        let source = try #require(Self.made(1, 400))
        let data = try #require(ProductPhotos.jpeg(source, maxDim: 240, quality: 0.85),
                                "a very thin picture produced no JPEG at all")
        let out = try #require(NSImage(data: data))
        #expect(out.size.width >= 1 && out.size.height >= 1)
    }

    // MARK: - Staging

    @Test("a staged picture writes the five fields the rule reads, and not the bytes")
    func stagedRecordShape() throws {
        let staged = StagedPicture(id: "PIMG-1", kind: "print", caption: "On a desk",
                                   thumbnail: "data:image/jpeg;base64,AA", path: "a.jpeg",
                                   bytes: Data([1, 2, 3]))
        guard case .object(let o) = staged.record() else {
            Issue.record("a staged picture did not encode as a record"); return
        }
        #expect(Set(o.keys) == ["id", "path", "thumbnail", "kind", "caption"],
                Comment(rawValue: "the record carries \(Set(o.keys).sorted())"))
        // The bytes are this app's business on the way to disk. In the book
        // they would be a megabyte of base64 per picture, duplicated.
        #expect(o["bytes"] == nil, "the full-size JPEG was about to be written into the book")
    }
}

/// That any of it is REACHED.
///
/// Every test above passes against a correct module wired to nothing — this
/// project's recurring failure. Delete a call and one of these fails.
@MainActor
struct ProductPictureWiringTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        return try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    @Test("the product sheet shows the strip, loads through the rule, and saves what it holds")
    func theSheetIsWired() throws {
        let sheet = try Self.source("ProductSheet.swift")
        #expect(sheet.contains("ProductPictureStrip(shop: shop"),
                "the product sheet does not draw the pictures")
        // Through the shared rule, never by reading `images` off the record —
        // that is where the migration lives.
        #expect(sheet.contains("await shop.pictures(of:"),
                "the sheet reads pictures without the migration")
        #expect(sheet.contains("pictures: staged"),
                "the sheet collects pictures and never saves them")
        #expect(sheet.contains("unlinking: unlink"),
                "removed pictures are never unlinked, so the folder only grows")
    }

    @Test("nothing reaches the products folder before the record is written")
    func unlinkComesLast() throws {
        // Cancelling must leave every picture where it was, so the unlink is
        // after the write and not in the sheet at all.
        let shop = try Self.source("Shop.swift")
        let writeAt = try #require(shop.range(of: "registerMoveUndo(undo, named: words.callIt(\"mac.edit_product\"))")?.lowerBound)
        let unlinkAt = try #require(shop.range(of: "ProductPhotos.delete(path, in: build)")?.lowerBound,
                                    "nothing ever unlinks a removed picture")
        #expect(writeAt < unlinkAt, "pictures are unlinked before the record is safely written")
        #expect(!(try Self.source("ProductPictures.swift").contains("ProductPhotos.delete")),
                "the strip deletes files itself, so cancelling the sheet loses them")
    }
}
