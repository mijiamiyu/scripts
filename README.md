# OpenClaw Scripts

OpenClaw 安装与模型切换脚本。

## 安装 OpenClaw

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/install-openclaw.ps1 | iex
```

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/install-openclaw.sh | bash
```

安装脚本会安装 OpenClaw，并在最后调用中文模型配置流程。
安装时会同时设置国内镜像：

- npm: `https://registry.npmmirror.com`
- ClawHub: `https://cn.clawhub-mirror.com`

## 更换模型

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/change-openclaw-model.ps1 | iex
```

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/change-openclaw-model.sh | bash
```

直接指定模型:

```powershell
$env:OPENCLAW_PROVIDER='qwen'
$env:OPENCLAW_API_KEY='sk-xxx'
$env:OPENCLAW_MODEL='qwen3.6-flash'
irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/change-openclaw-model.ps1 | iex
```

```bash
OPENCLAW_PROVIDER=qwen OPENCLAW_API_KEY=sk-xxx OPENCLAW_MODEL=qwen3.6-flash \
curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/change-openclaw-model.sh | bash
```

## 打开 OpenClaw 文件夹

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/mijiamiyu/scripts/main/open-openclaw-folder.ps1 | iex
```

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/mijiamiyu/scripts/main/open-openclaw-folder.sh | bash
```

如果 GitHub 访问慢，可以把域名换成 Gitee:

```powershell
irm https://gitee.com/mijiamiyu/scripts/raw/main/open-openclaw-folder.ps1 | iex
```

```bash
curl -fsSL https://gitee.com/mijiamiyu/scripts/raw/main/open-openclaw-folder.sh | bash
```

## 说明

脚本菜单只标注 `文本` 或 `文本/图片`，不额外标注其它输入能力。DeepSeek、MiniMax、Qwen、火山方舟、智谱、Kimi、千帆默认按 OpenAI 兼容 custom 接入；小米、OpenAI、Anthropic 使用 OpenClaw 内置 provider。
