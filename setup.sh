#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo ">>> Update system & install dependencies..."
sudo apt update && sudo apt -o Dpkg::Options::="--force-confold" upgrade -y
sudo apt install -y -o Dpkg::Options::="--force-confold" \
  tclsh pkg-config libssl-dev build-essential make cmake tcl openssl zlib1g-dev gcc perl net-tools nano ssh git zip unzip ffmpeg ufw apt-transport-https ca-certificates curl software-properties-common
  
echo ">>> Setup firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 5000/udp comment 'SRTLA Input'
sudo ufw allow 1935/tcp comment 'RTMP Output'
sudo ufw allow 5001/udp comment 'SRT Output'
sudo ufw allow 5002/udp comment 'SRT Output'
sudo ufw allow 8080/tcp comment 'WebUI'
sudo ufw allow 9090/tcp comment 'Monitoring'
sudo ufw --force enable

echo ">>> Install & build SRTLA..."
cd /root
sudo rm -rf srt srtla
sudo git clone https://github.com/BELABOX/srtla.git
cd srtla && sudo make && cd ..

echo ">>> Install & build SRT..."
sudo git clone https://github.com/BELABOX/srt.git
cd srt && sudo ./configure && sudo make && cd ..

echo ">>> Setup systemd services..."
sudo tee /etc/systemd/system/srtla-rec.service > /dev/null << 'EOF'
[Unit]
Description=SRTLA Receiver (Belabox Input)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/srtla
ExecStart=/root/srtla/srtla_rec 5000 127.0.0.1 5002
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/srt-rhei.service > /dev/null << 'EOF'
[Unit]
Description=SRT Transmitter to Restreamer
After=network.target
Requires=srtla-rec.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/srt
ExecStart=/root/srt/srt-live-transmit -st:yes \
  "srt://127.0.0.1:5002?mode=listener&latency=2000" \
  "srt://127.0.0.1:6000?mode=caller"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now srtla-rec srt-rhei

echo ">>> Install Docker..."
sudo apt install apt-transport-https ca-certificates curl software-properties-common -y
sudo mkdir -p /etc/apt/keyrings
sudo chmod 0755 /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
sudo systemctl enable docker
sudo systemctl is-active docker

echo ">>> Setup Restreamer..."
sudo mkdir -p /opt/restreamer /opt/core/config /opt/core/data
cat << 'EOF' | sudo tee /opt/restreamer/docker-compose.yml
version: '3.8'

services:
  restreamer:
    image: datarhei/restreamer:latest
    container_name: restreamer
    restart: unless-stopped
    privileged: true
    volumes:
      - /opt/core/config:/core/config
      - /opt/core/data:/core/data
    ports:
      - "8080:8080"
      - "8181:8181"
      - "1935:1935"
      - "5001:5001"
      - "1936:1936"
      - "6000:6000/udp"
EOF

cd /opt/restreamer
sudo docker compose up -d

echo ">>> Setup selesai! 🎉"
