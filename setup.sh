#!/usr/bin/env bash
# CyberPi provisioning and maintenance helper
# Supports Debian/Ubuntu-based CyberPi images. Run with: sudo bash setup.sh

set -Eeuo pipefail
IFS=$'\n\t'

readonly APP_NAME='CyberPi Setup'
readonly STATE_DIR='/etc/cyberpi-setup'
readonly STARTUP_SCRIPT='/usr/local/sbin/cyberpi-startup'
readonly STARTUP_UNIT='/etc/systemd/system/cyberpi-startup.service'
readonly LOG_FILE='/var/log/cyberpi-setup.log'

[[ ${EUID} -eq 0 ]] || { echo "Please run as root: sudo bash $0" >&2; exit 1; }
mkdir -p "$STATE_DIR"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
info() { printf '\n==> %s\n' "$*"; log "INFO: $*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; log "WARNING: $*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; log "ERROR: $*"; exit 1; }
confirm() { local reply; read -r -p "$1 [y/N]: " reply; [[ $reply =~ ^([yY]|[yY][eE][sS])$ ]]; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"; }

on_error() { local code=$?; warn "Failed at line $1 (exit $code). See $LOG_FILE."; exit "$code"; }
trap 'on_error $LINENO' ERR

apt_repair() {
  require_cmd apt-get
  info 'Repairing APT and package configuration'
  export DEBIAN_FRONTEND=noninteractive
  dpkg --configure -a
  apt-get -f install -y
  apt-get update
  apt-get check
  info 'APT repair completed'
}

install_packages() {
  info 'Installing base tools and security updates'
  apt_repair
  apt-get install -y --no-install-recommends \
    ca-certificates curl sudo openssh-server ufw fail2ban \
    unattended-upgrades apt-listchanges net-tools iproute2 dnsutils
  apt-get upgrade -y
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
  systemctl enable --now fail2ban 2>/dev/null || true
  info 'Installation completed'
}

configure_startup() {
  local cmd
  echo 'Enter the command CyberPi should run after the network is available.'
  echo 'Examples: /home/cyberpi/my_program.py   or   python3 /home/cyberpi/my_program.py'
  read -r -p 'Startup command: ' cmd
  [[ -n $cmd ]] || { warn 'No command entered; startup was not changed.'; return; }
  if ! confirm "Install this as a system startup command: $cmd"; then return; fi

  umask 077
  cat > "$STARTUP_SCRIPT" <<EOF
#!/usr/bin/env bash
# Managed by CyberPi Setup. Edit through setup.sh to preserve safe permissions.
set -euo pipefail
exec $cmd
EOF
  chmod 700 "$STARTUP_SCRIPT"
  cat > "$STARTUP_UNIT" <<'EOF'
[Unit]
Description=CyberPi custom startup task
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/cyberpi-startup
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable cyberpi-startup.service
  info 'Automatic startup service is installed and enabled for the next boot'
  if confirm 'Start it now?'; then systemctl restart cyberpi-startup.service; fi
}

list_interfaces() {
  ip -o link show | awk -F': ' '$2 != "lo" {sub(/@.*/, "", $2); print $2}'
}

valid_ipv4() {
  local ip=$1 octet; IFS=. read -r -a parts <<< "$ip"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for octet in "${parts[@]}"; do [[ $octet =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1; done
}
valid_prefix() { [[ $1 =~ ^[0-9]{1,2}$ ]] && ((10#$1 >= 1 && 10#$1 <= 32)); }

network_inputs() {
  local default_iface=$1
  read -r -p "Interface [$default_iface]: " IFACE
  IFACE=${IFACE:-$default_iface}
  ip link show "$IFACE" >/dev/null 2>&1 || die "Unknown interface: $IFACE"
  read -r -p 'Static IPv4 address (for example 192.168.1.50): ' IP_ADDR
  valid_ipv4 "$IP_ADDR" || die 'Invalid IPv4 address'
  read -r -p 'CIDR prefix [24]: ' PREFIX
  PREFIX=${PREFIX:-24}; valid_prefix "$PREFIX" || die 'Prefix must be 1 through 32'
  read -r -p 'Gateway IPv4 address: ' GATEWAY
  valid_ipv4 "$GATEWAY" || die 'Invalid gateway address'
  read -r -p 'DNS servers, space-separated [1.1.1.1 8.8.8.8]: ' DNS
  DNS=${DNS:-'1.1.1.1 8.8.8.8'}
  local server; for server in $DNS; do valid_ipv4 "$server" || die "Invalid DNS address: $server"; done
}

configure_static_ip() {
  local default_iface
  default_iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')
  default_iface=${default_iface:-$(list_interfaces | head -n1)}
  [[ -n $default_iface ]] || die 'No network interface found'
  echo 'Available interfaces:'; list_interfaces | sed 's/^/  - /'
  network_inputs "$default_iface"
  info "Configuring $IFACE with $IP_ADDR/$PREFIX"
  if command -v nmcli >/dev/null 2>&1 && nmcli -t -f DEVICE device status | grep -Fxq "$IFACE"; then
    local connection
    connection=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)
    [[ -n $connection && $connection != '--' ]] || connection=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v i="$IFACE" '$2==i {print $1; exit}')
    [[ -n $connection ]] || die "No NetworkManager connection found for $IFACE"
    nmcli connection modify "$connection" ipv4.method manual ipv4.addresses "$IP_ADDR/$PREFIX" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS" ipv6.method auto
    nmcli connection up "$connection"
  elif [[ -f /etc/dhcpcd.conf ]]; then
    cp -a /etc/dhcpcd.conf "$STATE_DIR/dhcpcd.conf.$(date +%s).bak"
    sed -i "/^# BEGIN CYBERPI SETUP $IFACE$/,/^# END CYBERPI SETUP $IFACE$/d" /etc/dhcpcd.conf
    { echo "# BEGIN CYBERPI SETUP $IFACE"; echo "interface $IFACE"; echo "static ip_address=$IP_ADDR/$PREFIX"; echo "static routers=$GATEWAY"; echo "static domain_name_servers=$DNS"; echo "# END CYBERPI SETUP $IFACE"; } >> /etc/dhcpcd.conf
    systemctl restart dhcpcd
  else
    die 'No supported network manager found (NetworkManager or dhcpcd)'
  fi
  info 'Static IP configuration applied. Your remote session may need to reconnect at the new address.'
}

reset_dhcp() {
  local default_iface IFACE connection
  default_iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')
  default_iface=${default_iface:-$(list_interfaces | head -n1)}
  read -r -p "Interface to return to DHCP [$default_iface]: " IFACE
  IFACE=${IFACE:-$default_iface}; ip link show "$IFACE" >/dev/null 2>&1 || die "Unknown interface: $IFACE"
  confirm "Return $IFACE to DHCP?" || return
  info "Resetting $IFACE to DHCP"
  if command -v nmcli >/dev/null 2>&1; then
    connection=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)
    [[ -n $connection && $connection != '--' ]] || die "No NetworkManager connection found for $IFACE"
    nmcli connection modify "$connection" ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns ''
    nmcli connection up "$connection"
  elif [[ -f /etc/dhcpcd.conf ]]; then
    cp -a /etc/dhcpcd.conf "$STATE_DIR/dhcpcd.conf.$(date +%s).bak"
    sed -i "/^# BEGIN CYBERPI SETUP $IFACE$/,/^# END CYBERPI SETUP $IFACE$/d" /etc/dhcpcd.conf
    systemctl restart dhcpcd
  else die 'No supported network manager found'; fi
  info 'DHCP configuration applied'
}

security_hardening() {
  info 'Applying baseline security hardening'
  install -d -m 755 /etc/apt/apt.conf.d
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now unattended-upgrades 2>/dev/null || true
  if command -v ufw >/dev/null 2>&1; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow OpenSSH 2>/dev/null || ufw allow 22/tcp
    ufw --force enable
  else warn 'UFW is not installed; run installation first to configure a firewall.'; fi
  if [[ -f /etc/ssh/sshd_config ]]; then
    cp -an /etc/ssh/sshd_config "$STATE_DIR/sshd_config.original" || true
    sed -i -E 's/^[#[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin no/' /etc/ssh/sshd_config
    grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+' /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
    sshd -t && (systemctl reload ssh || systemctl reload sshd) || warn 'SSH configuration was not reloaded; check sshd_config.'
  fi
  info 'Security hardening applied (SSH root login disabled; firewall permits SSH only)'
}

security_check() {
  info 'Security and health check'
  printf '\nSystem: '; uname -a
  printf '\nPending package upgrades:\n'; apt-get -s upgrade 2>/dev/null | awk '/^[0-9]+ upgraded/ {print}' || true
  printf '\nListening services:\n'; ss -tulpn 2>/dev/null || true
  printf '\nFirewall status:\n'; command -v ufw >/dev/null && ufw status verbose || echo 'UFW not installed'
  printf '\nFailed system services:\n'; systemctl --failed --no-pager || true
  printf '\nDisk use:\n'; df -h / || true
  printf '\nStartup service:\n'; systemctl is-enabled cyberpi-startup.service 2>/dev/null || true
  printf '\nNetwork addresses:\n'; ip -brief address || true
}

show_status() {
  echo; echo "$APP_NAME"; echo '----------------------------------------'
  echo "Log: $LOG_FILE"
  systemctl is-active --quiet cyberpi-startup.service && echo 'Startup service: active' || echo 'Startup service: not active'
  ip -brief address
}

main_menu() {
  while true; do
    show_status
    cat <<'EOF'

1) Install packages and updates
2) Configure automatic startup
3) Set static IP address
4) Reset an interface to DHCP
5) Apply security hardening
6) Run security and health checks
7) Repair APT / broken packages
8) Exit
EOF
    read -r -p 'Choose an option [1-8]: ' choice
    case $choice in
      1) install_packages ;; 2) configure_startup ;; 3) configure_static_ip ;;
      4) reset_dhcp ;; 5) security_hardening ;; 6) security_check ;;
      7) apt_repair ;; 8) exit 0 ;; *) warn 'Please choose a number from 1 to 8.' ;;
    esac
    read -r -p 'Press Enter to return to the menu...' _
  done
}

main_menu "$@"
