#!/usr/bin/env bash
set -Eeuo pipefail

# Set the default OpenClaw model on macOS/Linux.
# This script only changes model settings. It does not install Node, pnpm, Git,
# OpenClaw, or rewrite API keys.

MODEL="${OPENCLAW_MODEL:-}"
IMAGE_MODEL="${OPENCLAW_IMAGE_MODEL:-}"
LIST=0
ALL=0
STATUS=0
RESTART_GATEWAY=0

print_info() { printf '  \033[34m[INFO]\033[0m %s\n' "$1"; }
print_ok() { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
print_warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; }
print_err() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }

usage() {
  cat <<'EOF'
OpenClaw model switcher

Usage:
  ./openclaw-set-model.sh
  ./openclaw-set-model.sh --model openai/gpt-5.1-codex
  ./openclaw-set-model.sh --model xiaomi/mimo-v2-flash --no-restart-gateway
  OPENCLAW_MODEL=xiaomi/mimo-v2-flash curl -fsSL https://your-domain/openclaw-set-model.sh | bash
  curl -fsSL https://your-domain/openclaw-set-model.sh | bash -s -- --model openai/gpt-5.1-codex

Options:
  -m, --model <id>          Set default text model
  -i, --image-model <id>    Set default image model
  --list                    List configured models
  --all                     With --list, show the full model catalog
  --status                  Show current model status
  --restart-gateway         Restart gateway even if it was not running before
  --no-restart-gateway      Do not restart gateway after changing the model
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)
      MODEL="${2:-}"
      shift 2
      ;;
    -i|--image-model)
      IMAGE_MODEL="${2:-}"
      shift 2
      ;;
    --list)
      LIST=1
      shift
      ;;
    --all)
      ALL=1
      shift
      ;;
    --status)
      STATUS=1
      shift
      ;;
    --restart-gateway)
      RESTART_GATEWAY=1
      shift
      ;;
    --no-restart-gateway)
      RESTART_GATEWAY=-1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$MODEL" ]]; then
        MODEL="$1"
        shift
      else
        print_err "Unknown argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

choose_model() {
  local choices=(
    "openai-codex/gpt-5.4-mini|OpenAI Codex GPT-5.4 Mini"
    "openai/gpt-5.1-codex|OpenAI GPT-5.1 Codex"
    "openai/o3|OpenAI o3"
    "openai/o4-mini|OpenAI o4-mini"
    "anthropic/claude-sonnet-4-5|Claude Sonnet 4.5"
    "anthropic/claude-opus-4-6|Claude Opus 4.6"
    "gemini/gemini-2.5-pro|Gemini 2.5 Pro"
    "gemini/gemini-2.5-flash|Gemini 2.5 Flash"
    "xiaomi/mimo-v2-flash|Xiaomi MiMo V2 Flash"
  )

  printf '\n  Select default OpenClaw model:\n\n' >&2
  local i=1
  local entry id label
  for entry in "${choices[@]}"; do
    id="${entry%%|*}"
    label="${entry#*|}"
    printf '   %d) %s (%s)\n' "$i" "$label" "$id" >&2
    i=$((i + 1))
  done
  printf '   0) Custom model id\n\n' >&2
  printf '  Choose [0-%d]: ' "${#choices[@]}" >&2
  read -r choice

  if [[ "$choice" == "0" ]]; then
    printf '  Enter model id: ' >&2
    read -r custom
    printf '%s\n' "$custom"
    return
  fi

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#choices[@]} )); then
    entry="${choices[$((choice - 1))]}"
    printf '%s\n' "${entry%%|*}"
    return
  fi

  print_warn "Invalid choice." >&2
  printf '\n'
}

gateway_is_running() {
  local output
  if ! output="$(openclaw gateway probe --json 2>/dev/null)"; then
    return 1
  fi
  printf '%s\n' "$output" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'
}

printf '\n  OpenClaw model switcher\n'
printf '  -----------------------\n'

if ! command -v openclaw >/dev/null 2>&1; then
  print_err "Cannot find openclaw in PATH."
  print_warn "Install OpenClaw first or open a new terminal after installation."
  exit 1
fi

print_info "Using: $(command -v openclaw)"
if version="$(openclaw -v 2>/dev/null | tr -d '\r')"; then
  [[ -n "$version" ]] && print_ok "OpenClaw $version detected"
fi

GATEWAY_WAS_RUNNING=0
if [[ "$LIST" -eq 0 && "$STATUS" -eq 0 ]]; then
  print_info "Checking gateway state..."
  if gateway_is_running; then
    GATEWAY_WAS_RUNNING=1
    print_ok "Gateway is running; it will be restarted after model update"
  else
    print_warn "Gateway is not running; model will be updated without starting it"
  fi
fi

if [[ "$LIST" -eq 1 ]]; then
  if [[ "$ALL" -eq 1 ]]; then
    exec openclaw models list --all --plain
  fi
  exec openclaw models list --plain
fi

if [[ "$STATUS" -eq 1 ]]; then
  exec openclaw models status --plain
fi

if [[ -z "$MODEL" ]]; then
  MODEL="$(choose_model)"
fi

if [[ -z "$MODEL" ]]; then
  print_err "No model selected."
  exit 1
fi

print_info "Setting default model: $MODEL"
openclaw models set "$MODEL"
print_ok "Default model updated"

if [[ -n "$IMAGE_MODEL" ]]; then
  print_info "Setting image model: $IMAGE_MODEL"
  openclaw models set-image "$IMAGE_MODEL"
  print_ok "Image model updated"
fi

printf '\n'
print_info "Current model status:"
openclaw models status --plain || true

if [[ "$RESTART_GATEWAY" -eq 1 || ( "$GATEWAY_WAS_RUNNING" -eq 1 && "$RESTART_GATEWAY" -ne -1 ) ]]; then
  printf '\n'
  print_info "Restarting OpenClaw gateway..."
  openclaw gateway restart
  openclaw gateway probe || true
fi

printf '\n'
print_ok "Done"
