#!/usr/bin/env bash
set -euo pipefail

# rocm-vllm-install.sh — Minimal ROCm + vLLM installer for test LXC
# Runs on prox01 (host), uses pct exec into target LXC. No hlh-ai-engine-vllm garbage.
# Default target is 115 / 192.168.1.15 (test-vmid) — created via create-lxc.sh
# Usage: ./rocm-vllm-install.sh [--vmid 115] [--ip 192.168.1.15] [--rocm 6.4.2]
# Pull on prox01 and run as root. It will pct exec into 115 and do the work.

VMID="115"
IP="192.168.1.15"
ROCM_VERSION="6.4.2"
VLLM_VERSION=""

usage() {
  cat <<'EOF'
Usage: ./rocm-vllm-install.sh [options]

Host-side installer — run on prox01 as root. Uses pct exec into target LXC.
Does NOT run inside the CT directly (but will auto-detect if you pct enter).

Options:
  --vmid ID        Target LXC ID (default: 115)
  --ip IP          Target IP (default: 192.168.1.15) — for verification only
  --rocm VER       ROCm version (default: 6.4.2 — stable for vLLM, 10.0.0 also works for gfx1150)
  --vllm VER       vLLM version (default: latest)
  -h, --help       Show help

Examples:
  ./rocm-vllm-install.sh
  ./rocm-vllm-install.sh --vmid 115 --rocm 6.4.2
  ./rocm-vllm-install.sh --vmid 115 --rocm 10.0.0 --vllm 0.9.1
EOF
}

INSIDE_FORCED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --rocm) ROCM_VERSION="$2"; shift 2 ;;
    --vllm) VLLM_VERSION="$2"; shift 2 ;;
    --inside) INSIDE_FORCED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown option $1" >&2; usage; exit 1 ;;
  esac
done

# If running inside LXC (no pct, or systemd-detect-virt), just do inner install
if [[ "$INSIDE_FORCED" -eq 1 ]]; then
  echo "Forced inside mode via --inside (ROCM $ROCM_VERSION)"
  INSIDE=1
elif ! command -v pct >/dev/null 2>&1 || ! pct status "$VMID" >/dev/null 2>&1 2>&1; then
  if systemd-detect-virt 2>/dev/null | grep -qi lxc; then
    echo "Detected running INSIDE LXC — doing direct install (ROCM $ROCM_VERSION)"
    INSIDE=1
  else
    echo "ERROR: pct not found or VMID $VMID not found. Run on prox01 as root." >&2
    echo "If you are inside the CT, this script auto-detects LXC — but pct missing suggests host." >&2
    exit 1
  fi
else
  INSIDE=0
fi

# Host-side path
if [[ "$INSIDE" -eq 0 ]]; then
  echo "=== rocm-vllm-install (host) ==="
  echo "  Target: $VMID / $IP"
  echo "  ROCm: $ROCM_VERSION  vLLM: ${VLLM_VERSION:-latest}"
  echo ""

  # Checks
  if [[ "$(id -u)" -ne 0 ]]; then echo "ERROR: run as root on prox01" >&2; exit 1; fi
  pct status "$VMID" >/dev/null 2>&1 || { echo "ERROR: LXC $VMID not found" >&2; exit 1; }
  if ! pct status "$VMID" | grep -qi running; then
    echo "Starting $VMID ..."
    pct start "$VMID"
    sleep 5
  fi
  echo "LXC $VMID status: $(pct status "$VMID" 2>&1)"
  echo "Host GPU passthrough check:"
  ls -l /dev/dri 2>&1 | sed 's/^/  host /' || true
  ls -l /dev/kfd /dev/nvidia* 2>&1 | sed 's/^/  host /' || true
  echo "Inside LXC GPU check (before install):"
  pct exec "$VMID" -- bash -c 'ls -l /dev/dri 2>&1 | sed "s/^/  lxc /"; ls -l /dev/kfd /dev/nvidia* 2>&1 | sed "s/^/  lxc /"; cat /proc/mounts 2>&1 | grep -E "dri|kfd|nvidia" | sed "s/^/  mount /"' || true
  echo ""

  # Push self into LXC and run inner
  echo "[1/5] Pushing installer into LXC..."
  pct exec "$VMID" -- mkdir -p /root/rocm-vllm
  pct push "$VMID" "$0" /root/rocm-vllm/rocm-vllm-install.sh --perms 0755

  echo "[2/5] Running inner install inside $VMID (ROCM $ROCM_VERSION)..."
  # Pass through vars via env
  pct exec "$VMID" -- env ROCM_VERSION="$ROCM_VERSION" VLLM_VERSION="$VLLM_VERSION" bash /root/rocm-vllm/rocm-vllm-install.sh --inside

  echo ""
  echo "[3/5] Verifying from host..."
  pct exec "$VMID" -- bash -c 'echo "--- rocminfo ---"; rocminfo 2>&1 | head -80; echo "--- rocm-smi ---"; rocm-smi 2>&1 | head -40; echo "--- torch ---"; /opt/vllm-venv/bin/python -c "import torch; print(torch.__version__); print(torch.cuda.is_available()); print(torch.cuda.device_count())" 2>&1 | head -20; echo "--- vllm ---"; /opt/vllm-venv/bin/python -m vllm --help 2>&1 | head -30 || /opt/vllm-venv/bin/vllm --help 2>&1 | head -30' || true

  echo ""
  echo "=== Done (host) ==="
  echo "Test inside LXC:"
  echo "  pct exec $VMID -- bash -c 'rocminfo | head -20; rocm-smi'"
  echo "  pct exec $VMID -- /opt/vllm-venv/bin/python -c 'import torch; print(torch.cuda.is_available())'"
  echo "  ssh root@$IP  # then same checks"
  echo "  Inside LXC vLLM run: HSA_OVERRIDE_GFX_VERSION=11.0.0 /opt/vllm-venv/bin/vllm serve --model Qwen/Qwen2.5-0.5B-Instruct --port 8000"
  exit 0
fi

# --- INSIDE LXC (either via pct exec or direct) ---
# This block runs inside the target LXC

# Re-parse --inside flag (passed from host)
if [[ "${1:-}" == "--inside" ]]; then shift; fi

echo "=== rocm-vllm-install (inside LXC) ==="
echo "  ROCM_VERSION=$ROCM_VERSION VLLM_VERSION=${VLLM_VERSION:-latest}"
echo "  Hostname: $(hostname)  IP: $(hostname -I 2>&1 | head -1)"
echo "  GPU: $(ls -l /dev/dri 2>&1 | head -5; ls -l /dev/kfd 2>&1 | head -5)"
cat /etc/os-release | grep PRETTY_NAME || true
echo ""

if [[ "$(id -u)" -ne 0 ]]; then echo "ERROR: run as root inside LXC" >&2; exit 1; fi

export DEBIAN_FRONTEND=noninteractive
export ROCM_PATH="/opt/rocm"
export HIP_PATH="/opt/rocm"
VENV_DIR="/opt/vllm-venv"

echo "[1/4] Base deps..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates gnupg wget curl git build-essential pkg-config \
  python3 python3-venv python3-pip python3-dev \
  libopenblas-dev libnuma1

# For gfx1150 (890M) — override for torch HIP
GFX_VERSION="11.0.0"
echo "GFX override: $GFX_VERSION (890M gfx1150)"

echo "[2/4] ROCm $ROCM_VERSION repo + install..."
mkdir -p /etc/apt/keyrings
ROCM_MAJOR="$(echo "$ROCM_VERSION" | cut -d. -f1)"
# Decide repo: 10.x -> stable.repo.amd.com, else legacy multi-arch (6.x, 7.x)
if [[ "$ROCM_MAJOR" -ge 10 ]] 2>/dev/null; then
  echo "Using stable.repo.amd.com for ROCm 10.x"
  wget -qO - https://stable.repo.amd.com/rocm/gpg/packages.gpg | gpg --dearmor > /etc/apt/keyrings/amdrocm.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://stable.repo.amd.com/rocm/core/packages/ubuntu2404 stable main" > /etc/apt/sources.list.d/rocm.list
  echo -e "Package: *\nPin: origin stable.repo.amd.com\nPin-Priority: 1001" > /etc/apt/preferences.d/rocm-pin
else
  echo "Using repo.amd.com multi-arch for ROCm 6.x/7.x"
  wget -qO - https://repo.amd.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/keyrings/amdrocm.gpg 2>/dev/null || \
    wget -qO - https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg | gpg --dearmor > /etc/apt/keyrings/amdrocm.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/apt/6.4 ubuntu main" > /etc/apt/sources.list.d/rocm.list
  # fallback for older path
  if ! apt-get update 2>&1 | tail -5; then
    echo "Trying legacy path..."
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/apt/6.4 jammy main" > /etc/apt/sources.list.d/rocm.list || true
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404 stable main" > /etc/apt/sources.list.d/rocm.list || true
  fi
  echo -e "Package: *\nPin: origin repo.amd.com\nPin-Priority: 1001" > /etc/apt/preferences.d/rocm-pin || true
fi
echo 'APT::Key::GPGCommand "/usr/bin/gpg";' > /etc/apt/apt.conf.d/99gpg-override 2>/dev/null || true

# Try update, install rocm
apt-get update || apt-get update -o Acquire::AllowInsecureRepositories=true || true

# Install ROCm — try versioned then generic
ROCM_MM="$(echo "$ROCM_VERSION" | cut -d. -f1,2)"
echo "Installing ROCm packages for $ROCM_VERSION (MM=$ROCM_MM)..."
# Clean old rocminfo that conflicts
apt-get remove -y rocminfo 2>/dev/null || true

# For 6.4, packages are rocm-dev, rocm-smi-lib, rocminfo etc, not amdrocm
if [[ "$ROCM_MAJOR" -eq 6 ]] || [[ "$ROCM_MAJOR" -eq 7 ]]; then
  echo "Installing ROCm 6.x/7.x stack (rocm-dev)..."
  apt-get install -y --no-install-recommends rocm-dev rocm-smi-lib rocminfo 2>&1 | tail -30 || \
    apt-get install -y --no-install-recommends rocm 2>&1 | tail -30 || {
      echo "Trying amdrocm fallback..."
      apt-get install -y --no-install-recommends "amdrocm${ROCM_MM}" 2>&1 | tail -30 || true
    }
else
  # 10.x uses amdrocm
  apt-get install -y --no-install-recommends "amdrocm${ROCM_MM}-gfx1150" "amdrocm-core-dev${ROCM_MM}-gfx1150" 2>&1 | tail -30 || \
    apt-get install -y --no-install-recommends "amdrocm${ROCM_MM}" "amdrocm-core-dev${ROCM_MM}" 2>&1 | tail -30 || \
    apt-get install -y --no-install-recommends rocm-dev 2>&1 | tail -30 || true
fi

# Env
echo "Setting up ROCm env..."
cat > /etc/profile.d/rocm.sh << EOF
export ROCM_PATH=$ROCM_PATH
export HIP_PATH=$ROCM_PATH
export PATH=\$PATH:$ROCM_PATH/bin:$ROCM_PATH/llvm/bin
export LD_LIBRARY_PATH=$ROCM_PATH/lib:\$LD_LIBRARY_PATH
export HSA_OVERRIDE_GFX_VERSION=$GFX_VERSION
EOF
# shellcheck disable=SC1091
source /etc/profile.d/rocm.sh || true

usermod -aG render root 2>/dev/null || true
usermod -aG video root 2>/dev/null || true

echo "ROCm verify:"
rocminfo 2>&1 | head -60 || echo "rocminfo failed"
rocm-smi 2>&1 | head -40 || echo "rocm-smi failed"
ls -l /opt/rocm 2>&1 | head -20 || true
echo "HSA_OVERRIDE_GFX_VERSION=$HSA_OVERRIDE_GFX_VERSION"

echo "[3/4] vLLM venv + torch ROCm + vLLM..."
# Clean old venv if exists
rm -rf "$VENV_DIR"
python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
pip install --upgrade pip wheel setuptools

# Install torch ROCm — vLLM needs torch with ROCm
# Use ROCm 6.4 wheel for 6.4.2, nightly for 10.x fallback to 6.4
echo "Installing torch ROCm..."
if [[ "$ROCM_MAJOR" -ge 10 ]]; then
  echo "ROCm 10.x — trying torch nightly ROCm 6.4 fallback (10.x not yet in torch stable)"
  pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/rocm6.4 "torch==2.8.0" "torchaudio==2.8.0" 2>&1 | tail -20 || \
    pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/rocm6.2 "torch" "torchaudio" 2>&1 | tail -20 || \
    pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/rocm6.4 2>&1 | tail -20 || true
else
  pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/rocm6.4 "torch==2.8.0" 2>&1 | tail -20 || \
    pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/rocm6.4 2>&1 | tail -20 || true
fi
python -c "import torch; print('torch', torch.__version__); print('cuda avail', torch.cuda.is_available())" 2>&1 | tail -20 || true

echo "Installing vLLM..."
if [[ -n "$VLLM_VERSION" ]]; then
  pip install --no-cache-dir "vllm==$VLLM_VERSION" 2>&1 | tail -30 || true
else
  pip install --no-cache-dir vllm 2>&1 | tail -30 || true
fi
# Verify
python -c "import vllm; print('vllm', vllm.__version__)" 2>&1 | tail -20 || echo "vllm import failed"
python -c "import torch; print(torch.cuda.is_available(), torch.cuda.device_count()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'no cuda')" 2>&1 | tail -20 || true

echo "[4/4] Smoke test..."
echo "rocminfo agents:"
rocminfo 2>&1 | grep -E "Agent|gfx|Name" | head -20 || true
echo "rocm-smi:"
rocm-smi 2>&1 | head -20 || true
echo "vllm help:"
python -m vllm --help 2>&1 | head -20 || vllm --help 2>&1 | head -20 || true

deactivate 2>/dev/null || true

echo ""
echo "=== rocm-vllm-install (inside) done ==="
echo "Test: HSA_OVERRIDE_GFX_VERSION=$GFX_VERSION /opt/vllm-venv/bin/vllm serve --model Qwen/Qwen2.5-0.5B-Instruct --port 8000 --dtype auto"
echo "Or: /opt/vllm-venv/bin/python -c 'import torch; print(torch.cuda.is_available())'"
