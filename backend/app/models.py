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


# Stati possibili di una sessione — macchina a stati del flusso prodotto a 8 passi.
# NB: la colonna `status` è testo libero su Postgres, quindi estendere è sicuro
# (nessuna migrazione). Transizioni valide in services/session_state.py.
SessionStatus = Literal[
    "capturing",       # 1. l'app sta scattando le foto
    "uploading",       # 2. foto in caricamento sul backend
    "uploaded",        # 2. tutte le foto caricate → pronte per il calcolo mesh
    "queued_oc",       # 3. in coda per il calcolo Object Capture (Mac cloud)
    "computing_oc",    # 3. OC in esecuzione sul Mac
    "mesh_ready",      # 4. mesh calcolata e disponibile sui server
    "cleaning",        # 6. l'utente sta pulendo la mesh sul device
    "clean_uploaded",  # 6. mesh pulita ricaricata (in standby)
    "planes_ready",    # 7. piani puliti determinati e mostrati
    "mapping",         # 8. proiezione foto→piani (bake) in corso
    "completed",       # 8. facciata stesa pronta
    "failed",          # errore in un qualunque stadio
    "processing",      # (legacy) vecchia pipeline 2D stitching/keystone
]


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
    composite_url: Optional[str] = None
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


# ─── Composite operativo per 4-tap finale ──────────────────────────────────

class StripCompositeRequest(BaseModel):
    """Crea un composite operativo della facciata da foto keystone-corrected.

    Il risultato serve solo come immagine completa/leggibile su cui l'utente
    tappa i 4 angoli del piano facciata. La correzione metrica vera avviene
    dopo con /rectify-panorama + /scale.
    """
    order_indices: Optional[list[int]] = Field(
        default=None,
        description="Se presente usa solo questi order_index, utile per una singola colonna/sweep."
    )
    overlap_ratio: float = Field(default=0.45, ge=0.15, le=0.80)
    crop_width_ratio: float = Field(default=0.80, ge=0.30, le=1.00)
    crop_height_ratio: float = Field(default=1.00, ge=0.30, le=1.00)
    decompose_roll: bool = Field(
        default=False,
        description="Se true rimuove prima il roll in 2D, poi applica la keystone pitch/yaw."
    )
    post_pitch_roll: bool = Field(
        default=False,
        description="Se true applica prima la keystone pitch e poi ruota l'immagine di +roll."
    )
    post_horizontal_roll: bool = Field(
        default=False,
        description="Se true rifinisce il roll usando linee orizzontali/verticali rilevate sull'immagine."
    )
    scale_alignment: bool = Field(
        default=False,
        description="Se true allinea le fasce con scala+rotazione+traslazione invece che sola traslazione."
    )
    blend_mode: Literal["feather", "cut", "graphcut"] = Field(
        default="feather",
        description="'feather' fonde; 'cut' taglia netto; 'graphcut' cerca seam e usa multiband."
    )
    output_name: str = Field(default="composite.jpg")


class StripPlacementModel(BaseModel):
    order_index: int
    x_offset: int
    y_offset: int
    width: int
    height: int
    match_response: float
    match_method: str
    dx: float
    dy: float
    scale: float = 1.0


class StripCompositeResult(BaseModel):
    composite_url: str
    output_size: tuple[int, int]
    placements: list[StripPlacementModel]
    warnings: list[str] = []


class ColumnCompositeRequest(BaseModel):
    """Rileva automaticamente le colonne/sweep e genera un composite per ognuna."""
    pitch_reset_deg: float = Field(default=20.0, ge=5.0, le=60.0)
    lateral_reset_m: float = Field(default=1.25, ge=0.10, le=10.0)
    overlap_ratio: float = Field(default=0.30, ge=0.15, le=0.80)
    crop_width_ratio: float = Field(default=0.80, ge=0.30, le=1.00)
    crop_height_ratio: float = Field(default=1.00, ge=0.30, le=1.00)
    decompose_roll: bool = Field(
        default=False,
        description="Legacy: rimuove prima il roll in 2D, poi applica la keystone."
    )
    post_pitch_roll: bool = Field(
        default=True,
        description="Per le colonne: prima pitch/keystone verticale, poi +roll col segno reale."
    )
    post_horizontal_roll: bool = Field(
        default=True,
        description="Per le colonne: rifinisce il roll con linee della facciata, prima del compositing."
    )
    scale_alignment: bool = Field(
        default=True,
        description="Per le colonne: allineamento locale con scala+traslazione controllata."
    )
    blend_mode: Literal["feather", "cut", "graphcut"] = Field(
        default="cut",
        description="Per le colonne: 'graphcut' è più simile a Photoshop ma più costoso."
    )
    min_photos_per_column: int = Field(default=2, ge=1, le=20)


class ColumnGroupModel(BaseModel):
    column_index: int
    order_indices: list[int]
    reason: str


class ColumnCompositeModel(BaseModel):
    column_index: int
    order_indices: list[int]
    composite_url: str
    output_size: tuple[int, int]
    placements: list[StripPlacementModel]
    warnings: list[str] = []


class ColumnCompositeResult(BaseModel):
    columns: list[ColumnCompositeModel]
    groups: list[ColumnGroupModel]
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


class FacadePlaneModel(BaseModel):
    """Piano di facciata rilevato automaticamente (triangolazione + RANSAC).

    Stesso frame del piano 4-tap: `c` punto sul piano, `n` normale verso le
    camere, `up` gravità proiettata sul piano, `right` = up × n, `bounds` =
    [u_min, u_max, v_min, v_max] in metri lungo right/up rispetto a `c`."""
    c: tuple[float, float, float]
    n: tuple[float, float, float]
    up: tuple[float, float, float]
    right: tuple[float, float, float]
    bounds: tuple[float, float, float, float]
    n_inliers: int
    rms_cm: float
    area_m2: float


class FacadePlanesResult(BaseModel):
    """Risultato del rilevamento automatico piani: lista ordinata per n_inliers
    (il primo è la facciata principale) + statistiche della triangolazione."""
    planes: list[FacadePlaneModel] = []
    stats: dict = {}
    warnings: list[str] = []


# ─── Geometria 3D semi-automatica (estrusione poligoni) ───────────────────

class ExtrudePolygonRequest(BaseModel):
    """Un poligono disegnato dall'utente sull'ortofoto (px, convenzione v22):
    il backend campiona la nuvola dentro il poligono e ne stima la profondità."""
    poly_px: list[list[float]] = Field(..., min_length=3,
        description="Vertici [x,y] in pixel ortofoto (almeno 3)")
    ppm: float = Field(default=110.0, gt=0, description="Pixel per metro dell'ortofoto")


class ExtrudePolygonResult(BaseModel):
    """Profondità robusta della regione + classificazione e confidenza.

    `tipo`: estruso (sporge) | rientrato (incassa) | filo.
    `confidence`: alta | media | bassa | nessuna.
    `needs_user_depth`=True quando i punti sono troppo pochi: l'utente deve
    inserire la profondità a mano."""
    depth_m: float
    depth_mad_cm: float
    n_points: int
    confidence: str
    tipo: str
    needs_user_depth: bool


class SectionBin(BaseModel):
    """Un campione del profilo di sezione orizzontale: w mediano a quota u."""
    u_m: float
    w_m: float
    n: int


class HorizontalSectionResult(BaseModel):
    """Profilo (u, w) di una fascia di quota: supporto visivo dell'editor."""
    v_quota_m: float
    band_m: float
    profilo: list[SectionBin] = []


class PrismRequest(BaseModel):
    """Un prisma da costruire: poligono + profondità (eventualmente corretta
    a mano dall'utente) + tipo/nome."""
    poly_px: list[list[float]] = Field(..., min_length=3)
    depth_m: float = 0.0
    tipo: Optional[str] = None
    nome: str = "regione"


class FacadeModelRequest(BaseModel):
    """Lista di prismi da assemblare nel modello a scatole della facciata."""
    prisms: list[PrismRequest] = Field(..., min_length=1)
    ppm: float = Field(default=110.0, gt=0)


class FacadeModelResult(BaseModel):
    """Modello costruito: JSON editabile + URL dell'OBJ salvato su storage."""
    n_vertices: int
    n_faces: int
    n_prisms: int
    model_json: dict
    model_url: Optional[str] = None
    obj_url: Optional[str] = None


class MeshFileInfo(BaseModel):
    """Un file della mesh su storage (l'OBJ + eventuali MTL/PNG texture)."""
    name: str
    url: str
    size_bytes: int


class MeshUploadResult(BaseModel):
    """Esito dell'upload mesh dal Mac (Object Capture) verso il backend."""
    session_id: str
    files: list[MeshFileInfo] = []


class MeshInfoResult(BaseModel):
    """Mesh disponibile per la sessione: file + URL firmati per il download."""
    session_id: str
    main_obj: Optional[MeshFileInfo] = None
    files: list[MeshFileInfo] = []


class PlanesSaveResult(BaseModel):
    """Esito del salvataggio dei piani decisi nell'editor 3D (passo 7).
    Il JSON completo dei piani è su storage (out/planes.json); qui si riepiloga."""
    session_id: str
    count: int
    path: str
    url: str
    status: str


class PlanesDataResult(BaseModel):
    """Piani salvati per la sessione: URL firmato al planes.json + conteggio."""
    session_id: str
    count: int
    url: Optional[str] = None


class DetectedPlane(BaseModel):
    """Un piano rilevato automaticamente: poligono (anche trapezio) + tipo."""
    nome: str
    tipo: str                          # "facciata" | "spalla" | "falda" | "orizzontale"
    punto: list[float]                 # centro del piano (frame mesh)
    normale: list[float]               # normale (fuori dal muro), qualsiasi inclinazione
    corners: list[list[float]]         # poligono di N vertici (non solo 4)
    area_m2: float
    w: float
    h: float
    triangoli: list[int] = []          # triangoli mesh del piano (maschera proiezione)


class DetectPlanesResult(BaseModel):
    """Esito del rilevamento automatico piani sulla mesh della sessione."""
    session_id: str
    up: list[float]
    count: int
    engine: str = ""                   # "open3d" (v2) | "istogrammi" (fallback v1)
    engine_error: str = ""             # se v2 è caduto in fallback: perché (diagnosi)
    planes: list[DetectedPlane] = []


class ProjectionInput(BaseModel):
    """Stato di un singolo input della proiezione (foto/mesh/pose/piani)."""
    kind: str
    present: bool
    detail: str
    paths: list[str] = []


class ProjectionScaffoldResult(BaseModel):
    """Esito del controllo di prontezza della proiezione foto→piani."""
    session_id: str
    ready: bool
    status: str
    inputs: list[ProjectionInput] = []
    missing: list[str] = []


class ProjectionResult(BaseModel):
    """Mesh dei piani texturizzata prodotta dalla proiezione cloud."""
    session_id: str
    status: str
    count: int
    total_area_m2: float
    coverage: float
    main_obj: Optional[MeshFileInfo] = None
    files: list[MeshFileInfo] = []
    planes: list[dict] = []
    projection_mode: str = ""
    texture_encoding: str = ""
    fallback_reason: str = ""


class ProjectionJobResult(ProjectionResult):
    """Stato interrogabile del job di proiezione asincrono."""
    state: str
    progress: float = 0.0
    message: str = ""
    error: str = ""


class ZonaMarcataModel(BaseModel):
    """Singola zona marcata dall'operatore sull'ortofoto (schema concordato
    con l'editor iOS — i campi/rawValue NON vanno cambiati).

    tipo: esclusa | da_rifare | misurabile | nota | lineare.
    Per tipo="lineare" punti_px è una polilinea APERTA: area_m2=0 e
    perimetro_m è la lunghezza della linea in metri.
    """
    nome: str
    tipo: str
    visibile: bool = True
    colore: Optional[str] = None
    punti_px: list[list[float]]
    area_m2: float = 0.0
    perimetro_m: float = 0.0


class MarcaturaZoneDocument(BaseModel):
    """Documento JSON completo prodotto dall'editor di marcatura iOS:
    {"versione":1,"ppm":110,"larghezza_px":...,"altezza_px":...,"zone":[...]}
    """
    versione: int = 1
    ppm: float
    larghezza_px: int
    altezza_px: int
    zone: list[ZonaMarcataModel] = []


class ZoneMarkupResult(BaseModel):
    """Risposta all'upload della marcatura: totali ricalcolati server-side."""
    session_id: str
    zone_count: int
    area_m2_per_tipo: dict[str, float] = {}
    lunghezza_m_per_tipo: dict[str, float] = {}
    markup_url: Optional[str] = None
    warnings: list[str] = []


class CreateSessionResponse(BaseModel):
    session_id: str
    status: SessionStatus


class UploadPhotoResponse(BaseModel):
    session_id: str
    order_index: int
    photos_count: int


# ─── Worker Object Capture (opzione A: Mac dedicato che consuma la coda) ─────

class OcJobPhoto(BaseModel):
    """Una foto del job: URL firmato per il download + intrinseci ARKit (da
    unire alle pose OC, che non le contengono)."""
    order_index: int
    url: str
    camera_intrinsics: list[float] = Field(default_factory=list, description="K col-major 9 float")


class OcJobResponse(BaseModel):
    """Job assegnato al worker OC. `session_id` None = coda vuota (niente lavoro)."""
    session_id: Optional[str] = None
    photos: list[OcJobPhoto] = []


class FailRequest(BaseModel):
    reason: Optional[str] = None
