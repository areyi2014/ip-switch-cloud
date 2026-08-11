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
        Write-Info "访问 https://nodejs.org 进行下载安装/卸载重装"
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
    Write-Step "检查 Git 环境"

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        Write-OK "git $(& git --version) ($($gitCmd.Source))"
        return
    }

    Write-Warn "未检测到 git，正在自动安装..."

    # ── 获取 CPU 架构 ──────────────────────────────────────────────
    $arch = $env:PROCESSOR_ARCHITECTURE.ToLower()
    if ($arch -eq 'amd64') { $arch = 'x64' }
    Write-Info "检测到 CPU 架构: $arch"

    # ── 方案 1：已有 Git 但不在 PATH ──────────────────────────────
    $gitDir = "$env:LOCALAPPDATA\Git"
    $gitExe = "$gitDir\cmd\git.exe"
    $gitBin = "$gitDir\bin\git.exe"

    # 先检查常见 Git 安装位置
    $knownPaths = @(
        "$gitDir\cmd\git.exe",
        "$gitDir\bin\git.exe",
        "$env:ProgramFiles\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe"
    )
    foreach ($kp in $knownPaths) {
        if (Test-Path $kp) {
            $foundDir = Split-Path $kp -Parent
            Write-Info "检测到已有 Git: $foundDir，修复 PATH..."
            $env:Path = "$foundDir;$env:Path"
            Write-OK "git $(& git --version) ($kp)"
            return
        }
    }

    # ── 方案 2：下载并静默安装 ────────────────────────────────────
    $installerPath = Download-GitInstaller -Arch $arch
    if (-not $installerPath) {
        Write-Err "Git 下载失败，请手动安装: https://git-scm.com/download/win"
        exit 1
    }

    Write-Info "静默安装 Git 到 $gitDir ..."
    $proc = Start-Process -FilePath $installerPath `
        -ArgumentList "/VERYSILENT", "/NORESTART", "/CURRENTUSER", "/DIR=$gitDir", "/NOICONS" `
        -NoNewWindow -Wait -PassThru
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) {
        Write-Err "Git 安装失败 (exit code: $($proc.ExitCode))"
        Write-Info "请手动安装: https://git-scm.com/download/win"
        exit 1
    }

    # 加入 PATH
    Add-GitToPath $gitDir
    $env:Path = "$gitDir\cmd;$env:Path"
    if (Test-Path "$gitDir\bin\git.exe") {
        $env:Path = "$gitDir\bin;$env:Path"
    }
    Write-OK "git 安装完成: $(& $gitExe --version)"
}

# ── 下载 Git 安装包（Invoke-WebRequest，纯 PowerShell 无 .NET 依赖）──
function Download-GitInstaller {
    param([string]$Arch)

    $urls = Get-GitDownloadUrls -Arch $Arch
    if (-not $urls -or $urls.Count -eq 0) {
        return $null
    }

    $installerPath = "$env:TEMP\git-installer-$Arch.exe"
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    foreach ($url in $urls) {
        $shortUrl = if ($url.Length -gt 80) { $url.Substring(0, 80) + "..." } else { $url }
        Write-Info "尝试下载: $shortUrl"

        try {
            # Invoke-WebRequest 是 PowerShell 原生 cmdlet，不依赖外部 .NET
            # -UserAgent 必须设置，部分镜像站（如 TUNA）拒绝默认 UA
            Invoke-WebRequest -Uri $url -OutFile $installerPath `
                -UseBasicParsing -TimeoutSec 600 -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

            if (-not (Test-Path $installerPath)) {
                Write-Warn "  下载后文件不存在，尝试下一个源..."
                continue
            }

            $fileSize = (Get-Item $installerPath).Length
            if ($fileSize -lt 50MB) {
                Write-Warn "  文件过小 ($([math]::Round($fileSize/1MB, 1)) MB)，可能不完整，尝试下一个源..."
                Remove-Item $installerPath -Force
                continue
            }

            Write-Info "  下载完成: $([math]::Round($fileSize / 1MB, 1)) MB"
            return $installerPath

        } catch {
            Write-Warn "  下载失败: $_"
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            continue
        }
    }

    return $null
}

# 将 Git 目录加入用户 PATH（无弹窗）
function Add-GitToPath {
    param([string]$GitDir)
    $pathsToAdd = @()
    foreach ($sub in @("cmd", "bin")) {
        $p = "$GitDir\$sub"
        if (Test-Path "$p\git.exe") { $pathsToAdd += $p }
    }

    if ($pathsToAdd.Count -eq 0) { return }

    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $changed = $false
    foreach ($p in $pathsToAdd) {
        if ($userPath -notlike "*$p*") {
            $userPath += ";$p"
            $changed = $true
        }
    }
    if ($changed) {
        [System.Environment]::SetEnvironmentVariable("Path", $userPath, "User")
    }
}

# 从 GitHub API 获取官方最新版本号，构建下载 URL 列表
# 接口: https://api.github.com/repos/git-for-windows/git/releases/latest
# 官方文件名格式: Git-{version}-64-bit.exe / Git-{version}-arm64.exe
function Get-GitDownloadUrls {
    param([string]$Arch)

    # ── 通过 GitHub API 获取最新版本号 ────────────────────────────
    $apiUrl = "https://api.github.com/repos/git-for-windows/git/releases/latest"
    $tag = $null
    Write-Info "查询 Git for Windows 最新版本..."

    try {
        $release = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 15 -ErrorAction Stop
        $tag = $release.tag_name
        Write-Info "  官方最新版本: $tag"
    } catch {
        Write-Warn "  无法获取最新版本信息，使用内置版本"
        $tag = "v2.55.0.windows.3"
    }

    # 版本号格式: tag=v2.55.0.windows.3 → 文件名用 2.55.0.3（去掉 .windows.）
    $ver = $tag -replace '^v', ''                          # "2.55.0.windows.3"
    $fileVer = $ver -replace '\.windows\.', '.'             # "2.55.0.3"

    # 架构后缀: Git-2.55.0.3-64-bit.exe / Git-2.55.0.3-arm64.exe
    $suffix = if ($Arch -eq 'arm64') { "arm64" } else { "64-bit" }
    $filename = "Git-$fileVer-$suffix.exe"                  # 正确的文件名

    Write-Info "  安装包文件名: $filename"

    # 下载源（优先级从高到低，国内镜像优先）
    return @(
        # 源 1：NPMMirror CDN（国内最快，直接走 CDN 不做重定向）
        "https://cdn.npmmirror.com/binaries/git-for-windows/$tag/$filename",

        # 源 2：NPMMirror Registry（自动重定向到 CDN）
        "https://registry.npmmirror.com/-/binary/git-for-windows/$tag/$filename",

        # 源 3：清华大学 TUNA 镜像
        "https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/LatestRelease/$filename",

        # 源 4：GitHub 官方（兜底）
        "https://github.com/git-for-windows/git/releases/download/$tag/$filename"
    )
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

    Write-Info "仓库地址: $RepoUrl"
    Write-Info "目标分支: $Branch"
    Write-Info "安装目录: $InstallDir"
    Write-Host ""
    $userInput = Read-Host "确认安装到此目录? 按 Enter 确认，或输入新目录路径"
    if ($userInput) {
        $InstallDir = $userInput
        # 更新全局变量，后续步骤使用新路径
        $script:InstallDir = $InstallDir
        Write-Info "已更新安装目录: $InstallDir"
    }

    $parentDir = Split-Path $InstallDir -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # DNS 预热
    $repoHost = ([uri]$RepoUrl).Host
    Write-Info "预热 DNS: ping $repoHost ..."
    $null = & ping -n 1 $repoHost 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "无法解析仓库域名: $repoHost"
        Write-Info "请检查网络连接和 DNS 设置"
        exit 1
    }
    Write-OK "域名连通: $repoHost"

    # 最多重试 3 次克隆
    $maxRetries = 3
    $cloneOk = $false

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        if ($attempt -gt 1) {
            # 清理上次失败残留
            Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info "第 $attempt / $maxRetries 次重试克隆..."
            Start-Sleep -Seconds 3
        } else {
            Write-Info "正在克隆: $RepoUrl (分支: $Branch)"
        }

        # 直接用 Start-Process，git 进度条会自动输出到终端
        $proc = Start-Process -FilePath "git" `
            -ArgumentList "clone", "--branch", $Branch, "--depth", "1", $RepoUrl, $InstallDir `
            -NoNewWindow -Wait -PassThru

        if ($proc.ExitCode -eq 0) {
            $cloneOk = $true
            break
        }

        Write-Warn "克隆失败 (第 $attempt / $maxRetries 次)"
    }

    if (-not $cloneOk) {
        Write-Host ""
        Write-Err "克隆失败（已重试 $maxRetries 次）"
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
    Write-Host "UI 地址:    启动后终端会显示实际地址"
    Write-Host ""

    Write-Host "使用方式:" -ForegroundColor Yellow
    Write-Host "  # 启动 UI 配置服务器（可选）"
    Write-Host "  node $InstallDir\ui\server.cjs"
    Write-Host ""
    Write-Host "  # 浏览器打开配置页面（地址见服务器启动输出）"
    Write-Host "  start http://127.0.0.1:端口号"
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

