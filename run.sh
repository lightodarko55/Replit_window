#!/usr/bin/env bash
set -e

# =========================
# One-time cleanup
# =========================
if [ ! -f .cleanup_done ]; then
  echo "Performing first-time setup cleanup..."
  rm -rf .gradle .emu || true
  touch .cleanup_done
fi

# =========================
# Paths (Mapped /data to your local workspace)
# =========================
DATA_DIR="$PWD/data"
RAW_DISK="$DATA_DIR/disk.qcow2"
WIN_ISO="$DATA_DIR/automic11.iso"
VIRTIO_ISO="$DATA_DIR/virtio-win.iso"
NOVNC_DIR="$PWD/noVNC"

OVMF_DIR="$DATA_DIR/ovmf"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"
OVMF_VARS="$OVMF_DIR/OVMF_VARS.fd"

mkdir -p "$DATA_DIR" "$OVMF_DIR"

# =========================
# Download OVMF firmware if missing
# =========================
if [ ! -f "$OVMF_CODE" ]; then
  echo "Downloading OVMF_CODE.fd..."
  wget -O "$OVMF_CODE" https://qemu.weilnetz.de/test/ovmf/usr/share/OVMF/OVMF_CODE.fd
else
  echo "OVMF_CODE.fd already exists, skipping download."
fi

if [ ! -f "$OVMF_VARS" ]; then
  echo "Downloading OVMF_VARS.fd..."
  wget -O "$OVMF_VARS" https://qemu.weilnetz.de/test/ovmf/usr/share/OVMF/OVMF_VARS.fd
else
  echo "OVMF_VARS.fd already exists, skipping download."
fi

# =========================
# Download Windows ISO if missing
# =========================
if [ ! -f "$WIN_ISO" ]; then
  echo "Downloading Windows ISO..."
  wget -O "$WIN_ISO" https://archive.org/download/windows-10-lite-edition-19h2-x64/Windows%2010%20Lite%20Edition%2019H2%20x64.iso
else
  echo "Windows ISO already exists, skipping download."
fi

# =========================
# Download VirtIO drivers ISO if missing
# =========================
if [ ! -f "$VIRTIO_ISO" ]; then
  echo "Downloading VirtIO drivers ISO..."
  wget -O "$VIRTIO_ISO" https://github.com/kmille36/idx-windows-gui/releases/download/1.0/virtio-win-0.1.271.iso
else
  echo "VirtIO ISO already exists, skipping download."
fi

# =========================
# Clone noVNC if missing
# =========================
if [ ! -d "$NOVNC_DIR/.git" ]; then
  echo "Cloning noVNC..."
  mkdir -p "$NOVNC_DIR"
  git clone https://github.com/novnc/noVNC.git "$NOVNC_DIR"
else
  echo "noVNC already exists, skipping clone."
fi

# =========================
# [YOUR CODE] Create disk image if not exists
# =========================
if [ ! -f "$RAW_DISK" ]; then
  echo "💽 Creating 100GB virtual disk..."
  qemu-img create -f qcow2 "$RAW_DISK" 100G
fi

# [YOUR CODE] Windows-specific boot parameters
BOOT_ORDER="-boot order=c,menu=on"
if [ ! -s "$RAW_DISK" ] || [ $(stat -c%s "$RAW_DISK") -lt 1048576 ]; then
  echo "🚀 First boot - installing Windows from ISO"
  BOOT_ORDER="-boot order=d,menu=on"
fi

# =========================
# KVM Check & Hardware Config
# =========================
if [ -e /dev/kvm ]; then
  echo "🚀 KVM hardware acceleration detected!"
  CPU_FLAGS="-enable-kvm -cpu host,+topoext,hv_relaxed,hv_spinlocks=0x1fff,hv-passthrough,+pae,+nx,kvm=on,+svm"
else
  echo "⚠️ KVM acceleration not found. Running with slower software emulation."
  CPU_FLAGS="-cpu max,hv_relaxed,hv_spinlocks=0x1fff,+pae,+nx"
fi

# Adjust RAM Allocation depending on your Replit tier (e.g., 3072 = 3GB)
RAM_ALLOCATION=3072 

# =========================
# Start QEMU
# =========================
echo "Starting QEMU..."
nohup qemu-system-x86_64 \
  $CPU_FLAGS \
  -smp 4,cores=4 \
  -M q35,usb=on \
  -device usb-tablet \
  -m $RAM_ALLOCATION \
  -device virtio-balloon-pci \
  -vga virtio \
  -net nic,netdev=n0,model=virtio-net-pci \
  -netdev user,id=n0,hostfwd=tcp::3389-:3389 \
  $BOOT_ORDER \
  -device virtio-serial-pci \
  -device virtio-rng-pci \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive file="$RAW_DISK",format=qcow2,if=virtio \
  -cdrom "$WIN_ISO" \
  -drive file="$VIRTIO_ISO",media=cdrom,if=ide \
  -uuid e47ddb84-fb4d-46f9-b531-14bb15156336 \
  -vnc :0 \
  -display none \
  > /tmp/qemu.log 2>&1 &

# =========================
# Start noVNC on port 8888
# =========================
echo "Starting noVNC..."
nohup "$NOVNC_DIR/utils/novnc_proxy" \
  --vnc 127.0.0.1:5900 \
  --listen 8888 \
  > /tmp/novnc.log 2>&1 &

# =========================
# Start Cloudflared tunnel
# =========================
echo "Starting Cloudflared tunnel..."
nohup cloudflared tunnel \
  --no-autoupdate \
  --url http://localhost:8888 \
  > /tmp/cloudflared.log 2>&1 &

sleep 10

if grep -q "trycloudflare.com" /tmp/cloudflared.log; then
  URL=$(grep -o "https://[a-z0-9.-]*trycloudflare.com" /tmp/cloudflared.log | head -n1)
  echo "========================================="
  echo " 🌍 Windows 11 QEMU + noVNC ready:"
  echo "     $URL/vnc.html"
  echo "========================================="
  echo "$URL/vnc.html" > noVNC-URL.txt
else
  echo "❌ Cloudflared tunnel failed. Check /tmp/cloudflared.log"
fi

# Keep the process running
elapsed=0
while true; do
  echo "Workspace alive - Time elapsed: $elapsed min"
  ((elapsed++))
  sleep 60
done
