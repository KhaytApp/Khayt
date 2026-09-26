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
    nonisolated static func hero(_ file: URL, maxDim: Int, quality: Double) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
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

    /// Ask the service whether the store is live. Quiet about a shop with no cloud.
    func refreshWebStore() async {
        guard let build = source.build, Self.cloudConnected(settingsDict) else {
            webStoreLive = nil; return
        }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = URLSession(configuration: .ephemeral)
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
        guard let engine, let build = source.build else { return }
        webStoreRepublish?.cancel()
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
            let session = URLSession(configuration: .ephemeral)

            // ── AN AUTOMATIC PUBLISH ASKS FIRST ────────────────────────────
            //
            // "Live" here is what this Mac last heard. The store may have been
            // taken offline from the desktop since, and republishing it on the
            // next edit would put it back online without anybody asking. So a
            // publish nobody pressed checks the store is still live, and stops
            // following it if not.
            if automatic {
                let now = try await CatalogPublisher.status(connection, token: token) { try await session.data(for: $0) }
                guard now.live else {
                    webStoreLive = false
                    webStoreHeld = now
                    return
                }
                // EVERYTHING WAS DELETED. The service refuses an empty catalogue,
                // so without this the old one stayed up: customers could still
                // order what the shop had removed. An empty catalogue now means
                // no store, and the shop is told.
                if sent == 0 {
                    try await CatalogPublisher.publish(connection, token: token, catalog: nil) {
                        try await session.data(for: $0)
                    }
                    webStoreLive = false
                    webStoreHeld = CatalogPublisher.Held(live: false)
                    webStoreAt = Date()
                    webStoreSaid = words.callIt("mac.ws_emptied")
                    webStoreProblem = true
                    webStoreSaidAt = Date()
                    moveNotices.append(webStoreSaid ?? "")
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
        guard let build = source.build else { return }
        webStoreRepublish?.cancel()
        webStoreBusy = true
        defer { webStoreBusy = false }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = URLSession(configuration: .ephemeral)
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
              webStoreLive == true, let book = source.build?.storeURL,
              cloudRoleCanWrite else { return }
        webStoreRepublish?.cancel()
        webStoreRepublish = Task { [weak self] in
            try? await Task.sleep(for: CatalogPublisher.followDelay)
            // Still the same book, and still live: a book opened in the
            // meantime is a different shop with a store of its own.
            guard !Task.isCancelled, let self, self.source.build?.storeURL == book,
                  self.webStoreLive == true else { return }
            await self.publishWebStore(automatic: true)
        }
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
            let made = await Task.detached(priority: .utility) {
                CatalogPublisher.hero(file, maxDim: dim, quality: quality)
            }.value
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

    /// Save the store's shop-wide settings.
    func saveStorefront(_ draft: StorefrontDraft) async {
        guard let build = source.build else { return }
        do {
            try StoreWriter.update(build) { root in
                var settings = Self.settings(root)
                var sf: [String: JSONValue] = [:]
                if case .object(let had)? = settings["storefront"] { sf = had }
                draft.apply(to: &sf)
                settings["storefront"] = .object(sf)
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
                        .disabled(shop.webStoreBusy)
                }
                Button(shop.words.callIt("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt(shop.webStoreLive == true ? "mac.ws_update" : "store.publish")) {
                    Task { await shop.publishWebStore(withPhotos: photos) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(shop.webStoreBusy || count == 0)
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
            Button(w.callIt("common.save")) { Task { await shop.saveStorefront(store) } }
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
