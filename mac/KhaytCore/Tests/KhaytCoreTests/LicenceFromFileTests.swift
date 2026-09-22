import Foundation
import Testing
@testable import KhaytCore

/// What a model FILE says its licence is, translated — or refused.
///
/// The three strings that actually turn up in a real shop's ninety files are
/// `BY-NC-SA`, `Standard Digital File License` and `MakerWorld Exclusive
/// License`. One of those is a licence this module can reason about. The
/// other two are a platform's own terms, and translating them either way
/// would be Khayt inventing a legal opinion about a shop's right to sell.
struct LicenceFromFileTests {

    @Test("the Creative Commons clause lists a 3MF actually writes")
    func realStringsTranslate() {
        for (said, want) in [
            ("BY-NC-SA", "cc-by-nc-sa"), ("by-nc-sa", "cc-by-nc-sa"),
            ("CC BY-NC-SA 4.0", "cc-by-nc-sa"), ("CC-BY-SA", "cc-by-sa"),
            ("BY", "cc-by"), ("BY-ND", "cc-by-nd"), ("BY-NC-ND", "cc-by-nc-nd"),
            ("CC0", "cc0"), ("cc0-1.0", "cc0"), ("Public Domain", "cc0"),
            // A file already spelling it this module's way needs no table.
            ("cc-by-nc", "cc-by-nc"), ("own", "own"), ("commercial", "commercial"),
        ] {
            #expect(ModelLicence.fromFile(said)?.id == want,
                    Comment(rawValue: "\(said) became \(ModelLicence.fromFile(said)?.id ?? "nothing")"))
        }
    }

    /// THE HALF THAT MATTERS. Fifteen of that shop's files say "Standard
    /// Digital File License" and three say "MakerWorld Exclusive License".
    /// Neither is Creative Commons. A wrong answer here is a shop told it may
    /// sell something it may not, or told it may not sell its own work.
    @Test("a platform's own terms are not translated into a permission")
    func platformTermsAreRefused() {
        for said in ["Standard Digital File License", "MakerWorld Exclusive License",
                     "All Rights Reserved", "Royalty Free", "Personal use only",
                     "https://creativecommons.org/licenses/by-nc-sa/4.0/",
                     "Free for personal use, contact me for commercial",
                     "", "   ", "[]", "unknown", "GPL-3.0", "MIT"] {
            #expect(ModelLicence.fromFile(said) == nil, Comment(rawValue: """
                "\(said)" was translated to \(ModelLicence.fromFile(said)?.id ?? "-"), \
                which is this app forming a legal opinion it has no basis for
                """))
        }
    }

    /// Nil means NOBODY HAS SAID, and the rest of this module is careful that
    /// it is not the same as "no". A refusal must not become a refusal to sell.
    @Test("a licence that could not be translated leaves sellable unknown")
    func refusedIsNotForbidden() {
        #expect(ModelLicence.fromFile("Standard Digital File License") == nil)
        #expect(ModelLicence.sellable(nil) == nil, "unknown became a no")
        // And the one that does translate carries its real answer through.
        #expect(ModelLicence.fromFile("BY-NC-SA")?.commercial == false)
        #expect(ModelLicence.fromFile("BY")?.commercial == true)
    }

    /// A clause list this module does not hold is not invented: `by-xx` must
    /// not become `cc-by`, and a repeated clause is a malformed string.
    @Test("a clause list is matched whole or not at all")
    func nonsenseIsNotRoundedDown() {
        for said in ["BY-XX", "NC-SA", "BY-NC-SA-ND-XX", "BY-BY", "SA", "-BY-"] {
            #expect(ModelLicence.fromFile(said) == nil,
                    Comment(rawValue: "\(said) became \(ModelLicence.fromFile(said)?.id ?? "-")"))
        }
    }
}
