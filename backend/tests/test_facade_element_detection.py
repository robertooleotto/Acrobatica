import cv2
import numpy as np

from scripts import detect_facade_elements_local as detector


def test_illumination_normalization_reduces_slow_brightness_gradient():
    height, width = 120, 300
    ramp = np.linspace(80, 210, width, dtype=np.uint8)
    image = np.repeat(ramp[None, :, None], height, axis=0)
    image = np.repeat(image, 3, axis=2)

    lab, normalized = detector._normalized_lab(image)

    assert normalized[:, :, 0].std() < lab[:, :, 0].std() * 0.35


def test_opening_candidates_gain_confidence_from_repetition():
    image = np.full((500, 900, 3), 220, np.uint8)
    for x in (100, 300, 500, 700):
        cv2.rectangle(image, (x, 140), (x + 75, 310), (35, 35, 35), -1)
    valid = np.full(image.shape[:2], 255, np.uint8)

    candidates = detector._rectangular_opening_candidates(image, valid)

    repeated = [item for item in candidates if item["repeats"] >= 2]
    assert len(repeated) >= 4
    assert all("dimensione_ripetuta" in item["reason"] for item in repeated)
    assert all("allineamento_architettonico" in item["reason"] for item in repeated)


def test_working_mask_uses_manifest_faces_only():
    image = np.zeros((100, 200, 3), np.uint8)
    manifest = {"faces": [{"x": 20, "y": 10, "width": 80, "height": 60}]}

    working = detector._working_image(image, manifest, max_width=200)

    assert working.valid[20, 30] == 255
    assert working.valid[5, 30] == 0
    assert working.valid[20, 150] == 0


def test_structural_grid_completes_a_second_window_row():
    image = np.full((520, 900, 3), 225, np.uint8)
    columns = (130, 330, 530, 730)
    for center_y in (150, 370):
        for center_x in columns:
            cv2.rectangle(
                image,
                (center_x - 45, center_y - 75),
                (center_x + 45, center_y + 75),
                (35, 35, 35), 5,
            )
    direct = [{
        "box": [center_x - 45, 75, center_x + 45, 225],
        "center": (center_x, 150),
        "width": 90,
        "height": 150,
        "fill": 0.8,
        "quality": 0.9,
        "score": 0.9,
        "repeats": 3,
        "aligned_repeats": 3,
        "reason": ["contorno_rettangolare"],
    } for center_x in columns]

    completed = detector._complete_repeated_grid(
        image, ((0, 0, 900, 520),), direct)

    lower = [item for item in completed if item["center"][1] > 280]
    assert len(lower) >= 4
    assert all(item["source"] == "structural_grid" for item in lower)
