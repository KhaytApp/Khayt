import CoreGraphics
import Foundation
import ImageIO
import Network
import Testing
import KhaytCore
@testable import KhaytApp

/// The review before alpha.58: each finding, held.
@MainActor
struct Alpha58SecurityTests {

    // MARK: 1 — the shop's own network is not one visitor

    @Test("link-local, unique-local and on-link IPv6 visitors are keyed by their own address")
    func onLinkVisitorsAreSeparate() throws {
        let local = [try #require(LanOnLink.Prefix("2001:db8:5:6::", length: 64))]
        let key = { (r: String) in LanServer.throttleKey(r, onLink: local) }
        #expect(key("fe80::1%en0") != key("fe80::2%en0"), "every phone's Bonjour address was one visitor")
        #expect(key("fe80::1%en0") == key("fe80::1"), "the zone is not part of who it is")
        #expect(key("fd12:3456:789a:1::1") != key("fd12:3456:789a:1::2"))
        #expect(key("2001:db8:5:6::a") != key("2001:db8:5:6::b"), "the shop's own SLAAC /64")
        // A stranger's prefix is still one visitor, however many addresses it rotates through.
        #expect(key("2001:db8:7:8::a") == key("2001:db8:7:8:ffff::b"))
        #expect(key("2001:db8:7:8::a") != key("2001:db8:7:9::a"))
        #expect(key("::ffff:192.168.1.5") == "192.168.1.5")
        #expect(key("192.168.1.5") == "192.168.1.5")
        // A prefix too short to be a network is not taken as "on link".
        let wide = [try #require(LanOnLink.Prefix("2000::", length: 3))]
        #expect(LanServer.throttleKey("2001:db8:7:8::a", onLink: wide)
                == LanServer.throttleKey("2001:db8:7:8::b", onLink: wide))
    }

    @Test("a prefix holds the addresses inside it and no others")
    func prefixContains() throws {
        let p = try #require(LanOnLink.Prefix("2001:db8:5:6::", length: 64))
        let inside = [UInt8](try #require(IPv6Address("2001:db8:5:6:1234::9")).rawValue)
        let outside = [UInt8](try #require(IPv6Address("2001:db8:5:7::9")).rawValue)
        #expect(p.contains(inside))
        #expect(!p.contains(outside))
        let odd = try #require(LanOnLink.Prefix("2001:db8:5:6::", length: 60))
        #expect(odd.contains([UInt8](try #require(IPv6Address("2001:db8:5:f::1")).rawValue)))
        #expect(!odd.contains([UInt8](try #require(IPv6Address("2001:db8:5:10::1")).rawValue)))
    }

    @Test("ten wrong PINs from one phone on the Wi-Fi do not lock the owner's iPhone out")
    func linkLocalLockoutIsPerDevice() async throws {
        let server = try await LanSecurityReviewTests.server()
        for i in 0..<12 {
            _ = await server.respond(to: LanSecurityReviewTests.get(
                "/api/queue", from: "fe80::bad%en0", headers: ["x-khayt-pin": "wrong-\(i)"]))
        }
        let attacker = await server.respond(to: LanSecurityReviewTests.get(
            "/api/queue", from: "fe80::bad%en0", headers: ["x-khayt-pin": "24682468"]))
        #expect(attacker.status == 429, "the guesser itself is still locked out")
        let owner = await server.respond(to: LanSecurityReviewTests.get(
            "/api/queue", from: "fe80::1c2:3ff:fe04:506%en0", headers: ["x-khayt-pin": "24682468"]))
        #expect(owner.status == 200, "a neighbour's guesses locked the owner's phone out")
    }

    // MARK: 2 — the rollback mark is not the server's to lower

    @Test("a push answered at or below its own baseRev is refused, and the mark does not move")
    func pushReplyBelowBase() async throws {
        let memory = CloudReader.RevisionMemory(defaults: nil)
        memory.saw(CloudWriterTests.connection, rev: 40)
        await #expect(throws: CloudWriter.Failure.self) {
            _ = try await CloudWriter.send(CloudWriterTests.connection, token: "t",
                                           payload: CloudWriterTests.payload, dek: CloudWriterTests.dek,
                                           baseRev: 40, memory: memory,
                                           fetch: CloudWriterTests.answer(200, #"{"rev":1}"#))
        }
        #expect(memory.highest(CloudWriterTests.connection) == 40)
        await #expect(throws: CloudWriter.Failure.self) {
            _ = try await CloudWriter.sendWholeStore(CloudWriterTests.connection, token: "t", store: [:],
                                                     dek: CloudWriterTests.dek, baseRev: 40,
                                                     mergedFrom: CloudWriterTests.merged, memory: memory,
                                                     fetch: CloudWriterTests.answer(200, #"{"rev":40}"#))
        }
        #expect(memory.highest(CloudWriterTests.connection) == 40)
        // A genuine answer raises it.
        let sent = try await CloudWriter.send(CloudWriterTests.connection, token: "t",
                                              payload: CloudWriterTests.payload, dek: CloudWriterTests.dek,
                                              baseRev: 40, memory: memory,
                                              fetch: CloudWriterTests.answer(200, #"{"rev":41}"#))
        #expect(sent.rev == 41)
        #expect(memory.highest(CloudWriterTests.connection) == 41)
    }

    @Test("a whole-book push after a cloud reset keeps the mark until the shop trusts the older cloud")
    func resetNeedsTheShopsWord() async throws {
        let memory = CloudReader.RevisionMemory(defaults: nil)
        let c = CloudWriterTests.connection
        memory.saw(c, rev: 57)
        // The cloud was reset: nothing there, so the book goes up at baseRev 0 and comes back as rev 1.
        let sent = try await CloudWriter.sendWholeStore(c, token: "t", store: [:], dek: CloudWriterTests.dek,
                                                        baseRev: 0, mergedFrom: CloudWriterTests.merged,
                                                        memory: memory,
                                                        fetch: CloudWriterTests.answer(200, #"{"rev":1}"#))
        #expect(sent.rev == 1)
        #expect(memory.highest(c) == 57, "the server's own answer lowered the guard")
        #expect(memory.refusal(c) == 1, "the shop is not asked")
        #expect(memory.accept(c))
        #expect(memory.highest(c) == 1)
    }

    // MARK: 3 — a large body is refused from its head

    /// A request head promising `length` bytes and sending none; the status
    /// line that comes back. Anything but a quick refusal times out reading.
    nonisolated static func headOnly(port: UInt16, path: String, length: Int, extra: String = "") -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "no socket" }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { return "no connect" }
        let head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/octet-stream\r\n"
            + extra + "Content-Length: \(length)\r\n\r\n"
        let data = Data(head.utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        var tv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buf, 512)
        guard n > 0 else { return "no answer" }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }

    @Test("a 2 MB upload with no session, or with quoting off, is refused before a byte of it is read")
    func largeBodyRefusedFromTheHead() async throws {
        let bench = try await LanServerTests.Bench(intakeToken: "tok-58")
        defer { bench.stop() }
        let port = bench.port
        // Quoting is off in this book.
        let off = await offPool {
            Self.headOnly(port: port, path: "/api/intake/estimate?name=a.stl", length: 2 << 20,
                          extra: "X-Khayt-Intake-Token: tok-58\r\n")
        }
        #expect(off.hasPrefix("HTTP/1.1 403"), Comment(rawValue: off))
        #expect(off.contains(#""reason":"off""#), Comment(rawValue: off))
        // Quoting on, and nobody: no session, no token.
        bench.book.value = LanServerTests.quotingBook(bench.book.value)
        let stranger = await offPool {
            Self.headOnly(port: port, path: "/api/intake/estimate?name=a.stl", length: 2 << 20)
        }
        #expect(stranger.hasPrefix("HTTP/1.1 401"), Comment(rawValue: stranger))
        let wrongToken = await offPool {
            Self.headOnly(port: port, path: "/v1/intake/estimate?name=a.stl", length: 2 << 20,
                          extra: "X-Khayt-Intake-Token: guess\r\n")
        }
        #expect(wrongToken.hasPrefix("HTTP/1.1 401"), Comment(rawValue: wrongToken))
    }

    @Test("the head-only check lets the token and a live session through")
    func largeBodyAuthorised() async throws {
        let bench = try await LanServerTests.Bench(intakeToken: "tok-58")
        defer { bench.stop() }
        #expect(await bench.server.mayUploadLarge(headers: ["x-khayt-intake-token": "tok-58"], remote: "10.0.0.2"))
        #expect(!(await bench.server.mayUploadLarge(headers: [:], remote: "10.0.0.2")))
        let (_, cookie) = try await bench.openForm()
        #expect(await bench.server.mayUploadLarge(headers: ["cookie": cookie], remote: "127.0.0.1"))
        #expect(!(await bench.server.mayUploadLarge(headers: ["cookie": cookie], remote: "10.0.0.9")),
                "a session is the address it was opened from")
    }

    // MARK: 4 — a plug's name is where it resolves

    static func resolver(_ map: [String: [String]]) -> @Sendable (String) async -> [String] {
        { map[$0] ?? [] }
    }

    @Test("a plug name is allowed only when every address it resolves to is on this network")
    func plugNamesResolve() async throws {
        let engine = try KhaytEngine()
        let dns = Self.resolver([
            "plug.local": ["192.168.1.40"],
            "ha.local": ["fe80::1%en0"],
            "evil.example": ["8.8.8.8"],
            "split.example": ["192.168.1.9", "203.0.113.5"],
            "ha.example.ui.nabu.casa": ["35.1.2.3"],
            "home.example": ["127.0.0.1"],
            "meta.example": ["169.254.169.254"],
        ])
        for ok in ["http://plug.local/relay/0", "http://ha.local:8123/api", "https://plug.local/x"] {
            #expect(await SmartPlug.allowed(URL(string: ok)!, engine: engine, resolve: dns), Comment(rawValue: ok))
        }
        for bad in ["http://evil.example/relay", "http://split.example/x", "https://ha.example.ui.nabu.casa/api",
                    "http://home.example/x", "http://meta.example/latest", "http://nowhere.example/x"] {
            #expect(!(await SmartPlug.allowed(URL(string: bad)!, engine: engine, resolve: dns)),
                    Comment(rawValue: bad))
        }
    }

    @Test("plain HTTP goes to the address that was checked, with the name in Host")
    func plugIsPinned() async throws {
        let engine = try KhaytEngine()
        let dns = Self.resolver(["plug.local": ["192.168.1.40"], "ha.local": ["fe80::1%en0"]])
        let a = try #require(await SmartPlug.target(URL(string: "http://plug.local:8080/relay/0?x=1")!,
                                                    engine: engine, resolve: dns))
        #expect(a.url.absoluteString == "http://192.168.1.40:8080/relay/0?x=1")
        #expect(a.host == "plug.local:8080")
        // Link-local alone: checked, but sent by name — the zone it needs is not kept.
        let b = try #require(await SmartPlug.target(URL(string: "http://ha.local/api")!, engine: engine, resolve: dns))
        #expect(b.url.absoluteString == "http://ha.local/api")
        #expect(b.host == nil)
        // Unique-local IPv6 needs no zone, and is pinned.
        let ula = Self.resolver(["ula.local": ["fd12::40"]])
        let u = try #require(await SmartPlug.target(URL(string: "http://ula.local:81/x")!, engine: engine, resolve: ula))
        #expect(u.url.absoluteString == "http://[fd12::40]:81/x")
        #expect(u.host == "ula.local:81")
        // HTTPS keeps its name: the certificate is checked against it.
        let c = try #require(await SmartPlug.target(URL(string: "https://plug.local/x")!, engine: engine, resolve: dns))
        #expect(c.url.host() == "plug.local")
        #expect(c.host == nil)

        // And the send uses it.
        let machine: JSONValue = .object(["id": .string("M1"), "smartPlug": .object([
            "type": .string("homeassistant"), "host": .string("http://ha.local:8123"),
            "entity": .string("switch.core_one"), "token": .string("SECRET")])])
        let request = try #require(try await engine.plugRequest(machine: machine, action: "status"))
        let flipping = Self.resolver(["ha.local": ["192.168.1.77"]])
        var seen: URLRequest?
        _ = try await SmartPlug.send(request, engine: engine, resolve: flipping, fetch: { r in
            seen = r
            return (Data("{}".utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(seen?.url?.host() == "192.168.1.77")
        #expect(seen?.value(forHTTPHeaderField: "Host") == "ha.local:8123")
    }

    @Test("an IPv6 plug is judged as the address it is, not refused for its colons")
    func plugIPv6() async throws {
        let engine = try KhaytEngine()
        let none = Self.resolver([:])
        for ok in ["http://[fe80::1%25en0]/relay/0", "http://[fd12:3456::40]:8123/api", "http://[FE80::abcd]/x"] {
            #expect(await SmartPlug.allowed(URL(string: ok)!, engine: engine, resolve: none), Comment(rawValue: ok))
        }
        for bad in ["http://[2001:4860:4860::8888]/x", "http://[::1]/x", "http://[::ffff:127.0.0.1]/x", "http://[::]/x"] {
            #expect(!(await SmartPlug.allowed(URL(string: bad)!, engine: engine, resolve: none)), Comment(rawValue: bad))
        }
    }

    // MARK: 5 — a Bambu pin in defaults is migrated once, never afterwards

    final class FakeKeychain: @unchecked Sendable {
        let lock = NSLock()
        var items: [String: String] = [:]
        var writable = true
        var backend: BambuPin.Store.Backend {
            BambuPin.Store.Backend(
                read: { k in self.lock.withLock { self.items[k] } },
                write: { k, v in self.lock.withLock { guard self.writable else { return false }; self.items[k] = v; return true } },
                remove: { k in _ = self.lock.withLock { self.items.removeValue(forKey: k) } })
        }
    }

    static func suite() -> UserDefaults {
        let name = "khayt.test.bambupin.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("an existing defaults pin is moved to the Keychain once; one planted later is never trusted")
    func bambuPinMigratesOnce() {
        let keychain = FakeKeychain()
        let defaults = Self.suite()
        let old = BambuPin.key(serial: "OLD", host: "")
        let planted = BambuPin.key(serial: "NEW", host: "")
        defaults.set("legacy-fp", forKey: old)

        let store = BambuPin.Store.guarded(keychain.backend, defaults: defaults)
        #expect(store.read(old) == "legacy-fp", "the pin the shop already had is kept")
        #expect(defaults.string(forKey: old) == nil)
        #expect(keychain.items[old] == "legacy-fp")
        #expect(keychain.items[BambuPin.Store.migratedMarker] != nil)

        // Another process of this user writes a fingerprint for a printer not yet pinned.
        defaults.set("attacker-fp", forKey: planted)
        #expect(store.read(planted) == nil, "a defaults value was promoted after the migration")
        #expect(BambuPin.accept("real-fp", key: planted, in: store), "first sight is the printer's own")
        #expect(keychain.items[planted] == "real-fp")
        // And after a relaunch, too.
        defaults.set("attacker-fp", forKey: planted + "-2")
        let relaunched = BambuPin.Store.guarded(keychain.backend, defaults: defaults)
        #expect(relaunched.read(planted + "-2") == nil)
        #expect(keychain.items[planted + "-2"] == nil)
    }

    @Test("with no Keychain to write to, the pin lives in defaults rather than nowhere")
    func bambuPinWithoutKeychain() {
        let keychain = FakeKeychain()
        keychain.writable = false
        let defaults = Self.suite()
        let store = BambuPin.Store.guarded(keychain.backend, defaults: defaults)
        let key = BambuPin.key(serial: "CI", host: "")
        #expect(BambuPin.accept("aaaa", key: key, in: store))
        #expect(!BambuPin.accept("bbbb", key: key, in: store))
        #expect(defaults.string(forKey: key) == "aaaa")
    }

    // MARK: 6 — the machine sheet's key does not follow a redirect

    @Test("the Test button and the camera probe use the poller's no-redirect session")
    func machineSheetSession() throws {
        let sheet = try ClientSecurityTests.source("MachineSheet.swift")
        #expect(!sheet.contains("URLSession.shared"), "a printer's API key can be redirected anywhere")
        #expect(sheet.components(separatedBy: "PrinterWatch.session.data").count - 1 >= 2)
        #expect(PrinterWatch.session.delegate != nil, "the session has no redirect refusal")
        #expect(PrinterWatch.session.configuration.urlCache == nil)
    }

    // MARK: 7 — a symlink is not a model

    @Test("a symlink picked on its own is refused, even when it points at a real model")
    func libraryImportRefusesSymlink() async throws {
        let bench = try LibraryImportEndToEndTests.bench()
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let elsewhere = bench.dir.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let real = elsewhere.appending(path: "secret.stl")
        try MeshTests.binarySTL(MeshTests.boxFacets(10, 10, 10)).write(to: real)
        let link = bench.dir.appending(path: "innocent.stl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        await #expect(throws: LibraryImport.Failure.self) {
            _ = try await LibraryImportEndToEndTests.run(link, bench)
        }
        #expect(FileManager.default.fileExists(atPath: real.path), "the link's target was moved")
        #expect(try LibraryImportEndToEndTests.printFiles(in: bench).isEmpty)
        // The real file itself still imports.
        _ = try await LibraryImportEndToEndTests.run(real, bench, keepOriginal: true)
        #expect(try LibraryImportEndToEndTests.printFiles(in: bench).count == 1)
    }
}

// MARK: 8 — a picture is never decoded whole, nor absurd

@MainActor
struct Alpha58PictureTests {

    /// A real grey PNG of `w` × `h`, every pixel black: a hundred kilobytes
    /// on disk and `w × h` bytes decoded — a decompression bomb in miniature.
    /// ImageIO reports no size for a PNG whose data is truncated, so the data
    /// is all there: the rows are zeros, deflated.
    static func declaredPNG(width w: UInt32, height h: UInt32) throws -> Data {
        func crc(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xffff_ffff
            for b in bytes {
                c ^= UInt32(b)
                for _ in 0..<8 { c = (c & 1) != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
            }
            return ~c
        }
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let t = Array(type.utf8)
            return be(UInt32(body.count)) + t + body + be(crc(t + body))
        }
        // Each row: filter byte 0, then w zero bytes. Raw DEFLATE wrapped as
        // zlib: header, the stream, and the Adler-32 of n zeros (a=1, b=n).
        let n = Int(w + 1) * Int(h)
        let deflated = try (Data(count: n) as NSData).compressed(using: .zlib) as Data
        let adler = (UInt32(n % 65521) << 16) | 1
        let idat = [0x78, 0x9c] + [UInt8](deflated) + be(adler)
        var out: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        out += chunk("IHDR", be(w) + be(h) + [8, 0, 0, 0, 0])
        out += chunk("IDAT", idat)
        out += chunk("IEND", [])
        return Data(out)
    }

    static func jpegOf(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        return try #require(ProductPhotos.jpeg(image, maxDim: max(width, height), quality: 0.8))
    }

    @Test("a picture declaring absurd dimensions is refused before a pixel is decoded")
    func absurdDimensionsRefused() throws {
        let bomb = try Self.declaredPNG(width: 11_000, height: 11_000)   // 121 MP
        let source = try #require(CGImageSourceCreateWithData(bomb as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 11_000,
                "the fixture does not declare what it is meant to")
        #expect(ProductPhotos.upright(source) == nil)
        #expect(ProductPhotos.upright(source, maxPixel: 600) == nil)
        let dir = FileManager.default.temporaryDirectory.appending(path: "bomb-\(UUID().uuidString).png")
        try bomb.write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ProductPhotos.Failure.self) { _ = try ProductPhotos.prepare(dir) }
        #expect(throws: ProductPhotos.Failure.self) { _ = try GroupPictures.encode(dir) }
        #expect(throws: ProductPhotos.Failure.self) { _ = try LibraryPhoto.dataURI(of: dir) }
        #expect(!ProductPhotos.sensiblePixels(width: 0, height: 10))
        #expect(!ProductPhotos.sensiblePixels(width: 200_000, height: 1))
        #expect(ProductPhotos.sensiblePixels(width: 12_000, height: 9_000), "a 108 MP phone photo")
    }

    @Test("the decode is never larger than asked, nor than 4096 when nothing is asked")
    func decodeIsCapped() throws {
        let big = try Self.jpegOf(width: 5000, height: 2500)
        let source = try #require(CGImageSourceCreateWithData(big as CFData, nil))
        let capped = try #require(ProductPhotos.upright(source, maxPixel: 600))
        #expect(max(capped.width, capped.height) == 600)
        let unasked = try #require(ProductPhotos.upright(source))
        #expect(max(unasked.width, unasked.height) == ProductPhotos.maxDecodeDim)
        let small = try Self.jpegOf(width: 300, height: 200)
        let smallSource = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let s = try #require(ProductPhotos.upright(smallSource, maxPixel: 600))
        #expect(s.width == 300 && s.height == 200, "never enlarged")
        let group = try { () throws -> Data in
            let url = FileManager.default.temporaryDirectory.appending(path: "g-\(UUID().uuidString).jpg")
            try big.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            return try GroupPictures.encode(url)
        }()
        let groupSource = try #require(CGImageSourceCreateWithData(group as CFData, nil))
        let g = try #require(CGImageSourceCreateImageAtIndex(groupSource, 0, nil))
        #expect(max(g.width, g.height) == GroupPictures.maxDim)
    }

    // MARK: 9 — turning a picture touches only this product's own file

    @Test("a turned picture goes to a new file of its own, and only its own old file is let go")
    func turnTargetIsConfined() {
        let mine = { (t: (name: String, unlink: String?)) in
            ProductPhotos.belongs(t.name, toProduct: "P1") && t.name.hasPrefix("P1-PIMG-P1-0-") }
        // Its own file: a new name, and the old one handed back for the Trash.
        let own = ProductPhotos.target(existing: "P1-PIMG-P1-0.jpeg", productId: "P1", imageId: "PIMG-P1-0")
        #expect(mine(own) && own.unlink == "P1-PIMG-P1-0.jpeg")
        // A synced record naming ANOTHER product's file: never let go.
        let theirs = ProductPhotos.target(existing: "P2-PIMG-P2-0.jpeg", productId: "P1", imageId: "PIMG-P1-0",
                                          othersUse: ["P2-PIMG-P2-0.jpeg"])
        #expect(mine(theirs) && theirs.unlink == nil)
        // Named like this product's but another product names it too: left alone.
        let shared = ProductPhotos.target(existing: "P1-shared.jpeg", productId: "P1", imageId: "PIMG-P1-0",
                                          othersUse: ["P1-shared.jpeg"])
        #expect(mine(shared) && shared.unlink == nil)
        // A path aimed outside the folder is only ever a leaf, and not ours.
        let escape = ProductPhotos.target(existing: "../../book.jpeg", productId: "P1", imageId: "PIMG-P1-0")
        #expect(mine(escape) && escape.unlink == nil)
        // Its own PNG: a new JPEG name, and the PNG let go.
        let png = ProductPhotos.target(existing: "P1-PIMG-P1-0.png", productId: "P1", imageId: "PIMG-P1-0")
        #expect(mine(png) && png.unlink == "P1-PIMG-P1-0.png")
        #expect(ProductPhotos.belongs("P1.jpeg", toProduct: "P1"))
        #expect(!ProductPhotos.belongs("P10-x.jpeg", toProduct: "P1"))
        #expect(!ProductPhotos.belongs("other.jpeg", toProduct: "P1"))
    }

    @Test("what a save or a delete must leave alone: every file another product names")
    func otherProductsFiles() throws {
        let rows: [JSONValue] = [
            .object(["id": .string("P1"), "imagePath": .string("P1.jpeg"),
                     "images": .array([.object(["id": .string("a"), "path": .string("P2-PIMG-P2-0.jpeg")])])]),
            .object(["id": .string("P2"), "imagePath": .string("products/P2-PIMG-P2-0.jpeg"),
                     "images": .array([.object(["id": .string("b"), "path": .string("P2-PIMG-P2-0.jpeg")]),
                                       .object(["id": .string("c"), "path": .string("P1-stolen.jpeg")])])]),
        ]
        let others = Shop.pictureFiles(in: rows, except: "P1")
        #expect(others == ["P2-PIMG-P2-0.jpeg", "P1-stolen.jpeg"])
        #expect(!ProductPhotos.mayTouch("P2-PIMG-P2-0.jpeg", productId: "P1", othersUse: others))
        #expect(!ProductPhotos.mayTouch("P1-stolen.jpeg", productId: "P1", othersUse: others),
                "named like P1's, but P2 holds it")
        #expect(ProductPhotos.mayTouch("P1.jpeg", productId: "P1", othersUse: others))
        // The save and the delete both go through it.
        let shop = try ClientSecurityTests.source("Shop.swift")
        #expect(shop.contains("othersUse: othersUse)"))
        #expect(shop.components(separatedBy: "ProductPhotos.mayTouch(").count - 1 >= 2,
                "a product save or delete unlinks a picture without asking whose it is")
    }
}
