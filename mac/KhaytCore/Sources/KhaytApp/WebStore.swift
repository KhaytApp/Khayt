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

    /// Whether a catalogue is published, and when it last changed. A 404 is the
    /// answer "no", not a fault.
    static func status(_ connection: CloudReader.Connection, token: String,
                       fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws -> (live: Bool, at: Date?) {
        let request = try CloudReader.request(connection, token: token, method: "GET", tail: "/catalog")
        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            let body = try? JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let o)? = body, let catalog = o["catalog"], catalog != .null else {
                return (false, nil)
            }
            var at: Date?
            if case .string(let s)? = o["updatedAt"] { at = try? Date(s, strategy: .iso8601) }
            if at == nil, case .number(let ms)? = o["updatedAt"] { at = Date(timeIntervalSince1970: ms / 1000) }
            return (true, at)
        case 404: return (false, nil)
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
    func publishWebStore(withPhotos: Bool = WebStoreSheet.photosOn) async {
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
            if case .object(let o) = catalog, case .array(let items)? = o["items"], items.isEmpty {
                throw CatalogPublisher.Failure.empty
            }
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            let session = URLSession(configuration: .ephemeral)
            try await CatalogPublisher.publish(connection, token: token, catalog: catalog) {
                try await session.data(for: $0)
            }
            webStoreLive = true
            webStoreAt = Date()
            webStoreSaid = words.callIt("store.published")
            webStoreProblem = false
        } catch {
            webStoreSaid = words.callIt("mac.ws_failed") + " " + webStoreReason(error)
            webStoreProblem = true
        }
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
              webStoreLive == true, source.build != nil else { return }
        webStoreRepublish?.cancel()
        webStoreRepublish = Task { [weak self] in
            try? await Task.sleep(for: CatalogPublisher.followDelay)
            guard !Task.isCancelled else { return }
            await self?.publishWebStore()
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

// MARK: - The sheet

/// Publish, update or take down the web store, from the catalogue.
struct WebStoreSheet: View {
    @Bindable var shop: Shop
    @Environment(\.dismiss) private var dismiss
    @AppStorage("webstore.photos") private var photos = true
    @State private var count = 0
    @State private var askingOffline = false
    @State private var copied = false

    /// Whether pictures are sent; the live store's own republishes read it too.
    static var photosOn: Bool {
        UserDefaults.standard.object(forKey: "webstore.photos") as? Bool ?? true
    }

    private var connection: CloudReader.Connection? { try? CloudReader.connection(shop.settingsDict) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    if let said = shop.webStoreSaid {
                        Text(said)
                            .font(.caption)
                            .foregroundStyle(shop.webStoreProblem ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
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
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360)
        .confirmationDialog(shop.words.callIt("store.unpublish_q"), isPresented: $askingOffline) {
            Button(shop.words.callIt("store.unpublish"), role: .destructive) {
                Task { await shop.unpublishWebStore() }
            }
        }
        .task(id: shop.productRows.count) { count = await shop.webStoreCount() }
        .task { await shop.refreshWebStore() }
    }
}
