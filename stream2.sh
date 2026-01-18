#!/usr/bin/env bash
# =============================================================================
# SRTLA + Restreamer + BELABOX setup script (versi lebih baik - 2026)
# =============================================================================
# Catatan: Dijalankan sebagai root di Ubuntu 22.04 / 24.04 / 26.04 (atau Debian 12+)
# =============================================================================

set -euo pipefail
trap 'echo -e "\n${RED}ERROR: Script gagal di baris $LINENO${NC}" >&2; exit 1' ERR

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Konfigurasi - mudah diubah di sini
SRTLA_PORT=5000
SRT_LOCAL_PORT=5002
RESTREAMER_HTTP_PORT=8080
RESTREAMER_RTMP_PORT=1935
SRT_OUTPUT_PORT=6000
INSTALL_DIR="/opt/belabox"
LOG_FILE="/var/log/belabox-setup.log"

# ------------------------------------------------------------------------------
echo -e "${GREEN}=== Belabox SRTLA + Restreamer Setup (Improved) ===${NC}"
echo "Waktu mulai : $(date '+%Y-%m-%d %H:%M:%S')"
echo

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Script ini harus dijalankan sebagai root (sudo)${NC}"
    exit 1
fi

if ! grep -qiE 'ubuntu|debian' /etc/os-release; then
    echo -e "${RED}Script ini hanya support Ubuntu / Debian saat ini${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
echo -e "${YELLOW}1. Update sistem & install paket dasar...${NC}"

export DEBIAN_FRONTEND=noninteractive

{
    apt-get update -qq
    apt-get upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"
    apt-get install -y --no-install-recommends \
        build-essential cmake make gcc g++ pkg-config \
        libssl-dev zlib1g-dev tclsh tcl-dev \
        git curl wget nano net-tools ufw \
        ca-certificates apt-transport-https software-properties-common \
        ffmpeg zip unzip
} | tee -a "$LOG_FILE"

# ------------------------------------------------------------------------------
echo -e "${YELLOW}2. Konfigurasi firewall (UFW)...${NC}"

ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing

ufw allow ssh comment "SSH access"
ufw allow "$SRTLA_PORT/udp" comment "SRTLA input (Belabox)"
ufw allow "$RESTREAMER_RTMP_PORT/tcp" comment "RTMP output"
ufw allow 5001/udp comment "SRT output (opsional)"
ufw allow "$RESTREAMER_HTTP_PORT/tcp" comment "Restreamer Web UI"
ufw allow 9090/tcp comment "Monitoring (opsional)"
ufw --force enable

ufw status | grep -E 'ALLOW|DENY'

# ------------------------------------------------------------------------------
echo -e "${YELLOW}3. Build SRT & SRTLA...${NC}"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

rm -rf srt srtla 2>/dev/null || true

echo "→ Cloning & building SRTLA..."
git clone --depth 1 https://github.com/BELABOX/srtla.git
cd srtla
make clean >/dev/null 2>&1 || true
make -j"$(nproc)"
cd ..

echo "→ Cloning & building SRT..."
git clone --depth 1 https://github.com/BELABOX/srt.git
cd srt
./configure --prefix=/usr/local
make -j"$(nproc)"
make install
cd ..

# ------------------------------------------------------------------------------
echo -e "${YELLOW}4. Membuat systemd services...${NC}"

cat > /etc/systemd/system/srtla-receiver.service <<EOF
[Unit]
Description=SRTLA Receiver (Belabox input)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/srtla
ExecStart=$INSTALL_DIR/srtla/srtla_rec $SRTLA_PORT 127.0.0.1 $SRT_LOCAL_PORT
Restart=always
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/srt-forwarder.service <<EOF
[Unit]
Description=SRT forwarder to Restreamer
After=network-online.target srtla-receiver.service
Requires=srtla-receiver.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/srt
ExecStart=/usr/local/bin/srt-live-transmit \
    "srt://127.0.0.1:$SRT_LOCAL_PORT?mode=listener&latency=2000" \
    "srt://127.0.0.1:$SRT_OUTPUT_PORT?mode=caller"
Restart=always
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now srtla-receiver srt-forwarder

systemctl status --no-pager srtla-receiver srt-forwarder

# ------------------------------------------------------------------------------
echo -e "${YELLOW}5. Install Docker & Docker Compose (cara resmi 2025+)...${NC}"

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# ------------------------------------------------------------------------------
echo -e "${YELLOW}6. Setup Restreamer (datarhei)...${NC}"

mkdir -p /opt/restreamer/config /opt/restreamer/data

cat > /opt/restreamer/docker-compose.yml <<EOF
services:
  restreamer:
    image: datarhei/restreamer:latest
    container_name: restreamer
    restart: unless-stopped
    privileged: true
    network_mode: host          # <-- lebih simpel untuk RTMP/SRT
    volumes:
      - /opt/restreamer/config:/core/config
      - /opt/restreamer/data:/core/data
    environment:
      - RESTREAMER_UI_PORT=$RESTREAMER_HTTP_PORT
EOF

cd /opt/restreamer
docker compose pull
docker compose up -d

echo
echo -e "${GREEN}Setup selesai!${NC}"
echo
echo "→ Web UI Restreamer     : http://$(hostname -I | awk '{print $1}'):$RESTREAMER_HTTP_PORT"
echo "→ SRTLA mendengarkan    : UDP port $SRTLA_PORT"
echo "→ SRT ke Restreamer     : port $SRT_OUTPUT_PORT (localhost)"
echo "→ RTMP keluar           : rtmp://$(hostname -I | awk '{print $1}'):$RESTREAMER_RTMP_PORT/..."
echo
echo "Cek status:"
echo "  systemctl status srtla-receiver srt-forwarder"
echo "  docker compose -f /opt/restreamer/docker-compose.yml ps"
echo
echo -e "Semoga lancar streaming-nya! 🚀"
