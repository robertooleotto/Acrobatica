# Acrobatica iOS

App iOS Swift+SwiftUI: cattura foto facciata con ARKit (tracking + pose sincronizzata), upload al backend Python.

## Build

```bash
cd ios
xcodegen generate            # rigenera Acrobatica.xcodeproj da project.yml
open Acrobatica.xcodeproj
# in Xcode: Cmd+R
```

## Backend

L'app punta di default a `http://localhost:8000`. Cambia `BackendAPIClient.baseURL` per puntare al VPS.
Per testare sull'iPhone collegato col cavo, sostituisci `localhost` con l'IP del Mac sulla LAN.

## Struttura

```
Acrobatica/
  AcrobaticaApp.swift           # @main entry
  Info.plist
  Models/                       # CapturedFacadePhoto, FacadeCaptureSession, ARSnapshot
  Capture/
    ARFacadeCaptureManager.swift   # ARKit session + captureHighResolutionFrame
  Networking/
    BackendAPIClient.swift         # URLSession verso il backend Python
  UI/
    ContentView.swift              # SwiftUI: AR preview + shutter + thumb strip
    ARPreviewView.swift            # UIViewRepresentable wrapper di ARView
    CaptureGuideOverlay.swift      # overlay con indicatori tracking/contatore
```

## Note

- Bundle ID: `com.liscio.acrobatica.facciate` (Personal Team UKMVCW2U67).
- iOS 16+ richiesto (`session.captureHighResolutionFrame`).
- NO LiDAR obbligatorio: ARKit funziona con world tracking standard.
