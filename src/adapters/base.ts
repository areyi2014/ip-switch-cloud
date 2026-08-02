/**
 * Cloud Adapter Interface — 所有云平台适配器的统一契约
 *
 * 每个适配器实现这套接口，路由层根据 provider 参数选择对应适配器。
 * 凭据通过参数传入，适配器内部不持久化任何凭据。
 */

import type {
  CloudProvider,
  Credentials,
  RotateIpResult,
  InstanceInfo,
  AllocatedIp,
} from '../types.js';

export interface CloudAdapter {
  /** Provider identifier */
  readonly provider: CloudProvider;

  /**
   * 一键轮换实例的公网 IP
   *
   * - AWS: stop/start 实例获取新动态公网 IP
   * - Azure: 解绑旧 IP → 删除 → 创建新 Standard Static IP → 绑定
   * - OCI: 删除旧 ephemeral IP → 创建新 ephemeral IP
   * - Vultr: 创建新 reserved IP → 绑定到实例 → 删除旧 reserved IP
   */
  rotateIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<RotateIpResult>;

  /** 获取实例当前公网 IP */
  getInstancePublicIp(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<string | null>;

  /** 获取实例详细信息 */
  getInstanceInfo(
    instanceId: string,
    region: string,
    credentials: Credentials
  ): Promise<InstanceInfo>;

  /** 列出实例 */
  listInstances(
    region: string,
    credentials: Credentials
  ): Promise<InstanceInfo[]>;

  /** 分配新 IP（EIP / Public IP / Reserved IP） */
  allocateIp(
    region: string,
    credentials: Credentials
  ): Promise<AllocatedIp>;

  /** 绑定 IP 到实例 */
  associateIp(
    instanceId: string,
    allocationId: string,
    region: string,
    credentials: Credentials
  ): Promise<void>;

  /** 释放 IP */
  releaseIp(
    allocationId: string,
    region: string,
    credentials: Credentials
  ): Promise<void>;

  /** 列出已分配的 IP */
  listIps(
    region: string,
    credentials: Credentials
  ): Promise<AllocatedIp[]>;
}
