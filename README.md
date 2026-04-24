# OpenClaw Scripts

Small helper scripts for OpenClaw.

## Set Model

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/openclaw-set-model.ps1 | iex
```

Set a model directly:

```powershell
$env:OPENCLAW_MODEL='xiaomi/mimo-v2-flash'
irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/openclaw-set-model.ps1 | iex
```

macOS/Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/openclaw-set-model.sh | bash
```

Set a model directly:

```bash
curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/openclaw-set-model.sh | bash -s -- --model xiaomi/mimo-v2-flash
```

The scripts only change OpenClaw model settings. If the gateway is already running, they restart it after the model is updated. If the gateway is not running, they do not start it.
