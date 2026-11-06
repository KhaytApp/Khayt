import Foundation
import ImageIO
import UniformTypeIdentifiers
import KhaytCore

/// A picture made ready for a MakerRun listing, as the desktop's
/// `fitImageBuffer(buf, {maxEdge: 2048, budgetBytes: 14 MB})` makes it:
/// MakerRun refuses an image past its limits rather than resampling, and
/// promises to keep exactly what it is sent.
enum MakerRunPicture {
    static let maxEdge = 2048
    static let budget = 14 * 1024 * 1024

    /// The bytes to send, or nil when they are not a picture ImageIO reads.
    /// A JPEG, PNG or WebP that already fits goes as it is; anything else is
    /// redrawn to fit and sent as JPEG.
    static func fitted(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            // Not readable here. WebP the system cannot decode goes as-is,
            // and MakerRun measures it — the desktop's exception too.
            return MakerRun.sniffImageType(data) == "image/webp" && data.count <= budget ? data : nil
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        if max(w, h) <= maxEdge, data.count <= budget, MakerRun.sniffImageType(data) != nil { return data }
        var quality = 0.9
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        while quality >= 0.4 {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if out.length <= budget { return out as Data }
            quality -= 0.15
        }
        return nil
    }
}
