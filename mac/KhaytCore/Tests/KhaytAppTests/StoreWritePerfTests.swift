import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Every save freezes the window for a moment" (Oct 2026).
///
/// After #1859 and #1860 the library and the scan wrote off the main thread,
/// but most of the app's other writes still called the SYNCHRONOUS
/// `StoreWriter.update` from the main actor: the whole book decoded, changed,
/// encoded and fsynced inside the click — ~1 s a write on a debug build of a
/// 10,000-model book, ~100–150 ms on a release build of the shop's real one —
/// and as long again as any scan write already on the chain ahead of it. A
/// printer finishing a print (its photo and its energy) and a customer's
/// request over the shop's Wi-Fi did the same with nobody clicking anything.
///
/// The guard is `StoreWriter.MainHold`: the writer's own clock on the time the
/// main thread spent inside it, counted only for the work under the watch. NOT
/// a timer on the main queue — on CI the main actor is a queue of hundreds of
/// tests, so how late it answers measures them, not this.
extension LibraryEditPerfTests {

    /// The perf book, with the records a shop's actions need: two jobs, one
    /// machine, one customer.
    static func shopBook(models: Int = 10_000) -> [String: JSONValue] {
        var root = PerfBook.synthesize(models: models)
        root["printLog"] = .array([
            .object(["id": .string("JPERF1"), "project": .string("Bracket"), "status": .string("printing"),
                     "client": .string("Acme"), "clientId": .string("CPERF1"), "price": .number(400),
                     "rev": .number(3), "machineId": .string("MPERF1")]),
            .object(["id": .string("JPERF2"), "project": .string("Other"), "status": .string("pending"),
                     "rev": .number(1)]),
        ])
        root["machines"] = .array([
            .object(["id": .string("MPERF1"), "name": .string("Perf Printer"), "rev": .number(1)]),
        ])
        root["clients"] = .array([
            .object(["id": .string("CPERF1"), "name": .string("Acme"), "rev": .number(1)]),
        ])
        return root
    }

    /// A whole-book read-modify-write started on the chain, returned as soon
    /// as it is under way — what a scan's batch write is to the click behind it.
    static func holdChain(_ url: URL) async {
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                try? StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil },
                                        recordingDeletes: false) { root in
                    started.resume()
                    root["perfHeld"] = .bool(true)
                }
            }
        }
    }

    /// `action`, with the writer watching how long it holds the main thread.
    @MainActor
    static func held(_ action: () async -> Void) async -> StoreWriter.MainHold.Reading {
        let watch = StoreWriter.MainHold()
        await watch.watching { await action() }
        return watch.reading
    }

    /// The record `id` of `collection`, as on disk now.
    nonisolated static func onDisk(_ url: URL, _ collection: String, _ id: String) throws -> [String: JSONValue]? {
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        for case .object(let o) in Shop.rows(root, collection) where o["id"] == .string(id) { return o }
        return nil
    }

    // MARK: - The guards

    /// Nobody clicked anything: the printer's camera frame lands on the job
    /// at the end of a print, whatever the shop is doing in the window.
    @Test("a print's own photo at the end of a print writes the book off the main thread")
    func finishPhotoIsOffMain() async throws {
        try await withPerfBook(Self.shopBook()) { shop, url in
            var put = false
            let held = await Self.held {
                put = await shop.attachFinishPhoto(jobId: "JPERF1", data: OrderPhotoTests.image(64, 48))
            }
            #expect(put)
            #expect(held.count == 0, "the main thread waited \(Int(held.worstMs)) ms on a whole-book write")
            let job = try Self.onDisk(url, "printLog", "JPERF1")
            guard case .array(let photos)? = job?["printPhotos"] else {
                Issue.record("the photo never reached the book"); return
            }
            #expect(photos.count == 1)
            #expect(job?["rev"] == .number(4), "the job was not stamped, so the photo would not sync")
        }
    }

    /// A customer on the shop's Wi-Fi sends the intake form. That write was
    /// `try await StoreWriter.update(storeURL:…)` with no `await` inside its
    /// closure — which Swift resolves to the SYNCHRONOUS update.
    @Test("a customer's request over the LAN writes the book off the main thread")
    func lanIntakeIsOffMain() async throws {
        try await withPerfBook(Self.shopBook()) { shop, url in
            let entry: JSONValue = .object(["id": .string("WPERF1"), "name": .string("Walk-in")])
            var thrown: (any Error)?
            let held = await Self.held {
                do { try await shop.recordIntake(entry) } catch { thrown = error }
            }
            #expect(thrown == nil)
            #expect(held.count == 0, "the main thread waited \(Int(held.worstMs)) ms on a whole-book write")
            let waiting = try Self.onDisk(url, "waitingList", "WPERF1")
            #expect(waiting != nil, "the request never reached the book")
        }
    }

    /// The shop floor's most common click, while a scan's write is already on
    /// the chain: it used to wait on the main thread for that write to end.
    @Test("marking a bed clear behind a scan's write does not hold the window")
    func bedClearBehindAScan() async throws {
        try await withPerfBook(Self.shopBook()) { shop, url in
            let machine = try #require(shop.machines.first)
            await Self.holdChain(url)
            let held = await Self.held { await shop.markBedClear(machine) }
            #expect(shop.moveProblem == nil)
            #expect(held.count == 0, "the main thread waited \(Int(held.worstMs)) ms on the chain")
            let written = try Self.onDisk(url, "machines", "MPERF1")
            #expect(written?["bedClearedAt"] != nil, "the bed was never marked clear in the book")
            #expect(written?["perfHeld"] == nil)
        }
    }

    /// Already asynchronous — kept here so it stays that way.
    @Test("moving a job writes the book off the main thread")
    func jobMoveIsOffMain() async throws {
        try await withPerfBook(Self.shopBook()) { shop, url in
            let held = await Self.held { await shop.moveJob("JPERF2", to: .printing) }
            #expect(shop.moveProblem == nil)
            #expect(held.count == 0, "the main thread waited \(Int(held.worstMs)) ms on a whole-book write")
            let moved = try Self.onDisk(url, "printLog", "JPERF2")
            #expect(moved?["status"] == .string("printing"))
        }
    }

    /// The everyday saves: a setting, a location, a note on a customer.
    @Test("a settings save, a location and a customer's note write the book off the main thread")
    func savesAreOffMain() async throws {
        try await withPerfBook(Self.shopBook()) { shop, url in
            let wanted = shop.mode == "simple" ? "professional" : "simple"
            let entry = CommEntry(id: "COMMPERF1", kind: "note", note: "rang", at: Date())
            let held = await Self.held {
                await shop.chooseMode(wanted)
                await shop.saveLocation(id: nil, name: "Back room", address: "")
                await shop.addCommunication(entry, to: "CPERF1")
            }
            #expect(shop.writeProblem == nil)
            #expect(shop.moveProblem == nil)
            #expect(held.count == 0, "the main thread waited \(Int(held.worstMs)) ms on a whole-book write")
            let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
            #expect(Shop.settings(root)["mode"] == .string(wanted))
            let named = Shop.rows(root, "locations").contains { row in
                guard case .object(let o) = row else { return false }
                return o["name"] == .string("Back room")
            }
            #expect(named, "the location never reached the book")
            let client = try Self.onDisk(url, "clients", "CPERF1")
            guard case .array(let log)? = client?["commLog"] else {
                Issue.record("the note never reached the book"); return
            }
            #expect(log.count == 1)
            #expect(shop.mode == wanted, "the screen does not show the mode just saved")
        }
    }

    /// An undo written on the chain still puts its redo on the REDO stack:
    /// registered inside the undo, against the write still in flight.
    @Test("undoing a job move is written off the main thread, and Redo still redoes it")
    func moveUndoIsOffMain() async throws {
        try await withPerfBook(Self.shopBook(models: 40)) { shop, url in
            let undo = UndoManager()
            undo.groupsByEvent = false
            shop.undoManager = undo
            func status() throws -> JSONValue? { try Self.onDisk(url, "printLog", "JPERF2")?["status"] }
            /// The write lands on the chain, not on a main-thread deadline.
            func until(_ wanted: JSONValue) async throws -> Bool {
                for _ in 0..<600 {
                    if try status() == wanted { return true }
                    try await Task.sleep(for: .milliseconds(50))
                }
                return false
            }
            undo.beginUndoGrouping()
            await shop.moveJob("JPERF2", to: .printing)
            undo.endUndoGrouping()
            let moved = try status()
            #expect(moved == .string("printing"))
            #expect(undo.canUndo, "the move left nothing to undo")

            let held = await Self.held { undo.undo() }
            #expect(held.count == 0, "the undo held the main thread \(Int(held.worstMs)) ms")
            let undone = try await until(.string("pending"))
            #expect(undone, "the undo never reached the book")
            #expect(undo.canRedo, "the undo's redo went on the wrong stack")

            undo.redo()
            let redone = try await until(.string("printing"))
            #expect(redone, "the redo never reached the book")
            shop.undoManager = nil
        }
    }

    /// The watch is the writer's own clock — and it does see a synchronous
    /// write, or every guard above would pass by measuring nothing.
    @Test("the watch counts a synchronous write from the main thread, and only under it")
    func theWatchSeesASyncWrite() async throws {
        try await withPerfBook(Self.shopBook(models: 10)) { _, url in
            let held = await Self.held {
                try? StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                    root["perfTouched"] = .bool(true)
                }
            }
            #expect(held.count == 1)
            let outside = StoreWriter.MainHold()
            try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                root["perfTouched"] = .bool(false)
            }
            #expect(outside.reading.count == 0)
        }
    }

    // MARK: - Measuring

    /// Opt-in: `KHAYT_PERF_MEASURE=1` prints the timings behind this file;
    /// `KHAYT_PERF_BOOK=<path>` runs the raw writer on a local copy of a real
    /// book (never commit one). The real book is only ever written by
    /// `StoreWriter` in a temp folder — never loaded into a `Shop`, whose
    /// printers and cloud it would start.
    @Test("measure: a write from the main actor at real size (prints timings)",
          .enabled(if: ProcessInfo.processInfo.environment["KHAYT_PERF_MEASURE"] != nil))
    func measureWrites() async throws {
        let clock = ContinuousClock()
        let meter = MainStallMeter()

        // ── The writer alone, on the book given (or the synthetic one).
        let raw: [String: JSONValue]
        if let path = ProcessInfo.processInfo.environment["KHAYT_PERF_BOOK"] {
            raw = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            raw = Self.shopBook()
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-wperf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        try JSONValue.encode(.object(raw)).write(to: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("PERF book: \(size) bytes")

        let touch: @Sendable (inout [String: JSONValue]) -> Void = { root in
            var s: [String: JSONValue] = [:]
            if case .object(let o)? = root["settings"] { s = o }
            s["perfTouched"] = .string(UUID().uuidString)
            root["settings"] = .object(s)
        }
        @MainActor func time(_ name: String, _ action: () async throws -> Void) async throws {
            let watch = StoreWriter.MainHold()
            meter.start()
            let t = clock.now
            try await watch.watching { try await action() }
            let wall = ms(clock.now - t)
            let held = watch.reading
            print("PERF \(name): wall \(Int(wall)) ms, writer held main \(held.count)x worst \(Int(held.worstMs)) ms, worst main stall \(Int(await meter.stop())) ms")
        }
        for _ in 0..<3 {
            try await time("raw sync update") {
                try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { touch(&$0) }
            }
            await Self.holdChain(url)
            try await time("raw sync update behind a whole-book write") {
                try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { touch(&$0) }
            }
            try await time("raw async update") {
                try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root async in
                    touch(&root)
                }
            }
            try await time("raw updateOffMain") {
                try await StoreWriter.updateOffMain(storeURL: url, owns: { true }, whoHasIt: { nil }) { touch(&$0) }
            }
            await Self.holdChain(url)
            try await time("raw updateOffMain behind a whole-book write") {
                try await StoreWriter.updateOffMain(storeURL: url, owns: { true }, whoHasIt: { nil }) { touch(&$0) }
            }
        }

        // ── The shop's own actions, on the synthetic 10,000-model book.
        try await withPerfBook(Self.shopBook()) { shop, url in
            let machine = try #require(shop.machines.first)
            for _ in 0..<2 {
                try await time("markBedClear (machine)") { await shop.markBedClear(machine) }
                try await time("chooseMode (settings)") {
                    await shop.chooseMode(shop.mode == "simple" ? "professional" : "simple")
                }
                try await time("saveLocation (settings)") { await shop.saveLocation(id: nil, name: "Shelf", address: "") }
                try await time("addCommunication (customer)") {
                    await shop.addCommunication(CommEntry(id: UUID().uuidString, kind: "note", note: "rang", at: Date()),
                                                to: "CPERF1")
                }
                try await time("attachFinishPhoto (print end, automatic)") {
                    _ = await shop.attachFinishPhoto(jobId: "JPERF1", data: OrderPhotoTests.image(640, 480))
                }
                try await time("recordIntake (LAN, automatic)") {
                    try await shop.recordIntake(.object(["id": .string(UUID().uuidString)]))
                }
                try await time("moveJob") { await shop.moveJob("JPERF2", to: .printing) }
                try await time("moveJob back") { await shop.moveJob("JPERF2", to: .pending) }
                await Self.holdChain(url)
                try await time("markBedClear behind a whole-book write") { await shop.markBedClear(machine) }
            }
        }
    }
}
