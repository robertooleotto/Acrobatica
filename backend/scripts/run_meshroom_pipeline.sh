#!/bin/bash
# Pipeline Meshroom pose-prior ARKit, OUTPUT IN SCALA METRICA REALE.
# Sessione esempio: 1553ab3c, 215 foto @1920px. Da girare sul pod RunPod (A100).
# Richiede sul pod: images_<sid>.zip, poses_by_orderindex.json, inject_poses.py,
#                   rescale_to_arkit.py  (tutti in /workspace).
set -e
cd /workspace
MR=/workspace/Meshroom-2023.3.0
AV=$MR/aliceVision/bin
DB=$MR/aliceVision/share/aliceVision/cameraSensors.db
TREE=$MR/aliceVision/share/aliceVision/vlfeat_K80L3.SIFT.tree
export LD_LIBRARY_PATH=$MR/aliceVision/lib:$MR/lib:$LD_LIBRARY_PATH
export ALICEVISION_ROOT=$MR/aliceVision
export ALICEVISION_SENSOR_DB=$DB
export ALICEVISION_VOCTREE=$TREE
# IMPORTANTE: il container vede i 256 core dell'host -> limita i thread o esplode (libgomp)
export OMP_NUM_THREADS=16
SID=${1:-1553}
O=/workspace/out_$SID; rm -rf $O; mkdir -p $O $O/features $O/matches $O/mvs $O/depthMap $O/depthMapFilter $O/texture
LOG=/workspace/timing_$SID.txt; : > $LOG
step(){ local name="$1"; shift; local t0=$(date +%s)
  echo ""; echo ">>>>> $name $(date '+%H:%M:%S')"
  "$@" > "$O/log_$name.txt" 2>&1 || { echo "FALLITO $name"; tail -30 "$O/log_$name.txt"; exit 1; }
  printf "%-24s %4d s\n" "$name" $(( $(date +%s)-t0 )) | tee -a $LOG; }
stepok(){ local name="$1"; shift; local t0=$(date +%s)
  echo ""; echo ">>>>> $name $(date '+%H:%M:%S')"
  if "$@" > "$O/log_$name.txt" 2>&1; then printf "%-24s %4d s\n" "$name" $(( $(date +%s)-t0 )) | tee -a $LOG
  else echo "WARN $name fallito (skip)"; tail -15 "$O/log_$name.txt"; fi; }

rm -rf imgs_$SID; mkdir -p imgs_$SID
unzip -oq /workspace/images_$SID.zip -d imgs_$SID
IMG=$(dirname $(find /workspace/imgs_$SID -name '*.jpg' | head -1))
echo "immagini in: $IMG ($(ls $IMG/*.jpg | wc -l) foto)"

T0=$(date +%s)
step cameraInit $AV/aliceVision_cameraInit --imageFolder $IMG --sensorDatabase $DB --defaultFieldOfView 45 --allowSingleView 1 --output $O/cameraInit.sfm
step injectPoses python3 /workspace/inject_poses.py $O/cameraInit.sfm /workspace/poses_by_orderindex.json $O/withPoses.sfm
step featureExtraction $AV/aliceVision_featureExtraction --input $O/withPoses.sfm --describerTypes dspsift --forceCpuExtraction 1 --maxThreads 16 --output $O/features
step imageMatching $AV/aliceVision_imageMatching --input $O/withPoses.sfm --featuresFolders $O/features --tree $TREE --method VocabularyTree --output $O/imageMatches.txt
step featureMatching $AV/aliceVision_featureMatching --input $O/withPoses.sfm --featuresFolders $O/features --imagePairsList $O/imageMatches.txt --describerTypes dspsift --output $O/matches
step incrementalSfM $AV/aliceVision_incrementalSfM --input $O/withPoses.sfm --featuresFolders $O/features --matchesFolders $O/matches --describerTypes dspsift --lockScenePreviouslyReconstructed 1 --lockAllIntrinsics 1 --minNumberOfObservationsForTriangulation 2 --output $O/sfm.abc --outputViewsAndPoses $O/sfm.sfm
step prepareDenseScene $AV/aliceVision_prepareDenseScene --input $O/sfm.abc --output $O/mvs
step depthMap $AV/aliceVision_depthMapEstimation --input $O/sfm.abc --imagesFolder $O/mvs --output $O/depthMap
step depthMapFilter $AV/aliceVision_depthMapFiltering --input $O/sfm.abc --depthMapsFolder $O/depthMap --output $O/depthMapFilter
step meshing $AV/aliceVision_meshing --input $O/sfm.abc --depthMapsFolder $O/depthMapFilter --maxInputPoints 50000000 --maxPoints 5000000 --output $O/densePointCloud.abc --outputMesh $O/mesh.obj

MESH_FINAL=$O/mesh.obj
stepok meshFiltering $AV/aliceVision_meshFiltering --inputMesh $O/mesh.obj --outputMesh $O/mesh_filt.obj --keepLargestMeshOnly True --smoothingIterations 5 --filterLargeTrianglesFactor 20
[ -f $O/mesh_filt.obj ] && MESH_FINAL=$O/mesh_filt.obj
stepok meshDecimate $AV/aliceVision_meshDecimate --input $MESH_FINAL --output $O/mesh_decim.obj --nbVertices 60000
[ -f $O/mesh_decim.obj ] && MESH_FINAL=$O/mesh_decim.obj
step texturing $AV/aliceVision_texturing --input $O/densePointCloud.abc --inputMesh $MESH_FINAL --imagesFolder $O/mvs --textureSide 8192 --downscale 2 --output $O/texture

# --- RESCALE in scala metrica reale (fix gauge: allinea SfM alle pose ARKit) ---
RS=/workspace/rescale_to_arkit.py
if [ -f "$RS" ]; then
  for f in mesh_filt mesh_decim; do
    [ -f $O/$f.obj ] && python3 $RS $O/withPoses.sfm $O/sfm.sfm $O/$f.obj $O/${f}_metric.obj
  done
  [ -f $O/texture/texturedMesh.obj ] && python3 $RS $O/withPoses.sfm $O/sfm.sfm $O/texture/texturedMesh.obj $O/texture/texturedMesh_metric.obj
  [ -f $O/cloud_and_poses.ply ] && python3 $RS $O/withPoses.sfm $O/sfm.sfm $O/cloud_and_poses.ply $O/cloud_and_poses_metric.ply
else
  echo "ATTENZIONE: $RS mancante -> output NON in scala reale (carica rescale_to_arkit.py sul pod)"
fi

echo ""; echo "===== TOTALE $(( ($(date +%s)-T0)/60 ))m ====="; cat $LOG
ls -la $O/*_metric.* $O/texture/*_metric.* 2>/dev/null
date "+DONE_$SID %H:%M:%S" > /workspace/done_$SID.txt
