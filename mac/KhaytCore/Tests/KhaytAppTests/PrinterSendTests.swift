import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A sliced file sent from the Mac to a printer.
///
/// `test/printer-upload.test.js` holds the request shapes to what main.js
/// always sent. This holds the Mac's wire to those shapes — every request is
/// caught before it leaves, and its method, path, headers and bytes are read
/// back — and to the refusals, which must happen before a byte is sent.
@MainActor
struct PrinterSendTests {

    static func engine() async throws -> KhaytEngine {
        let shop = Shop()
        await shop.load(.sample)
        return try #require(shop.engine)
    }

    static func machine(_ type: String, host: String = "192.168.68.56", port: Int? = nil) throws -> Machine {
        var api: [String: JSONValue] = ["type": .string(type), "host": .string(host)]
        if let port { api["port"] = .number(Double(port)) }
        let json: JSONValue = .object(["id": .string("M1"), "name": .string("U1"), "printerApi": .object(api)])
        return try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(json))
    }

    /// A sliced file on disk, with a known body.
    static func file(_ name: String, _ body: String = "G28\nG1 X10\n") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "send-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try Data(body.utf8).write(to: url)
        return url
    }

    final class Caught: @unchecked Sendable { var requests: [URLRequest] = [] }

    static func stub(_ caught: Caught, status: Int = 201) -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            caught.requests.append(request)
            let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
            return (Data("{}".utf8), r)
        }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Moonraker: a multipart POST, the file first, then root and print")
    func moonraker() async throws {
        let engine = try await Self.engine()
        let caught = Caught()
        let file = try Self.file("Dragon.gcode")
        let sent = try await PrinterSend.send(file, to: try Self.machine("moonraker"), key: "", startPrint: true,
                                              engine: engine, now: Self.now, fetch: Self.stub(caught))
        #expect(sent.started)
        #expect(sent.remoteName.hasSuffix(".gcode"))
        let req = try #require(caught.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://192.168.68.56:7125/server/files/upload")
        #expect(req.value(forHTTPHeaderField: "X-Api-Key") == nil, "Moonraker was sent a key it does not have")
        let type = try #require(req.value(forHTTPHeaderField: "Content-Type"))
        #expect(type.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        let filePart = try #require(body.range(of: "name=\"file\"; filename=\"\(sent.remoteName)\""))
        let root = try #require(body.range(of: "name=\"root\"\r\n\r\ngcodes"))
        let print = try #require(body.range(of: "name=\"print\"\r\n\r\ntrue"))
        #expect(filePart.lowerBound < root.lowerBound && root.lowerBound < print.lowerBound,
                "the file part goes first, then the fields in order")
        #expect(body.contains("G28\nG1 X10\n"), "the file's bytes are not in the body")
    }

    @Test("PrusaLink: the raw bytes PUT to USB, as .bgcode when that is what it is")
    func prusalink() async throws {
        let engine = try await Self.engine()
        let caught = Caught()
        let file = try Self.file("Plate_1.bgcode", "GCDE-binary")
        let sent = try await PrinterSend.send(file, to: try Self.machine("prusalink"), key: "secret", startPrint: false,
                                              engine: engine, now: Self.now, fetch: Self.stub(caught))
        #expect(sent.remoteName.hasSuffix(".bgcode"), "a binary G-code stored as .gcode is refused by the printer")
        let req = try #require(caught.requests.first)
        #expect(req.httpMethod == "PUT")
        #expect(req.url?.path == "/api/v1/files/usb/\(sent.remoteName)")
        #expect(req.value(forHTTPHeaderField: "X-Api-Key") == "secret")
        #expect(req.value(forHTTPHeaderField: "Print-After-Upload") == "0")
        #expect(req.httpBody == Data("GCDE-binary".utf8))
    }

    @Test("OctoPrint: the key is always sent, and select and print follow the file")
    func octoprint() async throws {
        let engine = try await Self.engine()
        let caught = Caught()
        let file = try Self.file("a.gcode")
        _ = try await PrinterSend.send(file, to: try Self.machine("octoprint", port: 5000), key: "K", startPrint: true,
                                       engine: engine, now: Self.now, fetch: Self.stub(caught))
        let req = try #require(caught.requests.first)
        #expect(req.url?.absoluteString == "http://192.168.68.56:5000/api/files/local")
        #expect(req.value(forHTTPHeaderField: "X-Api-Key") == "K")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"select\"\r\n\r\ntrue") && body.contains("name=\"print\"\r\n\r\ntrue"))
    }

    @Test("what cannot be sent is refused before anything leaves")
    func refusals() async throws {
        let engine = try await Self.engine()
        let caught = Caught()
        func attempt(_ name: String, _ type: String) async -> Error? {
            do {
                _ = try await PrinterSend.send(try Self.file(name), to: try Self.machine(type), key: "",
                                               startPrint: true, engine: engine, fetch: Self.stub(caught))
                return nil
            } catch { return error }
        }
        #expect(await attempt("dragon.stl", "moonraker") as? PrinterSend.Problem == .notSliced)
        #expect(await attempt("plate.gcode.3mf", "moonraker") as? PrinterSend.Problem == .wrongKind("3mf"))
        #expect(await attempt("a.gcode", "bambu") as? PrinterSend.Problem == .bambuNotYet)
        #expect(await attempt("a.gcode", "duet") as? PrinterSend.Problem == .unsupported("duet"))
        #expect(await attempt("a.gcode", "") as? PrinterSend.Problem == .noConnection)
        #expect(caught.requests.isEmpty, "a refused file still went to the printer")
    }

    @Test("a public address is refused, and a printer's refusal or redirect is an error")
    func guards() async throws {
        let engine = try await Self.engine()
        let caught = Caught()
        let file = try Self.file("a.gcode")
        await #expect(throws: (any Error).self) {
            _ = try await PrinterSend.send(file, to: try Self.machine("moonraker", host: "8.8.8.8"), key: "",
                                           startPrint: true, engine: engine, fetch: Self.stub(caught))
        }
        #expect(caught.requests.isEmpty, "a file was sent to an address off this network")
        for status in [302, 403, 500] {
            await #expect(throws: (any Error).self) {
                _ = try await PrinterSend.send(file, to: try Self.machine("moonraker"), key: "", startPrint: true,
                                               engine: engine, fetch: Self.stub(Caught(), status: status))
            }
        }
    }

    @Test("a model's folder offers its sliced files, newest first, and nothing else")
    func slicedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sliced-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, age) in [("old.gcode", 300.0), ("new.bgcode", 10.0), ("proj.gcode.3mf", 100.0),
                            ("model.stl", 1.0), ("model.3mf", 2.0), ("guide.pdf", 3.0)] {
            let url = dir.appending(path: name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        #expect(PrinterSend.slicedFiles(in: dir).map(\.lastPathComponent) == ["new.bgcode", "proj.gcode.3mf", "old.gcode"])
    }

    @Test("the sheet is reachable, and the send opens the key at the moment it sends")
    func wired() {
        #expect(MenuCoverageTests.source("ShopWindow.swift").contains(".sheet(item: $shop.pendingSend) { SendToPrinterSheet("))
        for file in ["Menus.swift", "OrdersTable.swift", "OrderInspector.swift"] {
            #expect(MenuCoverageTests.source(file).contains("shop.pendingSend = Shop.PendingHold("),
                    Comment(rawValue: "\(file) no longer opens the Send sheet"))
        }
        #expect(MenuCoverageTests.source("SendToPrinterSheet.swift").contains("await shop.sendToPrinter(file,"))
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("await PrinterControl.key(for: machine, build: source.build)"))
        #expect(shop.contains("try await PrinterSend.send(file, to: machine, key: key,"))
    }
}
