import Foundation
import AppKit

/// A picture of a model that has none of its own.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// A 3MF carries a preview its slicer drew; an STL carries nothing but
/// triangles. A shop that imports its downloads folder therefore gets a library
/// of identical grey cubes — 445 of 472 on the book this was written against,
/// on the one screen in the app whose whole job is showing what the shop has.
///
/// The geometry is right there. The app already reads every triangle of an STL
/// to count them and measure the box they sit in, so drawing them costs one
/// more pass over the same bytes.
///
/// ── WHY IT IS DRAWN BY HAND ───────────────────────────────────────────────
///
/// No SceneKit, no Metal, no offscreen window: a software rasteriser is about
/// sixty lines, has no device to lose and no context to fail to create, and
/// runs the same on every Mac and inside a test. It is a thumbnail — a
/// z-buffer and flat shading is the whole of what it needs.
///
/// NOTHING IS HELD. The triangles are streamed twice, once to find the box and
/// once to draw, so a 400 MB mesh is never resident. That is the same reason
/// `Mesh` streams, and it is why this shares its reader rather than parsing
/// the file a second way.
enum MeshPreview {

    /// Rendered at twice the asked size and halved, which is the cheapest
    /// antialiasing there is: a thumbnail of a mesh is all silhouette, and a
    /// hard-edged one looks like a screenshot of a bug.
    static let scale = 2

    /// A PNG of the model, or nil when the file holds no triangles to draw.
    static func png(of url: URL, size: Int = 256) throws -> Data? {
        let isOBJ = url.pathExtension.lowercased() == "obj"
        guard let box = try (isOBJ ? Mesh.measureOBJ(url) : Mesh.measureSTL(url)),
              box.triangleCount > 0 else { return nil }
        let side = size * scale

        // The model, centred and turned to a three-quarter view. Straight on it
        // is a rectangle; turned, a shape a person recognises as the thing.
        let cx = (box.minX + box.maxX) / 2
        let cy = (box.minY + box.maxY) / 2
        let cz = (box.minZ + box.maxZ) / 2
        let yaw = 35.0 * .pi / 180, pitch = 24.0 * .pi / 180
        let cosY = cos(yaw), sinY = sin(yaw), cosP = cos(pitch), sinP = sin(pitch)

        // Z is up in a print file, so the camera's "up" is the model's Z.
        @inline(__always)
        func view(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let dx = x - cx, dy = y - cy, dz = z - cz
            let rx = dx * cosY + dy * sinY
            let ry = -dx * sinY + dy * cosY
            return (rx, dz * cosP - ry * sinP, ry * cosP + dz * sinP)
        }

        // A first pass for the extent of the TURNED model: the box of the
        // original does not bound its own projection, and scaling to it clips
        // the corners off anything long and diagonal.
        var minU = Double.infinity, maxU = -Double.infinity
        var minV = Double.infinity, maxV = -Double.infinity
        let corners = [(box.minX, box.minY, box.minZ), (box.maxX, box.minY, box.minZ),
                       (box.minX, box.maxY, box.minZ), (box.maxX, box.maxY, box.minZ),
                       (box.minX, box.minY, box.maxZ), (box.maxX, box.minY, box.maxZ),
                       (box.minX, box.maxY, box.maxZ), (box.maxX, box.maxY, box.maxZ)]
        for c in corners {
            let p = view(c.0, c.1, c.2)
            minU = min(minU, p.0); maxU = max(maxU, p.0)
            minV = min(minV, p.1); maxV = max(maxV, p.1)
        }
        let span = max(maxU - minU, maxV - minV)
        guard span > 0, span.isFinite else { return nil }
        let margin = 0.90
        let k = Double(side) * margin / span
        let offU = Double(side) / 2 - (minU + maxU) / 2 * k
        let offV = Double(side) / 2 + (minV + maxV) / 2 * k   // screen Y grows downward

        var depth = [Double](repeating: -.infinity, count: side * side)
        var shade = [UInt8](repeating: 0, count: side * side)
        var covered = [Bool](repeating: false, count: side * side)

        // Light over the viewer's left shoulder, which is where a person
        // expects it and what makes a curve read as a curve.
        let lx = -0.45, ly = 0.62, lz = 0.64

        // The draw itself, given a triangle. Both formats feed it: a text STL
        // is a CAD package's default and sixteen of this shop's models are one,
        // and reading only the binary form left exactly those as grey cubes.
        func draw(_ ax: Double, _ ay: Double, _ az: Double,
                  _ bx: Double, _ by: Double, _ bz: Double,
                  _ cxx: Double, _ cyy: Double, _ czz: Double) {
            let a = view(ax, ay, az), b = view(bx, by, bz), c = view(cxx, cyy, czz)
            let ux = a.0 * k + offU, uy = offV - a.1 * k
            let vx = b.0 * k + offU, vy = offV - b.1 * k
            let wx = c.0 * k + offU, wy = offV - c.1 * k

            let area = (vx - ux) * (wy - uy) - (wx - ux) * (vy - uy)
            if abs(area) < 1e-12 { return }

            // The normal from the CORNERS, never the one in the file: STL
            // normals are frequently zero and frequently wrong, which `Mesh`
            // says at greater length where it ignores them too.
            let e1 = (bx - ax, by - ay, bz - az), e2 = (cxx - ax, cyy - ay, czz - az)
            var nx = e1.1 * e2.2 - e1.2 * e2.1
            var ny = e1.2 * e2.0 - e1.0 * e2.2
            var nz = e1.0 * e2.1 - e1.1 * e2.0
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            if len > 0 { nx /= len; ny /= len; nz /= len }
            // Two-sided: a mesh with inconsistent winding is common and its
            // inside-out facets should still be lit rather than black.
            let lambert = abs(nx * lx + ny * ly + nz * lz)
            let tone = 0.28 + 0.72 * lambert
            let value = UInt8(max(0, min(255, (tone * 235).rounded())))

            let loX = max(0, Int(min(ux, vx, wx).rounded(.down)))
            let hiX = min(side - 1, Int(max(ux, vx, wx).rounded(.up)))
            let loY = max(0, Int(min(uy, vy, wy).rounded(.down)))
            let hiY = min(side - 1, Int(max(uy, vy, wy).rounded(.up)))
            if loX > hiX || loY > hiY { return }

            let za = a.2, zb = b.2, zc = c.2
            for py in loY...hiY {
                let fy = Double(py) + 0.5
                for px in loX...hiX {
                    let fx = Double(px) + 0.5
                    // Barycentric, normalised by the signed area so a triangle
                    // wound either way fills the same pixels.
                    var w0 = ((vx - ux) * (fy - uy) - (fx - ux) * (vy - uy)) / area
                    var w1 = ((fx - ux) * (wy - uy) - (wx - ux) * (fy - uy)) / area
                    if w0 < 0 || w1 < 0 || w0 + w1 > 1 { continue }
                    let w2 = 1 - w0 - w1
                    swap(&w0, &w1)
                    let z = za * w2 + zb * w1 + zc * w0
                    let at = py * side + px
                    if z > depth[at] {
                        depth[at] = z
                        shade[at] = value
                        covered[at] = true
                    }
                }
            }
        }

        if isOBJ {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                Mesh.eachOBJTriangle(text, draw)
            }
        } else if try !Mesh.eachSTLTriangle(url, draw),
                  let text = try? String(contentsOf: url, encoding: .utf8) {
            Mesh.eachAsciiSTLTriangle(text, draw)
        }

        guard covered.contains(true) else { return nil }
        return encode(shade: shade, covered: covered, side: side, out: size)
    }

    /// Grey on transparency, halved as it goes.
    ///
    /// Transparent rather than white: the tile behind it has a colour of its
    /// own and changes with the appearance, and a white square baked into the
    /// picture is a white square in dark mode.
    private static func encode(shade: [UInt8], covered: [Bool],
                               side: Int, out: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: out, pixelsHigh: out,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: out * 4, bitsPerPixel: 32),
            let pixels = rep.bitmapData else { return nil }

        let n = side / out
        for y in 0..<out {
            for x in 0..<out {
                var sum = 0, hits = 0
                for dy in 0..<n {
                    for dx in 0..<n {
                        let at = (y * n + dy) * side + (x * n + dx)
                        if covered[at] { sum += Int(shade[at]); hits += 1 }
                    }
                }
                let p = (y * out + x) * 4
                let value = hits > 0 ? UInt8(sum / hits) : 0
                // The average of the covered samples, with coverage as alpha —
                // so the silhouette's edge fades instead of stepping.
                pixels[p] = value; pixels[p + 1] = value; pixels[p + 2] = value
                pixels[p + 3] = UInt8(255 * hits / (n * n))
            }
        }
        return rep.representation(using: .png, properties: [:])
    }
}
