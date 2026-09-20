---
name: ips-list
description: List regional instances / 列出区域实例
---

# ips-list — List instances

Trigger words: list instances, show instances, instance info, public IP lookup.

Thin quick-command entry for the `ip-switch` MCP server. Read-only.

## Steps

1. Determine provider + region from the user's message; resolve the profile with `list_profiles` when needed.
2. Call the `list_instances` tool (exposed as `mcp__ip-switch__list_instances` in WorkBuddy).
3. Present a compact table: instance ID / name / state / public IP.
4. Drill-down on request: `get_instance_info` for full metadata, `get_instance_public_ip` for the current IP only.

## Conventions

- This skill is strictly read-only — never mutate anything.
- If the user actually wants a rotation, route to `/ips-rotate`.

## Extending

More `ips-*` quick commands can be added as sibling skills (one directory per command under the repo's `skills/`); both installers auto-install every `ips-*` directory they find there.
