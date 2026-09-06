---
name: ip-switch
license: MIT
github: https://github.com/areyi2014/ip-switch
description: ip-switch MCP 的可视化配置页唤起器。把 ip-switch 多云 IP 轮换 MCP 的配置界面（AWS / Azure / OCI / Vultr）直接唤起到浏览器。跨 WorkBuddy / Codex / 任何 AI Agent。零依赖 Node.js。
metadata:
  author: areyi2014
  version: 1.0.0
  display_name: "IP Switch · 配置面板"
  display_name_en: "IP Switch · UI"
  description_zh: "打开 ip-switch MCP 的浏览器配置页（云平台凭据 / Cloudflare DNS / 子域名绑定），不替代 MCP 工具"
  description_en: "Launch the ip-switch MCP config UI (cloud credentials, Cloudflare DNS, subdomain bindings) in the browser. Does NOT replace the MCP tools."
  visibility: "public"
---

# ip-switch Skill

## 这是什么

ip-switch 是一个多云公网 IP 轮换的 MCP 服务器。本 skill **不提供新的 MCP 工具**，而是把 MCP 的「可视化配置界面」直接唤起到浏览器：

- 用户对话里提到「添加/编辑/打开 ip-switch 配置」时，AI 应自动触发本 skill
- 用户可以手动在 WorkBuddy 输入 `/ip-switch` 直接调用
- 任意终端可手动执行 `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs`

## ⚠️ 前置条件（必读）

**必须先跑过 `bash install.sh` 或 `install.ps1`**，这条 skill 才会被实际安装到用户级目录。install 之后才能调脚本，否则 `open-ui.mjs` 路径不存在。

如果用户没跑过 install：
- WorkBuddy 端的 skill 列表里看不到「IP Switch · 配置面板」
- `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs` 会报「路径不存在」
- 但 `node <项目目录>/scripts/open-ui.mjs` 仍可运行（脚本会自己从 `~/.ip-switch/install-dir.txt` 找到项目）

如果用户不确定是否跑过 install，让用户重跑一次即可（幂等、可重复执行）。

## 何时调用本 skill

| 用户意图 | 调用方式 |
|---------|---------|
| 「我要添加一个 AWS 配置」 | `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs aws` |
| 「添加 Azure / OCI / Vultr 配置」 | `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs azure`（oci / vultr 同理） |
| 「打开 ip-switch 配置页面」 | `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs` |
| 「我想编辑 ip-switch 配置」 | 同上（打开主配置页即可编辑任意 profile） |
| 用户说「ip-switch 设置」/「ip-switch 凭据」 | 同上 |

> **触发判断**：凡是用户提到 *ip-switch + (配置 / 凭据 / 添加 / 编辑 / 打开 / 启动 UI / 设置)* 的组合，都应直接调用本 skill，**不要**改用 MCP 工具（save_profile 仍需用户先在表单填好凭据）。

## 调用方式（AI Agent 必须遵守的步骤）

### 步骤 1：定位脚本

**先确认 install 已跑过**——见上方「前置条件」。如果未跑，让用户跑 install 脚本。

install 脚本（`install_skill()` / `Install-Skill`）会创建以下两个用户级目录：

| 路径 | 是否一定有 | 说明 |
|------|-----------|------|
| `~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs` | ✅ 一定有 | install.sh/install.ps1 无条件创建（`mkdir -p` 自动建父目录） |
| `~/.codex/skills/ip-switch/scripts/open-ui.mjs` | ⚠️ 仅当 `~/.codex/skills/` 已存在 | install 不会主动创建 `~/.codex/skills/`（避免污染未启用 skill 的 Codex），所以只有用户**之前已经创建过 `~/.codex/skills/`** 的情况下才会有 Codex 镜像 |

按以下顺序查找：

```bash
# 1. WorkBuddy 标准安装位置（一定存在）
ls -la "$HOME/.workbuddy/skills/ip-switch/scripts/open-ui.mjs" 2>/dev/null

# 2. Codex 镜像位置（仅在 ~/.codex/skills/ 已存在时才有）
ls -la "$HOME/.codex/skills/ip-switch/scripts/open-ui.mjs" 2>/dev/null

# 3. 用户级任意位置（兜底模糊查找）
find "$HOME/.workbuddy/skills" "$HOME/.codex/skills" -maxdepth 4 -name "open-ui.mjs" -path "*ip-switch*" 2>/dev/null | head -1
```

**Windows PowerShell**：
```powershell
$paths = @(
  "$env:USERPROFILE\.workbuddy\skills\ip-switch\scripts\open-ui.mjs",
  "$env:USERPROFILE\.codex\skills\ip-switch\scripts\open-ui.mjs"
)
$script = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
```

### 步骤 2：调用（必须先查状态再决定是否启动）

> **重要约定**：**永远用浏览器打开**，不要使用 WorkBuddy 内嵌 widget（`show_widget`）。原因：widget 沙箱的 CSP 会拦截 `fetch`，保存按钮写不进去。

#### 推荐：直接调脚本（WorkBuddy / Codex 通吃）

```bash
# macOS / Linux / Git Bash
node "$HOME/.workbuddy/skills/ip-switch/scripts/open-ui.mjs" [aws|azure|oci|vultr]
```

```powershell
# Windows PowerShell
& "$env:USERPROFILE\.workbuddy\skills\ip-switch\scripts\open-ui.mjs" aws
```

脚本会自动：
1. 读 `~/.ip-switch/install-dir.txt`（install 脚本写入的标记文件）→ 找到 ip-switch 项目安装位置
2. 读 `~/.ip-switch/server-port.txt` + TCP 健康检查 → 看 UI server 是否已在跑
3. 没跑就后台启动 `<ip-switch 项目目录>/ui/server.cjs`（进程 cwd 即该目录），等 `~/.ip-switch/server-port.txt` 端口文件落地（最长 15 秒）
4. 跨平台打开默认浏览器：`cmd /c start`（Win）/ `open`（macOS）/ `xdg-open`（Linux）
5. 把控制台 URL 输出到 stderr，AI 可读到并向用户回显

#### 只想拿 URL、不打开浏览器（CI / 调试）

下列命令假设 `cd` 到 open-ui.mjs 所在目录（即 `~/.workbuddy/skills/ip-switch/scripts/` 用户级，或项目内 `<root>/scripts/`）；推荐写法是用绝对路径。

```bash
node open-ui.mjs --port       # 只 stdout 输出 URL，不调用 start/open/xdg-open
node open-ui.mjs --status     # 输出 JSON 状态（{running, url, installDir, pidFileExists}）
node open-ui.mjs --stop       # 关闭后台 UI server
```

### 步骤 3：向用户回显

脚本启动后，AI 必须告诉用户：

- 打开了哪个平台（aws / azure / oci / vultr / 默认全功能）
- 浏览器实际访问的 URL（让用户在浏览器没自动弹起时手动复制）
- 「保存后回到这里继续对话即可」

## 平台 / Agent 兼容性矩阵

| Agent | skill 自动发现？ | 调起方式 |
|-------|-----------------|---------|
| WorkBuddy（桌面） | ✅ 读 `~/.workbuddy/skills/` | AI 按上述规则调脚本 / 用户输入 `/ip-switch` |
| WorkBuddy（CLI） | ✅ 同上 | 同上 |
| Codex 桌面版 | ❌（无 skill 系统） | 让用户在终端跑 `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs` |
| Codex CLI | ❌ | 同上 |
| 任意能执行命令的 Agent | ❌ | 同上（只要能 shell out 就能用） |

> Codex 没有 skill 机制，但 ip-switch 的 install 脚本在 `~/.codex/skills/` 已存在时会镜像一份过去，所以 Codex 用户只要装过 ip-switch 就能直接跑该脚本。
>
> 如果 Codex 后续支持 `~/.codex/skills/`，install 脚本已预留扩展位（详见 install 脚本注释）。

## 与 MCP 工具的关系

**不要混淆**：

| 用途 | 用什么 |
|------|-------|
| 添加 / 编辑云账号凭据 | **本 skill**（开浏览器表单） |
| 查看已配置列表 | MCP 工具 `list_profiles` |
| 一键轮换 IP + 更新 DNS | MCP 工具 `rotate_ip_and_update_dns` |
| 列出云厂商实例 | MCP 工具 `list_instances` |

凭据保存在 `~/.ip-switch/config.json`，**必须由用户在浏览器表单里填**，绝不在对话里直接索取 accessKeyId / secretAccessKey 等明文（参考用户偏好）。

## install 脚本实际做了什么

以下事实来自 `install.sh` 的 `install_skill()` 与 `install.ps1` 的 `Install-Skill`（行为完全一致）：

### install 之前（项目仓库根目录）

```
<root>/
├── SKILL.md             ← 本文件
├── skill.json
└── scripts/
    ├── _icon.svg
    ├── open-ui.mjs      ← 本 skill 的入口脚本
    ├── open-ui.sh       ← Bash 包装器
    └── open-ui.ps1      ← PowerShell 包装器
```

### install 之后（用户级目录，由 install 脚本创建）

**WorkBuddy 目录**（无条件创建）：

```
~/.workbuddy/skills/ip-switch/                    ← mkdir -p 自动建
├── SKILL.md         ← cp -f 从 <root>/SKILL.md
├── skill.json       ← cp -f 从 <root>/skill.json
└── scripts/         ← mkdir -p 显式创建（保留目录名，不展平）
    ├── _icon.svg
    ├── open-ui.mjs  ← cp -R 从 <root>/scripts/
    ├── open-ui.sh
    └── open-ui.ps1
```

**Codex 镜像目录**（仅当 `~/.codex/skills/` 已存在时才复制）：

```
~/.codex/skills/ip-switch/                    ← 仅在 ~/.codex/skills 已存在时
├── SKILL.md
├── skill.json
└── scripts/
    └── ...
```

**`install-dir.txt` 标记**（让 `open-ui.mjs` 知道 ip-switch 项目本身装在哪里）：

```
~/.ip-switch/
└── install-dir.txt   ← 内容是 ip-switch 项目的绝对路径
                       ← Windows 下用 UTF-8 (no BOM)
                       ← Git Bash 下自动把 /c/Users/foo 转成 C:\Users\foo
```

### install 不做的事

- ❌ 不创建 `~/.codex/skills/`（避免污染未启用 skill 的 Codex 安装）
- ❌ 不动 `~/.codex/config.toml`（Codex MCP 注册由 install 脚本其他函数处理，与本 skill 无关）
- ❌ 不依赖 `dist/`（`open-ui.mjs` 只调 `ui/server.cjs`，不调 MCP 主进程）
- ❌ 不启动 UI server（`open-ui.mjs` 是 lazy 启动，install 完成后不立刻跑）

### install 可重复执行（幂等）

- `mkdir -p` / `New-Item -Force` 是幂等的
- `cp -f` / `Copy-Item -Force` 是覆盖式的，git pull 后再跑即可拿到新版脚本
- `find ... -exec chmod +x` 反复赋执行位无害

## 卸载（install 脚本给出的命令）

按 install 脚本 `print_success` / `Show-Success` 的卸载段：

```bash
# Linux / macOS / Git Bash
rm -rf ~/.workbuddy/skills/ip-switch      # 删除本 skill（含 scripts/ 子目录）
rm -rf ~/.ip-switch                       # 删除 install-dir.txt 等运行时标记
rm -rf <ip-switch 项目目录>               # 删除源码（可选，会同时清 MCP 配置）
```

```powershell
# Windows PowerShell
Remove-Item -Recurse -Force "$env:USERPROFILE\.workbuddy\skills\ip-switch"
Remove-Item -Recurse -Force "$env:USERPROFILE\.ip-switch"
Remove-Item -Recurse -Force "<ip-switch 项目目录>"
```

> 注意：`rm -rf <项目目录>` 会同时删除源码和 install 时配好的 MCP 注册（WorkBuddy 的 `mcp.json`、Codex 的 `marketplaces/local` 等）。如果只想卸 skill 不卸 MCP，**只删 `~/.workbuddy/skills/ip-switch/`** 即可。

## 失败排查

| 现象 | 原因 / 解决 |
|------|------------|
| `node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs` 报「路径不存在」 | install 没跑过。跑 `bash install.sh` 或 `install.ps1` |
| 脚本提示「未找到 ip-switch 安装目录」 | `~/.ip-switch/install-dir.txt` 缺失。重跑 install 脚本 |
| 脚本提示「UI server 启动超时」 | 看 `~/.ip-switch/ui-server.err.log` 找原因，常见是 dist 缺失或端口被占 |
| 浏览器没自动弹 | 看终端 stderr 是否输出 URL，复制手动访问；Linux 缺 xdg-open 时 `apt install xdg-utils` |
| 表单保存按钮无反应 | 确认**在浏览器**里打开（不是 WorkBuddy 内嵌 widget） |
| 端口冲突 | server.cjs 用 `PORT=0` 系统分配，正常不应冲突；若冲突，删 `~/.ip-switch/server-port.txt` 重试 |
| Codex 端跑不了 skill | `~/.codex/skills/` 目录不存在 → install 不会主动创建。先手动建该目录再重跑 install |

## 文件清单

### 项目内布局（仓库根目录 `<root>/`）

```
<root>/
├── SKILL.md                 ← 本文件（skill 元数据）
├── skill.json               ← skill 平台元数据（display_name 等）
├── README.md                ← 项目总览
├── INSTALL.md               ← 安装详细指南
├── package.json             ← npm 入口（依赖、scripts）
├── tsconfig.json            ← TypeScript 配置
├── install.sh               ← macOS / Linux 安装脚本（含 install_skill 函数）
├── install.ps1              ← Windows 安装脚本（含 Install-Skill 函数）
├── src/                     ← MCP 服务器 TypeScript 源码
│   ├── index.ts
│   ├── router.ts
│   ├── tools.ts             ← MCP 工具定义（list_profiles / rotate_ip_and_update_dns 等）
│   ├── config-store.ts
│   ├── types.ts
│   └── adapters/            ← 云厂商适配器
│       ├── base.ts
│       ├── aws.ts
│       ├── azure.ts
│       ├── oci.ts
│       ├── vultr.ts
│       └── cloudflare.ts
├── ui/                      ← UI 服务器 + 浏览器配置页（5 个 HTML + 1 个 Node.js server）
│   ├── server.cjs           ← 本地 HTTP server（默认端口 0 自动分配）
│   ├── config-form.html     ← 默认全功能配置表单
│   ├── aws-config.html      ← AWS 凭据编辑页
│   ├── azure-config.html    ← Azure 凭据编辑页
│   ├── oci-config.html      ← OCI 凭据编辑页
│   └── vultr-config.html    ← Vultr 凭据编辑页
├── dist/                    ← src/ 的 TypeScript 编译产物（npm run build 后生成）
│   └── index.js             ← MCP 启动入口，install.sh 配置到 mcp.json 里就是它
└── scripts/                 ← skill 脚本与图标（install 拷贝到用户级路径的 scripts/ 子目录）
    ├── _icon.svg            ← skill 图标
    ├── open-ui.mjs          ← 主脚本（跨平台零依赖，启动 ui/server.cjs 并打开浏览器）
    ├── open-ui.sh           ← Bash 包装器
    └── open-ui.ps1          ← PowerShell 包装器
```

### 用户级路径（install 之后）

- **目标目录**：`~/.workbuddy/skills/ip-switch/`
- **目标布局**（install 后）：
  ```
  ~/.workbuddy/skills/ip-switch/
  ├── SKILL.md
  ├── skill.json
  └── scripts/                       ← 保留为子目录（不展平）
      ├── _icon.svg
      ├── open-ui.mjs                 ← 调用入口：node ~/.workbuddy/skills/ip-switch/scripts/open-ui.mjs
      ├── open-ui.sh
      └── open-ui.ps1
  ```
- **install 流程**：`install.sh` / `install.ps1` 的 `install_skill` / `Install-Skill` 函数：从项目根拷 `SKILL.md`、`skill.json` 到目标根目录，再把整个 `scripts/` 子目录拷到目标的 `scripts/`。
- **Codex 镜像**：`~/.codex/skills/ip-switch/`（仅当 `~/.codex/skills/` 已存在时才复制）。
- **MCP 运行时数据**：`~/.ip-switch/` 下保存 `config.json`、`install-dir.txt`、`server-port.txt`、`server.pid`、`ui-server.out.log`、`ui-server.err.log`。