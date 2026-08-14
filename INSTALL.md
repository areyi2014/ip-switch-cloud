# cloud-ip-rotator-mcp 安装指南

对多个云公网IP轻松轮换的 AI Agent插件 —— 一键轮换 AWS / Azure / Oracle / Vultr 云服务器公网 IP，并自动更新域名解析。

---

## 目录

- [系统要求](#系统要求)
- [一键安装](#一键安装)
  - [Windows](#windows)
  - [macOS / Ubuntu](#macos--ubuntu)
  - [脚本自动完成的内容](#脚本自动完成的内容)
  - [自定义参数](#自定义参数)
- [手动安装](#手动安装)
- [MCP 配置](#mcp-配置)
  - [WorkBuddy](#workbuddy)
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
| git       | 可选     | 用于克隆仓库；缺失时脚本会自动安装 |
| os        | -       | Windows 10+, macOS 14+, Ubuntu 20.04+ |
| software  | -       | Workbuddy 1.1.0+|

---

## 一键安装

### Windows

在 PowerShell 中执行（如遇执行策略限制，先运行 `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`）：

```powershell
# 下载安装脚本
Invoke-WebRequest -Uri "https://gitee.com/areyi2014/cloud-ip-rotator-mcp/raw/main/install.ps1" -OutFile "$env:TEMP\install-cloud-ip-rotator.ps1"

# 运行（必须在 PowerShell 中执行；cmd 中不支持 & 语法）
& "$env:TEMP\install-cloud-ip-rotator.ps1"
```

> **注意**:
> - 请勿使用 `irm ... | iex` 简写 —— `irm`/`iex` 是 PowerShell 别名，在 cmd 等环境会报「找不到 irm」，且管道直接执行多行脚本易出错。
> - `& "$env:TEMP\..."` 是 PowerShell 语法，必须在 PowerShell 窗口执行，不能在 cmd 中运行。
> - 如在 cmd 或其他环境，可用以下命令（不依赖 `&`，也自动绕过执行策略限制）：
> ```
> powershell -ExecutionPolicy Bypass -File "%TEMP%\install-cloud-ip-rotator.ps1"
> ```

### macOS / Ubuntu

在终端中执行：

```bash
# 一条命令
bash <(curl -fsSL https://gitee.com/areyi2014/cloud-ip-rotator-mcp/raw/main/install.sh)
```

或分步执行：

```bash
# 下载安装脚本
curl -fsSL https://gitee.com/areyi2014/cloud-ip-rotator-mcp/raw/main/install.sh -o install-cloud-ip-rotator.sh

# 运行
bash install-cloud-ip-rotator.sh
```

### 脚本自动完成的内容

1. **检查 Node.js** —— 版本必须 >= 18，否则给出提示并退出
2. **检查 git** —— 未安装时自动处理：
   - Windows：按 CPU 架构（x64 / arm64）从国内镜像（NPMMirror / 清华 TUNA，GitHub 兜底）下载官方安装包，静默安装到用户目录 `%LOCALAPPDATA%\Git`，并自动加入 PATH，全程不弹窗
   - macOS / Ubuntu：通过包管理器（apt / brew / xcode-select）自动安装
3. **检测 MCP 客户端平台** —— 自动识别 `~/.workbuddy`
4. **克隆仓库** —— 克隆前会显示仓库/分支/目录并让您确认（回车或输入新路径）；先 ping 预热 DNS 缓存，最多自动重试 3 次
5. **安装依赖** —— `npm install`
6. **编译** —— TypeScript 编译到 `dist/`（自动清除 `ELECTRON_RUN_AS_NODE` 环境变量干扰）
7. **写入 MCP 配置** —— 直接用 node 序列化为标准 JSON，合并写入 `~/.workbuddy/mcp.json`（保留文件中已有的其他 server，不覆盖）

### 自定义参数

Windows PowerShell：

```powershell
& "$env:TEMP\install-cloud-ip-rotator.ps1" -InstallDir "D:\tools\cloud-ip-rotator-mcp"
& "$env:TEMP\install-cloud-ip-rotator.ps1" -RepoUrl "https://gitee.com/user/cloud-ip-rotator-mcp.git"
& "$env:TEMP\install-cloud-ip-rotator.ps1" -Branch develop
& "$env:TEMP\install-cloud-ip-rotator.ps1" -SkipBuild
& "$env:TEMP\install-cloud-ip-rotator.ps1" -Help
```

macOS / Ubuntu：

```bash
bash install-cloud-ip-rotator.sh --install-dir /opt/cloud-ip-rotator-mcp
bash install-cloud-ip-rotator.sh --repo-url https://gitee.com/user/cloud-ip-rotator-mcp.git
bash install-cloud-ip-rotator.sh --branch develop
bash install-cloud-ip-rotator.sh --skip-build
```

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

一键安装完成后，脚本已自动将 `cloud-ip-rotator` 条目合并写入以下文件（node 序列化，标准 JSON，保留其他已有 server）：

- `~/.workbuddy/mcp.json`

### WorkBuddy

1. 打开 WorkBuddy **连接器管理页面**
2. 在「自定义连接器」区域找到 `cloud-ip-rotator`
3. 点击 **「信任」**，即可在对话中使用

如未自动写入，可手动编辑 `~/.workbuddy/mcp.json`（如文件不存在则创建）：

```json
{
  "mcpServers": {
    "cloud-ip-rotator": {
      "command": "C:\\Program Files\\nodejs\\node.exe",
      "args": ["C:\\Users\\你的用户名\\cloud-ip-rotator-mcp\\dist\\index.js"]
    }
  }
}
```

> **路径说明**:
> - `command`: Node.js 可执行文件的完整路径（Windows 用 `Get-Command node`，macOS/Linux 用 `which node` 获取）
> - `args[0]`: `dist/index.js` 的完整绝对路径
> - Windows 路径中反斜杠必须写为 `\\`（JSON 转义）

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

在 WorkBuddy 对话中，尝试以下命令验证：

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
# 启动 UI 服务器（端口由系统自动分配，避免冲突）
node ui/server.cjs
```

启动后终端会打印实际地址 `http://127.0.0.1:<端口>`，用浏览器打开即可在可视化界面中填写和保存配置。

> **约定**: 配置表单**永远用浏览器打开**，不要使用 WorkBuddy 内嵌窗口（沙箱限制会拦截保存请求）。

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

重新运行安装脚本即可（检测到已克隆仓库时自动 `git pull` + 安装依赖 + 编译 + 更新 MCP 配置），或手动：

```bash
cd ~/cloud-ip-rotator-mcp
git pull
npm install
npm run build
```

### 卸载

```bash
# 删除项目目录
rm -rf ~/cloud-ip-rotator-mcp                 # macOS / Ubuntu
Remove-Item -Recurse -Force ~/cloud-ip-rotator-mcp   # Windows

# 删除配置数据（含保存的凭据）
rm -rf ~/.cloud-ip-rotator                     # macOS / Ubuntu
Remove-Item -Recurse -Force ~/.cloud-ip-rotator       # Windows

# 从 ~/.workbuddy/mcp.json 中移除 cloud-ip-rotator 条目
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
- 脚本已内置 DNS 预热（先 ping 仓库域名）与最多 3 次自动重试
- 如为私有仓库，先配置 SSH Key: `ssh-keygen -t ed25519 && cat ~/.ssh/id_ed25519.pub`
- 手动克隆: `git clone https://gitee.com/areyi2014/cloud-ip-rotator-mcp.git`

### 3. MCP 配置后工具未出现

**原因**: MCP 进程启动失败、配置路径错误或 mcp.json 格式不被识别。

**排查**:
1. 确认 `dist/index.js` 存在
2. 确认 `command` 中的 node 路径正确: `Get-Command node` / `which node`（需完整路径）
3. 确认 mcp.json 是标准 JSON（一键脚本使用 node 序列化输出，不会出现缩进或反斜杠转义问题）
4. 手动测试: `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | node dist/index.js`
5. 检查 WorkBuddy 连接器管理页面是否有错误信息

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

### 7. git 自动安装失败

**原因**: 国内镜像或 GitHub 均不可达。

**解决**: 手动前往 [git-scm.com/download](https://git-scm.com/download/win) 下载安装，装好后重新运行安装脚本（脚本会检测到已有 git 并跳过安装）。
