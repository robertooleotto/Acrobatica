import * as React from "react";
import { Alert, Image, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import * as ImagePicker from "expo-image-picker";
import { COLORS, SPACING } from "../theme";

type Phase = "pick" | "tagging" | "result";
type Pixel = { x: number; y: number };
type ScalePoint = Pixel;

interface GalleryPhoto {
  uri: string;
  width: number;
  height: number;
}

interface MeasureResult {
  larghezzaM: number;
  altezzaM: number;
  areaMq: number;
}

const CORNER_LABELS = ["Alto-sx", "Alto-dx", "Basso-dx", "Basso-sx"] as const;

export default function GalleryScanScreen() {
  const [phase, setPhase] = React.useState<Phase>("pick");
  const [photo, setPhoto] = React.useState<GalleryPhoto | null>(null);
  const [corners, setCorners] = React.useState<(Pixel | null)[]>([null, null, null, null]);
  const [scalePts, setScalePts] = React.useState<(ScalePoint | null)[]>([null, null]);
  const [scaleMetersText, setScaleMetersText] = React.useState("2.10");
  const [activeMode, setActiveMode] = React.useState<"corner" | "scale">("corner");
  const [activeCorner, setActiveCorner] = React.useState(0);
  const [activeScalePt, setActiveScalePt] = React.useState(0);
  const [result, setResult] = React.useState<MeasureResult | null>(null);

  const onPickPhoto = async () => {
    const perm = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (!perm.granted) {
      Alert.alert("Permesso negato", "Concedi accesso alla libreria foto in Impostazioni.");
      return;
    }
    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.Images,
      allowsEditing: false,
      quality: 1,
      exif: false
    });
    if (result.canceled || result.assets.length === 0) return;
    const a = result.assets[0]!;
    setPhoto({ uri: a.uri, width: a.width, height: a.height });
    setCorners([null, null, null, null]);
    setScalePts([null, null]);
    setActiveMode("corner");
    setActiveCorner(0);
    setActiveScalePt(0);
    setResult(null);
    setPhase("tagging");
  };

  const onTagPixel = (px: Pixel) => {
    if (activeMode === "corner") {
      setCorners(prev => {
        const next = [...prev]; next[activeCorner] = px; return next;
      });
      // advance to next missing corner
      const updated = [...corners]; updated[activeCorner] = px;
      const nextEmpty = updated.findIndex(c => c === null);
      if (nextEmpty >= 0) setActiveCorner(nextEmpty);
      else setActiveMode("scale");
    } else {
      setScalePts(prev => {
        const next = [...prev]; next[activeScalePt] = px; return next;
      });
      const updated = [...scalePts]; updated[activeScalePt] = px;
      const nextEmpty = updated.findIndex(p => p === null);
      if (nextEmpty >= 0) setActiveScalePt(nextEmpty);
    }
  };

  const cornersReady = corners.every(c => c !== null);
  const scaleReady = scalePts.every(p => p !== null);
  const scaleMeters = parseFloat(scaleMetersText.replace(",", "."));
  const computeReady = cornersReady && scaleReady && scaleMeters > 0;

  const compute = () => {
    if (!photo || !computeReady) return;
    const [s1, s2] = scalePts as [ScalePoint, ScalePoint];
    const sdx = s2.x - s1.x, sdy = s2.y - s1.y;
    const sPix = Math.sqrt(sdx * sdx + sdy * sdy);
    if (sPix < 1e-3) {
      Alert.alert("Riferimento di scala troppo corto", "I due punti scala sono coincidenti, riposizionali.");
      return;
    }
    const pxPerM = sPix / scaleMeters;
    const [tl, tr, br, bl] = corners as [Pixel, Pixel, Pixel, Pixel];
    const topPx = Math.hypot(tr.x - tl.x, tr.y - tl.y);
    const botPx = Math.hypot(br.x - bl.x, br.y - bl.y);
    const leftPx = Math.hypot(bl.x - tl.x, bl.y - tl.y);
    const rightPx = Math.hypot(br.x - tr.x, br.y - tr.y);
    const widthM = (topPx + botPx) / 2 / pxPerM;
    const heightM = (leftPx + rightPx) / 2 / pxPerM;
    const areaMq = widthM * heightM;
    setResult({ larghezzaM: widthM, altezzaM: heightM, areaMq });
    setPhase("result");
  };

  const onReset = () => {
    setPhoto(null);
    setCorners([null, null, null, null]);
    setScalePts([null, null]);
    setResult(null);
    setPhase("pick");
  };

  return (
    <View style={styles.root}>
      {phase === "pick" && (
        <SafeAreaView style={styles.pickRoot}>
          <Text style={styles.pickTitle}>Misura da galleria</Text>
          <Text style={styles.pickHint}>
            Carica una foto frontale della facciata. Avrai bisogno di indicare un oggetto di dimensione nota
            nella foto (es. una porta = 2.10 m) per dare la scala.
          </Text>
          <View style={{ flex: 1 }} />
          <Pressable style={styles.pickBtn} onPress={onPickPhoto}>
            <Text style={styles.pickBtnText}>Carica foto dal rullino</Text>
          </Pressable>
        </SafeAreaView>
      )}

      {phase === "tagging" && photo && (
        <SafeAreaView style={styles.tagRoot}>
          <View style={styles.tagHeader}>
            <Text style={styles.tagTitle}>{activeMode === "corner" ? "Tocca i 4 angoli" : "Tocca i 2 punti scala"}</Text>
            {activeMode === "corner" ? (
              <>
                <Text style={styles.tagSub}>
                  Stai segnando: <Text style={{ color: COLORS.primary, fontWeight: "700" }}>{CORNER_LABELS[activeCorner]}</Text>
                </Text>
                <View style={styles.cornerRow}>
                  {CORNER_LABELS.map((label, i) => (
                    <Pressable key={label} onPress={() => setActiveCorner(i)} style={[styles.cornerChip, activeCorner === i && styles.cornerChipActive, corners[i] && styles.cornerChipDone]}>
                      <Text style={[styles.cornerChipText, activeCorner === i && { color: "#000" }]}>{i + 1}</Text>
                    </Pressable>
                  ))}
                </View>
              </>
            ) : (
              <>
                <Text style={styles.tagSub}>
                  Tocca due estremi di un oggetto di misura nota (es. una porta).
                </Text>
                <View style={styles.cornerRow}>
                  {[0, 1].map(i => (
                    <Pressable key={i} onPress={() => setActiveScalePt(i)} style={[styles.cornerChip, activeScalePt === i && styles.cornerChipActive, scalePts[i] && styles.cornerChipDone]}>
                      <Text style={[styles.cornerChipText, activeScalePt === i && { color: "#000" }]}>{"S" + (i + 1)}</Text>
                    </Pressable>
                  ))}
                  <View style={styles.scaleInputBox}>
                    <TextInput
                      style={styles.scaleInput}
                      keyboardType="decimal-pad"
                      value={scaleMetersText}
                      onChangeText={setScaleMetersText}
                      placeholder="2.10"
                      placeholderTextColor={COLORS.textMuted}
                    />
                    <Text style={styles.scaleInputSuffix}>m</Text>
                  </View>
                </View>
              </>
            )}
            <View style={styles.modeSwitchRow}>
              <Pressable onPress={() => setActiveMode("corner")} style={[styles.modeSwitch, activeMode === "corner" && styles.modeSwitchActive]}>
                <Text style={[styles.modeSwitchText, activeMode === "corner" && { color: "#000" }]}>Angoli ({corners.filter(c => c).length}/4)</Text>
              </Pressable>
              <Pressable onPress={() => setActiveMode("scale")} style={[styles.modeSwitch, activeMode === "scale" && styles.modeSwitchActive]}>
                <Text style={[styles.modeSwitchText, activeMode === "scale" && { color: "#000" }]}>Scala ({scalePts.filter(p => p).length}/2)</Text>
              </Pressable>
            </View>
          </View>
          <PhotoCanvas
            photo={photo}
            corners={corners}
            scalePts={scalePts}
            activeMode={activeMode}
            activeCorner={activeCorner}
            activeScalePt={activeScalePt}
            onTap={onTagPixel}
          />
          <View style={styles.tagBottom}>
            <SmallBtn label="Cambia foto" kind="secondary" onPress={() => setPhase("pick")} />
            <SmallBtn
              label={computeReady ? "Calcola" : `${corners.filter(c => c).length + scalePts.filter(p => p).length}/6`}
              kind={computeReady ? "primary" : "disabled"}
              onPress={compute}
            />
          </View>
        </SafeAreaView>
      )}

      {phase === "result" && result && (
        <SafeAreaView style={styles.resultRoot}>
          <View style={styles.resultCard}>
            <Text style={styles.resultTitle}>Risultato</Text>
            <ResRow label="Larghezza" value={fmt(result.larghezzaM) + " m"} />
            <ResRow label="Altezza" value={fmt(result.altezzaM) + " m"} />
            <ResRow label="AREA" value={fmt(result.areaMq) + " m²"} big />
            <Text style={styles.dim}>
              Calcolo via riferimento di scala. Per accuratezza migliore, usa una foto frontale e un riferimento ben visibile.
            </Text>
            <View style={styles.row}>
              <SmallBtn label="Modifica" kind="secondary" onPress={() => setPhase("tagging")} />
              <SmallBtn label="Nuova" kind="primary" onPress={onReset} />
            </View>
          </View>
        </SafeAreaView>
      )}
    </View>
  );
}

function PhotoCanvas({
  photo, corners, scalePts, activeMode, activeCorner, activeScalePt, onTap
}: {
  photo: GalleryPhoto;
  corners: (Pixel | null)[];
  scalePts: (Pixel | null)[];
  activeMode: "corner" | "scale";
  activeCorner: number;
  activeScalePt: number;
  onTap: (px: Pixel) => void;
}) {
  const aspect = photo.width / photo.height;
  const [layout, setLayout] = React.useState<{ w: number; h: number }>({ w: 0, h: 0 });

  const handlePress = (e: { nativeEvent: { locationX: number; locationY: number } }) => {
    if (layout.w === 0) return;
    const sx = e.nativeEvent.locationX;
    const sy = e.nativeEvent.locationY;
    const px = (sx / layout.w) * photo.width;
    const py = (sy / layout.h) * photo.height;
    onTap({ x: px, y: py });
  };

  const toDisplay = (p: Pixel | null): { left: number; top: number } | null => {
    if (!p || layout.w === 0) return null;
    return { left: (p.x / photo.width) * layout.w, top: (p.y / photo.height) * layout.h };
  };

  return (
    <View style={styles.canvasWrap}>
      <Pressable
        style={[styles.tagPhotoBox, { aspectRatio: aspect }]}
        onLayout={(e) => setLayout({ w: e.nativeEvent.layout.width, h: e.nativeEvent.layout.height })}
        onPress={handlePress}
      >
        <Image source={{ uri: photo.uri }} style={StyleSheet.absoluteFillObject} resizeMode="contain" />
        {corners.map((c, i) => {
          const d = toDisplay(c);
          if (!d) return null;
          const isActive = activeMode === "corner" && i === activeCorner;
          return (
            <View key={"c" + i} pointerEvents="none" style={[styles.marker, styles.cornerMarker, { left: d.left - 14, top: d.top - 14 }, isActive && styles.markerActive]}>
              <Text style={styles.markerText}>{i + 1}</Text>
            </View>
          );
        })}
        {scalePts.map((c, i) => {
          const d = toDisplay(c);
          if (!d) return null;
          const isActive = activeMode === "scale" && i === activeScalePt;
          return (
            <View key={"s" + i} pointerEvents="none" style={[styles.marker, styles.scaleMarker, { left: d.left - 14, top: d.top - 14 }, isActive && styles.markerActive]}>
              <Text style={styles.markerText}>{"S" + (i + 1)}</Text>
            </View>
          );
        })}
        {scalePts[0] && scalePts[1] && (
          <ScaleLine a={toDisplay(scalePts[0])!} b={toDisplay(scalePts[1])!} />
        )}
      </Pressable>
    </View>
  );
}

function ScaleLine({ a, b }: { a: { left: number; top: number }; b: { left: number; top: number } }) {
  const dx = b.left - a.left;
  const dy = b.top - a.top;
  const len = Math.hypot(dx, dy);
  const angle = Math.atan2(dy, dx) * 180 / Math.PI;
  return (
    <View pointerEvents="none" style={{
      position: "absolute",
      left: a.left,
      top: a.top - 1,
      width: len,
      height: 2,
      backgroundColor: COLORS.info,
      transform: [{ translateX: 0 }, { rotate: `${angle}deg` }],
      transformOrigin: "0% 50%"
    }} />
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

  pickRoot: { flex: 1, padding: SPACING.lg },
  pickTitle: { color: COLORS.text, fontSize: 26, fontWeight: "800", marginTop: SPACING.lg },
  pickHint: { color: COLORS.textMuted, marginTop: SPACING.sm, lineHeight: 20 },
  pickBtn: { backgroundColor: COLORS.primary, padding: 20, borderRadius: 14, alignItems: "center" },
  pickBtnText: { color: "#000", fontSize: 18, fontWeight: "700" },

  tagRoot: { flex: 1, backgroundColor: COLORS.bg },
  tagHeader: { paddingHorizontal: SPACING.md, paddingTop: SPACING.sm, gap: 4 },
  tagTitle: { color: COLORS.text, fontSize: 20, fontWeight: "700" },
  tagSub: { color: COLORS.textMuted },
  cornerRow: { flexDirection: "row", gap: 6, marginTop: 6, alignItems: "center", flexWrap: "wrap" },
  cornerChip: { width: 32, height: 32, borderRadius: 16, backgroundColor: COLORS.surface, justifyContent: "center", alignItems: "center", borderWidth: 1, borderColor: COLORS.border },
  cornerChipActive: { backgroundColor: COLORS.primary, borderColor: COLORS.primary },
  cornerChipDone: { borderColor: COLORS.primary },
  cornerChipText: { color: "#fff", fontWeight: "700", fontSize: 12 },
  scaleInputBox: { flexDirection: "row", alignItems: "center", marginLeft: 8, backgroundColor: COLORS.surface, borderWidth: 1, borderColor: COLORS.border, borderRadius: 8, paddingHorizontal: 8, paddingVertical: 2 },
  scaleInput: { color: COLORS.text, fontSize: 16, fontWeight: "600", minWidth: 60, padding: 0 },
  scaleInputSuffix: { color: COLORS.textMuted, marginLeft: 4 },
  modeSwitchRow: { flexDirection: "row", gap: 6, marginTop: 8 },
  modeSwitch: { paddingHorizontal: 12, paddingVertical: 6, borderRadius: 14, borderWidth: 1, borderColor: COLORS.border, backgroundColor: COLORS.surface },
  modeSwitchActive: { backgroundColor: COLORS.primary, borderColor: COLORS.primary },
  modeSwitchText: { color: "#fff", fontSize: 12, fontWeight: "600" },

  canvasWrap: { flex: 1, padding: SPACING.md, alignItems: "center", justifyContent: "center" },
  tagPhotoBox: { backgroundColor: "#000", borderRadius: 10, overflow: "hidden", width: "100%", maxHeight: "100%" },
  marker: { position: "absolute", width: 28, height: 28, borderRadius: 14, borderWidth: 2, borderColor: "#fff", justifyContent: "center", alignItems: "center" },
  cornerMarker: { backgroundColor: "rgba(34,197,94,0.85)" },
  scaleMarker: { backgroundColor: "rgba(59,130,246,0.85)" },
  markerActive: { transform: [{ scale: 1.2 }], borderColor: COLORS.danger },
  markerText: { color: "#000", fontSize: 12, fontWeight: "800" },
  tagBottom: { flexDirection: "row", padding: SPACING.md, gap: SPACING.sm },

  resultRoot: { flex: 1, backgroundColor: COLORS.bg, justifyContent: "center", padding: SPACING.lg },
  resultCard: { backgroundColor: COLORS.surface, padding: SPACING.lg, borderRadius: 16, gap: SPACING.sm },
  resultTitle: { color: COLORS.text, fontSize: 16, fontWeight: "700", marginBottom: 4 },
  resRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", paddingVertical: 4 },
  resLabel: { color: COLORS.text, fontSize: 15 },
  resVal: { color: COLORS.text, fontSize: 16, fontWeight: "600" },
  dim: { color: COLORS.textMuted, fontSize: 12, fontStyle: "italic", marginTop: 4 },
  row: { flexDirection: "row", gap: 8, flexWrap: "wrap", marginTop: SPACING.md },

  smallBtn: { flex: 1, paddingVertical: 14, borderRadius: 12, alignItems: "center" },
  smallBtnText: { fontSize: 15, fontWeight: "600" }
});
