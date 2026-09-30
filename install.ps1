#===============================================================================
# ip-switch automated deployment script (Windows PowerShell)
# Chinese version: install-zh.ps1
#===============================================================================
# Purpose: one-click clone, install dependencies, build, generate the WorkBuddy config, generate the Codex config [create a desktop shortcut]
# Applies to: Windows 10/11 (PowerShell 5.1+)
# Prerequisites: git installed, Node.js >= 18 installed
#===============================================================================
param(
    [string]$RepoUrl    = "https://gitee.com/areyi2014/ip-switch-cloud.git",
    [string]$Branch     = "main",
    [string]$installDir = "$env:USERPROFILE\ip-switch",
    # Client selection: "" = interactive selection at runtime; "all" = every supported
    # client; "0" (or "n") = source build only (skip client integration); or a comma
    # list, e.g. "workbuddy,codex".
    [string]$Clients    = "",
    [switch]$SkipBuild  = $false,
    [switch]$Help       = $false
)

if ($Help) {
    Write-Host @"
Usage: .\install.ps1 [options]

Options:
  -RepoUrl URL     Repository URL (default: gitee)
  -Branch NAME     Branch name (default: main)
  -installDir DIR  Install directory (default: ~\ip-switch)
  -Clients LIST    Clients to install into: workbuddy,codex,all,0 (=n)
                   (default: interactive selection of the detected clients)
  -SkipBuild       Skip the build step
  -Help            Show help

Environment:
  IP_SWITCH_TELEMETRY=0        Disable install statistics
  IP_SWITCH_TELEMETRY_URL=URL  Override the statistics endpoint

Interactive prompts:
  Client selection  [Enter=all detected / 1 / 2 / 0=source only / q=quit]
                    0 = source build only (no client integration)
                    1 = WorkBuddy only, 2 = Codex only
                    Enter = every client detected on this machine
                    (1,2 / a / all still work: they force both, even the undetected one)
                    n / no / q / quit / cancel abort the whole install (nothing is written)
  Install directory Enter = use the suggested directory, q = quit, or type another path

Examples:
  .\install.ps1
  .\install.ps1 -RepoUrl "https://gitee.com/areyi2014/ip-switch.git"
  .\install.ps1 -installDir "D:\my-tools\ip-switch"
"@
    exit 0
}

$ErrorActionPreference = "Stop"
$NodeMinVersion = 18
$ProjectName = "ip-switch"

# -- Install statistics (opt-out) --------------------------------------------
# Reports at most 4 events (start / success / cancel / fail) to a Cloudflare Worker,
# which stores them in Workers Analytics Engine. The event includes the client IP (the
# endpoint records it from cf-connecting-ip, for abuse detection), the OS, the script
# version and a locally generated random GUID device id. No username, hostname, file
# path or credential is ever sent.
# Disable with IP_SWITCH_TELEMETRY=0; override the endpoint with IP_SWITCH_TELEMETRY_URL.
# Reporting is best effort: it never blocks for longer than 3s and never changes the
# exit code, so a dead endpoint can never break an install.
$script:ScriptVersion  = "1.0"
$script:ScriptLang     = "en"
$script:TelemetryOn    = -not ($env:IP_SWITCH_TELEMETRY -eq '0')
$script:TelemetryUrl   = if ($env:IP_SWITCH_TELEMETRY_URL) { $env:IP_SWITCH_TELEMETRY_URL } else { 'https://t.ipswitch.cloud/i' }
$script:Stage          = 'precheck'
$script:TelemetryArmed = $false
$script:TelemetrySent  = $false
$script:T0             = Get-Date
# Initialised here because the "start" event fires before the client selection runs,
# and Send-Telemetry reads them unconditionally.
$script:SelWB    = $false
$script:SelCodex = $false

# -- Helper functions --------------------------------------------------------
function Write-Step($msg) {
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}

function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Blue }
function Write-OK($msg)    { Write-Host "[ OK ]  $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# -- Install statistics ------------------------------------------------------
# Device id: a random GUID generated once and kept locally, used only to tell a new
# machine apart from a reinstall. It is not derived from any hardware or user data.
function Get-DeviceId {
    $dir = Join-Path $env:LOCALAPPDATA 'ip-switch'
    $f   = Join-Path $dir 'device-id'
    if (-not (Test-Path $f)) {
        try {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            (New-Guid).Guid | Set-Content -Path $f -NoNewline -Encoding ASCII
        } catch { }
    }
    try { return (Get-Content -Raw $f).Trim() } catch { return '' }
}

# $Event = start|success|cancel|fail; $Stage is only used by "fail".
# The TLS line matters on Windows PowerShell 5.1, which may still default to TLS 1.0
# and Cloudflare only accepts TLS 1.2+. Everything is swallowed on purpose.
function Send-Telemetry($Event, $Stage = '') {
    if (-not $script:TelemetryOn) { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $cl = @()
        if ($script:SelWB)    { $cl += 'wb' }
        if ($script:SelCodex) { $cl += 'codex' }
        $body = @{
            e       = $Event
            v       = $script:ScriptVersion
            os      = 'windows'
            ps      = 'ps1'
            l       = $script:ScriptLang
            clients = ($cl -join ',')
            stage   = $Stage
            d       = (Get-DeviceId)
            dur     = [int]((Get-Date) - $script:T0).TotalSeconds
            day     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri $script:TelemetryUrl -Method Post -ContentType 'application/json' `
            -Body $body -TimeoutSec 3 -ErrorAction Stop | Out-Null
    } catch { }
}

# -- Interactive abort handling -------------------------------------------------
# "n" / "no" / "q" / "quit" / "cancel" / "exit" always mean "abort the whole install".
# Rationale: "n" reads as "no" to any human, so it must never be silently interpreted
# as "no clients, install the source anyway" (that is what "0" is for at the prompt).
# Both call sites run before anything is cloned or written, so aborting is always safe.
function Test-CancelInput($text) {
    return ($text -match '^(n|no|q|quit|cancel|exit)$')
}

function Stop-Cancelled {
    Write-Host ""
    Write-Info "Cancelled: nothing was cloned and no files were written"
    if ($script:TelemetryArmed) { Send-Telemetry 'cancel'; $script:TelemetrySent = $true }
    exit 0
}

# -- Check the npm environment -------------------------------------------------
# Does not depend on the IDE-bundled node (its version directory changes on upgrades, making issues hard to trace).
# Only two paths: (1) system PATH has node+npm -> use the system one directly;
#            (2) otherwise download a standalone Node.js from nodejs.org into a fixed directory
#               ~\.nodejs\node (fixed path, easy to trace, does not pollute the system).
# The selection is recorded in $script:NodeExe / $script:NpmCli / $script:NpmCmd,
# shared by npm execution and the MCP configuration.
function Check-Npm {
    Write-Step "Checking the npm environment"

    $node = Get-Command node -ErrorAction SilentlyContinue
    $npm  = Get-Command npm -ErrorAction SilentlyContinue
    if ($node -and $npm) {
        $script:NodeExe = $node.Source
        $script:NpmCmd  = $npm.Source
        Write-OK "Using system Node.js: $($node.Source)"
        return
    }

    Install-NpmFromOfficial
}

# -- Download a standalone Node.js (with npm) from nodejs.org into a fixed directory -----
function Install-NpmFromOfficial {
    Write-Warn "System Node.js not found; downloading Node.js 22 LTS from nodejs.org..."
    $final = "$env:USERPROFILE\.nodejs\node"

    # Reuse first: if a complete install (with npm) already exists, use it directly; no re-download/delete.
    # Otherwise deletion fails while the MCP process holds node.exe, and repeated reinstalls are pointless.
    if ((Test-Path "$final\node.exe") -and (Test-Path "$final\node_modules\npm\bin\npm-cli.js")) {
        Write-Info "Existing Node.js detected, reusing: $final"
        $script:NodeExe = "$final\node.exe"
        $script:NpmCli  = "$final\node_modules\npm\bin\npm-cli.js"
        return
    }

    # Clean up temp extraction dirs possibly left by an interrupted run (ignore if locked; retry next time)
    $tmp = "$env:USERPROFILE\.nodejs\.tmp"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    # Resolve the latest v22.x version (fall back to a fixed LTS on failure)
    $ver = ""
    try { $ver = (Invoke-RestMethod "https://nodejs.org/dist/latest-v22.x/index.json" -TimeoutSec 30)[0].version } catch { }
    if (-not $ver) { $ver = "v22.14.0" }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $zipUrl = "https://nodejs.org/dist/$ver/node-$ver-win-$arch.zip"
    $zipPath = Join-Path $env:TEMP "node-$ver-win-$arch.zip"
    Write-Info "Downloading: $zipUrl"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -TimeoutSec 300
    Expand-Archive -Path $zipPath -DestinationPath $tmp -Force

    # The zip extracts a node-<ver>-win-<arch>/ subfolder; normalize it to node (stable path, easy to trace)
    $dir = Get-ChildItem $tmp -Directory | Where-Object { Test-Path "$($_.FullName)\node.exe" } | Select-Object -First 1
    if (-not $dir) {
        Write-Err "Download/extract failed; install Node.js manually: https://nodejs.org"
        exit 1
    }

    # If the old directory exists and is locked by MCP it cannot be deleted -- fail with a clear message instead of silently
    if (Test-Path $final) {
        Remove-Item $final -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $final) {
            Write-Err "Old install directory is locked and cannot be replaced: $final"
            Write-Info "Exit the Codex / WorkBuddy ip-switch MCP (or kill the process holding node.exe) first, then retry."
            Write-Info "The installed version keeps working; no functional impact."
            exit 1
        }
    }
    Move-Item $dir.FullName $final

    $script:NodeExe = "$final\node.exe"
    $script:NpmCli  = "$final\node_modules\npm\bin\npm-cli.js"
    if (-not (Test-Path $script:NpmCli)) {
        Write-Err "npm installation failed; install Node.js manually: https://nodejs.org"
        exit 1
    }
    # Clean up the temp extraction directory
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    $npmVer = & $script:NodeExe $script:NpmCli --version 2>$null
    Write-OK "Installed Node.js $ver (npm $npmVer) -> $final"
}

# -- Run npm commands -----------------------------------------------------------
# npm is essentially a JS script run by node (npm-cli.js). The downloaded node is not on the system PATH,
# and on Windows `npm run` executes node_modules/.bin/*.cmd (e.g. tsc.cmd) via cmd.exe,
# and those cmd scripts locate node via PATH -- so prepend the node dir to the process-local PATH before running
# (no system changes; restored when the process exits).
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
            # Temporary EAP relaxation: native commands writing to stderr throw NativeCommandError under EAP=Stop,
            # causing false failures during build; success is judged by $LASTEXITCODE, error text comes from npm output.
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

# -- Check git ----------------------------------------------------------------
function Check-Git {
    Write-Step "Checking the Git environment"

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        Write-OK "git $(& git --version) ($($gitCmd.Source))"
        return
    }

    Write-Warn "git not detected; installing automatically..."

    # -- Determine CPU architecture ------------------------------------------------
    $arch = $env:PROCESSOR_ARCHITECTURE.ToLower()
    if ($arch -eq 'amd64') { $arch = 'x64' }
    Write-Info "Detected CPU architecture: $arch"

    # -- Option 1: Git already installed but not on PATH ---------------------------
    $gitDir = "$env:LOCALAPPDATA\Git"
    $gitExe = "$gitDir\cmd\git.exe"
    $gitBin = "$gitDir\bin\git.exe"

    # Check common Git install locations first
    $knownPaths = @(
        "$gitDir\cmd\git.exe",
        "$gitDir\bin\git.exe",
        "$env:ProgramFiles\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe"
    )
    foreach ($kp in $knownPaths) {
        if (Test-Path $kp) {
            $foundDir = Split-Path $kp -Parent
            Write-Info "Existing Git detected: $foundDir; repairing PATH..."
            $env:Path = "$foundDir;$env:Path"
            Write-OK "git $(& git --version) ($kp)"
            return
        }
    }

    # -- Option 2: download and install silently -----------------------------------
    $installerPath = Download-GitInstaller -Arch $arch
    if (-not $installerPath) {
        Write-Err "Git download failed; install manually: https://git-scm.com/download/win"
        exit 1
    }

    Write-Info "Silently installing Git into $gitDir ..."
    $proc = Start-Process -FilePath $installerPath `
        -ArgumentList "/VERYSILENT", "/NORESTART", "/CURRENTUSER", "/DIR=$gitDir", "/NOICONS" `
        -NoNewWindow -Wait -PassThru
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) {
        Write-Err "Git installation failed (exit code: $($proc.ExitCode))"
        Write-Info "Install manually: https://git-scm.com/download/win"
        exit 1
    }

    # Add to PATH
    Add-GitToPath $gitDir
    $env:Path = "$gitDir\cmd;$env:Path"
    if (Test-Path "$gitDir\bin\git.exe") {
        $env:Path = "$gitDir\bin;$env:Path"
    }
    Write-OK "git installed: $(& $gitExe --version)"
}

# -- Download the Git installer (Invoke-WebRequest, pure PowerShell, no .NET dependency) --
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
        Write-Info "Trying download: $shortUrl"

        try {
            # Invoke-WebRequest is a native PowerShell cmdlet with no external .NET dependency
            # -UserAgent is required: some mirrors (e.g. TUNA) reject the default UA
            Invoke-WebRequest -Uri $url -OutFile $installerPath `
                -UseBasicParsing -TimeoutSec 600 -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

            if (-not (Test-Path $installerPath)) {
                Write-Warn "  File missing after download; trying the next source..."
                continue
            }

            $fileSize = (Get-Item $installerPath).Length
            if ($fileSize -lt 50MB) {
                Write-Warn "  File too small ($([math]::Round($fileSize/1MB, 1)) MB), possibly incomplete; trying the next source..."
                Remove-Item $installerPath -Force
                continue
            }

            Write-Info "  Download complete: $([math]::Round($fileSize / 1MB, 1)) MB"
            return $installerPath

        } catch {
            Write-Warn "  Download failed: $_"
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            continue
        }
    }

    return $null
}

# Add the Git directory to the user PATH (no popups)
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

# Fetch the latest official version from the GitHub API and build the download URL list
# API: https://api.github.com/repos/git-for-windows/git/releases/latest
# Official file name format: Git-{version}-64-bit.exe / Git-{version}-arm64.exe
function Get-GitDownloadUrls {
    param([string]$Arch)

    # -- Get the latest version via the GitHub API ----------------------------------
    $apiUrl = "https://api.github.com/repos/git-for-windows/git/releases/latest"
    $tag = $null
    Write-Info "Querying the latest Git for Windows version..."

    try {
        $release = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 15 -ErrorAction Stop
        $tag = $release.tag_name
        Write-Info "  Latest official version: $tag"
    } catch {
        Write-Warn "  Could not fetch the latest version; using the built-in one"
        $tag = "v2.55.0.windows.3"
    }

    # Version format: tag=v2.55.0.windows.3 -> the file name uses 2.55.0.3 (strip ".windows.")
    $ver = $tag -replace '^v', ''                          # "2.55.0.windows.3"
    $fileVer = $ver -replace '\.windows\.', '.'             # "2.55.0.3"

    # Architecture suffix: Git-2.55.0.3-64-bit.exe / Git-2.55.0.3-arm64.exe
    $suffix = if ($Arch -eq 'arm64') { "arm64" } else { "64-bit" }
    $filename = "Git-$fileVer-$suffix.exe"                  # correct file name

    Write-Info "  Installer file name: $filename"

    # Download sources (priority high to low, CN mirrors first)
    return @(
        # Source 1: NPMMirror CDN (fastest in CN, direct CDN, no redirect)
        "https://cdn.npmmirror.com/binaries/git-for-windows/$tag/$filename",

        # Source 2: NPMMirror Registry (auto-redirects to the CDN)
        "https://registry.npmmirror.com/-/binary/git-for-windows/$tag/$filename",

        # Source 3: Tsinghua TUNA mirror
        "https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/LatestRelease/$filename",

        # Source 4: GitHub official (fallback)
        "https://github.com/git-for-windows/git/releases/download/$tag/$filename"
    )
}

# -- Clone the repository ------------------------------------------------------
function Clone-Repo {
    Write-Step "Cloning the project repository"

    if (Test-Path "$installDir\.git") {
        Write-Warn "Target directory exists; running git pull to update..."
        Push-Location $installDir
        git fetch origin $Branch
        git checkout $Branch
        git pull origin $Branch
        Pop-Location
        Write-OK "Project updated: $installDir"
        return
    }

    Write-Info "Repository URL: $RepoUrl"
    Write-Info "Target branch: $Branch"
    Write-Info "Install directory: $installDir"
    Write-Host ""
    $rawDir = Read-Host "Install to this directory? [Enter=confirm / q=quit / or type a new path]"
    if ($null -eq $rawDir) {
        Write-Err "No input available (EOF); aborting the install"
        exit 1
    }
    $userInput = $rawDir.Trim()
    if (Test-CancelInput $userInput) { Stop-Cancelled }
    if ($userInput) {
        $installDir = $userInput
        # Update the global variable; later steps use the new path
        $script:installDir = $installDir
        Write-Info "Install directory updated: $installDir"
    }

    $parentDir = Split-Path $installDir -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # DNS warm-up
    $repoHost = ([uri]$RepoUrl).Host
    Write-Info "Warming up DNS: ping $repoHost ..."
    $null = & ping -n 1 $repoHost 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Cannot resolve the repository host: $repoHost"
        Write-Info "Check your network connection and DNS settings"
        exit 1
    }
    Write-OK "Host reachable: $repoHost"

    # Retry the clone up to 3 times
    $maxRetries = 3
    $cloneOk = $false

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        if ($attempt -gt 1) {
            # Clean up leftovers from the previous failed attempt
            Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info "Retry clone attempt $attempt / $maxRetries..."
            Start-Sleep -Seconds 3
        } else {
            Write-Info "Cloning: $RepoUrl (branch: $Branch)"
        }

        # Use Start-Process directly; git's progress bar streams to the terminal
        $proc = Start-Process -FilePath "git" `
            -ArgumentList "clone", "--branch", $Branch, "--depth", "1", $RepoUrl, $installDir `
            -NoNewWindow -Wait -PassThru

        if ($proc.ExitCode -eq 0) {
            $cloneOk = $true
            break
        }

        Write-Warn "Clone failed (attempt $attempt / $maxRetries)"
    }

    if (-not $cloneOk) {
        Write-Host ""
        Write-Err "Clone failed (retried $maxRetries times)"
        Write-Info ""
        Write-Info "Please check:"
        Write-Info "  1. The repository URL is correct: $RepoUrl"
        Write-Info "  2. Your network connection"
        Write-Info "  3. For a private repo, configure an SSH key first"
        Write-Info ""
        Write-Info "Manual steps:"
        Write-Info "  git clone $RepoUrl $installDir"
        exit 1
    }
    Write-OK "Clone succeeded: $installDir"
}

# -- Install dependencies ------------------------------------------------------
function Install-Deps {
    Write-Step "Installing npm dependencies"

    Push-Location $installDir

    if (-not (Test-Path package.json)) {
        Write-Err "package.json not found; unexpected project layout"
        Pop-Location
        exit 1
    }

    Write-Info "Installing dependencies, please wait..."
    if (Invoke-Npm -SubCommand "install" -ExtraArgs @("--loglevel=error")) {
        Write-OK "Dependencies installed"
    } else {
        Write-Err "Dependency installation failed"
        Write-Info "Try clearing the cache and retrying: cd $installDir; Remove-Item -Recurse -Force node_modules; npm install"
        Pop-Location
        exit 1
    }

    Pop-Location
}

# -- Build TypeScript -----------------------------------------------------------
function Build-Project {
    Write-Step "Building TypeScript"

    Push-Location $installDir

    # Clear Electron env interference (may be set by the WorkBuddy environment)
    $oldElectron = $env:ELECTRON_RUN_AS_NODE
    $oldNodeOpts = $env:NODE_OPTIONS
    $env:ELECTRON_RUN_AS_NODE = ""
    $env:NODE_OPTIONS = ""

    try {
        Write-Info "Building..."
        if (-not (Invoke-Npm -SubCommand "run" -ExtraArgs @("build"))) { throw "npm run build failed" }
        Write-OK "Build completed"
    } catch {
        Write-Err "Build failed: $_"
        $manualBuild = if ($script:NpmCli) { "& `"$($script:NodeExe)`" `"$($script:NpmCli)`" run build" } else { "npm run build" }
        Write-Info "Manual build: cd $installDir; `$env:ELECTRON_RUN_AS_NODE=''; $manualBuild"
        Pop-Location
        exit 1
    } finally {
        # Restore the original environment variable
        $env:ELECTRON_RUN_AS_NODE = $oldElectron
        $env:NODE_OPTIONS = $oldNodeOpts
    }

    # Verify the build output
    if (Test-Path "$installDir\dist\index.js") {
        Write-OK "Verified: dist\index.js generated"
    } else {
        Write-Err "Build output missing: dist\index.js does not exist"
        Pop-Location
        exit 1
    }

    Pop-Location
}

# -- Detect MCP client platforms -----------------------------------------------
function Detect-MCPPlatform {
    Write-Step "Detecting MCP client platforms"

    $script:DetectedWB    = $false
    $script:DetectedCodex = $false

    # WorkBuddy: check for the directory or mcp.json
    $wbDir = "$env:USERPROFILE\.workbuddy"
    if (Test-Path $wbDir) {
        $script:DetectedWB = $true
        Write-OK "WorkBuddy detected ($wbDir)"
    }

    # Codex: check for the directory or binary
    $codexDir = "$env:USERPROFILE\.codex"
    $codexBin = Get-Command codex -ErrorAction SilentlyContinue
    if ((Test-Path $codexDir) -or $codexBin) {
        $script:DetectedCodex = $true
        Write-OK "Codex detected ($codexDir)"
    }

    if (-not $script:DetectedWB -and -not $script:DetectedCodex) {
        Write-Warn "Neither WorkBuddy nor Codex detected; printing a generic MCP config"
    }
}

# -- Let the user choose which clients to install into -------------------------------
# Selection priority: -Clients argument > interactive prompt (Enter = all detected clients).
# Non-interactive callers without -Clients fall back to the detected clients as well.
# Results are stored in $script:SelWB / $script:SelCodex; only the selected clients
# get MCP configs, skills, marketplace manifests, etc. Detection alone no longer installs.
function Select-Clients {
    Write-Step "Selecting target clients"

    if ($Clients) {
        $script:SelWB    = $false
        $script:SelCodex = $false
        $normalized = $Clients.ToLower()
        if ($normalized -eq 'all') {
            $script:SelWB    = $true
            $script:SelCodex = $true
        } else {
            foreach ($c in ($normalized -split ',')) {
                switch ($c.Trim()) {
                    'workbuddy' { $script:SelWB    = $true }
                    'wb'        { $script:SelWB    = $true }
                    'codex'     { $script:SelCodex = $true }
                    # "0" is the short form advertised at the prompt; "n" is its alias here.
                    # (At the interactive prompt "n" means "abort" instead - different call
                    # site, different meaning; -Clients is explicit, so there is no ambiguity.)
                    '0'         { }
                    'n'         { }
                    ''          { }
                    default {
                        Write-Err "Unknown client '$c' (supported: workbuddy, codex, all, 0/n)"
                        exit 1
                    }
                }
            }
        }
        Write-Info "Clients selected via -Clients: workbuddy=$script:SelWB codex=$script:SelCodex"
        return
    }

    # Interactive selection
    Write-Host ""
    Write-Host "Detected AI-agent clients:"
    if ($script:DetectedWB) {
        Write-Host "  1) WorkBuddy   ($env:USERPROFILE\.workbuddy)"
    }
    if ($script:DetectedCodex) {
        Write-Host "  2) Codex       ($env:USERPROFILE\.codex)"
    }
    if (-not $script:DetectedWB -and -not $script:DetectedCodex) {
        Write-Host "  (none detected)"
    }
    Write-Host ""
    # Re-prompt until the answer is understood: a typo must never silently fall through
    # to the source-only install.
    while ($true) {
        $script:SelWB    = $false
        $script:SelCodex = $false
        # Enter (=all detected) is listed first: it is the intended answer for most users,
        # who should be able to accept it without reading the rest of the line.
        $rawAns = Read-Host "Install into which clients? [Enter=all detected / 1 / 2 / 0=source only / q=quit]"
        if ($null -eq $rawAns) {
            # stdin closed: abort instead of silently falling back to the default selection
            Write-Err "No input available (EOF); aborting the install"
            exit 1
        }
        $ans = $rawAns.Trim().ToLower()

        if (Test-CancelInput $ans) { Stop-Cancelled }

        $valid = $true
        switch -Regex ($ans) {
            # Enter = every client that was detected above (the detected subset).
            '^(|default|d)$' {
                $script:SelWB    = $script:DetectedWB
                $script:SelCodex = $script:DetectedCodex
            }
            # a / all is exactly "1,2": both, even if one of them was not detected. Kept as a
            # compatibility alias but never advertised in the prompt - it is the opposite of
            # what Enter does, so listing the two side by side invites misreading.
            '^(a|all)$' {
                $script:SelWB    = $true
                $script:SelCodex = $true
            }
            # Source-only build: "0" is the short form shown in the prompt; "n" is its alias
            # (unreachable from here - Test-CancelInput matches "n" as "abort" first).
            '^(0|n)$' { }
            default {
                foreach ($c in ($ans -split ',')) {
                    switch ($c.Trim()) {
                        '1'         { $script:SelWB    = $true }
                        'workbuddy' { $script:SelWB    = $true }
                        'wb'        { $script:SelWB    = $true }
                        '2'         { $script:SelCodex = $true }
                        'codex'     { $script:SelCodex = $true }
                        ''          { }
                        default {
                            Write-Warn "Unknown selection '$c'"
                            $valid = $false
                        }
                    }
                }
            }
        }

        if ($valid) { break }
        Write-Warn "Not understood; please answer again: Enter=all detected / 1 / 2 / 0=source only / q=quit"
        Write-Host ""
    }

    if ($script:SelWB)    { Write-OK "Will install into: WorkBuddy" }
    if ($script:SelCodex) { Write-OK "Will install into: Codex" }
    if (-not $script:SelWB -and -not $script:SelCodex) {
        Write-Warn "No client selected; only the source build will be installed (client integration skipped)"
        Write-Info "Rerun the installer later, or pass -Clients workbuddy,codex to add clients"
    }
}

# -- Write the MCP config (merge into the existing one; node serializes it as standard JSON) -------------------------------
function Write-MCPConfig {
    param([string]$PlatformDir, [string]$NodeExe, [string]$DistJs)

    $targetPath = "$PlatformDir\mcp.json"

    # Merge + serialization are fully delegated to node: guarantees standard JSON (2-space indent, properly escaped paths),
    # avoiding PowerShell 5.1 ConvertTo-Json's broken indentation
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
        Write-Err "Failed to write the MCP config: $targetPath"
        exit 1
    }
}

# -- Generate the WorkBuddy config -----------------------------------------------------
function Generate-WbConfig {
    Write-Step "Generating the WorkBuddy config"

    # Consistently use the selected Node.js (system or official download; neither is IDE-bundled, both have fixed paths)
    $defaultNode = (Get-Command node -ErrorAction SilentlyContinue).Source
    $nodeExe     = if ($script:NodeExe) { $script:NodeExe } else { $defaultNode }
    $distJs  = "$installDir\dist\index.js"

    # Windows paths need backslashes escaped as \\ in JSON (for terminal display only)
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

    # Write directly into the platform's mcp.json (using the selected Node.js)
    if ($script:SelWB) {
        $wbDir = "$env:USERPROFILE\.workbuddy"
        if (-not (Test-Path $wbDir)) {
            New-Item -ItemType Directory -Path $wbDir -Force | Out-Null
        }
        Write-MCPConfig -PlatformDir $wbDir -NodeExe $nodeExe -DistJs $distJs
        Write-OK "MCP config written: $wbDir\mcp.json"
        Write-Info "Click 'Trust' for ip-switch in the WorkBuddy connector management page to enable it"
        $written = $true
    }

    if (-not $written) {
        Write-Warn "No client selected; no MCP config was written"
        Write-Host ""
        Write-Host "MCP config content:" -ForegroundColor Cyan
        Write-Host $configJson
        Write-Host ""
        Write-Info "Manually add the config above to the corresponding client's mcp.json"
    }
}



# -- Generate the Codex MCP direct config (installDir\.mcp.json) ------------------------
#   (1) probe/validate Node.js (prefer $script:NodeExe, fall back to node on PATH)
#   (2) validate that the build output installDir\dist\index.js exists
#   (3) generate installDir\.mcp.json (full paths, overwriting the fragile command:"node" version shipped in the repo)
# Also store the final node / dist paths in script-level variables for Install-CodexToml to reuse.
function Install-CodexMcp {
    Write-Step "Generating the Codex MCP direct config (.mcp.json)"

    $distJs    = "$installDir\dist\index.js"
    $codexNode = if ($script:NodeExe) { $script:NodeExe } else { (Get-Command node -ErrorAction SilentlyContinue).Source }
    if (-not $codexNode) {
        Write-Err "Node.js not found; cannot generate the Codex MCP config"
        exit 1
    }

    # 1. Validate that the build output exists
    if (-not (Test-Path $distJs)) {
        Write-Err "Build output missing: $distJs; build first (or drop -SkipBuild)"
        exit 1
    }

    # 2. Generate installDir\.mcp.json (full paths, overwriting the fragile command:"node" version shipped in the repo)
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
    Write-OK "MCP config generated: $dotMcp"

    # 3. Expose for the later TOML config layer (script-level variables, visible across functions)
    $script:CodexMcpDist = $distJs
    $script:CodexMcpNode = $codexNode

    # 4. Verify
    $dotMcp = "$installDir\.mcp.json"
    if (Test-Path $dotMcp) {
        Write-OK "Codex MCP direct config ready: $dotMcp"
        Write-Info "Takes effect after restarting Codex (plugin-page discovery is handled by the marketplace)"
    } else {
        Write-Err "Failed to generate the MCP config; check $dotMcp"
        exit 1
    }
}

# -- Ensure the Codex [user-level config.toml] registers the local marketplace, plugin, and ip-switch MCP (globally visible) ---
#  Note: the standard usage of the Codex [project-level .codex/config.toml] (e.g. the codex-cli-best-practice repo)
#  does put model/sandbox_mode/approval_policy/[mcp_servers.*]/[features]/[agents]/[profiles.*] at project level,
#  but no example ever puts [marketplaces.*]/[plugins.*] at project level
function Append-CodexUserConfig {
    param(
        [Parameter(Mandatory = $true)][string]$CodexConfig
    )
    if (-not (Test-Path $CodexConfig)) {
        Write-Warning "$CodexConfig not found; skipping marketplace/plugin/MCP registration (created automatically on the first codex run)"
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
    # Idempotently append [mcp_servers.ip-switch]: uses the node/dist paths already resolved by the script; works even when CC Switch is not running
    if (-not $content.Contains('[mcp_servers.ip-switch]')) {
        $mcpNode = $script:CodexMcpNode
        $mcpDist = $script:CodexMcpDist
        $mcpCwd  = $script:installDir
        if ($mcpNode -and $mcpDist -and $mcpCwd) {
            $appended += "[mcp_servers.ip-switch]`ncommand = '$mcpNode'`nargs = ['$mcpDist']`ncwd = '$mcpCwd'`nstartup_timeout_sec = 30`nenabled = true`n"
        } else {
            Write-Warning "Node/dist paths missing (prerequisite steps incomplete); skipping the user-level [mcp_servers.ip-switch] registration"
        }
    }

    if ($appended.Count -eq 0) {
        Write-Info "The ip-switch marketplace, plugin, and MCP are already in the user-level config.toml; skipping"
        return
    }

    [System.IO.File]::AppendAllText($CodexConfig, "`n" + ($appended -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "Registered the ip-switch marketplace, plugin, and mcp_servers into the user-level config.toml (globally visible; the mcp section is written by the script, no longer depending on CC Switch)"
}

# -- Install the Codex user-level config (the only stable globally-visible channel) --------
# Responsibility: register ip-switch into the user-level ~/.codex/config.toml:
#       （[marketplaces.local] + [plugins."ip-switch@local"] + [mcp_servers.ip-switch]）。
#     If any of the three is missing, check CC Switch's common config for the model: the common_config_codex field of the settings table in cc-switch.db
function Install-CodexToml {
    Write-Step "Installing the Codex user-level config (the only stable globally-visible channel)"

    # The only stable channel = registration in the user-level ~/.codex/config.toml (marketplaces + plugins + mcp).
    $codexDir = "$env:USERPROFILE\.codex"
    Append-CodexUserConfig -CodexConfig "$codexDir\config.toml"
}

# -- Create the desktop shortcut ---------------------------------------------------------
# Split out of Install-CodexToml as a standalone function:
#   (1) copy the codex_app.vbs launcher (runs silently via wscript, no console window)
#   (2) copy the codex.ico icon file
#   (3) create a desktop shortcut: wscript.exe + codex_app.vbs, launching the codex app with the ip-switch directory as workspace
function Install-CodexShotcut {
    Write-Step "Creating the Codex desktop shortcut"

    $shortcutName = 'Codex with ip-switch'
    $shortcutPath = [System.Environment]::GetFolderPath('Desktop') + '\\' + $shortcutName + '.lnk'
    $wscriptExe = "$env:SystemRoot\System32\wscript.exe"
    $vbsPath = "$installDir\codex_app.vbs"

    # Copy the launcher script
    if (Test-Path '.\codex_app.vbs') {
        Copy-Item '.\codex_app.vbs' -Destination $vbsPath -Force
        Write-Host "✓ Copied codex_app.vbs to $vbsPath" -ForegroundColor Green
    } elseif (-not (Test-Path $vbsPath)) {
        Write-Host "Warning: codex_app.vbs not found in the install directory" -ForegroundColor Yellow
    }

    # Copy the icon file
    $iconPath = "$installDir\codex.ico"
    if (Test-Path '.\codex.ico') {
        Copy-Item '.\codex.ico' -Destination $iconPath -Force
        Write-Host "✓ Copied codex.ico to $iconPath" -ForegroundColor Green
    } elseif (-not (Test-Path $iconPath)) {
        Write-Host "Warning: codex.ico not found; the default icon will be used" -ForegroundColor Yellow
    }

    # Create the shortcut
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $wscriptExe
    $shortcut.Arguments = '"' + $vbsPath + '"'
    $shortcut.Description = 'Launch Codex and auto-load the ip-switch MCP service'
    $shortcut.WorkingDirectory = $installDir
    if (Test-Path $iconPath) {
        $shortcut.IconLocation = "$iconPath,0"
    }
    $shortcut.Save()

    Write-Host "✓ Desktop shortcut created: $shortcutPath" -ForegroundColor Green
}

# -- Install the Codex plugin marketplace so ip-switch is discoverable in the plugin page/marketplace ------
function Install-CodexMarketplace {
    Write-Step "Installing the Codex plugin marketplace (ip-switch)"
    $codexRoot = "$env:USERPROFILE\.codex"
    $marketDir = "$codexRoot\marketplaces\local"
    $marketPluginDir = "$marketDir\plugins\ip-switch\.codex-plugin"

    # 1. Marketplace manifest marketplace.json (modeled on Codex's built-in openai-bundled format)
    #    Note: the plugin package only carries the manifests + .mcp.json; no bundled skill copy anymore --
    #    the skill is provided by the standalone ~\.codex\skills\ips-main\ channel, avoiding dual-channel duplication
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

    # 2. In-market plugin manifest plugin.json (mcpServers points to the package's .mcp.json)
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
  "mcpServers": "./.mcp.json",
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
      "Add an AWS profile in the IP Switch UI",
      "Use IP Switch to rotate the public IP of a cloud instance and update its Cloudflare DNS record.",
      "Use IP Switch to query instance info or list instances in a cloud region."
    ]
  }
}
"@

    New-Item -ItemType Directory -Path "$marketDir\.agents\plugins" -Force | Out-Null
    New-Item -ItemType Directory -Path $marketPluginDir -Force | Out-Null
    Copy-Item -Path "$installDir\.mcp.json" -Destination "$marketDir\plugins\ip-switch\.mcp.json" -Force
    [System.IO.File]::WriteAllText("$marketDir\.agents\plugins\marketplace.json", $marketJson, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText("$marketPluginDir\plugin.json", $pluginJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "Marketplace manifest written: $marketDir\.agents\plugins\marketplace.json"
    Write-OK "Plugin manifest written: $marketPluginDir\plugin.json"

    # 3. This function only writes the manifest files (marketplace.json / plugin.json).
    #    The [marketplaces.local] + [plugins."ip-switch@local"] + [mcp_servers.ip-switch] registration in config.toml
    #    is handled by Append-CodexUserConfig (user-level, the only stable channel), not here.
    Write-OK "Codex plugin manifests written (the config.toml registration is done by Append-CodexUserConfig)"

    # 5. Verify
    if ((Test-Path "$marketDir\.agents\plugins\marketplace.json") -and (Test-Path "$marketPluginDir\plugin.json")) {
        Write-OK "Codex plugin marketplace installed: $marketDir"
        Write-Info "After restarting Codex, IP Switch appears in the plugin page/marketplace"
    } else {
        Write-Err "Marketplace installation incomplete; check $marketDir"
        exit 1
    }
}

# -- Install the ip-switch skill (WorkBuddy / Codex / any AI agent can open the config page) ----
# Responsibilities:
#   1. Flatten SKILL.md / skill.json (project root) + scripts/ (icon + scripts) into
#      $env:USERPROFILE\.workbuddy\skills\ips-main\ (auto-discovered by WorkBuddy)
#   2. Create the <install-dir>\data\ runtime directory (replacing the old $env:USERPROFILE\.ip-switch\)
#   3. Write INSTALL_DIR into .install-path.txt in the user-level copy (bootstrap anchor)
#   4. Write <install-dir>\data\install-dir.txt (runtime config, used by --status)
#   5. Mirror to $env:USERPROFILE\.codex\skills\ips-main\ (only when Codex is selected)
# Design:
#   - Idempotent: overwrites on rerun (run again after git pull to get the new version)
#   - Selection-based: skills are copied only into the clients the user selected
#     (Select-Clients). Nothing is written to ~\.workbuddy or ~\.codex otherwise.
function Install-Skill {
    Write-Step "Installing the ip-switch skill (AI-agent config page launcher)"

    $scriptsSrc = Join-Path $installDir "scripts"
    if (-not (Test-Path $scriptsSrc)) {
        Write-Warn "Skill scripts directory not found: $scriptsSrc (skipping the skill install)"
        return
    }

    # 1. Create the <install-dir>\data\ runtime directory (replacing the old $env:USERPROFILE\.ip-switch\)
    $dataDir = Join-Path $installDir "data"
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    $markerPath = Join-Path $dataDir "install-dir.txt"
    [System.IO.File]::WriteAllText($markerPath, $installDir, (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "install-dir marker written: $markerPath -> $installDir"

    # 2. Copy to the target locations (only for the clients the user selected)
    if (-not $script:SelWB -and -not $script:SelCodex) {
        Write-Warn "No client selected; skipping the skill install"
        return
    }

    if ($script:SelWB) {
    # 2. WorkBuddy copy (WorkBuddy discovers via a flat scan of ~/.workbuddy/skills/<name>/)
    #    Sources: project-root SKILL.md / skill.json + scripts\ + references\ (multilingual docs)
    #    Target layout:
    #       $env:USERPROFILE\.workbuddy\skills\ips-main\
    #       ├── SKILL.md
    #       ├── skill.json
    #       ├── .install-path.txt        <- bootstrap anchor (contains the absolute INSTALL_DIR path)
    #       ├── scripts\                  <- kept as a subdirectory (not flattened)
    #       │   ├── _icon.svg
    #       │   ├── open-ui.mjs
    #       │   ├── open-ui.sh
    #       │   └── open-ui.ps1
    #       └── references\               <- multilingual docs (zh.md etc.), loaded on demand
    $workbuddyDest = Join-Path $env:USERPROFILE ".workbuddy\skills\ips-main"
    $workbuddyScriptsDest = Join-Path $workbuddyDest "scripts"
    New-Item -ItemType Directory -Path $workbuddyDest -Force | Out-Null
    New-Item -ItemType Directory -Path $workbuddyScriptsDest -Force | Out-Null
    try {
        # 2a. Root skill metadata -> target root
        foreach ($f in @("SKILL.md", "skill.json")) {
            $srcFile = Join-Path $installDir $f
            if (Test-Path $srcFile) {
                Copy-Item -Path $srcFile -Destination $workbuddyDest -Force
            } else {
                Write-Warn "Root file not found: $srcFile (skipping)"
            }
        }

        # 2b. The whole scripts/ subdirectory -> the target scripts\ subdirectory (name preserved)
        Copy-Item -Path "$scriptsSrc\*" -Destination $workbuddyScriptsDest -Recurse -Force
        Write-OK "Skill installed: $workbuddyDest (with scripts\ subdirectory)"

        # 2b-2. references\ subdirectory (multilingual docs, e.g. zh.md) -> the target references\ subdirectory
        $refsSrc = Join-Path $installDir "references"
        if (Test-Path $refsSrc) {
            $refsDest = Join-Path $workbuddyDest "references"
            New-Item -ItemType Directory -Path $refsDest -Force | Out-Null
            try {
                Copy-Item -Path "$refsSrc\*" -Destination $refsDest -Recurse -Force
                Write-OK "Skill multilingual docs installed: $refsDest"
            } catch {
                Write-Warn "Failed to copy references: $refsSrc -> $refsDest (skipping; no functional impact)"
            }
        }

        # 2c. Bootstrap anchor: write the absolute INSTALL_DIR path under the user-level copy's scripts\
        #    open-ui.mjs reads this file first at startup to locate the ip-switch project
        #    Placed under scripts\ (next to open-ui.mjs) to avoid confusion
        $userMarker = Join-Path $workbuddyScriptsDest ".install-path.txt"
        [System.IO.File]::WriteAllText($userMarker, $installDir, (New-Object System.Text.UTF8Encoding($false)))
        Write-OK "Bootstrap anchor written: $userMarker"
    } catch {
        Write-Err "Failed to copy the skill: $scriptsSrc -> $workbuddyScriptsDest ($_)"
        return
    }
    }

    # 3. Codex mirror (only when the user selected Codex)
    $codexSkillsDir = Join-Path $env:USERPROFILE ".codex\skills"
    if ($script:SelCodex) {
        $codexDest = Join-Path $codexSkillsDir "ips-main"
        $codexScriptsDest = Join-Path $codexDest "scripts"
        New-Item -ItemType Directory -Path $codexDest -Force | Out-Null
        New-Item -ItemType Directory -Path $codexScriptsDest -Force | Out-Null
        try {
            foreach ($f in @("SKILL.md", "skill.json")) {
                $srcFile = Join-Path $installDir $f
                if (Test-Path $srcFile) {
                    Copy-Item -Path $srcFile -Destination $codexDest -Force
                }
            }
            Copy-Item -Path "$scriptsSrc\*" -Destination $codexScriptsDest -Recurse -Force
            # The Codex mirror also carries the references\ multilingual docs
            $codexRefsSrc = Join-Path $installDir "references"
            if (Test-Path $codexRefsSrc) {
                $codexRefsDest = Join-Path $codexDest "references"
                New-Item -ItemType Directory -Path $codexRefsDest -Force | Out-Null
                Copy-Item -Path "$codexRefsSrc\*" -Destination $codexRefsDest -Recurse -Force
            }
            # The Codex mirror copy also needs the bootstrap anchor (placed under scripts\)
            $codexMarker = Join-Path $codexScriptsDest ".install-path.txt"
            [System.IO.File]::WriteAllText($codexMarker, $installDir, (New-Object System.Text.UTF8Encoding($false)))
            Write-OK "Mirrored to Codex: $codexScriptsDest (takes effect if Codex enables skills)"
        } catch {
            Write-Warn "Failed to mirror to Codex: $_"
        }
    }

    if ($script:SelWB) {
        Write-Info "How AI agents open it:"
        Write-Info "  WorkBuddy: say \"Open the ip-switch config page\", \"Add an AWS account\", etc. in the chat"
        Write-Info "  Any terminal: node $workbuddyScriptsDest\open-ui.mjs [aws|azure|oci|vultr]"
    }
    if ($script:SelCodex) {
        Write-Info "  Codex: say \"Open the ip-switch config page\", \"Add an AWS account\", etc. in the chat"
        Write-Info "  Any terminal: node $codexScriptsDest\open-ui.mjs [aws|azure|oci|vultr]"
    }
}

# -- Install the ips-* quick-command skills (thin slash-command entries) ---------------------
# Each subdirectory under <installDir>\skills\ is one thin quick-command skill:
#   skills\ips-rotate\  skills\ips-dns\  skills\ips-cfg\  skills\ips-list\  ...
# Layout per skill: SKILL.md (English) + references\zh.md (Chinese, loaded on demand).
# Extensibility: the loop below auto-installs every ips-* directory -- adding a new
# quick command means dropping a new directory here, no installer edit required.
# Targets:
#   $env:USERPROFILE\.workbuddy\skills\ips-<name>\   (WorkBuddy flat-scan discovery -> /ips-... slash menu)
#   $env:USERPROFILE\.codex\skills\ips-<name>\       (mirror, only when .codex\skills already exists)
function Install-QuickSkills {
    $quickSrc = Join-Path $installDir "skills"
    if (-not (Test-Path $quickSrc)) {
        Write-Warn "Quick skills directory not found: $quickSrc (skipping the quick-skill install)"
        return
    }

    if (-not $script:SelWB -and -not $script:SelCodex) {
        Write-Warn "No client selected; skipping the quick-skill install"
        return
    }

    Get-ChildItem -Path $quickSrc -Directory | Where-Object { $_.Name -like "ips-*" } | ForEach-Object {
        $name = $_.Name
        $skillMd = Join-Path $_.FullName "SKILL.md"
        if (-not (Test-Path $skillMd)) {
            Write-Warn "Quick skill ${name}: SKILL.md missing (skipping)"
            return
        }

        # 1. WorkBuddy copy (only when the user selected WorkBuddy)
        if ($script:SelWB) {
        $qdest = Join-Path $env:USERPROFILE ".workbuddy\skills\$name"
        New-Item -ItemType Directory -Path $qdest -Force | Out-Null
        try {
            Copy-Item -Path $skillMd -Destination $qdest -Force
            $refs = Join-Path $_.FullName "references"
            if (Test-Path $refs) {
                $refsDest = Join-Path $qdest "references"
                New-Item -ItemType Directory -Path $refsDest -Force | Out-Null
                Copy-Item -Path "$refs\*" -Destination $refsDest -Recurse -Force
            }
            Write-OK "Quick skill installed: $qdest (slash command /$name)"
        } catch {
            Write-Err "Failed to install quick skill: $($_.FullName) -> $qdest ($_)"
            return
        }
        }

        # 2. Codex mirror (only when the user selected Codex)
        $codexSkillsDir = Join-Path $env:USERPROFILE ".codex\skills"
        if ($script:SelCodex) {
            $qcodex = Join-Path $codexSkillsDir $name
            New-Item -ItemType Directory -Path $qcodex -Force | Out-Null
            try {
                Copy-Item -Path $skillMd -Destination $qcodex -Force
                $refs = Join-Path $_.FullName "references"
                if (Test-Path $refs) {
                    $refsDest = Join-Path $qcodex "references"
                    New-Item -ItemType Directory -Path $refsDest -Force | Out-Null
                    Copy-Item -Path "$refs\*" -Destination $refsDest -Recurse -Force
                }
                Write-OK "Quick skill mirrored to Codex: $qcodex"
            } catch {
                Write-Warn "Failed to mirror quick skill to Codex: $_"
            }
        }
    }
}

# -- Restart the client app (WorkBuddy/Codex) so the MCP config takes effect immediately ----
function Restart-ClientApp {
    param(
        [string]$AppName,
        [string[]]$ProcessNames,
        [string[]]$PathKeywords = @(),
        [string]$LaunchExe = "",
        [string[]]$LaunchArgs = @()
    )

    # 1) Match by process name first (common names like codex / ChatGPT / WorkBuddy / CodeBuddy)
    $proc = $null
    foreach ($name in $ProcessNames) {
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) { break }
    }

    # 2) If the process name does not match, fall back to executable-path keywords (paths are more stable than names)
    if (-not $proc -and $PathKeywords.Count -gt 0) {
        foreach ($kw in $PathKeywords) {
            $proc = Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and $_.Path -like "*$kw*" } |
                Select-Object -First 1
            if ($proc) { break }
        }
    }

    # 3) When spawning the child, redirect stdout/stderr to temp files to suppress Electron debug logs
    $logOut = Join-Path $env:TEMP "ip-switch-$AppName-out.log"
    $logErr = Join-Path $env:TEMP "ip-switch-$AppName-err.log"
    Remove-Item $logOut, $logErr -Force -ErrorAction SilentlyContinue

    if ($proc) {
        $exePath = $proc.Path
        Write-Info "$AppName detected as running; restarting..."
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        # Prefer restarting via the original process path; otherwise use the configured launch command
        # -WindowStyle Hidden: prevents a console window flash when launching console programs (e.g. codex.exe CLI)
        if ($exePath -and (Test-Path $exePath)) {
            try {
                Start-Process -FilePath $exePath -WindowStyle Hidden `
                    -RedirectStandardOutput $logOut -RedirectStandardError $logErr `
                    -ErrorAction Stop | Out-Null
                Write-OK "$AppName restarted"
                return
            } catch { }
        }
        if ($LaunchExe) {
            try {
                Start-Process -FilePath $LaunchExe -ArgumentList $LaunchArgs -WindowStyle Hidden `
                    -RedirectStandardOutput $logOut -RedirectStandardError $logErr `
                    -ErrorAction Stop | Out-Null
                Write-OK "$AppName restarted"
                return
            } catch { }
        }
        Write-Warn "$AppName was closed but auto-restart failed; please open it manually"
    } else {
        # Original process not running -> do nothing, keep the current state
        Write-Info "$AppName is not running; skipping the restart (open it manually if needed)"
    }
}

# -- Post-install summary ------------------------------------------------------------
function Show-Success {
    # Auto-restart the client so the MCP config takes effect immediately
    Write-Host ""
    Write-Host "Restart the client:" -ForegroundColor Yellow
    if ($script:SelWB) {
        # Common process-name candidates + path-keyword fallback (path contains .workbuddy / CodeBuddy / WorkBuddy)
        Restart-ClientApp -AppName "WorkBuddy" `
            -ProcessNames @("WorkBuddy", "CodeBuddy") `
            -PathKeywords @("\.workbuddy\", "CodeBuddy", "WorkBuddy")
    }
    if ($script:SelCodex) {
        $vbsPath = "$installDir\codex_app.vbs"
        # The desktop process name may be codex / Codex / ChatGPT (Windows Store package exe name),
        # the fallback matches paths containing OpenAI.Codex / OpenAI\Codex
        if (Test-Path $vbsPath) {
            # Launch via codex_app.vbs, which also brings up the ip-switch service
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

    if ($script:SelWB -and $script:SelCodex) {
        $mcpHint = "  # Use via MCP tools (just chat in WorkBuddy/Codex)"
    } elseif ($script:SelWB) {
        $mcpHint = "  # Use via MCP tools (just chat in WorkBuddy)"
    } elseif ($script:SelCodex) {
        $mcpHint = "  # Use via MCP tools (just chat in Codex)"
    } else {
        $mcpHint = "  # After configuring the MCP client, use these commands via chat"
    }

    $successBanner = @"

+============================================================+
|          ip-switch installed successfully!                       |
+============================================================+

"@
    Write-Host $successBanner -ForegroundColor Green

    # Show paths for the actually installed platforms (WorkBuddy has no plugin dir, only mcp.json)
    $wbConfig       = "$env:USERPROFILE\.workbuddy\mcp.json"
    $codexMarketDir = "$env:USERPROFILE\.codex\marketplaces\local"
    $skillDir       = "$env:USERPROFILE\.workbuddy\skills\ips-main"

    if ($script:SelWB) {
        Write-Host "WorkBuddy MCP config: $wbConfig"
    }
    if ($script:SelCodex) {
        Write-Host "Codex marketplace manifest: $codexMarketDir"
        Write-Host "Codex user-level registration: $env:USERPROFILE\.codex\config.toml (globally visible, written by Append-CodexUserConfig)"
    }
    if ($script:SelWB -or $script:SelCodex) {
        Write-Host "ip-switch skill: $skillDir"
        Write-Host "                   (auto-discovered by WorkBuddy; from any terminal: node $skillDir\scripts\open-ui.mjs [aws|azure|oci|vultr])"
    }
    Write-Host "UI server:  node $installDir\ui\server.cjs"
    Write-Host "UI URL:     printed to the terminal when the server starts"
    Write-Host ""

    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  # Start the UI config server (optional)"
    Write-Host "  node $installDir\ui\server.cjs"
    Write-Host ""
    Write-Host "  # Open the config page in a browser (see the server startup output for the URL)"
    Write-Host "  start http://127.0.0.1:<port>"
    Write-Host ""
    Write-Host $mcpHint
    Write-Host "  - List profiles:  \"List my cloud server profiles\""
    Write-Host "  - Rotate IPs:     \"Rotate the IPs of all configured servers\""
    Write-Host "  - Add a profile:  \"I want to add an AWS profile\""
    Write-Host ""

    Write-Host "Manual update:" -ForegroundColor Yellow
    Write-Host "  cd $installDir; git pull; npm install; npm run build"
    Write-Host ""

    Write-Host "Uninstall:" -ForegroundColor Yellow
    if ($script:SelWB) {
        Write-Host "  Remove-Item -Force $wbConfig          # remove the WorkBuddy MCP config"
    }
    if ($script:SelCodex) {
        Write-Host "  Remove-Item -Recurse -Force $codexMarketDir  # remove the Codex marketplace manifests"
    }
    if ($script:SelWB -or $script:SelCodex) {
        Write-Host "  Remove-Item -Recurse -Force $skillDir        # remove the ip-switch skill"
    }
    Write-Host "  Remove-Item -Recurse -Force (Join-Path $installDir 'data')  # remove runtime data (keep the source)"
    Write-Host "  Remove-Item -Recurse -Force $installDir  # also remove the source if desired (wipes the data/ subdirectory too)"
    Write-Host ""
    Write-Host "Privacy: install stats log your IP, OS, script version and a random device id" -ForegroundColor Yellow
    Write-Host "         opt out with IP_SWITCH_TELEMETRY=0; details in INSTALL.md" -ForegroundColor Yellow
    Send-Telemetry 'success'
    $script:TelemetrySent = $true
}

# -- Main flow ------------------------------------------------------------------
function Main {
    Write-Host ""
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host "|   ip-switch automated deployment script v1.0                |" -ForegroundColor Green
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host ""

    $script:TelemetryArmed = $true
    Send-Telemetry 'start'

    $script:Stage = 'precheck'
    Check-Npm
    Check-Git
    Detect-MCPPlatform
    Select-Clients
    $script:Stage = 'clone'
    Clone-Repo
    $script:Stage = 'deps'
    Install-Deps
    $script:Stage = 'build'
    if (-not $SkipBuild) {
        Build-Project
    }
    if ($script:SelWB -or $script:SelCodex) {
        Generate-WbConfig
    }
    if ($script:SelCodex) {
        Install-CodexMcp
        Install-CodexToml
        Install-CodexShotcut
        Install-CodexMarketplace
    }
    # Skill install: a unified config-page launcher across WorkBuddy / Codex / any AI agent
    # Selection-based: copies go only into the clients the user selected (Select-Clients)
    $script:Stage = 'skill'
    Install-Skill
    # Quick-command skills (ips-*): thin slash-command entries for the frequent MCP operations
    Install-QuickSkills
    Show-Success

    Write-OK "Deployment complete!"
}

# Safety net for every failure path inside Main: Stage already says where it broke.
# Stop-Cancelled and Show-Success report themselves, so they set TelemetrySent first.
try { Main } catch { Send-Telemetry 'fail' $script:Stage; throw }

