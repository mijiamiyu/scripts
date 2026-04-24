<#
.SYNOPSIS
  Set the default OpenClaw model on Windows.

.DESCRIPTION
  This script only changes OpenClaw model settings. It does not install Node,
  pnpm, Git, OpenClaw, or rewrite API keys.

.EXAMPLES
  powershell -ExecutionPolicy Bypass -File .\openclaw-set-model.ps1
  powershell -ExecutionPolicy Bypass -File .\openclaw-set-model.ps1 -Model openai/gpt-5.1-codex
  powershell -ExecutionPolicy Bypass -File .\openclaw-set-model.ps1 -Model xiaomi/mimo-v2-flash -NoRestartGateway
  $env:OPENCLAW_MODEL='xiaomi/mimo-v2-flash'; irm https://your-domain/openclaw-set-model.ps1 | iex
#>

param(
    [string]$Model = $env:OPENCLAW_MODEL,
    [string]$ImageModel = $env:OPENCLAW_IMAGE_MODEL,
    [switch]$List,
    [switch]$All,
    [switch]$Status,
    [switch]$RestartGateway,
    [switch]$NoRestartGateway
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info { param([string]$Message) Write-Host "  [INFO] " -ForegroundColor Blue -NoNewline; Write-Host $Message }
function Write-Ok   { param([string]$Message) Write-Host "  [OK]   " -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn { param([string]$Message) Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Err  { param([string]$Message) Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline; Write-Host $Message }

function Get-OpenClawCommand {
    try {
        $cmd = Get-Command openclaw -ErrorAction Stop
        return $cmd.Source
    } catch {
        try {
            $cmd = Get-Command openclaw.cmd -ErrorAction Stop
            return $cmd.Source
        } catch {
            return $null
        }
    }
}

function Invoke-OpenClaw {
    param(
        [string[]]$OpenClawArgs,
        [switch]$AllowFailure
    )

    & $script:OpenClawCmd @OpenClawArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "openclaw $($OpenClawArgs -join ' ') failed with exit code $exitCode"
    }
    return $exitCode
}

function Test-GatewayRunning {
    try {
        $output = & $script:OpenClawCmd gateway probe --json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) { return $false }
        $json = ($output -join "`n") | ConvertFrom-Json
        return [bool]$json.ok
    } catch {
        return $false
    }
}

function Select-Model {
    $choices = @(
        @{ Id = "openai-codex/gpt-5.4-mini"; Label = "OpenAI Codex GPT-5.4 Mini" },
        @{ Id = "openai/gpt-5.1-codex"; Label = "OpenAI GPT-5.1 Codex" },
        @{ Id = "openai/o3"; Label = "OpenAI o3" },
        @{ Id = "openai/o4-mini"; Label = "OpenAI o4-mini" },
        @{ Id = "anthropic/claude-sonnet-4-5"; Label = "Claude Sonnet 4.5" },
        @{ Id = "anthropic/claude-opus-4-6"; Label = "Claude Opus 4.6" },
        @{ Id = "gemini/gemini-2.5-pro"; Label = "Gemini 2.5 Pro" },
        @{ Id = "gemini/gemini-2.5-flash"; Label = "Gemini 2.5 Flash" },
        @{ Id = "xiaomi/mimo-v2-flash"; Label = "Xiaomi MiMo V2 Flash" }
    )

    Write-Host ""
    Write-Host "  Select default OpenClaw model:" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $choices.Count; $i++) {
        Write-Host ("   {0}) {1} ({2})" -f ($i + 1), $choices[$i].Label, $choices[$i].Id)
    }
    Write-Host "   0) Custom model id"
    Write-Host ""

    $choice = (Read-Host "  Choose [0-$($choices.Count)]").Trim()
    if ($choice -eq "0") {
        return (Read-Host "  Enter model id").Trim()
    }

    $index = 0
    if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $choices.Count) {
        return $choices[$index - 1].Id
    }

    Write-Warn "Invalid choice."
    return ""
}

Write-Host ""
Write-Host "  OpenClaw model switcher" -ForegroundColor Green
Write-Host "  -----------------------" -ForegroundColor DarkGray

$script:OpenClawCmd = Get-OpenClawCommand
if (-not $script:OpenClawCmd) {
    Write-Err "Cannot find openclaw in PATH."
    Write-Host "  Install OpenClaw first or open a new terminal after installation." -ForegroundColor Yellow
    exit 1
}
Write-Info "Using: $script:OpenClawCmd"

try {
    $version = (& $script:OpenClawCmd -v 2>$null).Trim()
    if ($version) { Write-Ok "OpenClaw $version detected" }
} catch {}

$gatewayWasRunning = $false
if (-not $Status -and -not $List) {
    Write-Info "Checking gateway state..."
    $gatewayWasRunning = Test-GatewayRunning
    if ($gatewayWasRunning) {
        Write-Ok "Gateway is running; it will be restarted after model update"
    } else {
        Write-Warn "Gateway is not running; model will be updated without starting it"
    }
}

if ($List) {
    $args = @("models", "list", "--plain")
    if ($All) { $args = @("models", "list", "--all", "--plain") }
    Invoke-OpenClaw -OpenClawArgs $args
    exit $LASTEXITCODE
}

if ($Status) {
    Invoke-OpenClaw -OpenClawArgs @("models", "status", "--plain")
    exit $LASTEXITCODE
}

if (-not $Model) {
    $Model = Select-Model
}

if (-not $Model) {
    Write-Err "No model selected."
    exit 1
}

Write-Info "Setting default model: $Model"
Invoke-OpenClaw -OpenClawArgs @("models", "set", $Model)
Write-Ok "Default model updated"

if ($ImageModel) {
    Write-Info "Setting image model: $ImageModel"
    Invoke-OpenClaw -OpenClawArgs @("models", "set-image", $ImageModel)
    Write-Ok "Image model updated"
}

Write-Host ""
Write-Info "Current model status:"
Invoke-OpenClaw -OpenClawArgs @("models", "status", "--plain") -AllowFailure | Out-Null

if ((($gatewayWasRunning -and -not $NoRestartGateway) -or $RestartGateway)) {
    Write-Host ""
    Write-Info "Restarting OpenClaw gateway..."
    Invoke-OpenClaw -OpenClawArgs @("gateway", "restart")
    Invoke-OpenClaw -OpenClawArgs @("gateway", "probe") -AllowFailure | Out-Null
}

Write-Host ""
Write-Ok "Done"
