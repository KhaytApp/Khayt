import Foundation
import KhaytCore

extension Shop {
    /// An error, said in the shop's language where this app knows what it is.
    ///
    /// Eighty-odd places in the shop's actions showed `String(describing:
    /// error)` — Swift's or the writer's English, under an Arabic toolbar, and
    /// sometimes after an Arabic prefix, so one line read in two languages
    /// (Oct 2026 review). The failures this app raises itself are said here;
    /// anything else (a system error) is still shown as the system wrote it,
    /// because a translated guess at it would be worse than the truth.
    func said(_ error: Error) -> String {
        switch error {
        case let refusal as StoreWriter.Refusal:
            switch refusal {
            // WHO holds it, when the lock still says: "reopen it here" was
            // wrong for a Mac that never held the book (alpha.82 review).
            case .notOurs:
                if let build = source.build, let who = whoElseHasIt(build) {
                    return who + ". " + words.callIt("mac.write_refused_nothing")
                }
                return words.callIt("mac.lock_lost")
            case .tooLarge: return words.callIt("mac.store_too_large")
            case .unreadable(let why): return words.callIt("mac.store_unreadable", ["why": .string(why)])
            }
        case let refusal as MoveRefused: return refusal.sentence
        case let failure as Secrets.Failure:
            switch failure {
            case .noKeychain: return words.callIt("mac.secret_locked")
            case .unreadable: return words.callIt("mac.secret_unreadable")
            }
        case let failure as LibraryImport.Failure: return failure.said(words)
        case let failure as Converter.Failure: return failure.said(words)
        case let failure as CustomerRecordsPublisher.Failure: return failure.said(words)
        default: return String(describing: error)
        }
    }
}
