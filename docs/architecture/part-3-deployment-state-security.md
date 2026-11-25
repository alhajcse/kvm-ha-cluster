# KVM HA Cluster — Architecture, Part 3 of 4: Deployment, State and Security

*Where things live, what state exists, and the security posture.*

| | |
|---|---|
| **Version** | 1.0 (describes `main` @ `d273b5e`) |
| **Date** | 2026-11-25 |
| **Series** | KVM HA Cluster — Architecture & Design, Part 3 of 4 |
| **Related** | `docs/TECHNICAL-AUDIT.md` (findings referenced as F-nn) |

← [Part 2](part-2-network-and-processes.md) · [Part 4](part-4-target-state-and-quality.md) → · [Index](README.md)

---

## 6. Deployment view

### 6.1 On each host

| Item | Location |
|---|---|
| Repo and `.env` | operator's chosen directory (`.env` mode 0600) |
| Base image | `/var/lib/libvirt/images/ubuntu-24.04-cloudimg-amd64.img` |
| VM disks and seeds | `/var/lib/libvirt/images/<vm>.qcow2`, `<vm>-seed.iso` |
| Domain XML | `/etc/libvirt/qemu/<vm>.xml` |
| Autostart links | `/etc/libvirt/qemu/autostart/<vm>.xml` |
| NM profiles | `/etc/NetworkManager/system-connections/` (`br0`, `bridge-slave-<NIC>`) |
| QEMU logs | `/var/log/libvirt/qemu/<vm>.log` |

### 6.2 Packages
`qemu-kvm libvirt-daemon-system libvirt-clients virtinst cloud-image-utils bridge-utils` (+ `cpu-checker` is needed for `kvm-ok` and is not installed today, F-02).

### 6.3 Runtime lifecycle
`setup.sh` is run by an operator. No daemon belongs to this project. At runtime the system is just NetworkManager, libvirtd and the VMs, so the scripts have no availability impact once they finish.

---

## 7. Data and state

| State | Where | Owner | Notes |
|---|---|---|---|
| Host/VM config | `.env` | operator | untracked; back up separately |
| Network profiles | NetworkManager | NM | persistent across reboot |
| VM definitions | libvirt | libvirtd | `virsh dumpxml` to export |
| VM disks | qcow2 overlays | local disk | **depend on the base image**; losing or changing it breaks every VM on the host |
| Credentials | `.env`, `/tmp` user-data, seed ISO | — | see §8 |

There is no database and no central state. Hosts do not know about each other except through `CLUSTER_*` lists used for ping tests.

---

## 8. Security architecture

| Concern | Current design | Gap (audit ref) |
|---|---|---|
| Secrets in VCS | `.env` ignored, placeholders in example | `.env.backup.*` not ignored (F-10) |
| Secret handling at runtime | password interpolated into cloud-init | plaintext in `/tmp` and seed ISO (F-04) |
| VM authentication | password + `NOPASSWD` sudo | weak default, no key injection (F-05) |
| Network trust | VMs directly on the LAN | no segmentation or host firewall |
| Privileges | scripts mix `sudo` internally and run-as-root | choose one model |
| Supply chain | image from `current/` URL as root | no checksum or pin (F-03) |
| Config as code | `.env` is `source`d | any writer of `.env` gets code execution as the invoking user |

**Target posture:** SSH-key-only VMs, locked passwords, temp files in a `0700` directory with cleanup, verified pinned base image, optional VLAN or firewall for VM traffic.

---

← [Part 2](part-2-network-and-processes.md) · [Part 4](part-4-target-state-and-quality.md) → · [Index](README.md)
