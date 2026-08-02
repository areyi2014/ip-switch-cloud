/**
 * MCP Tool Definitions — 定义所有暴露给 AI Agent 的工具
 *
 * 设计原则：
 *   1. 凭据通过 credentials 参数传入，MCP 进程不持久化
 *   2. 所有工具都是幂等的（重试安全）
 *   3. 统一错误格式，包含 provider 上下文
 */

import { z } from 'zod';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { getAdapter } from './router.js';
import { CloudAdapterError } from './types.js';

/** 公共 schema 片段 */
const providerSchema = z.enum(['aws', 'azure', 'oci', 'vultr'])
  .describe('Cloud provider');

const regionSchema = z.string()
  .describe('Cloud region (e.g. us-east-1, eastus, us-ord-1, ewr)');

const credentialsSchema = z.record(z.string())
  .describe('Provider-specific credentials. Keys vary by provider:\n' +
    '- AWS: accessKeyId, secretAccessKey, [sessionToken]\n' +
    '- Azure: subscriptionId, clientId, clientSecret, tenantId, [resourceGroupName]\n' +
    '- OCI: tenancy, user, fingerprint, privateKey\n' +
    '- Vultr: apiKey');

/** 注册所有 MCP 工具 */
export function registerTools(server: McpServer): void {

  // ─── 1. rotate_instance_ip (主工具) ──────────────────

  server.tool(
    'rotate_instance_ip',
    'One-click public IP rotation for a cloud instance. ' +
    'AWS: stop/start to get new dynamic IP. ' +
    'Azure: swap public IP on NIC. ' +
    'OCI: delete & recreate ephemeral public IP. ' +
    'Vultr: create & attach new reserved IP.',
    {
      provider: providerSchema,
      instanceId: z.string().describe('Instance identifier (AWS: i-xxx, Azure: rg/vmName, OCI: ocid1.instance..., Vultr: instance UUID)'),
      region: regionSchema,
      credentials: credentialsSchema,
    },
    async ({ provider, instanceId, region, credentials }) => {
      try {
        const adapter = getAdapter(provider);
        const result = await adapter.rotateIp(instanceId, region, credentials);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );

  // ─── 2. get_instance_info ─────────────────────────────

  server.tool(
    'get_instance_info',
    'Get detailed information about a cloud instance, including current public IP, private IP, and state.',
    {
      provider: providerSchema,
      instanceId: z.string().describe('Instance identifier'),
      region: regionSchema,
      credentials: credentialsSchema,
    },
    async ({ provider, instanceId, region, credentials }) => {
      try {
        const adapter = getAdapter(provider);
        const info = await adapter.getInstanceInfo(instanceId, region, credentials);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify(info, null, 2) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );

  // ─── 3. list_instances ────────────────────────────────

  server.tool(
    'list_instances',
    'List all cloud instances in the given region. Returns instance IDs, states, and public IPs.',
    {
      provider: providerSchema,
      region: regionSchema,
      credentials: credentialsSchema,
    },
    async ({ provider, region, credentials }) => {
      try {
        const adapter = getAdapter(provider);
        const instances = await adapter.listInstances(region, credentials);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify({ count: instances.length, instances }, null, 2) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );

  // ─── 4. allocate_ip ───────────────────────────────────

  server.tool(
    'allocate_ip',
    'Allocate a new public IP (AWS Elastic IP, Azure Public IP, OCI Reserved IP, Vultr Reserved IP).',
    {
      provider: providerSchema,
      region: regionSchema,
      credentials: credentialsSchema,
    },
    async ({ provider, region, credentials }) => {
      try {
        const adapter = getAdapter(provider);
        const ip = await adapter.allocateIp(region, credentials);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify(ip, null, 2) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );

  // ─── 5. associate_ip ─────────────────────────────────

  server.tool(
    'associate_ip',
    'Associate (bind) a public IP to a cloud instance.',
    {
      provider: providerSchema,
      instanceId: z.string().describe('Instance identifier'),
      allocationId: z.string().describe('IP allocation ID (from allocate_ip)'),
      region: regionSchema,
      credentials: credentialsSchema,
    },
    async ({ provider, instanceId, allocationId, region, credentials }) => {
      try {
        const adapter = getAdapter(provider);
        await adapter.associateIp(instanceId, allocationId, region, credentials);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify({ success: true, message: `IP ${allocationId} associated to ${instanceId}` }) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );

  // ─── 6. release_ip ────────────────────────────────────

  server.tool(
    'release_ip',
    'Release (delete/deallocate) a public IP. The IP will be returned to the cloud provider pool.',
    {
      provider: providerSchema,
      allocationId: z.string().describe('IP allocation ID to release'),
      region: regionSchema,
      credentials: credentialsSchema,
    },
    async ({ provider, allocationId, region, credentials }) => {
      try {
        const adapter = getAdapter(provider);
        await adapter.releaseIp(allocationId, region, credentials);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify({ success: true, message: `IP ${allocationId} released` }) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );

  // ─── 7. list_ips ──────────────────────────────────────

  server.tool(
    'list_ips',
    'List all allocated/reserved public IPs in the given region.',
    {
      provider: providerSchema,
      region: regionSchema,
      credentials: credentialsSchema,
    },
    async ({ provider, region, credentials }) => {
      try {
        const adapter = getAdapter(provider);
        const ips = await adapter.listIps(region, credentials);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify({ count: ips.length, ips }, null, 2) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );

  // ─── 8. get_instance_public_ip ────────────────────────

  server.tool(
    'get_instance_public_ip',
    'Get the current public IP address of a cloud instance. Returns null if no public IP is assigned.',
    {
      provider: providerSchema,
      instanceId: z.string().describe('Instance identifier'),
      region: regionSchema,
      credentials: credentialsSchema,
    },
    async ({ provider, instanceId, region, credentials }) => {
      try {
        const adapter = getAdapter(provider);
        const ip = await adapter.getInstancePublicIp(instanceId, region, credentials);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify({ publicIp: ip }) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );
}

/** 统一错误格式化 */
function formatError(err: unknown) {
  if (err instanceof CloudAdapterError) {
    return {
      content: [{ type: 'text' as const, text: JSON.stringify({ success: false, error: err.message, provider: err.provider }) }],
      isError: true,
    };
  }
  const msg = err instanceof Error ? err.message : String(err);
  return {
    content: [{ type: 'text' as const, text: JSON.stringify({ success: false, error: msg }) }],
    isError: true,
  };
}
