# Object Capture su Mac cloud — mesh ad alta densità

Genera una mesh OC **molto più densa** dei 157k tri attuali, eseguendo Object
Capture a dettaglio `.full`/`.raw` su un Mac Apple Silicon potente affittato a ore.

La macchina locale è un MacBook Pro **Intel i7** → non adatta a `.full`/`.raw`
(poca VRAM, niente Neural Engine). Serve Apple Silicon con molta RAM.

---

## ⚠️ Vincolo: minimo 24h

La licenza macOS di Apple impone un **lease minimo di 24h** per i Mac in cloud.
Userai la macchina ~2h ma paghi la giornata. È economico (~15–35€).

## Quale Mac affittare

| Provider | Istanza | RAM | Note | Costo ~24h |
|---|---|---|---|---|
| **AWS EC2 Mac** | `mac2-m2pro.metal` | 32 GB | Dedicated host, min 24h. Setup più tecnico. | ~$22 |
| **Scaleway** (EU/Parigi) | Mac mini **M4 Pro** / M2-Pro | 24–32 GB | SSH pronto in minuti, fatturazione oraria (min 24h). Consigliato per l'Italia. | ~€10–18 |
| **MacStadium** | Mac Studio M2 Ultra | 64–192 GB | Più RAM (meglio per `.raw`), ma più enterprise/caro. | $$ |

**Per `.raw` su 327 foto** punta ad almeno **32 GB RAM**. Con meno RAM Object
Capture fa *automatic downsampling* (lo segnala nel log) e perdi densità.

Raccomandato: **Scaleway Mac mini M4 Pro 32 GB** (semplice, EU, economico) oppure
**Mac Studio 64 GB** se vuoi `.raw` senza compromessi.

---

## Procedura

### 1. Affitta e collegati
Crea l'istanza, prendi l'IP, abilita SSH. Esempio Scaleway/AWS:
```bash
ssh admin@<IP_DEL_MAC>      # AWS: ec2-user@<IP>, utente di default secondo provider
```

### 2. Prepara la macchina
```bash
# Xcode CLT (se non già presenti) — fornisce swiftc + RealityKit
xcode-select --install        # oppure: sudo xcodebuild -license accept
swiftc --version              # verifica
sysctl -n machdep.cpu.brand_string   # conferma chip Apple
```

### 3. Carica foto + tool (dal tuo Mac locale)
```bash
cd /Users/liscio/Acrobatica/backend/photogrammetry/objectcapture
MAC=admin@<IP_DEL_MAC>

ssh $MAC 'mkdir -p ~/oc/photos'
# 327 foto, 317 MB
scp -C /Users/liscio/Acrobatica/backend/data/fixtures/6cdcb8ff/photos/* $MAC:~/oc/photos/
scp HelloPhotogrammetry.swift $MAC:~/oc/
```
> Le foto bastano: Object Capture **non** usa il file `photos.json` (pose ARKit).
> Per il ponte metrico continuiamo a usare Umeyama OC→ARKit come ora.

### 4. Compila ed esegui (sul Mac affittato)
```bash
cd ~/oc
swiftc -O HelloPhotogrammetry.swift -o hpg

# mesh massima densità (geometria grezza, ideale per misurare rilievi)
./hpg ./photos ./model_raw.usdz raw unordered high

# in alternativa, levigata ma densa:
./hpg ./photos ./model_full.usdz full unordered high
```
Tempo atteso: pochi minuti (`.full`) / 10–30 min (`.raw`) su M2-Pro/M4.
Se compare `[warn] automatic downsampling` → RAM insufficiente, scendi a `.full`
o prendi una macchina con più RAM.

### 5. Riporta il risultato
```bash
# dal tuo Mac locale
scp $MAC:~/oc/model_raw.usdz \
    /Users/liscio/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/model_raw.usdz
```

### 6. Spegni l'istanza
**Termina/rilascia** l'host (paghi comunque le 24h, ma eviti rinnovi).

---

## Dopo il download: estrai OBJ + texture per il simulatore

Il `.usdz` contiene mesh + texture. Per usarlo nell'editor dei piani
(`plane_rebuild_prototype.html`, che carica le texture per nome fisso) usa lo
script pronto (gira sul Mac Intel locale, ModelI/O incluso):

```bash
cd /Users/liscio/Acrobatica/backend/photogrammetry/objectcapture
python3 usdz_to_editor.py \
    ~/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox/model_raw.usdz \
    ~/Documents/acrobatica_mesh/sess_6cdc/object_capture_nobbox \
    model_raw
```
Produce `model_raw.obj` + UV + `Texture_diffuseColor.png` / `_normal` /
`_occlusion` / `_roughness` (gli stessi nomi di `model_nobbox`) e riscrive l'MTL.

Poi in `plane_rebuild_prototype.html` cambia una riga:
```js
const MODEL = 'model_raw.obj';   // era 'model_nobbox.obj'
```
e ricarica `http://127.0.0.1:8781/plane_rebuild_prototype.html`. Ora clicchi i
piani sulla geometria densa.

## ⚠️ Scala metrica della nuova mesh

Una nuova run di Object Capture nasce in un **sistema di coordinate OC arbitrario
diverso** da quello di `model_nobbox`, e PhotogrammetrySession **non** esporta le
pose camera → il vecchio `oc_poses_nobbox.json` (ponte Umeyama OC→ARKit) non vale
per la mesh densa.

Soluzione prevista: **allineare la mesh densa a `model_nobbox.obj`** (ICP/Umeyama
mesh→mesh: stessa facciata, stesso oggetto) per ereditare la trasformazione
OC→ARKit metrica già calibrata. Da fare al ritorno della mesh, prima del bake.
Per il solo *clic dei piani* nell'editor la scala non blocca; serve per la
pipeline metrica successiva.
