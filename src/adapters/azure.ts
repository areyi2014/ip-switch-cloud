/**
 * Azure Adapter — 通过 Azure SDK 实现 VM 公网 IP 轮换
 *
 * 轮换方式：
 *   1. 查找 VM 的 NIC
 *   2. 解绑旧 Public IP
 *   3. 删除旧 Public IP
 *   4. 创建新 Standard Static Public IP
 *   5. 绑定新 IP 到 NIC
 *
 * 凭据通过参数传入，不持久化。
 */

import { NetworkManagementClient } from '@azure/arm-network';
import { ComputeManagementClient } from '@azure/arm-compute';
import { ClientSecretCredential } from '@azure/identity';
import type { CloudAdapter } from './base.js';
import type {
  CloudProvider,
  Credentials,
  RotateIpResult,
  InstanceInfo,
  AllocatedIp,
} from '../types.js';
import { CloudAdapterError } from '../types.js';

export class AzureAdapter implements CloudAdapter {
  readonly provider: CloudProvider = 'azure';

  /** 从凭据 map 中提取 Azure 认证参数 */
  private parseCreds(credentials: Credentials) {
    const subscriptionId = credentials.subscriptionId || credentials.AZURE_SUBSCRIPTION_ID;
    const clientId = credentials.clientId || credentials.AZURE_APP_ID || credentials.AZURE_CLIENT_ID;
    const clientSecret = credentials.clientSecret || credentials.AZURE_APP_PASSWORD || credentials.AZURE_CLIENT_SECRET;
    const tenantId = credentials.tenantId || credentials.AZURE_TENANT_ID;

    if (!subscriptionId) {
      throw new CloudAdapterError('azure', 'Missing Azure credentials: subscriptionId is required');
    }
    if (!clientId || !clientSecret || !tenantId) {
      throw new CloudAdapterError('azure', 'Missing Azure credentials: clientId, clientSecret, and tenantId are required for service principal auth');
    }
    return { subscriptionId, clientId, clientSecret, tenantId };
  }

  /** 创建 Azure 认证凭据 */
  private createCredential(credentials: Credentials) {
    const creds = this.parseCreds(credentials);
    return {
      credential: new ClientSecretCredential(creds.tenantId, creds.clientId, creds.clientSecret),
      subscriptionId: creds.subscriptionId,
    };
  }

  /** 创建 Network 管理客户端 */
  private createNetworkClient(credentials: Credentials): NetworkManagementClient {
    const { credential, subscriptionId } = this.createCredential(credentials);
    return new NetworkManagementClient(credential, subscriptionId);
  }

  /** 创建 Compute 管理客户端 */
  private createComputeClient(credentials: Credentials): ComputeManagementClient {
    const { credential, subscriptionId } = this.createCredential(credentials);
    return new ComputeManagementClient(credential, subscriptionId);
  }

  async rotateIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<RotateIpResult> {
    // instanceId 格式: resourceGroupName/vmName 或直接 vmName
    // 如果不含 /，则资源组需要单独传入（通过 credentials.resourceGroupName）
    const { resourceGroup, vmName } = parseAzureInstanceId(instanceId, credentials);

    const networkClient = this.createNetworkClient(credentials);

    try {
      // Step 1: 查找 VM 的 NIC
      const computeClient = this.createComputeClient(credentials);
      const vm = await computeClient.virtualMachines.get(resourceGroup, vmName);
      const nicRef = vm.networkProfile?.networkInterfaces?.[0]?.id;
      if (!nicRef) {
        throw new CloudAdapterError('azure', `VM ${instanceId} has no network interface`);
      }
      const nicName = extractResourceName(nicRef);
      const oldIp = await this.getInstancePublicIp(instanceId, region, credentials);

      // Step 2: 解绑旧 Public IP
      const nic = await networkClient.networkInterfaces.get(resourceGroup, nicName);
      const ipConfigName = nic.ipConfigurations?.[0]?.name ?? 'ipconfig1';

      if (nic.ipConfigurations?.[0]?.publicIPAddress?.id) {
        const oldPipId = nic.ipConfigurations[0].publicIPAddress.id;
        const oldPipName = extractResourceName(oldPipId);

        // 解绑
        await networkClient.networkInterfaces.beginCreateOrUpdateAndWait(resourceGroup, nicName, {
          location: nic.location,
          ipConfigurations: [{
            name: ipConfigName,
            publicIPAddress: undefined,
          }],
        });

        // 删除旧 IP
        await networkClient.publicIPAddresses.beginDeleteAndWait(resourceGroup, oldPipName);
      }

      // Step 3: 创建新 Public IP
      const pipName = `${vmName}-pip-${Date.now()}`;
      await networkClient.publicIPAddresses.beginCreateOrUpdateAndWait(resourceGroup, pipName, {
        location: region,
        sku: { name: 'Standard' },
        publicIPAllocationMethod: 'Static',
      });

      // Step 4: 绑定新 IP 到 NIC
      await networkClient.networkInterfaces.beginCreateOrUpdateAndWait(resourceGroup, nicName, {
        location: nic.location,
        ipConfigurations: [{
          name: ipConfigName,
          publicIPAddress: { id: `/subscriptions/${this.createCredential(credentials).subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Network/publicIPAddresses/${pipName}` },
        }],
      });

      // Step 5: 获取新 IP 地址
      const newPip = await networkClient.publicIPAddresses.get(resourceGroup, pipName);
      const newIp = newPip.ipAddress;

      return {
        success: true,
        oldIp: oldIp ?? undefined,
        newIp: newIp ?? undefined,
        message: `IP rotated: ${oldIp ?? 'N/A'} → ${newIp ?? 'N/A'}`,
        details: { publicIpName: pipName },
      };
    } catch (err) {
      throw new CloudAdapterError('azure', `Failed to rotate IP for VM ${instanceId}: ${errMsg(err)}`, err);
    }
  }

  async getInstancePublicIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<string | null> {
    const { resourceGroup, vmName } = parseAzureInstanceId(instanceId, credentials);
    const computeClient = this.createComputeClient(credentials);
    const networkClient = this.createNetworkClient(credentials);

    const vm = await computeClient.virtualMachines.get(resourceGroup, vmName);
    const nicRef = vm.networkProfile?.networkInterfaces?.[0]?.id;
    if (!nicRef) return null;

    const nicName = extractResourceName(nicRef);
    const nic = await networkClient.networkInterfaces.get(resourceGroup, nicName);
    const pipRef = nic.ipConfigurations?.[0]?.publicIPAddress?.id;
    if (!pipRef) return null;

    const pipName = extractResourceName(pipRef);
    const pip = await networkClient.publicIPAddresses.get(resourceGroup, pipName);
    return pip.ipAddress || null;
  }

  async getInstanceInfo(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<InstanceInfo> {
    const { resourceGroup, vmName } = parseAzureInstanceId(instanceId, credentials);
    const computeClient = this.createComputeClient(credentials);
    const vm = await computeClient.virtualMachines.get(resourceGroup, vmName);
    const publicIp = await this.getInstancePublicIp(instanceId, region, credentials);

    return {
      instanceId,
      provider: 'azure',
      region,
      state: vm.instanceView?.statuses?.find(s => s.code?.startsWith('PowerState/'))?.displayStatus ?? 'unknown',
      publicIp: publicIp ?? undefined,
      privateIp: vm.networkProfile?.networkInterfaces?.[0]?.id ? undefined : undefined,
      name: vm.name,
    };
  }

  async listInstances(region: string, credentials: Credentials): Promise<InstanceInfo[]> {
    const computeClient = this.createComputeClient(credentials);
    const instances: InstanceInfo[] = [];
    for await (const vm of computeClient.virtualMachines.listAll()) {
      if (vm.name && vm.id) {
        const rg = extractResourceGroup(vm.id);
        const publicIp = await this.getInstancePublicIp(`${rg}/${vm.name}`, region, credentials).catch(() => null);
        instances.push({
          instanceId: `${rg}/${vm.name}`,
          provider: 'azure',
          region,
          state: vm.provisioningState ?? 'unknown',
          publicIp: publicIp ?? undefined,
          name: vm.name,
        });
      }
    }
    return instances;
  }

  async allocateIp(region: string, credentials: Credentials): Promise<AllocatedIp> {
    const networkClient = this.createNetworkClient(credentials);
    const { subscriptionId } = this.createCredential(credentials);
    // Azure 需要资源组来创建 Public IP
    const resourceGroup = credentials.resourceGroupName || credentials.AZURE_RESOURCE_GROUP;
    if (!resourceGroup) {
      throw new CloudAdapterError('azure', 'Missing resourceGroupName in credentials for IP allocation');
    }
    const pipName = `pip-${Date.now()}`;
    await networkClient.publicIPAddresses.beginCreateOrUpdateAndWait(resourceGroup, pipName, {
      location: region,
      sku: { name: 'Standard' },
      publicIPAllocationMethod: 'Static',
    });
    const pip = await networkClient.publicIPAddresses.get(resourceGroup, pipName);
    return {
      allocationId: pip.id ?? pipName,
      publicIp: pip.ipAddress ?? '',
      provider: 'azure',
      region,
    };
  }

  async associateIp(
    instanceId: string,
    allocationId: string,
    region: string,
    credentials: Credentials
  ): Promise<void> {
    const { resourceGroup, vmName } = parseAzureInstanceId(instanceId, credentials);
    const networkClient = this.createNetworkClient(credentials);
    const computeClient = this.createComputeClient(credentials);

    const vm = await computeClient.virtualMachines.get(resourceGroup, vmName);
    const nicRef = vm.networkProfile?.networkInterfaces?.[0]?.id;
    if (!nicRef) throw new CloudAdapterError('azure', `VM ${instanceId} has no NIC`);
    const nicName = extractResourceName(nicRef);
    const nic = await networkClient.networkInterfaces.get(resourceGroup, nicName);
    const ipConfigName = nic.ipConfigurations?.[0]?.name ?? 'ipconfig1';

    await networkClient.networkInterfaces.beginCreateOrUpdateAndWait(resourceGroup, nicName, {
      location: nic.location,
      ipConfigurations: [{
        name: ipConfigName,
        publicIPAddress: { id: allocationId },
      }],
    });
  }

  async releaseIp(allocationId: string, region: string, credentials: Credentials): Promise<void> {
    const networkClient = this.createNetworkClient(credentials);
    // allocationId 是完整 resource ID 或 name
    const { resourceGroup, name } = parseAzureResourceId(allocationId, credentials);
    await networkClient.publicIPAddresses.beginDeleteAndWait(resourceGroup, name);
  }

  async listIps(region: string, credentials: Credentials): Promise<AllocatedIp[]> {
    const networkClient = this.createNetworkClient(credentials);
    const ips: AllocatedIp[] = [];
    for await (const pip of networkClient.publicIPAddresses.listAll()) {
      if (pip.name && pip.id) {
        const rg = extractResourceGroup(pip.id);
        ips.push({
          allocationId: pip.id,
          publicIp: pip.ipAddress ?? '',
          provider: 'azure',
          region,
        });
      }
    }
    return ips;
  }
}

// ─── Helpers ─────────────────────────────────────────────

/** Parse Azure instance ID: "rg/vmName" or just "vmName" (needs resourceGroupName in creds) */
function parseAzureInstanceId(instanceId: string, credentials: Credentials): { resourceGroup: string; vmName: string } {
  if (instanceId.includes('/')) {
    const [rg, name] = instanceId.split('/');
    return { resourceGroup: rg, vmName: name };
  }
  const rg = credentials.resourceGroupName || credentials.AZURE_RESOURCE_GROUP;
  if (!rg) {
    throw new CloudAdapterError('azure', 'Missing resourceGroupName in credentials (or use "resourceGroup/vmName" format)');
  }
  return { resourceGroup: rg, vmName: instanceId };
}

/** Extract resource name from Azure resource ID */
function extractResourceName(resourceId: string): string {
  const parts = resourceId.split('/');
  return parts[parts.length - 1];
}

/** Extract resource group from Azure resource ID */
function extractResourceGroup(resourceId: string): string {
  const match = resourceId.match(/resourceGroups\/([^/]+)/);
  return match?.[1] ?? '';
}

/** Parse Azure resource ID to get resource group and name */
function parseAzureResourceId(resourceId: string, credentials: Credentials): { resourceGroup: string; name: string } {
  if (resourceId.startsWith('/subscriptions/')) {
    return { resourceGroup: extractResourceGroup(resourceId), name: extractResourceName(resourceId) };
  }
  // It's just a name, need resource group from credentials
  const rg = credentials.resourceGroupName || credentials.AZURE_RESOURCE_GROUP;
  if (!rg) {
    throw new CloudAdapterError('azure', 'Missing resourceGroupName in credentials');
  }
  return { resourceGroup: rg, name: resourceId };
}

function errMsg(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}
