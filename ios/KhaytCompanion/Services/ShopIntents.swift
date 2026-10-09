import AppIntents
import Foundation

// Shop actions for Siri, Shortcuts, Spotlight and the Action button — the
// things a shop does with its hands full, without opening the app.
//
// "Advance a job" and "Filament left" run in the background against the
// phone's own book: the same write the order page makes (`BookWriter`), sent
// on like any edit. "Log a failed print" and "Scan a spool" open the app on
// the sheet that does it.

/// A job in the shop's queue, for Siri and Shortcuts to name.
struct ShopJobEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Job"
    static let defaultQuery = ShopJobQuery()

    let id: String
    let title: String
    let stage: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(stage)")
    }
}

struct ShopJobQuery: EntityQuery {
    @MainActor
    private func open() async -> [ShopJobEntity] {
        guard let book = try? CompanionBook.inSharedContainer(), book.exists,
              let queue = try? await BookReader(book: book).queue() else { return [] }
        return queue.compactMap { o in
            guard let stage = OrderStatus(rawValue: o.status), stage.nextInQueue != nil else { return nil }
            return ShopJobEntity(id: o.id, title: o.displayTitle, stage: stage.localizedLabel)
        }
    }

    func entities(for identifiers: [String]) async throws -> [ShopJobEntity] {
        await open().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ShopJobEntity] { await open() }
}

/// Move a job to its next stage — the order page's big button.
struct AdvanceJobIntent: AppIntent {
    static let title: LocalizedStringResource = "Advance a job"
    static let description = IntentDescription("Moves a job in the queue to its next stage.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Job") var job: ShopJobEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let api = KhaytAPIClient(settings: ConnectionSettings())
        let queue = (try? await api.fetchQueue()) ?? []
        guard let order = queue.first(where: { $0.id == job.id }),
              let next = OrderStatus(rawValue: order.status)?.nextInQueue else {
            return .result(dialog: IntentDialog(stringLiteral: L10n.tr("intent.advance.gone")))
        }
        try await api.updateOrderStatus(orderId: order.id, status: next.rawValue)
        return .result(dialog: IntentDialog(stringLiteral: L10n.format("intent.advance.done", order.displayTitle, next.localizedLabel)))
    }
}

/// "How much PLA is left?" — the shelf, from the book.
struct FilamentLeftIntent: AppIntent {
    static let title: LocalizedStringResource = "Filament left"
    static let description = IntentDescription("Says how much of a material is left on the shelf.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Material") var material: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let book = try? CompanionBook.inSharedContainer(), book.exists,
              let spools = try? await BookReader(book: book).inventory() else {
            return .result(dialog: IntentDialog(stringLiteral: L10n.tr("intent.no_book")))
        }
        return .result(dialog: IntentDialog(stringLiteral: Self.answer(spools, material: material)))
    }

    /// The sentence, pure, so it can be tested: the grams left of a material
    /// across its spools, or the whole shelf by material when none is named.
    static func answer(_ spools: [InventorySpool], material: String?) -> String {
        func grams(_ s: InventorySpool) -> Int { Int((s.remainingGrams ?? 0).rounded()) }
        let wanted = material?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if !wanted.isEmpty {
            let matching = spools.filter { ($0.material ?? "").lowercased() == wanted }
            guard !matching.isEmpty else { return L10n.format("intent.filament.none", material ?? "") }
            let total = matching.reduce(0) { $0 + grams($1) }
            return L10n.format("intent.filament.one", L10n.grams(total), material ?? "", matching.count)
        }
        var byMaterial: [String: Int] = [:]
        for s in spools { byMaterial[s.material ?? "—", default: 0] += grams(s) }
        guard !byMaterial.isEmpty else { return L10n.tr("intent.filament.empty") }
        return byMaterial.sorted { $0.key < $1.key }
            .map { "\($0.key): \(L10n.grams($0.value))" }
            .joined(separator: " · ")
    }
}

// "Log a failed print" and "Scan a spool" live in KhaytWidget/ShopControls.swift:
// they are also Control Center buttons, so the widget extension compiles them too.
