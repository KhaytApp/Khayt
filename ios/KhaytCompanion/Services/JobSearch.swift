import AppIntents
import CoreSpotlight
import Foundation

/// Every job the phone holds — open, and the newest finished — for Spotlight
/// and Siri to find by number, project or customer ("#1042", "Maya's
/// planter"), and to open. `ShopJobEntity` stays the narrower list of jobs
/// that can still be moved on.
struct JobSearchEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Khayt job"
    static let defaultQuery = JobSearchQuery()

    let id: String
    @Property(title: "Project") var title: String
    @Property(title: "Customer") var client: String
    @Property(title: "Stage") var stage: String

    init(id: String, title: String, client: String, stage: String) {
        self.id = id
        self.title = title
        self.client = client
        self.stage = stage
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: "\(["#" + id, client, stage].filter { !$0.isEmpty }.joined(separator: " · "))")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let a = defaultAttributeSet
        a.title = title
        a.contentDescription = [client, stage].filter { !$0.isEmpty }.joined(separator: " · ")
        a.keywords = [id, client].filter { !$0.isEmpty }
        return a
    }
}

struct JobSearchQuery: EntityStringQuery {
    @MainActor
    static func all() async -> [JobSearchEntity] {
        guard let book = try? CompanionBook.inSharedContainer(), book.exists,
              let rows = try? await BookReader(book: book).recentOrders(limit: 400) else { return [] }
        return rows.map { o in
            JobSearchEntity(id: o.id,
                            title: (o.project?.isEmpty == false ? o.project! : o.id),
                            client: o.client ?? "",
                            stage: OrderStatus(rawValue: o.status)?.localizedLabel ?? o.status)
        }
    }

    func entities(for identifiers: [String]) async throws -> [JobSearchEntity] {
        await Self.all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [JobSearchEntity] {
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !q.isEmpty else { return [] }
        return await Self.all().filter {
            $0.id.lowercased().contains(q) || $0.title.lowercased().contains(q) || $0.client.lowercased().contains(q)
        }
    }

    func suggestedEntities() async throws -> [JobSearchEntity] { Array(await Self.all().prefix(20)) }
}

/// Open a job — what a Spotlight result does when tapped.
struct OpenJobIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open a job"
    @Parameter(title: "Job") var target: JobSearchEntity

    init() {}
    init(target: JobSearchEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        JobSearch.open?(target.id)
        return .result()
    }
}

@MainActor
enum JobSearch {
    /// Set by the app: open a job by id.
    static var open: ((String) -> Void)?
    private static var indexedAt: Date?

    /// Hand Spotlight the jobs the phone holds, at most every ten minutes.
    static func index(now: Date = Date()) async {
        if let last = indexedAt, now.timeIntervalSince(last) < 600 { return }
        indexedAt = now
        let jobs = await JobSearchQuery.all()
        guard !jobs.isEmpty else { return }
        try? await CSSearchableIndex.default().indexAppEntities(jobs)
    }
}
