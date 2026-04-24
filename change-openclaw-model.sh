#!/usr/bin/env bash
set -Eeuo pipefail

# OpenClaw 中文模型配置与切换脚本 (macOS/Linux)
# 在线使用:
#   curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/change-openclaw-model.sh | bash

PROVIDER="${OPENCLAW_PROVIDER:-}"
API_KEY="${OPENCLAW_API_KEY:-}"
MODEL="${OPENCLAW_MODEL:-}"
BASE_URL="${OPENCLAW_BASE_URL:-}"
LIST=0
ALL=0
STATUS=0
RESTART_GATEWAY=0

print_info() { printf '  \033[34m[INFO]\033[0m %s\n' "$1"; }
print_ok() { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
print_warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; }
print_err() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }
step() { printf '\n━━━ %s ━━━\n\n' "$1"; }

usage() {
  cat <<'EOF'
OpenClaw 中文模型配置与切换脚本

用法:
  ./change-openclaw-model.sh
  ./change-openclaw-model.sh --provider qwen --api-key sk-xxx --model qwen3.6-flash
  curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/change-openclaw-model.sh | bash

参数:
  --provider <name>       厂商: deepseek/minimax/qwen/volcengine/zai/moonshot/qianfan/xiaomi/openai/anthropic/custom
  --api-key <key>         API Key
  --model <id>            直接指定 Model ID
  --base-url <url>        自定义 Base URL
  --list                  列出模型
  --all                   配合 --list 显示完整模型目录
  --status                显示当前模型
  --restart-gateway       无论 gateway 是否已运行，都执行 restart
  --no-restart-gateway    不重启 gateway
  -h, --help              显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="${2:-}"; shift 2 ;;
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    -m|--model) MODEL="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --list) LIST=1; shift ;;
    --all) ALL=1; shift ;;
    --status) STATUS=1; shift ;;
    --restart-gateway) RESTART_GATEWAY=1; shift ;;
    --no-restart-gateway) RESTART_GATEWAY=-1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print_err "未知参数: $1"; usage; exit 1 ;;
  esac
done

provider_keys=(1 2 3 4 5 6 7 8 9 10 11)
provider_names=(deepseek minimax qwen volcengine zai moonshot qianfan xiaomi openai anthropic custom)
provider_labels=("DeepSeek" "MiniMax" "阿里百炼 / Qwen" "火山方舟 / Doubao" "智谱 / BigModel" "Moonshot / Kimi" "百度千帆" "小米 MiMo" "OpenAI" "Anthropic" "自定义兼容接口")
provider_modes=(custom custom custom custom custom custom custom builtin builtin builtin custom)
provider_base_urls=("https://api.deepseek.com" "https://api.minimax.io/v1" "https://dashscope.aliyuncs.com/compatible-mode/v1" "https://ark.cn-beijing.volces.com/api/coding/v3" "https://open.bigmodel.cn/api/paas/v4" "https://api.moonshot.ai/v1" "https://qianfan.baidubce.com/v2" "" "" "" "")
provider_auth=("" "" "" "" "" "" "" "xiaomi-api-key" "openai-api-key" "apiKey" "")
provider_keyflag=("" "" "" "" "" "" "" "--xiaomi-api-key" "--openai-api-key" "--anthropic-api-key" "")

read_required() {
  local prompt="$1"
  local value="${2:-}"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return
  fi
  while true; do
    printf '%s' "$prompt" >&2
    read -r value
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return
    fi
    print_warn "不能为空，请重新输入" >&2
  done
}

provider_index_by_name_or_key() {
  local value="$1"
  local i
  for i in "${!provider_names[@]}"; do
    if [[ "${provider_names[$i]}" == "$value" || "${provider_keys[$i]}" == "$value" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

select_provider() {
  local idx choice
  if [[ -n "$PROVIDER" ]]; then
    if idx="$(provider_index_by_name_or_key "$PROVIDER")"; then
      printf '%s\n' "$idx"
      return
    fi
    print_warn "未识别的厂商: $PROVIDER，将进入交互选择" >&2
  fi

  printf '  请选择 AI 厂商:\n\n' >&2
  local i
  for i in "${!provider_names[@]}"; do
    printf '  %2s) %-10s - %s\n' "${provider_keys[$i]}" "${provider_names[$i]}" "${provider_labels[$i]}" >&2
  done
  printf '   0) 仅切换模型 / 跳过厂商配置\n\n' >&2
  printf '  请输入编号 [0-11]: ' >&2
  read -r choice
  if [[ "$choice" == "0" ]]; then
    printf '\n'
    return
  fi
  provider_index_by_name_or_key "$choice" || true
}

models_for_provider() {
  case "$1" in
    deepseek)
      printf '%s\n' \
        "deepseek-v4-pro|DeepSeek V4 Pro|文本|强推理/复杂任务" \
        "deepseek-v4-flash|DeepSeek V4 Flash|文本|高速/低成本" \
        "deepseek-chat|DeepSeek Chat|文本|旧别名，2026-07-24 弃用" \
        "deepseek-reasoner|DeepSeek Reasoner|文本|旧别名，2026-07-24 弃用" ;;
    minimax)
      printf '%s\n' \
        "MiniMax-M2.7|MiniMax M2.7|文本|默认推荐" \
        "MiniMax-M2.7-highspeed|MiniMax M2.7 Highspeed|文本|高速版" \
        "MiniMax-M2.5|MiniMax M2.5|文本|旧一代高性价比" \
        "MiniMax-M2.5-highspeed|MiniMax M2.5 Highspeed|文本|旧一代高速版" ;;
    qwen)
      printf '%s\n' \
        "qwen3.6-max-preview|Qwen3.6 Max Preview|文本|最高推理能力，成本较高" \
        "qwen3.6-plus|Qwen3.6 Plus|文本/图片|1M 上下文，主推" \
        "qwen3.6-flash|Qwen3.6 Flash|文本/图片|1M 上下文，低成本" \
        "qwen3.6-plus-2026-04-02|Qwen3.6 Plus 快照|文本/图片|固定快照" \
        "qwen3.6-flash-2026-04-16|Qwen3.6 Flash 快照|文本/图片|固定快照" \
        "qwen3.6-35b-a3b|Qwen3.6 35B A3B|文本/图片|开源/轻量 MoE" \
        "qwen3-coder-plus|Qwen3 Coder Plus|文本|代码模型" \
        "qwen3-coder-flash|Qwen3 Coder Flash|文本|低成本代码模型" ;;
    volcengine)
      printf '%s\n' \
        "doubao-seed-2.0-code|Doubao Seed 2.0 Code|文本/图片|编程/前端/Agent" \
        "doubao-seed-2.0-pro|Doubao Seed 2.0 Pro|文本/图片|强推理/复杂任务" \
        "doubao-seed-2.0-lite|Doubao Seed 2.0 Lite|文本/图片|通用性价比" \
        "doubao-seed-2.0-mini|Doubao Seed 2.0 Mini|文本/图片|低延迟/高并发/低成本" \
        "doubao-seed-2-0-code-preview-260215|Doubao Seed 2.0 Code 快照|文本/图片|版本化 ID" \
        "doubao-seed-2-0-pro-260215|Doubao Seed 2.0 Pro 快照|文本/图片|版本化 ID" \
        "doubao-seed-2-0-lite-260215|Doubao Seed 2.0 Lite 快照|文本/图片|版本化 ID" \
        "doubao-seed-2-0-mini-260215|Doubao Seed 2.0 Mini 快照|文本/图片|版本化 ID" \
        "ark-code-latest|Ark Code Latest|文本|由方舟控制台选择模型" ;;
    zai)
      printf '%s\n' \
        "glm-5.1|GLM-5.1|文本|当前快速开始默认模型" \
        "glm-5|GLM-5|文本|Agentic Engineering" \
        "glm-4.7|GLM-4.7|文本|Agentic Coding" \
        "glm-4.7-flashx|GLM-4.7 FlashX|文本|轻量高速版" \
        "glm-5v-turbo|GLM-5V Turbo|文本/图片|多模态 Coding 基座" \
        "glm-4.6v|GLM-4.6V|文本/图片|视觉理解" ;;
    moonshot)
      printf '%s\n' \
        "kimi-k2.6|Kimi K2.6|文本/图片|Kimi 新一代" \
        "kimi-k2.5|Kimi K2.5|文本/图片|视觉/代码/Agent" \
        "kimi-k2|Kimi K2|文本|旧一代" \
        "moonshot-v1-8k-vision-preview|Moonshot Vision Preview|文本/图片|视觉预览" ;;
    qianfan)
      printf '%s\n' \
        "ernie-4.5-turbo-32k|ERNIE 4.5 Turbo 32K|文本|通用文本" \
        "ernie-4.0-turbo-8k|ERNIE 4.0 Turbo 8K|文本|稳定旧版" \
        "deepseek-v3.2|DeepSeek V3.2 on Qianfan|文本|千帆代理模型" \
        "deepseek-r1-distill-qwen-32b|DeepSeek R1 Distill Qwen 32B|文本|蒸馏推理" ;;
    xiaomi)
      printf '%s\n' "xiaomi/mimo-v2-flash|MiMo V2 Flash|文本/图片|OpenClaw 内置 provider" ;;
    openai)
      printf '%s\n' \
        "openai/gpt-5.4|GPT-5.4|文本/图片|主力模型" \
        "openai/gpt-5.4-mini|GPT-5.4 Mini|文本/图片|轻量模型" \
        "openai/gpt-5.3-codex|GPT-5.3 Codex|文本|代码模型" \
        "openai/o3|o3|文本/图片|旧推理模型" ;;
    anthropic)
      printf '%s\n' \
        "anthropic/claude-opus-4-6|Claude Opus 4.6|文本/图片|最强推理" \
        "anthropic/claude-sonnet-4-6|Claude Sonnet 4.6|文本/图片|均衡" \
        "anthropic/claude-opus-4-5|Claude Opus 4.5|文本/图片|旧版" \
        "anthropic/claude-sonnet-4-5|Claude Sonnet 4.5|文本/图片|旧版" ;;
  esac
}

select_model() {
  local provider_name="${1:-}"
  if [[ -n "$MODEL" ]]; then
    printf '%s\n' "$MODEL"
    return
  fi
  mapfile -t models < <(models_for_provider "$provider_name")
  if [[ "${#models[@]}" -eq 0 ]]; then
    read_required "  请输入 Model ID: "
    return
  fi

  printf '\n  请选择默认模型:\n\n' >&2
  local i entry id label input note
  for i in "${!models[@]}"; do
    entry="${models[$i]}"
    IFS='|' read -r id label input note <<< "$entry"
    printf '  %2d) %s  [%s]  %s，%s\n' "$((i + 1))" "$label" "$input" "$id" "$note" >&2
  done
  printf '   0) 手动输入 Model ID\n\n' >&2
  printf '  请选择 [0-%d]: ' "${#models[@]}" >&2
  read -r choice
  if [[ "$choice" == "0" ]]; then
    read_required "  请输入自定义 Model ID: "
    return
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#models[@]} )); then
    entry="${models[$((choice - 1))]}"
    printf '%s\n' "${entry%%|*}"
    return
  fi
  print_warn "无效选择，跳过模型设置" >&2
  printf '\n'
}

gateway_is_running() {
  local output
  if ! output="$(openclaw gateway probe --json 2>/dev/null)"; then
    return 1
  fi
  printf '%s\n' "$output" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'
}

printf '\n  OpenClaw 中文模型配置与切换脚本\n'
printf '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'

if ! command -v openclaw >/dev/null 2>&1; then
  print_err "找不到 openclaw 命令，请先安装 OpenClaw，或重新打开终端后再试"
  exit 1
fi

print_info "OpenClaw 命令: $(command -v openclaw)"
if version="$(openclaw -v 2>/dev/null | tr -d '\r')"; then
  [[ -n "$version" ]] && print_ok "已检测到 $version"
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

GATEWAY_WAS_RUNNING=0
if gateway_is_running; then
  GATEWAY_WAS_RUNNING=1
  print_ok "Gateway 当前正在运行，配置完成后会直接执行 openclaw gateway restart"
else
  print_warn "Gateway 当前未运行，配置完成后不会主动启动"
fi

provider_idx="$(select_provider)"
provider_name=""
selected_model=""
if [[ -n "$provider_idx" ]]; then
  provider_name="${provider_names[$provider_idx]}"
  selected_model="$(select_model "$provider_name")"
else
  selected_model="$(select_model "")"
fi

if [[ -n "$provider_idx" ]]; then
  step "配置 ${provider_labels[$provider_idx]}"
  key="$(read_required '  请输入 API Key: ' "$API_KEY")"
  if [[ "${provider_modes[$provider_idx]}" == "builtin" ]]; then
    onboard_args=(
      onboard --non-interactive
      --accept-risk
      --mode local
      --auth-choice "${provider_auth[$provider_idx]}"
      "${provider_keyflag[$provider_idx]}" "$key"
      --secret-input-mode plaintext
      --gateway-port 18789
      --gateway-bind loopback
      --install-daemon
      --daemon-runtime node
      --skip-skills
    )
  else
    base="${BASE_URL:-${provider_base_urls[$provider_idx]}}"
    if [[ -z "$base" ]]; then
      base="$(read_required '  请输入 Base URL: ')"
    fi
    print_info "Base URL: $base"
    onboard_args=(
      onboard --non-interactive
      --accept-risk
      --mode local
      --auth-choice custom-api-key
      --custom-api-key "$key"
      --secret-input-mode plaintext
      --gateway-port 18789
      --gateway-bind loopback
      --install-daemon
      --daemon-runtime node
      --skip-skills
      --custom-base-url "$base"
      --custom-model-id "$selected_model"
      --custom-compatibility openai
    )
  fi
  print_info "正在配置 OpenClaw..."
  openclaw "${onboard_args[@]}"
  print_ok "OpenClaw 配置完成"
fi

if [[ -n "$selected_model" ]]; then
  print_info "正在设置默认模型: $selected_model"
  openclaw models set "$selected_model"
  print_ok "默认模型已设置"
fi

printf '\n'
print_info "当前模型状态:"
openclaw models status --plain || true

if [[ "$RESTART_GATEWAY" -eq 1 || ( "$GATEWAY_WAS_RUNNING" -eq 1 && "$RESTART_GATEWAY" -ne -1 ) ]]; then
  printf '\n'
  print_info "正在重启 OpenClaw Gateway..."
  openclaw gateway restart
  openclaw gateway probe || true
fi

printf '\n'
print_ok "完成"
