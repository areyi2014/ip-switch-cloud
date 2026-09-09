# ip-switch Installation Guide

[English](INSTALL.md) | [简体中文](INSTALL-zh.md)

---

An AI Agent plugin for effortless rotation of cloud public IPs — batch-rotate public IPs of cloud servers (AWS / Azure / Oracle / Vultr) with one click and automatically update DNS records, eliminating the tedium of logging into and configuring multiple web platforms.

---

## Table of Contents

- [System Requirements](#system-requirements)
- [One-Click Installation](#one-click-installation)
  - [Windows](#windows)
  - [macOS / Ubuntu](#macos--ubuntu)
  - [What the Script Does Automatically](#what-the-script-does-automatically)
  - [Custom Parameters](#custom-parameters)
- [Manual Installation](#manual-installation)
- [MCP Configuration](#mcp-configuration)
  - [WorkBuddy](#workbuddy)
  - [Environment Variables](#environment-variables)
- [Verify Installation](#verify-installation)
- [Configure Cloud Servers (UI)](#configure-cloud-servers-ui)
- [Usage](#usage)
- [Update & Uninstall](#update--uninstall)
- [FAQ](#faq)

---

## System Requirements

| Dependency | Min Version | Description |
|-----------|---------|-----------------------------------|
| Node.js   | >= 18   | Requires the native `fetch` API (Node 18+) |
| npm       | >= 9    | Installed together with Node.js |
| git       | Optional | Used to clone the repo; auto-installed by the script if missing |
| OS        | -       | Windows 10+, macOS 14+, Ubuntu 20.04+ |
| Software  | -       | Workbuddy 5.0+, Codex           |

---

## One-Click Installation

### Windows

Run in PowerShell (if you hit execution policy restrictions, run `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` first):

```powershell
# Download the install script
Invoke-WebRequest -Uri "https://gitee.com/areyi2014/ip-switch/raw/main/install.ps1" -OutFile "$env:TEMP\install-ip-switch.ps1"

# Run it (must be executed in PowerShell; cmd does not support the & syntax)
& "$env:TEMP\install-ip-switch.ps1"
```

> **Notes**:
> - Do NOT use the `irm ... | iex` shorthand — `irm`/`iex` are PowerShell aliases; in cmd and other environments they error with "irm not found", and piping a multi-line script straight into execution is error-prone.
> - `& "$env:TEMP\..."` is PowerShell syntax; it must run in a PowerShell window, not cmd.
> - If you are in cmd or another environment, use the following command instead (no reliance on `&`, and it bypasses execution policy restrictions):
> ```
> powershell -ExecutionPolicy Bypass -File "%TEMP%\install-ip-switch.ps1"
> ```

### macOS / Ubuntu

Run in a terminal:

```bash
# One command
bash <(curl -fsSL https://gitee.com/areyi2014/ip-switch/raw/main/install.sh)
```

Or step by step:

```bash
# Download the install script
curl -fsSL https://gitee.com/areyi2014/ip-switch/raw/main/install.sh -o install-ip-switch.sh

# Run it
bash install-ip-switch.sh
```

### What the Script Does Automatically

1. **Check Node.js** — version must be >= 18, otherwise it prints a message and exits
2. **Check git** — if missing, handled automatically:
   - Windows: downloads the official installer for your CPU architecture (x64 / arm64) from China mirrors (NPMMirror / Tsinghua TUNA, GitHub as fallback), silently installs to the user directory `%LOCALAPPDATA%\Git`, adds it to PATH — zero popups throughout
   - macOS / Ubuntu: auto-installed via package managers (apt / brew / xcode-select)
3. **Detect MCP client platforms** — recognizes `~/.workbuddy` automatically
4. **Clone the repo** — shows repo/branch/directory for confirmation before cloning (Enter or type a new path); pings first to warm up the DNS cache, retries up to 3 times
5. **Install dependencies** — `npm install`
6. **Build** — compiles TypeScript to `dist/` (automatically clears `ELECTRON_RUN_AS_NODE` interference)
7. **Write MCP config** — serialized to standard JSON via node, merged into `~/.workbuddy/mcp.json` (other servers already in the file are preserved, not overwritten)

### Custom Parameters

Windows PowerShell:

```powershell
& "$env:TEMP\install-ip-switch.ps1" -InstallDir "D:\tools\ip-switch"
& "$env:TEMP\install-ip-switch.ps1" -RepoUrl "https://gitee.com/areyi2014/ip-switch.git"
& "$env:TEMP\install-ip-switch.ps1" -Branch develop
& "$env:TEMP\install-ip-switch.ps1" -SkipBuild
& "$env:TEMP\install-ip-switch.ps1" -Help
```

macOS / Ubuntu:

```bash
bash install-ip-switch.sh --install-dir /opt/ip-switch
bash install-ip-switch.sh --repo-url https://gitee.com/areyi2014/ip-switch.git
bash install-ip-switch.sh --branch develop
bash install-ip-switch.sh --skip-build
```

---

## Manual Installation

If you don't use the one-click script, perform the following steps manually:

### 1. Make sure Node.js >= 18 is installed

```bash
node -v   # Should print v18.x.x or higher
npm -v    # Should print 9.x.x or higher
```

If not installed, download the LTS version (22.x recommended) from [nodejs.org](https://nodejs.org/).

### 2. Clone the repository

```bash
git clone --depth 1 https://gitee.com/areyi2014/ip-switch.git
cd ip-switch
```

### 3. Install dependencies

```bash
npm install
```

### 4. Build

```bash
npm run build
```

> **Note for WorkBuddy users**: If the build fails or exits silently, the `ELECTRON_RUN_AS_NODE` environment variable is interfering with `tsc`. Use the following commands instead:
> ```bash
> # macOS / Ubuntu
> env -u ELECTRON_RUN_AS_NODE npm run build
>
> # Windows PowerShell
> $env:ELECTRON_RUN_AS_NODE = ""; npm run build
> ```

### 5. Verify

After a successful build, `dist/index.js` should exist:

```bash
# macOS / Ubuntu
ls -la dist/index.js

# Windows
dir dist\index.js
```

---

## MCP Configuration

After one-click installation, the script has already merged the `ip-switch` entry into the following file (node-serialized standard JSON, preserving other existing servers):

- `~/.workbuddy/mcp.json`

### WorkBuddy

When the one-click script detects the `~/.workbuddy` directory, it automatically writes to `~/.workbuddy/mcp.json`. **WorkBuddy ships with its own Node.js**, and the script points `command` to it first (no separate Node.js install needed):

```
Windows:     C:\Users\<username>\.workbuddy\binaries\node\versions\22.22.2\node.exe
macOS/Linux: ~/.workbuddy/binaries/node/versions/<version>/bin/node
```

1. Open the WorkBuddy **connector management page**
2. Find `ip-switch` under "Custom connectors"
3. Click **"Trust"** — it is then available in conversations

If it was not written automatically, manually edit `~/.workbuddy/mcp.json` (create the file if it doesn't exist):

```json
{
  "mcpServers": {
    "ip-switch": {
      "command": "C:\\Users\\<username>\\.workbuddy\\binaries\\node\\versions\\22.22.2\\node.exe",
      "args": ["C:\\Users\\<username>\\ip-switch\\dist\\index.js"]
    }
  }
}
```

> **Path notes**:
> - `command`: Full path to the Node.js executable (**in a WorkBuddy environment, prefer the Node.js bundled with WorkBuddy**; the install script also auto-detects the Node.js bundled with Codex, see the Codex section below)
> - `args[0]`: Full absolute path to `dist/index.js`
> - Backslashes in Windows paths must be written as `\\` (JSON escaping)
> - **Note**: The version-number directory of WorkBuddy's bundled Node.js may change with updates. If the path breaks, find the actual path with:
> ```bash
> # Windows PowerShell (the version dir changes with updates)
> Get-ChildItem "$env:USERPROFILE\.workbuddy\binaries\node\versions" -Recurse -Filter node.exe | Select-Object -ExpandProperty FullName
>
> # macOS / Linux
> find ~/.workbuddy/binaries/node/versions -name node -type f
> ```

### Codex

When the one-click script detects the `~/.codex` directory, it automatically writes to `~/.codex/mcp.json`. **Codex ships with its own Node.js**, and the script points `command` to it first (no separate Node.js install needed):

```
Windows:   C:\Users\<username>\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe
macOS/Linux: ~/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node
```

If it was not written automatically, manually edit `~/.codex/mcp.json` (create the file if it doesn't exist):

```json
{
  "mcpServers": {
    "ip-switch": {
      "command": "C:\\Users\\<username>\\.cache\\codex-runtimes\\codex-primary-runtime\\dependencies\\node\\bin\\node.exe",
      "args": ["C:\\Users\\<username>\\ip-switch\\dist\\index.js"]
    }
  }
}
```

> **Note**: The Codex runtime directory may vary by version (e.g. the `codex-primary-runtime` prefix). If the path breaks, find the actual path with:
> ```bash
> # Windows PowerShell
> Get-ChildItem "$env:USERPROFILE\.cache\codex-runtimes" -Recurse -Filter node.exe | Select-Object -ExpandProperty FullName
>
> # macOS / Linux
> find ~/.cache/codex-runtimes -name node -type f
> ```

### Environment Variables

Environment variables can be set via the `env` field in the MCP config. In a WorkBuddy environment, this project usually needs the Electron interference cleared:

```json
{
  "command": "node",
  "args": ["/path/to/dist/index.js"],
  "env": {
    "ELECTRON_RUN_AS_NODE": ""
  }
}
```

| Variable | Description |
|------------------------|--------------------------------------|
| `ELECTRON_RUN_AS_NODE` | Set to empty string `""` to avoid Electron environment interference |

---

## Verify Installation

In a WorkBuddy conversation, try the following command to verify:

```
List my cloud server profiles
```

If the service loaded correctly, it returns a list of profiles (possibly empty `{}`).

You can also run `dist/index.js` directly to verify the MCP protocol works:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | node dist/index.js
```

The expected output contains 13 tool definitions.

---

## Configure Cloud Servers (UI)

A local browser-based configuration UI is provided for entering cloud platform credentials.

```bash
# Start the UI server (the port is auto-assigned by the system to avoid conflicts)
node ui/server.cjs
```

After startup, the terminal prints the actual address `http://127.0.0.1:<port>`. Open it in a browser to fill in and save configs in the visual interface.

> **Convention**: Always open the config form in a **browser**, not in the WorkBuddy embedded window (its sandbox limitations block the save request).

---

## Usage

Operate it directly through AI conversation. Common commands:

| Command | Function |
|-----------------------------------|---------------------------|
| "Add an AWS profile" | Open the UI to add a cloud server profile |
| "List my cloud server profiles" | View saved profiles |
| "Rotate the IPs of all configured servers" | One-click rotate all IPs + update DNS |
| "Rotate aws-ty's IP and update DNS" | Rotate the specified profile and sync DNS |
| "Delete the aws-ty profile" | Remove the specified profile |

For the complete list of 13 MCP tools, see the [Usage](./README.md#usage) section of [README.md](./README.md).

---

## Update & Uninstall

### Update

Just re-run the install script (when it detects an already-cloned repo, it automatically does `git pull` + installs dependencies + builds + updates the MCP config), or do it manually:

```bash
cd ~/ip-switch
git pull
npm install
npm run build
```

### Uninstall

```bash
# Delete the project directory
rm -rf ~/ip-switch                 # macOS / Ubuntu
Remove-Item -Recurse -Force ~/ip-switch   # Windows

# Delete config data (including saved credentials)
rm -rf ~/.ip-switch                     # macOS / Ubuntu
Remove-Item -Recurse -Force ~/.ip-switch       # Windows

# Remove the ip-switch entry from ~/.workbuddy/mcp.json
```

---

## FAQ

### 1. Build fails or exits silently

**Cause**: The `ELECTRON_RUN_AS_NODE=1` environment variable interferes with the `tsc` compiler.

**Fix**:

```bash
# macOS / Ubuntu
env -u ELECTRON_RUN_AS_NODE npm run build

# Windows PowerShell
$env:ELECTRON_RUN_AS_NODE = ""; npm run build
```

### 2. Repository clone fails

**Cause**: Network issues or the repository is unreachable.

**Fix**:
- Confirm the network works and gitee.com is reachable
- The script has built-in DNS warm-up (pings the repo domain first) and up to 3 automatic retries
- For a private repo, set up an SSH key first: `ssh-keygen -t ed25519 && cat ~/.ssh/id_ed25519.pub`
- Clone manually: `git clone https://gitee.com/areyi2014/ip-switch.git`

### 3. Tools don't appear after MCP configuration

**Cause**: The MCP process failed to start, the configured path is wrong, or the mcp.json format isn't recognized.

**Troubleshooting**:
1. Confirm `dist/index.js` exists
2. Confirm the node path in `command` is correct: `Get-Command node` / `which node` (full path required)
3. Confirm mcp.json is valid JSON (the one-click script serializes output with node, so indentation or backslash escaping issues won't occur)
4. Test manually: `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | node dist/index.js`
5. Check the WorkBuddy connector management page for error messages

### 4. npm install fails (permission error)

**Fix**: Avoid `sudo`. If you get an EACCES error:

```bash
# macOS / Ubuntu: Fix npm permissions
mkdir -p ~/.npm-global
npm config set prefix '~/.npm-global'
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

### 5. Azure SDK error "networkInterfaces.updateProperties does not exist"

This has been fixed in the latest code (replaced with `beginCreateOrUpdateAndWait`). Just make sure you're on the latest `main` branch.

### 6. Windows PowerShell script won't run

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Or bypass the restriction with `powershell -ExecutionPolicy Bypass -File install.ps1`.

### 7. Automatic git installation fails

**Cause**: Neither the China mirrors nor GitHub are reachable.

**Fix**: Manually download and install from [git-scm.com/download](https://git-scm.com/download/win), then re-run the install script (it detects the existing git and skips installation).
