import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the September review of the shop's real book found, pinned.
///
/// Each of these was visible only on the shop's own data — names with no
/// spaces, a book where every job is delivered, spools whose colour arrived
/// in a spelling the parser did not read — so the sample book never showed
/// them and nothing here would have.
@MainActor
struct LayoutReviewTests {

    // MARK: Library titles wrap where a person would

    @Test("a file name with no spaces gains break points after its separators")
    func titlesBreakAtSeparators() {
        let zw = "\u{200B}"
        #expect(TitleBreaks.soften("Kimba_gleam_stardemy") == "Kimba_\(zw)gleam_\(zw)stardemy")
        #expect(TitleBreaks.soften("Modular+Filament+Storage+Organizer")
                == "Modular+\(zw)Filament+\(zw)Storage+\(zw)Organizer")
        // A run of separators breaks once, after the run; a trailing one not at all.
        #expect(TitleBreaks.soften("a__b-") == "a__\(zw)b-")
        // A name a person typed is left exactly as it was.
        #expect(TitleBreaks.soften("Dark grey Joints PETG") == "Dark grey Joints PETG")
    }

    @Test("softening is display only: removing the breaks gives the name back")
    func softeningIsReversible() {
        for name in ["Grendizer_by_Santome", "#GV44 #I111 MK 4 6 7 Helmet Do3D",
                     "Infinity_Serpent_Long-Dragon_v1.0_ByHollowman", "بطاقة_هدية"] {
            #expect(TitleBreaks.soften(name).replacingOccurrences(of: "\u{200B}", with: "") == name)
        }
    }

    // MARK: A spool with a colour draws it

    @Test("a colour written as #RGB or RRGGBBAA is read, not drawn as the unknown grey")
    func hexSpellings() throws {
        let six = try #require(Swatch.rgb(fromHex: "#FF6A13"))
        let eight = try #require(Swatch.rgb(fromHex: "FF6A13FF"))
        #expect(six == eight)
        let three = try #require(Swatch.rgb(fromHex: "#F00"))
        #expect(three.r == 1 && three.g == 0 && three.b == 0)
        // Nobody said, or said nonsense: nil, never black.
        #expect(Swatch.rgb(fromHex: nil) == nil)
        #expect(Swatch.rgb(fromHex: "") == nil)
        #expect(Swatch.rgb(fromHex: "#GGHHII") == nil)
        #expect(Swatch.rgb(fromHex: "+12345") == nil)
        #expect(Swatch.rgb(fromHex: "#12345") == nil)
    }

    // MARK: The words the review changed

    @Test("the recased and replaced labels are sentence case in English, and exist in Arabic")
    func sentenceCase() {
        let keys = ["mac.issue_gift_card", "mac.gift_card_code", "mac.failure_category",
                    "mac.add_supplier", "mac.edit_supplier", "mac.expense_order_col",
                    "mac.pnl_title", "mac.waste_empty", "mac.board_open_jobs",
                    "mac.board_finished_elsewhere"]
        for key in keys {
            let en = Words.own[key]?["en"], ar = Words.own[key]?["ar"]
            #expect(en?.isEmpty == false, "\(key) has no English")
            #expect(ar?.isEmpty == false, "\(key) has no Arabic")
        }
        // The first word capitalised and no other, bar the P&L's own ampersand
        // name and the screen name "Jobs".
        for key in ["mac.issue_gift_card", "mac.gift_card_code", "mac.failure_category",
                    "mac.add_supplier", "mac.edit_supplier"] {
            let words = (Words.own[key]?["en"] ?? "").split(separator: " ").dropFirst()
            #expect(words.allSatisfy { $0.first?.isLowercase == true }, "\(key) is Title Case")
        }
        #expect(Words.own["mac.waste_empty"]?["en"]?.lowercased().contains("great") == false,
                "an empty waste log is not an achievement")
    }

    @Test("the board says where delivered work went, rather than showing empty lanes")
    func boardNamesFinishedWork() {
        let shop = Shop()
        let said = shop.words.counting(20, "mac.board_finished_elsewhere")
        #expect(said.contains("20"))
        #expect(!said.contains("{n}"))
        // Delivered and cancelled are the only stages the board leaves out, and
        // the banner counts exactly those.
        let off = Stage.allCases.filter { !Stage.boardColumns.contains($0) }
        #expect(Set(off) == [.delivered, .cancelled])
    }
}
