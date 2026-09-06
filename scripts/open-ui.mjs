#!/usr/bin/env node
/**
 * ip-switch Skill Launcher (跨平台)
 *
 * 职责：
 *   1. 定位 ip-switch 安装目录（读 ~/.ip-switch/install-dir.txt，回退到默认路径）
 *   2. 检查 UI server.cjs 是否已在运行（读 ~/.ip-switch/server-port.txt 并 TCP 健康检查）
 *   3. 未运行则后台启动 node ui/server.cjs，等待端口文件落地（最长 15 秒）
 *   4. 拼装 URL 并跨平台打开默认浏览器
 *
 * 用法：
 *   node open-ui.mjs                  # 打开默认全功能表单 config-form.html
 *   node open-ui.mjs aws              # 打开 AWS 配置页 aws-config.html
 *   node open-ui.mjs azure            # 打开 Azure 配置页
 *   node open-ui.mjs oci              # 打开 OCI 配置页
 *   node open-ui.mjs vultr            # 打开 Vultr 配置页
 *   node open-ui.mjs --port           # 只输出 URL，不打开浏览器（CI/调试用）
 *   node open-ui.mjs --stop           # 关闭后台 UI server（如果有的话）
 *   node open-ui.mjs --status         # 检查 UI server 是否在运行
 *
 * 跨平台浏览器打开：
 *   Windows: cmd /c start "" "<url>"
 *   macOS:   open "<url>"
 *   Linux:   xdg-open "<url>"
 *
 * 设计原则：
 *   - 零依赖：只用 Node.js 内置模块（fs/child_process/http/path/os）
 *   - 幂等：可重复执行，已在跑的 server 直接复用端口
 *   - 失败安全：任何异常都给出可读错误并退出码 1，不抛堆栈
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { spawn } from 'node:child_process';
import process from 'node:process';

// ── 常量 ──────────────────────────────────────────────────────────────────────
const IP_SWITCH_HOME = path.join(os.homedir(), '.ip-switch');
const INSTALL_DIR_MARKER = path.join(IP_SWITCH_HOME, 'install-dir.txt');
const PORT_FILE = path.join(IP_SWITCH_HOME, 'server-port.txt');
const PID_FILE = path.join(IP_SWITCH_HOME, 'server.pid');

const SUPPORTED_PAGES = new Set(['aws', 'azure', 'oci', 'vultr']);
const PAGE_PATHS = {
  '': '/config-form.html',
  aws: '/aws-config.html',
  azure: '/azure-config.html',
  oci: '/oci-config.html',
  vultr: '/vultr-config.html',
};

// ── 日志工具（输出到 stderr，避免污染脚本被管道消费的 stdout） ────────────────
const log = {
  info: (msg) => console.error(`[INFO]  ${msg}`),
  ok: (msg) => console.error(`[ OK ]  ${msg}`),
  warn: (msg) => console.error(`[WARN]  ${msg}`),
  err: (msg) => console.error(`[ERROR] ${msg}`),
};

// ── 解析参数 ──────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const out = { page: '', portOnly: false, stop: false, status: false, help: false };
  for (const arg of argv.slice(2)) {
    if (arg === '--port') out.portOnly = true;
    else if (arg === '--stop') out.stop = true;
    else if (arg === '--status') out.status = true;
    else if (arg === '--help' || arg === '-h') out.help = true;
    else if (SUPPORTED_PAGES.has(arg)) out.page = arg;
    else if (arg.startsWith('--')) out[arg.slice(2)] = true;
    else {
      log.err(`未知参数: ${arg}`);
      printHelp();
      process.exit(1);
    }
  }
  return out;
}

function printHelp() {
  console.log(`用法: node open-ui.mjs [页面] [选项]

页面:
  (无)             打开默认全功能表单（config-form.html）
  aws              打开 AWS 配置页
  azure            打开 Azure 配置页
  oci              打开 OCI 配置页
  vultr            打开 Vultr 配置页

选项:
  --port           只输出 URL 到 stdout，不打开浏览器（CI / 调试）
  --stop           关闭后台 UI server
  --status         检查 UI server 是否在运行，输出 JSON
  -h, --help       显示本帮助`);
}

// ── 定位 ip-switch 安装目录 ───────────────────────────────────────────────────
function findInstallDir() {
  // 优先读 marker（install 脚本写入）
  if (fs.existsSync(INSTALL_DIR_MARKER)) {
    const p = fs.readFileSync(INSTALL_DIR_MARKER, 'utf8').trim();
    if (p && fs.existsSync(path.join(p, 'ui', 'server.cjs'))) {
      return path.resolve(p);
    }
  }
  // 回退：常见位置
  const candidates = [
    path.join(os.homedir(), 'ip-switch'),
    path.join(os.homedir(), 'tools', 'ip-switch'),
    'C:\\ip-switch',
    '/opt/ip-switch',
  ];
  for (const c of candidates) {
    if (fs.existsSync(path.join(c, 'ui', 'server.cjs'))) return c;
  }
  return null;
}

// ── TCP 健康检查（端口是否真的在监听） ───────────────────────────────────────
function checkPort(port) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port, path: '/', timeout: 1500 }, (res) => {
      // 任何 HTTP 响应都算 OK（包括 404）；连接成功即可
      res.resume();
      resolve(true);
    });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
  });
}

// ── 读端口文件并验证 ──────────────────────────────────────────────────────────
async function readActivePort() {
  if (!fs.existsSync(PORT_FILE)) return null;
  const raw = fs.readFileSync(PORT_FILE, 'utf8').trim();
  const port = parseInt(raw, 10);
  if (!port || port < 1 || port > 65535) return null;
  return (await checkPort(port)) ? port : null;
}

// ── 后台启动 UI server ────────────────────────────────────────────────────────
async function startServer(installDir) {
  const serverJs = path.join(installDir, 'ui', 'server.cjs');
  if (!fs.existsSync(serverJs)) {
    log.err(`未找到 UI server: ${serverJs}`);
    log.err(`请确认 ip-switch 已正确安装，或重新运行 install 脚本`);
    return null;
  }

  fs.mkdirSync(IP_SWITCH_HOME, { recursive: true });

  // 写日志到固定位置，便于排查
  const outLog = path.join(IP_SWITCH_HOME, 'ui-server.out.log');
  const errLog = path.join(IP_SWITCH_HOME, 'ui-server.err.log');
  const out = fs.openSync(outLog, 'a');
  const err = fs.openSync(errLog, 'a');

  let child;
  if (process.platform === 'win32') {
    // Windows：用 cmd /c start /B 真正脱离父进程（detached+unref 在 Windows
    //   上仍可能因 job 对象被父终端回收）。start /B 不开新窗口，但仍完全后台。
    child = spawn('cmd.exe', ['/c', 'start', '/B', process.execPath, serverJs], {
      cwd: installDir,
      detached: true,
      stdio: ['ignore', out, err],
      windowsHide: true,
    });
  } else {
    // macOS / Linux：detached + unref 即可（POSIX setsid 等价）
    child = spawn(process.execPath, [serverJs], {
      cwd: installDir,
      detached: true,
      stdio: ['ignore', out, err],
    });
  }
  child.unref();

  // 写 PID（供 --stop 使用；Windows 下 cmd.exe 立即退出，PID 不准，仅做记录用）
  try { fs.writeFileSync(PID_FILE, String(child.pid)); } catch { /* ignore */ }

  log.info(`已后台启动 UI server，等待端口文件...`);

  // 等待端口文件落地（最长 15 秒）
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const port = await readActivePort();
    if (port) {
      log.ok(`UI server 已就绪: http://127.0.0.1:${port}`);
      return port;
    }
    await new Promise((r) => setTimeout(r, 300));
  }

  log.err(`UI server 启动超时（15s），请查看日志:`);
  log.err(`  ${errLog}`);
  return null;
}

// ── 关闭后台 UI server ────────────────────────────────────────────────────────
async function stopServer() {
  if (!fs.existsSync(PID_FILE)) {
    log.info('未找到 PID 文件，UI server 可能未在运行');
    return true;
  }
  const pid = parseInt(fs.readFileSync(PID_FILE, 'utf8').trim(), 10);
  if (!pid) {
    log.info('PID 文件无效');
    try { fs.unlinkSync(PID_FILE); } catch { /* ignore */ }
    return true;
  }
  try {
    process.kill(pid, 'SIGTERM');
    log.ok(`已发送 SIGTERM 给 pid=${pid}`);
  } catch (e) {
    log.warn(`结束进程 ${pid} 失败: ${e.message}（可能已退出）`);
  }
  try { fs.unlinkSync(PID_FILE); } catch { /* ignore */ }
  try { fs.unlinkSync(PORT_FILE); } catch { /* ignore */ }
  return true;
}

// ── 跨平台打开浏览器 ──────────────────────────────────────────────────────────
function openBrowser(url) {
  let cmd, args;
  switch (process.platform) {
    case 'win32':
      // Windows: cmd /c start "" "<url>"  （start 后必须跟空标题）
      cmd = 'cmd';
      args = ['/c', 'start', '""', url];
      break;
    case 'darwin':
      cmd = 'open';
      args = [url];
      break;
    default:
      // Linux/其他 Unix
      cmd = 'xdg-open';
      args = [url];
      break;
  }
  try {
    const child = spawn(cmd, args, { detached: true, stdio: 'ignore' });
    child.on('error', (e) => {
      log.warn(`无法打开浏览器: ${e.message}`);
      log.info(`请手动访问: ${url}`);
    });
    child.unref();
    return true;
  } catch (e) {
    log.warn(`无法打开浏览器: ${e.message}`);
    log.info(`请手动访问: ${url}`);
    return false;
  }
}

// ── 主流程 ────────────────────────────────────────────────────────────────────
async function main() {
  const args = parseArgs(process.argv);

  if (args.help) { printHelp(); return; }

  if (args.status) {
    const port = await readActivePort();
    const running = !!port;
    console.log(JSON.stringify({
      running,
      url: running ? `http://127.0.0.1:${port}` : null,
      installDir: findInstallDir(),
      pidFileExists: fs.existsSync(PID_FILE),
    }, null, 2));
    return;
  }

  if (args.stop) {
    await stopServer();
    return;
  }

  // 1. 定位安装目录
  const installDir = findInstallDir();
  if (!installDir) {
    log.err('未找到 ip-switch 安装目录');
    log.err(`已尝试:`);
    log.err(`  - 标记文件: ${INSTALL_DIR_MARKER}`);
    log.err(`  - 默认路径: ~/ip-switch`);
    log.err(`请确认 ip-switch 已安装，或重新运行 install.sh / install.ps1`);
    process.exit(1);
  }
  log.info(`ip-switch 安装目录: ${installDir}`);

  // 2. 检查端口（已在跑就直接复用）
  let port = await readActivePort();

  // 3. 未在跑则启动
  if (!port) {
    port = await startServer(installDir);
    if (!port) process.exit(1);
  } else {
    log.ok(`复用已在运行的 UI server: http://127.0.0.1:${port}`);
  }

  // 4. 拼装 URL
  const path = PAGE_PATHS[args.page] || PAGE_PATHS[''];
  const url = `http://127.0.0.1:${port}${path}`;

  if (args.portOnly) {
    // 只输出 URL 到 stdout（供其他脚本/AI 调用）
    process.stdout.write(url + '\n');
    return;
  }

  log.ok(`打开配置页面: ${url}`);
  openBrowser(url);
}

main().catch((err) => {
  log.err(`意外错误: ${err.message}`);
  process.exit(1);
});