# Camera projection (projection mapping) — stato e procedura

Riproiettare le foto ARKit sulla geometria/sul piano **dalla camera che le ha
scattate**, in stile Maya/3ds Max: la texture si "drappeggia" dal punto di vista
della camera, **senza usare le UV della mesh** → niente deformazione da UV.

Verità di fondo (dimostrata): la proiezione è **non deformata se la guardi dalla
camera che proietta**. Da altri angoli vedi la *forma* della geometria; se la mesh è
rumorosa (OC ±5 cm), la texture drappeggiata mostra quel rumore. Su un **piano liscio**
non c'è rumore → ortofoto piatta (è la direzione di produzione).

## Math (convenzione OC, validata)
Per ogni frammento, posizione mondo `G`, camera `(C, R, intrinsics fx,fy,cx,cy)`:
```
d  = G - C
Pc = R^T d            // R colonne = assi camera in world (da quaternione wxyz)
z  = -Pc.z            // forward = -Z (OC/ARKit)
u  = (fx*focalScale)*Pc.x/z + cx + shiftX
v  = (fy*focalScale)*Pc.y/z + cy + shiftY
texCoord = (u/imgW, 1 - v/imgH)   // flipV
```
- Le **pose OC** (`oc_poses_nobbox.json`) sono GIÀ nel frame della mesh OC → niente
  Umeyama, niente RANSAC: proiezione diretta.
- `flipV = 1` (le foto OC), e nella vista la camera ha `up ≈ -Y` → `up.negate()`.
- `shiftX/shiftY/focalScale` = micro-calibrazione per-foto (vedi auto-align).

## I viewer (in `web/`, three.js via CDN)
Servire la cartella DATI con un server statico e aprire l'URL (NON file://, serve
WebGL + fetch). Es. `python3 -m http.server 8781`.

- **camera_projection_single.html** (`proj_test`): una foto proiettata sulla mesh,
  `?idx=NNN`, tasto `v` flip-V. Prova base.
- **camera_projection_multi.html** (`proj_multi`): N foto, **un pulsante per foto**
  (on/off), **Vista frontale**, **Wireframe**, **▶ vista-da-camera** (prova che dalla
  camera la proiezione è piatta), best-view per frammento. `?mesh=...` per cambiare
  mesh (es. `model_nobbox_smooth30.obj`). MANCA: occlusione (depth dal proiettore).
- **oc_projection_compare.html**: confronto **OC-render vs foto** dalla stessa camera,
  modi Texture/Bianco/Proiezione/Blend, slider shift/focal, **Auto shift foto**.

## Auto-align (Auto shift foto) — criterio robusto
Stima SOLO `shiftX, shiftY, focalScale` (niente pose 3D, niente warp, niente feature
match globale che aggancia finestre sbagliate). Algoritmo (in
`oc_projection_compare.html`, funzione `autoShiftCurrentPhoto`):
1. Rende **OC** e **foto-proiettata** dalla **stessa camera** attraverso lo **shader
   vero** (mode `project`) → `focalScale`/`shift` modellati esattamente come in
   produzione (NO foto ridisegnata scalata attorno al centro: era il bug del vecchio).
2. Confronto a risoluzione decente (downscale 2), metrica = **NCC dei bordi (75%) +
   NCC grigio (25%)** sulle zone coperte/strutturate (robusta all'esposizione).
3. **Hill-climb locale** partito dalla calibrazione manuale, passo 6→3→1 px e
   0.004→0.001 focal, **vincolato a ±70 px / ±0.035** → non può saltare di una
   finestra. Applica solo se migliora davvero.
Verificato su foto 90: manuale (0, 79, 1.018) → auto **(1, 78, 1.018)** (il vecchio
degradava a −16, 40, 1.011). Regge anche su altre foto.

## Dati attesi nella cartella (NON nel repo — working dir / object storage)
`~/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/`:
- `model_nobbox_webgl_flipv.glb` (usdz_to_glb.py --flip-v sulla mesh nobbox)
- `model_nobbox.obj`, `oc_poses_nobbox.json`, `model_nobbox_photo_cam.json`
- `photos_web/NNNN.jpg` (sottoinsieme delle foto ARKit)

## Prossimi passi
- **Occlusione** (depth map dal proiettore, stile shadow mapping) → pulisce bordi/
  smearing nel multi-camera.
- **Proiezione sul PIANO** (quad liscio orientato come la facciata) invece che sulla
  mesh → ortofoto piatta non deformata (chiude il cerchio con la pipeline metrica).
- Smoothing/planarizzazione mesh come ripiego se si resta sulla mesh.
