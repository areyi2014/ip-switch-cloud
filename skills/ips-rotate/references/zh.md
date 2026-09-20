# ips-rotate — 轮换实例公网 IP

`ip-switch` MCP 服务的薄快捷入口。干活的是 MCP 工具，本技能只做路由。

## 步骤

1. 用户未指明 profile 时，先用 `list_profiles` 工具解析目标；仍有歧义再追问。
2. 调用 `rotate_instance_ip` 工具（WorkBuddy 中暴露为 `mcp__ip-switch__rotate_instance_ip`），传入 profile / 实例 / 区域参数。
3. 用紧凑表格汇报结果：云厂商 / 实例 / 旧 IP / 新 IP / 关联状态。
4. 如果用户要「轮换 + 更新 DNS」一步到位，优先用 `rotate_ip_and_update_dns` 工具（或轮换后再走 `/ips-dns`）。

## 兜底

- `rotate_instance_ip` 失败时，手动两步走：先 `allocate_ip`，再 `associate_ip`。
- 仅当用户明确要求放弃某个地址时才用 `release_ip`。

## 约定

- 绝不在对话里索要云凭据；引导用户走 `/ips-cfg`。
- 破坏性操作（释放 IP）必须先让用户确认目标。

## 扩展

更多 `ips-*` 快捷指令可作为同级技能添加（仓库 `skills/` 下一个命令一个目录）；两个安装脚本会自动安装目录下所有 `ips-*`。
