# ips-cfg — 打开凭据配置页

薄快捷入口：定位 ip-switch 安装目录、启动本地 UI server，并把页面嵌入回复。

## 步骤

1. 定位安装目录：读 `~/.workbuddy/skills/ips-main/scripts/.install-path.txt` 首行（兜底：`~/.codex/skills/ips-main/scripts/.install-path.txt`）。
2. 运行 `node <install-dir>/scripts/open-ui.mjs [aws|azure|oci|vultr]`，从 stdout 读取本地 URL。脚本设计上**默认不弹系统浏览器**。
3. 立即把页面**嵌入回复**（自动打开，绝不只贴链接等用户点），按客户端选择：
   - **WorkBuddy**：调 `present_files` 传 `http://127.0.0.1:<port>/...` URL —— 页面嵌入内置预览面板（同源 fetch 正常，保存按钮可直接写配置）。**禁用 `show_widget`**（其沙箱 CSP 拦截 fetch）。
   - **Codex 桌面端**：`open_in_codex`，`target: { type: "browser", url }`、`placement: "right"`。绝不打开 `plugin://ip-switch@local`（渲染空白页）。
   - **其他客户端**：把 URL 作为可点击链接写在回复里，不代开浏览器。
4. 页面语言：默认英文页；仅当用户说中文时用 `-zh` 页（`config-form-zh.html` 或脚本参数 `zh`）。
5. 可靠性：`open-ui.mjs` 的脱离式 server 可能随 agent 命令结束被回收。URL 不可达时（curl 000 / exit 7），改用**常驻后台任务**：环境变量 `IP_SWITCH_DATA_DIR=<install-dir>/data` + `node <install-dir>/ui/server.cjs`，然后读 `<install-dir>/data/server-port.txt` 拿端口，用 `curl --noproxy "*"` 验证 200 后再嵌入。
6. 用户保存后，用 `list_profiles` 工具验证（确认新 profile 与 `cloudflareConfigured`）。

## 约定

- 绝不在对话中索要或复述明文凭据；表单是唯一的凭据输入口。
- 完整手册：主技能 `ips-main`（英文）/ 其 `references/zh.md`（中文）。

## 扩展

更多 `ips-*` 快捷指令可作为同级技能添加（仓库 `skills/` 下一个命令一个目录）；两个安装脚本会自动安装目录下所有 `ips-*`。
