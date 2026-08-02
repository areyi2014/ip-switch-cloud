/**
 * AWS Adapter — 通过 AWS SDK v3 实现 EC2 实例公网 IP 轮换
 *
 * 轮换方式：停止 → 启动 EC2 实例，AWS 会回收旧的动态公网 IP 并分配新的。
 * 这是旧项目中验证过的方案，适用于非 Elastic IP 的动态公网 IP 场景。
 *
 * 凭据通过参数传入，不持久化。
 */

import {
  EC2Client,
  StopInstancesCommand,
  StartInstancesCommand,
  DescribeInstancesCommand,
  AllocateAddressCommand,
  AssociateAddressCommand,
  ReleaseAddressCommand,
  DescribeAddressesCommand,
  waitUntilInstanceStopped,
  waitUntilInstanceRunning,
} from '@aws-sdk/client-ec2';
import type { CloudAdapter } from './base.js';
import type {
  CloudProvider,
  Credentials,
  RotateIpResult,
  InstanceInfo,
  AllocatedIp,
} from '../types.js';
import { CloudAdapterError } from '../types.js';

export class AwsAdapter implements CloudAdapter {
  readonly provider: CloudProvider = 'aws';

  /** 从凭据 map 中提取 AWS 认证参数 */
  private parseCreds(credentials: Credentials) {
    const accessKeyId = credentials.accessKeyId || credentials.AWS_ACCESS_KEY_ID;
    const secretAccessKey = credentials.secretAccessKey || credentials.AWS_SECRET_ACCESS_KEY;
    const sessionToken = credentials.sessionToken || credentials.AWS_SESSION_TOKEN;

    if (!accessKeyId || !secretAccessKey) {
      throw new CloudAdapterError('aws', 'Missing AWS credentials: accessKeyId and secretAccessKey are required');
    }
    return { accessKeyId, secretAccessKey, sessionToken };
  }

  /** 创建 EC2 客户端 */
  private createClient(region: string, credentials: Credentials): EC2Client {
    const creds = this.parseCreds(credentials);
    return new EC2Client({
      region,
      credentials: {
        accessKeyId: creds.accessKeyId,
        secretAccessKey: creds.secretAccessKey,
        ...(creds.sessionToken && { sessionToken: creds.sessionToken }),
      },
    });
  }

  async rotateIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<RotateIpResult> {
    const client = this.createClient(region, credentials);

    try {
      // Step 1: 获取旧 IP（用于对比）
      const oldIp = await this.getInstancePublicIp(instanceId, region, credentials);

      // Step 2: 停止实例
      await client.send(new StopInstancesCommand({ InstanceIds: [instanceId] }));

      // Step 3: 等待实例完全停止
      await waitUntilInstanceStopped(
        { client, maxWaitTime: 180 },
        { InstanceIds: [instanceId] }
      );

      // Step 4: 启动实例
      await client.send(new StartInstancesCommand({ InstanceIds: [instanceId] }));

      // Step 5: 等待实例运行
      await waitUntilInstanceRunning(
        { client, maxWaitTime: 180 },
        { InstanceIds: [instanceId] }
      );

      // Step 6: 等待公网 IP 分配（AWS 异步分配，需要短暂等待）
      await sleep(30_000); // 30s

      // Step 7: 获取新 IP
      const newIp = await this.getInstancePublicIp(instanceId, region, credentials);

      return {
        success: true,
        oldIp: oldIp ?? undefined,
        newIp: newIp ?? undefined,
        message: `IP rotated successfully: ${oldIp ?? 'N/A'} → ${newIp ?? 'N/A'}`,
      };
    } catch (err) {
      throw new CloudAdapterError('aws', `Failed to rotate IP for instance ${instanceId}: ${errMsg(err)}`, err);
    }
  }

  async getInstancePublicIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<string | null> {
    const client = this.createClient(region, credentials);
    const response = await client.send(
      new DescribeInstancesCommand({ InstanceIds: [instanceId] })
    );
    const ip = response.Reservations?.[0]?.Instances?.[0]?.PublicIpAddress;
    return ip || null;
  }

  async getInstanceInfo(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<InstanceInfo> {
    const client = this.createClient(region, credentials);
    const response = await client.send(
      new DescribeInstancesCommand({ InstanceIds: [instanceId] })
    );
    const instance = response.Reservations?.[0]?.Instances?.[0];
    if (!instance) {
      throw new CloudAdapterError('aws', `Instance ${instanceId} not found`);
    }
    return {
      instanceId,
      provider: 'aws',
      region,
      state: instance.State?.Name ?? 'unknown',
      publicIp: instance.PublicIpAddress,
      privateIp: instance.PrivateIpAddress,
      name: instance.Tags?.find((t) => t.Key === 'Name')?.Value,
    };
  }

  async listInstances(region: string, credentials: Credentials): Promise<InstanceInfo[]> {
    const client = this.createClient(region, credentials);
    const response = await client.send(new DescribeInstancesCommand({}));
    const instances: InstanceInfo[] = [];
    for (const reservation of response.Reservations ?? []) {
      for (const inst of reservation.Instances ?? []) {
        if (inst.InstanceId) {
          instances.push({
            instanceId: inst.InstanceId,
            provider: 'aws',
            region,
            state: inst.State?.Name ?? 'unknown',
            publicIp: inst.PublicIpAddress,
            privateIp: inst.PrivateIpAddress,
            name: inst.Tags?.find((t) => t.Key === 'Name')?.Value,
          });
        }
      }
    }
    return instances;
  }

  async allocateIp(region: string, credentials: Credentials): Promise<AllocatedIp> {
    const client = this.createClient(region, credentials);
    const response = await client.send(new AllocateAddressCommand({ Domain: 'vpc' }));
    if (!response.AllocationId || !response.PublicIp) {
      throw new CloudAdapterError('aws', 'Failed to allocate EIP: missing AllocationId or PublicIp');
    }
    return {
      allocationId: response.AllocationId,
      publicIp: response.PublicIp,
      provider: 'aws',
      region,
    };
  }

  async associateIp(
    instanceId: string,
    allocationId: string,
    region: string,
    credentials: Credentials
  ): Promise<void> {
    const client = this.createClient(region, credentials);
    await client.send(
      new AssociateAddressCommand({ InstanceId: instanceId, AllocationId: allocationId })
    );
  }

  async releaseIp(allocationId: string, region: string, credentials: Credentials): Promise<void> {
    const client = this.createClient(region, credentials);
    await client.send(new ReleaseAddressCommand({ AllocationId: allocationId }));
  }

  async listIps(region: string, credentials: Credentials): Promise<AllocatedIp[]> {
    const client = this.createClient(region, credentials);
    const response = await client.send(new DescribeAddressesCommand({}));
    const ips: AllocatedIp[] = [];
    for (const addr of response.Addresses ?? []) {
      if (addr.AllocationId && addr.PublicIp) {
        ips.push({
          allocationId: addr.AllocationId,
          publicIp: addr.PublicIp,
          provider: 'aws',
          region,
        });
      }
    }
    return ips;
  }
}

/** Helper: sleep */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Helper: extract error message */
function errMsg(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}
