#!/usr/bin/env bash
set -e

# One-time cleanup
if [ ! -f "$HOME/.cleanup_done" ]; then
  rm -rf "$HOME/.gradle/"* "$HOME/.emu/"* || true
  find "$HOME" -mindepth 1 -maxdepth 1 ! -name 'idx-ubuntu22-gui' ! -name '.*' -exec rm -rf {} +
  touch "$HOME/.cleanup_done"
fi

# Note: The docker daemon must be running for the following commands to work.
# This requires a Replit VM workspace.
if ! docker ps -a --format '{{.Names}}' | grep -qx 'ubuntu-novnc'; then
  docker run -d --name=ubuntu-novnc -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC \
    -p 3000:3000 -p 3001:3001 -v "$PWD:/config" --shm-size="1gb" \
    --restart unless-stopped lscr.io/linuxserver/webtop:ubuntu-mate
else
  docker start ubuntu-novnc || true
fi

# Install Chrome inside the container
docker exec -it ubuntu-novnc bash -lc "
  sudo apt update &&
  sudo apt remove -y firefox || true &&
  sudo apt install -y wget &&
  sudo wget -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb &&
  sudo apt install -y /tmp/chrome.deb &&
  sudo rm -f /tmp/chrome.deb
"

# Run cloudflared in background, capture logs
nohup cloudflared tunnel --no-autoupdate --url http://localhost:3000 \
  > /tmp/cloudflared.log 2>&1 &

# Give it 10s to start
sleep 10

# Extract tunnel URL from logs
if grep -q "trycloudflare.com" /tmp/cloudflared.log; then
  URL=$(grep -o "https://[a-z0-9.-]*trycloudflare.com" /tmp/cloudflared.log | head -n1)
  echo "========================================="
  echo " 🌍 Your Cloudflared tunnel is ready:"
  echo "     $URL"
  echo "========================================="
else
  echo "❌ Cloudflared tunnel failed, check /tmp/cloudflared.log"
fi

# Proxy setup (Replit alternative to the IDX web manager socat command)
nohup socat TCP-LISTEN:8080,fork,reuseaddr TCP:127.0.0.1:3000 &

elapsed=0; 
while true; do 
  echo "Time elapsed: $elapsed min"
  ((elapsed++))
  sleep 60
done
