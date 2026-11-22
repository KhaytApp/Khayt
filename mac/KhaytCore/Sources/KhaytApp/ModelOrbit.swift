import SwiftUI
import AppKit
import SceneKit
import KhaytCore

/// The library's 3D viewer: a model you can orbit, zoom and pan, drawn solid
/// or as wireframe, in its filaments' colours or plain.
///
/// ── WHERE THE TRIANGLES COME FROM ─────────────────────────────────────────
///
/// A 3MF is read by `lib/mf-mesh.js` (`StudioEngine.viewerMesh`) — the
/// extractor the desktop's viewer draws from, so the two apps place the same
/// objects on the same plates in the same colours: paint, per-part filament
/// and PrusaSlicer volumes all resolve there, not in a second reader here.
/// STL and OBJ carry no colour and are streamed by `Mesh`, the reader that
/// measures them. A 3MF too big to hand to the engine falls back to `Mesh`
/// too, without colours, rather than to nothing.
///
/// ── THE BUDGETS ARE THE DESKTOP'S ─────────────────────────────────────────
///
/// Files past 150 MB are not drawn (`MESH_ANALYSIS_MAX_BYTES` in `main.js` —
/// the budget for keeping every triangle; past it a model is still measured,
/// only not drawn). Past `PREVIEW_BUDGET` faces the mesh is stride-sampled,
/// and past `HARD_CAP` nothing is drawn — both read from `lib/mf-mesh.js`,
/// and applied to the streamed formats with the same stride rule.
///
/// ── OFF THE MAIN THREAD ───────────────────────────────────────────────────
///
/// Reading, sampling, the normals and the SceneKit geometry are built on a
/// dispatch queue (`PinWork`) and the engine's own thread; the main thread
/// only receives the finished node.
enum ModelOrbitLoader {
    /// The desktop's keep-every-triangle budget, in bytes.
    static let maxFileBytes = 150 * 1024 * 1024

    struct Loaded: @unchecked Sendable {
        let node: SCNNode
        /// One material per colour group, in the order of `colours`.
        let materials: [SCNMaterial]
        let colours: [NSColor]
        let radius: Float
        let shown: Int
        let total: Int
    }

    enum Refusal: Error { case tooBig, nothing }

    static func load(_ url: URL) async throws -> Loaded {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw Refusal.tooBig }
        guard let studio = await Studio.engine() else { throw Refusal.nothing }
        let budgets = (try? await studio.viewerBudgets()) ?? (preview: 4_000_000, hardCap: 30_000_000)
        var mesh: StudioEngine.ViewerMesh?
        if url.pathExtension.lowercased() == "3mf" {
            if let read = try? await Converter.describeOffMain(url, bindMeshes: true) {
                mesh = try? await studio.viewerMesh(read.described, meshes: read.meshes, maxFaces: budgets.preview)
                if mesh?.skipped == true { throw Refusal.tooBig }
                if mesh?.faceState.isEmpty == true { mesh = nil }
            }
        }
        if mesh == nil {
            mesh = try await PinWork.run { () -> Result<StudioEngine.ViewerMesh, Error> in
                Result { try streamed(url, budget: budgets.preview, hardCap: budgets.hardCap) }
            }.get()
        }
        guard let mesh, !mesh.faceState.isEmpty else { throw Refusal.nothing }
        return await PinWork.run { build(mesh) }
    }

    /// STL, OBJ, or a 3MF the engine could not take: every `stride`-th face,
    /// the way `mf-mesh` samples (`gtri++ % stride === 0`).
    static func streamed(_ url: URL, budget: Int, hardCap: Int) throws -> StudioEngine.ViewerMesh {
        let ext = url.pathExtension.lowercased()
        guard let measured = try Mesh.readGeometry(url, ext: ext), measured.triangleCount > 0 else {
            throw Refusal.nothing
        }
        let count = measured.triangleCount
        guard count <= hardCap else { throw Refusal.tooBig }
        let stride = count > budget ? Int((Double(count) / Double(budget)).rounded(.up)) : 1
        var positions: [Float] = []
        positions.reserveCapacity((count / stride + 1) * 9)
        var seen = 0
        _ = try Mesh.eachTriangle(url, ext: ext) { ax, ay, az, bx, by, bz, cx, cy, cz in
            defer { seen += 1 }
            guard seen % stride == 0, Mesh.allFinite(ax, ay, az, bx, by, bz, cx, cy, cz) else { return }
            positions.append(Float(ax)); positions.append(Float(ay)); positions.append(Float(az))
            positions.append(Float(bx)); positions.append(Float(by)); positions.append(Float(bz))
            positions.append(Float(cx)); positions.append(Float(cy)); positions.append(Float(cz))
        }
        let faces = positions.count / 9
        return StudioEngine.ViewerMesh(positions: positions, faceState: [UInt8](repeating: 0, count: faces),
                                       palette: [], triangleCount: count, sampled: stride > 1, skipped: false)
    }

    /// A colour for a face's filament: the project's, else a plain grey.
    static func colour(state: UInt8, palette: [String]) -> NSColor {
        let i = Int(state) - 1
        if i >= 0, i < palette.count, let c = Swatch.rgb(fromHex: palette[i]) {
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
        return plain
    }

    static let plain = NSColor(srgbRed: 0.78, green: 0.80, blue: 0.82, alpha: 1)

    /// The SceneKit node: faces grouped by filament, one element and one
    /// material a group, flat normals, centred on the origin with Z turned up
    /// to SceneKit's Y.
    static func build(_ mesh: StudioEngine.ViewerMesh) -> Loaded {
        let faces = mesh.faceState.count
        var groups: [UInt8: [Int]] = [:]
        for f in 0..<faces { groups[mesh.faceState[f], default: []].append(f) }
        let order = groups.keys.sorted()

        var minV = SIMD3<Float>(repeating: .infinity), maxV = SIMD3<Float>(repeating: -.infinity)
        var positions = [Float](); positions.reserveCapacity(faces * 9)
        var normals = [Float](); normals.reserveCapacity(faces * 9)
        var elements: [SCNGeometryElement] = []
        var colours: [NSColor] = []
        var vertex: UInt32 = 0
        let p = mesh.positions
        for state in order {
            let list = groups[state] ?? []
            var indices = [UInt32](); indices.reserveCapacity(list.count * 3)
            for f in list {
                let k = f * 9
                let a = SIMD3(p[k], p[k + 1], p[k + 2])
                let b = SIMD3(p[k + 3], p[k + 4], p[k + 5])
                let c = SIMD3(p[k + 6], p[k + 7], p[k + 8])
                var n = simd_cross(b - a, c - a)
                let len = simd_length(n)
                n = len > 0 ? n / len : SIMD3(0, 0, 1)
                for j in 0..<9 {
                    positions.append(p[k + j])
                    normals.append(j % 3 == 0 ? n.x : j % 3 == 1 ? n.y : n.z)
                }
                minV = simd_min(minV, simd_min(a, simd_min(b, c)))
                maxV = simd_max(maxV, simd_max(a, simd_max(b, c)))
                indices.append(vertex); indices.append(vertex + 1); indices.append(vertex + 2)
                vertex += 3
            }
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            elements.append(SCNGeometryElement(data: data, primitiveType: .triangles,
                                               primitiveCount: list.count, bytesPerIndex: 4))
            colours.append(colour(state: state, palette: mesh.palette))
        }
        let count = positions.count / 3
        let vsrc = SCNGeometrySource(data: positions.withUnsafeBufferPointer { Data(buffer: $0) },
                                     semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let nsrc = SCNGeometrySource(data: normals.withUnsafeBufferPointer { Data(buffer: $0) },
                                     semantic: .normal, vectorCount: count, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let geometry = SCNGeometry(sources: [vsrc, nsrc], elements: elements)
        let materials = colours.map { c -> SCNMaterial in
            let m = SCNMaterial()
            m.diffuse.contents = c
            m.lightingModel = .blinn
            m.isDoubleSided = true
            return m
        }
        geometry.materials = materials
        let model = SCNNode(geometry: geometry)
        let centre = (minV + maxV) / 2
        model.position = SCNVector3(-CGFloat(centre.x), -CGFloat(centre.y), -CGFloat(centre.z))
        let holder = SCNNode()
        holder.addChildNode(model)
        // The file is Z up, as every slicer lays a bed out; SceneKit is Y up.
        holder.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        let radius = max(1, simd_length(maxV - minV) / 2)
        return Loaded(node: holder, materials: materials, colours: colours, radius: radius,
                      shown: faces, total: mesh.triangleCount)
    }
}

/// The SceneKit view, with the system's own camera control: drag to orbit
/// (turntable, so the bed stays level), scroll or pinch to zoom, Option-drag
/// or two-finger drag to pan.
struct OrbitSceneView: NSViewRepresentable {
    let loaded: ModelOrbitLoader.Loaded
    let coloured: Bool
    let wireframe: Bool
    let resetCount: Int

    final class Coordinator {
        var node: SCNNode?
        var reset = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.scene = SCNScene()
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        if c.node !== loaded.node {
            view.scene?.rootNode.childNodes.forEach { $0.removeFromParentNode() }
            view.scene?.rootNode.addChildNode(loaded.node)
            c.node = loaded.node
            c.reset = -1
        }
        if c.reset != resetCount {
            placeCamera(view)
            c.reset = resetCount
        }
        for (i, m) in loaded.materials.enumerated() {
            m.diffuse.contents = coloured ? loaded.colours[i] : ModelOrbitLoader.plain
            m.fillMode = wireframe ? .lines : .fill
        }
    }

    /// The three-quarter view from the front right, above — the picture a
    /// tile wears (`ModelViewAngle.iso`).
    private func placeCamera(_ view: SCNView) {
        view.scene?.rootNode.childNodes.filter { $0.camera != nil }.forEach { $0.removeFromParentNode() }
        let camera = SCNCamera()
        camera.zNear = Double(loaded.radius) / 100
        camera.zFar = Double(loaded.radius) * 100
        camera.fieldOfView = 35
        let node = SCNNode()
        node.camera = camera
        let d = CGFloat(loaded.radius) * 3.2
        let yaw = CGFloat(35 * Double.pi / 180), pitch = CGFloat(24 * Double.pi / 180)
        node.position = SCNVector3(d * sin(yaw) * cos(pitch), d * sin(pitch), d * cos(yaw) * cos(pitch))
        node.look(at: SCNVector3(0, 0, 0))
        view.scene?.rootNode.addChildNode(node)
        view.pointOfView = node
        view.defaultCameraController.target = SCNVector3(0, 0, 0)
    }
}

/// The 3D half of the inspector's viewer.
struct ModelOrbit: View {
    let shop: Shop
    let file: LibraryFile
    let url: URL

    @State private var loaded: ModelOrbitLoader.Loaded?
    @State private var reading = false
    @State private var refusal: String?
    @AppStorage("library.orbit.colours") private var coloured = true
    @AppStorage("library.orbit.wireframe") private var wireframe = false
    @State private var resetCount = 0

    var body: some View {
        let w = shop.words
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(w.callIt("mac.v3d_colours"), isOn: $coloured)
                    .disabled(!(loaded?.colours.contains { $0 != ModelOrbitLoader.plain } ?? false))
                Toggle(w.callIt("view3d.wireframe"), isOn: $wireframe)
                Spacer()
                Button(w.callIt("mac.v3d_reset")) { resetCount += 1 }.disabled(loaded == nil)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                if let loaded {
                    OrbitSceneView(loaded: loaded, coloured: coloured, wireframe: wireframe, resetCount: resetCount)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel(w.callIt("mac.v3d_help"))
                } else if let refusal {
                    Text(refusal).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
                if reading {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(w.callIt("mac.v3d_reading")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(w.callIt("mac.v3d_help")).font(.caption2).foregroundStyle(.secondary)
            if let loaded, loaded.shown < loaded.total {
                Text(w.callIt("mac.v3d_sampled", ["shown": .string(w.numeral(loaded.shown)),
                                                  "total": .string(w.numeral(loaded.total))]))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            loaded = nil
            refusal = nil
            reading = true
            do {
                let made = try await ModelOrbitLoader.load(url)
                guard !Task.isCancelled else { return }
                loaded = made
            } catch ModelOrbitLoader.Refusal.tooBig {
                refusal = w.callIt("mac.v3d_too_big")
            } catch {
                refusal = w.callIt("mac.v3d_failed")
            }
            reading = false
        }
    }
}
