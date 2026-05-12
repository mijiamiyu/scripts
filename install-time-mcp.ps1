# Time MCP 一键安装脚本 (Windows)
# 用法:
#   powershell -ExecutionPolicy Bypass -File install-time-mcp.ps1
# 在线一键安装:
#   irm https://gitee.com/mijiamiyu/scripts/raw/main/install-time-mcp.ps1 | iex

# ── Process Scope Bypass ──
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch {}

# ── 重启自修复 ──
if ($MyInvocation.MyCommand.Path) {
    try {
        $policy = Get-ExecutionPolicy -Scope Process
        if ($policy -eq "Restricted" -or $policy -eq "AllSigned") {
            Write-Host "  [INFO] 检测到执行策略为 $policy，正在以 Bypass 策略重新启动..." -ForegroundColor Blue
            Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Wait -NoNewWindow
            exit $LASTEXITCODE
        }
    } catch {}
}

# ── UTF-8 编码 ──
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ── 颜色输出 ──
function Write-Info  { param($Msg) Write-Host "  [INFO] " -ForegroundColor Blue -NoNewline; Write-Host $Msg }
function Write-Ok    { param($Msg) Write-Host "  [OK]   " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Warn  { param($Msg) Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err   { param($Msg) Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline; Write-Host $Msg }
function Write-Step  { param($Msg) Write-Host "`n━━━ $Msg ━━━`n" -ForegroundColor Cyan }

# ── 全局配置 ──
$OPENCLAW_DIR = Join-Path $HOME ".openclaw"
$OPENCLAW_CFG = Join-Path $OPENCLAW_DIR "openclaw.json"
$PIP_INDEX    = "https://pypi.tuna.tsinghua.edu.cn/simple"
$PKG_NAME     = "mcp-server-time"      # PyPI 包名(横线)
$MODULE_NAME  = "mcp_server_time"      # Python 模块名(下划线)
$LOCAL_TZ     = "Asia/Shanghai"

# ── 0/4  检查环境 ──
Write-Step "0/4  检查环境"

if (-not (Test-Path $OPENCLAW_DIR)) {
    Write-Err "未找到 ~/.openclaw/ 目录,请先装 OpenClaw"
    exit 1
}
Write-Ok "OpenClaw 配置目录: $OPENCLAW_DIR"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Err "未找到 node 命令。OpenClaw 依赖 Node.js,请先装 OpenClaw"
    exit 1
}
Write-Ok "Node.js 可用: $((node --version))"

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Err "未找到 python 命令"
    Write-Err "请先装 Python 3.10+:https://www.python.org/downloads/"
    Write-Err "(安装时务必勾选 'Add Python to PATH')"
    exit 1
}
$pyVer = (& python --version) 2>&1
Write-Ok "Python 可用: $pyVer"

# ── 1/4  装 Time MCP 包 ──
Write-Step "1/4  装 mcp-server-time(走清华源)"
Write-Info "pip install -i $PIP_INDEX $PKG_NAME"
& python -m pip install -i $PIP_INDEX $PKG_NAME
if ($LASTEXITCODE -ne 0) {
    Write-Err "pip install 失败(exit code $LASTEXITCODE)"
    Write-Err "可能原因:"
    Write-Err "  1. Python 装在系统目录(如 anaconda 在 ProgramData),无写权限"
    Write-Err "     -> 用管理员 PowerShell 重跑,或换装 python.org 用户级 Python"
    Write-Err "  2. 网络问题(清华源连不上)"
    exit 1
}
Write-Ok "mcp-server-time 已装好"

# ── 2/4  写入 openclaw.json ──
Write-Step "2/4  写入 OpenClaw 配置(mcp.servers.time)"

$tmpDir = Join-Path $env:TEMP "time-mcp-install-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

$nodeMergeScript = @"
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
"@

$mergeScriptPath = Join-Path $tmpDir "_merge.js"
Set-Content -Path $mergeScriptPath -Value $nodeMergeScript -Encoding UTF8

$result = & node $mergeScriptPath $OPENCLAW_CFG "python" $MODULE_NAME $LOCAL_TZ
if ($result -ne "OK") {
    Write-Err "写入 openclaw.json 失败"
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    exit 1
}
Write-Ok "已写入 $OPENCLAW_CFG"
if (Test-Path "$OPENCLAW_CFG.bak") {
    Write-Info "原配置已备份: $OPENCLAW_CFG.bak"
}

Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

# ── 3/4  重启 gateway ──
Write-Step "3/4  让新配置生效"
$tcp = New-Object Net.Sockets.TcpClient
$isRunning = $false
try {
    $connectTask = $tcp.ConnectAsync("127.0.0.1", 18789)
    if ($connectTask.Wait(2000) -and $tcp.Connected) {
        $isRunning = $true
    }
} catch {} finally {
    try { $tcp.Close() } catch {}
}

if ($isRunning) {
    Write-Info "检测到 OpenClaw gateway 正在运行(127.0.0.1:18789)"
    if (Get-Command openclaw -ErrorAction SilentlyContinue) {
        Start-Job -ScriptBlock { & openclaw gateway restart 2>&1 } | Out-Null
        Write-Ok "已发送 gateway restart 信号(后台执行,十几秒后生效)"
    } else {
        Write-Warn "找不到 openclaw 命令,无法自动 restart"
        Write-Warn "请手动关掉 OpenClaw 重新启动"
    }
} else {
    Write-Info "OpenClaw gateway 未运行,新配置会在你下次启动 OpenClaw 时自动生效"
}

# ── 4/4  完成 ──
Write-Step "4/4  完成"
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  Time MCP 已装好" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
Write-Host "  配置文件: $OPENCLAW_CFG"
Write-Host ""
Write-Host "  下一步:" -ForegroundColor Cyan
Write-Host "    用飞书发一句 '现在几点了?',验证 AI 能回精确到秒的时间"
Write-Host ""
