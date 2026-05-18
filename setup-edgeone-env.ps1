# EdgeOne Pages 培训环境一键装(Windows)
# 装 Node.js LTS + 全局切 npm 国内镜像源 + 装 edgeone CLI

# ── Process Scope Bypass(防 ExecutionPolicy 拦截)──
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch {}

# ── 重启自修复(当通过 -File 模式跑时,如果策略限制就 Bypass 重启自己)──
if ($MyInvocation.MyCommand.Path) {
    try {
        $policy = Get-ExecutionPolicy -Scope Process
        if ($policy -eq "Restricted" -or $policy -eq "AllSigned") {
            Write-Host "  [INFO] 当前执行策略 $policy,以 Bypass 重启..." -ForegroundColor Blue
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
function Write-Info  { param($Msg) Write-Host "  [INFO] " -ForegroundColor Blue   -NoNewline; Write-Host $Msg }
function Write-Ok    { param($Msg) Write-Host "  [OK]   " -ForegroundColor Green  -NoNewline; Write-Host $Msg }
function Write-Warn  { param($Msg) Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err   { param($Msg) Write-Host "  [FAIL] " -ForegroundColor Red    -NoNewline; Write-Host $Msg }
function Write-Step  { param($Msg) Write-Host "`n━━━ $Msg ━━━`n" -ForegroundColor Cyan }

# ── 全局配置 ──
$NODE_MIRROR    = "https://npmmirror.com/mirrors/node"
$NPM_REGISTRY   = "https://registry.npmmirror.com"
$NODE_MAJOR_LTS = 22
$REQUIRED_NODE  = 18  # edgeone CLI 要求 Node 18+

# ── 工具函数 ──

function Get-LocalAppData {
    if ($env:LOCALAPPDATA) { return $env:LOCALAPPDATA }
    return (Join-Path $HOME "AppData\Local")
}

function Refresh-PathEnv {
    $machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = "$machinePath;$userPath"
}

function Add-ToUserPath {
    param([string]$Dir)
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($currentPath -notlike "*$Dir*") {
        [Environment]::SetEnvironmentVariable("PATH", "$Dir;$currentPath", "User")
        $env:PATH = "$Dir;$env:PATH"
        Write-Info "已将 $Dir 永久加入用户 PATH"
    }
}

function Get-NodeMajor {
    try {
        $output = & node -v 2>$null
        if ($output -match "v(\d+)") { return [int]$Matches[1] }
    } catch {}
    return 0
}

function Get-Arch {
    if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { return "arm64" }
        return "x64"
    }
    return "x86"
}

function Get-LatestNodeVersion {
    param([int]$Major)
    $urls = @(
        "$NODE_MIRROR/latest-v${Major}.x/SHASUMS256.txt",
        "https://nodejs.org/dist/latest-v${Major}.x/SHASUMS256.txt"
    )
    foreach ($url in $urls) {
        try {
            $content = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15).Content
            if ($content -match "node-(v\d+\.\d+\.\d+)") { return $Matches[1] }
        } catch {}
    }
    return $null
}

function Download-File {
    param([string]$Dest, [string[]]$Urls)
    foreach ($url in $Urls) {
        $hostName = ([Uri]$url).Host
        Write-Info "从 $hostName 下载..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $Dest -UseBasicParsing -TimeoutSec 300
            Write-Ok "下载完成"
            return $true
        } catch {
            Write-Warn "从 $hostName 下载失败,尝试备用源..."
        }
    }
    return $false
}

function Install-NodeDirect {
    Write-Info "直接下载安装 Node.js v$NODE_MAJOR_LTS LTS..."

    $arch = Get-Arch
    $version = Get-LatestNodeVersion -Major $NODE_MAJOR_LTS
    if (-not $version) {
        Write-Err "无法获取 Node.js 版本信息,检查网络"
        return $false
    }
    Write-Info "最新 LTS 版本: $version"

    $filename = "node-$version-win-$arch.zip"
    $tmpPath  = Join-Path $env:TEMP "edgeone-setup"
    $tmpFile  = Join-Path $tmpPath $filename
    $extractedName = "node-$version-win-$arch"
    $installDir = Join-Path (Get-LocalAppData) "nodejs"

    New-Item -ItemType Directory -Force -Path $tmpPath | Out-Null

    $downloaded = Download-File -Dest $tmpFile -Urls @(
        "$NODE_MIRROR/$version/$filename",
        "https://nodejs.org/dist/$version/$filename"
    )

    if (-not $downloaded) {
        Write-Err "Node.js 下载失败"
        return $false
    }

    try {
        Write-Info "解压安装..."
        Expand-Archive -Path $tmpFile -DestinationPath $tmpPath -Force
        if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
        Move-Item (Join-Path $tmpPath $extractedName) $installDir

        $env:PATH = "$installDir;$env:PATH"
        Add-ToUserPath $installDir
    } catch {
        Write-Err "安装失败: $_"
        Remove-Item $tmpPath -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    Remove-Item $tmpPath -Recurse -Force -ErrorAction SilentlyContinue

    Refresh-PathEnv
    $major = Get-NodeMajor
    if ($major -ge $REQUIRED_NODE) {
        Write-Ok "Node.js $((& node -v)) 装好"
        return $true
    }
    Write-Warn "Node.js 装完但验证失败,可能要重开终端"
    return $false
}

# ── 主流程 ──

Write-Host "`n  🌐 EdgeOne Pages 培训环境一键装" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────`n" -ForegroundColor Cyan

# Step 1/4:Node.js
Write-Step "1/4  Node.js"

$major = Get-NodeMajor
if ($major -ge $REQUIRED_NODE) {
    Write-Ok "Node.js 已装且版本符合: $((& node -v))"
} else {
    if ($major -gt 0) {
        Write-Warn "已有 Node.js $((& node -v)) 但版本 < $REQUIRED_NODE,准备装新版"
    } else {
        Write-Info "未检测到 Node.js,开始安装"
    }
    if (-not (Install-NodeDirect)) {
        Write-Err "Node.js 安装失败,后续步骤无法继续"
        Write-Host "`n  按任意键退出..." -ForegroundColor Yellow
        try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch {}
        return
    }
}

# Step 2/4:npm 全局切镜像源(永久)
Write-Step "2/4  全局切 npm 国内镜像源"

try {
    & npm config set registry $NPM_REGISTRY
    $current = (& npm config get registry).Trim()
    if ($current -eq $NPM_REGISTRY) {
        Write-Ok "npm registry 已永久切到 $NPM_REGISTRY"
        Write-Info "(配置写入 ~/.npmrc,所有后续 npm 命令默认走国内镜像)"
    } else {
        Write-Warn "npm registry 切换可能未生效,当前: $current"
    }
} catch {
    Write-Err "npm config 操作失败: $_"
}

# Step 3/4:装 edgeone CLI
Write-Step "3/4  装 edgeone CLI"

try {
    & npm install -g edgeone@latest
    if ($LASTEXITCODE -ne 0) {
        Write-Err "edgeone CLI 安装失败 (exit $LASTEXITCODE)"
        Write-Host "`n  按任意键退出..." -ForegroundColor Yellow
        try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch {}
        return
    }
    Write-Ok "edgeone CLI 已装"
} catch {
    Write-Err "npm install 失败: $_"
    return
}

# Step 4/4:验证 edgeone CLI 版本
Write-Step "4/4  验证 edgeone CLI 版本"

Refresh-PathEnv
try {
    $eoVer = (& edgeone -v 2>$null).Trim()
    if ($eoVer -match "(\d+)\.(\d+)\.(\d+)") {
        $vmajor = [int]$Matches[1]
        $vminor = [int]$Matches[2]
        $vpatch = [int]$Matches[3]
        if ($vmajor -gt 1 -or ($vmajor -eq 1 -and $vminor -gt 2) -or ($vmajor -eq 1 -and $vminor -eq 2 -and $vpatch -ge 30)) {
            Write-Ok "edgeone CLI: $eoVer (>= 1.2.30 符合官方 skill 要求)"
        } else {
            Write-Warn "edgeone CLI: $eoVer (低于 1.2.30,可能要重装)"
        }
    } else {
        Write-Warn "edgeone CLI 已装但版本号格式异常: $eoVer"
    }
} catch {
    Write-Warn "edgeone 命令未找到,可能要重开终端再试"
}

# 完成
Write-Host ""
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host "  EdgeOne Pages 培训环境装好" -ForegroundColor Green
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
