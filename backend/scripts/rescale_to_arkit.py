"""Riporta l'output Meshroom in SCALA METRICA REALE allineandolo alle pose ARKit.

L'incrementalSfM non fissa la gauge globale (scala+rotazione+traslazione) delle pose
iniettate: la geometria resta corretta ma "rimpicciolita" di un fattore arbitrario.
Questo script calcola la similarità (Umeyama) tra i centri-camera SfM e quelli ARKit
iniettati, e la applia a una mesh/nuvola, scrivendo l'output in metri reali.

Uso sul pod, in coda alla pipeline:
  python3 rescale_to_arkit.py <withPoses.sfm> <sfm.sfm> <input_mesh.obj/.ply> <output>
  # withPoses.sfm = pose ARKit metriche (target)
  # sfm.sfm       = pose stimate da incrementalSfM (source, scala sbagliata)

Solo numpy (niente Supabase). Funziona su .obj e .ply (ascii/binary via piccolo parser).
"""
import sys, json, re
import numpy as np


def centers_by_view(sfm_path):
    """viewId -> camera center, da un file sfmData AliceVision (json)."""
    d = json.load(open(sfm_path))
    pose_c = {}
    for p in d.get("poses", []):
        c = p["pose"]["transform"]["center"]
        pose_c[p["poseId"]] = np.array([float(x) for x in c])
    out = {}
    for v in d.get("views", []):
        pid = v.get("poseId")
        if pid in pose_c:
            out[v["viewId"]] = pose_c[pid]
    return out


def umeyama(src, dst):
    """trova s,R,t con  s*R*src + t ~= dst  (similarità, con scala)."""
    ms, md = src.mean(0), dst.mean(0)
    sc, dc = src - ms, dst - md
    H = sc.T @ dc / len(src)
    U, S, Vt = np.linalg.svd(H)
    d = np.sign(np.linalg.det(Vt.T @ U.T))
    R = Vt.T @ np.diag([1, 1, d]) @ U.T
    s = (S * np.array([1, 1, d])).sum() / (sc ** 2).sum() * len(src)
    t = md - s * R @ ms
    return s, R, t


def compute_transform(withposes_sfm, sfm_sfm):
    ark = centers_by_view(withposes_sfm)   # target (metrico)
    est = centers_by_view(sfm_sfm)         # source (scala SfM)
    common = sorted(set(ark) & set(est))
    if len(common) < 3:
        raise SystemExit(f"troppe poche camere comuni ({len(common)})")
    A = np.array([ark[v] for v in common])
    B = np.array([est[v] for v in common])
    s, R, t = umeyama(B, A)
    res = np.linalg.norm((s * (R @ B.T).T + t) - A, axis=1)
    print(f"[rescale] camere accoppiate {len(common)} | scala {s:.3f}x | "
          f"residuo medio {res.mean()*1000:.1f}mm max {res.max()*1000:.1f}mm")
    return s, R, t


def apply_obj(inp, out, s, R, t):
    with open(inp) as f, open(out, "w") as g:
        for line in f:
            if line.startswith("v "):
                p = line.split()
                xyz = np.array([float(p[1]), float(p[2]), float(p[3])])
                x, y, z = s * (R @ xyz) + t
                g.write(f"v {x:.6f} {y:.6f} {z:.6f}" + (" " + " ".join(p[4:]) if len(p) > 4 else "") + "\n")
            else:
                g.write(line)


def apply_ply_ascii(inp, out, s, R, t):
    lines = open(inp).read().splitlines()
    hdr_end = next(i for i, l in enumerate(lines) if l.strip() == "end_header")
    nv = next(int(l.split()[-1]) for l in lines[:hdr_end] if l.startswith("element vertex"))
    g = open(out, "w")
    g.write("\n".join(lines[:hdr_end + 1]) + "\n")
    body = lines[hdr_end + 1:]
    for i, l in enumerate(body):
        if i < nv and l.strip():
            p = l.split()
            xyz = np.array([float(p[0]), float(p[1]), float(p[2])])
            x, y, z = s * (R @ xyz) + t
            g.write(f"{x:.6f} {y:.6f} {z:.6f}" + (" " + " ".join(p[3:]) if len(p) > 3 else "") + "\n")
        else:
            g.write(l + "\n")
    g.close()


if __name__ == "__main__":
    withposes, sfm, inp, out = sys.argv[1:5]
    s, R, t = compute_transform(withposes, sfm)
    if inp.lower().endswith(".ply"):
        apply_ply_ascii(inp, out, s, R, t)
    else:
        apply_obj(inp, out, s, R, t)
    print(f"[rescale] scritto {out} (scala reale, metri)")
