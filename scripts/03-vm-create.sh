#!/bin/bash
# ============================================================
# 03 — VM Creator
# Usage: 03-vm-create.sh <vm-name> <vm-ip> [hostname]
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

VM_NAME="$1"
VM_IP="$2"
VM_HOSTNAME="${3:-$VM_NAME}"

if [[ -z "$VM_NAME" || -z "$VM_IP" ]]; then
  echo "Usage: $0 <vm-name> <vm-ip> [hostname]"
  exit 1
fi

VM_DISK="$IMAGE_DIR/${VM_NAME}.qcow2"
VM_SEED="$IMAGE_DIR/${VM_NAME}-seed.iso"

echo "=== Creating VM: $VM_NAME ($VM_IP) ==="

[[ -f "$CLOUD_IMAGE_PATH" ]] || { echo "❌ Cloud image missing"; exit 1; }
sudo virsh list --all | grep -q "$VM_NAME" && { echo "❌ VM exists"; exit 1; }

# 1. Disk
echo "[1/4] Creating disk..."
sudo qemu-img create -f qcow2 -F qcow2 \
  -b "$CLOUD_IMAGE_PATH" "$VM_DISK" "$VM_DISK_SIZE"

# 2. Cloud-init
echo "[2/4] Creating cloud-init files..."
cat > /tmp/user-data-${VM_NAME}.yaml <<EOF
#cloud-config
hostname: ${VM_HOSTNAME}
fqdn: ${VM_HOSTNAME}.local
manage_etc_hosts: true

users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false

chpasswd:
  list: |
    ${VM_USER}:${VM_PASSWORD}
  expire: false

ssh_pwauth: true

package_update: true
packages:
  - openssh-server
  - curl
  - vim
  - net-tools
  - qemu-guest-agent

runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now ssh
EOF

cat > /tmp/meta-data-${VM_NAME}.yaml <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_HOSTNAME}
EOF

cat > /tmp/network-config-${VM_NAME}.yaml <<EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses:
      - ${VM_IP}/${NETWORK_CIDR}
    routes:
      - to: default
        via: ${GATEWAY_IP}
    nameservers:
      addresses: [${DNS_SERVERS}]
EOF

# 3. Seed ISO
echo "[3/4] Creating seed ISO..."
sudo cloud-localds \
  --network-config=/tmp/network-config-${VM_NAME}.yaml \
  "$VM_SEED" \
  /tmp/user-data-${VM_NAME}.yaml \
  /tmp/meta-data-${VM_NAME}.yaml

# 4. Create VM
echo "[4/4] Creating VM..."
sudo virt-install \
  --name "$VM_NAME" \
  --memory "$VM_RAM_MB" --vcpus "$VM_VCPU" \
  --disk ${VM_DISK},bus=virtio \
  --disk ${VM_SEED},device=cdrom \
  --import \
  --os-variant ubuntu24.04 \
  --network bridge="$BRIDGE_IFACE",model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole

echo ""
echo "✅ VM $VM_NAME created. Waiting 90s for boot..."
sleep 90

sudo virsh list
echo ""
ping -c 3 -W 2 "$VM_IP" && echo "✅ $VM_IP OK" || echo "⚠️ Retry in 30s"
