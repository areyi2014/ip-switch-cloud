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

# -- 检查 npm 环境 ------------------------------------------------------------
# 不依赖 IDE 捆绑的 node（版本目录会随升级变化，难以排查）。
# 仅两条路径: ① 系统 PATH 有 node+npm → 直接用系统的；
#            ② 否则从 nodejs.org 官方下载独立 Node.js 到固定目录
#               ~\.ip-switch-node\node（路径固定、可排查，不污染系统）。
# 选定结果统一记录到 $script:NodeExe / $script:NpmCli / $script:NpmCmd，
# 供 npm 执行与 MCP 配置共用。
function Check-Npm {
    Write-Step "检查 npm 环境"

    $node = Get-Command node -ErrorAction SilentlyContinue
    $npm  = Get-Command npm -ErrorAction SilentlyContinue
    if ($node -and $npm) {
        $script:NodeExe = $node.Source
        $script:NpmCmd  = $npm.Source
        Write-OK "使用系统 Node.js: $($node.Source)"
        return
    }

    Install-NpmFromOfficial
}

# -- 从 nodejs.org 官方下载独立 Node.js(含 npm) 到固定目录 ---------------------
function Install-NpmFromOfficial {
    Write-Warn "未找到系统 Node.js，正在从 nodejs.org 下载 Node.js 22 LTS..."
    $final = "$env:USERPROFILE\.ip-switch-node\node"

    # 解析最新 v22.x 版本号（失败时用固定 LTS 兜底）
    $ver = ""
    try { $ver = (Invoke-RestMethod "https://nodejs.org/dist/latest-v22.x/index.json" -TimeoutSec 30)[0].version } catch { }
    if (-not $ver) { $ver = "v22.14.0" }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $zipUrl = "https://nodejs.org/dist/$ver/node-$ver-win-$arch.zip"
    $zipPath = Join-Path $env:TEMP "node-$ver-win-$arch.zip"
    Write-Info "下载中: $zipUrl"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -TimeoutSec 300

    $tmp = "$env:USERPROFILE\.ip-switch-node\.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $tmp -Force

    # zip 解压出 node-<ver>-win-<arch>/ 子目录，统一固定为 node（路径稳定，便于排查）
    $dir = Get-ChildItem $tmp -Directory | Where-Object { Test-Path "$($_.FullName)\node.exe" } | Select-Object -First 1
    if (-not $dir) {
        Write-Err "下载解压失败，请手动安装 Node.js: https://nodejs.org"
        exit 1
    }
    if (Test-Path $final) { Remove-Item $final -Recurse -Force }
    Move-Item $dir.FullName $final

    $script:NodeExe = "$final\node.exe"
    $script:NpmCli  = "$final\node_modules\npm\bin\npm-cli.js"
    if (-not (Test-Path $script:NpmCli)) {
        Write-Err "npm 安装失败，请手动安装 Node.js: https://nodejs.org"
        exit 1
    }
    $npmVer = & $script:NodeExe $script:NpmCli --version 2>$null
    Write-OK "已安装 Node.js $ver (npm $npmVer) -> $final"
}

# -- 执行 npm 命令 -------------------------------------------------------------
# npm 本质是 node 运行的 JS 脚本(npm-cli.js)。官方下载的 node 不在系统 PATH，
# 而 npm run 在 Windows 上通过 cmd.exe 执行 node_modules/.bin/*.cmd（如 tsc.cmd），
# 这些 cmd 脚本从 PATH 查找 node —— 因此执行前把 node 目录临时置顶进程内 PATH
# （不改系统配置，退出即还原）。
function Invoke-Npm {
    param([Parameter(Mandatory = $true)][string]$SubCommand, [string[]]$ExtraArgs)
    if (-not $script:NpmCli -and -not $script:NpmCmd) { return $false }

    $oldPath = $env:Path
    $oldEAP  = $ErrorActionPreference
    try {
        if ($script:NpmCli) {
            $nodeDir = Split-Path $script:NodeExe -Parent
            if ($nodeDir -and $env:Path -notlike "*$nodeDir*") {
                $env:Path = "$nodeDir;$env:Path"
            }
            # EAP 临时放宽：native 命令写 stderr 在 EAP=Stop 下会抛 NativeCommandError，
            # 导致 build 失败时误报；统一以 $LASTEXITCODE 判断成败，错误文本由 npm 输出。
            $ErrorActionPreference = "Continue"
            & $script:NodeExe $script:NpmCli $SubCommand @ExtraArgs 2>&1 | Out-Host
            return ($LASTEXITCODE -eq 0)
        }
        if ($script:NpmCmd) {
            $ErrorActionPreference = "Continue"
            & $script:NpmCmd $SubCommand @ExtraArgs 2>&1 | Out-Host
            return ($LASTEXITCODE -eq 0)
        }
        return $false
    } finally {
        $env:Path = $oldPath
        $ErrorActionPreference = $oldEAP
    }
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
    if (Invoke-Npm -SubCommand "install" -ExtraArgs @("--loglevel=error")) {
        Write-OK "依赖安装完成"
    } else {
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
        if (-not (Invoke-Npm -SubCommand "run" -ExtraArgs @("build"))) { throw "npm run build 失败" }
        Write-OK "编译完成"
    } catch {
        Write-Err "编译失败: $_"
        $manualBuild = if ($script:NpmCli) { "& `"$($script:NodeExe)`" `"$($script:NpmCli)`" run build" } else { "npm run build" }
        Write-Info "手动编译: cd $installDir; `$env:ELECTRON_RUN_AS_NODE=''; $manualBuild"
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

    # 统一使用选定 Node.js（系统或官方下载，均非 IDE 捆绑、路径固定可排查）
    $defaultNode = (Get-Command node -ErrorAction SilentlyContinue).Source
    $nodeExe     = if ($script:NodeExe) { $script:NodeExe } else { $defaultNode }
    $distJs  = "$installDir\dist\index.js"

    # Windows 路径在 JSON 中需将反斜杠转义为 \\（仅用于终端提示展示）
    $nodeExeEscaped = $nodeExe.Replace('\', '\\')
    $distJsEscaped  = $distJs.Replace('\', '\\')

    $configJson = @"
{
  "mcpServers": {
    "ip-switch": {
      "command": "$nodeExeEscaped",
      "args": ["$distJsEscaped"]
    }
  }
}
"@

    $written = $false

    # 直接写入对应平台的 mcp.json（统一使用选定 Node.js）
    if ($script:DetectedWB) {
        $wbDir = "$env:USERPROFILE\.workbuddy"
        if (-not (Test-Path $wbDir)) {
            New-Item -ItemType Directory -Path $wbDir -Force | Out-Null
        }
        Write-MCPConfig -PlatformDir $wbDir -NodeExe $nodeExe -DistJs $distJs
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



# -- 生成 Codex MCP 直连配置（installDir\.mcp.json） ---------------------------
#   ① 探测/校验 Node.js（优先 $script:NodeExe，回退 PATH 中的 node）
#   ② 校验编译产物 installDir\dist\index.js 存在
#   ③ 生成 installDir\.mcp.json（全路径写法，覆盖仓库自带的 command:"node" 脆弱版本）
# 并把最终选定的 node / dist 路径写入脚本级变量供 Install-CodexToml 复用。
function Install-CodexMcp {
    Write-Step "生成 Codex MCP 直连配置（.mcp.json）"

    $distJs    = "$installDir\dist\index.js"
    $codexNode = if ($script:NodeExe) { $script:NodeExe } else { (Get-Command node -ErrorAction SilentlyContinue).Source }
    if (-not $codexNode) {
        Write-Err "未找到 Node.js，无法生成 Codex MCP 配置"
        exit 1
    }

    # 1. 校验编译产物存在
    if (-not (Test-Path $distJs)) {
        Write-Err "缺少编译产物 $distJs，请先编译（或去掉 -SkipBuild）"
        exit 1
    }

    # 2. 生成 installDir\.mcp.json（全路径写法，覆盖仓库自带的 command:"node" 脆弱版本）
    $nodeEsc = $codexNode.Replace('\', '\\')
    $distEsc = $distJs.Replace('\', '\\')
    $cwdEsc  = $installDir.Replace('\', '\\')
    $mcpJson = @"
{
  "mcpServers": {
    "ip-switch": {
      "command": "$nodeEsc",
      "args": ["$distEsc"],
      "cwd": "$cwdEsc",
      "startup_timeout_sec": 30,
      "tool_timeout_sec": 300
    }
  }
}
"@
    $dotMcp = "$installDir\.mcp.json"
    [System.IO.File]::WriteAllText($dotMcp, $mcpJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "已生成 MCP 配置: $dotMcp"

    # 3. 输出供后续 TOML 配置层复用（脚本级变量，跨函数可见）
    $script:CodexMcpDist = $distJs
    $script:CodexMcpNode = $codexNode

    # 4. 验证
    $dotMcp = "$installDir\.mcp.json"
    if (Test-Path $dotMcp) {
        Write-OK "Codex MCP 直连配置已就绪: $dotMcp"
        Write-Info "重启 Codex 后生效（插件页发现由市场负责）"
    } else {
        Write-Err "MCP 配置生成失败，请检查 $dotMcp"
        exit 1
    }
}

# -- 确保 Codex 用户级 config.toml 注册本地市场、插件与 ip-switch MCP（全局可见） ----------
#   • model 由 CC Switch 管理 → 不写用户级 config.toml（会被改写）
#   • marketplaces / plugins 不由 CC Switch 管理（SSOT 无对应表）→ 写用户级安全，
#     且只有写在这里，桌面版 Codex 在「任意工作区」打开时才能发现 ip-switch。
#   • [mcp_servers.ip-switch] 虽属 CC Switch 管理的 A 档（重启会按 SSOT 重生成），
#     但本函数用脚本已解析好的 node/dist 路径【幂等追加】该段：
#       - 若 CC Switch 正在运行并已写入该段 → Contains 命中 → 跳过（不重复，避免 TOML 重复表）
#       - 若 CC Switch 未运行 → 用户级 config.toml 无此段 → 脚本补写，ip-switch 在 MCP 列表可见
#     这样「用户级注册」不再依赖 CC Switch 是否在跑。
#   项目级 .codex/config.toml 里的同名声明是工作区作用域，普通打开 Codex 时不加载。
# 仅检测缺失项并追加，不做任何备份/恢复操作（避免风险）。
function Ensure-CodexUserConfig {
    param(
        [Parameter(Mandatory = $true)][string]$CodexConfig
    )
    if (-not (Test-Path $CodexConfig)) {
        Write-Warning "未找到 $CodexConfig，跳过市场/插件/MCP 注册（首次运行 codex 后会自动创建）"
        return
    }

    $marketDir = "$env:USERPROFILE\.codex\marketplaces\local"
    $content = [System.IO.File]::ReadAllText($CodexConfig)
    $appended = @()

    if (-not $content.Contains('[marketplaces.local]')) {
        $appended += "[marketplaces.local]`nsource_type = `"local`"`nsource = '$marketDir'`n"
    }
    if (-not $content.Contains('[plugins."ip-switch@local"]')) {
        $appended += "[plugins.`"ip-switch@local`"`]`nenabled = true`n"
    }
    # 幂等追加 [mcp_servers.ip-switch]：用脚本已解析的 node/dist 路径，CC Switch 未跑也能注册
    if (-not $content.Contains('[mcp_servers.ip-switch]')) {
        $mcpNode = $script:CodexMcpNode
        $mcpDist = $script:CodexMcpDist
        $mcpCwd  = $script:installDir
        if ($mcpNode -and $mcpDist -and $mcpCwd) {
            $appended += "[mcp_servers.ip-switch]`ncommand = '$mcpNode'`nargs = ['$mcpDist']`ncwd = '$mcpCwd'`nstartup_timeout_sec = 30`nenabled = true`n"
        } else {
            Write-Warning "缺少 Node/dist 路径（install 前置步骤未完成），跳过用户级 [mcp_servers.ip-switch] 注册"
        }
    }

    if ($appended.Count -eq 0) {
        Write-Info "ip-switch 市场、插件与 MCP 已在用户级 config.toml 中，跳过"
        return
    }

    [System.IO.File]::AppendAllText($CodexConfig, "`n" + ($appended -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "已注册 ip-switch 市场、插件与 mcp_servers 到用户级 config.toml（全局可见；mcp 段由脚本写入，不再依赖 CC Switch）"
}

# -- 安装 Codex TOML 配置层（项目级 + 叠加层配置） --------------------------
# 职责：
#   ② 生成 installDir\.codex\config.toml（项目级配置层 —— 桌面版的主要加载通道）
#      —— 桌面版 codex app 通过 codex:// 协议拉起，-c 参数传不进桌面进程，工作区内项目级 .codex/config.toml
#         首次以该目录为工作区启动时 Codex 会自动信任（写入 [projects] 表，见codex_app.vbs），
#         信任后本文件的 mcp_servers / marketplaces / plugins 全部生效
#   ③ 生成 ~/.codex/ip-switch.config.toml（叠加层配置，CLI 专用）
#      —— 用于 codex --profile ip-switch CLI 命令（mcp list / exec / review 等），会自动搜索ip-switch.config.toml
# 注：②③两份配置互为镜像；均独立于 config.toml，CC Switch 不影响。
function Install-CodexToml {
    Write-Step "安装 Codex TOML 配置层（项目级配置 + 叠加层配置）"

    # 1. 取 Install-CodexMcp 的输出（该函数在主流程先于本函数执行）
    $distJs    = $script:CodexMcpDist
    $codexNode = $script:CodexMcpNode

    # 2. 生成项目级配置层（installDir\.codex\config.toml）—— 桌面版的主要加载通道
    #     桌面版 codex app 无法接收 -c 覆盖（协议拉起时参数丢失），
    #    注意codex_app.vbs 已改为以 installDir 为工作区启动，且启动自动信任。
    $codexDir = "$env:USERPROFILE\.codex"
    $projectCodexDir = "$installDir\.codex"
    $marketDir = "$codexDir\marketplaces\local"
    New-Item -ItemType Directory -Path $projectCodexDir -Force | Out-Null
    $projectConfigFile = "$projectCodexDir\config.toml"

    # 公共配置主体的模板 —— 项目级配置层与 Profile 叠加层的内容完全一致（互为镜像），
    # 仅文件位置、加载时机与用途不同：
    #   ① 项目级配置层（installDir\.codex\config.toml）→ 桌面版加载通道
    #   ② Profile 叠加层（~/.codex/ip-switch.config.toml）→ CLI --profile 加载通道
    # 统一维护这一份模板，避免两份配置内容漂移；TOML 中表顺序无关紧要。
    $ipSwitchConfigBody = @"

[marketplaces.local]
source_type = "local"
source = '$marketDir'

[plugins."ip-switch@local"]
enabled = true
"@

    # 2.1 内容与 Profile 叠加层相同，共用 $ipSwitchConfigBody（见上方模板说明）。
    $projectConfigContent = @"
# ip-switch project-scoped config — layered on top of ~/.codex/config.toml
# Independent of user config.toml (CC Switch safe).
# Loaded by Codex when this workspace is opened and trusted.
$ipSwitchConfigBody
"@
    [System.IO.File]::WriteAllText($projectConfigFile, $projectConfigContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "已生成项目级配置层: $projectConfigFile"
    Write-Info "桌面版 Codex 以本目录为工作区启动时自动加载（首次启动自动信任）"

    # 2.2. 创建 Codex Profile 叠加层（~/.codex/ip-switch.config.toml）
    #    用途：codex --profile ip-switch CLI 命令（mcp list / exec / review 等）
    #    注意：codex app 子命令不支持 --profile；桌面版走上面的项目级配置层
    #    内容与项目级配置层相同，共用 $ipSwitchConfigBody（见上方模板说明）。
    New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
    $profileFile = "$codexDir\ip-switch.config.toml"
    $profileContent = @"
# ip-switch Profile — 独立于 config.toml 的叠加层
# CC Switch 只管 config.toml，此文件不受影响
# 用途：codex --profile ip-switch CLI 命令（mcp list / exec / review 等）
# 注意：codex app 子命令不支持 --profile；桌面版走工作区内 .codex/config.toml 项目级配
$ipSwitchConfigBody
"@
    [System.IO.File]::WriteAllText($profileFile, $profileContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "已创建 Codex Profile 叠加层: $profileFile"
    Write-Info "CC Switch 篡改 config.toml 不再影响 ip-switch（独立叠加层）"

    # 2.3. 全局注册本地市场与插件到用户级 config.toml：
    #      仅此处注册后，桌面版 Codex 在任意工作区打开都能发现 ip-switch（CC Switch 不管理该表，安全）
    Write-Step "安装 Codex TOML 配置层（用户层配置）"
    Ensure-CodexUserConfig -CodexConfig "$codexDir\config.toml"


}

# -- 创建桌面快捷方式 ----------------------------------------------------------
# 从 Install-CodexToml 拆出的独立函数：
#   ① 复制 codex_app.vbs 启动脚本（wscript 静默运行，无控制台窗口）
#   ② 复制 codex.ico 图标文件
#   ③ 创建桌面快捷方式：wscript.exe + codex_app.vbs，以 ip-switch 目录为工作区启动 codex app
function Install-CodexShotcut {
    Write-Step "创建Codex桌面快捷方式"

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
}

# -- 安装 Codex 插件市场（marketplace），使插件页/市场中可发现 ip-switch ------
function Install-CodexMarketplace {
    Write-Step "安装 Codex 插件市场（ip-switch）"
    $codexRoot = "$env:USERPROFILE\.codex"
    $marketDir = "$codexRoot\marketplaces\local"
    $marketPluginDir = "$marketDir\plugins\ip-switch\.codex-plugin"

    # 1. 市场清单 marketplace.json（参考 Codex 自带 openai-bundled 格式）
    $marketJson = @"
{
  "name": "local",
  "interface": {
    "displayName": "Local Marketplace"
  },
  "plugins": [
    {
      "name": "ip-switch",
      "source": {
        "source": "local",
        "path": "./plugins/ip-switch"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Developer Tools"
    }
  ]
}
"@

    # 2. 市场内插件清单 plugin.json（mcpServers 指向源码 .mcp.json 绝对路径）
    $mcpRef = "$installDir\.mcp.json".Replace('\', '\\')
    $pluginJson = @"
{
  "name": "ip-switch",
  "version": "1.0.0",
  "description": "Multi-cloud public IP switch MCP server with Cloudflare DNS auto-update",
  "author": {
    "name": "areyi2014",
    "url": "https://github.com/areyi2014/ip-switch"
  },
  "homepage": "https://github.com/areyi2014/ip-switch",
  "repository": "https://github.com/areyi2014/ip-switch.git",
  "license": "MIT",
  "keywords": [
    "mcp",
    "ip-switch",
    "cloud",
    "aws",
    "azure",
    "oci",
    "vultr",
    "cloudflare",
    "dns"
  ],
  "mcpServers": "$mcpRef",
  "interface": {
    "displayName": "IP Switch",
    "shortDescription": "Multi-cloud IP switch & DNS update",
    "longDescription": "Switch the public IP of cloud instances across AWS / Azure / Oracle OCI / Vultr and automatically update Cloudflare DNS A records. Exposes 13 MCP tools for one-click IP rotation, instance management, and DNS sync.",
    "developerName": "areyi2014",
    "category": "Developer Tools",
    "capabilities": [
      "Cloud",
      "Network"
    ],
    "websiteURL": "https://github.com/areyi2014/ip-switch",
    "defaultPrompt": [
      "Use IP Switch to rotate the public IP of a cloud instance and update its Cloudflare DNS record.",
      "Use IP Switch to query instance info or list instances in a cloud region."
    ]
  }
}
"@

    New-Item -ItemType Directory -Path "$marketDir\.agents\plugins" -Force | Out-Null
    New-Item -ItemType Directory -Path $marketPluginDir -Force | Out-Null
    [System.IO.File]::WriteAllText("$marketDir\.agents\plugins\marketplace.json", $marketJson, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText("$marketPluginDir\plugin.json", $pluginJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "已写入市场清单: $marketDir\.agents\plugins\marketplace.json"
    Write-OK "已写入插件清单: $marketPluginDir\plugin.json"

    # 3. 市场注册已移至 Profile 叠加层（~/.codex/ip-switch.config.toml）
    #    不再写 config.toml，避免 CC Switch 篡改导致丢失
    Write-OK "市场注册已在 Profile 叠加层中配置（ip-switch.config.toml）"

    # 5. 验证
    if ((Test-Path "$marketDir\.agents\plugins\marketplace.json") -and (Test-Path "$marketPluginDir\plugin.json")) {
        Write-OK "Codex 插件市场已安装: $marketDir"
        Write-Info "重启 Codex 后，插件页/市场中可见 IP Switch"
    } else {
        Write-Err "插件市场安装不完整，请检查 $marketDir"
        exit 1
    }
}

# -- 重启客户端应用（WorkBuddy/Codex），使 MCP 配置立即生效 -------------------
function Restart-ClientApp {
    param(
        [string]$AppName,
        [string[]]$ProcessNames,
        [string[]]$PathKeywords = @(),
        [string]$LaunchExe = "",
        [string[]]$LaunchArgs = @()
    )

    # 1) 先按进程名匹配（常见名，如 codex / ChatGPT / WorkBuddy / CodeBuddy）
    $proc = $null
    foreach ($name in $ProcessNames) {
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) { break }
    }

    # 2) 进程名没匹配上时，按可执行文件路径关键字兜底（路径比进程名稳定）
    if (-not $proc -and $PathKeywords.Count -gt 0) {
        foreach ($kw in $PathKeywords) {
            $proc = Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and $_.Path -like "*$kw*" } |
                Select-Object -First 1
            if ($proc) { break }
        }
    }

    # 3) 启动子进程时重定向 stdout/stderr 到临时文件，屏蔽 Electron 调试日志
    $logOut = Join-Path $env:TEMP "ip-switch-$AppName-out.log"
    $logErr = Join-Path $env:TEMP "ip-switch-$AppName-err.log"
    Remove-Item $logOut, $logErr -Force -ErrorAction SilentlyContinue

    if ($proc) {
        $exePath = $proc.Path
        Write-Info "检测到 $AppName 正在运行，正在重启..."
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        # 优先用原进程路径重启，其次用指定启动命令
        # -WindowStyle Hidden: 防止启动控制台程序（如 codex.exe CLI）时闪现黑色弹窗
        if ($exePath -and (Test-Path $exePath)) {
            try {
                Start-Process -FilePath $exePath -WindowStyle Hidden `
                    -RedirectStandardOutput $logOut -RedirectStandardError $logErr `
                    -ErrorAction Stop | Out-Null
                Write-OK "$AppName 已重新启动"
                return
            } catch { }
        }
        if ($LaunchExe) {
            try {
                Start-Process -FilePath $LaunchExe -ArgumentList $LaunchArgs -WindowStyle Hidden `
                    -RedirectStandardOutput $logOut -RedirectStandardError $logErr `
                    -ErrorAction Stop | Out-Null
                Write-OK "$AppName 已重新启动"
                return
            } catch { }
        }
        Write-Warn "$AppName 进程已关闭，但自动重启失败，请手动打开"
    } else {
        # 原进程未在运行 → 不做任何启动操作，保持现状
        Write-Info "$AppName 未在运行，跳过重启（如需使用请手动打开）"
    }
}

# -- 安装完成后提示 ----------------------------------------------------------
function Show-Success {
    # 自动重启客户端，使 MCP 配置立即生效
    Write-Host ""
    Write-Host "重启客户端:" -ForegroundColor Yellow
    if ($script:DetectedWB) {
        # 进程名常见候选 + 路径关键字兜底（路径含 .workbuddy / CodeBuddy / WorkBuddy）
        Restart-ClientApp -AppName "WorkBuddy" `
            -ProcessNames @("WorkBuddy", "CodeBuddy") `
            -PathKeywords @("\.workbuddy\", "CodeBuddy", "WorkBuddy")
    }
    if ($script:DetectedCodex) {
        $vbsPath = "$installDir\codex_app.vbs"
        # 桌面版进程名可能是 codex / Codex / ChatGPT（Windows 商店包 exe 名），
        # 兜底按路径含 OpenAI.Codex / OpenAI\Codex 匹配
        if (Test-Path $vbsPath) {
            # 通过 codex_app.vbs 启动，可同时拉起 ip-switch 服务
            Restart-ClientApp -AppName "Codex" `
                -ProcessNames @("codex", "Codex", "ChatGPT") `
                -PathKeywords @("OpenAI.Codex", "OpenAI\Codex") `
                -LaunchExe "$env:SystemRoot\System32\wscript.exe" -LaunchArgs @("`"$vbsPath`"")
        } else {
            Restart-ClientApp -AppName "Codex" `
                -ProcessNames @("codex", "Codex", "ChatGPT") `
                -PathKeywords @("OpenAI.Codex", "OpenAI\Codex") `
                -LaunchExe "codex" -LaunchArgs @("app")
        }
    }

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
|          ip-switch 安装成功!                                |
+============================================================+

"@
    Write-Host $successBanner -ForegroundColor Green

    # 按实际安装的平台显示路径（WorkBuddy 无插件目录，只有 mcp.json）
    $wbConfig       = "$env:USERPROFILE\.workbuddy\mcp.json"
    $codexMarketDir = "$env:USERPROFILE\.codex\marketplaces\local"

    if ($script:DetectedWB) {
        Write-Host "WorkBuddy MCP 配置: $wbConfig"
    }
    if ($script:DetectedCodex) {
        Write-Host "Codex 市场清单:     $codexMarketDir"
        Write-Host "Codex 项目级配置:   $env:USERPROFILE\ip-switch\.codex\config.toml（桌面版加载通道）"
    }
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
    if ($script:DetectedWB) {
        Write-Host "  Remove-Item -Force $wbConfig          # 删除 WorkBuddy MCP 配置"
    }
    if ($script:DetectedCodex) {
        $profileFile = "$env:USERPROFILE\.codex\ip-switch.config.toml"
        $projectCfg  = "$installDir\.codex"
        Write-Host "  Remove-Item -Force $profileFile        # 删除 Codex Profile 叠加层"
        Write-Host "  Remove-Item -Recurse -Force $projectCfg       # 删除项目级配置层"
        Write-Host "  Remove-Item -Recurse -Force $codexMarketDir  # 删除 Codex 市场清单"
    }
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

    Check-Npm
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
        Install-CodexMcp
        Install-CodexToml
        Install-CodexShotcut
        Install-CodexMarketplace
    }
    Show-Success

    Write-OK "部署完成!"
}

Main

