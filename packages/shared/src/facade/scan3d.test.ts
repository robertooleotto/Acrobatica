import { describe, it, expect } from "vitest";
import {
  polygonArea3D,
  quadDimensions,
  computeFacciataNettaMq3D,
  type Quad3D,
  type Polygon3D,
  type FacciataScan,
} from "./scan3d";

const wall = (w: number, h: number): Quad3D => [
  { x: 0, y: h, z: 0 },
  { x: w, y: h, z: 0 },
  { x: w, y: 0, z: 0 },
  { x: 0, y: 0, z: 0 },
];

const rect = (x0: number, y0: number, w: number, h: number, z = 0): Polygon3D => [
  { x: x0, y: y0 + h, z },
  { x: x0 + w, y: y0 + h, z },
  { x: x0 + w, y: y0, z },
  { x: x0, y: y0, z },
];

describe("polygonArea3D", () => {
  it("returns 0 for polygons with fewer than 3 vertices", () => {
    expect(polygonArea3D([])).toBe(0);
    expect(polygonArea3D([{ x: 0, y: 0, z: 0 }])).toBe(0);
    expect(polygonArea3D([{ x: 0, y: 0, z: 0 }, { x: 1, y: 0, z: 0 }])).toBe(0);
  });

  it("computes the area of an axis-aligned wall regardless of its plane orientation", () => {
    const wallXY = wall(5, 3);
    expect(polygonArea3D(wallXY)).toBeCloseTo(15, 9);

    const tiltedWall: Polygon3D = [
      { x: 0, y: 3, z: 0 },
      { x: 4, y: 3, z: 3 },
      { x: 4, y: 0, z: 3 },
      { x: 0, y: 0, z: 0 },
    ];
    expect(polygonArea3D(tiltedWall)).toBeCloseTo(15, 9);
  });
});

describe("quadDimensions", () => {
  it("averages opposite sides to derive width and height", () => {
    const q = wall(5, 3);
    const { width, height } = quadDimensions(q);
    expect(width).toBeCloseTo(5, 9);
    expect(height).toBeCloseTo(3, 9);
  });
});

describe("computeFacciataNettaMq3D", () => {
  it("returns the gross area when no exclusions or extras are present", () => {
    const scan: FacciataScan = {
      corners: wall(5, 3),
      excluded: [],
      extras: [],
      capturedAt: 0,
    };
    const r = computeFacciataNettaMq3D(scan);
    expect(r.lordaMq).toBeCloseTo(15, 9);
    expect(r.esclusiMq).toBe(0);
    expect(r.extraMq).toBe(0);
    expect(r.nettaMq).toBeCloseTo(15, 9);
    expect(r.larghezzaM).toBeCloseTo(5, 9);
    expect(r.altezzaM).toBeCloseTo(3, 9);
  });

  it("subtracts windows and adds balconies", () => {
    const scan: FacciataScan = {
      corners: wall(5, 3),
      excluded: [
        { id: "w1", polygon: rect(0.5, 1, 1, 1) },
        { id: "w2", polygon: rect(3, 1, 1, 1) },
      ],
      extras: [{ id: "b1", polygon: rect(0, 0, 2, 0.5) }],
      capturedAt: 0,
    };
    const r = computeFacciataNettaMq3D(scan);
    expect(r.lordaMq).toBeCloseTo(15, 9);
    expect(r.esclusiMq).toBeCloseTo(2, 9);
    expect(r.extraMq).toBeCloseTo(1, 9);
    expect(r.nettaMq).toBeCloseTo(15 - 2 + 1, 9);
  });

  it("caps exclusions at the gross area and keeps netta non-negative", () => {
    const scan: FacciataScan = {
      corners: wall(2, 2),
      excluded: [{ id: "huge", polygon: rect(-5, -5, 20, 20) }],
      extras: [],
      capturedAt: 0,
    };
    const r = computeFacciataNettaMq3D(scan);
    expect(r.lordaMq).toBeCloseTo(4, 9);
    expect(r.esclusiMq).toBeCloseTo(4, 9);
    expect(r.nettaMq).toBe(0);
  });
});
