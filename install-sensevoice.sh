#!/usr/bin/env bash
#
# SenseVoice 一键安装脚本 (macOS / Linux)
# 用法:
#   bash install-sensevoice.sh
#   curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/install-sensevoice.sh | bash
#

set -euo pipefail

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
RELEASE_BASE="https://gitee.com/mijiamiyu/sherpa/releases/download/v1"
INSTALL_DIR="$HOME/.openclaw-bin/sensevoice"
OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_CFG="$OPENCLAW_DIR/openclaw.json"

# ── 平台检测 ──
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS-$ARCH" in
    Darwin-arm64)
        PLATFORM="macos-arm64"
        BINARY_FILE="transcribe-macos-arm64"
        ;;
    Darwin-x86_64)
        # Intel Mac 跑 arm64 binary 走 Rosetta 2(性能损失 <10%)
        PLATFORM="macos-x64-rosetta"
        BINARY_FILE="transcribe-macos-arm64"
        info "检测到 Intel Mac,将使用 arm64 binary + Rosetta 2 转译"
        info "如果未装 Rosetta 2,跑 transcribe 时系统会自动提示安装"
        ;;
    Linux-*)
        error "Linux 平台未提供预编译 transcribe binary"
        error "(夜校课程主要支持 Win/Mac;如果是 Linux 学生请联系讲师)"
        exit 1
        ;;
    *)
        error "不支持的平台: $OS $ARCH"
        exit 1
        ;;
esac

# ── 交互式输入支持 ──
HAS_TTY=false
if [[ -t 0 ]] || [[ -e /dev/tty ]]; then
    HAS_TTY=true
fi

prompt_confirm() {
    local prompt_text="$1"
    local default_val="${2:-n}"
    local ans
    if [[ "$HAS_TTY" == "true" ]]; then
        if [[ -t 0 ]]; then
            read -rp "$prompt_text" ans
        else
            read -rp "$prompt_text" ans < /dev/tty
        fi
    else
        ans="$default_val"
    fi
    echo "$ans"
}

# ── 检测环境 ──
step "0/7  检查环境"

if [[ ! -d "$OPENCLAW_DIR" ]]; then
    warn "未找到 ~/.openclaw/ 目录"
    warn "建议先装 OpenClaw 再继续"
    warn "继续装也可以,但 openclaw.json 会被新建"
    ans=$(prompt_confirm "  继续? (y/n,默认 n): ")
    if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
        info "已取消"
        exit 0
    fi
    mkdir -p "$OPENCLAW_DIR"
fi
success "OpenClaw 配置目录: $OPENCLAW_DIR"

if ! command -v node >/dev/null 2>&1; then
    error "未找到 node 命令。OpenClaw 依赖 Node.js,请先装 OpenClaw"
    exit 1
fi
success "Node.js 可用: $(node --version)"

if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    error "找不到 shasum / sha256sum 命令"
    exit 1
fi

# ── 创建安装目录 ──
step "1/7  创建安装目录"
if [[ -d "$INSTALL_DIR" ]]; then
    warn "目录已存在: $INSTALL_DIR"
    ans=$(prompt_confirm "  覆盖? (y/n,默认 y): " "y")
    if [[ "$ans" == "n" || "$ans" == "N" ]]; then
        info "已取消"
        exit 0
    fi
    rm -rf "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"
success "已创建: $INSTALL_DIR"

# ── 下载函数(curl 自带进度条) ──
download_file() {
    local url="$1"
    local dest="$2"
    local label="$3"
    info "下载 $label ..."
    # -# 简洁进度条而非全静默
    if ! curl -fL --progress-bar --max-time 300 "$url" -o "$dest"; then
        error "下载失败: $url"
        exit 1
    fi
    local size
    if [[ "$OS" == "Darwin" ]]; then
        size=$(stat -f%z "$dest")
    else
        size=$(stat -c%s "$dest")
    fi
    success "  -> $((size / 1024 / 1024)) MB"
}

# ── 下载 transcribe 二进制(自包含 sherpa-onnx + ffmpeg) ──
step "2/7  下载语音识别引擎"
info "检测到系统平台: $PLATFORM ($OS $ARCH)"
TMP_DIR=$(mktemp -d -t sensevoice-install-XXXXXX)
trap "rm -rf $TMP_DIR" EXIT

BIN_PATH="$INSTALL_DIR/transcribe"
download_file "$RELEASE_BASE/$BINARY_FILE" "$BIN_PATH" "transcribe"
chmod +x "$BIN_PATH"
success "二进制可用: $BIN_PATH"

# ── 下载模型 3 块 + tokens + manifest ──
step "3/7  下载语音识别模型(228 MB,分 3 块)"
for part in aa ab ac; do
    download_file "$RELEASE_BASE/model.int8.onnx.part-$part" "$TMP_DIR/model.int8.onnx.part-$part" "模型分块 $part"
done

TOKENS_PATH="$INSTALL_DIR/tokens.txt"
download_file "$RELEASE_BASE/tokens.txt" "$TOKENS_PATH" "tokens.txt(词表)"
download_file "$RELEASE_BASE/manifest.txt" "$TMP_DIR/manifest.txt" "manifest.txt(校验)"

# ── 合并模型 + 校验 ──
step "4/7  合并模型 + 校验完整性"
MODEL_PATH="$INSTALL_DIR/model.int8.onnx"
info "合并 3 块为 model.int8.onnx ..."
cat "$TMP_DIR/model.int8.onnx.part-aa" "$TMP_DIR/model.int8.onnx.part-ab" "$TMP_DIR/model.int8.onnx.part-ac" > "$MODEL_PATH"
if [[ "$OS" == "Darwin" ]]; then
    MODEL_SIZE=$(stat -f%z "$MODEL_PATH")
else
    MODEL_SIZE=$(stat -c%s "$MODEL_PATH")
fi
success "合并完成: $((MODEL_SIZE / 1024 / 1024)) MB"

info "校验 SHA256 ..."
EXPECTED_HASH=$(awk '{print $1}' "$TMP_DIR/manifest.txt" | tr -d ' ')
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_HASH=$(sha256sum "$MODEL_PATH" | awk '{print $1}')
else
    ACTUAL_HASH=$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')
fi
if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
    error "SHA256 不匹配! 模型文件损坏,请重新跑脚本"
    error "  实测: $ACTUAL_HASH"
    error "  预期: $EXPECTED_HASH"
    rm -f "$MODEL_PATH"
    exit 1
fi
success "SHA256 校验通过: $ACTUAL_HASH"

# ── 配置 openclaw.json ──
step "5/7  写入 OpenClaw 配置"

MERGE_JS="$TMP_DIR/_merge.js"
cat > "$MERGE_JS" << 'EOF'
const fs = require('fs');
const cfgPath = process.argv[2];
const cfg = fs.existsSync(cfgPath) ? JSON.parse(fs.readFileSync(cfgPath, 'utf-8')) : {};
cfg.tools = cfg.tools || {};
cfg.tools.media = cfg.tools.media || {};
cfg.tools.media.audio = {
  enabled: true,
  maxBytes: 20971520,
  models: [{
    type: 'cli',
    command: process.argv[3],
    args: ['{{MediaPath}}'],
    timeoutSeconds: 45
  }]
};
if (fs.existsSync(cfgPath)) fs.copyFileSync(cfgPath, cfgPath + '.bak');
fs.writeFileSync(cfgPath + '.tmp', JSON.stringify(cfg, null, 2));
fs.renameSync(cfgPath + '.tmp', cfgPath);
console.log('OK');
EOF

RESULT=$(node "$MERGE_JS" "$OPENCLAW_CFG" "$BIN_PATH")
if [[ "$RESULT" != "OK" ]]; then
    error "写入 openclaw.json 失败"
    exit 1
fi
success "已写入 $OPENCLAW_CFG"
if [[ -f "$OPENCLAW_CFG.bak" ]]; then
    info "原配置已备份: $OPENCLAW_CFG.bak"
fi

# ── 清理 ──
step "6/7  清理临时文件"
rm -rf "$TMP_DIR"
trap - EXIT
success "已清理临时目录"

# ── 自动 restart gateway(如果在跑) ──
step "7/7  让新配置生效"
is_running=false
if (echo > /dev/tcp/127.0.0.1/18789) 2>/dev/null; then
    is_running=true
elif command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 18789 2>/dev/null; then
    is_running=true
fi

if [[ "$is_running" == "true" ]]; then
    info "检测到 OpenClaw gateway 正在运行(127.0.0.1:18789)"
    if command -v openclaw >/dev/null 2>&1; then
        # 后台发 restart 信号,不等结果
        nohup openclaw gateway restart >/dev/null 2>&1 &
        success "已发送 gateway restart 信号(后台执行,十几秒后生效)"
    else
        warn "找不到 openclaw 命令,无法自动 restart"
        warn "请手动关掉 OpenClaw 重新启动"
    fi
else
    info "OpenClaw gateway 未运行,新配置会在你下次启动 OpenClaw 时自动生效"
fi

# ── 完成 ──
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  本地语音识别已装好${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  二进制 + 模型: $INSTALL_DIR"
echo "  配置文件:      $OPENCLAW_CFG"
echo ""
echo -e "${CYAN}  下一步:${NC}"
echo "    1. 如果 OpenClaw 没在运行,启动它(脚本已自动 restart 过运行中的)"
echo "    2. 用飞书发个语音消息,验证识别是否生效"
echo ""
