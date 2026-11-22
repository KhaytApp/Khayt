import Foundation
import Testing
import CryptoKit
@testable import KhaytApp

/// `khayt://job/new` — bedready.io's "send to Khayt as a job". It may only
/// name a plain model file and must carry its hash; the file is used only when
/// both match, and the app asks before anything.
@MainActor
struct NewJobLinkTests {
    static let hash = String(repeating: "a", count: 64)

    @Test("the shape bedready sends is read; anything off it is refused")
    func parses() throws {
        let ok = try #require(NewJobLink(URL(string: "khayt://job/new?name=Sultan%20relief&printer=u1&plates=2&t1=%23ff0000,PLA,Bambu&file=sultan.3mf&sha256=\(Self.hash)")!))
        #expect(ok.name == "Sultan relief" && ok.file == "sultan.3mf" && ok.sha256 == Self.hash)
        for bad in ["khayt://job/new?file=sultan.3mf",                                   // no hash
                    "khayt://job/new?file=sultan.3mf&sha256=xyz",                       // not a hash
                    "khayt://job/new?file=../etc/passwd.3mf&sha256=\(Self.hash)",       // a path
                    "khayt://job/new?file=.hidden.3mf&sha256=\(Self.hash)",
                    "khayt://job/new?file=run.command&sha256=\(Self.hash)",             // not a model
                    "khayt://job/J-1",                                                  // a widget link
                    "https://job/new?file=a.3mf&sha256=\(Self.hash)"] {
            #expect(NewJobLink(URL(string: bad)!) == nil, Comment(rawValue: bad))
        }
        let long = NewJobLink(URL(string: "khayt://job/new?name=\(String(repeating: "x", count: 300))&file=a.stl&sha256=\(Self.hash)")!)
        #expect(long?.name.count == NewJobLink.maxName)
    }

    @Test("the file is used only with the same name and the same content")
    func locates() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "joblink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("solid probe\nendsolid probe\n".utf8)
        try bytes.write(to: dir.appending(path: "probe.stl"))
        let right = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let link = try #require(NewJobLink(URL(string: "khayt://job/new?file=probe.stl&sha256=\(right)")!))
        #expect(link.locate(in: dir)?.lastPathComponent == "probe.stl")
        let wrong = try #require(NewJobLink(URL(string: "khayt://job/new?file=probe.stl&sha256=\(Self.hash)")!))
        #expect(wrong.locate(in: dir) == nil, "a changed file was accepted")
        let gone = try #require(NewJobLink(URL(string: "khayt://job/new?file=other.stl&sha256=\(right)")!))
        #expect(gone.locate(in: dir) == nil)
    }

    @Test("the app routes it before the widget links, and it asks before New Job")
    func routedAndAsks() {
        let app = MenuCoverageTests.source("KhaytApp.swift")
        #expect(app.contains("let jobLinks = urls.compactMap(NewJobLink.init)"))
        #expect(app.contains("urls.filter { NewJobLink($0) == nil }.compactMap(ShopWidgetSnapshot.Link.init)"))
        let link = MenuCoverageTests.source("NewJobLink.swift")
        #expect(link.contains("guard alert.runModal() == .alertFirstButtonReturn else { return }"))
        #expect(link.contains("guard canMoveJobs, permitted(\"orders\", \"create\") else { return }"))
    }
}
