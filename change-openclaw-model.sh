#!/usr/bin/env bash
set -Eeuo pipefail

# OpenClaw 中文模型配置与切换脚本 (macOS/Linux)
# 在线使用:
#   curl -fsSL https://gitee.com/mijiamiyu/scripts/raw/main/change-openclaw-model.sh | bash

# 兜底:通过 curl|bash 调用时 stdin 是脚本内容管道,read 默认从 stdin 读会
# 吃掉 bash 还没解析的脚本字节,导致后续报 "syntax error near unexpected token"。
# 解法:新开 fd 3 指向 /dev/tty,所有交互 read 显式用 <&3 从终端读,不污染 stdin。
# 不能 exec </dev/tty,那会把脚本自身的输入流也接到终端,bash 反而卡在等用户敲完脚本。
# 三档兜底:终端 stdin → fd 0;/dev/tty 可开 → /dev/tty;都不行 → fd 0。
if [[ -t 0 ]]; then
  exec 3<&0
elif (exec 3</dev/tty) 2>/dev/null; then
  exec 3</dev/tty
else
  exec 3<&0
fi

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
  --provider <name>       厂商: deepseek/minimax/qwen/volcengine/ark-coding/qwen-token-plan/zai/moonshot/xiaomi/openai/custom
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

# provider_keys 中空字符串表示"主菜单不显示"——这些是子计费方式,
# 用户先选 volcengine/qwen,再二级菜单升级到 ark-coding / qwen-token-plan
provider_keys=(1 2 3 4 "" "" 5 6 7 8 9)
provider_names=(deepseek minimax qwen volcengine ark-coding qwen-token-plan zai moonshot xiaomi openai custom)
provider_labels=("DeepSeek" "MiniMax" "阿里百炼 / Qwen" "火山方舟 / Doubao" "火山方舟 Coding Plan" "阿里百炼 Token Plan" "智谱 / BigModel" "Moonshot / Kimi" "小米 MiMo" "OpenAI" "自定义兼容接口")
provider_modes=(custom custom custom custom custom custom custom custom custom custom custom)
provider_base_urls=("https://api.deepseek.com" "https://api.minimaxi.com/v1" "https://dashscope.aliyuncs.com/compatible-mode/v1" "https://ark.cn-beijing.volces.com/api/v3" "https://ark.cn-beijing.volces.com/api/coding/v3" "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1" "https://open.bigmodel.cn/api/paas/v4" "https://api.moonshot.ai/v1" "https://api.xiaomimimo.com/v1" "https://api.openai.com/v1" "")
provider_portals=("https://platform.deepseek.com/" "https://platform.minimaxi.com/subscribe/token-plan" "https://bailian.console.aliyun.com/" "https://console.volcengine.com/ark/" "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement/coding-plan" "https://bailian.console.aliyun.com/?tab=tokenplan" "https://open.bigmodel.cn/" "https://platform.moonshot.cn/" "https://platform.xiaomimimo.com/token-plan" "https://platform.openai.com/" "")
provider_auth=("" "" "" "" "" "" "" "" "" "" "")
provider_keyflag=("" "" "" "" "" "" "" "" "" "" "")

# 把上下文 token 数格式化成人类可读的 K/M 标签(K=1024,M=1024*1024)
# 仅在能整除时才用 K/M,否则直接输出原始数字
fmt_ctx() {
  local n="$1"
  if [[ -z "$n" || "$n" == "0" ]]; then
    return
  fi
  if (( n >= 1048576 )) && (( n % 1048576 == 0 )); then
    printf '%dM' "$((n / 1048576))"
  elif (( n >= 1024 )) && (( n % 1024 == 0 )); then
    printf '%dK' "$((n / 1024))"
  else
    printf '%d' "$n"
  fi
}

read_required() {
  local prompt="$1"
  local value="${2:-}"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return
  fi
  while true; do
    printf '%s' "$prompt" >&2
    read -r value <&3
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return
    fi
    print_warn "不能为空，请重新输入" >&2
  done
}

# 支持「输入 b 返回上一步」的 read。空值 = 重新输入,b = 输出 __BACK__ 信号
read_input_with_back() {
  local prompt="$1"
  local value="${2:-}"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return
  fi
  while true; do
    printf '%s' "$prompt" >&2
    read -r value <&3
    case "$value" in
      b|B|back)
        printf '__BACK__\n'
        return
        ;;
      "")
        print_warn "不能为空,请重新输入(或输入 b 返回上一步)" >&2
        ;;
      *)
        printf '%s\n' "$value"
        return
        ;;
    esac
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
  local i visible_max=0
  for i in "${!provider_names[@]}"; do
    # 跳过子计费方式(provider_keys 为空表示不在主菜单显示)
    [[ -z "${provider_keys[$i]}" ]] && continue
    (( ${provider_keys[$i]} > visible_max )) && visible_max="${provider_keys[$i]}"
    local portal_text=""
    [[ -n "${provider_portals[$i]}" ]] && portal_text=" | 官网: ${provider_portals[$i]}"
    printf '  %2s) %-10s - %s%s\n' "${provider_keys[$i]}" "${provider_names[$i]}" "${provider_labels[$i]}" "$portal_text" >&2
  done
  printf '   0) 仅切换模型 / 跳过厂商配置\n\n' >&2
  while true; do
    printf '  请输入编号 [0-%d]: ' "$visible_max" >&2
    read -r choice <&3
    if [[ "$choice" == "0" ]]; then
      printf '\n'
      return
    fi
    if idx="$(provider_index_by_name_or_key "$choice")"; then
      # 二级要求:必须是主菜单可见的(provider_keys 非空)
      if [[ -n "${provider_keys[$idx]}" ]]; then
        break
      fi
    fi
    print_warn "无效编号,请输入 0-${visible_max}" >&2
  done

  # 主厂商选定后,询问是否升级到付费计费方式 / 订阅 OAuth
  case "${provider_names[$idx]}" in
    volcengine)
      idx="$(ask_plan_upgrade "$idx" ark-coding 'Coding Plan(智能路由,需在火山方舟控制台单独订阅)')"
      ;;
    qwen)
      idx="$(ask_plan_upgrade "$idx" qwen-token-plan 'Token Plan(智能路由,需在阿里百炼控制台单独订阅)')"
      ;;
    openai)
      local route
      route="$(ask_openai_route)"
      if [[ "$route" == "subscription" ]]; then
        printf 'SUBSCRIPTION\n'
        return
      fi
      ;;
  esac
  printf '%s\n' "$idx"
}

# 二级菜单:OpenAI 接入方式(API Key vs ChatGPT 订阅 OAuth)
# 返回 "apikey" 或 "subscription"
ask_openai_route() {
  printf '\n  OpenAI 接入方式(可选):\n' >&2
  printf '   1) API Key(按 token 付费,默认)\n' >&2
  printf '   2) ChatGPT 订阅(Codex OAuth)\n' >&2
  local route
  while true; do
    printf '  请选择 [1/2,直接回车=1]: ' >&2
    read -r route <&3
    case "$route" in
      ""|1) printf 'apikey\n'; return ;;
      2)    printf 'subscription\n'; return ;;
      *)    print_warn "无效输入,请输入 1 或 2" >&2 ;;
    esac
  done
}

# 订阅路径:让 openclaw configure 接管 OAuth 流程
# 首次安装(无 openclaw.json)先跑 onboard --auth-choice skip 建基础架子
handle_subscription_flow() {
  step "配置 ChatGPT 订阅(OpenAI Codex OAuth)"
  printf '\n' >&2
  print_info "接下来由 OpenClaw 接管,请按下列顺序选择:" >&2
  printf '         1. Where will the Gateway run?  → Local (回车确认)\n' >&2
  printf '         2. Model/auth provider          → OpenAI\n' >&2
  printf '         3. OpenAI auth method           → OpenAI Codex (ChatGPT OAuth)\n' >&2
  printf '         4. 浏览器会自动弹出,完成登录授权\n' >&2
  printf '         5. Default model                → 选你订阅包含的模型\n' >&2
  printf '\n' >&2

  if [[ ! -f "$HOME/.openclaw/openclaw.json" ]]; then
    print_info "首次配置,先用 skip-auth onboard 创建 OpenClaw 基础环境..." >&2
    if ! openclaw onboard --non-interactive --accept-risk \
        --auth-choice skip --mode local \
        --gateway-port 18789 --gateway-bind loopback \
        --install-daemon --daemon-runtime node --skip-skills </dev/null; then
      print_err "skip-auth onboard 失败,无法继续订阅配置流程" >&2
      exit 1
    fi
    print_ok "基础环境就绪" >&2
    printf '\n' >&2
  fi

  print_info "正在调起 openclaw configure --section model..." >&2
  printf '\n' >&2

  # </dev/tty 确保 openclaw 能从终端读输入(脚本通过 curl|bash 跑时 stdin 是管道)
  if ! openclaw configure --section model </dev/tty; then
    print_err "openclaw configure 失败"
    exit 1
  fi

  printf '\n' >&2
  print_ok "OpenAI 订阅配置完成"

  if gateway_is_running; then
    printf '\n' >&2
    print_info "重启 Gateway 让新配置生效..."
    openclaw gateway restart </dev/null
    openclaw gateway probe </dev/null || true
  fi
}

# 二级菜单:问用户是要主厂商的标准 API 还是订阅计费方式
ask_plan_upgrade() {
  local base_idx="$1"
  local plan_name="$2"
  local plan_desc="$3"
  printf '\n  %s 还支持订阅计费方式(可选):\n' "${provider_labels[$base_idx]}" >&2
  printf '   1) 标准按量付费(默认,普通 API Key 即可)\n' >&2
  printf '   2) %s\n' "$plan_desc" >&2
  local plan_choice
  while true; do
    printf '  请选择 [1/2,直接回车=1]: ' >&2
    read -r plan_choice <&3
    case "$plan_choice" in
      ""|1)
        printf '%s\n' "$base_idx"
        return
        ;;
      2)
        local plan_idx
        if plan_idx="$(provider_index_by_name_or_key "$plan_name")"; then
          printf '%s\n' "$plan_idx"
          return
        fi
        printf '%s\n' "$base_idx"
        return
        ;;
      *)
        print_warn "无效输入,请输入 1 或 2" >&2
        ;;
    esac
  done
}

models_for_provider() {
  case "$1" in
    deepseek)
      printf '%s\n' \
        "deepseek-v4-pro|DeepSeek V4 Pro|文本|强推理/复杂任务|1048576|0|DeepSeek 官方 Hugging Face 模型卡" \
        "deepseek-v4-flash|DeepSeek V4 Flash|文本|高速/低成本|1048576|0|DeepSeek 官方 Hugging Face 模型卡" ;;
    minimax)
      printf '%s\n' \
        "MiniMax-M2.7|MiniMax M2.7|文本|默认推荐|204800|0|MiniMax 官方 API Overview" \
        "MiniMax-M2.7-highspeed|MiniMax M2.7 Highspeed|文本|高速版|204800|0|MiniMax 官方 API Overview" \
        "MiniMax-M2.5|MiniMax M2.5|文本|旧一代高性价比|204800|0|MiniMax 官方 API Overview" \
        "MiniMax-M2.5-highspeed|MiniMax M2.5 Highspeed|文本|旧一代高速版|204800|0|MiniMax 官方 API Overview" ;;
    qwen)
      printf '%s\n' \
        "qwen3.6-plus|Qwen3.6 Plus|文本/图片|1M 上下文，主推|1048576|0|阿里云官方新闻稿/Model Studio 文档" \
        "qwen3.6-flash|Qwen3.6 Flash|文本/图片|1M 上下文，低成本|1048576|0|用户确认，待阿里云精确 Model ID 文档同步" \
        "qwen3.6-max-preview|Qwen3.6 Max Preview|文本|256K 上下文，最高推理能力|262144|0|按 Qwen3 Max 系列官方上下文配置" \
        "qwen3-max|Qwen3 Max|文本/图片|256K 上下文，稳定版|262144|0|阿里云 Model Studio 官方模型列表" \
        "qwen3.5-plus|Qwen3.5 Plus|文本/图片|1M 上下文|1048576|0|阿里云 Model Studio 官方模型列表" \
        "qwen3.5-flash|Qwen3.5 Flash|文本/图片|1M 上下文|1048576|0|阿里云 Model Studio 官方模型列表" ;;
    volcengine)
      printf '%s\n' \
        "doubao-seed-2-0-code-preview-260215|Doubao Seed 2.0 Code|文本/图片|256K 上下文，编程/前端/Agent|262144|0|" \
        "doubao-seed-2-0-pro-260215|Doubao Seed 2.0 Pro|文本/图片|256K 上下文，强推理/复杂任务|262144|0|" \
        "doubao-seed-2-0-lite-260215|Doubao Seed 2.0 Lite|文本/图片|256K 上下文，通用性价比|262144|0|" \
        "doubao-seed-2-0-mini-260215|Doubao Seed 2.0 Mini|文本/图片|256K 上下文，低延迟/高并发/低成本|262144|0|" ;;
    ark-coding)
      # 上下文写在 note 里(K=1024 换算),不再额外用括号显示
      printf '%s\n' \
        "ark-code-latest|Ark Code Latest|文本/图片|250K 上下文，Auto 模式：按效果+速度智能路由（推荐）|256000|0|" \
        "doubao-seed-code|Doubao Seed Code|文本/图片|256K 上下文，Doubao 编程主推|262144|0|" \
        "doubao-seed-2.0-code|Doubao Seed 2.0 Code|文本/图片|256K 上下文，2.0 代编程版|262144|0|" \
        "doubao-seed-2.0-pro|Doubao Seed 2.0 Pro|文本/图片|256K 上下文，强推理|262144|0|" \
        "doubao-seed-2.0-lite|Doubao Seed 2.0 Lite|文本/图片|256K 上下文，通用性价比|262144|0|" \
        "kimi-k2.6|Kimi K2.6|文本|256K 上下文，Moonshot 最新|262144|0|" \
        "kimi-k2.5|Kimi K2.5|文本|256K 上下文，Moonshot 上一代|262144|0|" \
        "deepseek-v3.2|DeepSeek V3.2|文本|128K 上下文，DeepSeek 通过 Coding Plan 路由|131072|0|" \
        "minimax-m2.7|MiniMax M2.7|文本|200K 上下文，MiniMax 通过 Coding Plan 路由|204800|0|" \
        "glm-5.1|GLM-5.1|文本|200K 上下文，智谱通过 Coding Plan 路由|204800|0|" \
        "glm-4.7|GLM-4.7|文本|200K 上下文，智谱旧版|204800|0|" ;;
    qwen-token-plan)
      printf '%s\n' \
        "qwen3.6-plus|Qwen3.6 Plus|文本/图片|1M 上下文，阿里百炼 Token Plan 主推|1048576|0|" \
        "glm-5|GLM-5|文本|198K 上下文，智谱通过 Token Plan 路由|202752|0|" \
        "MiniMax-M2.5|MiniMax M2.5|文本|192K 上下文，MiniMax 通过 Token Plan 路由|196608|0|" \
        "deepseek-v3.2|DeepSeek V3.2|文本|160K 上下文，DeepSeek 通过 Token Plan 路由|163840|0|" ;;
    zai)
      printf '%s\n' \
        "glm-5.1|GLM-5.1|文本|200K 上下文，当前快速开始默认模型|204800|0|" \
        "glm-5|GLM-5|文本|200K 上下文，Agentic Engineering|204800|0|" \
        "glm-4.7|GLM-4.7|文本|200K 上下文，Agentic Coding|204800|0|" \
        "glm-5-turbo|GLM-5 Turbo|文本/图片|200K 上下文，多模态 Coding 基座|204800|0|" \
        "glm-4.6|GLM-4.6|文本/图片|128K 上下文，视觉理解|131072|0|" ;;
    moonshot)
      printf '%s\n' \
        "kimi-k2.6|Kimi K2.6|文本/图片|256K 上下文，Kimi 新一代|262144|0|" \
        "kimi-k2.5|Kimi K2.5|文本/图片|256K 上下文，视觉/代码/Agent|262144|0|" ;;
    xiaomi)
      printf '%s\n' \
        "xiaomi/mimo-v2.5-pro|MiMo V2.5 Pro|文本/图片|1M 上下文，强推理/复杂任务|1048576|0|" \
        "xiaomi/mimo-v2.5|MiMo V2.5|文本/图片|1M 上下文，通用|1048576|0|" \
        "xiaomi/mimo-v2-pro|MiMo V2 Pro|文本/图片|1M 上下文，旧版强推理|1048576|0|" \
        "xiaomi/mimo-v2-flash|MiMo V2 Flash|文本/图片|128K 上下文，轻量高速|131072|0|" ;;
    openai)
      # OpenAI 官方 token 数为十进制(1M=1000000),原样写入
      printf '%s\n' \
        "openai/gpt-5.5|GPT-5.5|文本/图片|1.05M 上下文|1050000|0|" \
        "openai/gpt-5.5-pro|GPT-5.5 Pro|文本/图片|1.05M 上下文|1050000|0|" \
        "openai/gpt-5.4|GPT-5.4|文本/图片|1.05M 上下文|1050000|0|" \
        "openai/gpt-5.4-pro|GPT-5.4 Pro|文本/图片|1.05M 上下文|1050000|0|" \
        "openai/gpt-5.4-mini|GPT-5.4 Mini|文本/图片|400K 上下文，轻量|400000|0|" \
        "openai/gpt-5.4-nano|GPT-5.4 Nano|文本/图片|400K 上下文，最轻量|400000|0|" \
        "openai/gpt-5.2|GPT-5.2|文本/图片|400K 上下文|400000|0|" \
        "openai/gpt-5.1|GPT-5.1|文本/图片|400K 上下文|400000|0|" \
        "openai/gpt-5|GPT-5|文本/图片|400K 上下文|400000|0|" \
        "openai/gpt-5-mini|GPT-5 Mini|文本/图片|400K 上下文|400000|0|" \
        "openai/gpt-5-nano|GPT-5 Nano|文本/图片|400K 上下文|400000|0|" \
        "openai/gpt-4.1|GPT-4.1|文本/图片|1M 上下文|1047576|0|" \
        "openai/gpt-4.1-mini|GPT-4.1 Mini|文本/图片|1M 上下文|1047576|0|" \
        "openai/gpt-4.1-nano|GPT-4.1 Nano|文本/图片|1M 上下文|1047576|0|" \
        "openai/gpt-4o|GPT-4o|文本/图片|128K 上下文|128000|0|" \
        "openai/gpt-4o-mini|GPT-4o Mini|文本/图片|128K 上下文|128000|0|" \
        "openai/o3|o3|文本/图片|200K 上下文，推理模型|200000|0|" \
        "openai/o3-pro|o3 Pro|文本/图片|200K 上下文，推理增强|200000|0|" \
        "openai/o4-mini|o4 Mini|文本/图片|200K 上下文，轻量推理|200000|0|" ;;
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
    # K=1024,M=1024*1024(全脚本统一二进制换算)
    case "$unit" in
      k|K) printf '%s\n' "$((num * 1024))" ;;
      m|M) printf '%s\n' "$((num * 1048576))" ;;
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
    read -r value <&3
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

  local is_known=true
  if ! metadata="$(model_metadata_for_provider "$provider_name" "$model_id")"; then
    is_known=false
    metadata="0|0|文本||"
  fi

  IFS='|' read -r context max_tokens input source note <<< "$metadata"
  context="${context:-0}"
  max_tokens="${max_tokens:-0}"

  if [[ -n "$CONTEXT_WINDOW" ]]; then
    context="$(read_optional_token_size "" "$CONTEXT_WINDOW")"
    source="用户手动输入"
  elif [[ "$is_known" == "false" && "$context" == "0" ]]; then
    # 用户手动输入的未知 model id,我们没有任何上下文数据,问一下
    printf '\n' >&2
    print_warn "手动输入的 Model ID 没有内置上下文配置。" >&2
    print_warn "直接回车 = 沿用 OpenClaw 默认值（custom 模型通常是 16K）。" >&2
    printf '  支持写法: 1M / 1m / 256K / 256k / 1048576 / 262144（K=1024）\n' >&2
    context="$(read_optional_token_size "  请输入上下文窗口 contextWindow（可选）: ")"
    if [[ "$context" != "0" ]]; then
      source="用户手动输入"
    fi
  fi
  # 已知模型(在预设里但没填 context)沿用 OpenClaw 默认值,不打断流程

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
  local i entry id label input note context max_tokens source
  for i in "${!models[@]}"; do
    entry="${models[$i]}"
    IFS='|' read -r id label input note context max_tokens source <<< "$entry"
    printf '  %2d) %s  [%s]  %s，%s\n' "$((i + 1))" "$label" "$input" "$id" "$note" >&2
  done
  printf '   0) 手动输入 Model ID\n' >&2
  printf '   b) 返回上一步(重选厂商)\n\n' >&2
  while true; do
    printf '  请选择 [0-%d / b]: ' "${#models[@]}" >&2
    read -r choice <&3
    case "$choice" in
      b|B|back)
        printf '__BACK__\n'
        return
        ;;
    esac
    if [[ "$choice" == "0" ]]; then
      # 用 read_input_with_back 让用户手动输入也能 b 返回
      local manual_id
      manual_id="$(read_input_with_back "  请输入自定义 Model ID(b 返回上一步): ")"
      if [[ "$manual_id" == "__BACK__" ]]; then
        printf '__BACK__\n'
        return
      fi
      printf '%s\n' "$manual_id"
      return
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#models[@]} )); then
      entry="${models[$((choice - 1))]}"
      printf '%s\n' "${entry%%|*}"
      return
    fi
    print_warn "无效输入,请输入 0-${#models[@]} 或 b" >&2
  done
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

provider_idx=""
provider_name=""
selected_model=""
key=""

# 状态机:provider → model → apikey,任一步输入 b 都能返回上一步
flow_state="provider"
while [[ "$flow_state" != "configured" ]]; do
  case "$flow_state" in
    provider)
      provider_idx="$(select_provider)"
      # 订阅 OAuth 路径:不走后续 model/apikey 状态机,直接交给 openclaw configure
      if [[ "$provider_idx" == "SUBSCRIPTION" ]]; then
        handle_subscription_flow
        exit 0
      fi
      provider_name=""
      [[ -n "$provider_idx" ]] && provider_name="${provider_names[$provider_idx]}"
      flow_state="model"
      ;;
    model)
      sel="$(select_model "$provider_name")"
      if [[ "$sel" == "__BACK__" ]]; then
        PROVIDER=""    # 清掉环境变量,让 select_provider 重新显示菜单
        flow_state="provider"
      else
        selected_model="$sel"
        if [[ -n "$provider_idx" ]]; then
          flow_state="apikey"
        else
          flow_state="configured"
        fi
      fi
      ;;
    apikey)
      step "配置 ${provider_labels[$provider_idx]}"
      key="$(read_input_with_back '  请输入 API Key (输入 b 返回上一步): ' "$API_KEY")"
      if [[ "$key" == "__BACK__" ]]; then
        MODEL=""    # 清掉环境变量,让 select_model 重新显示菜单
        selected_model=""
        flow_state="model"
      else
        flow_state="configured"
      fi
      ;;
  esac
done

if [[ -n "$provider_idx" ]]; then
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
  openclaw "${onboard_args[@]}" </dev/null
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
  openclaw models set "$selected_model" </dev/null
  print_ok "默认模型已设置"
elif [[ -n "$selected_model" && -n "$provider_idx" && "${provider_modes[$provider_idx]}" == "custom" ]]; then
  print_ok "Custom 模型已由 openclaw onboard 写入: $selected_model"
fi

printf '\n'
print_info "当前模型状态:"
openclaw models status --plain </dev/null || true

if [[ "$RESTART_GATEWAY" -eq 1 || ( "$GATEWAY_WAS_RUNNING" -eq 1 && "$RESTART_GATEWAY" -ne -1 ) ]]; then
  printf '\n'
  print_info "正在重启 OpenClaw Gateway..."
  openclaw gateway restart </dev/null
  openclaw gateway probe </dev/null || true
fi

printf '\n'
print_ok "完成"
