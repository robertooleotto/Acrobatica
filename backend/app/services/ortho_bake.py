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

Convenzione proiezione (identica a project_photos_to_mesh.py):
    Pc = (G - C) @ R ; z = -Pc[2] ; u = fx*Pc0/z + cx ; v = fy*Pc1/z + cy
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
    optical: np.ndarray = field(default=None)   # direzione di vista nel mondo

    def __post_init__(self):
        self.optical = self.R @ np.array([0.0, 0.0, -1.0])


def load_cameras(poses: dict) -> list[Camera]:
    keys = sorted((k for k in poses if "translation" in poses[k]), key=int)
    cams = []
    for k in keys:
        p = poses[k]
        fx, fy, cx, cy = p["intrinsics_fx_fy_cx_cy"]
        cams.append(Camera(k, np.asarray(p["translation"], float),
                           qR(*p["rotation_wxyz"]), fx, fy, cx, cy))
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
    width_m: float
    height_m: float
    tex_w: int
    tex_h: int
    texel_m: float


def plane_frame(plane: dict, up_world: np.ndarray, V: np.ndarray,
                faces: np.ndarray, texel_m: float) -> PlaneFrame | None:
    """Costruisce il frame ortho del piano: assi u/v (v = verticale) ed estensione
    dai triangoli del piano proiettati su u/v. `None` se il piano è degenere."""
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

    pts = _plane_vertices(V, faces, plane.get("triangoli", []))
    if len(pts) < 3:
        return None
    origin0 = np.asarray(plane["punto"], float)
    du = (pts - origin0) @ u
    dv = (pts - origin0) @ v
    umin, umax = float(du.min()), float(du.max())
    vmin, vmax = float(dv.min()), float(dv.max())
    width_m = max(umax - umin, 1e-3)
    height_m = max(vmax - vmin, 1e-3)
    origin = origin0 + u * umin + v * vmin

    tw = int(round(width_m / texel_m))
    th = int(round(height_m / texel_m))
    # riduci la risoluzione se troppi texel (memoria)
    if tw * th > _MAX_TEXELS:
        s = (float(tw) * th / _MAX_TEXELS) ** 0.5
        tw = int(tw / s)
        th = int(th / s)
    tw = min(max(tw, _TEX_CLAMP[0]), _TEX_CLAMP[1])
    th = min(max(th, _TEX_CLAMP[0]), _TEX_CLAMP[1])
    return PlaneFrame(origin, u, v, width_m, height_m, tw, th, texel_m)


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


def _score(cam: Camera, pts, u_px, v_px, W, H, diag):
    """Score per-punto (assialità/centralità/prossimità), come project_photos_to_mesh
    più il bonus di assialità orizzontale del viewer."""
    dirs = pts - cam.C
    dist = np.linalg.norm(dirs, axis=1)
    view = dirs / np.maximum(dist, 1e-6)[:, None]
    cosang = cam.optical @ view.T            # facing camera-punto (viewer: -viewDir)
    nx = (u_px - W * 0.5) / (W * 0.5)
    ny = (v_px - H * 0.5) / (H * 0.5)
    centrality = 1.0 - np.clip(np.sqrt(nx * nx + ny * ny), 0, 1.4) / 1.4
    prox = 1.0 / np.maximum(dist, 1e-3 * diag)
    prox = prox / (prox.max() + 1e-9)
    return (2.0 * centrality + 1.2 * np.clip(cosang, 0, 1) + 0.35 * prox).astype(np.float32)


def bake_plane(pf: PlaneFrame, cams: list[Camera], photos_dir: str, diag: float,
               occ: Occluder, plane_normal: np.ndarray,
               facing_min=0.20, max_photos=80, crop=0.9) -> tuple[np.ndarray, float]:
    """Ritorna (immagine RGB HxWx3 uint8, copertura 0..1) per un piano."""
    tw, th = pf.tex_w, pf.tex_h
    # griglia texel → punti mondo. y-flip: riga 0 = alto (v massimo).
    xs = (np.arange(tw) + 0.5) / tw * pf.width_m
    ys = (1.0 - (np.arange(th) + 0.5) / th) * pf.height_m
    gu, gv = np.meshgrid(xs, ys)                       # (th, tw)
    world = (pf.origin[None, None, :]
             + gu[..., None] * pf.u[None, None, :]
             + gv[..., None] * pf.v[None, None, :]).reshape(-1, 3)
    N = world.shape[0]

    n = _unit(plane_normal)
    best = np.full(N, -1e9, np.float32)
    col = np.zeros((N, 3), np.float32)
    src = np.full(N, -1, np.int32)

    # ordina le camere per quanto guardano frontalmente il piano; scarta le radenti.
    order = []
    for ci, cam in enumerate(cams):
        facing = abs(float(cam.optical @ n))
        if facing >= facing_min:
            order.append((facing, ci))
    order.sort(reverse=True)
    order = [ci for _, ci in order[:max_photos]]

    cmin, cmax = (1 - crop) * 0.5, 1 - (1 - crop) * 0.5
    for ci in order:
        cam = cams[ci]
        Pc = (world - cam.C) @ cam.R
        z = -Pc[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            u = cam.fx * Pc[:, 0] / z + cam.cx
            v = cam.fy * Pc[:, 1] / z + cam.cy
        pth = photo_path(photos_dir, cam.key)
        if pth is None:
            continue
        img = cv2.imread(pth)
        if img is None:
            continue
        H, W = img.shape[:2]
        # dentro il crop centrale dell'immagine
        infront = (z > 0.02) & (u >= cmin * W) & (v >= cmin * H) & \
                  (u < cmax * W) & (v < cmax * H)
        idx = np.where(infront)[0]
        if len(idx) == 0:
            continue
        if occ.enabled:
            vis = occ.visible_mask(world[idx], cam.C)
            idx = idx[vis]
            if len(idx) == 0:
                continue
        sc = _score(cam, world[idx], u[idx], v[idx], W, H, diag)
        upd = sc > best[idx]
        if not upd.any():
            continue
        sel = idx[upd]
        samp = _sample(img, u[sel], v[sel])
        col[sel] = samp[:, ::-1].astype(np.float32)     # BGR→RGB
        best[sel] = sc[upd]
        src[sel] = int(cam.key)

    cov = float((src >= 0).mean())
    out = col.reshape(th, tw, 3).clip(0, 255).astype(np.uint8)
    return out, cov


def _sanitize(name: str) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in name)[:40] or "piano"


def bake_planes(mesh_path: str, poses: dict, photos_dir: str, planes_doc: dict,
                out_dir: str, texel_mm: float = 8.0, max_photos: int = 80,
                occlusion: bool = False, facing_min: float = 0.20,
                crop: float = 0.9, log=print) -> dict:
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
    total_area = 0.0
    lines = [f"Superfici piani — bake ortografico {texel_mm:.0f} mm/texel", ""]
    for i, plane in enumerate(planes, 1):
        nome = plane.get("nome") or plane.get("tipo") or f"piano{i}"
        pf = plane_frame(plane, up_world, V, faces, texel_m)
        if pf is None:
            log(f"  piano {i} ({nome}): degenere/senza triangoli → salto")
            continue
        img, cov = bake_plane(pf, cams, photos_dir, diag, occ,
                              np.asarray(plane["normale"], float),
                              facing_min=facing_min, max_photos=max_photos, crop=crop)
        area = pf.width_m * pf.height_m
        total_area += area
        fname = f"plane_{i}_{_sanitize(nome)}.png"
        cv2.imwrite(os.path.join(out_dir, fname), img[:, :, ::-1])   # RGB→BGR per cv2
        log(f"  piano {i} ({nome}): {pf.tex_w}x{pf.tex_h}px  "
            f"{pf.width_m:.2f}x{pf.height_m:.2f}m  area {area:.2f} m²  copertura {cov*100:.0f}%")
        lines.append(f"plane_{i}_{nome:<16.16s} {pf.width_m:6.2f} x {pf.height_m:6.2f} m "
                     f"{area:8.2f} m²   copertura {cov*100:3.0f}%")
        results.append({"index": i, "nome": nome, "file": fname,
                        "width_m": round(pf.width_m, 3), "height_m": round(pf.height_m, 3),
                        "tex_w": pf.tex_w, "tex_h": pf.tex_h,
                        "area_m2": round(area, 2), "coverage": round(cov, 3)})
    lines += ["", f"TOTALE {total_area:8.2f} m²"]
    with open(os.path.join(out_dir, "_superfici.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")

    return {"planes": results, "total_area_m2": round(total_area, 2),
            "out_dir": out_dir, "count": len(results)}
