import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Every model's figures as `load` worked them out before they were batched:
/// one engine call per model, in library order, exactly as the four loops
/// did. The batched path is held to this, figure for figure.
struct OneAtATime {
    var fits: [String: KhaytEngine.Fit] = [:]
    var estimates: [String: KhaytEngine.MeshEstimate] = [:]
    var licences: [String: KhaytEngine.Standing] = [:]
    var risks: [String: KhaytEngine.PrintRiskReport] = [:]

    static func work(_ files: [LibraryFile], machines: [JSONValue], settings: [String: JSONValue],
                     orders: [JSONValue], nozzle: Double?, engine: KhaytEngine) async -> OneAtATime {
        var out = OneAtATime()
        for file in files {
            if !machines.isEmpty, let mesh = file.mesh,
               let fit = try? await engine.bestFit((x: mesh.x, y: mesh.y, z: mesh.z), among: machines) {
                out.fits[file.id] = fit
            }
            if let mesh = file.mesh, mesh.volumeMm3 > 0 {
                var area = 0.0
                if case .number(let a)? = file.riskAnalysis?["totalAreaMm2"], a > 0 { area = a }
                if let e = try? await engine.estimateMesh(
                    volumeMm3: mesh.volumeMm3, areaMm2: area, bbox: (x: mesh.x, y: mesh.y, z: mesh.z),
                    settings: settings, orders: orders) {
                    out.estimates[file.id] = e
                }
            }
            if !(file.licence ?? "").isEmpty || !(file.source ?? "").isEmpty,
               let standing = try? await engine.licenceStanding(source: file.source, licence: file.licence) {
                out.licences[file.id] = standing
            }
            if let analysis = file.riskAnalysis,
               let report = try? await engine.assessModel(
                analysis: analysis, nozzleDiameter: nozzle,
                bbox: file.mesh.map { (x: $0.x, y: $0.y, z: $0.z) }) {
                out.risks[file.id] = report
            }
        }
        return out
    }
}

/// A fit or a standing as text, since neither type is Equatable.
func described(_ fit: KhaytEngine.Fit?) -> String {
    guard let fit else { return "none" }
    let machine = (try? JSONValue.encode(fit.machine ?? .null)).flatMap { String(data: $0, encoding: .utf8) }
    return "\(fit.verdict)|\(fit.checked)|\(machine ?? "?")"
}

func described(_ s: KhaytEngine.Standing?) -> String {
    guard let s else { return "none" }
    return "\(s.known)|\(s.licence)|\(s.source)|\(String(describing: s.sellable))|\(s.attribution)|"
        + String(describing: s.derivatives)
}

/// Where two sets of figures differ, as sentences. Empty when identical.
func differences(_ new: ModelFigures, _ old: OneAtATime) -> [String] {
    var out: [String] = []
    if Set(new.fits.keys) != Set(old.fits.keys) { out.append("fits cover different models") }
    for (id, fit) in old.fits where described(new.fits[id]) != described(fit) { out.append("fit \(id)") }
    if new.estimates != old.estimates { out.append("estimates differ") }
    if Set(new.licences.keys) != Set(old.licences.keys) { out.append("licences cover different models") }
    for (id, s) in old.licences where described(new.licences[id]) != described(s) { out.append("licence \(id)") }
    if new.risks != old.risks { out.append("risks differ") }
    return out
}

@MainActor
@Suite(.serialized)
struct LoadFiguresTests {

    static func inputs(_ root: [String: JSONValue]) -> LoadFigures.Inputs {
        let files = Shop.decodeFiles(root).items
        let machines = Shop.rows(root, "machines")
        var widest: Double?
        for case .object(let m) in machines {
            if case .number(let d)? = m["nozzleDiameter"], d > 0 { widest = max(widest ?? 0, d) }
        }
        return .init(files: files, machines: machines, settings: Shop.settings(root),
                     orders: Shop.rows(root, "printLog"), nozzle: widest)
    }

    @Test("batched figures are the per-model figures, model for model, over a varied library")
    func batchedEqualsOneAtATime() async throws {
        let engine = try KhaytEngine()
        // Over two batches, so the seam between them is crossed.
        let root = FiguresBook.synthesize(models: LoadFigures.batch * 2 + 317, logo: false)
        let given = Self.inputs(root)
        let old = await OneAtATime.work(given.files, machines: given.machines, settings: given.settings,
                                        orders: given.orders, nozzle: given.nozzle, engine: engine)
        let maybeNew = await LoadFigures.work(given, engine: engine, wanted: { true })
        let new = try #require(maybeNew)
        let diff = differences(new, old)
        #expect(diff.isEmpty, "\(diff.prefix(10))")

        // And the library reached the cases it is there to reach — a test
        // comparing two empty dictionaries proves nothing.
        let verdicts = Set(old.fits.values.map(\.verdict))
        #expect(verdicts == ["fits", "rotate", "none"])
        #expect(old.estimates.values.contains { $0.isCalibrated })
        #expect(old.estimates.values.contains { $0.shellUnreliable })
        let sources = Set(old.estimates.values.compactMap(\.shellSource))
        #expect(sources == ["surface-area", "assumed"])
        let sellable = Set(old.licences.values.map { String(describing: $0.sellable) })
        #expect(sellable.count == 3, "sellable should be yes, no and unknown: \(sellable)")
        #expect(old.risks.values.contains { !$0.risks.isEmpty })
        #expect(old.risks.values.contains { $0.risks.isEmpty })
        // Models the one-model call could not answer stay unanswered: an
        // infinite and a NaN volume, a zero one, an unreadable key.
        let measured = given.files.filter { $0.geometryKey != nil }.count
        #expect(old.estimates.count < measured)
        #expect(old.estimates.count > measured / 2)
        // A summary describing a replaced file is not judged by either.
        let stale = given.files.filter { $0.printRisk != nil && $0.riskAnalysis == nil }
        #expect(!stale.isEmpty)
        #expect(stale.allSatisfy { new.risks[$0.id] == nil })
    }

    @Test("work an overtaken load no longer wants stops between batches")
    func unwantedWorkStops() async throws {
        let engine = try KhaytEngine()
        let given = Self.inputs(FiguresBook.synthesize(models: LoadFigures.batch * 3, logo: false))
        var asked = 0
        let answer = await LoadFigures.work(given, engine: engine, wanted: {
            asked += 1
            return asked < 2
        })
        #expect(answer == nil)
        // Asked after the Swift figures, then after the first batch — and
        // not a third time, because it had already stopped.
        #expect(asked == 2)
    }

    @Test("no engine, no figures — as when every figure went through it")
    func noEngineNoFigures() async throws {
        let given = Self.inputs(FiguresBook.synthesize(models: 50, logo: false))
        let answer = await LoadFigures.work(given, engine: nil, wanted: { true })
        let figures = try #require(answer)
        #expect(figures.fits.isEmpty && figures.estimates.isEmpty)
        #expect(figures.licences.isEmpty && figures.risks.isEmpty)
    }
}

/// The two that open a book live in the one serialised suite that sets the
/// test support folder (`StoreReader.Build.supportFolderForTests`): it is a
/// single global, and two suites setting it at once open each other's books.
extension LibraryEditPerfTests {

    @Test("a load puts up exactly the per-model figures")
    func loadEqualsOneAtATime() async throws {
        try await withPerfBook(FiguresBook.synthesize(models: 900, logo: false)) { shop, _ in
            let engine = try #require(shop.engine)
            let old = await OneAtATime.work(shop.files, machines: shop.machineRows,
                                            settings: shop.settingsDict, orders: shop.orderRows,
                                            nozzle: shop.nozzleForRisk, engine: engine)
            #expect(!old.fits.isEmpty && !old.estimates.isEmpty && !old.licences.isEmpty)
            let shown = ModelFigures(fits: shop.fits, estimates: shop.estimates,
                                     licences: shop.licences, risks: shop.risks)
            let diff = differences(shown, old)
            #expect(diff.isEmpty, "\(diff.prefix(10))")
        }
    }

    @Test("an edit puts up the per-model figures for the model it touched")
    func editEqualsOneAtATime() async throws {
        try await withPerfBook(FiguresBook.synthesize(models: 60, logo: false)) { shop, _ in
            let engine = try #require(shop.engine)
            let file = try #require(shop.files.first { $0.mesh != nil && $0.riskAnalysis != nil })
            shop.toggleFavourite(file)
            await shop.settleLibraryWrites()
            let touched = try #require(shop.files.first { $0.id == file.id })
            let old = await OneAtATime.work([touched], machines: shop.machineRows,
                                            settings: shop.settingsDict, orders: shop.orderRows,
                                            nozzle: shop.nozzleForRisk, engine: engine)
            #expect(old.estimates[file.id] != nil)
            #expect(shop.estimates[file.id] == old.estimates[file.id])
            #expect(described(shop.fits[file.id]) == described(old.fits[file.id]))
            #expect(shop.risks[file.id] == old.risks[file.id])
        }
    }
}
