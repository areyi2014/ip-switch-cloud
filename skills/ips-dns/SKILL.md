---
name: ips-dns
description: Update a Cloudflare DNS A record to point at a given IP via the ip-switch MCP server. Trigger words: DNS update, DNS record, A record, point domain to IP.
---

# ips-dns — Update Cloudflare DNS record

Thin quick-command entry for the `ip-switch` MCP server.

## Steps

1. Collect zone / record name / target IP from the user's message; ask only for what is missing.
2. Call the `update_dns` tool (exposed as `mcp__ip-switch__update_dns` in WorkBuddy).
3. Report: record name, old value, new value, TTL / proxy status when returned.
4. If the user wants "rotate IP and update DNS" in one step, call `rotate_ip_and_update_dns` instead of two separate commands.

## Conventions

- Never ask for the Cloudflare API token in chat; profiles holding tokens are managed via `/ips-cfg`.
- Confirm the record name and target IP with the user before writing when the request is ambiguous.

## Extending

More `ips-*` quick commands can be added as sibling skills (one directory per command under the repo's `skills/`); both installers auto-install every `ips-*` directory they find there.
