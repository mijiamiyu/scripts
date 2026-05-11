#!/usr/bin/env bash
set -Eeuo pipefail

# 打开用户级 skill 目录(~/.agents/skills/)。不存在则自动创建。
# 在线使用:
#   curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/open-skills-folder.sh | bash
#   curl -fsSL https://gitee.com/mijiamiyu/scripts/raw/main/open-skills-folder.sh | bash

info() { printf '  \033[34m[INFO]\033[0m %s\n' "$1"; }
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; }

skills_dir="$HOME/.agents/skills"

if [[ ! -d "$skills_dir" ]]; then
  info "skills 目录不存在,正在创建: $skills_dir"
  if mkdir -p "$skills_dir"; then
    ok "已创建: $skills_dir"
  else
    fail "创建失败"
    exit 1
  fi
else
  info "skills 目录: $skills_dir"
fi

if command -v open >/dev/null 2>&1; then
  open "$skills_dir"
  ok "已打开 skills 文件夹"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$skills_dir" >/dev/null 2>&1 &
  ok "已打开 skills 文件夹"
else
  info "当前环境没有图形化打开命令,请手动进入: $skills_dir"
fi
