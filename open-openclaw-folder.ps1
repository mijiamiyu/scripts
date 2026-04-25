<#
.SYNOPSIS
  打开 OpenClaw 配置文件夹。
.NOTES
  在线使用:
    irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/open-openclaw-folder.ps1 | iex
    irm https://gitee.com/mijiamiyu/scripts/raw/main/open-openclaw-folder.ps1 | iex
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

function Write-Info { param($Msg) Write-Host "  [INFO] " -ForegroundColor Blue -NoNewline; Write-Host $Msg }
function Write-Ok { param($Msg) Write-Host "  [OK]   " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Err { param($Msg) Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline; Write-Host $Msg }

$openClawDir = Join-Path $HOME ".openclaw"

if (-not (Test-Path $openClawDir)) {
    Write-Err "没有找到 OpenClaw 文件夹: $openClawDir"
    Write-Info "可能还没有安装 OpenClaw，或当前用户不是安装 OpenClaw 的用户"
    exit 1
}

Write-Info "OpenClaw 文件夹: $openClawDir"

try {
    Start-Process explorer.exe -ArgumentList "`"$openClawDir`""
    Write-Ok "已打开 OpenClaw 文件夹"
} catch {
    Write-Err "打开文件夹失败: $_"
    exit 1
}
