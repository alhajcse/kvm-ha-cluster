#!/bin/bash
# ============================================================
# Smart .env Setup
# Strategy:
#   1. If .env exists → skip (unless --force)
#   2. If .env missing → copy from .env.example
#   3. Auto-detect host values
#   4. Fill detected values into .env
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Colors
GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

FORCE="${1:-}"

# ═══════════════════════════════════════════
# GUARD: .env exists?
# ═══════════════════════════════════════════
if [[ -f .env && "$FORCE" != "--force" ]]; then
  echo -e "${YELLOW}⚠️  .env already exists — skipping${NC}"
  echo ""
  echo "Current configuration:"
  ls -la .env
  echo ""
  set -a; source .env 2>/dev/null; set +a
  echo "  HOST_NAME: $HOST_NAME"
  echo "  HOST_IP:   $HOST_IP"
  echo "  HOST_MAC:  $HOST_MAC"
  echo "  VMS:       $VMS"
  echo ""
  echo "Options:"
  echo "  • Edit:              nano .env"
  echo "  • Verify:            bash scripts/verify-env.sh"
  echo "  • Force regenerate:  bash scripts/env-autofill.sh --force"
  echo ""
  exit 0
fi

if [[ -f .env && "$FORCE" == "--force" ]]; then
  BACKUP=".env.backup.$(date +%Y%m%d-%H%M%S)"
  echo -e "${YELLOW}⚠️  --force: backing up → $BACKUP${NC}"
  cp .env "$BACKUP"
  echo ""
fi

# ═══════════════════════════════════════════
# STEP 1: Template থেকে copy
# ═══════════════════════════════════════════
echo -e "${CYAN}━━━ STEP 1: Template ━━━${NC}"

if [[ ! -f .env.example ]]; then
  echo -e "${RED}❌ .env.example missing${NC}"
  echo ""
  echo "Expected location: $(pwd)/.env.example"
  echo ""
  echo "Please pull from git:"
  echo "  git pull origin main"
  exit 1
fi

echo -e "  ✅ Found: .env.example ($(stat -c%s .env.example) bytes)"
echo ""
echo -e "${BLUE}  Copying .env.example → .env${NC}"
cp .env.example .env
chmod 600 .env
echo -e "  ${GREEN}✅ .env created${NC}"
echo ""

# ═══════════════════════════════════════════
# STEP 2: Auto-detect host values
# ═══════════════════════════════════════════
echo -e "${CYAN}━━━ STEP 2: Detect Host Values ━━━${NC}"
echo ""

# --- Interface ---
PHYS=$(ip -br link | grep -v "lo\|virbr\|vnet\|br0\|docker" | awk '{print $1}' | head -1)
[[ -z "$PHYS" ]] && { echo -e "${RED}❌ No physical NIC${NC}"; exit 1; }
echo -e "  ${BLUE}Interface:${NC}   $PHYS"

# --- IP ---
IP=$(ip -br a show "$PHYS" | awk '{print $3}' | cut -d/ -f1)
echo -e "  ${BLUE}IP:${NC}          $IP"

# --- MAC ---
MAC=$(cat /sys/class/net/$PHYS/address)
echo -e "  ${BLUE}MAC:${NC}         $MAC"

# --- Gateway ---
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
echo -e "  ${BLUE}Gateway:${NC}     $GATEWAY"

# --- CIDR ---
CIDR=$(ip -br a show "$PHYS" | grep -oP '/\K[0-9]+')
echo -e "  ${BLUE}CIDR:${NC}        /$CIDR"

# --- NM Connection ---
OLD_CONN=$(nmcli -t -f NAME,DEVICE connection show | grep "$PHYS" | cut -d: -f1 | head -1)
echo -e "  ${BLUE}Old conn:${NC}    $OLD_CONN"

# --- Hostname ---
HOSTNAME_RAW=$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
echo -e "  ${BLUE}Hostname:${NC}    $HOSTNAME_RAW"

echo ""

# ═══════════════════════════════════════════
# STEP 3: .env এর values replace করো
# ═══════════════════════════════════════════
echo -e "${CYAN}━━━ STEP 3: Fill Values ━━━${NC}"
echo ""

# Backup original for diff
cp .env /tmp/.env.before

# Replace values (using `|` as delimiter for URLs/MACs with special chars)
sed -i "s|^HOST_NAME=.*|HOST_NAME=\"$HOSTNAME_RAW\"|"       .env
sed -i "s|^HOST_IP=.*|HOST_IP=\"$IP\"|"                     .env
sed -i "s|^HOST_MAC=.*|HOST_MAC=\"$MAC\"|"                  .env
sed -i "s|^PHYS_IFACE=.*|PHYS_IFACE=\"$PHYS\"|"             .env
sed -i "s|^OLD_CONN=.*|OLD_CONN=\"$OLD_CONN\"|"             .env
sed -i "s|^GATEWAY_IP=.*|GATEWAY_IP=\"$GATEWAY\"|"          .env
sed -i "s|^NETWORK_CIDR=.*|NETWORK_CIDR=\"$CIDR\"|"         .env
sed -i "s|^PEER_SSH_USER=.*|PEER_SSH_USER=\"$USER\"|"       .env

echo "  ✅ Values updated:"
echo "     HOST_NAME=$HOSTNAME_RAW"
echo "     HOST_IP=$IP"
echo "     HOST_MAC=$MAC"
echo "     PHYS_IFACE=$PHYS"
echo "     OLD_CONN=$OLD_CONN"
echo "     GATEWAY_IP=$GATEWAY"
echo "     NETWORK_CIDR=$CIDR"
echo ""

# ═══════════════════════════════════════════
# STEP 4: Verify
# ═══════════════════════════════════════════
echo -e "${CYAN}━━━ STEP 4: Verify ━━━${NC}"
echo ""

# Syntax check
if bash -n .env 2>/dev/null; then
  echo -e "  ${GREEN}✅ Syntax valid${NC}"
else
  echo -e "  ${RED}❌ Syntax error in .env${NC}"
  exit 1
fi

# File permissions
PERMS=$(stat -c%a .env)
if [[ "$PERMS" == "600" ]]; then
  echo -e "  ${GREEN}✅ Permissions 600${NC}"
else
  echo -e "  ${YELLOW}⚠️  Permissions $PERMS — fixing${NC}"
  chmod 600 .env
fi

# Git ignore check
if git check-ignore -q .env 2>/dev/null; then
  echo -e "  ${GREEN}✅ Gitignored${NC}"
else
  echo -e "  ${YELLOW}⚠️  Not gitignored — adding${NC}"
  echo ".env" >> .gitignore
fi

echo ""

# ═══════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ .env setup complete${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

# Show diff from template
echo "Changes from template:"
diff /tmp/.env.before .env 2>/dev/null | grep "^>" | sed 's/^> /  /' || echo "  (no changes)"
rm -f /tmp/.env.before

echo ""
echo -e "${BLUE}Next steps:${NC}"
echo ""
echo "  1. Add VMs for this host:"
echo "     nano .env"
echo "     VMS=\"vm-01:10.70.16.201 vm-02:10.70.16.202\""
echo ""
echo "  2. Add cloud image peers (optional):"
echo "     CLOUD_IMAGE_PEERS=\"10.70.16.184:host-b 10.70.16.188:host-c\""
echo ""
echo "  3. Add cluster reference (optional):"
echo "     CLUSTER_HOSTS=\"10.70.16.184:host-b\""
echo "     CLUSTER_VMS=\"10.70.16.203:vm-03\""
echo ""
echo "  4. Verify:"
echo "     bash scripts/verify-env.sh"
echo ""
echo "  5. Run setup:"
echo "     sudo bash setup.sh full"
echo ""
