/**
 * Vultr Adapter — 通过 Vultr REST API v2 实现公网 IP 轮换
 *
 * 轮换方式：
 *   1. 创建新的 Reserved IP
 *   2. 绑定到实例
 *   3. 获取新 IP
 *   4. 删除旧的 Reserved IP（如果有）
 *
 * 凭据通过参数传入，不持久化。
 */

import type { CloudAdapter } from './base.js';
import type {
  CloudProvider,
  Credentials,
  RotateIpResult,
  InstanceInfo,
  AllocatedIp,
} from '../types.js';
import { CloudAdapterError } from '../types.js';

export class VultrAdapter implements CloudAdapter {
  readonly provider: CloudProvider = 'vultr';

  private readonly baseUrl = 'https://api.vultr.com/v2';

  /** 从凭据 map 中提取 Vultr API Key */
  private parseCreds(credentials: Credentials): string {
    const apiKey = credentials.apiKey || credentials.VULTR_API_KEY;
    if (!apiKey) {
      throw new CloudAdapterError('vultr', 'Missing Vultr API key: apiKey is required');
    }
    return apiKey;
  }

  /** 发送 Vultr API 请求 */
  private async vultrRequest(
    method: string,
    path: string,
    credentials: Credentials,
    body?: unknown
  ): Promise<Response> {
    const apiKey = this.parseCreds(credentials);
    const url = `${this.baseUrl}${path}`;

    const headers: Record<string, string> = {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    };

    const response = await fetch(url, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      const text = await response.text();
      throw new CloudAdapterError('vultr', `Vultr API ${method} ${path} failed: ${response.status} ${text}`);
    }

    return response;
  }

  async rotateIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<RotateIpResult> {
    try {
      // Step 1: 获取旧 IP 和旧 Reserved IP（如果有）
      const oldIp = await this.getInstancePublicIp(instanceId, region, credentials);
      const oldReservedIps = await this.getInstanceReservedIps(instanceId, region, credentials);

      // Step 2: 创建新的 Reserved IP
      const createResp = await this.vultrRequest('POST', '/reserved-ips', credentials, {
        region,
        label: `rotator-${Date.now()}`,
      });
      const createData = await createResp.json();
      const newReservedIpId = createData.reserved_ip?.id;
      if (!newReservedIpId) {
        throw new CloudAdapterError('vultr', 'Failed to create reserved IP: missing id');
      }

      // Step 3: 绑定到实例
      await this.vultrRequest('POST', `/reserved-ips/${newReservedIpId}/attach`, credentials, {
        instance_id: instanceId,
      });

      // Step 4: 获取新 IP
      await sleep(5_000);
      const ipResp = await this.vultrRequest('GET', `/reserved-ips/${newReservedIpId}`, credentials);
      const ipData = await ipResp.json();
      const newIp = ipData.reserved_ip?.subnet;

      // Step 5: 删除旧的 Reserved IP
      for (const oldIpId of oldReservedIps) {
        await this.vultrRequest('DELETE', `/reserved-ips/${oldIpId}`, credentials).catch(() => {});
      }

      return {
        success: true,
        oldIp: oldIp ?? undefined,
        newIp: newIp ?? undefined,
        message: `IP rotated: ${oldIp ?? 'N/A'} → ${newIp ?? 'N/A'}`,
        details: { reservedIpId: newReservedIpId },
      };
    } catch (err) {
      if (err instanceof CloudAdapterError) throw err;
      throw new CloudAdapterError('vultr', `Failed to rotate IP for instance ${instanceId}: ${errMsg(err)}`, err);
    }
  }

  async getInstancePublicIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<string | null> {
    const response = await this.vultrRequest('GET', `/instances/${instanceId}`, credentials);
    const data = await response.json();
    return data.instance?.main_ip || null;
  }

  async getInstanceInfo(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<InstanceInfo> {
    const response = await this.vultrRequest('GET', `/instances/${instanceId}`, credentials);
    const data = await response.json();
    const inst = data.instance;
    return {
      instanceId,
      provider: 'vultr',
      region: inst?.region ?? region,
      state: inst?.status ?? inst?.power_status ?? 'unknown',
      publicIp: inst?.main_ip,
      privateIp: inst?.internal_ip,
      name: inst?.label,
    };
  }

  async listInstances(region: string, credentials: Credentials): Promise<InstanceInfo[]> {
    const response = await this.vultrRequest('GET', '/instances', credentials);
    const data = await response.json();
    const instances: InstanceInfo[] = [];
    for (const inst of data.instances ?? []) {
      if (inst.region === region || !region) {
        instances.push({
          instanceId: inst.id,
          provider: 'vultr',
          region: inst.region,
          state: inst.status ?? 'unknown',
          publicIp: inst.main_ip,
          privateIp: inst.internal_ip,
          name: inst.label,
        });
      }
    }
    return instances;
  }

  async allocateIp(region: string, credentials: Credentials): Promise<AllocatedIp> {
    const response = await this.vultrRequest('POST', '/reserved-ips', credentials, {
      region,
      label: `rotator-${Date.now()}`,
    });
    const data = await response.json();
    return {
      allocationId: data.reserved_ip?.id ?? '',
      publicIp: data.reserved_ip?.subnet ?? '',
      provider: 'vultr',
      region,
    };
  }

  async associateIp(
    instanceId: string,
    allocationId: string,
    region: string,
    credentials: Credentials
  ): Promise<void> {
    await this.vultrRequest('POST', `/reserved-ips/${allocationId}/attach`, credentials, {
      instance_id: instanceId,
    });
  }

  async releaseIp(allocationId: string, region: string, credentials: Credentials): Promise<void> {
    await this.vultrRequest('DELETE', `/reserved-ips/${allocationId}`, credentials);
  }

  async listIps(region: string, credentials: Credentials): Promise<AllocatedIp[]> {
    const response = await this.vultrRequest('GET', '/reserved-ips', credentials);
    const data = await response.json();
    const ips: AllocatedIp[] = [];
    for (const ip of data.reserved_ips ?? []) {
      if (ip.region === region || !region) {
        ips.push({
          allocationId: ip.id,
          publicIp: ip.subnet ?? '',
          provider: 'vultr',
          region: ip.region,
        });
      }
    }
    return ips;
  }

  // ─── Private helpers ─────────────────────────────────

  /** 获取实例关联的 Reserved IP ID 列表 */
  private async getInstanceReservedIps(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<string[]> {
    try {
      const response = await this.vultrRequest('GET', '/reserved-ips', credentials);
      const data = await response.json();
      const ips: string[] = [];
      for (const ip of data.reserved_ips ?? []) {
        // 检查是否绑定到当前实例
        if (ip.instance_id === instanceId) {
          ips.push(ip.id);
        }
      }
      return ips;
    } catch {
      return [];
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errMsg(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}
