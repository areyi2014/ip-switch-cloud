# cloud-ip-rotator-mcp 安装指南

多云公网 IP 轮换 MCP 服务 —— 让 AI Agent 一键轮换 AWS / Azure / OCI / Vultr 云服务器公网 IP，并自动更新 Cloudflare 域名解析。

---

## 目录

- [系统要求](#系统要求)
- [一键安装](#一键安装)
  - [macOS / Ubuntu](#macos--ubuntu)
  - [Windows](#windows)
- [手动安装](#手动安装)
- [MCP 配置](#mcp-配置)
  - [WorkBuddy](#workbuddy)
  - [Codex](#codex)
  - [环境变量说明](#环境变量说明)
- [验证安装](#验证安装)
- [配置云服务器（UI）](#配置云服务器ui)
- [使用方式](#使用方式)
- [更新与卸载](#更新与卸载)
- [常见问题](#常见问题)

---

## 系统要求

| 依赖       | 最低版本 | 说明                              |
|-----------|---------|-----------------------------------|
| Node.js   | >= 18   | 需要原生 `fetch` API（Node 18+）  |
| npm       | >= 9    | 随 Node.js 一起安装               |
| git       | 任意版本  | 用于克隆仓库                      |
| 操作系统   | -       | macOS 14+, Ubuntu 20.04+, Windows 10+ |

---

## 一键安装

### macOS / Ubuntu

在终端中执行：

```bash
# 下载安装脚本
curl -fsSL https://gitee.com/areyi2014/cloud-ip-rotator-mcp/raw/main/install.sh -o install-cloud-ip-rotator.sh

# 运行（需要网络连接）
bash install-cloud-ip-rotator.sh
```

**自定义参数：**

```bash
# 指定安装目录
bash install-cloud-ip-rotator.sh --install-dir /opt/cloud-ip-rotator-mcp

# 使用 GitHub 镜像
bash install-cloud-ip-rotator.sh --repo-url https://gitee.com/user/cloud-ip-rotator-mcp.git

# 指定分支
bash install-cloud-ip-rotator.sh --branch develop

# 仅下载不编译
bash install-cloud-ip-rotator.sh --skip-build
```

脚本会依次完成：
1. 检查 Node.js >= 18
2. 检查 git
3. 克隆仓库到 `~/cloud-ip-rotator-mcp`
4. 安装 npm 依赖（共 6 个运行时包 + 2 个开发包）
5. 编译 TypeScript → `dist/`
6. 生成 MCP 配置文件

### Windows

在 PowerShell 中执行（**右键「以管理员身份运行」PowerShell**）：

```powershell
# 如果遇到执行策略限制，先运行：
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

# 下载安装脚本
Invoke-WebRequest -Uri "https://gitee.com/areyi2014/cloud-ip-rotator-mcp/raw/main/install.ps1" -OutFile "$env:TEMP\install-cloud-ip-rotator.ps1"

# 运行
& "$env:TEMP\install-cloud-ip-rotator.ps1"
```

**自定义参数：**

```powershell
& "$env:TEMP\install-cloud-ip-rotator.ps1" -InstallDir "D:\tools\cloud-ip-rotator-mcp"
& "$env:TEMP\install-cloud-ip-rotator.ps1" -RepoUrl "https://gitee.com/user/cloud-ip-rotator-mcp.git"
```

> **注意**: 如遇 `无法加载文件，因为在此系统上禁止运行脚本` 错误，请先执行 `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`。

---

## 手动安装

如果不使用一键脚本，可以手动执行以下步骤：

### 1. 确保 Node.js >= 18 已安装

```bash
node -v   # 应输出 v18.x.x 或更高
npm -v    # 应输出 9.x.x 或更高
```

如未安装，前往 [nodejs.org](https://nodejs.org/) 下载 LTS 版本（推荐 22.x）。

### 2. 克隆仓库

```bash
git clone --depth 1 https://gitee.com/areyi2014/cloud-ip-rotator-mcp.git
cd cloud-ip-rotator-mcp
```

### 3. 安装依赖

```bash
npm install
```

### 4. 编译

```bash
npm run build
```

> **WorkBuddy 用户注意**: 如果编译时报错或静默退出，说明 `ELECTRON_RUN_AS_NODE` 环境变量干扰了 `tsc`。执行以下命令代替：
> ```bash
> # macOS / Ubuntu
> env -u ELECTRON_RUN_AS_NODE npm run build
>
> # Windows PowerShell
> $env:ELECTRON_RUN_AS_NODE = ""; npm run build
> ```

### 5. 验证

编译成功后，`dist/index.js` 文件应存在：

```bash
# macOS / Ubuntu
ls -la dist/index.js

# Windows
dir dist\index.js
```

---

## MCP 配置

安装完成后，需要配置 MCP 客户端以加载本服务。

### WorkBuddy

**方法一：自动合并（推荐）**

安装脚本已自动生成配置到 `~/.cloud-ip-rotator/mcp-config.json`。

编辑 `~/.workbuddy/mcp.json`（如文件不存在则创建），将 `cloud-ip-rotator` 条目合并进去。

**方法二：手动添加**

编辑 `~/.workbuddy/mcp.json`，添加如下内容：

```json
{
  "mcpServers": {
    "cloud-ip-rotator": {
      "command": "/usr/local/bin/node",
      "args": ["/Users/你的用户名/cloud-ip-rotator-mcp/dist/index.js"]
    }
  }
}
```

> **路径说明**:
> - `command`: Node.js 可执行文件的完整路径（通过 `which node` 获取）
> - `args[0]`: `dist/index.js` 的完整绝对路径
> - Windows 路径中使用双反斜杠 `\\` 转义

**生效**:

1. 保存 `mcp.json`
2. 打开 WorkBuddy 连接器管理页面
3. 在「自定义连接器」区域找到 `cloud-ip-rotator`，点击 **「信任」**
4. 服务即可在对话中使用

### Codex

将上述 MCP 配置合并到 Codex 的 MCP 配置文件中。具体路径依 Codex 版本而定，常见的包括：

- `~/.codex/mcp.json`
- 项目级 `.codex/mcp.json`
- Codex 设置面板中的 MCP 配置区域

配置格式与 WorkBuddy 完全一致。

### 环境变量说明

MCP 配置中可以通过 `env` 字段设置环境变量。本项目在 WorkBuddy 环境下通常需要清除 Electron 干扰：

```json
{
  "command": "node",
  "args": ["/path/to/dist/index.js"],
  "env": {
    "ELECTRON_RUN_AS_NODE": ""
  }
}
```

| 变量                    | 说明                                  |
|------------------------|--------------------------------------|
| `ELECTRON_RUN_AS_NODE` | 设为空字符串 `""`，避免 Electron 环境干扰 |

---

## 验证安装

在 WorkBuddy 或 Codex 对话中，尝试以下命令验证：

```
列出我的云服务器配置
```

如果服务正常加载，会返回一个配置列表（可能为空 `{}`）。

也可以直接运行 `dist/index.js` 验证 MCP 协议是否正常：

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | node dist/index.js
```

预期输出包含 13 个工具定义。

---

## 配置云服务器（UI）

提供了一个本地浏览器配置界面，用于填写云平台凭据。

```bash
# 启动 UI 服务器
node ui/server.cjs
```

然后浏览器打开 `http://127.0.0.1:<端口>`（端口在终端启动时打印），即可在可视化界面中填写和保存配置。

> **约定**: 配置表单**永远用浏览器打开**，不要使用 WorkBuddy 内嵌窗口（沙箱限制）。

---

## 使用方式

通过 AI 对话即可操作，常用指令：

| 对话指令                           | 功能                       |
|-----------------------------------|---------------------------|
| 「添加一个 AWS 配置」               | 打开 UI 添加云服务器配置     |
| 「列出我的云服务器配置」             | 查看已保存的配置            |
| 「轮换所有已配置服务器的 IP」        | 一键轮换所有 IP + 更新 DNS  |
| 「轮换 aws-ty 的 IP 并更新 DNS」   | 轮换指定配置并同步 DNS      |
| 「删除 aws-ty 配置」               | 移除指定配置               |

13 个 MCP 工具完整列表详见 [AGENTS.md](./AGENTS.md)。

---

## 更新与卸载

### 更新

```bash
cd ~/cloud-ip-rotator-mcp
git pull
npm install
npm run build
```

### 卸载

```bash
# 删除项目目录
rm -rf ~/cloud-ip-rotator-mcp            # macOS / Ubuntu
Remove-Item -Recurse -Force ~/cloud-ip-rotator-mcp   # Windows

# 删除配置数据（含保存的凭据）
rm -rf ~/.cloud-ip-rotator                # macOS / Ubuntu
Remove-Item -Recurse -Force ~/.cloud-ip-rotator       # Windows

# 从 WorkBuddy mcp.json 中移除 cloud-ip-rotator 条目
```

---

## 常见问题

### 1. 编译报错或静默退出

**原因**: `ELECTRON_RUN_AS_NODE=1` 环境变量干扰了 `tsc` 编译器。

**解决**:

```bash
# macOS / Ubuntu
env -u ELECTRON_RUN_AS_NODE npm run build

# Windows PowerShell
$env:ELECTRON_RUN_AS_NODE = ""; npm run build
```

### 2. 克隆仓库失败

**原因**: 网络问题或仓库不可访问。

**解决**:
- 确认网络正常，能访问 gitee.com
- 如为私有仓库，先配置 SSH Key: `ssh-keygen -t ed25519 && cat ~/.ssh/id_ed25519.pub`
- 手动克隆: `git clone https://gitee.com/areyi2014/cloud-ip-rotator-mcp.git`

### 3. MCP 配置后工具未出现

**原因**: MCP 进程启动失败或配置路径错误。

**排查**:
1. 确认 `dist/index.js` 存在
2. 确认 `command` 中的 node 路径正确: `which node`（全路径）
3. 手动测试: `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | node dist/index.js`
4. 检查 WorkBuddy 连接器管理页面是否有错误信息

### 4. npm install 失败（权限错误）

**解决**: 避免使用 `sudo`。如提示 EACCES 错误：

```bash
# macOS / Ubuntu: 修复 npm 权限
mkdir -p ~/.npm-global
npm config set prefix '~/.npm-global'
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

### 5. Azure SDK 报错 "networkInterfaces.updateProperties 不存在"

此问题已在最新代码中修复（使用 `beginCreateOrUpdateAndWait` 替代），确保使用最新的 `main` 分支即可。

### 6. Windows PowerShell 脚本无法运行

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

或使用 `powershell -ExecutionPolicy Bypass -File install.ps1` 绕过限制。
