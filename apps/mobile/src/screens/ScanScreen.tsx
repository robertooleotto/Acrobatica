import * as React from "react";
import { Alert, Pressable, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import {
  ExpoArFacadeModule, ExpoArFacadeView,
  type ArTapEvent, type ArTrackingState,
  type ArFacadeProgressEvent, type ArFacadeCaptureResult,
  type ArRoomPlanResult,
  type ExpoArFacadeViewRef
} from "@acrobatica/expo-ar-facade";
import { computeFacciataNettaMq3D, type Point3D, type Quad3D, type FacciataResult3D } from "@acrobatica/shared";
import { COLORS, SPACING } from "../theme";
import { buildFacciataScan, useScanReducer, type ScanState } from "../scanState";

const CORNER_LABELS = ["Alto-sx", "Alto-dx", "Basso-dx", "Basso-sx"] as const;

type CaptureMode = "auto" | "manual" | "pro";
type AutoPhase = "idle" | "running";

export default function ScanScreen() {
  const [state, dispatch] = useScanReducer();
  const [tracking, setTracking] = React.useState<ArTrackingState>("limited.initializing");
  const [hasLidar, setHasLidar] = React.useState(false);
  const [hasRoomPlan, setHasRoomPlan] = React.useState(false);
  const [result, setResult] = React.useState<FacciataResult3D | null>(null);
  const [mode, setMode] = React.useState<CaptureMode>("auto");
  const [autoPhase, setAutoPhase] = React.useState<AutoPhase>("idle");
  const [autoStats, setAutoStats] = React.useState<ArFacadeProgressEvent>({ areaMq: 0, triangles: 0, ready: false });
  const [proRunning, setProRunning] = React.useState(false);
  const [proResult, setProResult] = React.useState<ArRoomPlanResult | null>(null);
  const viewRef = React.useRef<ExpoArFacadeViewRef | null>(null);

  React.useEffect(() => {
    ExpoArFacadeModule.requestAuthorization().then(() => {
      setHasLidar(ExpoArFacadeModule.hasLidar());
      setHasRoomPlan(ExpoArFacadeModule.isRoomPlanSupported());
    });
  }, []);

  React.useEffect(() => {
    if (state.phase === "result") {
      const scan = buildFacciataScan(state);
      if (scan) setResult(computeFacciataNettaMq3D(scan));
    }
  }, [state]);

  const onTap = (e: { nativeEvent: ArTapEvent }) => {
    if (state.phase === "placing_corners" && mode === "auto") return;
    const wp = e.nativeEvent.worldPoint;
    if (!wp) {
      Alert.alert("Punto non rilevato", "Punta una superficie con overlay verde.");
      return;
    }
    dispatch({ type: "add_point", point: { x: wp.x, y: wp.y, z: wp.z } });
  };

  const onStartAuto = async () => {
    if (!viewRef.current) return;
    if (!hasLidar) {
      Alert.alert("LiDAR non disponibile", "La modalita Auto richiede iPhone Pro con LiDAR. Usa Manuale.");
      return;
    }
    setAutoStats({ areaMq: 0, triangles: 0, ready: false });
    const ok = await viewRef.current.startAutoCapture();
    if (!ok) {
      Alert.alert("Impossibile avviare", "Inquadra la facciata e riprova.");
      return;
    }
    setAutoPhase("running");
  };

  const onConfirmAuto = async () => {
    if (!viewRef.current) return;
    const r: ArFacadeCaptureResult = await viewRef.current.captureFacadeAuto();
    setAutoPhase("idle");
    if (!r.corners || r.corners.length !== 4 || !r.ready) {
      Alert.alert("Rilevamento insufficiente",
        "Pochi triangoli rilevati. Muovi il telefono panoramicamente sulla facciata e riprova.");
      return;
    }
    dispatch({
      type: "set_corners",
      corners: r.corners.map(p => ({ x: p.x, y: p.y, z: p.z })) as unknown as Quad3D
    });
  };

  const onCancelAuto = async () => {
    if (viewRef.current) await viewRef.current.stopAutoCapture();
    setAutoPhase("idle");
  };

  const onStartPro = async () => {
    if (!viewRef.current) return;
    if (!hasRoomPlan) {
      Alert.alert("RoomPlan non disponibile", "Richiede iPhone Pro con LiDAR e iOS 16+.");
      return;
    }
    setProRunning(true);
    const r = await viewRef.current.startRoomPlanCapture();
    setProRunning(false);
    if (!r.ready) {
      Alert.alert("Scansione fallita", r.error ?? "Nessun muro rilevato.");
      return;
    }
    setProResult(r);
    if (r.corners && r.corners.length === 4) {
      dispatch({
        type: "set_corners",
        corners: r.corners.map(p => ({ x: p.x, y: p.y, z: p.z })) as unknown as Quad3D
      });
    }
  };

  return (
    <View style={styles.root}>
      <ExpoArFacadeView
        ref={viewRef}
        style={StyleSheet.absoluteFillObject}
        showPlaneOverlay
        useLidarMesh
        showSceneMesh={autoPhase === "running"}
        onTap={onTap}
        onTrackingStateChange={(e) => setTracking(e.nativeEvent.state)}
        onSessionError={(e) => Alert.alert("ARKit error", e.nativeEvent.message)}
        onFacadeProgress={(e) => setAutoStats({
          areaMq: e.nativeEvent.areaMq,
          triangles: e.nativeEvent.triangles,
          ready: e.nativeEvent.ready
        })}
      />
      {proRunning ? (
        <>
          <SafeAreaView style={styles.proBannerWrap} pointerEvents="none">
            <View style={styles.proBanner}>
              <Text style={styles.proBannerTitle}>Apple RoomPlan attivo</Text>
              <Text style={styles.proBannerSub}>Muovi il telefono lentamente per coprire muro e finestre.</Text>
            </View>
          </SafeAreaView>
          <View style={styles.proDoneWrap}>
            <Pressable
              style={({ pressed }) => [styles.proDoneBtn, pressed && { opacity: 0.8 }]}
              hitSlop={20}
              onPress={async () => {
                if (viewRef.current) await viewRef.current.endRoomPlanCapture();
              }}
            >
              <Text style={styles.proDoneText}>Termina scansione</Text>
            </Pressable>
          </View>
        </>
      ) : (
      <SafeAreaView style={styles.overlay} pointerEvents="box-none">
        <View style={styles.topBar} pointerEvents="box-none">
          <Text style={styles.phaseLabel}>{phaseToLabel(state, mode, autoPhase, proRunning)}</Text>
          <Text style={styles.subLabel}>{subLabel(state, mode, autoPhase, autoStats, proRunning)}</Text>
          <View style={styles.statusRow}>
            <Chip label={tracking === "normal" ? "Tracking OK" : tracking} color={tracking === "normal" ? COLORS.primary : COLORS.warning} />
            <Chip label={hasLidar ? "LiDAR" : "no LiDAR"} color={hasLidar ? COLORS.info : COLORS.textMuted} />
          </View>
          {state.phase === "placing_corners" && autoPhase === "idle" && !proRunning && (
            <View style={styles.modeRow}>
              <ModeBtn label="Auto" active={mode === "auto"} onPress={() => setMode("auto")} />
              <ModeBtn label="Manuale" active={mode === "manual"} onPress={() => setMode("manual")} />
              {hasRoomPlan && <ModeBtn label="Pro" active={mode === "pro"} onPress={() => setMode("pro")} />}
            </View>
          )}
        </View>
        <View style={{ flex: 1 }} pointerEvents="none" />
        <BottomBar
          state={state}
          mode={mode}
          autoPhase={autoPhase}
          autoStats={autoStats}
          proRunning={proRunning}
          proResult={proResult}
          dispatch={dispatch}
          result={result}
          onStartAuto={onStartAuto}
          onConfirmAuto={onConfirmAuto}
          onCancelAuto={onCancelAuto}
          onStartPro={onStartPro}
        />
      </SafeAreaView>
      )}
    </View>
  );
}

function BottomBar({
  state, mode, autoPhase, autoStats, proRunning, proResult, dispatch, result,
  onStartAuto, onConfirmAuto, onCancelAuto, onStartPro
}: {
  state: ScanState;
  mode: CaptureMode;
  autoPhase: AutoPhase;
  autoStats: ArFacadeProgressEvent;
  proRunning: boolean;
  proResult: ArRoomPlanResult | null;
  dispatch: React.Dispatch<Parameters<ReturnType<typeof useScanReducer>[1]>[0]>;
  result: FacciataResult3D | null;
  onStartAuto: () => void;
  onConfirmAuto: () => void;
  onCancelAuto: () => void;
  onStartPro: () => void;
}) {
  if (state.phase === "placing_corners" && mode === "pro") {
    if (proRunning) {
      return (
        <View style={styles.bottomBar}>
          <Text style={styles.hint}>Scansione Pro attiva. Segui le indicazioni di Apple. Premi Fine quando vedi muro + finestre.</Text>
        </View>
      );
    }
    return (
      <View style={styles.bottomBar}>
        <Text style={styles.hint}>Modalita Pro: Apple RoomPlan rileva muro + finestre automaticamente. Distanza max ~5m, indoor o facciate basse.</Text>
        <Btn label="Avvia scansione Pro" onPress={onStartPro} />
      </View>
    );
  }
  if (state.phase === "placing_corners" && mode === "auto") {
    if (autoPhase === "idle") {
      return (
        <View style={styles.bottomBar}>
          <Text style={styles.hint}>Inquadra la facciata e tocca Avvia. Poi muovi il telefono lateralmente per coprirla.</Text>
          <Btn label="Avvia rilevamento" onPress={onStartAuto} />
        </View>
      );
    }
    return (
      <View style={styles.bottomBar}>
        <Text style={styles.bigArea}>{fmt(autoStats.areaMq)} m2</Text>
        <Text style={styles.hint}>{autoStats.triangles} triangoli rilevati. Continua a muovere il telefono.</Text>
        <View style={styles.row}>
          <Btn label="Annulla" kind="secondary" onPress={onCancelAuto} />
          <Btn label="Conferma" kind={autoStats.ready ? "primary" : "disabled"}
               onPress={() => autoStats.ready && onConfirmAuto()} />
        </View>
      </View>
    );
  }
  if (state.phase === "placing_corners") {
    return (
      <View style={styles.bottomBar}>
        <Text style={styles.hint}>Tocca i 4 angoli: {CORNER_LABELS.join(" - ")}.</Text>
        {state.corners.length > 0 && <Btn label="Annulla ultimo" kind="secondary" onPress={() => dispatch({ type: "remove_last" })} />}
      </View>
    );
  }
  if (state.phase === "review_corners") {
    return (
      <View style={styles.bottomBar}>
        <Text style={styles.hint}>Aggiungi finestre o balconi extra.</Text>
        <View style={styles.row}>
          <Btn label="- Finestra" kind="danger" onPress={() => dispatch({ type: "start_excluded" })} />
          <Btn label="+ Balcone" kind="info" onPress={() => dispatch({ type: "start_extra" })} />
        </View>
        <Btn label={"Calcola (excl " + state.excluded.length + ", extra " + state.extras.length + ")"} onPress={() => dispatch({ type: "go_to_result" })} />
      </View>
    );
  }
  if (state.phase === "placing_excluded" || state.phase === "placing_extra") {
    const canClose = (state.inProgress?.points.length ?? 0) >= 3;
    return (
      <View style={styles.bottomBar}>
        <Text style={styles.hint}>Tocca vertici, poi Chiudi.</Text>
        <View style={styles.row}>
          <Btn label="Annulla ultimo" kind="secondary" onPress={() => dispatch({ type: "remove_last" })} />
          <Btn label="Annulla" kind="secondary" onPress={() => dispatch({ type: "cancel_polygon" })} />
          <Btn label="Chiudi" kind={canClose ? "primary" : "disabled"} onPress={() => canClose && dispatch({ type: "close_polygon" })} />
        </View>
      </View>
    );
  }
  if (!result) return null;
  return (
    <View style={styles.bottomBar}>
      <Text style={styles.resultTitle}>Risultato</Text>
      <Row label="Lorda" value={fmt(result.lordaMq) + " m2"} />
      <Row label="Esclusi" value={"-" + fmt(result.esclusiMq) + " m2"} tone="danger" />
      <Row label="Extra" value={"+" + fmt(result.extraMq) + " m2"} tone="info" />
      <Row label="NETTO" value={fmt(result.nettaMq) + " m2"} tone="primary" big />
      <Text style={styles.dim}>facciata {fmt(result.larghezzaM)} x {fmt(result.altezzaM)} m</Text>
      <View style={styles.row}>
        <Btn label="Modifica" kind="secondary" onPress={() => dispatch({ type: "back_to_corners" })} />
        <Btn label="Nuova" onPress={() => dispatch({ type: "reset" })} />
      </View>
    </View>
  );
}

function Row({ label, value, tone, big }: { label: string; value: string; tone?: "primary"|"danger"|"info"; big?: boolean }) {
  const color = tone === "primary" ? COLORS.primary : tone === "danger" ? COLORS.danger : tone === "info" ? COLORS.info : COLORS.text;
  return (
    <View style={styles.resRow}>
      <Text style={[styles.resLabel, big && { fontSize: 18 }]}>{label}</Text>
      <Text style={[styles.resVal, { color }, big && { fontSize: 28, fontWeight: "700" }]}>{value}</Text>
    </View>
  );
}

function Btn({ label, onPress, kind = "primary" }: { label: string; onPress: () => void; kind?: "primary"|"secondary"|"danger"|"info"|"disabled" }) {
  const bg = { primary: COLORS.primary, secondary: COLORS.surfaceElev, danger: COLORS.danger, info: COLORS.info, disabled: COLORS.surface }[kind];
  return (
    <Pressable onPress={kind === "disabled" ? undefined : onPress} style={[styles.btn, { backgroundColor: bg }]}>
      <Text style={[styles.btnText, { color: kind === "primary" ? "#000" : kind === "disabled" ? COLORS.textMuted : "#fff" }]}>{label}</Text>
    </Pressable>
  );
}

function ModeBtn({ label, active, onPress }: { label: string; active: boolean; onPress: () => void }) {
  return (
    <Pressable onPress={onPress} style={[styles.modeBtn, active && styles.modeBtnActive]}>
      <Text style={[styles.modeBtnText, active && styles.modeBtnTextActive]}>{label}</Text>
    </Pressable>
  );
}

function Chip({ label, color }: { label: string; color: string }) {
  return <View style={[styles.chip, { borderColor: color }]}><Text style={[styles.chipText, { color }]}>{label}</Text></View>;
}

function phaseToLabel(state: ScanState, mode: CaptureMode, autoPhase: AutoPhase, proRunning: boolean): string {
  if (state.phase === "placing_corners") {
    if (mode === "pro") return proRunning ? "Scansione Pro" : "Modalita Pro";
    if (mode === "auto") return autoPhase === "running" ? "Rilevamento in corso" : "Modalita auto";
    return CORNER_LABELS[state.corners.length] ?? "Tap angoli";
  }
  switch (state.phase) {
    case "review_corners": return "Pronto - aggiungi esclusioni o calcola";
    case "placing_excluded": return "Finestra/porta";
    case "placing_extra": return "Balcone/extra";
    case "result": return "Risultato";
  }
}

function subLabel(state: ScanState, mode: CaptureMode, autoPhase: AutoPhase, autoStats: ArFacadeProgressEvent, proRunning: boolean): string {
  if (state.phase === "placing_corners") {
    if (mode === "pro") return proRunning ? "Apple RoomPlan attivo" : "Apple RoomPlan";
    if (mode === "auto") return autoPhase === "running" ? autoStats.triangles + " triangoli" : "LiDAR mesh";
    return state.corners.length + "/4 angoli";
  }
  if (state.phase === "placing_excluded" || state.phase === "placing_extra") {
    return (state.inProgress?.points.length ?? 0) + " punti (min 3)";
  }
  return "";
}

function fmt(n: number): string { return n.toFixed(2).replace(".", ","); }

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },
  overlay: { flex: 1, justifyContent: "space-between" },
  proBannerWrap: { position: "absolute", top: 0, left: 0, right: 0 },
  proBanner: { marginHorizontal: SPACING.md, marginTop: SPACING.sm, padding: SPACING.md, backgroundColor: "rgba(10,10,10,0.85)", borderRadius: 16, borderWidth: 1, borderColor: COLORS.border },
  proBannerTitle: { color: COLORS.primary, fontWeight: "700", fontSize: 16 },
  proBannerSub: { color: COLORS.textMuted, marginTop: 4, fontSize: 13 },
  proDoneWrap: { position: "absolute", left: 0, right: 0, bottom: 48, alignItems: "center" },
  proDoneBtn: { paddingHorizontal: SPACING.xl, paddingVertical: 16, borderRadius: 28, backgroundColor: COLORS.primary, minWidth: 240, alignItems: "center", elevation: 8, shadowColor: "#000", shadowOpacity: 0.4, shadowRadius: 8, shadowOffset: { width: 0, height: 4 } },
  proDoneText: { color: "#000", fontSize: 17, fontWeight: "700" },
  topBar: { paddingHorizontal: SPACING.md, paddingTop: SPACING.sm, alignItems: "center" },
  phaseLabel: { color: COLORS.text, fontSize: 22, fontWeight: "700" },
  subLabel: { color: COLORS.textMuted, marginTop: 4 },
  statusRow: { flexDirection: "row", gap: 8, marginTop: 8 },
  modeRow: { flexDirection: "row", gap: 6, marginTop: 8 },
  modeBtn: { paddingHorizontal: 14, paddingVertical: 6, borderRadius: 16, borderWidth: 1, borderColor: COLORS.border, backgroundColor: "rgba(0,0,0,0.45)" },
  modeBtnActive: { backgroundColor: COLORS.primary, borderColor: COLORS.primary },
  modeBtnText: { color: COLORS.textMuted, fontSize: 13, fontWeight: "600" },
  modeBtnTextActive: { color: "#000" },
  chip: { borderWidth: 1, paddingHorizontal: 10, paddingVertical: 4, borderRadius: 12, backgroundColor: "rgba(0,0,0,0.45)" },
  chipText: { fontSize: 12, fontWeight: "600" },
  bottomBar: { marginHorizontal: SPACING.md, marginTop: SPACING.md, marginBottom: SPACING.lg, padding: SPACING.md, backgroundColor: "rgba(10,10,10,0.85)", borderRadius: 16, borderWidth: 1, borderColor: COLORS.border, gap: SPACING.sm },
  hint: { color: COLORS.textMuted, fontSize: 13 },
  bigArea: { color: COLORS.primary, fontSize: 44, fontWeight: "800", textAlign: "center" },
  row: { flexDirection: "row", gap: 8, flexWrap: "wrap" },
  btn: { flex: 1, minWidth: 120, paddingVertical: 14, borderRadius: 12, alignItems: "center" },
  btnText: { fontSize: 15, fontWeight: "600" },
  resultTitle: { color: COLORS.text, fontSize: 16, fontWeight: "700" },
  resRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", paddingVertical: 4 },
  resLabel: { color: COLORS.text, fontSize: 15 },
  resVal: { color: COLORS.text, fontSize: 16, fontWeight: "600" },
  dim: { color: COLORS.textMuted, fontSize: 12, fontStyle: "italic" }
});
