/**
 * Cloudflare DNS Adapter — Update Cloudflare DNS A records via REST API v4
 *
 * Two operations:
 *   1. getRecordId  — find the DNS A record ID for a given subdomain
 *   2. updateDns     — combined: find record ID + update IP content
 *
 * Uses native fetch (Node 18+). No external dependencies.
 */

import type { CloudflareConfig, DnsUpdateResult } from '../types.js';

const API_BASE = 'https://api.cloudflare.com/client/v4';

/** Error thrown by Cloudflare adapter */
export class CloudflareError extends Error {
  constructor(message: string, public statusCode?: number) {
    super(`[cloudflare] ${message}`);
    this.name = 'CloudflareError';
  }
}

/** Find the DNS A record ID for a subdomain. */
export async function getRecordId(
  config: CloudflareConfig,
  subdomain: string
): Promise<string> {
  const url = `${API_BASE}/zones/${config.zoneId}/dns_records?type=A&name=${encodeURIComponent(subdomain)}`;

  const resp = await fetch(url, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${config.apiToken}`,
      'Content-Type': 'application/json',
    },
  });

  if (!resp.ok) {
    const text = await resp.text();
    throw new CloudflareError(`GET dns_records failed: ${resp.status} ${text}`, resp.status);
  }

  const data = await resp.json() as CloudflareListResponse;
  if (!data.success) {
    throw new CloudflareError(`API returned success=false: ${JSON.stringify(data.errors)}`);
  }

  const record = data.result?.[0];
  if (!record) {
    throw new CloudflareError(`A record for "${subdomain}" not found in zone ${config.zoneId}`);
  }

  return record.id;
}

/** Update the DNS A record for a subdomain to point to a new IP. */
export async function updateDns(
  config: CloudflareConfig,
  subdomain: string,
  newIp: string,
  proxied: boolean = false
): Promise<DnsUpdateResult> {
  // Step 1: Find the existing record ID
  const recordId = await getRecordId(config, subdomain);

  // Step 2: Fetch current IP (for comparison)
  const currentIp = await getCurrentRecordIp(config, recordId);

  // Step 3: PUT update
  const url = `${API_BASE}/zones/${config.zoneId}/dns_records/${recordId}`;
  const body = {
    type: 'A',
    name: subdomain,
    content: newIp,
    ttl: 120,
    proxied,
  };

  const resp = await fetch(url, {
    method: 'PUT',
    headers: {
      Authorization: `Bearer ${config.apiToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const text = await resp.text();
    throw new CloudflareError(`PUT dns_records failed: ${resp.status} ${text}`, resp.status);
  }

  const data = await resp.json() as CloudflareUpdateResponse;
  if (!data.success) {
    throw new CloudflareError(`API returned success=false: ${JSON.stringify(data.errors)}`);
  }

  return {
    success: true,
    subdomain,
    oldIp: currentIp ?? undefined,
    newIp,
    recordId,
    message: `DNS A record for ${subdomain} updated: ${currentIp ?? 'N/A'} -> ${newIp}`,
  };
}

/** Get the current IP content of a DNS record (for comparison). */
async function getCurrentRecordIp(
  config: CloudflareConfig,
  recordId: string
): Promise<string | null> {
  try {
    const url = `${API_BASE}/zones/${config.zoneId}/dns_records/${recordId}`;
    const resp = await fetch(url, {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${config.apiToken}`,
        'Content-Type': 'application/json',
      },
    });
    if (!resp.ok) return null;
    const data = await resp.json() as CloudflareListResponse;
    return data.result?.[0]?.content ?? null;
  } catch {
    return null;
  }
}

// ─── Cloudflare API response types ───────────────────────

interface CloudflareDnsRecord {
  id: string;
  type: string;
  name: string;
  content: string;
  ttl: number;
  proxied: boolean;
}

interface CloudflareListResponse {
  success: boolean;
  errors: unknown[];
  messages: unknown[];
  result: CloudflareDnsRecord[];
}

interface CloudflareUpdateResponse {
  success: boolean;
  errors: unknown[];
  messages: unknown[];
  result: CloudflareDnsRecord;
}
