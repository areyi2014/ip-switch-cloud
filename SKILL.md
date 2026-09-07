---
name: ip-switch
license: MIT
github: https://github.com/areyi2014/ip-switch
description: ip-switch MCP 服务使用手册。指导 AI 唤起 MCP 的 13 个工具（多云公网 IP 轮换 / Cloudflare DNS / profile 管理）；凭据未配置时唤起浏览器配置页。跨 WorkBuddy / Codex / 任意支持 MCP 的 Agent。
metadata:
  author: areyi2014
  version: 1.0.0
  display_name: "IP Switch · 配置面板"
  display_name_en: "IP Switch · UI"
  description_zh: "ip-switch MCP 使用指南：何时直接调 MCP 工具（rotate_ip_and_update_dns 等 13 个）、何时开浏览器配置页填凭据、工具不可见时如何排障"
  description_en: "ip-switch MCP usage guide: when to invoke the 13 MCP tools (rotate_ip_and_update_dns, etc.), when to launch the browser config UI for credentials, and how to troubleshoot missing tools."
  visibility: "public"
---

# ip-switch — 多云 IP 轮换 MCP 服务使用手册

## 1. 这是什么

ip-switch 是一个 **MCP（Model Context Protocol）服务**，安装后被注册到本 Agent（WorkBuddy / Codex），为 AI 提供 13 个工具：轮换云实例公网 IP、查实例/弹性 IP、把子域名绑定到实例 IP 的 Cloudflare DNS、保存/管理云账号 profile。

本 skill 承担两个职责（**不要混淆**）：

| 场景 | 用哪个 |
|------|--------|
| 用户想做**操作**（轮换 IP、查 IP、更新 DNS、管理 profile） | **直接唤起 MCP 工具**（见 §3–§5），不需要本 skill 的脚本 |
| 用户要**配置凭据**（首次添加云账号 / 编辑凭据） | 用本 skill 自带的脚本打开浏览器表单（见 §6），由用户亲手填凭据并保存到 profile |

> 核心原则：**MCP 工具轮不到本 skill 脚本上场；只有「填凭据/看配置表单」才需要开 UI。**

## 2. 前置条件（必读）

**必须先跑过 `bash install.sh` 或 `install.ps1`**。install 做了三件事：
1. 编译并注册 MCP 服务 → 本 Agent 工具列表里出现 `ip-switch` 的 13 个工具（重点）
2. 把本 skill 装到用户级目录 → AI 能读到这份手册、能调用开 UI 的脚本
3. 创建运行时数据目录 `<install-dir>/data/`

若 Agent 的工具列表里**看不到** ip-switch 工具，跳到 §7 排障。

## 3. 快速决策：唤起 MCP 工具，还是开 UI？

```text
用户意图
├─ 涉及「添加 / 编辑 / 设置 / 填写 云账号、凭据、AccessKey、子域名」→ 开 UI 配置页（§6）
├─ 涉及「轮换 / 更换 公网 IP」且已提子域名 → 一键工具 rotate_ip_and_update_dns(profileName)
├─ 涉及「轮换 / 更换 IP / 分配 / 释放 / 绑定」→ 凭据即时工具组（§5.1）
├─ 涉及「列出 / 查看 已配置、我的账号」→ list_profiles（不泄露凭据明文）
├─ 涉及「为什么没生效 / DNS 没更新」→ list_profiles + get_instance_public_ip 查证
└─ 兜底：先 list_profiles 看现有配置，再决定
```

**执行前必须探活**：先调 `list_profiles` 确认服务在线、确认有没有可用的 profile（如果工具调用失败/返回空，见 §7）。

## 4. MCP 服务总览（13 个工具）

| 组 | 工具 | 一句话 | 依赖已保存的 profile？ |
|----|------|--------|----------------------|
| **一键** | `rotate_ip_and_update_dns` | 轮换 profile 实例 IP + 自动更新绑定子域名的 Cloudflare DNS | ✅ 必需（且 profile 内须带 Cloudflare 凭据） |
| **云操作** | `rotate_instance_ip` | 轮换实例公网 IP（AWS stop/start、Azure 换 NIC IP、OCI 删建、Vultr 换保留 IP） | ❌ 凭据实时传 |
| | `get_instance_info` | 查实例详情（当前公/私网 IP、状态） | ❌ |
| | `list_instances` | 列出区域内实例 | ❌ |
| | `allocate_ip` | 分配新公网 IP | ❌ |
| | `associate_ip` | 把已分配 IP 绑到实例 | ❌ |
| | `release_ip` | 释放/删除公网 IP | ❌ |
| | `list_ips` | 列出区域内已分配 IP | ❌ |
| | `get_instance_public_ip` | 查实例当前公网 IP | ❌ |
| **配置管理** | `save_profile` | 保存 profile（含可选 Cloudflare 凭据） | —（写数据） |
| | `list_profiles` | 列出所有 profile（含是否带 Cloudflare） | — |
| | `delete_profile` | 按名字删除 profile | — |
| **DNS** | `update_dns` | 把子域名 A 记录指向指定 IP（需显式传 Cloudflare Token/Zone） | ❌ 显式传参 |

- 服务进程：`node <install-dir>/dist/index.js`（stdio），由 MCP 客户端按需拉起，AI 无需手动启动；桌面快捷方式（`codex_app.vbs` / `codex_app.sh`）会常驻后台一份。
- 数据文件：profile 与凭据存于 **`<install-dir>/data/config.json`**（与 MCP server、UI server 三方共享，已 gitignore）。

## 5. 如何唤起 MCP 服务（重点）

### 5.1 凭据即时工具（不依赖 profile）

参数通用形态（zod 已注册，AI 按 schema 填空即可）：

```text
provider:    aws | azure | oci | vultr
region:      AWS: us-east-1…；Azure: eastus…；OCI: us-ord-1…；Vultr: ewr…
instanceId:  AWS: i-xxx；Azure: rg/vmName；OCI: ocid1.instance…；Vultr: 实例 UUID
credentials: { …按 provider 的键填… }
```

`credentials` 的键随 provider 变化（**不要把键混着填**）：

| provider | credentials 键 |
|----------|----------------|
| aws | `accessKeyId`, `secretAccessKey`, `[sessionToken]` |
| azure | `subscriptionId`, `clientId`, `clientSecret`, `tenantId`, `[resourceGroupName]` |
| oci | `tenancy`, `user`, `fingerprint`, `privateKey` |
| vultr | `apiKey` |

例（用户要求直接轮换某台 AWS 实例，且愿意在对话中给凭据——一般更推荐走 profile）：

```json
rotate_instance_ip({
  "provider": "aws", "instanceId": "i-0abc…", "region": "ap-southeast-1",
  "credentials": { "accessKeyId": "…", "secretAccessKey": "…" }
})
```

### 5.2 profile 一键工具（日常主力）

先 `list_profiles` 看有哪些 profile：

```text
{ profileCount: 2, profiles: [ { name: "aws-sg", provider: "aws", region: "ap-southeast-1",
  instanceId: "i-…", subdomain: "sg.example.com", proxied: false, cloudflareConfigured: true }, … ] }
```

- **轮换并同步 DNS（一次完成）**：`rotate_ip_and_update_dns({ "profileName": "aws-sg" })` → 返回 `oldIp / newIp / dnsUpdated / message`。
- 若该 profile 的 `cloudflareConfigured: false`，此工具会报错——需要先补 Cloudflare 凭据（见 5.3）。
- 用户说「轮换所有服务器 / 全部 IP」时，没有批量工具，正确做法是：`list_profiles` → 对每个 profile 依次调 `rotate_ip_and_update_dns`，逐个向用户汇报结果。

### 5.3 首次使用 / 添加账号（UI → profile 闭环）

**凭据属于敏感信息：绝不在对话里向用户索取或复述明文**。首次添加账号的流程：

1. 开 UI 表单（§6），让用户**在浏览器里亲手填** provider / 凭据 / 实例 / 子域名 / Cloudflare Token 与 Zone，点保存（保存写 `save_profile` 同款数据到 `data/config.json`）。
2. 回对话后用 `list_profiles` 确认 profile 已出现、`cloudflareConfigured` 为 true（绑定 DNS 需要）。
3. 之后一切操作都走 §5.2 的一键工具，无需再碰凭据。

> 用户坚持「用我给的 AccessKey 直接加一个配置」且不想开浏览器时，可代调 `save_profile`（schema 里带 `cfApiToken`/`cfZoneId` 可选），但保存前要把明文凭据展示给用户确认，并提示数据明文落盘于 `data/config.json`。

### 5.4 唤起前 Checklist（每轮都过一遍）

- [ ] 工具列表里有没有 `ip-switch` 的 13 个工具？（没有 → §7）
- [ ] 涉及 profile 的工具先 `list_profiles` 探活 + 确认 profile 存在
- [ ] `rotate_ip_and_update_dns` 前确认该 profile `cloudflareConfigured: true`，否则先引导补凭据（§5.3）
- [ ] 涉及删除/释放（`delete_profile` / `release_ip`）先跟用户确认目标
- [ ] 结果必须结构化回显：old IP → new IP、DNS 是否更新、失败原因

## 6. UI 配置页（本 skill 脚本，填凭据专用）

只有当用户要**配置/编辑凭据**时才调用。脚本位于用户级副本（install 已装好）：

| 场景 | 命令 | 是否弹窗 |
|------|------|----------|
| **Windows 外行 / 桌面快捷方式**（零窗口，推荐） | 双击 `~/.workbuddy/skills/ip-switch/scripts/open-ui.vbs` 或 `wscript open-ui.vbs [aws\|azure\|oci\|vultr]` | **完全不弹窗**（wscript + CREATE_NO_WINDOW） |
| 默认全功能表单（增删改所有云账号） | `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs` | 用户自己的终端可见日志 |
| 只加 AWS | `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs aws` | 同上 |
| 只加 Azure / OCI / Vultr | `… open-ui.mjs azure`（`oci` / `vultr` 同理） | 同上 |
| Windows PowerShell | `& "$env:USERPROFILE\.workbuddy\skills\ip-switch\scripts\open-ui.mjs" aws` | PowerShell 窗口可见日志 |
| 项目内原件（skill 未装时兜底） | `node <install-dir>/scripts/open-ui.mjs aws` | 用户终端可见日志 |
| 静默模式（不打印 [INFO]，日志写文件） | 加 `--quiet` / `-q`（vbs 已自动启用） | 仅文件日志 |

**给外行用户的标准建议**：桌面右键 `open-ui.vbs` → "发送到" → "桌面快捷方式"。以后双击图标就打开浏览器配置页，全程零窗口。`open-ui.vbs` 内部用 WScript.Shell 以 WindowStyle=0 调用 node，并自动加 `--quiet`，所以 [INFO] 日志全走 `<install-dir>/data/open-ui.log` 文件，stderr 干净。

脚本行为：
1. 自动定位 `<install-dir>`（用户级副本读旁侧的 `.install-path.txt`；项目内原件按自身路径推导）
2. 后台拉起 `ui/server.cjs`，浏览器打开表单；URL 也会打到 stderr 供回显
3. 辅助参数：`--port`（只输出 URL 不开浏览器）、`--status`（JSON 状态）、`--stop`（关掉后台 UI server）、`--quiet`（静默模式）

**Windows 后台进程"零窗口"机制说明**（why vbs works）：
- open-ui.mjs spawn server 时，**优先检测 `nodew.exe`**（Node 的 GUI 子系统版本，与 `node.exe` 同目录，Windows 官方安装包自带）。若存在则用之，否则 fallback 到 `node.exe + windowsHide: true`
- `nodew.exe` 是真正的 GUI subsystem → 启动时不创建 console → **彻底无窗口**
- 若你的机器没装 `nodew.exe`，spawn 仍带 `windowsHide: true`，但 `node.exe`（console subsystem）启动时 Windows 可能仍会闪一下——这种情况装个官方 Node 安装包就解决了，或者就用 vbs 入口（外层 wscript 已是 GUI subsystem，子进程无 console）

**浏览器约定**：一定要让用户用**真实浏览器**访问 URL 填表，不要用 Agent 内嵌 widget（其沙箱 CSP 会拦 fetch，保存写不进去）。表单保存后让用户「回到对话」，AI 用 `list_profiles` 验证。

## 7. 排障：MCP 工具不可见 / 调用报错

### 7.1 Agent 工具列表里没有 ip-switch

按顺序排查，**每一项都让用户配合做**：

1. **install 是否跑过**：没跑过 → 重跑 `bash install.sh` / `install.ps1`（幂等，可重复执行，会自动重启客户端）。
2. **WorkBuddy**：`~/.workbuddy/mcp.json` 里应有 `mcpServers.ip-switch`（command=node 绝对路径，args=[<install-dir>\dist\index.js]）。连接器管理页对 ip-switch 点「信任」，然后重启 WorkBuddy。
3. **Codex**：重启 Codex 使 `~/.codex/config.toml` 的 `[mcp_servers.ip-switch]` / 插件市场生效；插件页应能看到 "IP Switch" 并已启用。
4. **手动兜底**：把下面片段并入对应客户端的 mcp.json（`<install-dir>` 换成实际路径）：

```json
{
  "mcpServers": {
    "ip-switch": {
      "command": "<node 绝对路径>",
      "args": ["<install-dir>/dist/index.js"],
      "cwd": "<install-dir>"
    }
  }
}
```

5. **验证服务本体**：终端跑 `node <install-dir>/dist/index.js` 应输出 `[ip-switch] Starting MCP server (providers: aws, azure, oci, vultr)` 并等 stdin（stdio 连接），而不是立刻退出报错。报错多为 `dist/` 缺失 → `cd <install-dir> && npm install && npm run build`。

### 7.2 调用工具报错

| 现象 | 处理 |
|------|------|
| `Profile "x" not found` | 先 `list_profiles` 看真实名字/大小写；没有就用 §5.3 建 |
| `Profile has no Cloudflare credentials` | UI 或 `save_profile` 补 `cfApiToken` + `cfZoneId` 重新保存该 profile |
| 云厂商鉴权错误（InvalidAccessKeyId / AuthFailure / 401…） | 凭据错或失效 → 引导用户去 UI 表单更新凭据，绝不让用户在对话里重新粘贴 |
| 权限不足（UnauthorizedOperation / …） | 云账号 IAM 缺 EC2/VNet/Network 权限 → 让用户在云控制台加权限 |
| 轮换成功但无新 IP / DNS 未更新 | 回显 `rotateResult` / `dnsResult` 原样给用户，检查 Cloudflare Token 的 Zone 权限与 `proxied` 设置 |

## 8. 附录：路径速查

```
<install-dir>/                        ← ip-switch 项目（install 的目标）
├── dist/index.js                     ← MCP 服务入口（注册到各客户端的就是它）
├── data/config.json                  ← 凭据/profile（MCP 与 UI 共享，gitignore）
├── .mcp.json                         ← Codex 项目级直连配置
├── ui/server.cjs                     ← 配置页 HTTP server（open-ui.mjs 拉起）
├── scripts/open-ui.mjs               ← 本 skill 脚本原件
└── SKILL.md                          ← 本文件
~/.workbuddy/skills/ip-switch/        ← WorkBuddy skill 副本（install 创建）
~/.codex/skills/ip-switch/            ← Codex 镜像（仅当 ~/.codex/skills 已存在）
~/.workbuddy/mcp.json                 ← WorkBuddy MCP 注册
~/.codex/config.toml + ~/.codex/mcp.json + ~/.codex/marketplaces/local/  ← Codex MCP/插件注册
```

卸载：`rm -rf <install-dir>/data`（清凭据，保留程序）；`rm -rf ~/.workbuddy/skills/ip-switch ~/.codex/skills/ip-switch`（卸 skill）；整卸再删 `<install-dir>` 并从 mcp.json / config.toml 移除 ip-switch 条目。
