import { describe, it, expect } from "vitest";
import {
  rayFromPixel,
  rayPlaneIntersect,
  triangulateRays,
  widestBaselinePair,
  type CameraPose,
  type Plane3D,
  type Ray3D
} from "./triangulate";

/**
 * Build a camera pose where the camera is at world `position` looking down -Z in
 * its local frame, aligned with world axes (so camera-x = world-x, y = y, z = z).
 * Intrinsics use a simple pinhole with fx = fy = 1500, cx = cy = image center.
 */
function poseLookingForward(position: { x: number; y: number; z: number }, fx = 1500, w = 1920, h = 1440): CameraPose {
  // ARKit camera transform is camera→world, with camera local +z toward viewer.
  // We want the camera looking along world -z, so camera-z axis in world = +z.
  // Camera-x = +x, camera-y = +y.
  return {
    transform: [
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      position.x, position.y, position.z, 1
    ],
    intrinsics: [
      fx, 0, 0,
      0, fx, 0,
      w / 2, h / 2, 1
    ],
    imageWidth: w,
    imageHeight: h
  };
}

describe("rayFromPixel", () => {
  it("returns a ray pointing along -Z when sampling the principal point", () => {
    const pose = poseLookingForward({ x: 0, y: 0, z: 0 });
    const r = rayFromPixel(pose, pose.imageWidth / 2, pose.imageHeight / 2);
    expect(r.origin).toEqual({ x: 0, y: 0, z: 0 });
    expect(r.direction.x).toBeCloseTo(0, 6);
    expect(r.direction.y).toBeCloseTo(0, 6);
    expect(r.direction.z).toBeCloseTo(-1, 6);
  });

  it("returns a ray bending +x when sampling a pixel right of centre", () => {
    const pose = poseLookingForward({ x: 0, y: 0, z: 0 }, 1500);
    const r = rayFromPixel(pose, pose.imageWidth / 2 + 300, pose.imageHeight / 2);
    expect(r.direction.x).toBeGreaterThan(0);
    expect(r.direction.z).toBeLessThan(0);
    expect(r.direction.y).toBeCloseTo(0, 6);
  });
});

describe("triangulateRays", () => {
  it("recovers a 3D point from two intersecting rays", () => {
    // Target world point.
    const target = { x: 1, y: 2, z: -5 };
    // Two cameras at different positions, both looking forward.
    const poseA = poseLookingForward({ x: 0, y: 0, z: 0 });
    const poseB = poseLookingForward({ x: 3, y: 0, z: 0 });
    // Project target into each camera's image plane.
    const project = (pose: CameraPose) => {
      const Tx = pose.transform[12]!, Ty = pose.transform[13]!, Tz = pose.transform[14]!;
      const dxCam = target.x - Tx;
      const dyCam = target.y - Ty;
      const dzCam = target.z - Tz; // negative since target is in front
      const fx = pose.intrinsics[0]!, fy = pose.intrinsics[4]!;
      const cx = pose.intrinsics[6]!, cy = pose.intrinsics[7]!;
      // Pinhole: u = cx + fx * (dx / -dz), v = cy - fy * (dy / -dz)
      const u = cx + fx * (dxCam / -dzCam);
      const v = cy - fy * (dyCam / -dzCam);
      return { u, v };
    };
    const pa = project(poseA);
    const pb = project(poseB);
    const ra = rayFromPixel(poseA, pa.u, pa.v);
    const rb = rayFromPixel(poseB, pb.u, pb.v);
    const result = triangulateRays([ra, rb]);
    expect(result).not.toBeNull();
    expect(result!.x).toBeCloseTo(target.x, 4);
    expect(result!.y).toBeCloseTo(target.y, 4);
    expect(result!.z).toBeCloseTo(target.z, 4);
  });

  it("returns null when given fewer than 2 rays", () => {
    const ray: Ray3D = { origin: { x: 0, y: 0, z: 0 }, direction: { x: 0, y: 0, z: -1 } };
    expect(triangulateRays([])).toBeNull();
    expect(triangulateRays([ray])).toBeNull();
  });
});

describe("rayPlaneIntersect", () => {
  it("intersects a forward ray with a parallel plane in front of the origin", () => {
    const ray: Ray3D = { origin: { x: 0, y: 0, z: 0 }, direction: { x: 0, y: 0, z: -1 } };
    const plane: Plane3D = { origin: { x: 0, y: 0, z: -5 }, normal: { x: 0, y: 0, z: 1 } };
    const p = rayPlaneIntersect(ray, plane);
    expect(p).not.toBeNull();
    expect(p!.x).toBeCloseTo(0, 6);
    expect(p!.y).toBeCloseTo(0, 6);
    expect(p!.z).toBeCloseTo(-5, 6);
  });

  it("returns null when ray is parallel to the plane", () => {
    const ray: Ray3D = { origin: { x: 0, y: 0, z: 0 }, direction: { x: 1, y: 0, z: 0 } };
    const plane: Plane3D = { origin: { x: 0, y: 0, z: -5 }, normal: { x: 0, y: 0, z: 1 } };
    expect(rayPlaneIntersect(ray, plane)).toBeNull();
  });

  it("returns null when intersection is behind the ray origin", () => {
    const ray: Ray3D = { origin: { x: 0, y: 0, z: 0 }, direction: { x: 0, y: 0, z: -1 } };
    const plane: Plane3D = { origin: { x: 0, y: 0, z: 5 }, normal: { x: 0, y: 0, z: 1 } };
    expect(rayPlaneIntersect(ray, plane)).toBeNull();
  });
});

describe("widestBaselinePair", () => {
  it("picks the pair of camera poses with the largest separation", () => {
    const a = poseLookingForward({ x: 0, y: 0, z: 0 });
    const b = poseLookingForward({ x: 0.5, y: 0, z: 0 });
    const c = poseLookingForward({ x: 5, y: 0, z: 0 });
    const pair = widestBaselinePair([a, b, c]);
    expect(pair).toEqual([0, 2]);
  });
});
