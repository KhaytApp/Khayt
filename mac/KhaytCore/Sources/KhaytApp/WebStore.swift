import Foundation
import SwiftUI
import AppKit
import ImageIO
import KhaytCore

/// Publishing the catalogue to the shop's web store.
///
/// ── WHY THIS EXISTS ────────────────────────────────────────────────────────
///
/// A web store lists what Khayt Cloud holds at `/v1/shops/{id}/catalog`: the
/// hosted shop page renders it, and `/feed/medusa`, which a Medusa storefront
/// polls every few minutes, is derived from it. Until now only the Electron
/// Storefront dialog could put anything there. A product added or re-priced on
/// the Mac, the app the shop actually uses, never reached the store, and the
/// store sat on whatever the desktop had last sent (one product of five, the
/// day this was found).
///
/// What goes in the catalogue is decided by `lib/storefront-catalog.js`, the
/// same module the desktop uses, so the two apps cannot publish two different
/// prices for one product. What is here is the part no pure module can do:
/// resize the pictures, and talk to the service.
///
/// ── A LIVE STORE FOLLOWS THE CATALOGUE ────────────────────────────────────
///
/// Once the store is live, a change to a product republishes it a few seconds
/// later. A shop that has chosen to sell online expects a price it changes to be
/// the price customers see; a second step it has to remember is how the store
/// drifted in the first place. Taking the store offline stops it.
@MainActor
enum CatalogPublisher {

    enum Failure: Error, Equatable {
        case unauthorised
        case readOnly
        /// The service refuses a catalogue with nothing in it.
        case empty
        /// Over the service's 8 MB cap even after the pictures were trimmed.
        case tooLarge
        case http(Int, String)
    }

    private struct Body: Encodable { let catalog: JSONValue }

    /// Send one catalogue, or take the store offline with nil.
    static func publish(_ connection: CloudReader.Connection, token: String, catalog: JSONValue?,
                        fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws {
        var request = try CloudReader.request(connection, token: token, method: "PUT", tail: "/catalog")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Pictures make this the largest body the app sends; give it longer.
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(Body(catalog: catalog ?? .null))
        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return
        case 400: throw Failure.empty
        case 401: throw Failure.unauthorised
        case 403: throw Failure.readOnly
        case 413: throw Failure.tooLarge
        case let code: throw Failure.http(code, CloudWriter.said(data))
        }
    }

    /// What Khayt Cloud holds: whether a catalogue is published, when it last
    /// changed, and how many listings and photos it carries. A 404 is the
    /// answer "no", not a fault.
    struct Held: Equatable {
        var live: Bool
        var at: Date?
        var items = 0
        var photos = 0
        /// Product id → the price the store lists it at, as held.
        var prices: [String: String] = [:]
    }

    static func status(_ connection: CloudReader.Connection, token: String,
                       fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Held {
        var request = try CloudReader.request(connection, token: token, method: "GET", tail: "/catalog")
        // The service marks this public for 60 s; a read-back must see the
        // catalogue just sent, not a cached copy of the last one.
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            let body = try? JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let o)? = body, case .object(let catalog)? = o["catalog"] else {
                return Held(live: false)
            }
            var at: Date?
            if case .string(let s)? = o["updatedAt"] { at = try? Date(s, strategy: .iso8601) }
            if at == nil, case .number(let ms)? = o["updatedAt"] { at = Date(timeIntervalSince1970: ms / 1000) }
            var held = Held(live: true, at: at)
            if case .array(let items)? = catalog["items"] {
                held.items = items.count
                for case .object(let item) in items {
                    if case .array(let photos)? = item["photos"] { held.photos += photos.count }
                }
                held.prices = prices(of: .object(catalog))
            }
            return held
        case 404: return Held(live: false)
        case 401: throw Failure.unauthorised
        case let code: throw Failure.http(code, CloudWriter.said(data))
        }
    }

    /// The public page the service renders from the catalogue.
    static func shopPage(_ connection: CloudReader.Connection) -> URL? {
        let base = connection.url.hasSuffix("/") ? String(connection.url.dropLast()) : connection.url
        return URL(string: base + "/shop/" + connection.shopId.uriComponent)
    }

    /// One product picture at the size the store is sent: the desktop's
    /// `resizeImage(blob, HERO_MAX_DIM, HERO_QUALITY)`, through the same scaling
    /// the product editor already uses. nil when the file cannot be read, and
    /// the listing then falls back to its thumbnail.
    ///
    /// Read UPRIGHT (`ProductPhotos.upright`): a file that still carries an
    /// EXIF orientation tag — copied in by hand, or written by an older build
    /// — is published the way the shop sees it, not as its pixels lie.
    nonisolated static func hero(_ file: URL, maxDim: Int, quality: Double) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = ProductPhotos.upright(source),
              let jpeg = ProductPhotos.jpeg(image, maxDim: maxDim, quality: quality) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    /// `KhaytProductImages.HERO_MAX_DIM` / `HERO_QUALITY`. Pinned against the
    /// module by WebStoreTests.
    static let heroMaxDim = 1000
    static let heroQuality = 0.82

    /// How long a live store waits after a change before republishing, so a
    /// run of edits sends one catalogue rather than one each.
    static let followDelay: Duration = .seconds(4)

    // MARK: Prices nobody set are not published on their own

    /// A price as one comparable text: numbers in one spelling ("50", "50.0"
    /// and 50 are one price), anything else trimmed, nothing for no price.
    nonisolated static func priceText(_ value: JSONValue?) -> String? {
        let raw: String
        switch value {
        case .number(let n)?: raw = String(n)
        case .string(let s)?: raw = s.trimmingCharacters(in: .whitespaces)
        default: return nil
        }
        guard !raw.isEmpty else { return nil }
        guard let n = Double(raw), n.isFinite else { return raw }
        return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    }

    /// Product id → listed price, out of a catalogue (sent or held).
    nonisolated static func prices(of catalog: JSONValue) -> [String: String] {
        guard case .object(let o) = catalog, case .array(let items)? = o["items"] else { return [:] }
        var out: [String: String] = [:]
        for case .object(let item) in items {
            guard case .string(let id)? = item["id"], !id.isEmpty,
                  let price = priceText(item["price"]) else { continue }
            out[id] = price
        }
        return out
    }

    /// The products whose price a live store would change WITHOUT the shop
    /// having set it: listed at one price now, about to be sent at another,
    /// and not the price the shop saved for it (`explicit`). A product being
    /// added or taken off is not a re-price and is not held.
    ///
    /// Why it exists: a spool's size edited, a record merged by sync, a repair
    /// run on open — each could re-price the catalogue, and a store that
    /// followed the catalogue published it. A price change customers see has
    /// to be one somebody made.
    nonisolated static func heldPrices(sending: [String: String], published: [String: String],
                                       explicit: [String: String]) -> [String] {
        sending.keys.sorted().filter { id in
            guard let now = sending[id], let was = published[id], now != was else { return false }
            return explicit[id] != now
        }
    }
}

/// One price a live store was about to change on its own, held for review.
struct WebStorePriceChange: Identifiable, Equatable {
    let id: String
    let name: String
    let was: String
    let now: String
}

// MARK: - The shop's side

extension Shop {

    /// Forget everything about the last book's store. Called when a book is
    /// opened, before it is asked about its own.
    func resetWebStore() {
        webStoreRepublish?.cancel()
        webStoreRepublish = nil
        webStoreLive = nil
        webStoreAt = nil
        webStoreHeld = nil
        webStoreSaid = nil
        webStoreSaidAt = nil
        webStoreProblem = false
        webStoreHeroes = [:]
    }

    /// Called each time a book is read, before `webStoreFollow`. True when it
    /// is a different book from the last one read (or the first), and only
    /// then is the last store forgotten.
    ///
    /// `resetWebStore` used to run on EVERY load, after `webStoreFollow`, so a
    /// reload — and a change to the book IS a reload — cancelled the republish
    /// the follow had just scheduled and forgot the store was live. Automatic
    /// republishing never fired.
    @discardableResult
    func webStoreBookRead(_ book: URL?) -> Bool {
        let another = !webStoreBookKnown || webStoreBook != book
        webStoreBookKnown = true
        webStoreBook = book
        if another {
            resetWebStore()
            // Another shop's catalogue is not this one's "before".
            webStoreSeen = nil
        }
        return another
    }

    /// Ask the service whether the store is live. Quiet about a shop with no cloud.
    func refreshWebStore() async {
        guard let build = source.build, Self.cloudConnected(settingsDict) else {
            webStoreLive = nil; return
        }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = CloudReader.session
            let now = try await CatalogPublisher.status(connection, token: token) { try await session.data(for: $0) }
            webStoreLive = now.live
            webStoreAt = now.at
            webStoreHeld = now
        } catch {
            // Unknown, not offline: a store that could not be asked about must
            // not stop following the catalogue because of a dropped request.
            webStoreSaid = words.callIt("mac.ws_check_failed") + " " + webStoreReason(error)
            webStoreProblem = true
        }
    }

    /// How many products a publish would list.
    func webStoreCount() async -> Int {
        (try? await engine?.storefrontCount(products: productRows, settings: settingsValue, lang: words.language)) ?? 0
    }

    /// Build the catalogue from the book and send it.
    func publishWebStore(withPhotos: Bool = WebStoreSheet.photosOn, automatic: Bool = false) async {
        // A publish somebody pressed replaces the one waiting to follow. An
        // AUTOMATIC one is that waiting task — it runs inside
        // `webStoreRepublish` — and cancelling it here cancelled itself: every
        // request after this line ran in a cancelled task, so URLSession threw
        // and the store was never sent. A newer change still cancels it, from
        // `webStoreFollow`, and schedules the publish that replaces it.
        // A person publishing the shop's prices is changing a setting (the
        // staff lock). The AUTOMATIC republish is the owner's standing
        // choice, run after an allowed edit — not asked again.
        if !automatic { guard permitted("settings", "edit") else { return } }
        if !automatic { webStoreRepublish?.cancel() }
        guard let engine, let build = source.build else { return }
        webStoreBusy = true
        defer { webStoreBusy = false }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let settings = settingsValue
            let products = productRows
            var heroes: [String: JSONValue] = [:]
            if withPhotos {
                let names = try await engine.storefrontHeroPaths(products: products, settings: settings, lang: words.language)
                heroes = await webStoreHeroes(names, in: build)
            }
            let catalog = try await engine.storefrontCatalog(
                products: products, settings: settings, lang: words.language,
                withPhotos: withPhotos, heroes: heroes)
            var sent = 0
            if case .object(let o) = catalog, case .array(let items)? = o["items"] { sent = items.count }
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = CloudReader.session

            // ── AN AUTOMATIC PUBLISH ASKS FIRST ────────────────────────────
            //
            // "Live" here is what this Mac last heard. The store may have been
            // taken offline from the desktop since, and republishing it on the
            // next edit would put it back online without anybody asking. So a
            // publish nobody pressed checks the store is still live, and stops
            // following it if not.
            if automatic {
                let now = try await CatalogPublisher.status(connection, token: token) { try await session.data(for: $0) }
                switch automaticGate(sending: catalog, sent: sent, published: now) {
                case .send: break
                case .stop, .held: return
                case .empty:
                    // NEVER OFFLINE BY ITSELF. This used to publish nothing —
                    // taking a live store down because a sync, a repair or a
                    // half-finished edit left nothing listable for a moment.
                    // Held, and the shop is told; a person takes it offline.
                    holdEmptyStore()
                    return
                }
            }
            if sent == 0 { throw CatalogPublisher.Failure.empty }
            try await CatalogPublisher.publish(connection, token: token, catalog: catalog) {
                try await session.data(for: $0)
            }
            // ── READ IT BACK ───────────────────────────────────────────────
            //
            // A 200 says the service took the request, not what a customer
            // will see: it sanitises the catalogue and drops what it will not
            // store. The shop could only find out by opening the website. So
            // the answer is read back from Khayt Cloud itself, and what is said
            // is what it now holds.
            webStoreLive = true
            webStoreAt = Date()
            // What is listed now is what was just sent: nothing left to hold,
            // and the shop's saved prices are the store's prices.
            webStorePriceHold = []
            webStoreHoldBook = nil
            webStoreExplicitPrices = [:]
            // Its own failure: the catalogue WAS stored, and a read-back that
            // timed out must not say otherwise.
            guard let held = try? await CatalogPublisher.status(connection, token: token, fetch: {
                try await session.data(for: $0)
            }) else {
                webStoreSaid = words.callIt("mac.ws_sent_unchecked", ["products": .string(words.counting(sent, "mac.ws_products"))])
                webStoreProblem = false
                webStoreSaidAt = Date()
                return
            }
            webStoreHeld = held
            webStoreLive = held.live
            webStoreAt = held.at ?? Date()
            let listed = words.callIt("mac.ws_confirmed", [
                "products": .string(words.counting(held.items, "mac.ws_products")),
                "photos": .string(words.counting(held.photos, "mac.ws_photos")),
            ])
            if held.live && held.items == sent {
                webStoreSaid = listed
                webStoreProblem = false
            } else {
                webStoreSaid = words.callIt("mac.ws_short", ["sent": .string(String(sent))]) + " " + listed
                webStoreProblem = true
            }
        } catch {
            webStoreSaid = words.callIt("mac.ws_failed") + " " + webStoreReason(error)
            webStoreProblem = true
            // A live store republishing on its own fails where nobody is looking.
            if automatic { moveNotices.append(webStoreSaid ?? "") }
        }
        webStoreSaidAt = Date()
        FileHandle.standardError.write(Data("khayt: web store — \(webStoreSaid ?? "")\n".utf8))
    }

    /// Take the store offline.
    func unpublishWebStore() async {
        guard permitted("settings", "edit") else { return }
        guard let build = source.build else { return }
        webStoreRepublish?.cancel()
        webStoreBusy = true
        defer { webStoreBusy = false }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = CloudReader.session
            try await CatalogPublisher.publish(connection, token: token, catalog: nil) {
                try await session.data(for: $0)
            }
            webStoreLive = false
            webStoreAt = Date()
            webStoreSaid = words.callIt("store.unpublished")
            webStoreProblem = false
        } catch {
            webStoreSaid = words.callIt("mac.ws_failed") + " " + webStoreReason(error)
            webStoreProblem = true
        }
    }

    /// Called each time the book is read. A live store whose products or
    /// storefront settings changed is republished shortly; a re-read of the
    /// same book is not a change.
    func webStoreFollow(products: [JSONValue], settings: [String: JSONValue]) {
        let seen: JSONValue = .object([
            "products": .array(products),
            "storefront": settings["storefront"] ?? .null,
            "contentLangs": settings["contentLangs"] ?? .null,
            "currency": settings["currency"] ?? .null,
            "bizEn": settings["bizEn"] ?? .null,
            "bizAr": settings["bizAr"] ?? .null,
        ])
        defer { webStoreSeen = seen }
        guard let before = webStoreSeen, before != seen,
              webStoreLive == true, cloudRoleCanWrite else { return }
        // The book `webStoreBookRead` recorded for this load — the same one
        // `source.build?.storeURL` names, and set for the sample too.
        let book = webStoreBook
        let delay = webStoreFollowDelay
        webStoreRepublish?.cancel()
        webStoreRepublish = Task { [weak self] in
            try? await Task.sleep(for: delay)
            // Still the same book, and still live: a book opened in the
            // meantime is a different shop with a store of its own.
            guard !Task.isCancelled, let self, self.webStoreBook == book,
                  self.webStoreLive == true else { return }
            if let stand = self.webStoreAutoPublish { await stand(self); return }
            await self.publishWebStore(automatic: true)
        }
    }

    /// What an automatic publish does once it knows what the store holds.
    enum AutoGate: Equatable {
        /// Send the catalogue.
        case send
        /// The store is no longer live: stop following it.
        case stop
        /// A price nobody set would change: held for review, nothing sent.
        case held
        /// Nothing left to list: HELD — an automatic publish never takes the
        /// store offline (`holdEmptyStore`).
        case empty
    }

    /// The checks an automatic publish makes before it sends anything. Its own
    /// function so the rule can be asked without a network.
    func automaticGate(sending catalog: JSONValue, sent: Int,
                       published now: CatalogPublisher.Held) -> AutoGate {
        guard now.live else {
            webStoreLive = false
            webStoreHeld = now
            return .stop
        }
        // ── A PRICE NOBODY SET IS NOT PUBLISHED ON ITS OWN ───────────────
        //
        // Compared with what the store holds RIGHT NOW, not with the last read
        // of the book: whatever moved a price — a spool size, a sync, a repair
        // — a customer would see it. Held, and the shop is asked; pressing
        // Publish in the sheet sends it.
        if holdUnsetPrices(sending: catalog, published: now) { return .held }
        // NOTHING LISTABLE. The service refuses an empty catalogue. This used
        // to take the store offline by itself; an automatic publish must never
        // do that (a sync or a repair can empty the list for a moment), so it
        // is held and the shop is told — taking the store down is theirs.
        if sent == 0 { return .empty }
        return .send
    }

    /// Hold an automatic republish that would change a price the shop did
    /// not set. True when held.
    func holdUnsetPrices(sending catalog: JSONValue, published: CatalogPublisher.Held) -> Bool {
        let sending = CatalogPublisher.prices(of: catalog)
        let ids = CatalogPublisher.heldPrices(sending: sending, published: published.prices,
                                              explicit: webStoreExplicitPrices)
        guard !ids.isEmpty else { return false }
        var names: [String: String] = [:]
        if case .object(let o) = catalog, case .array(let items)? = o["items"] {
            for case .object(let item) in items {
                if case .string(let id)? = item["id"], case .string(let name)? = item["name"] { names[id] = name }
            }
        }
        let hold = ids.map {
            WebStorePriceChange(id: $0, name: names[$0] ?? $0, was: published.prices[$0] ?? "", now: sending[$0] ?? "")
        }
        let fresh = hold != webStorePriceHold
        webStorePriceHold = hold
        webStoreHoldBook = source.build?.storeURL
        webStoreSaid = words.callIt("mac.ws_prices_held")
        webStoreProblem = true
        webStoreSaidAt = Date()
        // Once per new set of prices, not on every edit that follows.
        if fresh { moveNotices.append(webStoreSaid ?? "") }
        FileHandle.standardError.write(Data("khayt: web store — held \(ids.count) price change(s) the shop did not make\n".utf8))
        return true
    }

    /// An automatic publish found nothing to list: leave the store as it is
    /// and say so — once, not on every edit that follows.
    func holdEmptyStore() {
        let said = words.callIt("mac.ws_empty_held")
        let fresh = webStoreSaid != said
        webStoreSaid = said
        webStoreProblem = true
        webStoreSaidAt = Date()
        if fresh { moveNotices.append(said) }
        FileHandle.standardError.write(Data("khayt: web store — automatic publish found nothing to list; store left as it is\n".utf8))
    }

    /// The held prices for THIS book; another book's are not this shop's.
    var webStorePricesHeld: [WebStorePriceChange] {
        guard let book = webStoreHoldBook, book == source.build?.storeURL else { return [] }
        return webStorePriceHold
    }

    /// The price the shop just saved for a product, as the store would list
    /// it: `lib/storefront-catalog.js`'s rule — the storefront's own entry,
    /// else the price, else the base.
    func noteExplicitPrice(_ id: String) {
        guard case .object(let p)? = productRows.first(where: { Self.recordId($0) == id }) else { return }
        var listed: String?
        if case .object(let sf)? = settingsDict["storefront"], case .object(let prices)? = sf["prices"] {
            listed = CatalogPublisher.priceText(prices[id])
        }
        listed = listed ?? CatalogPublisher.priceText(p["price"]) ?? CatalogPublisher.priceText(p["basePrice"])
        if let listed { webStoreExplicitPrices[id] = listed } else { webStoreExplicitPrices[id] = nil }
    }

    /// The web-sized pictures, made off the main thread and kept while the
    /// file is unchanged, so a live store republishing after a price edit does
    /// not re-encode every photo in the shop.
    private func webStoreHeroes(_ names: [String], in build: StoreReader.Build) async -> [String: JSONValue] {
        let folder = ProductPhotos.folder(build)
        var out: [String: JSONValue] = [:]
        for name in names {
            let leaf = (name as NSString).lastPathComponent
            guard !leaf.isEmpty, leaf == name else { continue }
            let file = folder.appending(path: leaf)
            let date = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? nil
            guard let date else { continue }
            if let kept = webStoreHeroes[name], kept.0 == date {
                out[name] = .string(kept.1); continue
            }
            let dim = CatalogPublisher.heroMaxDim, quality = CatalogPublisher.heroQuality
            let made = await ProductPhotos.offMain {
                CatalogPublisher.hero(file, maxDim: dim, quality: quality)
            }
            if let made {
                webStoreHeroes[name] = (date, made)
                out[name] = .string(made)
            }
        }
        return out
    }

    /// Why it failed, in the shop's words.
    func webStoreReason(_ error: Error) -> String {
        switch error {
        case CatalogPublisher.Failure.unauthorised, CloudReader.Failure.unauthorised:
            return words.callIt("mac.ws_err_token")
        case CatalogPublisher.Failure.readOnly: return words.callIt("mac.ws_err_readonly")
        case CatalogPublisher.Failure.empty: return words.callIt("store.no_products")
        case CatalogPublisher.Failure.tooLarge: return words.callIt("mac.ws_err_too_large")
        case CloudReader.Failure.notConnected: return words.callIt("mac.qs_needs_cloud")
        case CatalogPublisher.Failure.http(let code, _):
            return words.callIt("mac.ws_err_http", ["code": .string(String(code))])
        default:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - The store's own settings

/// `settings.storefront`'s shop-wide fields, as the sheet edits them.
///
/// The desktop's Storefront dialog was the only place to set these, so a shop
/// on the Mac could publish a catalogue but not say how it ships, what a
/// deposit is, or which codes give a discount. The per-product maps in the
/// same object (prices, categories, options, stock) are left exactly as they
/// are: this writes only the keys it owns.
struct StorefrontDraft: Equatable {
    struct Shipping: Equatable, Identifiable {
        var id = UUID()
        var label = ""
        var price = ""
    }
    struct Promo: Equatable, Identifiable {
        var id = UUID()
        var code = ""
        var fixed = false
        var value = ""
        var expires = ""
        var maxUses = ""
    }
    var note = ""
    var leadTime = ""
    var minOrder = ""
    var depositPct = ""
    var taxRate = ""
    var payUrl = ""
    var shipping: [Shipping] = []
    var promos: [Promo] = []

    static func text(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return s
        case .number(let n)? where n != 0: return n == n.rounded() ? String(Int(n)) : String(n)
        default: return ""
        }
    }

    init() {}

    init(_ settings: [String: JSONValue]) {
        guard case .object(let sf)? = settings["storefront"] else { return }
        note = Self.text(sf["note"]); leadTime = Self.text(sf["leadTime"])
        minOrder = Self.text(sf["minOrder"]); depositPct = Self.text(sf["depositPct"])
        taxRate = Self.text(sf["taxRate"]); payUrl = Self.text(sf["payUrl"])
        if case .array(let list)? = sf["shipping"] {
            shipping = list.compactMap {
                guard case .object(let o) = $0 else { return nil }
                return Shipping(label: Self.text(o["label"]), price: Self.text(o["price"]))
            }
        }
        if case .array(let list)? = sf["promos"] {
            promos = list.compactMap {
                guard case .object(let o) = $0 else { return nil }
                return Promo(code: Self.text(o["code"]), fixed: o["type"] == .string("fixed"),
                             value: Self.text(o["value"]), expires: Self.text(o["expires"]),
                             maxUses: Self.text(o["maxUses"]))
            }
        }
    }

    private static func number(_ s: String, max upper: Double? = nil) -> Double {
        let n = max(0, Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) ?? 0)
        return upper.map { min($0, n) } ?? n
    }

    /// Written over `settings.storefront`, keeping every key it does not own.
    /// The same clamps and filters as the desktop's `captureConfig`.
    func apply(to sf: inout [String: JSONValue]) {
        sf["note"] = .string(note.trimmingCharacters(in: .whitespaces))
        sf["leadTime"] = .string(leadTime.trimmingCharacters(in: .whitespaces))
        sf["minOrder"] = .number(Self.number(minOrder))
        sf["depositPct"] = .number(Self.number(depositPct, max: 100))
        sf["taxRate"] = .number(Self.number(taxRate, max: 100))
        sf["payUrl"] = .string(payUrl.trimmingCharacters(in: .whitespaces))
        sf["shipping"] = .array(shipping
            .filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(8)
            .map { .object(["label": .string($0.label.trimmingCharacters(in: .whitespaces)),
                            "price": .number(Self.number($0.price))]) })
        sf["promos"] = .array(promos.compactMap { p in
            let code = p.code.trimmingCharacters(in: .whitespaces).uppercased()
            let value = Self.number(p.value)
            guard !code.isEmpty, value > 0 else { return nil }
            return .object(["code": .string(code), "type": .string(p.fixed ? "fixed" : "pct"),
                            "value": .number(value), "expires": .string(p.expires.trimmingCharacters(in: .whitespaces)),
                            "maxUses": .number(Double(Int(Self.number(p.maxUses))))])
        })
    }
}

extension Shop {
    /// Show or hide one product on the web store.
    func setOnWebStore(_ id: String, _ on: Bool) async {
        guard permitted("settings", "edit") else { return }
        guard let build = source.build else { return }
        do {
            try StoreWriter.updateRecord(build, collection: "products", id: id) { record in
                if on { record.removeValue(forKey: "storefrontHidden") } else { record["storefrontHidden"] = .bool(true) }
            }
            await load(source)
        } catch {
            webStoreSaid = String(describing: error)
            webStoreProblem = true
        }
    }

    /// `settings.storefront` after a save of `draft`.
    static func storefront(_ draft: StorefrontDraft, opened: StorefrontDraft?,
                           over sf: [String: JSONValue]) -> [String: JSONValue] {
        var written = sf
        draft.apply(to: &written)
        guard let opened else { return written }
        var baseline = sf
        opened.apply(to: &baseline)
        return RoundTrip.keepUntouched(written: written, baseline: baseline, stored: sf)
    }

    /// Save the store's shop-wide settings.
    ///
    /// `opened` is the draft as the pane opened it: what the shop did not
    /// change is kept as the book spells it (`RoundTrip`) — a shipping row or
    /// a promo the other app wrote with a field of its own, a promo this pane
    /// would filter out, a lead time of `"3"`.
    func saveStorefront(_ draft: StorefrontDraft, opened: StorefrontDraft?) async {
        guard permitted("settings", "edit") else { return }
        guard let build = source.build else { return }
        do {
            try StoreWriter.update(build) { root in
                var settings = Self.settings(root)
                var sf: [String: JSONValue] = [:]
                if case .object(let had)? = settings["storefront"] { sf = had }
                settings["storefront"] = .object(Self.storefront(draft, opened: opened, over: sf))
                root["settings"] = .object(settings)
            }
            await load(source)
            webStoreSaid = words.callIt(webStoreLive == true ? "mac.ws_settings_saved_live" : "mac.ws_settings_saved")
            webStoreProblem = false
            webStoreSaidAt = Date()
        } catch {
            webStoreSaid = String(describing: error)
            webStoreProblem = true
        }
    }

    /// What a customer would find wrong with each listing.
    func webStoreReview() async -> KhaytEngine.StorefrontReview? {
        try? await engine?.storefrontReview(products: productRows, settings: settingsValue, lang: words.language)
    }
}

// MARK: - The sheet

/// Publish, update or take down the web store, from the catalogue.
struct WebStoreSheet: View {
    @Bindable var shop: Shop
    @Environment(\.dismiss) private var dismiss
    @AppStorage("webstore.photos") private var photos = true
    @State private var count = 0
    @State private var askingOffline = false
    @State private var copied = false
    @State private var review: KhaytEngine.StorefrontReview?
    @State private var store = StorefrontDraft()
    @State private var storeSaved = StorefrontDraft()
    @State private var showSettings = false

    /// Whether pictures are sent; the live store's own republishes read it too.
    static var photosOn: Bool {
        UserDefaults.standard.object(forKey: "webstore.photos") as? Bool ?? true
    }

    private var connection: CloudReader.Connection? { try? CloudReader.connection(shop.settingsDict) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── THE ANSWER, WHERE IT CANNOT BE MISSED ─────────────────────────
            //
            // It was a caption at the foot of a section, grey, and the shop
            // could only tell whether a publish had worked by opening the
            // website. Now it is the first thing in the sheet, says what Khayt
            // Cloud holds, and when it was checked.
            if shop.webStoreBusy {
                banner(symbol: nil, tint: .secondary, text: shop.words.callIt("mac.ws_publishing"), at: nil)
            } else if let said = shop.webStoreSaid {
                banner(symbol: shop.webStoreProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                       tint: shop.webStoreProblem ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(Khayt.done),
                       text: said, at: shop.webStoreSaidAt)
            }
            Form {
                Section {
                    Text(shop.words.callIt("mac.ws_desc"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent(shop.words.callIt("mac.ws_state")) {
                        HStack(spacing: 6) {
                            Image(systemName: shop.webStoreLive == true ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(shop.webStoreLive == true ? AnyShapeStyle(Khayt.done) : AnyShapeStyle(.secondary))
                            Text(shop.words.callIt(shop.webStoreLive == true ? "store.published"
                                                   : shop.webStoreLive == false ? "store.unpublished" : "mac.ws_unknown"))
                            if shop.webStoreLive == true, let held = shop.webStoreHeld {
                                Text(shop.words.counting(held.items, "mac.ws_products"))
                                    .foregroundStyle(.secondary)
                            }
                            if let at = shop.webStoreAt {
                                Text(shop.words.say(at, Date.FormatStyle(date: .abbreviated, time: .shortened)))
                                    .foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                    }
                    LabeledContent(shop.words.callIt("mac.ws_listing")) {
                        Text(shop.words.counting(count, "mac.ws_products"))
                    }
                    Toggle(shop.words.callIt("store.include_photos"), isOn: $photos)
                    if shop.webStoreLive == true {
                        Label(shop.words.callIt("mac.ws_follows"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // ── PRICES HELD BACK ─────────────────────────────────────────
                //
                // A live store follows the catalogue, but not into a price the
                // shop did not set. What was held is listed, old and new, and
                // the Publish button below is the shop saying yes.
                if !shop.webStorePricesHeld.isEmpty {
                    Section {
                        ForEach(shop.webStorePricesHeld) { change in
                            HeldPriceRow(shop: shop, change: change) {
                                // The way to settle it the shop's own way: set
                                // the price it wants, which a live store then
                                // follows (`noteExplicitPrice`).
                                Task {
                                    guard let product = await shop.productForEditing(change.id) else { return }
                                    dismiss()
                                    shop.editingProduct = product
                                }
                            }
                        }
                        Text(shop.words.callIt("mac.ws_prices_held_hint"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text(shop.words.callIt("mac.ws_prices_held"))
                    }
                }
                // ── BEFORE YOU PUBLISH ────────────────────────────────────────
                //
                // What a customer would notice, per listing, with the two ways
                // to fix it right here: edit the product, or keep it off the
                // store. `lib/storefront-catalog.js` decides what counts.
                if let review, !review.listings.isEmpty || review.hidden > 0 {
                    Section(shop.words.callIt("mac.ws_review")) {
                        ForEach(review.listings) { listing in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(Khayt.attention)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: listing.name).font(.callout.weight(.medium))
                                    Text(listing.issues.map { shop.words.callIt("mac.ws_issue_" + $0) }
                                            .formatted(.list(type: .and)))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Button(shop.words.callIt("mac.edit_product") + "\u{2026}") {
                                    Task {
                                        guard let product = await shop.productForEditing(listing.id) else { return }
                                        dismiss()
                                        shop.editingProduct = product
                                    }
                                }
                                .disabled(!shop.canMoveJobs)
                                Button(shop.words.callIt("mac.ws_hide")) {
                                    Task { await shop.setOnWebStore(listing.id, false) }
                                }
                                .disabled(!shop.canMoveJobs)
                            }
                        }
                        if review.hidden > 0 {
                            Label(shop.words.counting(review.hidden, "mac.ws_hidden"), systemImage: "eye.slash")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // ── WHAT EARNS MOST PER PRINTER HOUR ─────────────────────────
                //
                // Advice, and quiet about it: which listed products are the
                // best use of the one printer, and which earn well under the
                // shop's own average per hour. Only shown when there is
                // something to say. `lib/profit-per-hour.js` decides.
                if WebStorePerHourHints.hasAnything(shop.profitPerHour), let rates = shop.profitPerHour {
                    WebStorePerHourHints(shop: shop, report: rates)
                }
                // ── THE STORE'S OWN SETTINGS ─────────────────────────────────
                Section {
                    DisclosureGroup(isExpanded: $showSettings) {
                        storeSettings
                    } label: {
                        Text(shop.words.callIt("mac.ws_settings")).font(.callout)
                    }
                }
                if let page = connection.flatMap(CatalogPublisher.shopPage) {
                    Section(shop.words.callIt("mac.ws_page")) {
                        Text(verbatim: page.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        HStack {
                            Button(shop.words.callIt("mac.ws_open_page")) { NSWorkspace.shared.open(page) }
                            Button(shop.words.callIt(copied ? "store.copied" : "store.copy_link")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(page.absoluteString, forType: .string)
                                copied = true
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if shop.webStoreBusy { ProgressView().controlSize(.small) }
                Spacer()
                if shop.webStoreLive != false {
                    Button(shop.words.callIt("store.unpublish"), role: .destructive) { askingOffline = true }
                        .disabled(shop.webStoreBusy || !shop.lockAllows("settings", "edit"))
                }
                Button(shop.words.callIt("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt(shop.webStoreLive == true ? "mac.ws_update" : "store.publish")) {
                    Task { await shop.publishWebStore(withPhotos: photos) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(shop.webStoreBusy || count == 0 || !shop.lockAllows("settings", "edit"))
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 640)
        .confirmationDialog(shop.words.callIt("store.unpublish_q"), isPresented: $askingOffline) {
            Button(shop.words.callIt("store.unpublish"), role: .destructive) {
                Task { await shop.unpublishWebStore() }
            }
        }
        .task(id: shop.productRows) {
            count = await shop.webStoreCount()
            review = await shop.webStoreReview()
        }
        .task(id: shop.settingsValue) {
            let now = StorefrontDraft(shop.settingsDict)
            if store == storeSaved { store = now }
            storeSaved = now
        }
        .task { await shop.refreshWebStore() }
    }

    @ViewBuilder private var storeSettings: some View {
        let w = shop.words
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            settingRow("store.note_label", $store.note, prompt: w.callIt("store.note_ph"))
            settingRow("store.lead_time", $store.leadTime, prompt: w.callIt("store.lead_ph"))
            settingRow("store.min_order", $store.minOrder, unit: shop.currency, width: 100)
            settingRow("store.deposit_pct", $store.depositPct, unit: "%", width: 70)
            settingRow("store.tax_rate", $store.taxRate, unit: "%", width: 70)
            settingRow("store.pay_url", $store.payUrl, prompt: "https://pay…/{amount}")
        }
        Text(w.callIt("store.pay_url_hint"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text(w.callIt("store.shipping_label")).font(.callout.weight(.medium)).padding(.top, 6)
        ForEach($store.shipping) { $row in
            HStack {
                TextField(w.callIt("store.ship_label_ph"), text: $row.label).textFieldStyle(.roundedBorder)
                TextField("0", text: $row.price).textFieldStyle(.roundedBorder).frame(width: 80)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                Text(shop.currency).foregroundStyle(.secondary)
                Button(role: .destructive) { store.shipping.removeAll { $0.id == row.id } } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(w.callIt("common.delete"))
            }
        }
        Button("+ " + w.callIt("store.add_shipping")) { store.shipping.append(.init()) }
            .disabled(store.shipping.count >= 8)

        Text(w.callIt("store.promos_label")).font(.callout.weight(.medium)).padding(.top, 6)
        ForEach($store.promos) { $promo in
            HStack {
                TextField(w.callIt("store.promo_code"), text: $promo.code).textFieldStyle(.roundedBorder)
                Picker("", selection: $promo.fixed) {
                    Text(verbatim: "%").tag(false)
                    Text(verbatim: shop.currency).tag(true)
                }
                .labelsHidden().fixedSize()
                TextField("0", text: $promo.value).textFieldStyle(.roundedBorder).frame(width: 64)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                TextField(w.callIt("store.promo_expires"), text: $promo.expires).textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                TextField("∞", text: $promo.maxUses).textFieldStyle(.roundedBorder).frame(width: 50)
                    .help(w.callIt("store.promo_max"))
                Button(role: .destructive) { store.promos.removeAll { $0.id == promo.id } } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(w.callIt("common.delete"))
            }
        }
        Button("+ " + w.callIt("store.add_promo")) { store.promos.append(.init()) }

        HStack {
            Spacer()
            Button(w.callIt("common.cancel")) { store = storeSaved }
                .disabled(store == storeSaved)
            Button(w.callIt("common.save")) { Task { await shop.saveStorefront(store, opened: storeSaved) } }
                .disabled(store == storeSaved || !shop.canMoveJobs)
        }
        .padding(.top, 6)
    }

    private func settingRow(_ key: String, _ text: Binding<String>, prompt: String = "",
                            unit: String? = nil, width: CGFloat? = nil) -> some View {
        GridRow {
            Text(shop.words.callIt(key)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack {
                TextField(prompt, text: text).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: width ?? .infinity)
                if let unit { Text(verbatim: unit).foregroundStyle(.secondary) }
            }
        }
    }

    private func banner(symbol: String?, tint: some ShapeStyle, text: String, at: Date?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let at {
                Text(shop.words.say(at, Date.FormatStyle(date: .omitted, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding([.horizontal, .top])
        .accessibilityIdentifier("webstore-outcome")
    }
}

/// One price a live store held back: the product, what customers see now and
/// what it would become, as MONEY — and the way to set it by hand.
///
/// The two figures were the catalogue's bare strings ("50" → "48.5"), with no
/// currency and no grouping, beside nothing to do about them but publish.
struct HeldPriceRow: View {
    let shop: Shop
    let change: WebStorePriceChange
    var edit: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Khayt.attention)
            Text(verbatim: change.name).font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: Self.figures(change, currency: shop.currency))
                .font(.callout.monospacedDigit())
            Button(shop.words.callIt("mac.edit_product") + "\u{2026}", action: edit)
                .controlSize(.small)
                .disabled(!shop.canMoveJobs)
        }
    }

    /// "SAR 50.00 → SAR 48.50", or just the new figure when the store had
    /// none to show (a "was" of nothing is not a price, and "→ 48.50" with a
    /// blank in front of it reads as a fault).
    static func figures(_ change: WebStorePriceChange, currency: String) -> String {
        let now = money(change.now, currency)
        guard let was = money(change.was, currency), !change.was.trimmingCharacters(in: .whitespaces).isEmpty else {
            return now ?? change.now
        }
        // Old to new, left to right, in either language: figures read left
        // to right in Arabic too, and the line is held in that order (a
        // left-to-right isolate) so the arrow always points at the new one.
        return "\u{2066}" + was + " \u{2192} " + (now ?? change.now) + "\u{2069}"
    }

    static func money(_ text: String, _ currency: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let n = Double(t) else { return t.isEmpty ? nil : t }
        return Money.text(n, currency)
    }
}
