import Foundation
import KhaytCore

/// ⌘K, "Go to…": what it searches, who may see what, and where a row goes.
///
/// The palette itself is `GoToPalette`; the matching is `GoToIndex` in
/// KhaytCore, which is pure and knows nothing about a shop. This file is the
/// join between the two: it turns the book into index entries, decides which
/// kinds a person signed in may see, lists the screens and the commands, and
/// navigates with the same moves the sidebar, the dashboard and the library's
/// own reveal make.
extension Shop {

    // MARK: - The index, once per change

    /// The book's index, built when the book has changed since the last one
    /// and otherwise handed back as it was. Typing never comes here more than
    /// once: the palette asks when it opens, and searches what it was given.
    ///
    /// Built off the main actor. The rows are value types copied out first,
    /// so the build reads nothing the window can change under it.
    func goToIndex() async -> GoToIndex {
        if let cache = goToCache, cache.revision == bookRevision { return cache.index }
        let revision = bookRevision
        let book = GoToBook(orders: orders, customers: customers, files: files,
                            products: catalogueRows, machines: machines)
        let index = await Task.detached(priority: .userInitiated) { book.index() }.value
        goToBuilds += 1
        // Not over a newer book: a change that landed while this was building
        // leaves the cache empty, and the next open builds again.
        if revision == bookRevision { goToCache = (revision, index) }
        return index
    }

    // MARK: - Who may see what

    /// The kinds this person may be shown. GATED LIKE THE SCREENS THEY OPEN:
    /// a job is an order, a customer is the Customers screen — and a palette
    /// that lists what the sidebar hides is the half-a-gate the Go menu's own
    /// note warns about. Nothing at all while nobody is signed in.
    var goToKinds: Set<GoToIndex.Kind> {
        guard !needsSignIn else { return [] }
        var kinds: Set<GoToIndex.Kind> = [.screen, .model, .product, .machine]
        if lockAllows("orders", "view") { kinds.insert(.job) }
        if canShow(.customers) { kinds.insert(.customer) }
        return kinds
    }

    /// Whether ⌘K does anything. The Go menu is disabled as a whole while
    /// nobody is signed in; this says so for the palette as well.
    var canGoToAnything: Bool { !needsSignIn }

    // MARK: - Screens and commands

    /// The sidebar's screens, in its order, with its words.
    static let goToShelves: [Shelf] = [
        .dashboard, .jobs(nil), .board, .library(nil), .catalogue, .customers,
        .machines, .inventory, .expenses, .waste,
        .reports, .portfolio, .calculator, .colour, .giftCards,
    ]

    /// The screens this shop may open and the commands it may run right now,
    /// as a small index of their own. Built when the palette opens: twenty
    /// rows in the shop's own language, gated by `canShow` exactly as the
    /// sidebar is.
    func goToScreens() -> GoToIndex {
        var entries: [GoToIndex.Entry] = []
        guard goToKinds.contains(.screen) else { return GoToIndex([]) }
        for shelf in Self.goToShelves where canShow(shelf) {
            let title = words.callIt(Self.titleKey(of: shelf))
            entries.append(.init(kind: .screen, id: "screen:" + Shelves.name(shelf),
                                 title: title, subtitle: words.callIt("mac.goto_screen"),
                                 fields: [title]))
        }
        let facts = GoToCommand.Facts(shop: self)
        for command in GoToCommand.allCases where command.isEnabled(facts) {
            let title = words.callIt(command.titleKey)
            entries.append(.init(kind: .screen, id: "command:" + command.rawValue,
                                 title: title, subtitle: words.callIt("mac.goto_command"),
                                 fields: [title]))
        }
        return GoToIndex(entries)
    }

    // MARK: - Going there

    /// Go to a row: open its screen and select it, the way the screen's own
    /// rows do. Asked of the gate again, because a palette left open across a
    /// change of who is signed in must not open what the new person may not.
    func goTo(_ entry: GoToIndex.Entry) {
        guard goToKinds.contains(entry.kind) else { return }
        goingTo = false
        switch entry.kind {
        case .job:
            // The dashboard's "open the job" move, with the two things that
            // could hide the row from the table taken off first.
            shelf = .jobs(nil)
            search = ""
            kitFilter = nil
            selection = entry.id
        case .customer:
            shelf = .customers
            search = ""
            customerSelection = entry.id
        case .model:
            // The library's own reveal: clears the search and every filter,
            // opens the model's group and selects it.
            reveal(fileId: entry.id)
        case .product:
            shelf = .catalogue
            search = ""
            clearCatalogueFilter()
            catalogueSelection = entry.id
        case .machine:
            // The machines screen keeps no selection to set; the screen is
            // where a machine is.
            shelf = .machines
        case .screen:
            if entry.id.hasPrefix("command:"),
               let command = GoToCommand(rawValue: String(entry.id.dropFirst("command:".count))) {
                command.run(on: self)
            } else if entry.id.hasPrefix("screen:"),
                      let target = Shelves.shelf(String(entry.id.dropFirst("screen:".count)), in: self),
                      canShow(target) {
                shelf = target
            }
        }
    }
}

/// The book, as ⌘K reads it — copies, so the index builds off the main actor.
struct GoToBook: Sendable {
    var orders: [Order]
    var customers: [Customer]
    var files: [LibraryFile]
    var products: [KhaytEngine.CatalogueRow]
    var machines: [Machine]

    func index() -> GoToIndex {
        var entries: [GoToIndex.Entry] = []
        entries.reserveCapacity(orders.count + customers.count + files.count + products.count + machines.count)

        // Newest first, so of two equally good hits the recent job wins —
        // the one a shop is far likelier to be looking for.
        for job in orders.sorted(by: { $0.date > $1.date }) {
            var fields = [job.id, Self.number(job.id)]
            if let invoice = job.invoiceNumber { fields += [invoice, Self.number(invoice)] }
            fields += [job.client, job.project]
            fields += job.parts.map(\.name)
            let subtitle = [job.id, job.invoiceNumber ?? "", job.client]
                .filter { !$0.isEmpty }.map { Figure.isolated($0) }.joined(separator: " · ")
            entries.append(.init(kind: .job, id: job.id,
                                 title: job.project.isEmpty ? job.id : job.project,
                                 subtitle: subtitle, fields: fields))
        }
        for customer in customers {
            let phone = customer.record?.phone ?? ""
            let email = customer.record?.email ?? ""
            entries.append(.init(kind: .customer, id: customer.id, title: customer.name,
                                 subtitle: [phone, email].filter { !$0.isEmpty }.map { Figure.isolated($0) }.joined(separator: " · "),
                                 fields: [customer.name, customer.record?.nameEn ?? "",
                                          customer.record?.nameAr ?? "",
                                          phone, Self.digits(phone), email]))
        }
        // Not the ones put aside: the library hides them too, and a row that
        // opens on a model nobody can see is a palette that lies.
        for file in files where !file.isArchived {
            entries.append(.init(kind: .model, id: file.id, title: file.title,
                                 subtitle: file.groupName ?? file.sourceFile?.originalName ?? "",
                                 fields: [file.title, file.originalName ?? "",
                                          file.sourceFile?.originalName ?? "",
                                          file.sourceFile?.filename ?? ""]))
        }
        for product in products {
            entries.append(.init(kind: .product, id: product.id, title: product.name,
                                 subtitle: product.group, fields: [product.name, product.group]))
        }
        for machine in machines {
            entries.append(.init(kind: .machine, id: machine.id, title: machine.name,
                                 subtitle: machine.printerModelName ?? "",
                                 fields: [machine.name, machine.printerModelName ?? "", machine.vendor ?? ""]))
        }
        return GoToIndex(entries)
    }

    /// The number in an id, as a person says it: "ORD-01002" is job 1002.
    /// The last run of digits, leading zeros off.
    static func number(_ id: String) -> String {
        let run = id.reversed().prefix { $0.isASCII && $0.isNumber }
        let digits = String(run.reversed()).drop { $0 == "0" }
        return String(digits)
    }

    /// A phone as digits alone, so "0551234567" finds "055 123 4567".
    static func digits(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber })
    }
}

/// The menu actions ⌘K offers beside the screens.
///
/// EACH IS OFFERED WHEN ITS MENU ITEM IS ENABLED, by the same condition, and
/// runs the same line the menu runs. A command the palette offers and the
/// menu greys out would be a second, looser gate.
enum GoToCommand: String, CaseIterable {
    case newJob, newCustomer, newProduct, addModel, recordPayment, editJob, scan, readReceipt, backUp

    /// What the enablement is decided from — the shop's state, as values, so
    /// a test can ask every combination without building a book for each.
    struct Facts {
        var canMoveJobs: Bool
        var hasJob: Bool
        var importing: Bool

        init(canMoveJobs: Bool, hasJob: Bool, importing: Bool) {
            self.canMoveJobs = canMoveJobs
            self.hasJob = hasJob
            self.importing = importing
        }

        @MainActor init(shop: Shop) {
            self.init(canMoveJobs: shop.canMoveJobs,
                      hasJob: shop.selection.map { id in shop.orders.contains { $0.id == id } } ?? false,
                      importing: shop.importing)
        }
    }

    var titleKey: String {
        switch self {
        case .newJob: "mac.new_job"
        case .newCustomer: "mac.new_customer"
        case .newProduct: "mac.new_product"
        case .addModel: "mac.add_model"
        case .recordPayment: "pay.modal_title"
        case .editJob: "mac.edit_job"
        case .scan: "mac.scan_title"
        case .readReceipt: "mac.receipt_add"
        case .backUp: "mac.back_up_now"
        }
    }

    /// The menu item's own `.disabled`, inverted. See `Menus.swift`.
    func isEnabled(_ f: Facts) -> Bool {
        switch self {
        case .newJob, .newCustomer, .newProduct, .readReceipt, .backUp: f.canMoveJobs
        case .addModel: f.canMoveJobs && !f.importing
        case .recordPayment, .editJob: f.canMoveJobs && f.hasJob
        case .scan: true
        }
    }

    @MainActor func run(on shop: Shop) {
        guard isEnabled(Facts(shop: shop)) else { return }
        switch self {
        case .newJob: shop.takingAJob = true
        case .newCustomer: shop.editingCustomer = Shop.newCustomer()
        case .newProduct: shop.editingProduct = shop.newProduct()
        case .addModel: Task { await shop.addModelToLibrary() }
        case .recordPayment, .editJob:
            guard let id = shop.selection, let job = shop.orders.first(where: { $0.id == id }) else { return }
            let hold = Shop.PendingHold(id: job.id, project: job.project)
            if self == .recordPayment { shop.pendingPayment = hold } else { shop.pendingEdit = hold }
        case .scan: shop.scanning = true
        case .readReceipt: shop.startReadingReceipt()
        case .backUp: Task { await shop.backUpNow() }
        }
    }
}
