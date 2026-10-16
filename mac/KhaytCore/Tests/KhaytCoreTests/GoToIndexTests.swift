import Foundation
import Testing
@testable import KhaytCore

/// ⌘K's matching: folding, digits, ranking, permissions — and that the work a
/// keystroke does is bounded by the index, counted in rows, never timed.
struct GoToIndexTests {

    typealias Entry = GoToIndex.Entry

    static func titles(_ r: GoToIndex.Result, _ kind: GoToIndex.Kind) -> [String] {
        r.groups.first { $0.kind == kind }?.hits.map(\.entry.title) ?? []
    }

    // MARK: - Folding

    @Test("Arabic letter variants fold: hamza, tā' marbūṭa, alif maqṣūra, vowels")
    func arabicFolds() {
        let index = GoToIndex([
            Entry(kind: .customer, id: "c1", title: "أحمد العتيبي", fields: ["أحمد العتيبي"]),
            Entry(kind: .model, id: "m1", title: "مكتبة", fields: ["مكتبة"]),
            Entry(kind: .customer, id: "c2", title: "مصطفى", fields: ["مصطفى"]),
            Entry(kind: .customer, id: "c3", title: "إيمان", fields: ["إيمان"]),
        ])
        #expect(Self.titles(index.search("احمد"), .customer) == ["أحمد العتيبي"])
        #expect(Self.titles(index.search("مكتبه"), .model) == ["مكتبة"])
        #expect(Self.titles(index.search("مصطفي"), .customer) == ["مصطفى"])
        #expect(Self.titles(index.search("ايمان"), .customer) == ["إيمان"])
        // A vowelled query finds the bare spelling as well.
        #expect(Self.titles(index.search("أَحْمَد"), .customer) == ["أحمد العتيبي"])
    }

    @Test("Latin case and diacritics fold")
    func latinFolds() {
        let index = GoToIndex([Entry(kind: .customer, id: "c", title: "José Müller", fields: ["José Müller"])])
        #expect(Self.titles(index.search("JOSE"), .customer) == ["José Müller"])
        #expect(Self.titles(index.search("muller"), .customer) == ["José Müller"])
    }

    @Test("Arabic-Indic and Persian digits typed match the Western digits stored")
    func digitsFold() {
        let index = GoToIndex([
            Entry(kind: .job, id: "ORD-01002", title: "Bracket", fields: ["ORD-01002", "1002", "INV-2026-0042"]),
            Entry(kind: .customer, id: "c", title: "Sara", fields: ["Sara", "0551234567"]),
        ])
        #expect(Self.titles(index.search("١٠٠٢"), .job) == ["Bracket"])
        #expect(Self.titles(index.search("۱۰۰۲"), .job) == ["Bracket"])
        #expect(Self.titles(index.search("٢٠٢٦-٠٠٤٢"), .job) == ["Bracket"])
        #expect(Self.titles(index.search("٠٥٥١٢"), .customer) == ["Sara"])
        // And SearchText itself, which the library search shares.
        #expect(SearchText.fold("٠١٢٣٤٥٦٧٨٩") == "0123456789")
        #expect(SearchText.fold("۰۱۲۳۴۵۶۷۸۹") == "0123456789")
    }

    // MARK: - Ranking

    @Test("a prefix ranks above a word start, which ranks above a substring")
    func prefixFirst() {
        let index = GoToIndex([
            Entry(kind: .customer, id: "1", title: "Fahad", fields: ["Fahad"]),
            Entry(kind: .customer, id: "2", title: "Noura Ahmad", fields: ["Noura Ahmad"]),
            Entry(kind: .customer, id: "3", title: "Ahmad", fields: ["Ahmad"]),
            Entry(kind: .customer, id: "4", title: "Ah", fields: ["Ah"]),
        ])
        #expect(Self.titles(index.search("ah"), .customer) == ["Ah", "Ahmad", "Noura Ahmad", "Fahad"])
    }

    @Test("a hit on an earlier key ranks above the same hit on a later one; ties keep the index's order")
    func keyOrderThenPosition() {
        let index = GoToIndex([
            Entry(kind: .job, id: "a", title: "older, by part", fields: ["Lamp", "Cube stand"]),
            Entry(kind: .job, id: "b", title: "by name", fields: ["Cube", "Other"]),
            Entry(kind: .job, id: "c", title: "newer, by part", fields: ["Vase", "Cube holder"]),
        ])
        #expect(Self.titles(index.search("cube"), .job) == ["by name", "older, by part", "newer, by part"])
    }

    @Test("several words match when each is somewhere in the record")
    func severalWords() {
        let index = GoToIndex([Entry(kind: .customer, id: "c", title: "Ahmad Saleh", fields: ["Ahmad Saleh", "0550000000"])])
        #expect(Self.titles(index.search("saleh ahmad"), .customer) == ["Ahmad Saleh"])
        #expect(Self.titles(index.search("saleh nobody"), .customer).isEmpty)
    }

    @Test("at most the asked-for number per group, and the best of them")
    func perGroupCap() {
        let entries = (0..<50).map { Entry(kind: .model, id: "\($0)", title: "Part \($0)", fields: ["Part \($0)"]) }
            + [Entry(kind: .model, id: "x", title: "part", fields: ["part"])]
        let r = GoToIndex(entries).search("part", perGroup: 8)
        let hits = r.groups.first?.hits ?? []
        #expect(hits.count == 8)
        #expect(hits.first?.entry.id == "x", "the exact match is first even though it was added last")
        #expect(r.matched.count == 51, "every match is remembered for narrowing, not only the eight shown")
    }

    @Test("groups are ordered by their best hit, then by the fixed order")
    func groupOrder() {
        let index = GoToIndex([
            Entry(kind: .job, id: "j", title: "Big jobs lamp", fields: ["Big jobs lamp"]),
            Entry(kind: .screen, id: "screen:jobs", title: "Jobs", fields: ["Jobs"]),
        ])
        let r = index.search("jobs")
        #expect(r.groups.map(\.kind) == [.screen, .job])
        let merged = GoToIndex.merged([index.search("lamp"), index.search("jobs")])
        #expect(merged.first?.kind == .screen)
    }

    // MARK: - Permissions

    @Test("a kind not allowed is never looked at, let alone shown")
    func kindsFilter() {
        let index = GoToIndex([
            Entry(kind: .job, id: "j", title: "Ahmad's lamp", fields: ["Ahmad's lamp", "Ahmad"]),
            Entry(kind: .customer, id: "c", title: "Ahmad", fields: ["Ahmad"]),
            Entry(kind: .screen, id: "s", title: "Dashboard", fields: ["Dashboard"]),
        ])
        let r = index.search("ahmad", kinds: [.screen, .model])
        #expect(r.groups.isEmpty)
        #expect(r.touched == 1, "only the screen row was examined")
        #expect(index.search("ahmad", kinds: []).touched == 0)
        // Narrowing never carries a wider answer into a narrower permission.
        let wide = index.search("ah")
        let narrow = index.search("ahm", kinds: [.customer], narrowing: wide)
        #expect(narrow.groups.map(\.kind) == [.customer])
    }

    // MARK: - Bounded work

    /// A synthetic shop of 10,000 jobs and 600 customers, and the rows each
    /// keystroke touches. Counted, not timed: a test that asserts latency is
    /// a test that fails on a busy CI runner and teaches people to rerun it.
    @Test("10k jobs: one pass per query at most, and a longer query looks only at what the last one matched")
    func tenThousandJobs() {
        let names = ["Ahmad", "Fahad", "Noura", "Sara", "Turki", "Reem", "أحمد", "نورة", "سارة", "فهد"]
        var entries: [Entry] = []
        for i in 0..<10_000 {
            let id = String(format: "ORD-%05d", i)
            entries.append(Entry(kind: .job, id: id, title: "Job \(i)", subtitle: id,
                                 fields: [id, String(i), "INV-2026-\(i)", names[i % names.count] + " \(i % 600)",
                                          "Part \(i % 37)", "Bracket \(i % 11)"]))
        }
        for c in 0..<600 {
            entries.append(Entry(kind: .customer, id: "C\(c)", title: names[c % names.count] + " \(c)",
                                 fields: [names[c % names.count] + " \(c)", "05\(c)"]))
        }
        let index = GoToIndex(entries)
        let all = index.count
        #expect(all == 10_600)

        // The first key looks at every row once — and no more than once.
        let a = index.search("a")
        #expect(a.touched == all)
        #expect(a.groups.allSatisfy { $0.hits.count <= 8 })

        // Each further key looks only at what the one before it matched.
        var previous = a
        for q in ["ah", "ahm", "ahma", "ahmad"] {
            let r = index.search(q, narrowing: previous)
            #expect(r.touched == previous.matched.count, "\(q) looked beyond the last answer")
            #expect(r.touched <= all)
            previous = r
        }
        #expect(previous.matched.count < all / 5, "the narrowing had nothing to narrow")
        #expect(Self.titles(previous, .customer).first == "Ahmad 0", "prefix first, then the index's order")

        // A query that does NOT extend the last one starts again — once.
        let fresh = index.search("noura", narrowing: previous)
        #expect(fresh.touched == all)

        // Without the jobs (a role that cannot see them) the jobs are not
        // even walked past.
        let customersOnly = index.search("ahmad", kinds: [.customer])
        #expect(customersOnly.touched == 600)

        // An Arabic-Indic number finds the one job, after one pass.
        let one = index.search("٠٩٨٧٦")
        #expect(one.touched == all)
        #expect(Self.titles(one, .job).first == "Job 9876")
    }
}
