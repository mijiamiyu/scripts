#!/usr/bin/env bash
#
# Time MCP 一键安装脚本 (macOS / Linux)
# 用法:
#   bash install-time-mcp.sh
#   curl -fsSL https://gitee.com/mijiamiyu/scripts/raw/main/install-time-mcp.sh | bash
#

set -euo pipefail

# 清掉学员机器可能残留的代理 env(VPN/翻墙软件关掉后留的),避免 pip 走死代理连不上清华源
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy 2>/dev/null || true

# ── 颜色输出 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ ${NC}$*"; }
success() { echo -e "${GREEN}✅ ${NC}$*"; }
warn()    { echo -e "${YELLOW}⚠️  ${NC}$*"; }
error()   { echo -e "${RED}❌ ${NC}$*"; }
step()    { echo -e "\n${CYAN}━━━ $* ━━━${NC}\n"; }

# ── 全局配置 ──
OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_CFG="$OPENCLAW_DIR/openclaw.json"
PIP_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
PKG_NAME="mcp-server-time"      # PyPI 包名(横线)
MODULE_NAME="mcp_server_time"   # Python 模块名(下划线)
LOCAL_TZ="Asia/Shanghai"

# ── 0/4  检查环境 ──
step "0/4  检查环境"

if [[ ! -d "$OPENCLAW_DIR" ]]; then
    error "未找到 ~/.openclaw/ 目录,请先装 OpenClaw"
    exit 1
fi
success "OpenClaw 配置目录: $OPENCLAW_DIR"

if ! command -v node >/dev/null 2>&1; then
    error "未找到 node 命令。OpenClaw 依赖 Node.js,请先装 OpenClaw"
    exit 1
fi
success "Node.js 可用: $(node --version)"

if ! command -v python3 >/dev/null 2>&1; then
    error "未找到 python3 命令"
    error "请先装 Python 3.10+:"
    error "  macOS: brew install python3"
    error "  或 https://www.python.org/downloads/"
    exit 1
fi
success "Python 可用: $(python3 --version)"

# ── 1/4  装 Time MCP 包 ──
step "1/4  装 mcp-server-time(走清华源)"
info "pip install -i $PIP_INDEX $PKG_NAME"
if ! python3 -m pip install -i "$PIP_INDEX" "$PKG_NAME"; then
    error "pip install 失败"
    error "可能原因:"
    error "  1. Python 装在系统目录(系统 Python),无写权限"
    error "     -> 加 --user 选项,或用 brew 装一个用户级 Python"
    error "  2. 网络问题(清华源连不上)"
    exit 1
fi
success "mcp-server-time 已装好"

# ── 2/4  写入 openclaw.json ──
step "2/4  写入 OpenClaw 配置(mcp.servers.time)"

TMP_DIR=$(mktemp -d -t time-mcp-install-XXXXXX)
trap "rm -rf $TMP_DIR" EXIT

MERGE_JS="$TMP_DIR/_merge.js"
cat > "$MERGE_JS" << 'EOF'
const fs = require('fs');
const cfgPath = process.argv[2];
const cmd = process.argv[3];
const moduleName = process.argv[4];
const localTz = process.argv[5];

const cfg = fs.existsSync(cfgPath) ? JSON.parse(fs.readFileSync(cfgPath, 'utf-8')) : {};
cfg.mcp = cfg.mcp || {};
cfg.mcp.servers = cfg.mcp.servers || {};
cfg.mcp.servers.time = {
  command: cmd,
  args: ['-m', moduleName, '--local-timezone=' + localTz]
};

if (fs.existsSync(cfgPath)) fs.copyFileSync(cfgPath, cfgPath + '.bak');
fs.writeFileSync(cfgPath + '.tmp', JSON.stringify(cfg, null, 2));
fs.renameSync(cfgPath + '.tmp', cfgPath);
console.log('OK');
EOF

RESULT=$(node "$MERGE_JS" "$OPENCLAW_CFG" "python3" "$MODULE_NAME" "$LOCAL_TZ")
if [[ "$RESULT" != "OK" ]]; then
    error "写入 openclaw.json 失败"
    exit 1
fi
success "已写入 $OPENCLAW_CFG"
if [[ -f "$OPENCLAW_CFG.bak" ]]; then
    info "原配置已备份: $OPENCLAW_CFG.bak"
fi

# ── 3/4  重启 gateway ──
step "3/4  让新配置生效"
is_running=false
if (echo > /dev/tcp/127.0.0.1/18789) 2>/dev/null; then
    is_running=true
elif command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 18789 2>/dev/null; then
    is_running=true
fi

if [[ "$is_running" == "true" ]]; then
    info "检测到 OpenClaw gateway 正在运行(127.0.0.1:18789)"
    if command -v openclaw >/dev/null 2>&1; then
        nohup openclaw gateway restart >/dev/null 2>&1 &
        success "已发送 gateway restart 信号(后台执行,十几秒后生效)"
    else
        warn "找不到 openclaw 命令,无法自动 restart"
        warn "请手动关掉 OpenClaw 重新启动"
    fi
else
    info "OpenClaw gateway 未运行,新配置会在你下次启动 OpenClaw 时自动生效"
fi

# ── 4/4  完成 ──
step "4/4  完成"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Time MCP 已装好${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  配置文件: $OPENCLAW_CFG"
echo ""
echo -e "${CYAN}  下一步:${NC}"
echo "    用飞书发一句 '现在几点了?',验证 AI 能回精确到秒的时间"
echo ""
