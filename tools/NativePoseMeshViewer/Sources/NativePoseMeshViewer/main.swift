import SwiftUI
import SceneKit
import AppKit
import simd

func viewerDebugLog(_ message: String) {
    let url = URL(fileURLWithPath: "/tmp/nativeposeviewer.log")
    let line = "\(Date()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

private let defaultRoot = URL(fileURLWithPath: "/Users/liscio/Acrobatica")
private let originalOCMesh = URL(fileURLWithPath: "/Users/liscio/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/model_nobbox.obj")
private let bcsPlanesMesh = URL(fileURLWithPath: "/Users/liscio/Acrobatica/exports/bcs_planes_handoff_20260701/bcs_standard_oc.obj")
private let alignedBCSMesh = URL(fileURLWithPath: "/Users/liscio/Acrobatica/exports/bcs_verticale_medio_mesh_aligned_20260701/mesh_bcs_aligned.obj")
private let alignedBCSPlanesJSON = URL(fileURLWithPath: "/Users/liscio/Acrobatica/exports/bcs_verticale_medio_mesh_aligned_20260701/bcs_verticale_medio.json")
private let alignedBCSPlanesMesh = URL(fileURLWithPath: "/Users/liscio/Acrobatica/exports/bcs_verticale_medio_mesh_aligned_20260701/bcs_verticale_medio_planes.obj")
private let alignedBCSTransform = URL(fileURLWithPath: "/Users/liscio/Acrobatica/exports/bcs_verticale_medio_mesh_aligned_20260701/oc_to_arkit_transform.json")
private let defaultMesh = bcsPlanesMesh
private let defaultPoses = URL(fileURLWithPath: "/Users/liscio/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/oc_poses_nobbox.json")
private let defaultPhotos = defaultRoot.appendingPathComponent("backend/data/fixtures/6cdcb8ff/photos")

struct OCPoseFile: Decodable {
    let intrinsics_fx_fy_cx_cy: [Double]
    let rotation_wxyz: [Double]
    let translation: [Double]
}

struct CameraShot: Identifiable {
    let id: Int
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let imageWidth: Double
    let imageHeight: Double
    let transform: simd_float4x4
}

struct SimpleOBJMesh {
    let vertices: [SIMD3<Float>]
    let triangles: [SIMD3<Int32>]
}

struct ProjectedPatch {
    let geometry: SCNGeometry
    let vertices: [SIMD3<Float>]
    let indices: [UInt32]
    var texcoords: [SIMD2<Float>] = []
}

struct BCSPlaneFile: Decodable {
    let piani: [BCSPlane]
}

struct BCSPlane: Decodable {
    let tipo: String
    let area_m2: Double
    let corners: [[Double]]
}

@MainActor
final class ViewerModel: ObservableObject {
    @Published var meshURL: URL = defaultMesh
    @Published var posesURL: URL = defaultPoses
    @Published var photosURL: URL = defaultPhotos
    @Published var selectedShotID: Int = 163
    @Published var stride: Double = 10
    @Published var showWire = false
    @Published var showCellGrid = false
    @Published var showMesh = true
    @Published var showOCTexture = false
    @Published var showProjectedPhoto = false
    @Published var projectMultiplePhotos = false
    @Published var projectionCrop: Double = 0.9
    @Published var projectionMaxPhotos: Double = 60
    @Published var projectionFacingThreshold: Double = 0.34
    @Published var projectionMinCoverage: Double = 0.002
    @Published var occlusionEnabled = false
    @Published var showPhotoBorders = true
    @Published var showUncoveredCells = true
    @Published var showObliqueCells = false
    @Published var obliqueAngleDegrees: Double = 60
    @Published var photoConsensusEnabled = true
    @Published var excludedShotIDs = Set<Int>()
    @Published var continuityBonus: Double = 0.2
    @Published var edgeCleanupStrength: Double = 0.5
    @Published var fillHolesEnabled = true
    @Published var lastResortFillEnabled = true
    @Published var bakeResolutionMM: Double = 8
    @Published var bakeStatus = ""
    @Published var meshScaleInfo = ""
    @Published var showPhotoPlane = true
    @Published var showOriginalTexturedMesh = false
    @Published var ocTextureOpacity: Double = 0.72
    @Published var showReferenceMesh = false
    @Published var showReferenceWire = false
    @Published var selectedPlaneIndex = 0
    @Published var hiddenPlaneIDs = Set<Int>()
    @Published var planeCount = 0
    @Published var status = "Pronto"
    @Published var error: String?
    @Published var cameraRevision = 0
    @Published var inspectorEnabled = true
    @Published var inspectorTitle = ""
    @Published var inspectorLines: [String] = []

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let rootNode = SCNNode()
    private let originalTexturedMeshNode = SCNNode()
    private let referenceMeshNode = SCNNode()
    private let meshNode = SCNNode()
    private let cellGridNode = SCNNode()
    private let projectedPhotoNode = SCNNode()
    private let camerasNode = SCNNode()
    private let photoPlaneNode = SCNNode()
    private(set) var shots: [CameraShot] = []
    private var referenceMeshURL: URL = originalOCMesh
    private var simpleMesh: SimpleOBJMesh?
    private var originalMaterials: [ObjectIdentifier: [SCNMaterial]] = [:]
    private var flatMaterials: [ObjectIdentifier: [SCNMaterial]] = [:]
    private var projectedGeometryCache: [String: ProjectedPatch] = [:]
    private var occlusionTesterCache: OcclusionTester?
    private var occlusionMeshURL: URL?
    private var photoSampleCache: [Int: (width: Int, height: Int, rgba: [UInt8])] = [:]
    private var photoFullCache: [Int: (width: Int, height: Int, rgba: [UInt8])] = [:]
    private var nsImageCache: [Int: NSImage] = [:]

    // --- editor piani ---
    @Published var editPlanesMode = false
    @Published var editPlaneIndex = 0
    @Published var editPlaneCount = 0
    @Published var editSensitivity: Double = 1.0
    @Published var editStepCM: Double = 5
    @Published var liveEditProjection = true
    private var liveDragging = false
    private let editHandlesNode = SCNNode()
    var editablePlanes: [[SIMD3<Float>]] = []
    private var activeHandleKind = -1
    private var editSelectedKind = -1
    private var activeAxis = -1

    init() {
        scene.rootNode.addChildNode(rootNode)
        rootNode.addChildNode(originalTexturedMeshNode)
        rootNode.addChildNode(referenceMeshNode)
        rootNode.addChildNode(meshNode)
        rootNode.addChildNode(cellGridNode)
        rootNode.addChildNode(projectedPhotoNode)
        rootNode.addChildNode(camerasNode)
        rootNode.addChildNode(photoPlaneNode)
        rootNode.addChildNode(editHandlesNode)

        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.001
        cameraNode.camera?.zFar = 1000
        scene.rootNode.addChildNode(cameraNode)

        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .omni
        light.light?.intensity = 180
        light.position = SCNVector3(0, 8, 8)
        scene.rootNode.addChildNode(light)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 120
        scene.rootNode.addChildNode(ambient)
    }

    func reload() {
        error = nil
        do {
            try loadMesh()
            try loadReferenceMesh()
            if meshURL.path == originalOCMesh.path {
                originalTexturedMeshNode.childNodes.forEach { $0.removeFromParentNode() }
            } else {
                try loadOriginalTexturedMesh()
            }
            try loadPoses()
            rebuildCellGrid()
            rebuildCameras()
            rebuildPhotoPlane()
            rebuildProjectedPhoto()
            frameScene()
            status = isAlignedBCSMode
                ? "Allineamento BCS · piani + mesh + foto"
                : "\(shots.count) pose OC native · \(meshURL.lastPathComponent)"
        } catch {
            self.error = String(describing: error)
            status = "Errore"
        }
    }

    private var isAlignedBCSMode: Bool {
        meshURL.path == alignedBCSPlanesMesh.path && referenceMeshURL.path == alignedBCSMesh.path
    }

    func chooseMesh() {
        guard let url = openFile(allowed: ["obj", "usdz", "dae", "scn"]) else { return }
        var useURL = url
        // auto-scala la mesh caricata sul frame delle pose (bbox di model_nobbox):
        // il retopo è in scala metrica (~6× più grande) e altrimenti non allinea.
        if url.pathExtension.lowercased() == "obj",
           let target = try? Self.parseOBJ(originalOCMesh),
           let loaded = try? Self.parseOBJ(url) {
            let td = Self.bboxDiagonal(target), ld = Self.bboxDiagonal(loaded)
            if ld > 1e-6 {
                let factor = td / ld
                if abs(factor - 1) > 0.03, let scaled = try? Self.writeScaledOBJ(from: url, factor: factor) {
                    useURL = scaled
                    meshScaleInfo = String(format: "auto-scala ×%.3f", factor)
                } else {
                    meshScaleInfo = ""
                }
            }
        }
        meshURL = useURL
        // la mesh caricata fa da occlusore/riferimento di sé stessa:
        // essenziale per proiettare sulla geometria 3D vera senza attraversare gli aggetti.
        referenceMeshURL = useURL
        occlusionTesterCache = nil
        showReferenceMesh = false
        reload()
    }

    private static func bboxDiagonal(_ mesh: SimpleOBJMesh) -> Float {
        guard let first = mesh.vertices.first else { return 0 }
        var mn = first, mx = first
        for v in mesh.vertices { mn = simd_min(mn, v); mx = simd_max(mx, v) }
        return simd_length(mx - mn)
    }

    private static func writeScaledOBJ(from url: URL, factor: Float) throws -> URL {
        let text = try String(contentsOf: url)
        var out = ""
        out.reserveCapacity(text.count)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("v ") {
                let p = line.split(separator: " ")
                if p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) {
                    out += "v \(x * factor) \(y * factor) \(z * factor)\n"
                    continue
                }
            }
            out += line
            out += "\n"
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaled_\(url.deletingPathExtension().lastPathComponent).obj")
        try out.write(to: dst, atomically: true, encoding: .utf8)
        return dst
    }

    func useOriginalOCMesh() {
        referenceMeshURL = originalOCMesh
        meshURL = originalOCMesh
        showOCTexture = true
        showMesh = true
        showOriginalTexturedMesh = false
        showReferenceMesh = false
        reload()
    }

    func useClaudePlanesMesh() {
        referenceMeshURL = originalOCMesh
        meshURL = bcsPlanesMesh
        showOCTexture = false
        showMesh = true
        reload()
    }

    func useAlignedMediumPair() {
        referenceMeshURL = alignedBCSMesh
        meshURL = alignedBCSPlanesMesh
        showOCTexture = false
        showMesh = true
        showReferenceMesh = true
        reload()
    }

    func choosePoses() {
        if let url = openFile(allowed: ["json"]) {
            posesURL = url
            reload()
        }
    }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            photosURL = url
            projectedGeometryCache.removeAll()
            photoSampleCache.removeAll()
            rebuildPhotoPlane()
            rebuildProjectedPhoto()
        }
    }

    func setMeshVisible(_ visible: Bool) {
        meshNode.isHidden = !visible
    }

    func setReferenceMeshVisible(_ visible: Bool) {
        referenceMeshNode.isHidden = !visible
    }

    func setOriginalTexturedMeshVisible(_ visible: Bool) {
        originalTexturedMeshNode.isHidden = !visible
    }

    func applyMeshAppearance() {
        meshNode.isHidden = !showMesh
        meshNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let key = ObjectIdentifier(geometry)
            let materials = self.showOCTexture
                ? (self.originalMaterials[key] ?? geometry.materials)
                : (self.flatMaterials[key] ?? geometry.materials)
            for material in materials {
                material.fillMode = self.showWire ? .lines : .fill
                material.isDoubleSided = true
                if self.showOCTexture {
                    material.lightingModel = .constant
                    material.emission.contents = material.diffuse.contents
                    material.specular.contents = NSColor.black
                    material.multiply.contents = NSColor.white
                }
            }
            geometry.materials = materials
        }
    }

    func applyReferenceMeshAppearance() {
        referenceMeshNode.isHidden = !showReferenceMesh
        referenceMeshNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                material.fillMode = self.showReferenceWire ? .lines : .fill
                material.isDoubleSided = true
                material.lightingModel = .constant
                material.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.10, alpha: 1.0)
                material.emission.contents = self.showReferenceWire
                    ? NSColor(calibratedRed: 0.72, green: 0.48, blue: 0.08, alpha: 1.0)
                    : NSColor.black
                material.specular.contents = NSColor.black
                material.multiply.contents = NSColor(calibratedWhite: 0.75, alpha: 1.0)
                material.transparency = 1.0
                material.readsFromDepthBuffer = true
                material.writesToDepthBuffer = !self.showReferenceWire
            }
        }
    }

    func applyOriginalTexturedMeshAppearance() {
        originalTexturedMeshNode.isHidden = !showOriginalTexturedMesh
        originalTexturedMeshNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                material.fillMode = .fill
                material.isDoubleSided = true
                material.lightingModel = .constant
                material.emission.contents = material.diffuse.contents
                material.specular.contents = NSColor.black
                material.multiply.contents = NSColor.white
                material.transparency = CGFloat(self.ocTextureOpacity)
                material.readsFromDepthBuffer = true
                material.writesToDepthBuffer = self.ocTextureOpacity > 0.95
            }
        }
    }

    func frameScene() {
        let box = rootNode.boundingBoxInWorld()
        let center = box.center
        let radius = max(box.size.x, box.size.y, box.size.z, 1) * 0.8
        cameraNode.position = SCNVector3(center.x + radius * 1.35, center.y + radius * 0.65, center.z + radius * 1.75)
        cameraNode.look(at: center, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        cameraNode.camera?.zFar = Double(radius * 80)
        cameraRevision += 1
    }

    func viewFromSelectedCamera() {
        guard let shot = shots.first(where: { $0.id == selectedShotID }) else { return }
        rebuildPhotoPlane()
        cameraNode.simdTransform = shot.transform
        cameraNode.camera?.fieldOfView = 2 * atan(shot.imageHeight / (2 * shot.fy)) * 180 / .pi
        cameraNode.camera?.zNear = 0.001
        cameraNode.camera?.zFar = 100
        cameraRevision += 1
    }

    func rebuildCameras() {
        camerasNode.childNodes.forEach { $0.removeFromParentNode() }
        let s = max(Int(stride), 1)
        for (index, shot) in shots.enumerated() where index % s == 0 || shot.id == selectedShotID {
            camerasNode.addChildNode(makeFrustum(shot: shot, selected: shot.id == selectedShotID))
        }
    }

    func rebuildPhotoPlane() {
        photoPlaneNode.childNodes.forEach { $0.removeFromParentNode() }
        guard showPhotoPlane, let shot = shots.first(where: { $0.id == selectedShotID }) else { return }
        let depth: Float = 0.32
        let width = CGFloat(shot.imageWidth / shot.fx * Double(depth))
        let height = CGFloat(shot.imageHeight / shot.fy * Double(depth))
        let plane = SCNPlane(width: width, height: height)
        let material = SCNMaterial()
        let imageURL = photosURL.appendingPathComponent(String(format: "%04d.jpg", shot.id))
        material.diffuse.contents = NSImage(contentsOf: imageURL) ?? NSColor.systemOrange
        material.isDoubleSided = true
        material.transparency = 0.72
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        let x = Float(((shot.imageWidth / 2) - shot.cx) / shot.fx * Double(depth))
        let y = Float(-(((shot.imageHeight / 2) - shot.cy) / shot.fy * Double(depth)))
        node.simdPosition = SIMD3<Float>(x, y, -depth)
        node.simdTransform = shot.transform * node.simdTransform
        photoPlaneNode.addChildNode(node)
    }

    func rebuildProjectedPhoto() {
        projectedPhotoNode.childNodes.forEach { $0.removeFromParentNode() }
        guard showProjectedPhoto else { return }
        do {
            if simpleMesh == nil {
                simpleMesh = try Self.parseOBJ(meshURL)
            }
            guard let mesh = simpleMesh else { return }
            let crop = min(max(projectionCrop, 0.2), 1.0)

            if projectMultiplePhotos {
                let tester = liveDragging ? nil : occlusionTesterIfNeeded()
                let activeShots = shots.filter { !excludedShotIDs.contains($0.id) }
                let result = Self.buildMosaic(
                    mesh: mesh,
                    shots: activeShots,
                    cropFraction: crop,
                    minSurfaceFacing: Float(min(max(projectionFacingThreshold, 0.0), 0.99)),
                    maxPerBucket: max(Int(projectionMaxPhotos), 1),
                    minAreaFraction: liveDragging ? 0 : Float(max(projectionMinCoverage, 0)),
                    continuityBonus: liveDragging ? 0 : Float(min(max(continuityBonus, 0), 1)),
                    edgeCleanup: liveDragging ? 0 : Float(min(max(edgeCleanupStrength, 0), 2)),
                    fillHoles: liveDragging ? false : fillHolesEnabled,
                    lastResortFill: liveDragging ? false : lastResortFillEnabled,
                    obliqueMaxFacing: (!liveDragging && showObliqueCells) ? Float(cos(obliqueAngleDegrees * .pi / 180)) : 0,
                    occlusion: (!liveDragging && occlusionEnabled) ? tester : nil,
                    cellSize: liveDragging ? 0.22 : 0.055,
                    orientationProbe: tester,
                    colorSampler: (!liveDragging && photoConsensusEnabled)
                        ? { [weak self] shotID, u, v in self?.photoColor(shotID: shotID, u: u, v: v) }
                        : nil
                )
                var projected = 0
                for (shotID, patch) in result.patches.sorted(by: { $0.key < $1.key }) {
                    guard patch.geometry.elements.first?.primitiveCount ?? 0 > 0,
                          let shot = shots.first(where: { $0.id == shotID }) else { continue }
                    let imageURL = photosURL.appendingPathComponent(String(format: "%04d.jpg", shotID))
                    guard let image = NSImage(contentsOf: imageURL) else { continue }

                    let material = Self.projectedPhotoMaterial(image: image)
                    patch.geometry.materials = [material]
                    let node = SCNNode(geometry: patch.geometry)
                    node.renderingOrder = 0
                    projectedPhotoNode.addChildNode(node)
                    if showPhotoBorders {
                        addPatchDecorations(patch: patch, shot: shot)
                    }
                    projected += 1
                }
                if showObliqueCells, !result.oblique.isEmpty {
                    let geometry = Self.solidTriangleGeometry(
                        vertices: result.oblique,
                        color: NSColor(calibratedRed: 0.98, green: 0.60, blue: 0.05, alpha: 1.0)
                    )
                    geometry.firstMaterial?.transparency = 0.4
                    geometry.firstMaterial?.writesToDepthBuffer = false
                    let node = SCNNode(geometry: geometry)
                    node.renderingOrder = 3
                    projectedPhotoNode.addChildNode(node)
                }
                if showUncoveredCells, !result.uncovered.isEmpty {
                    let geometry = Self.solidTriangleGeometry(
                        vertices: result.uncovered,
                        color: NSColor(calibratedRed: 0.86, green: 0.08, blue: 0.06, alpha: 1.0)
                    )
                    let node = SCNNode(geometry: geometry)
                    node.renderingOrder = 1
                    projectedPhotoNode.addChildNode(node)
                }
                let gateDegrees = Int(acos(Double(min(max(projectionFacingThreshold, 0), 1))) * 180 / .pi)
                let holeCount = result.uncovered.count / 3
                let obliqueCount = result.oblique.count / 3
                let obliqueMsg = showObliqueCells ? " · oblique \(obliqueCount)" : ""
                status = "\(shots.count) pose · mosaico \(projected) foto (\(result.keptCount) selezionate) · gate \(gateDegrees)° · occl \(occlusionEnabled ? "on" : "off") · buchi \(holeCount)\(obliqueMsg)"
                return
            }

            guard let shot = shots.first(where: { $0.id == selectedShotID }) else { return }
            let imageURL = photosURL.appendingPathComponent(String(format: "%04d.jpg", shot.id))
            guard let image = NSImage(contentsOf: imageURL) else { return }
            let cacheKey = "\(shot.id)-\(String(format: "%.3f", crop))"
            let patch: ProjectedPatch
            if let cached = projectedGeometryCache[cacheKey] {
                patch = cached
            } else {
                patch = Self.projectedTextureGeometry(mesh: mesh, shot: shot, cropFraction: crop)
                projectedGeometryCache[cacheKey] = patch
            }
            guard patch.geometry.elements.first?.primitiveCount ?? 0 > 0 else { return }

            let material = Self.projectedPhotoMaterial(image: image)
            patch.geometry.materials = [material]
            let node = SCNNode(geometry: patch.geometry)
            node.renderingOrder = 0
            projectedPhotoNode.addChildNode(node)
            if showPhotoBorders {
                addPatchDecorations(patch: patch, shot: shot)
            }
            status = "\(shots.count) pose · proiezione \(String(format: "%04d", selectedShotID)) · crop \(Int(crop * 100))%"
        } catch {
            self.error = String(describing: error)
        }
    }

    func rebuildCellGrid() {
        cellGridNode.childNodes.forEach { $0.removeFromParentNode() }
        guard showCellGrid else { return }
        do {
            if simpleMesh == nil {
                simpleMesh = try Self.parseOBJ(meshURL)
            }
        } catch {
            self.error = String(describing: error)
            return
        }
        guard let mesh = simpleMesh else { return }
        let cells = Self.buildCells(mesh: mesh)
        guard !cells.isEmpty else { return }
        var minV = mesh.vertices.first ?? SIMD3<Float>(repeating: 0)
        var maxV = minV
        for vertex in mesh.vertices {
            minV = simd_min(minV, vertex)
            maxV = simd_max(maxV, vertex)
        }
        let lift = simd_length(maxV - minV) * 0.001
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(cells.count * 6)
        for cell in cells {
            let offset = cell.normal * lift
            let a = cell.a + offset
            let b = cell.b + offset
            let c = cell.c + offset
            points.append(contentsOf: [a, b, b, c, c, a])
        }
        let geometry = Self.lineGeometry(points: points, color: NSColor(calibratedWhite: 0.85, alpha: 1.0))
        geometry.firstMaterial?.transparency = 0.3
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 2
        cellGridNode.addChildNode(node)
    }

    func inspect(point: SIMD3<Float>, normal rawNormal: SIMD3<Float>) {
        guard inspectorEnabled, !shots.isEmpty else { return }
        if simpleMesh == nil {
            simpleMesh = try? Self.parseOBJ(meshURL)
        }
        guard let mesh = simpleMesh else { return }
        let normalLength = simd_length(rawNormal)
        guard normalLength > 1e-5 else { return }
        let normal = rawNormal / normalLength

        let crop = Float(min(max(projectionCrop, 0.2), 1.0))
        let cropMin = (1 - crop) / 2
        let cropMax = 1 - cropMin
        var minV = mesh.vertices.first ?? SIMD3<Float>(repeating: 0)
        var maxV = minV
        for vertex in mesh.vertices {
            minV = simd_min(minV, vertex)
            maxV = simd_max(maxV, vertex)
        }
        let proximityScale = max(simd_length(maxV - minV) * 0.1, 1e-3)
        var orientationAgnostic = mesh.triangles.count < 5_000
        let minFacing = Float(min(max(projectionFacingThreshold, 0.0), 0.99))
        let tester = occlusionTesterIfNeeded()
        let rejectionTester = occlusionEnabled ? tester : nil

        var outwardSign: Float = 1
        if orientationAgnostic, let probe = tester {
            let probeDistance = max(simd_length(maxV - minV) * 0.1, 0.05)
            let free = probe.freeDistance(from: point, direction: normal, maxDistance: probeDistance)
            let back = probe.freeDistance(from: point, direction: -normal, maxDistance: probeDistance)
            outwardSign = free >= back ? 1 : -1
            orientationAgnostic = false
        }

        var rows: [(score: Float, id: Int, cs: CellScore, cam: SIMD3<Float>)] = []
        for shot in shots {
            let cand = CandidateCam(shot)
            guard let cs = Self.evaluateCell(
                a: point, b: point, c: point,
                center: point, normal: normal,
                cand: cand,
                cropMin: cropMin, cropMax: cropMax,
                minSurfaceFacing: minFacing,
                proximityScale: proximityScale,
                orientationAgnostic: orientationAgnostic,
                outwardSign: outwardSign
            ) else { continue }
            rows.append((cs.score, shot.id, cs, cand.cameraPosition))
        }
        rows.sort { $0.score > $1.score }

        inspectorTitle = String(format: "Cella (%.2f · %.2f · %.2f) — %d candidate", point.x, point.y, point.z, rows.count)
        var lines: [String] = []
        var winnerFound = false
        for row in rows.prefix(8) {
            let isOccluded = rejectionTester?.isOccluded(from: point, toCamera: row.cam) ?? false
            let angle = Int(acos(min(max(Double(row.cs.facing), 0), 1)) * 180 / .pi)
            var marker = isOccluded ? "occlusa" : ""
            if !isOccluded && !winnerFound {
                marker = "◀ vince"
                winnerFound = true
            }
            lines.append(String(
                format: "%04d s%.2f ax%.2f %2d° c%.2f d%.1f %@",
                row.id, row.score, row.cs.axial, angle, row.cs.centrality, row.cs.distance, marker
            ))
        }
        if rows.isEmpty {
            lines.append("nessuna foto passa i gate qui")
        } else if !winnerFound {
            lines.append("(tutte le prime 8 occluse)")
        }
        inspectorLines = lines
    }

    func excludeSelectedShot() {
        excludedShotIDs.insert(selectedShotID)
        rebuildProjectedPhoto()
    }

    func clearExcludedShots() {
        excludedShotIDs.removeAll()
        rebuildProjectedPhoto()
    }

    private func photoSample(shotID: Int) -> (width: Int, height: Int, rgba: [UInt8])? {
        if let cached = photoSampleCache[shotID] { return cached }
        let url = photosURL.appendingPathComponent(String(format: "%04d.jpg", shotID))
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = 240
        let height = 180
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        let entry = (width, height, buffer)
        photoSampleCache[shotID] = entry
        return entry
    }

    func photoColor(shotID: Int, u: Float, v: Float) -> SIMD3<Float>? {
        guard u >= 0, u <= 1, v >= 0, v <= 1,
              let sample = photoSample(shotID: shotID) else { return nil }
        let x = min(max(Int(u * Float(sample.width)), 0), sample.width - 1)
        let y = min(max(Int(v * Float(sample.height)), 0), sample.height - 1)
        let index = (y * sample.width + x) * 4
        return SIMD3<Float>(
            Float(sample.rgba[index]),
            Float(sample.rgba[index + 1]),
            Float(sample.rgba[index + 2])
        ) / 255
    }

    private func occlusionTesterIfNeeded() -> OcclusionTester? {
        if occlusionMeshURL != referenceMeshURL {
            occlusionTesterCache = nil
        }
        if occlusionTesterCache == nil {
            guard let refMesh = try? Self.parseOBJ(referenceMeshURL) else { return nil }
            occlusionTesterCache = OcclusionTester(mesh: refMesh)
            occlusionMeshURL = referenceMeshURL
        }
        return occlusionTesterCache
    }

    private func photoFullPixels(_ shotID: Int) -> (width: Int, height: Int, rgba: [UInt8])? {
        if let cached = photoFullCache[shotID] { return cached }
        let url = photosURL.appendingPathComponent(String(format: "%04d.jpg", shotID))
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        if photoFullCache.count > 60 { photoFullCache.removeAll() }
        let entry = (w, h, buffer)
        photoFullCache[shotID] = entry
        return entry
    }

    // Parsa l'OBJ preservando i gruppi: per ogni piano restituisce i 4 corner (in ordine di rettangolo).
    private static func parseOBJPlaneGroups(_ url: URL) throws -> [(name: String, corners: [SIMD3<Float>])] {
        let text = try String(contentsOf: url)
        var verts: [SIMD3<Float>] = []
        var groups: [(name: String, faceVerts: [Int])] = []
        var current = -1
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("v ") {
                let p = line.split(separator: " ")
                if p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) {
                    verts.append(SIMD3<Float>(x, y, z))
                }
            } else if line.hasPrefix("g ") {
                groups.append((String(line.dropFirst(2)), []))
                current = groups.count - 1
            } else if line.hasPrefix("f "), current >= 0 {
                for tok in line.split(separator: " ").dropFirst() {
                    if let raw = tok.split(separator: "/").first, let idx = Int(raw) {
                        groups[current].faceVerts.append(idx > 0 ? idx - 1 : verts.count + idx)
                    }
                }
            }
        }
        return groups.compactMap { g in
            var seen: [Int] = []
            for v in g.faceVerts where !seen.contains(v) { seen.append(v) }
            guard seen.count >= 4 else { return nil }
            let corners = seen.prefix(4).map { verts[$0] }
            return (g.name, Array(corners))
        }
    }

    func bakeOrthophotos(outDir outDirOverride: URL? = nil) {
        bakeStatus = "Bake in corso…"
        error = nil
        do {
            let planes = try Self.parseOBJPlaneGroups(meshURL)
            guard !planes.isEmpty else { bakeStatus = "Nessun gruppo piano nell'OBJ"; return }
            let res = Float(max(bakeResolutionMM, 1) / 1000)  // m/texel
            let activeShots = shots.filter { !excludedShotIDs.contains($0.id) }
            let tester = occlusionTesterIfNeeded()
            let stamp = Self.timestamp()
            let outDir = outDirOverride
                ?? defaultRoot.appendingPathComponent("exports/ortho_bake_\(stamp)")
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            // trasformazione OC→metrico: i piani/pose sono in frame OC (~6× più piccolo del reale);
            // risoluzione e aree vanno calcolate in metri, non in unità OC.
            let metricT = try? Self.loadTransform(rowMajorJSON:
                meshURL.deletingLastPathComponent().appendingPathComponent("oc_to_arkit_transform.json"))
            func toMetric(_ p: SIMD3<Float>) -> SIMD3<Float> {
                guard let m = metricT else { return p }
                let v = m * SIMD4<Float>(p.x, p.y, p.z, 1)
                return SIMD3<Float>(v.x, v.y, v.z)
            }

            var done = 0
            var totalTexels = 0
            var baked: [(name: String, w: Int, h: Int, rgba: [UInt8], area: Float, widthM: Float, heightM: Float)] = []
            for (pi, plane) in planes.enumerated() {
                let c = plane.corners
                // L'ALTEZZA è lo spigolo più allineato alla verticale (gravità): l'ordine
                // degli angoli non è coerente fra i piani (plane_3/7 ruotati 90°), quindi
                // NON assumere sempre c3-c0. Origine = corner in basso dello spigolo verticale.
                let mcRaw = c.map(toMetric)
                let up = SIMD3<Float>(0, 1, 0)
                let e1 = c[1] - c[0], e3 = c[3] - c[0]
                let m1 = mcRaw[1] - mcRaw[0], m3 = mcRaw[3] - mcRaw[0]
                let e3IsVertical = abs(simd_dot(simd_normalize(m3), up)) >= abs(simd_dot(simd_normalize(m1), up))
                let vAxis = e3IsVertical ? e3 : e1     // verticale (altezza)
                let uAxis = e3IsVertical ? e1 : e3     // orizzontale (larghezza)
                let vAxisM = e3IsVertical ? m3 : m1
                let uAxisM = e3IsVertical ? m1 : m3
                let widthOC = simd_length(uAxis)
                let heightOC = simd_length(vAxis)
                guard widthOC > 0.01, heightOC > 0.01 else { continue }
                let uHat = uAxis / widthOC
                let vHat = vAxis / heightOC
                let mc = c.map(toMetric)
                let widthM = simd_length(uAxisM)
                let heightM = simd_length(vAxisM)
                guard widthM > 0.05, heightM > 0.05 else { continue }
                let area = 0.5 * simd_length(simd_cross(mc[1] - mc[0], mc[2] - mc[0]))
                         + 0.5 * simd_length(simd_cross(mc[2] - mc[0], mc[3] - mc[0]))
                let px = max(min(Int((widthM / res).rounded()), 8000), 8)
                let py = max(min(Int((heightM / res).rounded()), 8000), 8)

                // mosaico solo per questo piano (2 triangoli)
                let planeMesh = SimpleOBJMesh(
                    vertices: c,
                    triangles: [SIMD3<Int32>(0, 1, 2), SIMD3<Int32>(0, 2, 3)]
                )
                let result = Self.buildMosaic(
                    mesh: planeMesh, shots: activeShots, cropFraction: min(max(projectionCrop, 0.2), 1.0),
                    minSurfaceFacing: Float(min(max(projectionFacingThreshold, 0.0), 0.99)),
                    maxPerBucket: max(Int(projectionMaxPhotos), 1),
                    minAreaFraction: Float(max(projectionMinCoverage, 0)),
                    continuityBonus: Float(min(max(continuityBonus, 0), 1)),
                    edgeCleanup: Float(min(max(edgeCleanupStrength, 0), 2)),
                    fillHoles: fillHolesEnabled, lastResortFill: lastResortFillEnabled,
                    obliqueMaxFacing: 0,
                    occlusion: occlusionEnabled ? tester : nil, orientationProbe: tester,
                    colorSampler: photoConsensusEnabled ? { [weak self] id, u, v in self?.photoColor(shotID: id, u: u, v: v) } : nil
                )

                var rgba = [UInt8](repeating: 0, count: px * py * 4)
                for (shotID, patch) in result.patches {
                    guard let photo = photoFullPixels(shotID), patch.texcoords.count == patch.vertices.count else { continue }
                    var t = 0
                    while t + 2 < patch.indices.count {
                        let ia = Int(patch.indices[t]), ib = Int(patch.indices[t + 1]), ic = Int(patch.indices[t + 2])
                        Self.rasterizeTriangle(
                            world: (patch.vertices[ia], patch.vertices[ib], patch.vertices[ic]),
                            photoUV: (patch.texcoords[ia], patch.texcoords[ib], patch.texcoords[ic]),
                            origin: c[0], uHat: uHat, vHat: vHat, widthM: widthOC, heightM: heightOC,
                            texW: px, texH: py, photo: photo, out: &rgba
                        )
                        t += 3
                    }
                }

                let safeName = plane.name.replacingOccurrences(of: " ", with: "_")
                let pngURL = outDir.appendingPathComponent("\(safeName).png")
                try Self.writePNG(rgba: rgba, width: px, height: py, to: pngURL)
                try Self.writePlaneOBJ(name: safeName, corners: mc, widthM: widthM, heightM: heightM, dir: outDir)
                baked.append((safeName, px, py, rgba, area, widthM, heightM))
                totalTexels += px * py
                done += 1
                bakeStatus = "Bake \(done)/\(planes.count) · \(safeName) \(px)×\(py)"
            }

            // FOGLIO UNICO: tutti i piani stesi frontali a scala costante (packing a scaffali)
            let gap = 16
            let shelfMaxW = 4096
            let order = baked.indices.sorted { baked[$0].h > baked[$1].h }
            var placements: [(idx: Int, x: Int, y: Int)] = []
            var cx = gap, cy = gap, rowH = 0, atlasW = gap
            for oi in order {
                let b = baked[oi]
                if cx > gap, cx + b.w + gap > shelfMaxW { cx = gap; cy += rowH + gap; rowH = 0 }
                placements.append((oi, cx, cy))
                cx += b.w + gap
                rowH = max(rowH, b.h)
                atlasW = max(atlasW, cx)
            }
            let atlasH = cy + rowH + gap
            if atlasW > 0, atlasH > 0, atlasW * atlasH < 200_000_000 {
                var atlas = [UInt8](repeating: 0, count: atlasW * atlasH * 4)
                for p in placements {
                    let b = baked[p.idx]
                    for row in 0..<b.h {
                        let src = row * b.w * 4
                        let dst = ((p.y + row) * atlasW + p.x) * 4
                        atlas.replaceSubrange(dst..<(dst + b.w * 4), with: b.rgba[src..<(src + b.w * 4)])
                    }
                }
                try Self.writePNG(rgba: atlas, width: atlasW, height: atlasH,
                                  to: outDir.appendingPathComponent("_foglio_unico.png"))
            }

            // REPORT SUPERFICI
            var report = "Superfici piani — bake ortografico \(Int(bakeResolutionMM)) mm/texel\n"
            report += metricT != nil
                ? "(aree in METRI reali via oc_to_arkit_transform, normale frontale)\n\n"
                : "(ATTENZIONE: nessuna trasformazione metrica trovata — aree in unità OC!)\n\n"
            var total: Float = 0
            for b in baked {
                let name = b.name.padding(toLength: 22, withPad: " ", startingAt: 0)
                report += String(format: "%@ %6.2f × %6.2f m   %8.2f m²\n", name, b.widthM, b.heightM, b.area)
                total += b.area
            }
            report += String(format: "\n%@ %26.2f m²\n", "TOTALE".padding(toLength: 22, withPad: " ", startingAt: 0), total)
            try report.write(to: outDir.appendingPathComponent("_superfici.txt"), atomically: true, encoding: .utf8)

            bakeStatus = String(format: "Fatto: %d piani · %.2f m² totali · exports/ortho_bake_%@", done, total, stamp)
        } catch {
            self.error = String(describing: error)
            bakeStatus = "Errore bake"
        }
    }

    /// Esecuzione headless (senza GUI): imposta gli input, carica le pose e lancia
    /// lo STESSO bake della GUI su una cartella di output data. Ritorna true se ok.
    /// Il mesh è l'OBJ dei piani (gruppi = quad); accanto può esserci
    /// `oc_to_arkit_transform.json` per le aree metriche.
    func headlessBake(mesh: URL, poses: URL, photos: URL, out: URL,
                      resMM: Double, crop: Double, facing: Double,
                      maxPhotos: Int, occlusion: Bool, fullMesh: URL? = nil) -> Bool {
        meshURL = mesh
        posesURL = poses
        photosURL = photos
        // Mesh completa (occlusore + sonda di orientamento dei piani): DEVE essere nello
        // stesso frame di piani e pose. Se assente, si usa l'OBJ dei piani stesso.
        referenceMeshURL = fullMesh ?? mesh
        bakeResolutionMM = resMM
        projectionCrop = crop
        projectionFacingThreshold = facing
        projectionMaxPhotos = Double(maxPhotos)
        occlusionEnabled = occlusion
        projectMultiplePhotos = true
        do {
            try loadPoses()
        } catch {
            self.error = "loadPoses: \(error)"
            return false
        }
        guard !shots.isEmpty else { self.error = "nessuna posa caricata"; return false }
        bakeOrthophotos(outDir: out)
        return self.error == nil
    }

    // ============================ EDITOR PIANI ============================

    func setEditMode(_ on: Bool) {
        editPlanesMode = on
        if on {
            editablePlanes = ((try? Self.parseOBJPlaneGroups(meshURL)) ?? []).map { Array($0.corners.prefix(4)) }
                .filter { $0.count == 4 }
            editPlaneCount = editablePlanes.count
            editPlaneIndex = min(editPlaneIndex, max(editPlaneCount - 1, 0))
            refreshEditablePlanes()
        } else {
            editHandlesNode.childNodes.forEach { $0.removeFromParentNode() }
            editablePlanes = []
            editPlaneCount = 0
            simpleMesh = nil
            reload()
        }
    }

    private func planeAxes(_ quad: [SIMD3<Float>]) -> (u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>) {
        let u = simd_normalize(quad[1] - quad[0])
        var n = simd_cross(quad[1] - quad[0], quad[3] - quad[0])
        let nl = simd_length(n)
        n = nl > 1e-6 ? n / nl : SIMD3<Float>(0, 0, 1)
        let v = simd_normalize(simd_cross(n, u))
        return (u, v, n)
    }

    private func projectedPhotoImage(_ shotID: Int) -> NSImage? {
        if let cached = nsImageCache[shotID] { return cached }
        let url = photosURL.appendingPathComponent(String(format: "%04d.jpg", shotID))
        let img = NSImage(contentsOf: url)
        nsImageCache[shotID] = img
        return img
    }

    private func planeRenderNode(_ idx: Int) -> SCNNode {
        let geometry = Self.quadGeometry(editablePlanes[idx])
        let material = SCNMaterial()
        let sel = idx == editPlaneIndex
        material.diffuse.contents = sel
            ? NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.15, alpha: 0.28)
            : NSColor(calibratedRed: 0.25, green: 0.6, blue: 1.0, alpha: 0.12)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.transparency = sel ? 0.28 : 0.12
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = "R\(idx)"
        node.renderingOrder = 5
        return node
    }

    // Proietta le foto PER PIANO in nodi separati. Durante il drag riproietta solo il
    // piano selezionato (coarse); il resto resta com'è → tempo reale.
    func reprojectEditablePlanes(onlyIndex: Int?, coarse: Bool) {
        guard editPlanesMode else { return }
        guard showProjectedPhoto, projectMultiplePhotos else {
            projectedPhotoNode.childNodes.forEach { $0.removeFromParentNode() }
            return
        }
        let indices = onlyIndex.map { [$0] } ?? Array(editablePlanes.indices)
        if onlyIndex == nil { projectedPhotoNode.childNodes.forEach { $0.removeFromParentNode() } }
        let activeShots = shots.filter { !excludedShotIDs.contains($0.id) }
        let tester = (!coarse && occlusionEnabled) ? occlusionTesterIfNeeded() : nil
        for idx in indices where idx < editablePlanes.count {
            projectedPhotoNode.childNode(withName: "P\(idx)", recursively: false)?.removeFromParentNode()
            let quad = editablePlanes[idx]
            let mesh = SimpleOBJMesh(vertices: quad, triangles: [SIMD3<Int32>(0, 1, 2), SIMD3<Int32>(0, 2, 3)])
            let result = Self.buildMosaic(
                mesh: mesh, shots: activeShots, cropFraction: min(max(projectionCrop, 0.2), 1.0),
                minSurfaceFacing: Float(min(max(projectionFacingThreshold, 0.0), 0.99)),
                maxPerBucket: max(Int(projectionMaxPhotos), 1),
                minAreaFraction: coarse ? 0 : Float(max(projectionMinCoverage, 0)),
                continuityBonus: coarse ? 0 : Float(min(max(continuityBonus, 0), 1)),
                edgeCleanup: coarse ? 0 : Float(min(max(edgeCleanupStrength, 0), 2)),
                fillHoles: coarse ? false : fillHolesEnabled,
                lastResortFill: coarse ? false : lastResortFillEnabled,
                obliqueMaxFacing: 0,
                occlusion: tester,
                cellSize: coarse ? 0.22 : 0.055,
                colorSampler: (!coarse && photoConsensusEnabled)
                    ? { [weak self] id, u, v in self?.photoColor(shotID: id, u: u, v: v) } : nil
            )
            let group = SCNNode()
            group.name = "P\(idx)"
            for (shotID, patch) in result.patches {
                guard patch.geometry.elements.first?.primitiveCount ?? 0 > 0,
                      let img = projectedPhotoImage(shotID) else { continue }
                patch.geometry.materials = [Self.projectedPhotoMaterial(image: img)]
                group.addChildNode(SCNNode(geometry: patch.geometry))
            }
            projectedPhotoNode.addChildNode(group)
        }
    }

    // Ricostruisce render + mesh di proiezione + maniglie dai piani editabili (rebuild completo).
    func refreshEditablePlanes(reproject: Bool = true) {
        guard !editablePlanes.isEmpty else { return }
        meshNode.childNodes.forEach { $0.removeFromParentNode() }
        var verts: [SIMD3<Float>] = []
        var tris: [SIMD3<Int32>] = []
        for (idx, quad) in editablePlanes.enumerated() {
            let b = Int32(verts.count)
            verts.append(contentsOf: quad)
            tris.append(SIMD3<Int32>(b, b + 1, b + 2))
            tris.append(SIMD3<Int32>(b, b + 2, b + 3))
            meshNode.addChildNode(planeRenderNode(idx))
        }
        simpleMesh = SimpleOBJMesh(vertices: verts, triangles: tris)
        rebuildEditHandles()
        rebuildCellGrid()
        if reproject { reprojectEditablePlanes(onlyIndex: nil, coarse: false) }
    }

    // Aggiorna SOLO il render del piano selezionato (leggero, per il drag live).
    private func updateSelectedPlaneRender() {
        meshNode.childNode(withName: "R\(editPlaneIndex)", recursively: false)?.removeFromParentNode()
        meshNode.addChildNode(planeRenderNode(editPlaneIndex))
        rebuildEditHandles()
    }

    private func selectedHandlePosition() -> SIMD3<Float>? {
        guard editPlaneIndex < editablePlanes.count, editSelectedKind >= 0 else { return nil }
        let quad = editablePlanes[editPlaneIndex]
        if editSelectedKind < 4 { return quad[editSelectedKind] }
        let e = editSelectedKind - 10
        return (quad[e] + quad[(e + 1) % 4]) / 2
    }

    private func rebuildEditHandles() {
        editHandlesNode.childNodes.forEach { $0.removeFromParentNode() }
        guard editPlanesMode, editPlaneIndex < editablePlanes.count else { return }
        let quad = editablePlanes[editPlaneIndex]
        var mn = quad[0], mx = quad[0]
        for c in quad { mn = simd_min(mn, c); mx = simd_max(mx, c) }
        let r = CGFloat(max(simd_length(mx - mn) * 0.02, 0.01))
        func handle(_ pos: SIMD3<Float>, kind: Int, corner: Bool) {
            let s = SCNSphere(radius: corner ? r : r * 0.75)
            let m = SCNMaterial()
            let isSel = kind == editSelectedKind
            let base: NSColor = corner ? .systemYellow : .systemGreen
            m.diffuse.contents = isSel ? NSColor.systemRed : base
            m.emission.contents = isSel ? NSColor.systemRed : base
            m.lightingModel = .constant
            m.readsFromDepthBuffer = false
            s.materials = [m]
            let node = SCNNode(geometry: s)
            node.simdPosition = pos
            node.name = "EDIT:\(kind)"
            node.renderingOrder = 20
            editHandlesNode.addChildNode(node)
        }
        for i in 0..<4 { handle(quad[i], kind: i, corner: true) }
        for e in 0..<4 { handle((quad[e] + quad[(e + 1) % 4]) / 2, kind: 10 + e, corner: false) }

        // Gizmo a assi sulla maniglia selezionata: U(rosso) V(verde) N(blu=normale)
        if let anchor = selectedHandlePosition() {
            let axes = planeAxes(quad)
            let len = Float(max(simd_length(mx - mn) * 0.22, 0.05))
            func axis(_ dir: SIMD3<Float>, index: Int, color: NSColor) {
                let cyl = SCNCylinder(radius: CGFloat(len) * 0.05, height: CGFloat(len))
                let m = SCNMaterial()
                m.diffuse.contents = color
                m.emission.contents = color
                m.lightingModel = .constant
                m.readsFromDepthBuffer = false
                cyl.materials = [m]
                let bar = SCNNode(geometry: cyl)
                bar.simdPosition = SIMD3<Float>(0, len / 2, 0)  // estende da anchor lungo +Y locale
                let node = SCNNode()
                node.simdPosition = anchor
                node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(dir))
                node.addChildNode(bar)
                node.name = "AXIS:\(index)"
                node.renderingOrder = 21
                editHandlesNode.addChildNode(node)
            }
            axis(axes.u, index: 0, color: .systemRed)
            axis(axes.v, index: 1, color: .systemGreen)
            axis(axes.n, index: 2, color: .systemBlue)
        }
    }

    func beginHandleDrag(name: String?) {
        activeAxis = -1
        activeHandleKind = -1
        if let name, name.hasPrefix("AXIS:"), let a = Int(name.dropFirst(5)) {
            activeAxis = a
            return
        }
        if let name, name.hasPrefix("EDIT:"), let k = Int(name.dropFirst(5)) {
            activeHandleKind = k
            if k != editSelectedKind {
                editSelectedKind = k
                rebuildEditHandles()
            }
        }
    }

    private func applyDelta(_ delta: SIMD3<Float>) {
        guard editSelectedKind >= 0, editPlaneIndex < editablePlanes.count else { return }
        var quad = editablePlanes[editPlaneIndex]
        if editSelectedKind < 4 {
            quad[editSelectedKind] += delta
        } else {
            let e = editSelectedKind - 10
            quad[e] += delta
            quad[(e + 1) % 4] += delta
        }
        editablePlanes[editPlaneIndex] = quad
        // SOLO il piano selezionato: render leggero + (opzionale) riproiezione veloce.
        updateSelectedPlaneRender()
        if liveEditProjection && showProjectedPhoto && projectMultiplePhotos {
            reprojectEditablePlanes(onlyIndex: editPlaneIndex, coarse: true)
        }
    }

    // Trascinamento LIBERO (nel piano) della maniglia selezionata.
    func dragHandle(deltaX: CGFloat, deltaY: CGFloat) {
        guard activeHandleKind >= 0, editPlaneIndex < editablePlanes.count else { return }
        let axes = planeAxes(editablePlanes[editPlaneIndex])
        let diag = simd_length(editablePlanes[editPlaneIndex][2] - editablePlanes[editPlaneIndex][0])
        let s = Float(editSensitivity) * diag / 700
        applyDelta(axes.u * Float(deltaX) * s - axes.v * Float(deltaY) * s)
    }

    // Trascinamento VINCOLATO a un asse: la view calcola già il delta world lungo l'asse.
    func dragAlongAxis(_ worldDelta: SIMD3<Float>) {
        guard activeAxis >= 0 else { return }
        applyDelta(worldDelta * Float(editSensitivity))
    }

    func endHandleDrag() {
        activeHandleKind = -1
        activeAxis = -1
        // qualità piena SOLO sul piano modificato; gli altri restano com'erano.
        refreshEditablePlanes(reproject: false)
        reprojectEditablePlanes(onlyIndex: editPlaneIndex, coarse: false)
    }

    // Sposta l'intero piano selezionato lungo la sua normale (profondità).
    func nudgeDepth(_ sign: Float) {
        guard editPlaneIndex < editablePlanes.count else { return }
        let axes = planeAxes(editablePlanes[editPlaneIndex])
        let d = axes.n * sign * Float(editStepCM / 100)
        editablePlanes[editPlaneIndex] = editablePlanes[editPlaneIndex].map { $0 + d }
        updateSelectedPlaneRender()
        reprojectEditablePlanes(onlyIndex: editPlaneIndex, coarse: false)
    }

    // Rifila (sign -1) o allarga (sign +1) tutti i bordi del piano selezionato.
    func nudgeInset(_ sign: Float) {
        guard editPlaneIndex < editablePlanes.count else { return }
        var quad = editablePlanes[editPlaneIndex]
        let center = (quad[0] + quad[1] + quad[2] + quad[3]) / 4
        let amt = sign * Float(editStepCM / 100)
        for i in 0..<4 {
            let dir = simd_normalize(quad[i] - center)
            quad[i] += dir * amt
        }
        editablePlanes[editPlaneIndex] = quad
        updateSelectedPlaneRender()
        reprojectEditablePlanes(onlyIndex: editPlaneIndex, coarse: false)
    }

    func saveEditedPlanes() {
        guard !editablePlanes.isEmpty else { return }
        let stamp = Self.timestamp()
        let dir = defaultRoot.appendingPathComponent("exports/planes_edit_\(stamp)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var obj = "# piani BCS editati\n"
            var vi = 1
            for (idx, quad) in editablePlanes.enumerated() {
                obj += "g plane_\(idx + 1)_edit\n"
                for c in quad { obj += "v \(c.x) \(c.y) \(c.z)\n" }
                obj += "f \(vi) \(vi + 1) \(vi + 2) \(vi + 3)\n"
                vi += 4
            }
            try obj.write(to: dir.appendingPathComponent("planes_edit.obj"), atomically: true, encoding: .utf8)
            bakeStatus = "Piani salvati in exports/planes_edit_\(stamp)"
        } catch {
            self.error = String(describing: error)
        }
    }

    private static func quadGeometry(_ quad: [SIMD3<Float>]) -> SCNGeometry {
        let vertexData = Data(bytes: quad, count: quad.count * MemoryLayout<SIMD3<Float>>.stride)
        var indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        let indexData = Data(bytes: &indices, count: indices.count * MemoryLayout<UInt32>.stride)
        let vs = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: quad.count,
                                   usesFloatComponents: true, componentsPerVector: 3,
                                   bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                   dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let el = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: 2,
                                    bytesPerIndex: MemoryLayout<UInt32>.stride)
        return SCNGeometry(sources: [vs], elements: [el])
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    private static func rasterizeTriangle(
        world: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        photoUV: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
        origin: SIMD3<Float>, uHat: SIMD3<Float>, vHat: SIMD3<Float>,
        widthM: Float, heightM: Float, texW: Int, texH: Int,
        photo: (width: Int, height: Int, rgba: [UInt8]), out: inout [UInt8]
    ) {
        func planeUV(_ p: SIMD3<Float>) -> SIMD2<Float> {
            SIMD2<Float>(simd_dot(p - origin, uHat) / widthM, simd_dot(p - origin, vHat) / heightM)
        }
        // vertici in spazio texel (v=0 in basso → riga py-1)
        let a = planeUV(world.0), b = planeUV(world.1), c = planeUV(world.2)
        let ax = a.x * Float(texW), ay = (1 - a.y) * Float(texH)
        let bx = b.x * Float(texW), by = (1 - b.y) * Float(texH)
        let cx = c.x * Float(texW), cy = (1 - c.y) * Float(texH)
        let minX = max(Int(floor(min(ax, bx, cx))), 0)
        let maxX = min(Int(ceil(max(ax, bx, cx))), texW - 1)
        let minY = max(Int(floor(min(ay, by, cy))), 0)
        let maxY = min(Int(ceil(max(ay, by, cy))), texH - 1)
        guard minX <= maxX, minY <= maxY else { return }
        let denom = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        guard abs(denom) > 1e-6 else { return }
        for yy in minY...maxY {
            for xx in minX...maxX {
                let fx = Float(xx) + 0.5, fy = Float(yy) + 0.5
                let l0 = ((by - cy) * (fx - cx) + (cx - bx) * (fy - cy)) / denom
                let l1 = ((cy - ay) * (fx - cx) + (ax - cx) * (fy - cy)) / denom
                let l2 = 1 - l0 - l1
                guard l0 >= -0.001, l1 >= -0.001, l2 >= -0.001 else { continue }
                let uv = SIMD2<Float>(
                    l0 * photoUV.0.x + l1 * photoUV.1.x + l2 * photoUV.2.x,
                    l0 * photoUV.0.y + l1 * photoUV.1.y + l2 * photoUV.2.y
                )
                guard uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 else { continue }
                let sx = min(max(Int(uv.x * Float(photo.width)), 0), photo.width - 1)
                let sy = min(max(Int(uv.y * Float(photo.height)), 0), photo.height - 1)
                let si = (sy * photo.width + sx) * 4
                let di = (yy * texW + xx) * 4
                out[di] = photo.rgba[si]
                out[di + 1] = photo.rgba[si + 1]
                out[di + 2] = photo.rgba[si + 2]
                out[di + 3] = 255
            }
        }
    }

    private static func writePNG(rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ), let dest = rep.bitmapData else {
            throw NSError(domain: "bake", code: 1, userInfo: [NSLocalizedDescriptionKey: "NSBitmapImageRep nil"])
        }
        rgba.withUnsafeBytes { dest.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: width * height * 4) }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "bake", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encode fallita"])
        }
        try data.write(to: url)
    }

    private static func writePlaneOBJ(name: String, corners: [SIMD3<Float>], widthM: Float, heightM: Float, dir: URL) throws {
        let mtl = "newmtl \(name)\nmap_Kd \(name).png\n"
        try mtl.write(to: dir.appendingPathComponent("\(name).mtl"), atomically: true, encoding: .utf8)
        var obj = "mtllib \(name).mtl\nusemtl \(name)\n"
        for c in corners { obj += "v \(c.x) \(c.y) \(c.z)\n" }
        obj += "vt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\n"
        obj += "f 1/1 2/2 3/3\nf 1/1 3/3 4/4\n"
        try obj.write(to: dir.appendingPathComponent("\(name).obj"), atomically: true, encoding: .utf8)
    }

    func rebuildProjectedPhotoClearingCache() {
        projectedGeometryCache.removeAll()
        rebuildProjectedPhoto()
    }

    func projectAllFilteredPhotos() {
        projectMultiplePhotos = true
        projectionMaxPhotos = Double(max(shots.count, 1))
        rebuildProjectedPhotoClearingCache()
    }

    func deleteSelectedPlane() {
        guard planeCount > 0 else { return }
        hiddenPlaneIDs.insert(selectedPlaneIndex)
        simpleMesh = nil
        projectedGeometryCache.removeAll()
        do {
            try loadMesh()
            rebuildCellGrid()
            rebuildProjectedPhoto()
        } catch {
            self.error = String(describing: error)
        }
    }

    func restorePlanes() {
        hiddenPlaneIDs.removeAll()
        simpleMesh = nil
        projectedGeometryCache.removeAll()
        do {
            try loadMesh()
            rebuildCellGrid()
            rebuildProjectedPhoto()
        } catch {
            self.error = String(describing: error)
        }
    }

    func refreshPlaneSelection() {
        do {
            try loadMesh()
            rebuildCellGrid()
            rebuildProjectedPhoto()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func loadMesh() throws {
        meshNode.childNodes.forEach { $0.removeFromParentNode() }
        projectedPhotoNode.childNodes.forEach { $0.removeFromParentNode() }
        simpleMesh = nil
        originalMaterials.removeAll()
        flatMaterials.removeAll()
        projectedGeometryCache.removeAll()
        if meshURL.path == alignedBCSPlanesMesh.path {
            try loadBCSPlaneMesh()
            return
        }
        planeCount = 0
        hiddenPlaneIDs.removeAll()
        let loaded = try SCNScene(url: meshURL, options: [
            .checkConsistency: true,
            .flattenScene: false
        ])
        let container = SCNNode()
        for child in loaded.rootNode.childNodes {
            container.addChildNode(child.clone())
        }
        container.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let key = ObjectIdentifier(geometry)
            self.originalMaterials[key] = geometry.materials.map { $0.copy() as! SCNMaterial }
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedRed: 0.35, green: 0.86, blue: 0.58, alpha: 0.92)
            material.lightingModel = .physicallyBased
            material.isDoubleSided = true
            self.flatMaterials[key] = [material]
        }
        meshNode.addChildNode(container)
        applyMeshAppearance()
    }

    private func loadBCSPlaneMesh() throws {
        let data = try Data(contentsOf: alignedBCSPlanesJSON)
        let decoded = try JSONDecoder().decode(BCSPlaneFile.self, from: data)
        planeCount = decoded.piani.count
        if selectedPlaneIndex >= planeCount {
            selectedPlaneIndex = max(planeCount - 1, 0)
        }
        simpleMesh = Self.meshFromBCSPlanes(decoded.piani, hiddenPlaneIDs: hiddenPlaneIDs)

        for (index, plane) in decoded.piani.enumerated() where !hiddenPlaneIDs.contains(index) {
            let geometry = Self.bcsPlaneGeometry(plane)
            let material = SCNMaterial()
            let selected = index == selectedPlaneIndex
            material.diffuse.contents = selected
                ? NSColor(calibratedRed: 1.0, green: 0.16, blue: 0.12, alpha: 0.72)
                : NSColor(calibratedRed: 0.18, green: 0.78, blue: 0.38, alpha: 0.45)
            material.emission.contents = selected
                ? NSColor(calibratedRed: 0.55, green: 0.04, blue: 0.02, alpha: 1.0)
                : NSColor(calibratedRed: 0.03, green: 0.22, blue: 0.08, alpha: 1.0)
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.transparency = selected ? 0.72 : 0.45
            material.writesToDepthBuffer = true
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.name = "BCS plane \(index + 1)"
            meshNode.addChildNode(node)
        }
        applyMeshAppearance()
    }

    private func loadReferenceMesh() throws {
        referenceMeshNode.childNodes.forEach { $0.removeFromParentNode() }
        let loaded = try SCNScene(url: referenceMeshURL, options: [
            .checkConsistency: true,
            .flattenScene: false
        ])
        let container = SCNNode()
        for child in loaded.rootNode.childNodes {
            container.addChildNode(child.clone())
        }
        container.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedRed: 0.42, green: 0.62, blue: 1.0, alpha: 0.85)
            material.emission.contents = NSColor(calibratedRed: 0.18, green: 0.32, blue: 0.75, alpha: 1.0)
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            geometry.materials = [material]
        }
        referenceMeshNode.addChildNode(container)
        applyReferenceMeshAppearance()
    }

    private func loadOriginalTexturedMesh() throws {
        originalTexturedMeshNode.childNodes.forEach { $0.removeFromParentNode() }
        let loaded = try SCNScene(url: originalOCMesh, options: [
            .checkConsistency: true,
            .flattenScene: false
        ])
        let container = SCNNode()
        for child in loaded.rootNode.childNodes {
            container.addChildNode(child.clone())
        }
        container.simdTransform = isAlignedBCSMode
            ? try Self.loadTransform(rowMajorJSON: alignedBCSTransform)
            : matrix_identity_float4x4
        originalTexturedMeshNode.addChildNode(container)
        applyOriginalTexturedMeshAppearance()
    }

    private func loadPoses() throws {
        let data = try Data(contentsOf: posesURL)
        let decoded = try JSONDecoder().decode([String: OCPoseFile].self, from: data)
        let worldFromPoseSpace = isAlignedBCSMode
            ? try Self.loadTransform(rowMajorJSON: alignedBCSTransform)
            : matrix_identity_float4x4
        shots = decoded.keys.compactMap { key in
            guard let id = Int(key), let pose = decoded[key],
                  pose.intrinsics_fx_fy_cx_cy.count == 4,
                  pose.rotation_wxyz.count == 4,
                  pose.translation.count == 3 else { return nil }
            let intr = pose.intrinsics_fx_fy_cx_cy
            return CameraShot(
                id: id,
                fx: intr[0],
                fy: intr[1],
                cx: intr[2],
                cy: intr[3],
                imageWidth: 1920,
                imageHeight: 1440,
                transform: worldFromPoseSpace * Self.matrix(rotationWXYZ: pose.rotation_wxyz, translation: pose.translation)
            )
        }.sorted { $0.id < $1.id }
        if !shots.contains(where: { $0.id == selectedShotID }) {
            selectedShotID = shots[safe: shots.count / 2]?.id ?? shots.first?.id ?? 0
        }
    }

    private func makeFrustum(shot: CameraShot, selected: Bool) -> SCNNode {
        let depth: Float = 0.22
        let corners = [
            SIMD3<Float>(Float((0 - shot.cx) / shot.fx) * depth, Float((0 - shot.cy) / shot.fy) * depth, -depth),
            SIMD3<Float>(Float((shot.imageWidth - shot.cx) / shot.fx) * depth, Float((0 - shot.cy) / shot.fy) * depth, -depth),
            SIMD3<Float>(Float((shot.imageWidth - shot.cx) / shot.fx) * depth, Float((shot.imageHeight - shot.cy) / shot.fy) * depth, -depth),
            SIMD3<Float>(Float((0 - shot.cx) / shot.fx) * depth, Float((shot.imageHeight - shot.cy) / shot.fy) * depth, -depth)
        ]
        let origin = SIMD3<Float>(0, 0, 0)
        let segments = [
            origin, corners[0], origin, corners[1], origin, corners[2], origin, corners[3],
            corners[0], corners[1], corners[1], corners[2], corners[2], corners[3], corners[3], corners[0]
        ]
        let node = SCNNode(geometry: Self.lineGeometry(points: segments, color: selected ? .systemYellow : .systemPink))
        node.simdTransform = shot.transform
        return node
    }

    private func addPatchDecorations(patch: ProjectedPatch, shot: CameraShot) {
        guard !patch.vertices.isEmpty else { return }
        let color = Self.shotColor(shot.id)
        let cameraPosition = SIMD3<Float>(
            shot.transform.columns.3.x,
            shot.transform.columns.3.y,
            shot.transform.columns.3.z
        )

        let segments = Self.boundarySegments(vertices: patch.vertices, indices: patch.indices)
        if !segments.isEmpty {
            let lifted = segments.map { point -> SIMD3<Float> in
                let toCamera = cameraPosition - point
                let length = simd_length(toCamera)
                return length > 1e-5 ? point + toCamera / length * 0.02 : point
            }
            let borderNode = SCNNode(geometry: Self.lineGeometry(points: lifted, color: color))
            borderNode.renderingOrder = 4
            projectedPhotoNode.addChildNode(borderNode)
        }

        var minV = patch.vertices[0]
        var maxV = patch.vertices[0]
        var sum = SIMD3<Float>(repeating: 0)
        for vertex in patch.vertices {
            minV = simd_min(minV, vertex)
            maxV = simd_max(maxV, vertex)
            sum += vertex
        }
        let centroid = sum / Float(patch.vertices.count)
        let diagonal = simd_length(maxV - minV)
        let labelNode = Self.shotLabelNode(text: String(format: "%04d", shot.id), color: color)
        let labelScale = max(0.22, min(0.7, diagonal * 0.06))
        labelNode.scale = SCNVector3(CGFloat(labelScale), CGFloat(labelScale), CGFloat(labelScale))
        let toCamera = cameraPosition - centroid
        let lift = simd_length(toCamera) > 1e-5 ? simd_normalize(toCamera) * 0.3 : SIMD3<Float>(repeating: 0)
        labelNode.simdPosition = centroid + lift
        projectedPhotoNode.addChildNode(labelNode)
    }

    private static func shotColor(_ id: Int) -> NSColor {
        let hue = (Double(id) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        return NSColor(calibratedHue: hue, saturation: 0.85, brightness: 1.0, alpha: 1.0)
    }

    private static func shotLabelNode(text: String, color: NSColor) -> SCNNode {
        let textGeometry = SCNText(string: text, extrusionDepth: 0)
        textGeometry.font = NSFont.boldSystemFont(ofSize: 1)
        textGeometry.flatness = 0.05
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        textGeometry.materials = [material]
        let node = SCNNode(geometry: textGeometry)
        let (minB, maxB) = textGeometry.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, 0)
        node.constraints = [SCNBillboardConstraint()]
        node.renderingOrder = 10
        return node
    }

    private static func boundarySegments(vertices: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        guard indices.count >= 3 else { return [] }
        struct EdgeKey: Hashable {
            let a: SIMD3<Int32>
            let b: SIMD3<Int32>
        }
        func quantized(_ v: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(
                Int32((v.x * 1024).rounded()),
                Int32((v.y * 1024).rounded()),
                Int32((v.z * 1024).rounded())
            )
        }
        func ordered(_ a: SIMD3<Int32>, _ b: SIMD3<Int32>) -> Bool {
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return a.z < b.z
        }
        var edges: [EdgeKey: (count: Int, start: SIMD3<Float>, end: SIMD3<Float>)] = [:]
        edges.reserveCapacity(indices.count)
        for t in Swift.stride(from: 0, through: indices.count - 3, by: 3) {
            let ids = [Int(indices[t]), Int(indices[t + 1]), Int(indices[t + 2])]
            for e in 0..<3 {
                let p0 = vertices[ids[e]]
                let p1 = vertices[ids[(e + 1) % 3]]
                let q0 = quantized(p0)
                let q1 = quantized(p1)
                guard q0 != q1 else { continue }
                let key = ordered(q0, q1) ? EdgeKey(a: q0, b: q1) : EdgeKey(a: q1, b: q0)
                if var entry = edges[key] {
                    entry.count += 1
                    edges[key] = entry
                } else {
                    edges[key] = (1, p0, p1)
                }
            }
        }
        var segments: [SIMD3<Float>] = []
        for entry in edges.values where entry.count == 1 {
            segments.append(entry.start)
            segments.append(entry.end)
        }
        return segments
    }

    private func openFile(allowed: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowedFileTypes = allowed
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func matrix(rotationWXYZ r: [Double], translation t: [Double]) -> simd_float4x4 {
        let q = simd_quatf(ix: Float(r[1]), iy: Float(r[2]), iz: Float(r[3]), r: Float(r[0]))
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4<Float>(Float(t[0]), Float(t[1]), Float(t[2]), 1)
        return m
    }

    private static func loadTransform(rowMajorJSON url: URL) throws -> simd_float4x4 {
        struct TransformFile: Decodable {
            let matrix_row_major: [[Double]]
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(TransformFile.self, from: data)
        let m = decoded.matrix_row_major
        guard m.count == 4, m.allSatisfy({ $0.count == 4 }) else {
            throw NSError(domain: "NativePoseMeshViewer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Transform non valida: \(url.path)"])
        }
        return simd_float4x4(
            SIMD4<Float>(Float(m[0][0]), Float(m[1][0]), Float(m[2][0]), Float(m[3][0])),
            SIMD4<Float>(Float(m[0][1]), Float(m[1][1]), Float(m[2][1]), Float(m[3][1])),
            SIMD4<Float>(Float(m[0][2]), Float(m[1][2]), Float(m[2][2]), Float(m[3][2])),
            SIMD4<Float>(Float(m[0][3]), Float(m[1][3]), Float(m[2][3]), Float(m[3][3]))
        )
    }

    private static func lineGeometry(points: [SIMD3<Float>], color: NSColor) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: points.map { SCNVector3($0.x, $0.y, $0.z) })
        let indices = Array(UInt32(0)..<UInt32(points.count))
        let data = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(data: data, primitiveType: .line, primitiveCount: points.count / 2, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        geometry.materials = [material]
        return geometry
    }

    private static func bcsPlaneGeometry(_ plane: BCSPlane) -> SCNGeometry {
        let points = plane.corners.compactMap { corner -> SIMD3<Float>? in
            guard corner.count == 3 else { return nil }
            return SIMD3<Float>(Float(corner[0]), Float(corner[1]), Float(corner[2]))
        }
        let vertexData = Data(bytes: points, count: points.count * MemoryLayout<SIMD3<Float>>.stride)
        var indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        let indexData = Data(bytes: &indices, count: indices.count * MemoryLayout<UInt32>.stride)
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: 2,
            bytesPerIndex: MemoryLayout<UInt32>.stride
        )
        return SCNGeometry(sources: [vertexSource], elements: [element])
    }

    private static func meshFromBCSPlanes(_ planes: [BCSPlane], hiddenPlaneIDs: Set<Int>) -> SimpleOBJMesh {
        var vertices: [SIMD3<Float>] = []
        var triangles: [SIMD3<Int32>] = []
        for (index, plane) in planes.enumerated() where !hiddenPlaneIDs.contains(index) {
            let corners = plane.corners.compactMap { corner -> SIMD3<Float>? in
                guard corner.count == 3 else { return nil }
                return SIMD3<Float>(Float(corner[0]), Float(corner[1]), Float(corner[2]))
            }
            guard corners.count == 4 else { continue }
            let base = Int32(vertices.count)
            vertices.append(contentsOf: corners)
            triangles.append(SIMD3<Int32>(base, base + 1, base + 2))
            triangles.append(SIMD3<Int32>(base, base + 2, base + 3))
        }
        return SimpleOBJMesh(vertices: vertices, triangles: triangles)
    }

    private static func parseOBJ(_ url: URL) throws -> SimpleOBJMesh {
        let text = try String(contentsOf: url)
        var vertices: [SIMD3<Float>] = []
        var triangles: [SIMD3<Int32>] = []
        vertices.reserveCapacity(100_000)
        triangles.reserveCapacity(100_000)

        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("v ") {
                let parts = line.split(separator: " ")
                guard parts.count >= 4,
                      let x = Float(parts[1]),
                      let y = Float(parts[2]),
                      let z = Float(parts[3]) else { continue }
                vertices.append(SIMD3<Float>(x, y, z))
            } else if line.hasPrefix("f ") {
                let parts = line.split(separator: " ").dropFirst()
                let ids = parts.compactMap { token -> Int32? in
                    guard let raw = token.split(separator: "/").first,
                          let idx = Int32(raw) else { return nil }
                    return idx > 0 ? idx - 1 : Int32(vertices.count) + idx
                }
                guard ids.count >= 3 else { continue }
                for i in 1..<(ids.count - 1) {
                    triangles.append(SIMD3<Int32>(ids[0], ids[i], ids[i + 1]))
                }
            }
        }
        return SimpleOBJMesh(vertices: vertices, triangles: triangles)
    }

    private static func projectedPhotoMaterial(image: NSImage) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.mipFilter = .linear
        material.lightingModel = .constant
        material.isDoubleSided = false
        material.transparency = 1.0
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = true
        return material
    }

    private struct MosaicCell {
        let a: SIMD3<Float>
        let b: SIMD3<Float>
        let c: SIMD3<Float>
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    struct CandidateCam {
        let shot: CameraShot
        let invCam: simd_float4x4
        let cameraPosition: SIMD3<Float>
        let forward: SIMD3<Float>

        init(_ shot: CameraShot) {
            self.shot = shot
            invCam = shot.transform.inverse
            cameraPosition = SIMD3<Float>(shot.transform.columns.3.x, shot.transform.columns.3.y, shot.transform.columns.3.z)
            forward = simd_normalize(-SIMD3<Float>(shot.transform.columns.2.x, shot.transform.columns.2.y, shot.transform.columns.2.z))
        }
    }

    struct CellScore {
        let score: Float
        let axial: Float
        let facing: Float
        let centrality: Float
        let proximity: Float
        let distance: Float
        let ua: SIMD2<Float>
        let ub: SIMD2<Float>
        let uc: SIMD2<Float>
    }

    private static func projectUV(_ point: SIMD3<Float>, _ cand: CandidateCam) -> SIMD2<Float>? {
        let pc4 = cand.invCam * SIMD4<Float>(point.x, point.y, point.z, 1)
        let pc = SIMD3<Float>(pc4.x, pc4.y, pc4.z) / max(pc4.w, 1e-9)
        let z = -Double(pc.z)
        guard z > 0.01 else { return nil }
        let px = cand.shot.fx * Double(pc.x) / z + cand.shot.cx
        let py = cand.shot.cy - cand.shot.fy * Double(pc.y) / z
        return SIMD2<Float>(Float(px / cand.shot.imageWidth), Float(py / cand.shot.imageHeight))
    }

    static func evaluateCell(
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        c: SIMD3<Float>,
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        cand: CandidateCam,
        cropMin: Float,
        cropMax: Float,
        minSurfaceFacing: Float,
        proximityScale: Float,
        orientationAgnostic: Bool,
        outwardSign: Float = 1
    ) -> CellScore? {
        let toCenter = center - cand.cameraPosition
        let distance = simd_length(toCenter)
        guard distance > 1e-4 else { return nil }
        let viewDir = toCenter / distance
        guard simd_dot(cand.forward, viewDir) > 0.05 else { return nil }
        let orientedNormal = normal * outwardSign
        let facingRaw = simd_dot(orientedNormal, -viewDir)
        let surfaceFacing = orientationAgnostic ? abs(facingRaw) : facingRaw
        guard surfaceFacing >= minSurfaceFacing else { return nil }
        guard let ua = projectUV(a, cand), let ub = projectUV(b, cand), let uc = projectUV(c, cand) else { return nil }
        let centerUV = (ua + ub + uc) / 3
        guard centerUV.x >= cropMin, centerUV.x <= cropMax, centerUV.y >= cropMin, centerUV.y <= cropMax else { return nil }

        let outwardNormal = facingRaw >= 0 ? orientedNormal : -orientedNormal
        let toCamera = -viewDir
        var horizontalAxiality: Float = 1
        var planeHorizontal = simd_cross(SIMD3<Float>(0, 1, 0), outwardNormal)
        let hLength = simd_length(planeHorizontal)
        if hLength > 1e-4 {
            planeHorizontal /= hLength
            let tanH = abs(simd_dot(toCamera, planeHorizontal)) / max(surfaceFacing, 0.05)
            horizontalAxiality = 1 / (1 + 2 * tanH)
        }
        let centrality = max(0, 1 - max(abs(centerUV.x * 2 - 1), abs(centerUV.y * 2 - 1)))
        let proximity = 1 / (1 + distance / proximityScale)
        let score = 2 * horizontalAxiality + 0.4 * surfaceFacing + 0.8 * centrality + 0.35 * proximity
        return CellScore(
            score: score,
            axial: horizontalAxiality,
            facing: surfaceFacing,
            centrality: centrality,
            proximity: proximity,
            distance: distance,
            ua: ua,
            ub: ub,
            uc: uc
        )
    }

    private static func buildCells(mesh: SimpleOBJMesh, cellSize: Float = 0.055) -> [MosaicCell] {
        var cells: [MosaicCell] = []
        cells.reserveCapacity(mesh.triangles.count)

        func appendCell(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            guard length > 1e-7 else { return }
            cells.append(MosaicCell(a: a, b: b, c: c, center: (a + b + c) / 3, normal: normal / length))
        }

        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            a + (b - a) * t
        }

        func tessellate(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let maxEdge = max(simd_length(b - a), simd_length(c - b), simd_length(a - c))
            let steps = max(1, min(96, Int(ceil(maxEdge / cellSize))))
            if steps == 1 {
                appendCell(a, b, c)
                return
            }
            for row in 0..<steps {
                let t0 = Float(row) / Float(steps)
                let t1 = Float(row + 1) / Float(steps)
                let left0 = mix(a, c, t0)
                let right0 = mix(b, c, t0)
                let left1 = mix(a, c, t1)
                let right1 = mix(b, c, t1)
                let cols0 = steps - row
                let cols1 = steps - row - 1
                for col in 0..<cols0 {
                    let p00 = mix(left0, right0, Float(col) / Float(cols0))
                    let p01 = mix(left0, right0, Float(col + 1) / Float(cols0))
                    if col < cols1 {
                        let p10 = mix(left1, right1, Float(col) / Float(cols1))
                        let p11 = mix(left1, right1, Float(col + 1) / Float(cols1))
                        appendCell(p00, p01, p10)
                        appendCell(p01, p11, p10)
                    } else {
                        appendCell(p00, p01, c)
                    }
                }
            }
        }

        let shouldTessellate = mesh.triangles.count < 5_000
        for triangle in mesh.triangles {
            let ids = [Int(triangle.x), Int(triangle.y), Int(triangle.z)]
            guard ids.allSatisfy({ $0 >= 0 && $0 < mesh.vertices.count }) else { continue }
            let a = mesh.vertices[ids[0]]
            let b = mesh.vertices[ids[1]]
            let c = mesh.vertices[ids[2]]
            shouldTessellate ? tessellate(a, b, c) : appendCell(a, b, c)
        }
        return cells
    }

    private static func buildMosaic(
        mesh: SimpleOBJMesh,
        shots: [CameraShot],
        cropFraction: Double,
        minSurfaceFacing: Float,
        maxPerBucket: Int,
        minAreaFraction: Float,
        continuityBonus: Float,
        edgeCleanup: Float,
        fillHoles: Bool,
        lastResortFill: Bool,
        obliqueMaxFacing: Float,
        occlusion: OcclusionTester?,
        cellSize: Float = 0.055,
        orientationProbe: OcclusionTester? = nil,
        colorSampler: ((Int, Float, Float) -> SIMD3<Float>?)? = nil
    ) -> (patches: [Int: ProjectedPatch], keptCount: Int, uncovered: [SIMD3<Float>], oblique: [SIMD3<Float>]) {
        let cells = buildCells(mesh: mesh, cellSize: cellSize)
        guard !cells.isEmpty, !shots.isEmpty else { return ([:], 0, [], []) }

        let crop = Float(min(max(cropFraction, 0.2), 1.0))
        let cropMin = (1 - crop) / 2
        let cropMax = 1 - cropMin
        let candidates = shots.map(CandidateCam.init)
        var minV = mesh.vertices.first ?? SIMD3<Float>(repeating: 0)
        var maxV = minV
        for vertex in mesh.vertices {
            minV = simd_min(minV, vertex)
            maxV = simd_max(maxV, vertex)
        }
        let proximityScale = max(simd_length(maxV - minV) * 0.1, 1e-3)
        let orientationAgnostic = mesh.triangles.count < 5_000

        // Orientamento dei piani: l'esterno è il lato dove stanno le CAMERE (sono tutte
        // all'esterno dell'edificio, per definizione). Segnale robusto per spalle e winding
        // invertito: le foto perpendicolari al piano contribuiscono ~0, quelle allineate decidono.
        var orientationSigns: [Float]?
        if orientationAgnostic {
            var signs = [Float](repeating: 1, count: cells.count)
            for i in cells.indices {
                var dir = SIMD3<Float>(repeating: 0)
                let center = cells[i].center
                for cand in candidates {
                    let d = cand.cameraPosition - center
                    let len = simd_length(d)
                    if len > 1e-4 { dir += d / len }
                }
                signs[i] = simd_dot(cells[i].normal, dir) >= 0 ? 1 : -1
            }
            orientationSigns = signs
        }
        let effectiveAgnostic = orientationAgnostic && orientationSigns == nil

        struct PoolEntry {
            let score: Float
            let cand: Int
            let facing: Float
            let ua: SIMD2<Float>
            let ub: SIMD2<Float>
            let uc: SIMD2<Float>
        }

        func candidatePool(_ cell: MosaicCell, outwardSign: Float) -> [PoolEntry] {
            var valid: [PoolEntry] = []
            for (index, cand) in candidates.enumerated() {
                if let r = evaluateCell(
                    a: cell.a, b: cell.b, c: cell.c,
                    center: cell.center, normal: cell.normal,
                    cand: cand,
                    cropMin: cropMin, cropMax: cropMax,
                    minSurfaceFacing: minSurfaceFacing,
                    proximityScale: proximityScale,
                    orientationAgnostic: effectiveAgnostic,
                    outwardSign: outwardSign
                ) {
                    valid.append(PoolEntry(score: r.score, cand: index, facing: r.facing, ua: r.ua, ub: r.ub, uc: r.uc))
                }
            }
            valid.sort { $0.score > $1.score }
            var pool: [PoolEntry] = []
            for entry in valid {
                if let occlusion,
                   occlusion.isOccluded(from: cell.center, toCamera: candidates[entry.cand].cameraPosition) {
                    continue
                }
                pool.append(entry)
                if pool.count >= 6 { break }
            }

            if pool.count >= 3, let colorSampler {
                let colors = pool.map { entry -> SIMD3<Float>? in
                    let centerUV = (entry.ua + entry.ub + entry.uc) / 3
                    return colorSampler(candidates[entry.cand].shot.id, centerUV.x, centerUV.y)
                }
                let known = colors.compactMap { $0 }
                if known.count >= 3 {
                    let median = SIMD3<Float>(
                        known.map(\.x).sorted()[known.count / 2],
                        known.map(\.y).sorted()[known.count / 2],
                        known.map(\.z).sorted()[known.count / 2]
                    )
                    let filtered = pool.indices.filter { index in
                        guard let color = colors[index] else { return true }
                        return simd_length(color - median) <= 0.35
                    }.map { pool[$0] }
                    if !filtered.isEmpty {
                        pool = filtered
                    }
                }
            }
            return pool
        }

        var pools: [[PoolEntry]] = []
        pools.reserveCapacity(cells.count)
        for i in cells.indices {
            pools.append(candidatePool(cells[i], outwardSign: orientationSigns?[i] ?? 1))
        }
        var chosen: [Int] = pools.map { $0.isEmpty ? -1 : 0 }

        // vicinato spaziale per il bonus di continuità
        var edgeSum: Float = 0
        let edgeSamples = min(cells.count, 1000)
        for i in 0..<edgeSamples {
            edgeSum += simd_length(cells[i].b - cells[i].a)
        }
        let cellSize = max(edgeSum / Float(max(edgeSamples, 1)), 1e-4)
        struct GridKey: Hashable {
            let x: Int32
            let y: Int32
            let z: Int32
        }
        let bucketSide = cellSize * 2
        func gridKey(_ p: SIMD3<Float>) -> GridKey {
            GridKey(x: Int32(floorf(p.x / bucketSide)), y: Int32(floorf(p.y / bucketSide)), z: Int32(floorf(p.z / bucketSide)))
        }
        var grid: [GridKey: [Int32]] = [:]
        for (i, cell) in cells.enumerated() {
            grid[gridKey(cell.center), default: []].append(Int32(i))
        }
        let neighborRadius = cellSize * 1.9
        var neighbors: [[Int32]] = Array(repeating: [], count: cells.count)
        for (i, cell) in cells.enumerated() {
            let k = gridKey(cell.center)
            var list: [Int32] = []
            outer: for dx in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dz in Int32(-1)...1 {
                        guard let bucket = grid[GridKey(x: k.x + dx, y: k.y + dy, z: k.z + dz)] else { continue }
                        for j in bucket where j != Int32(i) {
                            if simd_distance(cells[Int(j)].center, cell.center) < neighborRadius {
                                list.append(j)
                                if list.count >= 10 { break outer }
                            }
                        }
                    }
                }
            }
            neighbors[i] = list
        }

        // Etichettatura a MARGINE: una cella adotta la foto dominante fra i vicini se
        // quella foto è "abbastanza buona" per la cella (entro `margin` dal suo massimo).
        // Così una foto copre TUTTA la sua zona d'interesse e due candidate simili non si
        // spartiscono la regione a metà — il confine cade solo dove una è NETTAMENTE migliore.
        // Il risultato è insensibile al numero di foto: candidate equivalenti vengono assorbite.
        func relax(sweeps: Int) {
            let baseMargin = max(continuityBonus, 0.001)
            for _ in 0..<sweeps {
                var changed = 0
                for i in cells.indices {
                    let pool = pools[i]
                    guard pool.count > 1 else { continue }
                    let nbs = neighbors[i]
                    guard !nbs.isEmpty else { continue }
                    var counts: [Int: Int] = [:]
                    for j in nbs {
                        let cj = chosen[Int(j)]
                        if cj >= 0 {
                            counts[pools[Int(j)][cj].cand, default: 0] += 1
                        }
                    }
                    // margine più ampio vicino al bordo del piano (poche celle attorno)
                    let edgeFactor = max(0, 1 - Float(nbs.count) / 8)
                    let margin = baseMargin + edgeCleanup * edgeFactor
                    let bestScore = pool[0].score            // pool ordinato per score desc
                    let threshold = bestScore * (1 - margin) // "abbastanza buona"
                    // fra le candidate accettabili (entro il margine), vince la più usata dai vicini
                    var bestIdx = 0
                    var bestFreq = -1
                    var bestSc = -Float.greatestFiniteMagnitude
                    for (pi, entry) in pool.enumerated() {
                        guard entry.score >= threshold else { continue }
                        let f = counts[entry.cand] ?? 0
                        if f > bestFreq || (f == bestFreq && entry.score > bestSc) {
                            bestFreq = f
                            bestSc = entry.score
                            bestIdx = pi
                        }
                    }
                    if bestIdx != chosen[i] {
                        chosen[i] = bestIdx
                        changed += 1
                    }
                }
                if changed == 0 { break }
            }
        }

        relax(sweeps: 6)
        let baselineScore: [Float] = pools.map { $0.first?.score ?? -Float.greatestFiniteMagnitude }

        var bucketNormals: [SIMD3<Float>] = []
        var cellBuckets = [Int](repeating: 0, count: cells.count)
        for i in cells.indices {
            let n = cells[i].normal
            var best = -1
            var bestDot: Float = 0.9
            for (bi, bn) in bucketNormals.enumerated() {
                let raw = simd_dot(bn, n)
                let d = orientationAgnostic ? abs(raw) : raw
                if d > bestDot {
                    bestDot = d
                    best = bi
                }
            }
            if best == -1 {
                if bucketNormals.count < 64 {
                    bucketNormals.append(n)
                    best = bucketNormals.count - 1
                } else {
                    var bd: Float = -2
                    best = 0
                    for (bi, bn) in bucketNormals.enumerated() {
                        let raw = simd_dot(bn, n)
                        let d = orientationAgnostic ? abs(raw) : raw
                        if d > bd {
                            bd = d
                            best = bi
                        }
                    }
                }
            }
            cellBuckets[i] = best
        }

        let bucketCount = max(bucketNormals.count, 1)
        // copertura greedy: a ogni giro entra la foto che copre più celle ancora scoperte
        var keep = [Bool](repeating: false, count: candidates.count)
        var bucketCells: [[Int]] = Array(repeating: [], count: bucketCount)
        for i in cells.indices {
            bucketCells[cellBuckets[i]].append(i)
        }
        let minCells = max(Int(minAreaFraction * Float(cells.count)), 1)
        for b in 0..<bucketCount {
            var covered = Set<Int>()
            for _ in 0..<maxPerBucket {
                var counts = [Int](repeating: 0, count: candidates.count)
                for i in bucketCells[b] where !covered.contains(i) {
                    for entry in pools[i] {
                        counts[entry.cand] += 1
                    }
                }
                var bestCand = -1
                var bestCount = 0
                for c in candidates.indices where counts[c] > bestCount {
                    bestCount = counts[c]
                    bestCand = c
                }
                guard bestCand >= 0, bestCount >= minCells else { break }
                keep[bestCand] = true
                for i in bucketCells[b] where !covered.contains(i) {
                    if pools[i].contains(where: { $0.cand == bestCand }) {
                        covered.insert(i)
                    }
                }
            }
        }

        let originalPools = pools
        for i in cells.indices {
            let currentCand = chosen[i] >= 0 ? pools[i][chosen[i]].cand : -1
            pools[i] = pools[i].filter { keep[$0.cand] }
            if pools[i].isEmpty {
                chosen[i] = -1
            } else if let index = pools[i].firstIndex(where: { $0.cand == currentCand }) {
                chosen[i] = index
            } else {
                chosen[i] = 0
            }
        }

        // gli orfani rivalutano da zero le sole foto tenute (non solo la top-6 in cache)
        let keptIndices = candidates.indices.filter { keep[$0] }
        if !keptIndices.isEmpty {
            for i in cells.indices where chosen[i] == -1 {
                var entries: [PoolEntry] = []
                for index in keptIndices {
                    if let r = evaluateCell(
                        a: cells[i].a, b: cells[i].b, c: cells[i].c,
                        center: cells[i].center, normal: cells[i].normal,
                        cand: candidates[index],
                        cropMin: cropMin, cropMax: cropMax,
                        minSurfaceFacing: minSurfaceFacing,
                        proximityScale: proximityScale,
                        orientationAgnostic: effectiveAgnostic,
                        outwardSign: orientationSigns?[i] ?? 1
                    ) {
                        entries.append(PoolEntry(score: r.score, cand: index, facing: r.facing, ua: r.ua, ub: r.ub, uc: r.uc))
                    }
                }
                entries.sort { $0.score > $1.score }
                for entry in entries {
                    if entry.score < baselineScore[i] * 0.55 { break }
                    if let occlusion,
                       occlusion.isOccluded(from: cells[i].center, toCamera: candidates[entry.cand].cameraPosition) {
                        continue
                    }
                    pools[i] = [entry]
                    chosen[i] = 0
                    break
                }
            }
        }
        relax(sweeps: 4)

        // Riempimento buchi: opera SOLO sulle celle ancora rosse, con i pool originali.
        // Le celle già assegnate sono congelate: le foto extra non possono riscriverle.
        var fillCount = 0
        if fillHoles {
            var fillKeep = Set<Int>()
            var covered = Set<Int>()
            while true {
                var counts = [Int: Int]()
                for i in cells.indices where chosen[i] == -1 && !covered.contains(i) {
                    for entry in originalPools[i] {
                        counts[entry.cand, default: 0] += 1
                    }
                }
                var bestCand = -1
                var bestCount = 0
                for (cand, n) in counts where n > bestCount {
                    bestCount = n
                    bestCand = cand
                }
                guard bestCand >= 0 else { break }
                fillKeep.insert(bestCand)
                for i in cells.indices where chosen[i] == -1 && !covered.contains(i) {
                    if originalPools[i].contains(where: { $0.cand == bestCand }) {
                        covered.insert(i)
                    }
                }
            }
            fillCount = fillKeep.count
            for i in cells.indices where chosen[i] == -1 {
                if let best = originalPools[i].first(where: { fillKeep.contains($0.cand) }) {
                    pools[i] = [best]
                    chosen[i] = 0
                }
            }
        }

        // Terza passata "ultima spiaggia": per le celle ANCORA rosse allenta i gate —
        // fotogramma intero (non solo il centro) e viste radenti fino a ~84°.
        // Congela sempre le celle già assegnate.
        if lastResortFill {
            let relaxedFacing: Float = 0.10
            func relaxedEntry(_ i: Int, _ index: Int) -> PoolEntry? {
                guard let r = evaluateCell(
                    a: cells[i].a, b: cells[i].b, c: cells[i].c,
                    center: cells[i].center, normal: cells[i].normal,
                    cand: candidates[index],
                    cropMin: 0, cropMax: 1,
                    minSurfaceFacing: relaxedFacing,
                    proximityScale: proximityScale,
                    orientationAgnostic: effectiveAgnostic,
                    outwardSign: orientationSigns?[i] ?? 1
                ) else { return nil }
                if let occlusion,
                   occlusion.isOccluded(from: cells[i].center, toCamera: candidates[index].cameraPosition) {
                    return nil
                }
                return PoolEntry(score: r.score, cand: index, facing: r.facing, ua: r.ua, ub: r.ub, uc: r.uc)
            }

            // 1) CRESCITA DI REGIONE: la cella rossa eredita la foto dei vicini già
            //    assegnati (quella più frequente che riesce a vederla). Estende in modo
            //    COERENTE le regioni esistenti — i balconi restano di un'unica foto,
            //    deformati dalla prospettiva ma continui, invece di frammentarsi.
            // La crescita eredita SOLO da vicini con orientamento simile (stesso piano):
            // così un corner frontale non prende la foto della spalla/torretta ("gira l'angolo").
            let sameOrientationDot: Float = 0.8
            var changed = true
            var sweep = 0
            while changed && sweep < 96 {
                changed = false
                sweep += 1
                for i in cells.indices where chosen[i] == -1 {
                    let ni = cells[i].normal
                    var freq: [Int: Int] = [:]
                    for j in neighbors[i] {
                        let cj = chosen[Int(j)]
                        guard cj >= 0 else { continue }
                        guard simd_dot(ni, cells[Int(j)].normal) > sameOrientationDot else { continue }
                        freq[pools[Int(j)][cj].cand, default: 0] += 1
                    }
                    guard !freq.isEmpty else { continue }
                    for (cand, _) in freq.sorted(by: { $0.value > $1.value }) {
                        if let entry = relaxedEntry(i, cand) {
                            pools[i] = [entry]
                            chosen[i] = 0
                            changed = true
                            break
                        }
                    }
                }
            }

            // 2) ISOLE senza vicini di pari orientamento: nessuna regione da estendere,
            //    prendo la migliore vista disponibile (isole piccole e rare).
            for i in cells.indices where chosen[i] == -1 {
                var best: PoolEntry?
                for index in candidates.indices {
                    guard let entry = relaxedEntry(i, index) else { continue }
                    if best == nil || entry.score > best!.score {
                        best = entry
                    }
                }
                if let best {
                    pools[i] = [best]
                    chosen[i] = 0
                }
            }
        }

        struct Accumulator {
            var vertices: [SIMD3<Float>] = []
            var texcoords: [SIMD2<Float>] = []
            var indices: [UInt32] = []
        }
        var accumulators: [Int: Accumulator] = [:]
        for i in cells.indices where chosen[i] >= 0 {
            let entry = pools[i][chosen[i]]
            let shotID = candidates[entry.cand].shot.id
            var acc = accumulators[shotID] ?? Accumulator()
            let base = UInt32(acc.vertices.count)
            acc.vertices.append(contentsOf: [cells[i].a, cells[i].b, cells[i].c])
            acc.texcoords.append(contentsOf: [entry.ua, entry.ub, entry.uc])
            acc.indices.append(contentsOf: [base, base + 1, base + 2])
            accumulators[shotID] = acc
        }
        let patches = accumulators.compactMapValues { acc -> ProjectedPatch? in
            guard !acc.indices.isEmpty else { return nil }
            return ProjectedPatch(
                geometry: geometryFromProjected(vertices: acc.vertices, texcoords: acc.texcoords, indices: acc.indices),
                vertices: acc.vertices,
                indices: acc.indices,
                texcoords: acc.texcoords
            )
        }
        let uncoveredLift = proximityScale * 0.005
        var uncovered: [SIMD3<Float>] = []
        for i in cells.indices where chosen[i] == -1 {
            let offset = cells[i].normal * uncoveredLift
            uncovered.append(contentsOf: [cells[i].a + offset, cells[i].b + offset, cells[i].c + offset])
        }
        // celle geometricamente oblique: la foto assegnata le vede oltre `obliqueMaxFacing`
        // dalla normale (texture debole per forza di cose, non per selezione).
        var oblique: [SIMD3<Float>] = []
        if obliqueMaxFacing > 0 {
            let lift = proximityScale * 0.004
            for i in cells.indices where chosen[i] >= 0 {
                guard pools[i][chosen[i]].facing < obliqueMaxFacing else { continue }
                let offset = cells[i].normal * lift
                oblique.append(contentsOf: [cells[i].a + offset, cells[i].b + offset, cells[i].c + offset])
            }
        }
        return (patches, keep.filter { $0 }.count + fillCount, uncovered, oblique)
    }

    private static func solidTriangleGeometry(vertices: [SIMD3<Float>], color: NSColor) -> SCNGeometry {
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<SIMD3<Float>>.stride)
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let indices = Array(UInt32(0)..<UInt32(vertices.count))
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: vertices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.stride
        )
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    private static func geometryFromProjected(vertices: [SIMD3<Float>], texcoords: [SIMD2<Float>], indices: [UInt32]) -> SCNGeometry {
        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<SIMD3<Float>>.stride)
        let texcoordData = Data(bytes: texcoords, count: texcoords.count * MemoryLayout<SIMD2<Float>>.stride)
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let texcoordSource = SCNGeometrySource(
            data: texcoordData,
            semantic: .texcoord,
            vectorCount: texcoords.count,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.stride
        )
        return SCNGeometry(sources: [vertexSource, texcoordSource], elements: [element])
    }

    private static func projectedTextureGeometry(mesh: SimpleOBJMesh, shot: CameraShot, cropFraction: Double) -> ProjectedPatch {
        let invCam = shot.transform.inverse
        var vertices: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        let crop = Float(min(max(cropFraction, 0.2), 1.0))
        let cropMin = (1 - crop) / 2
        let cropMax = 1 - cropMin
        let shouldTessellate = mesh.triangles.count < 5_000
        vertices.reserveCapacity(mesh.triangles.count * (shouldTessellate ? 1_200 : 3))
        texcoords.reserveCapacity(mesh.triangles.count * (shouldTessellate ? 1_200 : 3))
        indices.reserveCapacity(mesh.triangles.count * (shouldTessellate ? 1_200 : 3))

        func project(_ v: SIMD3<Float>) -> SIMD2<Float>? {
            let pc4 = invCam * SIMD4<Float>(v.x, v.y, v.z, 1)
            let pc = SIMD3<Float>(pc4.x, pc4.y, pc4.z) / max(pc4.w, 1e-9)
            let z = -Double(pc.z)
            guard z > 0.01 else { return nil }
            let px = shot.fx * Double(pc.x) / z + shot.cx
            let py = shot.cy - shot.fy * Double(pc.y) / z
            return SIMD2<Float>(Float(px / shot.imageWidth), Float(py / shot.imageHeight))
        }

        func appendTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let center = (a + b + c) / 3
            let normal = simd_cross(b - a, c - a)
            let normalLength = simd_length(normal)
            guard normalLength > 1e-7 else { return }
            let cameraPosition = SIMD3<Float>(
                shot.transform.columns.3.x,
                shot.transform.columns.3.y,
                shot.transform.columns.3.z
            )
            guard simd_dot(normal / normalLength, simd_normalize(cameraPosition - center)) > 0.05 else { return }
            guard let ua = project(a), let ub = project(b), let uc = project(c) else { return }
            let centerUV = (ua + ub + uc) / 3
            guard centerUV.x >= cropMin, centerUV.x <= cropMax, centerUV.y >= cropMin, centerUV.y <= cropMax else { return }
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: [a, b, c])
            texcoords.append(contentsOf: [ua, ub, uc])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }

        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            a + (b - a) * t
        }

        func tessellateTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let maxEdge = max(simd_length(b - a), simd_length(c - b), simd_length(a - c))
            let steps = max(1, min(96, Int(ceil(maxEdge / 0.055))))
            if steps == 1 {
                appendTriangle(a, b, c)
                return
            }

            for row in 0..<steps {
                let t0 = Float(row) / Float(steps)
                let t1 = Float(row + 1) / Float(steps)
                let left0 = mix(a, c, t0)
                let right0 = mix(b, c, t0)
                let left1 = mix(a, c, t1)
                let right1 = mix(b, c, t1)
                let cols0 = steps - row
                let cols1 = steps - row - 1
                for col in 0..<cols0 {
                    let s0 = Float(col) / Float(cols0)
                    let s1 = Float(col + 1) / Float(cols0)
                    let p00 = mix(left0, right0, s0)
                    let p01 = mix(left0, right0, s1)
                    if col < cols1 {
                        let q0 = Float(col) / Float(cols1)
                        let q1 = Float(col + 1) / Float(cols1)
                        let p10 = mix(left1, right1, q0)
                        let p11 = mix(left1, right1, q1)
                        appendTriangle(p00, p01, p10)
                        appendTriangle(p01, p11, p10)
                    } else {
                        appendTriangle(p00, p01, c)
                    }
                }
            }
        }

        for triangle in mesh.triangles {
            let ids = [Int(triangle.x), Int(triangle.y), Int(triangle.z)]
            guard ids.allSatisfy({ $0 >= 0 && $0 < mesh.vertices.count }) else { continue }
            let a = mesh.vertices[ids[0]]
            let b = mesh.vertices[ids[1]]
            let c = mesh.vertices[ids[2]]
            if shouldTessellate {
                tessellateTriangle(a, b, c)
            } else {
                appendTriangle(a, b, c)
            }
        }

        let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<SIMD3<Float>>.stride)
        let texcoordData = Data(bytes: texcoords, count: texcoords.count * MemoryLayout<SIMD2<Float>>.stride)
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let texcoordSource = SCNGeometrySource(
            data: texcoordData,
            semantic: .texcoord,
            vectorCount: texcoords.count,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD2<Float>>.stride
        )
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.stride
        )
        return ProjectedPatch(
            geometry: SCNGeometry(sources: [vertexSource, texcoordSource], elements: [element]),
            vertices: vertices,
            indices: indices,
            texcoords: texcoords
        )
    }
}

final class OcclusionTester {
    private var triA: [SIMD3<Float>] = []
    private var triB: [SIMD3<Float>] = []
    private var triC: [SIMD3<Float>] = []
    private var nodeMin: [SIMD3<Float>] = []
    private var nodeMax: [SIMD3<Float>] = []
    private var nodeLeft: [Int32] = []
    private var nodeRight: [Int32] = []
    private var nodeStart: [Int32] = []
    private var nodeCount: [Int32] = []
    let epsilon: Float
    let triangleCount: Int

    init?(mesh: SimpleOBJMesh) {
        var a: [SIMD3<Float>] = []
        var b: [SIMD3<Float>] = []
        var c: [SIMD3<Float>] = []
        a.reserveCapacity(mesh.triangles.count)
        b.reserveCapacity(mesh.triangles.count)
        c.reserveCapacity(mesh.triangles.count)
        for triangle in mesh.triangles {
            let ids = [Int(triangle.x), Int(triangle.y), Int(triangle.z)]
            guard ids.allSatisfy({ $0 >= 0 && $0 < mesh.vertices.count }) else { continue }
            a.append(mesh.vertices[ids[0]])
            b.append(mesh.vertices[ids[1]])
            c.append(mesh.vertices[ids[2]])
        }
        guard !a.isEmpty else { return nil }
        triangleCount = a.count

        var minV = a[0]
        var maxV = a[0]
        for i in a.indices {
            minV = simd_min(minV, simd_min(a[i], simd_min(b[i], c[i])))
            maxV = simd_max(maxV, simd_max(a[i], simd_max(b[i], c[i])))
        }
        epsilon = max(simd_length(maxV - minV) * 0.006, 1e-4)

        let centroids = a.indices.map { (a[$0] + b[$0] + c[$0]) / 3 }
        var order = Array(a.indices)
        var nMin: [SIMD3<Float>] = []
        var nMax: [SIMD3<Float>] = []
        var nLeft: [Int32] = []
        var nRight: [Int32] = []
        var nStart: [Int32] = []
        var nCount: [Int32] = []

        func build(_ lo: Int, _ hi: Int) -> Int32 {
            var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var bmax = -bmin
            for k in lo..<hi {
                let t = order[k]
                bmin = simd_min(bmin, simd_min(a[t], simd_min(b[t], c[t])))
                bmax = simd_max(bmax, simd_max(a[t], simd_max(b[t], c[t])))
            }
            let nodeIndex = nMin.count
            nMin.append(bmin)
            nMax.append(bmax)
            nLeft.append(-1)
            nRight.append(-1)
            nStart.append(-1)
            nCount.append(0)
            if hi - lo <= 8 {
                nStart[nodeIndex] = Int32(lo)
                nCount[nodeIndex] = Int32(hi - lo)
                return Int32(nodeIndex)
            }
            let size = bmax - bmin
            let axis = size.x >= size.y && size.x >= size.z ? 0 : (size.y >= size.z ? 1 : 2)
            let mid = (lo + hi) / 2
            order[lo..<hi].sort { centroids[$0][axis] < centroids[$1][axis] }
            nLeft[nodeIndex] = build(lo, mid)
            nRight[nodeIndex] = build(mid, hi)
            return Int32(nodeIndex)
        }
        _ = build(0, order.count)

        triA = order.map { a[$0] }
        triB = order.map { b[$0] }
        triC = order.map { c[$0] }
        nodeMin = nMin
        nodeMax = nMax
        nodeLeft = nLeft
        nodeRight = nRight
        nodeStart = nStart
        nodeCount = nCount
    }

    func isOccluded(from point: SIMD3<Float>, toCamera camera: SIMD3<Float>) -> Bool {
        let direction = camera - point
        let length = simd_length(direction)
        guard length > epsilon * 2.5 else { return false }
        let tMin = epsilon / length
        let tMax = 1 - epsilon / length
        let invDir = SIMD3<Float>(1 / direction.x, 1 / direction.y, 1 / direction.z)
        var stack: [Int32] = []
        stack.reserveCapacity(64)
        stack.append(0)
        while let nodeIndex = stack.popLast() {
            let ni = Int(nodeIndex)
            guard hitsBox(nodeMin[ni], nodeMax[ni], point, invDir, tMin, tMax) else { continue }
            if nodeCount[ni] > 0 {
                let start = Int(nodeStart[ni])
                for k in start..<(start + Int(nodeCount[ni])) {
                    if hitsTriangle(triA[k], triB[k], triC[k], origin: point, direction: direction, tMin: tMin, tMax: tMax) {
                        return true
                    }
                }
            } else {
                stack.append(nodeLeft[ni])
                stack.append(nodeRight[ni])
            }
        }
        return false
    }

    private func hitsBox(_ bmin: SIMD3<Float>, _ bmax: SIMD3<Float>, _ origin: SIMD3<Float>, _ invDir: SIMD3<Float>, _ tMin: Float, _ tMax: Float) -> Bool {
        var t0 = tMin
        var t1 = tMax
        for axis in 0..<3 {
            let inv = invDir[axis]
            if inv.isFinite {
                var tNear = (bmin[axis] - origin[axis]) * inv
                var tFar = (bmax[axis] - origin[axis]) * inv
                if tNear > tFar { swap(&tNear, &tFar) }
                t0 = max(t0, tNear)
                t1 = min(t1, tFar)
                if t0 > t1 { return false }
            } else if origin[axis] < bmin[axis] || origin[axis] > bmax[axis] {
                return false
            }
        }
        return true
    }

    private func hitsTriangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, origin: SIMD3<Float>, direction: SIMD3<Float>, tMin: Float, tMax: Float) -> Bool {
        triangleHitT(a, b, c, origin: origin, direction: direction, tMin: tMin, tMax: tMax) != nil
    }

    private func triangleHitT(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, origin: SIMD3<Float>, direction: SIMD3<Float>, tMin: Float, tMax: Float) -> Float? {
        let e1 = b - a
        let e2 = c - a
        let p = simd_cross(direction, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-12 else { return nil }
        let invDet = 1 / det
        let tvec = origin - a
        let u = simd_dot(tvec, p) * invDet
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(tvec, e1)
        let v = simd_dot(direction, q) * invDet
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * invDet
        return t > tMin && t < tMax ? t : nil
    }

    /// Distanza al primo ostacolo lungo `direction` (unitaria); `maxDistance` se libera.
    func freeDistance(from point: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float) -> Float {
        let dir = direction * maxDistance
        let tStart = epsilon / maxDistance
        var bestT: Float = 1
        let invDir = SIMD3<Float>(1 / dir.x, 1 / dir.y, 1 / dir.z)
        var stack: [Int32] = []
        stack.reserveCapacity(64)
        stack.append(0)
        while let nodeIndex = stack.popLast() {
            let ni = Int(nodeIndex)
            guard hitsBox(nodeMin[ni], nodeMax[ni], point, invDir, tStart, bestT) else { continue }
            if nodeCount[ni] > 0 {
                let start = Int(nodeStart[ni])
                for k in start..<(start + Int(nodeCount[ni])) {
                    if let t = triangleHitT(triA[k], triB[k], triC[k], origin: point, direction: dir, tMin: tStart, tMax: bestT) {
                        bestT = t
                    }
                }
            } else {
                stack.append(nodeLeft[ni])
                stack.append(nodeRight[ni])
            }
        }
        return bestT * maxDistance
    }
}

struct ContentView: View {
    @StateObject private var model = ViewerModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            NativeSceneView(
                scene: model.scene,
                pointOfView: model.cameraNode,
                cameraRevision: model.cameraRevision,
                editing: model.editPlanesMode,
                onClick: { point, normal in model.inspect(point: point, normal: normal) },
                onHandleBegin: { name in model.beginHandleDrag(name: name) },
                onHandleDrag: { dx, dy in model.dragHandle(deltaX: dx, deltaY: dy) },
                onAxisDrag: { delta in model.dragAlongAxis(delta) },
                onHandleEnd: { model.endHandleDrag() }
            )
            .background(Color.black)
        }
        .frame(minWidth: 1120, minHeight: 760)
        .onAppear { model.reload() }
    }

    private var sidebar: some View {
        ScrollView {
            sidebarContent
        }
        .frame(width: 320)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OC Pose Mesh Viewer")
                .font(.headline)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            Button("Carica mesh OBJ/USDZ") { model.chooseMesh() }
            HStack {
                Button("Mesh OC originale") { model.useOriginalOCMesh() }
                Button("Piani BCS JSON") { model.useClaudePlanesMesh() }
            }
            Button("Allineati medio") { model.useAlignedMediumPair() }
            Text(model.meshURL.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if !model.meshScaleInfo.isEmpty {
                Text(model.meshScaleInfo)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Button("Carica pose OC JSON") { model.choosePoses() }
            Text(model.posesURL.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Button("Cartella foto") { model.choosePhotos() }
            Text(model.photosURL.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            Toggle("Geometria visibile", isOn: $model.showMesh)
                .onChange(of: model.showMesh) { _ in model.setMeshVisible(model.showMesh) }

            Toggle("Wire geometria", isOn: $model.showWire)
                .onChange(of: model.showWire) { _ in model.applyMeshAppearance() }

            Toggle("Griglia celle", isOn: $model.showCellGrid)
                .onChange(of: model.showCellGrid) { _ in model.rebuildCellGrid() }

            if model.planeCount > 0 {
                Picker("Piano", selection: $model.selectedPlaneIndex) {
                    ForEach(0..<model.planeCount, id: \.self) { index in
                        let hidden = model.hiddenPlaneIDs.contains(index)
                        Text("Piano \(index + 1)\(hidden ? " nascosto" : "")").tag(index)
                    }
                }
                .onChange(of: model.selectedPlaneIndex) { _ in model.refreshPlaneSelection() }

                HStack {
                    Button("Elimina piano") { model.deleteSelectedPlane() }
                    Button("Ripristina piani") { model.restorePlanes() }
                }
            }

            Toggle("Texture OC", isOn: $model.showOCTexture)
                .onChange(of: model.showOCTexture) { _ in model.applyMeshAppearance() }

            Toggle("Texture foto proiettata", isOn: $model.showProjectedPhoto)
                .onChange(of: model.showProjectedPhoto) { _ in model.rebuildProjectedPhoto() }

            Toggle("Multi foto automatico", isOn: $model.projectMultiplePhotos)
                .onChange(of: model.projectMultiplePhotos) { _ in model.rebuildProjectedPhoto() }

            Toggle("Bordi + numeri foto", isOn: $model.showPhotoBorders)
                .onChange(of: model.showPhotoBorders) { _ in model.rebuildProjectedPhoto() }

            Toggle("Celle senza foto in rosso", isOn: $model.showUncoveredCells)
                .onChange(of: model.showUncoveredCells) { _ in model.rebuildProjectedPhoto() }

            Toggle("Evidenzia oblique (ambra)", isOn: $model.showObliqueCells)
                .onChange(of: model.showObliqueCells) { _ in model.rebuildProjectedPhoto() }

            if model.showObliqueCells {
                HStack {
                    Text("Oltre")
                    Slider(value: $model.obliqueAngleDegrees, in: 40...80, step: 5)
                    Text("\(Int(model.obliqueAngleDegrees))°")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .onChange(of: model.obliqueAngleDegrees) { _ in model.rebuildProjectedPhoto() }
            }

            Toggle("Riempi buchi (foto extra)", isOn: $model.fillHolesEnabled)
                .onChange(of: model.fillHolesEnabled) { _ in model.rebuildProjectedPhoto() }

            Toggle("Riempi residui (viste oblique)", isOn: $model.lastResortFillEnabled)
                .onChange(of: model.lastResortFillEnabled) { _ in model.rebuildProjectedPhoto() }

            Divider()

            Button("Esporta ortofoto piani (UV)") { model.bakeOrthophotos() }
            HStack {
                Text("Risoluzione")
                Slider(value: $model.bakeResolutionMM, in: 3...20, step: 1)
                Text("\(Int(model.bakeResolutionMM)) mm")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            if !model.bakeStatus.isEmpty {
                Text(model.bakeStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Toggle("Consenso colore (scarta intrusi)", isOn: $model.photoConsensusEnabled)
                .onChange(of: model.photoConsensusEnabled) { _ in model.rebuildProjectedPhoto() }

            HStack {
                Button("Escludi foto selezionata") { model.excludeSelectedShot() }
                if !model.excludedShotIDs.isEmpty {
                    Button("Riammetti") { model.clearExcludedShots() }
                }
            }
            if !model.excludedShotIDs.isEmpty {
                Text("Escluse: " + model.excludedShotIDs.sorted().map { String(format: "%04d", $0) }.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Button("Tutte filtrate") { model.projectAllFilteredPhotos() }

            Toggle("Occlusione mesh (raycast)", isOn: $model.occlusionEnabled)
                .onChange(of: model.occlusionEnabled) { _ in model.rebuildProjectedPhoto() }

            HStack {
                Text("Best N/piano")
                Slider(value: $model.projectionMaxPhotos, in: 1...Double(max(model.shots.count, 48)), step: 1)
                Text("\(Int(model.projectionMaxPhotos))")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .onChange(of: model.projectionMaxPhotos) { _ in model.rebuildProjectedPhoto() }

            HStack {
                Text("Angolo max")
                Slider(value: $model.projectionFacingThreshold, in: 0.05...0.9, step: 0.01)
                Text("\(Int(acos(min(max(model.projectionFacingThreshold, 0), 1)) * 180 / .pi))°")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .onChange(of: model.projectionFacingThreshold) { _ in model.rebuildProjectedPhoto() }

            HStack {
                Text("Area min")
                Slider(value: $model.projectionMinCoverage, in: 0.0...0.15, step: 0.005)
                Text(String(format: "%.1f%%", model.projectionMinCoverage * 100))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .onChange(of: model.projectionMinCoverage) { _ in model.rebuildProjectedPhoto() }

            HStack {
                Text("Continuità")
                Slider(value: $model.continuityBonus, in: 0.0...0.4, step: 0.05)
                Text("\(Int(model.continuityBonus * 100))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .onChange(of: model.continuityBonus) { _ in model.rebuildProjectedPhoto() }

            HStack {
                Text("Bordi puliti")
                Slider(value: $model.edgeCleanupStrength, in: 0.0...1.5, step: 0.1)
                Text("\(Int(model.edgeCleanupStrength * 100))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .onChange(of: model.edgeCleanupStrength) { _ in model.rebuildProjectedPhoto() }

            Divider()

            Toggle("Edita piani (maniglie)", isOn: $model.editPlanesMode)
                .onChange(of: model.editPlanesMode) { _ in model.setEditMode(model.editPlanesMode) }
            if model.editPlanesMode {
                if model.editPlaneCount > 0 {
                    Picker("Piano", selection: $model.editPlaneIndex) {
                        ForEach(0..<model.editPlaneCount, id: \.self) { i in
                            Text("Piano \(i + 1)").tag(i)
                        }
                    }
                    .onChange(of: model.editPlaneIndex) { _ in model.refreshEditablePlanes() }
                }
                Toggle("Proiezione live (veloce)", isOn: $model.liveEditProjection)
                HStack {
                    Text("Passo")
                    Slider(value: $model.editStepCM, in: 1...30, step: 1)
                    Text("\(Int(model.editStepCM)) cm")
                        .monospacedDigit().frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Text("Sensib.")
                    Slider(value: $model.editSensitivity, in: 0.2...3.0, step: 0.1)
                    Text(String(format: "%.1f", model.editSensitivity))
                        .monospacedDigit().frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Text("Profondità")
                    Button("−") { model.nudgeDepth(-1) }
                    Button("+") { model.nudgeDepth(1) }
                    Spacer()
                    Text("Rifila")
                    Button("−") { model.nudgeInset(-1) }
                    Button("+") { model.nudgeInset(1) }
                }
                Button("Salva piani editati") { model.saveEditedPlanes() }
                Text("Clicca una sfera (angolo giallo / spigolo verde) per selezionarla: appaiono gli assi U(rosso) V(verde) N(blu=normale). Trascina un asse per muovere vincolato, o trascina la sfera per movimento libero nel piano.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Text("Crop centro")
                Slider(value: $model.projectionCrop, in: 0.3...1.0, step: 0.05)
                Text("\(Int(model.projectionCrop * 100))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .onChange(of: model.projectionCrop) { _ in
                model.rebuildProjectedPhotoClearingCache()
            }

            Toggle("Piano foto selezionata", isOn: $model.showPhotoPlane)
                .onChange(of: model.showPhotoPlane) { _ in model.rebuildPhotoPlane() }

            Toggle("OC texture originale", isOn: $model.showOriginalTexturedMesh)
                .onChange(of: model.showOriginalTexturedMesh) { _ in model.setOriginalTexturedMeshVisible(model.showOriginalTexturedMesh) }

            HStack {
                Text("Opacità OC")
                Slider(value: $model.ocTextureOpacity, in: 0.2...1.0, step: 0.02)
                Text("\(Int(model.ocTextureOpacity * 100))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .onChange(of: model.ocTextureOpacity) { _ in model.applyOriginalTexturedMeshAppearance() }

            Toggle("Mesh nuova", isOn: $model.showReferenceMesh)
                .onChange(of: model.showReferenceMesh) { _ in model.setReferenceMeshVisible(model.showReferenceMesh) }

            Toggle("Wire mesh nuova", isOn: $model.showReferenceWire)
                .onChange(of: model.showReferenceWire) { _ in model.applyReferenceMeshAppearance() }

            HStack {
                Text("Stride")
                Slider(value: $model.stride, in: 1...40, step: 1)
                Text("\(Int(model.stride))")
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
            .onChange(of: model.stride) { _ in model.rebuildCameras() }

            Picker("Foto", selection: $model.selectedShotID) {
                ForEach(model.shots) { shot in
                    Text(String(format: "%04d", shot.id)).tag(shot.id)
                }
            }
            .onChange(of: model.selectedShotID) { _ in
                model.rebuildCameras()
                model.rebuildPhotoPlane()
                model.rebuildProjectedPhoto()
            }

            HStack {
                Button("Inquadra scena") { model.frameScene() }
                Button("Vista camera") { model.viewFromSelectedCamera() }
            }
            Button("Inquadra foto selezionata") {
                model.viewFromSelectedCamera()
            }

            Divider()

            Toggle("Ispettore click", isOn: $model.inspectorEnabled)
            if !model.inspectorLines.isEmpty {
                Text(model.inspectorTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                ForEach(Array(model.inspectorLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(line.hasSuffix("vince") ? Color.primary : Color.secondary)
                }
            }

            Spacer()

            Text("Default: piani BCS in coordinate OC + pose/foto OC originali. Mesh OC usata come riferimento.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

final class EditableSCNView: SCNView {
    var onInspect: ((SIMD3<Float>, SIMD3<Float>) -> Void)?
    var onHandleBegin: ((String?) -> Void)?
    var onHandleDrag: ((CGFloat, CGFloat) -> Void)?
    var onAxisDrag: ((SIMD3<Float>) -> Void)?
    var onHandleEnd: (() -> Void)?
    var editing = false
    private var mode = 0  // 0 none, 1 free, 2 axis
    private var downPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var moved = false
    private var axisAnchor = SIMD3<Float>(repeating: 0)
    private var axisDir = SIMD3<Float>(0, 1, 0)

    override func mouseDown(with e: NSEvent) {
        downPoint = convert(e.locationInWindow, from: nil)
        lastPoint = downPoint
        moved = false
        mode = 0
        if editing {
            let hits = hitTest(downPoint, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            if let axis = hits.first(where: { $0.node.name?.hasPrefix("AXIS:") == true }) {
                let t = axis.node.presentation.simdWorldTransform
                axisAnchor = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                axisDir = simd_normalize(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z))
                mode = 2
                onHandleBegin?(axis.node.name)
                return
            }
            if let h = hits.first(where: { $0.node.name?.hasPrefix("EDIT:") == true }) {
                mode = 1
                onHandleBegin?(h.node.name)
                return
            }
        }
        super.mouseDown(with: e)
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch mode {
        case 1:
            onHandleDrag?(e.deltaX, e.deltaY)
        case 2:
            let a0 = projectPoint(SCNVector3(axisAnchor.x, axisAnchor.y, axisAnchor.z))
            let tip = axisAnchor + axisDir
            let a1 = projectPoint(SCNVector3(tip.x, tip.y, tip.z))
            let sx = Float(a1.x - a0.x), sy = Float(a1.y - a0.y)
            let slen = sqrt(sx * sx + sy * sy)
            if slen > 0.5 {
                let dxp = Float(p.x - lastPoint.x), dyp = Float(p.y - lastPoint.y)
                let along = (dxp * sx + dyp * sy) / slen
                onAxisDrag?(axisDir * (along / slen))
            }
            lastPoint = p
        default:
            moved = true
            super.mouseDragged(with: e)
        }
    }

    override func mouseUp(with e: NSEvent) {
        if mode != 0 {
            mode = 0
            onHandleEnd?()
            return
        }
        super.mouseUp(with: e)
        guard !moved else { return }
        let hits = hitTest(downPoint, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
        for hit in hits {
            if hit.node.geometry is SCNText { continue }
            if hit.node.name?.hasPrefix("EDIT:") == true || hit.node.name?.hasPrefix("AXIS:") == true { continue }
            let p = hit.worldCoordinates
            let n = hit.worldNormal
            onInspect?(SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)),
                       SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z)))
            return
        }
    }
}

struct NativeSceneView: NSViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode
    let cameraRevision: Int
    let editing: Bool
    let onClick: (SIMD3<Float>, SIMD3<Float>) -> Void
    let onHandleBegin: (String?) -> Void
    let onHandleDrag: (CGFloat, CGFloat) -> Void
    let onAxisDrag: (SIMD3<Float>) -> Void
    let onHandleEnd: () -> Void

    func makeNSView(context: Context) -> EditableSCNView {
        let view = EditableSCNView()
        view.scene = scene
        view.pointOfView = pointOfView
        view.allowsCameraControl = true
        view.rendersContinuously = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        view.autoenablesDefaultLighting = false
        apply(to: view)
        context.coordinator.lastRevision = cameraRevision
        return view
    }

    func updateNSView(_ view: EditableSCNView, context: Context) {
        if view.scene !== scene { view.scene = scene }
        if context.coordinator.lastRevision != cameraRevision {
            view.pointOfView = pointOfView
            context.coordinator.lastRevision = cameraRevision
        }
        apply(to: view)
    }

    private func apply(to view: EditableSCNView) {
        view.onInspect = onClick
        view.onHandleBegin = onHandleBegin
        view.onHandleDrag = onHandleDrag
        view.onAxisDrag = onAxisDrag
        view.onHandleEnd = onHandleEnd
        view.editing = editing
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var lastRevision = -1
    }
}

struct NativePoseMeshViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
    }
}

/// Runner headless: `NativePoseMeshViewer --headless --mesh piani.obj --poses oc.json
/// --photos dir --out dir [--res 8] [--crop 0.9] [--facing 0.34] [--max-photos 60]
/// [--occlusion]`. Riusa lo stesso bake della GUI (buildMosaic + rasterizzazione).
enum HeadlessRunner {
    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
        return nil
    }
    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    @MainActor
    static func run() {
        func need(_ n: String) -> URL {
            guard let v = arg(n) else { err("manca argomento \(n)"); exit(2) }
            return URL(fileURLWithPath: v)
        }
        let mesh = need("--mesh"), poses = need("--poses")
        let photos = need("--photos"), out = need("--out")
        let fullMesh = arg("--full-mesh").map { URL(fileURLWithPath: $0) }
        let resMM = Double(arg("--res") ?? "") ?? 8
        let crop = Double(arg("--crop") ?? "") ?? 0.9
        let facing = Double(arg("--facing") ?? "") ?? 0.34
        let maxP = Int(arg("--max-photos") ?? "") ?? 60
        let occ = CommandLine.arguments.contains("--occlusion")

        let model = ViewerModel()
        let ok = model.headlessBake(mesh: mesh, poses: poses, photos: photos, out: out,
                                    resMM: resMM, crop: crop, facing: facing,
                                    maxPhotos: maxP, occlusion: occ, fullMesh: fullMesh)
        err(model.bakeStatus)
        if let e = model.error { err("ERRORE: " + e) }
        exit(ok ? 0 : 1)
    }
}

// Entry point: headless da CLI, altrimenti la GUI.
if CommandLine.arguments.contains("--headless") {
    MainActor.assumeIsolated { HeadlessRunner.run() }
} else {
    NativePoseMeshViewerApp.main()
}

private extension SCNNode {
    func boundingBoxInWorld() -> (min: SCNVector3, max: SCNVector3, center: SCNVector3, size: SCNVector3) {
        var minV = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

        enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }
            let (localMin, localMax) = node.boundingBox
            for x in [localMin.x, localMax.x] {
                for y in [localMin.y, localMax.y] {
                    for z in [localMin.z, localMax.z] {
                        let p = node.convertPosition(SCNVector3(x, y, z), to: nil)
                        let point = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
                        minV = simd_min(minV, point)
                        maxV = simd_max(maxV, point)
                    }
                }
            }
        }

        if minV.x == Float.greatestFiniteMagnitude {
            minV = SIMD3<Float>(-1, -1, -1)
            maxV = SIMD3<Float>(1, 1, 1)
        }

        let center = (minV + maxV) / 2
        let size = maxV - minV
        return (
            SCNVector3(minV.x, minV.y, minV.z),
            SCNVector3(maxV.x, maxV.y, maxV.z),
            SCNVector3(center.x, center.y, center.z),
            SCNVector3(size.x, size.y, size.z)
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
