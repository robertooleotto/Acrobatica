"""Rettifica interattiva 2D di un'immagine panorama via 4-tap utente.

Workflow di prodotto pulito (vedi discussione 2026-05-22):
  1. Carica un panorama (composite stitched / orto / qualsiasi immagine 2D).
  2. Mostra in finestra OpenCV.
  3. L'utente clicca 4 punti sul MURO PRINCIPALE (TL → TR → BR → BL).
     ⚠ NON su porte rientrate, vetrine, pensiline o elementi non coplanari.
  4. Calcola e applica cv2.getPerspectiveTransform → warpPerspective.
  5. Mostra il prima/dopo affiancati.
  6. Salva `rectified_facade.jpg` accanto al sorgente.

Uso:
    python scripts/rectify_facade_local.py <path_to_panorama.jpg>
    python scripts/rectify_facade_local.py /tmp/ortho4tap_a8b096e3/00_composite_final.jpg

Controlli finestra:
    click sinistro     → piazza i 4 corner TL → TR → BR → BL
    z / BACKSPACE      → annulla l'ultimo tap
    r                  → restart
    INVIO / SPACE      → conferma e calcola la rettifica
    q / ESC            → annulla tutto
"""
from __future__ import annotations
import sys, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import cv2
import numpy as np

from app.services.rectify_facade import (
    rectify_quad_to_rect, validate_quad, estimate_aspect_from_quad,
)

CORNER_NAMES = ["TL", "TR", "BR", "BL"]
CORNER_COLORS = [(0, 255, 255), (0, 200, 0), (0, 100, 255), (255, 0, 200)]
HELP_TEXT = [
    "Tappa 4 punti del MURO PRINCIPALE (NON porte rientrate/vetrine/pensiline)",
    "Ordine: TL -> TR -> BR -> BL  |  DRAG per regolare i punti già piazzati",
    "INVIO=conferma  z=undo  r=restart  q=annulla",
]
GRAB_RADIUS_PX = 18


def pick_4_corners(img_native: np.ndarray) -> list[tuple[float, float]] | None:
    """Apre finestra OpenCV, raccoglie 4 click sul sorgente nativo. Ritorna
    coords in pixel del sorgente."""
    H, W = img_native.shape[:2]
    target_w = 1600
    scale = min(target_w / W, 900 / H, 1.0)
    disp_w = int(W * scale); disp_h = int(H * scale)
    disp = cv2.resize(img_native, (disp_w, disp_h), interpolation=cv2.INTER_AREA) if scale < 1 else img_native.copy()
    base = disp.copy()

    taps_disp: list[list[int]] = []      # mutabile per drag
    drag_idx: list[int] = []              # 0 o 1 elemento ("idx in drag"); list per mutabilità in closure
    hover_idx: list[int] = []             # idx sotto il mouse (highlight)
    win = "Rettifica facciata — clicca 4 corner (TL TR BR BL), poi DRAG per regolare"

    def nearest_idx(mx: int, my: int) -> int:
        best_i, best_d2 = -1, GRAB_RADIUS_PX * GRAB_RADIUS_PX + 1
        for i, (x, y) in enumerate(taps_disp):
            d2 = (mx - x) * (mx - x) + (my - y) * (my - y)
            if d2 <= best_d2: best_i, best_d2 = i, d2
        return best_i

    def redraw():
        view = base.copy()
        for i, t in enumerate(HELP_TEXT):
            cv2.rectangle(view, (0, 8 + i*22), (disp_w, 8 + i*22 + 22), (0, 0, 0), -1)
            cv2.putText(view, t, (10, 24 + i*22), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1, cv2.LINE_AA)
        if len(taps_disp) >= 2:
            cv2.polylines(view, [np.array(taps_disp, dtype=np.int32)], len(taps_disp) == 4,
                          (255, 255, 0), 1, cv2.LINE_AA)
        # markers (highlight quello hover / in drag)
        active = (drag_idx[0] if drag_idx else (hover_idx[0] if hover_idx else -1))
        for i, (x, y) in enumerate(taps_disp):
            c = CORNER_COLORS[i]
            r_outer = 13 if i == active else 9
            cv2.circle(view, (x, y), r_outer, (255, 255, 255), 2)
            cv2.circle(view, (x, y), 5, c, -1)
            cv2.putText(view, CORNER_NAMES[i], (x + 10, y - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.55, c, 2, cv2.LINE_AA)
        cv2.putText(view, f"{len(taps_disp)}/4", (disp_w - 80, disp_h - 20),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 0), 2, cv2.LINE_AA)
        cv2.imshow(win, view)

    def on_mouse(event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN:
            ni = nearest_idx(x, y)
            if ni >= 0:
                # grab esistente per drag
                drag_idx.clear(); drag_idx.append(ni)
            elif len(taps_disp) < 4:
                taps_disp.append([x, y])
            redraw()
        elif event == cv2.EVENT_MOUSEMOVE:
            if drag_idx and (flags & cv2.EVENT_FLAG_LBUTTON):
                taps_disp[drag_idx[0]] = [max(0, min(disp_w - 1, x)),
                                          max(0, min(disp_h - 1, y))]
                redraw()
            else:
                ni = nearest_idx(x, y)
                if (hover_idx and hover_idx[0] == ni) or (not hover_idx and ni < 0):
                    return
                hover_idx.clear()
                if ni >= 0: hover_idx.append(ni)
                redraw()
        elif event == cv2.EVENT_LBUTTONUP:
            if drag_idx:
                drag_idx.clear(); redraw()

    cv2.namedWindow(win, cv2.WINDOW_AUTOSIZE)
    cv2.setMouseCallback(win, on_mouse)
    redraw()
    confirmed = False
    while True:
        k = cv2.waitKey(20) & 0xFF
        if k in (13, 32) and len(taps_disp) == 4:
            confirmed = True; break
        if k in (8, ord('z')) and taps_disp:
            taps_disp.pop(); redraw()
        if k == ord('r'):
            taps_disp.clear(); redraw()
        if k in (27, ord('q')): break
    cv2.destroyWindow(win)
    if not confirmed: return None
    inv = 1.0 / scale
    return [(float(x * inv), float(y * inv)) for (x, y) in taps_disp]





def main(panorama_path: str) -> None:
    src_path = Path(panorama_path).expanduser().resolve()
    if not src_path.exists():
        raise SystemExit(f"File non trovato: {src_path}")
    img = cv2.imread(str(src_path), cv2.IMREAD_COLOR)
    if img is None:
        raise SystemExit(f"Impossibile leggere {src_path}")
    H, W = img.shape[:2]
    print(f"Panorama: {src_path}  ({W}×{H})")

    print("\nClicca i 4 corner del MURO PRINCIPALE (TL → TR → BR → BL).")
    print("Evita porte rientrate, vetrine, pensiline.")
    quad = pick_4_corners(img)
    if quad is None:
        raise SystemExit("Annullato.")

    for i, (x, y) in enumerate(quad):
        print(f"  {CORNER_NAMES[i]}: ({x:.0f}, {y:.0f}) px")

    err = validate_quad(quad, W, H)
    if err:
        print(f"\n⚠ {err}")
        # Continuiamo lo stesso — l'utente magari sa cosa fa
    w_est, h_est = estimate_aspect_from_quad(quad)
    print(f"\nAspect stimato dai lati medi: {w_est:.0f}×{h_est:.0f} px → ratio {w_est/h_est:.2f}")

    rectified, info = rectify_quad_to_rect(img, quad, output_max_dim=2400)
    print(f"Output: {info.output_size[0]}×{info.output_size[1]} px")

    out_path = src_path.parent / f"{src_path.stem}_rectified.jpg"
    cv2.imwrite(str(out_path), rectified, [cv2.IMWRITE_JPEG_QUALITY, 92])
    print(f"\nSalvato: {out_path}")
    subprocess.run(["open", "-a", "Preview", str(src_path), str(out_path)], check=False)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Uso: python scripts/rectify_facade_local.py <path_to_panorama.jpg>")
    main(sys.argv[1])
