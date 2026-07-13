"""Bake ortofoto per piano (mosaico foto→piani, passo 8).

Riusa la proiezione pinhole OC validata (project_photos_to_mesh.py): le pose OC
sono nel frame della mesh, quindi ogni foto si proietta direttamente. Qui però
il bersaglio non sono i vertici della mesh ma una **griglia di texel** sul piano
(risoluzione mm reale), così l'output è un'ortofoto a piena risoluzione per piano.

Per ogni texel del piano:
  world = origin + u*u_m + v*v_m         (u = orizzontale, v = verticale/gravità)
  → si sceglie la foto con lo score migliore (assialità + centralità + prossimità),
    con occlusione opzionale (raycast Open3D, salta le foto ostruite dalla mesh),
    e si campiona il colore.

Input: mesh (occlusore + estensione piani), pose OC, foto, documento piani
(schema acro.planes/v1 dell'editor: planes[].punto/normale/triangoli + piano_base).
Output: PNG per piano + _superfici.txt (aree m²). Niente path hardcoded.

Convenzione proiezione (identica al NativePoseMeshViewer):
    Pc = (G - C) @ R ; z = -Pc[2] ; u = fx*Pc0/z + cx ; v = cy - fy*Pc1/z
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

# Limite prudente di texel per piano: oltre, si abbassa la risoluzione (memoria).
_MAX_TEXELS = 6_000_000
_TEX_CLAMP = (8, 8000)          # come il viewer: min/max lato in texel
_TOP_CAMERA_SLOTS = 12


def qR(w, x, y, z):
    """Quaternione (w,x,y,z) → matrice di rotazione 3x3 (camera→mondo)."""
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def load_obj(path):
    """Parser OBJ minimale (ASSIMP fallisce sulle righe 'o'/'g' degli OBJ OC)."""
    vs, fs = [], []
    with open(path) as fh:
        for ln in fh:
            if ln.startswith("v "):
                vs.append([float(a) for a in ln.split()[1:4]])
            elif ln.startswith("f "):
                idx = [int(t.split("/")[0]) - 1 for t in ln.split()[1:]]
                for i in range(1, len(idx) - 1):
                    fs.append([idx[0], idx[i], idx[i + 1]])
    return np.asarray(vs, float), np.asarray(fs, np.int32)


def photo_path(photo_dir, k):
    for ext in ("jpg", "jpeg", "png", "JPG"):
        p = os.path.join(photo_dir, f"{int(k):04d}.{ext}")
        if os.path.exists(p):
            return p
    return None


def _unit(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-9 else v


@dataclass
class Camera:
    key: str
    C: np.ndarray            # centro camera (mondo)
    R: np.ndarray            # rotazione camera→mondo
    fx: float
    fy: float
    cx: float
    cy: float
    image_width: int
    image_height: int
    optical: np.ndarray = field(default=None)   # direzione di vista nel mondo

    def __post_init__(self):
        self.optical = self.R @ np.array([0.0, 0.0, -1.0])


def load_cameras(poses: dict) -> list[Camera]:
    keys = sorted((k for k in poses if "translation" in poses[k]), key=int)
    cams = []
    for k in keys:
        p = poses[k]
        fx, fy, cx, cy = p["intrinsics_fx_fy_cx_cy"]
        size = p.get("image_width_height") or [round(cx * 2), round(cy * 2)]
        cams.append(Camera(k, np.asarray(p["translation"], float),
                           qR(*p["rotation_wxyz"]), fx, fy, cx, cy,
                           max(int(size[0]), 1), max(int(size[1]), 1)))
    return cams


def _plane_vertices(V: np.ndarray, faces: np.ndarray, triangoli: list[int]) -> np.ndarray:
    """Vertici (mondo) dei triangoli assegnati a un piano."""
    if not triangoli:
        return np.empty((0, 3))
    tri = np.asarray([t for t in triangoli if 0 <= t < len(faces)], np.int32)
    if len(tri) == 0:
        return np.empty((0, 3))
    vidx = np.unique(faces[tri].reshape(-1))
    return V[vidx]


@dataclass
class PlaneFrame:
    origin: np.ndarray       # angolo (min_u, min_v) sul piano, nel mondo
    u: np.ndarray            # asse orizzontale (unitario)
    v: np.ndarray            # asse verticale/gravità (unitario)
    corners: np.ndarray      # poligono reale, in coordinate mesh
    polygon_uv: np.ndarray   # coordinate nel rettangolo [0..1]
    width_world: float
    height_world: float
    width_m: float
    height_m: float
    area_m2: float
    tex_w: int
    tex_h: int
    texel_m: float


def plane_frame(plane: dict, up_world: np.ndarray, V: np.ndarray,
                faces: np.ndarray, texel_m: float,
                scale_m_per_mesh_unit: float = 1.0) -> PlaneFrame | None:
    """Costruisce il frame ortho del piano: assi u/v (v = verticale) ed estensione
    dal poligono revisionato (`corners`), con fallback ai triangoli. I triangoli
    sono supporto di riconoscimento e non devono ridimensionare il piano."""
    n = _unit(np.asarray(plane["normale"], float))
    if np.linalg.norm(n) < 1e-6:
        return None
    # v = componente della gravità nel piano; se il piano è ~orizzontale, ripiega.
    v = up_world - np.dot(up_world, n) * n
    if np.linalg.norm(v) < 1e-4:
        alt = np.array([1.0, 0.0, 0.0])
        v = alt - np.dot(alt, n) * n
    v = _unit(v)
    u = _unit(np.cross(n, v))   # orizzontale nel piano

    raw_corners = plane.get("corners")
    pts = np.asarray(raw_corners, float) if isinstance(raw_corners, list) else np.empty((0, 3))
    if pts.ndim != 2 or pts.shape[1:] != (3,) or len(pts) < 3:
        pts = _plane_vertices(V, faces, plane.get("triangoli", []))
    if len(pts) < 3:
        return None
    origin0 = np.asarray(plane["punto"], float)
    du = (pts - origin0) @ u
    dv = (pts - origin0) @ v
    umin, umax = float(du.min()), float(du.max())
    vmin, vmax = float(dv.min()), float(dv.max())
    width_world = max(umax - umin, 1e-6)
    height_world = max(vmax - vmin, 1e-6)
    width_m = width_world * scale_m_per_mesh_unit
    height_m = height_world * scale_m_per_mesh_unit
    origin = origin0 + u * umin + v * vmin
    pu = np.column_stack(((du - umin) / width_world, (dv - vmin) / height_world))
    area_world = 0.5 * abs(float(
        np.dot(pu[:, 0] * width_world, np.roll(pu[:, 1] * height_world, -1))
        - np.dot(pu[:, 1] * height_world, np.roll(pu[:, 0] * width_world, -1))))
    area_m2 = area_world * scale_m_per_mesh_unit ** 2

    tw = int(round(width_m / texel_m))
    th = int(round(height_m / texel_m))
    # riduci la risoluzione se troppi texel (memoria)
    if tw * th > _MAX_TEXELS:
        s = (float(tw) * th / _MAX_TEXELS) ** 0.5
        tw = int(tw / s)
        th = int(th / s)
    tw = min(max(tw, _TEX_CLAMP[0]), _TEX_CLAMP[1])
    th = min(max(th, _TEX_CLAMP[0]), _TEX_CLAMP[1])
    return PlaneFrame(origin, u, v, pts, pu, width_world, height_world,
                      width_m, height_m, area_m2, tw, th, texel_m)


class Occluder:
    """Raycast contro la mesh (Open3D) per scartare le foto ostruite. Opzionale:
    se Open3D non è installato o disabilitato, `test` ritorna sempre 'visibile'."""

    def __init__(self, V, faces, enabled: bool):
        self.enabled = False
        self.diag = float(np.linalg.norm(V.max(0) - V.min(0))) if len(V) else 1.0
        if not enabled:
            return
        try:
            import open3d as o3d
            m = o3d.geometry.TriangleMesh(o3d.utility.Vector3dVector(V),
                                          o3d.utility.Vector3iVector(faces))
            self.scene = o3d.t.geometry.RaycastingScene()
            self.scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(m))
            self._o3d = o3d
            self.enabled = True
        except Exception:
            self.enabled = False

    def visible_mask(self, pts: np.ndarray, C: np.ndarray, eps_frac=0.012) -> np.ndarray:
        """Per ogni punto: True se la mesh non lo occlude dalla camera C."""
        if not self.enabled or len(pts) == 0:
            return np.ones(len(pts), bool)
        dirs = pts - C
        d = np.linalg.norm(dirs, axis=1)
        nd = np.maximum(d, 1e-9)
        rays = self._o3d.core.Tensor(
            np.hstack([np.repeat(C[None, :], len(pts), 0),
                       dirs / nd[:, None]]).astype(np.float32))
        hit = self.scene.cast_rays(rays)["t_hit"].numpy()
        return hit >= (d - eps_frac * self.diag)


def _sample(img, u, v):
    """Campiona img (BGR) a coordinate float (u,v) con bilineare, a blocchi sotto il
    limite di cv2.remap (SHRT_MAX colonne)."""
    out = np.empty((len(u), 3), np.uint8)
    CH = 30000
    for s in range(0, len(u), CH):
        e = min(s + CH, len(u))
        uu = u[s:e].astype(np.float32).reshape(1, -1)
        vv = v[s:e].astype(np.float32).reshape(1, -1)
        out[s:e] = cv2.remap(img, uu, vv, cv2.INTER_LINEAR,
                             borderMode=cv2.BORDER_REFLECT)[0]
    return out


def _polygon_mask(width: int, height: int, polygon_uv: np.ndarray) -> np.ndarray:
    xy = np.column_stack((polygon_uv[:, 0] * width,
                          (1.0 - polygon_uv[:, 1]) * height))
    mask = np.zeros((height, width), np.uint8)
    cv2.fillPoly(mask, [np.round(xy).astype(np.int32)], 1)
    return mask.astype(bool)


def _project(cam: Camera, pts: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    pc = (pts - cam.C) @ cam.R
    z = -pc[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        x = cam.fx * pc[:, 0] / z + cam.cx
        # Il frame camera OC ha Y verso l'alto, i pixel JPEG verso il basso.
        y = cam.cy - cam.fy * pc[:, 1] / z
    return x, y, z


def _cell_score(cam: Camera, pts: np.ndarray, x: np.ndarray, y: np.ndarray,
                W: int, H: int, normal: np.ndarray, up: np.ndarray,
                proximity_scale: float) -> tuple[np.ndarray, np.ndarray]:
    dirs = pts - cam.C
    dist = np.linalg.norm(dirs, axis=1)
    view = dirs / np.maximum(dist, 1e-6)[:, None]
    facing = (-view) @ normal
    forward = view @ cam.optical
    plane_h = np.cross(up, normal)
    hlen = np.linalg.norm(plane_h)
    if hlen > 1e-6:
        plane_h /= hlen
        tan_h = np.abs((-view) @ plane_h) / np.maximum(facing, 0.05)
        axial = 1.0 / (1.0 + 2.0 * tan_h)
    else:
        axial = np.ones(len(pts))
    cx = x / W
    cy = y / H
    centrality = np.maximum(0.0, 1.0 - np.maximum(np.abs(cx * 2 - 1),
                                                  np.abs(cy * 2 - 1)))
    proximity = 1.0 / (1.0 + dist / max(proximity_scale, 1e-6))
    score = 2.0 * axial + 0.4 * facing + 0.8 * centrality + 0.35 * proximity
    return score.astype(np.float32), (forward > 0.05)


def _insert_top(top_scores: np.ndarray, top_cams: np.ndarray,
                scores: np.ndarray, camera_index: int) -> None:
    # Sostituisce solo il minimo corrente. Ordinare a ogni camera costava O(N)
    # allocazioni enormi sulle sessioni da 300+ foto; basta ordinare una volta.
    rows = np.arange(len(scores))
    slots = np.argmin(top_scores, axis=1)
    better = scores > top_scores[rows, slots]
    top_scores[rows[better], slots[better]] = scores[better]
    top_cams[rows[better], slots[better]] = camera_index


def _select_cameras(top_cams: np.ndarray, valid: np.ndarray,
                    camera_count: int, max_photos: int,
                    min_area_fraction: float = 0.005) -> np.ndarray:
    kept = np.zeros(camera_count, bool)
    covered = ~valid.copy()
    min_cells = max(1, int(valid.sum() * min_area_fraction))
    for _ in range(max_photos):
        rows = np.where(~covered)[0]
        if len(rows) == 0:
            break
        candidates = top_cams[rows].reshape(-1)
        candidates = candidates[candidates >= 0]
        if len(candidates) == 0:
            break
        counts = np.bincount(candidates, minlength=camera_count)
        counts[kept] = 0
        best = int(np.argmax(counts))
        if counts[best] < min_cells:
            break
        kept[best] = True
        covered[rows[np.any(top_cams[rows] == best, axis=1)]] = True
    if not kept.any():
        first = top_cams[valid, 0]
        first = first[first >= 0]
        if len(first):
            kept[int(np.bincount(first, minlength=camera_count).argmax())] = True
    return kept


def _relax_labels(labels: np.ndarray, top_cams: np.ndarray,
                  top_scores: np.ndarray, valid: np.ndarray,
                  width: int, height: int, margin: float = 0.20) -> np.ndarray:
    grid_valid = valid.reshape(height, width)
    for _ in range(6):
        grid = labels.reshape(height, width)
        neighbors = [grid]
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            shifted = np.full_like(grid, -1)
            ys = slice(max(0, dy), min(height, height + dy))
            xs = slice(max(0, dx), min(width, width + dx))
            sy = slice(max(0, -dy), min(height, height - dy))
            sx = slice(max(0, -dx), min(width, width - dx))
            shifted[ys, xs] = grid[sy, sx]
            neighbors.append(shifted)
        stack = np.stack(neighbors, axis=-1).reshape(-1, 5)
        counts = np.stack([(stack == stack[:, i:i + 1]).sum(axis=1)
                           for i in range(5)], axis=1)
        dominant = stack[np.arange(len(stack)), counts.argmax(axis=1)]
        matches = top_cams == dominant[:, None]
        candidate_score = np.where(matches, top_scores, -np.inf).max(axis=1)
        adopt = valid & (dominant >= 0) & \
            (candidate_score >= top_scores[:, 0] * (1.0 - margin))
        updated = labels.copy()
        updated[adopt] = dominant[adopt]
        updated[~grid_valid.reshape(-1)] = -1
        if np.array_equal(updated, labels):
            break
        labels = updated
    return labels


def bake_plane(pf: PlaneFrame, cams: list[Camera], photos_dir: str, diag: float,
               occ: Occluder, plane_normal: np.ndarray, up_world: np.ndarray,
               facing_min=0.342, max_photos=60, crop=0.9,
               cell_m=0.15,
               scale_m_per_mesh_unit=1.0, photo_resolver=None,
               available_photo_keys=None) -> tuple[np.ndarray, float, list[int]]:
    """Bake con lo stesso schema del viewer locale: scelta su celle, copertura
    greedy, regolarizzazione di continuità e raster finale ad alta risoluzione."""
    cw = max(2, int(np.ceil(pf.width_m / cell_m)))
    ch = max(2, int(np.ceil(pf.height_m / cell_m)))
    if cw * ch > 250_000:
        factor = np.sqrt(cw * ch / 250_000.0)
        cw, ch = max(2, int(cw / factor)), max(2, int(ch / factor))
    mask = _polygon_mask(cw, ch, pf.polygon_uv)
    cols, rows = np.meshgrid(np.arange(cw), np.arange(ch))
    gu = (cols.reshape(-1) + 0.5) / cw * pf.width_world
    gv = (1.0 - (rows.reshape(-1) + 0.5) / ch) * pf.height_world
    world = pf.origin + gu[:, None] * pf.u + gv[:, None] * pf.v
    valid_poly = mask.reshape(-1)

    n = _unit(np.asarray(plane_normal, float))
    camera_direction = sum((_unit(cam.C - pf.corners.mean(axis=0)) for cam in cams),
                           np.zeros(3))
    if np.dot(n, camera_direction) < 0:
        n = -n
    top_scores = np.full((len(world), _TOP_CAMERA_SLOTS), -np.inf, np.float32)
    top_cams = np.full((len(world), _TOP_CAMERA_SLOTS), -1, np.int32)
    cmin, cmax = (1 - crop) * 0.5, 1 - (1 - crop) * 0.5
    proximity_scale = max(diag * 0.1, 1e-4)

    for ci, cam in enumerate(cams):
        if available_photo_keys is not None:
            if str(int(cam.key)) not in available_photo_keys:
                continue
        elif photo_path(photos_dir, cam.key) is None:
            continue
        W, H = cam.image_width, cam.image_height
        x, y, z = _project(cam, world)
        score, forward = _cell_score(cam, world, x, y, W, H, n,
                                     up_world, proximity_scale)
        dirs = world - cam.C
        view = dirs / np.maximum(np.linalg.norm(dirs, axis=1), 1e-6)[:, None]
        facing = (-view) @ n
        good = valid_poly & forward & (facing >= facing_min) & (z > 0.01) & \
            (x >= cmin * W) & (x <= cmax * W) & \
            (y >= cmin * H) & (y <= cmax * H)
        if good.any() and occ.enabled:
            ids = np.where(good)[0]
            good[ids] &= occ.visible_mask(world[ids], cam.C)
        score[~good] = -np.inf
        _insert_top(top_scores, top_cams, score, ci)

    order = np.argsort(top_scores, axis=1)[:, ::-1]
    top_scores = np.take_along_axis(top_scores, order, axis=1)
    top_cams = np.take_along_axis(top_cams, order, axis=1)

    candidate_valid = valid_poly & (top_cams[:, 0] >= 0)
    kept = _select_cameras(top_cams, candidate_valid, len(cams), max_photos)
    allowed = np.where(top_cams >= 0, kept[np.maximum(top_cams, 0)], False)
    kept_scores = np.where(allowed, top_scores, -np.inf)
    choice = kept_scores.argmax(axis=1)
    labels = top_cams[np.arange(len(world)), choice]
    labels[~np.isfinite(kept_scores.max(axis=1))] = -1
    relax_cams = np.where(allowed, top_cams, -1)
    relax_scores = np.where(allowed, top_scores, -np.inf)
    relax_valid = valid_poly & np.any(allowed, axis=1)
    labels = _relax_labels(labels, relax_cams, relax_scores, relax_valid, cw, ch)

    full_labels = cv2.resize(labels.reshape(ch, cw).astype(np.int32),
                             (pf.tex_w, pf.tex_h), interpolation=cv2.INTER_NEAREST)
    full_mask = _polygon_mask(pf.tex_w, pf.tex_h, pf.polygon_uv)
    full_labels[~full_mask] = -1
    out = np.zeros((pf.tex_h, pf.tex_w, 4), np.uint8)
    out[..., 3] = np.where(full_mask, 255, 0).astype(np.uint8)
    painted = np.zeros((pf.tex_h, pf.tex_w), bool)
    for ci in sorted(set(full_labels[full_labels >= 0].tolist())):
        rr, cc = np.where(full_labels == ci)
        if len(rr) == 0:
            continue
        cam = cams[ci]
        path = (photo_resolver(cam.key) if photo_resolver
                else photo_path(photos_dir, cam.key))
        img = cv2.imread(path) if path else None
        if img is None:
            continue
        gu = (cc + 0.5) / pf.tex_w * pf.width_world
        gv = (1.0 - (rr + 0.5) / pf.tex_h) * pf.height_world
        pts = pf.origin + gu[:, None] * pf.u + gv[:, None] * pf.v
        x, y, z = _project(cam, pts)
        H, W = img.shape[:2]
        good = (z > 0.01) & (x >= 0) & (x < W) & (y >= 0) & (y < H)
        if not good.any():
            continue
        rgb = _sample(img, x[good], y[good])[:, ::-1]
        out[rr[good], cc[good], :3] = rgb
        painted[rr[good], cc[good]] = True
    coverage = float(painted[full_mask].mean()) if full_mask.any() else 0.0
    used = sorted(set(full_labels[painted].tolist()))
    return out, coverage, used


def _sanitize(name: str) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in name)[:40] or "piano"


def _write_textured_mesh(out_dir: str, frames: list[tuple[int, str, str, PlaneFrame]]) -> tuple[str, str]:
    obj_name = "planes_textured.obj"
    mtl_name = "planes_textured.mtl"
    obj = ["# Acrobatica textured planes", f"mtllib {mtl_name}"]
    mtl = ["# Acrobatica projected materials"]
    vertex_offset = 1
    uv_offset = 1
    for index, name, texture, pf in frames:
        material = f"plane_{index}_{_sanitize(name)}"
        obj += [f"o {material}", f"g {material}", f"usemtl {material}"]
        obj += [f"v {p[0]:.9g} {p[1]:.9g} {p[2]:.9g}" for p in pf.corners]
        obj += [f"vt {uv[0]:.9g} {uv[1]:.9g}" for uv in pf.polygon_uv]
        for k in range(1, len(pf.corners) - 1):
            ids = (0, k, k + 1)
            obj.append("f " + " ".join(
                f"{vertex_offset + q}/{uv_offset + q}" for q in ids))
        mtl += [f"newmtl {material}", "Ka 1 1 1", "Kd 1 1 1",
                "illum 1", f"map_Kd {texture}", ""]
        vertex_offset += len(pf.corners)
        uv_offset += len(pf.corners)
    Path(out_dir, obj_name).write_text("\n".join(obj) + "\n")
    Path(out_dir, mtl_name).write_text("\n".join(mtl) + "\n")
    return obj_name, mtl_name


def bake_planes(mesh_path: str, poses: dict, photos_dir: str, planes_doc: dict,
                out_dir: str, texel_mm: float = 8.0, max_photos: int = 80,
                occlusion: bool = False, facing_min: float = 0.20,
                crop: float = 0.9, scale_m_per_mesh_unit: float = 1.0,
                log=print, progress=None, photo_resolver=None,
                available_photo_keys=None) -> dict:
    """Bake di tutti i piani del documento. Ritorna un riepilogo (piani, aree, file).
    Scrive PNG per piano + _superfici.txt in `out_dir`."""
    os.makedirs(out_dir, exist_ok=True)
    V, faces = load_obj(mesh_path)
    diag = float(np.linalg.norm(V.max(0) - V.min(0)))
    cams = load_cameras(poses)
    occ = Occluder(V, faces, occlusion)
    if occlusion and not occ.enabled:
        log("[avviso] occlusione richiesta ma Open3D non disponibile → disattivata")

    pb = planes_doc.get("piano_base") or {}
    up_world = _unit(np.asarray(pb.get("up", [0.0, 1.0, 0.0]), float))
    texel_m = texel_mm / 1000.0
    planes = planes_doc.get("planes", [])
    log(f"mesh {len(V)} v / {len(faces)} f · camere {len(cams)} · piani {len(planes)} · "
        f"texel {texel_mm}mm · occlusione {'on' if occ.enabled else 'off'}")

    results = []
    frames: list[tuple[int, str, str, PlaneFrame]] = []
    total_area = 0.0
    lines = [f"Superfici piani — bake ortografico {texel_mm:.0f} mm/texel", ""]
    for i, plane in enumerate(planes, 1):
        nome = plane.get("nome") or plane.get("tipo") or f"piano{i}"
        pf = plane_frame(plane, up_world, V, faces, texel_m,
                         scale_m_per_mesh_unit=scale_m_per_mesh_unit)
        if pf is None:
            log(f"  piano {i} ({nome}): degenere/senza triangoli → salto")
            continue
        img, cov, used = bake_plane(pf, cams, photos_dir, diag, occ,
                              np.asarray(plane["normale"], float), up_world,
                              facing_min=facing_min, max_photos=max_photos, crop=crop,
                              photo_resolver=photo_resolver,
                              available_photo_keys=available_photo_keys)
        area = pf.area_m2
        total_area += area
        fname = f"plane_{i}_{_sanitize(nome)}.png"
        cv2.imwrite(os.path.join(out_dir, fname), cv2.cvtColor(img, cv2.COLOR_RGBA2BGRA))
        log(f"  piano {i} ({nome}): {pf.tex_w}x{pf.tex_h}px  "
            f"{pf.width_m:.2f}x{pf.height_m:.2f}m  area {area:.2f} m²  copertura {cov*100:.0f}%")
        lines.append(f"plane_{i}_{nome:<16.16s} {pf.width_m:6.2f} x {pf.height_m:6.2f} m "
                     f"{area:8.2f} m²   copertura {cov*100:3.0f}%")
        results.append({"index": i, "nome": nome, "file": fname,
                        "width_m": round(pf.width_m, 3), "height_m": round(pf.height_m, 3),
                        "tex_w": pf.tex_w, "tex_h": pf.tex_h,
                        "area_m2": round(area, 2), "coverage": round(cov, 3),
                        "photos_used": len(used)})
        frames.append((i, nome, fname, pf))
        if progress:
            progress(i, len(planes), nome)
    lines += ["", f"TOTALE {total_area:8.2f} m²"]
    with open(os.path.join(out_dir, "_superfici.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")

    main_obj, _ = _write_textured_mesh(out_dir, frames)
    coverage = (sum(p["coverage"] * p["area_m2"] for p in results) / total_area
                if total_area > 0 else 0.0)
    return {"planes": results, "total_area_m2": round(total_area, 2),
            "coverage": round(coverage, 3), "main_obj": main_obj,
            "out_dir": out_dir, "count": len(results)}
