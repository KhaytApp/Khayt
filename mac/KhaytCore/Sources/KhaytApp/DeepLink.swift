import Foundation
import KhaytCore
import KhaytWidgetData

/// A desktop widget's row, opened: `khayt://machine/<id>`, `job/<id>`,
/// `spool/<id>` or `screen/<name>` (`ShopWidgetSnapshot.Link`).
///
/// ── ONLY WHAT ⌘K WOULD OPEN ──────────────────────────────────────────────
///
/// A URL scheme is a door any app or web page on this Mac can knock on, so the
/// address is only ever a way to NAVIGATE — never to change anything — and it
/// goes through the same gate as ⌘K (`goToKinds`, `canShow`): a job opens only
/// for someone allowed to see jobs, a screen only where the sidebar would show
/// it, and nothing at all while nobody is signed in. An id the open book does
/// not have does nothing, rather than opening a screen on a selection that is
/// not there. Anything that is not exactly one of the four shapes was already
/// refused when the URL was read (`Link.init`).
extension Shop {

    /// Links handed to the app by the system, waiting for a book.
    @MainActor static var openedLinks: [ShopWidgetSnapshot.Link] = [] {
        didSet { if !openedLinks.isEmpty { NotificationCenter.default.post(name: .khaytOpenedLinks, object: nil) } }
    }

    /// Follow the newest link once a book is open. Older ones are dropped: two
    /// clicks before the book opened mean the second.
    func takeOpenedLinks() {
        guard let link = Self.openedLinks.last, engine != nil, !needsSignIn else { return }
        Self.openedLinks = []
        follow(link)
    }

    /// Go where `link` points, if this person may and the book has it.
    @discardableResult
    func follow(_ link: ShopWidgetSnapshot.Link) -> Bool {
        guard !needsSignIn else { return false }
        switch link {
        case .job(let id):
            guard goToKinds.contains(.job), orders.contains(where: { $0.id == id }) else { return false }
            goTo(GoToIndex.Entry(kind: .job, id: id, title: id, fields: []))
        case .machine(let id):
            guard goToKinds.contains(.machine), machines.contains(where: { $0.id == id }) else { return false }
            goTo(GoToIndex.Entry(kind: .machine, id: id, title: id, fields: []))
        case .spool(let id):
            guard canShow(.inventory), spools.contains(where: { $0.id == id }) else { return false }
            shelf = .inventory
        case .screen(let name):
            guard let target = Shelves.shelf(name, in: self), canShow(target) else { return false }
            shelf = target
        }
        return true
    }
}

extension Notification.Name {
    /// A widget's link arrived through `application(_:open:)` — see `Shop.openedLinks`.
    static let khaytOpenedLinks = Notification.Name("app.khayt.mac.openedLinks")
}
