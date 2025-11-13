/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from 'commons';

const TAG = 'OrganizationService';

export class OrganizationService {
  private static instance: OrganizationService | null = null;
  private appContext?: Context;
  private currentOrganization: string = '';
  private listeners: Set<(org: string) => void> = new Set();
  private readonly PREF_NAME: string = 'watermark_prefs';
  private readonly PREF_KEY_ORGANIZATION: string = 'organization_name';

  static getInstance(): OrganizationService {
    if (!OrganizationService.instance) {
      OrganizationService.instance = new OrganizationService();
    }
    return OrganizationService.instance as OrganizationService;
  }

  async initialize(ctx?: common.UIAbilityContext | Context): Promise<void> {
    if (ctx) {
      try {
        // 使用应用上下文，避免 UI 上下文在某些调用时无效
        if (typeof (ctx as common.UIAbilityContext).getApplicationContext === 'function') {
          this.appContext = (ctx as common.UIAbilityContext).getApplicationContext();
        } else {
          this.appContext = ctx as Context;
        }
      } catch (_) {
        this.appContext = ctx as Context;
      }
    }
    try {
      const org = await this.getOrganizationFromPrefs(this.appContext);
      this.currentOrganization = org;
      if (org && org.length > 0) {
        this.notify(org);
      }
    } catch (err) {
      Logger.warn(TAG, `初始化组织失败: ${String(err)}`);
    }
  }

  getOrganization(): string {
    return this.currentOrganization;
  }

  async getOrganizationFromPrefs(ctx?: Context): Promise<string> {
    try {
      const contextToUse: Context | undefined = ctx ?? this.appContext;
      if (!contextToUse) {
        return '';
      }
      const prefs: preferences.Preferences = await preferences.getPreferences(contextToUse, this.PREF_NAME);
      const val = await prefs.get(this.PREF_KEY_ORGANIZATION, '') as string;
      return typeof val === 'string' ? val : '';
    } catch (err) {
      Logger.warn(TAG, `读取组织失败: ${String(err)}`);
      return '';
    }
  }

  async setOrganization(newOrg: string, ctx?: Context): Promise<void> {
    const normalized = (newOrg || '').trim();
    this.currentOrganization = normalized;
    this.notify(normalized);
    try {
      const contextToUse: Context | undefined = ctx ?? this.appContext;
      if (contextToUse) {
        const prefs: preferences.Preferences = await preferences.getPreferences(contextToUse, this.PREF_NAME);
        await prefs.put(this.PREF_KEY_ORGANIZATION, normalized);
        await prefs.flush();
      }
    } catch (err) {
      Logger.warn(TAG, `持久化组织失败: ${String(err)}`);
    }
  }

  addListener(listener: (org: string) => void): void {
    this.listeners.add(listener);
  }

  removeListener(listener: (org: string) => void): void {
    this.listeners.delete(listener);
  }

  private notify(org: string): void {
    try {
      this.listeners.forEach(fn => {
        try { fn(org); } catch (_) {}
      });
    } catch (_) {}
  }
}

export default OrganizationService;