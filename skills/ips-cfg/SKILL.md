---
name: ips-cfg
description: Open the ip-switch credential config page and embed it in the chat reply (never a system-browser popup). Trigger words: config page, credentials, add account, edit AccessKey, Cloudflare token.
---

# ips-cfg — Open the credential config page

Thin quick-command entry. Locates the ip-switch install dir, starts the local UI server, and embeds the page in the reply.

## Steps

1. Locate the install dir: read the first line of `~/.workbuddy/skills/ips-main/scripts/.install-path.txt` (fallback: `~/.codex/skills/ips-main/scripts/.install-path.txt`).
2. Run `node <install-dir>/scripts/open-ui.mjs [aws|azure|oci|vultr]` and read the local URL from stdout. The script never opens a system browser by design.
3. Embed the page in the reply immediately (auto-open; never just paste a link), per client:
   - **WorkBuddy**: call `present_files` with the `http://127.0.0.1:<port>/...` URL — the page embeds into the built-in preview panel (same-origin fetch works, Save buttons write config directly). Never embed with `show_widget` (its sandbox CSP blocks fetch).
   - **Codex desktop**: `open_in_codex` with `target: { type: "browser", url }` and `placement: "right"`. Never open `plugin://ip-switch@local` (renders blank).
   - **Other clients**: put the URL as a clickable link in the reply.
4. Page language: default to the English page; use the `-zh` pages (`config-form-zh.html` or the script arg `zh`) only when the user speaks Chinese.
5. Reliability: the detached server spawned by `open-ui.mjs` may be reaped when the agent command exits. If the URL is unreachable (curl 000 / exit 7), start a **long-lived background task**: env `IP_SWITCH_DATA_DIR=<install-dir>/data` + `node <install-dir>/ui/server.cjs`, then read the port from `<install-dir>/data/server-port.txt` and verify with `curl --noproxy "*"` before embedding.
6. After the user saves, verify with the `list_profiles` tool (check the new profile and `cloudflareConfigured`).

## Conventions

- Never ask for or repeat plaintext credentials in the conversation; the form is the only credential input.
- Full manual: the main `ips-main` skill (English) or its `references/zh.md` (Chinese).

## Extending

More `ips-*` quick commands can be added as sibling skills (one directory per command under the repo's `skills/`); both installers auto-install every `ips-*` directory they find there.
