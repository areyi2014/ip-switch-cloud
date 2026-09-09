# ip-switch

[English](README.md) | [简体中文](README-zh.md)

---

An AI Agent plugin for effortless rotation of cloud public IPs — batch-rotate public IPs of cloud servers (AWS / Azure / Oracle / Vultr) with one click and sync DNS records, eliminating the tedium of logging into and configuring multiple web platforms.

Supported platforms: Workbuddy / Codex + AWS / Azure / Oracle OCI / Vultr + Cloudflare DNS

---

## Quick Download & Installation

> Requires **Node.js >= 18** (download the LTS from [nodejs.org](https://nodejs.org/)). If git is not installed, the script installs it automatically.

**Windows**:

> **Environment: PowerShell**

```powershell
# Download the install script
Invoke-WebRequest -Uri "https://gitee.com/areyi2014/ip-switch/raw/main/install.ps1" -OutFile "$env:TEMP\install-ip-switch.ps1"

# Run it (must be executed in PowerShell; cmd does not support the & syntax)
& "$env:TEMP\install-ip-switch.ps1"
```

> **Tip**: If you are in cmd or another environment, use the following command instead (no reliance on `&`, and it bypasses execution policy restrictions):
>
> ```
> powershell -ExecutionPolicy Bypass -File "%TEMP%\install-ip-switch.ps1"
> ```

**macOS / Ubuntu**:

> **Environment: Bash Shell (terminal)**

```bash
# Download the install script
curl -fsSL https://gitee.com/areyi2014/ip-switch/raw/main/install.sh -o install-ip-switch.sh

# Run it
bash install-ip-switch.sh
```

The script automatically: checks the environment (installs git if missing) → clones the repo → installs dependencies → builds → writes the MCP config. See below for detailed installation instructions.

---

# ip-switch Installation Guide

An MCP service for rotating cloud public IPs — lets AI Agents batch-rotate public IPs of cloud servers (AWS / Azure / OCI / Vultr) with one click and sync DNS records.

---

## Table of Contents

- [System Requirements](#system-requirements)
- [One-Click Installation](#one-click-installation)
  - [macOS / Ubuntu](#macos--ubuntu)
  - [Windows](#windows)
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
| git       | Any     | Used to clone the repo; auto-installed by the script if missing |
| OS        | -       | macOS 14+, Ubuntu 20.04+, Windows 10+ |
| Software  | -       | Workbuddy 1.1.0+ |

---

## One-Click Installation

### macOS / Ubuntu

> **Environment: Bash Shell (terminal)**

```bash
# Download the install script
curl -fsSL https://gitee.com/areyi2014/ip-switch/raw/main/install.sh -o install-ip-switch.sh

# Run it (requires network connection)
bash install-ip-switch.sh
```

**Custom parameters:**

> **Environment: Bash Shell (terminal)**

```bash
# Specify install directory
bash install-ip-switch.sh --install-dir /opt/ip-switch

# Use a mirror repo URL
bash install-ip-switch.sh --repo-url https://gitee.com/areyi2014/ip-switch.git

# Specify a branch
bash install-ip-switch.sh --branch develop

# Download only, skip build
bash install-ip-switch.sh --skip-build
```

The script performs, in order:
1. Check Node.js >= 18
2. Check git (auto-installed via package manager if missing)
3. Clone the repo to `~/ip-switch` (confirms the directory, warms up DNS, retries up to 3 times before cloning)
4. Install npm dependencies
5. Compile TypeScript → `dist/`
6. Generate the MCP config file (written directly to `~/.workbuddy/mcp.json`)

### Windows

> **Environment: PowerShell**

```powershell
# If you hit execution policy restrictions, run this first:
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

# Download the install script
Invoke-WebRequest -Uri "https://gitee.com/areyi2014/ip-switch/raw/main/install.ps1" -OutFile "$env:TEMP\install-ip-switch.ps1"

# Run it
& "$env:TEMP\install-ip-switch.ps1"
```

**Custom parameters:**

> **Environment: PowerShell**

```powershell
& "$env:TEMP\install-ip-switch.ps1" -InstallDir "D:\tools\ip-switch"
& "$env:TEMP\install-ip-switch.ps1" -RepoUrl "https://gitee.com/areyi2014/ip-switch.git"
```

> **Note**: If you get the error `file cannot be loaded because running scripts is disabled on this system`, run `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` first.

> **Tip**: If git is not installed, the script silently downloads and installs git for your CPU architecture (accelerated via a China mirror) into the user directory — no manual action needed.

---

## Manual Installation

If you don't use the one-click script, perform the following steps manually:

### 1. Make sure Node.js >= 18 is installed

> **Environment: Bash Shell / PowerShell (either works)**

```bash
node -v   # Should print v18.x.x or higher
npm -v    # Should print 9.x.x or higher
```

If not installed, download the LTS version (22.x recommended) from [nodejs.org](https://nodejs.org/).

### 2. Clone the repository

> **Environment: Bash Shell / PowerShell (either works)**

```bash
git clone --depth 1 https://gitee.com/areyi2014/ip-switch.git
cd ip-switch
```

### 3. Install dependencies

> **Environment: Bash Shell / PowerShell (either works)**

```bash
npm install
```

### 4. Build

> **Environment: Bash Shell / PowerShell (either works)**

```bash
npm run build
```

> **Note for WorkBuddy users**: If the build fails or exits silently, the `ELECTRON_RUN_AS_NODE` environment variable is interfering with `tsc`. Use the following commands instead:
>
> ```bash
> # macOS / Ubuntu
> env -u ELECTRON_RUN_AS_NODE npm run build
>
> # Windows PowerShell
> $env:ELECTRON_RUN_AS_NODE = ""; npm run build
> ```

### 5. Verify

After a successful build, `dist/index.js` should exist:

> **Environment: Bash Shell (macOS / Ubuntu) or PowerShell (Windows)**

```bash
# macOS / Ubuntu
ls -la dist/index.js

# Windows
dir dist\index.js
```

---

## MCP Configuration

After one-click installation, the script has already merged the `ip-switch` entry into:

- `~/.workbuddy/mcp.json`

(Merged write — it will NOT overwrite other server configs already in the file.)

### WorkBuddy

When the one-click script detects the `~/.workbuddy` directory, it automatically writes to `~/.workbuddy/mcp.json`. **WorkBuddy ships with its own Node.js**, and the script points `command` to it first (no separate Node.js install needed):

```
Windows:     C:\Users\<username>\.workbuddy\binaries\node\versions\22.22.2\node.exe
macOS/Linux: ~/.workbuddy/binaries/node/versions/<version>/bin/node
```

Open the WorkBuddy **connector management page**, find `ip-switch` under "Custom connectors", click **"Trust"**, and it becomes available in conversations.

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
> - Use double backslashes `\\` to escape Windows paths
> - **Note**: The version-number directory of WorkBuddy's bundled Node.js may change with updates. If the path breaks, find the actual path with:
>
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
>
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

> **Environment: Bash Shell / PowerShell (either works)**

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | node dist/index.js
```

The expected output contains 13 tool definitions.

---

## Configure Cloud Servers (UI)

A local browser-based configuration UI is provided for entering cloud platform credentials.

> **Environment: Bash Shell / PowerShell (either works)**

```bash
# Start the UI server
node ui/server.cjs
```

Then open `http://127.0.0.1:<port>` in your browser (the port is auto-assigned by the system and printed to the terminal on startup) to fill in and save configs in the visual interface.

> **Convention**: Always open the config form in a **browser**, not in the WorkBuddy embedded window (sandbox limitation).
>
> Reason: Embedded widgets of AI chat platforms (e.g. WorkBuddy's `show_widget`) run in a sandbox where CSP policy blocks `fetch` requests, so the save button cannot write the config file. Same-origin `fetch` in a browser is unrestricted.

The server exposes the following endpoints:

- `GET /` — Config form page
- `GET /api/config` — Read the current config
- `POST /api/save-config` — Save the config (merged into config.json)
- `POST /api/delete-profile` — Delete a specified profile

You can also open the `ui/config-form.html` file directly (in that case saving falls back to the clipboard).

**Form features**:

- Tab switching across four platforms (AWS / Azure / OCI / Vultr)
- The region dropdown supports "Other region (manual input)"
- Checking "Enable Cloudflare DNS" expands API Token + Zone ID inputs
- Each profile can bind its own independent Cloudflare credentials

---

## Project Structure

```
ip-switch/
├── src/
│   ├── index.ts          # MCP Server entry (stdio transport)
│   ├── tools.ts          # 14 MCP tool definitions
│   ├── router.ts         # Multi-cloud dispatch routing layer
│   ├── types.ts          # Unified type definitions
│   ├── config-store.ts   # Persistent config store
│   └── adapters/
│       ├── base.ts       # CloudAdapter interface
│       ├── aws.ts        # AWS (stop/start to get a new dynamic IP)
│       ├── azure.ts      # Azure (unbind → delete → create → bind)
│       ├── oci.ts        # OCI (ephemeral IP, RSA-SHA256 signing)
│       ├── vultr.ts      # Vultr (reserved IP → attach → delete old)
│       └── cloudflare.ts # Cloudflare DNS (find + update A record)
├── ui/
│   ├── config-form.html  # Full-featured config form (639 lines, four-platform tabs)
│   ├── aws-config.html   # AWS standalone form (lightweight, ~90 lines)
│   ├── azure-config.html # Azure standalone form
│   ├── oci-config.html   # OCI standalone form
│   ├── vultr-config.html # Vultr standalone form
│   └── server.cjs        # Local config server (system-assigned port)
└── dist/                 # Build output
```

## Config File

Path: `~/.ip-switch/config.json` (i.e. `C:\Users\<username>\.ip-switch\config.json`)

Structure:

```json
{
  "profiles": {
    "aws-sg": {
      "name": "aws-sg",
      "provider": "aws",
      "region": "ap-southeast-1",
      "instanceId": "i-xxx",
      "credentials": { "accessKeyId": "...", "secretAccessKey": "..." },
      "subdomain": "app.example.com",
      "proxied": false,
      "cloudflare": {
        "apiToken": "profile-level Cloudflare API Token",
        "zoneId": "profile-level Zone ID"
      }
    }
  }
}
```

Cloudflare credentials are stored inside each profile — there are no global fields anymore. Each profile independently binds its own Cloudflare account.

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

**Complete list of MCP tools (13)**

### Cloud platform operations (8, credentials passed per-call)

1. `rotate_instance_ip` — One-click rotate the public IP
2. `get_instance_info` — Query instance details
3. `list_instances` — List all instances in a region
4. `allocate_ip` — Allocate a new public IP
5. `associate_ip` — Associate an IP with an instance
6. `release_ip` — Release/delete a public IP
7. `list_ips` — List allocated public IPs
8. `get_instance_public_ip` — Query an instance's current public IP

### Profile management + DNS (5, persisted)

9. `save_profile` — Save a cloud platform profile (with its own Cloudflare credentials)
10. `list_profiles` — List all saved profiles
11. `delete_profile` — Delete a saved profile
12. `update_dns` — Manually update the Cloudflare DNS A record (requires cfApiToken + cfZoneId)
13. `rotate_ip_and_update_dns` — One-click: rotate IP + auto-update DNS (core tool)

---

## Update & Uninstall

### Update

Re-run the install script (auto git pull + install dependencies + build + update MCP config), or do it manually:

> **Environment: Bash Shell / PowerShell (either works)**

```bash
cd ~/ip-switch
git pull
npm install
npm run build
```

### Uninstall

> **Environment: Bash Shell (macOS / Ubuntu) or PowerShell (Windows)**

```bash
# Delete the project directory
rm -rf ~/ip-switch            # macOS / Ubuntu
Remove-Item -Recurse -Force ~/ip-switch   # Windows

# Delete config data (including saved credentials)
rm -rf ~/.ip-switch                # macOS / Ubuntu
Remove-Item -Recurse -Force ~/.ip-switch       # Windows

# Remove the ip-switch entry from WorkBuddy's mcp.json
```

---

## FAQ

### 1. Build fails or exits silently

**Cause**: The `ELECTRON_RUN_AS_NODE=1` environment variable interferes with the `tsc` compiler.

**Fix**:

> **Environment: Bash Shell (macOS / Ubuntu) or PowerShell (Windows)**

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
- The script has built-in DNS warm-up and up to 3 automatic retries
- For a private repo, set up an SSH key first: `ssh-keygen -t ed25519 && cat ~/.ssh/id_ed25519.pub`
- Clone manually: `git clone https://gitee.com/areyi2014/ip-switch.git`

### 3. Tools don't appear after MCP configuration

**Cause**: The MCP process failed to start, the configured path is wrong, or the mcp.json format isn't recognized.

**Troubleshooting**:
1. Confirm `dist/index.js` exists
2. Confirm the node path in `command` is correct: `which node` (full path)
3. Confirm mcp.json is valid JSON (the script serializes output with node, so indentation/escaping issues won't occur)
4. Test manually: `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | node dist/index.js`
5. Check the WorkBuddy connector management page for error messages

### 4. npm install fails (permission error)

**Fix**: Avoid `sudo`. If you get an EACCES error:

> **Environment: Bash Shell (macOS / Ubuntu)**

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

> **Environment: PowerShell**

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Or bypass the restriction with `powershell -ExecutionPolicy Bypass -File install.ps1`.

### 7. Create a Codex desktop shortcut (no flashing console window)

When launching the Codex desktop app directly with `codex.exe` on Windows, a console window flashes on screen. Running the VBS script via `wscript.exe` (the GUI version of Windows Script Host) avoids this.

**Steps:**

1. Copy `codex_app.vbs` from the project root to a fixed location (e.g. `C:\Users\<username>\bin\codex_app.vbs`).

> The script uses **dynamic path resolution** — no hardcoded paths need manual editing. It locates `codex.exe` with these strategies in order:
> 1. **Strategy 1**: Read the `CODEX_CLI_PATH` setting from `~\.codex\config.toml`;
> 2. **Strategy 2**: Scan all subdirectories under `%LOCALAPPDATA%\OpenAI\Codex\bin` and pick the `codex.exe` with the **latest modification time**;
> 3. **Strategy 3**: If both fail, fall back to the `codex` command on the system `PATH`.

2. On the desktop, right-click → **New → Shortcut**, and in the target field enter:

```
C:\Windows\System32\wscript.exe "C:\Users\<username>\bin\codex_app.vbs"
```

3. Click "Next", name it "Codex", and finish. Double-clicking the shortcut now launches the Codex desktop app without a flashing console window.

> **Notes**:
> - `wscript.exe` is the GUI version of Windows Script Host (WSH); `cscript.exe` is the console version. Running the script with `wscript.exe` **does not pop up a console window**.
> - The 2nd argument `0` of `WshShell.Run` means launch with a hidden window; the 3rd argument `False` means don't wait for the script to finish.
> - **No hardcoded paths needed**: Codex's install directory often contains a version hash (e.g. `bin\8e8bf206e63ac436\`); this script auto-locates the latest version, so the shortcut keeps working after Codex upgrades.
> - Setting `CODEX_CLI_PATH` in `config.toml` explicitly specifies the codex.exe path (highest priority).
> - You can also run it directly with `wscript.exe`: `wscript.exe "C:\Users\<username>\bin\codex_app.vbs"` (equivalent effect).

---

## Notes for Developers

- `tsc` may exit silently (exit 1, no output) due to interference from the `ELECTRON_RUN_AS_NODE=1` environment variable
- Solution: `env -u ELECTRON_RUN_AS_NODE -u NODE_OPTIONS npx tsc` (Windows PowerShell: `$env:ELECTRON_RUN_AS_NODE = ""; npm run build`)
- Azure SDK: `networkInterfaces.updateProperties` doesn't exist — use `beginCreateOrUpdateAndWait`
- MCP SDK: returned content `type: 'text'` needs `as const`
- `package.json` is set to `"type": "module"`; local scripts use the `.cjs` extension
