#!/usr/bin/env python3
# usdz_to_editor.py
#
# Converte un .usdz di Object Capture nel formato atteso dall'editor dei piani
# (plane_rebuild_prototype.html): <name>.obj con UV + le texture rinominate
#   Texture_diffuseColor.png / Texture_normal.png / Texture_occlusion.png /
#   Texture_roughness.png
#
# Passi:
#   1. geometria+UV via il tool Swift ModelI/O (usdz2obj) -> stesso path con cui
#      fu generato model_nobbox.obj;
#   2. estrazione dei PNG embeddati nell'usdz (e' uno zip) e rinomina secondo la
#      convenzione fissa che l'editor carica per nome;
#   3. riscrittura dell'MTL verso quei nomi.
#
# Uso:
#   python3 usdz_to_editor.py <input.usdz> <output_dir> [basename]
# Esempio (mesh densa scaricata dal Mac affittato):
#   python3 usdz_to_editor.py \
#       ~/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/model_raw.usdz \
#       ~/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox \
#       model_raw
#
# Gira su Mac Intel (ModelI/O disponibile). Richiede il binario ./usdz2obj
# (lo compila al volo se manca: swiftc -O usdz2obj.swift -o usdz2obj).

import os
import re
import sys
import shutil
import zipfile
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent

# suffisso interno usdz -> nome file atteso dall'editor
TEX_MAP = {
    "_tex0":       "Texture_diffuseColor.png",
    "_norm0":      "Texture_normal.png",
    "_ao0":        "Texture_occlusion.png",
    "_roughness0": "Texture_roughness.png",
}
# riga MTL -> nome file
MTL_MAP = {
    "map_Kd":                 "Texture_diffuseColor.png",
    "map_tangentSpaceNormal": "Texture_normal.png",
    "map_ao":                 "Texture_occlusion.png",
    "map_roughness":          "Texture_roughness.png",
}


def ensure_tool() -> Path:
    binp = HERE / "usdz2obj"
    if binp.exists():
        return binp
    src = HERE / "usdz2obj.swift"
    if not src.exists():
        sys.exit(f"[ERROR] manca {src} e il binario usdz2obj")
    print("Compilo usdz2obj ...")
    subprocess.run(["swiftc", "-O", str(src), "-o", str(binp)], check=True)
    return binp


def main():
    if len(sys.argv) < 3:
        sys.exit("Uso: usdz_to_editor.py <input.usdz> <output_dir> [basename]")
    usdz = Path(sys.argv[1]).expanduser().resolve()
    outdir = Path(sys.argv[2]).expanduser().resolve()
    base = sys.argv[3] if len(sys.argv) > 3 else usdz.stem
    if not usdz.exists():
        sys.exit(f"[ERROR] input non trovato: {usdz}")
    outdir.mkdir(parents=True, exist_ok=True)

    obj = outdir / f"{base}.obj"
    mtl = outdir / f"{base}.mtl"

    # 1) geometria + UV
    tool = ensure_tool()
    print(f"[1/3] OBJ+UV via ModelI/O -> {obj.name}")
    subprocess.run([str(tool), str(usdz), str(obj)], check=True)

    # 2) estrai e rinomina le texture
    print("[2/3] estraggo texture dall'usdz")
    found = {}
    with zipfile.ZipFile(usdz) as z:
        for info in z.infolist():
            name = info.filename
            if not name.lower().endswith(".png"):
                continue
            for suffix, target in TEX_MAP.items():
                if suffix in name:
                    dest = outdir / target
                    with z.open(info) as src, open(dest, "wb") as f:
                        shutil.copyfileobj(src, f)
                    found[target] = dest
                    print(f"   {name}  ->  {target}")
                    break
    if "Texture_diffuseColor.png" not in found:
        print("[WARN] diffuse non trovata: l'editor mostrera' la mesh senza colore")

    # 3) riscrivi MTL verso i nomi standard
    print("[3/3] riscrivo MTL")
    if mtl.exists():
        lines = mtl.read_text().splitlines()
        out = []
        for ln in lines:
            key = ln.strip().split()[0] if ln.strip() else ""
            if key in MTL_MAP and MTL_MAP[key] in found:
                indent = ln[: len(ln) - len(ln.lstrip())]
                out.append(f"{indent}{key} {MTL_MAP[key]}")
            else:
                out.append(ln)
        mtl.write_text("\n".join(out) + "\n")

    print("\n[OK] pronto per l'editor.")
    print(f"  mesh:    {obj}")
    print(f"  texture: {', '.join(sorted(found)) or '(nessuna)'}")
    print("\nPer caricarla nel simulatore, in plane_rebuild_prototype.html cambia:")
    print(f"    const MODEL = '{obj.name}';   // era 'model_nobbox.obj'")
    print("poi ricarica http://127.0.0.1:8781/plane_rebuild_prototype.html")


if __name__ == "__main__":
    main()
