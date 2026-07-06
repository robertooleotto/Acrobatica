#!/usr/bin/env python3
# usdz_to_assets.py — Stadio 3 della pipeline facciata (consolidamento).
#
# Da un model.usdz di Object Capture produce, in un solo passo ripetibile:
#   - <name>.obj + .mtl + texture PNG   (UV native, via usd_to_obj.py)
#   - <name>.glb                         (per il web/GLTFLoader, via usdz_to_glb.py --flip-v)
#   - manifest.json                      (sorgente, conteggi, timestamp)
#
# NOTA POSE: l'usdz di Object Capture NON contiene le camere (verificato: 0 camere
# nell'output .raw/.nobbox). Le pose usate a valle sono le POSE ARKit (da
# photos.json della cattura iOS) portate nel frame della mesh — l'allineamento
# mesh↔pose è lo Stadio 4 (pulizia mesh: Umeyama + warp). Questo stadio produce
# solo la geometria; non inventa pose OC inesistenti.
#
# Uso:
#   # forma esplicita
#   python usdz_to_assets.py --usdz model_raw.usdz --out ./mesh --name model
#   # forma per sessione (cerca <session>/oc/model_<detail>.usdz → <session>/mesh/)
#   python usdz_to_assets.py --session ~/Documents/acrobatica_mesh/sess_XXXX --detail raw
#
# Dipendenze: usd-core, numpy, pillow (vedi .venv accanto a questo file).
import argparse, json, os, subprocess, sys, glob

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd):
    print("+ " + " ".join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True)


def main():
    ap = argparse.ArgumentParser(description="usdz OC → OBJ+GLB (stadio 3)")
    ap.add_argument("--usdz", help="percorso del model.usdz")
    ap.add_argument("--session", help="dir sessione (usa <session>/oc/model_<detail>.usdz)")
    ap.add_argument("--detail", default="raw", help="dettaglio usato nel nome file OC (default raw)")
    ap.add_argument("--out", help="cartella output (default <session>/mesh o accanto all'usdz)")
    ap.add_argument("--name", default="model", help="basename degli asset (default model)")
    ap.add_argument("--no-glb", action="store_true", help="salta la conversione GLB")
    args = ap.parse_args()

    # risolvi usdz + out
    usdz = args.usdz
    out = args.out
    if args.session:
        sess = os.path.expanduser(args.session)
        if not usdz:
            cand = os.path.join(sess, "oc", f"model_{args.detail}.usdz")
            if not os.path.exists(cand):
                hits = glob.glob(os.path.join(sess, "oc", "*.usdz")) or glob.glob(os.path.join(sess, "*.usdz"))
                if not hits:
                    sys.exit(f"ERRORE: nessun usdz in {sess}/oc/  (esegui prima run_oc_remote.sh)")
                cand = hits[0]
            usdz = cand
        out = out or os.path.join(sess, "mesh")
    if not usdz:
        sys.exit("ERRORE: specifica --usdz o --session")
    usdz = os.path.expanduser(usdz)
    if not os.path.exists(usdz):
        sys.exit(f"ERRORE: usdz non trovato: {usdz}")
    out = os.path.expanduser(out or os.path.join(os.path.dirname(usdz), "mesh"))
    os.makedirs(out, exist_ok=True)

    py = sys.executable
    print(f"── Stadio 3: usdz → asset\n   usdz: {usdz}\n   out:  {out}\n   name: {args.name}")

    # 1. OBJ + UV native + texture
    run([py, os.path.join(HERE, "usd_to_obj.py"), usdz, out, args.name])
    obj_path = os.path.join(out, f"{args.name}.obj")

    # 2. GLB per il web
    glb_path = os.path.join(out, f"{args.name}.glb")
    if not args.no_glb:
        run([py, os.path.join(HERE, "usdz_to_glb.py"), usdz, "-o", glb_path, "--flip-v"])

    # 3. manifest
    def count_obj(p):
        v = f = 0
        try:
            with open(p) as fh:
                for ln in fh:
                    if ln.startswith("v "): v += 1
                    elif ln.startswith("f "): f += 1
        except FileNotFoundError:
            pass
        return v, f
    nv, nf = count_obj(obj_path)
    manifest = {
        "stage": "3-usdz_to_assets",
        "source_usdz": os.path.abspath(usdz),
        "obj": os.path.basename(obj_path),
        "glb": (os.path.basename(glb_path) if not args.no_glb else None),
        "vertices": nv, "faces": nf,
        "note": "pose OC non presenti nell'usdz; usare pose ARKit + allineamento (stadio 4)",
    }
    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)

    print(f"── OK: {nv} vertici, {nf} facce")
    print(f"   OBJ: {obj_path}")
    if not args.no_glb:
        print(f"   GLB: {glb_path}")
    print(f"   manifest: {os.path.join(out, 'manifest.json')}")


if __name__ == "__main__":
    main()
