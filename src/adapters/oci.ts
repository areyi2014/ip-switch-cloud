/**
 * Oracle OCI Adapter — 通过 OCI REST API 实现公网 IP 轮换
 *
 * 轮换方式：
 *   1. 查找实例的 VNIC
 *   2. 获取 Private IP ID
 *   3. 尝试创建 ephemeral 公网 IP
 *   4. 如果冲突（已有公网 IP），从错误中提取已有 IP OCID 并删除
 *   5. 重试创建新 ephemeral 公网 IP
 *
 * OCI 使用 API Key 认证，需要对请求进行 RSA-SHA256 签名。
 */

import crypto from 'node:crypto';
import type { CloudAdapter } from './base.js';
import type {
  CloudProvider,
  Credentials,
  RotateIpResult,
  InstanceInfo,
  AllocatedIp,
} from '../types.js';
import { CloudAdapterError } from '../types.js';

export class OciAdapter implements CloudAdapter {
  readonly provider: CloudProvider = 'oci';

  /** 从凭据 map 中提取 OCI 认证参数 */
  private parseCreds(credentials: Credentials) {
    const tenancy = credentials.tenancy || credentials.OCI_TENANCY;
    const user = credentials.user || credentials.OCI_USER;
    const fingerprint = credentials.fingerprint || credentials.OCI_FINGERPRINT;
    const privateKey = credentials.privateKey || credentials.OCI_KEY_CONTENT || credentials.OCI_KEY_FILE;

    if (!tenancy || !user || !fingerprint || !privateKey) {
      throw new CloudAdapterError(
        'oci',
        'Missing OCI credentials: tenancy, user, fingerprint, and privateKey are required'
      );
    }
    return { tenancy, user, fingerprint, privateKey };
  }

  /** OCI API 版本 */
  private readonly apiVersion = '20160918';

  async rotateIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<RotateIpResult> {
    try {
      // Step 1: 获取旧 IP
      const oldIp = await this.getInstancePublicIp(instanceId, region, credentials);

      // Step 2: 查找实例的 VNIC
      const vnic = await this.getInstanceVnic(instanceId, region, credentials);
      if (!vnic) {
        throw new CloudAdapterError('oci', `No VNIC found for instance ${instanceId}`);
      }

      // Step 3: 获取 Private IP ID
      const privateIpId = await this.getPrivateIpId(vnic.id, region, credentials);
      if (!privateIpId) {
        throw new CloudAdapterError('oci', `No private IP found for VNIC ${vnic.id}`);
      }

      // Step 4: 获取 Compartment ID
      const instance = await this.getInstance(instanceId, region, credentials);
      const compartmentId = instance.compartmentId;

      // Step 5: 尝试创建 ephemeral 公网 IP
      let newPublicIpId: string;
      const createResult = await this.createEphemeralPublicIp(privateIpId, compartmentId, region, credentials);

      if (createResult.success) {
        newPublicIpId = createResult.publicIpId!;
      } else {
        // 冲突：已有公网 IP，从错误中提取 ID 并删除
        if (createResult.existingIpId) {
          await this.deletePublicIp(createResult.existingIpId, region, credentials);
          await sleep(10_000); // 等待 10s

          // 重试创建
          const retryResult = await this.createEphemeralPublicIp(privateIpId, compartmentId, region, credentials);
          if (!retryResult.success) {
            throw new CloudAdapterError('oci', `Failed to create ephemeral public IP after deleting old one: ${retryResult.error}`);
          }
          newPublicIpId = retryResult.publicIpId!;
        } else {
          throw new CloudAdapterError('oci', `Failed to create ephemeral public IP: ${createResult.error}`);
        }
      }

      // Step 6: 通过 VNIC 获取新公网 IP
      await sleep(5_000); // 等待 IP 分配
      const newIp = await this.getVnicPublicIp(vnic.id, region, credentials);

      return {
        success: true,
        oldIp: oldIp ?? undefined,
        newIp: newIp ?? undefined,
        message: `IP rotated: ${oldIp ?? 'N/A'} → ${newIp ?? 'N/A'}`,
        details: { publicIpOcid: newPublicIpId },
      };
    } catch (err) {
      if (err instanceof CloudAdapterError) throw err;
      throw new CloudAdapterError('oci', `Failed to rotate IP for instance ${instanceId}: ${errMsg(err)}`, err);
    }
  }

  async getInstancePublicIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<string | null> {
    const vnic = await this.getInstanceVnic(instanceId, region, credentials);
    if (!vnic) return null;
    return this.getVnicPublicIp(vnic.id, region, credentials);
  }

  async getInstanceInfo(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<InstanceInfo> {
    const instance = await this.getInstance(instanceId, region, credentials);
    const publicIp = await this.getInstancePublicIp(instanceId, region, credentials);

    return {
      instanceId,
      provider: 'oci',
      region,
      state: instance.lifecycleState ?? 'unknown',
      publicIp: publicIp ?? undefined,
      name: instance.displayName,
    };
  }

  async listInstances(region: string, credentials: Credentials): Promise<InstanceInfo[]> {
    const response = await this.ociRequest('GET', `/instances`, region, credentials, {
      compartmentId: this.parseCreds(credentials).tenancy,
    });
    const data = await response.json();
    const instances: InstanceInfo[] = [];
    for (const inst of data.data ?? []) {
      instances.push({
        instanceId: inst.id,
        provider: 'oci',
        region,
        state: inst['lifecycle-state'] ?? 'unknown',
        name: inst['display-name'],
      });
    }
    return instances;
  }

  async allocateIp(region: string, credentials: Credentials): Promise<AllocatedIp> {
    // OCI 的 reserved public IP 需要 compartmentId
    const compartmentId = credentials.compartmentId || this.parseCreds(credentials).tenancy;
    const response = await this.ociRequest('POST', '/publicIps', region, credentials, undefined, {
      compartmentId,
      lifetime: 'RESERVED',
      displayName: `reserved-ip-${Date.now()}`,
    });
    const data = await response.json();
    if (!data.id) {
      throw new CloudAdapterError('oci', 'Failed to allocate reserved public IP');
    }
    return {
      allocationId: data.id,
      publicIp: data['ip-address'] ?? '',
      provider: 'oci',
      region,
    };
  }

  async associateIp(
    instanceId: string,
    allocationId: string,
    region: string,
    credentials: Credentials
  ): Promise<void> {
    // 获取 VNIC 和 Private IP
    const vnic = await this.getInstanceVnic(instanceId, region, credentials);
    if (!vnic) throw new CloudAdapterError('oci', `No VNIC for instance ${instanceId}`);
    const privateIpId = await this.getPrivateIpId(vnic.id, region, credentials);
    if (!privateIpId) throw new CloudAdapterError('oci', `No private IP for VNIC ${vnic.id}`);

    // 更新 Private IP 的 publicIpId
    await this.ociRequest('PUT', `/privateIps/${privateIpId}`, region, credentials, undefined, {
      publicIpId: allocationId,
    });
  }

  async releaseIp(allocationId: string, region: string, credentials: Credentials): Promise<void> {
    await this.deletePublicIp(allocationId, region, credentials);
  }

  async listIps(region: string, credentials: Credentials): Promise<AllocatedIp[]> {
    const compartmentId = credentials.compartmentId || this.parseCreds(credentials).tenancy;
    const response = await this.ociRequest('GET', '/publicIps', region, credentials, {
      compartmentId,
      scope: 'REGION',
      lifetime: 'RESERVED',
    });
    const data = await response.json();
    const ips: AllocatedIp[] = [];
    for (const pip of data.data ?? []) {
      ips.push({
        allocationId: pip.id,
        publicIp: pip['ip-address'] ?? '',
        provider: 'oci',
        region,
      });
    }
    return ips;
  }

  // ─── Private helpers ─────────────────────────────────

  /** 获取实例信息 */
  private async getInstance(instanceId: string, region: string, credentials: Credentials): Promise<OciInstance> {
    const response = await this.ociRequest('GET', `/instances/${instanceId}`, region, credentials);
    const data = await response.json();
    return {
      id: data.id,
      compartmentId: data['compartment-id'],
      displayName: data['display-name'],
      lifecycleState: data['lifecycle-state'],
    };
  }

  /** 获取实例的 VNIC */
  private async getInstanceVnic(instanceId: string, region: string, credentials: Credentials): Promise<{ id: string } | null> {
    const response = await this.ociRequest('GET', '/vnics', region, credentials, { instanceId });
    const data = await response.json();
    const vnic = data.data?.[0];
    return vnic?.id ? { id: vnic.id } : null;
  }

  /** 获取 VNIC 的公网 IP */
  private async getVnicPublicIp(vnicId: string, region: string, credentials: Credentials): Promise<string | null> {
    const response = await this.ociRequest('GET', `/vnics/${vnicId}`, region, credentials);
    const data = await response.json();
    return data['public-ip'] || null;
  }

  /** 获取 VNIC 的 Private IP ID */
  private async getPrivateIpId(vnicId: string, region: string, credentials: Credentials): Promise<string | null> {
    const response = await this.ociRequest('GET', '/privateIps', region, credentials, { vnicId });
    const data = await response.json();
    return data.data?.[0]?.id || null;
  }

  /** 创建 ephemeral 公网 IP */
  private async createEphemeralPublicIp(
    privateIpId: string,
    compartmentId: string,
    region: string,
    credentials: Credentials
  ): Promise<{ success: boolean; publicIpId?: string; existingIpId?: string; error?: string }> {
    try {
      const response = await this.ociRequest('POST', '/publicIps', region, credentials, undefined, {
        compartmentId,
        lifetime: 'EPHEMERAL',
        privateIpId,
      });
      const data = await response.json();
      if (response.ok && data.id) {
        return { success: true, publicIpId: data.id };
      }
      // 尝试从错误信息中提取已有的 public IP OCID
      const errorMsg = data.message || JSON.stringify(data);
      const match = errorMsg.match(/ocid1\.publicip\.[^\s"']+/);
      if (match) {
        return { success: false, existingIpId: match[0], error: errorMsg };
      }
      return { success: false, error: errorMsg };
    } catch (err) {
      const msg = errMsg(err);
      const match = msg.match(/ocid1\.publicip\.[^\s"']+/);
      if (match) {
        return { success: false, existingIpId: match[0], error: msg };
      }
      return { success: false, error: msg };
    }
  }

  /** 删除公网 IP */
  private async deletePublicIp(publicIpId: string, region: string, credentials: Credentials): Promise<void> {
    await this.ociRequest('DELETE', `/publicIps/${publicIpId}`, region, credentials);
  }

  /**
   * OCI API 请求 — 包含 API Key 签名
   *
   * 签名格式：
   *   Authorization: Signature keyId="ocid1.user.oc1.../ocid1.tenancy.oc1.../fingerprint",
   *                  algorithm="rsa-sha256",
   *                  headers="date (request-target) host content-type content-length",
   *                  signature="base64(...)"
   */
  private async ociRequest(
    method: string,
    path: string,
    region: string,
    credentials: Credentials,
    queryParams?: Record<string, string>,
    body?: unknown
  ): Promise<Response> {
    const creds = this.parseCreds(credentials);
    const host = `iaas.${region}.oraclecloud.com`;

    // 构建完整 URL
    let url = `https://${host}/${this.apiVersion}${path}`;
    if (queryParams && Object.keys(queryParams).length > 0) {
      const qs = new URLSearchParams(queryParams).toString();
      url += `?${qs}`;
    }

    // 准备请求头
    const date = new Date().toUTCString();
    const bodyStr = body ? JSON.stringify(body) : '';
    const headers: Record<string, string> = {
      date,
      host,
      'content-type': 'application/json',
    };
    if (bodyStr) {
      headers['content-length'] = Buffer.byteLength(bodyStr, 'utf8').toString();
    } else {
      headers['content-length'] = '0';
    }

    // 构建签名字符串
    const requestTarget = `${method.toLowerCase()} ${url.replace(`https://${host}`, '')}`;
    const signingHeaders = 'date (request-target) host content-type content-length';
    const signingString = [
      `date: ${date}`,
      `(request-target): ${requestTarget}`,
      `host: ${host}`,
      `content-type: application/json`,
      `content-length: ${headers['content-length']}`,
    ].join('\n');

    // 签名
    const keyId = `${creds.tenancy}/${creds.user}/${creds.fingerprint}`;
    const signature = this.sign(signingString, creds.privateKey);

    headers['authorization'] = `Signature keyId="${keyId}",algorithm="rsa-sha256",headers="${signingHeaders}",signature="${signature}"`;

    // 发送请求
    const response = await fetch(url, {
      method,
      headers,
      body: bodyStr || undefined,
    });

    if (!response.ok && response.status !== 409) {
      const text = await response.text();
      throw new CloudAdapterError('oci', `OCI API ${method} ${path} failed: ${response.status} ${text}`);
    }

    return response;
  }

  /** 使用 RSA-SHA256 签名 */
  private sign(data: string, privateKeyPem: string): string {
    // 支持 \n 转义（如果从环境变量传入的密钥包含字面 \n）
    const pem = privateKeyPem.includes('-----BEGIN') ? privateKeyPem : privateKeyPem.replace(/\\n/g, '\n');
    const signer = crypto.createSign('RSA-SHA256');
    signer.update(data);
    signer.end();
    const signature = signer.sign(pem);
    return signature.toString('base64');
  }
}

// ─── Types ─────────────────────────────────────────────

interface OciInstance {
  id: string;
  compartmentId: string;
  displayName?: string;
  lifecycleState?: string;
}

// ─── Helpers ────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errMsg(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}
