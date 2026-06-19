# -*- coding: utf-8 -*-
# Rilevazione piani sul modello 3D per REGION GROWING (regioni connesse + normale).
# A differenza del RANSAC "per dominanza", segue la CONNETTIVITA': il muro grande
# resta un'unica regione, mentre torrette/spallette/ali (separate da uno spigolo dove
# la normale cambia) escono come piani distinti anche se piccoli. Vincolo gravita' per
# classificare verticale/orizzontale. Output: PLY colorato + JSON dei piani + render CPU.
import sys, json, time, numpy as np, cv2
from collections import deque, defaultdict

D = "/Users/liscio/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox"
MESH = sys.argv[1] if len(sys.argv) > 1 else f"{D}/model_nobbox.obj"
CAMJSON = f"{D}/model_nobbox_photo_cam.json"
GRAV = np.array([0.027, 0.999, -0.041]); GRAV /= np.linalg.norm(GRAV)   # punta in basso (nobbox)
COS_GROW = 0.90        # ~26°: cresce su facce con normale simile, si ferma sugli spigoli
MIN_FACES = 150        # scarta regioni troppo piccole (rumore)
t0 = time.time(); log = lambda m: print(f"[{time.time()-t0:5.1f}s] {m}", flush=True)

# --- carica OBJ ---
Vs, Fs = [], []
for ln in open(MESH):
    if ln.startswith("v "): Vs.append([float(a) for a in ln.split()[1:4]])
    elif ln.startswith("f "):
        idx = [int(t.split("/")[0]) - 1 for t in ln.split()[1:]]
        for i in range(1, len(idx) - 1): Fs.append([idx[0], idx[i], idx[i + 1]])
V = np.asarray(Vs); F = np.asarray(Fs, np.int64); diag = np.linalg.norm(V.max(0) - V.min(0))
log(f"mesh {len(V)} vtx, {len(F)} facce, diag {diag:.2f}")

# normali e baricentri di faccia
fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
ln_ = np.linalg.norm(fn, axis=1); fn = fn / (ln_[:, None] + 1e-12)
fc = V[F].mean(1)
OFF_TOL = 0.015 * diag  # tolleranza planarita' (offset dal piano della regione)

# adiacenza facce: weld vertici (arrotonda) -> spigoli condivisi
key = np.round(V / (1e-3 * diag)).astype(np.int64)
uniq = {}; vid = np.empty(len(V), np.int64)
for i, k in enumerate(map(tuple, key)):
    j = uniq.get(k)
    if j is None: j = len(uniq); uniq[k] = j
    vid[i] = j
em = defaultdict(list)
for f in range(len(F)):
    a, b, c = vid[F[f, 0]], vid[F[f, 1]], vid[F[f, 2]]
    for x, y in ((a, b), (b, c), (c, a)):
        em[(min(x, y), max(x, y))].append(f)
adj = [[] for _ in range(len(F))]
for arr in em.values():
    if len(arr) >= 2:
        for i in range(len(arr)):
            for j in range(i + 1, len(arr)):
                adj[arr[i]].append(arr[j]); adj[arr[j]].append(arr[i])
log("adiacenza pronta")

# --- region growing ---
lab = np.full(len(F), -1, np.int64)
regions = []
for seed in range(len(F)):
    if lab[seed] != -1: continue
    rid = len(regions)
    mean_n = fn[seed].copy(); mean_c = fc[seed].copy(); cnt = 1
    lab[seed] = rid; q = deque([seed]); members = [seed]
    while q:
        f = q.popleft()
        for g in adj[f]:
            if lab[g] != -1: continue
            if np.dot(fn[g], mean_n) < COS_GROW: continue              # normale simile
            if abs(np.dot(fc[g] - mean_c, mean_n)) > OFF_TOL: continue # resta planare
            lab[g] = rid; members.append(g); q.append(g)
            cnt += 1; w = 1.0 / cnt
            mean_n = mean_n * (1 - w) + fn[g] * w; mean_n /= np.linalg.norm(mean_n)
            mean_c = mean_c * (1 - w) + fc[g] * w
    regions.append(dict(faces=np.array(members), n=mean_n, c=mean_c))
log(f"regioni grezze: {len(regions)}")

# filtra piccole; fit finale del piano (SVD sui baricentri)
kept = []
for r in regions:
    if len(r["faces"]) < MIN_FACES: continue
    P = fc[r["faces"]]; c = P.mean(0)
    _, _, vt = np.linalg.svd(P - c); n = vt[2]; n /= np.linalg.norm(n)
    if n[1] < 0: n = -n
    ang_grav = np.degrees(np.arccos(np.clip(abs(np.dot(n, GRAV)), 0, 1)))
    kind = "ORIZZONTALE" if ang_grav < 25 else ("VERTICALE" if ang_grav > 65 else "obliquo")
    kept.append(dict(faces=r["faces"], n=n, c=c, d=float(-np.dot(n, c)),
                     nfaces=int(len(r["faces"])), ang_grav=float(ang_grav), kind=kind))
# --- MERGE globale: unisci patch COMPLANARI (stessa normale + stessa quota d),
# anche se non connesse -> il muro spezzato dalle finestre torna un piano unico,
# ma finestre rientranti / cornicioni sporgenti (stessa n, d diverso) restano a parte,
# e ali/torrette (n diversa) pure.
DTOL = 0.05 * diag   # ~50cm: assorbe bugnato/cornici/finestre come stesso muro (rilievo δ),
                     # ma tiene separati muri paralleli lontani metri
planes = []
for r in kept:
    for pl in planes:
        if abs(np.dot(r["n"], pl["n"])) > 0.975 and abs(r["d"] - pl["d"]) < DTOL:
            pl["faces"] = np.concatenate([pl["faces"], r["faces"]]); break
    else:
        planes.append(dict(faces=r["faces"].copy(), n=r["n"].copy(), d=r["d"]))
# ri-fit finale di ogni piano unito
kept = []
for pl in planes:
    if len(pl["faces"]) < MIN_FACES: continue
    P = fc[pl["faces"]]; c = P.mean(0)
    _, _, vt = np.linalg.svd(P - c); n = vt[2]; n /= np.linalg.norm(n)
    if n[1] < 0: n = -n
    ang = np.degrees(np.arccos(np.clip(abs(np.dot(n, GRAV)), 0, 1)))
    kind = "ORIZZONTALE" if ang < 25 else ("VERTICALE" if ang > 65 else "obliquo")
    kept.append(dict(faces=pl["faces"], n=n, c=c, d=float(-np.dot(n, c)),
                     nfaces=int(len(pl["faces"])), ang_grav=float(ang), kind=kind))
kept.sort(key=lambda r: -r["nfaces"])
log(f"piani dopo merge: {len(kept)}")
for i, r in enumerate(kept[:14]):
    print(f"  P{i:>2}: {r['nfaces']:>6} facce  n={np.round(r['n'],2)}  {r['kind']}  (ang.grav {r['ang_grav']:.0f}°)")

# colora i vertici per regione
pal = (np.array([[90,230,90],[40,140,255],[240,200,40],[240,90,200],[40,230,230],[160,120,255],
                 [255,150,50],[120,255,150],[255,80,80],[170,170,255],[230,230,90],[100,210,230],
                 [200,120,80],[120,230,120]])/255.0)
vcol = np.full((len(V), 3), 0.16)
for i, r in enumerate(kept):
    vidx = np.unique(F[r["faces"]].ravel()); vcol[vidx] = pal[i % len(pal)]

# salva PLY + JSON
import struct
tris = F
with open(f"{D}/planes_rg.ply", "wb") as f:
    f.write(b"ply\nformat binary_little_endian 1.0\n"); f.write(f"element vertex {len(V)}\n".encode())
    f.write(b"property float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\n")
    f.write(f"element face {len(tris)}\n".encode()); f.write(b"property list uchar int vertex_indices\nend_header\n")
    cc = (vcol*255).astype(np.uint8)
    for i in range(len(V)): f.write(struct.pack("<fff", *V[i]) + struct.pack("<BBB", *cc[i]))
    for t in tris: f.write(struct.pack("<B", 3) + struct.pack("<iii", *t))
json.dump([{k: (r[k] if k not in ("n","c") else r[k].tolist()) for k in ("nfaces","kind","ang_grav","n","c","d")} for r in kept],
          open(f"{D}/planes_rg.json", "w"), indent=2)

# render CPU frontale
cam = json.load(open(CAMJSON)); n = np.array(cam["view_dir"]); n /= np.linalg.norm(n)
up = np.array([0,-1,0.0]); right = np.cross(n, up); right/=np.linalg.norm(right); up = np.cross(right, n); up/=np.linalg.norm(up)
c = V.mean(0); d = V - c; x = d@right; y = d@up; z = d@n; W, H = 1200, 1000; p = 0.06
px = (p+(1-2*p)*(x-x.min())/(x.max()-x.min()))*W; py = (p+(1-2*p)*(1-(y-y.min())/(y.max()-y.min())))*H
img = np.full((H, W, 3), 0.12); zb = np.full((H, W), -1e9)
for i in np.argsort(z):
    a, b = int(px[i]), int(py[i])
    if 0 <= a < W and 0 <= b < H:
        for da in (-1,0,1):
            for db in (-1,0,1):
                aa, bb = a+da, b+db
                if 0 <= aa < W and 0 <= bb < H and z[i] > zb[bb, aa]: zb[bb, aa] = z[i]; img[bb, aa] = vcol[i, ::-1]
cv2.imwrite("/tmp/planes_rg.png", (img*255).astype(np.uint8))
log("scritto planes_rg.ply, planes_rg.json, /tmp/planes_rg.png")
