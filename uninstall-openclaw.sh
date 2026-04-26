#!/usr/bin/env bash
# OpenClaw 一键卸载脚本 (macOS / Linux)
# 用法:
#   bash uninstall-openclaw.sh
#   bash uninstall-openclaw.sh --force
#   bash uninstall-openclaw.sh --keep-user-data
#
# 参数:
#   --force            跳过确认提示（自动化场景）
#   --keep-user-data   保留 ~/.openclaw 用户数据目录（升级换版本时用）
#
# 在线一键卸载:
#   curl -fsSL https://gitee.com/mijiamiyu/scripts/raw/main/uninstall-openclaw.sh | bash
#   curl -fsSL https://gitee.com/mijiamiyu/scripts/raw/main/uninstall-openclaw.sh | bash -s -- --force

set -u  # 未定义变量报错；不开 -e，卸载脚本要尽量跑完

FORCE=0
KEEP_USER_DATA=0
for arg in "$@"; do
  case "$arg" in
    --force)          FORCE=1 ;;
    --keep-user-data) KEEP_USER_DATA=1 ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
  esac
done

# ── 颜色输出 ──
if [[ -t 1 ]]; then
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m';  C_CYAN=$'\033[36m';  C_GRAY=$'\033[90m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_GRAY=""; C_RESET=""
fi

info()    { printf "  ${C_BLUE}[INFO]${C_RESET} %s\n" "$*"; }
success() { printf "  ${C_GREEN}[OK]  ${C_RESET} %s\n" "$*"; }
warn()    { printf "  ${C_YELLOW}[WARN]${C_RESET} %s\n" "$*"; }
err()     { printf "  ${C_RED}[FAIL]${C_RESET} %s\n" "$*"; }
step()    { printf "\n${C_CYAN}━━━ %s ━━━${C_RESET}\n\n" "$*"; }

# ── 平台检测 ──
OS_KIND="linux"
if [[ "$(uname -s)" == "Darwin" ]]; then OS_KIND="macos"; fi

# ── 工具函数 ──
detect_installed() {
  command -v openclaw >/dev/null 2>&1 && return 0
  pnpm list -g 2>/dev/null | grep -q openclaw && return 0
  npm list -g 2>/dev/null | grep -q openclaw && return 0
  [[ -d "$HOME/.openclaw" ]] && return 0
  if [[ "$OS_KIND" == "macos" ]]; then
    launchctl list 2>/dev/null | grep -qi openclaw && return 0
  else
    systemctl --user list-unit-files 2>/dev/null | grep -qi openclaw && return 0
  fi
  return 1
}

stop_openclaw_processes() {
  info "查找并停止运行中的 OpenClaw 进程..."
  local killed=0
  # 通过 ps 找命令行含 openclaw 的 node 进程
  local pids
  pids=$(ps -eo pid,command 2>/dev/null | grep -i 'openclaw' | grep -v 'grep' | grep -v 'uninstall-openclaw' | awk '{print $1}')
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null && success "已停止 PID $pid" && killed=$((killed+1))
    fi
  done
  # 残留再 -9
  sleep 1
  pids=$(ps -eo pid,command 2>/dev/null | grep -i 'openclaw' | grep -v 'grep' | grep -v 'uninstall-openclaw' | awk '{print $1}')
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null && warn "强制 kill PID $pid"
    fi
  done
  [[ $killed -eq 0 ]] && info "没有运行中的 OpenClaw 进程"
}

uninstall_gateway_service() {
  # 优先让 openclaw 自己注销 service（它知道怎么处理 launchd/systemd 单元）
  if command -v openclaw >/dev/null 2>&1; then
    info "正在让 openclaw 自己注销 gateway 服务..."
    openclaw gateway uninstall 2>/dev/null && success "Gateway 服务已注销" && return
    warn "openclaw gateway uninstall 失败或不可用，尝试手动清理..."
  fi
  # 手动兜底
  if [[ "$OS_KIND" == "macos" ]]; then
    local plist
    for plist in "$HOME/Library/LaunchAgents/com.openclaw."*.plist; do
      [[ -e "$plist" ]] || continue
      local label
      label=$(basename "$plist" .plist)
      launchctl unload "$plist" 2>/dev/null
      rm -f "$plist" && success "已删除 launch agent: $label"
    done
  else
    local unit
    for unit in $(systemctl --user list-unit-files 2>/dev/null | awk '/openclaw/ {print $1}'); do
      systemctl --user stop "$unit" 2>/dev/null
      systemctl --user disable "$unit" 2>/dev/null
      success "已停止并禁用 $unit"
    done
    rm -f "$HOME/.config/systemd/user/openclaw"*.service 2>/dev/null
    systemctl --user daemon-reload 2>/dev/null
  fi
}

remove_global_package() {
  info "通过包管理器卸载 openclaw..."
  local removed=0
  if command -v pnpm >/dev/null 2>&1 && pnpm list -g 2>/dev/null | grep -q openclaw; then
    if pnpm uninstall -g openclaw >/dev/null 2>&1; then
      success "pnpm 已卸载 openclaw"; removed=1
    else
      warn "pnpm uninstall 失败"
    fi
  fi
  if command -v npm >/dev/null 2>&1 && npm list -g 2>/dev/null | grep -q openclaw; then
    if npm uninstall -g openclaw >/dev/null 2>&1; then
      success "npm 已卸载 openclaw"; removed=1
    else
      warn "npm uninstall 失败（可能需要 sudo）"
    fi
  fi
  [[ $removed -eq 0 ]] && info "未在 pnpm / npm 全局列表中发现 openclaw（可能已被卸载）"
}

remove_user_data() {
  if [[ $KEEP_USER_DATA -eq 1 ]]; then
    info "传入 --keep-user-data，保留 ~/.openclaw 不删除"
    return
  fi
  if [[ -d "$HOME/.openclaw" ]]; then
    local size
    size=$(du -sh "$HOME/.openclaw" 2>/dev/null | awk '{print $1}')
    info "正在删除用户数据目录 ~/.openclaw（约 ${size:-?}）..."
    if rm -rf "$HOME/.openclaw"; then
      success "用户数据目录已删除"
    else
      err "删除失败，可能某个进程占用文件"
    fi
  else
    info "~/.openclaw 不存在，跳过"
  fi
}

clear_env_vars() {
  info "清理 OpenClaw 写入 shell profile 的环境变量..."

  local profiles=()
  [[ -f "$HOME/.zshrc"   ]] && profiles+=("$HOME/.zshrc")
  [[ -f "$HOME/.bashrc"  ]] && profiles+=("$HOME/.bashrc")
  [[ -f "$HOME/.profile" ]] && profiles+=("$HOME/.profile")
  [[ -f "$HOME/.bash_profile" ]] && profiles+=("$HOME/.bash_profile")

  if [[ ${#profiles[@]} -eq 0 ]]; then
    info "未发现 shell profile 文件，跳过"
    return
  fi

  # 跨平台 sed -i 写法
  local sed_inplace=()
  if sed --version >/dev/null 2>&1; then
    sed_inplace=(sed -i)               # GNU sed
  else
    sed_inplace=(sed -i '')            # BSD sed (macOS)
  fi

  for f in "${profiles[@]}"; do
    local changed=0
    # 删 export CLAWHUB_REGISTRY=... 那行
    if grep -q '^export CLAWHUB_REGISTRY=' "$f" 2>/dev/null; then
      "${sed_inplace[@]}" '/^export CLAWHUB_REGISTRY=/d' "$f" 2>/dev/null && changed=1
    fi
    # 删紧邻的 OpenClaw 注释行
    if grep -q '^# OpenClaw ClawHub 国内镜像' "$f" 2>/dev/null; then
      "${sed_inplace[@]}" '/^# OpenClaw ClawHub 国内镜像/d' "$f" 2>/dev/null && changed=1
    fi
    [[ $changed -eq 1 ]] && success "已清理 $f"
  done

  # 当前进程的 env 也清掉（仅当前 shell 生效，子进程会重新加载 profile）
  unset CLAWHUB_REGISTRY OPENCLAW_VERSION OPENCLAW_GATEWAY_TOKEN 2>/dev/null
}

verify_cleanup() {
  step "验证清理结果"
  local issues=0

  if pnpm list -g 2>/dev/null | grep -q openclaw; then
    err "pnpm 全局仍有 openclaw"; issues=$((issues+1))
  else
    success "pnpm 全局已无 openclaw"
  fi

  if npm list -g 2>/dev/null | grep -q openclaw; then
    err "npm 全局仍有 openclaw"; issues=$((issues+1))
  else
    success "npm 全局已无 openclaw"
  fi

  if command -v openclaw >/dev/null 2>&1; then
    err "openclaw 命令仍在 PATH: $(command -v openclaw)"; issues=$((issues+1))
  else
    success "openclaw 命令已不在 PATH 中"
  fi

  if [[ $KEEP_USER_DATA -eq 0 ]]; then
    if [[ -d "$HOME/.openclaw" ]]; then
      err "~/.openclaw 仍存在"; issues=$((issues+1))
    else
      success "~/.openclaw 已删除"
    fi
  fi

  if [[ "$OS_KIND" == "macos" ]]; then
    if launchctl list 2>/dev/null | grep -qi openclaw; then
      err "macOS launchd 仍有 OpenClaw 服务"; issues=$((issues+1))
    else
      success "macOS launchd 无 OpenClaw 服务"
    fi
  else
    if systemctl --user list-unit-files 2>/dev/null | grep -qi openclaw; then
      err "systemd --user 仍有 OpenClaw 单元"; issues=$((issues+1))
    else
      success "systemd --user 无 OpenClaw 单元"
    fi
  fi

  return "$issues"
}

# ── 主流程 ──
main() {
  printf "\n  🦞 ${C_GREEN}OpenClaw 一键卸载脚本${C_RESET}\n"
  printf "  ${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n\n"

  if ! detect_installed; then
    success "未检测到 OpenClaw 安装痕迹，无需卸载"
    return 0
  fi

  if [[ $FORCE -eq 0 ]]; then
    printf "  ${C_YELLOW}即将执行的操作：${C_RESET}\n"
    printf "    1. 停止所有 OpenClaw 相关进程\n"
    printf "    2. 注销 launchd / systemd 服务单元\n"
    printf "    3. 卸载 pnpm / npm 全局 openclaw 包\n"
    if [[ $KEEP_USER_DATA -eq 1 ]]; then
      printf "    4. ${C_GRAY}跳过：保留 ~/.openclaw（传入了 --keep-user-data）${C_RESET}\n"
    else
      printf "    4. 删除 ~/.openclaw 全部用户数据 (含会话历史 / 缓存)\n"
    fi
    printf "    5. 从 shell profile 移除 CLAWHUB_REGISTRY 等环境变量\n\n"
    printf "  确认继续？[y/N] "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      info "已取消"
      return 0
    fi
  fi

  step "步骤 1/5: 终止运行中的进程"
  stop_openclaw_processes

  step "步骤 2/5: 注销 Gateway 服务（launchd / systemd）"
  uninstall_gateway_service

  step "步骤 3/5: 卸载全局 npm 包"
  remove_global_package

  step "步骤 4/5: 处理用户数据目录"
  remove_user_data

  step "步骤 5/5: 清理环境变量 / shell profile"
  clear_env_vars

  verify_cleanup
  local issues=$?

  printf "\n  ${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
  if [[ $issues -eq 0 ]]; then
    printf "  🦞 ${C_GREEN}卸载完成！系统已干净${C_RESET}\n"
  else
    printf "  ⚠ ${C_YELLOW}卸载基本完成，但有 $issues 项未完全清理（详见上方）${C_RESET}\n"
  fi
  printf "  ${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n\n"

  if [[ $KEEP_USER_DATA -eq 0 ]]; then
    printf "  ${C_GRAY}提示：新打开终端窗口后 PATH / 环境变量才会刷新${C_RESET}\n\n"
  fi
}

main
