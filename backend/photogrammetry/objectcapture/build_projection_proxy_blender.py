#!/usr/bin/env python3
"""Build a lightweight textured OBJ for OC-reference projection.

Run through Blender so the decimator preserves materials and UV coordinates:

    blender -b --python build_projection_proxy_blender.py -- \
        source.obj projection_proxy.obj 180000
"""
from __future__ import annotations

import sys
from pathlib import Path

import bpy


def main() -> None:
    try:
        separator = sys.argv.index("--")
        source, output, target_raw = sys.argv[separator + 1:separator + 4]
    except (ValueError, IndexError) as exc:
        raise SystemExit("Uso: source.obj output.obj target_faces") from exc

    source_path = Path(source).resolve()
    output_path = Path(output).resolve()
    target_faces = max(int(target_raw), 10_000)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.obj_import(filepath=str(source_path))
    objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    total_faces = sum(len(obj.data.polygons) for obj in objects)
    if not objects or total_faces == 0:
        raise RuntimeError(f"Nessuna mesh importata da {source_path}")

    ratio = min(1.0, target_faces / float(total_faces))
    if ratio < 0.999:
        for obj in objects:
            bpy.context.view_layer.objects.active = obj
            obj.select_set(True)
            modifier = obj.modifiers.new(name="ProjectionProxy", type="DECIMATE")
            modifier.decimate_type = "COLLAPSE"
            modifier.ratio = ratio
            modifier.use_collapse_triangulate = True
            bpy.ops.object.modifier_apply(modifier=modifier.name)
            obj.select_set(False)

    for obj in bpy.context.selected_objects:
        obj.select_set(False)
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.wm.obj_export(
        filepath=str(output_path),
        export_selected_objects=True,
        apply_modifiers=True,
        export_uv=True,
        export_normals=True,
        export_materials=True,
        export_triangulated_mesh=True,
        path_mode="COPY",
    )
    final_faces = sum(len(obj.data.polygons) for obj in objects)
    print(f"Projection proxy: {total_faces} -> {final_faces} triangoli")


if __name__ == "__main__":
    main()
