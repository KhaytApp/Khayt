import Foundation

/// The printer chips on a library tile: which of the shop's machines a model
/// goes on, and where it can start now.
///
/// ── THE INSPECTOR'S ANSWER, DRAWN SMALLER ─────────────────────────────────
///
/// A chip is one machine's `ModelReadiness.State` — the very list the model
/// page's "Where it can print" draws (`Shop.machineFits`) — so a tile and the
/// page beside it can never say two things about one printer. Nothing here
/// works out a fit: it only decides which of those answers a tile has room
/// for, in what order, and what "+2" stands for.
///
/// ── WHAT A TILE SHOWS ─────────────────────────────────────────────────────
///
/// - Ready (loaded and on the bed) first, then "fits, change a spool", then
///   fits — the order a shop picks a printer in — each kept in the machines'
///   own order.
/// - A machine it is too big for is left off: the tile is a list of where it
///   CAN go. The page still names each refusal.
/// - Too big for every machine that said anything is one chip of its own,
///   as the page's one sentence is.
/// - A machine that knows nothing (no bed, no mesh, no spools) is not there at
///   all — unknown is not a refusal and not a promise.
///
/// "Fits <machine>" in the filter bar is the same question: a model is in it
/// exactly when that machine's chip is on its tile (`shows`).
public enum LibraryFitChips {

    /// How a chip is drawn.
    public enum Tone: String, Sendable, Hashable, CaseIterable {
        /// Can start now: loaded and on the bed (turned or not).
        case ready
        /// Goes on the bed; a spool has to change first.
        case swap
        /// Goes on the bed; nothing known about its spools.
        case fits
    }

    public struct Chip: Sendable, Hashable, Identifiable {
        public let machineId: String
        /// The machine's whole name, for the hover and VoiceOver.
        public let name: String
        /// What the chip says (`short`).
        public let label: String
        public let tone: Tone
        /// Only on the bed turned a quarter turn.
        public let turned: Bool
        public var id: String { machineId }

        public init(machineId: String, name: String, label: String, tone: Tone, turned: Bool) {
            self.machineId = machineId
            self.name = name
            self.label = label
            self.tone = tone
            self.turned = turned
        }
    }

    /// One tile's chips.
    public struct Row: Sendable, Hashable {
        public var chips: [Chip] = []
        /// Every machine that said anything is too small for it.
        public var tooBigEverywhere = false

        public init(chips: [Chip] = [], tooBigEverywhere: Bool = false) {
            self.chips = chips
            self.tooBigEverywhere = tooBigEverywhere
        }

        /// Nothing to draw.
        public var isEmpty: Bool { chips.isEmpty && !tooBigEverywhere }
    }

    /// Does this machine's chip go on the tile? Every state but a refusal.
    public static func shows(_ state: ModelReadiness.State) -> Bool { state != .tooBig }

    public static func tone(_ state: ModelReadiness.State) -> Tone? {
        switch state {
        case .ready, .readyTurned: .ready
        case .needsSwap: .swap
        case .fits, .fitsTurned: .fits
        case .tooBig: nil
        }
    }

    /// A tile's chips from each machine's answer, in the machines' order.
    public static func row(_ fits: [(id: String, name: String, state: ModelReadiness.State)]) -> Row {
        guard !fits.isEmpty else { return Row() }
        if fits.allSatisfy({ $0.state == .tooBig }) { return Row(chips: [], tooBigEverywhere: true) }
        let rank: [Tone: Int] = [.ready: 0, .swap: 1, .fits: 2]
        let chips = fits.enumerated().compactMap { i, f -> (Int, Chip)? in
            guard let tone = tone(f.state) else { return nil }
            return (i, Chip(machineId: f.id, name: f.name, label: short(f.name), tone: tone,
                            turned: f.state == .readyTurned || f.state == .fitsTurned))
        }
        .sorted { a, b in
            let ra = rank[a.1.tone]!, rb = rank[b.1.tone]!
            return ra != rb ? ra < rb : a.0 < b.0
        }
        .map(\.1)
        return Row(chips: chips)
    }

    /// The row with one machine's chip moved to the front — the machine a
    /// Fits or Ready on filter names, so a tile under "Fits X1C" never hides
    /// the X1C chip behind "+1". Unchanged when that machine has no chip.
    public static func leading(_ row: Row, _ machineId: String?) -> Row {
        guard let machineId, let i = row.chips.firstIndex(where: { $0.machineId == machineId }), i > 0
        else { return row }
        var out = row
        out.chips.insert(out.chips.remove(at: i), at: 0)
        return out
    }

    /// The longest name a chip spells out whole.
    public static let shortLength = 10

    /// What a chip calls a machine. A short name is kept as it is ("Bambu
    /// X1C"); a long one loses its leading words — the maker — until it is
    /// short ("Snapmaker U1" → "U1", "Prusa CORE One" → "CORE One", "Bambu
    /// Lab X1 Carbon" → "X1 Carbon"), else it is cut with an ellipsis. Whole
    /// names go on the hover.
    public static func short(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > shortLength else { return trimmed }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        var rest = words
        while rest.count > 1 {
            rest.removeFirst()
            let joined = rest.joined(separator: " ")
            if joined.count <= shortLength { return joined }
        }
        return String(trimmed.prefix(shortLength - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// How many chips fit in `available` points, leaving room for a "+N"
    /// chip when some do not. `widths` are the chips' own, in order;
    /// `overflow(n)` is the width of the "+n" chip. Zero when not even one
    /// chip fits beside the "+N": the tile then shows "+N" alone, and the
    /// whole list is on its hover.
    public static func visibleCount(widths: [Double], available: Double, spacing: Double,
                                    overflow: (Int) -> Double) -> Int {
        guard !widths.isEmpty, available > 0 else { return 0 }
        // Everything, if everything fits.
        let all = widths.reduce(0, +) + spacing * Double(widths.count - 1)
        if all <= available { return widths.count }
        // Otherwise the most that fit beside the "+N" for the rest.
        var n = widths.count - 1
        while n > 0 {
            let used = widths.prefix(n).reduce(0, +) + spacing * Double(n) + overflow(widths.count - n)
            if used <= available { return n }
            n -= 1
        }
        return 0
    }
}
