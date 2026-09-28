#!/bin/bash
# ============================================================
# 05 — Bridge Rollback
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

echo "=== Bridge Rollback ==="

nmcli connection down "$BRIDGE_IFACE" 2>/dev/null || true
nmcli connection delete "$BRIDGE_IFACE" 2>/dev/null || true
nmcli connection delete "bridge-slave-$PHYS_IFACE" 2>/dev/null || true

ip link set "$PHYS_IFACE" nomaster 2>/dev/null || true
ip link delete "$BRIDGE_IFACE" 2>/dev/null || true

nmcli device set "$PHYS_IFACE" managed yes

nmcli connection modify "$OLD_CONN" connection.autoconnect yes
nmcli connection up "$OLD_CONN"

sleep 8
ip -br a show "$PHYS_IFACE"
ping -c 2 "$GATEWAY_IP"
