# OpenClaw 一键卸载脚本 (Windows)
# 用法:
#   powershell -ExecutionPolicy Bypass -File uninstall-openclaw.ps1
#   powershell -ExecutionPolicy Bypass -File uninstall-openclaw.ps1 -Force
#   powershell -ExecutionPolicy Bypass -File uninstall-openclaw.ps1 -KeepUserData
#
# 参数:
#   -Force          跳过确认提示（自动化场景）
#   -KeepUserData   保留 ~/.openclaw 用户数据目录（升级换版本时用）
#
# 在线一键卸载:
#   irm https://gitee.com/<your-repo>/uninstall-openclaw.ps1 | iex
param(
    [switch]$Force,
    [switch]$KeepUserData
)

# ── 编码与执行策略 ──
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"  # 卸载脚本要尽量跑完，不因单步失败中断

# ── 颜色输出 ──
function Write-Info { param($Msg) Write-Host "  [INFO] " -ForegroundColor Blue   -NoNewline; Write-Host $Msg }
function Write-Ok   { param($Msg) Write-Host "  [OK]   " -ForegroundColor Green  -NoNewline; Write-Host $Msg }
function Write-Warn { param($Msg) Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err  { param($Msg) Write-Host "  [FAIL] " -ForegroundColor Red    -NoNewline; Write-Host $Msg }
function Write-Step { param($Msg) Write-Host "`n━━━ $Msg ━━━`n" -ForegroundColor Cyan }

# ── 工具函数 ──
function Test-OpenclawInstalled {
    # 检查 pnpm 全局
    try {
        $pnpmList = & pnpm list -g 2>$null | Out-String
        if ($pnpmList -match "openclaw") { return $true }
    } catch {}
    # 检查 npm 全局
    try {
        $npmList = & npm list -g 2>$null | Out-String
        if ($npmList -match "openclaw") { return $true }
    } catch {}
    # 检查可执行文件
    try {
        $w = & where.exe openclaw 2>$null
        if ($w) { return $true }
    } catch {}
    # 检查用户数据目录
    if (Test-Path "$HOME\.openclaw") { return $true }
    # 检查 Scheduled Task
    if (Get-ScheduledTask -TaskName "OpenClaw*" -ErrorAction SilentlyContinue) { return $true }
    return $false
}

function Stop-OpenclawProcesses {
    Write-Info "查找并杀掉所有 OpenClaw 相关 node 进程..."
    $killed = 0
    try {
        $procs = Get-Process -Name node -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            try {
                $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine
                if ($cmdline -and $cmdline -like "*openclaw*") {
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                    Write-Ok "已杀掉 PID $($p.Id)"
                    $killed++
                }
            } catch {}
        }
    } catch {}
    if ($killed -eq 0) { Write-Info "没有运行中的 OpenClaw 进程" }
}

function Remove-ScheduledTasks {
    Write-Info "查找并注销 OpenClaw 相关 Scheduled Task..."
    $found = 0
    try {
        $tasks = Get-ScheduledTask -TaskName "OpenClaw*" -ErrorAction SilentlyContinue
        foreach ($t in $tasks) {
            try {
                Stop-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction Stop
                Write-Ok "已注销 Scheduled Task: $($t.TaskName)"
                $found++
            } catch {
                Write-Warn "注销 $($t.TaskName) 失败: $_"
            }
        }
    } catch {}
    if ($found -eq 0) { Write-Info "没有 OpenClaw Scheduled Task" }
}

function Remove-GlobalPackage {
    Write-Info "正在通过包管理器卸载 openclaw..."
    $removed = $false

    # 优先 pnpm
    try {
        $pnpmList = & pnpm list -g 2>$null | Out-String
        if ($pnpmList -match "openclaw") {
            & pnpm uninstall -g openclaw 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "pnpm 已卸载 openclaw"
                $removed = $true
            } else {
                Write-Warn "pnpm uninstall 退出码非 0: $LASTEXITCODE"
            }
        }
    } catch {}

    # 备选 npm
    try {
        $npmList = & npm list -g 2>$null | Out-String
        if ($npmList -match "openclaw") {
            & npm uninstall -g openclaw 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "npm 已卸载 openclaw"
                $removed = $true
            }
        }
    } catch {}

    if (-not $removed) { Write-Info "未在 pnpm / npm 全局列表中发现 openclaw（可能已被卸载）" }
}

function Remove-UserData {
    if ($KeepUserData) {
        Write-Info "传入 -KeepUserData，保留 $HOME\.openclaw 不删除"
        return
    }
    $userDir = "$HOME\.openclaw"
    if (Test-Path $userDir) {
        try {
            $size = (Get-ChildItem $userDir -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $sizeMB = [math]::Round($size / 1MB, 1)
        } catch { $sizeMB = "?" }
        Write-Info "正在删除用户数据目录 $userDir（约 $sizeMB MB）..."
        try {
            Remove-Item $userDir -Recurse -Force -ErrorAction Stop
            Write-Ok "用户数据目录已删除"
        } catch {
            Write-Err "删除失败: $_"
            Write-Warn "可能某个进程占用文件，请关掉所有相关程序后重试"
        }
    } else {
        Write-Info "$userDir 不存在，跳过"
    }
}

function Clear-EnvVars {
    Write-Info "清理 OpenClaw 相关用户环境变量..."
    $vars = @("CLAWHUB_REGISTRY", "OPENCLAW_VERSION", "OPENCLAW_GATEWAY_TOKEN")
    foreach ($v in $vars) {
        $val = [Environment]::GetEnvironmentVariable($v, "User")
        if ($val) {
            try {
                [Environment]::SetEnvironmentVariable($v, $null, "User")
                Write-Ok "已清除 $v"
            } catch {
                Write-Warn "清除 $v 失败: $_"
            }
        }
    }
}

function Verify-Cleanup {
    Write-Step "验证清理结果"
    $issues = 0

    # 1. pnpm 全局
    try {
        $pnpmList = & pnpm list -g 2>$null | Out-String
        if ($pnpmList -match "openclaw") {
            Write-Err "pnpm 全局列表里还有 openclaw"
            $issues++
        } else { Write-Ok "pnpm 全局已无 openclaw" }
    } catch { Write-Ok "pnpm 不可用，跳过该项检查" }

    # 2. npm 全局
    try {
        $npmList = & npm list -g 2>$null | Out-String
        if ($npmList -match "openclaw") {
            Write-Err "npm 全局列表里还有 openclaw"
            $issues++
        } else { Write-Ok "npm 全局已无 openclaw" }
    } catch {}

    # 3. 命令可执行性
    try {
        $w = & where.exe openclaw 2>$null
        if ($w) {
            Write-Warn "still found: $w"
            $issues++
        } else { Write-Ok "openclaw 命令已不在 PATH 中" }
    } catch { Write-Ok "openclaw 命令已不在 PATH 中" }

    # 4. 用户数据目录
    if (-not $KeepUserData) {
        if (Test-Path "$HOME\.openclaw") {
            Write-Err "$HOME\.openclaw 仍存在"
            $issues++
        } else { Write-Ok "$HOME\.openclaw 已删除" }
    }

    # 5. Scheduled Task
    $tasks = Get-ScheduledTask -TaskName "OpenClaw*" -ErrorAction SilentlyContinue
    if ($tasks) {
        Write-Err "仍有 OpenClaw Scheduled Task: $($tasks.TaskName -join ', ')"
        $issues++
    } else { Write-Ok "无 OpenClaw Scheduled Task" }

    # 6. 环境变量
    $envIssues = 0
    foreach ($v in @("CLAWHUB_REGISTRY", "OPENCLAW_VERSION", "OPENCLAW_GATEWAY_TOKEN")) {
        if ([Environment]::GetEnvironmentVariable($v, "User")) { $envIssues++ }
    }
    if ($envIssues -gt 0) {
        Write-Warn "$envIssues 个 OpenClaw 用户环境变量仍存在"
        $issues++
    } else { Write-Ok "OpenClaw 用户环境变量已清理" }

    return $issues
}

# ── 主流程 ──
function Main {
    Write-Host ""
    Write-Host "  🦞 OpenClaw 一键卸载脚本" -ForegroundColor Green
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
    Write-Host ""

    # Step 0: 检测是否安装
    if (-not (Test-OpenclawInstalled)) {
        Write-Ok "未检测到 OpenClaw 安装痕迹，无需卸载"
        return
    }

    # Step 1: 远程一键场景（irm | iex）自动启用 -Force
    if (-not $Force) {
        try {
            if ([Console]::IsInputRedirected) {
                Write-Info "检测到 stdin 被重定向（远程一键 irm | iex 场景），自动启用 -Force 模式"
                $Force = $true
            }
        } catch {}
    }

    # Step 2: 确认
    if (-not $Force) {
        Write-Host "  即将执行的操作：" -ForegroundColor Yellow
        Write-Host "    1. 杀掉所有 OpenClaw node 进程" -ForegroundColor White
        Write-Host "    2. 注销 OpenClaw Gateway 计划任务" -ForegroundColor White
        Write-Host "    3. 卸载 pnpm / npm 全局 openclaw 包" -ForegroundColor White
        if ($KeepUserData) {
            Write-Host "    4. 跳过：保留 $HOME\.openclaw 用户数据 (传入了 -KeepUserData)" -ForegroundColor DarkGray
        } else {
            Write-Host "    4. 删除 $HOME\.openclaw 全部用户数据 (含会话历史 / 缓存)" -ForegroundColor White
        }
        Write-Host "    5. 清理 CLAWHUB_REGISTRY 等用户环境变量" -ForegroundColor White
        Write-Host ""
        $confirm = (Read-Host "  确认继续？[y/N]").Trim()
        if ($confirm -notmatch "^[Yy]") {
            Write-Info "已取消"
            return
        }
    }

    # Step 2: 杀进程
    Write-Step "步骤 1/5: 终止运行中的进程"
    Stop-OpenclawProcesses

    # Step 3: 注销 Scheduled Task
    Write-Step "步骤 2/5: 注销 Scheduled Task"
    Remove-ScheduledTasks

    # Step 4: 卸载全局包
    Write-Step "步骤 3/5: 卸载全局 npm 包"
    Remove-GlobalPackage

    # Step 5: 删用户数据
    Write-Step "步骤 4/5: 处理用户数据目录"
    Remove-UserData

    # Step 6: 清环境变量
    Write-Step "步骤 5/5: 清理环境变量"
    Clear-EnvVars

    # Step 7: 验证
    $issues = Verify-Cleanup

    Write-Host ""
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    if ($issues -eq 0) {
        Write-Host "  🦞 卸载完成！系统已干净" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ 卸载基本完成，但有 $issues 项未完全清理（详见上方）" -ForegroundColor Yellow
    }
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host ""

    if (-not $KeepUserData) {
        Write-Host "  提示：新打开终端窗口后 PATH 缓存才会刷新" -ForegroundColor DarkGray
        Write-Host ""
    }
}

Main
