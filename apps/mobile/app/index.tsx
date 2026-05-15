import * as React from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useRouter } from "expo-router";
import { ExpoArFacadeModule } from "@acrobatica/expo-ar-facade";
import { COLORS, SPACING } from "../src/theme";

export default function HomeScreen() {
  const router = useRouter();
  const [supported, setSupported] = React.useState<boolean | null>(null);
  const [hasLidar, setHasLidar] = React.useState<boolean | null>(null);
  React.useEffect(() => {
    setSupported(ExpoArFacadeModule.isSupported());
    setHasLidar(ExpoArFacadeModule.hasLidar());
  }, []);
  return (
    <SafeAreaView style={styles.root}>
      <View style={styles.brand}>
        <Text style={styles.brandText}>ACROBATICA</Text>
        <Text style={styles.brandSub}>Rilevamento facciate</Text>
      </View>
      <View style={styles.statusCard}>
        <Line label="ARKit world tracking" value={supported} />
        <Line label="Sensore LiDAR" value={hasLidar} />
        {hasLidar === false && (
          <Text style={styles.warn}>Niente LiDAR: la precisione sarà ridotta.</Text>
        )}
      </View>
      <View style={{ gap: SPACING.sm }}>
        <Pressable
          style={({ pressed }) => [styles.cta, { opacity: pressed ? 0.85 : 1 }]}
          onPress={() => router.push("/scan")}
          disabled={supported === false}
        >
          <Text style={styles.ctaText}>Inizia scansione (live)</Text>
        </Pressable>
        <Pressable
          style={({ pressed }) => [styles.ctaSecondary, { opacity: pressed ? 0.85 : 1 }]}
          onPress={() => router.push("/gallery")}
        >
          <Text style={styles.ctaSecondaryText}>Carica da galleria</Text>
        </Pressable>
      </View>
      <Text style={styles.footer}>v0.1 demo · @acrobatica/facciate</Text>
    </SafeAreaView>
  );
}

function Line({ label, value }: { label: string; value: boolean | null }) {
  const dot = value === null ? COLORS.textMuted : value ? COLORS.primary : COLORS.danger;
  const text = value === null ? "…" : value ? "OK" : "NO";
  return (
    <View style={styles.statusLine}>
      <View style={[styles.dot, { backgroundColor: dot }]} />
      <Text style={styles.statusLabel}>{label}</Text>
      <Text style={[styles.statusValue, { color: dot }]}>{text}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg, padding: SPACING.lg, justifyContent: "space-between" },
  brand: { marginTop: SPACING.xl, alignItems: "center" },
  brandText: { color: COLORS.text, fontSize: 36, fontWeight: "800", letterSpacing: 3 },
  brandSub: { color: COLORS.textMuted, marginTop: 4 },
  statusCard: { backgroundColor: COLORS.surface, padding: SPACING.md, borderRadius: 12, gap: SPACING.sm },
  statusLine: { flexDirection: "row", alignItems: "center", gap: 12 },
  dot: { width: 10, height: 10, borderRadius: 5 },
  statusLabel: { color: COLORS.text, flex: 1, fontSize: 15 },
  statusValue: { fontWeight: "700" },
  warn: { color: COLORS.warning, fontSize: 12, marginTop: 4 },
  cta: { padding: 20, borderRadius: 14, alignItems: "center", backgroundColor: COLORS.primary },
  ctaText: { color: "#000", fontSize: 18, fontWeight: "700" },
  ctaSecondary: { padding: 16, borderRadius: 14, alignItems: "center", backgroundColor: COLORS.surfaceElev, borderWidth: 1, borderColor: COLORS.border },
  ctaSecondaryText: { color: COLORS.text, fontSize: 16, fontWeight: "600" },
  footer: { color: COLORS.textMuted, textAlign: "center", fontSize: 11 }
});
