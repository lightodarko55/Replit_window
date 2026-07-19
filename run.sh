#!/bin/bash
set -e

echo "Starting Windows VM setup on Replit..."

# =========================
# Paths & Variables
# =========================
WORKSPACE_DIR="$PWD"
VM_DIR="$WORKSPACE_DIR/qemu"
RAW_DISK="$VM_DIR/windows.qcow2"
WIN_ISO="$VM_DIR/automic11.iso"
VIRTIO_ISO="$VM_DIR/virtio-win.iso"
NOVNC_DIR="$WORKSPACE_DIR/noVNC"
OVMF_DIR="$VM_DIR/ovmf"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"
OVMF_VARS="$OVMF_DIR/OVMF_VARS.fd"

SKIP_QCOW2_DOWNLOAD=0

mkdir -p "$VM_DIR"
mkdir -p "$OVMF_DIR"

# =========================
# Download OVMF firmware
# =========================
if [ ! -f "$OVMF_CODE" ]; then
  echo "Downloading OVMF_CODE.fd..."
  wget -q -O "$OVMF_CODE" https://qemu.weilnetz.de/test/ovmf/usr/share/OVMF/OVMF_CODE.fd
else
  echo "OVMF_CODE.fd already exists."
fi

if [ ! -f "$OVMF_VARS" ]; then
  echo "Downloading OVMF_VARS.fd..."
  wget -q -O "$OVMF_VARS" https://qemu.weilnetz.de/test/ovmf/usr/share/OVMF/OVMF_VARS.fd
else
  echo "OVMF_VARS.fd already exists."
fi

# =========================
# Download Disk & ISOs
# =========================
if [ "$SKIP_QCOW2_DOWNLOAD" -ne 1 ]; then
  if [ ! -f "$RAW_DISK" ]; then
    echo "Downloading QCOW2 disk..."
    wget -q -O "$RAW_DISK" https://bit.ly/45hceMn
  else
    echo "QCOW2 disk already exists."
  fi
fi

if [ ! -f "$WIN_ISO" ]; then
  echo "Downloading Windows ISO..."
  wget -q -O "$WIN_ISO" https://github.com/kmille36/idx-windows-gui/releases/download/1.0/automic11.iso
else
  echo "Windows ISO already exists."
fi

if [ ! -f "$VIRTIO_ISO" ]; then
  echo "Downloading VirtIO drivers ISO..."
  wget -q -O "$VIRTIO_ISO" https://github.com/kmille36/idx-windows-gui/releases/download/1.0/virtio-win-0.1.271.iso
else
  echo "VirtIO ISO already exists."
fi

# =========================
# Clone noVNC
# =========================
if [ ! -d "$NOVNC_DIR/.git" ]; then
  echo "Cloning noVNC..."
  git clone https://github.com/novnc/noVNC.git "$NOVNC_DIR"
else
  echo "noVNC already exists."
fi

if [ ! -f "$RAW_DISK" ]; then
  echo "Creating QCOW2 disk..."
  qemu-img create -f qcow2 "$RAW_DISK" 11G
fi

# =========================
# Start QEMU (Software Virtualization)
# =========================
echo "Starting QEMU (Note: KVM is disabled on Replit)..."
nohup qemu-system-x86_64 \
  -cpu qemu64 \
  -smp 4,cores=4 \
  -M q35,usb=on \
  -device usb-tablet \
  -m 4096 \
  -device virtio-balloon-pci \
  -vga virtio \
  -net nic,netdev=n0,model=virtio-net-pci \
  -netdev user,id=n0,hostfwd=tcp::3389-:3389 \
  -boot c \
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
echo "Starting noVNC on port 8888..."
nohup "$NOVNC_DIR/utils/novnc_proxy" \
  --vnc 127.0.0.1:5900 \
  --listen 8888 \
  > /tmp/novnc.log 2>&1 &

# =========================
# Start Cloudflared tunnel
# =========================
echo "Starting Cloudflared tunnel for port 8888..."
nohup cloudflared tunnel \
  --no-autoupdate \
  --url http://localhost:8888 \
  > /tmp/cloudflared.log 2>&1 &

sleep 10

if grep -q "trycloudflare.com" /tmp/cloudflared.log; then
  URL=$(grep -o "https://[a-z0-9.-]*trycloudflare.com" /tmp/cloudflared.log | head -n1)
  echo "========================================="
  echo " 🌍 Windows 11 QEMU + noVNC ready:"
  echo "      $URL/vnc.html"
  echo "========================================="
else
  echo "❌ Cloudflared tunnel failed to generate a URL."
  cat /tmp/cloudflared.log
fi

# =========================
# Keep workspace alive
# =========================
elapsed=0
while true; do
  echo "Time elapsed: $elapsed min"
  ((elapsed++))
  sleep 60
done
