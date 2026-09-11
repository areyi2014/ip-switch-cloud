---
name: ip-switch
description: 配置和管理 ip-switch 的多云账号、凭据与 Cloudflare DNS；需要打开 AWS、Azure、OCI、Vultr 或全功能配置页面时使用。
---

# ip-switch

本技能负责配置入口和操作路由。详细的工具矩阵、参数说明和排障步骤见 [references/zh.md](references/zh.md)。

## 使用原则

- 轮换公网 IP、查询实例、更新 DNS、列出或删除 profile：直接调用 `ip-switch` MCP 工具，不要启动配置页面。
- 添加或修改云厂商凭据、AccessKey、Cloudflare Token：打开配置页面，让用户在页面里亲手填写；不要在对话中索要或复述明文凭据。
- 用户保存后，调用 `list_profiles` 验证 profile 是否生成，并检查 `cloudflareConfigured` 是否符合预期。
- 删除 profile、释放公网 IP 等有破坏性的操作，先向用户确认目标。

## 打开配置页面

1. 根据用户目标选择页面：`aws`、`azure`、`oci`、`vultr`；未指定时打开默认全功能表单。
2. 在本技能根目录运行：

   ```powershell
   node <skill-root>/scripts/open-ui.mjs aws --port
   ```

   读取 stdout 最后一行的本地 URL。`<skill-root>` 指本 `SKILL.md` 所在目录。
3. 在 Codex 桌面端，立即用 `open_in_codex` 打开该 URL：
   `target: { type: "browser", url: "<printed-url>" }`，`placement: "right"`。
   不要打开 `plugin://ip-switch@local`；该协议地址在内置浏览器中会渲染为空白页。
4. 其他客户端或手动运行场景，让用户用系统浏览器打开 URL。
5. 用户在页面保存后回到对话，再调用 `list_profiles` 验证结果。

## 维护命令

```powershell
node <skill-root>/scripts/open-ui.mjs --status
node <skill-root>/scripts/open-ui.mjs --stop
```

`--status` 返回 UI 服务是否运行、实际端口和安装目录；`--stop` 停止后台 UI 服务。若脚本找不到安装目录，先重新执行 `install.ps1` 或 `install.sh`。
