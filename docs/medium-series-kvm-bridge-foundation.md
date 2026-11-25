# Build a KVM Virtualization Cluster Foundation (4-Part Series)

*Tags: Linux, KVM, Virtualization, DevOps, Networking*

| Part | Title |
|---|---|
| 1 | Why a Bridge, and How to Configure Your Host |
| 2 | The Setup Workflow and the Bridge, Step by Step |
| 3 | Provisioning VMs, Verifying and Recovering |
| 4 | Security, the Roadmap to HA, and a Network-Change Runbook |

---

# PART 1 of 4: Why a Bridge, and How to Configure Your Host

*Series: Build a KVM Virtualization Cluster Foundation*

## The problem

If you run KVM on several machines, VMs on different hosts can't talk to each other. Libvirt's default network (`virbr0`) is NAT. VMs can reach the internet, but other hosts can't reach them.

I wanted something repeatable: clone a repo, fill in one config file, run one command, and get a working host. I called the project **kvm-ha-cluster**.

It gives you:

- One-command host setup
- A per-host `.env` file, so one repo serves every machine
- Cloud-init VM provisioning with static IPs
- Reboot persistence and a rollback path

**Scope note:** this series covers the **networking and provisioning foundation** of an HA cluster. Shared storage, Pacemaker and fencing come later (Part 4).

## Why a bridge, not NAT

| Feature | NAT (`virbr0`) | Linux bridge |
|---|:-:|:-:|
| Host → VM | ✅ | ✅ |
| VM → VM (same host) | ✅ | ✅ |
| **VM → VM (other host)** | ❌ | ✅ |
| Precondition for live migration | ❌ | ✅ |

With a bridge, each VM is a normal peer on your LAN. The bridge forwards frames by MAC address at layer 2, so there's no routing:

```
VM1 → br0 (Host-B) → physical switch → br0 (Host-C) → VM3
```

On each host, the physical NIC becomes a *slave* of `br0`, and VMs attach through `vnet` tap devices. The host's own IP moves from the NIC to `br0`.

## Quick start

```bash
git clone <your-repo-url> && cd kvm-ha-cluster
cp .env.example .env && chmod 600 .env
nano .env                       # your host's real values
sudo bash setup.sh full         # install KVM + build the bridge
sudo bash setup.sh all-vms      # create the VMs from .env
bash setup.sh verify            # ping + SSH matrix
```

Plan for about 15 minutes, mostly package installs. Run the bridge step from a **local console**, because it switches your host's network connection.

## What's in the repo

```
kvm-ha-cluster/
├── setup.sh                  # master dispatcher
├── .env.example              # config template (committed)
├── scripts/
│   ├── env-autofill.sh       # detect host values → .env
│   ├── 01-host-prep.sh       # KVM stack + cloud image
│   ├── 02-bridge-setup.sh    # NetworkManager bridge
│   ├── 03-vm-create.sh       # disk + cloud-init + virt-install
│   ├── 04-verify.sh          # ping / SSH matrix
│   └── 05-rollback.sh        # restore original network
└── cloud-init/               # user-data + network-config templates
```

## Configuration: one `.env` per host

`.env` is gitignored, so real IPs, MACs and passwords never reach GitHub.

| Group | Variables |
|---|---|
| Host identity | `HOST_NAME`, `HOST_IP`, `HOST_MAC`, `PHYS_IFACE`, `OLD_CONN`, `BRIDGE_IFACE` |
| Network | `GATEWAY_IP`, `NETWORK_CIDR`, `DNS_SERVERS` |
| VM defaults | `VM_USER`, `VM_PASSWORD`, `VM_VCPU`, `VM_RAM_MB`, `VM_DISK_SIZE` |
| Image | `CLOUD_IMAGE_URL`, `CLOUD_IMAGE_PATH`, `IMAGE_DIR` |
| This host's VMs | `VMS="vm5:10.0.0.205 vm6:10.0.0.206"` |
| Cluster reference | `CLUSTER_HOSTS`, `CLUSTER_VMS` (used by verify) |

Find your host's values:

```bash
ip -br a                                   # IP and interface
cat /sys/class/net/<nic>/address           # MAC
nmcli -t -f NAME,DEVICE connection show    # NetworkManager connection name
ip route | grep default                    # gateway
```

Or let the helper detect and fill most of them:

```bash
bash scripts/env-autofill.sh
```

**Next, Part 2:** the setup workflow and the bridge script in detail.

---

# PART 2 of 4: The Setup Workflow and the Bridge, Step by Step

*Recap: Part 1 explained why a bridge beats NAT and how to configure `.env`.*

## The commands

| Command | What it does |
|---|---|
| `setup.sh full` | `prep` + `bridge` |
| `setup.sh prep` | install KVM, libvirt and cloud-image tools; download the image |
| `setup.sh bridge` | build `br0` |
| `setup.sh vm <name> <ip>` | create one VM |
| `setup.sh all-vms` | create every VM in `VMS` |
| `setup.sh verify` | connectivity tests |
| `setup.sh rollback` | restore the original network |
| `setup.sh status` | show bridge, NIC and VM state |

The flow is: `.env` → `prep` → check KVM works → `bridge` → check `br0` has an IP → `all-vms` → `verify`.

## Host prep

`prep` installs `qemu-kvm`, `libvirt`, `virtinst` and `cloud-image-utils`, verifies that hardware virtualization is available, enables `libvirtd`, adds your user to the `libvirt` and `kvm` groups, and downloads the Ubuntu 24.04 cloud image. If KVM isn't available, enable VT-x or AMD-V in the BIOS.

## Adding another host

This is where the per-host `.env` pays off. To add Host-D, clone the same repo, copy the template, change only the host-specific lines, and run the same commands:

```bash
HOST_NAME="host-d"
HOST_IP="10.0.0.13"
VMS="vm7:10.0.0.207 vm8:10.0.0.208"
CLUSTER_HOSTS="10.0.0.11:host-b 10.0.0.12:host-c"
```

```bash
sudo bash setup.sh full && sudo bash setup.sh all-vms && bash setup.sh verify
```

Same code, different config.

## The bridge script

This is the most delicate part. It does the following:

1. **Pre-flight checks:** the old connection exists, the NIC exists and the MAC matches `.env`.
2. **Disable autoconnect** on the old connection.
3. **Create `br0` with a cloned MAC:**
   ```bash
   nmcli connection add type bridge ifname br0 con-name br0 \
     ipv4.method auto ipv6.method ignore \
     ethernet.cloned-mac-address "$HOST_MAC"
   ```
4. **Create the bridge slave** for the physical NIC.
5. **Activate in order:** old connection down, slave up, bridge up.
6. **Verify the IP,** then set autoconnect and enable `libvirtd`.

### Why clone the MAC?

A bridge normally gets a random MAC. DHCP servers and reservations key on MAC, so your host would get a different address, or none. Cloning the NIC's MAC keeps the host's identity unchanged.

### When `br0` gets no IP

If `br0` sits at `connecting (getting IP configuration)`, the script falls back to attaching the NIC at the kernel level:

```bash
sudo nmcli device set <nic> managed no
sudo ip link set <nic> master br0
sudo ip link set br0 up && sudo ip link set <nic> up
sudo nmcli device set <nic> managed yes
sudo nmcli connection up bridge-slave-<nic>
```

### Safety rule for this step

Run it from a **local console**, not over SSH. The connection switches mid-script, and a dropped SSH session can leave the host half-configured. If anything goes wrong, `setup.sh rollback` restores the original connection (Part 3).

**Next, Part 3:** provisioning VMs, verifying, troubleshooting and recovery.

---

# PART 3 of 4: Provisioning VMs, Verifying and Recovering

*Recap: Part 2 built a persistent `br0` bridge on each host.*

## How a VM gets created

```
Ubuntu cloud image → qcow2 overlay disk → cloud-init seed ISO → virt-install → VM ready
```

- A **copy-on-write disk** sits on top of the shared base image, so a 20 GB VM only uses space as it grows.
- **Cloud-init** sets the hostname, the user and a static IP, and installs `qemu-guest-agent` and SSH.
- `virt-install --import` boots the VM on `br0` with a virtio NIC.
- **Autostart** is enabled, so the VM comes back after a host reboot.

Defaults: 2 vCPU, 4 GB RAM, 20 GB disk, Ubuntu 24.04. All are overridable in `.env`.

```bash
sudo bash setup.sh vm my-vm 10.0.0.207    # one VM
sudo bash setup.sh all-vms                # every VM in VMS
```

### The network config

```yaml
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses: [10.0.0.207/24]
    routes:
      - to: default
        via: 10.0.0.1
    nameservers:
      addresses: [8.8.8.8, 8.8.4.4]
```

`enp1s0` is the NIC name the guest gets on a standard virtio setup. If your VM comes up with no network, check the interface name first.

## Verifying

```bash
bash setup.sh verify
```

It prints bridge state and VMs, then runs a ping matrix (gateway, other hosts, local and remote VMs), an internet check and an SSH check on every VM.

| From \ To | Host | VM (local) | VM (remote) |
|---|:-:|:-:|:-:|
| Host | ✅ | ✅ | ✅ |
| VM | ✅ | ✅ | ✅ |

The **remote VM** column is the real test that the bridge works across hosts. The SSH check uses key-based login, so distribute keys to the VMs first (see Part 4), or it will report failures even when the VMs are fine.

Manual checks:

```bash
ip -br a show br0
bridge link show
sudo virsh list --all
```

## Troubleshooting

| Symptom | Likely fix |
|---|---|
| `master waiting for slaves` | `nmcli con up bridge-slave-<nic>` |
| `br0` has no IP | confirm the cloned MAC; use the kernel-level fix |
| `br0` down, no carrier | NIC not enslaved: `ip link set <nic> master br0` |
| No IP after reboot | check `nmcli con show br0 \| grep auto` |
| Intermittent ping | `sysctl -w net.bridge.bridge-nf-call-iptables=0` |
| Ping works, SSH fails | `virsh console <vm>` then `systemctl start ssh` |
| VM not visible on LAN | `bridge link show` to see if the vnet is attached |

Useful diagnostics:

```bash
bridge fdb show br br0
nmcli device status
sudo virsh domifaddr <vm>
sudo journalctl -u NetworkManager --since "5 min ago"
sudo tail -50 /var/log/libvirt/qemu/<vm>.log
```

## Recovery

```bash
# Undo the bridge and restore the original connection
sudo bash setup.sh rollback

# Stuck VM
sudo virsh destroy <vm> && sudo virsh start <vm>

# Corrupted VM: rebuild it
sudo virsh undefine <vm> --remove-all-storage
sudo bash setup.sh vm <vm> <ip>
```

**Before a rollback, shut down your VMs.** Deleting `br0` disconnects any VM still attached to it.

For a **full host reset**, roll back the network, undefine all VMs with `--remove-all-storage`, then remove leftover `*.qcow2` and `*-seed.iso` files in `/var/lib/libvirt/images`.

**Next, Part 4:** security, the roadmap to real HA, and a runbook for changing a VM's IP.

---

# PART 4 of 4: Security, the Roadmap to HA, and a Network-Change Runbook

*Recap: Parts 1–3 gave you a working bridged KVM host with VMs you can verify and recover.*

## Security habits

| File | In git? | Contains |
|---|:-:|---|
| `.env.example` | ✅ | placeholders only |
| `.env` | ❌ gitignored | real IPs, MACs, passwords |
| scripts and templates | ✅ | code |

Before every commit:

```bash
git check-ignore -v .env                 # confirm it's ignored
git diff --cached --name-only | grep -E "^\.env$" && echo "❌ staged" || echo "✅ safe"
```

Further steps:

- **Change the default `VM_PASSWORD`.** Better, use **SSH keys**:
  ```bash
  ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
  for entry in $VMS; do ssh-copy-id "${VM_USER}@${entry%%:*}"; done
  ```
  Then disable password login on the VMs.
- **Back up `.env` outside git,** for example in a password manager.
- **Ignore `.env` backups too.** Add `.env.*` to `.gitignore`, with `!.env.example` as an exception. Otherwise a file like `.env.backup.<date>` can slip into a commit.
- Remember that bridged VMs are **regular LAN hosts**. Anything with a weak password is reachable by everything else on the network.

## Roadmap: from networking to real HA

This repo is **Layer 1**:

| Layer | Component | Why |
|---|---|---|
| 1 ✅ | KVM + bridge + VMs | cross-host connectivity |
| 2 | Shared storage (NFS / DRBD / Ceph) | hosts must see the same VM disks |
| 3 | Corosync + Pacemaker | cluster membership and resource management |
| 4 | VM failover | restart VMs on a surviving host |
| 5 | Prometheus + Grafana | observability |

Two items to add before failover:

- **Fencing (STONITH).** It guarantees a failed node is really off before its VMs start elsewhere. Without it, two hosts could write to the same disk and corrupt it.
- **Backups.** HA protects against host failure, not against deletion or corruption.

The storage choice also matters: VM disks that depend on a node-local base image can't be live-migrated, so decide on shared storage before Pacemaker.

## Bonus runbook: change a VM's IP safely

1. **Record** the MAC, current IP and Netplan file:
   ```bash
   ip neigh; cat /sys/class/net/enp1s0/address
   ls -l /etc/netplan/; sudo netplan get
   ```
2. **Back up** the file you will edit:
   ```bash
   sudo cp /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.backup
   ```
3. **Edit** with the approved IP, prefix, gateway and DNS. Don't reuse example addresses.
4. **Validate and apply:** `sudo netplan generate`, then `sudo netplan try` for remote changes (it rolls back if you lose connectivity), or `netplan apply`.
5. **Verify in this order:**
   ```bash
   ip addr show enp1s0          # interface up, correct IP
   ip route                     # correct default route
   ping -c 2 <gateway>          # gateway
   ping -c 2 8.8.8.8            # external IP
   ping -c 2 google.com         # DNS
   ```
   If the gateway fails, check ARP, VLAN and IP/MAC binding. If `8.8.8.8` fails, check routing, firewall and NAT. If only the name fails, check DNS.
6. **Roll back** by restoring the *same file* you backed up, then `netplan generate && netplan apply`.

> `netplan apply` isn't the end of the change. It's finished only when IP, route, gateway, external connectivity and DNS are all verified.

## Wrap-up

In about 15 minutes per host you get a KVM host with a persistent, MAC-cloned bridge, cloud-init VMs on your real LAN, cross-host connectivity you can verify with one command, and a rollback path. Shared storage, a cluster manager and fencing are the next steps toward real failover.

*Tags: Linux, KVM, Virtualization, DevOps, Networking*
