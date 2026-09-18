import Foundation
import AppKit
import KhaytCore

/// The shop's own mark, as it goes onto a document.
///
/// ── THE RULE IS THE OTHER APP'S, AND IT IS A SECURITY RULE ────────────────
///
/// `safeBizLogo()` in `renderer/app-helpers.js` passes a value only when it
/// begins `data:image/`. That is not fussiness: an invoice goes to a customer,
/// and a settings file that could put an arbitrary URL into it would make every
/// invoice a beacon — or worse, a broken image where the shop's mark should be,
/// on a document nobody re-reads before sending.
///
/// So the bytes travel INSIDE the book. Which is also why there is a size cap:
/// the logo is in every sync, every backup and every export of the settings.
enum ShopLogo {

    /// The other app's own cap — `file.size > 1024 * 1024` in `wire-events.js`.
    static let maxBytes = 1024 * 1024

    /// The formats worth accepting, by their own opening bytes rather than by
    /// the name somebody gave the file. PNG first because it is the one that
    /// keeps a transparent background, which is what a logo on white paper
    /// wants.
    static func mediaType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        // An SVG is text and could carry a script, so it is refused rather
        // than sniffed — the document that would draw it is handed to a
        // customer.
        return nil
    }

    enum Refused: LocalizedError, Equatable {
        case tooBig(Int)
        case notAnImage

        var errorDescription: String? {
            switch self {
            case .tooBig: "set.logo_too_big"
            case .notAnImage: "settings.logo_invalid_type"
            }
        }
    }

    /// The file as the book stores it: `data:<type>;base64,<bytes>`.
    ///
    /// NOT re-encoded. A logo is line art and a shop's own file is already the
    /// size it wants; running it through a JPEG encoder would put a halo round
    /// every edge and lose the transparency the paper needs.
    static func dataURI(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw Refused.tooBig(data.count) }
        guard let type = mediaType(of: data) else { throw Refused.notAnImage }
        return "data:\(type);base64," + data.base64EncodedString()
    }

    /// The stored value, as anything that draws it should read it — the same
    /// test the document applies, so a picture the invoice will not print is
    /// not shown in Settings as though it would.
    static func image(from stored: String?) -> NSImage? {
        guard let stored, stored.hasPrefix("data:image/"),
              let comma = stored.firstIndex(of: ","),
              let data = Data(base64Encoded: String(stored[stored.index(after: comma)...])),
              let image = NSImage(data: data) else { return nil }
        return image
    }
}
