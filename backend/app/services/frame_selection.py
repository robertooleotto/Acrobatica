"""Scrematura dei frame da una raffica di cattura.

L'app scatta in raffica (a tempo, senza gating sui gradi) lungo colonne verticali.
Qui decimiamo: teniamo ~1 frame ogni `pitch_step_deg` di pitch DENTRO ogni colonna,
e iniziamo una nuova colonna quando l'operatore si sposta lateralmente di più di
`lateral_reset_m`. Così dalla raffica densa otteniamo un set ben distribuito per
la pipeline pose-prior + ortho, senza ridondanza.

Pitch e posizione sono ricavati dal `camera_transform` (robusto), NON dagli
`euler_angles` (che in alcune sessioni risultano sballati).
"""
from __future__ import annotations
import math
import numpy as np


def _pose_pitch_and_xz(camera_transform) -> tuple[float, float, float]:
    """Ritorna (pitch_deg, x, z) dal camera_transform (16 float col-major).

    pitch = elevazione dell'asse ottico (ARKit guarda lungo -Z della camera);
    Y è l'alto del mondo. pitch>0 = camera punta verso l'alto.
    """
    T = np.asarray(camera_transform, dtype=np.float64).reshape(4, 4, order="F")
    R = T[:3, :3]
    optical_world = -(R @ np.array([0.0, 0.0, 1.0]))
    pitch = math.degrees(math.asin(max(-1.0, min(1.0, float(optical_world[1])))))
    return pitch, float(T[0, 3]), float(T[2, 3])


def decimate_by_pitch(
    photos: list[dict],
    pitch_step_deg: float = 4.0,
    lateral_reset_m: float = 1.0,
) -> list[dict]:
    """Screma una raffica tenendo ~1 frame ogni `pitch_step_deg` per colonna.

    `photos`: lista di dict con almeno `metadata.camera_transform` e `order_index`.
    Ritorna il sottoinsieme tenuto, nell'ordine di cattura (order_index ASC).

    Greedy in ordine di cattura:
      - prima foto di una colonna → tenuta (ancora colonna);
      - spostamento laterale > lateral_reset_m → nuova colonna, tieni;
      - altrimenti tieni solo se il pitch differisce di ≥ pitch_step_deg
        dall'ultima tenuta nella colonna.
    """
    ordered = sorted(photos, key=lambda p: int(p["order_index"]))
    kept: list[dict] = []
    col_anchor_xz: tuple[float, float] | None = None
    last_pitch: float | None = None

    for p in ordered:
        ct = p["metadata"]["camera_transform"]
        pitch, x, z = _pose_pitch_and_xz(ct)
        if col_anchor_xz is None:
            kept.append(p); col_anchor_xz = (x, z); last_pitch = pitch
            continue
        lateral = math.dist((x, z), col_anchor_xz)
        if lateral > lateral_reset_m:
            # nuova colonna: reset ancora + tieni
            kept.append(p); col_anchor_xz = (x, z); last_pitch = pitch
        elif last_pitch is None or abs(pitch - last_pitch) >= pitch_step_deg:
            kept.append(p); last_pitch = pitch
        # else: scartata (troppo vicina in pitch alla precedente, stessa colonna)

    return kept
