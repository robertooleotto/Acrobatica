import * as React from "react";
import { Alert, Image, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import {
  ExpoArFacadeModule, ExpoArFacadeView,
  type CapturedPhoto, type ArTrackingState, type ExpoArFacadeViewRef,
  type FacadePlaneInfo, type RectifiedOrthophoto
} from "@acrobatica/expo-ar-facade";
import {
  rayFromPixel, rayPlaneIntersect, triangulateRays, widestBaselinePair,
  planeAxes, planeUVToWorld,
  computeFacciataNettaMq3D,
  type CameraPose, type Plane3D, type Point3D, type FacciataResult3D, type Quad3D
} from "@acrobatica/shared";
import { COLORS, SPACING } from "../theme";

type Phase = "shooting" | "tagging" | "result";
type TaggedPhoto = Required<Pick<CapturedPhoto, "uri" | "width" | "height" | "transform" | "intrinsics">> & {
  facadePlane?: FacadePlaneInfo;
  rectified?: RectifiedOrthophoto;
};
/**
 * A user tap on a photo. `kind: "pixel"` carries raw landscape image pixel coords
 * (for un-rectified photos, used with ray-plane intersection in computeResult).
 * `kind: "meters"` carries (u, v) in plane-frame meters (for rectified ortophotos,
 * lifted to 3D via planeUVToWorld).
 */
type Tap =
  | { kind: "pixel"; x: number; y: number }
  | { kind: "meters"; u: number; v: number };
type Pixel = { x: number; y: number };

const CORNER_LABELS = ["Alto-sx", "Alto-dx", "Basso-dx", "Basso-sx"] as const;

export default function PhotoScanScreen() {
  const [phase, setPhase] = React.useState<Phase>("shooting");
  const [tracking, setTracking] = React.useState<ArTrackingState>("limited.initializing");
  const [photos, setPhotos] = React.useState<TaggedPhoto[]>([]);
  const [shooting, setShooting] = React.useState(false);
  const [planeLocked, setPlaneLocked] = React.useState<FacadePlaneInfo | null>(null);
  const [activePhoto, setActivePhoto] = React.useState<number>(0);
  const [taps, setTaps] = React.useState<(Tap | null)[]>([null, null, null, null]);
  // Per-corner photo index (which photo was tapped for each corner). Used in plane-mode.
  const [tapsPhotoIdx, setTapsPhotoIdx] = React.useState<(number | null)[]>([null, null, null, null]);
  // Fallback two-photo triangulation taps (used when no plane is locked).
  const [tapsA, setTapsA] = React.useState<(Pixel | null)[]>([null, null, null, null]);
  const [tapsB, setTapsB] = React.useState<(Pixel | null)[]>([null, null, null, null]);
  const [pickedPair, setPickedPair] = React.useState<readonly [number, number]>([0, 1]);
  const [activeCorner, setActiveCorner] = React.useState(0);
  const [result, setResult] = React.useState<FacciataResult3D | null>(null);
  const viewRef = React.useRef<ExpoArFacadeViewRef | null>(null);

  React.useEffect(() => {
    ExpoArFacadeModule.requestAuthorization();
  }, []);

  const [viewSize, setViewSize] = React.useState<{ w: number; h: number }>({ w: 0, h: 0 });

  const onLockPlanePress = async () => {
    if (!viewRef.current) return;
    if (viewSize.w === 0) {
      Alert.alert("Aspetta", "AR view non pronta. Riprova tra un secondo.");
      return;
    }
    // Aim at the centre of the AR view.
    const cx = viewSize.w / 2;
    const cy = viewSize.h / 2;
    const r = await viewRef.current.lockFacadePlane(cx, cy);
    if (!r.ready || !r.origin || !r.normal) {
      Alert.alert("Piano non rilevato",
        r.error ?? "Punta una parete verticale uniforme con texture, attendi 2-3s che ARKit la riconosca, poi riprova.");
      return;
    }
    setPlaneLocked({ origin: r.origin, normal: r.normal });
  };

  const onUnlockPlane = async () => {
    if (viewRef.current) await viewRef.current.unlockFacadePlane();
    setPlaneLocked(null);
  };

  const onShutter = async () => {
    console.log("[Shutter] tapped, viewRef=", !!viewRef.current, "shooting=", shooting);
    if (!viewRef.current || shooting) return;
    setShooting(true);
    try {
      const p = await viewRef.current.capturePhoto();
      console.log("[Shutter] capturePhoto returned:", JSON.stringify({ ready: p.ready, error: p.error, uri: p.uri?.slice(0, 50), w: p.width, h: p.height }));
      if (!p.ready || !p.uri || !p.transform || !p.intrinsics || !p.width || !p.height) {
        Alert.alert("Scatto fallito", p.error ?? "Riprova.");
        return;
      }
      setPhotos(prev => [...prev, {
        uri: p.uri!, width: p.width!, height: p.height!,
        transform: p.transform!, intrinsics: p.intrinsics!,
        ...(p.facadePlane ? { facadePlane: p.facadePlane } : {}),
        ...(p.rectified ? { rectified: p.rectified } : {})
      }]);
    } catch (err) {
      console.log("[Shutter] error:", err);
      Alert.alert("Errore", String(err));
    } finally {
      setShooting(false);
    }
  };

  const onMeasure = () => {
    if (planeLocked) {
      if (photos.length < 1) {
        Alert.alert("Servono foto", "Scatta almeno una foto.");
        return;
      }
      setActivePhoto(0);
      setTaps([null, null, null, null]);
      setTapsPhotoIdx([null, null, null, null]);
      setActiveCorner(0);
      setPhase("tagging");
      return;
    }
    if (photos.length < 2) {
      Alert.alert("Servono almeno 2 foto", "Senza piano agganciato servono 2 foto da angoli diversi.");
      return;
    }
    const poses: CameraPose[] = photos.map(p => ({
      transform: p.transform, intrinsics: p.intrinsics,
      imageWidth: p.width, imageHeight: p.height
    }));
    const pair = widestBaselinePair(poses);
    if (!pair) return;
    setPickedPair(pair);
    setTapsA([null, null, null, null]);
    setTapsB([null, null, null, null]);
    setActiveCorner(0);
    setPhase("tagging");
  };

  const computeResult = React.useCallback(() => {
    const corners: Point3D[] = [];
    if (planeLocked) {
      const plane: Plane3D = { origin: planeLocked.origin, normal: planeLocked.normal };
      const axes = planeAxes(plane);
      for (let i = 0; i < 4; i++) {
        const t = taps[i];
        const idx = tapsPhotoIdx[i];
        if (!t || idx === null || idx === undefined) return;
        if (t.kind === "meters") {
          if (!axes) return;
          corners.push(planeUVToWorld(plane, axes, t.u, t.v));
        } else {
          const p = photos[idx]!;
          const pose: CameraPose = { transform: p.transform, intrinsics: p.intrinsics, imageWidth: p.width, imageHeight: p.height };
          const ray = rayFromPixel(pose, t.x, t.y);
          const p3 = rayPlaneIntersect(ray, plane);
          if (!p3) return;
          corners.push(p3);
        }
      }
    } else {
      const [iA, iB] = pickedPair;
      const pA = photos[iA]!, pB = photos[iB]!;
      const poseA: CameraPose = { transform: pA.transform, intrinsics: pA.intrinsics, imageWidth: pA.width, imageHeight: pA.height };
      const poseB: CameraPose = { transform: pB.transform, intrinsics: pB.intrinsics, imageWidth: pB.width, imageHeight: pB.height };
      for (let i = 0; i < 4; i++) {
        const ta = tapsA[i], tb = tapsB[i];
        if (!ta || !tb) return;
        const ra = rayFromPixel(poseA, ta.x, ta.y);
        const rb = rayFromPixel(poseB, tb.x, tb.y);
        const p3 = triangulateRays([ra, rb]);
        if (!p3) return;
        corners.push(p3);
      }
    }
    const r = computeFacciataNettaMq3D({
      corners: corners as unknown as Quad3D,
      excluded: [], extras: [], capturedAt: Date.now()
    });
    setResult(r);
    setPhase("result");
  }, [planeLocked, taps, tapsPhotoIdx, photos, pickedPair, tapsA, tapsB]);

  const onReset = () => {
    setPhotos([]);
    setTaps([null, null, null, null]);
    setTapsPhotoIdx([null, null, null, null]);
    setTapsA([null, null, null, null]);
    setTapsB([null, null, null, null]);
    setResult(null);
    setPhase("shooting");
  };

  return (
    <View style={styles.root}>
      {phase === "shooting" && (
        <>
          <ExpoArFacadeView
            ref={viewRef}
            style={StyleSheet.absoluteFillObject}
            showPlaneOverlay
            useLidarMesh={false}
            onLayout={(e) => setViewSize({ w: e.nativeEvent.layout.width, h: e.nativeEvent.layout.height })}
            onTrackingStateChange={(e) => setTracking(e.nativeEvent.state)}
            onSessionError={(e) => Alert.alert("ARKit error", e.nativeEvent.message)}
          />
          <View pointerEvents="none" style={styles.centerReticle}>
            <View style={styles.reticleCross} />
          </View>
          <SafeAreaView style={styles.overlay} pointerEvents="box-none">
            <View style={styles.topBar} pointerEvents="box-none">
              <Text style={styles.phaseLabel}>{planeLocked ? "Piano agganciato" : "Aggancia piano facciata"}</Text>
              <Text style={styles.subLabel}>
                {planeLocked
                  ? `${photos.length} ${photos.length === 1 ? "scatto" : "scatti"} - bastera 1 foto per misurare`
                  : "Tocca la facciata (overlay verde) per fissare il piano"}
              </Text>
              <View style={styles.statusRow}>
                <Chip label={tracking === "normal" ? "Tracking OK" : tracking} color={tracking === "normal" ? COLORS.primary : COLORS.warning} />
                {planeLocked && <Chip label="Piano OK" color={COLORS.primary} />}
              </View>
              <View style={styles.modeRow}>
                {!planeLocked ? (
                  <Pressable onPress={onLockPlanePress} style={styles.primaryActionBtn}>
                    <Text style={styles.primaryActionBtnText}>Aggancia piano qui</Text>
                  </Pressable>
                ) : (
                  <Pressable onPress={onUnlockPlane} style={styles.unlockBtn}>
                    <Text style={styles.unlockBtnText}>Sblocca piano</Text>
                  </Pressable>
                )}
              </View>
            </View>
            <View style={{ flex: 1 }} pointerEvents="none" />
            <View style={styles.shutterBar}>
              <ThumbStrip photos={photos} />
              <View style={styles.shutterRow}>
                <View style={{ flex: 1 }}>
                  {photos.length > 0 && <SmallBtn label="Azzera" onPress={onReset} kind="secondary" />}
                </View>
                <Pressable
                  style={({ pressed }) => [styles.shutter, pressed && { opacity: 0.7 }, shooting && { opacity: 0.5 }]}
                  onPress={onShutter}
                  disabled={shooting}
                  hitSlop={20}
                >
                  <View style={styles.shutterInner} />
                </Pressable>
                <View style={{ flex: 1, alignItems: "flex-end" }}>
                  {((planeLocked && photos.length >= 1) || (!planeLocked && photos.length >= 2)) && (
                    <SmallBtn label="Misura" onPress={onMeasure} kind="primary" />
                  )}
                </View>
              </View>
              <Text style={styles.hintSmall}>
                {planeLocked
                  ? "Scatta foto dei vari pezzi della facciata. Una basta per misurare, ma piu ne fai piu copri."
                  : "Aggancia prima il piano. Senza piano servono 2 foto da posizioni diverse."}
              </Text>
            </View>
          </SafeAreaView>
        </>
      )}

      {phase === "tagging" && planeLocked && (
        <PlaneTagView
          photos={photos}
          activePhoto={activePhoto}
          setActivePhoto={setActivePhoto}
          taps={taps}
          setTaps={setTaps}
          tapsPhotoIdx={tapsPhotoIdx}
          setTapsPhotoIdx={setTapsPhotoIdx}
          activeCorner={activeCorner}
          setActiveCorner={setActiveCorner}
          onBack={() => setPhase("shooting")}
          onCompute={computeResult}
        />
      )}

      {phase === "tagging" && !planeLocked && (
        <TwoPhotoTagView
          photoA={photos[pickedPair[0]]!}
          photoB={photos[pickedPair[1]]!}
          tapsA={tapsA}
          tapsB={tapsB}
          setTapsA={setTapsA}
          setTapsB={setTapsB}
          activeCorner={activeCorner}
          setActiveCorner={setActiveCorner}
          onBack={() => setPhase("shooting")}
          onCompute={computeResult}
          aIndex={pickedPair[0]}
          bIndex={pickedPair[1]}
        />
      )}

      {phase === "result" && result && (
        <ResultView result={result} onAgain={onReset} onBack={() => setPhase("tagging")} />
      )}
    </View>
  );
}

function ThumbStrip({ photos }: { photos: TaggedPhoto[] }) {
  if (photos.length === 0) return null;
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.thumbRow}>
      {photos.map((p, i) => (
        <View key={p.uri} style={styles.thumbWrap}>
          <Image source={{ uri: p.uri }} style={styles.thumb} />
          <View style={styles.thumbBadge}><Text style={styles.thumbBadgeText}>{i + 1}</Text></View>
        </View>
      ))}
    </ScrollView>
  );
}

function PlaneTagView({
  photos, activePhoto, setActivePhoto, taps, setTaps, tapsPhotoIdx, setTapsPhotoIdx,
  activeCorner, setActiveCorner, onBack, onCompute
}: {
  photos: TaggedPhoto[];
  activePhoto: number;
  setActivePhoto: (i: number) => void;
  taps: (Tap | null)[];
  setTaps: React.Dispatch<React.SetStateAction<(Tap | null)[]>>;
  tapsPhotoIdx: (number | null)[];
  setTapsPhotoIdx: React.Dispatch<React.SetStateAction<(number | null)[]>>;
  activeCorner: number;
  setActiveCorner: (i: number) => void;
  onBack: () => void;
  onCompute: () => void;
}) {
  const ready = taps.every(t => t !== null);
  const photo = photos[activePhoto]!;

  const onTapPhoto = (tap: Tap) => {
    setTaps(prev => {
      const next = [...prev]; next[activeCorner] = tap; return next;
    });
    setTapsPhotoIdx(prev => {
      const next = [...prev]; next[activeCorner] = activePhoto; return next;
    });
    // Advance to next empty corner.
    for (let i = activeCorner + 1; i < 4; i++) {
      if (taps[i] === null) { setActiveCorner(i); return; }
    }
    for (let i = 0; i < activeCorner; i++) {
      if (taps[i] === null) { setActiveCorner(i); return; }
    }
  };

  return (
    <SafeAreaView style={styles.tagRoot}>
      <View style={styles.tagHeader}>
        <Text style={styles.tagTitle}>Tocca i 4 angoli</Text>
        <Text style={styles.tagSub}>Stai segnando: <Text style={{ color: COLORS.primary, fontWeight: "700" }}>{CORNER_LABELS[activeCorner]}</Text></Text>
        <View style={styles.cornerRow}>
          {CORNER_LABELS.map((label, i) => (
            <Pressable key={label} onPress={() => setActiveCorner(i)} style={[styles.cornerChip, activeCorner === i && styles.cornerChipActive, taps[i] !== null && styles.cornerChipDone]}>
              <Text style={[styles.cornerChipText, activeCorner === i && { color: "#000" }]}>{i + 1}</Text>
            </Pressable>
          ))}
        </View>
      </View>
      <View style={styles.singlePhotoWrap}>
        <SinglePhoto
          photo={photo}
          activePhotoIdx={activePhoto}
          taps={taps}
          tapsPhotoIdx={tapsPhotoIdx}
          activeCorner={activeCorner}
          onTap={onTapPhoto}
        />
      </View>
      <View style={styles.photoPickerRow}>
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 6 }}>
          {photos.map((p, i) => (
            <Pressable key={p.uri} onPress={() => setActivePhoto(i)} style={[styles.thumbWrap, activePhoto === i && styles.thumbWrapActive]}>
              <Image source={{ uri: p.uri }} style={styles.thumb} />
              <View style={styles.thumbBadge}><Text style={styles.thumbBadgeText}>{i + 1}</Text></View>
            </Pressable>
          ))}
        </ScrollView>
      </View>
      <View style={styles.tagBottom}>
        <SmallBtn label="Indietro" kind="secondary" onPress={onBack} />
        <SmallBtn label={ready ? "Calcola" : `${taps.filter(t => t).length}/4`}
                  kind={ready ? "primary" : "disabled"}
                  onPress={() => ready && onCompute()} />
      </View>
    </SafeAreaView>
  );
}

function SinglePhoto({
  photo, activePhotoIdx, taps, tapsPhotoIdx, activeCorner, onTap
}: {
  photo: TaggedPhoto;
  activePhotoIdx: number;
  taps: (Tap | null)[];
  tapsPhotoIdx: (number | null)[];
  activeCorner: number;
  onTap: (tap: Tap) => void;
}) {
  const useRect = !!photo.rectified;
  const r = photo.rectified;
  const aspect = useRect ? (r!.height / r!.width) : (photo.height / photo.width);
  const uri = useRect ? r!.uri : photo.uri;
  const [layout, setLayout] = React.useState<{ w: number; h: number }>({ w: 0, h: 0 });

  const handlePress = (e: { nativeEvent: { locationX: number; locationY: number } }) => {
    if (layout.w === 0 || layout.h === 0) return;
    const sx = e.nativeEvent.locationX;
    const sy = e.nativeEvent.locationY;
    if (useRect && r) {
      // Display is shown as-is (no EXIF rotation, since the rectified JPEG has no orientation tag).
      // (sx, sy) ∈ [0..layout.w, 0..layout.h]; rectified spans (uOrigin..uOrigin+widthM, vOrigin..vOrigin+heightM)
      // with top of image = v = vOrigin + heightM (high v), bottom = vOrigin (low v).
      const u = r.uOrigin + (sx / layout.w) * r.widthMeters;
      const v = r.vOrigin + r.heightMeters * (1 - sy / layout.h);
      onTap({ kind: "meters", u, v });
    } else {
      // Raw photo: ARKit captured landscape, displayed portrait via EXIF rotation. Map screen tap → raw pixel.
      const nx = sx / layout.w;
      const ny = sy / layout.h;
      const rawX = ny * photo.width;
      const rawY = (1 - nx) * photo.height;
      onTap({ kind: "pixel", x: rawX, y: rawY });
    }
  };

  const markerDisplay = (t: Tap | null): { left: number; top: number } | null => {
    if (!t || layout.w === 0) return null;
    if (t.kind === "meters") {
      if (!r) return null;
      const nx = (t.u - r.uOrigin) / r.widthMeters;
      const ny = 1 - (t.v - r.vOrigin) / r.heightMeters;
      return { left: nx * layout.w, top: ny * layout.h };
    }
    // pixel kind → reverse landscape→portrait rotation
    const nx = 1 - t.y / photo.height;
    const ny = t.x / photo.width;
    return { left: nx * layout.w, top: ny * layout.h };
  };

  return (
    <Pressable
      style={[styles.tagPhotoBox, { aspectRatio: aspect }]}
      onLayout={(e) => setLayout({ w: e.nativeEvent.layout.width, h: e.nativeEvent.layout.height })}
      onPress={handlePress}
    >
      <Image source={{ uri }} style={StyleSheet.absoluteFillObject} resizeMode="contain" />
      {taps.map((t, i) => {
        if (tapsPhotoIdx[i] !== activePhotoIdx) return null;
        const d = markerDisplay(t);
        if (!d) return null;
        const isActive = i === activeCorner;
        return (
          <View key={i} pointerEvents="none" style={[styles.marker, { left: d.left - 14, top: d.top - 14 }, isActive && styles.markerActive]}>
            <Text style={styles.markerText}>{i + 1}</Text>
          </View>
        );
      })}
    </Pressable>
  );
}

function TwoPhotoTagView({
  photoA, photoB, tapsA, tapsB, setTapsA, setTapsB, activeCorner, setActiveCorner,
  onBack, onCompute, aIndex, bIndex
}: {
  photoA: TaggedPhoto; photoB: TaggedPhoto;
  tapsA: (Pixel | null)[]; tapsB: (Pixel | null)[];
  setTapsA: React.Dispatch<React.SetStateAction<(Pixel | null)[]>>;
  setTapsB: React.Dispatch<React.SetStateAction<(Pixel | null)[]>>;
  activeCorner: number;
  setActiveCorner: (i: number) => void;
  onBack: () => void;
  onCompute: () => void;
  aIndex: number;
  bIndex: number;
}) {
  const aDone = tapsA.every(t => t !== null);
  const bDone = tapsB.every(t => t !== null);
  const ready = aDone && bDone;

  const onTapPhoto = (which: "A" | "B", displayPx: Pixel) => {
    const idx = activeCorner;
    if (which === "A") {
      setTapsA(prev => { const n = [...prev]; n[idx] = displayPx; return n; });
    } else {
      setTapsB(prev => { const n = [...prev]; n[idx] = displayPx; return n; });
    }
  };

  return (
    <SafeAreaView style={styles.tagRoot}>
      <View style={styles.tagHeader}>
        <Text style={styles.tagTitle}>Tocca i 4 angoli su entrambe</Text>
        <Text style={styles.tagSub}>Stai segnando: <Text style={{ color: COLORS.primary, fontWeight: "700" }}>{CORNER_LABELS[activeCorner]}</Text></Text>
        <View style={styles.cornerRow}>
          {CORNER_LABELS.map((label, i) => (
            <Pressable key={label} onPress={() => setActiveCorner(i)} style={[styles.cornerChip, activeCorner === i && styles.cornerChipActive]}>
              <Text style={[styles.cornerChipText, activeCorner === i && { color: "#000" }]}>{i + 1}</Text>
            </Pressable>
          ))}
        </View>
      </View>
      <View style={styles.tagPair}>
        <PhotoTile label={`Foto #${aIndex + 1}`} photo={photoA} taps={tapsA} onTap={(p) => onTapPhoto("A", p)} activeCorner={activeCorner} />
        <PhotoTile label={`Foto #${bIndex + 1}`} photo={photoB} taps={tapsB} onTap={(p) => onTapPhoto("B", p)} activeCorner={activeCorner} />
      </View>
      <View style={styles.tagBottom}>
        <SmallBtn label="Indietro" kind="secondary" onPress={onBack} />
        <SmallBtn label={ready ? "Calcola" : `${tapsA.filter(t => t).length + tapsB.filter(t => t).length}/8`}
                  kind={ready ? "primary" : "disabled"}
                  onPress={() => ready && onCompute()} />
      </View>
    </SafeAreaView>
  );
}

function PhotoTile({
  label, photo, taps, onTap, activeCorner
}: {
  label: string; photo: TaggedPhoto; taps: (Pixel | null)[];
  onTap: (px: Pixel) => void; activeCorner: number;
}) {
  const aspect = photo.height / photo.width;
  const [layout, setLayout] = React.useState<{ w: number; h: number }>({ w: 0, h: 0 });

  const handlePress = (e: { nativeEvent: { locationX: number; locationY: number } }) => {
    if (layout.w === 0 || layout.h === 0) return;
    const sx = e.nativeEvent.locationX, sy = e.nativeEvent.locationY;
    const nx = sx / layout.w, ny = sy / layout.h;
    const rawX = ny * photo.width;
    const rawY = (1 - nx) * photo.height;
    onTap({ x: rawX, y: rawY });
  };

  const markerDisplay = (p: Pixel | null): { left: number; top: number } | null => {
    if (!p || layout.w === 0) return null;
    const nx = 1 - p.y / photo.height;
    const ny = p.x / photo.width;
    return { left: nx * layout.w, top: ny * layout.h };
  };

  return (
    <View style={styles.tagPhotoCard}>
      <Text style={styles.tagPhotoLabel}>{label}</Text>
      <Pressable
        style={[styles.tagPhotoBox, { aspectRatio: aspect }]}
        onLayout={(e) => setLayout({ w: e.nativeEvent.layout.width, h: e.nativeEvent.layout.height })}
        onPress={handlePress}
      >
        <Image source={{ uri: photo.uri }} style={StyleSheet.absoluteFillObject} resizeMode="contain" />
        {taps.map((t, i) => {
          const d = markerDisplay(t);
          if (!d) return null;
          const isActive = i === activeCorner;
          return (
            <View key={i} pointerEvents="none" style={[styles.marker, { left: d.left - 14, top: d.top - 14 }, isActive && styles.markerActive]}>
              <Text style={styles.markerText}>{i + 1}</Text>
            </View>
          );
        })}
      </Pressable>
    </View>
  );
}

function ResultView({ result, onAgain, onBack }: { result: FacciataResult3D; onAgain: () => void; onBack: () => void }) {
  return (
    <SafeAreaView style={styles.resultRoot}>
      <View style={styles.resultCard}>
        <Text style={styles.resultTitle}>Risultato</Text>
        <ResRow label="Larghezza" value={fmt(result.larghezzaM) + " m"} />
        <ResRow label="Altezza" value={fmt(result.altezzaM) + " m"} />
        <ResRow label="NETTO" value={fmt(result.nettaMq) + " m²"} big />
        <View style={styles.row}>
          <SmallBtn label="Indietro" kind="secondary" onPress={onBack} />
          <SmallBtn label="Nuova" kind="primary" onPress={onAgain} />
        </View>
      </View>
    </SafeAreaView>
  );
}

function ResRow({ label, value, big }: { label: string; value: string; big?: boolean }) {
  return (
    <View style={styles.resRow}>
      <Text style={[styles.resLabel, big && { fontSize: 18 }]}>{label}</Text>
      <Text style={[styles.resVal, big && { fontSize: 32, fontWeight: "800", color: COLORS.primary }]}>{value}</Text>
    </View>
  );
}

function Chip({ label, color }: { label: string; color: string }) {
  return <View style={[styles.chip, { borderColor: color }]}><Text style={[styles.chipText, { color }]}>{label}</Text></View>;
}

function SmallBtn({ label, onPress, kind }: { label: string; onPress: () => void; kind: "primary" | "secondary" | "disabled" }) {
  const bg = kind === "primary" ? COLORS.primary : kind === "secondary" ? COLORS.surfaceElev : COLORS.surface;
  const color = kind === "primary" ? "#000" : kind === "disabled" ? COLORS.textMuted : "#fff";
  return (
    <Pressable onPress={kind === "disabled" ? undefined : onPress} style={[styles.smallBtn, { backgroundColor: bg }]}>
      <Text style={[styles.smallBtnText, { color }]}>{label}</Text>
    </Pressable>
  );
}

function fmt(n: number): string { return n.toFixed(2).replace(".", ","); }

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
  overlay: { flex: 1, justifyContent: "space-between" },
  topBar: { paddingHorizontal: SPACING.md, paddingTop: SPACING.sm, alignItems: "center" },
  phaseLabel: { color: COLORS.text, fontSize: 22, fontWeight: "700" },
  subLabel: { color: COLORS.textMuted, marginTop: 4, textAlign: "center" },
  statusRow: { flexDirection: "row", gap: 8, marginTop: 8 },
  modeRow: { flexDirection: "row", gap: 6, marginTop: 8 },
  unlockBtn: { paddingHorizontal: 14, paddingVertical: 6, borderRadius: 16, borderWidth: 1, borderColor: COLORS.warning, backgroundColor: "rgba(0,0,0,0.45)" },
  unlockBtnText: { color: COLORS.warning, fontSize: 12, fontWeight: "600" },
  primaryActionBtn: { paddingHorizontal: 20, paddingVertical: 10, borderRadius: 22, backgroundColor: COLORS.primary },
  primaryActionBtnText: { color: "#000", fontSize: 14, fontWeight: "700" },
  centerReticle: { position: "absolute", top: 0, left: 0, right: 0, bottom: 0, justifyContent: "center", alignItems: "center" },
  reticleCross: { width: 40, height: 40, borderWidth: 2, borderColor: "rgba(34,197,94,0.9)", borderRadius: 4 },
  chip: { borderWidth: 1, paddingHorizontal: 10, paddingVertical: 4, borderRadius: 12, backgroundColor: "rgba(0,0,0,0.45)" },
  chipText: { fontSize: 12, fontWeight: "600" },

  shutterBar: { paddingHorizontal: SPACING.md, paddingBottom: SPACING.lg, gap: SPACING.sm },
  thumbRow: { gap: 6, paddingHorizontal: 4 },
  thumbWrap: { width: 56, height: 56, borderRadius: 8, overflow: "hidden", borderWidth: 1, borderColor: COLORS.border },
  thumbWrapActive: { borderColor: COLORS.primary, borderWidth: 2 },
  thumb: { width: 56, height: 56 },
  thumbBadge: { position: "absolute", top: 2, left: 2, backgroundColor: "rgba(0,0,0,0.8)", borderRadius: 8, paddingHorizontal: 5, paddingVertical: 1 },
  thumbBadgeText: { color: "#fff", fontSize: 10, fontWeight: "700" },
  shutterRow: { flexDirection: "row", alignItems: "center", gap: SPACING.md },
  shutter: { width: 72, height: 72, borderRadius: 36, borderWidth: 4, borderColor: "#fff", justifyContent: "center", alignItems: "center", backgroundColor: "rgba(0,0,0,0.3)" },
  shutterInner: { width: 56, height: 56, borderRadius: 28, backgroundColor: "#fff" },
  hintSmall: { color: COLORS.textMuted, fontSize: 12, textAlign: "center" },

  tagRoot: { flex: 1, backgroundColor: COLORS.bg },
  tagHeader: { paddingHorizontal: SPACING.md, paddingTop: SPACING.sm, gap: 4 },
  tagTitle: { color: COLORS.text, fontSize: 20, fontWeight: "700" },
  tagSub: { color: COLORS.textMuted },
  cornerRow: { flexDirection: "row", gap: 6, marginTop: 6 },
  cornerChip: { width: 32, height: 32, borderRadius: 16, backgroundColor: COLORS.surface, justifyContent: "center", alignItems: "center", borderWidth: 1, borderColor: COLORS.border },
  cornerChipActive: { backgroundColor: COLORS.primary, borderColor: COLORS.primary },
  cornerChipDone: { borderColor: COLORS.primary },
  cornerChipText: { color: "#fff", fontWeight: "700" },

  singlePhotoWrap: { flex: 1, padding: SPACING.md, alignItems: "center", justifyContent: "center" },
  photoPickerRow: { paddingHorizontal: SPACING.md, paddingVertical: SPACING.sm },

  tagPair: { flex: 1, padding: SPACING.md, gap: SPACING.sm },
  tagPhotoCard: { flex: 1, gap: 4 },
  tagPhotoLabel: { color: COLORS.textMuted, fontSize: 12 },
  tagPhotoBox: { backgroundColor: "#000", borderRadius: 10, overflow: "hidden", alignSelf: "center", width: "100%" },
  marker: { position: "absolute", width: 28, height: 28, borderRadius: 14, backgroundColor: "rgba(34,197,94,0.85)", borderWidth: 2, borderColor: "#fff", justifyContent: "center", alignItems: "center" },
  markerActive: { backgroundColor: COLORS.danger, transform: [{ scale: 1.15 }] },
  markerText: { color: "#000", fontSize: 14, fontWeight: "800" },
  tagBottom: { flexDirection: "row", padding: SPACING.md, gap: SPACING.sm },

  resultRoot: { flex: 1, backgroundColor: COLORS.bg, justifyContent: "center", padding: SPACING.lg },
  resultCard: { backgroundColor: COLORS.surface, padding: SPACING.lg, borderRadius: 16, gap: SPACING.sm },
  resultTitle: { color: COLORS.text, fontSize: 16, fontWeight: "700", marginBottom: 4 },
  resRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", paddingVertical: 4 },
  resLabel: { color: COLORS.text, fontSize: 15 },
  resVal: { color: COLORS.text, fontSize: 16, fontWeight: "600" },
  row: { flexDirection: "row", gap: 8, flexWrap: "wrap", marginTop: SPACING.md },

  smallBtn: { flex: 1, paddingVertical: 14, borderRadius: 12, alignItems: "center" },
  smallBtnText: { fontSize: 15, fontWeight: "600" }
});
