#!/usr/bin/env bash
# =============================================================================
# AI LOCAL STACK INSTALLER
# =============================================================================
set -uo pipefail  # removed -e intentionally, we handle errors manually

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$INSTALL_DIR/models"
LLAMA_DIR="$INSTALL_DIR/llama.cpp"
VENV_DIR="$INSTALL_DIR/venv"
LAUNCHER="$INSTALL_DIR/launcher.sh"
LOG="$INSTALL_DIR/install.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG"; }
err()  { echo -e "${RED}[x]${NC} $*" | tee -a "$LOG"; exit 1; }
info() { echo -e "${CYAN}[.]${NC} $*"; }
br()   { echo ""; }

die() {
  echo -e "${RED}[FATAL]${NC} $* (line ${BASH_LINENO[0]})" | tee -a "$LOG"
  exit 1
}
trap 'die "Unexpected error at line $LINENO"' ERR

clear
echo -e "${BOLD}"
cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║          AI LOCAL STACK INSTALLER                    ║
║  llama.cpp + LiteLLM + Models + Optimized Launcher   ║
╚══════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
info "Install directory: $INSTALL_DIR"
info "Log file: $LOG"
br

mkdir -p "$MODELS_DIR"
echo "=== Install started: $(date) ===" > "$LOG"

# =============================================================================
# DETECT OS
# =============================================================================
detect_os() {
  OS=""
  ARCH=""
  case "$(uname -s)" in
    Linux*)  OS="linux" ;;
    Darwin*) OS="macos" ;;
    *)       err "Unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64)        ARCH="x86_64" ;;
    aarch64|arm64) ARCH="arm64"  ;;
    *)             err "Unsupported arch: $(uname -m)" ;;
  esac
  log "OS: $OS | Arch: $ARCH"
}

# =============================================================================
# DETECT GPU
# =============================================================================
detect_gpu() {
  GPU_VENDOR="cpu"
  GPU_NAME="None (CPU only)"
  VRAM_MB=0

  if [ "$OS" = "macos" ]; then
    local chip
    chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
    if echo "$chip" | grep -qi "apple"; then
      GPU_VENDOR="apple"
      GPU_NAME="$chip"
      local mem_bytes
      mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
      VRAM_MB=$(( mem_bytes / 1024 / 1024 * 70 / 100 ))
      log "Apple Silicon: $GPU_NAME | Usable: ${VRAM_MB}MB"
      return
    fi
  fi

  if [ "$OS" = "linux" ]; then
    if command -v nvidia-smi &>/dev/null; then
      local raw_vram raw_name
      raw_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
      raw_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)
      if [[ "$raw_vram" =~ ^[0-9]+$ ]] && [ "$raw_vram" -gt 0 ]; then
        VRAM_MB="$raw_vram"
        GPU_NAME="${raw_name:-NVIDIA GPU}"
        GPU_VENDOR="nvidia"
        log "NVIDIA GPU: $GPU_NAME (${VRAM_MB} MB VRAM)"
        return
      fi
    fi

    if command -v rocm-smi &>/dev/null; then
      GPU_VENDOR="amd"
      GPU_NAME="AMD GPU"
      VRAM_MB=8000  # safe default
      log "AMD GPU detected"
      return
    fi
  fi

  warn "No discrete GPU detected — CPU only mode"
}

# =============================================================================
# PICK CONTEXT SIZE
# =============================================================================
pick_context() {
  CTX=8192  # safe default

  if [ "$GPU_VENDOR" = "apple" ]; then
    local mem_gb
    mem_gb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}' || echo 8)
    if   [ "$mem_gb" -ge 32 ]; then CTX=65536
    elif [ "$mem_gb" -ge 16 ]; then CTX=32768
    else                             CTX=16384
    fi
  elif [ "$GPU_VENDOR" = "nvidia" ] || [ "$GPU_VENDOR" = "amd" ]; then
    if   [ "$VRAM_MB" -ge 16000 ]; then CTX=65536
    elif [ "$VRAM_MB" -ge 8000  ]; then CTX=32768
    elif [ "$VRAM_MB" -ge 4000  ]; then CTX=16384
    else                                 CTX=8192
    fi
  else
    local ram_gb=8
    if command -v free &>/dev/null; then
      ram_gb=$(free -g 2>/dev/null | awk '/Mem:/{print $2}' || echo 8)
    elif [ "$OS" = "macos" ]; then
      ram_gb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f",$1/1024/1024/1024}' || echo 8)
    fi
    if   [ "$ram_gb" -ge 32 ]; then CTX=32768
    elif [ "$ram_gb" -ge 16 ]; then CTX=16384
    else                             CTX=8192
    fi
  fi

  log "Context window: $CTX tokens"
}

# =============================================================================
# CHECK & INSTALL SYSTEM DEPENDENCIES
# =============================================================================
check_deps() {
  log "Checking system dependencies..."
  local missing=()

  for cmd in git curl python3 cmake make; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [ ${#missing[@]} -gt 0 ]; then
    warn "Missing packages: ${missing[*]}"
    if [ "$OS" = "linux" ]; then
      if command -v apt-get &>/dev/null; then
        log "Installing via apt..."
        apt-get update -qq 2>>"$LOG"
        apt-get install -y "${missing[@]}" \
          build-essential libcurl4-openssl-dev pkg-config \
          >>"$LOG" 2>&1 || err "apt-get failed — check $LOG"
      elif command -v dnf &>/dev/null; then
        dnf install -y "${missing[@]}" gcc gcc-c++ make libcurl-devel >>"$LOG" 2>&1
      elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm "${missing[@]}" base-devel curl >>"$LOG" 2>&1
      else
        err "Cannot auto-install deps. Please install: ${missing[*]}"
      fi
    elif [ "$OS" = "macos" ]; then
      command -v brew &>/dev/null || err "Homebrew not found — install from https://brew.sh"
      brew install "${missing[@]}" >>"$LOG" 2>&1
    fi
  fi

  # Python version
  local py_minor
  py_minor=$(python3 -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo 0)
  [ "$py_minor" -lt 9 ] && err "Python 3.9+ required (found 3.${py_minor})"

  log "System dependencies OK"
}

# =============================================================================
# VIRTUALENV
# =============================================================================
setup_venv() {
  log "Setting up Python virtualenv at $VENV_DIR..."

  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR" >>"$LOG" 2>&1 || err "Failed to create venv"
  else
    log "Venv already exists — skipping creation"
  fi

  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate" || err "Failed to activate venv"

  log "Installing Python packages (litellm, huggingface_hub)..."
  pip install --upgrade pip --quiet >>"$LOG" 2>&1
  pip install litellm huggingface_hub requests --quiet >>"$LOG" 2>&1 \
    || err "pip install failed — check $LOG"

  log "Python packages installed"
}

# =============================================================================
# BUILD LLAMA.CPP
# =============================================================================
build_llama() {
  log "Setting up llama.cpp..."

  if [ ! -d "$LLAMA_DIR/.git" ]; then
    log "Cloning llama.cpp..."
    git clone --depth=1 https://github.com/ggerganov/llama.cpp "$LLAMA_DIR" >>"$LOG" 2>&1 \
      || err "git clone failed — check internet connection"
  else
    log "llama.cpp already cloned — pulling latest..."
    git -C "$LLAMA_DIR" pull --ff-only >>"$LOG" 2>&1 || warn "Could not pull — using existing"
  fi

  local build_dir="$LLAMA_DIR/build"
  mkdir -p "$build_dir"

  local cmake_flags="-DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON"

  case "$GPU_VENDOR" in
    nvidia)
      log "Build target: NVIDIA CUDA"
      cmake_flags="$cmake_flags -DGGML_CUDA=ON"
      ;;
    amd)
      log "Build target: AMD ROCm/HIP"
      cmake_flags="$cmake_flags -DGGML_HIPBLAS=ON"
      ;;
    apple)
      log "Build target: Apple Metal"
      cmake_flags="$cmake_flags -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON"
      ;;
    cpu)
      log "Build target: CPU (AVX2)"
      cmake_flags="$cmake_flags -DGGML_AVX2=ON"
      ;;
  esac

  local cpu_count
  cpu_count=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

  log "Running cmake configure..."
  cmake -S "$LLAMA_DIR" -B "$build_dir" $cmake_flags >>"$LOG" 2>&1 \
    || err "cmake configure failed — check $LOG"

  log "Building llama.cpp with $cpu_count threads (this takes a few minutes)..."
  cmake --build "$build_dir" --config Release -j "$cpu_count" >>"$LOG" 2>&1 \
    || err "cmake build failed — check $LOG"

  # Find binary
  LLAMA_SERVER_BIN=""
  for candidate in \
    "$build_dir/bin/llama-server" \
    "$build_dir/llama-server" \
    "$LLAMA_DIR/llama-server"; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      LLAMA_SERVER_BIN="$candidate"
      break
    fi
  done

  [ -z "$LLAMA_SERVER_BIN" ] && err "llama-server binary not found after build — check $LOG"
  log "llama.cpp ready: $LLAMA_SERVER_BIN"
}

# =============================================================================
# DETECT SUPPORTED FLAGS
# =============================================================================
detect_flags() {
  log "Detecting supported llama.cpp flags..."
  FLASH_ATTN_SUPPORT=false
  NUMA_SUPPORT=false
  MLOCK_SUPPORT=false

  local help_out
  help_out=$("$LLAMA_SERVER_BIN" --help 2>&1 || true)

  echo "$help_out" | grep -q -- "--flash-attn"  && FLASH_ATTN_SUPPORT=true
  echo "$help_out" | grep -q -- "--numa"         && NUMA_SUPPORT=true
  echo "$help_out" | grep -q -- "--mlock"        && MLOCK_SUPPORT=true

  log "flash-attn=$FLASH_ATTN_SUPPORT | numa=$NUMA_SUPPORT | mlock=$MLOCK_SUPPORT"
}

# =============================================================================
# HF TOKEN
# =============================================================================
ask_hf_token() {
  br
  echo -e "${BOLD}Hugging Face Token (optional)${NC}"
  info "Required only for gated models (Llama 3, Gemma, etc)."
  info "Press Enter to skip."
  br
  read -rp "HF Token: " HF_TOKEN || true
  HF_TOKEN="${HF_TOKEN:-}"

  if [ -n "$HF_TOKEN" ]; then
    export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
    python3 - <<PYEOF 2>/dev/null || warn "Could not validate HF token"
from huggingface_hub import login
login(token="$HF_TOKEN", add_to_git_credential=False)
print("HF token saved.")
PYEOF
    log "HF token configured"
  else
    HF_TOKEN=""
    warn "No HF token — gated models unavailable"
  fi
}

# =============================================================================
# MODEL MENU
# =============================================================================
show_model_menu() {
  br
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  TOP MODELS — best open-source alternatives to Claude    ${NC}"
  echo -e "${BOLD}  Select one or more separated by comma (e.g. 1,3)        ${NC}"
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  br

  echo -e "  ${CYAN}[1]${NC} ${BOLD}Qwen2.5-Coder-7B-Instruct IQ4_XS${NC}  (~4.3 GB)"
  echo -e "      Best coding 7B open model. Closest to Claude Sonnet for code tasks."
  br
  echo -e "  ${CYAN}[2]${NC} ${BOLD}Qwen2.5-Coder-14B-Instruct IQ4_XS${NC} (~8.5 GB)"
  echo -e "      Noticeably smarter. Runs GPU+RAM split on 4GB VRAM. Recommended."
  br
  echo -e "  ${CYAN}[3]${NC} ${BOLD}Qwen2.5-7B-Instruct IQ4_XS${NC}        (~4.3 GB)"
  echo -e "      General purpose: reasoning, math, multilingual. Fast."
  br
  echo -e "  ${CYAN}[4]${NC} ${BOLD}Gemma-3-4B-IT IQ4_XS${NC}              (~2.5 GB)"
  echo -e "      Smallest/fastest. Google model. Good for quick tasks on low VRAM."
  br
  echo -e "  ${CYAN}[5]${NC} ${BOLD}Llama-3.1-8B-Instruct IQ4_XS${NC}      (~4.7 GB)"
  echo -e "      Meta's flagship 8B. Well-rounded, huge community."
  br
  echo -e "  ${YELLOW}[6]${NC} ${BOLD}Custom${NC} — enter your own HuggingFace repo + filename"
  br
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  br
  read -rp "Your choice(s): " MODEL_CHOICE || true
  MODEL_CHOICE="${MODEL_CHOICE:-1}"
}

# =============================================================================
# DOWNLOAD MODELS
# =============================================================================
download_models() {
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  local -A REPOS FILES
  REPOS[1]="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF"
  FILES[1]="Qwen2.5-Coder-7B-Instruct-IQ4_XS.gguf"

  REPOS[2]="bartowski/Qwen2.5-Coder-14B-Instruct-GGUF"
  FILES[2]="Qwen2.5-Coder-14B-Instruct-IQ4_XS.gguf"

  REPOS[3]="bartowski/Qwen2.5-7B-Instruct-GGUF"
  FILES[3]="Qwen2.5-7B-Instruct-IQ4_XS.gguf"

  REPOS[4]="bartowski/gemma-3-4b-it-GGUF"
  FILES[4]="gemma-3-4b-it-IQ4_XS.gguf"

  REPOS[5]="bartowski/Meta-Llama-3.1-8B-Instruct-GGUF"
  FILES[5]="Meta-Llama-3.1-8B-Instruct-IQ4_XS.gguf"

  IFS=',' read -ra CHOICES <<< "$MODEL_CHOICE"

  for RAW in "${CHOICES[@]}"; do
    local choice="${RAW// /}"

    if [ "$choice" = "6" ]; then
      br
      read -rp "  HuggingFace repo: " CUSTOM_REPO || true
      read -rp "  Filename (.gguf): " CUSTOM_FILE || true
      if [ -n "$CUSTOM_REPO" ] && [ -n "$CUSTOM_FILE" ]; then
        log "Downloading custom: $CUSTOM_FILE"
        huggingface-cli download "$CUSTOM_REPO" \
          --include "$CUSTOM_FILE" \
          --local-dir "$MODELS_DIR" \
          ${HF_TOKEN:+--token "$HF_TOKEN"} \
          2>&1 | tee -a "$LOG" || warn "Custom download failed — check $LOG"
      fi
      continue
    fi

    if [ -z "${REPOS[$choice]+_}" ]; then
      warn "Invalid choice: '$choice' — skipping"
      continue
    fi

    local repo="${REPOS[$choice]}"
    local file="${FILES[$choice]}"
    local target="$MODELS_DIR/$file"

    if [ -f "$target" ]; then
      log "Already exists: $file — skipping download"
      continue
    fi

    log "Downloading $file ..."
    huggingface-cli download "$repo" \
      --include "$file" \
      --local-dir "$MODELS_DIR" \
      ${HF_TOKEN:+--token "$HF_TOKEN"} \
      2>&1 | tee -a "$LOG" || warn "Download failed for $file — check $LOG"

    [ -f "$target" ] && log "Saved: $target" || warn "File not found after download: $target"
  done
}

# =============================================================================
# WRITE LAUNCHER
# =============================================================================
write_launcher() {
  log "Writing launcher: $LAUNCHER"

  # Capture install-time values into local vars to embed cleanly
  local _gpu_vendor="$GPU_VENDOR"
  local _gpu_name="$GPU_NAME"
  local _ctx="$CTX"
  local _fa="$FLASH_ATTN_SUPPORT"
  local _numa="$NUMA_SUPPORT"
  local _mlock="$MLOCK_SUPPORT"
  local _llama_bin="$LLAMA_SERVER_BIN"
  local _venv="$VENV_DIR"
  local _models="$MODELS_DIR"
  local _idir="$INSTALL_DIR"

  # Write the launcher using printf to avoid heredoc quoting issues
  cat > "$LAUNCHER" << 'LAUNCHER_SCRIPT_EOF'
#!/usr/bin/env bash
# =============================================================================
# AI LOCAL LAUNCHER — generated by installer
# =============================================================================
set -uo pipefail

LAUNCHER_SCRIPT_EOF

  # Append install-time baked variables
  cat >> "$LAUNCHER" << BAKED_EOF
INSTALL_DIR="${_idir}"
MODELS_DIR="${_models}"
LLAMA_SERVER="${_llama_bin}"
VENV_DIR="${_venv}"
GPU_VENDOR="${_gpu_vendor}"
GPU_NAME="${_gpu_name}"
DEFAULT_CTX=${_ctx}
FLASH_ATTN_SUPPORT=${_fa}
NUMA_SUPPORT=${_numa}
MLOCK_SUPPORT=${_mlock}
LLAMA_PORT=8080
LLM_PROXY_PORT=4000
BAKED_EOF

  # Append the rest as a literal (no variable substitution)
  cat >> "$LAUNCHER" << 'LAUNCHER_BODY_EOF'

THREADS=$(( $(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4) - 2 ))
[ "$THREADS" -lt 1 ] && THREADS=1

source "$VENV_DIR/bin/activate"
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES  # macOS fork safety

clear
echo "========================================================"
echo "  AI LOCAL LAUNCHER"
echo "  GPU: $GPU_NAME"
echo "========================================================"
echo

# =========================
# LIST MODELS
# =========================
mapfile -t MODELS < <(find "$MODELS_DIR" -type f -name "*.gguf" | sort)
if [ ${#MODELS[@]} -eq 0 ]; then
  echo "[x] No models found in $MODELS_DIR"
  echo "    Re-run install.sh to download models."
  exit 1
fi

echo "Available models:"
for i in "${!MODELS[@]}"; do
  SIZE=$(du -sh "${MODELS[$i]}" 2>/dev/null | cut -f1 || echo "?")
  echo "  [$i] $(basename "${MODELS[$i]}") ($SIZE)"
done
echo
read -rp "Select model [0]: " MIDX
MIDX="${MIDX:-0}"
MODEL="${MODELS[$MIDX]}"
MODEL_NAME="$(basename "$MODEL" .gguf)"

[ ! -f "$MODEL" ] && echo "[x] Invalid selection" && exit 1

echo
echo "Model: $(basename "$MODEL")"
echo

# =========================
# MODE
# =========================
echo "  [1] llama.cpp CLI     (direct terminal chat)"
echo "  [2] Claude Code       (via LiteLLM proxy)"
echo "  [3] OpenCode          (via LiteLLM proxy)"
echo
read -rp "Mode [2]: " MODE
MODE="${MODE:-2}"
echo

# =========================
# STOP OLD SERVICES
# =========================
echo "[.] Stopping old services..."
pkill -f llama-server 2>/dev/null || true
pkill -f litellm      2>/dev/null || true
sleep 1

# =========================
# RECALCULATE VRAM AT RUNTIME
# =========================
VRAM_MB=0
if [ "$GPU_VENDOR" = "nvidia" ] && command -v nvidia-smi &>/dev/null; then
  RAW=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
  [[ "$RAW" =~ ^[0-9]+$ ]] && VRAM_MB="$RAW"
elif [ "$GPU_VENDOR" = "apple" ]; then
  MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  VRAM_MB=$(( MEM_BYTES / 1024 / 1024 * 70 / 100 ))
fi

# Dynamic context
if   [ "$VRAM_MB" -ge 16000 ]; then CTX=65536
elif [ "$VRAM_MB" -ge 8000  ]; then CTX=32768
elif [ "$VRAM_MB" -ge 4000  ]; then CTX=16384
else                                 CTX=$DEFAULT_CTX
fi

echo "[+] VRAM: ${VRAM_MB}MB | Context: ${CTX} tokens | Threads: $THREADS"

# =========================
# OPTIONAL FLAGS
# =========================
EXTRA_FLAGS=""
[ "$FLASH_ATTN_SUPPORT" = "true" ]                          && EXTRA_FLAGS="$EXTRA_FLAGS --flash-attn"
[ "$NUMA_SUPPORT" = "true" ] && [ "$GPU_VENDOR" != "apple" ] && EXTRA_FLAGS="$EXTRA_FLAGS --numa distribute"
[ "$MLOCK_SUPPORT" = "true" ]                                && EXTRA_FLAGS="$EXTRA_FLAGS --mlock"

# AMD env
if [ "$GPU_VENDOR" = "amd" ]; then
  export HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-10.3.0}"
  export ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
fi

# =========================
# START LLAMA.CPP
# =========================
echo "[+] Starting llama.cpp..."
# shellcheck disable=SC2086
"$LLAMA_SERVER" \
  -m "$MODEL" \
  --host 127.0.0.1 \
  --port $LLAMA_PORT \
  -c $CTX \
  -t $THREADS \
  -ngl 99 \
  -b 512 \
  -ub 512 \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --chat-template chatml \
  --metrics \
  $EXTRA_FLAGS \
  > /tmp/llama.log 2>&1 &
LLAMA_PID=$!

echo "[+] Waiting for llama.cpp (up to 30s)..."
for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:$LLAMA_PORT/v1/models" &>/dev/null; then
    echo "[+] llama.cpp ready."
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "[!] llama.cpp not responding. Log:"
    tail -10 /tmp/llama.log
  fi
done

LLAMA_MODEL_ID=$(curl -s "http://127.0.0.1:$LLAMA_PORT/v1/models" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null \
  || echo "$MODEL_NAME")
echo "[+] Model ID: $LLAMA_MODEL_ID"

# =========================
# LITELLM CONFIG
# =========================
LITELLM_CONFIG="/tmp/litellm_runtime.yaml"
cat > "$LITELLM_CONFIG" << YAML_EOF
model_list:
  - model_name: claude-sonnet-4-6
    litellm_params:
      model: openai/${LLAMA_MODEL_ID}
      api_base: http://127.0.0.1:${LLAMA_PORT}/v1
      api_key: dummy
  - model_name: claude-sonnet-4-5
    litellm_params:
      model: openai/${LLAMA_MODEL_ID}
      api_base: http://127.0.0.1:${LLAMA_PORT}/v1
      api_key: dummy
  - model_name: claude-haiku-4-5
    litellm_params:
      model: openai/${LLAMA_MODEL_ID}
      api_base: http://127.0.0.1:${LLAMA_PORT}/v1
      api_key: dummy
litellm_settings:
  drop_params: true
  set_verbose: false
YAML_EOF

# =========================
# START LITELLM
# =========================
echo "[+] Starting LiteLLM proxy..."
litellm \
  --config "$LITELLM_CONFIG" \
  --port $LLM_PROXY_PORT \
  --host 127.0.0.1 \
  --telemetry False \
  > /tmp/litellm.log 2>&1 &
LITELLM_PID=$!

for i in $(seq 1 15); do
  if curl -s "http://127.0.0.1:$LLM_PROXY_PORT/health" &>/dev/null; then
    echo "[+] LiteLLM ready."
    break
  fi
  sleep 1
  [ "$i" -eq 15 ] && echo "[!] LiteLLM not responding — check /tmp/litellm.log"
done

# =========================
# ENVIRONMENT FOR CLAUDE CODE
# =========================
unset ANTHROPIC_API_KEY 2>/dev/null || true
export ANTHROPIC_BASE_URL="http://127.0.0.1:$LLM_PROXY_PORT"
export ANTHROPIC_API_KEY="sk-ant-local-dummy-not-real"
export OPENAI_BASE_URL="http://127.0.0.1:$LLM_PROXY_PORT/v1"
export OPENAI_API_BASE="http://127.0.0.1:$LLM_PROXY_PORT/v1"
export OPENAI_API_KEY="dummy"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

echo ""
echo "========================================================"
echo "  Ready"
echo "  LLM Proxy : http://127.0.0.1:$LLM_PROXY_PORT/v1"
echo "  Llama.cpp : http://127.0.0.1:$LLAMA_PORT"
echo "  Context   : $CTX tokens"
echo "  Metrics   : http://127.0.0.1:$LLAMA_PORT/metrics"
echo "========================================================"
echo ""

cleanup() {
  echo ""
  echo "[.] Shutting down..."
  kill $LLAMA_PID $LITELLM_PID 2>/dev/null || true
  rm -f "$LITELLM_CONFIG"
}
trap cleanup EXIT

# =========================
# LAUNCH MODE
# =========================
case $MODE in
  1)
    echo "[+] Launching llama.cpp CLI..."
    exec "$LLAMA_SERVER" \
      -m "$MODEL" -ngl 99 -c $CTX -t $THREADS \
      --chat-template chatml -cnv
    ;;
  2)
    echo "[+] Launching Claude Code..."
    exec claude --model claude-sonnet-4-6
    ;;
  3)
    echo "[+] Launching OpenCode..."
    exec opencode
    ;;
  *)
    echo "[x] Invalid mode: $MODE"
    exit 1
    ;;
esac
LAUNCHER_BODY_EOF

  chmod +x "$LAUNCHER"
  log "Launcher written: $LAUNCHER"
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
  br
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║  Installation complete!                              ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  br
  echo -e "  ${BOLD}GPU:${NC}      $GPU_NAME"
  echo -e "  ${BOLD}Context:${NC}  $CTX tokens"
  echo -e "  ${BOLD}Models:${NC}   $MODELS_DIR"
  echo -e "  ${BOLD}Launcher:${NC} $LAUNCHER"
  br
  echo -e "  To start:   ${CYAN}bash $LAUNCHER${NC}"
  br
  echo -e "  To add more models later, re-run:"
  echo -e "  ${CYAN}bash $INSTALL_DIR/install.sh${NC}"
  br
  echo -e "  Full log:   $LOG"
  br
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  detect_os
  detect_gpu
  pick_context
  check_deps
  setup_venv
  build_llama
  detect_flags
  ask_hf_token
  show_model_menu
  download_models
  write_launcher
  print_summary
}

main
