#!/usr/bin/env python3
"""Prototipo (isolato) del rilevamento piani a ISTOGRAMMI nel sistema di assi
dell'edificio (BCS), come da pipeline Gemini + nostre regole.

NON tocca l'app: legge un OBJ metrico (es. la mesh ripulita), stima gli assi
dell'edificio dalle normali (up + direzioni dominanti dei muri, anche oblique),
e per ogni direzione fa un istogramma 1D pesato per area lungo la profondità.
I picchi = piani; quad dai percentili 5/95; balconi/cornici scartati per area.

Uso:
  backend/venv/bin/python backend/scripts/proto_planes_histogram.py \
      ios/Acrobatica/Resources/facciata_demo.obj --out /tmp/piani_proto

Output:
  - stampa i piani trovati (direzione, offset, larghezza×altezza, area, tipo)
  - <out>.json   (i quad)
  - <out>.obj    (i quad come geometria, per vederli sovrapposti alla mesh)
"""
import argparse
import json
import math
import sys

import numpy as np


# ----------------------------- IO -----------------------------

def carica_obj(path):
    """Legge vertici e triangoli (1-indexed, 'f a b c' o 'f a/.. b/.. c/..')."""
    verts, tris = [], []
    with open(path, "r") as f:
        for line in f:
            if line.startswith("v "):
                _, x, y, z = line.split()[:4]
                verts.append((float(x), float(y), float(z)))
            elif line.startswith("f "):
                idx = [int(tok.split("/")[0]) for tok in line.split()[1:]]
                # triangola un'eventuale faccia poligonale (fan)
                for k in range(1, len(idx) - 1):
                    tris.append((idx[0] - 1, idx[k] - 1, idx[k + 1] - 1))
    return np.asarray(verts, dtype=np.float64), np.asarray(tris, dtype=np.int64)


def scrivi_obj_quads(path, quads, nome="bcs_planes"):
    """Scrive i quad come OBJ (4 vertici + 2 triangoli per quad, un gruppo
    per piano). Il winding dei triangoli segue l'ordine dei corner, quindi
    la normale OBJ coincide con `dir` del quad."""
    with open(path, "w") as f:
        f.write(f"o {nome}\n")
        base = 1
        for i, q in enumerate(quads):
            f.write(f"g plane_{i+1}_{q['tipo']}\n")
            for v in q["corners"]:
                f.write(f"v {v[0]:.5f} {v[1]:.5f} {v[2]:.5f}\n")
            f.write(f"f {base} {base+1} {base+2}\n")
            f.write(f"f {base} {base+2} {base+3}\n")
            base += 4


# ----------------------- geometria di base -----------------------

def normali_aree_centroidi(verts, tris):
    a = verts[tris[:, 0]]
    b = verts[tris[:, 1]]
    c = verts[tris[:, 2]]
    cross = np.cross(b - a, c - a)
    norm = np.linalg.norm(cross, axis=1)
    area = 0.5 * norm
    n = np.zeros_like(cross)
    ok = norm > 1e-12
    n[ok] = cross[ok] / norm[ok, None]
    cen = (a + b + c) / 3.0
    return n, area, cen


def stima_up(normals, areas):
    """Up = direzione che le normali dei muri EVITANO (autovettore covarianza,
    autovalore minimo). Segno verso +Y mondo. Robust al terreno inclinato."""
    w = areas[:, None]
    cov = (normals * w).T @ normals
    vals, vecs = np.linalg.eigh(cov)
    up = vecs[:, 0]            # autovalore più piccolo
    if up[1] < 0:
        up = -up
    return up / np.linalg.norm(up)


def assi_da_pca(verts):
    """Frame della facciata dalla PCA delle POSIZIONI: una facciata è sottile in
    profondità → asse di minima varianza = normale; asse medio = verticale;
    asse massimo = larghezza. Robusto a mesh acquisite storte (assi inclinati)."""
    ctr = verts.mean(0)
    Q = verts - ctr
    val, vec = np.linalg.eigh(Q.T @ Q)   # autovalori crescenti
    d = vec[:, 0]          # min varianza → normale facciata
    up = vec[:, 1]         # media → verticale
    if up[1] < 0:          # orienta verso l'alto (Y mondo come riferimento debole)
        up = -up
    right = np.cross(up, d); right /= (np.linalg.norm(right) + 1e-12)
    d = np.cross(right, up); d /= (np.linalg.norm(d) + 1e-12)   # ortonormale coerente
    return d, up, right


def normale_facciata(normals, areas, up, ang_tol_deg):
    """Per una mesh di UNA sola facciata: normale = media pesata per area delle
    normali verticali, riportate tutte nello stesso emisfero. Robusta e precisa."""
    cos_up = np.abs(normals @ up)
    vert = cos_up < math.sin(math.radians(ang_tol_deg))
    nv = normals[vert]
    av = areas[vert]
    if av.sum() <= 0:
        return None, None
    ref = nv[np.argmax(av)]                       # normale della faccia più grande
    flip = (nv @ ref) < 0
    nv = nv.copy(); nv[flip] = -nv[flip]          # stesso emisfero
    d = (nv * av[:, None]).sum(0)
    d = d - (d @ up) * up                         # rendi orizzontale
    d /= (np.linalg.norm(d) + 1e-12)
    right = np.cross(up, d); right /= (np.linalg.norm(right) + 1e-12)
    return d, right


def direzioni_muri(normals, areas, up, ang_tol_deg, n_dir=4, min_frazione=0.04):
    """Direzioni-normale dominanti dei muri verticali: istogramma circolare
    (0..180°) degli angoli delle normali orizzontali, pesato per area."""
    cos_up = np.abs(normals @ up)
    vert = cos_up < math.sin(math.radians(ang_tol_deg))   # ~verticale
    nh = normals[vert] - np.outer(normals[vert] @ up, up)  # parte orizzontale
    lens = np.linalg.norm(nh, axis=1)
    ok = lens > 1e-6
    nh = nh[ok] / lens[ok, None]
    w = areas[vert][ok]
    # base ortonormale orizzontale (e0, e1)
    e0 = np.cross(up, [0, 0, 1.0])
    if np.linalg.norm(e0) < 1e-4:
        e0 = np.cross(up, [1.0, 0, 0])
    e0 /= np.linalg.norm(e0)
    e1 = np.cross(up, e0)
    ang = (np.arctan2(nh @ e1, nh @ e0)) % math.pi   # 0..π (±n stesso muro)
    nb = 180
    hist, edges = np.histogram(ang, bins=nb, range=(0, math.pi), weights=w)
    # smussa (circolare) e prendi i picchi
    k = np.array([1, 2, 3, 2, 1.0]); k /= k.sum()
    hs = np.convolve(np.r_[hist[-2:], hist, hist[:2]], k, "same")[2:-2]
    tot = hs.sum()
    picchi = []
    for i in range(nb):
        if hs[i] >= hs[(i - 1) % nb] and hs[i] >= hs[(i + 1) % nb] and hs[i] > tot * min_frazione:
            picchi.append((hs[i], (edges[i] + edges[i + 1]) / 2))
    picchi.sort(reverse=True)
    dirs = []
    for _, a in picchi[:n_dir]:
        d = math.cos(a) * e0 + math.sin(a) * e1
        # evita duplicati ~paralleli
        if all(abs(d @ x) < 0.97 for x in dirs):
            dirs.append(d / np.linalg.norm(d))
    return dirs, e0, e1


# ----------------------- pipeline a istogrammi -----------------------

def cluster_contigui(values, weights, bin_m, max_gap, floor_frac=0.02):
    """Raggruppa `values` (pesati per area) in cluster contigui lungo un asse:
    bin-izza, tieni i bin sopra una soglia, unisci i contigui colmando vuoti
    fino a `max_gap` bin. Ritorna lista di (lo, hi) negli stessi valori."""
    lo, hi = float(values.min()), float(values.max())
    nb = max(1, int(math.ceil((hi - lo) / bin_m)))
    hist, edges = np.histogram(values, bins=nb, range=(lo, hi + 1e-6), weights=weights)
    floor = max(hist.max() * floor_frac, 1e-9)
    occ = hist > floor
    out = []
    i = 0
    while i < nb:
        if not occ[i]:
            i += 1; continue
        j = i; gap = 0; end = i
        while j < nb:
            if occ[j]:
                end = j; gap = 0
            else:
                gap += 1
                if gap > max_gap:
                    break
            j += 1
        out.append((edges[i], edges[end + 1]))
        i = j
    return out


def piani_lungo_asse(axis, e_h, e_v, tipo, normals, areas, cen, verts_all,
                     ang_tol_deg, bin_m, min_area_m2, perc,
                     max_gap_prof=3, max_gap_oriz=4, pad_m=0.0):
    """Istogramma della profondità lungo `axis` (normale dei piani cercati), poi
    split lungo `e_h`. Il quad finale è nel piano (e_h, e_v). `tipo` = etichetta.
    Generalizza le 3 viste: fronte (axis=normale), lato (axis=right), alto (axis=up)."""
    sel = np.abs(normals @ axis) > math.cos(math.radians(ang_tol_deg))   # facce ~⊥ ad axis
    if sel.sum() == 0:
        return []
    idx_sel = np.where(sel)[0]
    depth = cen[sel] @ axis
    a = areas[sel]
    hcoord = cen[sel] @ e_h
    piani = []

    def quad_da(face_idx):
        if face_idx.size == 0:
            return None
        ar = float(areas[face_idx].sum())
        if ar < min_area_m2:
            return None
        vid = np.unique(tris_global[face_idx].reshape(-1))
        P = verts_all[vid]
        x = P @ e_h; y = P @ e_v; zc = P @ axis
        minx, maxx = np.percentile(x, perc[0]), np.percentile(x, perc[1])
        miny, maxy = np.percentile(y, perc[0]), np.percentile(y, perc[1])
        minx -= pad_m
        maxx += pad_m
        miny -= pad_m
        maxy += pad_m
        off = float(zc.mean())
        # verso "fuori dal muro" del cluster: maggioranza (pesata per area)
        # delle normali mesh lungo axis — le facce OC guardano verso le camere
        s = float(((normals[face_idx] @ axis) * areas[face_idx]).sum())
        def P3(xx, yy): return (e_h * xx + e_v * yy + axis * off).tolist()
        return {"tipo": tipo, "dir": axis.tolist(), "offset": off, "area_m2": ar,
                "verso_mesh": 1.0 if s >= 0 else -1.0,
                "w": float(maxx - minx), "h": float(maxy - miny),
                "centro": (e_h*(minx+maxx)/2 + e_v*(miny+maxy)/2 + axis*off).tolist(),
                "corners": [P3(minx, miny), P3(maxx, miny), P3(maxx, maxy), P3(minx, maxy)]}

    for (z0, z1) in cluster_contigui(depth, a, bin_m, max_gap_prof):
        md = (depth >= z0 - bin_m) & (depth <= z1 + bin_m)
        if md.sum() == 0:
            continue
        for (h0, h1) in cluster_contigui(hcoord[md], a[md], bin_m, max_gap_oriz):
            mh = md & (hcoord >= h0 - bin_m) & (hcoord <= h1 + bin_m)
            q = quad_da(idx_sel[mh])
            if q is not None:
                piani.append(q)
    return piani


def intersezione_piani(qA, qB, up):
    """Spigolo (segmento) = intersezione dei piani qA e qB, clippato all'altezza
    condivisa lungo `up`. Ritorna (p0, p1) o None se ~paralleli o senza overlap."""
    nA = np.asarray(qA["dir"]); nB = np.asarray(qB["dir"])
    cA = np.asarray(qA["centro"]); cB = np.asarray(qB["centro"])
    dirL = np.cross(nA, nB); L = np.linalg.norm(dirL)
    if L < 0.2:                       # quasi paralleli → niente spigolo
        return None
    dirL /= L
    M = np.array([nA, nB, dirL]); b = np.array([nA @ cA, nB @ cB, 0.0])
    try:
        p = np.linalg.solve(M, b)
    except np.linalg.LinAlgError:
        return None
    # overlap in altezza: proietta i corner dei due quad su up, interseca i range
    def vrange(q):
        ys = [np.asarray(c) @ up for c in q["corners"]]
        return min(ys), max(ys)
    a0, a1 = vrange(qA); b0, b1 = vrange(qB)
    lo = max(a0, b0); hi = min(a1, b1)
    if hi - lo < 1e-3:
        return None
    pu = p @ up
    return ((p + dirL * (lo - pu)).tolist(), (p + dirL * (hi - pu)).tolist())


def bounds_su_assi(q, e_h, e_v):
    P = np.asarray(q["corners"], dtype=np.float64)
    h = P @ e_h
    v = P @ e_v
    return float(h.min()), float(h.max()), float(v.min()), float(v.max())


def snap_bound(value, candidates, tol_m):
    """Porta un limite sul candidato più vicino, solo se è entro tolleranza."""
    if not candidates:
        return value
    best = min(candidates, key=lambda x: abs(x - value))
    return float(best) if abs(best - value) <= tol_m else value


def quad_da_bounds(q, axis, e_h, e_v, h0, h1, v0, v1):
    """Ricostruisce il quad mantenendo direzione/offset, ma con bounds regolarizzati."""
    off = float(q["offset"])

    def P3(hh, vv):
        return (e_h * hh + e_v * vv + axis * off).tolist()

    out = dict(q)
    out["w"] = float(h1 - h0)
    out["h"] = float(v1 - v0)
    out["centro"] = (e_h * (h0 + h1) / 2 + e_v * (v0 + v1) / 2 + axis * off).tolist()
    out["corners"] = [P3(h0, v0), P3(h1, v0), P3(h1, v1), P3(h0, v1)]
    out["regularized"] = True
    return out


def regolarizza_piani_verticali(piani, up, d_main, right, snap_m=1.25):
    """Fase post-detection: trasforma cluster indipendenti in piani più edilizi.

    - tutti i piani verticali condividono la stessa quota bassa/alta;
    - le facciate si estendono fino agli offset delle spallette vicine;
    - le spallette si estendono fino agli offset delle facciate vicine.

    Non decide ancora quali piani eliminare: rende solo i quad più coerenti e
    snappabili tra loro.
    """
    verticali = [p for p in piani if p["tipo"] in ("facciata", "spalla")]
    if not verticali:
        return piani

    vertical_bounds = []
    for p in verticali:
        _, _, v0, v1 = bounds_su_assi(p, right if p["tipo"] == "facciata" else d_main, up)
        vertical_bounds.append((p, v0, v1, v1 - v0))
    max_h = max(h for _, _, _, h in vertical_bounds)
    # La regolarizzazione va applicata solo ai piani edilizi. Piccoli cluster
    # bassi/isolati (auto, arredo urbano, rumore) non devono essere stirati a
    # tutta altezza.
    edifici = [p for p, v0, _, h in vertical_bounds if h >= max_h * 0.45 or v0 > 1.5]
    if not edifici:
        return piani

    vmins, vmaxs = [], []
    for p in edifici:
        _, _, v0, v1 = bounds_su_assi(p, right if p["tipo"] == "facciata" else d_main, up)
        vmins.append(v0)
        vmaxs.append(v1)
    v0_common = float(min(vmins))
    v1_common = float(max(vmaxs))

    front_offsets = [float(p["offset"]) for p in edifici if p["tipo"] == "facciata"]
    side_offsets = [float(p["offset"]) for p in edifici if p["tipo"] == "spalla"]

    out = []
    for p in piani:
        if p not in edifici:
            q = dict(p)
            q["regularized"] = False
            q["regularize_skip"] = "non_edificio"
            out.append(q)
            continue
        if p["tipo"] == "facciata":
            h0, h1, _, _ = bounds_su_assi(p, right, up)
            h0 = snap_bound(h0, side_offsets, snap_m)
            h1 = snap_bound(h1, side_offsets, snap_m)
            if h1 < h0:
                h0, h1 = h1, h0
            out.append(quad_da_bounds(p, d_main, right, up, h0, h1, v0_common, v1_common))
        elif p["tipo"] == "spalla":
            h0, h1, _, _ = bounds_su_assi(p, d_main, up)
            h0 = snap_bound(h0, front_offsets, snap_m)
            h1 = snap_bound(h1, front_offsets, snap_m)
            if h1 < h0:
                h0, h1 = h1, h0
            out.append(quad_da_bounds(p, right, d_main, up, h0, h1, v0_common, v1_common))
        else:
            out.append(p)
    return out


def orienta_quads(piani, cam_centroid=None):
    """Rende coerente il verso di ogni quad: `dir` punta FUORI dal muro e il
    winding dei corner segue `dir` (normale = cross(c1-c0, c3-c0)).

    Verso scelto con la maggioranza delle normali mesh del cluster
    (`verso_mesh`, calcolato in quad_da); se `cam_centroid` è dato, vince
    invece il baricentro delle posizioni camera: flip se
    dot(dir, cam_centroid - centro_piano) < 0. Se `dir` viene ribaltata,
    anche `offset` cambia segno così resta dot(x, dir) = offset.
    Ritorna (n_flip_dir, n_flip_winding)."""
    flip_dir = 0
    flip_wind = 0
    for p in piani:
        n = np.asarray(p["dir"], dtype=np.float64)
        if cam_centroid is not None:
            c = np.asarray(p["centro"], dtype=np.float64)
            segno = 1.0 if float(n @ (cam_centroid - c)) >= 0 else -1.0
        else:
            segno = float(p.pop("verso_mesh", 1.0))
        p.pop("verso_mesh", None)
        if segno < 0:
            n = -n
            p["dir"] = n.tolist()
            p["offset"] = -float(p["offset"])
            flip_dir += 1
        C = np.asarray(p["corners"], dtype=np.float64)
        if float(np.cross(C[1] - C[0], C[3] - C[0]) @ n) < 0:
            p["corners"] = [C[0].tolist(), C[3].tolist(), C[2].tolist(), C[1].tolist()]
            flip_wind += 1
    return flip_dir, flip_wind


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("obj")
    ap.add_argument("--out", default="/tmp/piani_proto")
    ap.add_argument("--ang-tol", type=float, default=20.0)
    ap.add_argument("--bin-frac", type=float, default=0.006,
                    help="dimensione bin = frazione dell'estensione mesh (scala-invariante)")
    ap.add_argument("--min-area-frac", type=float, default=0.02,
                    help="area minima picco = frazione dell'area verticale totale")
    ap.add_argument("--perc", type=float, nargs=2, default=[5.0, 95.0])
    ap.add_argument("--side-perc", type=float, nargs=2, default=[2.0, 98.0],
                    help="percentili per spallette/lati; larghi per non tagliare i bordi")
    ap.add_argument("--pad-m", type=float, default=0.15,
                    help="margine metrico aggiunto ai quad ricostruiti")
    ap.add_argument("--min-width-m", type=float, default=0.4,
                    help="scarta i piani con un lato < soglia (rimuove i degeneri ~0 m)")
    ap.add_argument("--no-regularize", action="store_true",
                    help="disabilita uniformazione altezze e snap su intersezioni")
    ap.add_argument("--snap-m", type=float, default=1.25,
                    help="tolleranza metrica per snap dei bordi su piani perpendicolari")
    ap.add_argument("--up", type=float, nargs=3, default=None,
                    help="up NOTO (gravità), es. --up 0 1 0. Salta la stima PCA (fragile su "
                         "mesh rumorose): per le mesh OC/ARKit la gravità è Y → piani dritti.")
    ap.add_argument("--axes-json", help="JSON con plane.n / plane.up / plane.right da usare come BCS")
    ap.add_argument("--transform-json", help="JSON con matrix_row_major da applicare ai vertici OBJ prima del fitting")
    ap.add_argument("--cameras-json", help="JSON pose camere (id -> {translation:[x,y,z]}, es. oc_poses_nobbox.json); "
                                           "orienta i quad verso il baricentro camere (stesso frame dell'OBJ, "
                                           "--transform-json viene applicato anche a loro)")
    ap.add_argument("--include-horizontal", action="store_true",
                    help="include anche piani orizzontali; per facciate resta spento di default")
    args = ap.parse_args()

    verts, tris = carica_obj(args.obj)
    M = None
    if args.transform_json:
        with open(args.transform_json, "r") as f:
            tr_data = json.load(f)
        M = np.asarray(tr_data["matrix_row_major"], dtype=np.float64)
        verts = (M[:3, :3] @ verts.T).T + M[:3, 3]
        print(f"trasformazione vertici da: {args.transform_json}")

    cam_centroid = None
    if args.cameras_json:
        with open(args.cameras_json, "r") as f:
            poses = json.load(f)
        it = poses.values() if isinstance(poses, dict) else poses
        cam_pos = np.asarray([p["translation"] for p in it], dtype=np.float64)
        if M is not None:
            cam_pos = (M[:3, :3] @ cam_pos.T).T + M[:3, 3]
        cam_centroid = cam_pos.mean(0)
        print(f"camere: {len(cam_pos)}  baricentro=[{cam_centroid[0]:.2f} "
              f"{cam_centroid[1]:.2f} {cam_centroid[2]:.2f}]")
    global tris_global
    tris_global = tris
    print(f"mesh: {len(verts)} vertici, {len(tris)} triangoli")

    normals, areas, cen = normali_aree_centroidi(verts, tris)
    if args.axes_json:
        with open(args.axes_json, "r") as f:
            axes_data = json.load(f)
        plane = axes_data.get("plane", axes_data)
        d_main = np.asarray(plane["n"], dtype=np.float64)
        up = np.asarray(plane["up"], dtype=np.float64)
        right = np.asarray(plane["right"], dtype=np.float64)
        d_main /= np.linalg.norm(d_main) + 1e-12
        up = up - (up @ d_main) * d_main
        up /= np.linalg.norm(up) + 1e-12
        right = right - (right @ d_main) * d_main - (right @ up) * up
        right /= np.linalg.norm(right) + 1e-12
        d_main = np.cross(right, up)
        d_main /= np.linalg.norm(d_main) + 1e-12
        print(f"assi BCS da: {args.axes_json}")
    elif args.up is not None:
        up = np.asarray(args.up, dtype=np.float64)
        up /= np.linalg.norm(up) + 1e-12
        dn, rt = normale_facciata(normals, areas, up, args.ang_tol)
        if dn is not None:
            d_main, right = dn, rt                    # normale facciata robusta, up = gravità nota
        else:
            d_main, up, right = assi_da_pca(verts)
    else:
        d_main, up, right = assi_da_pca(verts)       # frame robusto dalle posizioni
    estensione = float((verts.max(0) - verts.min(0)).max())
    bin_m = estensione * args.bin_frac
    cos_up = np.abs(normals @ up)
    area_vert = float(areas[cos_up < math.sin(math.radians(args.ang_tol))].sum())
    min_area = area_vert * args.min_area_frac
    print(f"up: [{up[0]:.3f} {up[1]:.3f} {up[2]:.3f}]  estensione={estensione:.2f}  "
          f"bin={bin_m:.3f}  area_vert={area_vert:.1f}  min_area_picco={min_area:.2f}")
    print(f"normale facciata (PCA): [{d_main[0]:.3f} {d_main[1]:.3f} {d_main[2]:.3f}]")

    # 3 viste = 3 istogrammi sugli assi dell'edificio.
    # Fronte: tolleranza ampia (assorbe il rilievo). Lato/alto: SEVERA, così le
    # spalle/orizzontali restano perpendicolari nette e sottili (no rettangoli gonfi).
    fronte = piani_lungo_asse(d_main, right, up, "facciata", normals, areas, cen, verts,
                              args.ang_tol, bin_m, min_area, args.perc, pad_m=args.pad_m)
    lato   = piani_lungo_asse(right, d_main, up, "spalla", normals, areas, cen, verts,
                              12.0, bin_m, min_area, args.side_perc, pad_m=args.pad_m)
    alto = []
    if args.include_horizontal:
        alto = piani_lungo_asse(up, right, d_main, "orizzontale", normals, areas, cen, verts,
                                12.0, bin_m, min_area, args.side_perc, pad_m=args.pad_m)
    piani = fronte + lato + alto
    print(f"  fronte: {len(fronte)}  lato/spalle: {len(lato)}  alto/orizz: {len(alto)}")

    if not args.no_regularize:
        piani = regolarizza_piani_verticali(piani, up, d_main, right, snap_m=args.snap_m)
        print(f"  regolarizzazione: altezze comuni + snap bordi entro {args.snap_m:.2f} m")

    # spigoli precisi = intersezione facciata ∩ spalla
    spigoli = []
    for f in fronte:
        for s in lato:
            seg = intersezione_piani(f, s, up)
            if seg is not None:
                spigoli.append({"p0": seg[0], "p1": seg[1]})
    print(f"  spigoli (facciata ∩ spalla): {len(spigoli)}")

    # winding coerente: normale fuori dal muro (o verso il baricentro camere)
    fd, fw = orienta_quads(piani, cam_centroid)
    print(f"  orientamento quad: {fd} dir ribaltate, {fw} winding corretti"
          + ("  [baricentro camere]" if cam_centroid is not None else "  [normali mesh]"))

    # scarta i piani degeneri (un lato ~0 = spazzatura da lati sovra-rilevati)
    n0 = len(piani)
    piani = [p for p in piani if p["w"] >= args.min_width_m and p["h"] >= args.min_width_m]
    if len(piani) < n0:
        print(f"  scartati {n0 - len(piani)} piani degeneri (lato < {args.min_width_m} m)")

    # ordina per area decrescente
    piani.sort(key=lambda p: p["area_m2"], reverse=True)
    print(f"\nPIANI TROVATI: {len(piani)}")
    for i, p in enumerate(piani):
        print(f"  #{i+1}  area={p['area_m2']:6.1f} m²  {p['w']:.2f}×{p['h']:.2f} m  "
              f"offset={p['offset']:+.2f}  dir=[{p['dir'][0]:.2f} {p['dir'][1]:.2f} {p['dir'][2]:.2f}]")

    with open(args.out + ".json", "w") as f:
        json.dump({"up": up.tolist(), "d": d_main.tolist(), "right": right.tolist(),
                   "piani": piani, "spigoli": spigoli}, f, indent=2)
    scrivi_obj_quads(args.out + ".obj", piani)
    print(f"\nscritti: {args.out}.json  e  {args.out}.obj")


if __name__ == "__main__":
    main()
