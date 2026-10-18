import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Import and convert refusals are said in the shop's language.
@MainActor
struct LibraryErrorWordsTests {
    @Test("every import and convert refusal is in English and Arabic, and the Arabic is not English")
    func arabic() async {
        let w = Words()
        await w.load("ar", engine: try? KhaytEngine())
        let said = [
            LibraryImport.Failure.notOurs.said(w), LibraryImport.Failure.noLibrary.said(w),
            LibraryImport.Failure.unknownKind("abc").said(w), LibraryImport.Failure.alreadyHere("Vase").said(w),
            LibraryImport.Failure.failed("x").said(w),
            Converter.Failure.unreadable("x").said(w), Converter.Failure.meshTooBig("m", bytes: 300 << 20).said(w),
            Converter.Failure.tooBig(bytes: 3 << 30).said(w),
        ]
        for s in said {
            #expect(!s.hasPrefix("mac."), "a raw key: \(s)")
            #expect(!s.contains("Khayt does not") && !s.contains("Could not") && !s.contains("This 3MF"),
                    "English in the Arabic app: \(s)")
        }
        #expect(said[2].contains("abc") && said[3].contains("Vase"))
    }
}
