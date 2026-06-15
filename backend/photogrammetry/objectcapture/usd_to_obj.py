#!/usr/bin/env python3
# usd_to_obj.py — estrae geometria + UV ORIGINALI da un .usdz di Object Capture
# usando la libreria USD di Pixar (usd-core), SENZA ModelI/O (che corrompe le UV
# sulle mesh .raw a 2 pagine) e senza Blender. Scriptabile, gira anche su Linux.
#
# Produce: <out>.obj (con UV corrette, facce raggruppate per pagina texture),
#          <out>.mtl (2 materiali -> 2 pagine), e le 2 texture PNG estratte.
#
# Uso:  python usd_to_obj.py model_raw.usdz <outdir> model_raw_usd
#
# Dipendenza:  pip install usd-core

import sys, os, zipfile, shutil
from pxr import Usd, UsdGeom, UsdShade


def find_mesh(stage):
    for prim in stage.Traverse():
        if prim.IsA(UsdGeom.Mesh):
            return UsdGeom.Mesh(prim)
    raise SystemExit("nessuna Mesh nello stage USD")


def material_texture_file(mesh_prim, subset):
    """Ritorna il basename del file texture legato al subset (o None)."""
    binding = UsdShade.MaterialBindingAPI(subset.GetPrim())
    mat = binding.ComputeBoundMaterial()[0]
    if not mat:
        return None
    for shader_prim in Usd.PrimRange(mat.GetPrim()):
        shader = UsdShade.Shader(shader_prim)
        if not shader:
            continue
        sid = shader.GetIdAttr().Get()
        if sid == "UsdUVTexture":
            f = shader.GetInput("file")
            if f:
                val = f.Get()
                if val:
                    return os.path.basename(str(val.path if hasattr(val, "path") else val))
    return None


def main():
    usdz, outdir, base = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(outdir, exist_ok=True)
    stage = Usd.Stage.Open(usdz)
    mesh = find_mesh(stage)
    prim = mesh.GetPrim()

    points = mesh.GetPointsAttr().Get()
    counts = mesh.GetFaceVertexCountsAttr().Get()
    fvi = mesh.GetFaceVertexIndicesAttr().Get()

    pv = UsdGeom.PrimvarsAPI(prim).GetPrimvar("st")
    st_vals = pv.Get()
    st_idx = pv.GetIndices()
    st_interp = pv.GetInterpolation()
    print(f"mesh: {len(points)} punti, {len(counts)} facce, "
          f"st interp={st_interp}, st vals={len(st_vals)}, "
          f"st idx={'si' if st_idx else 'no'}")

    # corrispondenza face-vertex -> indice UV
    def uv_index(fv_global, point_idx):
        if st_interp == "vertex":
            return point_idx
        # faceVarying
        return st_idx[fv_global] if st_idx else fv_global

    # subset materiali -> pagina texture + facce
    subsets = UsdGeom.Subset.GetGeomSubsets(mesh)
    face_mat = [0] * len(counts)
    pages = {}   # nome materiale -> (indice locale, file texture)
    order = []
    if subsets:
        for si, ss in enumerate(subsets):
            tex = material_texture_file(prim, ss)
            name = ss.GetPrim().GetName()
            pages[si] = (name, tex)
            order.append(si)
            for fidx in ss.GetIndicesAttr().Get():
                face_mat[fidx] = si
            print(f"  subset {name}: {len(ss.GetIndicesAttr().Get())} facce -> {tex}")
    else:
        pages[0] = ("Texture", None)
        order = [0]

    # estrai le texture dall'usdz e mappa file interno -> nome editor
    page_png = {}      # si -> nome file PNG su disco
    with zipfile.ZipFile(usdz) as z:
        png_in_zip = {os.path.basename(n): n for n in z.namelist() if n.lower().endswith(".png")}
        for si, (name, tex) in pages.items():
            target = f"Texture_diffuseColor.png" if si == order[0] else f"Texture_diffuseColor_{si}.png"
            srcname = None
            if tex and tex in png_in_zip:
                srcname = png_in_zip[tex]
            else:
                # fallback: ordina tex0/tex1 per nome
                tx = sorted(png_in_zip)
                if si < len(tx):
                    srcname = png_in_zip[tx[si]]
            if srcname:
                with z.open(srcname) as s, open(os.path.join(outdir, target), "wb") as f:
                    shutil.copyfileobj(s, f)
                page_png[si] = target
                print(f"  texture {srcname} -> {target}")

    # scrivi MTL
    mtl_path = os.path.join(outdir, base + ".mtl")
    with open(mtl_path, "w") as m:
        for si in order:
            m.write(f"newmtl mat_{si}\n")
            if si in page_png:
                m.write(f"map_Kd {page_png[si]}\n")
            m.write("\n")

    # scrivi OBJ (facce ordinate per materiale)
    obj_path = os.path.join(outdir, base + ".obj")
    with open(obj_path, "w") as o:
        o.write(f"mtllib {base}.mtl\n")
        for p in points:
            o.write(f"v {p[0]} {p[1]} {p[2]}\n")
        for uv in st_vals:
            o.write(f"vt {uv[0]} {uv[1]}\n")
        # offset face-vertex globali
        starts = []
        acc = 0
        for c in counts:
            starts.append(acc); acc += c
        for si in order:
            o.write(f"usemtl mat_{si}\n")
            for fidx, c in enumerate(counts):
                if face_mat[fidx] != si:
                    continue
                g = starts[fidx]
                verts = []
                for k in range(c):
                    pidx = fvi[g + k]
                    uvi = uv_index(g + k, pidx)
                    verts.append(f"{pidx + 1}/{uvi + 1}")
                o.write("f " + " ".join(verts) + "\n")

    print(f"[OK] {obj_path}")
    print(f"[OK] {mtl_path}")
    print(f"texture: {', '.join(sorted(page_png.values()))}")


if __name__ == "__main__":
    main()
