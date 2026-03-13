#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Authors: MickLesk (CanbiZ) | Co-Author: remz1337 | Co-Author: Mati-l33t
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/ | Github: https://github.com/blakeblackshear/frigate

# This script runs after the community-scripts base install.
# It fixes the known issues that caused the script to be removed:
#   - Missing labelmap at /openvino-model/coco_91cl_bkgr.txt
#   - Missing cpu_model.tflite symlink at /cpu_model.tflite
#   - Wrong detector in config.yml (OpenVino on non-AVX CPUs)
#   - Empty cameras section causing config migration crash

# Auto-detect AVX — LXC containers share host CPU flags via /proc/cpuinfo
if grep -qm1 'avx' /proc/cpuinfo; then
  INSTALL_OPENVINO="yes"
else
  INSTALL_OPENVINO="no"
fi

# ─────────────────────────────────────────────
# Download missing model files
# ─────────────────────────────────────────────

mkdir -p /opt/frigate/model_cache
mkdir -p /openvino-model

curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite" \
  -o "/opt/frigate/model_cache/cpu_model.tflite"

curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite" \
  -o "/opt/frigate/model_cache/edgetpu_model.tflite"

curl -fsSL \
  "https://github.com/openvinotoolkit/open_model_zoo/raw/master/data/dataset_classes/coco_91cl_bkgr.txt" \
  -o "/openvino-model/coco_91cl_bkgr.txt"

sed -i 's/truck/car/g' /openvino-model/coco_91cl_bkgr.txt

ln -sf /opt/frigate/model_cache/cpu_model.tflite /cpu_model.tflite
ln -sf /opt/frigate/model_cache/edgetpu_model.tflite /edgetpu_model.tflite

# ─────────────────────────────────────────────
# Write correct config.yml
# ─────────────────────────────────────────────

if [ "$INSTALL_OPENVINO" = "yes" ]; then
  DETECTOR_BLOCK='detectors:
  ov:
    type: openvino
    device: AUTO
    model:
      path: /openvino-model/FP16/ssdlite_mobilenet_v2.xml
      labelmap_path: /openvino-model/coco_91cl_bkgr.txt
      width: 300
      height: 300'
else
  CPU_THREADS=$(nproc)
  DETECT_THREADS=$(( CPU_THREADS / 2 ))
  [ "$DETECT_THREADS" -lt 2 ] && DETECT_THREADS=2
  DETECTOR_BLOCK="detectors:
  cpu1:
    type: cpu
    num_threads: ${DETECT_THREADS}"
fi

mkdir -p /config
cat > /config/config.yml <<EOF
mqtt:
  enabled: false

${DETECTOR_BLOCK}

cameras:
  test:
    ffmpeg:
      inputs:
        - path: /media/frigate/person-bicycle-car-detection.mp4
          input_args: -re -stream_loop -1 -fflags +genpts
          roles:
            - detect
    detect:
      width: 1920
      height: 1080
      fps: 5

record:
  enabled: false

snapshots:
  enabled: false
EOF

# ─────────────────────────────────────────────
# Restart Frigate with correct config
# ─────────────────────────────────────────────

systemctl restart frigate
