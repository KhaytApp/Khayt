import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// MEASUREMENT HARNESS (Nov 11 2026, uncommitted). Does nothing unless
/// `KHAYT_MEASURE_BOOK` names a SCRUBBED book file; it copies that file into
/// a temp support folder and never opens the original for writing.
/// Writes counts and timings only to `KHAYT_MEASURE_OUT`.
@MainActor
@Suite(.serialized)
struct MeasureNov11Tests {

    static func memory() -> (resident: Int, footprint: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (Int(info.resident_size), Int(info.phys_footprint))
    }

    /// CPU the whole process used, in ms: what a stretch of work costs with
    /// the machine's other load taken out (the engine works on its own thread).
    static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e6 }
    /// CPU this thread used, in ms: for work done here, start to end.
    static func mine() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    static func timed(_ body: () async throws -> Void) async rethrows -> (wall: Double, cpu: Double) {
        let clock = ContinuousClock()
        let t0 = clock.now, c0 = cpu()
        try await body()
        return (ms(clock.now - t0), cpu() - c0)
    }

    static func stats(_ xs: [Double]) -> [String: Double] {
        guard !xs.isEmpty else { return [:] }
        let s = xs.sorted()
        let median = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        return ["median": median, "max": s.last!, "min": s.first!, "n": Double(s.count)]
    }

    /// One load's engine calls, summed and ranked.
    static func summarise(_ calls: [MeasureProbe.Call]) -> [String: Any] {
        func msOf(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
        var encode = 0.0, parse = 0.0, rule = 0.0, stringify = 0.0, decode = 0.0
        var argBytes = 0, resultBytes = 0
        for c in calls {
            encode += msOf(c.encodeNs); parse += msOf(c.parseNs); rule += msOf(c.ruleNs)
            stringify += msOf(c.stringifyNs); decode += msOf(c.decodeNs)
            argBytes += c.argBytes; resultBytes += c.resultBytes
        }
        let top = calls.sorted { $0.totalNs > $1.totalNs }.prefix(12).map { c -> [String: Any] in
            ["name": c.name, "totalMs": msOf(c.totalNs), "encodeMs": msOf(c.encodeNs),
             "parseMs": msOf(c.parseNs), "ruleMs": msOf(c.ruleNs), "stringifyMs": msOf(c.stringifyNs),
             "decodeMs": msOf(c.decodeNs), "argBytes": c.argBytes, "resultBytes": c.resultBytes]
        }
        let big = calls.filter { $0.argBytes > 1_000_000 }.count
        return ["calls": calls.count, "encodeMs": encode, "parseMs": parse, "ruleMs": rule,
                "stringifyMs": stringify, "decodeMs": decode,
                "engineMs": encode + parse + rule + stringify + decode,
                "argBytes": argBytes, "resultBytes": resultBytes,
                "callsOver1MBArgs": big, "top": Array(top)]
    }

    static func loads(_ shop: Shop, _ source: Shop.Source, runs: Int) async -> [[String: Any]] {
        var out: [[String: Any]] = []
        for _ in 0..<runs {
            _ = MeasureProbe.take()
            let meter = MainStallMeter()
            meter.start()
            let took = await timed { await shop.load(source) }
            let stall = await meter.stop()
            let taken = MeasureProbe.take()
            var one = summarise(taken.calls)
            one["wallMs"] = took.wall
            one["cpuMs"] = took.cpu
            one["models"] = shop.files.count
            one["jobs"] = shop.orders.count
            one["worstMainStallMs"] = stall
            one["enginesMade"] = taken.engines.count
            out.append(one)
            // What a load starts in the background (readiness, the chips)
            // finishes before the next is timed.
            try? await Task.sleep(for: .seconds(3))
        }
        return out
    }

    static func board(_ shop: Shop) -> [String: Any] {
        var out: [String: Any] = ["jobs": shop.orders.count, "spools": shop.spools.count]
        for term in ["", "a", "pla"] {
            shop.search = term
            var matching: [Double] = [], lots: [Double] = [], lanes: [Double] = [], draw: [Double] = []
            for _ in 0..<9 {
                var t = mine()
                _ = shop.matching(shop.orders)
                matching.append(mine() - t)
                t = mine()
                _ = shop.lotReasons(shop.orders)
                lots.append(mine() - t)
                t = mine()
                _ = shop.board
                lanes.append(mine() - t)
                // Everything `Kanban.body` asks of the book in one draw.
                t = mine()
                _ = shop.matching(shop.orders).filter {
                    guard shop.inSite($0), let stage = Stage.of($0) else { return false }
                    return !Stage.boardColumns.contains(stage)
                }.count
                _ = shop.lotReasons(shop.orders)
                _ = shop.board
                if !shop.unplaced.isEmpty { _ = shop.unplaced.count }
                else { _ = shop.matching(shop.orders).isEmpty }
                draw.append(mine() - t)
            }
            out["term:\(term.count)chars"] = ["matching": stats(matching), "lotReasons": stats(lots),
                                              "board": stats(lanes), "oneDraw": stats(draw),
                                              "matched": shop.matching(shop.orders).count]
        }
        shop.search = ""
        return out
    }

    static func library(_ shop: Shop) async -> [String: Any] {
        var out: [String: Any] = ["models": shop.files.count, "rows": shop.libraryRows.count]
        shop.search = ""
        shop.shelf = .library(nil)
        // First open: the list, its entries, the tile facts, the chips.
        var t = mine()
        let shown = shop.shownFiles
        out["firstShownMs"] = mine() - t
        out["shown"] = shown.count
        t = mine()
        let entries = shop.memoEntries()
        out["firstEntriesMs"] = mine() - t
        out["entries"] = entries.entries.count
        t = mine()
        for f in shop.files { _ = shop.libraryFacts(f) }
        out["factsAllFirstMs"] = mine() - t
        t = mine()
        for f in shop.files { _ = shop.libraryFacts(f) }
        out["factsAllAgainMs"] = mine() - t

        // The chips' counts (filter axes), from nothing, repeated.
        var facets: [Double] = [], facetsWall: [Double] = []
        for _ in 0..<7 {
            shop.facetMemo = nil
            _ = MeasureProbe.take()
            let took = await timed { await shop.readLibraryFacets() }
            facets.append(took.cpu)
            facetsWall.append(took.wall)
        }
        out["facetRecountCpu"] = stats(facets)
        out["facetRecountWall"] = stats(facetsWall)
        shop.facetMemo = nil
        _ = MeasureProbe.take()
        await shop.readLibraryFacets()
        out["facetRecountEngine"] = summarise(MeasureProbe.take().calls)

        // A saved search's count.
        var counts: [Double] = []
        for i in 0..<7 {
            var q = LibraryQuery()
            q.text = String(repeating: "z", count: i + 1)
            t = mine()
            _ = shop.libraryCount(q)
            counts.append(mine() - t)
        }
        out["oneQueryCount"] = stats(counts)

        // Every sort order, list rebuilt each time.
        var sorts: [String: Any] = [:]
        for sort in LibrarySort.allCases {
            shop.librarySort = sort
            t = mine()
            _ = shop.shownFiles
            let a = mine() - t
            t = mine()
            _ = shop.memoEntries()
            sorts[sort.rawValue] = ["shownMs": a, "entriesMs": mine() - t]
        }
        shop.librarySort = .added
        out["sorts"] = sorts
        // Flat list (no groups), as a search shows it.
        // Typing: each keystroke is the list, the entries and the chips.
        var typing: [[String: Any]] = []
        for word in ["stand", "box"] {
            shop.search = ""
            _ = shop.shownFiles; _ = shop.memoEntries()
            for n in 1...word.count {
                shop.search = String(word.prefix(n))
                t = mine()
                let found = shop.shownFiles
                let a = mine() - t
                t = mine()
                _ = shop.memoEntries()
                let b = mine() - t
                let c = await timed { await shop.readLibraryFacets() }.cpu
                typing.append(["chars": n, "found": found.count, "shownMs": a, "entriesMs": b,
                               "facetsMs": c, "keystrokeMs": a + b + c])
            }
        }
        out["typing"] = typing
        shop.search = ""
        _ = shop.shownFiles
        let work = shop.libraryMemo.work
        out["work"] = ["builds": work.builds, "narrowed": work.narrowed, "entryBuilds": work.entryBuilds,
                       "factBuilds": work.factBuilds, "facetRecounts": work.facetRecounts]
        shop.shelf = .dashboard
        return out
    }

    @Test("measure (only when KHAYT_MEASURE_OUT is set)")
    func measure() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outPath = env["KHAYT_MEASURE_OUT"] else { return }
        var report: [String: Any] = [:]
        var loadsAtStart = [Double](repeating: 0, count: 3)
        getloadavg(&loadsAtStart, 3)
        report["loadAverageAtStart"] = loadsAtStart
        #if DEBUG
        report["build"] = "debug"
        #else
        report["build"] = "release"
        #endif

        // ── D6: making an engine ─────────────────────────────────────────
        var made: [[String: Any]] = []
        var kept: [KhaytEngine] = []
        for i in 0..<7 {
            let before = Self.memory()
            let t = await Self.timed { kept.append(try! KhaytEngine()) }
            let after = Self.memory()
            // What `Words.preload` then asks of it.
            let first = await Self.timed { _ = try? await kept[i].translations(language: "en") }
            let warm = Self.memory()
            made.append(["createWallMs": t.wall, "createCpuMs": t.cpu, "residentDeltaMB": Double(after.resident - before.resident) / 1_048_576,
                         "footprintDeltaMB": Double(after.footprint - before.footprint) / 1_048_576,
                         "firstCallWallMs": first.wall, "firstCallCpuMs": first.cpu,
                         "footprintAfterFirstCallDeltaMB": Double(warm.footprint - before.footprint) / 1_048_576])
        }
        report["engineCreate"] = made
        kept.removeAll()
        _ = MeasureProbe.take()

        MeasureProbe.on = true
        // ── The sample book ──────────────────────────────────────────────
        let sample = Shop()
        report["sampleLoads"] = await Self.loads(sample, .sample, runs: 7)
        report["sampleCounts"] = ["jobs": sample.orders.count, "models": sample.files.count,
                                  "customers": sample.clients.count, "spools": sample.spools.count,
                                  "machines": sample.machines.count]
        MeasureProbe.on = false
        report["sampleBoard"] = Self.board(sample)
        report["sampleLibrary"] = await Self.library(sample)

        // ── The scrubbed book ────────────────────────────────────────────
        if let bookPath = env["KHAYT_MEASURE_BOOK"] {
            let support = FileManager.default.temporaryDirectory
                .appending(path: "khayt-measure-\(UUID().uuidString)/Application Support")
            let folder = support.appending(path: StoreReader.Build.shipped.rawValue)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: bookPath),
                                             to: folder.appending(path: "khayt-store.json"))
            StoreReader.Build.supportFolderForTests = support
            let spotlight = UserDefaults.standard.object(forKey: Spotlight.defaultsKey)
            UserDefaults.standard.set(false, forKey: Spotlight.defaultsKey)
            defer {
                StoreReader.Build.supportFolderForTests = nil
                UserDefaults.standard.set(spotlight, forKey: Spotlight.defaultsKey)
                try? FileManager.default.removeItem(at: support.deletingLastPathComponent())
            }

            // The parts of a read that are not the engine, each on its own.
            var readMs: [Double] = [], filesMs: [Double] = [], ordersMs: [Double] = []
            for _ in 0..<5 {
                var raw: [String: JSONValue] = [:]
                readMs.append(await Self.timed { raw = (try? StoreReader(build: .shipped).raw) ?? [:] }.cpu)
                filesMs.append(await Self.timed { _ = Shop.decodeFiles(raw) }.cpu)
                ordersMs.append(await Self.timed { _ = try? Shop.decodeOrders(raw) }.cpu)
            }
            report["bookRead"] = ["readAndParse": Self.stats(readMs), "decodeFiles": Self.stats(filesMs),
                                  "decodeOrders": Self.stats(ordersMs)]

            let shop = Shop()
            MeasureProbe.on = true
            let before = Self.memory()
            report["bookLoads"] = await Self.loads(shop, .store(.shipped), runs: 7)
            let after = Self.memory()
            MeasureProbe.on = false
            report["bookLoadFootprintDeltaMB"] = Double(after.footprint - before.footprint) / 1_048_576
            report["bookProblem"] = shop.problem == nil ? "none" : "load reported a problem"
            report["bookCounts"] = ["jobs": shop.orders.count, "models": shop.files.count,
                                    "customers": shop.clients.count, "spools": shop.spools.count,
                                    "machines": shop.machines.count, "products": shop.productRows.count]
            report["bookBoard"] = Self.board(shop)
            MeasureProbe.on = true
            report["bookLibrary"] = await Self.library(shop)
            MeasureProbe.on = false
            await shop.settleLibraryWrites()
            await shop.load(.sample)
        }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        report["loadAverageAtEnd"] = loads
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
    }
}
