#!/usr/bin/env bash
set -Eeuo pipefail

# OpenClaw 中文模型配置与切换脚本 (macOS/Linux)
# 在线使用:
#   curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/change-openclaw-model.sh | bash

PROVIDER="${OPENCLAW_PROVIDER:-}"
API_KEY="${OPENCLAW_API_KEY:-}"
MODEL="${OPENCLAW_MODEL:-}"
BASE_URL="${OPENCLAW_BASE_URL:-}"
CONTEXT_WINDOW="${OPENCLAW_CONTEXT_WINDOW:-}"
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
  --context-window <n>    自定义上下文窗口，支持 1M/256K/1000000
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
    --context-window) CONTEXT_WINDOW="${2:-}"; shift 2 ;;
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
provider_portals=("https://platform.deepseek.com/" "https://platform.minimaxi.com/subscribe/token-plan" "https://bailian.console.aliyun.com/" "https://console.volcengine.com/ark/" "https://open.bigmodel.cn/" "https://platform.moonshot.cn/" "https://console.bce.baidu.com/qianfan/" "https://platform.xiaomimimo.com/token-plan" "https://platform.openai.com/" "https://console.anthropic.com/" "")
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
    print_warn "未识别的厂商: ${PROVIDER}，将进入交互选择" >&2
  fi

  printf '  请选择 AI 厂商:\n\n' >&2
  local i
  for i in "${!provider_names[@]}"; do
    local base_text=""
    local portal_text=""
    [[ -n "${provider_base_urls[$i]}" ]] && base_text=" | API: ${provider_base_urls[$i]}"
    [[ -n "${provider_portals[$i]}" ]] && portal_text=" | 官网: ${provider_portals[$i]}"
    printf '  %2s) %-10s - %s%s%s\n' "${provider_keys[$i]}" "${provider_names[$i]}" "${provider_labels[$i]}" "$base_text" "$portal_text" >&2
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
        "deepseek-v4-pro|DeepSeek V4 Pro|文本|强推理/复杂任务|1000000|0|DeepSeek 官方 Hugging Face 模型卡" \
        "deepseek-v4-flash|DeepSeek V4 Flash|文本|高速/低成本|1000000|0|DeepSeek 官方 Hugging Face 模型卡" \
        "deepseek-chat|DeepSeek Chat|文本|旧别名，2026-07-24 弃用|0|0|" \
        "deepseek-reasoner|DeepSeek Reasoner|文本|旧别名，2026-07-24 弃用|0|0|" ;;
    minimax)
      printf '%s\n' \
        "MiniMax-M2.7|MiniMax M2.7|文本|默认推荐|204800|0|MiniMax 官方 API Overview" \
        "MiniMax-M2.7-highspeed|MiniMax M2.7 Highspeed|文本|高速版|204800|0|MiniMax 官方 API Overview" \
        "MiniMax-M2.5|MiniMax M2.5|文本|旧一代高性价比|204800|0|MiniMax 官方 API Overview" \
        "MiniMax-M2.5-highspeed|MiniMax M2.5 Highspeed|文本|旧一代高速版|204800|0|MiniMax 官方 API Overview" ;;
    qwen)
      printf '%s\n' \
        "qwen3.6-plus|Qwen3.6 Plus|文本/图片|1M 上下文，主推|1000000|0|阿里云官方新闻稿/Model Studio 文档" \
        "qwen3.6-flash|Qwen3.6 Flash|文本/图片|1M 上下文，低成本|1000000|0|用户确认，待阿里云精确 Model ID 文档同步" \
        "qwen3.6-max-preview|Qwen3.6 Max Preview|文本|256K 上下文，最高推理能力|262144|0|按 Qwen3 Max 系列官方上下文配置" \
        "qwen3-max|Qwen3 Max|文本/图片|256K 上下文，稳定版|262144|0|阿里云 Model Studio 官方模型列表" \
        "qwen3.5-plus|Qwen3.5 Plus|文本/图片|1M 上下文|1000000|0|阿里云 Model Studio 官方模型列表" \
        "qwen3.5-flash|Qwen3.5 Flash|文本/图片|1M 上下文|1000000|0|阿里云 Model Studio 官方模型列表" ;;
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

model_metadata_for_provider() {
  local provider_name="$1"
  local model_id="$2"
  local entry id label input note context max_tokens source
  while IFS= read -r entry; do
    IFS='|' read -r id label input note context max_tokens source <<< "$entry"
    if [[ "$id" == "$model_id" ]]; then
      printf '%s|%s|%s|%s|%s\n' "${context:-0}" "${max_tokens:-0}" "${input:-}" "${source:-}" "${note:-}"
      return 0
    fi
  done < <(models_for_provider "$provider_name")
  return 1
}

parse_token_size() {
  local raw="${1:-}"
  local normalized
  normalized="$(printf '%s' "$raw" | tr -d ',' | tr -d '[:space:]')"
  if [[ -z "$normalized" ]]; then
    printf '0\n'
    return 0
  fi
  if [[ "$normalized" =~ ^([0-9]+)([kKmM]?)$ ]]; then
    local num="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    case "$unit" in
      k|K) printf '%s\n' "$((num * 1000))" ;;
      m|M) printf '%s\n' "$((num * 1000000))" ;;
      *) printf '%s\n' "$num" ;;
    esac
    return 0
  fi
  return 1
}

read_optional_token_size() {
  local prompt="$1"
  local value="${2:-}"
  local parsed
  while true; do
    if [[ -n "$value" ]]; then
      if parsed="$(parse_token_size "$value")"; then
        printf '%s\n' "$parsed"
        return 0
      fi
      print_warn "无法识别 token 数量: ${value}。示例: 1M、256K、1000000、262144" >&2
      printf '0\n'
      return 0
    fi
    printf '%s' "$prompt" >&2
    read -r value
    if [[ -z "$value" ]]; then
      printf '0\n'
      return 0
    fi
    if parsed="$(parse_token_size "$value")"; then
      printf '%s\n' "$parsed"
      return 0
    fi
    print_warn "无法识别 token 数量: ${value}。示例: 1M、256K、1000000、262144" >&2
    value=""
  done
}

apply_custom_model_metadata() {
  local provider_name="$1"
  local model_id="$2"
  local base_url="$3"
  local metadata context max_tokens input source note

  if ! metadata="$(model_metadata_for_provider "$provider_name" "$model_id")"; then
    metadata="0|0|文本||"
  fi

  IFS='|' read -r context max_tokens input source note <<< "$metadata"
  context="${context:-0}"
  max_tokens="${max_tokens:-0}"

  if [[ -n "$CONTEXT_WINDOW" ]]; then
    context="$(read_optional_token_size "" "$CONTEXT_WINDOW")"
    source="用户手动输入"
  elif [[ "$context" == "0" ]]; then
    printf '\n' >&2
    print_warn "当前模型没有内置上下文配置。" >&2
    print_warn "直接回车 = 保留 OpenClaw 默认值（custom 模型通常是 16K 上下文）。" >&2
    printf '  支持写法: 1M / 1m / 256K / 256k / 1000000 / 262144\n' >&2
    context="$(read_optional_token_size "  请输入上下文窗口 contextWindow（可选）: ")"
    if [[ "$context" != "0" ]]; then
      source="用户手动输入"
    fi
  fi

  if [[ "$context" == "0" && "$max_tokens" == "0" ]]; then
    print_info "未设置上下文元数据，保留 OpenClaw 默认值（custom 模型通常是 16K）"
    return 0
  fi

  local config_path="${HOME}/.openclaw/openclaw.json"
  if [[ ! -f "$config_path" ]]; then
    print_warn "未找到 OpenClaw 配置文件，无法写入模型元数据: $config_path"
    return 0
  fi

  local rc=0
  CONFIG_PATH="$config_path" \
  TARGET_BASE_URL="$base_url" \
  TARGET_MODEL_ID="$model_id" \
  CONTEXT_WINDOW="$context" \
  MAX_TOKENS="$max_tokens" \
  INPUT_LABEL="$input" \
  node <<'NODE' || rc=$?
const fs = require('fs');

const configPath = process.env.CONFIG_PATH;
const targetBaseUrl = normalizeUrl(process.env.TARGET_BASE_URL || '');
const targetModelId = process.env.TARGET_MODEL_ID || '';
const contextWindow = Number(process.env.CONTEXT_WINDOW || 0);
const maxTokens = Number(process.env.MAX_TOKENS || 0);
const inputLabel = process.env.INPUT_LABEL || '';

function normalizeUrl(value) {
  return String(value || '').trim().replace(/\/+$/, '');
}

function inputFromLabel(label) {
  return label.includes('图片') ? ['text', 'image'] : ['text'];
}

const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const providers = config?.models?.providers || {};
let provider = null;
for (const candidate of Object.values(providers)) {
  if (normalizeUrl(candidate?.baseUrl) === targetBaseUrl) {
    provider = candidate;
    break;
  }
}

if (!provider) {
  console.error('provider_not_found');
  process.exit(2);
}

const models = provider.models || {};
let targetModel = null;
for (const candidate of Object.values(models)) {
  if (candidate?.id === targetModelId) {
    targetModel = candidate;
    break;
  }
}

if (!targetModel) {
  console.error('model_not_found');
  process.exit(3);
}

if (contextWindow > 0) targetModel.contextWindow = contextWindow;
if (maxTokens > 0) targetModel.maxTokens = maxTokens;
if (inputLabel) targetModel.input = inputFromLabel(inputLabel);

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n', 'utf8');
NODE
  if [[ "$rc" -eq 0 ]]; then
    local ctx_text="contextWindow=保留默认"
    local out_text="maxTokens=保留默认"
    [[ "$context" != "0" ]] && ctx_text="contextWindow=$context"
    [[ "$max_tokens" != "0" ]] && out_text="maxTokens=$max_tokens"
    print_ok "已写入官方核实模型元数据: $ctx_text, $out_text"
    [[ -n "$source" ]] && print_info "核实来源: $source"
  elif [[ "$rc" -eq 2 ]]; then
    print_warn "未能按 Base URL 找到 custom provider，跳过模型元数据写入"
  elif [[ "$rc" -eq 3 ]]; then
    print_warn "未能在 custom provider 中找到模型 ${model_id}，跳过模型元数据写入"
  else
    print_warn "写入模型元数据失败，OpenClaw 主配置已完成"
  fi
}

custom_onboard_applied() {
  local model_id="$1"
  local base_url="$2"
  local config_path="$HOME/.openclaw/openclaw.json"
  [[ -f "$config_path" ]] || return 1

  CONFIG_PATH="$config_path" TARGET_BASE_URL="$base_url" TARGET_MODEL_ID="$model_id" node <<'NODE'
const fs = require('fs');

function normalizeUrl(value) {
  return String(value || '').trim().replace(/\/+$/, '');
}

try {
  const config = JSON.parse(fs.readFileSync(process.env.CONFIG_PATH, 'utf8'));
  const targetBaseUrl = normalizeUrl(process.env.TARGET_BASE_URL || '');
  const targetModelId = process.env.TARGET_MODEL_ID || '';
  const providers = config?.models?.providers || {};
  for (const provider of Object.values(providers)) {
    if (normalizeUrl(provider?.baseUrl) !== targetBaseUrl) continue;
    for (const model of Object.values(provider?.models || {})) {
      if (model?.id === targetModelId) process.exit(0);
    }
  }
} catch {}
process.exit(1);
NODE
}

select_model() {
  local provider_name="${1:-}"
  if [[ -n "$MODEL" ]]; then
    printf '%s\n' "$MODEL"
    return
  fi
  local models=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && models+=("$line")
  done < <(models_for_provider "$provider_name")
  if [[ "${#models[@]}" -eq 0 ]]; then
    read_required "  请输入 Model ID: "
    return
  fi

  printf '\n  请选择默认模型:\n\n' >&2
  local i entry id label input note context max_tokens source ctx_label out_label
  for i in "${!models[@]}"; do
    entry="${models[$i]}"
    IFS='|' read -r id label input note context max_tokens source <<< "$entry"
    ctx_label=""
    out_label=""
    [[ "${context:-0}" != "0" ]] && ctx_label=" | 上下文: $context"
    [[ "${max_tokens:-0}" != "0" ]] && out_label=" | 输出: $max_tokens"
    printf '  %2d) %s  [%s]  %s%s%s，%s\n' "$((i + 1))" "$label" "$input" "$id" "$ctx_label" "$out_label" "$note" >&2
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
  set +e
  openclaw "${onboard_args[@]}"
  onboard_rc=$?
  set -e
  if [[ "$onboard_rc" -ne 0 ]]; then
    if [[ "${provider_modes[$provider_idx]}" == "custom" ]] && custom_onboard_applied "$selected_model" "$base"; then
      print_warn "openclaw onboard 返回退出码 ${onboard_rc}，但模型配置已写入；通常是 Gateway 探测失败，继续补写模型元数据"
      print_info "Gateway 启动失败不等于模型配置失败，可稍后单独执行 openclaw gateway restart 排查"
    else
      print_err "openclaw onboard 执行失败，退出码: $onboard_rc"
      exit "$onboard_rc"
    fi
  fi
  print_ok "OpenClaw 配置完成"
  print_info "配置文件已写入: $HOME/.openclaw/openclaw.json"
  if [[ "${provider_modes[$provider_idx]}" == "custom" ]]; then
    apply_custom_model_metadata "$provider_name" "$selected_model" "$base"
  fi
fi

if [[ -n "$selected_model" && ( -z "$provider_idx" || "${provider_modes[$provider_idx]}" != "custom" ) ]]; then
  print_info "正在设置默认模型: $selected_model"
  openclaw models set "$selected_model"
  print_ok "默认模型已设置"
elif [[ -n "$selected_model" && -n "$provider_idx" && "${provider_modes[$provider_idx]}" == "custom" ]]; then
  print_ok "Custom 模型已由 openclaw onboard 写入: $selected_model"
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
