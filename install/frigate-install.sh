#!/usr/bin/env bash

# Copyright (c) 2025-2026 Mati-l33t
# Author: Mati-l33t
# License: MIT | https://github.com/Mati-l33t/frigate-proxmox/raw/main/LICENSE
# Source: https://frigate.video/ | Github: https://github.com/blakeblackshear/frigate

# ─────────────────────────────────────────────
# Safety check — refuse to run on Proxmox host
# ─────────────────────────────────────────────
if [ -f /etc/pve/version ]; then
  echo "ERROR: This script must run inside an LXC container, not on the Proxmox host!"
  exit 1
fi

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

YW="\033[33m"
GN="\033[1;92m"
RD="\033[01;31m"
CM="\033[0;92m"
CL="\033[m"
TAB="  "

msg_info()  { echo -e "${TAB}${YW}  ⏳ ${1}...${CL}"; }
msg_ok()    { echo -e "${TAB}${CM}  ✔️   ${1}${CL}"; }
msg_error() { echo -e "${TAB}${RD}  ✖️   ${1}${CL}"; exit 1; }

# ─────────────────────────────────────────────
# Auto-login
# ─────────────────────────────────────────────
mkdir -p /etc/systemd/system/container-getty@1.service.d
cat > /etc/systemd/system/container-getty@1.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
EOF

# ─────────────────────────────────────────────
# Disable IPv6
# ─────────────────────────────────────────────
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p -q 2>/dev/null || true

# ─────────────────────────────────────────────
# AVX detection
# ─────────────────────────────────────────────
if grep -qm1 'avx' /proc/cpuinfo; then
  INSTALL_OPENVINO="yes"
else
  INSTALL_OPENVINO="no"
fi

# ─────────────────────────────────────────────
# System update & dependencies
# ─────────────────────────────────────────────
msg_info "Updating container OS"
apt-get update -qq
apt-get upgrade -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
msg_ok "Container OS updated"

msg_info "Installing dependencies"
apt-get install -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  curl wget git sudo unzip \
  ffmpeg \
  python3 python3-pip python3-venv \
  libsm6 libxext6 libtbb-dev libtbbmalloc2 libgomp1 \
  ccache moreutils \
  apt-transport-https ca-certificates \
  build-essential pkg-config
msg_ok "Dependencies installed"

# ─────────────────────────────────────────────
# Frigate source
# ─────────────────────────────────────────────
msg_info "Fetching latest Frigate release"
FRIGATE_RELEASE=$(curl -fsSL https://api.github.com/repos/blakeblackshear/frigate/releases/latest \
  | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
rm -rf /opt/frigate
mkdir -p /opt/frigate
cd /opt/frigate
git -c advice.detachedHead=false clone --depth 1 --branch "${FRIGATE_RELEASE}" \
  https://github.com/blakeblackshear/frigate.git . -q
msg_ok "Fetched Frigate ${FRIGATE_RELEASE}"

# ─────────────────────────────────────────────
# Frigate's own dependency installer
# ─────────────────────────────────────────────
msg_info "Installing Frigate system dependencies"
DEBIAN_FRONTEND=noninteractive TARGETARCH=amd64 bash /opt/frigate/docker/main/install_deps.sh >/dev/null 2>&1
msg_ok "Frigate system dependencies installed"

# ─────────────────────────────────────────────
# Build nginx
# ─────────────────────────────────────────────
msg_info "Building nginx (this will take a while)"
bash /opt/frigate/docker/main/build_nginx.sh >/dev/null 2>&1
ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx 2>/dev/null || true
sed -e '/s6-notifyoncheck/ s/^#*/#/' \
  -i /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/nginx/run
msg_ok "nginx built"

# ─────────────────────────────────────────────
# go2rtc
# ─────────────────────────────────────────────
msg_info "Deploying go2rtc"
GO2RTC_RELEASE=$(curl -fsSL https://api.github.com/repos/AlexxIT/go2rtc/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
mkdir -p /usr/local/go2rtc
curl -fsSL "https://github.com/AlexxIT/go2rtc/releases/download/${GO2RTC_RELEASE}/go2rtc_linux_amd64" \
  -o /usr/local/go2rtc/go2rtc
chmod +x /usr/local/go2rtc/go2rtc
ln -sf /usr/local/go2rtc/go2rtc /usr/local/bin/go2rtc
msg_ok "go2rtc ${GO2RTC_RELEASE} deployed"

# ─────────────────────────────────────────────
# Python environment
# ─────────────────────────────────────────────
msg_info "Setting up Python environment"
python3 -m venv /opt/frigate/venv
source /opt/frigate/venv/bin/activate
pip install --upgrade pip -q
pip install -r /opt/frigate/docker/main/requirements-wheels.txt -q
msg_ok "Python environment ready"

# ─────────────────────────────────────────────
# OpenVino (only on AVX-capable CPUs)
# ─────────────────────────────────────────────
if [ "$INSTALL_OPENVINO" = "yes" ]; then
  msg_info "Installing OpenVino (AVX detected)"
  pip install -r /opt/frigate/docker/main/requirements-ov.txt -q
  mkdir -p /opt/frigate/openvino-model
  /usr/local/bin/omz_converter \
    --name ssdlite_mobilenet_v2 \
    --precision FP16 \
    --mo /usr/local/bin/mo \
    --output_dir /opt/frigate/openvino-model \
    >/dev/null 2>&1
  msg_ok "OpenVino installed"
else
  msg_info "Skipping OpenVino (no AVX on this CPU)"
  msg_ok "OpenVino skipped"
fi

# ─────────────────────────────────────────────
# Detection models
# ─────────────────────────────────────────────
msg_info "Downloading detection models"
mkdir -p /opt/frigate/model_cache
mkdir -p /opt/frigate/openvino-model

curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite" \
  -o "/opt/frigate/model_cache/cpu_model.tflite"

curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite" \
  -o "/opt/frigate/model_cache/edgetpu_model.tflite"

curl -fsSL \
  "https://github.com/openvinotoolkit/open_model_zoo/raw/master/data/dataset_classes/coco_91cl_bkgr.txt" \
  -o "/opt/frigate/openvino-model/coco_91cl_bkgr.txt"

sed -i 's/truck/car/g' /opt/frigate/openvino-model/coco_91cl_bkgr.txt
ln -sf /opt/frigate/model_cache/cpu_model.tflite /cpu_model.tflite
ln -sf /opt/frigate/model_cache/edgetpu_model.tflite /edgetpu_model.tflite
ln -sf /opt/frigate/openvino-model /openvino-model
msg_ok "Detection models downloaded"

# ─────────────────────────────────────────────
# Sample video
# ─────────────────────────────────────────────
msg_info "Downloading sample detection video"
mkdir -p /media/frigate
curl -fsSL \
  "https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4" \
  -o "/media/frigate/person-bicycle-car-detection.mp4"
msg_ok "Sample video downloaded"

# ─────────────────────────────────────────────
# Frigate config.yml
# ─────────────────────────────────────────────
msg_info "Writing Frigate configuration"
mkdir -p /config

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
msg_ok "Frigate configuration written"

# ─────────────────────────────────────────────
# Systemd services
# ─────────────────────────────────────────────
msg_info "Creating systemd services"

cat > /etc/systemd/system/frigate-shm.service <<EOF
[Unit]
Description=Frigate shared memory log setup
Before=frigate.service go2rtc.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/bin/mkdir -p /dev/shm/logs/{frigate,go2rtc,nginx} && /bin/touch /dev/shm/logs/{frigate/current,go2rtc/current,nginx/current} && /bin/chmod -R 777 /dev/shm/logs'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/go2rtc.service <<EOF
[Unit]
Description=go2rtc
After=network.target frigate-shm.service

[Service]
WorkingDirectory=/usr/local/go2rtc
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/go2rtc/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/frigate.service <<EOF
[Unit]
Description=Frigate NVR
After=network.target frigate-shm.service go2rtc.service

[Service]
WorkingDirectory=/opt/frigate
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q frigate-shm go2rtc frigate
systemctl start frigate-shm go2rtc frigate
msg_ok "Systemd services created and started"

# ─────────────────────────────────────────────
# Update utility
# ─────────────────────────────────────────────
msg_info "Setting up update utility"
cat > /usr/bin/update << 'EOF'
#!/usr/bin/env bash
# Copyright (c) 2025-2026 Mati-l33t
# License: MIT | https://github.com/Mati-l33t/frigate-proxmox/raw/main/LICENSE

YW="\033[33m"; CM="\033[0;92m"; CL="\033[m"; TAB="  "
msg_info() { echo -e "${TAB}${YW}  ⏳ ${1}...${CL}"; }
msg_ok()   { echo -e "${TAB}${CM}  ✔️   ${1}${CL}"; }

msg_info "Stopping Frigate"
systemctl stop frigate go2rtc
msg_ok "Frigate stopped"
msg_info "Updating Frigate"
RELEASE=$(curl -fsSL https://api.github.com/repos/blakeblackshear/frigate/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
cd /opt/frigate
git fetch --depth 1 --tags -q
git checkout "${RELEASE}" -q
source /opt/frigate/venv/bin/activate
pip install --upgrade pip -q
pip install -r /opt/frigate/docker/main/requirements-wheels.txt -q
msg_ok "Frigate updated to ${RELEASE}"
msg_info "Starting Frigate"
systemctl start go2rtc frigate
msg_ok "Frigate started"
EOF
chmod +x /usr/bin/update
msg_ok "Update utility ready"

# ─────────────────────────────────────────────
# MOTD
# ─────────────────────────────────────────────
msg_info "Setting up MOTD"
IP=$(hostname -I | awk '{print $1}')
cat > /etc/motd << EOF

  Frigate NVR LXC Container
  🌐   Provided by: Mati-l33t | proxmox-scripts.com
  🐙   GitHub: https://github.com/Mati-l33t/frigate-proxmox
  🖥️   OS: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
  🏠   Hostname: $(hostname)
  💡   IP Address: ${IP}

EOF
msg_ok "MOTD configured"

# ─────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────
msg_info "Cleaning up"
apt-get autoremove -y -qq
apt-get autoclean -qq
msg_ok "Cleaned up"

echo ""
msg_ok "Frigate ${FRIGATE_RELEASE} installed successfully"
if [ "$INSTALL_OPENVINO" = "yes" ]; then
  msg_ok "Detector: OpenVino (Intel hardware acceleration)"
else
  msg_ok "Detector: CPU/TFLite with ${DETECT_THREADS} threads"
fi
msg_ok "Web UI: http://${IP}:5000"
msg_ok "Config: /config/config.yml"
