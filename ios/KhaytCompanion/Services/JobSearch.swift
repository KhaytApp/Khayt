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
                              subtitle: "\([id, client, stage].filter { !$0.isEmpty }.joined(separator: " · "))")
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
        // Read BEFORE the book is: an index begun with the lock off must not
        // decide after a wait that customers may be named.
        let hide = JobSearch.hidesCustomers
        guard let book = try? CompanionBook.inSharedContainer(), book.exists,
              let rows = try? await BookReader(book: book).recentOrders(limit: 400) else { return [] }
        return rows.map { o in
            entity(id: o.id, title: o.displayTitle, client: o.client,
                   stage: OrderStatus(rawValue: o.status)?.localizedLabel ?? o.status, hideCustomer: hide)
        }
    }

    /// One job for Spotlight, Siri and Shortcuts. While the app lock is on
    /// (`hideCustomer`), the job is still found by its number, title and
    /// stage, but carries no customer: not shown, and not searchable by
    /// their name (Turki, Nov 24).
    static func entity(id: String, title: String, client: String?, stage: String, hideCustomer: Bool) -> JobSearchEntity {
        JobSearchEntity(id: id, title: title, client: hideCustomer ? "" : (client ?? ""), stage: stage)
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
    /// Whether this phone is a floor phone, asked at each index (the app
    /// passes `ConnectionSettings.isFloorPhone`; a test sets its own).
    nonisolated(unsafe) static var floorPhone: () -> Bool = { false }
    private static var indexedAt: Date?

    /// Whether the app lock is in force on this phone, where the intents
    /// (which run without the app's screens) can read it.
    static let lockKey = "khayt.lock.inForce"
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    /// Before this build's gate has said (Siri or a Shortcut running before
    /// the first launch after the update), the person's own choice, else
    /// hidden: never a customer named on a guess (release review L3).
    nonisolated static var hidesCustomers: Bool {
        if let inForce = defaults.object(forKey: lockKey) as? Bool { return inForce }
        return defaults.object(forKey: lockChoiceKey) as? Bool ?? true
    }
    /// `AppLock`'s own key for the person's choice.
    nonisolated static let lockChoiceKey = "khayt.lock.choice"

    /// The build whose index Spotlight holds.
    static let indexedBuildKey = "khayt.spotlight.indexedBuild"

    /// The first launch of a new build (also one Siri starts in the
    /// background) replaces what the older build put in Spotlight at once:
    /// it may name customers this build hides while the lock is on (release
    /// review L3). Later launches do nothing here.
    static func reindexIfUpdated(build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                                 into spotlight: any JobIndex = CSSearchableIndex.default()) async {
        guard defaults.string(forKey: indexedBuildKey) != build else { return }
        defaults.set(build, forKey: indexedBuildKey)
        indexedAt = nil
        await index(into: spotlight)
    }

    /// The lock turned on or off: what Spotlight holds is replaced at once,
    /// without customers while it is on and with them again when it is off.
    /// Nothing happens when it has not changed.
    static func lockChanged(inForce: Bool, into spotlight: any JobIndex = CSSearchableIndex.default()) async {
        guard defaults.object(forKey: lockKey) as? Bool != inForce else { return }
        defaults.set(inForce, forKey: lockKey)
        generation += 1
        indexedAt = nil
        await index(into: spotlight)
    }

    /// Hand Spotlight the jobs the phone holds, at most every ten minutes.
    ///
    /// The jobs indexed last time go first. Indexing only ADDS: a job cut
    /// from the book, deleted on the Mac, or from the sample shop the phone
    /// opened before its real one, stayed findable for good.
    static func index(now: Date = Date(), into spotlight: any JobIndex = CSSearchableIndex.default()) async {
        // A floor phone (operator or viewer) keeps none of the shop's jobs in
        // Spotlight, even while a book it may no longer hold is still on disk
        // waiting for its edits to be sent (M2): customer names must not come
        // back through a re-index (the lock's, or the next one).
        if floorPhone() {
            indexedAt = nil
            try? await spotlight.deleteJobs()
            return
        }
        if let last = indexedAt, now.timeIntervalSince(last) < 600 { return }
        indexedAt = now
        // An index that was under way when the lock changed is stale: it may
        // hold customers the lock now hides (or lack ones it now shows). It
        // drops its write; the lock's own index replaces what is there.
        let mine = generation
        let jobs = await JobSearchQuery.all()
        guard mine == generation else { return }
        await reindex(jobs, into: spotlight)
    }

    /// Counts the lock's changes, so a stale index can tell it is one.
    private static var generation = 0

    static func reindex(_ jobs: [JobSearchEntity], into spotlight: any JobIndex) async {
        try? await spotlight.deleteJobs()
        guard !jobs.isEmpty else { return }
        try? await spotlight.indexJobs(jobs)
    }

    /// Unpairing: nothing of the shop stays in Spotlight, and the next shop
    /// is indexed at once rather than ten minutes on.
    static func forget(_ spotlight: CSSearchableIndex = .default()) {
        indexedAt = nil
        spotlight.deleteAllSearchableItems(completionHandler: nil)
    }
}

/// Where the jobs go: Spotlight, or a test's stand-in.
protocol JobIndex {
    func deleteJobs() async throws
    func indexJobs(_ jobs: [JobSearchEntity]) async throws
}

extension CSSearchableIndex: JobIndex {
    func deleteJobs() async throws { try await deleteAppEntities(ofType: JobSearchEntity.self) }
    func indexJobs(_ jobs: [JobSearchEntity]) async throws { try await indexAppEntities(jobs) }
}
