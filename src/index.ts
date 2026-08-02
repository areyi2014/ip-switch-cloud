#!/usr/bin/env node

/**
 * Cloud IP Rotator MCP Server
 *
 * 一个多云公网 IP 轮换的 MCP (Model Context Protocol) 服务进程。
 * 支持 AWS / Azure / Oracle OCI / Vultr 四大云平台。
 *
 * 设计特点：
 *   - 无需 Docker、无需 CLI、无需虚拟化
 *   - 凭据通过参数传入，进程本身不持久化任何凭据
 *   - 统一适配器接口，新增云平台只需实现 CloudAdapter
 *
 * 用法：
 *   1. npm install && npm run build
 *   2. 在 AI Agent 的 MCP 配置中添加：
 *      {
 *        "mcpServers": {
 *          "cloud-ip-rotator": {
 *            "command": "node",
 *            "args": ["/path/to/cloud-ip-rotator-mcp/dist/index.js"]
 *          }
 *        }
 *      }
 *   3. Agent 调用工具时传入 provider + instanceId + region + credentials
 */

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { registerTools } from './tools.js';
import { getSupportedProviders } from './router.js';

const server = new McpServer({
  name: 'cloud-ip-rotator',
  version: '1.0.0',
});

// 注册所有工具
registerTools(server);

// 启动服务
async function main() {
  const providers = getSupportedProviders().join(', ');
  console.error(`[cloud-ip-rotator] Starting MCP server (providers: ${providers})`);

  const transport = new StdioServerTransport();
  await server.connect(transport);

  console.error('[cloud-ip-rotator] MCP server ready');
}

main().catch((err) => {
  console.error('[cloud-ip-rotator] Fatal error:', err);
  process.exit(1);
});
