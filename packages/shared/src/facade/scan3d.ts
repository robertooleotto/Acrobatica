export interface Point3D { readonly x: number; readonly y: number; readonly z: number; }
export type Polygon3D = readonly Point3D[];
export type Quad3D = readonly [Point3D, Point3D, Point3D, Point3D];

export interface FacciataScan {
  readonly corners: Quad3D;
  readonly excluded: ReadonlyArray<{ readonly id: string; readonly label?: string; readonly polygon: Polygon3D }>;
  readonly extras: ReadonlyArray<{ readonly id: string; readonly label?: string; readonly polygon: Polygon3D }>;
  readonly confidence?: number;
  readonly capturedAt: number;
}

export interface FacciataResult3D {
  readonly lordaMq: number;
  readonly esclusiMq: number;
  readonly extraMq: number;
  readonly nettaMq: number;
  readonly larghezzaM: number;
  readonly altezzaM: number;
}

export function distance3D(a: Point3D, b: Point3D): number {
  const dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
}

function subtract(a: Point3D, b: Point3D): Point3D { return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z }; }
function cross(a: Point3D, b: Point3D): Point3D {
  return { x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x };
}
function magnitude(v: Point3D): number { return Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z); }

export function polygonArea3D(polygon: Polygon3D): number {
  if (polygon.length < 3) return 0;
  const origin = polygon[0]!;
  let total: Point3D = { x: 0, y: 0, z: 0 };
  for (let i = 1; i < polygon.length - 1; i++) {
    const a = subtract(polygon[i]!, origin);
    const b = subtract(polygon[i + 1]!, origin);
    const c = cross(a, b);
    total = { x: total.x + c.x, y: total.y + c.y, z: total.z + c.z };
  }
  return magnitude(total) / 2;
}

export function quadDimensions(q: Quad3D): { width: number; height: number } {
  const top = distance3D(q[0], q[1]);
  const bottom = distance3D(q[3], q[2]);
  const left = distance3D(q[0], q[3]);
  const right = distance3D(q[1], q[2]);
  return { width: (top + bottom) / 2, height: (left + right) / 2 };
}

export function computeFacciataNettaMq3D(scan: FacciataScan): FacciataResult3D {
  const lordaMq = polygonArea3D(scan.corners);
  const esclusiMqRaw = scan.excluded.reduce((s, e) => s + polygonArea3D(e.polygon), 0);
  const extraMq = scan.extras.reduce((s, e) => s + polygonArea3D(e.polygon), 0);
  const esclusiMq = Math.min(esclusiMqRaw, lordaMq);
  const nettaMq = Math.max(lordaMq - esclusiMq, 0) + extraMq;
  const dims = quadDimensions(scan.corners);
  return { lordaMq, esclusiMq, extraMq, nettaMq, larghezzaM: dims.width, altezzaM: dims.height };
}
