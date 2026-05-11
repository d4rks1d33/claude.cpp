#!/usr/bin/env bash
# =============================================================================
# AI LOCAL STACK INSTALLER v14
# llama.cpp + LiteLLM + Models + Speculative Decoding + Optimized Launcher
# Multi-arch: macOS (Apple Silicon), Linux (NVIDIA/AMD/CPU), WSL2
# =============================================================================
set -uo pipefail

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
die()  { echo -e "${RED}[FATAL]${NC} $* (line ${BASH_LINENO[0]})" | tee -a "$LOG"; exit 1; }
trap 'die "Unexpected error at line $LINENO"' ERR

clear
echo -e "${BOLD}"
cat << 'BANNER'
╔══════════════════════════════════════════════════════╗
║          AI LOCAL STACK INSTALLER v14                 ║
║  llama.cpp + LiteLLM + Speculative Decoding           ║
║  macOS · Linux · WSL2 · NVIDIA · AMD · Apple Silicon  ║
╚══════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
info "Install dir: $INSTALL_DIR"
info "Log: $LOG"
br
mkdir -p "$MODELS_DIR"
echo "=== Install started: $(date) ===" > "$LOG"

activate_venv() { source "$VENV_DIR/bin/activate" || err "Failed to activate venv"; }

detect_os() {
  OS=""; ARCH=""
  case "$(uname -s)" in Linux*) OS="linux";; Darwin*) OS="macos";; *) err "Unsupported OS";; esac
  case "$(uname -m)" in x86_64) ARCH="x86_64";; aarch64|arm64) ARCH="arm64";; *) err "Unsupported arch";; esac
  log "OS: $OS | Arch: $ARCH"
}

detect_gpu() {
  GPU_VENDOR="cpu"; GPU_NAME="None (CPU only)"; VRAM_MB=0; TOTAL_RAM_GB=8
  if [ "$OS" = "macos" ]; then
    local chip; chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
    if echo "$chip" | grep -qi "apple"; then
      GPU_VENDOR="apple"; GPU_NAME="$chip"
      local mb; mb=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
      VRAM_MB=$(( mb / 1024 / 1024 * 70 / 100 ))
      TOTAL_RAM_GB=$(( mb / 1024 / 1024 / 1024 ))
      log "Apple Silicon: $GPU_NAME | RAM: ${TOTAL_RAM_GB}GB | Usable GPU: ${VRAM_MB}MB"; return
    fi
  fi
  if [ "$OS" = "linux" ]; then
    if command -v nvidia-smi &>/dev/null; then
      local rv rn
      rv=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
      rn=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)
      if [[ "$rv" =~ ^[0-9]+$ ]] && [ "$rv" -gt 0 ]; then
        VRAM_MB="$rv"; GPU_NAME="${rn:-NVIDIA GPU}"; GPU_VENDOR="nvidia"
        log "NVIDIA: $GPU_NAME (${VRAM_MB}MB)"; return
      fi
    fi
    if command -v rocm-smi &>/dev/null; then
      GPU_VENDOR="amd"; GPU_NAME="AMD GPU"; VRAM_MB=8000; log "AMD GPU"; return
    fi
  fi
  if command -v free &>/dev/null; then TOTAL_RAM_GB=$(free -g 2>/dev/null | awk '/Mem:/{print $2}' || echo 8); fi
  warn "No GPU — CPU only"
}

# Context: Claude Code system prompt ~34K. Min 40960 for Claude Code.
# CONSERVATIVE for <=16GB to avoid system freeze
pick_context() {
  CTX=8192
  if [ "$GPU_VENDOR" = "apple" ]; then
    if   [ "$TOTAL_RAM_GB" -ge 64 ]; then CTX=131072
    elif [ "$TOTAL_RAM_GB" -ge 32 ]; then CTX=65536
    elif [ "$TOTAL_RAM_GB" -ge 16 ]; then CTX=40960  # was 49152, too aggressive for 16GB
    else CTX=32768; fi
  elif [ "$GPU_VENDOR" = "nvidia" ] || [ "$GPU_VENDOR" = "amd" ]; then
    if   [ "$VRAM_MB" -ge 24000 ]; then CTX=131072
    elif [ "$VRAM_MB" -ge 16000 ]; then CTX=65536
    elif [ "$VRAM_MB" -ge 8000  ]; then CTX=49152
    elif [ "$VRAM_MB" -ge 6000  ]; then CTX=40960
    else CTX=16384; fi
  else
    if   [ "$TOTAL_RAM_GB" -ge 32 ]; then CTX=49152
    elif [ "$TOTAL_RAM_GB" -ge 16 ]; then CTX=40960
    else CTX=16384; fi
  fi
  log "Context: $CTX tokens"
}

check_deps() {
  log "Checking dependencies..."
  local missing=()
  for cmd in git curl python3 cmake make; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "Missing: ${missing[*]}"
    if [ "$OS" = "linux" ]; then
      if command -v apt-get &>/dev/null; then apt-get update -qq 2>>"$LOG"; apt-get install -y "${missing[@]}" build-essential libcurl4-openssl-dev pkg-config >>"$LOG" 2>&1
      elif command -v dnf &>/dev/null; then dnf install -y "${missing[@]}" gcc gcc-c++ make libcurl-devel >>"$LOG" 2>&1
      elif command -v pacman &>/dev/null; then pacman -Sy --noconfirm "${missing[@]}" base-devel curl >>"$LOG" 2>&1
      else err "Install manually: ${missing[*]}"; fi
    elif [ "$OS" = "macos" ]; then
      command -v brew &>/dev/null || err "Homebrew not found"; brew install "${missing[@]}" >>"$LOG" 2>&1
    fi
  fi
  local pv; pv=$(python3 -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo 0)
  [ "$pv" -lt 9 ] && err "Python 3.9+ required"
  log "Dependencies OK"
}

setup_venv() {
  log "Setting up venv..."
  [ ! -d "$VENV_DIR" ] && python3 -m venv "$VENV_DIR" >>"$LOG" 2>&1
  activate_venv
  pip install --upgrade pip --quiet >>"$LOG" 2>&1
  pip install "litellm[proxy]" "huggingface_hub[cli]" requests --quiet >>"$LOG" 2>&1 || err "pip install failed"
  if command -v huggingface-cli &>/dev/null; then HF_CLI_CMD="huggingface-cli"
  elif command -v hf &>/dev/null; then HF_CLI_CMD="hf"
  else err "HF CLI not found"; fi
  log "Venv ready | HF CLI: $HF_CLI_CMD"
}

build_llama() {
  log "Setting up llama.cpp..."
  if [ ! -d "$LLAMA_DIR/.git" ]; then
    git clone --depth=1 https://github.com/ggerganov/llama.cpp "$LLAMA_DIR" >>"$LOG" 2>&1 || err "git clone failed"
  else git -C "$LLAMA_DIR" pull --ff-only >>"$LOG" 2>&1 || warn "Could not pull"; fi
  local bd="$LLAMA_DIR/build"; mkdir -p "$bd"
  local cf="-DCMAKE_BUILD_TYPE=Release"
  case "$GPU_VENDOR" in
    nvidia) cf="$cf -DGGML_CUDA=ON";; amd) cf="$cf -DGGML_HIPBLAS=ON";;
    apple)  cf="$cf -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON";; cpu) cf="$cf -DGGML_AVX2=ON";;
  esac
  local nc; nc=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
  cmake -S "$LLAMA_DIR" -B "$bd" $cf >>"$LOG" 2>&1 || err "cmake configure failed"
  log "Building with $nc threads..."
  cmake --build "$bd" --config Release -j "$nc" >>"$LOG" 2>&1 || err "build failed"
  LLAMA_SERVER_BIN=""; LLAMA_CLI_BIN=""
  for c in "$bd/bin/llama-server" "$bd/llama-server"; do [ -f "$c" ] && [ -x "$c" ] && LLAMA_SERVER_BIN="$c" && break; done
  for c in "$bd/bin/llama-cli" "$bd/llama-cli"; do [ -f "$c" ] && [ -x "$c" ] && LLAMA_CLI_BIN="$c" && break; done
  [ -z "$LLAMA_SERVER_BIN" ] && err "llama-server not found"
  log "llama-server: $LLAMA_SERVER_BIN"
  [ -n "$LLAMA_CLI_BIN" ] && log "llama-cli: $LLAMA_CLI_BIN" || warn "llama-cli not found"
}

detect_flags() {
  log "Detecting flags..."
  FLASH_ATTN_SUPPORT=false; FLASH_ATTN_NEEDS_VALUE=false
  NUMA_SUPPORT=false; MLOCK_SUPPORT=false; PRIO_SUPPORT=false; SPEC_SUPPORT=false
  local h; h=$("$LLAMA_SERVER_BIN" --help 2>&1 || true)
  if echo "$h" | grep -q -- "--flash-attn"; then
    FLASH_ATTN_SUPPORT=true
    echo "$h" | grep -- "--flash-attn" | grep -qi "on\|off\|auto" && FLASH_ATTN_NEEDS_VALUE=true
  fi
  echo "$h" | grep -q -- "--numa"  && NUMA_SUPPORT=true
  echo "$h" | grep -q -- "--mlock" && MLOCK_SUPPORT=true
  echo "$h" | grep -q -- "--prio"  && PRIO_SUPPORT=true
  echo "$h" | grep -q -- "--spec-draft-model" && SPEC_SUPPORT=true
  log "flash=$FLASH_ATTN_SUPPORT | mlock=$MLOCK_SUPPORT | prio=$PRIO_SUPPORT | spec=$SPEC_SUPPORT"
}

configure_claude_settings() {
  log "Configuring Claude Code..."
  local d="$HOME/.claude" f="$HOME/.claude/settings.json"
  mkdir -p "$d"
  if [ -f "$f" ] && grep -q "CLAUDE_CODE_ATTRIBUTION_HEADER" "$f" 2>/dev/null; then log "Already configured"; return; fi
  [ -f "$f" ] && cp "$f" "$f.bak"
  cat > "$f" << 'EOF'
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
  },
  "attribution": { "commit": "", "pr": "" },
  "prefersReducedMotion": true,
  "terminalProgressBarEnabled": false
}
EOF
  log "ATTRIBUTION_HEADER=0 set (fixes 90% KV cache penalty)"
}

ask_hf_token() {
  br; echo -e "${BOLD}Hugging Face Token (optional — press Enter to skip)${NC}"; br
  read -rp "HF Token: " HF_TOKEN || true; HF_TOKEN="${HF_TOKEN:-}"
  [ -n "$HF_TOKEN" ] && log "HF token set" || { HF_TOKEN=""; warn "No HF token"; }
}

show_model_menu() {
  br
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  MODEL SELECTION — GPU: $GPU_NAME | VRAM: ${VRAM_MB}MB   ${NC}"
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  br
  local rec=""
  if [ "$VRAM_MB" -ge 16000 ]; then rec="2"
  elif [ "$VRAM_MB" -ge 8000 ]; then rec="1"
  else rec="4"; fi
  echo -e "  ${CYAN}[1]${NC} ${BOLD}Qwen2.5-Coder-7B Q4_K_M${NC}    (~4.7 GB) $([ "$rec" = "1" ] && echo -e "${GREEN}← RECOMMENDED${NC}")"
  echo -e "      Best coding 7B. 128K ctx. Spec-decode compatible."
  br
  echo -e "  ${CYAN}[2]${NC} ${BOLD}Qwen2.5-Coder-14B Q4_K_M${NC}   (~9.2 GB) $([ "$rec" = "2" ] && echo -e "${GREEN}← RECOMMENDED${NC}")"
  echo -e "      Best quality/speed. Needs 16GB+. Spec-decode compatible."
  br
  echo -e "  ${CYAN}[3]${NC} ${BOLD}Qwen2.5-7B-Instruct Q4_K_M${NC} (~4.7 GB)"
  echo -e "      General purpose. 128K ctx. Spec-decode compatible."
  br
  echo -e "  ${CYAN}[4]${NC} ${BOLD}Llama-3.1-8B Q4_K_M${NC}        (~4.9 GB) $([ "$rec" = "4" ] && echo -e "${GREEN}← RECOMMENDED${NC}")"
  echo -e "      Meta 8B. 128K ctx."
  br
  echo -e "  ${CYAN}[5]${NC} ${BOLD}Gemma-3-4B-IT Q4_K_M${NC}       (~3.0 GB)"
  echo -e "      Smallest. Good for <8GB."
  br
  echo -e "  ${YELLOW}[6]${NC} ${BOLD}Custom${NC} — HuggingFace repo + filename"
  br
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  br
  read -rp "Choice(s) [1-6, comma-sep, default=$rec]: " MODEL_CHOICE || true
  MODEL_CHOICE="${MODEL_CHOICE:-$rec}"
}

get_model_repo() { case "$1" in
  1) echo "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF";; 2) echo "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF";;
  3) echo "bartowski/Qwen2.5-7B-Instruct-GGUF";; 4) echo "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF";;
  5) echo "bartowski/gemma-3-4b-it-GGUF";; *) echo "";; esac; }
get_model_file() { case "$1" in
  1) echo "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf";; 2) echo "Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf";;
  3) echo "Qwen2.5-7B-Instruct-Q4_K_M.gguf";; 4) echo "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf";;
  5) echo "gemma-3-4b-it-Q4_K_M.gguf";; *) echo "";; esac; }
get_model_size() { case "$1" in
  1) echo "4.7 GB";; 2) echo "9.2 GB";; 3) echo "4.7 GB";; 4) echo "4.9 GB";; 5) echo "3.0 GB";; *) echo "?";; esac; }
get_draft_repo() { case "$1" in
  1|2) echo "bartowski/Qwen2.5-Coder-0.5B-Instruct-GGUF";; 3) echo "bartowski/Qwen2.5-0.5B-Instruct-GGUF";; *) echo "";; esac; }
get_draft_file() { case "$1" in
  1|2) echo "Qwen2.5-Coder-0.5B-Instruct-Q8_0.gguf";; 3) echo "Qwen2.5-0.5B-Instruct-Q8_0.gguf";; *) echo "";; esac; }

download_with_progress() {
  local repo="$1" file="$2" dir="$3" size="$4"
  br; echo -e "  ${CYAN}Downloading:${NC} $file (~$size)"; echo -e "  ${CYAN}From:${NC} $repo"; br
  "$HF_CLI_CMD" download "$repo" --include "$file" --local-dir "$dir" ${HF_TOKEN:+--token "$HF_TOKEN"}
  local rc=$?; br; return $rc
}

# Speculative decoding: only on >=24GB (draft model + extra KV cache don't fit on 16GB with long ctx)
ask_speculative() {
  SPEC_ENABLED=false; DRAFT_FILE_NAME=""
  local first="${MODEL_CHOICE%%,*}"; first="${first// /}"
  local dr; dr=$(get_draft_repo "$first")
  local df; df=$(get_draft_file "$first")
  DRAFT_FILE_NAME="$df"

  if [ -z "$dr" ]; then info "No draft model available for this model family."; return; fi
  if [ "$SPEC_SUPPORT" != "true" ]; then info "Your llama.cpp build doesn't support speculative decoding."; return; fi

  # Memory check: need at least 24GB for model + draft + context KV cache
  local avail_mem=0
  if [ "$GPU_VENDOR" = "apple" ]; then avail_mem=$TOTAL_RAM_GB
  elif [ "$VRAM_MB" -gt 0 ]; then avail_mem=$(( VRAM_MB / 1024 ))
  fi
  if [ "$avail_mem" -lt 24 ]; then
    info "Speculative decoding skipped: needs >=24GB (you have ${avail_mem}GB)."
    info "The draft model + KV cache would leave too little memory for the system."
    return
  fi

  br
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  SPECULATIVE DECODING (optional — up to 2.5x faster)    ${NC}"
  echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
  br
  echo -e "  Uses a tiny 0.5B draft model to predict tokens in parallel."
  echo -e "  Main model verifies them — ${GREEN}no quality loss${NC}."
  echo -e "  Extra VRAM: ~400MB | Draft: $df"
  br
  read -rp "Enable speculative decoding? [y/N]: " SPEC_ANS || true
  if [[ "${SPEC_ANS:-n}" =~ ^[yY] ]]; then
    SPEC_ENABLED=true
    local target="$MODELS_DIR/$df"
    if [ ! -f "$target" ]; then
      log "Downloading draft model..."
      download_with_progress "$dr" "$df" "$MODELS_DIR" "~400 MB" || warn "Draft download failed"
    else log "Draft exists: $df"; fi
  fi
}

download_models() {
  activate_venv
  IFS=',' read -ra CHOICES <<< "$MODEL_CHOICE"
  for RAW in "${CHOICES[@]}"; do
    local choice="${RAW// /}"
    if [ "$choice" = "6" ]; then
      read -rp "  HF repo: " CR || true; read -rp "  Filename: " CF || true
      [ -n "$CR" ] && [ -n "$CF" ] && download_with_progress "$CR" "$CF" "$MODELS_DIR" "?" || true; continue
    fi
    [[ "$choice" =~ ^[1-5]$ ]] || { warn "Invalid: '$choice'"; continue; }
    local repo file target size
    repo=$(get_model_repo "$choice"); file=$(get_model_file "$choice")
    target="$MODELS_DIR/$file"; size=$(get_model_size "$choice")
    [ -f "$target" ] && { log "Exists: $file"; continue; }
    log "Downloading $file (~$size)..."
    download_with_progress "$repo" "$file" "$MODELS_DIR" "$size" && \
      [ -f "$target" ] && log "Done: $file" || warn "Failed: $file"
  done
}

# =============================================================================
write_launcher() {
  log "Writing launcher: $LAUNCHER"
  cat > "$LAUNCHER" << 'EOF_H'
#!/usr/bin/env bash
set -uo pipefail
EOF_H
  cat >> "$LAUNCHER" << EOF_V
INSTALL_DIR="${INSTALL_DIR}"
MODELS_DIR="${MODELS_DIR}"
LLAMA_SERVER="${LLAMA_SERVER_BIN}"
LLAMA_CLI="${LLAMA_CLI_BIN:-}"
VENV_DIR="${VENV_DIR}"
GPU_VENDOR="${GPU_VENDOR}"
GPU_NAME="${GPU_NAME}"
TOTAL_RAM_GB=${TOTAL_RAM_GB}
DEFAULT_CTX=${CTX}
FLASH_ATTN_SUPPORT=${FLASH_ATTN_SUPPORT}
FLASH_ATTN_NEEDS_VALUE=${FLASH_ATTN_NEEDS_VALUE}
NUMA_SUPPORT=${NUMA_SUPPORT}
MLOCK_SUPPORT=${MLOCK_SUPPORT}
PRIO_SUPPORT=${PRIO_SUPPORT}
SPEC_ENABLED=${SPEC_ENABLED}
DRAFT_FILE_NAME="${DRAFT_FILE_NAME}"
LLAMA_PORT=8080
LLM_PROXY_PORT=4000
EOF_V
  cat >> "$LAUNCHER" << 'EOF_B'

LLAMA_PID=""; LITELLM_PID=""
force_cleanup() {
  echo ""; echo "[.] Shutting down..."
  for p in $LLAMA_PID $LITELLM_PID; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  sleep 1
  for p in $LLAMA_PID $LITELLM_PID; do
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
  done
  pkill -9 -f "llama-server.*--port $LLAMA_PORT" 2>/dev/null || true
  pkill -9 -f "litellm.*--port $LLM_PROXY_PORT" 2>/dev/null || true
  sleep 0.5
  local s; s=$(ps aux 2>/dev/null | grep -E "llama-server|litellm" | grep -v grep || true)
  [ -n "$s" ] && echo "$s" | awk '{print $2}' | while read -r x; do kill -9 "$x" 2>/dev/null; done
  rm -f /tmp/litellm_runtime.yaml 2>/dev/null
  echo "[+] Stopped."
}
trap force_cleanup EXIT INT TERM HUP QUIT

TOTAL_CORES=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
THREADS=$(( TOTAL_CORES - 4 ))
[ "$THREADS" -lt 2 ] && THREADS=2

source "$VENV_DIR/bin/activate"
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

clear
echo "========================================================"
echo "  AI LOCAL LAUNCHER"
echo "  GPU: $GPU_NAME | Cores: $TOTAL_CORES | Threads: $THREADS"
echo "  RAM: ${TOTAL_RAM_GB}GB"
echo "========================================================"
echo

# =========================================================================
# macOS WIRED MEMORY — conservative based on total RAM
# <=16GB: 60% (leave 6.4GB for system — prevents freezes)
# 32GB:   70%
# 64GB+:  75%
# =========================================================================
if [ "$GPU_VENDOR" = "apple" ]; then
  if   [ "$TOTAL_RAM_GB" -ge 64 ]; then WIRED_PCT=75
  elif [ "$TOTAL_RAM_GB" -ge 32 ]; then WIRED_PCT=70
  else WIRED_PCT=60; fi
  WMB=$(( TOTAL_RAM_GB * 1024 * WIRED_PCT / 100 ))
  CUR=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
  if [ "$WMB" -gt "$CUR" ] 2>/dev/null; then
    echo "[+] GPU wired memory: ${CUR}MB -> ${WMB}MB (${WIRED_PCT}% of ${TOTAL_RAM_GB}GB)"
    sudo sysctl iogpu.wired_limit_mb="$WMB" 2>/dev/null || echo "[!] Could not set — run with sudo"
  fi
fi

pkill -9 -f "llama-server.*--port $LLAMA_PORT" 2>/dev/null || true
pkill -9 -f "litellm.*--port $LLM_PROXY_PORT" 2>/dev/null || true
sleep 0.5

# =========================================================================
# MODEL SELECTION
# =========================================================================
MODELS=()
while IFS= read -r -d '' f; do MODELS+=("$f")
done < <(find "$MODELS_DIR" -type f -name "*.gguf" ! -name "*0.5B*" -print0 | sort -z)
[ ${#MODELS[@]} -eq 0 ] && echo "[x] No models found" && exit 1

echo "Available models:"
for i in "${!MODELS[@]}"; do
  S=$(du -sh "${MODELS[$i]}" 2>/dev/null | cut -f1 || echo "?")
  echo "  [$i] $(basename "${MODELS[$i]}") ($S)"
done
echo; read -rp "Select model [0]: " MIDX; MIDX="${MIDX:-0}"
MODEL="${MODELS[$MIDX]}"; MODEL_NAME="$(basename "$MODEL" .gguf)"
[ ! -f "$MODEL" ] && echo "[x] Invalid" && exit 1
echo "Model: $(basename "$MODEL")"

DRAFT_MODEL=""
if [ "$SPEC_ENABLED" = "true" ] && [ -n "$DRAFT_FILE_NAME" ]; then
  local_draft="$MODELS_DIR/$DRAFT_FILE_NAME"
  if [ -f "$local_draft" ]; then
    DRAFT_MODEL="$local_draft"
    echo "Draft: $(basename "$DRAFT_MODEL") (speculative decoding ON)"
  else
    echo "[!] Draft not found — spec decode disabled"
    SPEC_ENABLED=false
  fi
fi
echo

[ -n "$LLAMA_CLI" ] && [ -f "$LLAMA_CLI" ] && echo "  [1] llama.cpp CLI     (direct chat)"
echo "  [2] Claude Code       (via LiteLLM proxy)"
echo "  [3] OpenCode          (via LiteLLM proxy)"
echo; read -rp "Mode [2]: " MODE; MODE="${MODE:-2}"; echo
[ "$MODE" = "1" ] && { [ -z "$LLAMA_CLI" ] || [ ! -f "$LLAMA_CLI" ]; } && echo "[x] No llama-cli" && exit 1

# =========================================================================
# VRAM & CONTEXT — runtime, conservative for low-RAM systems
# =========================================================================
VRAM_MB=0
if [ "$GPU_VENDOR" = "nvidia" ] && command -v nvidia-smi &>/dev/null; then
  R=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
  [[ "$R" =~ ^[0-9]+$ ]] && VRAM_MB="$R"
elif [ "$GPU_VENDOR" = "apple" ]; then
  VRAM_MB=$(( TOTAL_RAM_GB * 1024 * 70 / 100 ))
fi

# Context: conservative for <=16GB to prevent system freeze
if [ "$GPU_VENDOR" = "apple" ]; then
  if   [ "$TOTAL_RAM_GB" -ge 64 ]; then CTX=131072
  elif [ "$TOTAL_RAM_GB" -ge 32 ]; then CTX=65536
  elif [ "$TOTAL_RAM_GB" -ge 16 ]; then CTX=40960
  else CTX=32768; fi
elif [ "$VRAM_MB" -ge 24000 ]; then CTX=131072
elif [ "$VRAM_MB" -ge 16000 ]; then CTX=65536
elif [ "$VRAM_MB" -ge 8000  ]; then CTX=49152
elif [ "$VRAM_MB" -ge 6000  ]; then CTX=40960
else CTX=$DEFAULT_CTX; fi

[ "$MODE" = "2" ] && [ "$CTX" -lt 40960 ] && echo "[!] WARNING: Context $CTX may be too small for Claude Code"
echo "[+] VRAM: ${VRAM_MB}MB | Context: $CTX | Threads: $THREADS/$TOTAL_CORES"

# =========================================================================
# FLAGS — memory-safe: no --mlock on <=16GB (causes system freeze)
# =========================================================================
EXTRA=""
if [ "$FLASH_ATTN_SUPPORT" = "true" ] && [ "$GPU_VENDOR" != "amd" ]; then
  [ "$FLASH_ATTN_NEEDS_VALUE" = "true" ] && EXTRA="$EXTRA --flash-attn on" || EXTRA="$EXTRA --flash-attn"
fi

# mlock only on systems with enough headroom (>=32GB)
if [ "$MLOCK_SUPPORT" = "true" ]; then
  local_ram=$TOTAL_RAM_GB
  [ "$GPU_VENDOR" = "nvidia" ] && local_ram=$(( VRAM_MB / 1024 ))
  if [ "$local_ram" -ge 32 ]; then
    EXTRA="$EXTRA --mlock"
  fi
fi

[ "$PRIO_SUPPORT" = "true" ]  && EXTRA="$EXTRA --prio 2"
[ "$NUMA_SUPPORT" = "true" ] && [ "$GPU_VENDOR" = "cpu" ] && EXTRA="$EXTRA --numa distribute"

if [ "$GPU_VENDOR" = "cpu" ]; then BATCH=512; UBATCH=512; NGL=0
else BATCH=2048; UBATCH=2048; NGL=99; fi

SPEC_FLAGS=""
if [ "$SPEC_ENABLED" = "true" ] && [ -n "$DRAFT_MODEL" ]; then
  SPEC_FLAGS="--spec-draft-model $DRAFT_MODEL --spec-draft-ngl $NGL --spec-draft-n-max 16 --spec-draft-n-min 5"
  echo "[+] Speculative decoding: ON (max=16, min=5)"
fi

[ "$GPU_VENDOR" = "amd" ] && {
  export HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION:-10.3.0}"
  export ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
}

# =========================================================================
# CLI MODE
# =========================================================================
if [ "$MODE" = "1" ]; then
  LLAMA_PID=""; LITELLM_PID=""
  echo "[+] CLI: -ngl $NGL -c $CTX -t $THREADS -b $BATCH $SPEC_FLAGS $EXTRA"
  # shellcheck disable=SC2086
  exec "$LLAMA_CLI" -m "$MODEL" -ngl $NGL -c $CTX -t $THREADS \
    -b $BATCH -ub $UBATCH --cache-type-k q8_0 --cache-type-v q8_0 \
    -cnv $SPEC_FLAGS $EXTRA
fi

# =========================================================================
# SERVER MODE
# =========================================================================
echo "[+] Server: -ngl $NGL -c $CTX -t $THREADS -b $BATCH $SPEC_FLAGS $EXTRA"
# shellcheck disable=SC2086
"$LLAMA_SERVER" -m "$MODEL" --host 127.0.0.1 --port $LLAMA_PORT \
  -ngl $NGL -c $CTX -t $THREADS -b $BATCH -ub $UBATCH \
  --cache-type-k q8_0 --cache-type-v q8_0 --metrics \
  $SPEC_FLAGS $EXTRA > /tmp/llama.log 2>&1 &
LLAMA_PID=$!

echo "[+] Waiting for llama.cpp (up to 90s)..."
for i in $(seq 1 90); do
  curl -s "http://127.0.0.1:$LLAMA_PORT/v1/models" &>/dev/null && echo "[+] Ready (${i}s)." && break
  sleep 1; [ "$i" -eq 90 ] && { echo "[!] Failed:"; tail -20 /tmp/llama.log; exit 1; }
done

MID=$(curl -s "http://127.0.0.1:$LLAMA_PORT/v1/models" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "$MODEL_NAME")

cat > /tmp/litellm_runtime.yaml << YAML
model_list:
  - model_name: claude-sonnet-4-6
    litellm_params:
      model: openai/${MID}
      api_base: http://127.0.0.1:${LLAMA_PORT}/v1
      api_key: dummy
  - model_name: claude-sonnet-4-5
    litellm_params:
      model: openai/${MID}
      api_base: http://127.0.0.1:${LLAMA_PORT}/v1
      api_key: dummy
  - model_name: claude-haiku-4-5
    litellm_params:
      model: openai/${MID}
      api_base: http://127.0.0.1:${LLAMA_PORT}/v1
      api_key: dummy
litellm_settings:
  drop_params: true
  set_verbose: false
YAML

echo "[+] Starting LiteLLM..."
litellm --config /tmp/litellm_runtime.yaml --port $LLM_PROXY_PORT \
  --host 127.0.0.1 --telemetry False > /tmp/litellm.log 2>&1 &
LITELLM_PID=$!

for i in $(seq 1 30); do
  curl -s "http://127.0.0.1:$LLM_PROXY_PORT/health" &>/dev/null && echo "[+] LiteLLM ready (${i}s)." && break
  sleep 1; [ "$i" -eq 30 ] && { echo "[!] LiteLLM failed:"; tail -20 /tmp/litellm.log; }
done

unset ANTHROPIC_API_KEY 2>/dev/null || true
export ANTHROPIC_BASE_URL="http://127.0.0.1:$LLM_PROXY_PORT"
export ANTHROPIC_API_KEY="sk-ant-local-dummy-not-real"
export OPENAI_BASE_URL="http://127.0.0.1:$LLM_PROXY_PORT/v1"
export OPENAI_API_BASE="http://127.0.0.1:$LLM_PROXY_PORT/v1"
export OPENAI_API_KEY="dummy"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

SL="OFF"; [ "$SPEC_ENABLED" = "true" ] && SL="ON (up to 2.5x faster)"
ML="OFF"; echo "$EXTRA" | grep -q "mlock" && ML="ON"
echo ""
echo "========================================================"
echo "  Ready"
echo "  Proxy   : http://127.0.0.1:$LLM_PROXY_PORT/v1"
echo "  Server  : http://127.0.0.1:$LLAMA_PORT"
echo "  Context : $CTX | Batch: $BATCH | GPU: $NGL layers"
echo "  Threads : $THREADS/$TOTAL_CORES | mlock: $ML | Spec: $SL"
echo "  Metrics : http://127.0.0.1:$LLAMA_PORT/metrics"
echo "========================================================"
echo ""

case $MODE in
  2) echo "[+] Claude Code... (Ctrl+C or /exit to stop)"; echo ""; claude --model claude-sonnet-4-6;;
  3) echo "[+] OpenCode..."; opencode;;
  *) echo "[x] Invalid"; exit 1;;
esac
exit 0
EOF_B
  chmod +x "$LAUNCHER"
  log "Launcher written: $LAUNCHER"
}

print_summary() {
  local sm="disabled"; [ "$SPEC_ENABLED" = "true" ] && sm="ENABLED"
  br
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║  Installation complete!                              ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  br
  echo -e "  ${BOLD}GPU:${NC}        $GPU_NAME (${TOTAL_RAM_GB}GB)"
  echo -e "  ${BOLD}Context:${NC}    $CTX tokens"
  echo -e "  ${BOLD}Spec decode:${NC} $sm"
  echo -e "  ${BOLD}Launcher:${NC}   $LAUNCHER"
  br
  echo -e "  To start: ${CYAN}bash $LAUNCHER${NC}"
  br
  echo -e "  ${YELLOW}OPTIMIZATIONS:${NC}"
  echo -e "  • ATTRIBUTION_HEADER=0 — fixes 90% KV cache penalty"
  echo -e "  • flash-attn + KV q8_0 — halves cache memory"
  echo -e "  • batch 2048 — 2-3x faster prompt processing"
  [ "$TOTAL_RAM_GB" -ge 32 ] && echo -e "  • mlock — prevents paging latency spikes"
  [ "$TOTAL_RAM_GB" -lt 32 ] && echo -e "  • mlock DISABLED — ${TOTAL_RAM_GB}GB RAM, prevents system freeze"
  echo -e "  • prio 2 — reduces scheduling jitter"
  [ "$OS" = "macos" ] && echo -e "  • iogpu.wired_limit_mb — conservative GPU allocation"
  [ "$SPEC_ENABLED" = "true" ] && echo -e "  • speculative decoding — up to 2.5x faster generation"
  br; echo -e "  Log: $LOG"; br
}

main() {
  detect_os; detect_gpu; pick_context; check_deps; setup_venv
  build_llama; detect_flags; configure_claude_settings; ask_hf_token
  show_model_menu; download_models; ask_speculative; write_launcher; print_summary
}
main
