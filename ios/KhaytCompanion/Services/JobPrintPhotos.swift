import Foundation
import UIKit
import KhaytCore

/// The job's own photos of the finished print: `printLog[].printPhotos[]`.
///
/// ── WHERE THEY COME FROM ─────────────────────────────────────────────────
///
/// The Mac (`OrderPhoto`, `FinishCamera`) and the desktop (`hub:save-order-photo`,
/// `captureFinishPhotos` in renderer/integrations.js) write the same record:
///
///     { "thumb": "data:image/jpeg;base64,…", "filename": "{id}-{n}-{base36}.jpg" }
///
/// The THUMBNAIL (240 px, JPEG) is inline, so it travels with the book and
/// reaches this phone in its copy. The full-size file is named only: it sits
/// in `order-photos/` beside the store on the computer that took it, and no
/// route sends it to a phone. That is why this page shows the thumbnails and
/// adds nothing to the list — a photo added here would have no full-size file
/// anywhere, and the Portfolio on the computer would hold a cell it cannot open.
///
/// The printer's own photo at the end of a print is one of these records, in
/// the same shape: neither app marks where a photo came from, so this page
/// does not label one as the printer's either. Portfolio shows every one of
/// them; there is no per-photo "in the portfolio" flag in the book.
///
/// These are NOT the photos on the customer's tracking page (`OrderPhotos`),
/// which live in Khayt Cloud beside the published item.
struct JobPrintPhoto: Identifiable, Equatable, Sendable {
    /// The position in the job's list: what the other apps' filenames carry.
    let index: Int
    /// The thumbnail's bytes, decoded from the record's data URI.
    let thumb: Data
    /// The full-size file's name on the computer, when there is one.
    let filename: String?
    var id: Int { index }
}

extension KhaytAPIClient {
    /// The job's photos from this phone's copy of the book. Empty when the
    /// phone holds no book or the job has none.
    func printPhotos(orderId: String) -> [JobPrintPhoto] {
        guard let book, book.exists, let store = try? book.read() else { return [] }
        return Self.printPhotos(in: store, orderId: orderId)
    }

    /// A thumbnail bigger than this is not one either app writes (240 px at
    /// 0.85 is a few tens of KB), and is not decoded.
    nonisolated static let maxThumbBytes = 1_000_000

    /// Pure, for the tests: the records as the Mac and the desktop write them.
    /// A row that is not an object (an old book's bare filename string) or
    /// whose thumbnail is not an inline JPEG or PNG is skipped, and keeps its
    /// index so the others still line up with their files.
    nonisolated static func printPhotos(in store: [String: JSONValue], orderId: String) -> [JobPrintPhoto] {
        guard case .array(let rows)? = store["printLog"] else { return [] }
        for row in rows {
            guard case .object(let job) = row, job["id"] == .string(orderId) else { continue }
            guard case .array(let photos)? = job["printPhotos"] else { return [] }
            var out: [JobPrintPhoto] = []
            for (i, photo) in photos.enumerated() {
                guard case .object(let p) = photo, case .string(let uri)? = p["thumb"],
                      let bytes = thumbBytes(uri) else { continue }
                var name: String?
                if case .string(let f)? = p["filename"], !f.isEmpty { name = f }
                out.append(JobPrintPhoto(index: i, thumb: bytes, filename: name))
            }
            return out
        }
        return []
    }

    /// The bytes of an inline `data:image/jpeg|png;base64,` thumbnail, and
    /// nothing else: a URL in the record is never fetched.
    nonisolated static func thumbBytes(_ uri: String) -> Data? {
        let prefixes = ["data:image/jpeg;base64,", "data:image/jpg;base64,", "data:image/png;base64,"]
        guard let prefix = prefixes.first(where: { uri.lowercased().hasPrefix($0) }) else { return nil }
        let body = uri.dropFirst(prefix.count)
        // Base64 is 4 characters for 3 bytes: refuse before decoding.
        guard body.count <= maxThumbBytes / 3 * 4 + 4,
              let data = Data(base64Encoded: String(body), options: .ignoreUnknownCharacters),
              !data.isEmpty else { return nil }
        let jpeg = data.starts(with: [0xFF, 0xD8, 0xFF])
        guard jpeg || OrderPhotoPrep.isPNG(data) else { return nil }
        return data
    }
}

/// What the Mac said to a photo sent from this phone.
enum JobPhotoUpload: Equatable, Sendable {
    case added(index: Int)
    case refused(String)

    /// 201 `{ ok, index, filename }`; otherwise the refusal's `reason`, or
    /// one read off the status the route documents.
    static func read(status: Int, body: Data) -> JobPhotoUpload {
        let o: [String: JSONValue] = {
            if case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: body) { return o }
            return [:]
        }()
        if (200...299).contains(status), o["ok"] == .bool(true) {
            if case .number(let n)? = o["index"] { return .added(index: Int(n)) }
            return .added(index: -1)
        }
        if case .string(let r)? = o["reason"], !r.isEmpty { return .refused(r) }
        switch status {
        case 403: return .refused("device-key-required")
        // The route's own 404 says `not-found`; a bare one is a Mac from
        // before the route (beta.26 and older), which has no such address.
        case 404: return .refused("old-mac")
        case 409: return .refused("read-only")
        case 413: return .refused("too-large")
        case 415: return .refused("not-an-image")
        default: return .refused("unreachable")
        }
    }

    /// What to tell the person when it was not added.
    var sentence: String {
        switch self {
        case .added: return ""
        case .refused(let r):
            switch r {
            case "device-key-required": return L10n.tr("printphotos.why.device")
            case "not-found": return L10n.tr("printphotos.why.not_found")
            case "old-mac": return L10n.tr("printphotos.why.old_mac")
            case "read-only": return L10n.tr("printphotos.why.read_only")
            case "too-large": return L10n.tr("printphotos.why.too_large")
            case "not-an-image": return L10n.tr("printphotos.why.not_image")
            default: return L10n.tr("printphotos.why.unreachable")
            }
        }
    }
}
