<#
.SYNOPSIS
  打开用户级 skill 目录(~/.agents/skills/)。不存在则自动创建。
.NOTES
  在线使用:
    irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/open-skills-folder.ps1 | iex
    irm https://gitee.com/mijiamiyu/scripts/raw/main/open-skills-folder.ps1 | iex
#>

# ── Process Scope Bypass：让 iex 模式在 Restricted/AllSigned 系统也能跑 ──
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch {}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

function Write-Info { param($Msg) Write-Host "  [INFO] " -ForegroundColor Blue -NoNewline; Write-Host $Msg }
function Write-Ok { param($Msg) Write-Host "  [OK]   " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Err { param($Msg) Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline; Write-Host $Msg }

$skillsDir = Join-Path $HOME ".agents\skills"

if (-not (Test-Path -LiteralPath $skillsDir)) {
    Write-Info "skills 目录不存在,正在创建: $skillsDir"
    try {
        New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null
        Write-Ok "已创建: $skillsDir"
    } catch {
        Write-Err "创建失败: $_"
        exit 1
    }
} else {
    Write-Info "skills 目录: $skillsDir"
}

try {
    Start-Process explorer.exe -ArgumentList "`"$skillsDir`""
    Write-Ok "已打开 skills 文件夹"
} catch {
    Write-Err "打开文件夹失败: $_"
    exit 1
}
