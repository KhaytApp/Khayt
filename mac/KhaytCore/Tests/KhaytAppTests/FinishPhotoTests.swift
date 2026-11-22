import Foundation
import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// The printer's own photo at the end of a print.
///
/// Four things are pinned here, each through the path the app actually runs:
/// the edge fires once per print (`FinishCamera.observe` over the shared
/// rule), nothing is taken for a cancelled or failed print, the frame lands on
/// the RIGHT job (the rule's choice, then `OrderPhoto.attach` on a copy of a
/// store), and "Use as product photo" adds a `print`-kind picture through
/// `product-images`. The camera is a mocked Moonraker snapshot, which is the
/// U1's path: `/webcam/?action=snapshot` on the printer's own host.
@MainActor
struct FinishPhotoTests {

    static func status(_ state: String, _ progress: Int = 0, _ file: String = "lamp.gcode") -> JSONValue {
        .object(["state": .string(state), "progress": .number(Double(progress)),
                 "filename": .string(file)])
    }

    /// A Snapmaker U1 with its camera switched on.
    static func u1(id: String = "M1") throws -> Machine {
        let row: [String: JSONValue] = [
            "id": .string(id), "name": .string("U1"),
            "printerApi": .object(["type": .string("moonraker"), "host": .string("192.168.1.50")]),
            "webcam": .object(["enabled": .bool(true),
                               "snapshotUrl": .string("http://192.168.1.50/webcam/?action=snapshot")]),
        ]
        return try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
    }

    static func job(_ id: String, _ status: String, machine: String, file: String? = nil,
                    product: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status),
                                      "machineId": .string(machine), "project": .string(id)]
        if let file { o["parts"] = .array([.object(["name": .string("p"), "fileRef": .string(file)])]) }
        if let product { o["productId"] = .string(product) }
        return .object(o)
    }

    /// Moonraker answering a snapshot with a real JPEG.
    static func jpegAnswer(_ request: URLRequest) -> (Data, URLResponse) {
        (OrderPhotoTests.image(640, 480),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                         headerFields: ["Content-Type": "image/jpeg"])!)
    }

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    // MARK: - When

    /// The photo-worthy edges only: the filename of each FINISHED print.
    static func finishes(_ camera: FinishCamera, _ polls: [JSONValue], engine: KhaytEngine,
                         machine: String = "M1") async -> [String] {
        var out: [String] = []
        for s in polls {
            if let edge = await camera.observe(machine, status: s, engine: engine), edge.capture {
                out.append(edge.filename)
            }
        }
        return out
    }

    @Test("the edge fires once per print, however long the printer sits on complete")
    func firesOnce() async throws {
        let engine = try KhaytEngine()
        let camera = FinishCamera()
        var edges = 0
        for s in [Self.status("standby"), Self.status("printing", 10), Self.status("printing", 98),
                  Self.status("complete", 100), Self.status("complete", 100),
                  Self.status("complete", 100), Self.status("standby")] {
            if await camera.observe("M1", status: s, engine: engine) != nil { edges += 1 }
        }
        #expect(edges == 1, "one print, one edge")

        // The next print is a new edge.
        let next = await Self.finishes(camera, [Self.status("printing", 5, "b.gcode"),
                                                Self.status("complete", 100, "b.gcode")], engine: engine)
        #expect(next == ["b.gcode"])
    }

    @Test("a cancelled or failed print is an edge, but takes no photo")
    func noPhotoOnFailure() async throws {
        let engine = try KhaytEngine()
        for (end, said) in [("cancelled", "cancelled"), ("error", "failed"),
                            ("FAILED", "failed"), ("STOPPED", "cancelled")] {
            let camera = FinishCamera()
            var edges: [KhaytEngine.FinishTrack] = []
            for s in [Self.status("printing", 99), Self.status(end, 99), Self.status("standby")] {
                if let e = await camera.observe("M1", status: s, engine: engine) { edges.append(e) }
            }
            #expect(edges.count == 1, Comment(rawValue: "\(end): \(edges.count) edges"))
            #expect(edges.first?.outcome == said)
            #expect(edges.first?.capture == false, Comment(rawValue: "\(end) asked for a photo"))
        }
        // And an idle printer short of the end is a cancel that did not say so.
        let camera = FinishCamera()
        #expect(await Self.finishes(camera, [Self.status("printing", 40), Self.status("standby", 0)],
                                    engine: engine).isEmpty)
    }

    @Test("a book closed and reopened has not just finished a print")
    func resetForgets() async throws {
        let engine = try KhaytEngine()
        let camera = FinishCamera()
        _ = await camera.observe("M1", status: Self.status("printing", 50), engine: engine)
        camera.reset()
        #expect(await camera.observe("M1", status: Self.status("complete", 100), engine: engine) == nil)
    }

    // MARK: - Which job, the camera, and the event

    static func edge(_ outcome: String, file: String = "lamp.gcode", duration: Double? = 3600) -> KhaytEngine.FinishTrack {
        var o: [String: JSONValue] = ["memo": .object([:]), "capture": .bool(outcome == "finished"),
                                      "outcome": .string(outcome), "filename": .string(file)]
        o["durationS"] = duration.map(JSONValue.number) ?? .null
        return try! JSONDecoder().decode(KhaytEngine.FinishTrack.self,
                                         from: JSONEncoder().encode(JSONValue.object(o)))
    }

    @Test("the U1's snapshot goes to the printing job that names the file, and the event says so")
    func attachesToTheRightJob() async throws {
        let shop = await Self.shop()
        let log = [Self.job("A", "printing", machine: "M1", file: "other.gcode"),
                   Self.job("B", "printing", machine: "M1", file: "gcodes/lamp.gcode"),
                   Self.job("C", "printing", machine: "M2", file: "lamp.gcode")]
        var asked: [URL] = []
        var got: (String, Data)?
        let (ended, photo) = await FinishCamera.finish(try Self.u1(), edge: Self.edge("finished"),
                                                       printLog: log, shop: shop, get: { request in
            asked.append(request.url!)
            return Self.jpegAnswer(request)
        }) { jobId, data in
            got = (jobId, data)
            return true
        }
        #expect(photo == .attached("B"))
        #expect(got?.0 == "B")
        #expect(got.map { !$0.1.isEmpty } == true)
        #expect(asked.map(\.absoluteString) == ["http://192.168.1.50/webcam/?action=snapshot"])
        #expect(ended == FinishCamera.Ended(machineId: "M1", machineName: "U1", orderId: "B",
                                            outcome: "finished", durationS: 3600, photoTaken: true,
                                            filename: "lamp.gcode"))
    }

    @Test("a cancelled print makes no request, attaches nothing, and is still reported")
    func cancelledIsReportedWithoutAPhoto() async throws {
        let shop = await Self.shop()
        let log = [Self.job("A", "printing", machine: "M1", file: "lamp.gcode")]
        var asked = 0
        var attached = false
        for outcome in ["cancelled", "failed"] {
            let (ended, photo) = await FinishCamera.finish(try Self.u1(), edge: Self.edge(outcome, duration: nil),
                                                           printLog: log, shop: shop, get: { request in
                asked += 1
                return Self.jpegAnswer(request)
            }) { _, _ in attached = true; return true }
            #expect(photo == .notFinished)
            #expect(ended.outcome == outcome)
            #expect(ended.orderId == "A", "the job is still named for a print that did not finish")
            #expect(ended.durationS == nil)
            #expect(!ended.photoTaken)
        }
        #expect(asked == 0)
        #expect(!attached)
    }

    @Test("no job the book can name: no request, and the event carries no order")
    func noJobNoRequest() async throws {
        let shop = await Self.shop()
        let log = [Self.job("A", "printing", machine: "M1"), Self.job("B", "printing", machine: "M1")]
        var asked = 0
        var attached = false
        let (ended, photo) = await FinishCamera.finish(try Self.u1(), edge: Self.edge("finished", file: "x.gcode"),
                                                       printLog: log, shop: shop, get: { request in
            asked += 1
            return Self.jpegAnswer(request)
        }) { _, _ in attached = true; return true }
        #expect(photo == .noJob)
        #expect(ended.orderId == nil, "two printing jobs: the seam is not handed a guess")
        #expect(asked == 0)
        #expect(!attached)
    }

    @Test("a snapshot that fails attaches nothing and blocks nothing")
    func snapshotFailureIsQuiet() async throws {
        let shop = await Self.shop()
        let log = [Self.job("A", "printing", machine: "M1", file: "lamp.gcode")]
        var attached = false
        let (refusedEvent, refused) = await FinishCamera.finish(try Self.u1(), edge: Self.edge("finished"),
                                                                printLog: log, shop: shop, get: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                                     headerFields: [:])!)
        }) { _, _ in attached = true; return true }
        #expect(refused == .noFrame)
        #expect(refusedEvent.photoTaken == false)
        #expect(refusedEvent.orderId == "A")
        let (_, thrown) = await FinishCamera.finish(try Self.u1(), edge: Self.edge("finished"),
                                                    printLog: log, shop: shop,
                                                    get: { _ in throw URLError(.timedOut) }) { _, _ in
            attached = true; return true
        }
        #expect(thrown == .noFrame)
        #expect(!attached)
    }

    @Test("a machine with no camera is not asked")
    func noCamera() async throws {
        let shop = await Self.shop()
        let row: [String: JSONValue] = [
            "id": .string("M1"), "name": .string("U1"),
            "printerApi": .object(["type": .string("moonraker"), "host": .string("192.168.1.50")]),
        ]
        let machine = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
        let (ended, photo) = await FinishCamera.finish(machine, edge: Self.edge("finished"),
                                                       printLog: [], shop: shop) { _, _ in true }
        #expect(photo == .noCamera)
        #expect(!ended.photoTaken)
    }

    // MARK: - On the job, on disk

    static func tempStore(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-finish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    @Test("the frame is written to the chosen job only, file first, and stamped")
    func writtenToTheJob() throws {
        let store = try Self.tempStore(["printLog": .array([
            Self.job("A", "printing", machine: "M1"), Self.job("B", "printing", machine: "M1"),
        ])])
        let folder = store.deletingLastPathComponent().appending(path: "order-photos")
        let made = try #require(OrderPhoto.encode(OrderPhotoTests.image(640, 480)))
        let name = try OrderPhoto.attach(made, jobId: "B", job: nil, folder: folder) { change in
            try StoreWriter.updateRecord(storeURL: store, owns: { true }, whoHasIt: { nil },
                                         collection: "printLog", id: "B", change: change)
        }
        #expect(name.hasPrefix("B-0-"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path))

        guard case .array(let jobs)? = try Self.read(store)["printLog"] else {
            Issue.record("no printLog"); return
        }
        for case .object(let job) in jobs {
            let photos: [JSONValue] = { if case .array(let p)? = job["printPhotos"] { return p }; return [] }()
            if job["id"] == .string("B") {
                #expect(photos == [OrderPhoto.record(thumb: made.thumb, filename: name)])
                #expect(job["rev"] != nil, "unstamped: the other machine's copy wins the next merge")
            } else {
                #expect(photos.isEmpty, "the photo went on the wrong job")
            }
        }
    }

    @Test("a file that cannot be written leaves the record alone")
    func noFileNoRecord() throws {
        let made = try #require(OrderPhoto.encode(OrderPhotoTests.image(64, 48)))
        var wrote = false
        // A folder under a FILE cannot be created.
        let blocker = FileManager.default.temporaryDirectory.appending(path: "khayt-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        #expect(throws: (any Error).self) {
            _ = try OrderPhoto.attach(made, jobId: "A", job: nil,
                                      folder: blocker.appending(path: "order-photos")) { _ in wrote = true }
        }
        #expect(!wrote)
    }

    // MARK: - On the product

    @Test("use as product photo adds a print-kind picture, after the primary")
    func addsAPrintKindPicture() async throws {
        let engine = try KhaytEngine()
        let product: JSONValue = .object([
            "id": .string("PRD-1"), "name": .string("Lamp"),
            "images": .array([.object(["id": .string("PIMG-PRD1-0"), "path": .string("PRD-1-PIMG-PRD1-0.jpeg"),
                                       "thumbnail": .string("data:image/jpeg;base64,UkVOREVS"),
                                       "kind": .string("render"), "caption": .string("")])]),
            "imagePath": .string("PRD-1-PIMG-PRD1-0.jpeg"),
            "thumbnail": .string("data:image/jpeg;base64,UkVOREVS"),
        ])
        let made = try #require(OrderPhoto.encode(OrderPhotoTests.image(640, 480)))
        var files: [String] = []
        let fields = try #require(try await ProductPhotos.addPrintPhoto(
            made, to: product, productId: "PRD-1", engine: engine) { imageId in
            let name = ProductPhotos.filename(productId: "PRD-1", imageId: imageId)
            files.append(name)
            return name
        })
        #expect(files.count == 1, "the file is written once, with the minted id")
        guard case .array(let images)? = fields["images"], images.count == 2,
              case .object(let added) = images[1] else {
            Issue.record("expected two pictures: \(String(describing: fields["images"]))"); return
        }
        #expect(added["kind"] == .string("print"))
        #expect(added["path"] == .string(files[0]))
        #expect(added["thumbnail"] == .string(made.thumb))
        #expect(fields["imagePath"] == .string("PRD-1-PIMG-PRD1-0.jpeg"), "the shop's primary stays primary")

        var after: [String: JSONValue] = ["id": .string("PRD-1")]
        for (k, v) in fields { after[k] = v }
        #expect(try await engine.productHasRealPhoto(.object(after)), "the listing now shows the real thing")

        // The same picture again is one picture, and nothing is written.
        let again = try await ProductPhotos.addPrintPhoto(
            made, to: .object(after), productId: "PRD-1", engine: engine) { _ in
            Issue.record("a second file was written for the same picture"); return "x"
        }
        #expect(again == nil)
    }

    @Test("a product with no pictures gets it as its primary")
    func firstPictureIsPrimary() async throws {
        let engine = try KhaytEngine()
        let made = try #require(OrderPhoto.encode(OrderPhotoTests.image(64, 48)))
        let fields = try #require(try await ProductPhotos.addPrintPhoto(
            made, to: .object(["id": .string("P")]), productId: "P", engine: engine) { _ in "P-x.jpeg" })
        #expect(fields["imagePath"] == .string("P-x.jpeg"))
        #expect(fields["thumbnail"] == .string(made.thumb))
    }

    @Test("the data URI a thumbnail travels as is read back to bytes")
    func dataURI() {
        #expect(Shop.dataURIBytes("data:image/jpeg;base64,AAEC") == Data([0, 1, 2]))
        #expect(Shop.dataURIBytes("not a uri") == nil)
    }
}
