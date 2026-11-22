import Foundation
import KhaytCore

/// What `load` works out for every model in the library: which machine it
/// fits, what it would weigh and take, what its licence permits, and what its
/// stored overhang summary says against this shop's nozzle.
///
/// ── WHY IT IS ITS OWN STEP ────────────────────────────────────────────────
///
/// It was four loops in `load`, one engine round trip per model each, and on
/// the shop's real book (9,802 models, 3,553 measured, 3,097 with a summary)
/// that was most of a minute after every launch, scan and reload. The mesh
/// estimate was the bulk of it: each call handed over the shop's whole
/// settings — 1.1 MB with the logo in them — and its print log, and learned the
/// grams-per-hour rate again, once per model.
///
/// Now:
///
/// - **fits and licences** are Swift ports (`PrintFit`, `ModelLicence`), so
///   they are asked directly, off the main thread, without a hop per model;
/// - **estimates and risks** go to the engine in batches — the settings and
///   the log cross once a batch, the rate is learned once a batch — through
///   `KhaytEngine.estimateMeshes` and `assessModels`, which give each model the
///   answer the one-model call gives it (`EngineBatchParityTests`);
/// - **between batches** the caller is asked whether it still wants the
///   answer, so a load that a newer one has overtaken stops spending the
///   engine on a book nobody will see.
///
/// Nothing here is assigned to the shop. The caller takes the whole answer
/// and puts it up at once, if it is still the newest — see `Shop.load`.
struct ModelFigures: Sendable {
    var fits: [String: KhaytEngine.Fit] = [:]
    var estimates: [String: KhaytEngine.MeshEstimate] = [:]
    var licences: [String: KhaytEngine.Standing] = [:]
    var risks: [String: KhaytEngine.PrintRiskReport] = [:]
}

enum LoadFigures {

    /// Models per engine crossing. Large enough that the settings crossing
    /// once a batch is noise, small enough that an overtaken load stops within
    /// a fraction of a second.
    static let batch = 1_000

    /// Everything `work` reads, taken from the shop at one moment.
    struct Inputs: Sendable {
        let files: [LibraryFile]
        let machines: [JSONValue]
        let settings: [String: JSONValue]
        let orders: [JSONValue]
        /// The widest nozzle any machine records (`Shop.nozzleForRisk`).
        let nozzle: Double?
    }

    /// Work out every model's figures, or nil if `wanted` said stop.
    ///
    /// Each figure follows the rule the old per-model loop followed, model
    /// for model:
    ///
    /// - a fit for every model with a mesh, when there is an engine and at
    ///   least one machine;
    /// - an estimate for every mesh with a volume, using the stored summary's
    ///   surface area where there is one (`priceMeshes`);
    /// - a licence standing for every model that names a licence or a source;
    /// - a risk report for every model whose stored summary still describes its
    ///   file (`LibraryFile.riskAnalysis`), judged against the widest nozzle,
    ///   with the measured box and no bed (`Shop.judge`).
    ///
    /// No engine, no figures — as before, when every call went through it.
    static func work(_ inputs: Inputs, engine: KhaytEngine?,
                     wanted: @MainActor () -> Bool) async -> ModelFigures? {
        guard let engine else { return ModelFigures() }
        var out = await BookWork.run { native(inputs) }
        guard await wanted() else { return nil }

        // Estimates, a batch at a time.
        let meshes = meshInputs(inputs.files)
        var start = 0
        while start < meshes.count {
            let part = Array(meshes[start..<min(start + batch, meshes.count)])
            let answers = (try? await engine.estimateMeshes(part.map(\.input), settings: inputs.settings,
                                                           orders: inputs.orders)) ?? []
            for (k, answer) in answers.enumerated() { if let answer { out.estimates[part[k].id] = answer } }
            guard await wanted() else { return nil }
            start += batch
        }

        // Stored risks, a batch at a time.
        let judged = riskInputs(inputs.files)
        start = 0
        while start < judged.count {
            let part = Array(judged[start..<min(start + batch, judged.count)])
            let reports = (try? await engine.assessModels(part.map(\.input),
                                                         nozzleDiameter: inputs.nozzle)) ?? []
            for (k, report) in reports.enumerated() { if let report { out.risks[part[k].id] = report } }
            guard await wanted() else { return nil }
            start += batch
        }
        return out
    }

    /// `worked`, out of `figured`, for a library that is `now` — with the
    /// figures on screen (`shown`) kept for every model whose record changed
    /// in between.
    ///
    /// A library edit that lands while a load is working (a licence set, a
    /// model re-measured) puts its own figures up for the models it touched,
    /// from the newer record (`Shop.showLibraryWritten`). The load's figures
    /// for those models came from the older record, and putting them up
    /// would show a model just marked non-commercial as sellable again until
    /// the next reload. A model the edit is still writing keeps what is shown,
    /// and its write puts the right figures up when it lands.
    ///
    /// Risks are merged by the caller, so a changed model's risk is simply
    /// left out here: the merge then keeps whatever is shown.
    static func settle(_ worked: ModelFigures, figured: [LibraryFile], now: [LibraryFile],
                       shown: ModelFigures) -> ModelFigures {
        var was: [String: LibraryFile] = [:]
        for file in figured { was[file.id] = file }
        var out = worked
        var present = Set<String>()
        for file in now {
            present.insert(file.id)
            guard was[file.id] != file else { continue }
            out.fits[file.id] = shown.fits[file.id]
            out.estimates[file.id] = shown.estimates[file.id]
            out.licences[file.id] = shown.licences[file.id]
            out.risks[file.id] = nil
        }
        // Gone from the library meanwhile: no figures to put back for it.
        for id in was.keys where !present.contains(id) {
            out.fits[id] = nil; out.estimates[id] = nil; out.licences[id] = nil; out.risks[id] = nil
        }
        return out
    }

    /// Fits and licences: Swift rules, no engine needed.
    static func native(_ inputs: Inputs) -> ModelFigures {
        var out = ModelFigures()
        for file in inputs.files {
            if !inputs.machines.isEmpty, let mesh = file.mesh {
                out.fits[file.id] = KhaytEngine.fit((x: mesh.x, y: mesh.y, z: mesh.z),
                                                    among: inputs.machines)
            }
            if !(file.licence ?? "").isEmpty || !(file.source ?? "").isEmpty {
                out.licences[file.id] = KhaytEngine.standing(source: file.source, licence: file.licence)
            }
        }
        return out
    }

    /// The meshes to price, in library order — `priceMeshes`'s choice of
    /// which, and of the area.
    static func meshInputs(_ files: [LibraryFile]) -> [(id: String, input: KhaytEngine.MeshInput)] {
        files.compactMap { file in
            guard let mesh = file.mesh, mesh.volumeMm3 > 0 else { return nil }
            // The surface area where the shop has already paid for it — see
            // `Shop.priceMeshes`.
            var area = 0.0
            if case .number(let a)? = file.riskAnalysis?["totalAreaMm2"], a > 0 { area = a }
            return (file.id, KhaytEngine.MeshInput(volumeMm3: mesh.volumeMm3, areaMm2: area,
                                                   bbox: (x: mesh.x, y: mesh.y, z: mesh.z)))
        }
    }

    /// The summaries to judge, in library order.
    static func riskInputs(_ files: [LibraryFile]) -> [(id: String, input: KhaytEngine.RiskInput)] {
        files.compactMap { file in
            guard let analysis = file.riskAnalysis else { return nil }
            return (file.id, KhaytEngine.RiskInput(
                analysis: analysis, bbox: file.mesh.map { (x: $0.x, y: $0.y, z: $0.z) }))
        }
    }
}
