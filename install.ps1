#===============================================================================
# cloud-ip-rotator-mcp 自动部署脚本 (Windows PowerShell)
#===============================================================================
# 用途: 一键克隆、安装依赖、编译、生成 MCP 配置
# 适用: Windows 10/11 (PowerShell 5.1+)
# 前提: git 已安装, Node.js >= 18 已安装
#===============================================================================
param(
    [string]$RepoUrl    = "https://gitee.com/areyi2014/cloud-ip-rotator-mcp.git",
    [string]$Branch     = "main",
    [string]$InstallDir = "$env:USERPROFILE\cloud-ip-rotator-mcp",
    [switch]$SkipBuild  = $false,
    [switch]$Help       = $false
)

if ($Help) {
    Write-Host @"
用法: .\install.ps1 [选项]

选项:
  -RepoUrl URL     指定仓库地址（默认 gitee）
  -Branch NAME     指定分支（默认 main）
  -InstallDir DIR  指定安装目录（默认 ~\cloud-ip-rotator-mcp）
  -SkipBuild       跳过编译步骤
  -Help            显示帮助

示例:
  .\install.ps1
  .\install.ps1 -RepoUrl "https://gitee.com/user/cloud-ip-rotator-mcp.git"
  .\install.ps1 -InstallDir "D:\my-tools\cloud-ip-rotator-mcp"
"@
    exit 0
}

$ErrorActionPreference = "Stop"
$NodeMinVersion = 18
$ProjectName = "cloud-ip-rotator-mcp"

# -- 辅助函数 ---------------------------------------------------------------
function Write-Step($msg) {
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}

function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Blue }
function Write-OK($msg)    { Write-Host "[ OK ]  $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# -- 检查 Node.js ------------------------------------------------------------
function Check-Node {
    Write-Step "检查 Node.js 环境"

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        Write-Err "未检测到 Node.js，请先安装 Node.js >= $NodeMinVersion"
        Write-Info "访问 https://nodejs.org/ 下载安装"
        Write-Info "推荐安装 Node.js 22 LTS 版本"
        exit 1
    }

    $nodeVersion = node -v
    $major = [int]($nodeVersion -replace 'v', '').Split('.')[0]

    if ($major -lt $NodeMinVersion) {
        Write-Err "Node.js 版本过低: $nodeVersion，需要 >= v$NodeMinVersion"
        exit 1
    }

    $nodeExePath = $nodeCmd.Source
    Write-OK "Node.js $nodeVersion ($nodeExePath)"

    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCmd) {
        Write-Err "未检测到 npm"
        exit 1
    }
    Write-OK "npm $(& npm --version) ($($npmCmd.Source))"
}

# -- 检查 git -----------------------------------------------------------------
function Check-Git {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        Write-Err "未检测到 git，请先安装 Git for Windows"
        Write-Info "访问 https://git-scm.com/download/win 下载安装"
        exit 1
    }
    Write-OK "git $(& git --version) ($($gitCmd.Source))"
}

# -- 克隆仓库 ----------------------------------------------------------------
function Clone-Repo {
    Write-Step "克隆项目仓库"

    if (Test-Path "$InstallDir\.git") {
        Write-Warn "目标目录已存在，执行 git pull 更新..."
        Push-Location $InstallDir
        git fetch origin $Branch
        git checkout $Branch
        git pull origin $Branch
        Pop-Location
        Write-OK "项目已更新: $InstallDir"
        return
    }

    Write-Info "正在克隆: $RepoUrl (分支: $Branch)"

    $parentDir = Split-Path $InstallDir -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $cloneError = $(git clone --branch $Branch --depth 1 $RepoUrl $InstallDir 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-Err "克隆失败，错误信息:"
        Write-Host "  $cloneError" -ForegroundColor Red
        Write-Info ""
        Write-Info "请检查:"
        Write-Info "  1. 仓库地址是否正确: $RepoUrl"
        Write-Info "  2. 网络是否正常"
        Write-Info "  3. 如为私有仓库，请先配置 SSH Key"
        Write-Info ""
        Write-Info "手动操作:"
        Write-Info "  git clone $RepoUrl $InstallDir"
        exit 1
    }
    Write-OK "克隆成功: $InstallDir"
}

# -- 安装依赖 ----------------------------------------------------------------
function Install-Deps {
    Write-Step "安装 npm 依赖"

    Push-Location $InstallDir

    if (-not (Test-Path package.json)) {
        Write-Err "未找到 package.json，项目结构异常"
        Pop-Location
        exit 1
    }

    Write-Info "正在安装依赖，请稍候..."
    try {
        $null = npm install --loglevel=error 2>&1
        Write-OK "依赖安装完成"
    } catch {
        Write-Err "依赖安装失败"
        Write-Info "尝试清除缓存后重试: cd $InstallDir; Remove-Item -Recurse -Force node_modules; npm install"
        Pop-Location
        exit 1
    }

    Pop-Location
}

# -- 编译 TypeScript ----------------------------------------------------------
function Build-Project {
    Write-Step "编译 TypeScript"

    Push-Location $InstallDir

    # 清除 Electron 环境变量干扰（WorkBuddy 环境可能设置）
    $oldElectron = $env:ELECTRON_RUN_AS_NODE
    $oldNodeOpts = $env:NODE_OPTIONS
    $env:ELECTRON_RUN_AS_NODE = ""
    $env:NODE_OPTIONS = ""

    try {
        Write-Info "正在编译..."
        $output = npm run build 2>&1
        Write-OK "编译完成"
    } catch {
        Write-Err "编译失败: $_"
        Write-Info "手动编译: cd $InstallDir; `$env:ELECTRON_RUN_AS_NODE=''; npm run build"
        Pop-Location
        exit 1
    } finally {
        # 恢复原始环境变量
        $env:ELECTRON_RUN_AS_NODE = $oldElectron
        $env:NODE_OPTIONS = $oldNodeOpts
    }

    # 验证编译产物
    if (Test-Path "$InstallDir\dist\index.js") {
        Write-OK "验证通过: dist\index.js 已生成"
    } else {
        Write-Err "编译产物缺失: dist\index.js 不存在"
        Pop-Location
        exit 1
    }

    Pop-Location
}

# -- 检测 MCP 客户端平台 -----------------------------------------------------
function Detect-MCPPlatform {
    Write-Step "检测 MCP 客户端平台"

    $script:DetectedWB    = $false
    $script:DetectedCodex = $false

    # WorkBuddy: 检查目录或 mcp.json 是否存在
    $wbDir = "$env:USERPROFILE\.workbuddy"
    if (Test-Path $wbDir) {
        $script:DetectedWB = $true
        Write-OK "检测到 WorkBuddy ($wbDir)"
    }

    # Codex: 检查目录或二进制是否存在
    $codexDir = "$env:USERPROFILE\.codex"
    $codexBin = Get-Command codex -ErrorAction SilentlyContinue
    if ((Test-Path $codexDir) -or $codexBin) {
        $script:DetectedCodex = $true
        Write-OK "检测到 Codex"
    }

    if (-not $script:DetectedWB -and -not $script:DetectedCodex) {
        Write-Warn "未检测到 WorkBuddy 或 Codex，将输出通用 MCP 配置"
    }
}

# -- 生成 MCP 配置 ------------------------------------------------------------
function Generate-MCPConfig {
    Write-Step "生成 MCP 配置"

    $nodeExe = (Get-Command node).Source
    $distJs  = "$InstallDir\dist\index.js"

    # Windows 路径中使用双反斜杠转义
    $nodeExeEscaped = $nodeExe -replace '\\', '\\'
    $distJsEscaped  = $distJs -replace '\\', '\\'

    $configJson = @"
{
  "mcpServers": {
    "cloud-ip-rotator": {
      "command": "$nodeExeEscaped",
      "args": ["$distJsEscaped"]
    }
  }
}
"@

    # 写入通用配置文件（如已存在则跳过）
    $configDir  = "$env:USERPROFILE\.cloud-ip-rotator"
    $configPath = "$configDir\mcp-config.json"
    if (Test-Path $configPath) {
        Write-Info "MCP 配置文件已存在，跳过生成: $configPath"
    } else {
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        Set-Content -Path $configPath -Value $configJson -Encoding UTF8
        Write-OK "MCP 配置已生成: $configPath"
    }

    # 根据实际检测到的平台，给出针对性指引
    $shown = $false

    if ($script:DetectedWB) {
        Write-Host ""
        Write-Host "-- WorkBuddy 设置步骤 --" -ForegroundColor Cyan
        Write-Info "1. 将上方的 cloud-ip-rotator 配置合并到:"
        Write-Info "   $env:USERPROFILE\.workbuddy\mcp.json"
        Write-Info "2. 在 WorkBuddy 连接器管理页面点击「信任」cloud-ip-rotator"
        $shown = $true
    }

    if ($script:DetectedCodex) {
        Write-Host ""
        Write-Host "-- Codex 设置步骤 --" -ForegroundColor Cyan
        Write-Info "1. 将上方的 cloud-ip-rotator 配置合并到 Codex 的 MCP 配置文件"
        Write-Info "   常见路径: $env:USERPROFILE\.codex\mcp.json 或 Codex 设置面板"
        Write-Info "2. 重启 Codex 使配置生效"
        $shown = $true
    }

    if (-not $shown) {
        Write-Host ""
        Write-Info "未检测到兼容的 MCP 客户端。配置已保存，可手动导入到你的 MCP 客户端。"
    }
}

# -- 安装完成后提示 ----------------------------------------------------------
function Show-Success {
    if ($script:DetectedWB -and $script:DetectedCodex) {
        $mcpHint = "  # 通过 MCP 工具使用（在 WorkBuddy/Codex 中直接对话即可）"
    } elseif ($script:DetectedWB) {
        $mcpHint = "  # 通过 MCP 工具使用（在 WorkBuddy 中直接对话即可）"
    } elseif ($script:DetectedCodex) {
        $mcpHint = "  # 通过 MCP 工具使用（在 Codex 中直接对话即可）"
    } else {
        $mcpHint = "  # 配置 MCP 客户端后，即可通过对话使用以下指令"
    }

    $successBanner = @"

+============================================================+
|          cloud-ip-rotator-mcp 安装成功!                     |
+============================================================+

"@
    Write-Host $successBanner -ForegroundColor Green

    Write-Host "项目路径:   $InstallDir"
    Write-Host "配置目录:   $env:USERPROFILE\.cloud-ip-rotator\config.json"
    Write-Host "UI 服务器:  node $InstallDir\ui\server.cjs"
    Write-Host "UI 地址:    http://localhost:8787"
    Write-Host ""

    Write-Host "使用方式:" -ForegroundColor Yellow
    Write-Host "  # 启动 UI 配置服务器（可选）"
    Write-Host "  node $InstallDir\ui\server.cjs"
    Write-Host ""
    Write-Host "  # 浏览器打开配置页面"
    Write-Host "  start http://localhost:8787"
    Write-Host ""
    Write-Host $mcpHint
    Write-Host "  - 列出配置:   列出我的云服务器配置"
    Write-Host "  - 轮换 IP:    轮换所有配置好的服务器的IP"
    Write-Host "  - 添加配置:   我要添加一个 AWS 配置"
    Write-Host ""

    Write-Host "手动更新:" -ForegroundColor Yellow
    Write-Host "  cd $InstallDir; git pull; npm install; npm run build"
    Write-Host ""

    Write-Host "卸载:" -ForegroundColor Yellow
    Write-Host "  Remove-Item -Recurse -Force $InstallDir"
    Write-Host "  Remove-Item -Recurse -Force $env:USERPROFILE\.cloud-ip-rotator"
    Write-Host ""
}

# -- 主流程 ------------------------------------------------------------------
function Main {
    Write-Host ""
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host "|   cloud-ip-rotator-mcp 自动部署脚本 v1.0                    |" -ForegroundColor Green
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host ""

    Check-Node
    Check-Git
    Detect-MCPPlatform
    Clone-Repo
    Install-Deps
    if (-not $SkipBuild) {
        Build-Project
    }
    Generate-MCPConfig
    Show-Success

    Write-OK "部署完成!"
}

Main

