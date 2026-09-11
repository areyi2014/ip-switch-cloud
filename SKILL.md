---
name: ip-switch
description: Configure and manage multi-cloud accounts, credentials, and Cloudflare DNS for ip-switch; use when opening the AWS, Azure, OCI, Vultr, or full-featured config page is needed.
---

# ip-switch

This skill owns the configuration entry point and operation routing. For the detailed tool matrix, parameter reference, and troubleshooting steps, read [references/zh.md](references/zh.md) (Chinese manual) on demand.

## Usage Principles

- Rotating a public IP, querying instances, updating DNS, listing or deleting a profile: call the `ip-switch` MCP tools directly. Do not launch the config page.
- Adding or editing cloud provider credentials, AccessKeys, or Cloudflare tokens: open the config page and let the user fill in the form themselves. Never ask for or repeat plaintext credentials in the conversation.
- After the user saves, call `list_profiles` to verify the profile was created and that `cloudflareConfigured` matches expectations.
- For destructive operations (deleting a profile, releasing a public IP), confirm the target with the user first.

## Opening the Config Page

1. Pick the page based on the user's goal: `aws`, `azure`, `oci`, `vultr`; when unspecified, open the default full-featured form.
2. Run this from the skill root (the directory containing this `SKILL.md`):

   ```powershell
   node <skill-root>/scripts/open-ui.mjs aws
   ```

   Read the local URL from the last line of stdout.
   The script **never opens a system browser by default** — strictly forbidden to switch to `start`/`open`/`xdg-open` or `--open` to pop a new window.
3. Once you have the URL you **must auto-open it immediately** (the agent actively invokes the open action; never just paste a link and wait for the user to click) and embed the page in the reply, per client:
   - **Codex desktop**: immediately use `open_in_codex` with the URL:
     `target: { type: "browser", url: "<printed-url>" }`, `placement: "right"`.
     Do not open `plugin://ip-switch@local`; that protocol renders as a blank page in the built-in browser.
   - **WorkBuddy**: call `present_files` with the `http://127.0.0.1:<port>/...` URL;
     the page auto-embeds into the built-in browser preview panel (same-origin fetch works, the save button can write config directly).
     Never embed with `show_widget` — its sandbox CSP blocks fetch, breaking the save button.
   - **Other clients**: put the URL in the reply as a clickable link; do not open a browser on the user's behalf.
   - Reliability note: if the URL is unreachable after the script exits (curl returns 000 / exit 7), the detached server was reaped with the session.
     Instead run `node <install-dir>/ui/server.cjs` as a **long-lived background task**
     (env `IP_SWITCH_DATA_DIR=<install-dir>/data`), read the port from `<install-dir>/data/server-port.txt`,
     verify HTTP 200 with `curl --noproxy "*"` before invoking the open action; testing curl requires `--noproxy` (a local proxy turns localhost into 502).
4. After the user saves in the page and returns to the conversation, call `list_profiles` to verify the result.

## Maintenance Commands

```powershell
node <skill-root>/scripts/open-ui.mjs --status
node <skill-root>/scripts/open-ui.mjs --stop
```

`--status` reports whether the UI server is running, its actual port, and the install dir; `--stop` shuts the background UI server down. If the script cannot find the install dir, re-run `install.ps1` or `install.sh` first.
