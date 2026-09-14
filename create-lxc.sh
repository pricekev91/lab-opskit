#!/usr/bin/env bash
set -euo pipefail

# create-lxc.sh — Generic Proxmox LXC creator for homelab 192.168.1.0/24
# Supports: privileged toggle (for LLM perf), VMID/IP prompts, AMD iGPU + NVIDIA eGPU passthrough
# Run on Proxmox host (192.168.1.10). Template defaults to Ubuntu 24.04.

BRIDGE="vmbr0"
GATEWAY="192.168.1.1"
DEFAULT_TEMPLATE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
DEFAULT_STORAGE="RaidZ1-6TB"
DEFAULT_ROOTFS="32"
DEFAULT_CORES="4"
DEFAULT_MEMORY_MB="4096"
DEFAULT_MEMORY_GB="4"
DEFAULT_HOSTNAME_PREFIX="test"

usage() {
  cat <<'EOF'
Usage: ./create-lxc.sh [options]

Interactive (default): prompts for VMID, IP, privileged, root password.
Non-interactive: pass flags.

Options:
  --vmid ID                 LXC ID (>=100, Proxmox requires 100+)
  --ip IP                   192.168.1.X or 192.168.1.X/24 or just X (e.g. 50 -> 192.168.1.50/24)
  --hostname NAME           Container hostname (default: test-<vmid>)
  --privileged / --unprivileged  privileged=1 for performance/LLM (default: prompt, privileged=yes)
  --password PASS           root password (otherwise prompted securely)
  --gpu MODE                amd|nvidia|both|none|auto (default: auto=both if devices exist)
  --cores N                 CPU cores (default: 4 — options 4/8)
  --memory GB|MB            RAM — GB choices 2/4/6/8 (default: 4GB). Accepts 4, 4GB, or 4096
  --storage POOL            Proxmox storage (default: RaidZ1-6TB — like hlh-ai-engine)
  --rootfs GB               Rootfs size in GB (default: 32G — options 25/50/75 or any GB like 50)
  --template TPL            Template (default: local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst)
  --bridge BR               Bridge (default: vmbr0)
  -h, --help                Show this help

Examples:
  ./create-lxc.sh
  ./create-lxc.sh --vmid 200 --ip 50 --privileged --gpu both
  ./create-lxc.sh --vmid 201 --ip 192.168.1.51/24 --unprivileged --gpu nvidia

IP handling: All IPs are forced into 192.168.1.0/24. Input 50, 192.168.1.50, or 192.168.1.50/24 all -> 192.168.1.50/24 gw 192.168.1.1
EOF
}

# --- defaults from flags ---
VMID=""
IP_INPUT=""
HOSTNAME=""
PRIVILEGED_FLAG="" # 0 or 1 if set
PASSWORD=""
GPU_MODE="auto"
CORES="$DEFAULT_CORES"
MEMORY="$DEFAULT_MEMORY_MB"
ROOTFS="$DEFAULT_ROOTFS"
STORAGE="$DEFAULT_STORAGE"
TEMPLATE="$DEFAULT_TEMPLATE"
BRIDGE_OPT="$BRIDGE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2 ;;
    --ip) IP_INPUT="$2"; shift 2 ;;
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --privileged) PRIVILEGED_FLAG="1"; shift ;;
    --unprivileged) PRIVILEGED_FLAG="0"; shift ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --gpu) GPU_MODE="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --rootfs) ROOTFS="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --bridge) BRIDGE_OPT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# --- helpers ---
is_valid_vmid() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 100 && $1 <= 999999 ))
}

normalize_ip() {
  local inp="$1"
  local octet=""
  # strip /24 if present
  inp="${inp%%/24}"
  inp="${inp%%/32}"
  if [[ "$inp" =~ ^[0-9]+$ ]]; then
    # just last octet
    octet="$inp"
  elif [[ "$inp" =~ ^192\.168\.1\.([0-9]{1,3})$ ]]; then
    octet="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  if ! [[ "$octet" =~ ^[0-9]+$ ]] || (( octet < 1 || octet > 254 )); then
    return 1
  fi
  # reject .0, .255, .1 gateway
  if (( octet == 0 || octet == 255 )); then return 1; fi
  echo "192.168.1.${octet}/24"
}

normalize_memory_to_mb() {
  local inp="$1"
  inp="$(echo "$inp" | tr '[:upper:]' '[:lower:]' | xargs)"
  inp="${inp//gb/}"; inp="${inp//g/}"; inp="${inp//mb/}"; inp="${inp//m/}"
  inp="$(echo "$inp" | xargs)"
  if ! [[ "$inp" =~ ^[0-9]+$ ]]; then return 1; fi
  # if value <=64 assume GB, else MB — but prefer explicit: 4/8/12/16/32 are GB, >100 are MB
  if (( inp <= 64 )); then
    echo $(( inp * 1024 ))
  else
    echo "$inp"
  fi
}

need_pct() {
  if ! command -v pct >/dev/null 2>&1; then
    echo "ERROR: 'pct' not found. Run this script on the Proxmox host (192.168.1.10)." >&2
    exit 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: Run as root (or via sudo) on Proxmox host." >&2
    exit 1
  fi
}

prompt_vmid() {
  while true; do
    if [[ -n "$VMID" ]]; then
      if ! is_valid_vmid "$VMID"; then
        echo "ERROR: VMID must be >=100 (got: $VMID)" >&2
        VMID=""
        continue
      fi
      if pct status "$VMID" >/dev/null 2>&1; then
        echo "WARNING: VMID $VMID already exists!" >&2
        pct status "$VMID" 2>&1 | sed 's/^/  /' >&2 || true
        echo "Config: /etc/pve/lxc/${VMID}.conf" >&2
        cat "/etc/pve/lxc/${VMID}.conf" 2>&1 | head -n 20 | sed 's/^/  /' >&2 || true
        echo "" >&2
        # Non-interactive with all flags — require explicit DELETE_IT via prompt still, so fail unless interactive
        if [[ -n "${IP_INPUT:-}" && -n "${PRIVILEGED_FLAG:-}" && -n "${PASSWORD:-}" ]]; then
          echo "Non-interactive mode: VMID $VMID exists. Re-run interactively and type DELETE_IT to nuke, or choose another VMID." >&2
          exit 1
        fi
        read -rp "VMID $VMID exists — type DELETE_IT to nuke/redeploy, or press Enter to choose another VMID: " ans
        if [[ "$ans" == "DELETE_IT" ]]; then
          echo "Destroying existing LXC $VMID ..."
          pct stop "$VMID" >/dev/null 2>&1 || true
          # pct destroy vs delete — try both
          if ! pct destroy "$VMID" 2>&1; then
            pct delete "$VMID" 2>&1 || true
          fi
          echo "Destroyed $VMID — will recreate."
          break
        else
          echo "Not deleting — choose another VMID." >&2
          VMID=""
          continue
        fi
      fi
      break
    fi
    read -rp "Enter VMID (>=100): " VMID
    VMID="$(echo "$VMID" | xargs)"
  done
}

prompt_ip() {
  while true; do
    if [[ -n "$IP_INPUT" ]]; then
      if IP_CIDR="$(normalize_ip "$IP_INPUT")"; then
        IP_INPUT="$IP_CIDR"
        break
      else
        echo "ERROR: IP must be 192.168.1.X (1-254) or just X, e.g. 50 or 192.168.1.50" >&2
        if [[ -n "$VMID" && -n "${PRIVILEGED_FLAG:-}" ]]; then
          exit 1
        fi
        IP_INPUT=""
        continue
      fi
    fi
    read -rp "Enter IP [192.168.1.X or X, will become 192.168.1.X/24]: " IP_INPUT
    IP_INPUT="$(echo "$IP_INPUT" | xargs)"
  done
  IP_CIDR="$IP_INPUT"
  IP_ADDR="${IP_CIDR%%/*}"
}

prompt_hostname() {
  if [[ -z "$HOSTNAME" ]]; then
    local def="${DEFAULT_HOSTNAME_PREFIX}-${VMID}"
    read -rp "Enter hostname [${def}]: " inp
    inp="$(echo "${inp:-}" | xargs)"
    HOSTNAME="${inp:-$def}"
  fi
}

prompt_privileged() {
  while true; do
    if [[ -n "$PRIVILEGED_FLAG" ]]; then
      break
    fi
    read -rp "Privileged container for performance/LLM? [Y/n]: " ans
    ans="$(echo "${ans:-Y}" | tr '[:upper:]' '[:lower:]' | xargs)"
    case "$ans" in
      y|yes) PRIVILEGED_FLAG="1"; break ;;
      n|no) PRIVILEGED_FLAG="0"; break ;;
      *) echo "Please answer y/n" ;;
    esac
  done
}

prompt_password() {
  if [[ -n "$PASSWORD" ]]; then
    return
  fi
  while true; do
    read -rsp "Enter root password for LXC $VMID: " PASSWORD
    echo
    if [[ -z "$PASSWORD" ]]; then
      echo "Password cannot be empty." >&2
      continue
    fi
    read -rsp "Confirm root password: " PASSWORD2
    echo
    if [[ "$PASSWORD" != "$PASSWORD2" ]]; then
      echo "Passwords do not match." >&2
      continue
    fi
    break
  done
}

prompt_gpu() {
  if [[ "$GPU_MODE" != "auto" ]]; then
    return
  fi
  echo ""
  echo "GPU passthrough: host has AMD iGPU (/dev/kfd + /dev/dri) and/or NVIDIA eGPU (/dev/nvidia*)"
  echo "  Detected on this host:"
  ls -l /dev/dri 2>&1 | sed 's/^/    /' || echo "    /dev/dri not found"
  ls -l /dev/kfd /dev/nvidia* 2>&1 | sed 's/^/    /' || true
  echo ""
  read -rp "GPU mode [both/amd/nvidia/none/auto] (default: both): " inp
  inp="$(echo "${inp:-both}" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$inp" in
    amd|nvidia|both|none) GPU_MODE="$inp" ;;
    auto) GPU_MODE="both" ;;
    *) echo "Invalid, using 'both'"; GPU_MODE="both" ;;
  esac
}

prompt_cores_memory() {
  # Normalize MEMORY if passed via --memory flag (handles 2/4/6/8, 4GB, 4096)
  if [[ -n "$MEMORY" ]]; then
    if ! MEMORY="$(normalize_memory_to_mb "$MEMORY" 2>/dev/null)"; then
      echo "ERROR: --memory must be 2/4/6/8 or MB (e.g. 4, 4GB, 4096)" >&2
      exit 1
    fi
  fi
  # Normalize ROOTFS if passed via --rootfs (handles 32, 32G, 32GB, 50)
  if [[ -n "$ROOTFS" ]]; then
    ROOTFS="$(echo "$ROOTFS" | tr '[:upper:]' '[:lower:]' | sed 's/gb//;s/g//;s/m//')"
    if ! [[ "$ROOTFS" =~ ^[0-9]+$ ]] || (( ROOTFS < 4 || ROOTFS > 1024 )); then
      echo "ERROR: --rootfs must be size in GB (e.g. 32, 50, 32G)" >&2
      exit 1
    fi
  fi

  # only prompt if interactive and not set via flags? Keep defaults but allow override
  if [[ -n "$VMID" && -n "$IP_CIDR" && -n "$PRIVILEGED_FLAG" && -n "$PASSWORD" && "$GPU_MODE" != "auto" && -n "$CORES" && -n "$MEMORY" && -n "$ROOTFS" ]]; then
    return
  fi

  # Cores — 4/8 with 4 default, Enter for fast install
  echo "Cores options: 4, 8 (default: ${CORES} — Enter for fast install)"
  while true; do
    read -rp "Cores [${CORES}]: " inp; inp="$(echo "${inp:-$CORES}" | xargs)"
    if [[ "$inp" =~ ^(4|8)$ ]]; then
      CORES="$inp"; break
    elif [[ "$inp" =~ ^[0-9]+$ ]] && (( inp >= 1 && inp <= 32 )); then
      echo "  Note: usual choices are 4/8 — using ${inp} anyway"
      CORES="$inp"; break
    else
      echo "  Invalid — choose 4 or 8 (or 1-32)"
    fi
  done

  # RAM — 2/4/6/8 GB, default 4GB, Enter for fast install
  local mem_gb_default=$(( MEMORY / 1024 ))
  echo "RAM options: 2, 4, 6, 8 GB (default: ${mem_gb_default}GB — Enter for fast install)"
  while true; do
    read -rp "RAM in GB [${mem_gb_default}]: " inp; inp="$(echo "${inp:-$mem_gb_default}" | xargs)"
    inp="$(echo "$inp" | tr '[:upper:]' '[:lower:]' | sed 's/gb//;s/g//')"
    if [[ "$inp" =~ ^(2|4|6|8)$ ]]; then
      MEMORY=$(( inp * 1024 ))
      break
    elif [[ "$inp" =~ ^[0-9]+$ ]] && (( inp >= 1 && inp <= 64 )); then
      echo "  Note: usual choices are 2/4/6/8 — using ${inp}GB anyway"
      MEMORY=$(( inp * 1024 ))
      break
    else
      echo "  Invalid — choose 2, 4, 6, or 8"
    fi
  done

  # Rootfs / Storage size — default 32G, allow 25/50/75 or any GB like 50
  echo "Disk size options: 25, 50, 75 GB (default: ${ROOTFS}G on ${STORAGE} — Enter for fast, or type any GB like 50)"
  while true; do
    read -rp "Rootfs size GB [${ROOTFS}]: " inp; inp="$(echo "${inp:-$ROOTFS}" | xargs)"
    inp="$(echo "$inp" | tr '[:upper:]' '[:lower:]' | sed 's/gb//;s/g//')"
    if [[ "$inp" =~ ^(25|50|75)$ ]]; then
      ROOTFS="$inp"; break
    elif [[ "$inp" =~ ^[0-9]+$ ]] && (( inp >= 8 && inp <= 1024 )); then
      echo "  Note: standard choices are 25/50/75 — using ${inp}GB anyway (manual)"
      ROOTFS="$inp"; break
    else
      echo "  Invalid — enter number 8-1024 (e.g. 25, 50, 75)"
    fi
  done

  # Storage pool — default RaidZ1-6TB like hlh-ai-engine (--storage local fails: does not support container directories)
  if command -v pvesm >/dev/null 2>&1; then
    echo "  Available storages (container capable):"
    pvesm status 2>&1 | awk 'NR==1 || $3 ~ /rootdir/ || $2 ~ /RaidZ1/' | sed 's/^/    /' || true
  fi
  read -rp "Storage [${STORAGE}]: " inp; inp="$(echo "${inp:-}" | xargs)"; STORAGE="${inp:-$STORAGE}"
  read -rp "Template [${TEMPLATE}]: " inp; inp="$(echo "${inp:-}" | xargs)"; TEMPLATE="${inp:-$TEMPLATE}"
}

# --- main ---
need_pct
prompt_vmid
prompt_ip
prompt_hostname
prompt_privileged
prompt_password
prompt_gpu
prompt_cores_memory

UNPRIVILEGED="1"
if [[ "$PRIVILEGED_FLAG" == "1" ]]; then UNPRIVILEGED="0"; fi

MEMORY_GB=$(( MEMORY / 1024 ))
echo ""
echo "=== Summary ==="
echo "  VMID        : $VMID"
echo "  Hostname    : $HOSTNAME"
echo "  IP          : $IP_CIDR gw $GATEWAY bridge $BRIDGE_OPT"
echo "  Privileged  : $PRIVILEGED_FLAG (pct --unprivileged $UNPRIVILEGED) $([[ "$PRIVILEGED_FLAG" == "1" ]] && echo '[for LLM perf]' || echo '[secure]')"
echo "  Cores/RAM   : ${CORES} cores / ${MEMORY_GB}GB (${MEMORY} MB)"
echo "  Storage     : $STORAGE (${ROOTFS}G rootfs on ${STORAGE} — default 32G like hlh-ai-engine)"
echo "  Template    : $TEMPLATE"
echo "  GPU mode    : $GPU_MODE"
echo "  Root PW     : [hidden, will be set via chpasswd]"
echo ""

if [[ -z "${PASSWORD:-}" ]]; then echo "ERROR: password empty" >&2; exit 1; fi

read -rp "Create LXC $VMID ($HOSTNAME) at $IP_CIDR ? [y/N]: " confirm
confirm="$(echo "${confirm:-N}" | tr '[:upper:]' '[:lower:]' | xargs)"
if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

# Check template exists (templates live on 'local', not on RaidZ1-6TB)
if [[ ! -e "/var/lib/vz/template/cache/$(basename "${TEMPLATE#*:}")" ]] && ! pveam list local 2>&1 | grep -q "$(basename "${TEMPLATE#*:}")"; then
  echo "WARNING: Template $TEMPLATE not found in /var/lib/vz/template/cache" >&2
  echo "Available:"
  pveam available 2>&1 | grep -i ubuntu | head -20 || true
  echo ""
  read -rp "Try to download default ubuntu template? [y/N]: " dl
  if [[ "$(echo "${dl:-N}" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
    pveam update
    # try to find latest ubuntu-24.04 standard
    TPL_NAME="$(pveam available 2>&1 | grep -o 'ubuntu-24\.04-standard[^ ]*\.tar\.zst' | head -1)"
    if [[ -n "$TPL_NAME" ]]; then
      pveam download local "$TPL_NAME"
      TEMPLATE="local:vztmpl/$TPL_NAME"
      echo "Using TEMPLATE=$TEMPLATE"
    else
      echo "Could not find ubuntu template, continuing with $TEMPLATE"
    fi
  fi
fi

echo "[1/6] Creating LXC $VMID ..."
pct create "$VMID" "$TEMPLATE" \
  --storage "$STORAGE" \
  --rootfs "${ROOTFS}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap 0 \
  --features nesting=1,keyctl=1 \
  --net0 "name=eth0,bridge=${BRIDGE_OPT},ip=${IP_CIDR},gw=${GATEWAY}" \
  --unprivileged "$UNPRIVILEGED" \
  --onboot 1

CONF="/etc/pve/lxc/${VMID}.conf"
cp "$CONF" "${CONF}.bak.$(date +%s)"
echo "Backed up $CONF -> ${CONF}.bak.*"

# --- GPU passthrough ---
echo "[2/6] Configuring GPU passthrough (mode=$GPU_MODE) ..."
# Always add apparmor unconfined for GPU access (needed for both amd/nvidia, privileged or not)
if ! grep -q "lxc.apparmor.profile" "$CONF"; then
  echo "lxc.apparmor.profile: unconfined" >> "$CONF"
fi

# Helper to append if not already present
append_conf() {
  local line="$1"
  grep -qF "$line" "$CONF" || echo "$line" >> "$CONF"
}

if [[ "$GPU_MODE" == "amd" || "$GPU_MODE" == "both" ]]; then
  echo "  -> AMD iGPU: /dev/dri + /dev/kfd"
  # Allow DRI (226) and KFD (major varies: 511 on 6.8, 234 on 10.x, 238 legacy) — allow all for compat
  append_conf "lxc.cgroup2.devices.allow: c 226:* rwm"
  append_conf "lxc.cgroup2.devices.allow: c 511:* rwm"
  append_conf "lxc.cgroup2.devices.allow: c 234:* rwm"
  append_conf "lxc.cgroup2.devices.allow: c 238:* rwm"
  # Bind mounts — per-file with optional (host may have card0/1/2, renderD128/129)
  for dev in /dev/dri/card* /dev/dri/renderD* ; do
    [[ -e "$dev" ]] || continue
    base="$(basename "$dev")"
    # use create=file for devices
    append_conf "lxc.mount.entry: ${dev} dev/dri/${base} none bind,optional,create=file"
  done
  # fallback: if no /dev/dri enumerated yet (e.g. this build host), bind dir
  if [[ ! -e /dev/dri/card0 && ! -e /dev/dri/renderD128 ]]; then
    # still add generic dir bind so on Proxmox host with different enumeration it works
    # but avoid duplicate if per-file already added
    if ! grep -q "lxc.mount.entry: /dev/dri " "$CONF"; then
      append_conf "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
    fi
  fi
  if [[ -e /dev/kfd ]]; then
    append_conf "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file"
  else
    # add anyway — on Proxmox host /dev/kfd exists but not on this build host
    append_conf "lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file"
  fi
fi

if [[ "$GPU_MODE" == "nvidia" || "$GPU_MODE" == "both" ]]; then
  echo "  -> NVIDIA eGPU: /dev/nvidia* + /dev/dri"
  # NVIDIA majors: 195=nvidia, 235=nvidia-uvm (sometimes 511), 226=dri
  append_conf "lxc.cgroup2.devices.allow: c 195:* rwm"
  append_conf "lxc.cgroup2.devices.allow: c 235:* rwm"
  append_conf "lxc.cgroup2.devices.allow: c 226:* rwm"
  # also allow nvidia-caps (511) if present
  append_conf "lxc.cgroup2.devices.allow: c 511:* rwm"
  for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    [[ -e "$dev" ]] || continue
    base="$(basename "$dev")"
    append_conf "lxc.mount.entry: ${dev} dev/${base} none bind,optional,create=file"
  done
  # nvidia-caps dir
  if [[ -d /dev/nvidia-caps ]]; then
    append_conf "lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir"
  else
    # add generic caps bind for Proxmox host
    if ! grep -q "nvidia-caps" "$CONF"; then
      append_conf "lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir"
    fi
  fi
  # Ensure DRI bind for nvidia as well (if not already from AMD block)
  if ! grep -q "lxc.mount.entry: /dev/dri" "$CONF"; then
    if [[ -e /dev/dri ]]; then
      for dev in /dev/dri/card* /dev/dri/renderD*; do
        [[ -e "$dev" ]] || continue
        base="$(basename "$dev")"
        append_conf "lxc.mount.entry: ${dev} dev/dri/${base} none bind,optional,create=file"
      done
    else
      append_conf "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
    fi
  fi
fi

if [[ "$GPU_MODE" == "none" ]]; then
  echo "  -> Skipping GPU passthrough"
fi

echo ""
echo "LXC config $CONF:"
cat "$CONF"
echo ""

echo "[3/6] Starting LXC $VMID ..."
pct start "$VMID"
sleep 5
pct status "$VMID"

echo "[4/6] Setting root password ..."
# Robust password set: push temp file to avoid shell escaping issues with special chars
TMP_PW="$(mktemp)"
printf 'root:%s\n' "$PASSWORD" > "$TMP_PW"
chmod 600 "$TMP_PW"
if pct push "$VMID" "$TMP_PW" /tmp/pw-set --perms 600 2>&1; then
  pct exec "$VMID" -- bash -c 'chpasswd < /tmp/pw-set && rm -f /tmp/pw-set' || {
    echo "WARNING: chpasswd via push failed, trying lxc-attach" >&2
    lxc-attach -n "$VMID" -- bash -c 'chpasswd < /tmp/pw-set && rm -f /tmp/pw-set' || true
  }
else
  echo "WARNING: pct push failed, falling back to inline chpasswd" >&2
  pct exec "$VMID" -- bash -c 'printf "%s:%s\n" "root" "$1" | chpasswd' _ "$PASSWORD" || \
    lxc-attach -n "$VMID" -- bash -c 'printf "%s:%s\n" "root" "$1" | chpasswd' _ "$PASSWORD" || true
fi
shred -u "$TMP_PW" 2>/dev/null || rm -f "$TMP_PW"
# Keep PASSWORD for SSH test until after SSH config, then clear
# (do not unset yet — need for test below, will unset after SSH step)

echo "[5/6] Configuring SSH for root like hlh-ai-engine (PermitRootLogin yes, PasswordAuthentication yes) ..."
# Like hlh-ai-engine/ansible/files/configure-ai-engine-inside-lxc.sh:187-195
# Use printf not heredoc inside pct exec to avoid quoting issues
pct exec "$VMID" -- bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  echo "Waiting for network in LXC..."
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 || getent hosts archive.ubuntu.com >/dev/null 2>&1; then
      echo "Network up after $i tries"
      break
    fi
    echo "  no network yet, try $i/10 — sleep 2"
    sleep 2
  done
  echo "APT update..."
  apt-get update
  echo "Installing openssh-server..."
  apt-get install -y --no-install-recommends openssh-server
  usermod -aG render root 2>/dev/null || true
  usermod -aG video root 2>/dev/null || true
  mkdir -p /etc/ssh/sshd_config.d
  printf "PermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication no\nUsePAM yes\n" > /etc/ssh/sshd_config.d/99-root-login.conf
  echo "Wrote /etc/ssh/sshd_config.d/99-root-login.conf:"
  cat /etc/ssh/sshd_config.d/99-root-login.conf
  # Also ensure main sshd_config has Include (Ubuntu 24.04 does, but verify)
  grep -q "Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config || echo "Include /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
  # Validate config
  sshd -t && echo "sshd -t OK" || { echo "sshd -t FAILED"; cat /etc/ssh/sshd_config; cat /etc/ssh/sshd_config.d/*.conf; }
  echo "Effective sshd config:"
  sshd -T 2>&1 | grep -Ei "permitroot|passwordauth|port " | head -20
  # Enable and start — try systemctl, then service, then direct sshd
  systemctl daemon-reload 2>&1 | tail -5 || true
  systemctl enable ssh 2>&1 | tail -5 || systemctl enable sshd 2>&1 | tail -5 || true
  if ! systemctl restart ssh 2>&1 | tail -20; then
    systemctl restart sshd 2>&1 | tail -20 || service ssh restart 2>&1 | tail -20 || /usr/sbin/sshd 2>&1 | tail -20 || true
  fi
  sleep 2
  echo "systemctl status:"
  systemctl is-active ssh 2>&1 || systemctl is-active sshd 2>&1 || service ssh status 2>&1 | head -30 || true
  echo "ss listening:"
  ss -tlnp 2>&1 | grep -E ":22" | head -10 || netstat -tlnp 2>&1 | grep -E ":22" | head -10 || ss -tln 2>&1 | head -20
  echo "journalctl ssh:"
  journalctl -u ssh --no-pager -n 30 2>&1 | tail -30 || journalctl -u sshd --no-pager -n 30 2>&1 | tail -30 || true
' || echo "WARNING: SSH setup failed (check pct exec $VMID -- systemctl status ssh; journalctl -u ssh)" >&2

# Host-side check: try to reach port 22 from Proxmox host (not inside LXC)
echo "Host-side SSH check for $IP_ADDR:22 ..."
if command -v nc >/dev/null 2>&1; then
  nc -vz -w5 "$IP_ADDR" 22 2>&1 || echo "  nc failed — sshd not yet reachable from host"
elif command -v ncat >/dev/null 2>&1; then
  ncat -vz -w5 "$IP_ADDR" 22 2>&1 || true
else
  timeout 5 bash -c "cat < /dev/null > /dev/tcp/$IP_ADDR/22 && echo \"  TCP connect OK\" || echo \"  TCP connect failed\"" 2>&1 || true
fi
# Also verify inside LXC that 127.0.0.1:22 works
pct exec "$VMID" -- bash -c "ss -tlnp 2>&1 | grep 22; systemctl is-active ssh 2>&1; sshd -T 2>&1 | grep -i permit" 2>&1 | sed "s/^/  LXC ssh: /" || true

# Now safe to clear password
unset PASSWORD PASSWORD2 TMP_PW

echo "[6/6] Verifying (GPU + SSH) ..."
pct exec "$VMID" -- bash -c 'ls -l /dev/dri 2>&1; echo "---"; ls -l /dev/kfd /dev/nvidia* 2>&1; echo "---"; cat /proc/mounts 2>&1 | grep -E "dri|kfd|nvidia" | head -20' || true
pct exec "$VMID" -- bash -c 'echo "--- SSH ---"; cat /etc/ssh/sshd_config.d/99-root-login.conf 2>&1; echo "---"; systemctl is-active ssh 2>&1 || systemctl is-active sshd 2>&1 || service ssh status 2>&1 | head -20; ss -tlnp 2>&1 | grep :22 | head -5 || true' || true

echo ""
echo "=== Done ==="
echo "LXC $VMID ($HOSTNAME) at $IP_ADDR created (privileged=$PRIVILEGED_FLAG, gpu=$GPU_MODE)"
echo "  pct enter $VMID"
echo "  pct exec $VMID -- bash"
echo "  ssh root@$IP_ADDR  # like hlh-ai-engine: PermitRootLogin yes + PasswordAuthentication yes (99-root-login.conf)"
echo "  Inside LXC:  rocminfo | head -n 50   # AMD"
echo "  Inside LXC:  nvidia-smi             # NVIDIA"
echo "  Inside LXC:  ls -l /dev/dri /dev/kfd /dev/nvidia*"
echo ""
echo "Fiddle notes:"
echo "  - If AMD not visible: check host ls -l /dev/kfd /dev/dri and /proc/devices | grep kfd, then adjust lxc.cgroup2.devices.allow majors (511/234/238)"
echo "  - If NVIDIA not visible: host nvidia-smi must work; check major via stat -c '%t %T' /dev/nvidia0 (should be 195:0) and allow c 195:* / c 235:*"
echo "  - For unprivileged, you may need lxc.idmap or chown render/video gid mapping — privileged avoids that"
echo "  - To edit: nano $CONF then pct stop $VMID && pct start $VMID"
