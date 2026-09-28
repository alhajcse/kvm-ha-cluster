# KVM HA Cluster — Pull & Run

Two-command setup for a KVM host with bridge networking.

## 🚀 Quick Start (Host C Example)

```bash
# 1. Clone
git clone https://github.com/YOUR_USERNAME/kvm-ha-cluster.git
cd kvm-ha-cluster

# 2. Configure for THIS host
cp .env.example .env
nano .env
#   HOST_NAME="host-c"
#   HOST_IP="10.0.0.12"
#   HOST_MAC="aa:bb:cc:dd:ee:03"
#   PHYS_IFACE="enp3s0"
#   OLD_CONN="Wired connection 1"
#   VMS="vm5:10.0.0.205 vm6:10.0.0.206"

# 3. Run everything
sudo bash setup.sh full

# 4. Create VMs
sudo bash setup.sh all-vms

# 5. Verify
bash setup.sh verify
exit
