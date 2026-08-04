/**
 * Config Store — Persistent JSON configuration storage
 *
 * Stores cloud provider profiles (with per-profile Cloudflare credentials)
 * in a JSON file at ~/.cloud-ip-rotator/config.json
 *
 * File format:
 * {
 *   "profiles": {
 *     "aws-sg": { "provider": "aws", "region": "...", "cloudflare": { ... }, ... },
 *     ...
 *   }
 * }
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import type { AppConfig, ConfigProfile } from './types.js';

const CONFIG_DIR = join(homedir(), '.cloud-ip-rotator');
const CONFIG_FILE = join(CONFIG_DIR, 'config.json');

const EMPTY_CONFIG: AppConfig = {
  profiles: {},
};

/** Load config from disk. Returns empty config if file doesn't exist. */
export function loadConfig(): AppConfig {
  try {
    if (!existsSync(CONFIG_FILE)) {
      return { ...EMPTY_CONFIG };
    }
    const raw = readFileSync(CONFIG_FILE, 'utf-8');
    const data = JSON.parse(raw) as Partial<AppConfig>;
    return {
      profiles: data.profiles ?? {},
    };
  } catch (err) {
    console.error(`[config-store] Failed to load config: ${err}`);
    return { ...EMPTY_CONFIG };
  }
}

/** Save config to disk (creates directory if needed). */
export function saveConfig(config: AppConfig): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), 'utf-8');
}

/** Save or update a cloud provider profile. */
export function saveProfile(profile: ConfigProfile): AppConfig {
  const config = loadConfig();
  config.profiles[profile.name] = profile;
  saveConfig(config);
  return config;
}

/** Delete a profile by name. Returns true if deleted, false if not found. */
export function deleteProfile(name: string): boolean {
  const config = loadConfig();
  if (!(name in config.profiles)) return false;
  delete config.profiles[name];
  saveConfig(config);
  return true;
}

/** Get a profile by name. Returns undefined if not found. */
export function getProfile(name: string): ConfigProfile | undefined {
  return loadConfig().profiles[name];
}

/** List all saved profiles. */
export function listProfiles(): ConfigProfile[] {
  return Object.values(loadConfig().profiles);
}

/** Get the config file path (for logging/debugging). */
export function getConfigPath(): string {
  return CONFIG_FILE;
}
