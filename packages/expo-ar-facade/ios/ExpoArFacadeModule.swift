import ExpoModulesCore
import ARKit
import AVFoundation

public class ExpoArFacadeModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoArFacade")

    Function("isSupported") { () -> Bool in ARWorldTrackingConfiguration.isSupported }

    Function("hasLidar") { () -> Bool in
      if #available(iOS 13.4, *) {
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
      }
      return false
    }

    Function("isRoomPlanSupported") { () -> Bool in
      ExpoArFacadeView.isRoomPlanSupported()
    }

    AsyncFunction("requestAuthorization") { () async -> Bool in
      return await withCheckedContinuation { c in
        AVCaptureDevice.requestAccess(for: .video) { granted in c.resume(returning: granted) }
      }
    }

    View(ExpoArFacadeView.self) {
      Events("onTap", "onPlaneDetected", "onTrackingStateChange", "onSessionError", "onFacadeProgress")
      Prop("showPlaneOverlay") { (v: ExpoArFacadeView, s: Bool) in v.showPlaneOverlay = s }
      Prop("useLidarMesh") { (v: ExpoArFacadeView, s: Bool) in v.useLidarMesh = s }
      Prop("showSceneMesh") { (v: ExpoArFacadeView, s: Bool) in v.showSceneMesh = s }
      AsyncFunction("resetSession") { (v: ExpoArFacadeView) in v.resetSession() }
      AsyncFunction("startAutoCapture") { (v: ExpoArFacadeView) -> Bool in v.startAutoCapture() }
      AsyncFunction("stopAutoCapture") { (v: ExpoArFacadeView) in v.stopAutoCapture() }
      AsyncFunction("captureFacadeAuto") { (v: ExpoArFacadeView) -> [String: Any] in v.captureFacadeAuto() }
      AsyncFunction("startRoomPlanCapture") { (v: ExpoArFacadeView, promise: Promise) in
        Task { @MainActor in
          let r = await v.startRoomPlanCapture()
          promise.resolve(r)
        }
      }
      AsyncFunction("endRoomPlanCapture") { (v: ExpoArFacadeView) in v.endRoomPlanCapture() }
      AsyncFunction("capturePhoto") { (v: ExpoArFacadeView, promise: Promise) in
        Task { @MainActor in
          let r = await v.capturePhoto()
          promise.resolve(r)
        }
      }
      AsyncFunction("lockFacadePlane") { (v: ExpoArFacadeView, screenX: Double, screenY: Double) -> [String: Any] in
        v.lockFacadePlane(screenX: screenX, screenY: screenY)
      }
      AsyncFunction("unlockFacadePlane") { (v: ExpoArFacadeView) in v.unlockFacadePlane() }
    }
  }
}
