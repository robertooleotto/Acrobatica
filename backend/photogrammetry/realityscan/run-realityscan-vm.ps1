param(
  [string]$DatasetRoot = "C:\photogrammetry\1553ab3c",
  [string]$RealityScanExe = "C:\Program Files\Epic Games\RealityScan\RealityScan.exe"
)

$ErrorActionPreference = "Stop"

$Photos = Join-Path $DatasetRoot "photos"
$Out = Join-Path $DatasetRoot "out"
$Cmd = Join-Path $DatasetRoot "palazzo-adriatica-normal.rscmd"

New-Item -ItemType Directory -Force -Path $Out | Out-Null

Write-Host "RealityScan exe: $RealityScanExe"
Write-Host "Dataset:         $DatasetRoot"
Write-Host "Photos:          $Photos"
Write-Host "Output:          $Out"
Write-Host "Command file:    $Cmd"

if (!(Test-Path $RealityScanExe)) { throw "RealityScan.exe non trovato: $RealityScanExe" }
if (!(Test-Path $Photos)) { throw "Cartella foto non trovata: $Photos" }
if (!(Test-Path $Cmd)) { throw "Command file non trovato: $Cmd" }

& $RealityScanExe -execRSCMD $Cmd

Write-Host "Done. Controlla output in $Out"

