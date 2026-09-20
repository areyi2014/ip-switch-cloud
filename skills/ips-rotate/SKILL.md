---
name: ips-rotate
description: Rotate instance public IP (ip-switch) / 轮换实例公网 IP（ip-switch）
---

# ips-rotate — Rotate instance public IP

Trigger words: rotate IP, change public IP, new IP, swap IP.

Thin quick-command entry for the `ip-switch` MCP server. The MCP tools do the work; this skill only routes.

## Steps

1. Resolve the target profile with the `list_profiles` tool when the user did not name one; ask only if ambiguity remains.
2. Call the `rotate_instance_ip` tool (exposed as `mcp__ip-switch__rotate_instance_ip` in WorkBuddy) with the profile / instance / region arguments.
3. Report the result as a compact table: provider / instance / old IP / new IP / association status.
4. If the user wants rotation AND a DNS update, prefer the one-step `rotate_ip_and_update_dns` tool (or route to `/ips-dns` afterwards).

## Fallback

- If `rotate_instance_ip` fails, do the two-step flow manually: `allocate_ip` then `associate_ip`.
- Use `release_ip` only when the user explicitly asks to give up an address.

## Conventions

- Never ask for cloud credentials in chat; route the user to `/ips-cfg` instead.
- Destructive actions (releasing an IP) require explicit user confirmation of the target first.

## Extending

More `ips-*` quick commands can be added as sibling skills (one directory per command under the repo's `skills/`); both installers auto-install every `ips-*` directory they find there.
