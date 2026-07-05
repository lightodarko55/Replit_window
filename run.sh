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
# Paths (Scoped to workspace for persistence)
# =========================
SKIP_QCOW2_DOWNLOAD=1

VM_DIR="$PWD/qemu"
RAW_DISK="$VM_DIR/disk.qcow2"
WIN_ISO="$VM_DIR/automic11.iso"
VIRTIO_ISO="$VM_DIR/virtio-win.iso"
NOVNC_DIR="$PWD/noVNC"

OVMF_DIR="$VM_DIR/ovmf"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"
OVMF_VARS="$OVMF_DIR/OVMF_VARS.fd"

mkdir -p "$OVMF_DIR"

# =========================
# Force clear stuck background processes
# =========================
echo "🧹 Cleaning up any frozen background instances to release file locks..."
pkill -9 -f "qemu-system-x86_64|novnc_proxy|cloudflared" || true
sleep 2

# =========================
# Download OVMF firmware if missing (Kept for KVM mode)
# =========================
if [ ! -f "$OVMF_CODE" ]; then
  echo "Downloading OVMF_CODE.fd..."
  wget -O "$OVMF_CODE" https://qemu.weilnetz.de/test/ovmf/usr/share/OVMF/OVMF_CODE.fd
else
  echo "OVMF_CODE.fd already exists."
fi

if [ ! -f "$OVMF_VARS" ]; then
  echo "Downloading OVMF_VARS.fd..."
  wget -O "$OVMF_VARS" https://qemu.weilnetz.de/test/ovmf/usr/share/OVMF/OVMF_VARS.fd
else
  echo "OVMF_VARS.fd already exists."
fi

# =========================
# Download Windows ISO if missing
# =========================
if [ ! -f "$WIN_ISO" ]; then
  echo "Downloading Windows ISO..."
  wget -O "$WIN_ISO" https://github.com/kmille36/idx-windows-gui/releases/download/1.0/automic11.iso
else
  echo "Windows ISO already exists."
fi

# =========================
# Download VirtIO drivers ISO if missing
# =========================
if [ ! -f "$VIRTIO_ISO" ]; then
  echo "Downloading VirtIO drivers ISO..."
  wget -O "$VIRTIO_ISO" https://github.com/kmille36/idx-windows-gui/releases/download/1.0/virtio-win-0.1.271.iso
else
  echo "VirtIO ISO already exists."
fi

# =========================
# Clone noVNC if missing
# =========================
if [ ! -d "$NOVNC_DIR/.git" ]; then
  echo "Cloning noVNC..."
  mkdir -p "$NOVNC_DIR"
  git clone https://github.com/novnc/noVNC.git "$NOVNC_DIR"
else
  echo "noVNC already exists."
fi

# =========================
# Create disk image if not exists
# =========================
if [ ! -f "$RAW_DISK" ]; then
  echo "💽 Creating 100GB virtual disk..."
  qemu-img create -f qcow2 "$RAW_DISK" 100G
fi

# =========================
# Dynamic Boot Setup
# =========================
BOOT_ORDER="-boot order=c,menu=on"
if [ ! -s "$RAW_DISK" ] || [ $(stat -c%s "$RAW_DISK") -lt 1048576 ]; then
  echo "🚀 First boot - installing Windows from ISO"
  BOOT_ORDER="-boot order=d,menu=on"
fi

# =========================
# KVM Check & Dynamic Hardware Mapping
# =========================
if [ -e /dev/kvm ]; then
  echo "🚀 KVM hardware acceleration detected! Using UEFI mode."
  CPU_FLAGS="-enable-kvm -cpu host,+topoext,hv_relaxed,hv_spinlocks=0x1fff,hv-passthrough,+pae,+nx,kvm=on,+svm"
  FIRMWARE_FLAGS="-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE -drive if=pflash,format=raw,file=$OVMF_VARS"
  MACHINE_FLAG="-M q35,usb=on"
  VGA_FLAG="-vga virtio"
  DISK_FLAG="-drive file=$RAW_DISK,format=qcow2,if=virtio"
else
  echo "⚠️ KVM acceleration not found. Switching to bulletproof Software Emulation Profile."
  CPU_FLAGS="-cpu qemu64,+kvm_pv_unhalt" 
  FIRMWARE_FLAGS="" 
  MACHINE_FLAG="-M pc,usb=on" 
  VGA_FLAG="-vga std"
  # Standard -hda routing completely avoids bus selection errors & lockups
  DISK_FLAG="-hda $RAW_DISK" 
fi

# Safe RAM allocation tailored perfectly to your 7.8GB container limit
RAM_ALLOCATION=3072 

# =========================
# Start QEMU
# =========================
echo "Starting QEMU..."
rm -f /tmp/qemu.log
nohup qemu-system-x86_64 \
  $CPU_FLAGS \
  -smp 2,cores=2 \
  $MACHINE_FLAG \
  -device usb-tablet \
  -m $RAM_ALLOCATION \
  -device virtio-balloon-pci \
  $VGA_FLAG \
  -net nic,netdev=n0,model=virtio-net-pci \
  -netdev user,id=n0,hostfwd=tcp::3389-:3389 \
  $BOOT_ORDER \
  -device virtio-serial-pci \
  -device virtio-rng-pci \
  $FIRMWARE_FLAGS \
  $DISK_FLAG \
  -cdrom "$WIN_ISO" \
  -drive file="$VIRTIO_ISO",media=cdrom,if=ide \
  -uuid e47ddb84-fb4d-46f9-b531-14bb15156336 \
  -vnc 127.0.0.1:0 \
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

echo "Waiting for services to initialize..."
sleep 15

# =========================
# Auto-Diagnostic System Check
# =========================
if ! pgrep -f qemu-system-x86_64 > /dev/null; then
  echo "❌ QEMU CRASHED IMMEDIATELY! Printing error log below:"
  echo "------------------------------------------------------"
  cat /tmp/qemu.log
  echo "------------------------------------------------------"
  exit 1
fi

if grep -q "trycloudflare.com" /tmp/cloudflared.log; then
  URL=$(grep -o "https://[a-z0-9.-]*trycloudflare.com" /tmp/cloudflared.log | head -n1)
  echo "========================================="
  echo " 🌍 Windows 11 QEMU + noVNC ready:"
  echo "      $URL/vnc.html"
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
