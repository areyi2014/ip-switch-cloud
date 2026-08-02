/**
 * Cloud IP Rotator MCP — Shared Type Definitions
 */

/** Supported cloud providers */
export type CloudProvider = 'aws' | 'azure' | 'oci' | 'vultr';

/** Result of an IP rotation operation */
export interface RotateIpResult {
  success: boolean;
  oldIp?: string;
  newIp?: string;
  message: string;
  details?: Record<string, unknown>;
}

/** Basic instance information */
export interface InstanceInfo {
  instanceId: string;
  provider: CloudProvider;
  region: string;
  state: string;
  publicIp?: string;
  privateIp?: string;
  name?: string;
}

/** Allocated IP information */
export interface AllocatedIp {
  allocationId: string;
  publicIp: string;
  provider: CloudProvider;
  region: string;
}

/** Credentials passed per-call (key-value map, provider-specific keys) */
export type Credentials = Record<string, string>;

/** Parameters for IP rotation */
export interface RotateIpParams {
  provider: CloudProvider;
  instanceId: string;
  region: string;
  credentials: Credentials;
}

/** Parameters for IP allocation */
export interface AllocateIpParams {
  provider: CloudProvider;
  region: string;
  credentials: Credentials;
}

/** Parameters for IP association */
export interface AssociateIpParams {
  provider: CloudProvider;
  instanceId: string;
  allocationId: string;
  region: string;
  credentials: Credentials;
}

/** Parameters for IP release */
export interface ReleaseIpParams {
  provider: CloudProvider;
  allocationId: string;
  region: string;
  credentials: Credentials;
}

/** Parameters for getting instance info */
export interface GetInstanceParams {
  provider: CloudProvider;
  instanceId: string;
  region: string;
  credentials: Credentials;
}

/** Parameters for listing instances */
export interface ListInstancesParams {
  provider: CloudProvider;
  region: string;
  credentials: Credentials;
}

/** Parameters for listing allocated IPs */
export interface ListIpsParams {
  provider: CloudProvider;
  region: string;
  credentials: Credentials;
}

/** Standardized error with provider context */
export class CloudAdapterError extends Error {
  constructor(
    public provider: CloudProvider,
    message: string,
    public cause?: unknown
  ) {
    super(`[${provider}] ${message}`);
    this.name = 'CloudAdapterError';
  }
}
