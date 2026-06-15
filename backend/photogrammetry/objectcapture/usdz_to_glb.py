#!/usr/bin/env python3
"""USDZ (Apple Object Capture) -> GLB texturizzato per WebGL / three.js GLTFLoader.

Headless, niente Blender. Legge l'usdz con `usd-core` (pxr).

Punto chiave: le UV di Object Capture sono `primvars:st` *faceVarying indicizzate*
(indici separati da quelli di posizione). glTF invece vuole UN indice per vertice
condiviso da posizione/normale/UV. Lo script splitta i vertici per combinazione
(pointIdx, stIdx, normalIdx) e genera una primitiva per ogni GeomSubset/materiale
(es. Group->tex0, Group_1->tex1). Le texture PNG vengono incorporate nel GLB come
immagini in bufferView (niente file esterni, niente base64 nel JSON).

Per three.js usare la variante con --flip-v (UV scritte come (u, 1-v)).

Uso:
    python usdz_to_glb.py model_raw.usdz -o model_raw_webgl_flipv.glb --flip-v

Dipendenze: pip install usd-core
Validazione consigliata: npx --yes @gltf-transform/cli validate <out>.glb
"""
import argparse
import json
import math
import mimetypes
import struct
import zipfile
from pathlib import Path

from pxr import Sdf, Usd, UsdGeom, UsdShade


COMPONENT_TYPE_FLOAT = 5126
COMPONENT_TYPE_UINT = 5125
TARGET_ARRAY_BUFFER = 34962
TARGET_ELEMENT_ARRAY_BUFFER = 34963


def align4(data):
    pad = (-len(data)) % 4
    return data + (b"\x00" * pad)


def json_align(data):
    pad = (-len(data)) % 4
    return data + (b" " * pad)


def mime_for(path):
    mime, _ = mimetypes.guess_type(path)
    return mime or "application/octet-stream"


def find_first_mesh(stage):
    for prim in stage.Traverse():
        if prim.IsA(UsdGeom.Mesh):
            return UsdGeom.Mesh(prim)
    raise RuntimeError("No UsdGeom.Mesh found")


def material_texture_asset(stage, material_path):
    mat_prim = stage.GetPrimAtPath(material_path)
    if not mat_prim:
        return None

    for prim in Usd.PrimRange(mat_prim):
        if not prim.IsA(UsdShade.Shader):
            continue
        shader = UsdShade.Shader(prim)
        inp = shader.GetInput("file")
        if inp:
            asset = inp.Get()
            if isinstance(asset, Sdf.AssetPath):
                return asset.path or asset.resolvedPath
            if asset:
                return str(asset)
    return None


def extract_asset_from_usdz(usdz_path, asset_path, out_dir):
    clean = asset_path.strip("@")
    out_path = out_dir / Path(clean).name
    if out_path.exists():
        return out_path

    with zipfile.ZipFile(usdz_path, "r") as zf:
        names = zf.namelist()
        match = clean if clean in names else None
        if match is None:
            suffix = Path(clean).name
            matches = [n for n in names if Path(n).name == suffix]
            if not matches:
                raise RuntimeError(f"Texture asset not found in USDZ: {asset_path}")
            match = matches[0]
        out_path.write_bytes(zf.read(match))
    return out_path


def subset_material_path(subset):
    rel = subset.GetPrim().GetRelationship("material:binding")
    if not rel:
        return None
    targets = rel.GetTargets()
    return targets[0] if targets else None


def add_buffer_view(doc, binary, payload, target=None):
    offset = len(binary)
    binary.extend(align4(payload))
    view = {
        "buffer": 0,
        "byteOffset": offset,
        "byteLength": len(payload),
    }
    if target is not None:
        view["target"] = target
    doc["bufferViews"].append(view)
    return len(doc["bufferViews"]) - 1


def add_accessor(doc, view, component_type, count, acc_type, min_value=None, max_value=None):
    accessor = {
        "bufferView": view,
        "byteOffset": 0,
        "componentType": component_type,
        "count": count,
        "type": acc_type,
    }
    if min_value is not None:
        accessor["min"] = min_value
    if max_value is not None:
        accessor["max"] = max_value
    doc["accessors"].append(accessor)
    return len(doc["accessors"]) - 1


def vec_min_max(values):
    mins = [math.inf, math.inf, math.inf]
    maxs = [-math.inf, -math.inf, -math.inf]
    for x, y, z in values:
        if x < mins[0]:
            mins[0] = x
        if y < mins[1]:
            mins[1] = y
        if z < mins[2]:
            mins[2] = z
        if x > maxs[0]:
            maxs[0] = x
        if y > maxs[1]:
            maxs[1] = y
        if z > maxs[2]:
            maxs[2] = z
    return mins, maxs


def pack_vec3(values):
    return b"".join(struct.pack("<fff", float(x), float(y), float(z)) for x, y, z in values)


def pack_vec2(values, flip_v):
    if flip_v:
        return b"".join(struct.pack("<ff", float(u), float(1.0 - v)) for u, v in values)
    return b"".join(struct.pack("<ff", float(u), float(v)) for u, v in values)


def pack_u32(values):
    return b"".join(struct.pack("<I", int(v)) for v in values)


def convert(usdz_path, out_glb, flip_v=False):
    usdz_path = Path(usdz_path)
    out_glb = Path(out_glb)
    work_dir = out_glb.parent

    stage = Usd.Stage.Open(str(usdz_path))
    if not stage:
        raise RuntimeError(f"Cannot open USDZ: {usdz_path}")

    mesh = find_first_mesh(stage)
    mesh_prim = mesh.GetPrim()
    points = list(mesh.GetPointsAttr().Get())
    counts = list(mesh.GetFaceVertexCountsAttr().Get())
    fvi = list(mesh.GetFaceVertexIndicesAttr().Get())
    normals = list(mesh.GetNormalsAttr().Get() or [])
    normal_interp = mesh.GetNormalsInterpolation()

    if any(c != 3 for c in counts):
        raise RuntimeError("Only triangulated meshes are supported by this converter")

    st_primvar = UsdGeom.PrimvarsAPI(mesh_prim).GetPrimvar("st")
    if not st_primvar:
        raise RuntimeError("Mesh has no primvars:st UV set")
    st_values = list(st_primvar.Get())
    st_indices = list(st_primvar.GetIndices() or [])
    if not st_indices:
        st_indices = list(range(len(st_values)))

    subsets = UsdGeom.Subset.GetGeomSubsets(mesh)
    if not subsets:
        subsets = [None]

    face_starts = [0] * len(counts)
    cursor = 0
    for i, count in enumerate(counts):
        face_starts[i] = cursor
        cursor += count

    doc = {
        "asset": {"version": "2.0", "generator": "usdz_to_glb.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": mesh_prim.GetName()}],
        "meshes": [{"name": mesh_prim.GetName(), "primitives": []}],
        "buffers": [{"byteLength": 0}],
        "bufferViews": [],
        "accessors": [],
        "materials": [],
        "textures": [],
        "images": [],
        "samplers": [{"magFilter": 9729, "minFilter": 9729, "wrapS": 10497, "wrapT": 10497}],
    }
    binary = bytearray()

    material_for_path = {}

    for subset_index, subset in enumerate(subsets):
        if subset is None:
            face_indices = list(range(len(counts)))
            material_path = None
        else:
            face_indices = list(subset.GetIndicesAttr().Get() or [])
            material_path = subset_material_path(subset)

        material_index = 0
        if material_path is not None:
            material_path_str = str(material_path)
            if material_path_str not in material_for_path:
                asset = material_texture_asset(stage, material_path)
                if not asset:
                    raise RuntimeError(f"No texture file found for material {material_path}")
                texture_path = extract_asset_from_usdz(usdz_path, asset, work_dir)
                image_payload = texture_path.read_bytes()
                image_view = add_buffer_view(doc, binary, image_payload)
                image_index = len(doc["images"])
                doc["images"].append({"bufferView": image_view, "mimeType": mime_for(texture_path)})
                texture_index = len(doc["textures"])
                doc["textures"].append({"sampler": 0, "source": image_index})
                material_index = len(doc["materials"])
                doc["materials"].append(
                    {
                        "name": Path(material_path_str).name,
                        "pbrMetallicRoughness": {
                            "baseColorTexture": {"index": texture_index, "texCoord": 0},
                            "metallicFactor": 0.0,
                            "roughnessFactor": 1.0,
                        },
                        "doubleSided": False,
                    }
                )
                material_for_path[material_path_str] = material_index
            material_index = material_for_path[material_path_str]

        vertex_map = {}
        positions = []
        uvs = []
        out_normals = []
        indices = []

        for face_index in face_indices:
            start = face_starts[face_index]
            for corner in range(3):
                k = start + corner
                pi = int(fvi[k])
                ui = int(st_indices[k])

                if normal_interp == UsdGeom.Tokens.faceVarying and normals:
                    ni = k
                else:
                    ni = pi

                key = (pi, ui, ni if normals else -1)
                out_index = vertex_map.get(key)
                if out_index is None:
                    out_index = len(positions)
                    vertex_map[key] = out_index
                    p = points[pi]
                    uv = st_values[ui]
                    positions.append((p[0], p[1], p[2]))
                    uvs.append((uv[0], uv[1]))
                    if normals:
                        n = normals[ni]
                        out_normals.append((n[0], n[1], n[2]))
                indices.append(out_index)

        pos_min, pos_max = vec_min_max(positions)
        pos_view = add_buffer_view(doc, binary, pack_vec3(positions), TARGET_ARRAY_BUFFER)
        uv_view = add_buffer_view(doc, binary, pack_vec2(uvs, flip_v), TARGET_ARRAY_BUFFER)
        idx_view = add_buffer_view(doc, binary, pack_u32(indices), TARGET_ELEMENT_ARRAY_BUFFER)

        pos_acc = add_accessor(doc, pos_view, COMPONENT_TYPE_FLOAT, len(positions), "VEC3", pos_min, pos_max)
        uv_acc = add_accessor(doc, uv_view, COMPONENT_TYPE_FLOAT, len(uvs), "VEC2")
        idx_acc = add_accessor(doc, idx_view, COMPONENT_TYPE_UINT, len(indices), "SCALAR")

        attributes = {"POSITION": pos_acc, "TEXCOORD_0": uv_acc}
        if out_normals:
            norm_view = add_buffer_view(doc, binary, pack_vec3(out_normals), TARGET_ARRAY_BUFFER)
            norm_acc = add_accessor(doc, norm_view, COMPONENT_TYPE_FLOAT, len(out_normals), "VEC3")
            attributes["NORMAL"] = norm_acc

        doc["meshes"][0]["primitives"].append(
            {
                "attributes": attributes,
                "indices": idx_acc,
                "material": material_index,
                "mode": 4,
                "extras": {
                    "sourceSubset": subset.GetPrim().GetName() if subset is not None else "all",
                    "sourceFaceCount": len(face_indices),
                    "vertexCount": len(positions),
                },
            }
        )

        print(
            f"primitive {subset_index}: faces={len(face_indices)} "
            f"vertices={len(positions)} indices={len(indices)} material={material_index}"
        )

    doc["buffers"][0]["byteLength"] = len(binary)
    json_bytes = json_align(json.dumps(doc, separators=(",", ":")).encode("utf-8"))
    bin_bytes = align4(bytes(binary))

    total_len = 12 + 8 + len(json_bytes) + 8 + len(bin_bytes)
    with out_glb.open("wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total_len))
        f.write(struct.pack("<I4s", len(json_bytes), b"JSON"))
        f.write(json_bytes)
        f.write(struct.pack("<I4s", len(bin_bytes), b"BIN\x00"))
        f.write(bin_bytes)

    print(f"wrote {out_glb} ({out_glb.stat().st_size / 1024 / 1024:.1f} MiB)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", default="model_raw.usdz")
    parser.add_argument("-o", "--output", default="model_raw_webgl.glb")
    parser.add_argument("--flip-v", action="store_true", help="Write TEXCOORD_0 as (u, 1-v) — usare per three.js")
    args = parser.parse_args()
    convert(args.input, args.output, flip_v=args.flip_v)


if __name__ == "__main__":
    main()
