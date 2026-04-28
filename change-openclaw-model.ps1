# OpenClaw 中文模型配置与切换脚本 (Windows)
# 在线使用:
#   irm https://gitee.com/mijiamiyu/scripts/raw/main/change-openclaw-model.ps1 | iex
#
# 直接设置:
#   $env:OPENCLAW_PROVIDER='qwen'
#   $env:OPENCLAW_API_KEY='sk-xxx'
#   $env:OPENCLAW_MODEL='qwen3.6-flash'
#   irm https://gitee.com/mijiamiyu/scripts/raw/main/change-openclaw-model.ps1 | iex

param(
    [string]$Provider = $env:OPENCLAW_PROVIDER,
    [string]$ApiKey = $env:OPENCLAW_API_KEY,
    [string]$Model = $env:OPENCLAW_MODEL,
    [string]$BaseUrl = $env:OPENCLAW_BASE_URL,
    [string]$ContextWindow = $env:OPENCLAW_CONTEXT_WINDOW,
    [switch]$Status,
    [switch]$List,
    [switch]$All,
    [switch]$RestartGateway,
    [switch]$NoRestartGateway
)

# ── Process Scope Bypass：让 iex 模式 + pnpm 装的 openclaw.ps1 都能在 Restricted/AllSigned 系统跑 ──
# Process Scope 不写注册表、不需要管理员,只活在当前 PowerShell 进程。
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch {}

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

# 上下文 token 数格式化为 K/M(K=1024, M=1024*1024 整除时)
function Format-ContextWindow {
    param([int]$Value)
    if ($Value -le 0) { return "" }
    if (($Value -ge 1048576) -and ($Value % 1048576 -eq 0)) { return "$([math]::Floor($Value / 1048576))M" }
    if (($Value -ge 1024) -and ($Value % 1024 -eq 0)) { return "$([math]::Floor($Value / 1024))K" }
    return "$Value"
}

# 支持 b 返回的输入(空 = 重新输入,b = 返回 __BACK__)
function Read-InputWithBack {
    param([string]$Prompt, [string]$Value = "")
    if ($Value) { return $Value }
    while ($true) {
        $input = (Read-Host $Prompt).Trim()
        switch -Regex ($input) {
            "^(b|B|back)$" { return "__BACK__" }
            "^$" { Write-Warn "不能为空,请重新输入(或输入 b 返回上一步)" }
            default { return $input }
        }
    }
}

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
        throw "openclaw $($OpenClawArgs[0]) 执行失败，退出码: $exitCode"
    }
    return $exitCode
}

function Test-CustomOnboardApplied {
    param([string]$SelectedModel, [string]$EffectiveBaseUrl)

    $configPath = Join-Path $HOME ".openclaw\openclaw.json"
    if (-not (Test-Path $configPath)) { return $false }

    try {
        $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $targetBase = Normalize-Url $EffectiveBaseUrl
        $providers = $config.models.providers
        if (-not $providers) { return $false }

        foreach ($providerProp in $providers.PSObject.Properties) {
            $candidate = $providerProp.Value
            if ((Normalize-Url $candidate.baseUrl) -ne $targetBase) { continue }
            foreach ($modelProp in $candidate.models.PSObject.Properties) {
                if ($modelProp.Value.id -eq $SelectedModel) { return $true }
            }
        }
    } catch {}

    return $false
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
    param(
        [string]$Id,
        [string]$Label,
        [string]$Modality,
        [string]$Note = "",
        [int]$ContextWindow = 0,
        [int]$MaxTokens = 0,
        [string]$Source = ""
    )
    return @{
        Id=$Id
        Label=$Label
        Input=$Modality
        Note=$Note
        ContextWindow=$ContextWindow
        MaxTokens=$MaxTokens
        Source=$Source
    }
}

# Key 为空字符串("")表示主菜单不显示——这些是子计费方式,
# 用户先选 volcengine/qwen,再二级菜单升级到 ark-coding / qwen-token-plan
$script:Providers = @(
    @{ Key="1";  Name="deepseek";       Label="DeepSeek";              Mode="custom"; BaseUrl="https://api.deepseek.com"; Compatibility="openai"; Portal="https://platform.deepseek.com/" },
    @{ Key="2";  Name="minimax";        Label="MiniMax";               Mode="custom"; BaseUrl="https://api.minimaxi.com/v1"; Compatibility="openai"; Portal="https://platform.minimaxi.com/subscribe/token-plan" },
    @{ Key="3";  Name="qwen";           Label="阿里百炼 / Qwen";        Mode="custom"; BaseUrl="https://dashscope.aliyuncs.com/compatible-mode/v1"; Compatibility="openai"; Portal="https://bailian.console.aliyun.com/" },
    @{ Key="4";  Name="volcengine";     Label="火山方舟 / Doubao";      Mode="custom"; BaseUrl="https://ark.cn-beijing.volces.com/api/v3"; Compatibility="openai"; Portal="https://console.volcengine.com/ark/" },
    @{ Key="";   Name="ark-coding";     Label="火山方舟 Coding Plan";   Mode="custom"; BaseUrl="https://ark.cn-beijing.volces.com/api/coding/v3"; Compatibility="openai"; Portal="https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement/coding-plan" },
    @{ Key="";   Name="qwen-token-plan";Label="阿里百炼 Token Plan";    Mode="custom"; BaseUrl="https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"; Compatibility="openai"; Portal="https://bailian.console.aliyun.com/?tab=tokenplan" },
    @{ Key="5";  Name="zai";            Label="智谱 / BigModel";        Mode="custom"; BaseUrl="https://open.bigmodel.cn/api/paas/v4"; Compatibility="openai"; Portal="https://open.bigmodel.cn/" },
    @{ Key="";   Name="zai-coding-plan"; Label="智谱 BigModel Coding Plan"; Mode="custom"; BaseUrl="https://open.bigmodel.cn/api/coding/paas/v4"; Compatibility="openai"; Portal="https://open.bigmodel.cn/" },
    @{ Key="6";  Name="moonshot";       Label="Moonshot / Kimi";       Mode="custom"; BaseUrl="https://api.moonshot.cn/v1"; Compatibility="openai"; Portal="https://platform.moonshot.cn/" },
    @{ Key="";   Name="moonshot-coding-plan"; Label="Kimi Coding Plan"; Mode="custom"; BaseUrl="https://api.kimi.com/coding/v1"; Compatibility="openai"; Portal="https://platform.moonshot.cn/" },
    @{ Key="7";  Name="xiaomi";         Label="小米 MiMo";              Mode="custom"; BaseUrl="https://api.xiaomimimo.com/v1"; Compatibility="openai"; Portal="https://platform.xiaomimimo.com/" },
    @{ Key="";   Name="xiaomi-token-plan"; Label="小米 MiMo Token Plan"; Mode="custom"; BaseUrl="https://token-plan-cn.xiaomimimo.com/v1"; Compatibility="openai"; Portal="https://platform.xiaomimimo.com/token-plan" },
    @{ Key="8";  Name="custom";         Label="自定义兼容接口";         Mode="custom"; BaseUrl=""; Compatibility="openai"; Portal="" }
)

$script:ModelMap = @{
    "deepseek" = @(
        (New-Model "deepseek-v4-pro" "DeepSeek V4 Pro" "文本" "强推理/复杂任务" 1048576 0 "DeepSeek 官方 Hugging Face 模型卡"),
        (New-Model "deepseek-v4-flash" "DeepSeek V4 Flash" "文本" "高速/低成本" 1048576 0 "DeepSeek 官方 Hugging Face 模型卡")
    )
    "minimax" = @(
        (New-Model "MiniMax-M2.7" "MiniMax M2.7" "文本" "默认推荐" 204800 0 "MiniMax 官方 API Overview"),
        (New-Model "MiniMax-M2.7-highspeed" "MiniMax M2.7 Highspeed" "文本" "高速版" 204800 0 "MiniMax 官方 API Overview"),
        (New-Model "MiniMax-M2.5" "MiniMax M2.5" "文本" "旧一代高性价比" 204800 0 "MiniMax 官方 API Overview"),
        (New-Model "MiniMax-M2.5-highspeed" "MiniMax M2.5 Highspeed" "文本" "旧一代高速版" 204800 0 "MiniMax 官方 API Overview")
    )
    "qwen" = @(
        (New-Model "qwen3.6-plus" "Qwen3.6 Plus" "文本/图片" "1M 上下文，主推" 1048576 0 "阿里云官方新闻稿/Model Studio 文档"),
        (New-Model "qwen3.6-flash" "Qwen3.6 Flash" "文本/图片" "1M 上下文，低成本" 1048576 0 "用户确认，待阿里云精确 Model ID 文档同步"),
        (New-Model "qwen3.6-max-preview" "Qwen3.6 Max Preview" "文本" "256K 上下文，最高推理能力" 262144 0 "按 Qwen3 Max 系列官方上下文配置"),
        (New-Model "qwen3-max" "Qwen3 Max" "文本/图片" "256K 上下文，稳定版" 262144 0 "阿里云 Model Studio 官方模型列表"),
        (New-Model "qwen3.5-plus" "Qwen3.5 Plus" "文本/图片" "1M 上下文" 1048576 0 "阿里云 Model Studio 官方模型列表"),
        (New-Model "qwen3.5-flash" "Qwen3.5 Flash" "文本/图片" "1M 上下文" 1048576 0 "阿里云 Model Studio 官方模型列表")
    )
    "volcengine" = @(
        (New-Model "doubao-seed-2-0-code-preview-260215" "Doubao Seed 2.0 Code" "文本/图片" "256K 上下文，编程/前端/Agent" 262144 0 ""),
        (New-Model "doubao-seed-2-0-pro-260215" "Doubao Seed 2.0 Pro" "文本/图片" "256K 上下文，强推理/复杂任务" 262144 0 ""),
        (New-Model "doubao-seed-2-0-lite-260215" "Doubao Seed 2.0 Lite" "文本/图片" "256K 上下文，通用性价比" 262144 0 ""),
        (New-Model "doubao-seed-2-0-mini-260215" "Doubao Seed 2.0 Mini" "文本/图片" "256K 上下文，低延迟/高并发/低成本" 262144 0 "")
    )
    "ark-coding" = @(
        (New-Model "ark-code-latest" "Ark Code Latest" "文本/图片" "250K 上下文，Auto 模式：按效果+速度智能路由（推荐）" 256000 0 ""),
        (New-Model "doubao-seed-code" "Doubao Seed Code" "文本/图片" "256K 上下文，Doubao 编程主推" 262144 0 ""),
        (New-Model "doubao-seed-2.0-code" "Doubao Seed 2.0 Code" "文本/图片" "256K 上下文，2.0 代编程版" 262144 0 ""),
        (New-Model "doubao-seed-2.0-pro" "Doubao Seed 2.0 Pro" "文本/图片" "256K 上下文，强推理" 262144 0 ""),
        (New-Model "doubao-seed-2.0-lite" "Doubao Seed 2.0 Lite" "文本/图片" "256K 上下文，通用性价比" 262144 0 ""),
        (New-Model "kimi-k2.6" "Kimi K2.6" "文本" "256K 上下文，Moonshot 最新" 262144 0 ""),
        (New-Model "kimi-k2.5" "Kimi K2.5" "文本" "256K 上下文，Moonshot 上一代" 262144 0 ""),
        (New-Model "deepseek-v3.2" "DeepSeek V3.2" "文本" "128K 上下文，DeepSeek 通过 Coding Plan 路由" 131072 0 ""),
        (New-Model "minimax-m2.7" "MiniMax M2.7" "文本" "200K 上下文，MiniMax 通过 Coding Plan 路由" 204800 0 ""),
        (New-Model "glm-5.1" "GLM-5.1" "文本" "200K 上下文，智谱通过 Coding Plan 路由" 204800 0 ""),
        (New-Model "glm-4.7" "GLM-4.7" "文本" "200K 上下文，智谱旧版" 204800 0 "")
    )
    "qwen-token-plan" = @(
        (New-Model "qwen3.6-plus" "Qwen3.6 Plus" "文本/图片" "1M 上下文，阿里百炼 Token Plan 主推" 1048576 0 ""),
        (New-Model "glm-5" "GLM-5" "文本" "198K 上下文，智谱通过 Token Plan 路由" 202752 0 ""),
        (New-Model "MiniMax-M2.5" "MiniMax M2.5" "文本" "192K 上下文，MiniMax 通过 Token Plan 路由" 196608 0 ""),
        (New-Model "deepseek-v3.2" "DeepSeek V3.2" "文本" "160K 上下文，DeepSeek 通过 Token Plan 路由" 163840 0 "")
    )
    "zai" = @(
        (New-Model "glm-5.1" "GLM-5.1" "文本" "200K 上下文，当前快速开始默认模型" 204800 0 ""),
        (New-Model "glm-5" "GLM-5" "文本" "200K 上下文，Agentic Engineering" 204800 0 ""),
        (New-Model "glm-4.7" "GLM-4.7" "文本" "200K 上下文，Agentic Coding" 204800 0 ""),
        (New-Model "glm-5-turbo" "GLM-5 Turbo" "文本/图片" "200K 上下文，多模态 Coding 基座" 204800 0 ""),
        (New-Model "glm-4.6" "GLM-4.6" "文本/图片" "128K 上下文，视觉理解" 131072 0 "")
    )
    "zai-coding-plan" = @(
        (New-Model "glm-5.1" "GLM-5.1" "文本" "200K 上下文，Coding Plan 路由" 204800 0 ""),
        (New-Model "glm-5" "GLM-5" "文本" "200K 上下文，Coding Plan 路由" 204800 0 ""),
        (New-Model "glm-4.7" "GLM-4.7" "文本" "200K 上下文，Coding Plan 路由" 204800 0 ""),
        (New-Model "glm-5-turbo" "GLM-5 Turbo" "文本/图片" "200K 上下文，Coding Plan 路由" 204800 0 ""),
        (New-Model "glm-4.6" "GLM-4.6" "文本/图片" "128K 上下文，Coding Plan 路由" 131072 0 "")
    )
    "moonshot" = @(
        (New-Model "kimi-k2.6" "Kimi K2.6" "文本/图片" "256K 上下文，Kimi 新一代" 262144 0 ""),
        (New-Model "kimi-k2.5" "Kimi K2.5" "文本/图片" "256K 上下文，视觉/代码/Agent" 262144 0 "")
    )
    "moonshot-coding-plan" = @(
        (New-Model "kimi-for-coding" "Kimi for Coding" "文本" "Coding Plan 专用单模型" 0 0 "")
    )
    "xiaomi" = @(
        (New-Model "xiaomi/mimo-v2.5-pro" "MiMo V2.5 Pro" "文本/图片" "1M 上下文，强推理/复杂任务" 1048576 0 ""),
        (New-Model "xiaomi/mimo-v2.5" "MiMo V2.5" "文本/图片" "1M 上下文，通用" 1048576 0 ""),
        (New-Model "xiaomi/mimo-v2-pro" "MiMo V2 Pro" "文本/图片" "1M 上下文，旧版强推理" 1048576 0 ""),
        (New-Model "xiaomi/mimo-v2-flash" "MiMo V2 Flash" "文本/图片" "128K 上下文，轻量高速" 131072 0 "")
    )
    "xiaomi-token-plan" = @(
        (New-Model "xiaomi/mimo-v2.5-pro" "MiMo V2.5 Pro" "文本/图片" "1M 上下文，Token Plan 路由" 1048576 0 ""),
        (New-Model "xiaomi/mimo-v2.5" "MiMo V2.5" "文本/图片" "1M 上下文，Token Plan 路由" 1048576 0 ""),
        (New-Model "xiaomi/mimo-v2-pro" "MiMo V2 Pro" "文本/图片" "1M 上下文，Token Plan 路由" 1048576 0 ""),
        (New-Model "xiaomi/mimo-v2-flash" "MiMo V2 Flash" "文本/图片" "128K 上下文，Token Plan 路由" 131072 0 "")
    )
}

function Select-Provider {
    if ($Provider) {
        $matched = $script:Providers | Where-Object { $_.Name -eq $Provider -or $_.Key -eq $Provider } | Select-Object -First 1
        if ($matched) {
            return (Get-PlanUpgrade -Base $matched)
        }
        Write-Warn "未识别的厂商: $Provider，将进入交互选择"
    }

    Write-Host "  请选择 AI 厂商:" -ForegroundColor Cyan
    Write-Host ""
    $visibleMax = 0
    foreach ($p in $script:Providers) {
        # 跳过 Key 为空的子计费方式(主菜单不显示)
        if (-not $p.Key) { continue }
        $keyInt = 0
        if ([int]::TryParse($p.Key, [ref]$keyInt) -and $keyInt -gt $visibleMax) { $visibleMax = $keyInt }
        $portalText = if ($p.Portal) { " | 官网: $($p.Portal)" } else { "" }
        Write-Host ("  {0,2}) {1,-10} - {2}{3}" -f $p.Key, $p.Name, $p.Label, $portalText)
    }
    Write-Host "   0) 仅切换模型 / 跳过厂商配置"
    Write-Host ""

    while ($true) {
        $choice = (Read-Host "  请输入编号 [0-$visibleMax]").Trim()
        if ($choice -eq "0") { return $null }
        $picked = $script:Providers | Where-Object { ($_.Key -and $_.Key -eq $choice) -or $_.Name -eq $choice } | Select-Object -First 1
        if ($picked -and $picked.Key) {
            return (Get-PlanUpgrade -Base $picked)
        }
        Write-Warn "无效编号,请输入 0-$visibleMax"
    }
}

# 二级菜单:volcengine→Coding Plan, qwen→Token Plan, xiaomi→Token Plan
function Get-PlanUpgrade {
    param([hashtable]$Base)
    $planMap = @{
        "volcengine" = @{ Name="ark-coding"; Desc="Coding Plan(智能路由,需在火山方舟控制台单独订阅)" }
        "qwen"       = @{ Name="qwen-token-plan"; Desc="Token Plan(智能路由,需在阿里百炼控制台单独订阅)" }
        "zai"        = @{ Name="zai-coding-plan"; Desc="Coding Plan(智能路由,需在智谱 BigModel 控制台单独订阅)" }
        "moonshot"   = @{ Name="moonshot-coding-plan"; Desc="Coding Plan(只支持 kimi-for-coding 单模型,需在 Moonshot 控制台单独订阅)" }
        "xiaomi"     = @{ Name="xiaomi-token-plan"; Desc="Token Plan(智能路由,需在小米 MiMo 控制台单独订阅)" }
    }
    if (-not $planMap.ContainsKey($Base.Name)) { return $Base }

    $plan = $planMap[$Base.Name]
    Write-Host ""
    Write-Host "  $($Base.Label) 还支持订阅计费方式(可选):" -ForegroundColor Cyan
    Write-Host "   1) 标准按量付费(默认,普通 API Key 即可)"
    Write-Host "   2) $($plan.Desc)"
    while ($true) {
        $planChoice = (Read-Host "  请选择 [1/2,直接回车=1]").Trim()
        switch ($planChoice) {
            { $_ -in @("", "1") } {
                return $Base
            }
            "2" {
                $upgraded = $script:Providers | Where-Object { $_.Name -eq $plan.Name } | Select-Object -First 1
                if ($upgraded) { return $upgraded }
                return $Base
            }
            default { Write-Warn "无效输入,请输入 1 或 2" }
        }
    }
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

    # 只有 1 个模型时自动选中,跳过菜单(用于 kimi-for-coding 这类单模型 Plan)
    if ($models.Count -eq 1) {
        $only = $models[0]
        Write-Host ""
        Write-Info "默认模型自动选中: $($only["Label"]) [$($only["Id"])]"
        Write-Host ""
        return $only["Id"]
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
    Write-Host "   b) 返回上一步(重选厂商)"
    Write-Host ""

    while ($true) {
        $choice = (Read-Host "  请选择 [0-$($models.Count) / b]").Trim()
        if ($choice -match "^(b|B|back)$") { return "__BACK__" }
        if ($choice -eq "0") {
            $manual = Read-InputWithBack -Prompt "  请输入自定义 Model ID(b 返回上一步)"
            if ($manual -eq "__BACK__") { return "__BACK__" }
            return $manual
        }
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $models.Count) {
            return $models[$idx - 1].Id
        }
        Write-Warn "无效输入,请输入 0-$($models.Count) 或 b"
    }
}

function Get-SelectedModelInfo {
    param([hashtable]$ProviderInfo, [string]$SelectedModel)
    if (-not $ProviderInfo -or -not $SelectedModel) { return $null }
    $models = $script:ModelMap[$ProviderInfo.Name]
    if (-not $models) { return $null }
    return ($models | Where-Object { $_["Id"] -eq $SelectedModel } | Select-Object -First 1)
}

function Normalize-Url {
    param([string]$Url)
    if (-not $Url) { return "" }
    return $Url.Trim().TrimEnd("/")
}

function Set-JsonProperty {
    param([object]$Object, [string]$Name, $Value)
    if ($null -eq $Object) { return }
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Convert-ModalityToInput {
    param([string]$Modality)
    if ($Modality -like "*图片*") { return ,@("text", "image") }
    return ,@("text")
}

function Convert-TokenSize {
    param([string]$Value)
    $raw = if ($Value) { $Value.Trim() } else { "" }
    if (-not $raw) { return 0 }

    $normalized = $raw -replace ",", ""
    if ($normalized -match '^(?<num>\d+(\.\d+)?)(?<unit>[kKmM])?$') {
        $num = [double]$Matches["num"]
        $unit = $Matches["unit"]
        # K=1024, M=1024*1024(全脚本统一二进制换算)
        if ($unit -match "^[kK]$") { return [int][math]::Round($num * 1024) }
        if ($unit -match "^[mM]$") { return [int][math]::Round($num * 1048576) }
        return [int][math]::Round($num)
    }

    throw "无法识别 token 数量: $Value。示例: 1M、256K、1048576、262144"
}

function Read-OptionalTokenSize {
    param([string]$Prompt, [string]$Value = "")
    while ($true) {
        $raw = if ($Value) { $Value.Trim() } else { (Read-Host $Prompt).Trim() }
        if (-not $raw) { return 0 }
        try { return (Convert-TokenSize $raw) }
        catch {
            Write-Warn $_
            if ($Value) { return 0 }
        }
    }
}

function Resolve-CustomMetadata {
    param([hashtable]$ProviderInfo, [string]$SelectedModel)
    $modelInfo = Get-SelectedModelInfo -ProviderInfo $ProviderInfo -SelectedModel $SelectedModel
    if ($modelInfo) {
        $clone = $modelInfo.Clone()
        $clone["IsKnown"] = $true
        return $clone
    }

    return @{
        Id=$SelectedModel
        Label=$SelectedModel
        Input="文本"
        Note=""
        ContextWindow=0
        MaxTokens=0
        Source=""
        IsKnown=$false
    }
}

function Complete-CustomMetadata {
    param([hashtable]$ModelInfo)

    if ($ContextWindow) {
        $ModelInfo["ContextWindow"] = Read-OptionalTokenSize -Prompt "" -Value $ContextWindow
        $ModelInfo["Source"] = "用户手动输入"
    }
    elseif ((-not $ModelInfo["IsKnown"]) -and ($ModelInfo["ContextWindow"] -le 0)) {
        # 用户手动输入的未知 model id,我们没有上下文数据,问一下
        Write-Host ""
        Write-Warn "手动输入的 Model ID 没有内置上下文配置。"
        Write-Warn "直接回车 = 沿用 OpenClaw 默认值（custom 模型通常是 16K）。"
        Write-Host "  支持写法: 1M / 1m / 256K / 256k / 1048576 / 262144（K=1024）"
        $ctx = Read-OptionalTokenSize -Prompt "  请输入上下文窗口 contextWindow（可选）"
        if ($ctx -gt 0) {
            $ModelInfo["ContextWindow"] = $ctx
            $ModelInfo["Source"] = "用户手动输入"
        }
    }
    # 已知模型(在预设里但 ContextWindow=0)沿用 OpenClaw 默认值,不打断流程
    return $ModelInfo
}

function Apply-CustomModelMetadata {
    param([hashtable]$ProviderInfo, [string]$SelectedModel, [string]$EffectiveBaseUrl)
    if (-not $ProviderInfo -or $ProviderInfo.Mode -ne "custom" -or -not $SelectedModel) { return }

    $modelInfo = Resolve-CustomMetadata -ProviderInfo $ProviderInfo -SelectedModel $SelectedModel
    $modelInfo = Complete-CustomMetadata -ModelInfo $modelInfo
    if (-not $modelInfo -or (($modelInfo["ContextWindow"] -le 0) -and ($modelInfo["MaxTokens"] -le 0))) {
        Write-Info "未设置上下文元数据，保留 OpenClaw 默认值（custom 模型通常是 16K）"
        return
    }

    $configPath = Join-Path $env:USERPROFILE ".openclaw\openclaw.json"
    if (-not (Test-Path $configPath)) {
        Write-Warn "未找到 OpenClaw 配置文件，无法写入模型元数据: $configPath"
        return
    }

    try {
        $config = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $targetBase = Normalize-Url $EffectiveBaseUrl
        $provider = $null

        foreach ($prop in $config.models.providers.PSObject.Properties) {
            $candidate = $prop.Value
            if ((Normalize-Url $candidate.baseUrl) -eq $targetBase) {
                $provider = $candidate
                break
            }
        }

        if (-not $provider) {
            Write-Warn "未能按 Base URL 找到 custom provider，跳过模型元数据写入"
            return
        }

        $targetModel = $null
        foreach ($modelProp in $provider.models.PSObject.Properties) {
            if ($modelProp.Value.id -eq $SelectedModel) {
                $targetModel = $modelProp.Value
                break
            }
        }

        if (-not $targetModel) {
            Write-Warn "未能在 custom provider 中找到模型 $SelectedModel，跳过模型元数据写入"
            return
        }

        if ($modelInfo["ContextWindow"] -gt 0) {
            Set-JsonProperty -Object $targetModel -Name "contextWindow" -Value ([int]$modelInfo["ContextWindow"])
        }
        if ($modelInfo["MaxTokens"] -gt 0) {
            Set-JsonProperty -Object $targetModel -Name "maxTokens" -Value ([int]$modelInfo["MaxTokens"])
        }
        if ($modelInfo["Input"]) {
            Set-JsonProperty -Object $targetModel -Name "input" -Value (Convert-ModalityToInput $modelInfo["Input"])
        }

        $json = $config | ConvertTo-Json -Depth 100
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($configPath, $json + [Environment]::NewLine, $utf8NoBom)

        $ctxText = if ($modelInfo["ContextWindow"] -gt 0) { "contextWindow=$($modelInfo["ContextWindow"])" } else { "contextWindow=保留默认" }
        $outText = if ($modelInfo["MaxTokens"] -gt 0) { "maxTokens=$($modelInfo["MaxTokens"])" } else { "maxTokens=保留默认" }
        Write-Ok "已写入官方核实模型元数据: $ctxText, $outText"
        if ($modelInfo["Source"]) { Write-Info "核实来源: $($modelInfo["Source"])" }
    } catch {
        Write-Warn "写入模型元数据失败，OpenClaw 主配置已完成: $_"
    }
}

function Configure-Provider {
    param([hashtable]$ProviderInfo, [string]$SelectedModel, [string]$ApiKeyValue)
    if (-not $ProviderInfo) { return }

    $key = $ApiKeyValue

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
    $onboardExit = Invoke-OpenClaw -OpenClawArgs $onboardArgs -AllowFailure
    if ($onboardExit -ne 0) {
        $applied = $false
        if ($ProviderInfo.Mode -eq "custom") {
            $applied = Test-CustomOnboardApplied -SelectedModel $SelectedModel -EffectiveBaseUrl $base
        }
        if ($applied) {
            Write-Warn "openclaw onboard 返回退出码 $onboardExit，但模型配置已写入；通常是 Gateway 探测失败，继续补写模型元数据"
            Write-Info "Gateway 启动失败不等于模型配置失败，可稍后单独执行 openclaw gateway restart 排查"
        } else {
            throw "openclaw onboard 执行失败，退出码: $onboardExit"
        }
    }
    Write-Ok "OpenClaw 配置完成"
    Write-Info "配置文件已写入: $HOME\.openclaw\openclaw.json"

    if ($ProviderInfo.Mode -eq "custom") {
        Apply-CustomModelMetadata -ProviderInfo $ProviderInfo -SelectedModel $SelectedModel -EffectiveBaseUrl $base
    }
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
$selectedModel = ""
$apiKeyInput = ""

# 状态机:provider → model → apikey,任一步输入 b 都能返回上一步
if ($Provider -or $ApiKey -or $BaseUrl -or -not $Model) {
    $flowState = "provider"
    while ($flowState -ne "configured") {
        switch ($flowState) {
            "provider" {
                $providerInfo = Select-Provider
                $flowState = "model"
            }
            "model" {
                $sel = if ($Model) { $Model.Trim() } else { Select-Model -ProviderInfo $providerInfo }
                if ($sel -eq "__BACK__") {
                    # 清掉环境变量,让 Select-Provider 重新显示菜单
                    $Provider = ""
                    $flowState = "provider"
                } else {
                    $selectedModel = $sel
                    if ($providerInfo) {
                        $flowState = "apikey"
                    } else {
                        $flowState = "configured"
                    }
                }
            }
            "apikey" {
                Write-Step "配置 $($providerInfo.Label)"
                $apiKeyInput = Read-InputWithBack -Prompt "  请输入 API Key (输入 b 返回上一步)" -Value $ApiKey
                if ($apiKeyInput -eq "__BACK__") {
                    # 清掉环境变量,让 Select-Model 重新显示菜单
                    $Model = ""
                    $selectedModel = ""
                    $flowState = "model"
                } else {
                    $flowState = "configured"
                }
            }
        }
    }
} else {
    $selectedModel = $Model.Trim()
}

if ($providerInfo) {
    Configure-Provider -ProviderInfo $providerInfo -SelectedModel $selectedModel -ApiKeyValue $apiKeyInput
}

if ($selectedModel -and (-not $providerInfo -or $providerInfo.Mode -ne "custom")) {
    Write-Info "正在设置默认模型: $selectedModel"
    Invoke-OpenClaw -OpenClawArgs @("models", "set", $selectedModel)
    Write-Ok "默认模型已设置"
} elseif ($selectedModel -and $providerInfo.Mode -eq "custom") {
    Write-Ok "Custom 模型已由 openclaw onboard 写入: $selectedModel"
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
