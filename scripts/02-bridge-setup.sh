#!/bin/bash
# ============================================================
# 02 — Bridge Setup (FIXED VERSION)
# ⚠️  Run on LOCAL CONSOLE — SSH will disconnect
# ============================================================
# FIXES:
#   - Persistence now set in BOTH success and kernel-fix paths
#   - libvirtd enabled automatically
#   - Better error handling
#   - Proper verification
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

# ─── Colors ───
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Helper Functions ───
log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[✓]${NC}     $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC}     $1"; }
log_error() { echo -e "${RED}[✗]${NC}     $1"; }

set_persistence() {
  log_info "Setting persistence (autoconnect)..."
  sudo nmcli connection modify "$BRIDGE_IFACE" connection.autoconnect yes
  sudo nmcli connection modify "$BRIDGE_IFACE" connection.autoconnect-slaves 1
  sudo nmcli connection modify "bridge-slave-$PHYS_IFACE" connection.autoconnect yes
  log_ok "Persistence set"
}

enable_libvirtd() {
  log_info "Ensuring libvirtd is enabled..."
  if systemctl is-enabled libvirtd > /dev/null 2>&1; then
    log_ok "libvirtd already enabled"
  else
    sudo systemctl enable --now libvirtd
    log_ok "libvirtd enabled"
  fi

  if systemctl is-active libvirtd > /dev/null 2>&1; then
    log_ok "libvirtd is active"
  else
    log_warn "libvirtd not active — starting..."
    sudo systemctl start libvirtd
    sleep 2
    systemctl is-active libvirtd
  fi
}

verify_bridge() {
  echo ""
  echo "─── Verification ───"
  echo ""
  echo "Bridge IP:"
  ip -br a show "$BRIDGE_IFACE" 2>/dev/null | sed 's/^/  /'
  echo ""
  echo "Bridge slaves:"
  bridge link show 2>/dev/null | sed 's/^/  /'
  echo ""
  echo "Ping test:"
  ping -c 2 "$GATEWAY_IP" 2>&1 | tail -3 | sed 's/^/  /'
}

# ─── Banner ───
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN} Bridge Setup${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo "  Host:        $HOST_NAME"
echo "  Host IP:     $HOST_IP"
echo "  NIC:         $PHYS_IFACE ($HOST_MAC)"
echo "  Bridge:      $BRIDGE_IFACE"
echo "  Old conn:    $OLD_CONN"
echo "  Gateway:     $GATEWAY_IP"
echo ""

# ─── Pre-flight Checks ───
log_info "Pre-flight checks..."

# Check if bridge already exists
if nmcli connection show "$BRIDGE_IFACE" > /dev/null 2>&1; then
  log_warn "Bridge '$BRIDGE_IFACE' already exists!"
  read -p "Delete and recreate? (yes/no): " confirm
  if [[ "$confirm" == "yes" ]]; then
    sudo nmcli connection down "$BRIDGE_IFACE" 2>/dev/null || true
    sudo nmcli connection delete "$BRIDGE_IFACE" 2>/dev/null || true
    sudo nmcli connection delete "bridge-slave-$PHYS_IFACE" 2>/dev/null || true
    log_ok "Existing bridge removed"
  else
    log_info "Exiting — no changes made"
    exit 0
  fi
fi

# Check old connection exists
if ! nmcli connection show "$OLD_CONN" > /dev/null 2>&1; then
  log_error "Old connection '$OLD_CONN' not found!"
  log_info "Available connections:"
  nmcli -t -f NAME,DEVICE connection show | sed 's/^/  /'
  exit 1
fi
log_ok "Old connection '$OLD_CONN' found"

# Check physical NIC exists
if ! ip link show "$PHYS_IFACE" > /dev/null 2>&1; then
  log_error "Physical NIC '$PHYS_IFACE' not found!"
  exit 1
fi
log_ok "Physical NIC '$PHYS_IFACE' found"

# Verify MAC matches
ACTUAL_MAC=$(cat /sys/class/net/$PHYS_IFACE/address)
if [[ "$ACTUAL_MAC" != "$HOST_MAC" ]]; then
  log_warn "MAC mismatch!"
  log_info "  .env:     $HOST_MAC"
  log_info "  Actual:   $ACTUAL_MAC"
  read -p "Use actual MAC? (yes/no): " confirm
  if [[ "$confirm" == "yes" ]]; then
    HOST_MAC="$ACTUAL_MAC"
    sed -i "s|^HOST_MAC=.*|HOST_MAC=\"$ACTUAL_MAC\"|" .env
    log_ok "MAC updated in .env"
  fi
fi

echo ""
read -p "⚠️  SSH will disconnect. Continue? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || {
  log_info "Cancelled"
  exit 0
}

# ─── Step 1: Disable autoconnect on old connection ───
echo ""
log_info "[1/5] Disabling autoconnect on old connection..."
sudo nmcli connection modify "$OLD_CONN" connection.autoconnect no
log_ok "Old connection autoconnect disabled"

# ─── Step 2: Create bridge with cloned MAC ───
echo ""
log_info "[2/5] Creating bridge with cloned MAC..."
sudo nmcli connection add type bridge ifname "$BRIDGE_IFACE" con-name "$BRIDGE_IFACE" \
  ipv4.method auto \
  ipv6.method ignore \
  ethernet.cloned-mac-address "$HOST_MAC"
log_ok "Bridge '$BRIDGE_IFACE' created"

# ─── Step 3: Create bridge slave ───
echo ""
log_info "[3/5] Creating bridge slave..."
sudo nmcli connection add type bridge-slave ifname "$PHYS_IFACE" master "$BRIDGE_IFACE"
log_ok "Bridge slave created"

# ─── Step 4: Activate ───
echo ""
log_info "[4/5] Activating bridge..."
sudo nmcli connection down "$OLD_CONN" 2>/dev/null || true
sudo nmcli connection up "bridge-slave-$PHYS_IFACE"
sudo nmcli connection up "$BRIDGE_IFACE"
log_ok "Activated — waiting for DHCP..."
sleep 20

# ─── Step 5: Verify & Fix if needed ───
echo ""
log_info "[5/5] Verifying..."

if ip -br a show "$BRIDGE_IFACE" 2>/dev/null | grep -q "$HOST_IP"; then
  # ─── SUCCESS PATH ───
  log_ok "Bridge UP with correct IP: $HOST_IP"

  set_persistence
  enable_libvirtd
  verify_bridge

  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}✅ Bridge setup complete${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo ""
  echo "Next steps:"
  echo "  1. Verify:  bash setup.sh verify"
  echo "  2. Create VMs:  sudo bash setup.sh all-vms"
  echo "  3. Enable autostart:  (auto-set by VM create)"
  echo ""
  exit 0

else
  # ─── KERNEL-LEVEL FIX PATH ───
  log_warn "No IP detected — attempting kernel-level fix..."
  echo ""

  log_info "Detaching $PHYS_IFACE from NetworkManager..."
  sudo nmcli device set "$PHYS_IFACE" managed no
  sleep 2

  log_info "Force-attaching at kernel level..."
  sudo ip link set "$PHYS_IFACE" master "$BRIDGE_IFACE"
  sudo ip link set "$BRIDGE_IFACE" up
  sudo ip link set "$PHYS_IFACE" up
  sleep 5

  log_info "Re-attaching to NetworkManager..."
  sudo nmcli device set "$PHYS_IFACE" managed yes
  sleep 3

  log_info "Activating bridge slave..."
  sudo nmcli connection up "bridge-slave-$PHYS_IFACE" 2>/dev/null || true
  sleep 5

  log_info "Restarting bridge connection..."
  sudo nmcli connection down "$BRIDGE_IFACE" 2>/dev/null || true
  sudo nmcli connection up "$BRIDGE_IFACE"
  sleep 15

  # ⭐ CRITICAL FIX: Set persistence even in kernel-fix path
  set_persistence
  enable_libvirtd
  verify_bridge

  # Final check
  echo ""
  if ip -br a show "$BRIDGE_IFACE" 2>/dev/null | grep -q "$HOST_IP"; then
    log_ok "IP acquired after kernel fix: $HOST_IP"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Bridge setup complete (via kernel fix)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Reboot test:  sudo reboot"
    echo "  2. Verify after reboot:  ip -br a show $BRIDGE_IFACE"
    echo "  3. Create VMs:  sudo bash setup.sh all-vms"
    echo ""
    exit 0
  else
    log_error "Bridge still has no IP!"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check logs:  sudo journalctl -u NetworkManager -n 30"
    echo "  2. Check NIC:   ip link show $PHYS_IFACE"
    echo "  3. Check cable: cat /sys/class/net/$PHYS_IFACE/carrier"
    echo "  4. Manual DHCP: sudo dhclient $BRIDGE_IFACE"
    echo ""
    exit 1
  fi
fi