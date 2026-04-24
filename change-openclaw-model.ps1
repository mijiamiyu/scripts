# OpenClaw 中文模型配置与切换脚本 (Windows)
# 在线使用:
#   irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/change-openclaw-model.ps1 | iex
#
# 直接设置:
#   $env:OPENCLAW_PROVIDER='qwen'
#   $env:OPENCLAW_API_KEY='sk-xxx'
#   $env:OPENCLAW_MODEL='qwen3.6-flash'
#   irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/change-openclaw-model.ps1 | iex

param(
    [string]$Provider = $env:OPENCLAW_PROVIDER,
    [string]$ApiKey = $env:OPENCLAW_API_KEY,
    [string]$Model = $env:OPENCLAW_MODEL,
    [string]$BaseUrl = $env:OPENCLAW_BASE_URL,
    [switch]$Status,
    [switch]$List,
    [switch]$All,
    [switch]$RestartGateway,
    [switch]$NoRestartGateway
)

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

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Info { param($Msg) Write-Host "  [INFO] " -ForegroundColor Blue -NoNewline; Write-Host $Msg }
function Write-Ok   { param($Msg) Write-Host "  [OK]   " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Warn { param($Msg) Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err  { param($Msg) Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline; Write-Host $Msg }
function Write-Step { param($Msg) Write-Host "`n━━━ $Msg ━━━`n" -ForegroundColor Cyan }

function Get-OpenClawCommand {
    foreach ($name in @("openclaw", "openclaw.cmd", "openclaw.ps1")) {
        try {
            $cmd = Get-Command $name -ErrorAction Stop
            if ($cmd.Source) { return $cmd.Source }
        } catch {}
    }
    return $null
}

function Invoke-OpenClaw {
    param([string[]]$OpenClawArgs, [switch]$AllowFailure)
    & $script:OpenClawCmd @OpenClawArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "openclaw $($OpenClawArgs -join ' ') 执行失败，退出码: $exitCode"
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

function Read-Required {
    param([string]$Prompt, [string]$Value = "")
    if ($Value) { return $Value.Trim() }
    while ($true) {
        $v = (Read-Host $Prompt).Trim()
        if ($v) { return $v }
        Write-Warn "不能为空，请重新输入"
    }
}

function New-Model {
    param([string]$Id, [string]$Label, [string]$Modality, [string]$Note = "")
    return @{ Id=$Id; Label=$Label; Input=$Modality; Note=$Note }
}

$script:Providers = @(
    @{ Key="1";  Name="deepseek";  Label="DeepSeek";        Mode="custom"; BaseUrl="https://api.deepseek.com"; Compatibility="openai" },
    @{ Key="2";  Name="minimax";   Label="MiniMax";         Mode="custom"; BaseUrl="https://api.minimax.io/v1"; Compatibility="openai" },
    @{ Key="3";  Name="qwen";      Label="阿里百炼 / Qwen";  Mode="custom"; BaseUrl="https://dashscope.aliyuncs.com/compatible-mode/v1"; Compatibility="openai" },
    @{ Key="4";  Name="volcengine";Label="火山方舟 / Doubao";Mode="custom"; BaseUrl="https://ark.cn-beijing.volces.com/api/coding/v3"; Compatibility="openai" },
    @{ Key="5";  Name="zai";       Label="智谱 / BigModel";  Mode="custom"; BaseUrl="https://open.bigmodel.cn/api/paas/v4"; Compatibility="openai" },
    @{ Key="6";  Name="moonshot";  Label="Moonshot / Kimi"; Mode="custom"; BaseUrl="https://api.moonshot.ai/v1"; Compatibility="openai" },
    @{ Key="7";  Name="qianfan";   Label="百度千帆";         Mode="custom"; BaseUrl="https://qianfan.baidubce.com/v2"; Compatibility="openai" },
    @{ Key="8";  Name="xiaomi";    Label="小米 MiMo";        Mode="builtin"; AuthChoice="xiaomi-api-key"; KeyFlag="--xiaomi-api-key" },
    @{ Key="9";  Name="openai";    Label="OpenAI";          Mode="builtin"; AuthChoice="openai-api-key"; KeyFlag="--openai-api-key" },
    @{ Key="10"; Name="anthropic"; Label="Anthropic";       Mode="builtin"; AuthChoice="apiKey"; KeyFlag="--anthropic-api-key" },
    @{ Key="11"; Name="custom";    Label="自定义兼容接口";   Mode="custom"; BaseUrl=""; Compatibility="openai" }
)

$script:ModelMap = @{
    "deepseek" = @(
        (New-Model "deepseek-v4-pro" "DeepSeek V4 Pro" "文本" "强推理/复杂任务"),
        (New-Model "deepseek-v4-flash" "DeepSeek V4 Flash" "文本" "高速/低成本"),
        (New-Model "deepseek-chat" "DeepSeek Chat" "文本" "旧别名，2026-07-24 弃用"),
        (New-Model "deepseek-reasoner" "DeepSeek Reasoner" "文本" "旧别名，2026-07-24 弃用")
    )
    "minimax" = @(
        (New-Model "MiniMax-M2.7" "MiniMax M2.7" "文本" "默认推荐"),
        (New-Model "MiniMax-M2.7-highspeed" "MiniMax M2.7 Highspeed" "文本" "高速版"),
        (New-Model "MiniMax-M2.5" "MiniMax M2.5" "文本" "旧一代高性价比"),
        (New-Model "MiniMax-M2.5-highspeed" "MiniMax M2.5 Highspeed" "文本" "旧一代高速版")
    )
    "qwen" = @(
        (New-Model "qwen3.6-max-preview" "Qwen3.6 Max Preview" "文本" "最高推理能力，成本较高"),
        (New-Model "qwen3.6-plus" "Qwen3.6 Plus" "文本/图片" "1M 上下文，主推"),
        (New-Model "qwen3.6-flash" "Qwen3.6 Flash" "文本/图片" "1M 上下文，低成本"),
        (New-Model "qwen3.6-plus-2026-04-02" "Qwen3.6 Plus 快照" "文本/图片" "固定快照"),
        (New-Model "qwen3.6-flash-2026-04-16" "Qwen3.6 Flash 快照" "文本/图片" "固定快照"),
        (New-Model "qwen3.6-35b-a3b" "Qwen3.6 35B A3B" "文本/图片" "开源/轻量 MoE"),
        (New-Model "qwen3-coder-plus" "Qwen3 Coder Plus" "文本" "代码模型"),
        (New-Model "qwen3-coder-flash" "Qwen3 Coder Flash" "文本" "低成本代码模型")
    )
    "volcengine" = @(
        (New-Model "doubao-seed-2.0-code" "Doubao Seed 2.0 Code" "文本/图片" "编程/前端/Agent"),
        (New-Model "doubao-seed-2.0-pro" "Doubao Seed 2.0 Pro" "文本/图片" "强推理/复杂任务"),
        (New-Model "doubao-seed-2.0-lite" "Doubao Seed 2.0 Lite" "文本/图片" "通用性价比"),
        (New-Model "doubao-seed-2.0-mini" "Doubao Seed 2.0 Mini" "文本/图片" "低延迟/高并发/低成本"),
        (New-Model "doubao-seed-2-0-code-preview-260215" "Doubao Seed 2.0 Code 快照" "文本/图片" "版本化 ID"),
        (New-Model "doubao-seed-2-0-pro-260215" "Doubao Seed 2.0 Pro 快照" "文本/图片" "版本化 ID"),
        (New-Model "doubao-seed-2-0-lite-260215" "Doubao Seed 2.0 Lite 快照" "文本/图片" "版本化 ID"),
        (New-Model "doubao-seed-2-0-mini-260215" "Doubao Seed 2.0 Mini 快照" "文本/图片" "版本化 ID"),
        (New-Model "ark-code-latest" "Ark Code Latest" "文本" "由方舟控制台选择模型")
    )
    "zai" = @(
        (New-Model "glm-5.1" "GLM-5.1" "文本" "当前快速开始默认模型"),
        (New-Model "glm-5" "GLM-5" "文本" "Agentic Engineering"),
        (New-Model "glm-4.7" "GLM-4.7" "文本" "Agentic Coding"),
        (New-Model "glm-4.7-flashx" "GLM-4.7 FlashX" "文本" "轻量高速版"),
        (New-Model "glm-5v-turbo" "GLM-5V Turbo" "文本/图片" "多模态 Coding 基座"),
        (New-Model "glm-4.6v" "GLM-4.6V" "文本/图片" "视觉理解")
    )
    "moonshot" = @(
        (New-Model "kimi-k2.6" "Kimi K2.6" "文本/图片" "Kimi 新一代"),
        (New-Model "kimi-k2.5" "Kimi K2.5" "文本/图片" "视觉/代码/Agent"),
        (New-Model "kimi-k2" "Kimi K2" "文本" "旧一代"),
        (New-Model "moonshot-v1-8k-vision-preview" "Moonshot Vision Preview" "文本/图片" "视觉预览")
    )
    "qianfan" = @(
        (New-Model "ernie-4.5-turbo-32k" "ERNIE 4.5 Turbo 32K" "文本" "通用文本"),
        (New-Model "ernie-4.0-turbo-8k" "ERNIE 4.0 Turbo 8K" "文本" "稳定旧版"),
        (New-Model "deepseek-v3.2" "DeepSeek V3.2 on Qianfan" "文本" "千帆代理模型"),
        (New-Model "deepseek-r1-distill-qwen-32b" "DeepSeek R1 Distill Qwen 32B" "文本" "蒸馏推理")
    )
    "xiaomi" = @(
        (New-Model "xiaomi/mimo-v2-flash" "MiMo V2 Flash" "文本/图片" "OpenClaw 内置 provider")
    )
    "openai" = @(
        (New-Model "openai/gpt-5.4" "GPT-5.4" "文本/图片" "主力模型"),
        (New-Model "openai/gpt-5.4-mini" "GPT-5.4 Mini" "文本/图片" "轻量模型"),
        (New-Model "openai/gpt-5.3-codex" "GPT-5.3 Codex" "文本" "代码模型"),
        (New-Model "openai/o3" "o3" "文本/图片" "旧推理模型")
    )
    "anthropic" = @(
        (New-Model "anthropic/claude-opus-4-6" "Claude Opus 4.6" "文本/图片" "最强推理"),
        (New-Model "anthropic/claude-sonnet-4-6" "Claude Sonnet 4.6" "文本/图片" "均衡"),
        (New-Model "anthropic/claude-opus-4-5" "Claude Opus 4.5" "文本/图片" "旧版"),
        (New-Model "anthropic/claude-sonnet-4-5" "Claude Sonnet 4.5" "文本/图片" "旧版")
    )
}

function Select-Provider {
    if ($Provider) {
        $matched = $script:Providers | Where-Object { $_.Name -eq $Provider -or $_.Key -eq $Provider } | Select-Object -First 1
        if ($matched) { return $matched }
        Write-Warn "未识别的厂商: $Provider，将进入交互选择"
    }

    Write-Host "  请选择 AI 厂商:" -ForegroundColor Cyan
    Write-Host ""
    foreach ($p in $script:Providers) {
        Write-Host ("  {0,2}) {1,-10} - {2}" -f $p.Key, $p.Name, $p.Label)
    }
    Write-Host "   0) 仅切换模型 / 跳过厂商配置"
    Write-Host ""

    $choice = (Read-Host "  请输入编号 [0-11]").Trim()
    if ($choice -eq "0") { return $null }
    return ($script:Providers | Where-Object { $_.Key -eq $choice -or $_.Name -eq $choice } | Select-Object -First 1)
}

function Select-Model {
    param([hashtable]$ProviderInfo)

    if ($Model) { return $Model.Trim() }
    if (-not $ProviderInfo) {
        return (Read-Required -Prompt "  请输入 Model ID")
    }

    $models = $script:ModelMap[$ProviderInfo.Name]
    if (-not $models -or $models.Count -eq 0) {
        return (Read-Required -Prompt "  请输入 Model ID")
    }

    Write-Host ""
    Write-Host "  请选择默认模型:" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $models.Count; $i++) {
        $m = $models[$i]
        $note = if ($m["Note"]) { "，$($m["Note"])" } else { "" }
        $inputLabel = if ($m["Input"]) { "[$($m["Input"])]" } else { "" }
        Write-Host ("  {0,2}) {1}  {2}  {3}{4}" -f ($i + 1), $m["Label"], $inputLabel, $m["Id"], $note)
    }
    Write-Host "   0) 手动输入 Model ID"
    Write-Host ""

    $choice = (Read-Host "  请选择 [0-$($models.Count)]").Trim()
    if ($choice -eq "0") {
        return (Read-Required -Prompt "  请输入自定义 Model ID")
    }

    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $models.Count) {
        return $models[$idx - 1].Id
    }

    Write-Warn "无效选择，跳过模型设置"
    return ""
}

function Configure-Provider {
    param([hashtable]$ProviderInfo, [string]$SelectedModel)
    if (-not $ProviderInfo) { return }

    Write-Step "配置 $($ProviderInfo.Label)"
    $key = Read-Required -Prompt "  请输入 API Key" -Value $ApiKey

    if ($ProviderInfo.Mode -eq "builtin") {
        $onboardArgs = @(
            "onboard", "--non-interactive",
            "--accept-risk",
            "--mode", "local",
            "--auth-choice", $ProviderInfo.AuthChoice,
            $ProviderInfo.KeyFlag, $key,
            "--secret-input-mode", "plaintext",
            "--gateway-port", "18789",
            "--gateway-bind", "loopback",
            "--install-daemon",
            "--daemon-runtime", "node",
            "--skip-skills"
        )
    } else {
        $base = if ($BaseUrl) { $BaseUrl.Trim() } elseif ($ProviderInfo.BaseUrl) { $ProviderInfo.BaseUrl } else { Read-Required -Prompt "  请输入 Base URL" }
        $compat = if ($ProviderInfo.Compatibility) { $ProviderInfo.Compatibility } else { "openai" }
        $onboardArgs = @(
            "onboard", "--non-interactive",
            "--accept-risk",
            "--mode", "local",
            "--auth-choice", "custom-api-key",
            "--custom-api-key", $key,
            "--secret-input-mode", "plaintext",
            "--gateway-port", "18789",
            "--gateway-bind", "loopback",
            "--install-daemon",
            "--daemon-runtime", "node",
            "--skip-skills",
            "--custom-base-url", $base,
            "--custom-model-id", $SelectedModel,
            "--custom-compatibility", $compat
        )
        Write-Info "Base URL: $base"
    }

    Write-Info "正在配置 OpenClaw..."
    Invoke-OpenClaw -OpenClawArgs $onboardArgs
    Write-Ok "OpenClaw 配置完成"
}

Write-Host ""
Write-Host "  OpenClaw 中文模型配置与切换脚本" -ForegroundColor Green
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
Write-Host ""

$script:OpenClawCmd = Get-OpenClawCommand
if (-not $script:OpenClawCmd) {
    Write-Err "找不到 openclaw 命令，请先安装 OpenClaw，或重新打开终端后再试"
    exit 1
}
Write-Info "OpenClaw 命令: $script:OpenClawCmd"

try {
    $version = (& $script:OpenClawCmd -v 2>$null).Trim()
    if ($version) { Write-Ok "已检测到 $version" }
} catch {}

if ($List) {
    $listArgs = @("models", "list", "--plain")
    if ($All) { $listArgs = @("models", "list", "--all", "--plain") }
    Invoke-OpenClaw -OpenClawArgs $listArgs
    exit $LASTEXITCODE
}

if ($Status) {
    Invoke-OpenClaw -OpenClawArgs @("models", "status", "--plain")
    exit $LASTEXITCODE
}

$gatewayWasRunning = Test-GatewayRunning
if ($gatewayWasRunning) {
    Write-Ok "Gateway 当前正在运行，配置完成后会直接执行 openclaw gateway restart"
} else {
    Write-Warn "Gateway 当前未运行，配置完成后不会主动启动"
}

$providerInfo = $null
if ($Provider -or $ApiKey -or $BaseUrl -or -not $Model) {
    $providerInfo = Select-Provider
}
$selectedModel = if ($Model) { $Model.Trim() } else { Select-Model -ProviderInfo $providerInfo }

if ($providerInfo) {
    Configure-Provider -ProviderInfo $providerInfo -SelectedModel $selectedModel
}

if ($selectedModel) {
    Write-Info "正在设置默认模型: $selectedModel"
    Invoke-OpenClaw -OpenClawArgs @("models", "set", $selectedModel)
    Write-Ok "默认模型已设置"
}

Write-Host ""
Write-Info "当前模型状态:"
Invoke-OpenClaw -OpenClawArgs @("models", "status", "--plain") -AllowFailure | Out-Null

if ((($gatewayWasRunning -and -not $NoRestartGateway) -or $RestartGateway)) {
    Write-Host ""
    Write-Info "正在重启 OpenClaw Gateway..."
    Invoke-OpenClaw -OpenClawArgs @("gateway", "restart")
    Invoke-OpenClaw -OpenClawArgs @("gateway", "probe") -AllowFailure | Out-Null
}

Write-Host ""
Write-Ok "完成"
