@echo off
rem ===========================================================================
rem  ip-switch automated deployment script (Windows Command Prompt / cmd.exe)
rem  Chinese version: install-zh.cmd
rem ===========================================================================
rem  Purpose: one-click clone, install dependencies, build, generate the
rem           WorkBuddy config, generate the Codex config, create a desktop
rem           shortcut
rem  Applies to: Windows 10/11 (no PowerShell required)
rem  Prerequisites: git and Node.js >= 18
rem
rem  This is a full port of install.ps1. It never calls PowerShell.
rem  Everything is done with cmd builtins plus these externals:
rem    git.exe     clone / pull              (same as the ps1)
rem    node.exe    JSON writing, version read  (the ps1 requires node anyway)
rem    curl.exe    downloads + telemetry       (ships with Win10 1803+)
rem    tar.exe     unzip Node.js               (bsdtar, ships with Win10 1803+)
rem    cscript.exe create the .lnk shortcut via a generated .vbs
rem    wmic.exe    locate a running client exe for the restart step
rem    xcopy.exe   copy the skill folders
rem    reg.exe     read the Windows version and the user PATH
rem
rem  Options: -RepoUrl -Branch -installDir -Clients -SkipBuild -Help
rem  Run "install.cmd -Help" for the full usage.
rem ===========================================================================

setlocal EnableExtensions DisableDelayedExpansion

set "SCRIPT_VERSION=1.0"
set "SCRIPT_LANG=en"
set "PROJECT_NAME=ip-switch"

rem -- build the "slash question mark" token from variables --------------------
rem    A literal slash-question-mark anywhere in this file, even inside a rem
rem    line, is swallowed by cmd as the REM help switch and breaks the script.
set "Q=/"
set "Q=%Q%?"

rem -- defaults (overridden by arguments) ---------------------------------------
set "REPO_URL=https://gitee.com/areyi2014/ip-switch-cloud.git"
set "BRANCH=main"
set "INSTALL_DIR=%USERPROFILE%\ip-switch"
set "CLIENTS="
set "SKIP_BUILD=0"

rem -- runtime state ------------------------------------------------------------
set "NODE_EXE="
set "NPM_CLI="
set "NPM_CMD="
set "GIT_EXE="
set "CURL_EXE="
set "TAR_EXE="
set "SEL_WB=0"
set "SEL_CODEX=0"
set "DET_WB=0"
set "DET_CODEX=0"
set "CODEX_MCP_DIST="
set "CODEX_MCP_NODE="
set "TELEMETRY_ARMED=0"
set "TELEMETRY_SENT=0"
set "STAGE=precheck"
set "RC=0"

rem ===========================================================================
rem  Argument parsing
rem ===========================================================================
:parse_args
if "%~1"=="" goto :args_done
set "OPT=%~1"
if /i "%OPT%"=="%Q%"          goto :usage
if /i "%OPT%"=="-?"          goto :usage
if /i "%OPT%"=="/help"       goto :usage
if /i "%OPT%"=="-help"       goto :usage
if /i "%OPT%"=="-RepoUrl"    goto :a_repourl
if /i "%OPT%"=="-Branch"     goto :a_branch
if /i "%OPT%"=="-installDir" goto :a_installdir
if /i "%OPT%"=="-Clients"    goto :a_clients
if /i "%OPT%"=="-SkipBuild"  goto :a_skipbuild
goto :a_unknown

:a_repourl
set "REPO_URL=%~2"
shift
shift
goto :parse_args
:a_branch
set "BRANCH=%~2"
shift
shift
goto :parse_args
:a_installdir
set "INSTALL_DIR=%~2"
shift
shift
goto :parse_args
:a_clients
set "CLIENTS=%~2"
rem Validate the list right here, so a typo fails before anything is cloned
rem or written rather than after the prechecks have already run.
rem "for /f ... in ("x")" would treat x as a file name, so the plain "for" form
rem is used to iterate over a literal string.
call :validate_clients_list
if not "%VALID%"=="0" goto :a_clients_ok
set "RC=2"
goto :finish
:a_clients_ok
shift
shift
goto :parse_args

:a_skipbuild
set "SKIP_BUILD=1"
shift
goto :parse_args

rem An unrecognised option that still names a client is treated as a continuation
rem of the -Clients list. Git Bash and MSYS split "workbuddy,codex" into two
rem separate arguments before cmd ever sees them, and the same happens when the
rem installer is driven from a shell that does not quote commas. Without this,
rem "install.cmd -Clients workbuddy,codex" would fail on the stray "codex".
:a_unknown
call :is_client_name "%OPT%"
if "%IS_CLIENT%"=="1" (
    set "CLIENTS=%CLIENTS%,%OPT%"
    shift
    goto :parse_args
)
call :err "Unknown option: %OPT%  ^(run install.cmd -Help^)"
set "RC=2"
goto :finish

rem %1 = candidate. Sets IS_CLIENT when it names a supported client.
:is_client_name
set "IS_CLIENT=0"
set "CN=%~1"
if /i "%CN%"=="workbuddy" set "IS_CLIENT=1"
if /i "%CN%"=="wb" set "IS_CLIENT=1"
if /i "%CN%"=="codex" set "IS_CLIENT=1"
if /i "%CN%"=="all" set "IS_CLIENT=1"
if /i "%CN%"=="0" set "IS_CLIENT=1"
if /i "%CN%"=="n" set "IS_CLIENT=1"
if /i "%CN%"=="1" set "IS_CLIENT=1"
if /i "%CN%"=="2" set "IS_CLIENT=1"
if /i "%CN%"=="d" set "IS_CLIENT=1"
if /i "%CN%"=="a" set "IS_CLIENT=1"
if /i "%CN%"=="default" set "IS_CLIENT=1"
goto :eof

rem Validates CLIENTS into SEL_WB / SEL_CODEX. Sets VALID=0 on a bad entry.
:validate_clients_list
set "VALID=1"
set "SEL_WB=0"
set "SEL_CODEX=0"
for %%A in (%CLIENTS:,= %) do call :classify_arg "%%~A"
goto :eof

:args_done
goto :main

rem ===========================================================================
rem  Output helpers
rem ===========================================================================
rem    Reached only through an explicit goto. cmd executes labels in file order,
rem    so falling through from :args_done into :usage would print the help and
rem    exit without ever running the installer.
:usage
echo.
echo ip-switch automated deployment script v%SCRIPT_VERSION% ^(cmd.exe^)
echo.
echo Usage: install.cmd [options]
echo.
echo Options:
echo   -RepoUrl URL     Repository URL ^(default: gitee^)
echo   -Branch NAME     Branch name ^(default: main^)
echo   -installDir DIR  Install directory ^(default: ~\ip-switch^)
echo   -Clients LIST    Clients to install into: workbuddy,codex,all,0 or n
echo                    ^(default: interactive selection of the detected clients^)
echo   -SkipBuild       Skip the build step
echo   -Help            Show help
echo.
echo Environment:
echo   IP_SWITCH_TELEMETRY=0        Disable install statistics
echo   IP_SWITCH_TELEMETRY_URL=URL  Override the statistics endpoint
echo.
echo Interactive prompts:
echo   Client selection  [Enter=all detected / 1 / 2 / 0=source only / q=quit]
echo                     0 = source build only ^(no client integration^)
echo                     1 = WorkBuddy only, 2 = Codex only
echo                     Enter = every client detected on this machine
echo                     n / no / q / quit / cancel aborts the whole install
echo   Install directory Enter = use the suggested directory, q = quit,
echo                     or type another path
echo.
echo Examples:
echo   install.cmd
echo   install.cmd -RepoUrl "https://gitee.com/areyi2014/ip-switch.git"
echo   install.cmd -installDir "D:\my-tools\ip-switch"
echo.
set "RC=0"
goto :finish

:step
echo.
echo === %~1 ===
goto :eof

:info
echo [INFO]  %~1
goto :eof

:ok
echo [ OK ]  %~1
goto :eof

:warn
echo [WARN]  %~1
goto :eof

:err
echo [ERROR] %~1
goto :eof

rem -- "n / no / q / quit / cancel / exit" always aborts the whole install ------
rem    Rationale: "n" reads as "no" to a human, so it must never be silently
rem    taken as "no clients, build the source anyway" (that is what "0" means at
rem    the prompt). Both call sites run before anything is written, so aborting
rem    is always safe.
:is_cancel
set "IS_CANCEL=0"
if /i "%~1"=="n"      set "IS_CANCEL=1"
if /i "%~1"=="no"     set "IS_CANCEL=1"
if /i "%~1"=="q"      set "IS_CANCEL=1"
if /i "%~1"=="quit"   set "IS_CANCEL=1"
if /i "%~1"=="cancel" set "IS_CANCEL=1"
if /i "%~1"=="exit"   set "IS_CANCEL=1"
goto :eof

:stop_cancelled
echo.
call :info "Cancelled: nothing was cloned and no files were written"
if "%TELEMETRY_ARMED%"=="1" (
    call :telemetry "cancel" ""
    set "TELEMETRY_SENT=1"
)
set "RC=0"
goto :finish

rem ===========================================================================
rem  Install statistics (opt-out)
rem ===========================================================================
rem    Reports at most 4 events ^(start / success / cancel / fail^) to a Cloudflare
rem    Worker, which stores them in Workers Analytics Engine. The event includes
rem    the client IP ^(the endpoint records it from cf-connecting-ip, for abuse
rem    detection^), the OS, the script version and a locally generated random
rem    device id. No username, hostname, file path or credential is ever sent.
rem    Disable with IP_SWITCH_TELEMETRY=0; override the endpoint with
rem    IP_SWITCH_TELEMETRY_URL. Reporting is best effort: it never blocks longer
rem    than 3s and never changes the exit code.
rem
rem    The device id is a random GUID generated once and kept locally, used only
rem    to tell a new machine apart from a reinstall. It is not derived from any
rem    hardware or user data.
:get_device_id
set "DEV_ID="
set "DEV_FILE=%LOCALAPPDATA%\%PROJECT_NAME%\device-id"
if exist "%DEV_FILE%" (
    for /f "usebackq tokens=*" %%A in (`type "%DEV_FILE%" 2^>nul`) do set "DEV_ID=%%A"
)
if not defined DEV_ID (
    if not exist "%LOCALAPPDATA%\%PROJECT_NAME%" mkdir "%LOCALAPPDATA%\%PROJECT_NAME%" 2>nul
    setlocal EnableDelayedExpansion
    set "A=%RANDOM%%RANDOM%%RANDOM%%RANDOM%"
    set "B=%RANDOM%%RANDOM%%RANDOM%%RANDOM%"
    set "DEV_ID=!A:~0,8!-!A:~8,4!-4!A:~0,3!-!B:~0,4!-!B:~0,12!"
    echo !DEV_ID!> "%DEV_FILE%" 2>nul
    endlocal
)
goto :eof

rem Windows version detail, e.g. "11 23H2". Read from the registry and cached,
rem so a run with telemetry disabled never touches the registry at all.
:get_os_version
if defined OS_VERSION goto :eof
set "OS_VERSION="
set "OS_BUILD=0"
set "OS_NAME="
set "OS_REL="
for /f "usebackq tokens=3" %%A in (`reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul`) do set "OS_BUILD=%%A"
for /f "usebackq tokens=*" %%A in (`reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2^>nul`) do set "OS_REL=%%A"
if not defined OS_REL for /f "usebackq tokens=*" %%A in (`reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v ReleaseId 2^>nul`) do set "OS_REL=%%A"
rem Build 22000 and up is Windows 11; anything older that reports a build is 10.
setlocal EnableDelayedExpansion
set "BN=0"
if defined OS_BUILD set "BN=!OS_BUILD!"
if !BN! GEQ 22000 (set "OS_NAME=11") else (if !BN! GTR 0 (set "OS_NAME=10"))
set "OS_VERSION=!OS_NAME! !OS_REL!"
set "OS_VERSION=!OS_VERSION: =!"
rem Keep it short and JSON-safe, same rule as the shell scripts.
if not "!OS_VERSION!"=="" set "OS_VERSION=!OS_VERSION:~0,24!"
endlocal
goto :eof

rem %1 = start^|success^|cancel^|fail ; %2 = stage, only used by "fail".
rem Everything is swallowed on purpose: a dead endpoint can never break an install.
:telemetry
if "%IP_SWITCH_TELEMETRY%"=="0" goto :eof
if not defined CURL_EXE goto :eof
call :get_os_version
call :get_device_id
set "TELE_URL=%IP_SWITCH_TELEMETRY_URL%"
if not defined TELE_URL set "TELE_URL=https://t.ipswitch.cloud/i"
rem The arguments must be copied into ordinary variables first: %1 and %2 are
rem position parameters and are not expanded inside a parenthesised block.
set "EV=%~1"
set "STG=%~2"
if not defined STG set "STG=unknown"
set "BODY_PRE={\\?e\\?:\?!EV!\?,\\?v\\?:\?%SCRIPT_VERSION%\?,\\?os\\?:\?windows\?,\\?osver\\?:\?!OS_VERSION!\?,\\?ps\\?:\?cmd\?,\\?l\\?:\?!SCRIPT_LANG!\?,\\?clients\\?:\?!CLS!\?,\\?stage\\?:\?!STG!\?,\\?d\\?:\?!DEV_ID!\?,\\?day\\?:\?!DAY!\?}"
setlocal EnableDelayedExpansion
set "CLS="
if "!SEL_WB!"=="1" set "CLS=wb"
if "!SEL_CODEX!"=="1" (
    if defined CLS (set "CLS=!CLS!,codex") else (set "CLS=codex")
)
if not defined CLS set "CLS=,"
call :get_utc_day
set "BODY=!BODY_PRE!"
rem -m 3 caps the wait; the result is discarded and the exit code is ignored on
rem purpose, so telemetry can neither hang nor fail the install.
"!CURL_EXE!" -s -m 3 -o nul -X POST -H "Content-Type: application/json" -d "!BODY!" "!TELE_URL!" >nul 2>&1
endlocal
goto :eof

rem -- UTC date as yyyy-mm-dd, without wmic ---------------------------------
rem    wmic is deprecated and absent on some Windows installs, so the date is
rem    derived from %DATE% instead. Only the digits are kept, which sidesteps
rem    every locale separator. A parse failure is not worth failing an install
rem    over, so "unknown" is a valid answer.
rem    Note: "for /f ... in ("x")" would treat x as a file name, so the digits
rem    are pulled out with a plain "for" over the string instead.
:get_utc_day
setlocal EnableDelayedExpansion
set "DAY=unknown"
set "D_RAW=%DATE%"
set "D_DIGITS=%D_RAW%"
for %%X in (0 1 2 3 4 5 6 7 8 9) do set "D_DIGITS=!D_DIGITS:%%X=!"
if "!D_DIGITS!"=="" goto :day_done
rem Strip the weekday name that some locales prepend, keeping digits only.
set "D_ALL=!D_DIGITS!"
set "D_DIGITS="
:keep_digits
if "!D_ALL!"=="" goto :digits_done
set "D_CH=!D_ALL:~0,1!"
set "D_ALL=!D_ALL:~1!"
rem "0123456789" delims returns the leading non-digit run; an empty result
rem means the first character is a digit, so keep it.
set "D_PRE="
for /f "delims=0123456789" %%X in ("!D_CH!") do set "D_PRE=%%X"
if not defined D_PRE set "D_DIGITS=!D_DIGITS!!D_CH!"
goto :keep_digits
:digits_done
rem Now D_DIGITS is a pure digit run; the date is yyyymmdd in the zh-CN and
rem en-US layouts. A leading 19 or 20 means the run starts with a year; any
rem other layout falls back to "unknown" rather than sending a wrong date.
if "!D_DIGITS:~8!"=="" goto :day_done
set "D_A=!D_DIGITS:~0,4!"
set "D_B=!D_DIGITS:~4,2!"
set "D_C=!D_DIGITS:~6,2!"
if "!D_A:~0,2!"=="19" set "DAY=!D_A!-!D_B!-!D_C!" & goto :day_done
if "!D_A:~0,2!"=="20" set "DAY=!D_A!-!D_B!-!D_C!" & goto :day_done
:day_done
rem The result is handed back through a file: DAY belongs to this setlocal, so
rem reading it after endlocal would give the outer, still-unset value.
> "%TEMP%\ip-switch-day.txt" echo !DAY!
endlocal
set "DAY=unknown"
if exist "%TEMP%\ip-switch-day.txt" (
    for /f "usebackq tokens=*" %%D in (`type "%TEMP%\ip-switch-day.txt"`) do set "DAY=%%D"
    del /f /q "%TEMP%\ip-switch-day.txt" >nul 2>&1
)
goto :eof

rem ===========================================================================
rem  Locate the external tools
rem ===========================================================================
:locate_tools
set "CURL_EXE="
set "NODE_FALLBACK="
set "NPM_FALLBACK="
for /f "usebackq delims=" %%A in (`where curl.exe 2^>nul`) do if not defined CURL_EXE set "CURL_EXE=%%A"
rem tar: prefer the System32 bsdtar; a GNU tar earlier on PATH cannot unzip.
set "TAR_EXE="
if exist "%SystemRoot%\System32\tar.exe" set "TAR_EXE=%SystemRoot%\System32\tar.exe"
for /f "usebackq delims=" %%A in (`where node.exe 2^>nul`) do if not defined NODE_FALLBACK set "NODE_FALLBACK=%%A"
for /f "usebackq delims=" %%A in (`where npm.cmd 2^>nul`) do if not defined NPM_FALLBACK set "NPM_FALLBACK=%%A"
goto :eof

rem ===========================================================================
rem  Check the npm environment
rem ===========================================================================
rem    Does not depend on the IDE-bundled node. Only two paths:
rem      ^(1^) system PATH has node+npm -> use the system one directly;
rem      ^(2^) otherwise download a standalone Node.js from nodejs.org into a fixed
rem          directory ~\.nodejs\node ^(fixed path, easy to trace, does not
rem          pollute the system^).
:check_npm
call :step "Checking the npm environment"
call :locate_tools
set "NODE_EXE="
set "NPM_CLI="
set "NPM_CMD="
for /f "usebackq delims=" %%A in (`where node.exe 2^>nul`) do if not defined NODE_EXE set "NODE_EXE=%%A"
for /f "usebackq delims=" %%A in (`where npm.cmd 2^>nul`) do if not defined NPM_CMD set "NPM_CMD=%%A"

rem npm is a batch shim: running "npm.cmd ..." from a batch file ends the
rem calling script, so the lines after it never ran and every npm failure was
rem reported as a success. npm is therefore always launched as
rem "node <npm-cli.js>", which behaves like any other program. NPM_CMD is kept
rem only as a last resort.
if not defined NODE_EXE goto :npm_no_cli
for %%D in ("%NODE_EXE%") do set "NODEDIR=%%~dpD"
if exist "%NODEDIR%node_modules\npm\bin\npm-cli.js" set "NPM_CLI=%NODEDIR%node_modules\npm\bin\npm-cli.js"
:npm_no_cli
if defined NPM_CLI goto :npm_have_cli
if exist "%APPDATA%\npm\node_modules\npm\bin\npm-cli.js" set "NPM_CLI=%APPDATA%\npm\node_modules\npm\bin\npm-cli.js"
:npm_have_cli
if not defined NPM_CLI goto :npm_cli_missing
call :ok "Using system Node.js: %NODE_EXE%"
goto :eof

:npm_cli_missing
call :install_npm_official
goto :eof

rem -- Download a standalone Node.js ^(with npm^) from nodejs.org ----------------
:install_npm_official
call :warn "System Node.js not found; downloading Node.js 22 LTS from nodejs.org..."
set "FINAL=%USERPROFILE%\.nodejs\node"

rem Reuse first: a complete install ^(with npm^) must not be re-downloaded, because
rem deleting it fails while the MCP process holds node.exe, and repeated
rem reinstalls are pointless.
if exist "%FINAL%\node.exe" if exist "%FINAL%\node_modules\npm\bin\npm-cli.js" (
    call :info "Existing Node.js detected, reusing: %FINAL%"
    set "NODE_EXE=%FINAL%\node.exe"
    set "NPM_CLI=%FINAL%\node_modules\npm\bin\npm-cli.js"
    goto :eof
)

if not defined TAR_EXE (
    call :err "Cannot install Node.js automatically: tar.exe is missing"
    call :info "Install Node.js 18+ manually: https://nodejs.org"
    set "RC=1"
    goto :finish
)
if not defined NODE_FALLBACK (
    call :err "Cannot install Node.js automatically: node.exe is missing ^(needed to read the version list^)"
    call :info "Install Node.js 18+ manually: https://nodejs.org"
    set "RC=1"
    goto :finish
)
if not defined CURL_EXE (
    call :err "Cannot install Node.js automatically: curl.exe is missing"
    call :info "Install Node.js 18+ manually: https://nodejs.org"
    set "RC=1"
    goto :finish
)

rem Clean up a temp extraction dir possibly left by an interrupted run
set "TMPDIR=%USERPROFILE%\.nodejs\.tmp"
if exist "%TMPDIR%" rd /s /q "%TMPDIR%" >nul 2>&1
mkdir "%TMPDIR%"

rem Resolve the latest v22.x. The old index.json under dist/latest-v22.x now
rem answers 404, so the file list is read instead: the win-<arch> zip name
rem embeds the version. Falls back to a fixed LTS on any failure.
set "VER="
set "SHAFILE=%TMPDIR%\SHASUMS256.txt"
"%CURL_EXE%" -sSL --max-time 30 -o "%SHAFILE%" "https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt" >nul 2>&1
if exist "%SHAFILE%" for /f "usebackq delims=" %%V in (`node -e "const s=require('fs').readFileSync(process.argv[1],'utf8');const m=s.match(/node-(v[0-9.]+)-win-x64\.zip/);console.log(m?m[1]:'')" "%SHAFILE%"`) do set "VER=%%V"
if not defined VER set "VER=v22.14.0"

set "ARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=arm64"
set "ZIPURL=https://nodejs.org/dist/%VER%/node-%VER%-win-%ARCH%.zip"
set "ZIPPATH=%TEMP%\node-%VER%-win-%ARCH%.zip"
call :info "Downloading: %ZIPURL%"
"%CURL_EXE%" -sSL --max-time 600 -o "%ZIPPATH%" "%ZIPURL%"
if not exist "%ZIPPATH%" (
    call :err "Download failed; install Node.js manually: https://nodejs.org"
    set "RC=1"
    goto :finish
)
call :info "Extracting..."
"%TAR_EXE%" -xf "%ZIPPATH%" -C "%TMPDIR%"
if errorlevel 1 (
    call :err "Extraction failed; install Node.js manually: https://nodejs.org"
    set "RC=1"
    goto :finish
)

rem The zip holds a node-<ver>-win-<arch>/ subfolder; find it and normalize the
rem name to "node" so the path stays stable across upgrades.
set "SRCDIR="
for /d %%D in ("%TMPDIR%\node-*") do (
    if exist "%%~fD\node.exe" if not defined SRCDIR set "SRCDIR=%%~fD"
)
if not defined SRCDIR (
    call :err "Download/extract failed; install Node.js manually: https://nodejs.org"
    set "RC=1"
    goto :finish
)

rem If the old directory is locked by a running MCP it cannot be deleted: fail
rem with a clear message instead of silently continuing.
if exist "%FINAL%" (
    rd /s /q "%FINAL%" >nul 2>&1
    if exist "%FINAL%" (
        call :err "Old install directory is locked and cannot be replaced: %FINAL%"
        call :info "Exit the Codex / WorkBuddy ip-switch MCP ^(or kill the process holding node.exe^) first, then retry."
        call :info "The installed version keeps working; no functional impact."
        set "RC=1"
        goto :finish
    )
)
move "%SRCDIR%" "%FINAL%" >nul 2>&1

set "NODE_EXE=%FINAL%\node.exe"
set "NPM_CLI=%FINAL%\node_modules\npm\bin\npm-cli.js"
if not exist "%NPM_CLI%" (
    call :err "npm installation failed; install Node.js manually: https://nodejs.org"
    set "RC=1"
    goto :finish
)
rd /s /q "%TMPDIR%" >nul 2>&1

set "NPMVER="
for /f "usebackq delims=" %%A in (`"%NODE_EXE%" "%NPM_CLI%" --version 2^>nul`) do set "NPMVER=%%A"
call :ok "Installed Node.js %VER% ^(npm %NPMVER%^) -^> %FINAL%"
goto :eof

rem -- Run an npm command -------------------------------------------------------
rem    npm is a JS script run by node. The downloaded node is not on the system
rem    PATH, and on Windows "npm run" executes node_modules/.bin/*.cmd ^(e.g.
rem    tsc.cmd^) which locate node via PATH -- so the node dir is prepended to
rem    the process-local PATH first. No system change; restored right after.
rem    %1 = subcommand, the rest = extra args.
rem
rem    The result is returned in NPM_RC, NOT through "exit /b". In a "call"
rem    chain an "exit /b" out of a nested routine ended the whole script: the
rem    caller's next line never ran, so a failing tsc looked like a passing build
rem    and the installer went on to announce "Deployment complete".
rem -- Run an npm command -------------------------------------------------------
rem    npm is a JS script run by node. The downloaded node is not on the system
rem    PATH, and on Windows "npm run" executes node_modules/.bin/*.cmd ^(e.g.
rem    tsc.cmd^) which locate node via PATH -- so the node dir is prepended to
rem    the process-local PATH first. No system change; restored right after.
rem    %1 = subcommand, %2..%4 = extra args. The result comes back in NPM_RC.
rem
rem    Two earlier shapes both broke the run:
rem      - "exit /b" ended the whole script, so the caller's next line never ran
rem        and a failing tsc looked like a passing build;
rem      - the argument loop used its own labels, and a "goto :eof" out of a
rem        nested "call" lost the call frame, which surfaced as
rem        "the system cannot find the batch label specified" on the next call.
rem    Only three extra args are ever needed here, so they are read positionally
rem    and the routine has no loop and no helper of its own.
rem -- Run an npm command -------------------------------------------------------
rem    npm is a JS script run by node. The downloaded node is not on the system
rem    PATH, and on Windows "npm run" executes node_modules/.bin/*.cmd ^(e.g.
rem    tsc.cmd^) which locate node via PATH -- so the node dir is prepended to
rem    the process-local PATH first. No system change; restored right after.
rem    %1 = subcommand, %2..%4 = extra args. The result comes back in NPM_RC.
rem
rem    The exit code is turned into NPM_RC twice, by two independent mechanisms,
rem    and the caller checks both. That redundancy is deliberate: this routine is
rem    the one that decides whether a failed build stops the install, and every
rem    single-method version tried here mis-reported a broken build as good.
rem      - "exit /b" ended the whole script, so the caller's next line never ran;
rem      - "if errorlevel 1" alone cannot tell 1 from 2, so the exact value is
rem        also written to a temp file by cmd itself and read back;
rem      - a helper subroutine for either step lost the call frame and produced
rem        "the system cannot find the batch label specified" on the next call,
rem        so both mechanisms are inlined here with no subroutine and no goto.
:invoke_npm
set "NPM_SUBCMD=%~1"
rem The leading space matters: the command is assembled as
rem "%NPM_SUBCMD%%NPM_EXTRA%", and without it "run" + "build" is "runbuild".
set "NPM_EXTRA= %~2 %~3 %~4"
set "NPM_RC=0"
if not defined NPM_CLI goto :npm_cmd_path
for %%D in ("%NODE_EXE%") do set "NODEDIR=%%~dpD"
set "SAVED_PATH=%PATH%"
set "PATH=%NODEDIR%;%PATH%"
"%NODE_EXE%" "%NPM_CLI%" %NPM_SUBCMD%%NPM_EXTRA%
goto :npm_after

:npm_cmd_path
if defined NPM_CMD goto :npm_cmd_run
rem No npm at all: the precheck catches this, so this is only a safety net.
set "NPM_RC=1"
goto :eof

:npm_cmd_run
"%NPM_CMD%" %NPM_SUBCMD%%NPM_EXTRA%

:npm_after
if defined SAVED_PATH set "PATH=%SAVED_PATH%"
rem npm is launched as "node npm-cli.js", so its status is readable here with a
rem plain "if errorlevel" chain. The exact value is not needed, only zero vs
rem non-zero, and "if errorlevel 1" already means ">= 1".
set "NPM_RC=0"
if not errorlevel 1 goto :eof
set "NPM_RC=1"
goto :eof

:npm_via_cli
for %%D in ("%NODE_EXE%") do set "NODEDIR=%%~dpD"
set "SAVED_PATH=%PATH%"
set "PATH=%NODEDIR%;%PATH%"
"%NODE_EXE%" "%NPM_CLI%" %NPM_SUBCMD%%NPM_EXTRA%
rem The exit code is read right here, not through a helper: inside "if (...)"
rem every %ERRORLEVEL% is expanded before the block runs, and a called routine
rem starts with its own ERRORLEVEL. Either way a failing tsc read as success.
> "%TEMP%\ip-switch-rc.txt" echo %ERRORLEVEL%
for /f "usebackq tokens=*" %%R in (`type "%TEMP%\ip-switch-rc.txt"`) do set "NPM_RC=%%R"
del /f /q "%TEMP%\ip-switch-rc.txt" >nul 2>&1
set "PATH=%SAVED_PATH%"
goto :eof

:npm_via_cmd
"%NPM_CMD%" %NPM_SUBCMD%%NPM_EXTRA%
> "%TEMP%\ip-switch-rc.txt" echo %ERRORLEVEL%
for /f "usebackq tokens=*" %%R in (`type "%TEMP%\ip-switch-rc.txt"`) do set "NPM_RC=%%R"
del /f /q "%TEMP%\ip-switch-rc.txt" >nul 2>&1
goto :eof

rem ===========================================================================
rem  Check git
rem ===========================================================================
:check_git
call :step "Checking the Git environment"
set "GIT_EXE="
for /f "usebackq delims=" %%A in (`where git.exe 2^>nul`) do if not defined GIT_EXE set "GIT_EXE=%%A"
if defined GIT_EXE goto :git_ok

call :warn "git not detected; installing automatically..."

set "ARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=arm64"
call :info "Detected CPU architecture: %ARCH%"

rem -- Option 1: Git is installed but not on PATH -------------------------------
set "GITDIR=%LOCALAPPDATA%\Git"
set "KNOWN="
if exist "%GITDIR%\cmd\git.exe" set "KNOWN=%GITDIR%\cmd"
if not defined KNOWN if exist "%GITDIR%\bin\git.exe" set "KNOWN=%GITDIR%\bin"
if not defined KNOWN if exist "%ProgramFiles%\Git\cmd\git.exe" set "KNOWN=%ProgramFiles%\Git\cmd"
if not defined KNOWN if exist "%ProgramFiles(x86)%\Git\cmd\git.exe" set "KNOWN=%ProgramFiles(x86)%\Git\cmd"
if defined KNOWN goto :git_known
goto :git_download

rem -- Option 2: download and install silently ----------------------------------
call :download_git_installer
if not defined GIT_INSTALLER (
    call :err "Git download failed; install manually: https://git-scm.com/download/win"
    set "RC=1"
    goto :finish
)

call :info "Silently installing Git into %GITDIR% ..."
start "" /wait "%GIT_INSTALLER%" /VERYSILENT /NORESTART /CURRENTUSER /DIR="%GITDIR%" /NOICONS
set "GITRC=%ERRORLEVEL%"
del /f /q "%GIT_INSTALLER%" >nul 2>&1
if not "%GITRC%"=="0" (
    call :err "Git installation failed ^(exit code: %GITRC%^)"
    call :info "Install manually: https://git-scm.com/download/win"
    set "RC=1"
    goto :finish
)

call :add_git_to_path "%GITDIR%"
set "PATH=%GITDIR%\cmd;%PATH%"
if exist "%GITDIR%\bin\git.exe" set "PATH=%GITDIR%\bin;%PATH%"
set "GIT_EXE=%GITDIR%\cmd\git.exe"
for /f "usebackq delims=" %%A in (`"%GIT_EXE%" --version 2^>nul`) do set "GITVER=%%A"
call :ok "git installed: %GITVER%"
goto :eof

rem -- Success exits. These are separate labels rather than if (...) blocks on
rem    purpose: inside a block every variable is expanded before the block runs,
rem    so a value set inside the block would still read as empty on the next line
rem    of that same block.
:git_ok
set "GITVER="
for /f "usebackq delims=" %%A in (`git --version 2^>nul`) do set "GITVER=%%A"
call :ok "%GITVER% ^(%GIT_EXE%^)"
goto :eof

:git_known
call :info "Existing Git detected: %KNOWN%; repairing PATH..."
set "PATH=%KNOWN%;%PATH%"
set "GIT_EXE=%KNOWN%\git.exe"
set "GITVER="
for /f "usebackq delims=" %%A in (`git --version 2^>nul`) do set "GITVER=%%A"
call :ok "%GITVER% ^(%GIT_EXE%^)"
goto :eof

:git_download

rem -- Download the Git installer; sets GIT_INSTALLER on success ----------------
rem    %1 = arch. Sources are tried in order, CN mirrors first.
:download_git_installer
set "GIT_INSTALLER="
if not defined CURL_EXE (
    call :err "curl.exe is required to download Git automatically"
    goto :eof
)

set "TAG="
call :info "Querying the latest Git for Windows version..."
set "APIFILE=%TEMP%\git-release.json"
"%CURL_EXE%" -sSL --max-time 15 -A "Mozilla/5.0" -o "%APIFILE%" "https://api.github.com/repos/git-for-windows/git/releases/latest" >nul 2>&1
if exist "%APIFILE%" for /f "usebackq tokens=2 delims=:, " %%A in (`findstr /c:"tag_name" "%APIFILE%"`) do if not defined TAG set "TAG=%%~A"
if not defined TAG (
    call :warn "  Could not fetch the latest version; using the built-in one"
    set "TAG=v2.55.0.windows.3"
)
call :info "  Latest official version: %TAG%"

rem tag=v2.55.0.windows.3 -> the file name uses 2.55.0.3 ^(strip "v" and ".windows."^)
set "VER=%TAG%"
if /i "%VER:~0,1%"=="v" set "VER=%VER:~1%"
set "FILEVER=%VER:.windows.=%"
set "SUFFIX=64-bit"
if /i "%~1"=="arm64" set "SUFFIX=arm64"
set "FILENAME=Git-%FILEVER%-%SUFFIX%.exe"
call :info "  Installer file name: %FILENAME%"

set "INSTALLER_PATH=%TEMP%\git-installer-%~1.exe"
if exist "%INSTALLER_PATH%" del /f /q "%INSTALLER_PATH%" >nul 2>&1

rem Source 1: NPMMirror CDN ^(fastest in CN, direct CDN, no redirect^)
call :try_git_url "https://cdn.npmmirror.com/binaries/git-for-windows/%TAG%/%FILENAME%" "%INSTALLER_PATH%"
if defined GIT_INSTALLER goto :eof
rem Source 2: NPMMirror registry ^(redirects to the CDN^)
call :try_git_url "https://registry.npmmirror.com/-/binary/git-for-windows/%TAG%/%FILENAME%" "%INSTALLER_PATH%"
if defined GIT_INSTALLER goto :eof
rem Source 3: Tsinghua TUNA mirror
call :try_git_url "https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/LatestRelease/%FILENAME%" "%INSTALLER_PATH%"
if defined GIT_INSTALLER goto :eof
rem Source 4: GitHub official ^(fallback^)
call :try_git_url "https://github.com/git-for-windows/git/releases/download/%TAG%/%FILENAME%" "%INSTALLER_PATH%"
goto :eof

rem %1 = url, %2 = destination. Sets GIT_INSTALLER when the file looks complete.
rem -A is required: some mirrors reject the default curl user agent.
:try_git_url
call :info "Trying download: %~1"
setlocal EnableDelayedExpansion
"%CURL_EXE%" -sSL --max-time 600 -A "Mozilla/5.0 ^(Windows NT 10.0; Win64; x64^)" -o "%~2" "%~1"
if not exist "%~2" (
    call :warn "  File missing after download; trying the next source..."
    endlocal
    goto :eof
)
set "FSIZE=0"
for %%A in ("%~2") do set "FSIZE=%%~zA"
rem Below 50 MB means an HTML error page or a truncated transfer, not Git.
if !FSIZE! LSS 50000000 (
    call :warn "  File too small ^(!FSIZE! bytes^), possibly incomplete; trying the next source..."
    del /f /q "%~2" >nul 2>&1
    endlocal
    goto :eof
)
call :info "  Download complete: !FSIZE! bytes"
set "GIT_INSTALLER=%~2"
endlocal & set "GIT_INSTALLER=%~2"
goto :eof

rem -- Add the Git directory to the user PATH, no popup --------------------------
:add_git_to_path
set "ADDP="
if exist "%~1\cmd\git.exe" set "ADDP=%ADDP%;%~1\cmd"
if exist "%~1\bin\git.exe" set "ADDP=%ADDP%;%~1\bin"
if not defined ADDP goto :eof

rem The user PATH is REG_EXPAND_SZ and may legitimately contain things like
rem %SystemRoot%, so it is read from a file and written back through a file too
rem instead of going through "set", which would expand the percent signs.
set "PATHBAK=%TEMP%\ip-switch-userpath.txt"
reg query "HKCU\Environment" /v Path > "%PATHBAK%" 2>nul
if not exist "%PATHBAK%" goto :eof
set "CURPATH="
for /f "usebackq tokens=2,*" %%A in (`findstr /i /c:"Path" "%PATHBAK%"`) do set "CURPATH=%%B"
del /f /q "%PATHBAK%" >nul 2>&1
if not defined CURPATH goto :eof

setlocal EnableDelayedExpansion
set "NEW=!CURPATH!"
for %%P in (%ADDP%) do (
    set "NEEDADD=1"
    echo !NEW! | find /i /c "%%~P" >nul 2>&1 && set "NEEDADD=0"
    if "!NEEDADD!"=="1" set "NEW=!NEW!;%%~P"
)
set "NEWFILE=%TEMP%\ip-switch-pathval.txt"
> "!NEWFILE!" echo !NEW!
endlocal
reg add "HKCU\Environment" /v Path /t REG_EXPAND_SZ /f /d "%NEW%" >nul 2>&1
del /f /q "%TEMP%\ip-switch-pathval.txt" >nul 2>&1
goto :eof

rem ===========================================================================
rem  Clone the repository
rem ===========================================================================
:clone_repo
call :step "Cloning the project repository"

if exist "%INSTALL_DIR%\.git" (
    call :warn "Target directory exists; running git pull to update..."
    pushd "%INSTALL_DIR%"
    git fetch origin %BRANCH%
    git checkout %BRANCH%
    git pull origin %BRANCH%
    popd
    call :ok "Project updated: %INSTALL_DIR%"
    goto :eof
)

call :info "Repository URL: %REPO_URL%"
call :info "Target branch: %BRANCH%"
call :info "Install directory: %INSTALL_DIR%"
echo.
rem set /p cannot distinguish a bare Enter from a closed stdin: both leave the
rem variable empty and both set ERRORLEVEL 1. install.ps1 checks for a null
rem Read-Host result, which cmd has no equivalent for. Treating both as "use the
rem suggested directory" matches what a human pressing Enter means, and keeps the
rem installer usable from a pipe or a scheduled task. Only an explicit q / no /
rem cancel aborts.
set "RAWDIR="
set /p "RAWDIR=Install to this directory? [Enter=confirm / q=quit / or type a new path]"
if "%RAWDIR%"=="" goto :dir_default
call :is_cancel "%RAWDIR%"
if "%IS_CANCEL%"=="1" goto :stop_cancelled
set "INSTALL_DIR=%RAWDIR%"
call :info "Install directory updated: %INSTALL_DIR%"

:dir_default
rem Create the parent directory if it does not exist
for %%A in ("%INSTALL_DIR%") do set "PARENT=%%~dpA"
if not exist "%PARENT%" mkdir "%PARENT%"

rem DNS warm-up: fail early and clearly instead of letting git report a
rem confusing network error thirty seconds later.
call :repo_host "%REPO_URL%" HOST
call :info "Warming up DNS: ping %HOST% ..."
ping -n 1 %HOST% >nul 2>&1
if errorlevel 1 (
    call :err "Cannot resolve the repository host: %HOST%"
    call :info "Check your network connection and DNS settings"
    set "RC=1"
    goto :finish
)
call :ok "Host reachable: %HOST%"

set "MAXRETRIES=3"
set "CLONE_OK=0"
set /a ATTEMPT=0
:clone_loop
set /a ATTEMPT+=1
if %ATTEMPT% GTR %MAXRETRIES% goto :clone_failed
if %ATTEMPT% GTR 1 (
    rem Clean up leftovers from the previous failed attempt
    rd /s /q "%INSTALL_DIR%" >nul 2>&1
    call :info "Retry clone attempt %ATTEMPT% / %MAXRETRIES%..."
    ping -n 4 127.0.0.1 >nul 2>&1
) else (
    call :info "Cloning: %REPO_URL% ^(branch: %BRANCH%^)"
)
git clone --branch %BRANCH% --depth 1 "%REPO_URL%" "%INSTALL_DIR%"
if not errorlevel 1 (
    set "CLONE_OK=1"
    goto :clone_done
)
call :warn "Clone failed ^(attempt %ATTEMPT% / %MAXRETRIES%^)"
goto :clone_loop

:clone_done
call :ok "Clone succeeded: %INSTALL_DIR%"
goto :eof

:clone_failed
echo.
call :err "Clone failed ^(retried %MAXRETRIES% times^)"
call :info ""
call :info "Please check:"
call :info "  1. The repository URL is correct: %REPO_URL%"
call :info "  2. Your network connection"
call :info "  3. For a private repo, configure an SSH key first"
call :info ""
call :info "Manual steps:"
call :info "  git clone %REPO_URL% %INSTALL_DIR%"
set "RC=1"
goto :finish

rem %1 = url, %2 = variable name that receives the host.
rem    node is already a hard requirement of this installer, and its URL parser
rem    is exact, whereas doing it in cmd needs a chain of fragile substitutions:
rem    "https://host" turned into "https///host" the moment every colon was
rem    replaced first, and a bare "for" leaves the last token rather than the
rem    first one.
:repo_host
set "%~2="
set "HOSTPART="
if not defined NODE_EXE for /f "usebackq delims=" %%A in (`where node.exe 2^>nul`) do if not defined NODE_EXE set "NODE_EXE=%%A"
if not defined NODE_EXE goto :eof
if exist "%TEMP%\ip-switch-host.txt" del /f /q "%TEMP%\ip-switch-host.txt" >nul 2>&1
"%NODE_EXE%" -e "const fs=require('fs');let s=process.argv[1].trim();s=s.replace(/^[a-zA-Z]+:\/\//,'').replace(/^[^@]*@/,'');const h=s.split('/')[0].split(':')[0];if(h)fs.writeFileSync(process.argv[2],h)" "%~1" "%TEMP%\ip-switch-host.txt" >nul 2>&1
if not exist "%TEMP%\ip-switch-host.txt" goto :eof
for /f "usebackq tokens=*" %%H in (`type "%TEMP%\ip-switch-host.txt"`) do set "HOSTPART=%%H"
del /f /q "%TEMP%\ip-switch-host.txt" >nul 2>&1
if defined HOSTPART set "%~2=%HOSTPART%"
goto :eof

rem ===========================================================================
rem  Install dependencies
rem ===========================================================================
:install_deps
call :step "Installing npm dependencies"
pushd "%INSTALL_DIR%"
rem Labels, not a block: a "goto" inside "if (...)" leaves the caller's context.
if exist "package.json" goto :deps_have_pkg
call :err "package.json not found; unexpected project layout"
popd
set "RC=1"
goto :finish

:deps_have_pkg
call :info "Installing dependencies, please wait..."
call :invoke_npm "install" "--loglevel=error"
rem NPM_RC, not "if not errorlevel": the helper reports through a variable, and
rem this check used to sit inside a block whose "goto :eof" left the caller.
if not "%NPM_RC%"=="0" goto :deps_failed
call :ok "Dependencies installed"
popd
goto :eof

:deps_failed
call :err "Dependency installation failed ^(npm exit code: %NPM_RC%^)"
call :info "This is usually a full disk: npm extracts a tarball and a short write leaves a truncated file."
call :info "Check free space, then: cd %INSTALL_DIR% ^& rmdir /s /q node_modules ^& npm install"
popd
set "RC=1"
goto :finish

rem ===========================================================================
rem  Build TypeScript
rem ===========================================================================
:build_project
call :step "Building TypeScript"
pushd "%INSTALL_DIR%"

rem Clear Electron env interference ^(may be set by the WorkBuddy environment^)
set "SAVED_ELECTRON=%ELECTRON_RUN_AS_NODE%"
set "SAVED_NODEOPTS=%NODE_OPTIONS%"
set "ELECTRON_RUN_AS_NODE="
set "NODE_OPTIONS="

call :info "Building..."
rem The previous output is removed so a stale dist\index.js cannot make the
rem "verified" check below pass after a failed build. The delete runs from
rem outside the tree on purpose: removing the directory the shell currently sits
rem in invalidates the shell's directory handle, and the next "call" then failed
rem with "the system cannot find the batch label specified".
pushd "%TEMP%"
if exist "%INSTALL_DIR%\dist" rd /s /q "%INSTALL_DIR%\dist" >nul 2>&1
popd
pushd "%INSTALL_DIR%"
call :invoke_npm "run" "build"
rem NPM_RC, not %ERRORLEVEL%: the helper returns through a variable because an
rem "exit /b" inside a nested "call" ended the whole script before this line ran.

set "ELECTRON_RUN_AS_NODE=%SAVED_ELECTRON%"
set "NODE_OPTIONS=%SAVED_NODEOPTS%"

rem A build failure must stop the run. This check used to live inside an
rem "if (...)" block with a "goto :finish" inside it, and a goto inside a block
rem leaves the caller's context: tsc would report its errors, the script would
rem carry on, write every client config and then announce "Deployment complete"
rem with a broken build. Labels keep the jump on the same path.
rem
rem Whether the build succeeded is decided by npm's exit code AND by the build
rem output. Both are needed: tsc still writes dist\index.js when it reports type
rem errors, so the file alone would accept a broken build. npm is launched as
rem "node npm-cli.js" rather than "npm.cmd" because the batch shim ends the
rem calling script, which is what hid these failures in the first place.
if not "%NPM_RC%"=="0" goto :build_failed
if exist "%INSTALL_DIR%\dist\index.js" goto :build_ok
call :err "Build produced no dist\index.js although npm reported success"
call :info "Nothing was installed; the previous build is still in place."
call :info "Build manually to see the error: cd /d %INSTALL_DIR% ^& npm run build"
popd
set "RC=1"
goto :finish

:build_ok
call :ok "Build completed and verified: dist\index.js generated"
popd
goto :eof

:build_failed
call :err "Build failed ^(npm exit code: %NPM_RC%^) — see the tsc errors above"
call :info "Nothing was installed; the previous build is still in place."
call :info "Build manually to see the error: cd /d %INSTALL_DIR% ^& set ELECTRON_RUN_AS_NODE= ^& npm run build"
call :info "If the errors are TS7016/TS1005, a package was extracted incompletely: rmdir /s /q node_modules ^& npm install"
popd
set "RC=1"
goto :finish

rem ===========================================================================
rem  Detect MCP client platforms
rem ===========================================================================
:detect_mcp
call :step "Detecting MCP client platforms"
set "DET_WB=0"
set "DET_CODEX=0"
set "CODEX_BIN="
for /f "usebackq delims=" %%A in (`where codex 2^>nul`) do if not defined CODEX_BIN set "CODEX_BIN=%%A"

if exist "%USERPROFILE%\.workbuddy" (
    set "DET_WB=1"
    call :ok "WorkBuddy detected ^(%USERPROFILE%\.workbuddy^)"
)
if exist "%USERPROFILE%\.codex" set "DET_CODEX=1"
if defined CODEX_BIN set "DET_CODEX=1"
if not "%DET_CODEX%"=="0" call :ok "Codex detected ^(%USERPROFILE%\.codex^)"

if "%DET_WB%%DET_CODEX%"=="00" call :warn "Neither WorkBuddy nor Codex detected; printing a generic MCP config"
goto :eof

rem ===========================================================================
rem  Let the user choose which clients to install into
rem ===========================================================================
rem    Priority: -Clients argument > interactive prompt ^(Enter = all detected^).
rem    Results land in SEL_WB / SEL_CODEX; only the selected clients get MCP
rem    configs, skills and marketplace manifests.
:select_clients
call :step "Selecting target clients"
if defined CLIENTS goto :from_arg

echo.
echo Detected AI-agent clients:
if "%DET_WB%"=="1" echo   1^) WorkBuddy   ^(%USERPROFILE%\.workbuddy^)
if "%DET_CODEX%"=="1" echo   2^) Codex       ^(%USERPROFILE%\.codex^)
if "%DET_WB%%DET_CODEX%"=="00" echo   ^(none detected^)
echo.

rem Re-prompt until the answer is understood: a typo must never silently fall
rem through to the source-only install.
:ask_loop
set "SEL_WB=0"
set "SEL_CODEX=0"
set "ANS="
rem An empty answer means Enter, which selects every detected client. A closed
rem stdin lands here too and takes the same path, which keeps the installer
rem usable from a pipe or a scheduled task.
set /p "ANS=Install into which clients? [Enter=all detected / 1 / 2 / 0=source only / q=quit]"
if not defined ANS goto :pick_detected
call :is_cancel "%ANS%"
if "%IS_CANCEL%"=="1" goto :stop_cancelled

rem Only a single-token answer can be one of the shortcuts; a multi-token answer
rem such as "1,2" is classified token by token further down. Taking the first
rem token needs node, because a bare "for" leaves the last one behind and a
rem conditional inside the loop body would need delayed expansion to see it.
set "TOK1="
if defined NODE_EXE if exist "%TEMP%\ip-switch-tok.txt" del /f /q "%TEMP%\ip-switch-tok.txt" >nul 2>&1
if defined NODE_EXE "%NODE_EXE%" -e "const fs=require('fs');const t=process.argv[1].trim().split(/[\s,]+/).filter(Boolean)[0];if(t)fs.writeFileSync(process.argv[2],t)" "%ANS%" "%TEMP%\ip-switch-tok.txt" >nul 2>&1
if exist "%TEMP%\ip-switch-tok.txt" (
    for /f "usebackq tokens=*" %%T in (`type "%TEMP%\ip-switch-tok.txt"`) do set "TOK1=%%T"
    del /f /q "%TEMP%\ip-switch-tok.txt" >nul 2>&1
)
if not defined TOK1 goto :pick_detected
if /i "%TOK1%"=="default" goto :pick_detected
if /i "%TOK1%"=="d" goto :pick_detected
if /i "%TOK1%"=="a" goto :pick_all
if /i "%TOK1%"=="all" goto :pick_all
if /i "%TOK1%"=="0" goto :pick_none
if /i "%TOK1%"=="n" goto :pick_none
goto :parse_list

:pick_detected
if "%DET_WB%"=="1" set "SEL_WB=1"
if "%DET_CODEX%"=="1" set "SEL_CODEX=1"
goto :answer_ok

:pick_all
set "SEL_WB=1"
set "SEL_CODEX=1"
goto :answer_ok

:pick_none
goto :answer_ok

:parse_list
set "VALID=1"
rem ANS is already lowercased with commas turned into spaces, so the plain
rem "for" form iterates one client token at a time.
for %%C in (%ANS%) do call :classify "%%~C"
if "%VALID%"=="0" goto :ask_again
goto :answer_ok

:ask_again
call :warn "Not understood; please answer again: Enter=all detected / 1 / 2 / 0=source only / q=quit"
echo.
goto :ask_loop

:answer_ok
if "%SEL_WB%"=="1" call :ok "Will install into: WorkBuddy"
if "%SEL_CODEX%"=="1" call :ok "Will install into: Codex"
if "%SEL_WB%%SEL_CODEX%"=="00" (
    call :warn "No client selected; only the source build will be installed ^(client integration skipped^)"
    call :info "Rerun the installer later, or pass -Clients workbuddy,codex to add clients"
)
goto :eof

:cancelled_clients
goto :stop_cancelled

rem %1 = one client token from the interactive answer.
:classify
set "C=%~1"
if "%C%"=="" goto :eof
if /i "%C%"=="1" set "SEL_WB=1" & goto :eof
if /i "%C%"=="workbuddy" set "SEL_WB=1" & goto :eof
if /i "%C%"=="wb" set "SEL_WB=1" & goto :eof
if /i "%C%"=="2" set "SEL_CODEX=1" & goto :eof
if /i "%C%"=="codex" set "SEL_CODEX=1" & goto :eof
call :warn "Unknown selection '%C%'"
set "VALID=0"
goto :eof

rem -- -Clients argument ---------------------------------------------------------
:from_arg
call :validate_clients_list
if "%VALID%"=="0" goto :clients_bad
call :info "Clients selected via -Clients: workbuddy=%SEL_WB% codex=%SEL_CODEX%"
goto :eof

:clients_bad
call :err "Unknown client in -Clients ^(supported: workbuddy, codex, all, 0/n^)"
set "RC=1"
goto :finish

rem %1 = one client token from the -Clients list.
:classify_arg
set "C=%~1"
if "%C%"=="" goto :eof
if /i "%C%"=="all" (set "SEL_WB=1" & set "SEL_CODEX=1" & goto :eof)
if /i "%C%"=="workbuddy" set "SEL_WB=1" & goto :eof
if /i "%C%"=="wb" set "SEL_WB=1" & goto :eof
if /i "%C%"=="codex" set "SEL_CODEX=1" & goto :eof
rem "0" is the short form advertised at the prompt; "n" is its alias here. ^At the
rem interactive prompt "n" means "abort" instead -- different call site, and
rem -Clients is explicit, so there is no ambiguity.
if "%C%"=="0" goto :eof
if /i "%C%"=="n" goto :eof
call :err "Unknown client '%C%' ^(supported: workbuddy, codex, all, 0/n^)"
set "VALID=0"
goto :eof

rem ===========================================================================
rem  Write the MCP config
rem ===========================================================================
rem    Merging and serialization are delegated to node, which guarantees standard
rem    JSON ^(2-space indent, correctly escaped Windows paths^). The helper lives
rem    in a temp file rather than being passed to "node -e" because cmd treats
rem    several characters that JSON needs as its own metacharacters.
rem    %1 = platform dir, %2 = node exe, %3 = dist js
:write_mcp_config
set "TARGET=%~1\mcp.json"
if not exist "%~1" mkdir "%~1"
call :write_helper_js
if not exist "%HELPER_JS%" (
    call :err "Failed to write the MCP config: %TARGET%"
    set "RC=1"
    goto :finish
)
"%NODE_EXE%" "%HELPER_JS%" "%TARGET%" "%~2" "%~3"
if not "%ERRORLEVEL%"=="0" (
    call :err "Failed to write the MCP config: %TARGET%"
    set "RC=1"
    goto :finish
)
goto :eof

rem -- Write the shared node helper ----------------------------------------------
rem    Careful: this file is written with echo, so it must not contain the cmd
rem    metacharacters pipe, ampersand, redirect, caret or a doubled percent sign.
:write_helper_js
set "HELPER_JS=%TEMP%\ip-switch-write-mcp.js"
>"%HELPER_JS%" echo const fs = require('fs');
>>"%HELPER_JS%" echo const target = process.argv[2];
>>"%HELPER_JS%" echo const entry = { command: process.argv[3], args: [process.argv[4]] };
>>"%HELPER_JS%" echo let config = {};
>>"%HELPER_JS%" echo try {
>>"%HELPER_JS%" echo if (fs.existsSync(target)) { config = JSON.parse(fs.readFileSync(target, 'utf8')); }
>>"%HELPER_JS%" echo } catch (e) { config = {}; }
>>"%HELPER_JS%" echo if (!config.mcpServers) { config.mcpServers = {}; }
>>"%HELPER_JS%" echo config.mcpServers['ip-switch'] = entry;
>>"%HELPER_JS%" echo fs.writeFileSync(target, JSON.stringify(config, null, 2) + String.fromCharCode(10), 'utf8');
goto :eof

rem ===========================================================================
rem  Generate the WorkBuddy config
rem ===========================================================================
:generate_wb_config
call :step "Generating the WorkBuddy config"
if not defined NODE_EXE for /f "usebackq delims=" %%A in (`where node.exe 2^>nul`) do if not defined NODE_EXE set "NODE_EXE=%%A"
if not defined NODE_EXE (
    call :err "Node.js not found; cannot write the WorkBuddy MCP config"
    set "RC=1"
    goto :finish
)
set "DIST_JS=%INSTALL_DIR%\dist\index.js"

if "%SEL_WB%"=="1" (
    if not exist "%USERPROFILE%\.workbuddy" mkdir "%USERPROFILE%\.workbuddy"
    call :write_mcp_config "%USERPROFILE%\.workbuddy" "%NODE_EXE%" "%DIST_JS%"
    if not "%RC%"=="0" goto :eof
    call :ok "MCP config written: %USERPROFILE%\.workbuddy\mcp.json"
    call :info "Click 'Trust' for ip-switch in the WorkBuddy connector management page to enable it"
    goto :eof
)
call :warn "No client selected; no MCP config was written"
echo.
echo MCP config content:
echo {
echo   "mcpServers": {
echo     "ip-switch": {
echo       "command": "%NODE_EXE%",
echo       "args": ["%DIST_JS%"]
echo     }
echo   }
echo }
echo.
call :info "Manually add the config above to the corresponding client's mcp.json"
goto :eof

rem ===========================================================================
rem  Generate the Codex MCP direct config (installDir\.mcp.json)
rem ===========================================================================
rem    ^(1^) resolve Node.js ; ^(2^) validate the build output exists ;
rem    ^(3^) write installDir\.mcp.json with full paths, overwriting the fragile
rem    command:"node" version shipped in the repo.
:install_codex_mcp
call :step "Generating the Codex MCP direct config ^(.mcp.json^)"
if not defined NODE_EXE for /f "usebackq delims=" %%A in (`where node.exe 2^>nul`) do if not defined NODE_EXE set "NODE_EXE=%%A"
if not defined NODE_EXE (
    call :err "Node.js not found; cannot generate the Codex MCP config"
    set "RC=1"
    goto :finish
)
set "DIST_JS=%INSTALL_DIR%\dist\index.js"
if not exist "%DIST_JS%" (
    call :err "Build output missing: %DIST_JS%; build first ^(or drop -SkipBuild^)"
    set "RC=1"
    goto :finish
)
call :write_dot_mcp "%INSTALL_DIR%\.mcp.json" "%NODE_EXE%" "%DIST_JS%" "%INSTALL_DIR%"
set "CODEX_MCP_DIST=%DIST_JS%"
set "CODEX_MCP_NODE=%NODE_EXE%"
if exist "%INSTALL_DIR%\.mcp.json" (
    call :ok "Codex MCP direct config ready: %INSTALL_DIR%\.mcp.json"
    call :info "Takes effect after restarting Codex ^(plugin-page discovery is handled by the marketplace^)"
    goto :eof
)
call :err "Failed to generate the MCP config; check %INSTALL_DIR%\.mcp.json"
set "RC=1"
goto :finish

rem -- Write .mcp.json ^(full paths, cwd, timeouts^) ---------------------------
rem    %1 = target path, %2 = node, %3 = dist js, %4 = cwd
:write_dot_mcp
set "DOTMCP_JS=%TEMP%\ip-switch-write-dotmcp.js"
>"%DOTMCP_JS%" echo const fs = require('fs');
>>"%DOTMCP_JS%" echo const cfg = {
>>"%DOTMCP_JS%" echo mcpServers: {
>>"%DOTMCP_JS%" echo 'ip-switch': {
>>"%DOTMCP_JS%" echo command: process.argv[3],
>>"%DOTMCP_JS%" echo args: [process.argv[4]],
>>"%DOTMCP_JS%" echo cwd: process.argv[5],
>>"%DOTMCP_JS%" echo startup_timeout_sec: 30,
>>"%DOTMCP_JS%" echo tool_timeout_sec: 300
>>"%DOTMCP_JS%" echo }
>>"%DOTMCP_JS%" echo }
>>"%DOTMCP_JS%" echo };
>>"%DOTMCP_JS%" echo fs.writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2) + String.fromCharCode(10), 'utf8');
"%NODE_EXE%" "%DOTMCP_JS%" "%~1" "%~2" "%~3" "%~4"
goto :eof

rem ===========================================================================
rem  Register ip-switch in the Codex user-level config.toml
rem ===========================================================================
rem    The project-level .codex/config.toml can hold model / mcp_servers and
rem    similar keys, but no example ever puts [marketplaces.*] / [plugins.*] at
rem    project level, so the user-level file is the only stable globally visible
rem    channel. Every block is appended idempotently.
:append_codex_user_config
set "CODEX_CONFIG=%USERPROFILE%\.codex\config.toml"
if not exist "%CODEX_CONFIG%" (
    call :warn "%CODEX_CONFIG% not found; skipping marketplace/plugin/MCP registration ^(created automatically on the first codex run^)"
    goto :eof
)
set "MARKET_DIR=%USERPROFILE%\.codex\marketplaces\local"
set "TOML_APPEND=%TEMP%\ip-switch-codex-append.toml"
if exist "%TOML_APPEND%" del /f /q "%TOML_APPEND%"

findstr /i /c:"[marketplaces.local]" "%CODEX_CONFIG%" >nul 2>&1
if errorlevel 1 (
    >>"%TOML_APPEND%" echo [marketplaces.local]
    >>"%TOML_APPEND%" echo source_type = "local"
    >>"%TOML_APPEND%" echo source = '%MARKET_DIR%'
    >>"%TOML_APPEND%" echo.
)
findstr /i /c:"ip-switch@local" "%CODEX_CONFIG%" >nul 2>&1
if errorlevel 1 (
    >>"%TOML_APPEND%" echo [plugins."ip-switch@local"]
    >>"%TOML_APPEND%" echo enabled = true
    >>"%TOML_APPEND%" echo.
)
findstr /i /c:"[mcp_servers.ip-switch]" "%CODEX_CONFIG%" >nul 2>&1
if errorlevel 1 (
    if defined CODEX_MCP_NODE if defined CODEX_MCP_DIST (
        >>"%TOML_APPEND%" echo [mcp_servers.ip-switch]
        >>"%TOML_APPEND%" echo command = '%CODEX_MCP_NODE%'
        >>"%TOML_APPEND%" echo args = ['%CODEX_MCP_DIST%']
        >>"%TOML_APPEND%" echo cwd = '%INSTALL_DIR%'
        >>"%TOML_APPEND%" echo startup_timeout_sec = 30
        >>"%TOML_APPEND%" echo enabled = true
        >>"%TOML_APPEND%" echo.
    ) else (
        call :warn "Node/dist paths missing ^(prerequisite steps incomplete^); skipping the user-level [mcp_servers.ip-switch] registration"
    )
)

if not exist "%TOML_APPEND%" (
    call :info "The ip-switch marketplace, plugin, and MCP are already in the user-level config.toml; skipping"
    goto :eof
)

rem type + append keeps the original file's encoding and line endings intact.
set "TOML_SIZE=0"
for %%A in ("%CODEX_CONFIG%") do set "TOML_SIZE=%%~zA"
if "%TOML_SIZE%"=="0" (
    type "%TOML_APPEND%" > "%CODEX_CONFIG%"
) else (
    echo.>> "%CODEX_CONFIG%"
    type "%TOML_APPEND%" >> "%CODEX_CONFIG%"
)
del /f /q "%TOML_APPEND%" >nul 2>&1
call :ok "Registered the ip-switch marketplace, plugin, and mcp_servers into the user-level config.toml ^(globally visible; the mcp section is written by the script, no longer depending on CC Switch^)"
goto :eof

:install_codex_toml
call :step "Installing the Codex user-level config ^(the only stable globally-visible channel^)"
call :append_codex_user_config
goto :eof

rem ===========================================================================
rem  Create the desktop shortcut
rem ===========================================================================
rem    ^(1^) copy the codex_app.vbs launcher ^(runs silently via wscript, no
rem        console window^) ; ^(2^) copy codex.ico ; ^(3^) create a .lnk whose
rem    target is wscript.exe running that vbs.
rem    cmd cannot create a .lnk directly, so a small .vbs is generated and run
rem    through cscript.exe: the same COM object, without PowerShell.
:install_codex_shortcut
call :step "Creating the Codex desktop shortcut"
set "VBS_PATH=%INSTALL_DIR%\codex_app.vbs"
set "ICON_PATH=%INSTALL_DIR%\codex.ico"

if exist "%~dp0codex_app.vbs" (
    copy /y "%~dp0codex_app.vbs" "%VBS_PATH%" >nul
    if exist "%VBS_PATH%" (echo [ OK ]  Copied codex_app.vbs to %VBS_PATH%) else (echo [WARN]  Could not copy codex_app.vbs)
) else (
    if not exist "%VBS_PATH%" echo [WARN]  codex_app.vbs not found in the install directory
)
if exist "%~dp0codex.ico" (
    copy /y "%~dp0codex.ico" "%ICON_PATH%" >nul
    if exist "%ICON_PATH%" (echo [ OK ]  Copied codex.ico to %ICON_PATH%) else (echo [WARN]  Could not copy codex.ico)
) else (
    if not exist "%ICON_PATH%" echo [WARN]  codex.ico not found; the default icon will be used
)

set "SHORTCUT_PATH=%USERPROFILE%\Desktop\Codex with ip-switch.lnk"
rem The vbs path is passed unquoted: the generator adds the quotes, so a path
rem with spaces cannot break the argument.
call :make_shortcut "%SHORTCUT_PATH%" "%SystemRoot%\System32\wscript.exe" "%VBS_PATH%" "%INSTALL_DIR%" "%ICON_PATH%" "Launch Codex and auto-load the ip-switch MCP service"
if not "%SHORTCUT_RC%"=="0" (
    call :warn "Desktop shortcut creation failed; skip it and launch Codex manually"
    goto :eof
)
call :ok "Desktop shortcut created: %SHORTCUT_PATH%"
goto :eof

rem -- Create a .lnk via a generated .vbs ----------------------------------------
rem    %1 = .lnk path, %2 = target, %3 = arguments, %4 = working dir,
rem    %5 = icon path ^(%5^ may be empty^), %6 = description. Sets SHORTCUT_RC.
rem
rem    The .vbs is produced by a small node script rather than by echo, because a
rem    vbs line is full of parentheses and quotes that cmd mangles on the way out.
rem    An earlier echo-based version wrote a script whose shortcut path came out
rem    empty, which cscript rejected with "the shortcut path name must end with
rem    .lnk or .url". The arguments are passed unquoted and the script adds the
rem    quotes, so a path with spaces survives.
:make_shortcut
set "SHORTCUT_RC=1"
if not defined NODE_EXE for /f "usebackq delims=" %%A in (`where node.exe 2^>nul`) do if not defined NODE_EXE set "NODE_EXE=%%A"
if not defined NODE_EXE goto :eof
call :write_lnk_generator
set "MK_VBS=%TEMP%\ip-switch-mk-shortcut.vbs"
rem A stale file from an interrupted run would be reused by cscript.
if exist "%MK_VBS%" del /f /q "%MK_VBS%" >nul 2>&1
if exist "%~1" del /f /q "%~1" >nul 2>&1
"%NODE_EXE%" "%LNK_GEN_JS%" "%MK_VBS%" "%~1" "%~2" "%~3" "%~4" "%~5" "%~6" >nul 2>&1
if not exist "%MK_VBS%" goto :eof
cscript //nologo "%MK_VBS%" >nul 2>&1
del /f /q "%MK_VBS%" >nul 2>&1
if exist "%~1" set "SHORTCUT_RC=0"
goto :eof

rem -- Write the .vbs generator. Kept as a real file because it is re-read on
rem    every install. Two cmd traps shape the code below:
rem      - a caret cannot escape "=" or "<" in an echo line, they land in the
rem        file as ">=" and "<";
rem      - the ">" of an arrow function silently truncates the whole line.
rem    So the quoting helper is a plain function and every quote is built from
rem    String.fromCharCode plus "+".
:write_lnk_generator
set "LNK_GEN_JS=%TEMP%\ip-switch-lnkgen.js"
>"%LNK_GEN_JS%" echo const fs = require('fs');
>>"%LNK_GEN_JS%" echo const Q = String.fromCharCode(34);
>>"%LNK_GEN_JS%" echo const NL = String.fromCharCode(10);
>>"%LNK_GEN_JS%" echo function q(s) { return Q + s + Q; }
>>"%LNK_GEN_JS%" echo const a = process.argv.slice(2);
>>"%LNK_GEN_JS%" echo const L = [];
>>"%LNK_GEN_JS%" echo L.push('Set shell = CreateObject(' + q('WScript.Shell') + ')');
>>"%LNK_GEN_JS%" echo L.push('Set lnk = shell.CreateShortcut(' + q(a[1]) + ')');
>>"%LNK_GEN_JS%" echo L.push('lnk.TargetPath = ' + q(a[2]));
rem    The Arguments line is emitted in a form VBScript accepts. Three cmd traps
rem    shape it: a literal "&" in an echo line is a command separator, "^=" and
rem    "^<" cannot be escaped, and VBScript rejects doubled quotes inside a
rem    literal ("compiler error: statement not finished"). So the ampersand is
rem    written as String.fromCharCode(38) and the quotes come from Chr(34)
rem    inside the vbs, and the generator contains no caret at all.
>>"%LNK_GEN_JS%" echo const A = String.fromCharCode(38);
>>"%LNK_GEN_JS%" echo const D = 'Chr(' + Q + '34' + Q + ')';
>>"%LNK_GEN_JS%" echo L.push('lnk.Arguments = ' + D + ' ' + A + ' ' + q(a[3]) + ' ' + A + ' ' + D);
>>"%LNK_GEN_JS%" echo L.push('lnk.Description = ' + q(a[6]));
>>"%LNK_GEN_JS%" echo L.push('lnk.WorkingDirectory = ' + q(a[4]));
>>"%LNK_GEN_JS%" echo if (a[5]) L.push('lnk.IconLocation = ' + q(a[5] + ',0'));
>>"%LNK_GEN_JS%" echo L.push('lnk.Save');
>>"%LNK_GEN_JS%" echo fs.writeFileSync(a[0], L.join(NL), 'ascii');
goto :eof

rem ===========================================================================
rem  Install the Codex plugin marketplace
rem ===========================================================================
:install_codex_marketplace
call :step "Installing the Codex plugin marketplace ^(ip-switch^)"
set "MARKET_DIR=%USERPROFILE%\.codex\marketplaces\local"
set "MARKET_JSON_DIR=%MARKET_DIR%\.agents\plugins"
set "MARKET_PLUGIN_DIR=%MARKET_DIR%\plugins\ip-switch\.codex-plugin"

if not exist "%MARKET_JSON_DIR%" mkdir "%MARKET_JSON_DIR%"
if not exist "%MARKET_PLUGIN_DIR%" mkdir "%MARKET_PLUGIN_DIR%"

if not exist "%INSTALL_DIR%\.mcp.json" (
    call :err "%INSTALL_DIR%\.mcp.json not found; run the Codex MCP step first"
    set "RC=1"
    goto :finish
)
if not exist "%MARKET_DIR%\plugins\ip-switch" mkdir "%MARKET_DIR%\plugins\ip-switch"
copy /y "%INSTALL_DIR%\.mcp.json" "%MARKET_DIR%\plugins\ip-switch\.mcp.json" >nul
if not exist "%MARKET_DIR%\plugins\ip-switch\.mcp.json" (
    call :err "Could not copy .mcp.json into the marketplace package"
    set "RC=1"
    goto :finish
)

call :write_marketplace_json "%MARKET_JSON_DIR%\marketplace.json"
call :write_plugin_json "%MARKET_PLUGIN_DIR%\plugin.json"

if exist "%MARKET_JSON_DIR%\marketplace.json" if exist "%MARKET_PLUGIN_DIR%\plugin.json" (
    call :ok "Marketplace manifest written: %MARKET_JSON_DIR%\marketplace.json"
    call :ok "Plugin manifest written: %MARKET_PLUGIN_DIR%\plugin.json"
    call :ok "Codex plugin marketplace installed: %MARKET_DIR%"
    call :info "After restarting Codex, IP Switch appears in the plugin page/marketplace"
    goto :eof
)
call :err "Marketplace installation incomplete; check %MARKET_DIR%"
set "RC=1"
goto :finish

rem -- marketplace.json -----------------------------------------------------------
rem    Modelled on Codex's built-in openai-bundled format. The plugin package only
rem    carries the manifests + .mcp.json; the skill comes from the standalone
rem    ~\.codex\skills\ips-main\ channel, avoiding dual-channel duplication.
:write_marketplace_json
set "MJ_JS=%TEMP%\ip-switch-write-marketplace.js"
>"%MJ_JS%" echo const fs = require('fs');
>>"%MJ_JS%" echo const cfg = {
>>"%MJ_JS%" echo name: 'local',
>>"%MJ_JS%" echo interface: { displayName: 'Local Marketplace' },
>>"%MJ_JS%" echo plugins: [
>>"%MJ_JS%" echo {
>>"%MJ_JS%" echo name: 'ip-switch',
>>"%MJ_JS%" echo source: { source: 'local', path: './plugins/ip-switch' },
>>"%MJ_JS%" echo policy: { installation: 'AVAILABLE', authentication: 'ON_INSTALL' },
>>"%MJ_JS%" echo category: 'Developer Tools'
>>"%MJ_JS%" echo }
>>"%MJ_JS%" echo ]
>>"%MJ_JS%" echo };
>>"%MJ_JS%" echo fs.writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2) + String.fromCharCode(10), 'utf8');
"%NODE_EXE%" "%MJ_JS%" "%~1"
goto :eof

rem -- plugin.json ---------------------------------------------------------------
:write_plugin_json
set "PJ_JS=%TEMP%\ip-switch-write-plugin.js"
>"%PJ_JS%" echo const fs = require('fs');
>>"%PJ_JS%" echo const cfg = {
>>"%PJ_JS%" echo name: 'ip-switch',
>>"%PJ_JS%" echo version: '1.0.0',
>>"%PJ_JS%" echo description: 'Multi-cloud public IP switch MCP server with Cloudflare DNS auto-update',
>>"%PJ_JS%" echo author: { name: 'areyi2014', url: 'https://github.com/areyi2014/ip-switch' },
>>"%PJ_JS%" echo homepage: 'https://github.com/areyi2014/ip-switch',
>>"%PJ_JS%" echo repository: 'https://github.com/areyi2014/ip-switch.git',
>>"%PJ_JS%" echo license: 'MIT',
>>"%PJ_JS%" echo keywords: ['mcp', 'ip-switch', 'cloud', 'aws', 'azure', 'oci', 'vultr', 'cloudflare', 'dns'],
>>"%PJ_JS%" echo mcpServers: './.mcp.json',
>>"%PJ_JS%" echo interface: {
>>"%PJ_JS%" echo displayName: 'IP Switch',
rem The ampersand is built from a char code: a literal "&" in an echo line is a
rem command separator in cmd and would truncate the JS string literal.
>>"%PJ_JS%" echo shortDescription: 'Multi-cloud IP switch ' + String.fromCharCode(38) + ' DNS update',
>>"%PJ_JS%" echo longDescription: 'Switch the public IP of cloud instances across AWS / Azure / Oracle OCI / Vultr and automatically update Cloudflare DNS A records. Exposes 13 MCP tools for one-click IP rotation, instance management, and DNS sync.',
>>"%PJ_JS%" echo developerName: 'areyi2014',
>>"%PJ_JS%" echo category: 'Developer Tools',
>>"%PJ_JS%" echo capabilities: ['Cloud', 'Network'],
>>"%PJ_JS%" echo websiteURL: 'https://github.com/areyi2014/ip-switch',
>>"%PJ_JS%" echo defaultPrompt: [
>>"%PJ_JS%" echo 'Add an AWS profile in the IP Switch UI',
>>"%PJ_JS%" echo 'Use IP Switch to rotate the public IP of a cloud instance and update its Cloudflare DNS record.',
>>"%PJ_JS%" echo 'Use IP Switch to query instance info or list instances in a cloud region.'
>>"%PJ_JS%" echo ]
>>"%PJ_JS%" echo }
>>"%PJ_JS%" echo };
>>"%PJ_JS%" echo fs.writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2) + String.fromCharCode(10), 'utf8');
"%NODE_EXE%" "%PJ_JS%" "%~1"
goto :eof

rem ===========================================================================
rem  Install the ip-switch skill
rem ===========================================================================
rem    Responsibilities:
rem      1. copy SKILL.md / skill.json + scripts\ into
rem         %USERPROFILE%\.workbuddy\skills\ips-main\ ^(auto-discovered^)
rem      2. create the <install-dir>\data\ runtime directory
rem      3. write INSTALL_DIR into .install-path.txt in the user-level copy
rem         ^<the bootstrap anchor^)
rem      4. write <install-dir>\data\install-dir.txt ^<used by --status^)
rem      5. mirror to %USERPROFILE%\.codex\skills\ips-main\ ^(Codex only^)
rem    Idempotent, and copies only into the clients that were selected.
:install_skill
call :step "Installing the ip-switch skill ^(AI-agent config page launcher^)"
set "SCRIPTS_SRC=%INSTALL_DIR%\scripts"
if not exist "%SCRIPTS_SRC%" (
    call :warn "Skill scripts directory not found: %SCRIPTS_SRC% ^(skipping the skill install^)"
    goto :eof
)

set "DATA_DIR=%INSTALL_DIR%\data"
if not exist "%DATA_DIR%" mkdir "%DATA_DIR%"
set "MARKER_PATH=%DATA_DIR%\install-dir.txt"
call :write_text_file "%MARKER_PATH%" "%INSTALL_DIR%"
call :ok "install-dir marker written: %MARKER_PATH% -^> %INSTALL_DIR%"

if "%SEL_WB%%SEL_CODEX%"=="00" (
    call :warn "No client selected; skipping the skill install"
    goto :eof
)

if "%SEL_WB%"=="1" call :install_skill_to_wb
if "%SEL_CODEX%"=="1" call :install_skill_to_codex

if "%SEL_WB%"=="1" (
    call :info "How AI agents open it:"
    call :info "  WorkBuddy: say \Open the ip-switch config page\, \Add an AWS account\, etc. in the chat"
    call :info "  Any terminal: node %USERPROFILE%\.workbuddy\skills\ips-main\scripts\open-ui.mjs aws/azure/oci/vultr"
)
if "%SEL_CODEX%"=="1" call :info "  Codex: say \Open the ip-switch config page\, \Add an AWS account\, etc. in the chat"
goto :eof

:install_skill_to_wb
rem WorkBuddy discovers skills by a flat scan of ~/.workbuddy/skills/^<name\>/
set "WBDEST=%USERPROFILE%\.workbuddy\skills\ips-main"
set "WBSCRIPTS=%WBDEST%\scripts"
if not exist "%WBSCRIPTS%" mkdir "%WBSCRIPTS%"
if exist "%INSTALL_DIR%\SKILL.md" (copy /y "%INSTALL_DIR%\SKILL.md" "%WBDEST%\" >nul) else (call :warn "Root file not found: %INSTALL_DIR%\SKILL.md ^(skipping^)")
if exist "%INSTALL_DIR%\skill.json" (copy /y "%INSTALL_DIR%\skill.json" "%WBDEST%\" >nul) else (call :warn "Root file not found: %INSTALL_DIR%\skill.json ^(skipping^)")
xcopy "%SCRIPTS_SRC%\*" "%WBSCRIPTS%\" /e /i /y /q >nul 2>&1
call :ok "Skill installed: %WBDEST% ^(with scripts\ subdirectory^)"
if exist "%INSTALL_DIR%\references" (
    if not exist "%WBDEST%\references" mkdir "%WBDEST%\references"
    xcopy "%INSTALL_DIR%\references\*" "%WBDEST%\references\" /e /i /y /q >nul 2>&1
    if exist "%WBDEST%\references" (call :ok "Skill multilingual docs installed: %WBDEST%\references") else (call :warn "Failed to copy references ^(skipping; no functional impact^)")
)
call :write_text_file "%WBSCRIPTS%\.install-path.txt" "%INSTALL_DIR%"
call :ok "Bootstrap anchor written: %WBSCRIPTS%\.install-path.txt"
goto :eof

:install_skill_to_codex
set "CXDEST=%USERPROFILE%\.codex\skills\ips-main"
set "CXSCRIPTS=%CXDEST%\scripts"
if not exist "%CXSCRIPTS%" mkdir "%CXSCRIPTS%"
if exist "%INSTALL_DIR%\SKILL.md" copy /y "%INSTALL_DIR%\SKILL.md" "%CXDEST%\" >nul
if exist "%INSTALL_DIR%\skill.json" copy /y "%INSTALL_DIR%\skill.json" "%CXDEST%\" >nul
xcopy "%SCRIPTS_SRC%\*" "%CXSCRIPTS%\" /e /i /y /q >nul 2>&1
if exist "%INSTALL_DIR%\references" (
    if not exist "%CXDEST%\references" mkdir "%CXDEST%\references"
    xcopy "%INSTALL_DIR%\references\*" "%CXDEST%\references\" /e /i /y /q >nul 2>&1
)
call :write_text_file "%CXSCRIPTS%\.install-path.txt" "%INSTALL_DIR%"
call :ok "Mirrored to Codex: %CXSCRIPTS% ^(takes effect if Codex enables skills^)"
if "%SEL_WB%"=="0" call :info "  Any terminal: node %CXSCRIPTS%\open-ui.mjs aws/azure/oci/vultr"
goto :eof

rem -- Write a text file with no trailing newline and no BOM ----------------------
rem    %1 = target, %2 = content. echo|set /p writes without a newline, which is
rem    what the readers of these marker files expect.
rem -- Write a text file with no trailing newline and no BOM ----------------------
rem    %1 = target, %2 = content. node is used because "set /p" treats its
rem    argument as a prompt, and a Windows path inside it breaks the parse.
:write_text_file
rem mkdir prints "Access denied" on some systems when the directory already
rem exists, so the folder is created by node together with the file.
if not defined NODE_EXE for /f "usebackq delims=" %%A in (`where node.exe 2^>nul`) do if not defined NODE_EXE set "NODE_EXE=%%A"
if not defined NODE_EXE (
    if not exist "%~dp1" mkdir "%~dp1" >nul 2>&1
    < nul set /p "%~2" > "%~1"
    goto :eof
)
"%NODE_EXE%" -e "const fs=require('fs');const p=require('path');try{fs.mkdirSync(p.dirname(process.argv[1]),{recursive:true})}catch(e){};fs.writeFileSync(process.argv[1],process.argv[2],'utf8')" "%~1" "%~2" >nul 2>&1
goto :eof


rem ===========================================================================
rem  Install the ips-* quick-command skills
rem ===========================================================================
rem    Each subdirectory under <install-dir>\skills\ is one thin quick command:
rem      skills\ips-rotate\  skills\ips-dns\  skills\ips-cfg\  skills\ips-list\
rem    Layout per skill: SKILL.md ^(English^) + references\zh.md ^(Chinese, loaded
rem    on demand^). The loop auto-installs every ips-* directory, so adding a new
rem    quick command means dropping a directory here -- no installer edit.
:install_quick_skills
set "QUICK_SRC=%INSTALL_DIR%\skills"
if not exist "%QUICK_SRC%" (
    call :warn "Quick skills directory not found: %QUICK_SRC% ^(skipping the quick-skill install^)"
    goto :eof
)
if "%SEL_WB%%SEL_CODEX%"=="00" (
    call :warn "No client selected; skipping the quick-skill install"
    goto :eof
)
for /d %%D in ("%QUICK_SRC%\ips-*") do call :install_one_quick_skill "%%~fD" "%%~nxD"
goto :eof

rem %1 = skill source dir, %2 = skill name
:install_one_quick_skill
setlocal EnableDelayedExpansion
set "QSRC=%~1"
set "QNAME=%~2"
if not exist "%QSRC%\SKILL.md" (
    call :warn "Quick skill %QNAME%: SKILL.md missing ^(skipping^)"
    endlocal
    goto :eof
)
if "%SEL_WB%"=="1" (
    set "QDEST=%USERPROFILE%\.workbuddy\skills\!QNAME!"
    if not exist "!QDEST!" mkdir "!QDEST!"
    copy /y "%QSRC%\SKILL.md" "!QDEST!\" >nul
    if exist "%QSRC%\references" (
        if not exist "!QDEST!\references" mkdir "!QDEST!\references"
        xcopy "%QSRC%\references\*" "!QDEST!\references\" /e /i /y /q >nul 2>&1
    )
    call :ok "Quick skill installed: %USERPROFILE%\.workbuddy\skills\!QNAME! ^(/!QNAME!^)"
)
if "%SEL_CODEX%"=="1" (
    set "QCOD=%USERPROFILE%\.codex\skills\!QNAME!"
    if not exist "!QCOD!" mkdir "!QCOD!"
    copy /y "%QSRC%\SKILL.md" "!QCOD!\" >nul
    if exist "%QSRC%\references" (
        if not exist "!QCOD!\references" mkdir "!QCOD!\references"
        xcopy "%QSRC%\references\*" "!QCOD!\references\" /e /i /y /q >nul 2>&1
    )
    call :ok "Quick skill mirrored to Codex: %USERPROFILE%\.codex\skills\!QNAME!"
)
endlocal
goto :eof

rem ===========================================================================
rem  Restart the client app so the MCP config takes effect immediately
rem ===========================================================================
rem    %1 = app label, %2 = comma separated process names, %3 = comma separated
rem    path keywords ^(%3^ may be empty^), %4 = launch exe ^(%4^ may be empty^),
rem    %5 = launch args ^(%5^ may be empty^)
rem    The executable path of a running process is needed in order to restart
rem    the very same binary, which is what Get-Process .Path was used for.
rem
rem    wmic lists every process on the machine, so its raw output must never
rem    reach the screen: an earlier version leaked one
rem    "system cannot find the file" line per running process. The list is now
rem    captured to a file, filtered by node, and only the single match is shown.
:restart_client_app
set "APP_NAME=%~1"
set "PROCNAMES=%~2"
set "PATHKEYS=%~3"
set "LAUNCH_EXE=%~4"
set "LAUNCH_ARGS=%~5"

set "FOUND_EXE="
call :find_running_exe "%PROCNAMES%" "%PATHKEYS%"
if not defined FOUND_EXE (
    call :info "%APP_NAME% is not running; skipping the restart ^(open it manually if needed^)"
    goto :eof
)

call :info "%APP_NAME% detected as running; restarting..."
for %%N in (%PROCNAMES%) do taskkill /f /im %%N.exe >nul 2>&1
ping -n 3 127.0.0.1 >nul 2>&1

rem Redirect the child's output to temp files to suppress Electron debug logs.
set "LOGOUT=%TEMP%\ip-switch-%APP_NAME%-out.log"
set "LOGERR=%TEMP%\ip-switch-%APP_NAME%-err.log"
if exist "%LOGOUT%" del /f /q "%LOGOUT%" >nul 2>&1
if exist "%LOGERR%" del /f /q "%LOGERR%" >nul 2>&1

if exist "%FOUND_EXE%" (
    start "" /min "%FOUND_EXE%" > "%LOGOUT%" 2> "%LOGERR%"
    call :ok "%APP_NAME% restarted"
    goto :eof
)
if not "%LAUNCH_EXE%"=="" (
    start "" /min "%LAUNCH_EXE%" %LAUNCH_ARGS% > "%LOGOUT%" 2> "%LOGERR%"
    call :ok "%APP_NAME% restarted"
    goto :eof
)
call :warn "%APP_NAME% was closed but auto-restart failed; please open it manually"
goto :eof

rem -- Find the exe of a running process. Sets FOUND_EXE, or leaves it empty ---
rem    %1 = comma separated process names, tried first because they are cheap.
rem    %2 = comma separated path keywords, the fallback when the name misses.
rem    Everything is done by node against a captured wmic listing: parsing that
rem    listing in cmd needs a nested for /f plus delayed expansion, and every
rem    step of it can leak wmic's own error text to the console.
:find_running_exe
set "FOUND_EXE="
if not defined NODE_EXE for /f "usebackq delims=" %%A in (`where node.exe 2^>nul`) do if not defined NODE_EXE set "NODE_EXE=%%A"
if not defined NODE_EXE goto :eof
set "PROC_LIST=%TEMP%\ip-switch-proclist.txt"
set "PROC_HIT=%TEMP%\ip-switch-prochit.txt"
if exist "%PROC_HIT%" del /f /q "%PROC_HIT%" >nul 2>&1

rem Capture the whole listing once; both the name and the keyword pass read it.
rem 2^>nul keeps wmiprvse complaints off the screen, and the file itself is
rem deleted right after, so nothing is left behind either way.
wmic process get Name^,ExecutablePath /value > "%PROC_LIST%" 2>nul
if not exist "%PROC_LIST%" goto :eof

rem Pass 1: exact process-name match.
"%NODE_EXE%" -e "const fs=require('fs');const raw=fs.readFileSync(process.argv[1],'utf8');const want=process.argv[2].toLowerCase().split(',').map(s=>s.trim()).filter(Boolean);let name='',path='';for(const line of raw.split(/\r?\n/)){const i=line.indexOf('=');if(i<0)continue;const k=line.slice(0,i).trim().toLowerCase();const v=line.slice(i+1).trim();if(k==='name'&&!name)name=v;if(k==='executablepath'&&!path)path=v;if(name&&path)break;}if(path&&want.includes(name.toLowerCase()+'.exe'))fs.writeFileSync(process.argv[3],path);" "%PROC_LIST%" "%~1" "%PROC_HIT%" >nul 2>&1

rem Pass 2: fall back to a path keyword when the name did not match.
if not exist "%PROC_HIT%" if not "%~2"=="" (
    "%NODE_EXE%" -e "const fs=require('fs');const raw=fs.readFileSync(process.argv[1],'utf8');const keys=process.argv[2].toLowerCase().split(',').map(s=>s.trim()).filter(Boolean);let cur={},out=[];const flush=()=>{if(cur.name&&cur.path){const p=cur.path.toLowerCase();if(keys.some(k=>p.includes(k)))out.push(cur.path);}cur={};};for(const line of raw.split(/\r?\n/)){const i=line.indexOf('=');if(i<0){flush();continue;}const k=line.slice(0,i).trim().toLowerCase();cur[k]=line.slice(i+1).trim();}flush();if(out.length)fs.writeFileSync(process.argv[3],out[0]);" "%PROC_LIST%" "%~2" "%PROC_HIT%" >nul 2>&1
)

if exist "%PROC_HIT%" for /f "usebackq tokens=*" %%P in (`type "%PROC_HIT%"`) do set "FOUND_EXE=%%P"
if exist "%PROC_HIT%" del /f /q "%PROC_HIT%" >nul 2>&1
del /f /q "%PROC_LIST%" >nul 2>&1
goto :eof
if exist "%FOUND_EXE%" (
    start "" /min "%FOUND_EXE%" > "%LOGOUT%" 2> "%LOGERR%"
    call :ok "%APP_NAME% restarted"
    goto :eof
)
if not "%LAUNCH_EXE%"=="" (
    start "" /min "%LAUNCH_EXE%" %LAUNCH_ARGS% > "%LOGOUT%" 2> "%LOGERR%"
    call :ok "%APP_NAME% restarted"
    goto :eof
)
call :warn "%APP_NAME% was closed but auto-restart failed; please open it manually"
goto :eof

rem ===========================================================================
rem  Post-install summary
rem ===========================================================================
:show_success
echo.
echo Restart the client:
if "%SEL_WB%"=="1" call :restart_client_app "WorkBuddy" "WorkBuddy,CodeBuddy" "WorkBuddy,CodeBuddy" "" ""
if "%SEL_CODEX%"=="1" (
    set "LAUNCH_VBS=%INSTALL_DIR%\codex_app.vbs"
    if exist "%LAUNCH_VBS%" (
        rem Launch via codex_app.vbs, which also brings up the ip-switch service
        call :restart_client_app "Codex" "codex,Codex,ChatGPT" "OpenAI.Codex,OpenAI\Codex" "%SystemRoot%\System32\wscript.exe" "\"%LAUNCH_VBS%\""
    ) else (
        call :restart_client_app "Codex" "codex,Codex,ChatGPT" "OpenAI.Codex,OpenAI\Codex" "codex" "app"
    )
)

rem No pipe characters in the banner: a line that starts with a pipe is read
rem as a pipe operator by cmd, which aborts the whole script with a syntax
rem error, and quoting it would print the quotes.
echo.
echo +============================================================+
echo   ip-switch installed successfully!
echo +============================================================+
echo.

if "%SEL_WB%"=="1" echo WorkBuddy MCP config: %USERPROFILE%\.workbuddy\mcp.json
if "%SEL_CODEX%"=="1" (
    echo Codex marketplace manifest: %USERPROFILE%\.codex\marketplaces\local
    echo Codex user-level registration: %USERPROFILE%\.codex\config.toml ^(globally visible, written by Append-CodexUserConfig^)
)
if "%SEL_WB%%SEL_CODEX%"=="11" goto :mcp_hint_both
if "%SEL_WB%"=="1" goto :mcp_hint_wb
if "%SEL_CODEX%"=="1" goto :mcp_hint_codex
echo   # After configuring the MCP client, use these commands via chat
goto :mcp_hint_done
:mcp_hint_both
echo   # Use via MCP tools ^(^just chat in WorkBuddy/Codex^)
goto :mcp_hint_done
:mcp_hint_wb
echo   # Use via MCP tools ^(^just chat in WorkBuddy^)
goto :mcp_hint_done
:mcp_hint_codex
echo   # Use via MCP tools ^(^just chat in Codex^)
:mcp_hint_done
if not "%SEL_WB%%SEL_CODEX%"=="00" (
    echo ip-switch skill: %USERPROFILE%\.workbuddy\skills\ips-main
    rem No pipes or angle brackets here: a chain such as "aws^|azure^)^" mixes
rem several escapes on one line and cmd mis-parses it.
echo                    ^(auto-discovered by WorkBuddy; from any terminal: node %USERPROFILE%\.workbuddy\skills\ips-main\scripts\open-ui.mjs aws/azure/oci/vultr^)
)
echo UI server:  node %INSTALL_DIR%\ui\server.cjs
echo UI URL:     printed to the terminal when the server starts
echo.

echo Usage:
echo   # Start the UI config server ^(optional^)
echo   node %INSTALL_DIR%\ui\server.cjs
echo.
echo   # Open the config page in a browser ^(see the server startup output for the URL^)
echo   start http://127.0.0.1:PORT
echo.
echo   - List profiles:  \List my cloud server profiles\
echo   - Rotate IPs:     \Rotate the IPs of all configured servers\
echo   - Add a profile:  \I want to add an AWS profile\
echo.

echo Manual update:
echo   cd %INSTALL_DIR% ^& git pull ^& npm install ^& npm run build
echo.

echo Uninstall:
if "%SEL_WB%"=="1" echo   del /f /q "%USERPROFILE%\.workbuddy\mcp.json"          # remove the WorkBuddy MCP config
if "%SEL_CODEX%"=="1" echo   rd /s /q "%USERPROFILE%\.codex\marketplaces\local"     # remove the Codex marketplace manifests
if not "%SEL_WB%%SEL_CODEX%"=="00" echo   rd /s /q "%USERPROFILE%\.workbuddy\skills\ips-main"        # remove the ip-switch skill
echo   rd /s /q "%INSTALL_DIR%\data"   # remove runtime data ^(keep the source^)
echo   rd /s /q "%INSTALL_DIR%"        # also remove the source if desired
echo.
echo Privacy: install stats log your IP, OS, script version and a random device id
echo          opt out with IP_SWITCH_TELEMETRY=0; details in INSTALL.md
call :telemetry "success" ""
set "TELEMETRY_SENT=1"
goto :eof

rem ===========================================================================
rem  Main flow
rem ===========================================================================
:main
echo.
rem No pipe characters in the banner: a line that starts with a pipe is read
rem as a pipe operator by cmd, which aborts the whole script with a syntax
rem error, and quoting it would print the quotes.
echo.
echo +============================================================+
echo   ip-switch automated deployment script v%SCRIPT_VERSION%
echo +============================================================+
echo.
echo.

call :locate_tools
set "TELEMETRY_ARMED=1"
call :telemetry "start" ""

set "STAGE=precheck"
call :check_npm
if not "%RC%"=="0" goto :finish
call :check_git
if not "%RC%"=="0" goto :finish
call :detect_mcp
call :select_clients

set "STAGE=clone"
call :clone_repo
if not "%RC%"=="0" goto :finish

set "STAGE=deps"
call :install_deps
if not "%RC%"=="0" goto :finish

set "STAGE=build"
rem -SkipBuild still needs dist\index.js, because every client config points at
rem it. Checking here stops the run before the client steps cascade into a
rem series of "missing file" errors.
rem Labels, not a block: a "goto" inside "if (...)" leaves the caller's context.
if "%SKIP_BUILD%"=="1" goto :build_skip_check
goto :build_run
:build_skip_check
if exist "%INSTALL_DIR%\dist\index.js" goto :build_run
call :err "Build output missing: %INSTALL_DIR%\dist\index.js"
call :info "-SkipBuild was given but there is no build to install; drop -SkipBuild, or run: cd %INSTALL_DIR% ^& npm install ^& npm run build"
set "RC=1"
goto :finish

:build_run
if not "%SKIP_BUILD%"=="1" call :build_project
if not "%RC%"=="0" goto :finish

if not "%SEL_WB%%SEL_CODEX%"=="00" call :generate_wb_config
if not "%RC%"=="0" goto :finish
if "%SEL_CODEX%"=="1" goto :codex_steps
goto :skill_steps

:codex_steps
call :install_codex_mcp
if not "%RC%"=="0" goto :finish
call :install_codex_toml
call :install_codex_shortcut
call :install_codex_marketplace
if not "%RC%"=="0" goto :finish

:skill_steps

set "STAGE=skill"
call :install_skill
call :install_quick_skills
call :show_success

call :ok "Deployment complete!"
goto :finish

:finish
rem Hold the window open only when double-clicked ^(cmd /c "...install.cmd"^),
rem otherwise a double-click would close the window the moment the script ends.
rem RC belongs to the outer scope, so it is copied in before endlocal drops it,
rem and the copy is read with delayed expansion for the same reason.
setlocal EnableDelayedExpansion
set "HOLD="
set "FINAL_RC=!RC!"
if "!FINAL_RC!"=="" set "FINAL_RC=1"
echo !cmdcmdline! | find /i "%~nx0" >nul 2>&1 && set "HOLD=1"
if defined HOLD pause
endlocal & exit /b %FINAL_RC%
