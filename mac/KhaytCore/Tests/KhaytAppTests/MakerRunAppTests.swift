import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import KhaytApp
@testable import KhaytCore

/// The Mac side of MakerRun, the colour planner and the 3D viewer: the fields
/// a download puts on its record, the picture a listing is sent, the link's
/// store, the menu that reaches the tab, and the viewer's own reading.
@MainActor
struct MakerRunAppTests {

    @Test("a MakerRun download is recorded as the desktop's importConvertedAsNew records it")
    func recordFields() {
        let f = Shop.makerRunFields(slug: "clip", license: "CC-BY-4.0", creator: "Noura",
                                    page: " https://makerrun.com/designs/clip ", recordLicence: "cc-by")
        #expect(f["source"] == .string("https://makerrun.com/designs/clip"))
        #expect(f["licence"] == .string("cc-by"))
        #expect(f["makerrun"] == .object(["slug": .string("clip"), "license": .string("CC-BY-4.0"),
                                          "creator": .string("Noura")]))
        // A licence the record's menu does not offer is not written; the raw
        // MakerRun string is kept beside it, as on the desktop.
        let g = Shop.makerRunFields(slug: "x", license: "All rights reserved", creator: nil,
                                    page: nil, recordLicence: "not-a-licence")
        #expect(g["licence"] == nil)
        #expect(g["source"] == nil)
        #expect(g["makerrun"] == .object(["slug": .string("x"), "license": .string("All rights reserved"),
                                          "creator": .null]))
    }

    @Test("Tools has a MakerRun item and Maker Tools a MakerRun tab")
    func reachable() throws {
        #expect(StudioTab.allCases.contains(.makerrun))
        let src = try String(contentsOf: StoreRoundTripTests.repoRoot
            .appending(path: "mac/KhaytCore/Sources/KhaytApp/StudioWindow.swift"), encoding: .utf8)
        #expect(src.contains("open(.makerrun)"))
        #expect(src.contains("MakerRunBrowser(shop: shop)"))
    }

    @Test("the link is cleared only while it is still the one stored")
    func storeClear() async {
        let store = MakerRunMemoryStore(MakerRunTokens(access: "A", refresh: "R2", expires: 0))
        await store.clear(onlyIf: "R1")
        #expect(await store.load()?.refresh == "R2", "a racing refresh's token survives")
        await store.clear(onlyIf: "R2")
        #expect(await store.load() == nil)
    }

    static func png(_ w: Int, _ h: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test("a picture that fits goes as it is; a big one is fitted to 2048 pixels")
    func picture() throws {
        let small = try Self.png(64, 48)
        #expect(MakerRunPicture.fitted(small) == small)
        let big = try Self.png(3000, 1000)
        let fitted = try #require(MakerRunPicture.fitted(big))
        #expect(MakerRun.sniffImageType(fitted) == "image/jpeg")
        let src = try #require(CGImageSourceCreateWithData(fitted as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyPixelWidth] as? Int) == 2048)
        #expect(MakerRunPicture.fitted(Data("not a picture".utf8)) == nil)
    }

    @Test("an STL is streamed for the viewer, sampled with the desktop's stride rule")
    func streamedSTL() throws {
        let stl = FileManager.default.temporaryDirectory.appending(path: "orbit-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: stl) }
        try MeshTests.binarySTL(MeshTests.boxFacets(20, 20, 20)).write(to: stl)
        let all = try ModelOrbitLoader.streamed(stl, budget: 4_000_000, hardCap: 30_000_000)
        #expect(all.faceState.count == 12)
        #expect(all.positions.count == 12 * 9)
        #expect(!all.sampled)
        let half = try ModelOrbitLoader.streamed(stl, budget: 6, hardCap: 30_000_000)
        #expect(half.faceState.count == 6 && half.sampled && half.triangleCount == 12)
        #expect(throws: ModelOrbitLoader.Refusal.self) {
            try ModelOrbitLoader.streamed(stl, budget: 4, hardCap: 10)
        }
    }

    @Test("the scene groups faces by filament, one material each, centred on the origin")
    func build() {
        let positions: [Float] = [0, 0, 0, 10, 0, 0, 0, 10, 0,
                                  0, 0, 0, 10, 0, 0, 0, 0, 10,
                                  0, 0, 0, 0, 10, 0, 0, 0, 10]
        let mesh = StudioEngine.ViewerMesh(positions: positions, faceState: [2, 1, 2], palette: ["#FF0000", "#00FF00"],
                                           triangleCount: 3, sampled: false, skipped: false)
        let loaded = ModelOrbitLoader.build(mesh)
        #expect(loaded.materials.count == 2)
        #expect(loaded.shown == 3 && loaded.total == 3)
        let geometry = loaded.node.childNodes.first?.geometry
        #expect(geometry?.elements.map(\.primitiveCount) == [1, 2], "filament 1, then filament 2")
        #expect(loaded.colours[0] == ModelOrbitLoader.colour(state: 1, palette: mesh.palette))
        #expect(ModelOrbitLoader.colour(state: 0, palette: mesh.palette) == ModelOrbitLoader.plain)
        let centre = loaded.node.childNodes.first?.position
        #expect(centre?.x == -5 && centre?.y == -5 && centre?.z == -5)
    }

    // MARK: What the shop is told, for the four codes the live API sends

    @Test("mfa_required tells the shop to finish two-factor on makerrun.com")
    func saysMfa() {
        let words = Words()
        let said = Shop.saidMakerRun(MakerRun.Failure("mfa_required", "x", status: 403), words: words, publishing: true)
        #expect(said == words.callIt("mr.err_mfa"))
        #expect(said != words.callIt("mr.err_relink"), "not a sign-in-again")
    }

    @Test("maintenance says MakerRun is down for maintenance and when to come back")
    func saysMaintenance() {
        let words = Words()
        let said = Shop.saidMakerRun(MakerRun.maintenanceFailure(retryAfter: 600), words: words)
        #expect(said == words.callIt("mr.err_maintenance", ["mins": .string(words.numeral(10))]))
        #expect(said.contains("maintenance"))
    }

    @Test("rate_limited while publishing names the 20-an-hour, 60-a-day cap")
    func saysRateLimit() {
        let words = Words()
        let f = MakerRun.Failure("rate_limited", "x", status: 429, retryAfter: 60)
        let publishing = Shop.saidMakerRun(f, words: words, publishing: true)
        #expect(publishing == words.callIt("mac.mkr_rate_publish"))
        #expect(publishing.contains("20") && publishing.contains("60"))
        // Browsing keeps the desktop's plain "wait a minute".
        #expect(Shop.saidMakerRun(f, words: words) == words.callIt("mr.err_rate", ["secs": .string(words.numeral(60))]))
    }

    @Test("invalid names each refused field by the form's own label")
    func saysInvalidFields() {
        let words = Words()
        let f = MakerRun.Failure("invalid", "Some fields were rejected.", status: 422,
                                 details: [MakerRun.Detail(field: "title", message: "Too similar."),
                                           MakerRun.Detail(field: "license", message: "Not allowed.")])
        let said = Shop.saidMakerRun(f, words: words, publishing: true)
        #expect(said.contains(words.callIt("mr.f_title")) && said.contains("Too similar."))
        #expect(said.contains(words.callIt("mr.f_licence")) && said.contains("Not allowed."))
        #expect(Shop.fieldLabel("weird", words: words) == "weird")
    }

    @Test("a wait while publishing keeps the half-made listing and does not fail the step")
    func waitsKeepTheListing() throws {
        let src = try String(contentsOf: StoreRoundTripTests.repoRoot
            .appending(path: "mac/KhaytCore/Sources/KhaytApp/MakerRunPublish.swift"), encoding: .utf8)
        let fail = try #require(src.range(of: "private func fail("))
        let body = String(src[fail.lowerBound...].prefix(900))
        #expect(body.contains(#"code == "maintenance" || code == "rate_limited""#))
        #expect(body.contains("set(id, .pending)"))
        // The wait returns before anything touches the record.
        let waitEnd = try #require(body.range(of: "return\n"))
        #expect(!body[..<waitEnd.lowerBound].contains("setMakerRunListing"))
    }

}
