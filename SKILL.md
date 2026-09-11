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
   node <skill-root>/scripts/open-ui.mjs aws
   ```

   读取 stdout 最后一行的本地 URL。`<skill-root>` 指本 `SKILL.md` 所在目录。
   该脚本默认**不弹系统浏览器**——严禁改用 `start`/`open`/`xdg-open` 或 `--open` 弹新窗口。
3. 拿到 URL 后**必须立即自动打开**（agent 主动调打开动作，不允许只贴链接让用户自己点），并把页面嵌入回复，按客户端选择方式：
   - **Codex 桌面端**：立即用 `open_in_codex` 打开该 URL：
     `target: { type: "browser", url: "<printed-url>" }`，`placement: "right"`。
     不要打开 `plugin://ip-switch@local`；该协议地址在内置浏览器中会渲染为空白页。
   - **WorkBuddy**：调用 `present_files` 传入该 `http://127.0.0.1:<port>/...` URL，
     页面会自动嵌入内置浏览器预览面板（同源 fetch 正常，保存按钮可直接写配置）。
     不要用 `show_widget` 内嵌——其沙箱 CSP 会拦截 fetch，保存按钮失效。
   - **其他客户端**：把 URL 作为可点击链接写在回复里，不要代开浏览器。
   - 可靠性提示：脚本退出后若 URL 连不上（curl 返回 000/exit 7），说明脱离式 server 被会话回收，
     改用**后台任务**常驻运行 `node <install-dir>/ui/server.cjs`
     （env `IP_SWITCH_DATA_DIR=<install-dir>/data`），端口从 `<install-dir>/data/server-port.txt` 读取，
     `curl --noproxy "*"` 验证 HTTP 200 后再执行打开动作；测试 curl 必须加 `--noproxy`（本机代理会返回 502）。
4. 用户在页面保存后回到对话，再调用 `list_profiles` 验证结果。

## 维护命令

```powershell
node <skill-root>/scripts/open-ui.mjs --status
node <skill-root>/scripts/open-ui.mjs --stop
```

`--status` 返回 UI 服务是否运行、实际端口和安装目录；`--stop` 停止后台 UI 服务。若脚本找不到安装目录，先重新执行 `install.ps1` 或 `install.sh`。
