# 🎥 Frigate NVR — Proxmox LXC Installer

A standalone Proxmox VE script that installs [Frigate NVR](https://frigate.video/) as a native LXC container — no Docker required.

> 🌐 **Website:** [proxmox-scripts.com](https://proxmox-scripts.com/)  
> 🐙 **GitHub:** [github.com/Mati-l33t/frigate-proxmox](https://github.com/Mati-l33t/frigate-proxmox)

---

## ✨ Features

- **No Docker** — Frigate runs natively as a systemd service inside an LXC container
- **AVX auto-detection** — automatically selects the correct object detector based on your CPU
  - CPUs **with AVX** (Intel Sandy Bridge 2011+): OpenVino hardware-accelerated detector
  - CPUs **without AVX** (e.g. Xeon X5650, older Westmere): CPU/TFLite detector — no crashes
- **Automatic device passthrough** — detects and configures GPU and Coral TPU automatically
- **Dual-port access** — authenticated web UI on port 8971, unauthenticated internal access on port 5000
- **Default & Advanced install modes** — simple one-click defaults or full control over every setting
- **Built-in update utility** — run `update` inside the container to upgrade Frigate
- **Clean MOTD** — shows hostname, IP, and access URLs on every login

---

## 🚀 Install

Run the following command in your **Proxmox host shell**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mati-l33t/frigate-proxmox/main/ct/frigate.sh)"
```

The install takes 15–30 minutes depending on your hardware. At the end, the script will display:

- Web UI URL
- Default admin username and password

---

## ⚙️ Default Settings

| Setting | Value |
|---|---|
| OS | Debian 12 |
| CPU Cores | 4 |
| RAM | 4096 MiB |
| Disk | 20 GB |
| Container Type | Privileged |
| Network | DHCP |

---

## 🧩 Advanced Settings

When choosing **Advanced**, you can configure:

- Container ID
- Hostname
- Disk size
- CPU cores
- RAM
- Network bridge
- Static IP or DHCP
- VLAN tag
- Root password
- SSH access
- Privileged or Unprivileged container
- Verbose install output

---

## 🔐 Authentication

| Port | Access | Description |
|---|---|---|
| **8971** | Authenticated | Main web UI with login — use this for daily access |
| **5000** | Unauthenticated | Internal access for Home Assistant and other integrations |

Default admin credentials are printed at the end of installation. If you missed them:

```bash
pct enter <CTID>
grep Password /dev/shm/logs/frigate/current
```

You can manage users and change passwords in the web UI under **Settings > Users**.

---

## 🔌 Automatic Device Passthrough

The installer automatically detects and configures hardware passthrough before the container starts — no manual configuration needed.

| Device | Detection Method | Notes |
|---|---|---|
| Intel/AMD GPU | `/dev/dri` present on host | Enables VAAPI hardware video decoding |
| Google Coral USB | `lsusb` vendor ID scan | Fast hardware object detection |
| Google Coral PCIe | `lspci` device scan | Fast hardware object detection |

If no supported devices are detected, nothing is added and the install continues normally.

---

## 📷 Adding Cameras

After install, edit the config file inside the container:

```bash
pct enter <CTID>
nano /config/config.yml
```

Replace the test camera with your own RTSP streams:

```yaml
cameras:
  front_door:
    ffmpeg:
      inputs:
        - path: rtsp://user:password@camera_ip:554/stream
          roles:
            - detect
            - record
    detect:
      width: 1280
      height: 720
      fps: 5
```

Then restart Frigate:

```bash
systemctl restart frigate
```

The web UI is available at `http://<container-ip>:8971`

---

## 🔄 Updating Frigate

Run this inside the container:

```bash
update
```

This will pull the latest Frigate release, update Python dependencies, rebuild the web frontend, and restart all services.

---

## 📂 File Locations

| Path | Description |
|---|---|
| `/config/config.yml` | Frigate configuration |
| `/config/go2rtc.yaml` | go2rtc configuration |
| `/media/frigate` | Recordings and clips |
| `/dev/shm/logs/frigate/current` | Frigate logs |
| `/dev/shm/logs/go2rtc/current` | go2rtc logs |
| `/dev/shm/logs/nginx/current` | Nginx logs |
| `/opt/frigate` | Frigate installation directory |

---

## 🖥️ Supported Hardware

| Hardware | Detector | Notes |
|---|---|---|
| Intel Sandy Bridge (2011+) | OpenVino | AVX required |
| Intel Xeon X5650 / Westmere | CPU/TFLite | No AVX — auto-detected |
| Any x86_64 CPU | CPU/TFLite | Universal fallback |
| Google Coral TPU | Edge TPU | Auto passthrough |
| Intel/AMD iGPU | VAAPI | Auto passthrough via /dev/dri |

---

## 📋 Requirements

- Proxmox VE 8.x (tested on 8.4.14)
- At least 20 GB disk space
- At least 4 GB RAM
- Internet access from the Proxmox host

---
