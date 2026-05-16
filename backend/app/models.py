"""Pydantic models shared between routers and services."""
from __future__ import annotations
from typing import Literal, Optional
from pydantic import BaseModel, Field


# Metadata ARKit per ogni foto (col 4x4 e 3x3 in row-major float)
class ARMetadata(BaseModel):
    order_index: int = Field(..., description="Posizione della foto nella sequenza")
    timestamp: float = Field(..., description="Unix epoch ms")
    # Camera→world transform, 16 floats column-major (come ARKit lo emette)
    camera_transform: list[float] = Field(..., min_length=16, max_length=16)
    # Intrinsics K = [[fx,0,0],[0,fy,0],[cx,cy,1]], 9 floats column-major
    camera_intrinsics: list[float] = Field(..., min_length=9, max_length=9)
    euler_angles: Optional[list[float]] = Field(default=None, min_length=3, max_length=3)
    tracking_state: Optional[str] = None
    image_width: int
    image_height: int


# Stati possibili di una sessione
SessionStatus = Literal["capturing", "uploading", "processing", "completed", "failed"]


class Opening(BaseModel):
    """Apertura rilevata sulla facciata (finestra/porta/balcone)."""
    type: Literal["window", "balcony", "door", "unknown"] = "unknown"
    polygon: list[tuple[float, float]] = Field(..., description="Pixel (x,y) nell'immagine rectified")
    confidence: float = 0.0
    area_pixels: float = 0.0


class ProcessRequest(BaseModel):
    """Parametri opzionali per il processo (es. 4 punti facciata noti)."""
    facade_quad_pixels: Optional[list[tuple[float, float]]] = Field(
        default=None,
        description="4 punti del muro nell'immagine stitched (TL, TR, BR, BL)."
    )
    scale_factor_meters_per_pixel: Optional[float] = Field(
        default=None,
        description="Se noto, converte area pixel → m². Altrimenti il risultato resta in pixel."
    )


class ProcessResult(BaseModel):
    stitched_url: Optional[str] = None
    rectified_url: Optional[str] = None
    facade_polygon: Optional[list[tuple[float, float]]] = None
    vanishing_points: Optional[list[tuple[float, float]]] = None
    openings: list[Opening] = []
    gross_area_pixels: float = 0.0
    excluded_area_pixels: float = 0.0
    net_area_pixels: float = 0.0
    gross_area_m2: Optional[float] = None
    net_area_m2: Optional[float] = None
    warnings: list[str] = []


class SessionState(BaseModel):
    session_id: str
    status: SessionStatus = "capturing"
    photos: list[ARMetadata] = []
    result: Optional[ProcessResult] = None
    created_at: float
    updated_at: float


class CreateSessionResponse(BaseModel):
    session_id: str
    status: SessionStatus


class UploadPhotoResponse(BaseModel):
    session_id: str
    order_index: int
    photos_count: int
