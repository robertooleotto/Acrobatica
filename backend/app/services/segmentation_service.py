"""Segmentazione delle aperture (finestre, balconi, porte) sull'ortofoto.

Versione attuale: mock (ritorna lista vuota).
Versione futura: YOLO segmentation, Mask R-CNN, o SAM.
"""
from __future__ import annotations
import numpy as np

from ..models import Opening


def segment_openings(rectified_image: np.ndarray) -> list[Opening]:
    """Mock. Restituisce nessuna apertura.

    Quando sarà disponibile un modello CoreML/PyTorch, lo invocheremo qui e
    convertiremo le maschere in poligoni.
    """
    return []
