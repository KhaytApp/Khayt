import Foundation
import Testing
@testable import KhaytCore

/// A colour's plain name through the engine the Mac and the phone ship, against
/// the vectors the desktop's own test reads (`test/colour-name.test.js`).
struct ColourNameTests {

    struct Vectors: Decodable {
        struct Case: Decodable { let why: String; let hex: String; let lang: String; let known: String?; let want: String? }
        let cases: [Case]
    }

    @Test("the shared cases: the spool's own name, else the nearest everyday name, else none; never a code")
    func cases() async throws {
        let engine = try KhaytEngine()
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: CrossAppFixtureTests.fixture("colour-name-vectors.json")))
        #expect(v.cases.count >= 15, "the fixture lost cases")
        for c in v.cases {
            let got = try await engine.colourName(hex: c.hex, lang: c.lang, known: c.known)
            #expect(got == c.want, Comment(rawValue: c.why))
        }
    }
}
