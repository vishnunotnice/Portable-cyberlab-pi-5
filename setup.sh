#!/usr/bin/env bash

set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run this script using sudo."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/cyberpi-install.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================"
echo " CYBERPI SECURITY LAB INSTALLER"
echo "======================================"

echo "[1/8] Updating package lists..."

apt-get update

echo "[2/8] Installing networking tools..."

apt-get install -y \
    nmap \
    iputils-ping \
    traceroute \
    dnsutils \
    iperf3 \
    netcat-openbsd \
    iproute2 \
    curl \
    wget

echo "[3/8] Installing packet analysis tools..."

apt-get install -y \
    tcpdump \
    tshark

echo "[4/8] Installing VPN and security tools..."

apt-get install -y \
    wireguard \
    ufw \
    fail2ban \
    lynis \
    openssh-server

echo "[5/8] Installing development tools..."

apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-psutil \
    git \
    sqlite3 \
    jq \
    htop \
    ca-certificates

echo "[6/8] Configuring SSH..."

systemctl enable --now ssh

echo "[7/8] Creating project directories..."

TARGET_USER="${SUDO_USER:-root}"

if [[ "$TARGET_USER" == "root" ]]; then
    PROJECT_HOME="/root"
else
    PROJECT_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi

PROJECT_DIR="$PROJECT_HOME/cyberpi"

mkdir -p \
    "$PROJECT_DIR/scans" \
    "$PROJECT_DIR/captures" \
    "$PROJECT_DIR/reports" \
    "$PROJECT_DIR/logs" \
    "$PROJECT_DIR/backend" \
    "$PROJECT_DIR/frontend"

chown -R "$TARGET_USER:$TARGET_USER" "$PROJECT_DIR"

echo "[8/8] Verifying installed tools..."

TOOLS=(
    nmap
    tshark
    tcpdump
    ping
    traceroute
    dig
    iperf3
    nc
    wg
    ufw
    fail2ban-client
    lynis
    ssh
    python3
    git
    sqlite3
    jq
    htop
)

FAILED=0

for tool in "${TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "[OK] $tool"
    else
        echo "[MISSING] $tool"
        FAILED=1
    fi
done

echo ""
echo "======================================"
echo " INSTALLATION SUMMARY"
echo "======================================"

echo "Project directory: $PROJECT_DIR"
echo "Installation log: $LOG_FILE"

echo ""
echo "SSH status:"
systemctl is-active ssh || true

echo ""
echo "Raspberry Pi IP addresses:"
hostname -I || true

echo ""
echo "WireGuard:"
wg --version || true

echo ""
echo "Nmap:"
nmap --version | head -n 1 || true

echo ""
echo "TShark:"
tshark --version | head -n 1 || true

echo ""
echo "======================================"

if [[ "$FAILED" -eq 0 ]]; then
    echo "CYBERPI INSTALLATION COMPLETE"
else
    echo "INSTALLATION FINISHED WITH MISSING TOOLS"
    exit 1
fi

echo "======================================"