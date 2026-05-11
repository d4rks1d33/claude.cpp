# claude.cpp

> Run Claude Code and OpenCode against a **fully local LLM** — no API costs, no data leaving your machine.
> One installer. One launcher. Works on Linux (NVIDIA / AMD / CPU) and macOS (Apple Silicon / Intel).

<img width="686" height="286" alt="image" src="https://github.com/user-attachments/assets/5707a23e-93c8-45e0-bb43-319f52d63b3f" />


---

## What is this?

**claude.cpp** wires three things together automatically:

| Component | Role |
|-----------|------|
| [llama.cpp](https://github.com/ggerganov/llama.cpp) | Runs the local model (CUDA / Metal / ROCm / CPU) |
| [LiteLLM proxy](https://github.com/BerriAI/litellm) | Translates Anthropic API calls → OpenAI-compatible local endpoint |
| `launcher.sh` | Auto-generated, hardware-optimized start script |

Claude Code thinks it's talking to Anthropic. It's actually talking to your GPU.

---

## Features

- **One-command install** — detects your GPU, builds llama.cpp with the right flags, installs dependencies
- **Hardware-aware optimization** — context window, KV cache quantization, flash attention, NUMA, mlock all tuned per device
- **Model downloader** — pick from a curated list of top open-source models (Qwen2.5-Coder, Llama 3, Gemma 3, and more)
- **Supports Claude Code and OpenCode** out of the box
- **Everything in one folder** — models, binaries, venv, configs, launcher all co-located
- **Re-runnable** — run the installer again to add more models; existing files are skipped

---

## Requirements

| | Linux | macOS |
|---|---|---|
| GPU | NVIDIA (CUDA) / AMD (ROCm) / CPU | Apple Silicon (Metal) / Intel |
| RAM | 8 GB minimum, 16 GB recommended | 8 GB minimum |
| Python | 3.9+ | 3.9+ |
| Other | `git`, `cmake`, `curl`, `make` | Homebrew, Xcode CLT |

> **WSL2 users:** fully supported. Make sure your NVIDIA drivers are installed on the Windows side and `nvidia-smi` works inside WSL.

---

## Quick start

```bash
# 1. Clone the repo
git clone https://github.com/d4rks1d33/claude.cpp
cd claude.cpp

# 2. Run the installer
bash install.sh
```

The installer will:
1. Detect your OS, architecture, and GPU
2. Install missing system dependencies
3. Create a Python virtualenv and install `litellm` + `huggingface_hub`
4. Clone and build llama.cpp with optimal flags for your hardware
5. Ask for an optional Hugging Face token (needed for gated models)
6. Show a model menu — pick one or several
7. Download selected models to `./models/`
8. Generate `./launcher.sh` baked for your exact hardware

```bash
# 3. Launch
bash launcher.sh
```

<img width="908" height="557" alt="image" src="https://github.com/user-attachments/assets/e811335c-0658-4aaf-940a-b870ff668d78" />
<img width="981" height="957" alt="image" src="https://github.com/user-attachments/assets/8d8068fe-4403-49c1-b896-2508d7c6f8e6" />


---

## Launcher

When you run `launcher.sh` you get:

```
========================================================
  AI LOCAL LAUNCHER
  GPU: NVIDIA GeForce RTX 3050 Ti Laptop GPU
========================================================

Available models:
  [0] Qwen2.5-Coder-7B-Instruct-IQ4_XS.gguf (4.3G)
  [1] gemma-3-4b-it-IQ4_XS.gguf (2.5G)

Select model [0]: 0

  [1] llama.cpp CLI     (direct terminal chat)
  [2] Claude Code       (via LiteLLM proxy)
  [3] OpenCode          (via LiteLLM proxy)

Mode [2]:
```

<img width="786" height="610" alt="image" src="https://github.com/user-attachments/assets/540566a4-6fdd-4f7f-8790-6d134f6ecfe9" />


---

## Supported models (installer menu)

| # | Model | Size | Best for |
|---|-------|------|----------|
| 1 | Qwen2.5-Coder-7B-Instruct IQ4_XS | ~4.3 GB | Coding — closest open alternative to Claude Sonnet |
| 2 | Qwen2.5-Coder-14B-Instruct IQ4_XS | ~8.5 GB | Higher quality coding, runs GPU+RAM split |
| 3 | Qwen2.5-7B-Instruct IQ4_XS | ~4.3 GB | General purpose — reasoning, math, multilingual |
| 4 | Gemma-3-4B-IT IQ4_XS | ~2.5 GB | Fastest, lowest VRAM, good for quick tasks |
| 5 | Llama-3.1-8B-Instruct IQ4_XS | ~4.7 GB | Well-rounded, huge community support |
| 6 | Custom | — | Any GGUF from HuggingFace |

> To add more models after installation, just re-run `bash install.sh` — it skips what's already done and lets you pick additional models.

---

## Hardware optimization details

The launcher is generated with flags tuned for your device at install time:

| Flag | Effect | Condition |
|------|--------|-----------|
| `-ngl 99` | All layers on GPU | Always |
| `--cache-type-k q8_0` | KV cache compressed ~50% | Always |
| `--cache-type-v q8_0` | V cache compressed ~50% | Always |
| `--flash-attn` | Faster attention, less VRAM | If build supports it |
| `--mlock` | Pin model in RAM, prevent swap | If supported |
| `--numa distribute` | Better CPU throughput on multi-socket | Linux non-Apple |
| `-DGGML_CUDA=ON` | NVIDIA GPU acceleration | NVIDIA detected |
| `-DGGML_METAL=ON` | Apple Silicon GPU acceleration | macOS Apple Silicon |
| `-DGGML_HIPBLAS=ON` | AMD GPU acceleration | AMD ROCm detected |

Context window is auto-selected based on VRAM:

| VRAM / Unified Memory | Context |
|-----------------------|---------|
| 4 GB | 16,384 tokens |
| 8 GB | 32,768 tokens |
| 16 GB+ | 65,536 tokens |

---

## How the proxy works

```
Claude Code / OpenCode
        │
        │  POST /v1/messages (Anthropic API format)
        ▼
  LiteLLM proxy :4000
        │
        │  POST /v1/chat/completions (OpenAI format)
        ▼
  llama.cpp server :8080
        │
        ▼
  Local GGUF model (your GPU)
```

Claude Code sees `ANTHROPIC_BASE_URL=http://127.0.0.1:4000` and a dummy API key. LiteLLM translates the request format and forwards to llama.cpp. All traffic stays on localhost.

---

## Project structure

```
claude.cpp/
├── install.sh          # Installer — run this first
├── launcher.sh         # Generated by installer — run this to start
├── models/             # Downloaded GGUF models go here
├── llama.cpp/          # Cloned and built by installer
├── venv/               # Python virtualenv (litellm, huggingface_hub)
└── install.log         # Full install log for debugging
```

---

## Troubleshooting

**llama.cpp not responding after launch**
```bash
tail -20 /tmp/llama.log
```
Common causes: not enough VRAM (try a smaller model or lower context), CUDA not available in WSL (check `nvidia-smi`).

**LiteLLM not responding**
```bash
tail -20 /tmp/litellm.log
```
Common cause: port 4000 already in use. Kill old processes: `pkill -f litellm`.

**Claude Code still shows "API Usage Billing"**

Run this once to clear any stored API key helper:
```bash
export ANTHROPIC_API_KEY='your_api_key_here'
```
Then relaunch via `launcher.sh`.

**Model download fails**

Some models (Llama 3, Gemma) require a Hugging Face account and accepted license. Get a token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) and re-run the installer.

**Build fails on CUDA**

Make sure CUDA toolkit is installed:
```bash
nvcc --version
```
If missing: `apt install nvidia-cuda-toolkit` (or install from [developer.nvidia.com/cuda-downloads](https://developer.nvidia.com/cuda-downloads)).

---

## Adding models manually

Drop any `.gguf` file into the `models/` folder. The launcher auto-detects everything in that directory.

```bash
# Example: download manually with huggingface-cli
source venv/bin/activate
huggingface-cli download bartowski/Mistral-7B-Instruct-v0.3-GGUF \
  --include "Mistral-7B-Instruct-v0.3-IQ4_XS.gguf" \
  --local-dir ./models/
```

---

## Contributing

PRs welcome. Main areas where help would be great:

- Testing on AMD ROCm
- Testing on macOS Apple Silicon (M1/M2/M3/M4)
- Adding more curated models to the installer menu
- Windows native support (currently WSL2 only on Windows)

---

## License

MIT

---

## Acknowledgements

- [llama.cpp](https://github.com/ggerganov/llama.cpp) by Georgi Gerganov
- [LiteLLM](https://github.com/BerriAI/litellm) by BerriAI
- [bartowski](https://huggingface.co/bartowski) for the GGUF quantizations

