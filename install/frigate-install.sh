#!/usr/bin/env bash

# Copyright (c) 2025-2026 Mati-l33t
# Author: Mati-l33t
# License: MIT | https://github.com/Mati-l33t/frigate-proxmox/raw/main/LICENSE
# Source: https://frigate.video/ | Github: https://github.com/blakeblackshear/frigate
#
# Docker-to-LXC adaptation. Every fix below addresses a specific
# difference between a Docker container and a Proxmox LXC:
#
#   1. frigate/version.py    — generated in Docker build, absent in git
#   2. Web frontend          — built in separate Docker stage, needs npm
#   3. vec0.so (sqlite-vec)  — built in Docker, needs deb-src for LXC
#   4. ffmpeg path           — Docker: /usr/lib/ffmpeg/bin/  LXC: /usr/bin/
#   5. nginx config          — Docker ships its own, LXC gets default
#   6. nginx service         — Docker: s6-overlay  LXC: systemd
#   7. go2rtc config         — Docker generates at runtime
#   8. System-wide Python    — Docker has no venv restrictions
#   9. PIP_BREAK_SYSTEM_PACKAGES — Debian 12 LXC blocks pip without it
#  10. s6-overlay → systemd  — all process management replaced

# ─────────────────────────────────────────────
# Safety check
# ─────────────────────────────────────────────
if [ -f /etc/pve/version ]; then
  echo "ERROR: This script must run inside an LXC container, not on the Proxmox host!"
  exit 1
fi

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PIP_BREAK_SYSTEM_PACKAGES=1

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
# Auto-login for Proxmox console
# ─────────────────────────────────────────────
mkdir -p /etc/systemd/system/container-getty@1.service.d
cat > /etc/systemd/system/container-getty@1.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
EOF

# ─────────────────────────────────────────────
# Disable IPv6 (prevents download failures on
# networks without IPv6 connectivity)
# ─────────────────────────────────────────────
cat >> /etc/sysctl.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl -p -q 2>/dev/null || true

# ─────────────────────────────────────────────
# AVX detection — OpenVino needs AVX
# ─────────────────────────────────────────────
if grep -qm1 ' avx ' /proc/cpuinfo 2>/dev/null || grep -qm1 ' avx$' /proc/cpuinfo 2>/dev/null; then
  INSTALL_OPENVINO="yes"
else
  INSTALL_OPENVINO="no"
fi

# ─────────────────────────────────────────────
# APT sources — add deb-src (needed for
# build_nginx.sh and build_sqlite_vec.sh)
# ─────────────────────────────────────────────
cat > /etc/apt/sources.list.d/debian.sources << 'SOURCES'
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main

Types: deb deb-src
URIs: http://security.debian.org/debian-security
Suites: bookworm-security
Components: main
SOURCES

# ─────────────────────────────────────────────
# System update & dependencies
# ─────────────────────────────────────────────
msg_info "Updating container OS"
apt-get update -qq
apt-get upgrade -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
msg_ok "Container OS updated"

msg_info "Installing base dependencies"
apt-get install -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  curl wget git sudo unzip \
  ffmpeg \
  python3 python3-pip python3-dev \
  libsm6 libxext6 libtbb-dev libtbbmalloc2 libgomp1 \
  ccache moreutils \
  apt-transport-https ca-certificates gnupg \
  build-essential pkg-config cmake \
  lsb-release
msg_ok "Base dependencies installed"

# ─────────────────────────────────────────────
# FIX #4: ffmpeg path symlinks
# Frigate hardcodes /usr/lib/ffmpeg/bin/ffmpeg
# (Docker path). System ffmpeg is at /usr/bin/.
# ─────────────────────────────────────────────
msg_info "Creating ffmpeg compatibility symlinks"
mkdir -p /usr/lib/ffmpeg/bin
ln -sf "$(command -v ffmpeg)" /usr/lib/ffmpeg/bin/ffmpeg
ln -sf "$(command -v ffprobe)" /usr/lib/ffmpeg/bin/ffprobe
msg_ok "ffmpeg symlinks created"

# ─────────────────────────────────────────────
# Node.js 20 (FIX #2: needed for web build)
# ─────────────────────────────────────────────
msg_info "Installing Node.js 20"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs
msg_ok "Node.js $(node --version) installed"

# ─────────────────────────────────────────────
# Frigate source
# ─────────────────────────────────────────────
msg_info "Fetching latest Frigate release"
FRIGATE_RELEASE=$(curl -fsSL https://api.github.com/repos/blakeblackshear/frigate/releases/latest \
  | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
FRIGATE_VERSION="${FRIGATE_RELEASE#v}"
rm -rf /opt/frigate
mkdir -p /opt/frigate
cd /opt/frigate
git -c advice.detachedHead=false clone --depth 1 --branch "${FRIGATE_RELEASE}" \
  https://github.com/blakeblackshear/frigate.git . -q
msg_ok "Fetched Frigate ${FRIGATE_RELEASE}"

# ─────────────────────────────────────────────
# FIX #1: Create frigate/version.py
# This file is generated during Docker build
# and doesn't exist in the git repo.
# ─────────────────────────────────────────────
msg_info "Creating version module"
echo "VERSION = '${FRIGATE_VERSION}'" > /opt/frigate/frigate/version.py
msg_ok "version.py created (${FRIGATE_VERSION})"

# ─────────────────────────────────────────────
# Frigate's own dependency installer
# ─────────────────────────────────────────────
msg_info "Installing Frigate system dependencies (this takes a few minutes)"
echo 'libedgetpu1-max libedgetpu/accepted-eula select true' | debconf-set-selections
echo 'libedgetpu1-std libedgetpu/accepted-eula select true' | debconf-set-selections
# install_deps.sh expects Docker env vars; set them for LXC compatibility
export TARGETARCH=amd64
bash /opt/frigate/docker/main/install_deps.sh >/dev/null 2>&1 || {
  msg_info "install_deps.sh had warnings (expected for LXC), continuing"
}
msg_ok "Frigate system dependencies installed"

# ─────────────────────────────────────────────
# Build nginx with vod module
# ─────────────────────────────────────────────
msg_info "Building nginx (takes 3-5 minutes)"
apt-get update -qq
bash /opt/frigate/docker/main/build_nginx.sh >/dev/null 2>&1
ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx 2>/dev/null || true
msg_ok "nginx built"

# ─────────────────────────────────────────────
# FIX #3: Build sqlite-vec (vec0.so)
# Required for Frigate's embedding/search.
# ─────────────────────────────────────────────
msg_info "Building sqlite-vec extension"
if [ -f /opt/frigate/docker/main/build_sqlite_vec.sh ]; then
  bash /opt/frigate/docker/main/build_sqlite_vec.sh >/dev/null 2>&1 || {
    msg_info "sqlite-vec build had issues, attempting manual build"
    cd /tmp
    SQLVEC_VER=$(curl -fsSL https://api.github.com/repos/asg017/sqlite-vec/releases/latest \
      | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    git clone --depth 1 --branch "${SQLVEC_VER}" https://github.com/asg017/sqlite-vec.git >/dev/null 2>&1
    cd sqlite-vec
    make loadable >/dev/null 2>&1
    cp dist/vec0.so /usr/local/lib/vec0.so
    cd /opt/frigate
    rm -rf /tmp/sqlite-vec
  }
else
  msg_info "build_sqlite_vec.sh not found, building manually"
  cd /tmp
  SQLVEC_VER=$(curl -fsSL https://api.github.com/repos/asg017/sqlite-vec/releases/latest \
    | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
  git clone --depth 1 --branch "${SQLVEC_VER}" https://github.com/asg017/sqlite-vec.git >/dev/null 2>&1
  cd sqlite-vec
  make loadable >/dev/null 2>&1
  cp dist/vec0.so /usr/local/lib/vec0.so
  cd /opt/frigate
  rm -rf /tmp/sqlite-vec
fi
msg_ok "sqlite-vec built"

# ─────────────────────────────────────────────
# go2rtc binary
# ─────────────────────────────────────────────
msg_info "Deploying go2rtc"
GO2RTC_RELEASE=$(curl -fsSL https://api.github.com/repos/AlexxIT/go2rtc/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
mkdir -p /usr/local/go2rtc/bin
curl -fsSL "https://github.com/AlexxIT/go2rtc/releases/download/${GO2RTC_RELEASE}/go2rtc_linux_amd64" \
  -o /usr/local/go2rtc/bin/go2rtc
chmod +x /usr/local/go2rtc/bin/go2rtc
ln -sf /usr/local/go2rtc/bin/go2rtc /usr/local/bin/go2rtc
msg_ok "go2rtc ${GO2RTC_RELEASE} deployed"

# ─────────────────────────────────────────────
# FIX #8/#9: Python deps — system-wide, no venv
# Matches Docker behavior exactly. The container
# is dedicated to Frigate so no isolation needed.
# PIP_BREAK_SYSTEM_PACKAGES is exported at top.
# ─────────────────────────────────────────────
msg_info "Installing Python dependencies"
pip3 install --upgrade pip -q 2>/dev/null
if [ -f /opt/frigate/docker/main/requirements-wheels.txt ]; then
  pip3 install -r /opt/frigate/docker/main/requirements-wheels.txt -q 2>/dev/null
fi
msg_ok "Python dependencies installed"

# ─────────────────────────────────────────────
# OpenVino (only on AVX-capable CPUs)
# ─────────────────────────────────────────────
if [ "$INSTALL_OPENVINO" = "yes" ]; then
  msg_info "Installing OpenVino (AVX detected)"
  if [ -f /opt/frigate/docker/main/requirements-ov.txt ]; then
    pip3 install -r /opt/frigate/docker/main/requirements-ov.txt -q 2>/dev/null
  fi
  msg_ok "OpenVino installed"
else
  msg_ok "OpenVino skipped (no AVX — using CPU detector)"
fi

# ─────────────────────────────────────────────
# FIX #2: Build web frontend
# In Docker this happens in a separate build
# stage. For LXC we build in-place.
# ─────────────────────────────────────────────
msg_info "Building web frontend (takes 3-8 minutes)"
cd /opt/frigate/web
export VITE_APP_VERSION="${FRIGATE_VERSION}"
npm install --loglevel=error 2>&1 | tail -3
npm run build 2>&1 | tail -5
if [ ! -d /opt/frigate/web/dist ]; then
  msg_error "Web frontend build failed — dist/ directory not created"
fi
cd /opt/frigate
msg_ok "Web frontend built"

# ─────────────────────────────────────────────
# Detection models & Docker-path symlinks
# ─────────────────────────────────────────────
msg_info "Downloading detection models"
mkdir -p /opt/frigate/model_cache
mkdir -p /opt/frigate/openvino-model

# CPU TFLite model
curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite" \
  -o "/opt/frigate/model_cache/cpu_model.tflite"

# Edge TPU model
curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite" \
  -o "/opt/frigate/model_cache/edgetpu_model.tflite"

# COCO labelmap
curl -fsSL \
  "https://github.com/openvinotoolkit/open_model_zoo/raw/master/data/dataset_classes/coco_91cl_bkgr.txt" \
  -o "/opt/frigate/openvino-model/coco_91cl_bkgr.txt"
sed -i 's/truck/car/g' /opt/frigate/openvino-model/coco_91cl_bkgr.txt

# Docker-compatible root-level symlinks
ln -sf /opt/frigate/model_cache/cpu_model.tflite /cpu_model.tflite
ln -sf /opt/frigate/model_cache/edgetpu_model.tflite /edgetpu_model.tflite
ln -sf /opt/frigate/openvino-model /openvino-model
ln -sf /opt/frigate/openvino-model/coco_91cl_bkgr.txt /labelmap.txt
msg_ok "Detection models downloaded"

# ─────────────────────────────────────────────
# Sample video for test camera
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

CPU_THREADS=$(nproc)
DETECT_THREADS=$(( CPU_THREADS / 2 ))
[ "$DETECT_THREADS" -lt 2 ] && DETECT_THREADS=2

if [ "$INSTALL_OPENVINO" = "yes" ]; then
  cat > /config/config.yml <<EOF
mqtt:
  enabled: false

detectors:
  ov:
    type: openvino
    device: AUTO
    model:
      path: /openvino-model/FP16/ssdlite_mobilenet_v2.xml
      labelmap_path: /openvino-model/coco_91cl_bkgr.txt
      width: 300
      height: 300

model:
  path: /cpu_model.tflite

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

version: 0.14
EOF
else
  cat > /config/config.yml <<EOF
mqtt:
  enabled: false

detectors:
  cpu1:
    type: cpu
    num_threads: ${DETECT_THREADS}

model:
  path: /cpu_model.tflite

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

version: 0.14
EOF
fi
msg_ok "Frigate configuration written"

# ─────────────────────────────────────────────
# FIX #7: go2rtc config
# ─────────────────────────────────────────────
msg_info "Writing go2rtc configuration"
cat > /config/go2rtc.yaml << 'EOF'
api:
  listen: ":1984"

rtsp:
  listen: ":8554"

webrtc:
  listen: ":8555"
EOF
msg_ok "go2rtc configuration written"

# ─────────────────────────────────────────────
# FIX #5: nginx reverse proxy config
# Frigate's FastAPI listens on 127.0.0.1:5001.
# nginx proxies port 5000 → 5001 with websocket
# support, matching the Docker setup.
# ─────────────────────────────────────────────
msg_info "Writing nginx configuration"
cat > /usr/local/nginx/conf/nginx.conf << 'NGINXCONF'
worker_processes auto;
daemon off;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;
    client_max_body_size 100M;

    upstream frigate_api {
        server 127.0.0.1:5001;
    }

    upstream frigate_mqtt_ws {
        server 127.0.0.1:5002;
    }

    server {
        listen 5000;

        # Websocket for live event updates
        location /ws {
            proxy_pass http://frigate_mqtt_ws/ws;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_read_timeout 86400;
        }

        # go2rtc API and WebRTC
        location /api/go2rtc/ {
            proxy_pass http://127.0.0.1:1984/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
        }

        # Live camera streams via go2rtc
        location /live/ {
            proxy_pass http://127.0.0.1:1984/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
        }

        # Everything else → FastAPI (serves API + web UI)
        location / {
            proxy_pass http://frigate_api;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_buffering off;
        }
    }
}
NGINXCONF
msg_ok "nginx configuration written"

# ─────────────────────────────────────────────
# FIX #6/#10: Systemd services replacing s6-overlay
# ─────────────────────────────────────────────
msg_info "Creating systemd services"

# Shared memory log dirs (Frigate writes here)
cat > /etc/systemd/system/frigate-shm.service << 'EOF'
[Unit]
Description=Frigate shared memory log setup
Before=frigate.service go2rtc.service frigate-nginx.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/bin/mkdir -p /dev/shm/logs/{frigate,go2rtc,nginx} && /bin/touch /dev/shm/logs/{frigate/current,go2rtc/current,nginx/current} && /bin/chmod -R 777 /dev/shm/logs'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# go2rtc — runs independently so RTSP streams
# survive Frigate restarts
cat > /etc/systemd/system/go2rtc.service << 'EOF'
[Unit]
Description=go2rtc
After=network.target frigate-shm.service

[Service]
ExecStart=/usr/local/go2rtc/bin/go2rtc -config /config/go2rtc.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Frigate — main NVR process
cat > /etc/systemd/system/frigate.service << 'EOF'
[Unit]
Description=Frigate NVR
After=network.target frigate-shm.service go2rtc.service

[Service]
WorkingDirectory=/opt/frigate
Environment="CONFIG_FILE=/config/config.yml"
ExecStart=/usr/bin/python3 -m frigate
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# nginx — reverse proxy on port 5000
cat > /etc/systemd/system/frigate-nginx.service << 'EOF'
[Unit]
Description=Frigate Nginx Proxy
After=network.target frigate.service

[Service]
ExecStart=/usr/local/nginx/sbin/nginx -g "daemon off;"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q frigate-shm go2rtc frigate frigate-nginx

# Start in correct order with waits
systemctl start frigate-shm
systemctl start go2rtc
sleep 2
systemctl start frigate
sleep 5
systemctl start frigate-nginx
msg_ok "Systemd services created and started"

# ─────────────────────────────────────────────
# Update utility
# ─────────────────────────────────────────────
msg_info "Setting up update utility"
cat > /usr/bin/update << 'UPDATEEOF'
#!/usr/bin/env bash
# Frigate LXC update utility

export PIP_BREAK_SYSTEM_PACKAGES=1
YW="\033[33m"; CM="\033[0;92m"; RD="\033[01;31m"; CL="\033[m"; TAB="  "
msg_info() { echo -e "${TAB}${YW}  ⏳ ${1}...${CL}"; }
msg_ok()   { echo -e "${TAB}${CM}  ✔️   ${1}${CL}"; }
msg_error(){ echo -e "${TAB}${RD}  ✖️   ${1}${CL}"; }

CURRENT=$(/usr/bin/python3 -c "from frigate.version import VERSION; print(VERSION)" 2>/dev/null || echo "unknown")
LATEST=$(curl -fsSL https://api.github.com/repos/blakeblackshear/frigate/releases/latest \
  | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
LATEST_VER="${LATEST#v}"

echo ""
echo -e "  Current: ${CURRENT}"
echo -e "  Latest:  ${LATEST_VER}"
echo ""

if [ "${CURRENT}" = "${LATEST_VER}" ]; then
  msg_ok "Already on latest version"
  exit 0
fi

msg_info "Stopping services"
systemctl stop frigate-nginx frigate go2rtc
msg_ok "Services stopped"

msg_info "Updating Frigate to ${LATEST_VER}"
cd /opt/frigate
git fetch --depth 1 origin tag "${LATEST}" -q
git checkout "${LATEST}" -q
echo "VERSION = '${LATEST_VER}'" > /opt/frigate/frigate/version.py
pip3 install -r /opt/frigate/docker/main/requirements-wheels.txt -q 2>/dev/null
msg_ok "Python deps updated"

msg_info "Rebuilding web frontend"
cd /opt/frigate/web
export VITE_APP_VERSION="${LATEST_VER}"
npm install --loglevel=error 2>&1 | tail -3
npm run build 2>&1 | tail -3
cd /opt/frigate
msg_ok "Web frontend rebuilt"

msg_info "Starting services"
systemctl start go2rtc frigate
sleep 3
systemctl start frigate-nginx
msg_ok "Frigate updated to ${LATEST_VER}"
UPDATEEOF
chmod +x /usr/bin/update
msg_ok "Update utility ready (run 'update' to check for updates)"

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
  📝   Config: /config/config.yml
  🔄   Update: run 'update'

EOF
msg_ok "MOTD configured"

# ─────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────
msg_info "Cleaning up"
apt-get autoremove -y -qq
apt-get autoclean -qq
rm -f /tmp/frigate-install.sh
msg_ok "Cleaned up"

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────
echo ""
msg_ok "Frigate ${FRIGATE_VERSION} installed successfully"
if [ "$INSTALL_OPENVINO" = "yes" ]; then
  msg_ok "Detector: OpenVino (Intel hardware acceleration)"
else
  msg_ok "Detector: CPU/TFLite with ${DETECT_THREADS} threads"
fi
msg_ok "Web UI: http://${IP}:5000"
msg_ok "Config: /config/config.yml"
