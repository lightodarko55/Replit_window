#!/usr/bin/env bash
set -e

# =========================
# One-time cleanup
# =========================
if [ ! -f "$HOME/.cleanup_done" ]; then
  rm -rf "$HOME/.gradle"/* "$HOME/.emu"/* || true
  touch "$HOME/.cleanup_done"
fi

# =========================
# Optional swap (best-effort, Replit may block this)
# =========================
if [ ! -f /tmp/swapfile ]; then
  fallocate -l 1536M /tmp/swapfile 2>/dev/null || dd if=/dev/zero of=/tmp/swapfile bs=1M count=1536 2>/dev/null
  chmod 600 /tmp/swapfile 2>/dev/null
  mkswap /tmp/swapfile 2>/dev/null && swapon /tmp/swapfile 2>/dev/null \
    && echo "Swap enabled" || echo "Swap not permitted on this environment, continuing without it"
fi

# =========================
# Paths
# =========================
VM_DIR="$HOME/qemu"
RAW_DISK="$VM_DIR/windows.qcow2"
WIN_ISO="$VM_DIR/automic11.iso"
VIRTIO_ISO="$VM_DIR/virtio-win.iso"
NOVNC_DIR="$HOME/noVNC"
OVMF_DIR="$VM_DIR/ovmf"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"
OVMF_VARS="$OVMF_DIR/OVMF_VARS.fd"

mkdir -p "$OVMF_DIR" "$VM_DIR"

# =========================
# Download firmware / disk / ISOs if missing
# =========================
[ -f "$OVMF_CODE" ] || wget -O "$OVMF_CODE" https://qemu.weilnetz.de/test/ovmf/usr/share/OVMF/OVMF_CODE.fd
[ -f "$OVMF_VARS" ] || wget -O "$OVMF_VARS" https://qemu.weilnetz.de/test/ovmf/usr/share/OVMF/OVMF_VARS.fd
[ -f "$RAW_DISK" ]  || qemu-img create -f qcow2 "$RAW_DISK" 11G
[ -f "$WIN_ISO" ]   || wget -O "$WIN_ISO" https://github.com/kmille36/idx-windows-gui/releases/download/1.0/automic11.iso
[ -f "$VIRTIO_ISO" ] || wget -O "$VIRTIO_ISO" https://github.com/kmille36/idx-windows-gui/releases/download/1.0/virtio-win-0.1.271.iso

[ -d "$NOVNC_DIR/.git" ] || git clone https://github.com/novnc/noVNC.git "$NOVNC_DIR"

# =========================
# Start QEMU — TCG (software) mode, tuned for 4 cores / 7GB host
# =========================
echo "Starting QEMU (software emulation, no KVM)..."
nohup qemu-system-x86_64 \
  -accel tcg,thread=multi,tb-size=256 \
  -cpu max \
  -smp 4,cores=4 \
  -M q35,usb=on \
  -device usb-tablet \
  -m 3584 \
  -device virtio-balloon-pci \
  -vga std \
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

echo "Starting noVNC..."
nohup "$NOVNC_DIR/utils/novnc_proxy" \
  --vnc 127.0.0.1:5900 \
  --listen 8888 \
  > /tmp/novnc.log 2>&1 &

echo "Starting Cloudflared tunnel..."
nohup cloudflared tunnel \
  --no-autoupdate \
  --url http://localhost:8888 \
  > /tmp/cloudflared.log 2>&1 &

sleep 10
if grep -q "trycloudflare.com" /tmp/cloudflared.log; then
  URL=$(grep -o "https://[a-z0-9.-]*trycloudflare.com" /tmp/cloudflared.log | head -n1)
  echo "========================================="
  echo " Windows GUI ready (software-emulated, expect slowness):"
  echo "     $URL/vnc.html"
  echo "========================================="
else
  echo "Cloudflared tunnel failed — check /tmp/cloudflared.log"
fi

while true; do sleep 60; done
