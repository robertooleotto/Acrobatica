#!/usr/bin/env bash
# run_oc_remote.sh — Bridge "calcolo Object Capture su Mac M4 remoto".
#
# Stadio 0 della pipeline facciata. La macchina locale (MacBook Pro Intel) NON
# può fare OC .raw: il calcolo gira su un Mac Apple Silicon affittato (es.
# Scaleway Mac mini M4 Pro). Questo script automatizza:
#   1. invio delle foto della sessione al Mac M4 (rsync/ssh)
#   2. compilazione + esecuzione di HelloPhotogrammetry.swift a dettaglio .raw
#   3. download del model.usdz risultante nella cartella sessione locale
#
# Uso:
#   ./run_oc_remote.sh --session <dir_sessione> --host <user@ip> [opzioni]
#
# Esempio:
#   ./run_oc_remote.sh \
#       --session ~/Documents/acrobatica_mesh/sess_6cdc \
#       --host admin@51.15.xx.xx \
#       --detail raw
#
# La <dir_sessione> deve contenere una cartella `photos/` con i JPG (0000.jpg…).
# Output: <dir_sessione>/oc/model_<detail>.usdz  + log di reconstruction.
#
# Requisiti sul Mac remoto: Xcode Command Line Tools (swiftc), Apple Silicon,
# ≥32 GB RAM per .raw senza downsampling automatico. SSH key già autorizzata.
set -euo pipefail

# ─── default ────────────────────────────────────────────────────────────────
SESSION=""
HOST=""
DETAIL="raw"                 # preview|reduced|medium|full|raw
ORDERING="unordered"         # unordered|sequential
SENSITIVITY="high"           # normal|high
REMOTE_ROOT="acro_oc"        # workdir sul Mac remoto (relativo alla home; niente ~ per non rompere il quoting SSH)
SSH_OPTS="-o StrictHostKeyChecking=accept-new"
DRY_RUN=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HPG_SRC="$SCRIPT_DIR/HelloPhotogrammetry.swift"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -32; exit "${1:-0}"; }

# ─── parse args ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)     SESSION="$2"; shift 2 ;;
    --host)        HOST="$2"; shift 2 ;;
    --detail)      DETAIL="$2"; shift 2 ;;
    --ordering)    ORDERING="$2"; shift 2 ;;
    --sensitivity) SENSITIVITY="$2"; shift 2 ;;
    --remote-root) REMOTE_ROOT="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "Argomento sconosciuto: $1" >&2; usage 2 ;;
  esac
done

[[ -z "$SESSION" ]] && { echo "ERRORE: --session mancante" >&2; usage 2; }
[[ -z "$HOST"    ]] && { echo "ERRORE: --host mancante" >&2; usage 2; }

SESSION="${SESSION/#\~/$HOME}"
PHOTOS="$SESSION/photos"
[[ -d "$PHOTOS" ]] || { echo "ERRORE: cartella foto non trovata: $PHOTOS" >&2; exit 1; }

NPHOTOS=$(find "$PHOTOS" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' \) | wc -l | tr -d ' ')
[[ "$NPHOTOS" -gt 0 ]] || { echo "ERRORE: nessuna immagine in $PHOTOS" >&2; exit 1; }

SESSION_NAME="$(basename "$SESSION")"
REMOTE_DIR="$REMOTE_ROOT/$SESSION_NAME"
OUT_LOCAL="$SESSION/oc"
OUT_USDZ="$OUT_LOCAL/model_${DETAIL}.usdz"
mkdir -p "$OUT_LOCAL"

echo "══════════════════════════════════════════════════════════════"
echo " Object Capture remoto"
echo "   sessione:  $SESSION_NAME  ($NPHOTOS immagini)"
echo "   host:      $HOST"
echo "   dettaglio: $DETAIL  ordering: $ORDERING  sensitivity: $SENSITIVITY"
echo "   remoto:    $REMOTE_DIR"
echo "   output:    $OUT_USDZ"
echo "══════════════════════════════════════════════════════════════"

run() { echo "+ $*"; [[ "$DRY_RUN" -eq 1 ]] || "$@"; }
rsh() { echo "+ ssh $HOST '$*'"; [[ "$DRY_RUN" -eq 1 ]] || ssh $SSH_OPTS "$HOST" "$*"; }

# ─── 0. preflight: connettività + swiftc sul remoto ─────────────────────────
echo "── preflight ──"
if [[ "$DRY_RUN" -eq 0 ]]; then
  ssh $SSH_OPTS "$HOST" 'command -v swiftc >/dev/null || { echo "swiftc mancante: installa Xcode Command Line Tools (xcode-select --install)"; exit 3; }'
  ARCH=$(ssh $SSH_OPTS "$HOST" 'uname -m')
  echo "  remoto arch: $ARCH"
  [[ "$ARCH" == "arm64" ]] || echo "  [ATTENZIONE] il remoto non è Apple Silicon: OC .raw sarà instabile/lento."
fi

# ─── 1. upload foto + sorgente OC ───────────────────────────────────────────
echo "── upload ($NPHOTOS immagini) ──"
rsh "mkdir -p '$REMOTE_DIR/photos'"
run rsync -az --info=progress2 -e "ssh $SSH_OPTS" "$PHOTOS/" "$HOST:$REMOTE_DIR/photos/"
run rsync -az -e "ssh $SSH_OPTS" "$HPG_SRC" "$HOST:$REMOTE_DIR/HelloPhotogrammetry.swift"

# ─── 2. compila hpg (idempotente) + esegui OC ───────────────────────────────
echo "── compila + esegui Object Capture (può richiedere 1–3h a .raw) ──"
rsh "cd '$REMOTE_DIR' && [ -x hpg -a hpg -nt HelloPhotogrammetry.swift ] || swiftc -O HelloPhotogrammetry.swift -o hpg"
rsh "cd '$REMOTE_DIR' && time ./hpg ./photos ./model_${DETAIL}.usdz $DETAIL $ORDERING $SENSITIVITY 2>&1 | tee oc_run.log"

# ─── 3. download usdz + pose + log ──────────────────────────────────────────
echo "── download risultato (mesh + pose) ──"
run rsync -az --info=progress2 -e "ssh $SSH_OPTS" "$HOST:$REMOTE_DIR/model_${DETAIL}.usdz" "$OUT_USDZ"
run rsync -az -e "ssh $SSH_OPTS" "$HOST:$REMOTE_DIR/oc_poses.json" "$OUT_LOCAL/oc_poses.json" || true
run rsync -az -e "ssh $SSH_OPTS" "$HOST:$REMOTE_DIR/oc_run.log" "$OUT_LOCAL/oc_run.log" || true

if [[ "$DRY_RUN" -eq 0 && -f "$OUT_USDZ" ]]; then
  SZ=$(du -h "$OUT_USDZ" | cut -f1)
  echo "══════════════════════════════════════════════════════════════"
  echo " ✅ Mesh scaricata: $OUT_USDZ ($SZ)"
  echo "    Prossimo stadio: usdz → OBJ/GLB + pose OC (Task #3)."
  echo "══════════════════════════════════════════════════════════════"
else
  echo "(dry-run: nessuna esecuzione reale)"
fi
