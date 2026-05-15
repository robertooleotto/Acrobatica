import type { Point3D } from "../facade/scan3d";

/**
 * ARKit camera pose snapshot at the moment a photo was captured.
 * - `transform`: 16-float column-major homogeneous matrix (camera→world).
 * - `intrinsics`: 9-float column-major 3x3 intrinsics K = [[fx,0,0],[0,fy,0],[cx,cy,1]].
 * - `imageWidth/Height`: dimensions of the ARKit captured image (typically 1920x1440 landscape).
 */
export interface CameraPose {
  readonly transform: readonly number[];
  readonly intrinsics: readonly number[];
  readonly imageWidth: number;
  readonly imageHeight: number;
}

export interface Ray3D {
  readonly origin: Point3D;
  readonly direction: Point3D;
}

export interface Plane3D {
  /** A point known to lie on the plane (in world coordinates). */
  readonly origin: Point3D;
  /** Unit vector normal to the plane (in world coordinates). */
  readonly normal: Point3D;
}

/**
 * Build orthonormal in-plane axes (u, v) for a plane, with v aligned with world-up.
 * Returns null if the plane normal is parallel to world up (a horizontal plane).
 */
export function planeAxes(plane: Plane3D): { u: Point3D; v: Point3D } | null {
  const worldUp = { x: 0, y: 1, z: 0 };
  const dot = worldUp.x * plane.normal.x + worldUp.y * plane.normal.y + worldUp.z * plane.normal.z;
  const vRawX = worldUp.x - dot * plane.normal.x;
  const vRawY = worldUp.y - dot * plane.normal.y;
  const vRawZ = worldUp.z - dot * plane.normal.z;
  const vLen = Math.sqrt(vRawX * vRawX + vRawY * vRawY + vRawZ * vRawZ);
  if (vLen < 1e-4) return null;
  const v: Point3D = { x: vRawX / vLen, y: vRawY / vLen, z: vRawZ / vLen };
  // u = v × normal
  const uX = v.y * plane.normal.z - v.z * plane.normal.y;
  const uY = v.z * plane.normal.x - v.x * plane.normal.z;
  const uZ = v.x * plane.normal.y - v.y * plane.normal.x;
  const uLen = Math.sqrt(uX * uX + uY * uY + uZ * uZ);
  if (uLen < 1e-4) return null;
  const u: Point3D = { x: uX / uLen, y: uY / uLen, z: uZ / uLen };
  return { u, v };
}

/** Lift a 2D point (u, v) in the plane local frame to a 3D world point. */
export function planeUVToWorld(plane: Plane3D, axes: { u: Point3D; v: Point3D }, u: number, v: number): Point3D {
  return {
    x: plane.origin.x + u * axes.u.x + v * axes.v.x,
    y: plane.origin.y + u * axes.u.y + v * axes.v.y,
    z: plane.origin.z + u * axes.u.z + v * axes.v.z
  };
}

/**
 * Intersect a ray with a plane. Returns the 3D intersection point or null if the
 * ray is parallel to the plane / intersects behind the origin.
 */
export function rayPlaneIntersect(ray: Ray3D, plane: Plane3D): Point3D | null {
  const dn = ray.direction.x * plane.normal.x
    + ray.direction.y * plane.normal.y
    + ray.direction.z * plane.normal.z;
  if (Math.abs(dn) < 1e-6) return null;
  const ox = plane.origin.x - ray.origin.x;
  const oy = plane.origin.y - ray.origin.y;
  const oz = plane.origin.z - ray.origin.z;
  const t = (ox * plane.normal.x + oy * plane.normal.y + oz * plane.normal.z) / dn;
  if (t <= 0) return null;
  return {
    x: ray.origin.x + t * ray.direction.x,
    y: ray.origin.y + t * ray.direction.y,
    z: ray.origin.z + t * ray.direction.z
  };
}

/**
 * Build a unit world-space ray that exits the camera at the given pixel
 * in the ARKit captured-image coordinate system (origin top-left, +x right, +y down).
 */
export function rayFromPixel(pose: CameraPose, pixelX: number, pixelY: number): Ray3D {
  const K = pose.intrinsics;
  const fx = K[0]!, fy = K[4]!, cx = K[6]!, cy = K[7]!;
  // ARKit camera local frame: +x right, +y up, +z toward viewer.
  // Image y axis points down, so we flip it. The camera looks down -z.
  const dxCam = (pixelX - cx) / fx;
  const dyCam = -(pixelY - cy) / fy;
  const dzCam = -1;
  const len = Math.sqrt(dxCam * dxCam + dyCam * dyCam + dzCam * dzCam);
  const dx = dxCam / len, dy = dyCam / len, dz = dzCam / len;

  const T = pose.transform;
  // Camera-x axis in world = T column 0
  // Camera-y axis in world = T column 1
  // Camera-z axis in world = T column 2
  // Translation = T column 3
  const wx = T[0]! * dx + T[4]! * dy + T[8]! * dz;
  const wy = T[1]! * dx + T[5]! * dy + T[9]! * dz;
  const wz = T[2]! * dx + T[6]! * dy + T[10]! * dz;
  return {
    origin: { x: T[12]!, y: T[13]!, z: T[14]! },
    direction: { x: wx, y: wy, z: wz }
  };
}

/**
 * Triangulate the 3D point that best fits N rays (N >= 2) in a least-squares sense.
 * Minimises sum_i || (I - d_i d_i^T) (X - o_i) ||^2 with a normal-equation 3x3 solve.
 * Returns null if the rays are degenerate (parallel).
 */
export function triangulateRays(rays: readonly Ray3D[]): Point3D | null {
  if (rays.length < 2) return null;
  let a00 = 0, a01 = 0, a02 = 0, a11 = 0, a12 = 0, a22 = 0;
  let b0 = 0, b1 = 0, b2 = 0;
  for (const r of rays) {
    const dx = r.direction.x, dy = r.direction.y, dz = r.direction.z;
    const ox = r.origin.x, oy = r.origin.y, oz = r.origin.z;
    const m00 = 1 - dx * dx, m01 = -dx * dy, m02 = -dx * dz;
    const m11 = 1 - dy * dy, m12 = -dy * dz;
    const m22 = 1 - dz * dz;
    a00 += m00; a01 += m01; a02 += m02;
    a11 += m11; a12 += m12;
    a22 += m22;
    b0 += m00 * ox + m01 * oy + m02 * oz;
    b1 += m01 * ox + m11 * oy + m12 * oz;
    b2 += m02 * ox + m12 * oy + m22 * oz;
  }
  return solve3x3([[a00, a01, a02], [a01, a11, a12], [a02, a12, a22]], [b0, b1, b2]);
}

function solve3x3(A: readonly number[][], b: readonly number[]): Point3D | null {
  const a: number[][] = [A[0]!.slice(), A[1]!.slice(), A[2]!.slice()];
  const c: number[] = [b[0]!, b[1]!, b[2]!];
  const get = (i: number, j: number): number => a[i]![j]!;
  const set = (i: number, j: number, v: number): void => { a[i]![j] = v; };
  for (let i = 0; i < 3; i++) {
    let max = Math.abs(get(i, i));
    let maxRow = i;
    for (let k = i + 1; k < 3; k++) {
      const v = Math.abs(get(k, i));
      if (v > max) { max = v; maxRow = k; }
    }
    if (max < 1e-9) return null;
    if (maxRow !== i) {
      const tmp = a[i]!; a[i] = a[maxRow]!; a[maxRow] = tmp;
      const tc = c[i]!; c[i] = c[maxRow]!; c[maxRow] = tc;
    }
    for (let k = i + 1; k < 3; k++) {
      const factor = get(k, i) / get(i, i);
      for (let j = i; j < 3; j++) set(k, j, get(k, j) - factor * get(i, j));
      c[k] = c[k]! - factor * c[i]!;
    }
  }
  const x: number[] = [0, 0, 0];
  for (let i = 2; i >= 0; i--) {
    let s = c[i]!;
    for (let j = i + 1; j < 3; j++) s -= get(i, j) * x[j]!;
    x[i] = s / get(i, i);
  }
  return { x: x[0]!, y: x[1]!, z: x[2]! };
}

/**
 * Given N+ photos, pick the pair with the widest camera baseline (max distance
 * between camera origins). Returns indices [i, j] or null if fewer than 2 photos.
 */
export function widestBaselinePair(poses: readonly CameraPose[]): readonly [number, number] | null {
  if (poses.length < 2) return null;
  let bestI = 0, bestJ = 1, bestD2 = -1;
  for (let i = 0; i < poses.length; i++) {
    const ti = poses[i]!.transform;
    const xi = ti[12]!, yi = ti[13]!, zi = ti[14]!;
    for (let j = i + 1; j < poses.length; j++) {
      const tj = poses[j]!.transform;
      const dx = xi - tj[12]!, dy = yi - tj[13]!, dz = zi - tj[14]!;
      const d2 = dx * dx + dy * dy + dz * dz;
      if (d2 > bestD2) { bestD2 = d2; bestI = i; bestJ = j; }
    }
  }
  return [bestI, bestJ];
}
