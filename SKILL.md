# ip-switch — Multi-Cloud IP Rotation MCP Service Handbook

> **Description**: Multi-cloud public IP rotation MCP service (AWS / Azure / OCI / Vultr) with Cloudflare DNS auto-update, plus a browser-based credential config UI launcher. (Bilingual metadata lives in `skill.json`: `description_zh` / `description_en`.)
>
> Chinese version of this handbook: `references/zh.md` — read it on demand when serving users who prefer Chinese. This file stays English-only to keep the agent instruction layer lean.

## 1. What this is

ip-switch is an **MCP (Model Context Protocol) service**. Once installed, it is registered to this Agent (WorkBuddy / Codex) and provides 13 tools for the AI: rotate cloud instance public IPs, query instances/elastic IPs, point a subdomain's Cloudflare DNS A record at an instance IP, and save/manage cloud account profiles.

This skill has two distinct responsibilities (**do not mix them up**):

| Scenario | Which path to use |
| ---------------------------------------- | ------------------------------------------------ |
| User wants an **operation** (rotate IP, query IP, update DNS, manage profiles) | **Invoke the MCP tools directly** (see §3–§5). This skill's scripts are NOT needed |
| User wants to **configure credentials** (first-time cloud account setup / edit credentials) | Use this skill's bundled script to open the browser config form (see §6); the user fills in credentials by hand and saves them into a profile |

> Core principle: **MCP tools come first; only "enter credentials / view the config form" needs the UI.**

## 2. Prerequisites (must read)

**`bash install.sh` or `install.ps1` must have been run first**. Install does three things:

1. Builds and registers the MCP service → 13 `ip-switch` tools appear in this Agent's tool list (the key part)
2. Installs this skill into the user-level directory → the AI can read this handbook and invoke the UI launcher script
3. Creates the runtime data directory `<install-dir>/data/`

If the ip-switch tools are **missing** from the Agent's tool list, jump to §7 troubleshooting.

## 3. Quick decision: invoke MCP tools, or open the UI?

```text
User intent
├─ Involves "add / edit / set / fill in cloud account, credentials, AccessKey, subdomain" → open the UI config page (§6)
├─ Involves "rotate / change public IP" and a subdomain was mentioned → one-click tool rotate_ip_and_update_dns(profileName)
├─ Involves "rotate / change / allocate / release / associate IP" → per-call credential tools (§5.1)
├─ Involves "list / show configured, my accounts" → list_profiles (never leaks plaintext credentials)
├─ Involves "why didn't it take effect / DNS not updated" → list_profiles + get_instance_public_ip to verify
└─ Fallback: run list_profiles first to see existing profiles, then decide
```

**Liveness check before executing anything**: call `list_profiles` first to confirm the service is online and whether any usable profiles exist (if the tool call fails or returns empty, see §7).

## 4. MCP service overview (13 tools)

| Group | Tool | One-liner | Depends on a saved profile? |
| -------- | -------------------------- | ------------------------------------------------------------ | --------------------------------- |
| **One-click** | `rotate_ip_and_update_dns` | Rotate the profile's instance IP + automatically update the bound subdomain's Cloudflare DNS | ✅ Required (and the profile must carry Cloudflare credentials) |
| **Cloud ops** | `rotate_instance_ip` | Rotate instance public IP (AWS stop/start, Azure swap NIC IP, OCI delete+create, Vultr swap reserved IP) | ❌ Credentials passed per-call |
|          | `get_instance_info`        | Query instance details (current public/private IP, state)    | ❌                                 |
|          | `list_instances`           | List instances in a region                                   | ❌                                 |
|          | `allocate_ip`              | Allocate a new public IP                                     | ❌                                 |
|          | `associate_ip`             | Associate an allocated IP with an instance                   | ❌                                 |
|          | `release_ip`               | Release/delete a public IP                                   | ❌                                 |
|          | `list_ips`                 | List allocated IPs in a region                               | ❌                                 |
|          | `get_instance_public_ip`   | Query an instance's current public IP                        | ❌                                 |
| **Profile mgmt** | `save_profile`     | Save a profile (with optional Cloudflare credentials)        | — (writes data)                   |
|          | `list_profiles`            | List all profiles (including whether Cloudflare is configured) | —                               |
|          | `delete_profile`           | Delete a profile by name                                     | —                                 |
| **DNS**  | `update_dns`               | Point a subdomain's A record at a given IP (requires explicit Cloudflare Token/Zone) | ❌ Explicit params |

- Service process: `node <install-dir>/dist/index.js` (stdio), spawned on demand by the MCP client — the AI never needs to start it manually; the desktop shortcuts (`codex_app.vbs` / `codex_app.sh`) keep one copy running in the background.
- Data file: profiles and credentials live in **`<install-dir>/data/config.json`** (shared by the MCP server and the UI server, gitignored).

## 5. How to invoke the MCP service (key section)

### 5.1 Per-call credential tools (no profile needed)

Common parameter shape (zod schemas are registered; the AI just fills them in):

```text
provider:    aws | azure | oci | vultr
region:      AWS: us-east-1…; Azure: eastus…; OCI: us-ord-1…; Vultr: ewr…
instanceId:  AWS: i-xxx; Azure: rg/vmName; OCI: ocid1.instance…; Vultr: instance UUID
credentials: { …keys vary by provider… }
```

The `credentials` keys change per provider (**never mix keys across providers**):

| provider | credentials keys                                                                   |
| -------- | ------------------------------------------------------------------------------- |
| aws      | `accessKeyId`, `secretAccessKey`, `[sessionToken]`                              |
| azure    | `subscriptionId`, `clientId`, `clientSecret`, `tenantId`, `[resourceGroupName]` |
| oci      | `tenancy`, `user`, `fingerprint`, `privateKey`                                  |
| vultr    | `apiKey`                                                                        |

Example (user asks to rotate a specific AWS instance directly and is willing to share credentials in the conversation — using a profile is generally preferred):

```json
rotate_instance_ip({
  "provider": "aws", "instanceId": "i-0abc…", "region": "ap-southeast-1",
  "credentials": { "accessKeyId": "…", "secretAccessKey": "…" }
})
```

### 5.2 Profile one-click tools (daily workhorse)

First run `list_profiles` to see what exists:

```text
{ profileCount: 2, profiles: [ { name: "aws-sg", provider: "aws", region: "ap-southeast-1",
  instanceId: "i-…", subdomain: "sg.example.com", proxied: false, cloudflareConfigured: true }, … ] }
```

- **Rotate + sync DNS in one shot**: `rotate_ip_and_update_dns({ "profileName": "aws-sg" })` → returns `oldIp / newIp / dnsUpdated / message`.
- If the profile's `cloudflareConfigured: false`, this tool errors out — guide the user to add Cloudflare credentials first (see §5.3).
- When the user says "rotate all servers / all IPs", there is no batch tool. The correct approach: `list_profiles` → call `rotate_ip_and_update_dns` for each profile in turn, reporting results to the user one by one.

### 5.3 First-time setup / adding an account (UI → profile loop)

**Credentials are sensitive: never ask for or echo plaintext credentials in the conversation**. First-time account setup flow:

1. Open the UI form (§6); the user **fills in by hand in the browser**: provider / credentials / instance / subdomain / Cloudflare Token & Zone, then clicks save (save writes the same shape of data as `save_profile` into `data/config.json`).
2. Back in the conversation, use `list_profiles` to confirm the profile appeared and `cloudflareConfigured` is true (required for DNS binding).
3. From then on everything goes through the §5.2 one-click tools — credentials are never touched again.

> If the user insists on "add a profile directly with the AccessKey I give you" and doesn't want to open a browser, you may call `save_profile` on their behalf (schema includes optional `cfApiToken`/`cfZoneId`), but display the plaintext credentials back to the user for confirmation before saving, and note that data is stored in plaintext at `data/config.json`.

### 5.4 Pre-invocation checklist (run through every turn)

- [ ] Are the 13 `ip-switch` tools in the tool list? (If not → §7)
- [ ] For profile-based tools, run `list_profiles` first (liveness check + confirm the profile exists)
- [ ] Before `rotate_ip_and_update_dns`, confirm the profile has `cloudflareConfigured: true`, otherwise guide the user through §5.3 first
- [ ] For delete/release operations (`delete_profile` / `release_ip`), confirm the target with the user first
- [ ] Always report results in a structured way: old IP → new IP, whether DNS was updated, failure reason if any

## 6. UI config page (this skill's scripts, for credential entry only)

Only invoke when the user wants to **configure/edit credentials**. The scripts live in the **user-level copy** (installed by install) and exist in both directories — **interchangeable across both agents**:

| Agent                  | Skill root path                        |
| ---------------------- | -------------------------------- |
| **WorkBuddy**          | `~/.workbuddy/skills/ip-switch/` |
| **Codex desktop / CLI**    | `~/.codex/skills/ip-switch/`     |
| **In-project original** (fallback when skill not installed) | `<install-dir>/scripts/`         |

> The install script auto-mirrors to both locations (the Codex copy is created **only if `~/.codex/skills` already exists**). The `<skill-root>` in all commands below can be any of the paths above.

| Scenario | Command | Console window? |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| **Windows novice / desktop shortcut** (zero windows, recommended) | Double-click `<skill-root>/scripts/open-ui.vbs`, or `wscript open-ui.vbs [aws\|azure\|oci\|vultr]` | **Never** (wscript + CREATE_NO_WINDOW) |
| Default full-featured form (add/edit/delete all cloud accounts) | `node <skill-root>/scripts/open-ui.mjs` | Logs visible in the user's own terminal |
| AWS only | `node <skill-root>/scripts/open-ui.mjs aws` | Same as above |
| Azure / OCI / Vultr only | `… open-ui.mjs azure` (same for `oci` / `vultr`) | Same as above |
| Windows PowerShell | `& "$env:USERPROFILE\<skill-root relative path>\scripts\open-ui.mjs" aws` (WorkBuddy = `.workbuddy\skills\ip-switch`, Codex = `.codex\skills\ip-switch`) | Logs visible in the PowerShell window |
| Quiet mode (no [INFO] prints, logs go to file) | Add `--quiet` / `-q` (vbs enables it automatically) | File log only |

**Standard advice for novice users**: right-click `open-ui.vbs` on the desktop → "Send to" → "Desktop shortcut". From then on, double-clicking the icon opens the browser config page with zero console windows. Internally `open-ui.vbs` uses WScript.Shell with WindowStyle=0 to call node and automatically appends `--quiet`, so all [INFO] logs go to the `<install-dir>/data/open-ui.log` file and stderr stays clean.

Script behavior:

1. Auto-locates `<install-dir>` (the user-level copy reads the adjacent `.install-path.txt`; the in-project original infers from its own path)
2. Spawns `ui/server.cjs` in the background and opens the form in the browser; the URL is also printed to stderr for echo-back
3. Helper flags: `--port` (print URL only, no browser), `--status` (JSON status), `--stop` (stop the background UI server), `--quiet` (quiet mode)

**How the Windows "zero-window" background mechanism works** (why vbs works):

- When open-ui.mjs spawns the server, it **prefers `nodew.exe`** (the GUI-subsystem build of Node, sitting next to `node.exe`, bundled with the official Windows installer). If present it's used; otherwise fallback to `node.exe + windowsHide: true`
- `nodew.exe` is a true GUI subsystem → no console is created on start → **completely windowless**
- If `nodew.exe` isn't installed, the spawn still carries `windowsHide: true`, but `node.exe` (console subsystem) may still flash briefly on Windows — installing the official Node package fixes it, or just use the vbs entry point (the outer wscript is already GUI subsystem, so the child gets no console)

**Browser convention**: always have the user open the URL in a **real browser** to fill the form — never an Agent's embedded widget (its sandbox CSP blocks fetch, so saving fails). After saving, ask the user to "return to the conversation"; the AI verifies with `list_profiles`.

### 6.1 Multi-agent user perspectives (desktop / CLI / manual)

Install has mirrored the skill to both `~/.workbuddy/skills/ip-switch/` and `~/.codex/skills/ip-switch/` — **both agents can discover and use it**. Broken down by scenario, with WorkBuddy / Codex side by side.

#### 1. Desktop apps (most common, novice-friendly)

The user **doesn't type commands** — one natural-language sentence in the Agent chat box is enough; the AI runs the script automatically and reports the URL:

| Agent | User says in chat | Command the AI runs | Browser behavior |
|-------|---------------|-----------------|-----------|
| **WorkBuddy desktop** | "Open the ip-switch config page" / "Add an AWS account" / "Update the Azure credentials" | `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs aws` | Browser opens the matching form |
| **Codex desktop** | Same as above | `node ~/.codex/skills/ip-switch/scripts/open-ui.mjs aws` | Same as above |

> **Prerequisites**: WorkBuddy — click "Trust" for ip-switch on the connector management page, then restart; Codex — enable "IP Switch" on the plugins page (see §7.1 troubleshooting).

#### 2. CLI / developers (bypass the Agent chat, run scripts directly)

| Agent | Command |
|-------|------|
| **Codex CLI** | `codex --profile ip-switch exec "Add an AWS account"` (the profile has the MCP server and skill paths configured); or directly `node ~/.codex/skills/ip-switch/scripts/open-ui.mjs aws` |
| **WorkBuddy** (no official CLI) | Call the skill script directly: `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs aws` (bypasses the desktop app; the UI starts in the background and opens the browser separately) |

#### 3. Manual (any OS / anyone)

| OS | Command (`<skill-root>` = WorkBuddy / Codex / in-project, any of them) |
|----|------|
| **macOS / Linux** | `node <skill-root>/scripts/open-ui.mjs aws` or `bash <skill-root>/scripts/open-ui.sh aws` |
| **Windows zero-window** (recommended for novices) | Double-click `<skill-root>\scripts\open-ui.vbs`, or `wscript <skill-root>\scripts\open-ui.vbs aws` |
| **Windows terminal** (PowerShell) | `& "$env:USERPROFILE\<skill-root relative path>\scripts\open-ui.mjs" aws` |
| **Windows terminal** (Git Bash / cmd) | `node <skill-root>\scripts\open-ui.mjs aws` |

#### Path quick reference (recap of the §6 table header)

| Agent | skill root path |
|-------|------------|
| WorkBuddy | `~/.workbuddy/skills/ip-switch/` |
| Codex | `~/.codex/skills/ip-switch/` |
| In-project original (fallback) | `<install-dir>/scripts/` |

> The three skill roots are **fully equivalent** — all four entry points (vbs / sh / ps1 / mjs) are installed everywhere; install auto-mirrors. The only difference is the path prefix.

## 7. Troubleshooting: MCP tools invisible / tool call errors

### 7.1 ip-switch missing from the Agent's tool list

Troubleshoot in order, **with the user's cooperation at every step**:

1. **Was install run?** If not, re-run `bash install.sh` / `install.ps1` (idempotent, safe to repeat; it auto-restarts clients).
2. **WorkBuddy**: `~/.workbuddy/mcp.json` should contain `mcpServers.ip-switch` (command = absolute node path, args = [<install-dir>\dist\index.js]). Click "Trust" for ip-switch on the connector management page, then restart WorkBuddy.
3. **Codex**: restart Codex so the `[mcp_servers.ip-switch]` entry in `~/.codex/config.toml` / the plugin marketplace takes effect; the plugins page should show "IP Switch" as enabled.
4. **Manual fallback**: merge the snippet below into the client's mcp.json (replace `<install-dir>` with the actual path):

```json
{
  "mcpServers": {
    "ip-switch": {
      "command": "<absolute node path>",
      "args": ["<install-dir>/dist/index.js"],
      "cwd": "<install-dir>"
    }
  }
}
```

5. **Verify the service itself**: running `node <install-dir>/dist/index.js` in a terminal should print `[ip-switch] Starting MCP server (providers: aws, azure, oci, vultr)` and wait on stdin (stdio connection) rather than exiting with an error. Most errors mean `dist/` is missing → `cd <install-dir> && npm install && npm run build`.

### 7.2 Tool call errors

| Symptom | Handling |
| ------------------------------------------------ | --------------------------------------------------------------------------------- |
| `Profile "x" not found` | Run `list_profiles` to check real names/casing; if absent, create via §5.3 |
| `Profile has no Cloudflare credentials` | Re-save the profile with `cfApiToken` + `cfZoneId` via the UI or `save_profile` |
| Cloud vendor auth errors (InvalidAccessKeyId / AuthFailure / 401…) | Credentials wrong or expired → guide the user to update credentials in the UI form; never have them re-paste credentials in the conversation |
| Insufficient permissions (UnauthorizedOperation / …) | The cloud account's IAM lacks EC2/VNet/Network permissions → have the user add permissions in the cloud console |
| Rotation succeeded but no new IP / DNS not updated | Show the user the raw `rotateResult` / `dnsResult`; check the Cloudflare Token's Zone permissions and the `proxied` setting |

## 8. Appendix: path quick reference

```
<install-dir>/                        ← ip-switch project (install target)
├── dist/index.js                     ← MCP service entry (what gets registered to clients)
├── data/config.json                  ← credentials/profiles (shared by MCP & UI, gitignored)
├── .mcp.json                         ← Codex project-level direct config
├── ui/server.cjs                     ← config page HTTP server (spawned by open-ui.mjs)
├── scripts/open-ui.mjs               ← this skill's script originals
├── SKILL.md                          ← this file
└── references/
    └── zh.md                         ← Chinese version of this handbook (on-demand)
~/.workbuddy/skills/ip-switch/        ← WorkBuddy skill copy (created by install)
~/.codex/skills/ip-switch/            ← Codex mirror (only if ~/.codex/skills exists)
~/.workbuddy/mcp.json                 ← WorkBuddy MCP registration
~/.codex/config.toml + ~/.codex/mcp.json + ~/.codex/marketplaces/local/  ← Codex MCP/plugin registration
```

Uninstall: `rm -rf <install-dir>/data` (clears credentials, keeps the program); `rm -rf ~/.workbuddy/skills/ip-switch ~/.codex/skills/ip-switch` (removes the skill); full removal also deletes `<install-dir>` and removes the ip-switch entries from mcp.json / config.toml.
