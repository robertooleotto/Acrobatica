import ExpoModulesCore
import ARKit
import RealityKit
import RoomPlan
import UIKit
import simd

private extension ARGeometrySource {
  func value3f(at index: Int) -> SIMD3<Float> {
    let p = buffer.contents()
      .advanced(by: offset + stride * index)
      .assumingMemoryBound(to: Float.self)
    return SIMD3<Float>(p[0], p[1], p[2])
  }
}

private extension ARMeshGeometry {
  func faceVertexIndices(_ face: Int) -> (UInt32, UInt32, UInt32) {
    let base = faces.buffer.contents().advanced(by: faces.bytesPerIndex * 3 * face)
    let i0 = base.assumingMemoryBound(to: UInt32.self).pointee
    let i1 = base.advanced(by: faces.bytesPerIndex).assumingMemoryBound(to: UInt32.self).pointee
    let i2 = base.advanced(by: faces.bytesPerIndex * 2).assumingMemoryBound(to: UInt32.self).pointee
    return (i0, i1, i2)
  }
  func faceClassification(_ face: Int) -> ARMeshClassification {
    guard let cls = classification else { return .none }
    let ptr = cls.buffer.contents().advanced(by: cls.offset + cls.stride * face)
    let raw = ptr.assumingMemoryBound(to: UInt8.self).pointee
    return ARMeshClassification(rawValue: Int(raw)) ?? .none
  }
}

public class ExpoArFacadeView: ExpoView, ARSessionDelegate {
  let onTap = EventDispatcher()
  let onPlaneDetected = EventDispatcher()
  let onTrackingStateChange = EventDispatcher()
  let onSessionError = EventDispatcher()
  let onFacadeProgress = EventDispatcher()

  private let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
  private let planeAnchors: NSMapTable<NSString, AnchorEntity> = NSMapTable.strongToStrongObjects()
  private var meshAnchors: [UUID: ARMeshAnchor] = [:]
  private var captureActive: Bool = false
  private var facadeNormalWorld: SIMD3<Float>? = nil
  private var lastEmitTime: TimeInterval = 0

  // RoomPlan state
  private var roomCaptureView: RoomCaptureView?
  private var roomCaptureContinuation: CheckedContinuation<[String: Any], Never>?

  // Locked facade plane (origin + outward normal in world coords)
  private var lockedFacadePlane: (origin: SIMD3<Float>, normal: SIMD3<Float>)? = nil

  public var showPlaneOverlay: Bool = true { didSet { updateOverlayVisibility() } }
  public var useLidarMesh: Bool = true { didSet { restartSessionIfRunning() } }
  public var showSceneMesh: Bool = false { didSet { updateSceneMeshDebug() } }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupView()
    startSession()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  private func setupView() {
    arView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(arView)
    NSLayoutConstraint.activate([
      arView.topAnchor.constraint(equalTo: topAnchor),
      arView.leadingAnchor.constraint(equalTo: leadingAnchor),
      arView.trailingAnchor.constraint(equalTo: trailingAnchor),
      arView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    arView.addGestureRecognizer(tap)
    arView.session.delegate = self
  }

  private func startSession() {
    guard ARWorldTrackingConfiguration.isSupported else {
      onSessionError(["message": "ARKit non supportato."])
      return
    }
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.vertical, .horizontal]
    config.environmentTexturing = .none
    if useLidarMesh {
      if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
        config.sceneReconstruction = .meshWithClassification
      } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
        config.sceneReconstruction = .mesh
      }
      if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
        config.frameSemantics.insert(.sceneDepth)
      }
    }
    arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
  }

  private func restartSessionIfRunning() { arView.session.pause(); startSession() }
  public func resetSession() {
    planeAnchors.removeAllObjects()
    meshAnchors.removeAll()
    captureActive = false
    facadeNormalWorld = nil
    restartSessionIfRunning()
  }

  // MARK: - Auto facade capture

  public func startAutoCapture() -> Bool {
    guard let frame = arView.session.currentFrame else { return false }
    let xf = frame.camera.transform
    let forward = -SIMD3<Float>(xf.columns.2.x, xf.columns.2.y, xf.columns.2.z)
    var n = -forward
    n.y = 0
    if simd_length(n) < 0.01 { return false }
    facadeNormalWorld = simd_normalize(n)
    captureActive = true
    lastEmitTime = 0
    return true
  }

  public func stopAutoCapture() { captureActive = false }

  public func captureFacadeAuto() -> [String: Any] {
    let r = computeFacadeStats(buildCorners: true)
    captureActive = false
    return r
  }

  private func computeFacadeStats(buildCorners: Bool = false) -> [String: Any] {
    guard let n = facadeNormalWorld else {
      return ["areaMq": 0.0, "triangles": 0, "ready": false]
    }
    let upDotMax: Float = 0.50       // sin(30°): allow ±30° tilt from vertical
    let facadeDotMin: Float = 0.64   // cos(50°): align with chosen facade normal within ±50°
    var totalArea: Float = 0
    var triCount: Int = 0
    var verts: [SIMD3<Float>] = []
    if buildCorners { verts.reserveCapacity(2048) }

    for anchor in meshAnchors.values {
      let geom = anchor.geometry
      let xf = anchor.transform
      let R = simd_float3x3(
        SIMD3<Float>(xf.columns.0.x, xf.columns.0.y, xf.columns.0.z),
        SIMD3<Float>(xf.columns.1.x, xf.columns.1.y, xf.columns.1.z),
        SIMD3<Float>(xf.columns.2.x, xf.columns.2.y, xf.columns.2.z)
      )
      let t = SIMD3<Float>(xf.columns.3.x, xf.columns.3.y, xf.columns.3.z)
      let hasClassification = geom.classification != nil
      let faceCount = geom.faces.count
      for f in 0..<faceCount {
        if hasClassification {
          let cls = geom.faceClassification(f)
          // Accept .wall and .none (often slow to classify). Reject explicit floor/ceiling/seat/table/window/door.
          if cls != .wall && cls != .none { continue }
        }
        let (i0, i1, i2) = geom.faceVertexIndices(f)
        let p0 = R * geom.vertices.value3f(at: Int(i0)) + t
        let p1 = R * geom.vertices.value3f(at: Int(i1)) + t
        let p2 = R * geom.vertices.value3f(at: Int(i2)) + t
        let e1 = p1 - p0
        let e2 = p2 - p0
        let crossV = simd_cross(e1, e2)
        let len = simd_length(crossV)
        if len < 1e-6 { continue }
        let nrm = crossV / len
        if abs(nrm.y) > upDotMax { continue }
        if abs(simd_dot(nrm, n)) < facadeDotMin { continue }
        totalArea += 0.5 * len
        triCount += 1
        if buildCorners {
          verts.append(p0); verts.append(p1); verts.append(p2)
        }
      }
    }

    var out: [String: Any] = [
      "areaMq": Double(totalArea),
      "triangles": triCount,
      "ready": triCount > 0
    ]

    if buildCorners && !verts.isEmpty {
      let worldUp = SIMD3<Float>(0, 1, 0)
      let u = simd_normalize(simd_cross(worldUp, n))
      let v = worldUp
      var centroid = SIMD3<Float>(0,0,0)
      for p in verts { centroid += p }
      centroid /= Float(verts.count)
      var uMin: Float = .infinity, uMax: Float = -.infinity
      var vMin: Float = .infinity, vMax: Float = -.infinity
      for p in verts {
        let d = p - centroid
        let cu = simd_dot(d, u)
        let cv = simd_dot(d, v)
        if cu < uMin { uMin = cu }
        if cu > uMax { uMax = cu }
        if cv < vMin { vMin = cv }
        if cv > vMax { vMax = cv }
      }
      let tl = centroid + uMin*u + vMax*v
      let tr = centroid + uMax*u + vMax*v
      let br = centroid + uMax*u + vMin*v
      let bl = centroid + uMin*u + vMin*v
      out["corners"] = [
        ["x": Double(tl.x), "y": Double(tl.y), "z": Double(tl.z)],
        ["x": Double(tr.x), "y": Double(tr.y), "z": Double(tr.z)],
        ["x": Double(br.x), "y": Double(br.y), "z": Double(br.z)],
        ["x": Double(bl.x), "y": Double(bl.y), "z": Double(bl.z)]
      ]
      out["bboxWidth"] = Double(uMax - uMin)
      out["bboxHeight"] = Double(vMax - vMin)
    }
    return out
  }

  // MARK: - Tap (manual mode)

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    let p = gesture.location(in: arView)
    var payload: [String: Any] = ["screenX": p.x, "screenY": p.y]
    let queries: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .existingPlaneInfinite, .estimatedPlane]
    var hit: ARRaycastResult?
    for target in queries {
      if let q = arView.makeRaycastQuery(from: p, allowing: target, alignment: .any),
         let r = arView.session.raycast(q).first {
        hit = r
        payload["raycastTarget"] = String(describing: target)
        break
      }
    }
    if let h = hit {
      let t = h.worldTransform.columns.3
      payload["worldPoint"] = ["x": Double(t.x), "y": Double(t.y), "z": Double(t.z)]
      let n = h.worldTransform.columns.2
      payload["normal"] = ["x": Double(n.x), "y": Double(n.y), "z": Double(n.z)]
    }
    onTap(payload)
  }

  // MARK: - ARSession delegate

  public func session(_ s: ARSession, didAdd anchors: [ARAnchor]) {
    for a in anchors {
      if let plane = a as? ARPlaneAnchor {
        emitPlane(plane, added: true)
        if showPlaneOverlay { addOverlay(for: plane) }
      } else if let m = a as? ARMeshAnchor {
        meshAnchors[m.identifier] = m
      }
    }
  }

  public func session(_ s: ARSession, didUpdate anchors: [ARAnchor]) {
    for a in anchors {
      if let plane = a as? ARPlaneAnchor, showPlaneOverlay { updateOverlay(for: plane) }
      else if let m = a as? ARMeshAnchor { meshAnchors[m.identifier] = m }
    }
  }

  public func session(_ s: ARSession, didRemove anchors: [ARAnchor]) {
    for a in anchors {
      if let m = a as? ARMeshAnchor { meshAnchors.removeValue(forKey: m.identifier) }
    }
  }

  public func session(_ s: ARSession, didUpdate frame: ARFrame) {
    guard captureActive else { return }
    let t = frame.timestamp
    if t - lastEmitTime >= 0.2 {
      lastEmitTime = t
      onFacadeProgress(computeFacadeStats())
    }
  }

  public func session(_ s: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    let state: String
    switch camera.trackingState {
    case .normal: state = "normal"
    case .notAvailable: state = "notAvailable"
    case .limited(let reason):
      switch reason {
      case .initializing: state = "limited.initializing"
      case .excessiveMotion: state = "limited.excessiveMotion"
      case .insufficientFeatures: state = "limited.insufficientFeatures"
      case .relocalizing: state = "limited.relocalizing"
      @unknown default: state = "limited.unknown"
      }
    }
    onTrackingStateChange(["state": state])
  }

  public func session(_ s: ARSession, didFailWithError error: Error) {
    onSessionError(["message": error.localizedDescription])
  }

  private func emitPlane(_ plane: ARPlaneAnchor, added: Bool) {
    let c = plane.center, e = plane.planeExtent
    let alignment: String = plane.alignment == .vertical ? "vertical" : "horizontal"
    onPlaneDetected([
      "id": plane.identifier.uuidString,
      "alignment": alignment,
      "center": ["x": Double(c.x), "y": Double(c.y), "z": Double(c.z)],
      "extent": ["width": Double(e.width), "height": Double(e.height)],
      "added": added
    ])
  }

  private func addOverlay(for plane: ARPlaneAnchor) {
    let mesh = MeshResource.generatePlane(width: plane.planeExtent.width, depth: plane.planeExtent.height)
    let mat = SimpleMaterial(
      color: plane.alignment == .vertical
        ? UIColor.systemGreen.withAlphaComponent(0.25)
        : UIColor.systemBlue.withAlphaComponent(0.15),
      isMetallic: false
    )
    let modelEntity = ModelEntity(mesh: mesh, materials: [mat])
    let anchor = AnchorEntity(anchor: plane)
    anchor.addChild(modelEntity)
    arView.scene.addAnchor(anchor)
    planeAnchors.setObject(anchor, forKey: plane.identifier.uuidString as NSString)
  }

  private func updateOverlay(for plane: ARPlaneAnchor) {
    guard let anchor = planeAnchors.object(forKey: plane.identifier.uuidString as NSString),
          let model = anchor.children.first as? ModelEntity else { return }
    model.model?.mesh = MeshResource.generatePlane(width: plane.planeExtent.width, depth: plane.planeExtent.height)
    model.position = SIMD3<Float>(plane.center.x, 0, plane.center.z)
  }

  private func updateOverlayVisibility() {
    let e = planeAnchors.objectEnumerator()
    while let anchor = e?.nextObject() as? AnchorEntity { anchor.isEnabled = showPlaneOverlay }
  }

  private func updateSceneMeshDebug() {
    if showSceneMesh {
      arView.debugOptions.insert(.showSceneUnderstanding)
    } else {
      arView.debugOptions.remove(.showSceneUnderstanding)
    }
  }

  // MARK: - RoomPlan (Pro mode)

  public static func isRoomPlanSupported() -> Bool {
    if #available(iOS 16, *) { return RoomCaptureSession.isSupported }
    return false
  }

  public func startRoomPlanCapture() async -> [String: Any] {
    guard #available(iOS 16, *), RoomCaptureSession.isSupported else {
      return ["error": "RoomPlan non supportato su questo dispositivo"]
    }
    return await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
      roomCaptureContinuation = c
      DispatchQueue.main.async { [weak self] in self?.presentRoomCaptureView() }
    }
  }

  public func endRoomPlanCapture() {
    if #available(iOS 16, *) {
      roomCaptureView?.captureSession.stop()
    }
  }

  // MARK: - Photo capture with ARKit pose

  // MARK: - Facade plane lock

  public func lockFacadePlane(screenX: Double, screenY: Double) -> [String: Any] {
    let p = CGPoint(x: screenX, y: screenY)
    let queries: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .existingPlaneInfinite, .estimatedPlane]
    var hit: ARRaycastResult? = nil
    for target in queries {
      if let q = arView.makeRaycastQuery(from: p, allowing: target, alignment: .vertical),
         let r = arView.session.raycast(q).first {
        hit = r
        break
      }
    }
    guard let r = hit else {
      return ["ready": false, "error": "Nessun piano verticale rilevato sotto il dito"]
    }
    let xf = r.worldTransform
    let origin = SIMD3<Float>(xf.columns.3.x, xf.columns.3.y, xf.columns.3.z)
    // For ARRaycastResult on vertical alignment, the y-axis of the transform is the surface normal.
    // (ARKit convention for plane anchors: y axis = up vector of the plane geometry; for vertical
    // planes "up" is the outward normal.)
    var n = SIMD3<Float>(xf.columns.1.x, xf.columns.1.y, xf.columns.1.z)
    n = simd_normalize(n)
    // Make sure normal points toward the camera (so dot(normal, -cameraForward) > 0).
    if let frame = arView.session.currentFrame {
      let cam = frame.camera.transform
      let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
      if simd_dot(camPos - origin, n) < 0 {
        n = -n
      }
    }
    lockedFacadePlane = (origin: origin, normal: n)
    return [
      "ready": true,
      "origin": ["x": Double(origin.x), "y": Double(origin.y), "z": Double(origin.z)],
      "normal": ["x": Double(n.x), "y": Double(n.y), "z": Double(n.z)]
    ]
  }

  public func unlockFacadePlane() {
    lockedFacadePlane = nil
  }

  public func capturePhoto() async -> [String: Any] {
    guard let frame = arView.session.currentFrame else {
      return ["ready": false, "error": "ARKit non attivo"]
    }
    let pixelBuffer = frame.capturedImage
    let camera = frame.camera

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext(options: nil)
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      return ["ready": false, "error": "Conversione immagine fallita"]
    }
    // ARKit captures landscape (sensor-native). Tag the JPEG with EXIF orientation 6
    // (rotate 90° CW for display) so consumers see it portrait without re-encoding.
    let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    guard let jpegData = uiImage.jpegData(compressionQuality: 0.85) else {
      return ["ready": false, "error": "Encoding JPEG fallito"]
    }

    let filename = "photo_\(UUID().uuidString.prefix(8)).jpg"
    let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let url = docsURL.appendingPathComponent(filename)
    do {
      try jpegData.write(to: url)
    } catch {
      return ["ready": false, "error": "Salvataggio fallito: \(error.localizedDescription)"]
    }

    let w = CVPixelBufferGetWidth(pixelBuffer)
    let h = CVPixelBufferGetHeight(pixelBuffer)
    let T = camera.transform
    let K = camera.intrinsics

    let transform: [Double] = [
      Double(T.columns.0.x), Double(T.columns.0.y), Double(T.columns.0.z), Double(T.columns.0.w),
      Double(T.columns.1.x), Double(T.columns.1.y), Double(T.columns.1.z), Double(T.columns.1.w),
      Double(T.columns.2.x), Double(T.columns.2.y), Double(T.columns.2.z), Double(T.columns.2.w),
      Double(T.columns.3.x), Double(T.columns.3.y), Double(T.columns.3.z), Double(T.columns.3.w)
    ]
    let intrinsics: [Double] = [
      Double(K.columns.0.x), Double(K.columns.0.y), Double(K.columns.0.z),
      Double(K.columns.1.x), Double(K.columns.1.y), Double(K.columns.1.z),
      Double(K.columns.2.x), Double(K.columns.2.y), Double(K.columns.2.z)
    ]

    var payload: [String: Any] = [
      "ready": true,
      "uri": url.absoluteString,
      "width": w,
      "height": h,
      "transform": transform,
      "intrinsics": intrinsics,
      "capturedAt": Date().timeIntervalSince1970 * 1000
    ]
    if let plane = lockedFacadePlane {
      payload["facadePlane"] = [
        "origin": ["x": Double(plane.origin.x), "y": Double(plane.origin.y), "z": Double(plane.origin.z)],
        "normal": ["x": Double(plane.normal.x), "y": Double(plane.normal.y), "z": Double(plane.normal.z)]
      ]
      // Try to generate a rectified ortophoto of the facade plane visible in this frame.
      if let recti = rectifyOntoFacadePlane(
        ciImage: ciImage, context: context, plane: plane, camera: camera,
        imageWidth: w, imageHeight: h, docsURL: docsURL
      ) {
        payload["rectified"] = recti
      }
    }
    return payload
  }

  private func rectifyOntoFacadePlane(
    ciImage: CIImage, context: CIContext,
    plane: (origin: SIMD3<Float>, normal: SIMD3<Float>),
    camera: ARCamera, imageWidth w: Int, imageHeight h: Int,
    docsURL: URL
  ) -> [String: Any]? {
    let T = camera.transform
    let K = camera.intrinsics
    let camPos = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
    let R = simd_float3x3(
      SIMD3<Float>(T.columns.0.x, T.columns.0.y, T.columns.0.z),
      SIMD3<Float>(T.columns.1.x, T.columns.1.y, T.columns.1.z),
      SIMD3<Float>(T.columns.2.x, T.columns.2.y, T.columns.2.z)
    )
    let Rt = R.transpose
    let fx = K.columns.0.x, fy = K.columns.1.y
    let cx = K.columns.2.x, cy = K.columns.2.y

    // Plane local frame: v_axis = world-up projected onto plane (vertical), u_axis = v × normal.
    let worldUp = SIMD3<Float>(0, 1, 0)
    let vRaw = worldUp - simd_dot(worldUp, plane.normal) * plane.normal
    if simd_length(vRaw) < 1e-4 { return nil }
    let vAxis = simd_normalize(vRaw)
    let uAxis = simd_normalize(simd_cross(vAxis, plane.normal))

    // For each of the 4 image corners (in ARKit image coords with origin top-left, +y down),
    // shoot a ray and intersect with the plane, then express the hit in (u, v) on the plane.
    let imageCorners: [(x: Float, y: Float)] = [
      (0, 0), (Float(w), 0), (Float(w), Float(h)), (0, Float(h))
    ]
    var uvs: [(u: Float, v: Float)] = []
    for c in imageCorners {
      let dx = (c.x - cx) / fx
      let dy = -(c.y - cy) / fy
      let dz: Float = -1
      var dCam = SIMD3<Float>(dx, dy, dz)
      dCam = simd_normalize(dCam)
      let dWorld = R * dCam
      let denom = simd_dot(dWorld, plane.normal)
      if abs(denom) < 1e-4 { return nil }
      let t = simd_dot(plane.origin - camPos, plane.normal) / denom
      if t <= 0 { return nil }
      let P = camPos + t * dWorld
      let delta = P - plane.origin
      uvs.append((u: simd_dot(delta, uAxis), v: simd_dot(delta, vAxis)))
    }
    let umin = uvs.map { $0.u }.min()!
    let umax = uvs.map { $0.u }.max()!
    let vmin = uvs.map { $0.v }.min()!
    let vmax = uvs.map { $0.v }.max()!
    let widthM = umax - umin
    let heightM = vmax - vmin
    if widthM < 0.05 || heightM < 0.05 { return nil }
    if widthM > 100 || heightM > 100 { return nil } // sanity bounds

    // Pick output resolution: 300 px/m, capped at 2400 max dimension.
    let pxPerM: Float = min(300, 2400 / max(widthM, heightM))
    let outW = max(1, Int(widthM * pxPerM))
    let outH = max(1, Int(heightM * pxPerM))

    // The 4 corners of the output rectangle (in plane uv-meters) project back to 4 pixels
    // in the source image. Pass those 4 pixels to CIPerspectiveCorrection.
    let cornersUV: [(u: Float, v: Float)] = [
      (umin, vmax), // TL of output
      (umax, vmax), // TR
      (umax, vmin), // BR
      (umin, vmin)  // BL
    ]
    var inputPixels: [CGPoint] = []
    for c in cornersUV {
      let P = plane.origin + c.u * uAxis + c.v * vAxis
      let cCam = Rt * (P - camPos)
      if cCam.z >= -1e-4 { return nil } // behind camera
      let px = fx * cCam.x / -cCam.z + cx
      let py = fy * (-cCam.y) / -cCam.z + cy
      // Convert to CIImage coords (origin bottom-left, y up).
      let ciY = Float(h) - py
      inputPixels.append(CGPoint(x: CGFloat(px), y: CGFloat(ciY)))
    }

    guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgPoint: inputPixels[0]), forKey: "inputTopLeft")
    filter.setValue(CIVector(cgPoint: inputPixels[1]), forKey: "inputTopRight")
    filter.setValue(CIVector(cgPoint: inputPixels[2]), forKey: "inputBottomRight")
    filter.setValue(CIVector(cgPoint: inputPixels[3]), forKey: "inputBottomLeft")
    guard let warped = filter.outputImage else { return nil }
    // Scale the warped image to the desired output resolution.
    let extent = warped.extent
    if extent.width <= 0 || extent.height <= 0 { return nil }
    let sx = CGFloat(outW) / extent.width
    let sy = CGFloat(outH) / extent.height
    let scaled = warped.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    let cropped = scaled.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))

    guard let outCG = context.createCGImage(cropped, from: cropped.extent) else { return nil }
    let outUI = UIImage(cgImage: outCG)
    guard let outData = outUI.jpegData(compressionQuality: 0.85) else { return nil }
    let outName = "rect_\(UUID().uuidString.prefix(8)).jpg"
    let outURL = docsURL.appendingPathComponent(outName)
    do { try outData.write(to: outURL) } catch { return nil }

    return [
      "uri": outURL.absoluteString,
      "width": outW,
      "height": outH,
      "widthMeters": Double(widthM),
      "heightMeters": Double(heightM),
      "uOrigin": Double(umin),
      "vOrigin": Double(vmin)
    ]
  }

  @available(iOS 16, *)
  private func presentRoomCaptureView() {
    arView.session.pause()
    arView.isHidden = true
    let rcv = RoomCaptureView(frame: bounds)
    rcv.translatesAutoresizingMaskIntoConstraints = false
    rcv.delegate = self
    addSubview(rcv)
    NSLayoutConstraint.activate([
      rcv.topAnchor.constraint(equalTo: topAnchor),
      rcv.leadingAnchor.constraint(equalTo: leadingAnchor),
      rcv.trailingAnchor.constraint(equalTo: trailingAnchor),
      rcv.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    let config = RoomCaptureSession.Configuration()
    rcv.captureSession.run(configuration: config)
    roomCaptureView = rcv
  }

  @available(iOS 16, *)
  private func dismissRoomCaptureView() {
    roomCaptureView?.captureSession.stop()
    roomCaptureView?.removeFromSuperview()
    roomCaptureView = nil
    arView.isHidden = false
    startSession()
  }

  @available(iOS 16, *)
  fileprivate func finishRoomPlan(_ result: [String: Any]) {
    let c = roomCaptureContinuation
    roomCaptureContinuation = nil
    dismissRoomCaptureView()
    c?.resume(returning: result)
  }

  @available(iOS 16, *)
  fileprivate func extractFacade(from room: CapturedRoom) -> [String: Any] {
    guard let largest = room.walls.max(by: {
      ($0.dimensions.x * $0.dimensions.y) < ($1.dimensions.x * $1.dimensions.y)
    }) else {
      return ["ready": false, "error": "Nessun muro rilevato"]
    }
    let w = largest.dimensions.x
    let h = largest.dimensions.y
    let wallArea = w * h

    // Only count windows/doors that lie roughly on the same plane as the largest wall.
    let wallCenter = SIMD3<Float>(
      largest.transform.columns.3.x,
      largest.transform.columns.3.y,
      largest.transform.columns.3.z
    )
    let wallNormal = simd_normalize(SIMD3<Float>(
      largest.transform.columns.2.x,
      largest.transform.columns.2.y,
      largest.transform.columns.2.z
    ))
    let coplanarTol: Float = 0.4 // meters of allowed offset along normal

    func coplanar(_ surface: CapturedRoom.Surface) -> Bool {
      let c = SIMD3<Float>(
        surface.transform.columns.3.x,
        surface.transform.columns.3.y,
        surface.transform.columns.3.z
      )
      return abs(simd_dot(c - wallCenter, wallNormal)) < coplanarTol
    }

    let windows = room.windows.filter(coplanar)
    let doors = room.doors.filter(coplanar)
    let openings = room.openings.filter(coplanar)

    let windowArea = windows.reduce(Float(0)) { $0 + $1.dimensions.x * $1.dimensions.y }
    let doorArea = doors.reduce(Float(0)) { $0 + $1.dimensions.x * $1.dimensions.y }
    let openingArea = openings.reduce(Float(0)) { $0 + $1.dimensions.x * $1.dimensions.y }
    let excludedArea = windowArea + doorArea + openingArea
    let netArea = max(wallArea - excludedArea, 0)

    // 4 corners of the wall in world space
    let xf = largest.transform
    let halfW = w / 2
    let halfH = h / 2
    let local: [SIMD4<Float>] = [
      SIMD4<Float>(-halfW,  halfH, 0, 1),
      SIMD4<Float>( halfW,  halfH, 0, 1),
      SIMD4<Float>( halfW, -halfH, 0, 1),
      SIMD4<Float>(-halfW, -halfH, 0, 1)
    ]
    let corners: [[String: Double]] = local.map { p in
      let w4 = xf * p
      return ["x": Double(w4.x), "y": Double(w4.y), "z": Double(w4.z)]
    }

    return [
      "ready": true,
      "wallArea": Double(wallArea),
      "windowArea": Double(windowArea),
      "doorArea": Double(doorArea),
      "openingArea": Double(openingArea),
      "netArea": Double(netArea),
      "width": Double(w),
      "height": Double(h),
      "walls": room.walls.count,
      "windows": windows.count,
      "doors": doors.count,
      "openings": openings.count,
      "corners": corners
    ]
  }
}

@available(iOS 16, *)
extension ExpoArFacadeView: RoomCaptureViewDelegate {
  public func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
    return error == nil
  }

  public func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    if let e = error {
      finishRoomPlan(["ready": false, "error": e.localizedDescription])
      return
    }
    finishRoomPlan(extractFacade(from: processedResult))
  }
}
