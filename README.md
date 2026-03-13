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
- **Default & Advanced install modes** — simple one-click defaults or full control over every setting
- **Built-in update utility** — run `update` inside the container to upgrade Frigate
- **Clean MOTD** — shows hostname and IP on every login

---

## 🚀 Install

Run the following command in your **Proxmox host shell**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mati-l33t/frigate-proxmox/main/ct/frigate.sh)"
```

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

The web UI is available at `http://<container-ip>:5000`

---

## 🔄 Updating Frigate

Run this inside the container:

```bash
update
```

---

## 🖥️ Supported Hardware

| Hardware | Detector | Notes |
|---|---|---|
| Intel Sandy Bridge (2011+) | OpenVino | AVX required |
| Intel Xeon X5650 / Westmere | CPU/TFLite | No AVX — auto-detected |
| Any x86_64 CPU | CPU/TFLite | Universal fallback |
| Google Coral TPU | Edge TPU | Manual config required |

---

## 📋 Requirements

- Proxmox VE 7.x or 8.x
- At least 20GB disk space
- At least 4GB RAM
- Internet access from the Proxmox host

---

## 📄 License

MIT — see [LICENSE](LICENSE)

---

<div align="center">
  Made by <a href="https://proxmox-scripts.com">Mati-l33t</a>
</div>
