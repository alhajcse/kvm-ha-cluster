#!/bin/bash
# ============================================================
# KVM HA Cluster — Master Setup Script
# ============================================================
# Usage:
#   sudo bash setup.sh              # Full setup (prep + bridge)
#   sudo bash setup.sh prep         # Only host preparation
#   sudo bash setup.sh bridge       # Only bridge setup
#   sudo bash setup.sh vm <name> <ip>   # Create one VM
#   sudo bash setup.sh all-vms      # Create all VMs in .env
#   sudo bash setup.sh verify       # Run verification
#   sudo bash setup.sh rollback     # Rollback bridge
#   sudo bash setup.sh status       # Show current state
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---- Load .env ----
if [[ ! -f .env ]]; then
  echo -e "${RED}❌ .env not found${NC}"
  echo "   Copy from template:"
  echo "   cp .env.example .env"
  echo "   nano .env"
  exit 1
fi

set -a
source .env
set +a

# ---- Validate required vars ----
REQUIRED_VARS=(
  HOST_NAME HOST_IP HOST_MAC PHYS_IFACE OLD_CONN
  GATEWAY_IP NETWORK_CIDR BRIDGE_IFACE
  VM_USER VM_PASSWORD
  CLOUD_IMAGE_PATH IMAGE_DIR
)

MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  [[ -z "${!var}" ]] && MISSING+=("$var")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo -e "${RED}❌ Missing variables in .env:${NC}"
  printf '   - %s\n' "${MISSING[@]}"
  exit 1
fi

# ---- Banner ----
print_banner() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║       KVM HA Cluster — Setup Script                  ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BLUE}Host:${NC}      $HOST_NAME"
  echo -e "  ${BLUE}IP:${NC}        $HOST_IP/$NETWORK_CIDR"
  echo -e "  ${BLUE}MAC:${NC}       $HOST_MAC"
  echo -e "  ${BLUE}NIC:${NC}       $PHYS_IFACE"
  echo -e "  ${BLUE}Bridge:${NC}    $BRIDGE_IFACE"
  echo -e "  ${BLUE}Old conn:${NC}  $OLD_CONN"
  echo -e "  ${BLUE}VMs:${NC}       ${VMS:-none}"
  echo ""
}

# ---- Commands ----
cmd_prep() {
  echo -e "${GREEN}[HOST PREP]${NC} Installing KVM stack..."
  bash scripts/01-host-prep.sh
}

cmd_bridge() {
  echo -e "${GREEN}[BRIDGE]${NC} Setting up bridge..."
  bash scripts/02-bridge-setup.sh
}

cmd_vm() {
  local name="$1"
  local ip="$2"
  if [[ -z "$name" || -z "$ip" ]]; then
    echo -e "${RED}Usage: setup.sh vm <name> <ip>${NC}"
    exit 1
  fi
  bash scripts/03-vm-create.sh "$name" "$ip"
}

cmd_all_vms() {
  if [[ -z "$VMS" ]]; then
    echo -e "${YELLOW}⚠️  No VMs defined in .env (VMS=\"...\")${NC}"
    exit 0
  fi
  for entry in $VMS; do
    local name="${entry%%:*}"
    local ip="${entry##*:}"
    echo ""
    echo -e "${GREEN}═══ Creating VM: $name ($ip) ═══${NC}"
    bash scripts/03-vm-create.sh "$name" "$ip"
  done
}

cmd_verify() {
  bash scripts/04-verify.sh
}

cmd_rollback() {
  bash scripts/05-rollback.sh
}

cmd_status() {
  echo -e "${CYAN}═══ Current Host State ═══${NC}"
  echo ""
  echo -e "${BLUE}Hostname:${NC} $(hostname)"
  echo ""
  echo -e "${BLUE}Bridge ($BRIDGE_IFACE):${NC}"
  ip -br a show "$BRIDGE_IFACE" 2>/dev/null || echo "  ❌ not present"
  echo ""
  echo -e "${BLUE}Physical ($PHYS_IFACE):${NC}"
  ip -br a show "$PHYS_IFACE" 2>/dev/null
  echo ""
  echo -e "${BLUE}NM Devices:${NC}"
  nmcli device status | grep -E "$BRIDGE_IFACE|$PHYS_IFACE" || true
  echo ""
  echo -e "${BLUE}VMs:${NC}"
  sudo virsh list --all 2>/dev/null || echo "  libvirt not available"
  echo ""
}

cmd_full() {
  print_banner
  echo -e "${YELLOW}⚠️  Full setup will run:${NC}"
  echo "   1. Host preparation (packages, KVM, cloud image)"
  echo "   2. Bridge setup (SSH will disconnect — local console needed)"
  echo ""
  read -p "Continue? (yes/no): " confirm
  [[ "$confirm" == "yes" ]] || exit 0

  cmd_prep
  cmd_bridge

  echo ""
  echo -e "${GREEN}✅ Full setup complete${NC}"
  echo ""
  echo "Next: create VMs with:"
  echo "   sudo bash setup.sh all-vms"
}

cmd_help() {
  print_banner
  cat << EOF
${CYAN}Commands:${NC}

  ${GREEN}full${NC}              Complete setup (host prep + bridge)
  ${GREEN}prep${NC}              Install KVM stack + cloud image
  ${GREEN}bridge${NC}            Setup bridge network
  ${GREEN}vm <name> <ip>${NC}    Create single VM
  ${GREEN}all-vms${NC}           Create all VMs from .env VMS list
  ${GREEN}verify${NC}            Run all verification tests
  ${GREEN}rollback${NC}          Remove bridge, restore original network
  ${GREEN}status${NC}            Show current host state
  ${GREEN}help${NC}              Show this help

${CYAN}Examples:${NC}

  sudo bash setup.sh full
  sudo bash setup.sh all-vms
  sudo bash setup.sh vm my-vm 10.0.0.207
  bash setup.sh verify
  sudo bash setup.sh rollback

EOF
}

# ---- Dispatch ----
CMD="${1:-help}"
shift || true

case "$CMD" in
  full)      cmd_full ;;
  prep)      cmd_prep ;;
  bridge)    cmd_bridge ;;
  vm)        cmd_vm "$@" ;;
  all-vms)   cmd_all_vms ;;
  verify)    cmd_verify ;;
  rollback)  cmd_rollback ;;
  status)    cmd_status ;;
  help|"")   cmd_help ;;
  *)
    echo -e "${RED}❌ Unknown command: $CMD${NC}"
    cmd_help
    exit 1
    ;;
esac
