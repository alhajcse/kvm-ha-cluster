#!/bin/bash
# ============================================================
# 02 — Bridge Setup  (⚠️ LOCAL CONSOLE — SSH will disconnect)
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

echo "=== Bridge Setup ==="
echo "Host: $HOST_NAME"
echo "NIC:  $PHYS_IFACE ($HOST_MAC)"
echo "Bridge: $BRIDGE_IFACE"
echo ""

read -p "⚠️  SSH will disconnect. Continue? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || exit 0

echo "[1/5] Disable autoconnect on old connection..."
sudo nmcli connection modify "$OLD_CONN" connection.autoconnect no

echo "[2/5] Create bridge with cloned MAC..."
sudo nmcli connection add type bridge ifname "$BRIDGE_IFACE" con-name "$BRIDGE_IFACE" \
  ipv4.method auto ipv6.method ignore \
  ethernet.cloned-mac-address "$HOST_MAC"

echo "[3/5] Create bridge slave..."
sudo nmcli connection add type bridge-slave ifname "$PHYS_IFACE" master "$BRIDGE_IFACE"

echo "[4/5] Activate..."
sudo nmcli connection down "$OLD_CONN" 2>/dev/null || true
sudo nmcli connection up "bridge-slave-$PHYS_IFACE"
sudo nmcli connection up "$BRIDGE_IFACE"
sleep 20

echo "[5/5] Verify..."
if ip -br a show "$BRIDGE_IFACE" | grep -q "$HOST_IP"; then
  echo "✅ Bridge UP with correct IP"

  sudo nmcli connection modify "$BRIDGE_IFACE" connection.autoconnect yes
  sudo nmcli connection modify "$BRIDGE_IFACE" connection.autoconnect-slaves 1
  sudo nmcli connection modify "bridge-slave-$PHYS_IFACE" connection.autoconnect yes

  echo "✅ Persistence set"
  ip -br a show "$BRIDGE_IFACE"
  bridge link show
else
  echo "⚠️  No IP — kernel-level fix..."
  sudo nmcli device set "$PHYS_IFACE" managed no
  sleep 2
  sudo ip link set "$PHYS_IFACE" master "$BRIDGE_IFACE"
  sudo ip link set "$BRIDGE_IFACE" up
  sudo ip link set "$PHYS_IFACE" up
  sleep 5
  sudo nmcli device set "$PHYS_IFACE" managed yes
  sleep 3
  sudo nmcli connection up "bridge-slave-$PHYS_IFACE"
  sleep 10
  ip -br a show "$BRIDGE_IFACE"
  ping -c 2 "$GATEWAY_IP"
fi

echo ""
echo "✅ Bridge setup complete"
