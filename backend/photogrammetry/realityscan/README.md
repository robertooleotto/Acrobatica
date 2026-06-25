# RealityScan / RealityCapture VM Pipeline

Dataset pilota: `1553ab3c`, Palazzo Adriatica completo, 215 foto.

## Cosa Serve

- VM Windows con GPU NVIDIA CUDA.
- Driver NVIDIA aggiornati.
- Disco locale veloce, idealmente NVMe.
- RealityScan / RealityCapture installato.
- Login Epic/licenza funzionante nella VM.
- Dataset copiato in `C:\photogrammetry\1553ab3c\photos`.

## File Da Copiare Sulla VM

Dal Mac:

- `/Users/liscio/Acrobatica/backend/data/fixtures/1553ab3c/photos/`
- `/Users/liscio/Acrobatica/backend/photogrammetry/realityscan/palazzo-adriatica-normal.rscmd`
- `/Users/liscio/Acrobatica/backend/photogrammetry/realityscan/run-realityscan-vm.ps1`

Struttura attesa su Windows:

```text
C:\photogrammetry\1553ab3c\
  photos\
    0000.jpg
    ...
    0214.jpg
  out\
  palazzo-adriatica-normal.rscmd
  run-realityscan-vm.ps1
  export-obj.xml
```

`export-obj.xml` va generato una volta dalla UI di RealityScan scegliendo export OBJ/textured mesh e salvando i parametri di export. La CLI usa quel file per sapere formato, texture, coordinate e opzioni.

## Run

Da PowerShell nella VM:

```powershell
cd C:\photogrammetry\1553ab3c
.\run-realityscan-vm.ps1
```

Se il path dell'eseguibile è diverso:

```powershell
.\run-realityscan-vm.ps1 -RealityScanExe "C:\Path\To\RealityScan.exe"
```

## Output Attesi

```text
C:\photogrammetry\1553ab3c\out\
  palazzo-adriatica.obj
  palazzo-adriatica.mtl
  texture files
  palazzo-adriatica.rsproj
```

## Note Operative

- Il primo run va fatto guardando la UI/log: se l'allineamento crea più componenti, bisogna verificare quanti frame sono entrati nel componente maggiore.
- Il comando usa `calculateNormalModel` per un primo benchmark. Se qualità/tempo sono buoni, faremo un secondo run high-detail.
- La semplificazione a 3M triangoli è una scelta da MVP: abbastanza grande per leggere la facciata, non ingestibile da scaricare.
- Per export PLY/point cloud potremmo aggiungere un secondo export dopo aver creato/salvato i parametri dalla UI.

