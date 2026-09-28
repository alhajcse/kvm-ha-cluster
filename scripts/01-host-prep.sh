#!/bin/bash
# ============================================================
# 01 — Host Preparation
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

echo "[1/6] System update..."
sudo apt update
sudo apt upgrade -y

echo "[2/6] Installing KVM stack..."
sudo apt install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients \
  virtinst cloud-image-utils bridge-utils

echo "[3/6] Verifying KVM..."
if kvm-ok 2>/dev/null | grep -q "can be used"; then
  echo "✅ KVM OK"
else
  echo "❌ KVM not available — enable VT-x/AMD-V in BIOS"
  exit 1
fi

echo "[4/6] Enabling libvirtd..."
sudo systemctl enable --now libvirtd
sudo systemctl is-active libvirtd

echo "[5/6] Adding $USER to libvirt/kvm groups..."
sudo usermod -aG libvirt,kvm "$USER"

echo "[6/6] Cloud image..."
if [ -f "$CLOUD_IMAGE_PATH" ]; then
  echo "✅ Already exists"
else
  sudo wget -O "$CLOUD_IMAGE_PATH" "$CLOUD_IMAGE_URL"
fi
sudo qemu-img info "$CLOUD_IMAGE_PATH" | head -5

echo ""
echo "✅ Host prep complete — log out and back in for group changes"
