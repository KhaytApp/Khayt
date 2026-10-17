import Foundation
import AppKit
import SwiftUI
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
        didSet {
            guard !openedLinks.isEmpty else { return }
            openedLinksArrived = Date()
            NotificationCenter.default.post(name: .khaytOpenedLinks, object: nil)
        }
    }

    /// When the newest of `openedLinks` arrived — see `isStale`.
    @MainActor static var openedLinksArrived = Date.distantPast

    /// How long before its window began something handed to the app may still
    /// be acted on.
    static let handedOverGrace: TimeInterval = 5

    /// ── A CLICK IS ANSWERED NOW OR NEVER ─────────────────────────────────────
    ///
    /// Something handed to the app (a widget's link, a file dropped on the Dock)
    /// that arrived well before the window taking it began is not acted on.
    /// With the shop window closed (⌘W; Settings, Help or the kiosk keep the
    /// app running) a click used to queue silently and fire whenever the window
    /// was next opened — minutes or hours later, as a screen change or a New
    /// Job sheet nobody had just asked for. The arrival now opens the window
    /// (`ShopWindowOpener`); this is the guard behind that, so a link the window
    /// could not be brought up for is dropped rather than followed late.
    ///
    /// `windowOpenedAt` nil means the window was already open when it arrived —
    /// never stale. A cold launch by the link itself is not stale either: it
    /// arrives as the window's `.task` begins, and the book's load may take as
    /// long as it takes after that.
    static func isStale(arrivedAt: Date, windowOpenedAt: Date?) -> Bool {
        guard let windowOpenedAt else { return false }
        return arrivedAt < windowOpenedAt.addingTimeInterval(-handedOverGrace)
    }

    /// Follow the newest link once a book is open. Older ones are dropped: two
    /// clicks before the book opened mean the second. `windowOpenedAt` is when
    /// the taking window's `.task` began; nil from the live receiver.
    func takeOpenedLinks(windowOpenedAt: Date? = nil) {
        guard let link = Self.openedLinks.last, engine != nil, !needsSignIn else { return }
        Self.openedLinks = []
        guard !Self.isStale(arrivedAt: Self.openedLinksArrived, windowOpenedAt: windowOpenedAt) else { return }
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

/// Brings the shop's window up when something is handed to the app.
///
/// A khayt:// link or a dropped file arrives at the app delegate, which has no
/// SwiftUI environment and so no `openWindow`. The shop window keeps its action
/// here when it first appears, and the delegate calls it: for a `Window` scene
/// it opens the window when it is closed and brings it forward when it is not.
/// Before the window has ever appeared (the link that launched the app) there
/// is nothing to keep, and nothing is needed: the window is opening anyway.
@MainActor
enum ShopWindowOpener {
    static var openWindow: OpenWindowAction?

    static func raise() {
        if let openWindow {
            openWindow(id: "shop")
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("shop") == true }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    /// A widget's link arrived through `application(_:open:)` — see `Shop.openedLinks`.
    static let khaytOpenedLinks = Notification.Name("app.khayt.mac.openedLinks")
}
