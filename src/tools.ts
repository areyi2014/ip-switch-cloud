/**
 * MCP Tool Definitions — 定义所有暴露给 AI Agent 的工具
 *
 * 设计原则：
 *   1. 凭据可通过 credentials 参数即时传入，也可持久化到配置文件
 *   2. 所有工具都是幂等的（重试安全）
 *   3. 统一错误格式，包含 provider 上下文
 */

import { z } from 'zod';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { getAdapter } from './router.js';
import { CloudAdapterError, type ConfigProfile } from './types.js';
import {
  saveProfile,
  deleteProfile,
  listProfiles,
  getProfile,
  getConfigPath,
} from './config-store.js';
import { updateDns, CloudflareError } from './adapters/cloudflare.js';

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

  // ─── 9. save_profile ────────────────────────────────

  server.tool(
    'save_profile',
    'Save a cloud provider profile with credentials, region, instance ID, and a bound subdomain. ' +
    'The subdomain will be updated via Cloudflare DNS when the instance IP changes. ' +
    'Use this to persist configuration so you do not need to pass credentials every time. ' +
    'Optionally save Cloudflare API token and Zone ID per profile so different subdomains ' +
    'in different Cloudflare accounts/zones can be managed independently.',
    {
      name: z.string().describe('Profile name (e.g. "aws-sg", "azure-hk")'),
      provider: providerSchema,
      region: regionSchema,
      instanceId: z.string().describe('Instance identifier'),
      credentials: credentialsSchema,
      subdomain: z.string().describe('Subdomain to bind (e.g. ty.example.com)'),
      proxied: z.boolean().default(false).describe('Enable Cloudflare proxy for this subdomain'),
      cfApiToken: z.string().optional().describe('Profile-specific Cloudflare API token (overrides global)'),
      cfZoneId: z.string().optional().describe('Profile-specific Cloudflare Zone ID (overrides global)'),
    },
    async ({ name, provider, region, instanceId, credentials, subdomain, proxied, cfApiToken, cfZoneId }) => {
      try {
        const profile: ConfigProfile = { name, provider, region, instanceId, credentials, subdomain, proxied };
        if (cfApiToken && cfZoneId) {
          profile.cloudflare = { apiToken: cfApiToken, zoneId: cfZoneId };
        }
        saveProfile(profile);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify({
            success: true,
            message: `Profile "${name}" saved (${provider} ${instanceId} in ${region}, DNS: ${subdomain})`,
            configPath: getConfigPath(),
          }, null, 2) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );

  // ─── 10. list_profiles ───────────────────────────────

  server.tool(
    'list_profiles',
    'List all saved cloud provider profiles with their subdomain bindings. ' +
    'Also shows whether each profile has Cloudflare DNS config attached.',
    {},
    async () => {
      const profiles = listProfiles();
      return {
        content: [{ type: 'text' as const, text: JSON.stringify({
          profileCount: profiles.length,
          profiles: profiles.map(p => ({
            name: p.name,
            provider: p.provider,
            region: p.region,
            instanceId: p.instanceId,
            subdomain: p.subdomain,
            proxied: p.proxied,
            cloudflareConfigured: !!p.cloudflare,
          })),
        }, null, 2) }],
      };
    }
  );

  // ─── 11. delete_profile ──────────────────────────────

  server.tool(
    'delete_profile',
    'Delete a saved cloud provider profile by name.',
    {
      name: z.string().describe('Profile name to delete'),
    },
    async ({ name }) => {
      const deleted = deleteProfile(name);
      return {
        content: [{ type: 'text' as const, text: JSON.stringify({
          success: deleted,
          message: deleted ? `Profile "${name}" deleted` : `Profile "${name}" not found`,
        }, null, 2) }],
      };
    }
  );

  // ─── 12. update_dns ──────────────────────────────────

  server.tool(
    'update_dns',
    'Update a Cloudflare DNS A record to point a subdomain to a new IP. ' +
    'Requires Cloudflare API token and Zone ID to be passed directly.',
    {
      subdomain: z.string().describe('Subdomain to update (e.g. ty.example.com)'),
      ip: z.string().describe('New IP address'),
      proxied: z.boolean().default(false).describe('Enable Cloudflare proxy'),
      cfApiToken: z.string().describe('Cloudflare API token'),
      cfZoneId: z.string().describe('Cloudflare Zone ID'),
    },
    async ({ subdomain, ip, proxied, cfApiToken, cfZoneId }) => {
      try {
        const cf = { apiToken: cfApiToken, zoneId: cfZoneId };
        const result = await updateDns(cf, subdomain, ip, proxied);
        return {
          content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }],
        };
      } catch (err) {
        return formatError(err);
      }
    }
  );

  // ─── 13. rotate_ip_and_update_dns ────────────────────

  server.tool(
    'rotate_ip_and_update_dns',
    'One-click: rotate a saved profile instance IP and update its bound subdomain DNS. ' +
    'This combines rotate_instance_ip + update_dns into a single operation. ' +
    'The profile must be saved first (use save_profile) with Cloudflare credentials attached.',
    {
      profileName: z.string().describe('Saved profile name'),
    },
    async ({ profileName }) => {
      try {
        // Step 1: Load profile
        const profile = getProfile(profileName);
        if (!profile) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({
              success: false,
              error: `Profile "${profileName}" not found. Use list_profiles to see saved profiles.`,
            }) }],
            isError: true,
          };
        }

        // Step 2: Check Cloudflare config (profile-level only)
        const cf = profile.cloudflare;
        if (!cf) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({
              success: false,
              error: 'Profile has no Cloudflare credentials. Re-save the profile with cfApiToken and cfZoneId.',
            }) }],
            isError: true,
          };
        }

        // Step 3: Rotate IP
        const adapter = getAdapter(profile.provider);
        const rotateResult = await adapter.rotateIp(
          profile.instanceId,
          profile.region,
          profile.credentials
        );

        if (!rotateResult.success || !rotateResult.newIp) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({
              success: false,
              error: 'IP rotation succeeded but no new IP was obtained',
              rotateResult,
            }) }],
            isError: true,
          };
        }

        // Step 4: Update DNS
        const dnsResult = await updateDns(
          cf,
          profile.subdomain,
          rotateResult.newIp,
          profile.proxied
        );

        // Step 5: Return combined result
        return {
          content: [{ type: 'text' as const, text: JSON.stringify({
            success: true,
            profile: profileName,
            provider: profile.provider,
            instanceId: profile.instanceId,
            oldIp: rotateResult.oldIp,
            newIp: rotateResult.newIp,
            subdomain: profile.subdomain,
            dnsUpdated: dnsResult.success,
            message: `IP rotated ${rotateResult.oldIp ?? 'N/A'} -> ${rotateResult.newIp}, DNS ${profile.subdomain} updated`,
          }, null, 2) }],
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
  if (err instanceof CloudflareError) {
    return {
      content: [{ type: 'text' as const, text: JSON.stringify({ success: false, error: err.message, statusCode: err.statusCode }) }],
      isError: true,
    };
  }
  const msg = err instanceof Error ? err.message : String(err);
  return {
    content: [{ type: 'text' as const, text: JSON.stringify({ success: false, error: msg }) }],
    isError: true,
  };
}
