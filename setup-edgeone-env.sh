#!/usr/bin/env bash
#
# EdgeOne Pages 培训环境一键装 (macOS / Linux)
# 装 Node.js LTS + 全局切 npm 国内镜像源 + 装 edgeone CLI
#
# 用法:
#   bash setup-edgeone-env.sh
#   curl -fsSL https://gitee.com/mijiamiyu/scripts/raw/main/setup-edgeone-env.sh | bash
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
NODE_MIRROR="https://npmmirror.com/mirrors/node"
NPM_REGISTRY="https://registry.npmmirror.com"
NODE_MAJOR_LTS=22
REQUIRED_NODE=18

# ── 工具函数 ──

get_node_major() {
    if ! command -v node >/dev/null 2>&1; then echo 0; return; fi
    node -v 2>/dev/null | sed 's/^v\([0-9][0-9]*\).*/\1/' || echo 0
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "x64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) echo "$arch" ;;
    esac
}

get_os() {
    case "$(uname -s)" in
        Darwin) echo "darwin" ;;
        Linux)  echo "linux"  ;;
        *) echo "unknown" ;;
    esac
}

get_latest_node_version() {
    local major="$1"
    local urls=(
        "$NODE_MIRROR/latest-v${major}.x/SHASUMS256.txt"
        "https://nodejs.org/dist/latest-v${major}.x/SHASUMS256.txt"
    )
    for url in "${urls[@]}"; do
        if curl -fsSL --max-time 15 "$url" 2>/dev/null \
            | grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+" \
            | head -1 \
            | sed 's/^node-//'; then
            return 0
        fi
    done
    return 1
}

# ── 全局变量保留学员当前 shell 配置文件路径 ──
detect_shell_rc() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS 默认 zsh
        echo "$HOME/.zshrc"
    else
        # Linux 看当前 shell
        case "${SHELL:-}" in
            */zsh)  echo "$HOME/.zshrc"  ;;
            */bash) echo "$HOME/.bashrc" ;;
            *)      echo "$HOME/.profile" ;;
        esac
    fi
}

install_node_direct() {
    info "下载安装 Node.js v$NODE_MAJOR_LTS LTS..."

    local os arch version filename tmpdir installdir rc_file
    os=$(get_os)
    arch=$(get_arch)
    version=$(get_latest_node_version "$NODE_MAJOR_LTS")
    if [[ -z "${version:-}" ]]; then
        error "无法获取 Node.js 版本信息,检查网络"
        return 1
    fi
    info "最新 LTS 版本: $version"

    filename="node-${version}-${os}-${arch}.tar.gz"
    tmpdir=$(mktemp -d -t edgeone-setup-XXXXXX)
    installdir="$HOME/.local/nodejs"
    rc_file=$(detect_shell_rc)

    local urls=(
        "$NODE_MIRROR/${version}/${filename}"
        "https://nodejs.org/dist/${version}/${filename}"
    )

    local downloaded=false
    for url in "${urls[@]}"; do
        info "从 $(echo "$url" | sed 's|https://||; s|/.*||') 下载..."
        if curl -fsSL --max-time 600 -o "$tmpdir/$filename" "$url"; then
            downloaded=true
            success "下载完成"
            break
        fi
        warn "下载失败,尝试备用源..."
    done

    if ! $downloaded; then
        error "Node.js 下载失败"
        rm -rf "$tmpdir"
        return 1
    fi

    info "解压安装..."
    tar -xzf "$tmpdir/$filename" -C "$tmpdir"
    rm -rf "$installdir"
    mkdir -p "$(dirname "$installdir")"
    mv "$tmpdir/node-${version}-${os}-${arch}" "$installdir"
    rm -rf "$tmpdir"

    # 加 PATH(永久,写 rc 文件)
    local line='export PATH="$HOME/.local/nodejs/bin:$PATH"'
    if [[ -f "$rc_file" ]] && grep -qF "$HOME/.local/nodejs/bin" "$rc_file" 2>/dev/null; then
        info "PATH 已在 $rc_file 配置过,跳过写入"
    else
        echo "" >> "$rc_file"
        echo "# Node.js (edgeone setup)" >> "$rc_file"
        echo "$line" >> "$rc_file"
        success "已将 \$HOME/.local/nodejs/bin 永久加入 PATH ($rc_file)"
    fi
    export PATH="$HOME/.local/nodejs/bin:$PATH"

    local ver_check
    ver_check=$(get_node_major)
    if [[ "$ver_check" -ge "$REQUIRED_NODE" ]]; then
        success "Node.js $(node -v) 装好"
        return 0
    fi
    warn "Node.js 装完但验证失败,可能要重开终端"
    return 1
}

# ── 主流程 ──

echo ""
echo -e "${CYAN}  🌐 EdgeOne Pages 培训环境一键装${NC}"
echo -e "${CYAN}  ──────────────────────────────${NC}"
echo ""

# Step 1/4: Node.js
step "1/4  Node.js"

current_major=$(get_node_major)
if [[ "$current_major" -ge "$REQUIRED_NODE" ]]; then
    success "Node.js 已装且版本符合: $(node -v)"
else
    if [[ "$current_major" -gt 0 ]]; then
        warn "已有 Node.js $(node -v) 但版本 < $REQUIRED_NODE,准备装新版"
    else
        info "未检测到 Node.js,开始安装"
    fi
    if ! install_node_direct; then
        error "Node.js 安装失败,后续步骤无法继续"
        exit 1
    fi
fi

# Step 2/4: npm 全局切镜像源(永久)
step "2/4  全局切 npm 国内镜像源"

if npm config set registry "$NPM_REGISTRY"; then
    current=$(npm config get registry)
    if [[ "$current" == "$NPM_REGISTRY" ]]; then
        success "npm registry 已永久切到 $NPM_REGISTRY"
        info "(配置写入 ~/.npmrc,所有后续 npm 命令默认走国内镜像)"
    else
        warn "npm registry 切换可能未生效,当前: $current"
    fi
else
    error "npm config 操作失败"
fi

# Step 3/4: 装 edgeone CLI
step "3/4  装 edgeone CLI"

if npm install -g edgeone@latest; then
    success "edgeone CLI 已装"
else
    error "edgeone CLI 安装失败"
    warn "macOS 全局装 npm 包可能要 sudo,试: sudo npm install -g edgeone@latest"
    warn "或者用 nvm 装的 Node 默认不要 sudo"
    exit 1
fi

# Step 4/4: 验证
step "4/4  验证 edgeone CLI 版本"

eo_ver=$(edgeone -v 2>/dev/null || true)
if [[ -n "$eo_ver" ]]; then
    if [[ "$eo_ver" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        vmajor="${BASH_REMATCH[1]}"
        vminor="${BASH_REMATCH[2]}"
        vpatch="${BASH_REMATCH[3]}"
        if [[ "$vmajor" -gt 1 ]] \
            || [[ "$vmajor" -eq 1 && "$vminor" -gt 2 ]] \
            || [[ "$vmajor" -eq 1 && "$vminor" -eq 2 && "$vpatch" -ge 30 ]]; then
            success "edgeone CLI: $eo_ver (>= 1.2.30 符合官方 skill 要求)"
        else
            warn "edgeone CLI: $eo_ver (低于 1.2.30,可能要重装)"
        fi
    else
        warn "edgeone CLI 已装但版本号格式异常: $eo_ver"
    fi
else
    warn "edgeone 命令未找到,可能要重开终端再试"
fi

echo ""
echo -e "${GREEN}  环境配置完成${NC}"
echo ""
