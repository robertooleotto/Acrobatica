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
    # Normale del piano verticale ARKit sotto il reticle al momento dello scatto,
    # in world coords (ARKit Y-up). Se presente, abilita keystone full-plane
    # (orizzontali parallele oltre alle verticali). Assente se nessun ARPlaneAnchor
    # verticale era stabile sotto il reticle.
    wall_normal_world: Optional[list[float]] = Field(default=None, min_length=3, max_length=3)


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


class CornerTap(BaseModel):
    """Un singolo tap di un angolo facciata su una specifica foto della sessione."""
    photo_order_index: int
    pixel: tuple[float, float] = Field(..., description="Coordinate pixel ARKit raw (origine top-left)")


class TriangulateRequest(BaseModel):
    """4 angoli della facciata, ognuno tappato su >= 2 foto per triangolare in 3D."""
    corners: list[list[CornerTap]] = Field(..., min_length=4, max_length=4,
                                            description="4 liste di tap (TL, TR, BR, BL), ognuna con >= 2 elementi")


class TriangulateResult(BaseModel):
    corners_3d: list[tuple[float, float, float]] = Field(..., min_length=4, max_length=4)
    width_m: float
    height_m: float
    area_m2: float
    warnings: list[str] = []


class KeystonePhotoResult(BaseModel):
    """Risultato per UNA foto raddrizzata."""
    order_index: int
    original_url: str
    rectified_url: str
    pitch_deg: float
    roll_deg: float
    yaw_deg: float
    input_size: tuple[int, int]
    output_size: tuple[int, int]


class KeystoneSessionResult(BaseModel):
    photos: list[KeystonePhotoResult] = []
    warnings: list[str] = []


# ─── Rettifica facciata 2D (4-tap homography sul panorama) ────────────────

class RectifyPanoramaRequest(BaseModel):
    """4 tap dell'utente sul panorama (ordine TL, TR, BR, BL) in coords pixel
    del panorama stesso. Il backend rettifica e salva l'output."""
    src_quad: list[tuple[float, float]] = Field(..., min_length=4, max_length=4,
        description="4 punti TL/TR/BR/BL del muro principale, in pixel del panorama")
    source: Literal["stitched", "composite"] = Field(default="stitched",
        description="Quale immagine usare: 'stitched' (cv2.Stitcher) o 'composite' (ortho fasce)")
    output_max_dim: int = 2400


class RectifyPanoramaResult(BaseModel):
    rectified_url: str
    output_size: tuple[int, int]
    homography_3x3: list[list[float]]


# ─── Scala metrica (2 tap + distanza nota sul rettificato) ────────────────

class SetScaleRequest(BaseModel):
    p1: tuple[float, float]
    p2: tuple[float, float]
    distance_m: float = Field(..., gt=0, description="Distanza reale fra i 2 tap, in metri")


class SetScaleResult(BaseModel):
    meters_per_pixel: float
    facade_width_m: Optional[float] = None      # se conosciamo size del rettificato
    facade_height_m: Optional[float] = None


class WallPlaneModel(BaseModel):
    """Piano del muro in world coords + basis 2D per il rendering ortografico."""
    point:  tuple[float, float, float]
    normal: tuple[float, float, float]
    right:  tuple[float, float, float]
    up:     tuple[float, float, float]
    u_min: float
    u_max: float
    v_min: float
    v_max: float

    @property
    def width_m(self) -> float:  return self.u_max - self.u_min
    @property
    def height_m(self) -> float: return self.v_max - self.v_min


class OrthorectifyPhotoResult(BaseModel):
    order_index: int
    ortho_url: str
    pre_rotated_cw: bool
    output_size: tuple[int, int]
    pixels_per_meter: float


class OrthorectifySessionResult(BaseModel):
    wall_plane: WallPlaneModel
    photos: list[OrthorectifyPhotoResult] = []
    composite_url: Optional[str] = None
    warnings: list[str] = []


class CreateSessionResponse(BaseModel):
    session_id: str
    status: SessionStatus


class UploadPhotoResponse(BaseModel):
    session_id: str
    order_index: int
    photos_count: int
