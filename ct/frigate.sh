#!/usr/bin/env bash

# Copyright (c) 2025-2026 Mati-l33t
# Author: Mati-l33t
# License: MIT | https://github.com/Mati-l33t/frigate-proxmox/raw/main/LICENSE
# Source: https://frigate.video/ | Github: https://github.com/blakeblackshear/frigate

set -euo pipefail

INSTALL_SCRIPT="https://raw.githubusercontent.com/Mati-l33t/frigate-proxmox/main/install/frigate-install.sh"

YW="\033[33m"
GN="\033[1;92m"
RD="\033[01;31m"
BL="\033[36m"
CM="\033[0;92m"
CL="\033[m"
BOLD="\033[1m"
TAB="  "

APP="Frigate"
NSAPP="frigate"
var_cpu="4"
var_ram="4096"
var_disk="20"
var_unprivileged="0"

msg_info()  { echo -e "${TAB}${YW}  ⏳ ${1}...${CL}"; }
msg_ok()    { echo -e "${TAB}${CM}  ✔️   ${1}${CL}"; }
msg_error() { echo -e "${TAB}${RD}  ✖️   ${1}${CL}"; }

header_info() {
  clear
  cat << 'EOF'
    ______     _             __     
   / ____/____(_)___ _____ _/ /____ 
  / /_  / ___/ / __ `/ __ `/ __/ _ \
 / __/ / /  / / /_/ / /_/ / /_/  __/
/_/   /_/  /_/\__, /\__,_/\__/\___/ 
             /____/                 
EOF
  echo -e "${TAB}${BOLD}${BL}Frigate NVR LXC Installer${CL}"
  echo -e "${TAB}${YW}Provided by: Mati-l33t | proxmox-scripts.com${CL}"
  echo -e "${TAB}${YW}GitHub: https://github.com/Mati-l33t/frigate-proxmox${CL}"
  echo ""
}

# ─────────────────────────────────────────────
# Storage
# ─────────────────────────────────────────────
select_storage() {
  local type="$1"
  local content="rootdir"
  [ "$type" = "template" ] && content="vztmpl"

  local names=()
  while IFS= read -r name; do
    names+=("$name" " ")
  done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 {print $1}')

  local count=$(( ${#names[@]} / 2 ))
  if [ "$count" -eq 0 ]; then
    msg_error "No suitable ${type} storage found"
    exit 1
  fi
  if [ "$count" -eq 1 ]; then
    echo "${names[0]}"
    return
  fi

  whiptail --backtitle "Frigate NVR Installer" \
    --title "$([ "$type" = "template" ] && echo "TEMPLATE STORAGE" || echo "CONTAINER STORAGE")" \
    --menu "\nWhere to store the ${type}?" 16 58 8 \
    "${names[@]}" \
    3>&1 1>&2 2>&3
}

# ─────────────────────────────────────────────
# Template
# ─────────────────────────────────────────────
get_template() {
  local storage="$1"
  local TEMPLATE_NAME="debian-12-standard_12.12-1_amd64.tar.zst"

  local existing
  existing=$(pveam list "$storage" 2>/dev/null | awk '{print $1}' | grep -F "$TEMPLATE_NAME" | head -1)
  if [ -n "$existing" ]; then
    echo "$existing"
    return
  fi

  msg_info "Downloading Debian 12 template"
  pveam update >/dev/null 2>&1
  if ! pveam download "$storage" "$TEMPLATE_NAME" >/dev/null 2>&1; then
    msg_error "Failed to download Debian 12 template"
    exit 1
  fi
  echo "${storage}:vztmpl/${TEMPLATE_NAME}"
}

# ─────────────────────────────────────────────
# Device passthrough detection
# ─────────────────────────────────────────────
detect_passthrough() {
  GPU_PASSTHROUGH="no"
  CORAL_USB_PASSTHROUGH="no"
  CORAL_PCIE_PASSTHROUGH="no"

  if [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    GPU_PASSTHROUGH="yes"
  fi

  if lsusb 2>/dev/null | grep -qE "1a6e:|18d1:9302"; then
    CORAL_USB_PASSTHROUGH="yes"
  fi

  if lspci 2>/dev/null | grep -qi "Global Unichip\|089a"; then
    CORAL_PCIE_PASSTHROUGH="yes"
  fi
}

apply_passthrough() {
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"

  if [ "$GPU_PASSTHROUGH" = "yes" ]; then
    for dev in /dev/dri/*; do
      local major minor
      major=$(stat -c '%t' "$dev" 2>/dev/null | xargs printf '%d')
      minor=$(stat -c '%T' "$dev" 2>/dev/null | xargs printf '%d')
      echo "lxc.cgroup2.devices.allow: c ${major}:${minor} rwm" >> "$conf"
      echo "lxc.mount.entry: ${dev} dev/dri/$(basename $dev) none bind,optional,create=file 0 0" >> "$conf"
    done
    local video_gid render_gid
    video_gid=$(getent group video 2>/dev/null | cut -d: -f3 || echo "44")
    render_gid=$(getent group render 2>/dev/null | cut -d: -f3 || echo "104")
    pct exec "$ctid" -- sh -c "groupadd -g ${video_gid} video 2>/dev/null || true" >/dev/null 2>&1
    pct exec "$ctid" -- sh -c "groupadd -g ${render_gid} render 2>/dev/null || true" >/dev/null 2>&1
    pct exec "$ctid" -- sh -c "usermod -aG video,render root 2>/dev/null || true" >/dev/null 2>&1
    msg_ok "GPU (/dev/dri) passthrough configured"
  fi

  if [ "$CORAL_USB_PASSTHROUGH" = "yes" ]; then
    while IFS= read -r line; do
      if echo "$line" | grep -qE "1a6e:|18d1:9302"; then
        local bus dev_path usb_dev
        bus=$(echo "$line" | awk '{print $2}')
        dev_path=$(echo "$line" | awk '{print $4}' | tr -d ':')
        usb_dev="/dev/bus/usb/${bus}/${dev_path}"
        if [ -e "$usb_dev" ]; then
          local major minor
          major=$(stat -c '%t' "$usb_dev" 2>/dev/null | xargs printf '%d')
          minor=$(stat -c '%T' "$usb_dev" 2>/dev/null | xargs printf '%d')
          echo "lxc.cgroup2.devices.allow: c ${major}:${minor} rwm" >> "$conf"
          echo "lxc.mount.entry: ${usb_dev} dev/bus/usb/${bus}/${dev_path} none bind,optional,create=file 0 0" >> "$conf"
        fi
      fi
    done < <(lsusb 2>/dev/null)
    msg_ok "Google Coral USB passthrough configured"
  fi

  if [ "$CORAL_PCIE_PASSTHROUGH" = "yes" ] && [ -e /dev/apex_0 ]; then
    local major minor
    major=$(stat -c '%t' /dev/apex_0 2>/dev/null | xargs printf '%d')
    minor=$(stat -c '%T' /dev/apex_0 2>/dev/null | xargs printf '%d')
    echo "lxc.cgroup2.devices.allow: c ${major}:${minor} rwm" >> "$conf"
    echo "lxc.mount.entry: /dev/apex_0 dev/apex_0 none bind,optional,create=file 0 0" >> "$conf"
    msg_ok "Google Coral PCIe passthrough configured"
  fi
}

# ─────────────────────────────────────────────
# Default settings
# ─────────────────────────────────────────────
default_settings() {
  CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
  HN="$NSAPP"
  DISK_SIZE="$var_disk"
  CORE_COUNT="$var_cpu"
  RAM_SIZE="$var_ram"
  BRG="vmbr0"
  NET="dhcp"
  GATE=""
  VLAN_TAG=""
  UNPRIVILEGED="$var_unprivileged"
  PW=""
  SSH="no"
  VERB="no"

  echo -e "${TAB}${BOLD}⚙️  Using Default Settings${CL}"
  echo -e "${TAB}🆔  Container ID: ${BL}${CTID}${CL}"
  echo -e "${TAB}🏠  Hostname: ${BL}${HN}${CL}"
  echo -e "${TAB}📦  Container Type: ${BL}Privileged${CL}"
  echo -e "${TAB}💾  Disk Size: ${BL}${DISK_SIZE}GB${CL}"
  echo -e "${TAB}🧠  CPU Cores: ${BL}${CORE_COUNT}${CL}"
  echo -e "${TAB}🛠️  RAM: ${BL}${RAM_SIZE}MiB${CL}"
  echo -e "${TAB}🌉  Bridge: ${BL}${BRG}${CL}"
  echo -e "${TAB}📡  IP: ${BL}DHCP${CL}"
  echo ""
}

# ─────────────────────────────────────────────
# Advanced settings
# ─────────────────────────────────────────────
advanced_settings() {
  local nextid
  nextid=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)

  CTID=$(whiptail --backtitle "Frigate NVR Installer" --title "CONTAINER ID" \
    --inputbox "\nSet Container ID:" 8 58 "$nextid" 3>&1 1>&2 2>&3) || exit

  HN=$(whiptail --backtitle "Frigate NVR Installer" --title "HOSTNAME" \
    --inputbox "\nSet Hostname:" 8 58 "$NSAPP" 3>&1 1>&2 2>&3) || exit
  HN=$(echo "${HN,,}" | tr -d ' ')

  DISK_SIZE=$(whiptail --backtitle "Frigate NVR Installer" --title "DISK SIZE" \
    --inputbox "\nSet Disk Size in GB:" 8 58 "$var_disk" 3>&1 1>&2 2>&3) || exit

  CORE_COUNT=$(whiptail --backtitle "Frigate NVR Installer" --title "CPU CORES" \
    --inputbox "\nAllocate CPU Cores:" 8 58 "$var_cpu" 3>&1 1>&2 2>&3) || exit

  RAM_SIZE=$(whiptail --backtitle "Frigate NVR Installer" --title "RAM" \
    --inputbox "\nAllocate RAM in MiB:" 8 58 "$var_ram" 3>&1 1>&2 2>&3) || exit

  local bridge_opts=()
  while IFS= read -r br; do
    bridge_opts+=("$br" " ")
  done < <(ip link show 2>/dev/null | awk -F': ' '/^[0-9]+: vmbr/{print $2}' | cut -d@ -f1)

  if [ "${#bridge_opts[@]}" -gt 2 ]; then
    BRG=$(whiptail --backtitle "Frigate NVR Installer" --title "NETWORK BRIDGE" \
      --menu "\nSelect network bridge:" 16 58 6 "${bridge_opts[@]}" 3>&1 1>&2 2>&3) || exit
  else
    BRG="vmbr0"
  fi

  local ip_choice
  ip_choice=$(whiptail --backtitle "Frigate NVR Installer" --title "IP CONFIGURATION" \
    --menu "\nSelect IP configuration:" 12 58 2 \
    "dhcp"   "Automatic (DHCP)" \
    "static" "Static IP" \
    3>&1 1>&2 2>&3) || exit

  if [ "$ip_choice" = "static" ]; then
    NET=$(whiptail --backtitle "Frigate NVR Installer" --title "STATIC IP" \
      --inputbox "\nEnter Static IP with CIDR:\n(e.g. 192.168.1.100/24)" 10 58 "" 3>&1 1>&2 2>&3) || exit
    local gw
    gw=$(whiptail --backtitle "Frigate NVR Installer" --title "GATEWAY" \
      --inputbox "\nEnter Gateway IP:\n(e.g. 192.168.1.1)" 10 58 "" 3>&1 1>&2 2>&3) || exit
    GATE=",gw=${gw}"
  else
    NET="dhcp"
    GATE=""
  fi

  local vlan_input
  vlan_input=$(whiptail --backtitle "Frigate NVR Installer" --title "VLAN TAG" \
    --inputbox "\nSet VLAN Tag (leave blank for none):" 8 58 "" 3>&1 1>&2 2>&3) || exit
  [ -n "$vlan_input" ] && VLAN_TAG=",tag=${vlan_input}" || VLAN_TAG=""

  local pw1 pw2
  pw1=$(whiptail --backtitle "Frigate NVR Installer" --title "ROOT PASSWORD" \
    --passwordbox "\nSet Root Password\n(leave blank for automatic login):" 10 58 3>&1 1>&2 2>&3) || exit
  if [ -n "$pw1" ]; then
    pw2=$(whiptail --backtitle "Frigate NVR Installer" --title "CONFIRM PASSWORD" \
      --passwordbox "\nConfirm Root Password:" 10 58 3>&1 1>&2 2>&3) || exit
    if [ "$pw1" != "$pw2" ]; then
      msg_error "Passwords do not match"
      exit 1
    fi
    PW="--password ${pw1}"
  else
    PW=""
  fi

  SSH=$(whiptail --backtitle "Frigate NVR Installer" --title "SSH ACCESS" \
    --radiolist "\nAllow root SSH access?" 10 58 2 \
    "no"  "No (recommended)" ON \
    "yes" "Yes" OFF \
    3>&1 1>&2 2>&3) || exit

  UNPRIVILEGED=$(whiptail --backtitle "Frigate NVR Installer" --title "CONTAINER TYPE" \
    --radiolist "\nSelect container type:\n\nFrigate requires Privileged for camera access." 12 62 2 \
    "0" "Privileged (recommended for Frigate)" ON \
    "1" "Unprivileged" OFF \
    3>&1 1>&2 2>&3) || exit

  VERB=$(whiptail --backtitle "Frigate NVR Installer" --title "VERBOSE MODE" \
    --radiolist "\nEnable verbose install output?" 10 58 2 \
    "no"  "No" ON \
    "yes" "Yes" OFF \
    3>&1 1>&2 2>&3) || exit

  echo -e "${TAB}${BOLD}🧩 Using Advanced Settings${CL}"
  echo -e "${TAB}🆔  Container ID: ${BL}${CTID}${CL}"
  echo -e "${TAB}🏠  Hostname: ${BL}${HN}${CL}"
  echo -e "${TAB}📦  Container Type: ${BL}$([ "$UNPRIVILEGED" = "1" ] && echo Unprivileged || echo Privileged)${CL}"
  echo -e "${TAB}💾  Disk Size: ${BL}${DISK_SIZE}GB${CL}"
  echo -e "${TAB}🧠  CPU Cores: ${BL}${CORE_COUNT}${CL}"
  echo -e "${TAB}🛠️  RAM: ${BL}${RAM_SIZE}MiB${CL}"
  echo -e "${TAB}🌉  Bridge: ${BL}${BRG}${CL}"
  echo -e "${TAB}📡  IP: ${BL}${NET}${CL}"
  echo -e "${TAB}🔑  SSH: ${BL}${SSH}${CL}"
  echo -e "${TAB}🔊  Verbose: ${BL}${VERB}${CL}"
  echo ""
}

# ─────────────────────────────────────────────
# Build container
# ─────────────────────────────────────────────
build_container() {
  msg_info "Selecting storage"
  TEMPLATE_STORAGE=$(select_storage template)
  CONTAINER_STORAGE=$(select_storage container)
  msg_ok "Storage selected"

  TEMPLATE=$(get_template "$TEMPLATE_STORAGE")
  msg_ok "Template ready"

  local tz
  tz=$(timedatectl show --value --property=Timezone 2>/dev/null || echo "UTC")
  [[ "$tz" == Etc/* ]] && tz="UTC"

  msg_info "Creating LXC container ${CTID}"
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$HN" \
    --cores "$CORE_COUNT" \
    --memory "$RAM_SIZE" \
    --rootfs "${CONTAINER_STORAGE}:${DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRG},ip=${NET}${GATE}${VLAN_TAG}" \
    --features "nesting=1" \
    --unprivileged "$UNPRIVILEGED" \
    --tags "frigate" \
    --onboot 1 \
    --timezone "$tz" \
    $PW \
    >/dev/null 2>&1
  msg_ok "LXC container ${CTID} created"

  msg_info "Detecting hardware for passthrough"
  detect_passthrough
  apply_passthrough "$CTID"
  if [ "$GPU_PASSTHROUGH" = "no" ] && [ "$CORAL_USB_PASSTHROUGH" = "no" ] && [ "$CORAL_PCIE_PASSTHROUGH" = "no" ]; then
    msg_ok "No passthrough devices detected"
  fi

  msg_info "Starting container"
  pct start "$CTID"
  sleep 8
  msg_ok "Container started"

  msg_info "Waiting for network"
  local tries=0
  while ! pct exec "$CTID" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; do
    sleep 3
    tries=$((tries + 1))
    if [ $tries -gt 15 ]; then
      msg_error "Network not reachable inside container"
      exit 1
    fi
  done
  msg_ok "Network connected"

  IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
}

# ─────────────────────────────────────────────
# Run install
# ─────────────────────────────────────────────
run_install() {
  msg_info "Downloading install script"
  curl -fsSL "$INSTALL_SCRIPT" -o /tmp/frigate-install.sh
  msg_ok "Install script downloaded"

  msg_info "Pushing install script into container"
  pct push "$CTID" /tmp/frigate-install.sh /tmp/frigate-install.sh --perms 0755
  rm -f /tmp/frigate-install.sh
  msg_ok "Install script ready"

  msg_info "Running Frigate installer inside container (this takes 15-30 minutes)"
  if [ "$VERB" = "yes" ]; then
    pct exec "$CTID" -- bash /tmp/frigate-install.sh
  else
    pct exec "$CTID" -- bash /tmp/frigate-install.sh 2>&1 | grep -E "✔️|✖️|⏳" || true
  fi

  sleep 5
  if pct exec "$CTID" -- systemctl is-active frigate >/dev/null 2>&1; then
    msg_ok "Frigate installer finished"
  else
    msg_error "Frigate service failed to start — enter container ${CTID} to debug"
    exit 1
  fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
header_info

if whiptail --backtitle "Frigate NVR Installer" --title "INSTALL MODE" \
  --yesno "\nWould you like to use Default Settings?\n\nDefaults:\n  CPU: 4 cores\n  RAM: 4096 MiB\n  Disk: 20GB\n  IP: DHCP\n  Type: Privileged" 16 58; then
  default_settings
else
  advanced_settings
fi

echo -e "${TAB}${BOLD}🚀 Creating Frigate LXC...${CL}"
build_container
run_install

# Get the auto-generated Frigate password
FRIGATE_PASS=$(pct exec "$CTID" -- grep -oP 'Password: \K\S+' /dev/shm/logs/frigate/current 2>/dev/null | tail -1 || true)

echo ""
msg_ok "Frigate installation complete!"
echo ""
echo -e "${TAB}${GN}🌐 Web UI: ${BL}http://${IP}:8971${CL}"
echo -e "${TAB}${GN}🔑 Login: ${BL}admin${CL} / ${BL}${FRIGATE_PASS:-check logs}${CL}"
echo -e "${TAB}${YW}🔓 Internal (no auth): ${BL}http://${IP}:5000${CL}"
echo -e "${TAB}${YW}📝 Config: /config/config.yml${CL}"
echo -e "${TAB}${YW}🔄 Update: run 'update' inside container${CL}"
