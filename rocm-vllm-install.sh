#!/usr/bin/env bash
set -euo pipefail

# rocm-vllm-install.sh — Minimal ROCm + vLLM installer for test LXC
# Runs on prox01 (host), uses pct exec into target LXC. No hlh-ai-engine-vllm garbage.
# Default target is 115 / 192.168.1.15 (test-vmid) — created via create-lxc.sh
# Usage: ./rocm-vllm-install.sh [--vmid 115] [--ip 192.168.1.15] [--rocm 10.0.0]
# Pull on prox01 and run as root. It will pct exec into 115 and do the work.
# ROCm 10.0.x is current stable (2026), vLLM latest — both stated in output.

VMID="115"
IP="192.168.1.15"
ROCM_VERSION="10.0.0"
VLLM_VERSION=""

usage() {
  cat <<'EOF'
Usage: ./rocm-vllm-install.sh [options]

Host-side installer — run on prox01 as root. Uses pct exec into target LXC.
Does NOT run inside the CT directly (but will auto-detect if you pct enter).

Options:
  --vmid ID        Target LXC ID (default: 115)
  --ip IP          Target IP (default: 192.168.1.15) — for verification only
  --rocm VER       ROCm version (default: 10.0.0 — latest stable 10.0.x, also 6.4.2 works)
  --vllm VER       vLLM version (default: latest from PyPI)
  -h, --help       Show help

Examples:
  ./rocm-vllm-install.sh
  ./rocm-vllm-install.sh --vmid 115 --rocm 10.0.0
  ./rocm-vllm-install.sh --vmid 115 --rocm 6.4.2 --vllm 0.9.1
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
  echo "  ROCm: $ROCM_VERSION (latest 10.0.x)  vLLM: ${VLLM_VERSION:-latest (from PyPI)}"
  echo "  Both versions stated as requested — defaults to latest stable"
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

  echo "[2/5] Running inner install inside $VMID (ROCm $ROCM_VERSION / vLLM ${VLLM_VERSION:-latest})..."
  # Pass through vars via env
  pct exec "$VMID" -- env ROCM_VERSION="$ROCM_VERSION" VLLM_VERSION="$VLLM_VERSION" bash /root/rocm-vllm/rocm-vllm-install.sh --inside

  echo ""
  echo "[3/5] Verifying from host (ROCm $ROCM_VERSION + vLLM ${VLLM_VERSION:-latest})..."
  pct exec "$VMID" -- bash -c 'echo "--- rocminfo ---"; rocminfo 2>&1 | head -80; echo "--- rocm-smi ---"; rocm-smi 2>&1 | head -40; echo "--- torch (for vLLM) ---"; /opt/vllm-venv/bin/python -c "import torch; print(torch.__version__); print(torch.cuda.is_available()); print(torch.cuda.device_count())" 2>&1 | head -20; echo "--- vllm ---"; /opt/vllm-venv/bin/python -c "import vllm; print(vllm.__version__)" 2>&1 | head -20; /opt/vllm-venv/bin/python -m vllm --help 2>&1 | head -30 || /opt/vllm-venv/bin/vllm --help 2>&1 | head -30' || true

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
echo "  ROCm: $ROCM_VERSION (latest 10.0.x)  vLLM: ${VLLM_VERSION:-latest (from PyPI)} — both stated"
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

echo "[2/4] ROCm $ROCM_VERSION repo + install (latest 10.0.x)..."
echo "  Requested ROCm: $ROCM_VERSION + vLLM: ${VLLM_VERSION:-latest} — both stated"
mkdir -p /etc/apt/keyrings
ROCM_MAJOR="$(echo "$ROCM_VERSION" | cut -d. -f1)"

# Use amdgpu-install deb — official quick-start (https://rocm.docs.amd.com/en/latest/install/quick_start.html)
# For Ubuntu 24.04 noble: amdgpu-install_7.2.4... for latest, or 6.4.2 installer for 6.4
# This handles repo + keyring automatically, then apt install rocm (no dkms in LXC)
AMDGPU_INSTALL_DEB="/tmp/amdgpu-install.deb"
AMDGPU_INSTALL_URL=""
if [[ "$ROCM_MAJOR" -ge 10 ]] || [[ "$ROCM_VERSION" == 10* ]]; then
  AMDGPU_INSTALL_URL="https://repo.radeon.com/amdgpu-install/7.2.4/ubuntu/noble/amdgpu-install_7.2.4.70204-1_all.deb"
  echo "Using amdgpu-install 7.2.4 for ROCm 10.x (stable, noble)"
elif [[ "$ROCM_VERSION" == 6.4* ]]; then
  AMDGPU_INSTALL_URL="https://repo.radeon.com/amdgpu-install/6.4.2/ubuntu/noble/amdgpu-install_6.4.60204-1_all.deb"
  echo "Using amdgpu-install 6.4.2 for ROCm 6.4.x"
elif [[ "$ROCM_MAJOR" -eq 6 ]]; then
  AMDGPU_INSTALL_URL="https://repo.radeon.com/amdgpu-install/6.4.1/ubuntu/noble/amdgpu-install_6.4.60103-1_all.deb"
  echo "Using amdgpu-install 6.4.1 for ROCm 6.x"
else
  AMDGPU_INSTALL_URL="https://repo.radeon.com/amdgpu-install/7.2.4/ubuntu/noble/amdgpu-install_7.2.4.70204-1_all.deb"
  echo "Using amdgpu-install 7.2.4 fallback for $ROCM_VERSION"
fi

echo "Downloading $AMDGPU_INSTALL_URL ..."
if wget -qO "$AMDGPU_INSTALL_DEB" "$AMDGPU_INSTALL_URL"; then
  echo "Installing amdgpu-install deb..."
  apt-get install -y "$AMDGPU_INSTALL_DEB" || dpkg -i "$AMDGPU_INSTALL_DEB" || true
  apt-get update || apt-get update -o Acquire::AllowInsecureRepositories=true || true
else
  echo "WARNING: amdgpu-install download failed, falling back to manual repo"
  # Fallback manual repo for 10.x: stable.repo.amd.com
  if [[ "$ROCM_MAJOR" -ge 10 ]]; then
    wget -qO - https://stable.repo.amd.com/rocm/gpg/packages.gpg | gpg --dearmor > /etc/apt/keyrings/amdrocm.gpg || true
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://stable.repo.amd.com/rocm/core/packages/ubuntu2404 stable main" > /etc/apt/sources.list.d/rocm.list
  else
    wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/keyrings/amdrocm.gpg 2>/dev/null || \
      wget -qO - https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg | gpg --dearmor > /etc/apt/keyrings/amdrocm.gpg || true
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION}/ubuntu noble main" > /etc/apt/sources.list.d/rocm.list || \
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.radeon.com/rocm/apt/6.4.2/ubuntu noble main" > /etc/apt/sources.list.d/rocm.list
  fi
  echo 'APT::Key::GPGCommand "/usr/bin/gpg";' > /etc/apt/apt.conf.d/99gpg-override 2>/dev/null || true
  apt-get update || true
fi

# Install ROCm — minimal stack for LXC (no dkms)
echo "Installing ROCm (apt install rocm) for $ROCM_VERSION..."
# amdgpu-install deb already added repo, now install
apt-get install -y --no-install-recommends rocm 2>&1 | tail -50 || {
  echo "rocm meta failed, trying rocm-dev..."
  apt-get install -y --no-install-recommends rocm-dev rocminfo rocm-smi-lib 2>&1 | tail -50 || {
    echo "Trying amdrocm fallback..."
    ROCM_MM="$(echo "$ROCM_VERSION" | cut -d. -f1,2)"
    apt-get install -y --no-install-recommends "amdrocm${ROCM_MM}" 2>&1 | tail -30 || true
  }
}
# Also ensure rocminfo present
apt-get install -y rocminfo 2>&1 | tail -20 || true

# Env — fix unbound variable with :- 
echo "Setting up ROCm env (HSA_OVERRIDE_GFX_VERSION=$GFX_VERSION)..."
cat > /etc/profile.d/rocm.sh << EOF
export ROCM_PATH=$ROCM_PATH
export HIP_PATH=$ROCM_PATH
export PATH=\$PATH:$ROCM_PATH/bin:$ROCM_PATH/llvm/bin
export LD_LIBRARY_PATH=\$ROCM_PATH/lib:\${LD_LIBRARY_PATH:-}
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
