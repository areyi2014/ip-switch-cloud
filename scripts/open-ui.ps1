# ip-switch Skill - PowerShell 包装器
# 自动定位 node 并调用 open-ui.mjs
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$NodeScript = Join-Path $ScriptDir "open-ui.mjs"

# 收集所有参数（包括 --port / aws 等）
$AllArgs = @()
if ($args) { $AllArgs = $args }

# 优先用本脚本所在目录的 node，回退到 PATH
$NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeExe) {
    Write-Error "未找到 node，请先安装 Node.js 18+: https://nodejs.org"
    exit 1
}

& $NodeExe $NodeScript @AllArgs
exit $LASTEXITCODE