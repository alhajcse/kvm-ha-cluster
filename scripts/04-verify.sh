#!/bin/bash
# ============================================================
# 04 — Verification
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

echo "=============================================="
echo "=== Verification — $(hostname) ==="
echo "=============================================="

echo ""
echo "=== Bridge ==="
ip -br a show "$BRIDGE_IFACE" 2>/dev/null || echo "❌ missing"
bridge link show 2>/dev/null

echo ""
echo "=== NM Devices ==="
nmcli device status | grep -E "$BRIDGE_IFACE|$PHYS_IFACE"

echo ""
echo "=== VMs ==="
sudo virsh list --all

echo ""
echo "=== Ping Matrix ==="

ping_test() {
  local ip="$1" name="$2"
  if ping -c 1 -W 2 "$ip" > /dev/null 2>&1; then
    printf "  %-15s %-20s ✅\n" "$ip" "$name"
  else
    printf "  %-15s %-20s ❌\n" "$ip" "$name"
  fi
}

ping_test "$GATEWAY_IP" "Gateway"
for entry in $CLUSTER_HOSTS; do
  ping_test "${entry%%:*}" "host:${entry##*:}"
done
for entry in $VMS $CLUSTER_VMS; do
  ping_test "${entry%%:*}" "vm:${entry##*:}"
done

echo ""
echo "=== Internet ==="
ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1 && echo "  ✅" || echo "  ❌"

echo ""
echo "=== SSH to All VMs ==="
for entry in $VMS $CLUSTER_VMS; do
  ip="${entry%%:*}"
  name="${entry##*:}"
  result=$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
    -o BatchMode=yes "${VM_USER}@${ip}" hostname 2>/dev/null)
  if [[ -n "$result" ]]; then
    echo "  ✅ ${ip} → ${result}"
  else
    echo "  ❌ ${ip} → SSH failed"
  fi
done

echo ""
echo "=============================================="
