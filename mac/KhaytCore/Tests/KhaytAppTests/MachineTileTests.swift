import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The machine strip on the front door.
///
/// ── TWO DEFECTS, BOTH INVISIBLE FROM THE SOURCE ───────────────────────────
///
/// **A print in progress was drawn as a change.** `MachineTile` set its
/// percentage in `Figure.signedPercent`, which exists for a rise or a fall, so
/// a print nine percent through read "+9%" on the screen a shop leaves open
/// all day. It had never been seen, because neither book this app is
/// photographed against can reach a printer — the sample's addresses are
/// somebody else's and the real book's jobs are finished. `00d-dashboard-running`
/// is the picture that found it.
///
/// **"no link" was said about four different things.** The tile had one test —
/// is there a reading — and everything that failed it got the same sentence: a
/// laser Khayt has no protocol for, a printer with no address typed in yet, and
/// a perfectly well configured machine that had not answered its first poll of
/// the morning. One of those is permanent, one is thirty seconds' work, and one
/// is not a problem. `Dashboard.Tile` had already been through this argument in
/// its own comment and the reasoning was never applied here, so two views
/// answered one question and the one people look at had the wrong answer.
@MainActor
struct MachineTileTests {

    static func book() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    static func printing(_ progress: Int, state: String = "printing") -> PrinterWatch.Reading {
        PrinterWatch.Reading(
            status: KhaytEngine.PrinterStatus(
                state: state, progress: progress, progressSource: "layers",
                filename: "falcon-hood-v4.gcode", timeRemaining: 9360,
                tempNozzle: 245, tempBed: 60, type: "moonraker"),
            problem: nil, at: Date())
    }

    // MARK: - A level is not a change

    /// THE ONE THAT SHIPPED. `signedPercent` puts a `+` in front of anything
    /// above zero, which is right for a margin moving and wrong for how far
    /// through a print is.
    @Test("how far through a print is never carries a sign")
    func progressIsALevel() {
        for value in [0.09, 0.48, 0.96, 1.0] {
            let level = Figure(value: value, style: .percent).renderedText
            #expect(!level.contains("+"), "a print \(value) through reads as a rise: \(level)")
            // And the style it used to be set in still does what it is for,
            // so this is a wrong USE being fixed rather than a style changed
            // under everything else that reads it.
            #expect(Figure(value: value, style: .signedPercent).renderedText.contains("+"))
        }
        #expect(Figure(value: 0.48, style: .percent).renderedText.contains("48"))
    }

    // MARK: - Why a machine is quiet

    /// A machine that has ANSWERED is idle, whatever its record looks like —
    /// an answer is the strongest evidence there is, and this test was third
    /// in the chain at first, so a machine that had answered was still
    /// reported as not set up.
    @Test("a machine that answered and is not printing is idle")
    func answeringBeatsTheRecord() async throws {
        let shop = await Self.book()
        let machine = try #require(shop.machines.first)
        shop.printers.setReadingForTesting(machine.id, Self.printing(0, state: "idle"))
        #expect(shop.quiet(machine) == .idle)
        #expect(shop.tileReading(for: machine).percent == nil,
                "an idle machine was drawn as a print at 0%")
    }

    /// A KIND with no protocol in this repo. Permanent, and not a fault: the
    /// sample shop has a UV flatbed and a laser cutter for exactly this.
    @Test("a machine Khayt has no protocol for says so, and says it differently")
    func noProtocolIsItsOwnSentence() async throws {
        let shop = await Self.book()
        let unaskable = shop.machines.filter { !(shop.kind(of: $0)?.polled ?? true) }
        #expect(!unaskable.isEmpty, "the sample book no longer exercises this at all")
        for machine in unaskable {
            #expect(shop.quiet(machine) == .noProtocol,
                    "\(machine.name) is not askable and was not reported as such")
        }
        // And it is NOT the sentence a fixable machine gets.
        #expect(Shop.Quiet.noProtocol.wordKey != Shop.Quiet.notSetUp.wordKey)
    }

    /// A printer Khayt speaks to, with no address. The one worth a shop's
    /// thirty seconds, and the whole reason the four cases are separate.
    @Test("a printer with no address is not set up, not 'no link'")
    func notSetUpIsFixable() async throws {
        let shop = await Self.book()
        let askable = shop.machines.filter { shop.kind(of: $0)?.polled ?? true }
        #expect(!askable.isEmpty)
        for machine in askable {
            #expect(shop.quiet(machine) == .notSetUp,
                    "\(machine.name) has no address and was reported as \(shop.quiet(machine))")
        }
    }

    /// Set up, asked, silent — the case BOTH tiles were missing. It is the
    /// only one of the four that is news, so it is the only one that gets its
    /// own mark.
    @Test("a configured machine that has not answered is the only one that is news")
    func silenceIsTheOneWorthSeeing() {
        #expect(Shop.Quiet.notAnswering.state == .machineCheck)
        for quiet in [Shop.Quiet.idle, .notSetUp, .noProtocol] {
            #expect(quiet.state == .queued,
                    "\(quiet) draws a mark that says something is wrong")
        }
        // `StateMark` says the glyph names the KIND and the word carries the
        // severity, and that no glyph appears in two tables. The three quiet
        // cases are one kind with three sentences.
        let words = Set([Shop.Quiet.idle, .notSetUp, .noProtocol, .notAnswering].map(\.wordKey))
        #expect(words.count == 4, "two of the four say the same thing again")
        let language = Words()
        for quiet in [Shop.Quiet.idle, .notSetUp, .noProtocol, .notAnswering] {
            for tongue in Words.supported {
                #expect(Words.own[quiet.wordKey]?[tongue]?.isEmpty == false,
                        Comment(rawValue: "\(quiet.wordKey) has nothing in \(tongue)"))
            }
            #expect(!language.callIt(quiet.wordKey).hasPrefix("mac."),
                    Comment(rawValue: "\(quiet.wordKey) renders as its own key"))
        }
    }

    /// The running tile says how LONG, not what the file is called. A sliced
    /// filename is a long ugly string and the tile is two hundred points wide;
    /// the time left is what a shop plans around. The name is in the tooltip.
    @Test("a running tile says the time left, and keeps the file for the tooltip")
    func theLineIsTheTimeLeft() async throws {
        let shop = await Self.book()
        let machine = try #require(shop.machines.first { shop.kind(of: $0)?.polled ?? true })
        shop.printers.setReadingForTesting(machine.id, Self.printing(48))
        let reading = shop.tileReading(for: machine)
        #expect(reading.percent == 0.48)
        #expect(reading.state == .running)
        #expect(reading.line == PrinterWatch.spell(9360), "the line is not the time left")
        #expect(!reading.line.contains(".gcode"), "the filename is back on the tile")
        #expect(reading.filename == "falcon-hood-v4.gcode")
    }
}
