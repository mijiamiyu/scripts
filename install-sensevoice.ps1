# SenseVoice 一键安装脚本 (Windows)
# 用法:
#   powershell -ExecutionPolicy Bypass -File install-sensevoice.ps1
# 在线一键安装:
#   irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/install-sensevoice.ps1 | iex

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

# 清掉学员机器可能残留的代理 env(VPN/翻墙软件关掉后留的),避免 curl 走死代理连不上 gitee
$env:HTTP_PROXY = $null
$env:HTTPS_PROXY = $null
$env:http_proxy = $null
$env:https_proxy = $null
$env:ALL_PROXY = $null
$env:all_proxy = $null
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── 颜色输出 ──
function Write-Info  { param($Msg) Write-Host "  [INFO] " -ForegroundColor Blue -NoNewline; Write-Host $Msg }
function Write-Ok    { param($Msg) Write-Host "  [OK]   " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Warn  { param($Msg) Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err   { param($Msg) Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline; Write-Host $Msg }
function Write-Step  { param($Msg) Write-Host "`n━━━ $Msg ━━━`n" -ForegroundColor Cyan }

# ── 全局配置 ──
$RELEASE_BASE = "https://gitee.com/mijiamiyu/sherpa/releases/download/v1"
$INSTALL_DIR  = Join-Path $HOME ".openclaw-bin\sensevoice"
$OPENCLAW_DIR = Join-Path $HOME ".openclaw"
$OPENCLAW_CFG = Join-Path $OPENCLAW_DIR "openclaw.json"

# ── 平台检测 ──
$isArm = ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") -or ($env:PROCESSOR_ARCHITEW6432 -eq "ARM64")
if ($isArm) {
    Write-Err "Windows ARM64 暂不支持(transcribe binary 未发布该平台版本)"
    exit 1
}
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Err "需要 64 位 Windows,32 位系统不支持"
    exit 1
}
$WIN_BINARY_NAME = "transcribe-windows-x64.exe"
$WIN_BINARY_SIZE_MB = 62

# ── 检测 OpenClaw 是否装 ──
Write-Step "0/7  检查环境"
if (-not (Test-Path $OPENCLAW_DIR)) {
    Write-Warn "未找到 ~/.openclaw/ 目录"
    Write-Warn "建议先装 OpenClaw 再继续"
    Write-Warn "继续装也可以,但 openclaw.json 会被新建"
    $ans = Read-Host "  继续? (y/n,默认 n)"
    if ($ans -ne "y" -and $ans -ne "Y") {
        Write-Info "已取消"
        exit 0
    }
    New-Item -ItemType Directory -Force -Path $OPENCLAW_DIR | Out-Null
}
Write-Ok "OpenClaw 配置目录: $OPENCLAW_DIR"

# 检查 node 是否可用(用于 JSON merge)
$nodeAvailable = $null -ne (Get-Command node -ErrorAction SilentlyContinue)
if (-not $nodeAvailable) {
    Write-Err "未找到 node 命令。OpenClaw 依赖 Node.js,请先装 OpenClaw"
    exit 1
}
Write-Ok "Node.js 可用: $((node --version))"

# ── 创建安装目录 ──
Write-Step "1/7  创建安装目录"
if (Test-Path $INSTALL_DIR) {
    Write-Warn "目录已存在: $INSTALL_DIR"
    $ans = Read-Host "  覆盖? (y/n,默认 y)"
    if ($ans -eq "n" -or $ans -eq "N") {
        Write-Info "已取消"
        exit 0
    }
    Remove-Item -Recurse -Force $INSTALL_DIR
}
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
Write-Ok "已创建: $INSTALL_DIR"

# ── 下载函数(优先 curl.exe 带进度条,回退 Invoke-WebRequest) ──
$curlExe = (Get-Command curl.exe -ErrorAction SilentlyContinue).Path
function Download-File {
    param([string]$Url, [string]$Dest, [string]$Label)
    Write-Info "下载 $Label ..."
    if ($curlExe) {
        # curl.exe 自带进度条(Win 10/11 内置)
        & $curlExe -L --progress-bar --max-time 300 --fail "$Url" -o "$Dest"
        if ($LASTEXITCODE -ne 0) {
            Write-Err "下载失败 (curl exit code $LASTEXITCODE): $Url"
            exit 1
        }
    } else {
        # fallback 老 Win 没 curl.exe 的情况
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 300
        } catch {
            Write-Err "下载失败: $Url"
            Write-Err "  $_"
            exit 1
        }
    }
    $size = (Get-Item $Dest).Length
    Write-Ok "  -> $([math]::Round($size/1MB, 2)) MB"
}

# ── 下载 transcribe 二进制(自包含 sherpa-onnx + ffmpeg) ──
Write-Step "2/7  下载语音识别引擎(约 $WIN_BINARY_SIZE_MB MB)"
$binPath = Join-Path $INSTALL_DIR "transcribe.exe"
Download-File -Url "$RELEASE_BASE/$WIN_BINARY_NAME" -Dest $binPath -Label "transcribe.exe"

# ── 下载模型 3 块 ──
Write-Step "3/7  下载语音识别模型(228 MB,分 3 块)"
$tmpDir = Join-Path $env:TEMP "sensevoice-install-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

$parts = @("aa", "ab", "ac")
foreach ($part in $parts) {
    $partFile = Join-Path $tmpDir "model.int8.onnx.part-$part"
    Download-File -Url "$RELEASE_BASE/model.int8.onnx.part-$part" -Dest $partFile -Label "模型分块 $part"
}

# tokens.txt + manifest.txt
$tokensPath = Join-Path $INSTALL_DIR "tokens.txt"
Download-File -Url "$RELEASE_BASE/tokens.txt" -Dest $tokensPath -Label "tokens.txt(词表)"

$manifestPath = Join-Path $tmpDir "manifest.txt"
Download-File -Url "$RELEASE_BASE/manifest.txt" -Dest $manifestPath -Label "manifest.txt(校验)"

# ── 合并模型 + 校验 ──
Write-Step "4/7  合并模型 + 校验完整性"
$modelPath = Join-Path $INSTALL_DIR "model.int8.onnx"
Write-Info "合并 3 块为 model.int8.onnx ..."
$out = [System.IO.File]::OpenWrite($modelPath)
try {
    foreach ($part in $parts) {
        $partFile = Join-Path $tmpDir "model.int8.onnx.part-$part"
        $in = [System.IO.File]::OpenRead($partFile)
        $in.CopyTo($out)
        $in.Close()
    }
} finally {
    $out.Close()
}
Write-Ok "合并完成: $([math]::Round((Get-Item $modelPath).Length / 1MB, 2)) MB"

# 校验 SHA256
Write-Info "校验 SHA256 ..."
$actualHash = (Get-FileHash -Algorithm SHA256 $modelPath).Hash.ToLower()
$expectedHash = (Get-Content $manifestPath -Raw).Trim().Split()[0].ToLower()
if ($actualHash -ne $expectedHash) {
    Write-Err "SHA256 不匹配! 模型文件损坏,请重新跑脚本"
    Write-Err "  实测: $actualHash"
    Write-Err "  预期: $expectedHash"
    Remove-Item -Force $modelPath
    Remove-Item -Recurse -Force $tmpDir
    exit 1
}
Write-Ok "SHA256 校验通过: $actualHash"

# ── 配置 openclaw.json ──
Write-Step "5/7  写入 OpenClaw 配置"
$nodeMergeScript = @"
const fs = require('fs'), path = require('path'), os = require('os');
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
"@

$mergeScriptPath = Join-Path $tmpDir "_merge.js"
Set-Content -Path $mergeScriptPath -Value $nodeMergeScript -Encoding UTF8

$result = & node $mergeScriptPath $OPENCLAW_CFG $binPath
if ($result -ne "OK") {
    Write-Err "写入 openclaw.json 失败"
    exit 1
}
Write-Ok "已写入 $OPENCLAW_CFG"
if (Test-Path "$OPENCLAW_CFG.bak") {
    Write-Info "原配置已备份: $OPENCLAW_CFG.bak"
}

# ── 清理临时文件 ──
Write-Step "6/7  清理临时文件"
Remove-Item -Recurse -Force $tmpDir
Write-Ok "已清理 $tmpDir"

# ── 自动 restart gateway(如果在跑) ──
Write-Step "7/7  让新配置生效"
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
    $openclawCmd = Get-Command openclaw -ErrorAction SilentlyContinue
    if ($openclawCmd) {
        # 后台发 restart 信号,不等结果(restart 本身要 stop service + start,可能花十几秒)
        Start-Job -ScriptBlock { & openclaw gateway restart 2>&1 } | Out-Null
        Write-Ok "已发送 gateway restart 信号(后台执行,十几秒后生效)"
    } else {
        Write-Warn "找不到 openclaw 命令,无法自动 restart"
        Write-Warn "请手动关掉 OpenClaw 重新启动"
    }
} else {
    Write-Info "OpenClaw gateway 未运行,新配置会在你下次启动 OpenClaw 时自动生效"
}

# ── 完成 ──
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  本地语音识别已装好" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
Write-Host "  二进制 + 模型: $INSTALL_DIR"
Write-Host "  配置文件:      $OPENCLAW_CFG"
Write-Host ""
Write-Host "  下一步:" -ForegroundColor Cyan
Write-Host "    1. 如果 OpenClaw 没在运行,启动它(脚本已自动 restart 过运行中的)"
Write-Host "    2. 用飞书发个语音消息,验证识别是否生效"
Write-Host ""
