#!/bin/bash
# ============================================================
#  ADSB RADAR KIOSK — Proxmox LXC Installer
#  github.com/hankalf/adsb-kiosk
#
#  Run on Proxmox HOST shell:
#    curl -sL https://raw.githubusercontent.com/hankalf/adsb-kiosk/main/install.sh \
#      -o /tmp/adsb-setup.sh && bash /tmp/adsb-setup.sh
# ============================================================
set -e

# ── Change this if you fork the repo ────────────────────────
GITHUB_RAW="https://raw.githubusercontent.com/hankalf/adsb-kiosk/main"

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; AMBER='\033[0;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${AMBER}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${GREEN}══════════════════════════════════════════${NC}";
            echo -e "${BOLD}${GREEN}  $*${NC}";
            echo -e "${BOLD}${GREEN}══════════════════════════════════════════${NC}\n"; }

# ── Preflight ────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run as root on the Proxmox HOST node."
command -v pct    >/dev/null 2>&1 || error "pct not found — is this a Proxmox host?"
command -v curl   >/dev/null 2>&1 || error "curl not found."

header "ADSB Radar Kiosk — LXC Installer"
echo -e "${BOLD}Radar display source:${NC} ${GITHUB_RAW}/index.html"
echo -e "${BOLD}Enrichment:${NC} adsbdb.com + hexdb.io (no API keys needed)"
echo ""

# ── User input ───────────────────────────────────────────────
read -p "$(echo -e ${BOLD}LXC Container ID${NC} [default: 200]: )" CT_ID
CT_ID=${CT_ID:-200}
if pct status "$CT_ID" &>/dev/null; then
  error "Container ID $CT_ID already exists. Choose a different ID."
fi

read -p "$(echo -e ${BOLD}Container hostname${NC} [default: adsb-kiosk]: )" CT_HOSTNAME
CT_HOSTNAME=${CT_HOSTNAME:-adsb-kiosk}

echo ""
info "Available storage pools:"
pvesm status | awk 'NR>1 {print "  " $1 " (" $2 ")"}'
echo ""
read -p "$(echo -e ${BOLD}Storage pool${NC} [default: local-lvm]: )" CT_STORAGE
CT_STORAGE=${CT_STORAGE:-local-lvm}

read -p "$(echo -e ${BOLD}Network bridge${NC} [default: vmbr0]: )" CT_BRIDGE
CT_BRIDGE=${CT_BRIDGE:-vmbr0}

read -p "$(echo -e ${BOLD}RAM in MB${NC} [default: 1024]: )" CT_RAM
CT_RAM=${CT_RAM:-1024}

read -p "$(echo -e ${BOLD}Disk size in GB${NC} [default: 8]: )" CT_DISK
CT_DISK=${CT_DISK:-8}

read -p "$(echo -e ${BOLD}CPU cores${NC} [default: 2]: )" CT_CORES
CT_CORES=${CT_CORES:-2}

echo ""
read -s -p "$(echo -e ${BOLD}Set root password for the container: ${NC})" CT_PASS; echo ""
read -s -p "$(echo -e ${BOLD}Confirm password: ${NC})" CT_PASS2; echo ""
[[ "$CT_PASS" != "$CT_PASS2" ]] && error "Passwords do not match."

# ── Template ─────────────────────────────────────────────────
header "Step 1/5 — Debian 12 Template"

TEMPLATE_STORE=$(pvesm status | awk '/vztmpl|dir/ {print $1}' | head -1)
[[ -z "$TEMPLATE_STORE" ]] && TEMPLATE_STORE="local"
TEMPLATE=$(pveam list "$TEMPLATE_STORE" 2>/dev/null | grep "debian-12" | awk '{print $1}' | head -1)

if [[ -z "$TEMPLATE" ]]; then
  info "Downloading Debian 12 template..."
  pveam update
  TEMPLATE_NAME=$(pveam available | grep "debian-12-standard" | awk '{print $2}' | head -1)
  [[ -z "$TEMPLATE_NAME" ]] && error "Could not find Debian 12 template. Run 'pveam update' manually."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_NAME"
  TEMPLATE="${TEMPLATE_STORE}:vztmpl/${TEMPLATE_NAME}"
else
  success "Found template: $TEMPLATE"
fi

# ── Create LXC ───────────────────────────────────────────────
header "Step 2/5 — Creating LXC Container"

info "Creating container $CT_ID ($CT_HOSTNAME)..."
pct create "$CT_ID" "$TEMPLATE" \
  --hostname "$CT_HOSTNAME" \
  --password "$CT_PASS" \
  --cores "$CT_CORES" \
  --memory "$CT_RAM" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
  --features nesting=1 \
  --unprivileged 1 \
  --ostype debian \
  --start 1

success "Container $CT_ID created and started."
info "Waiting for container to boot..."
sleep 8

CT_IP=""
for i in {1..15}; do
  CT_IP=$(pct exec "$CT_ID" -- ip -4 addr show eth0 2>/dev/null \
    | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1)
  [[ -n "$CT_IP" ]] && break
  sleep 2
done
[[ -n "$CT_IP" ]] && success "Container IP: $CT_IP" \
  || warn "Could not auto-detect IP — DHCP may still be pending."

# ── Install packages ─────────────────────────────────────────
header "Step 3/5 — Installing Packages"

info "Installing Xorg, Openbox, Chromium, Python3..."
pct exec "$CT_ID" -- bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    xorg openbox chromium unclutter python3 \
    fonts-liberation fonts-dejavu ca-certificates \
    dbus-x11 curl 2>&1 | tail -3
"
success "Packages installed."

# ── Deploy display ───────────────────────────────────────────
header "Step 4/5 — Deploying ADSB Radar Display"

info "Creating /opt/adsb-kiosk..."
pct exec "$CT_ID" -- mkdir -p /opt/adsb-kiosk

info "Downloading radar display from GitHub..."
pct exec "$CT_ID" -- bash -c "
  curl -sL '${GITHUB_RAW}/index.html' -o /opt/adsb-kiosk/index.html
  echo 'Downloaded:' \$(wc -c < /opt/adsb-kiosk/index.html) 'bytes'
"
success "Radar display deployed."

info "Writing web server systemd service..."
pct exec "$CT_ID" -- bash -c "cat > /etc/systemd/system/adsb-webserver.service << 'EOF'
[Unit]
Description=ADSB Radar Web Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/adsb-kiosk
ExecStart=/usr/bin/python3 -m http.server 8080
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF"

info "Writing kiosk launch script..."
pct exec "$CT_ID" -- bash -c "cat > /opt/adsb-kiosk/start-kiosk.sh << 'EOF'
#!/bin/bash
sleep 3
export DISPLAY=:0
export HOME=/root
export XAUTHORITY=/root/.Xauthority
unclutter -idle 1 -root &
xset s off
xset -dpms
xset s noblank
/usr/bin/chromium \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --disable-session-crashed-bubble \
  --disable-restore-session-state \
  --no-sandbox \
  --user-data-dir=/root/.chromium-kiosk \
  --app=http://localhost:8080/index.html
EOF
chmod +x /opt/adsb-kiosk/start-kiosk.sh"

info "Writing kiosk systemd service..."
pct exec "$CT_ID" -- bash -c "cat > /etc/systemd/system/adsb-kiosk.service << 'EOF'
[Unit]
Description=ADSB Radar Kiosk Display
After=network.target adsb-webserver.service
Requires=adsb-webserver.service

[Service]
Type=simple
User=root
Environment=DISPLAY=:0
Environment=XAUTHORITY=/root/.Xauthority
ExecStartPre=/bin/bash -c 'X :0 -nolisten tcp &>/var/log/xorg-kiosk.log & sleep 2'
ExecStart=/opt/adsb-kiosk/start-kiosk.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

info "Enabling services..."
pct exec "$CT_ID" -- bash -c "
  systemctl daemon-reload
  systemctl enable adsb-webserver adsb-kiosk
  systemctl start adsb-webserver
"
success "Services configured."

# ── Done ─────────────────────────────────────────────────────
header "Step 5/5 — Done!"

echo -e "${BOLD}${GREEN}✔  ADSB Radar Kiosk is installed!${NC}"
echo ""
echo -e "  ${BOLD}Container ID:${NC}   $CT_ID"
echo -e "  ${BOLD}Hostname:${NC}       $CT_HOSTNAME"
[[ -n "$CT_IP" ]] && echo -e "  ${BOLD}IP Address:${NC}     ${AMBER}$CT_IP${NC}"
echo ""
echo -e "${BOLD}Open in any browser on your network:${NC}"
[[ -n "$CT_IP" ]] && echo -e "  ${AMBER}http://$CT_IP:8080${NC}"
echo ""
echo -e "${BOLD}Start the projector kiosk:${NC}"
echo -e "  pct exec $CT_ID -- systemctl start adsb-kiosk"
echo ""
echo -e "${BOLD}To update the display in future:${NC}"
echo -e "  1. Edit ${BLUE}index.html${NC} in your GitHub repo"
echo -e "  2. Run on Proxmox:"
echo -e "     ${AMBER}pct exec $CT_ID -- bash -c \"curl -sL ${GITHUB_RAW}/index.html -o /opt/adsb-kiosk/index.html && systemctl restart adsb-kiosk\"${NC}"
echo ""
echo -e "${BOLD}Other useful commands:${NC}"
echo -e "  pct exec $CT_ID -- systemctl status adsb-kiosk"
echo -e "  pct exec $CT_ID -- journalctl -u adsb-kiosk -f"
echo -e "  pct stop $CT_ID   # shut down"
echo -e "  pct start $CT_ID  # start up"
echo ""
echo -e "${BOLD}${GREEN}Enjoy your radar! ✈${NC}"
