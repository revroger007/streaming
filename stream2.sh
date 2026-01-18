#!/bin/bash

# =============================================================================
# Script Installer SRTLA + SRT + Restreamer (Versi Terbaru - Robust dengan Error Handling)
# Dibuat ulang & dikomentari detail oleh Grok berdasarkan repo revroger007/streaming
# Tujuan: Setup low-latency streaming dari Belabox → SRTLA → SRT → Restreamer
# Dukungan: Ubuntu/Debian 22.04/24.04+, Restreamer 2.10.0+, SRT patched BELABOX
#
# Fitur Error Handling:
# - Fungsi error_exit untuk handle kegagalan dengan pesan jelas & exit code
# - Cek $? setelah command kritis
# - Trap untuk cleanup jika Ctrl+C atau error tak terduga
# - Cek prerequisite tools sebelum mulai
# =============================================================================

set -e  # Keluar jika command gagal (bisa di-override sementara dengan || true jika perlu)

# Warna output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Fungsi error handling utama
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    echo -e "${RED}Script dihentikan. Kode exit: $2${NC}" >&2
    exit "${2:-1}"
}

# Fungsi untuk jalankan command & cek error
run_cmd() {
    echo "$1"
    eval "$1" || error_exit "Gagal menjalankan: $1" 3
}

# Trap untuk cleanup jika script diinterupsi (Ctrl+C, kill, dll)
cleanup() {
    echo -e "${YELLOW}Script diinterupsi. Membersihkan sementara...${NC}"
    # Opsional: matikan service jika sudah dibuat
    systemctl stop srtla-rec.service srt-rhei.service 2>/dev/null
    docker compose -f /opt/restreamer/docker-compose.yml down 2>/dev/null
    echo -e "${YELLOW}Cleanup selesai.${NC}"
}
trap cleanup EXIT ERR SIGINT SIGTERM

echo -e "${GREEN}=== Mulai Install SRTLA + SRT + Restreamer Terbaru (Robust) ===${NC}"
echo "Tanggal: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Pastikan kamu jalankan sebagai ROOT!"
echo ""

# ----------------------------------------------------------------------------
# 1. Cek prerequisite tools dasar
# ----------------------------------------------------------------------------
for cmd in git make cmake curl wget ufw; do
    command -v "$cmd" >/dev/null 2>&1 || error_exit "Tool '$cmd' tidak ditemukan. Install dulu dengan apt." 10
done

# ----------------------------------------------------------------------------
# 2. Update & Upgrade Sistem + Install paket dasar
# ----------------------------------------------------------------------------
echo -e "${GREEN}Update & upgrade sistem...${NC}"
apt update -y || error_exit "Gagal apt update" 11
apt upgrade -y || error_exit "Gagal apt upgrade" 12
apt install -y git make cmake tclsh pkg-config libssl-dev zlib1g-dev curl wget ufw net-tools build-essential || error_exit "Gagal install paket dasar" 13

echo -e "${GREEN}Sistem update & paket dasar OK.${NC}"

# ----------------------------------------------------------------------------
# 3. Install Docker jika belum ada
# ----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}Install Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh || error_exit "Gagal download installer Docker" 20
    sh get-docker.sh || error_exit "Gagal install Docker" 21
    rm get-docker.sh
    usermod -aG docker "${USER:-root}"  # Tambah ke group docker
else
    echo -e "${GREEN}Docker sudah terinstall.${NC}"
fi

# Cek docker compose (v2+)
if ! docker compose version >/dev/null 2>&1; then
    error_exit "Docker Compose tidak ditemukan atau versi lama. Install manual: https://docs.docker.com/compose/install/" 22
fi

# ----------------------------------------------------------------------------
# 4. Input StreamID & Passphrase
# ----------------------------------------------------------------------------
echo ""
read -p "Masukkan SRT StreamID (contoh: live/stream/belabox, kosongkan jika tidak pakai): " SRT_STREAMID
read -p "Masukkan SRT Passphrase (kosongkan jika tidak pakai): " SRT_PASSPHRASE

SRT_PARAMS=""
[ -n "$SRT_STREAMID" ] && SRT_PARAMS+="&streamid=$SRT_STREAMID"
[ -n "$SRT_PASSPHRASE" ] && SRT_PARAMS+="&passphrase=$SRT_PASSPHRASE"

echo -e "${GREEN}StreamID: ${SRT_STREAMID:-tidak dipakai}${NC}"
echo -e "${GREEN}Passphrase: ${SRT_PASSPHRASE:-tidak dipakai}${NC}"
echo ""

# ----------------------------------------------------------------------------
# 5. Compile SRT patched BELABOX
# ----------------------------------------------------------------------------
cd /root || error_exit "Gagal cd /root" 30

if [ ! -d "srt" ]; then
    git clone https://github.com/BELABOX/srt.git || error_exit "Gagal clone BELABOX/srt" 31
fi
cd srt || error_exit "Gagal cd srt" 32

./configure || error_exit "Gagal configure SRT" 33
make -j$(nproc) || error_exit "Gagal make SRT" 34
make install || error_exit "Gagal make install SRT" 35
ldconfig || error_exit "Gagal ldconfig" 36

# ----------------------------------------------------------------------------
# 6. Compile SRTLA
# ----------------------------------------------------------------------------
cd /root || error_exit "Gagal cd /root" 40

if [ ! -d "srtla" ]; then
    git clone https://github.com/BELABOX/srtla.git || error_exit "Gagal clone BELABOX/srtla" 41
fi
cd srtla || error_exit "Gagal cd srtla" 42
make -j$(nproc) || error_exit "Gagal make SRTLA" 43

# ----------------------------------------------------------------------------
# 7. Setup Restreamer Docker
# ----------------------------------------------------------------------------
mkdir -p /opt/restreamer/{config,data} || error_exit "Gagal buat direktori Restreamer" 50

cat <<EOF > /opt/restreamer/docker-compose.yml || error_exit "Gagal buat docker-compose.yml" 51
version: '3.8'
services:
  restreamer:
    image: datarhei/restreamer:latest
    container_name: restreamer
    restart: always
    privileged: true
    ports:
      - 8080:8080/tcp
      - 8181:8181/tcp
      - 1935:1935/tcp
      - 1936:1936/tcp
      - 6000:6000/udp
    volumes:
      - /opt/restreamer/config:/core/config
      - /opt/restreamer/data:/core/data
    environment:
      - RS_USERNAME=admin
      - RS_PASSWORD=admin
EOF

cd /opt/restreamer || error_exit "Gagal cd /opt/restreamer" 52
docker compose pull || error_exit "Gagal pull Restreamer image" 53
docker compose up -d || error_exit "Gagal start Restreamer container" 54

# ----------------------------------------------------------------------------
# 8. Buat systemd services
# ----------------------------------------------------------------------------
cat <<EOF > /etc/systemd/system/srtla-rec.service || error_exit "Gagal buat srtla-rec.service" 60
[Unit]
Description=SRTLA Receiver (BELABOX bonding)
After=network.target

[Service]
ExecStart=/root/srtla/srtla_rec 5000 127.0.0.1 5002 1
Restart=always
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/srt-rhei.service || error_exit "Gagal buat srt-rhei.service" 61
[Unit]
Description=SRT Relay: 5002 → Restreamer 6000
After=network.target docker.service
Requires=docker.service

[Service]
ExecStart=/root/srt/srt-live-transmit "srt://127.0.0.1:5002?mode=listener&latency=2000${SRT_PARAMS}" "srt://127.0.0.1:6000?mode=caller"
Restart=always
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------------------------------------------------------
# 9. Aktifkan services & firewall
# ----------------------------------------------------------------------------
systemctl daemon-reload || error_exit "Gagal daemon-reload" 70
systemctl enable --now srtla-rec.service || error_exit "Gagal enable/start srtla-rec" 71
systemctl enable --now srt-rhei.service || error_exit "Gagal enable/start srt-rhei" 72

ufw allow OpenSSH || true
ufw allow 5000/udp || true
ufw allow 6000/udp || true
ufw allow 8080/tcp || true
ufw allow 1935/tcp || true
ufw --force enable || error_exit "Gagal enable UFW" 73

# ----------------------------------------------------------------------------
# 10. Final status & instruksi
# ----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}=== Setup Selesai (semua tahap OK)! ===${NC}"
systemctl status srtla-rec.service --no-pager -l | head -n 10
echo ""
systemctl status srt-rhei.service --no-pager -l | head -n 10
echo ""
docker ps | grep restreamer || echo -e "${YELLOW}Container Restreamer tidak terlihat? Cek 'docker logs restreamer'${NC}"

echo -e "${GREEN}Langkah selanjutnya:${NC}"
echo "1. Buka: http://$(hostname -I | awk '{print $1}'):8080 → admin/admin"
echo "2. Setup SRT Listener: Port 6000, Latency 2000ms, StreamID sesuai input"
echo "3. Tes Belabox: srtla://IP_KAMU:5000"
echo ""
echo "Log pantau: journalctl -u srt-rhei.service -f"
echo "Edit config: sudo nano /etc/systemd/system/srt-rhei.service → daemon-reload & restart"
echo ""
echo -e "${GREEN}Jika ada error selama install, copy pesan ERROR merah & share!${NC}"
