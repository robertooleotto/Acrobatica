# Photogrammetry API Pilot

Goal: compare two production paths for generating point clouds and textured meshes from the same facade photo sets.

## Candidates

1. Autodesk Reality Capture API
   - Cloud REST API.
   - Inputs: photos uploaded to a photoscene.
   - Outputs to request: OBJ textured mesh, RCM, and point cloud if available for the scene type.
   - Cost model: ReCap/Flex entitlement plus Reality Capture token usage.

2. RealityCapture / RealityScan on a GPU VM
   - Self-managed VM with NVIDIA CUDA GPU.
   - Inputs: local image folder copied to the VM.
   - Outputs to export: OBJ/FBX/PLY point cloud if supported by the command sequence, plus textures.
   - Cost model: RealityScan seat if applicable, plus VM runtime and storage.

## Baseline Datasets

Primary benchmark:

- `/Users/liscio/Acrobatica/backend/data/fixtures/1553ab3c`
  - Palazzo Adriatica completo
  - 215 photos
  - captured on 2026-06-01 around 17:48-17:54 Europe/Rome

Historical small sample:

- `origin/samples/palazzo-adriatica`: `IMG_2974.jpeg` through `IMG_2979.jpeg`

Other realistic ARKit facade sets:

- `/Users/liscio/Acrobatica/backend/data/fixtures/53f1b49d`
- `/Users/liscio/Acrobatica/backend/data/fixtures/f604436f`

## Comparison Criteria

- Processing succeeds without manual intervention.
- Number of aligned cameras/photos.
- Output availability: textured mesh, point cloud, orthophoto if supported.
- Visual quality on facade plane: holes, warping, texture blur, duplicated geometry.
- Runtime from upload/start to downloadable result.
- Effective cost per processed facade.
- Automation fit: API simplicity, retry behavior, logs, deterministic output paths.

## Autodesk Reality Capture API Steps

1. Create or use an Autodesk Platform Services app with Reality Capture API enabled.
2. Obtain APS OAuth credentials.
3. Create a photoscene with object/manual scene type for facade/object photos.
4. Upload images.
5. Start processing.
6. Poll progress.
7. Retrieve result links.
8. Download outputs and store them under `backend/data/photogrammetry-runs/autodesk/<dataset>/`.

## RealityCapture / RealityScan VM Steps

1. Provision a Windows GPU VM with NVIDIA CUDA support.
2. Install RealityScan / RealityCapture and sign in with the Epic account/license.
3. Copy the image set to the VM.
4. Run an `.rscmd` command file or CLI sequence:
   - import images
   - align
   - build model
   - texture
   - export mesh and point cloud
5. Copy outputs back to `backend/data/photogrammetry-runs/realityscan/<dataset>/`.

Local VM assets:

- `/Users/liscio/Acrobatica/backend/photogrammetry/realityscan/README.md`
- `/Users/liscio/Acrobatica/backend/photogrammetry/realityscan/palazzo-adriatica-normal.rscmd`
- `/Users/liscio/Acrobatica/backend/photogrammetry/realityscan/run-realityscan-vm.ps1`

## Local Preparation

Run this to prepare a reproducible input bundle and manifest:

```bash
cd /Users/liscio/Acrobatica/backend
./venv/bin/python scripts/prepare_photogrammetry_dataset.py 1553ab3c
```

## Needed Before Running

- Autodesk APS client ID / client secret with Reality Capture API access.
- Autodesk billing/Flex/ReCap entitlement enabled for Reality Capture processing.
- Choice of GPU VM provider and budget cap for the RealityCapture / RealityScan run.
- Epic account/license for RealityScan on the VM.
