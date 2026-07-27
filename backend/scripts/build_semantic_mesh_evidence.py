#!/usr/bin/env python3
"""Build non-destructive semantic evidence for an Object Capture mesh.

Grounding DINO and SAM 2 classify posed photographs. Their masks are lifted to
visible mesh triangles and combined with the planar-topology v2 hypotheses. The
script does not modify planes or mesh geometry.
"""
from __future__ import annotations

import argparse
import gc
import json
import math
import struct
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
import open3d as o3d
from PIL import Image

from app.services import opening_detection_service as detector_service


CLASS_NAMES = ["uncertain", "wall", "return", "attachment", "opening"]
CLASS_COLORS = np.asarray([
    [105, 112, 116],
    [0, 174, 239],
    [54, 211, 153],
    [255, 138, 0],
    [229, 57, 143],
], dtype=np.uint8)
CLASS_PRIORITY = {"wall": 1, "return": 2, "attachment": 3, "opening": 4}

PROMPTS = [[
    "window", "door", "French window", "shop window", "storefront",
    "balcony", "balcony railing", "cornice", "architectural molding",
    "column", "pilaster", "awning", "building facade", "exterior wall",
    "side wall",
]]


@dataclass
class Camera:
    key: str
    center: np.ndarray
    rotation: np.ndarray
    intrinsics: tuple[float, float, float, float]
    photo: Path
    width: int
    height: int


def quaternion_matrix(w: float, x: float, y: float, z: float) -> np.ndarray:
    return np.asarray([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ], dtype=np.float64)


def load_obj(path: Path) -> tuple[np.ndarray, np.ndarray]:
    vertices: list[list[float]] = []
    faces: list[list[int]] = []
    with path.open() as source:
        for raw in source:
            if raw.startswith("v "):
                vertices.append([float(value) for value in raw.split()[1:4]])
            elif raw.startswith("f "):
                indices = [int(token.split("/")[0]) - 1 for token in raw.split()[1:]]
                for index in range(1, len(indices) - 1):
                    faces.append([indices[0], indices[index], indices[index + 1]])
    return np.asarray(vertices, np.float32), np.asarray(faces, np.int32)


def mesh_geometry(vertices: np.ndarray, faces: np.ndarray) -> tuple[np.ndarray, np.ndarray, float]:
    triangles = vertices[faces]
    centers = triangles.mean(axis=1)
    cross = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    lengths = np.linalg.norm(cross, axis=1)
    normals = cross / np.maximum(lengths[:, None], 1e-12)
    edges = np.concatenate([
        np.linalg.norm(triangles[:, 1] - triangles[:, 0], axis=1),
        np.linalg.norm(triangles[:, 2] - triangles[:, 1], axis=1),
        np.linalg.norm(triangles[:, 0] - triangles[:, 2], axis=1),
    ])
    return centers, normals, float(np.median(edges[edges > 1e-9]))


def find_photo(root: Path, key: str) -> Path | None:
    for extension in ("jpg", "jpeg", "png", "JPG"):
        path = root / f"{int(key):04d}.{extension}"
        if path.exists():
            return path
    return None


def load_cameras(path: Path, photos: Path) -> list[Camera]:
    document = json.loads(path.read_text())
    cameras = []
    for key in sorted(document, key=int):
        record = document[key]
        photo = find_photo(photos, key)
        if photo is None or not record.get("intrinsics_fx_fy_cx_cy"):
            continue
        with Image.open(photo) as image:
            width, height = image.size
        cameras.append(Camera(
            key=str(key),
            center=np.asarray(record["translation"], np.float64),
            rotation=quaternion_matrix(*record["rotation_wxyz"]),
            intrinsics=tuple(float(value) for value in record["intrinsics_fx_fy_cx_cy"]),
            photo=photo,
            width=width,
            height=height,
        ))
    return cameras


def project(camera: Camera, points: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    fx, fy, cx, cy = camera.intrinsics
    local = (points - camera.center) @ camera.rotation
    depth = -local[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        x = fx * local[:, 0] / depth + cx
        y = cy - fy * local[:, 1] / depth
    return x, y, depth


def adaptive_keyframes(
    cameras: list[Camera],
    centers: np.ndarray,
    normals: np.ndarray,
    *,
    target_observations: int,
    coverage_target: float,
    max_keyframes: int,
) -> tuple[list[Camera], dict]:
    vertical = np.abs(normals[:, 1]) <= 0.72
    candidate_ids = np.flatnonzero(vertical)
    if len(candidate_ids) > 30_000:
        candidate_ids = candidate_ids[np.linspace(0, len(candidate_ids) - 1, 30_000).astype(int)]
    sample = centers[candidate_ids]
    sample_normals = normals[candidate_ids]
    coverage = []
    for camera in cameras:
        x, y, depth = project(camera, sample)
        rays = sample - camera.center
        rays /= np.maximum(np.linalg.norm(rays, axis=1)[:, None], 1e-12)
        facing = np.abs(np.einsum("ij,ij->i", sample_normals, -rays))
        mask = (
            (depth > 0.02)
            & (x >= camera.width * 0.03) & (x < camera.width * 0.97)
            & (y >= camera.height * 0.03) & (y < camera.height * 0.97)
            & (facing >= 0.12)
        )
        coverage.append(mask)
    coverage_matrix = np.asarray(coverage, dtype=bool)
    observations = np.zeros(len(sample), np.uint16)
    remaining = set(range(len(cameras)))
    selected: list[int] = []
    stop_reason = "no_gain"
    while remaining and len(selected) < max_keyframes:
        deficit = observations < target_observations
        gains = [(int(np.count_nonzero(coverage_matrix[index] & deficit)), index) for index in remaining]
        gain, best = max(gains)
        if gain < max(20, int(len(sample) * 0.0015)):
            break
        selected.append(best)
        remaining.remove(best)
        observations[coverage_matrix[best]] += 1
        ratio = float(np.mean(observations >= target_observations))
        if ratio >= coverage_target:
            stop_reason = "coverage_target"
            break
    else:
        if len(selected) >= max_keyframes:
            stop_reason = "safety_cap"
    return [cameras[index] for index in selected], {
        "sample_faces": int(len(sample)),
        "target_observations": int(target_observations),
        "coverage_target": float(coverage_target),
        "achieved_coverage": float(np.mean(observations >= target_observations)),
        "stop_reason": stop_reason,
        "selected": [cameras[index].key for index in selected],
    }


def semantic_class(label: str) -> str:
    normalized = label.lower()
    if any(word in normalized for word in ("window", "door", "storefront")):
        return "opening"
    if any(word in normalized for word in (
        "balcony", "railing", "cornice", "molding", "column", "pilaster", "awning",
    )):
        return "attachment"
    if any(word in normalized for word in ("facade", "wall")):
        return "wall"
    return "uncertain"


def box_iou(first: list[float], second: list[float]) -> float:
    x0, y0 = max(first[0], second[0]), max(first[1], second[1])
    x1, y1 = min(first[2], second[2]), min(first[3], second[3])
    intersection = max(x1 - x0, 0.0) * max(y1 - y0, 0.0)
    area_first = max(first[2] - first[0], 0.0) * max(first[3] - first[1], 0.0)
    area_second = max(second[2] - second[0], 0.0) * max(second[3] - second[1], 0.0)
    union = area_first + area_second - intersection
    return intersection / union if union > 0 else 0.0


def deduplicate_by_class(proposals: list[dict], threshold: float = 0.55) -> list[dict]:
    kept: list[dict] = []
    for proposal in sorted(proposals, key=lambda item: item["score"], reverse=True):
        if all(
            proposal["semantic_class"] != other["semantic_class"]
            or box_iou(proposal["box"], other["box"]) < threshold
            for other in kept
        ):
            kept.append(proposal)
    return kept


def detect_boxes(image: Image.Image, runtime) -> list[dict]:
    torch, processor, model = runtime
    inputs = processor(images=image, text=PROMPTS, return_tensors="pt")
    with torch.inference_mode():
        outputs = model(**inputs)
    result = processor.post_process_grounded_object_detection(
        outputs,
        inputs.input_ids,
        threshold=0.20,
        text_threshold=0.17,
        target_sizes=[image.size[::-1]],
    )[0]
    labels = result.get("text_labels")
    if labels is None:
        labels = result.get("labels")
    if labels is None:
        labels = []
    proposals = []
    image_area = float(image.width * image.height)
    for box, score, label in zip(result["boxes"], result["scores"], labels):
        values = [float(value) for value in box.tolist()]
        semantic = semantic_class(str(label))
        area = max(values[2] - values[0], 0.0) * max(values[3] - values[1], 0.0)
        if semantic == "uncertain" or (semantic != "wall" and area / image_area > 0.38):
            continue
        proposals.append({
            "box": values,
            "score": float(score.item()),
            "label": str(label),
            "semantic_class": semantic,
        })
    return deduplicate_by_class(proposals)[:80]


def resized_image(camera: Camera, max_side: int) -> tuple[Image.Image, float, float]:
    image = Image.open(camera.photo).convert("RGB")
    scale = min(1.0, max_side / max(image.size))
    size = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
    if size != image.size:
        image = image.resize(size, Image.Resampling.LANCZOS)
    return image, image.width / camera.width, image.height / camera.height


def run_grounding(cameras: list[Camera], output: Path, max_side: int) -> dict[str, dict]:
    runtime = detector_service._load_grounding()
    detections = {}
    for position, camera in enumerate(cameras, 1):
        image, scale_x, scale_y = resized_image(camera, max_side)
        proposals = detect_boxes(image, runtime)
        detections[camera.key] = {
            "image_size": list(image.size),
            "scale": [scale_x, scale_y],
            "proposals": proposals,
        }
        print(f"Grounding {position}/{len(cameras)} foto {camera.key}: {len(proposals)} box", flush=True)
    (output / "detections.json").write_text(json.dumps(detections, indent=2))
    del runtime
    gc.collect()
    return detections


def run_sam(
    cameras: list[Camera], detections: dict[str, dict], output: Path, max_side: int,
) -> dict[str, Path]:
    runtime = detector_service._load_sam2()
    mask_paths = {}
    for position, camera in enumerate(cameras, 1):
        image, _, _ = resized_image(camera, max_side)
        proposals = detections[camera.key]["proposals"]
        class_map = np.zeros((image.height, image.width), np.uint8)
        score_map = np.zeros((image.height, image.width), np.float32)
        for start in range(0, len(proposals), 16):
            batch = proposals[start:start + 16]
            masks = detector_service._segment_boxes(image, [item["box"] for item in batch], runtime)
            for proposal, raw_mask in zip(batch, masks):
                mask = np.asarray(raw_mask).squeeze() > 0
                if mask.shape != class_map.shape:
                    mask = cv2.resize(mask.astype(np.uint8), class_map.shape[::-1], interpolation=cv2.INTER_NEAREST) > 0
                class_name = proposal["semantic_class"]
                if class_name != "wall" and float(mask.mean()) > 0.32:
                    continue
                class_id = CLASS_NAMES.index(class_name)
                score = float(proposal["score"])
                priority = CLASS_PRIORITY[class_name]
                current_priority = np.take(
                    np.asarray([0, 1, 2, 3, 4], dtype=np.uint8), class_map,
                )
                update = mask & ((priority > current_priority) | ((priority == current_priority) & (score > score_map)))
                class_map[update] = class_id
                score_map[update] = score
        mask_path = output / f"semantic_{int(camera.key):04d}.png"
        cv2.imwrite(str(mask_path), class_map)
        cv2.imwrite(str(output / f"semantic_{int(camera.key):04d}_preview.png"), CLASS_COLORS[class_map][..., ::-1])
        np.save(output / f"semantic_{int(camera.key):04d}_score.npy", score_map.astype(np.float16))
        mask_paths[camera.key] = mask_path
        print(f"SAM 2 {position}/{len(cameras)} foto {camera.key}", flush=True)
    del runtime
    gc.collect()
    return mask_paths


def make_scene(vertices: np.ndarray, faces: np.ndarray) -> o3d.t.geometry.RaycastingScene:
    legacy = o3d.geometry.TriangleMesh(
        o3d.utility.Vector3dVector(vertices.astype(np.float64)),
        o3d.utility.Vector3iVector(faces),
    )
    scene = o3d.t.geometry.RaycastingScene()
    scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(legacy))
    return scene


def visible_faces(
    camera: Camera,
    centers: np.ndarray,
    scene: o3d.t.geometry.RaycastingScene,
    tolerance: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    x, y, depth = project(camera, centers)
    in_frame = (
        (depth > 0.02)
        & (x >= 0) & (x < camera.width)
        & (y >= 0) & (y < camera.height)
    )
    face_ids = np.flatnonzero(in_frame)
    directions = centers[face_ids] - camera.center
    distances = np.linalg.norm(directions, axis=1)
    directions /= np.maximum(distances[:, None], 1e-12)
    visible_parts = []
    for start in range(0, len(face_ids), 200_000):
        stop = min(start + 200_000, len(face_ids))
        rays = np.hstack([
            np.repeat(camera.center[None, :], stop - start, axis=0),
            directions[start:stop],
        ]).astype(np.float32)
        hit = scene.cast_rays(o3d.core.Tensor(rays))["t_hit"].numpy()
        visible_parts.append(hit >= distances[start:stop] - tolerance)
    visible = np.concatenate(visible_parts) if visible_parts else np.zeros(0, dtype=bool)
    selected = face_ids[visible]
    return selected, x[selected], y[selected]


def geometric_priors(
    centers: np.ndarray,
    normals: np.ndarray,
    topology: dict,
    voxel: float,
) -> tuple[np.ndarray, np.ndarray]:
    labels = np.zeros(len(centers), np.uint8)
    confidence = np.zeros(len(centers), np.float32)
    structural_normals = [
        np.asarray(face["normal"], dtype=float)
        for face in topology.get("faces", []) if face.get("role") == "structural"
    ]
    for face in topology.get("faces", []):
        corners = np.asarray(face["corners"], dtype=float)
        normal = np.asarray(face["normal"], dtype=float)
        normal /= max(np.linalg.norm(normal), 1e-12)
        axis_u = corners[1] - corners[0]
        axis_v = corners[3] - corners[0]
        length_u = max(np.linalg.norm(axis_u), 1e-12)
        length_v = max(np.linalg.norm(axis_v), 1e-12)
        axis_u /= length_u
        axis_v /= length_v
        relative = centers - corners[0]
        u = relative @ axis_u
        v = relative @ axis_v
        distance = np.abs(relative @ normal)
        alignment = np.abs(normals @ normal)
        inside = (
            (u >= -voxel * 2) & (u <= length_u + voxel * 2)
            & (v >= -voxel * 2) & (v <= length_v + voxel * 2)
            & (distance <= voxel * 4) & (alignment >= math.cos(math.radians(24)))
        )
        if face.get("role") == "structural":
            class_name = "wall"
            score = 0.72
        else:
            nearest_angle = min((
                math.degrees(math.acos(np.clip(abs(float(normal @ other)), 0.0, 1.0)))
                for other in structural_normals
            ), default=90.0)
            class_name = "return" if nearest_angle >= 18.0 else "wall"
            score = 0.58 if class_name == "return" else 0.48
        update = inside & (score > confidence)
        labels[update] = CLASS_NAMES.index(class_name)
        confidence[update] = score
    return labels, confidence


def lift_masks(
    cameras: list[Camera],
    detections: dict[str, dict],
    mask_paths: dict[str, Path],
    centers: np.ndarray,
    normals: np.ndarray,
    scene: o3d.t.geometry.RaycastingScene,
    tolerance: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    votes = np.zeros((len(centers), len(CLASS_NAMES)), np.float32)
    supports = np.zeros((len(centers), len(CLASS_NAMES)), np.uint8)
    observations = np.zeros(len(centers), np.uint16)
    for position, camera in enumerate(cameras, 1):
        face_ids, x, y = visible_faces(camera, centers, scene, tolerance)
        scale_x, scale_y = detections[camera.key]["scale"]
        class_map = cv2.imread(str(mask_paths[camera.key]), cv2.IMREAD_GRAYSCALE)
        score_map = np.load(mask_paths[camera.key].with_name(mask_paths[camera.key].stem + "_score.npy"))
        px = np.clip(np.rint(x * scale_x).astype(int), 0, class_map.shape[1] - 1)
        py = np.clip(np.rint(y * scale_y).astype(int), 0, class_map.shape[0] - 1)
        class_ids = class_map[py, px]
        scores = score_map[py, px].astype(np.float32)
        rays = centers[face_ids] - camera.center
        rays /= np.maximum(np.linalg.norm(rays, axis=1)[:, None], 1e-12)
        facing = np.abs(np.einsum("ij,ij->i", normals[face_ids], -rays))
        weight = scores * (0.45 + 0.55 * facing)
        observations[face_ids] += 1
        for class_id in range(1, len(CLASS_NAMES)):
            selected = class_ids == class_id
            np.add.at(votes[:, class_id], face_ids[selected], weight[selected])
            np.add.at(supports[:, class_id], face_ids[selected], 1)
        print(f"Fusione {position}/{len(cameras)} foto {camera.key}: {len(face_ids):,} facce visibili", flush=True)
    return votes, supports, observations


def finalize_labels(
    votes: np.ndarray,
    supports: np.ndarray,
    observations: np.ndarray,
    prior_labels: np.ndarray,
    prior_confidence: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    ai_scores = votes / np.maximum(observations[:, None], 1)
    ai_labels = np.argmax(ai_scores, axis=1).astype(np.uint8)
    ai_confidence = np.max(ai_scores, axis=1)
    labels = prior_labels.copy()
    confidence = prior_confidence.copy()
    sources = np.zeros(len(labels), np.uint8)  # 0 uncertain, 1 geometry, 2 AI, 3 hybrid
    sources[labels > 0] = 1
    selected_support = supports[np.arange(len(supports)), ai_labels]
    ai_valid = (ai_labels > 0) & (ai_confidence >= 0.09) & (selected_support >= 2)
    for class_name in ("wall", "return", "attachment", "opening"):
        class_id = CLASS_NAMES.index(class_name)
        selected = ai_valid & (ai_labels == class_id)
        if class_name in ("attachment", "opening"):
            update = selected
        else:
            update = selected & ((labels == 0) | (confidence < ai_confidence))
        labels[update] = class_id
        confidence[update] = np.maximum(confidence[update], ai_confidence[update])
        sources[update] = np.where(prior_labels[update] > 0, 3, 2)
    return labels, np.clip(confidence, 0.0, 1.0), sources


def write_semantic_points(
    path: Path, centers: np.ndarray, labels: np.ndarray, confidence: np.ndarray,
) -> None:
    colors = CLASS_COLORS[labels].astype(np.float32)
    colors = colors * (0.45 + 0.55 * confidence[:, None])
    colors = np.clip(colors, 0, 255).astype(np.uint8)
    with path.open("wb") as output:
        header = (
            "ply\nformat binary_little_endian 1.0\n"
            f"element vertex {len(centers)}\n"
            "property float x\nproperty float y\nproperty float z\n"
            "property uchar red\nproperty uchar green\nproperty uchar blue\n"
            "end_header\n"
        )
        output.write(header.encode("ascii"))
        record = struct.Struct("<fffBBB")
        for point, color in zip(centers, colors):
            output.write(record.pack(float(point[0]), float(point[1]), float(point[2]), *map(int, color)))


def run(args: argparse.Namespace) -> Path:
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    print("Carico mesh", flush=True)
    vertices, faces = load_obj(args.mesh)
    centers, normals, median_edge = mesh_geometry(vertices, faces)
    cameras = load_cameras(args.poses, args.photos)
    selected, selection = adaptive_keyframes(
        cameras,
        centers,
        normals,
        target_observations=args.target_observations,
        coverage_target=args.coverage_target,
        max_keyframes=args.max_keyframes,
    )
    print(f"Viste selezionate: {selection['selected']} ({selection['achieved_coverage']:.1%})", flush=True)
    (output / "selection.json").write_text(json.dumps(selection, indent=2))
    if args.selection_only:
        return output / "selection.json"

    if args.reuse_masks:
        detections = json.loads((output / "detections.json").read_text())
        mask_paths = {
            camera.key: output / f"semantic_{int(camera.key):04d}.png"
            for camera in selected
        }
        missing = [str(path) for path in mask_paths.values() if not path.exists()]
        if missing:
            raise RuntimeError(f"Maschere mancanti: {missing[:3]}")
    else:
        detections = run_grounding(selected, output, args.max_image_side)
        mask_paths = run_sam(selected, detections, output, args.max_image_side)

    topology = json.loads(args.topology.read_text())
    voxel = float(args.voxel or topology.get("section_summary", {}).get("step", median_edge) / 5.0)
    prior_labels, prior_confidence = geometric_priors(centers, normals, topology, voxel)
    scene = make_scene(vertices, faces)
    diagonal = float(np.linalg.norm(vertices.max(axis=0) - vertices.min(axis=0)))
    votes, supports, observations = lift_masks(
        selected, detections, mask_paths, centers, normals, scene,
        tolerance=max(diagonal * 0.0015, median_edge * 0.35),
    )
    labels, confidence, sources = finalize_labels(
        votes, supports, observations, prior_labels, prior_confidence,
    )
    np.savez_compressed(
        output / "semantic_faces.npz",
        labels=labels,
        confidence=confidence.astype(np.float16),
        sources=sources,
        observations=observations,
        votes=votes.astype(np.float16),
        supports=supports,
    )
    write_semantic_points(output / "semantic_points.ply", centers, labels, confidence)

    counts = {name: int(np.count_nonzero(labels == index)) for index, name in enumerate(CLASS_NAMES)}
    document = {
        "schema": "acrobatica.semantic-mesh-evidence.v1",
        "source_mesh": str(args.mesh.resolve()),
        "source_topology": str(args.topology.resolve()),
        "face_count": int(len(faces)),
        "classes": [
            {"id": index, "name": name, "color": CLASS_COLORS[index].tolist(), "faces": counts[name]}
            for index, name in enumerate(CLASS_NAMES)
        ],
        "selection": selection,
        "models": {
            "detector": detector_service._DETECTOR_MODEL,
            "segmenter": detector_service._SEGMENTER_MODEL,
            "prompts": PROMPTS[0],
        },
        "files": {
            "face_evidence": "semantic_faces.npz",
            "point_preview": "semantic_points.ply",
            "detections": "detections.json",
        },
        "policy": {
            "geometry_modified": False,
            "opening_and_attachment_override_geometry": True,
            "uncertain_faces_require_review": True,
        },
    }
    result_path = output / "semantic_evidence.v1.json"
    result_path.write_text(json.dumps(document, indent=2))
    print(f"Classi: {counts}", flush=True)
    print(f"Scritto {result_path}", flush=True)
    return result_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mesh", type=Path, required=True)
    parser.add_argument("--poses", type=Path, required=True)
    parser.add_argument("--photos", type=Path, required=True)
    parser.add_argument("--topology", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--target-observations", type=int, default=2)
    parser.add_argument("--coverage-target", type=float, default=0.90)
    parser.add_argument("--max-keyframes", type=int, default=24)
    parser.add_argument("--max-image-side", type=int, default=1024)
    parser.add_argument("--voxel", type=float)
    parser.add_argument("--selection-only", action="store_true")
    parser.add_argument("--reuse-masks", action="store_true")
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
