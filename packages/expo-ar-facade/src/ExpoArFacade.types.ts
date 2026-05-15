import type { ViewProps } from "react-native";

export interface WorldPoint { x: number; y: number; z: number; }

export interface ArTapEvent {
  screenX: number;
  screenY: number;
  worldPoint?: WorldPoint;
  normal?: WorldPoint;
  raycastTarget?: "existingPlaneGeometry" | "existingPlaneInfinite" | "estimatedPlane";
}

export interface ArPlaneEvent {
  id: string;
  alignment: "vertical" | "horizontal" | "unknown";
  center: WorldPoint;
  extent: { width: number; height: number };
  added: boolean;
}

export type ArTrackingState =
  | "normal" | "notAvailable"
  | "limited.initializing" | "limited.excessiveMotion"
  | "limited.insufficientFeatures" | "limited.relocalizing" | "limited.unknown";

export interface ArTrackingStateEvent { state: ArTrackingState; }
export interface ArSessionErrorEvent { message: string; }

export interface ArFacadeProgressEvent {
  areaMq: number;
  triangles: number;
  ready: boolean;
}

export interface ArFacadeCaptureResult extends ArFacadeProgressEvent {
  corners?: [WorldPoint, WorldPoint, WorldPoint, WorldPoint];
  bboxWidth?: number;
  bboxHeight?: number;
}

export interface FacadePlaneInfo {
  origin: WorldPoint;
  normal: WorldPoint;
}

export interface RectifiedOrthophoto {
  uri: string;
  width: number;
  height: number;
  /** Real-world width of the rectified rectangle (meters). */
  widthMeters: number;
  /** Real-world height of the rectified rectangle (meters). */
  heightMeters: number;
  /** Plane-frame (u, v) of the rectified rectangle's lower-left corner. */
  uOrigin: number;
  vOrigin: number;
}

export interface CapturedPhoto {
  ready: boolean;
  error?: string;
  uri?: string;
  width?: number;
  height?: number;
  /** Column-major 4x4 camera→world transform (16 floats). */
  transform?: number[];
  /** Column-major 3x3 intrinsics K = [[fx,0,0],[0,fy,0],[cx,cy,1]] (9 floats). */
  intrinsics?: number[];
  capturedAt?: number;
  /** Locked facade plane info (present only if a plane was locked when capturing). */
  facadePlane?: FacadePlaneInfo;
  /** Rectified ortophoto rendered onto the locked plane (present if rectification succeeded). */
  rectified?: RectifiedOrthophoto;
}

export interface FacadePlaneLockResult {
  ready: boolean;
  error?: string;
  origin?: WorldPoint;
  normal?: WorldPoint;
}

export interface ArRoomPlanResult {
  ready: boolean;
  error?: string;
  wallArea?: number;
  windowArea?: number;
  doorArea?: number;
  openingArea?: number;
  netArea?: number;
  width?: number;
  height?: number;
  walls?: number;
  windows?: number;
  doors?: number;
  openings?: number;
  corners?: [WorldPoint, WorldPoint, WorldPoint, WorldPoint];
}

export interface ExpoArFacadeViewProps extends ViewProps {
  showPlaneOverlay?: boolean;
  useLidarMesh?: boolean;
  showSceneMesh?: boolean;
  onTap?: (event: { nativeEvent: ArTapEvent }) => void;
  onPlaneDetected?: (event: { nativeEvent: ArPlaneEvent }) => void;
  onTrackingStateChange?: (event: { nativeEvent: ArTrackingStateEvent }) => void;
  onSessionError?: (event: { nativeEvent: ArSessionErrorEvent }) => void;
  onFacadeProgress?: (event: { nativeEvent: ArFacadeProgressEvent }) => void;
}

export interface ExpoArFacadeViewRef {
  resetSession(): Promise<void>;
  startAutoCapture(): Promise<boolean>;
  stopAutoCapture(): Promise<void>;
  captureFacadeAuto(): Promise<ArFacadeCaptureResult>;
  startRoomPlanCapture(): Promise<ArRoomPlanResult>;
  endRoomPlanCapture(): Promise<void>;
  capturePhoto(): Promise<CapturedPhoto>;
  lockFacadePlane(screenX: number, screenY: number): Promise<FacadePlaneLockResult>;
  unlockFacadePlane(): Promise<void>;
}

export interface ExpoArFacadeModuleApi {
  isSupported(): boolean;
  hasLidar(): boolean;
  isRoomPlanSupported(): boolean;
  requestAuthorization(): Promise<boolean>;
}
