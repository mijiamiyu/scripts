#!/usr/bin/env bash
set -Eeuo pipefail

# 打开 OpenClaw 配置文件夹。
# 在线使用:
#   curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/open-openclaw-folder.sh | bash
#   curl -fsSL https://gitee.com/mijiamiyu/scripts/raw/main/open-openclaw-folder.sh | bash

info() { printf '  \033[34m[INFO]\033[0m %s\n' "$1"; }
ok() { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }

openclaw_dir="$HOME/.openclaw"

if [[ ! -d "$openclaw_dir" ]]; then
  fail "没有找到 OpenClaw 文件夹: $openclaw_dir"
  info "可能还没有安装 OpenClaw，或当前用户不是安装 OpenClaw 的用户"
  exit 1
fi

info "OpenClaw 文件夹: $openclaw_dir"

if command -v open >/dev/null 2>&1; then
  open "$openclaw_dir"
  ok "已打开 OpenClaw 文件夹"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$openclaw_dir" >/dev/null 2>&1 &
  ok "已打开 OpenClaw 文件夹"
else
  info "当前环境没有图形化打开命令，请手动进入: $openclaw_dir"
fi
