import Foundation
import UIKit
import KhaytCore

/// Photos of an order — the finished part, usually — kept on the customer's
/// tracking page (`/p/{token}`), not only shared once in a chat.
///
/// khayt-cloud "Customer portal & published items", added 2026-10-10
/// (khayt-cloud #111). A photo is kept BESIDE the published item rather than in
/// its payload, so the Mac republishing the order after a move leaves it in
/// place. The phone talks to the cloud with its OWN sign-in (`CloudSession`):
/// the route wants the shop token with a write role, and the Mac is not in the
/// path.
///
/// ── WHAT THE PHONE CANNOT DO ──────────────────────────────────────────────
///
/// It cannot publish. An order gets its link (its `trackingToken`) when the
/// shop publishes it from the Mac; until then there is no page to put a photo
/// on and the cloud answers 404. The card says so instead of offering a button
/// that will fail.
extension KhaytAPIClient {
    struct OrderPhoto: Codable, Identifiable, Equatable, Sendable {
        let id: String
        /// A path on the cloud (`/v1/p/{token}/photos/{id}`), public to whoever holds the link.
        let url: String
        let mime: String?
        let bytes: Int?
        let at: String?
    }

    /// Whether this order's page can carry photos from this phone.
    enum PhotoAccess: Equatable {
        case ready(token: String)
        /// The order has no link yet — the Mac publishes it.
        case notPublished
        /// This phone is not signed in to Khayt Cloud.
        case needsCloud
        /// Signed in as a viewer: may look, may not add.
        case viewOnly(token: String)
    }

    enum PhotoFailure: LocalizedError, Equatable {
        case full(max: Int)
        case tooLarge
        case notPublished
        case viewer
        case notAnImage
        case other(String)

        var errorDescription: String? {
            switch self {
            case .full(let max): return L10n.format("photos.err.full", max)
            case .tooLarge: return L10n.tr("photos.err.too_large")
            case .notPublished: return L10n.tr("photos.err.not_published")
            case .viewer: return L10n.tr("photos.err.viewer")
            case .notAnImage: return L10n.tr("photos.err.not_an_image")
            case .other(let words): return words
            }
        }
    }

    /// The cloud's limits, from the contract.
    nonisolated static let maxPhotoBytes = 2_000_000
    nonisolated static let maxPhotosPerOrder = 6

    /// The order's tracking token, from the book. Pure, for the tests.
    nonisolated static func trackingToken(in store: [String: JSONValue], orderId: String) -> String? {
        guard case .array(let rows)? = store["printLog"] else { return nil }
        for row in rows {
            guard case .object(let o) = row, o["id"] == .string(orderId) else { continue }
            if case .string(let t)? = o["trackingToken"], !t.isEmpty { return t }
            return nil
        }
        return nil
    }

    func photoAccess(orderId: String) -> PhotoAccess {
        guard let book, book.exists, let store = try? book.read(),
              let token = Self.trackingToken(in: store, orderId: orderId) else { return .notPublished }
        guard let cloud else { return .needsCloud }
        return cloud.canWrite ? .ready(token: token) : .viewOnly(token: token)
    }

    /// The order's photos, oldest first — read from the PUBLIC item, which is
    /// the only route that lists them (the owner side has add and delete).
    func orderPhotos(token: String) async throws -> [OrderPhoto] {
        guard let cloud, let url = Self.cloudURL(cloud.url, path: "/v1/p/" + Self.segment(token)) else { return [] }
        let (data, response) = try await CloudReader.session.data(for: URLRequest(url: url))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw PhotoFailure.notPublished }
        guard code == 200 else { throw Self.photoFailure(status: code, body: data) }
        struct Item: Decodable { let photos: [OrderPhoto]? }
        return (try JSONDecoder().decode(Item.self, from: data)).photos ?? []
    }

    /// Put a photo on the order's page. `bytes` must already be upright —
    /// `OrderPhotoPrep.upright` — because the cloud strips EXIF, orientation with it.
    func addOrderPhoto(token: String, bytes: Data) async throws -> OrderPhoto {
        guard let cloud else { throw PhotoFailure.other(L10n.tr("cloud.signed_out")) }
        guard cloud.canWrite else { throw PhotoFailure.viewer }
        guard bytes.count <= Self.maxPhotoBytes else { throw PhotoFailure.tooLarge }
        var request = try CloudReader.request(
            CloudReader.Connection(url: cloud.url, shopId: cloud.shopId, storedToken: ""),
            token: cloud.token, method: "POST", tail: Self.photosTail(token: token))
        request.setValue(OrderPhotoPrep.isPNG(bytes) ? "image/png" : "image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = bytes
        request.timeoutInterval = 90
        let (data, response) = try await CloudReader.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Self.photoFailure(status: code, body: data) }
        struct Reply: Decodable { let photo: OrderPhoto }
        return try JSONDecoder().decode(Reply.self, from: data).photo
    }

    func deleteOrderPhoto(token: String, id: String) async throws {
        guard let cloud else { throw PhotoFailure.other(L10n.tr("cloud.signed_out")) }
        guard cloud.canWrite else { throw PhotoFailure.viewer }
        let request = try CloudReader.request(
            CloudReader.Connection(url: cloud.url, shopId: cloud.shopId, storedToken: ""),
            token: cloud.token, method: "DELETE", tail: Self.photosTail(token: token) + "/" + Self.segment(id))
        let (data, response) = try await CloudReader.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Already gone is what was asked for.
        guard code == 200 || code == 404 else { throw Self.photoFailure(status: code, body: data) }
    }

    /// Where a listed photo is fetched from: the cloud's address plus its path.
    func photoURL(_ photo: OrderPhoto) -> URL? {
        guard let cloud else { return nil }
        return Self.cloudURL(cloud.url, path: photo.url)
    }

    // MARK: - Pure parts

    nonisolated static func photosTail(token: String) -> String {
        "/published/" + segment(token) + "/photos"
    }

    /// One path segment, RFC 3986 unreserved characters only — the same
    /// spelling as `encodeURIComponent` for every token the cloud issues.
    nonisolated static func segment(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// An https cloud address plus a path that must start with `/v1/` — a
    /// listed photo's `url` is the cloud's word, and is never followed off it.
    nonisolated static func cloudURL(_ base: String, path: String) -> URL? {
        guard path.hasPrefix("/v1/"), !path.contains("//"), !path.contains(".."),
              let b = URL(string: base), b.scheme == "https", b.host != nil else { return nil }
        var root = b.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: root + path)
    }

    /// The cloud's refusal, as the person can act on it.
    nonisolated static func photoFailure(status: Int, body: Data) -> PhotoFailure {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch status {
        case 409: return .full(max: (json?["max"] as? Int) ?? maxPhotosPerOrder)
        case 413: return .tooLarge
        case 404: return .notPublished
        case 403: return .viewer
        case 400: return .notAnImage
        default:
            if let words = json?["error"] as? String, !words.isEmpty { return .other(words) }
            return .other(L10n.format("photos.err.http", status))
        }
    }
}

/// A photo made ready for the cloud: upright pixels, JPEG, within 2 MB.
///
/// The cloud strips EXIF before storing — a phone photo's EXIF carries the
/// workshop's GPS position — and the orientation tag goes with it. A portrait
/// photo sent as the camera wrote it would land on the customer's page on its
/// side, so the pixels are redrawn upright here first.
enum OrderPhotoPrep {
    /// Longest edge, in pixels. A tracking page shows a photo phone-sized; a
    /// 48 MP original would only be shrunk again by the size cap.
    static let maxEdge: CGFloat = 2048

    static func upright(_ image: UIImage, maxBytes: Int = KhaytAPIClient.maxPhotoBytes) -> Data? {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard px.width > 0, px.height > 0 else { return nil }
        var edge = min(maxEdge, max(px.width, px.height))
        while edge >= 320 {
            let k = edge / max(px.width, px.height)
            let size = CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            // `draw(in:)` applies `imageOrientation`: what comes out is upright,
            // and a JPEG from the renderer carries no orientation tag at all.
            let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality in [0.82, 0.7, 0.55] as [CGFloat] {
                if let data = drawn.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
            }
            edge *= 0.75
        }
        return nil
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }
}
