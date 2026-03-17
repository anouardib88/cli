#!/usr/bin/env bash
# =============================================================================
# TAUROS Pi5 Setup Script
# Raspberry Pi 5 — Full Stack Installer
# =============================================================================
# Installs and configures:
#   - Pi-hole (network-wide ad/tracker blocking)
#   - LVM setup for dual 3.64TB disks
#   - TAUROS NetForensics tools
#   - Auto-mount at boot
#   - SSH hardening
# =============================================================================
# Usage: sudo bash pi5-setup.sh
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
banner() {
  echo -e "${BOLD}${CYAN}"
  echo "  ████████╗ █████╗ ██╗   ██╗██████╗  ██████╗ ███████╗"
  echo "     ██╔══╝██╔══██╗██║   ██║██╔══██╗██╔═══██╗██╔════╝"
  echo "     ██║   ███████║██║   ██║██████╔╝██║   ██║███████╗"
  echo "     ██║   ██╔══██║██║   ██║██╔══██╗██║   ██║╚════██║"
  echo "     ██║   ██║  ██║╚██████╔╝██║  ██║╚██████╔╝███████║"
  echo "     ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝"
  echo -e "  Pi5 NetForensics Setup — v1.0${NC}"
  echo ""
}

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight() {
  banner
  info "Running preflight checks..."

  [[ $EUID -ne 0 ]] && err "This script must be run as root: sudo bash $0"

  if ! grep -qi "raspberry" /proc/cpuinfo 2>/dev/null && \
     ! grep -qi "raspberry" /sys/firmware/devicetree/base/model 2>/dev/null; then
    warn "Not detected as a Raspberry Pi — continuing anyway."
  fi

  command -v apt-get >/dev/null 2>&1 || err "apt-get not found. Debian/Ubuntu required."
  ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 || err "No internet connectivity. Check network."

  log "Preflight OK"
}

# ── System update ─────────────────────────────────────────────────────────────
update_system() {
  log "Updating system packages..."
  apt-get update -qq
  apt-get upgrade -y -qq
  apt-get install -y -qq \
    curl wget git vim htop net-tools dnsutils \
    lvm2 parted gdisk \
    ufw fail2ban \
    python3 python3-pip \
    tcpdump tshark nmap netcat-openbsd \
    rsync screen tmux \
    jq
  log "System updated"
}

# ── Pi-hole ───────────────────────────────────────────────────────────────────
install_pihole() {
  log "Installing Pi-hole..."

  if command -v pihole >/dev/null 2>&1; then
    warn "Pi-hole already installed — skipping"
    return
  fi

  # Disable systemd-resolved stub listener to free port 53
  if systemctl is-active --quiet systemd-resolved; then
    log "Disabling systemd-resolved stub listener..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/pihole.conf <<'EOF'
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
FallbackDNS=1.1.1.1 8.8.8.8
EOF
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
  fi

  # Unattended Pi-hole install
  mkdir -p /etc/pihole
  cat > /etc/pihole/setupVars.conf <<EOF
PIHOLE_INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
IPV4_ADDRESS=$(ip -4 addr show "$(ip route | awk '/default/ {print $5; exit}')" | awk '/inet / {print $2; exit}')
IPV6_ADDRESS=
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=8.8.8.8
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=false
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=single
WEBPASSWORD=$(openssl rand -hex 16)
BLOCKING_ENABLED=true
EOF

  curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
  log "Pi-hole installed — admin at http://$(hostname -I | awk '{print $1}')/admin"
}

# ── LVM dual-disk setup ───────────────────────────────────────────────────────
setup_lvm() {
  log "Setting up LVM for dual 3.64TB disks..."

  # Detect the two largest non-root block devices
  mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,TYPE \
    | awk '$3=="disk" && $1!~/mmcblk|nvme.*p/' \
    | sort -k2 -rh \
    | awk '{print $1}' \
    | head -2)

  if [[ ${#DISKS[@]} -lt 2 ]]; then
    warn "Less than 2 extra disks detected — skipping LVM setup"
    info "Detected disks: $(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk"' | tr '\n' ' ')"
    return
  fi

  DISK1="${DISKS[0]}"
  DISK2="${DISKS[1]}"
  VG_NAME="tauros_vg"
  LV_DATA="tauros_data"
  LV_FORENSICS="tauros_forensics"
  MOUNT_DATA="/mnt/tauros/data"
  MOUNT_FORENSICS="/mnt/tauros/forensics"

  info "Using disks: $DISK1  $DISK2"
  info "This will DESTROY all data on those disks."
  read -r -t 15 -p "  Proceed? [y/N] " CONFIRM || true
  [[ "${CONFIRM,,}" != "y" ]] && { warn "LVM setup skipped by user"; return; }

  # Wipe and partition
  for DISK in "$DISK1" "$DISK2"; do
    log "Wiping $DISK..."
    wipefs -a "$DISK"
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary 0% 100%
    parted -s "$DISK" set 1 lvm on
    partprobe "$DISK"
    sleep 1
    pvcreate "${DISK}1"
  done

  # Volume group
  if vgs "$VG_NAME" >/dev/null 2>&1; then
    warn "VG $VG_NAME already exists — extending"
    vgextend "$VG_NAME" "${DISK1}1" "${DISK2}1" || true
  else
    vgcreate "$VG_NAME" "${DISK1}1" "${DISK2}1"
  fi

  # Logical volumes — 60% data, 40% forensics
  lvcreate -l 60%VG -n "$LV_DATA"      "$VG_NAME"
  lvcreate -l 40%VG -n "$LV_FORENSICS" "$VG_NAME"

  # Format
  mkfs.ext4 -F -L tauros_data      "/dev/$VG_NAME/$LV_DATA"
  mkfs.ext4 -F -L tauros_forensics "/dev/$VG_NAME/$LV_FORENSICS"

  # Mount
  mkdir -p "$MOUNT_DATA" "$MOUNT_FORENSICS"
  mount "/dev/$VG_NAME/$LV_DATA"      "$MOUNT_DATA"
  mount "/dev/$VG_NAME/$LV_FORENSICS" "$MOUNT_FORENSICS"

  # Persist in fstab
  grep -q "$LV_DATA" /etc/fstab || \
    echo "/dev/$VG_NAME/$LV_DATA  $MOUNT_DATA  ext4  defaults,noatime  0 2" >> /etc/fstab
  grep -q "$LV_FORENSICS" /etc/fstab || \
    echo "/dev/$VG_NAME/$LV_FORENSICS  $MOUNT_FORENSICS  ext4  defaults,noatime  0 2" >> /etc/fstab

  log "LVM ready: $MOUNT_DATA  $MOUNT_FORENSICS"
}

# ── TAUROS NetForensics ───────────────────────────────────────────────────────
install_tauros_netforensics() {
  log "Installing TAUROS NetForensics toolchain..."

  TAUROS_HOME="/opt/tauros"
  mkdir -p "$TAUROS_HOME"/{bin,captures,reports,logs}

  # Network forensics packages
  apt-get install -y -qq \
    tshark \
    tcpdump \
    nmap \
    arp-scan \
    whois \
    traceroute \
    mtr \
    netstat-nat \
    iftop \
    nethogs \
    bmon \
    vnstat \
    suricata || warn "Some packages unavailable — continuing"

  # vnstat monitoring
  if command -v vnstat >/dev/null 2>&1; then
    IFACE=$(ip route | awk '/default/ {print $5; exit}')
    vnstat -i "$IFACE" --add 2>/dev/null || true
    systemctl enable --now vnstat
  fi

  # TAUROS capture daemon script
  cat > "$TAUROS_HOME/bin/capture.sh" <<'CAPTURE'
#!/usr/bin/env bash
# TAUROS — continuous packet capture with rotation
IFACE=${1:-$(ip route | awk '/default/ {print $5; exit}')}
OUT_DIR="/mnt/tauros/forensics/captures"
mkdir -p "$OUT_DIR"
exec tcpdump -i "$IFACE" \
  -C 500 \
  -W 100 \
  -z gzip \
  -w "$OUT_DIR/capture_%Y%m%d_%H%M%S.pcap" \
  -G 3600 \
  not port 22
CAPTURE
  chmod +x "$TAUROS_HOME/bin/capture.sh"

  # TAUROS network scan script
  cat > "$TAUROS_HOME/bin/scan.sh" <<'SCAN'
#!/usr/bin/env bash
# TAUROS — local network scan & report
REPORT_DIR="/mnt/tauros/reports"
mkdir -p "$REPORT_DIR"
SUBNET=$(ip -4 route | awk '/proto kernel/ {print $1; exit}')
STAMP=$(date +%Y%m%d_%H%M%S)
echo "[$(date)] Scanning $SUBNET..." | tee "$REPORT_DIR/scan_${STAMP}.txt"
nmap -sn -T4 "$SUBNET" \
  --open \
  -oN "$REPORT_DIR/scan_${STAMP}.txt" \
  2>/dev/null
echo "Report: $REPORT_DIR/scan_${STAMP}.txt"
SCAN
  chmod +x "$TAUROS_HOME/bin/scan.sh"

  # Systemd unit for capture daemon
  cat > /etc/systemd/system/tauros-capture.service <<EOF
[Unit]
Description=TAUROS Continuous Packet Capture
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$TAUROS_HOME/bin/capture.sh
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  # Don't auto-start capture — let user enable explicitly
  info "Capture daemon ready: systemctl enable --now tauros-capture"
  log "TAUROS NetForensics installed at $TAUROS_HOME"
}

# ── SSH hardening ─────────────────────────────────────────────────────────────
harden_ssh() {
  log "Hardening SSH..."

  SSHD_CONF="/etc/ssh/sshd_config"
  cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)"

  # Apply hardened settings
  declare -A SSH_SETTINGS=(
    ["PermitRootLogin"]="no"
    ["PasswordAuthentication"]="yes"
    ["PubkeyAuthentication"]="yes"
    ["AuthorizedKeysFile"]=".ssh/authorized_keys"
    ["X11Forwarding"]="no"
    ["AllowTcpForwarding"]="no"
    ["MaxAuthTries"]="3"
    ["LoginGraceTime"]="30"
    ["ClientAliveInterval"]="300"
    ["ClientAliveCountMax"]="2"
    ["Protocol"]="2"
    ["HostbasedAuthentication"]="no"
    ["IgnoreRhosts"]="yes"
    ["PermitEmptyPasswords"]="no"
  )

  for KEY in "${!SSH_SETTINGS[@]}"; do
    VALUE="${SSH_SETTINGS[$KEY]}"
    if grep -q "^${KEY}" "$SSHD_CONF"; then
      sed -i "s|^${KEY}.*|${KEY} ${VALUE}|" "$SSHD_CONF"
    elif grep -q "^#${KEY}" "$SSHD_CONF"; then
      sed -i "s|^#${KEY}.*|${KEY} ${VALUE}|" "$SSHD_CONF"
    else
      echo "${KEY} ${VALUE}" >> "$SSHD_CONF"
    fi
  done

  sshd -t && systemctl restart ssh
  log "SSH hardened"
}

# ── Fail2ban ──────────────────────────────────────────────────────────────────
setup_fail2ban() {
  log "Configuring fail2ban..."

  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 86400
EOF

  systemctl enable --now fail2ban
  log "fail2ban active"
}

# ── UFW firewall ──────────────────────────────────────────────────────────────
setup_ufw() {
  log "Configuring UFW firewall..."

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw allow 53         # DNS (Pi-hole)
  ufw allow 80/tcp     # Pi-hole web UI
  ufw allow 443/tcp    # HTTPS
  ufw --force enable
  log "UFW firewall active"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  TAUROS Pi5 Setup Complete!${NC}"
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
  IP=$(hostname -I | awk '{print $1}')
  echo ""
  echo -e "  ${CYAN}Pi-hole admin:${NC}   http://${IP}/admin"
  echo -e "  ${CYAN}Forensics dir:${NC}   /mnt/tauros/forensics"
  echo -e "  ${CYAN}Data dir:${NC}        /mnt/tauros/data"
  echo -e "  ${CYAN}TAUROS tools:${NC}    /opt/tauros/bin/"
  echo ""
  echo -e "  ${YELLOW}Enable capture:${NC}  systemctl enable --now tauros-capture"
  echo -e "  ${YELLOW}Network scan:${NC}    /opt/tauros/bin/scan.sh"
  echo ""
  echo -e "${BOLD}  Set Pi-hole password:  pihole -a -p${NC}"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  preflight
  update_system
  install_pihole
  setup_lvm
  install_tauros_netforensics
  harden_ssh
  setup_fail2ban
  setup_ufw
  print_summary
}

main "$@"
