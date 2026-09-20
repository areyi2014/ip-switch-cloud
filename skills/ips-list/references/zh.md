# ips-list — 列出区域实例

`ip-switch` MCP 服务的薄快捷入口。只读操作。

## 步骤

1. 从用户消息确定云厂商 + 区域；需要时用 `list_profiles` 解析 profile。
2. 调用 `list_instances` 工具（WorkBuddy 中暴露为 `mcp__ip-switch__list_instances`）。
3. 用紧凑表格汇报：实例 ID / 名称 / 状态 / 公网 IP。
4. 按需下钻：`get_instance_info` 看完整元数据，`get_instance_public_ip` 只看当前公网 IP。

## 约定

- 本技能严格只读——不做任何变更操作。
- 用户实际想轮换 IP 时，路由到 `/ips-rotate`。

## 扩展

更多 `ips-*` 快捷指令可作为同级技能添加（仓库 `skills/` 下一个命令一个目录）；两个安装脚本会自动安装目录下所有 `ips-*`。
