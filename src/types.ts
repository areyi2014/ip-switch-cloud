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

// ─── Cloudflare DNS ──────────────────────────────────────

/** Cloudflare API configuration (global, one account) */
export interface CloudflareConfig {
  apiToken: string;
  zoneId: string;
}

/** Result of a DNS record update */
export interface DnsUpdateResult {
  success: boolean;
  subdomain: string;
  oldIp?: string;
  newIp: string;
  recordId: string;
  message: string;
}

// ─── Persistent Configuration ────────────────────────────

/** A saved cloud provider profile with subdomain binding */
export interface ConfigProfile {
  /** Profile name (user-defined, e.g. "aws-sg", "azure-hk") */
  name: string;
  /** Cloud provider */
  provider: CloudProvider;
  /** Cloud region (e.g. ap-southeast-1, eastus) */
  region: string;
  /** Instance identifier */
  instanceId: string;
  /** Provider-specific credentials */
  credentials: Credentials;
  /** Bound subdomain for DNS update (e.g. ty.example.com) */
  subdomain: string;
  /** Whether Cloudflare proxy is enabled for this subdomain */
  proxied: boolean;
}

/** Full application config persisted to disk */
export interface AppConfig {
  /** Cloudflare API config (shared across all profiles) */
  cloudflare: CloudflareConfig | null;
  /** Saved cloud provider profiles, keyed by name */
  profiles: Record<string, ConfigProfile>;
}
