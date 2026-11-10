import SwiftUI
import SceneKit

extension ThreeMF {
    /// Reads whichever 3D text format the reply used.
    static func mesh(from text: String) -> Mesh? {
        let lower = text.lowercased()
        var mesh: Mesh?
        if lower.contains("<model"), lower.contains("3dmanufacturing"), lower.contains("<triangle") {
            mesh = parseModelXML(text)
        } else if lower.contains("facet"), lower.contains("vertex") {
            mesh = parseSTL(text)
        } else if text.contains("\nf ") || text.hasPrefix("f "), text.contains("v ") {
            mesh = parseOBJ(text)
        }
        guard let mesh, !mesh.triangles.isEmpty else { return nil }
        return mesh
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let start = tag.range(of: " \(name)=\"") else { return nil }
        let rest = tag[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func parseModelXML(_ text: String) -> Mesh {
        var mesh = Mesh()
        for part in text.components(separatedBy: "<vertex").dropFirst() {
            let tag = part.prefix(while: { $0 != ">" })
            if let x = attribute("x", in: tag).flatMap(Double.init),
               let y = attribute("y", in: tag).flatMap(Double.init),
               let z = attribute("z", in: tag).flatMap(Double.init) {
                mesh.vertices.append((x, y, z))
            }
        }
        // "<triangles>" also starts with "<triangle", so only tags with a v1 count.
        for part in text.components(separatedBy: "<triangle").dropFirst() {
            let tag = part.prefix(while: { $0 != ">" })
            if let a = attribute("v1", in: tag).flatMap(Int.init),
               let b = attribute("v2", in: tag).flatMap(Int.init),
               let c = attribute("v3", in: tag).flatMap(Int.init),
               [a, b, c].allSatisfy({ $0 >= 0 && $0 < mesh.vertices.count }) {
                mesh.triangles.append((a, b, c))
            }
        }
        return mesh
    }
}

extension ThreeMF.Mesh {
    struct Check {
        var size: (Double, Double, Double) = (0, 0, 0)
        var openEdges = 0
        var crowdedEdges = 0
        var isClosed: Bool { openEdges == 0 && crowdedEdges == 0 }
    }

    /// Size of the shape and whether it is a closed solid: every edge must be shared by exactly two faces.
    var check: Check {
        var result = Check()
        guard let first = vertices.first else { return result }
        var low = first
        var high = first
        for v in vertices {
            low = (min(low.0, v.0), min(low.1, v.1), min(low.2, v.2))
            high = (max(high.0, v.0), max(high.1, v.1), max(high.2, v.2))
        }
        result.size = (high.0 - low.0, high.1 - low.1, high.2 - low.2)

        // Points at the same place count as one, however many times the file lists them.
        var canonical: [String: Int] = [:]
        let ids = vertices.map { v -> Int in
            let key = "\(v.0) \(v.1) \(v.2)"
            if let id = canonical[key] { return id }
            let id = canonical.count
            canonical[key] = id
            return id
        }
        var uses: [Int: Int] = [:]
        let n = max(1, canonical.count)
        for t in triangles {
            let corners = [ids[t.0], ids[t.1], ids[t.2]]
            for i in 0..<3 {
                let a = corners[i]
                let b = corners[(i + 1) % 3]
                guard a != b else { continue }
                uses[min(a, b) * n + max(a, b), default: 0] += 1
            }
        }
        result.openEdges = uses.values.filter { $0 == 1 }.count
        result.crowdedEdges = uses.values.filter { $0 > 2 }.count
        return result
    }
}

/// A turnable 3D view: one finger rotates, pinch zooms, two fingers move.
struct ModelSceneView: UIViewRepresentable {
    let mesh: ThreeMF.Mesh
    let showEdges: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.scene(for: mesh)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.scene?.rootNode.childNode(withName: "edges", recursively: true)?.isHidden = !showEdges
    }

    static func scene(for mesh: ThreeMF.Mesh) -> SCNScene {
        let scene = SCNScene()
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var faceIndices: [Int32] = []
        var edgeIndices: [Int32] = []

        var low = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var high = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

        // Each face gets its own three points and normal, so flat sides look flat.
        for t in mesh.triangles {
            let corners = [mesh.vertices[t.0], mesh.vertices[t.1], mesh.vertices[t.2]].map {
                SCNVector3(Float($0.0), Float($0.1), Float($0.2))
            }
            let u = SCNVector3(corners[1].x - corners[0].x, corners[1].y - corners[0].y, corners[1].z - corners[0].z)
            let w = SCNVector3(corners[2].x - corners[0].x, corners[2].y - corners[0].y, corners[2].z - corners[0].z)
            var normal = SCNVector3(u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x)
            let length = (normal.x * normal.x + normal.y * normal.y + normal.z * normal.z).squareRoot()
            if length > 0 { normal = SCNVector3(normal.x / length, normal.y / length, normal.z / length) }

            let base = Int32(positions.count)
            for corner in corners {
                positions.append(corner)
                normals.append(normal)
                low = SCNVector3(min(low.x, corner.x), min(low.y, corner.y), min(low.z, corner.z))
                high = SCNVector3(max(high.x, corner.x), max(high.y, corner.y), max(high.z, corner.z))
            }
            faceIndices.append(contentsOf: [base, base + 1, base + 2])
            edgeIndices.append(contentsOf: [base, base + 1, base + 1, base + 2, base + 2, base])
        }
        guard !positions.isEmpty else { return scene }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)

        let solid = SCNGeometry(sources: [vertexSource, normalSource],
                                elements: [SCNGeometryElement(indices: faceIndices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal
        material.isDoubleSided = true
        solid.materials = [material]

        let lines = SCNGeometry(sources: [vertexSource],
                                elements: [SCNGeometryElement(indices: edgeIndices, primitiveType: .line)])
        let lineMaterial = SCNMaterial()
        lineMaterial.diffuse.contents = UIColor.label
        lineMaterial.lightingModel = .constant
        lines.materials = [lineMaterial]

        // Printing files are Z-up; SceneKit is Y-up. The holder turns the model upright around its own centre.
        let center = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
        let holder = SCNNode()
        holder.eulerAngles.x = -.pi / 2
        let solidNode = SCNNode(geometry: solid)
        let edgeNode = SCNNode(geometry: lines)
        edgeNode.name = "edges"
        for node in [solidNode, edgeNode] {
            node.position = SCNVector3(-center.x, -center.y, -center.z)
            holder.addChildNode(node)
        }
        scene.rootNode.addChildNode(holder)

        let dx = high.x - low.x, dy = high.y - low.y, dz = high.z - low.z
        let radius = max(0.0001, (dx * dx + dy * dy + dz * dz).squareRoot() / 2)
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(radius * 1.6, radius * 1.3, radius * 2.2)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        return scene
    }
}

/// The viewer with its facts: size, triangle count and whether the shape can be printed as it is.
struct ModelPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let mesh: ThreeMF.Mesh
    let title: String
    @State private var showEdges = true
    @State private var share: ShareItem?

    private func save() {
        let base = title.split(separator: ".").first.map(String.init) ?? "model"
        let data = ThreeMF.zip(modelXML: ThreeMF.modelXML(mesh))
        if let url = ReplyFiles.write(name: base + ".3mf", data: data) { share = ShareItem(url: url) }
    }

    var body: some View {
        let check = mesh.check
        NavigationStack {
            VStack(spacing: 0) {
                ModelSceneView(mesh: mesh, showEdges: showEdges)
                    .ignoresSafeArea(edges: .horizontal)
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(format: "%.1f × %.1f × %.1f mm", check.size.0, check.size.1, check.size.2), systemImage: "ruler")
                    Label("\(mesh.triangles.count) triangles", systemImage: "triangle")
                    if check.isClosed {
                        Label("Closed solid: ready for a slicer", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("Not a closed solid: \(check.openEdges) open edges, \(check.crowdedEdges) tangled edges. It has holes or stray faces and will not print as it is.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Toggle("Show triangle edges", isOn: $showEdges)
                    Text("Drag to turn, pinch to zoom, two fingers to move.").font(.caption).foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { save() } label: { Label("Save .3mf", systemImage: "square.and.arrow.down") }
                }
            }
            .sheet(item: $share) { item in
                ActivityView(items: [item.url])
            }
        }
    }
}
