# lab-opskit

Homelab ops kit — lightweight bash tooling for Proxmox on `192.168.1.10`.

## create-lxc.sh

Generic Proxmox LXC creator for `192.168.1.0/24`.

Features:
- Prompt for **VMID** (`>=100`, Proxmox requirement) and **IP** (`192.168.1.X` / `X` → `192.168.1.X/24` gw `192.168.1.1`)
- **Privileged toggle** (`--privileged`/`--unprivileged`, default prompt `Y` for LLM perf)
- **Root password** prompt (hidden, `chpasswd` via `pct push`)
- **AMD iGPU + NVIDIA eGPU** passthrough (`both`/`amd`/`nvidia`/`none`): `/dev/dri`, `/dev/kfd` (511/234/238 compat), `/dev/nvidia*`, `nvidia-uvm`, `nvidia-caps`
- Validates `pct` exists, backs up `/etc/pve/lxc/<VMID>.conf`, uses `lxc.apparmor.profile: unconfined` + `cgroup2` allows

### Usage

Interactive (on Proxmox host as root):
```bash
./create-lxc.sh
```

Non-interactive:
```bash
./create-lxc.sh --vmid 200 --ip 50 --privileged --gpu both
./create-lxc.sh --vmid 201 --ip 192.168.1.51/24 --unprivileged --gpu nvidia --cores 8 --memory 32768
```

All IPs forced to `192.168.1.0/24`. See `./create-lxc.sh --help`.

### Verify inside LXC
```bash
pct exec <vmid> -- bash -c 'ls -l /dev/dri /dev/kfd /dev/nvidia* 2>&1; rocminfo | head; nvidia-smi'
```

