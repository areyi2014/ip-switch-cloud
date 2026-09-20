# ips-dns — 更新 Cloudflare 域名解析记录

`ip-switch` MCP 服务的薄快捷入口。

## 步骤

1. 从用户消息里收集 zone / 记录名 / 目标 IP；缺什么问什么，不重复索要。
2. 调用 `update_dns` 工具（WorkBuddy 中暴露为 `mcp__ip-switch__update_dns`）。
3. 汇报：记录名、旧值、新值，以及返回的 TTL / 代理状态。
4. 用户要「轮换 IP + 更新 DNS」一步到位时，直接调 `rotate_ip_and_update_dns`，不要拆成两条指令。

## 约定

- 绝不在对话里索要 Cloudflare API Token；存 Token 的 profile 通过 `/ips-cfg` 管理。
- 请求含糊时，写入前先和用户确认记录名与目标 IP。

## 扩展

更多 `ips-*` 快捷指令可作为同级技能添加（仓库 `skills/` 下一个命令一个目录）；两个安装脚本会自动安装目录下所有 `ips-*`。
