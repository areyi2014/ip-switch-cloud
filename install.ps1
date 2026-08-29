#===============================================================================
# ip-switch 自动部署脚本 (Windows PowerShell)
#===============================================================================
# 用途: 一键克隆、安装依赖、编译、生成 workbuddy 配置、生成 codex 配置[创建桌面图标]
# 适用: Windows 10/11 (PowerShell 5.1+)
# 前提: git 已安装, Node.js >= 18 已安装
#===============================================================================
param(
    [string]$RepoUrl    = "https://gitee.com/areyi2014/ip-switch.git",
    [string]$Branch     = "main",
    [string]$installDir = "$env:USERPROFILE\ip-switch",
    [switch]$SkipBuild  = $false,
    [switch]$Help       = $false
)

if ($Help) {
    Write-Host @"
用法: .\install.ps1 [选项]

选项:
  -RepoUrl URL     指定仓库地址（默认 gitee）
  -Branch NAME     指定分支（默认 main）
  -installDir DIR  指定安装目录（默认 ~\ip-switch）
  -SkipBuild       跳过编译步骤
  -Help            显示帮助

示例:
  .\install.ps1
  .\install.ps1 -RepoUrl "https://gitee.com/areyi2014/ip-switch.git"
  .\install.ps1 -installDir "D:\my-tools\ip-switch"
"@
    exit 0
}

$ErrorActionPreference = "Stop"
$NodeMinVersion = 18
$ProjectName = "ip-switch"

# -- 辅助函数 ---------------------------------------------------------------
function Write-Step($msg) {
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}

function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Blue }
function Write-OK($msg)    { Write-Host "[ OK ]  $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# -- 查找 WorkBuddy/CodeBuddy 自带 Node.js -------------------------------------
function Get-WorkBuddyNodeExe {
    # 优先使用 CodeBuddy 注入的环境变量（运行时自动指向最新版本）
    if ($env:CODEBUDDY_NODE_BIN -and (Test-Path $env:CODEBUDDY_NODE_BIN)) {
        return $env:CODEBUDDY_NODE_BIN
    }

    # 兜底: 扫描 ~/.workbuddy/binaries/node/versions/<版本>/node.exe
    $versionsDir = "$env:USERPROFILE\.workbuddy\binaries\node\versions"
    if (-not (Test-Path $versionsDir)) { return $null }

    # 按修改时间取最新版本目录
    $versions = Get-ChildItem -Path $versionsDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    foreach ($v in $versions) {
        $nodeExe = Join-Path $v.FullName "node.exe"
        if (Test-Path $nodeExe) { return $nodeExe }
    }
    return $null
}

# -- 查找 Codex 自带 Node.js --------------------------------------------------
function Get-CodexNodeExe {
    $cacheRoot = "$env:USERPROFILE\.cache\codex-runtimes"
    if (-not (Test-Path $cacheRoot)) { return $null }

    # 优先 codex-primary-runtime，其次其他 runtime
    $primary = "$cacheRoot\codex-primary-runtime\dependencies\node\bin\node.exe"
    if (Test-Path $primary) { return $primary }

    $others = Get-ChildItem -Path $cacheRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'codex-primary-runtime' } |
        ForEach-Object { "$($_.FullName)\dependencies\node\bin\node.exe" } |
        Where-Object { Test-Path $_ }

    if ($others.Count -gt 0) { return $others[0] }
    return $null
}

# -- 检测系统上所有可用的 Node.js ---------------------------------------------
function Get-AllNodeExes {
    $nodes = @()

    # 1. WorkBuddy 自带
    $wb = Get-WorkBuddyNodeExe
    if ($wb) {
        $nodes += [pscustomobject]@{
            Source = "WorkBuddy 自带"
            Path   = $wb
        }
    }

    # 2. Codex 自带
    $codex = Get-CodexNodeExe
    if ($codex) {
        $nodes += [pscustomobject]@{
            Source = "Codex 自带"
            Path   = $codex
        }
    }

    # 3. 系统 PATH 中的 node
    $sys = Get-Command node -ErrorAction SilentlyContinue
    if ($sys -and $sys.Source) {
        $nodes += [pscustomobject]@{
            Source = "系统 PATH"
            Path   = $sys.Source
        }
    }

    # 去重（同一路径可能被多种来源命中）
    $seen = @{}
    $result = @()
    foreach ($n in $nodes) {
        $key = $n.Path.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $n
        }
    }
    return $result
}

# -- 检查 Node.js ------------------------------------------------------------
function Check-Node {
    Write-Step "检查 Node.js 环境"

    # 检测系统上所有可用的 Node.js（WorkBuddy / Codex 自带 + 系统 PATH 安装的）
    $allNodes = @(Get-AllNodeExes)

    if ($allNodes.Count -eq 0) {
        Write-Err "未检测到任何 Node.js，请先安装 Node.js >= $NodeMinVersion"
        Write-Info "访问 https://nodejs.org 进行下载安装/卸载重装"
        Write-Info "推荐安装 Node.js 22 LTS 版本"
        exit 1
    }

    Write-Host ""
    Write-Info "检测到以下 Node.js 环境:"
    $nodeIndex = 0
    $maxNode = $null
    $maxVersion = [version]"0.0.0"
    foreach ($n in $allNodes) {
        $nodeIndex++
        $ver = ""
        try { $ver = (& $n.Path -v).Trim() } catch { $ver = "" }
        $ver = $ver.TrimStart('v')
        if (-not $ver) {
            Write-Host ("  [{0}] {1,-16} 版本未知" -f $nodeIndex, $n.Source) -ForegroundColor Gray
            Write-Host ("      {0}" -f $n.Path) -ForegroundColor DarkGray
            continue
        }
        Write-Host ("  [{0}] {1,-16} v{2}" -f $nodeIndex, $n.Source, $ver) -ForegroundColor Gray
        Write-Host ("      {0}" -f $n.Path) -ForegroundColor DarkGray

        try {
            $v = [version]$ver
            if ($v -gt $maxVersion) {
                $maxVersion = $v
                $maxNode = $n
            }
        } catch { }
    }
    Write-Host ""

    # 记录 WorkBuddy / Codex 自带 node（供生成 MCP 配置时按平台选用）
    $script:WBNodeExe = ($allNodes | Where-Object { $_.Source -eq "WorkBuddy 自带" } | Select-Object -First 1).Path
    $script:CodexNodeExe = ($allNodes | Where-Object { $_.Source -eq "Codex 自带" } | Select-Object -First 1).Path

    # 默认使用"版本号最大"的 Node.js
    $nodeExe = $maxNode.Path
    $nodeBinDir = Split-Path $nodeExe -Parent
    if ($env:PATH -notlike "*$nodeBinDir*") {
        $env:PATH = "$nodeBinDir;$env:PATH"
    }

    $nodeVersion = & $nodeExe -v
    $major = [int]($nodeVersion -replace 'v', '').Split('.')[0]

    if ($major -lt $NodeMinVersion) {
        Write-Err "Node.js 版本过低: $nodeVersion，需要 >= v$NodeMinVersion"
        Write-Info "可尝试改用列表中其他版本的 Node.js，或升级当前版本"
        exit 1
    }

    Write-OK "使用 Node.js $nodeVersion ($nodeExe)"
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

    if (Test-Path "$installDir\.git") {
        Write-Warn "目标目录已存在，执行 git pull 更新..."
        Push-Location $installDir
        git fetch origin $Branch
        git checkout $Branch
        git pull origin $Branch
        Pop-Location
        Write-OK "项目已更新: $installDir"
        return
    }

    Write-Info "仓库地址: $RepoUrl"
    Write-Info "目标分支: $Branch"
    Write-Info "安装目录: $installDir"
    Write-Host ""
    $userInput = Read-Host "确认安装到此目录? 按 Enter 确认，或输入新目录路径"
    if ($userInput) {
        $installDir = $userInput
        # 更新全局变量，后续步骤使用新路径
        $script:installDir = $installDir
        Write-Info "已更新安装目录: $installDir"
    }

    $parentDir = Split-Path $installDir -Parent
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
            Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info "第 $attempt / $maxRetries 次重试克隆..."
            Start-Sleep -Seconds 3
        } else {
            Write-Info "正在克隆: $RepoUrl (分支: $Branch)"
        }

        # 直接用 Start-Process，git 进度条会自动输出到终端
        $proc = Start-Process -FilePath "git" `
            -ArgumentList "clone", "--branch", $Branch, "--depth", "1", $RepoUrl, $installDir `
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
        Write-Info "  git clone $RepoUrl $installDir"
        exit 1
    }
    Write-OK "克隆成功: $installDir"
}

# -- 安装依赖 ----------------------------------------------------------------
function Install-Deps {
    Write-Step "安装 npm 依赖"

    Push-Location $installDir

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
        Write-Info "尝试清除缓存后重试: cd $installDir; Remove-Item -Recurse -Force node_modules; npm install"
        Pop-Location
        exit 1
    }

    Pop-Location
}

# -- 编译 TypeScript ----------------------------------------------------------
function Build-Project {
    Write-Step "编译 TypeScript"

    Push-Location $installDir

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
        Write-Info "手动编译: cd $installDir; `$env:ELECTRON_RUN_AS_NODE=''; npm run build"
        Pop-Location
        exit 1
    } finally {
        # 恢复原始环境变量
        $env:ELECTRON_RUN_AS_NODE = $oldElectron
        $env:NODE_OPTIONS = $oldNodeOpts
    }

    # 验证编译产物
    if (Test-Path "$installDir\dist\index.js") {
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
        Write-OK "检测到 Codex ($codexDir)"
    }

    if (-not $script:DetectedWB -and -not $script:DetectedCodex) {
        Write-Warn "未检测到 WorkBuddy 或 Codex，将输出通用 MCP 配置"
    }
}

# -- 写入 MCP 配置（合并到已有配置，由 node 序列化为标准 JSON）------------------------------------------------------------
function Write-MCPConfig {
    param([string]$PlatformDir, [string]$NodeExe, [string]$DistJs)

    $targetPath = "$PlatformDir\mcp.json"

    # 合并 + 序列化全部交给 node：保证输出标准 JSON（2 空格缩进、路径正确转义），
    # 不依赖 PowerShell 5.1 ConvertTo-Json 的错位缩进格式
    $nodeScript = @'
const fs = require('fs');
const target = process.argv[1];
const entry = {
  command: process.argv[2],
  args: [process.argv[3]]
};
let config = {};
try {
  if (fs.existsSync(target)) {
    config = JSON.parse(fs.readFileSync(target, 'utf8'));
  }
} catch (e) {
  config = {};
}
config.mcpServers = config.mcpServers || {};
config.mcpServers['ip-switch'] = entry;
fs.writeFileSync(target, JSON.stringify(config, null, 2) + '\n', 'utf8');
'@

    & $NodeExe -e $nodeScript $targetPath $NodeExe $DistJs
    if ($LASTEXITCODE -ne 0) {
        Write-Err "写入 MCP 配置失败: $targetPath"
        exit 1
    }
}

# -- 生成 Workbuddy 配置 ------------------------------------------------------------
function Generate-WbConfig {
    Write-Step "生成 Workbuddy 配置"

    # 各平台优先使用其自带 Node.js（用户可能只装了 IDE，没有独立 Node）
    $defaultNode = (Get-Command node).Source
    $wbNodeExe    = if ($script:WBNodeExe)    { $script:WBNodeExe }    else { $defaultNode }
    $codexNodeExe = if ($script:CodexNodeExe) { $script:CodexNodeExe } else { $defaultNode }
    $distJs  = "$installDir\dist\index.js"

    # Windows 路径在 JSON 中需将反斜杠转义为 \\（仅用于终端提示展示）
    $wbNodeExeEscaped = $wbNodeExe.Replace('\', '\\')
    $distJsEscaped  = $distJs.Replace('\', '\\')

    $configJson = @"
{
  "mcpServers": {
    "ip-switch": {
      "command": "$wbNodeExeEscaped",
      "args": ["$distJsEscaped"]
    }
  }
}
"@

    $written = $false

    # 直接写入对应平台的 mcp.json（各自优先用自带 Node.js）
    if ($script:DetectedWB) {
        $wbDir = "$env:USERPROFILE\.workbuddy"
        if (-not (Test-Path $wbDir)) {
            New-Item -ItemType Directory -Path $wbDir -Force | Out-Null
        }
        Write-MCPConfig -PlatformDir $wbDir -NodeExe $wbNodeExe -DistJs $distJs
        Write-OK "已写入 MCP 配置: $wbDir\mcp.json"
        Write-Info "WorkBuddy 连接器管理页面点击「信任」ip-switch 即可使用"
        $written = $true
    }

    if (-not $written) {
        Write-Warn "未检测到 WorkBuddy 或 Codex 平台目录"
        Write-Host ""
        Write-Host "MCP 配置内容:" -ForegroundColor Cyan
        Write-Host $configJson
        Write-Host ""
        Write-Info "请将以上配置手动添加到对应客户端的 mcp.json 文件中"
    }
}



# -- 安装 Codex 插件（仅清单，MCP 直接运行源码 dist） --------------------------
function Install-CodexPlugin {
    Write-Step "安装 Codex 插件（仅清单，MCP 直接运行源码 dist）"

    # 1. 校验源码编译产物与插件清单
    if (-not (Test-Path "$installDir\dist\index.js")) {
        Write-Err "缺少编译产物 $installDir\dist\index.js，请先编译（或去掉 -SkipBuild）"
        exit 1
    }
    if (-not (Test-Path "$installDir\.codex-plugin\plugin.json")) {
        Write-Err "缺少插件清单 $installDir\.codex-plugin\plugin.json，项目结构异常"
        exit 1
    }
    if (-not (Test-Path "$installDir\.mcp.json")) {
        Write-Err "缺少 MCP 配置 $installDir\.mcp.json，项目结构异常"
        exit 1
    }

    # 2. 清理旧目标，避免残留旧文件
    $targetDir = "$env:USERPROFILE\.codex\plugins\ip-switch"
    New-Item -ItemType Directory -Path "$env:USERPROFILE\.codex\plugins" -Force | Out-Null
    if (Test-Path $targetDir) {
        Write-Info "目标目录已存在，执行整体替换: $targetDir"
        Remove-Item $targetDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

    # 3. 只复制插件清单（MCP server 直接运行源码 dist，插件目录保持轻量）
    Write-Info "复制插件清单 .codex-plugin ..."
    Copy-Item -Recurse -Force "$installDir\.codex-plugin" "$targetDir\.codex-plugin"

    # 4. 改写 plugin.json，mcpServers 指向源码 .mcp.json（绝对路径）
    $pluginJsonPath = "$targetDir\.codex-plugin\plugin.json"
    $raw = Get-Content -Raw -Path $pluginJsonPath
    $mcpRef = "$installDir\.mcp.json".Replace('\', '\\')
    $newRaw = $raw -replace '"mcpServers"\s*:\s*"[^"]*"', ('"mcpServers": "' + $mcpRef + '"')
    [System.IO.File]::WriteAllText($pluginJsonPath, $newRaw, (New-Object System.Text.UTF8Encoding($false)))

    # 5. 写入/更新 Codex config.toml 的 [mcp_servers.ip-switch]（缺失则添加，已有则指向源码）
#     $configFile = "$env:USERPROFILE\.codex\config.toml"
#     New-Item -ItemType Directory -Path "$env:USERPROFILE\.codex" -Force | Out-Null
#     $content = ""
#     if (Test-Path $configFile) {
#         $content = [System.IO.File]::ReadAllText($configFile)
#     }
#     $mcpCmd = "$installDir\dist\index.js"
#     $mcpCwd = $installDir
#     if ($content -match '(?m)^\[mcp_servers\.ip-switch\]') {
#         Write-Info "config.toml 已含 [mcp_servers.ip-switch]，更新 command/cwd 指向源码..."
#         $segStart = $content.IndexOf("[mcp_servers.ip-switch]")
#         $segEnd = $content.IndexOf("`n[", $segStart)
#         if ($segEnd -lt 0) { $segEnd = $content.Length }
#         $seg = $content.Substring($segStart, $segEnd - $segStart)
#         $seg = $seg -replace '(?m)^command = .*$', "command = '$mcpCmd'"
#         $seg = $seg -replace '(?m)^cwd = .*$', "cwd = '$mcpCwd'"
#         $content = $content.Substring(0, $segStart) + $seg + $content.Substring($segEnd)
#     } else {
#         Write-Info "config.toml 缺少 [mcp_servers.ip-switch]，追加配置..."
#         $block = @"

# [mcp_servers.ip-switch]
# args = []
# command = '$mcpCmd'
# startup_timeout_sec = 30
# cwd = '$mcpCwd'
# enabled = true
# "@
#         if ($content.Trim().Length -eq 0) {
#             $content = $block.TrimStart() + "`n"
#         } else {
#             $content = $content.TrimEnd() + "`n`n" + $block.TrimStart() + "`n"
#         }
#     }
#     [System.IO.File]::WriteAllText($configFile, $content, (New-Object System.Text.UTF8Encoding($false)))
#     Write-OK "已写入 MCP 配置: $configFile"

    # 6. 创建桌面快捷方式
    Write-Host '正在创建Codex快捷方式...' -ForegroundColor Green

    $shortcutName = 'Codex with ip-switch'
    $shortcutPath = [System.Environment]::GetFolderPath('Desktop') + '\\' + $shortcutName + '.lnk'
    $wscriptExe = "$env:SystemRoot\System32\wscript.exe"
    $vbsPath = "$installDir\codex_app.vbs"

    # 复制启动脚本
    if (Test-Path '.\codex_app.vbs') {
        Copy-Item '.\codex_app.vbs' -Destination $vbsPath -Force
        Write-Host "✓ 已复制codex_app.vbs到 $vbsPath" -ForegroundColor Green
    } elseif (-not (Test-Path $vbsPath)) {
        Write-Host "警告: 安装目录下未找到codex_app.vbs文件" -ForegroundColor Yellow
    }

    # 复制图标文件
    $iconPath = "$installDir\codex.ico"
    if (Test-Path '.\codex.ico') {
        Copy-Item '.\codex.ico' -Destination $iconPath -Force
        Write-Host "✓ 已复制codex.ico到 $iconPath" -ForegroundColor Green
    } elseif (-not (Test-Path $iconPath)) {
        Write-Host "警告: 未找到codex.ico图标文件，将使用默认图标" -ForegroundColor Yellow
    }

    # 创建快捷方式
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $wscriptExe
    $shortcut.Arguments = '"' + $vbsPath + '"'
    $shortcut.Description = '启动 Codex 并自动加载 ip-switch MCP 服务'
    $shortcut.WorkingDirectory = $installDir
    if (Test-Path $iconPath) {
        $shortcut.IconLocation = "$iconPath,0"
    }
    $shortcut.Save()

    Write-Host "✓ 已创建桌面快捷方式: $shortcutPath" -ForegroundColor Green

    # 验证
    if (Test-Path "$targetDir\.codex-plugin\plugin.json") {
        Write-OK "插件已安装: $targetDir"
        Write-Info "MCP 配置指向: $installDir\.mcp.json"
        Write-Info "重启 Codex 后插件生效"
    } else {
        Write-Err "插件安装不完整，请检查 $targetDir"
        exit 1
    }
}

# -- 安装完成后提示 ----------------------------------------------------------
function Show-Success {
    $targetDir = "$env:USERPROFILE\.codex\plugins\ip-switch"

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
|          ip-switch 安装成功!                     |
+============================================================+

"@
    Write-Host $successBanner -ForegroundColor Green

    Write-Host "插件安装路径: $targetDir"
    Write-Host "UI 服务器:  node $installDir\ui\server.cjs"
    Write-Host "UI 地址:    启动后终端会显示实际地址"
    Write-Host ""

    Write-Host "使用方式:" -ForegroundColor Yellow
    Write-Host "  # 启动 UI 配置服务器（可选）"
    Write-Host "  node $installDir\ui\server.cjs"
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
    Write-Host "  cd $installDir; git pull; npm install; npm run build"
    Write-Host ""

    Write-Host "卸载:" -ForegroundColor Yellow
    Write-Host "  Remove-Item -Recurse -Force $targetDir   # 删除插件清单"
    Write-Host "  Remove-Item -Recurse -Force $installDir  # 如需同时删除源码"
    Write-Host ""
}

# -- 主流程 ------------------------------------------------------------------
function Main {
    Write-Host ""
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host "|   ip-switch 自动部署脚本 v1.0                               |" -ForegroundColor Green
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
    if ($script:DetectedWB) {
        Generate-WbConfig
    }
    if ($script:DetectedCodex) {
        Install-CodexPlugin
    }
    Show-Success

    Write-OK "部署完成!"
}

Main

