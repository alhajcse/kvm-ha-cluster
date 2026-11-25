# KVM HA Cluster — Technical Audit & System Documentation

| | |
|---|---|
| **Audit date** | 2026-11-25 |
| **Scope** | Whole repository at `main` @ `d273b5e` (6 commits, 2026-09-28 → 2026-10-08) |
| **Method** | Static read of every tracked file (`setup.sh`, 6 scripts, 2 cloud-init templates, `.env.example`, `.gitignore`, `README.md`), `bash -n` syntax check, and small probes of specific claims. **Nothing was executed against real hosts**: no bridge was created and no VM was provisioned. Findings marked *(runtime)* need a lab run to confirm. |
| **Tooling gap** | `shellcheck` is not installed here. Run it in CI (see §7). |

---

## 1. Executive summary

The repo is a small, readable Bash toolkit. It turns an Ubuntu host with one NIC into a KVM host with a Linux bridge (`br0`), and it provisions cloud-init Ubuntu VMs on that bridge with static IPs. It only covers **Layer 1** of the roadmap in README §14. There is no shared storage, cluster manager, fencing or failover yet, so despite the name it is **not an HA cluster today**.

The structure is sound: one dispatcher, numbered scripts, a per-host `.env`, and a rollback script. The README is unusually thorough. The main risks are in operational safety and security hygiene, not in code structure.

| Severity | Count | Headline |
|---|:-:|---|
| 🔴 High | 5 | Bridge setup can strand a remote host with no auto-rollback. `kvm-ok` is never installed. Partial image download is treated as valid. Plaintext password in world-readable `/tmp`. Default weak password with SSH password auth open on the LAN. |
| 🟠 Medium | 9 | Substring matching bugs, STP delay likely causing the "race condition", rollback ignores VMs, fragile NIC auto-detection, dead and drifting templates, and more. |
| 🟡 Low | 10 | Doc/code drift, missing files, no CI, and similar. |

**Verdict:** fine for a lab where someone sits at the console. **Not ready** to run unattended or on hosts that matter until the 🔴 items are fixed.

---

## 2. What the system does

### 2.1 Components

| File | Role |
|---|---|
| `setup.sh` | Dispatcher. Loads and validates `.env`, then runs `full│prep│bridge│vm│all-vms│verify│rollback│status│help`. |
| `scripts/env-autofill.sh` | Creates `.env` from `.env.example` and fills in detected NIC, IP, MAC, gateway, CIDR and NM connection name. **Not wired into `setup.sh`.** |
| `scripts/01-host-prep.sh` | `apt upgrade`, installs the KVM and libvirt stack, checks KVM, enables `libvirtd`, adds the user to groups, downloads the Ubuntu 24.04 cloud image. |
| `scripts/02-bridge-setup.sh` | Replaces the NM wired connection with `br0` (cloned MAC, DHCP) plus a bridge-slave. Has a kernel-level fallback. Sets persistence and enables `libvirtd`. |
| `scripts/03-vm-create.sh` | Creates a qcow2 overlay disk, a cloud-init seed ISO and the domain, then sets autostart and pings the VM. |
| `scripts/04-verify.sh` | Prints bridge state, VMs and a ping/SSH matrix across `VMS`, `CLUSTER_HOSTS` and `CLUSTER_VMS`. |
| `scripts/05-rollback.sh` | Deletes `br0` and the slave, then re-enables and activates the original connection. |
| `cloud-init/*.template.yaml` | Templates with `${VAR}` placeholders. **Unused**, see F-12. |
| `.env.example` | Host config template (identity, network, VM defaults, image, VM list, cluster reference). |

### 2.2 Execution flow

```
 .env.example ──env-autofill.sh──▶ .env (0600, gitignored)
                                      │ sourced by every script
 setup.sh full ─▶ 01-host-prep ─▶ 02-bridge-setup      (needs local console)
 setup.sh all-vms ─▶ 03-vm-create × N   (sequential, ≥90 s each)
 setup.sh verify  ─▶ 04-verify
 setup.sh rollback─▶ 05-rollback
```

### 2.3 Target topology

```
 LAN 10.0.0.0/24 ── gateway 10.0.0.1
   ├─ host-a .10 ─ br0 ─ vm1, vm2        (hosts and VMs share one L2 segment)
   ├─ host-b .11 ─ br0 ─ vm3, vm4
   └─ host-c .12 ─ br0 ─ vm5, vm6
```

Each VM is a full LAN peer. That is correct for cross-host VM traffic and is a precondition for live migration. It also means every VM is as exposed as any other LAN machine (see F-04, F-05).

### 2.4 Configuration contract (`.env`)

`.env` is `source`d as shell by every script. `setup.sh` enforces 12 required variables: `HOST_NAME HOST_IP HOST_MAC PHYS_IFACE OLD_CONN GATEWAY_IP NETWORK_CIDR BRIDGE_IFACE VM_USER VM_PASSWORD CLOUD_IMAGE_PATH IMAGE_DIR`.

Variables used but **not validated** (F-14): `DNS_SERVERS`, `VM_VCPU`, `VM_RAM_MB`, `VM_DISK_SIZE`, `CLOUD_IMAGE_URL`.

Variables that are **list-typed strings** (`name:ip` pairs): `VMS`, `CLUSTER_HOSTS`, `CLUSTER_VMS`. They are split with `${entry%%:*}` and `${entry##*:}`, so there is no validation of IP format or duplicates.

---

## 3. Findings

IDs are stable so they can be turned into backlog items. File references use `path:line`.

### 🔴 High

**F-01 · Bridge setup can strand a remote host, with no automatic rollback** — `scripts/02-bridge-setup.sh:136-170, 245-255`
The script tells you SSH will drop, then brings down `OLD_CONN` (`:166`) before the new path is proven. If it is run over SSH, the SIGHUP from the dying session can kill the script mid-way, because there is no `nohup`, `systemd-run` or `setsid`. On the failure branch (`:245`) it exits 1 and leaves `OLD_CONN` with `autoconnect no` (set at `:145`). A reboot then boots with a half-configured bridge, or none, and the host stays unreachable.
*Fix:* run in a detached unit (`systemd-run --unit=br-setup`). Add a watchdog that restores `OLD_CONN` if the gateway is not pingable within N seconds. Call `05-rollback.sh` automatically on the failure branch. Refuse to run when `$SSH_CONNECTION` is set unless `--i-have-console` is passed.

**F-02 · `kvm-ok` is never installed, so host prep fails on a fresh host** *(runtime)* — `scripts/01-host-prep.sh:16-26`
`kvm-ok` ships in `cpu-checker`, which is not in the install list (grep confirms the package is never mentioned). With `2>/dev/null | grep -q`, the "command not found" error is hidden. The script then prints "KVM not available — enable VT-x/AMD-V in BIOS" and exits 1, which is a misleading diagnosis.
*Fix:* add `cpu-checker` to the install list, or test `[[ -c /dev/kvm ]]` plus `grep -Ec '(vmx|svm)' /proc/cpuinfo`.

**F-03 · A failed or partial image download is treated as valid on re-run** — `scripts/01-host-prep.sh:36-41`
`wget -O "$CLOUD_IMAGE_PATH"` writes straight to the final path. An interrupted download leaves a truncated file, and the next run prints "✅ Already exists". Every VM overlay then uses a corrupt backing file. There is also no checksum check (Ubuntu publishes `SHA256SUMS`), and the URL points at `current/`, so the base image silently changes between hosts.
*Fix:* download to `*.part`, verify against `SHA256SUMS`, then `mv`. Pin a dated release directory, or record the hash in `.env`.

**F-04 · Plaintext VM password lands in world-readable, predictable `/tmp` files and is never deleted** — `scripts/03-vm-create.sh:36-93`
`/tmp/user-data-<vm>.yaml` is written with the default umask (typically 0644) and contains `${VM_USER}:${VM_PASSWORD}`. The path is predictable, which allows a symlink race. The files are never removed. The seed ISO in `IMAGE_DIR` also contains the password and stays attached to the VM as a CD-ROM (`:101`).
*Fix:* use `mktemp -d` with `umask 077` and `trap 'rm -rf "$tmp"' EXIT`. Prefer `ssh_authorized_keys` and a locked password (F-05). Eject the seed after first boot (`virsh change-media --eject`).

**F-05 · Weak default credential, password SSH and passwordless sudo on a flat LAN** — `.env.example:47-48`, `scripts/03-vm-create.sh:44-53`
`VM_PASSWORD="changeme"` is accepted by the validator, which only checks for non-empty. Every VM gets `ssh_pwauth: true` and `NOPASSWD:ALL`. With bridged networking, any host on the LAN can log in as a sudoer. The README password section (§13.3) recommends keys, but the provisioning path does not support them.
*Fix:* add `VM_SSH_PUBKEY` to `.env` and inject it with `ssh_authorized_keys`. Default to `ssh_pwauth: false`. Reject `changeme` and short passwords in `setup.sh`.

### 🟠 Medium

**F-06 · The "race condition" is probably STP forwarding delay, not carrier loss** *(runtime)* — `scripts/02-bridge-setup.sh:151, 170`; README §8.3
NM creates bridges with STP enabled and a 15 s forward delay by default. A new port spends about 30 s in listening and learning, so DHCP on `br0` fails while a fixed `sleep 20` is still running. The existing kernel-level workaround may only succeed because it takes longer.
*Fix to test:* add `bridge.stp no` (or `bridge.forward-delay 0`) to the `nmcli add` and poll for the IP in a loop with a timeout instead of `sleep 20`. If this holds, the whole fallback branch can be removed.

**F-07 · Substring matching produces false positives** — `03-vm-create.sh:27`, `02-bridge-setup.sh:176, 231`
`virsh list --all | grep -q "$VM_NAME"` matches `vm10` when creating `vm1` (verified), and the script then aborts with "VM exists". `grep -q "$HOST_IP"` against `ip -br a` matches `10.0.0.1` inside `10.0.0.12`, and the dots are regex wildcards (verified).
*Fix:* `virsh dominfo "$VM_NAME" &>/dev/null`, and `grep -qwF "$HOST_IP/"`.

**F-08 · Rollback ignores running VMs and requires root implicitly** — `scripts/05-rollback.sh`
It deletes `br0` while VMs are still attached, so their `vnet*` taps are orphaned and every VM loses its network. There is no warning or confirmation. Unlike `02`, it has no internal `sudo`, so `bash scripts/05-rollback.sh` as a normal user fails part-way under `set -e`. It also prints no recovery hint if `OLD_CONN` fails to come up.
*Fix:* list attached VMs and require confirmation, add a `[[ $EUID -eq 0 ]]` guard, and take a `nmcli connection show` snapshot before changes so rollback can restore exactly.

**F-09 · Interface auto-detection is fragile and fails silently** — `scripts/env-autofill.sh:81-102`
- `grep -v "lo\|virbr\|vnet\|br0\|docker"` treats `lo` as a substring, so it drops any interface with "lo" in its name (e.g. `wlo1`). It still picks down links, Wi-Fi, `tailscale0` and bonds, and just takes the first.
- It excludes `br0`, so on a host that is already bridged the IP is empty.
- Empty values are written into `.env` by `sed` without a check.
- Under `set -e`, a failing `grep` (e.g. no default route) exits with no message.
- A connection name containing `&` or `|` breaks the `sed` replacement.
*Fix:* derive the NIC from `ip -o route get 1.1.1.1` (`dev` field) and verify that each value is non-empty before writing. Escape `sed` replacements or write `.env` with `printf`.

**F-10 · `.env.backup.*` files are not gitignored** — `.gitignore:4-6`, `env-autofill.sh:45`
`--force` creates `.env.backup.<timestamp>` (verified with `git check-ignore`: not ignored). The patterns `.env`, `.env.local` and `*.env` do not match it, so the file holding `VM_PASSWORD` can be committed with `git add .`.
*Fix:* add `.env.*` and `!.env.example`.

**F-11 · `--force` regeneration resets the host-specific lists to example data** — `env-autofill.sh:69`
It copies the template over `.env`, which restores `VMS="vm5:10.0.0.205 vm6:10.0.0.206"`. Because `all-vms` has no confirmation, a user who forgets to edit it will create VMs with another host's identities and IPs. The same applies on first run.
*Fix:* ship `VMS=""` in the template (or require it to be set), and carry over existing `VMS`, `CLUSTER_*` and `VM_*` values on `--force`.

**F-12 · `cloud-init/*.template.yaml` are dead code and have drifted from the inline copies** — `03-vm-create.sh:36-85`
The script generates its own YAML with heredocs. The templates lack `fqdn`, `shell` and the `curl vim net-tools` packages and `package_update`. Two sources of truth will diverge further.
*Fix:* render the templates with `envsubst` and delete the heredocs, or delete the templates.

**F-13 · Guest NIC name `enp1s0` is hard-coded, so networking silently fails if it differs** *(runtime)* — `03-vm-create.sh:76`, `cloud-init/network-config.template.yaml:3`
It holds only if the machine type is q35 and the NIC is the first PCIe slot. On `i440fx` it is `ens3`. The VM then boots with no network and the script just prints "⚠️ Retry in 30s".
*Fix:* match by MAC (`match: {macaddress: …}` plus `set-name`) and pass `--network …,mac=<derived>`. A MAC derived from the IP also gives stable DHCP and ARP behaviour across re-creation.

**F-14 · Validation gaps** — `setup.sh:43-48`
`VM_VCPU`, `VM_RAM_MB`, `VM_DISK_SIZE`, `DNS_SERVERS` and `CLOUD_IMAGE_URL` are not required, so `vm` or `all-vms` fail deep inside `qemu-img` or `virt-install` with a cryptic error. IPs and the `name:ip` format are also unchecked. There is no duplicate-IP detection (`arping -D`) before a VM is created.

### 🟡 Low

| ID | Finding | Where |
|---|---|---|
| F-15 | `apt upgrade -y` in a "prep" step can pull kernel/libvirt upgrades on a production host with no prompt. Use `apt install` only. `bridge-utils` is legacy and unused. | `01-host-prep.sh:11-18` |
| F-16 | Fixed `sleep 90` before autostart. If the run is interrupted, autostart is never set. Set autostart immediately after `virt-install` and poll for the guest agent or ping with a timeout. | `03-vm-create.sh:111-116` |
| F-17 | `04-verify.sh` uses `BatchMode=yes` with password-only VMs, so every SSH check shows ❌ unless keys were distributed. `StrictHostKeyChecking=no` disables host-key checking. It does not check autostart, libvirtd state, MAC clone or persistence, which README promises ("persistence verified"). | `04-verify.sh:56-57` |
| F-18 | Dead references in `env-autofill.sh`: `PEER_SSH_USER` (sed matches nothing, not in `.env.example`, and `$USER` is `root` under sudo), `CLOUD_IMAGE_PEERS`, and `scripts/verify-env.sh`, which does not exist. Examples use `10.70.16.x` while the rest uses `10.0.0.x`. | `env-autofill.sh:39,128,194,201` |
| F-19 | `setup.sh` with no argument prints help (not `full`) and needs a valid `.env` even to show help. The 3rd arg `[hostname]` of `03-vm-create.sh` is not reachable via `setup.sh vm`. | `setup.sh:30-36,96,186` |
| F-20 | README drift: it lists `LICENSE` and `docs/README-full.md` (neither exists). The §5.2 variable table omits `VM_VCPU`, `VM_RAM_MB`, `VM_DISK_SIZE`, `CLOUD_IMAGE_*` and `IMAGE_DIR`. `env-autofill.sh` is not mentioned. The clone URL is still `YOUR_USERNAME`. | README §4, §5.2, §3 |
| F-21 | README overstates: "Suitable for HA" and "VM live migration ✅" describe only a network precondition. Live migration also needs shared storage and a matching CPU model (`--cpu host-model` or a baseline), and HA needs the cluster manager and fencing, all of which are roadmap items (§14). Overlay disks that depend on a node-local base image are not migratable as built. | README §1, §14 |
| F-22 | `--os-variant ubuntu24.04` fails on hosts with an old `osinfo-db` (e.g. 22.04). Fixed `/tmp/.env.before` in autofill is another predictable temp path. | `03-vm-create.sh:103`, `env-autofill.sh:118` |
| F-23 | `qemu-img create` silently overwrites an existing `${VM}.qcow2`. A leftover disk from an undefined domain is destroyed without warning. | `03-vm-create.sh:31` |
| F-24 | No CI, lint, tests or license. 6 commits, no tags or releases. Logic that is easy to unit-test (list parsing, env validation) is untested. | repo |

### What is done well

- `set -e`, `SCRIPT_DIR` resolution and `set -a; source .env` are used consistently.
- Pre-flight checks in `02`: old connection exists, NIC exists, MAC verified, confirmation prompts.
- MAC cloning is the correct approach for DHCP-reserved hosts, and the README explains why.
- `.env` is gitignored and `env-autofill.sh` sets `0600` and verifies the ignore.
- Rollback exists and is documented. The README has solid troubleshooting and a VM network-change runbook (§15).
- All scripts pass `bash -n`.

---

## 4. Security assessment

| Area | Status | Notes |
|---|---|---|
| Secrets in repo | ✅ | Only placeholders (`changeme`, `aa:bb:…`, RFC1918 `10.0.0.x`). No real values found. |
| Secrets at rest on host | 🔴 | F-04: `/tmp` files and the seed ISO hold the password. |
| Authentication on VMs | 🔴 | F-05: password SSH, weak default, `NOPASSWD:ALL`. |
| Config injection | 🟠 | `.env` is executed as shell. Fine for a root-owned file, but anything that can write it gets root. Keep it `0600` and root- or owner-owned. `sed` replacements are unescaped (F-09). |
| Supply chain | 🟠 | F-03: unverified image from a floating URL, downloaded as root. |
| Network exposure | 🟠 | Bridged VMs sit directly on the LAN with no host firewall or VLAN isolation. If Docker is installed, its `FORWARD` policy can also drop bridged traffic. |
| Privilege use | 🟡 | Mix of `sudo bash setup.sh` and in-script `sudo`. Choose one model, root-only with a guard, and drop the redundant `sudo`. |

---

## 5. Reliability & operations

- **Idempotence:** `01` is mostly idempotent apart from F-03. `02` offers delete and recreate. `03` is not resumable: it fails on a leftover VM or silently overwrites a disk (F-07, F-23).
- **Failure handling:** `set -e` only. There are no `trap` handlers, no cleanup of temp files, and no rollback on failure.
- **Observability:** console output only. There is no log file despite `*.log` being gitignored, and no timestamps.
- **Scale:** `all-vms` is sequential at ≥ 90 s per VM, so 6 VMs take about 10 minutes of pure sleep.
- **Reboot behaviour:** claimed but never tested by the tooling. The kernel-fix path itself asks for a manual reboot test (`02:240`).

---

## 6. Gap analysis against the stated goal ("HA cluster")

| Capability | In repo | Needed for HA |
|---|:-:|---|
| Cross-host L2 networking | ✅ | Bridge on every host |
| VM provisioning | ✅ | Reproducible, key-based |
| Shared storage (NFS/DRBD/Ceph) | ❌ | Required for failover and live migration |
| Cluster membership (Corosync) | ❌ | ≥ 3 nodes or a quorum device |
| Resource manager (Pacemaker) | ❌ | Manages VM resources |
| **Fencing / STONITH** | ❌ | **Mandatory** to avoid two hosts running the same VM disk (data corruption) |
| Monitoring and alerting | ❌ | Prometheus/Grafana (roadmap L5) |
| Backup / restore | ❌ | Not on roadmap |
| Host/VM config as code | ◐ | Imperative scripts, not idempotent desired state |

Two roadmap points are worth fixing now. The README estimates a 1 hr for Corosync + Pacemaker and 30 min for NFS, which is optimistic once fencing is included. Fencing and backup are missing from the roadmap entirely, and fencing is the item that decides whether HA is safe.

---

## 7. Remediation plan

| Priority | Item | Findings | Effort |
|:-:|---|---|:-:|
| P0 | Make `02-bridge-setup` safe remotely: detached run, watchdog, auto-rollback, STP fix | F-01, F-06 | M |
| P0 | Fix `cpu-checker` / KVM check; safe, verified image download | F-02, F-03 | S |
| P0 | Secure cloud-init: `mktemp` + `trap`, SSH keys, no password SSH, reject weak default | F-04, F-05 | M |
| P1 | Exact-match fixes (`virsh dominfo`, `grep -wF`) | F-07 | S |
| P1 | Rollback guard and confirmation, VM-aware | F-08 | S |
| P1 | Harden `env-autofill` (route-based NIC detect, non-empty checks, preserve lists on `--force`); `.gitignore` `.env.*` | F-09, F-10, F-11 | M |
| P1 | One cloud-init source (`envsubst`), MAC-matched netplan | F-12, F-13 | M |
| P2 | Validate all `.env` vars and IP formats; duplicate-IP check | F-14 | S |
| P2 | Poll instead of `sleep`; set autostart early; richer `verify` | F-16, F-17 | S |
| P2 | Clean dead refs; sync README (structure, variables, HA claims); add `LICENSE` | F-18–F-21 | S |
| P3 | CI: `shellcheck`, `shfmt`, `bats` tests for parsing and validation | F-24 | M |
| P3 | Roadmap: add fencing, backup and a test-failover plan | §6 | — |

Suggested CI baseline:

```bash
shellcheck -x setup.sh scripts/*.sh
shfmt -d -i 2 setup.sh scripts/*.sh
bash -n setup.sh scripts/*.sh
```

---

## 8. Open questions

1. Is the target OS strictly Ubuntu 24.04 on hosts too? That affects `osinfo-db`, `netplan` route syntax and the `libvirtd` vs modular daemons.
2. Will hosts always have a DHCP reservation for the cloned MAC? If not, `br0` should be static, not `ipv4.method auto`.
3. Is a 2-host or 3-host cluster the target? Two nodes need a quorum device or an external fence.
4. Is the LAN trusted? That determines how strictly F-05 must be fixed.
5. Which shared storage is intended (NFS vs DRBD vs Ceph)? It decides whether overlay disks on a local base image can remain.

---

*Prepared from static analysis of the repository at commit `d273b5e`. Findings marked (runtime) should be confirmed on a lab host before being treated as defects.*
