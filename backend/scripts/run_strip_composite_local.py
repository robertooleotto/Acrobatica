"""Strip composite locale: scarica una sessione Supabase e produce
`facade_strip_composite_<mode>.jpg` via il flow product 2026-05-25:
- keystone verticale per foto
- crop centrale in larghezza, altezza piena
- allineamento via phase correlation (offset dx/dy)
- blending selezionabile

Output in /tmp/strip_<sid>/:
  - facade_strip_composite_<mode>.jpg  (composite finale, bottom→top)
  - strips/strip_NN.jpg          (fasce intermedie, debug)
  - placements_<mode>.json       (offset, response, method per ogni strip)

Uso:
    python scripts/run_strip_composite_local.py <session_id_prefix>
    python scripts/run_strip_composite_local.py data/fixtures/<id>   # da fixture
    python scripts/run_strip_composite_local.py <session> 3 4 5 6    # filtro order_index
    python scripts/run_strip_composite_local.py <session> --mode graphcut 11 12 13 14
"""
from __future__ import annotations
import sys, json, subprocess
from pathlib import Path
from dataclasses import asdict

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

import cv2
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")

from app.services.strip_composite_service import compose_vertical_strips
from _session_source import SessionSource


def main(arg: str, filter_order: list[int] | None = None, blend_mode: str = "cut") -> None:
    src = SessionSource.open(arg)
    sid = src.sid
    print(f"Sessione: {src.source_label}  ({len(src.photos)} foto)")

    # 1. Carica foto + metadata, ordinate per order_index ASC (bottom→top).
    #    Optional filter: process only a subset of order_index (es. single sweep).
    photos_sorted = sorted(src.photos, key=lambda p: int(p["order_index"]))
    if filter_order is not None:
        wanted = set(filter_order)
        photos_sorted = [p for p in photos_sorted if int(p["order_index"]) in wanted]
        print(f"Filtro order_index: {sorted(wanted)} → {len(photos_sorted)} foto")
    images = []
    metadatas = []
    for p in photos_sorted:
        img = src.load_image(p)
        if img is None:
            print(f"  [{p['order_index']}] decode fallito, skip")
            continue
        images.append(img)
        metadatas.append(p["metadata"])

    print(f"Caricate {len(images)} foto. Ordino e compongo…")

    # 2. Composizione
    result = compose_vertical_strips(
        images, metadatas,
        overlap_ratio=0.30,
        crop_width_ratio=0.80,
        crop_height_ratio=1.00,
        post_horizontal_roll=True,
        # scale_alignment=True produceva foto 6 (pitch 56°) gigantesca con
        # gap nero: scala foto stirate dal keystone UP invece che DOWN.
        # Senza è meglio (vedi /tmp/strip_857a6303/_test_no_scale).
        scale_alignment=False,
        blend_mode=blend_mode,
    )
    print(f"Composite: {result.canvas_size[0]}×{result.canvas_size[1]} px")
    for w in result.warnings: print(f"  ⚠ {w}")

    # 3. Save outputs
    out_dir = Path(f"/tmp/strip_{sid[:8]}")
    out_dir.mkdir(parents=True, exist_ok=True)
    strips_dir = out_dir / "strips"
    strips_dir.mkdir(exist_ok=True)

    # Salva placements JSON
    (out_dir / f"placements_{blend_mode}.json").write_text(
        json.dumps([asdict(p) for p in result.placements], indent=2),
        encoding="utf-8",
    )

    # Salva fasce intermedie per debug
    for order, strip in result.strips:
        cv2.imwrite(str(strips_dir / f"strip_{order:02d}.jpg"), strip,
                    [cv2.IMWRITE_JPEG_QUALITY, 85])
    print(f"Strip individuali in {strips_dir}/ ({len(result.strips)} files)")

    # Salva il composite finale
    comp_path = out_dir / f"facade_strip_composite_{blend_mode}.jpg"
    cv2.imwrite(str(comp_path), result.composite, [cv2.IMWRITE_JPEG_QUALITY, 90])
    print(f"\n→ {comp_path}")

    # Stampa tabella placements
    print(f"\n{'order':>5}  {'x':>6}  {'y':>6}  {'WxH':>10}  {'resp':>5}  {'dx':>6}  {'dy':>6}  method")
    for p in result.placements:
        print(f"{p.order_index:>5}  {p.x_offset:>6}  {p.y_offset:>6}  "
              f"{p.width}x{p.height:<5}  {p.match_response:>5.2f}  "
              f"{p.dx:>6.1f}  {p.dy:>6.1f}  {p.match_method}")

    # Apri in Preview: il composite + le prime/ultime strip per debug visivo
    subprocess.run(["open", "-a", "Preview", str(comp_path)], check=False)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Uso: python scripts/run_strip_composite_local.py <session_prefix|fixture_dir> [order_idx ...]")
    args = sys.argv[2:]
    mode = "cut"
    if "--mode" in args:
        i = args.index("--mode")
        try:
            mode = args[i + 1]
        except IndexError:
            raise SystemExit("--mode richiede: feather | cut | graphcut")
        del args[i:i + 2]
    fo = [int(x) for x in args] if args else None
    main(sys.argv[1], filter_order=fo, blend_mode=mode)
