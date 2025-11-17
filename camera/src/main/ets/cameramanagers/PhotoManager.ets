/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 ("the License");
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

import { camera } from '@kit.CameraKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { sensor } from '@kit.SensorServiceKit';
import { Decimal } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { colorSpaceManager } from '@kit.ArkGraphics2D';
import { geoLocationManager } from '@kit.LocationKit';
import { display } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from 'commons';
import { OrganizationService } from '../dataservices/OrganizationService';
import GeoDataService from '../dataservices/GeoDataService';
import OutputManager, { CreateOutputConfig } from './OutputManager';
import CameraConstant from '../constants/CameraConstants';
// 内联水印处理所需接口与类型
interface WatermarkInfo {
  readonly timestamp: string;
  readonly weather?: string;
  readonly location?: string;
  readonly altitude?: string;
  readonly direction?: string;
  readonly longitude?: string;
  readonly latitude?: string;
  readonly organization?: string;
}

interface WatermarkInfoItem {
  label: string;
  value: string;
}

// ArkTS: avoid inline object literal types in declarations
interface WatermarkBaseMetrics {
  // 中部信息区
  itemHeight: number;
  valueFontSize: number;
  maxLabelWidth: number;
  valueX: number;
  valueMaxWidth: number;
  infoItemsCount: number;
  infoItemsTextY: Array<number>;
}

interface LocationWeatherResult {
  location: string;
  weather: string;
}

interface WatermarkBaseCacheEntry {
  pixelMap: image.PixelMap;
  expiresAt: number;
  metrics: WatermarkBaseMetrics;
}

// Cache of dynamic info items (excluding timestamp)
interface WatermarkDynamicInfo {
  weather: string;
  location: string;
  altitude: string;
  direction: string;
  longitude: string;
  latitude: string;
  organization: string;
}

// ArkTS: 避免内联对象字面量类型，定义专用接口
interface Size2D {
  width: number;
  height: number;
}
interface PhotoAssetEvent {
  uri: string;
}

// ArkTS: 为静态底图布局参数定义显式接口，避免内联对象类型
interface WatermarkBaseLayout {
  MARGIN: number;
  DOUBLE_MARGIN: number;
  radius: number;
  topRectX: number;
  topRectY: number;
  topRectWidth: number;
  topRectHeight: number;
  bottomRegionHeight: number;
  infoRegionTop: number;
  infoRegionHeight: number;
  itemCount: number;
  infoItems: Array<WatermarkInfoItem>;
}

interface WatermarkConfig {
  targetPhotoWidth: number;
  targetPhotoHeight: number;
  watermarkWidthRatio: number;
  watermarkHeightRatio: number;
  jpegQuality: number;
  dynamicRange: image.PackingDynamicRange;
  watermarkBaseCacheTTL: number;
  watermarkInfoCacheTTL: number;
}

const TAG_LOG = 'PhotoManager';

export class PhotoManager implements OutputManager {
  output?: camera.PhotoOutput;
  isActive: boolean = true;
  context: Context;
  private readonly appContext: Context;
  location: geoLocationManager.Location | null = null;
  /**
   * 编码与水印尺寸等参数常量，集中管理，便于维护
   */
  private config: WatermarkConfig = {
    targetPhotoWidth: 2880,
    targetPhotoHeight: 2160,
    watermarkWidthRatio: 0.4,
    watermarkHeightRatio: 0.5,
    jpegQuality: 100,
    dynamicRange: image.PackingDynamicRange.AUTO,
    watermarkBaseCacheTTL: 120000,
    watermarkInfoCacheTTL: 30000
  };
  // 调试开关：水印与像素处理详细日志
  private readonly DEBUG_WATERMARK_LOGS: boolean = true;
  // 复用图像打包器，减少多次创建的开销
  private imagePacker?: image.ImagePacker;
  // 显示信息缓存
  private displayInfoCached?: display.Display;
  // 制作单位由 OrganizationService 统一管理
  public getOrganization(): string {
    return OrganizationService.getInstance().getOrganization();
  }

  public addOrganizationListener(listener: (org: string) => void): void {
    OrganizationService.getInstance().addListener(listener);
  }

  public removeOrganizationListener(listener: (org: string) => void): void {
    OrganizationService.getInstance().removeListener(listener);
  }
  
  // 水印处理相关属性
  private enableWatermark: boolean = true;
  private saveMode: 'WM_ONLY' | 'KEEP_BOTH' = 'WM_ONLY';
  private readonly PREF_KEY_SAVE_MODE: string = 'save_mode';
  
  // 并发保护：避免同时处理多张照片
  private isProcessingPhoto: boolean = false;

  // 水印底图缓存：复用不依赖动态信息项的绘制结果（背景、徽标、标题栏等）
  private watermarkBaseCache: Map<string, WatermarkBaseCacheEntry> = new Map();
  private watermarkBaseCacheTTL: number = 120000;

  private getWatermarkBaseKey(width: number, height: number, organization: string): string {
    // 组织名称纳入缓存键，确保底部“制作单位”值静态化且正确复用
    return `${width}x${height}|org=${organization}`;
  }

  private purgeExpiredWatermarkBaseCache(): void {
    const now = Date.now();
    const entriesIter = this.watermarkBaseCache.entries();
    for (const keyEntry of entriesIter) {
      const key = keyEntry[0];
      const entry = keyEntry[1];
      if (entry.expiresAt <= now) {
        try { entry.pixelMap.release(); } catch (_) {}
        this.watermarkBaseCache.delete(key);
      }
    }
  }

  // ===== 水印信息项缓存（不含时间戳） =====
  private watermarkInfoCacheTTL: number = 30000;
  private cachedInfoExpiresAt: number = 0;
  private cachedInfoValues: WatermarkDynamicInfo | null = null; // weather/location/altitude/direction/longitude/latitude/organization
  private orgListener?: (org: string) => void;
  private externalLocWeaProvider?: () => Promise<LocationWeatherResult>;
  private debugWatermark: boolean = false;

  public setLocationWeatherProvider(provider: () => Promise<LocationWeatherResult>): void {
    this.externalLocWeaProvider = provider;
    if (this.debugWatermark) {
      Logger.info(TAG_LOG, 'provider:set ok');
    }
  }

  public setDebugWatermark(enabled: boolean): void {
    this.debugWatermark = !!enabled;
  }

  /**
   * 计算水印绘制尺寸（考虑设备像素比）
   */
  private computeWatermarkSize(): Size2D {
    const displayInfo = this.getDisplayInfo();
    const pixelRatio = displayInfo.densityPixels;
    const width = Math.round(this.config.targetPhotoWidth * this.config.watermarkWidthRatio / pixelRatio);
    const height = Math.round(this.config.targetPhotoHeight * this.config.watermarkHeightRatio / pixelRatio);
    return { width, height };
  }

  /**
   * 预热水印动态信息项（不含时间戳），用于后续绘制复用
   */
  private async prewarmWatermarkInfo(orgOverride?: string): Promise<void> {
    const orgValue = typeof orgOverride === 'string'
      ? orgOverride
      : (OrganizationService.getInstance().getOrganization() ||
        await OrganizationService.getInstance().getEffectiveOrganization(this.appContext));
    const snap = GeoDataService.getInstance().getSnapshot();
    if (this.debugWatermark) {
      Logger.info(TAG_LOG, `prewarm org='${orgValue}' provider=${this.externalLocWeaProvider ? 'true' : 'false'} snap{alt='${snap.altitude.display}',dir='${snap.direction.display}',lon='${snap.longitude.display}',lat='${snap.latitude.display}'}`);
    }
    const values: WatermarkDynamicInfo = {
      weather: await this.getWeatherInfo(),
      location: await this.getLocationInfo(),
      altitude: snap.altitude.display || '获取中',
      direction: snap.direction.display || '获取中',
      longitude: snap.longitude.display || '获取中',
      latitude: snap.latitude.display || '获取中',
      organization: orgValue
    };
    this.cachedInfoValues = values;
    this.cachedInfoExpiresAt = Date.now() + this.watermarkInfoCacheTTL;
    if (this.debugWatermark) {
      Logger.info(TAG_LOG, `prewarm cache weather='${values.weather}' location='${values.location}' ttl=${this.watermarkInfoCacheTTL}`);
    }
  }

  /**
   * 预热水印底图缓存（按期望尺寸），将冷态重绘移出拍照链路
   */
  private async prewarmWatermarkBaseCacheForExpectedSize(): Promise<void> {
    try {
      // ArkTS: 禁止解构式变量声明，改为显式赋值
      const size: Size2D = this.computeWatermarkSize();
      const watermarkWidth = size.width;
      const watermarkHeight = size.height;

      // 若已存在缓存则跳过
      const orgForKey = (this.cachedInfoValues?.organization && this.cachedInfoValues.organization.length > 0)
        ? this.cachedInfoValues.organization
        : (OrganizationService.getInstance().getOrganization() ||
          await OrganizationService.getInstance().getEffectiveOrganization(this.appContext));
      const key = this.getWatermarkBaseKey(watermarkWidth, watermarkHeight, orgForKey);
      if (this.watermarkBaseCache.has(key)) return;

      const offscreenCanvas = new OffscreenCanvas(watermarkWidth, watermarkHeight);
      const ctx2d = offscreenCanvas.getContext('2d');
      if (!ctx2d) return;

      // 使用当前（或预热后的）信息项绘制，底图快照会在方法内被缓存
      const now = new Date();
      const weekdays = ['星期日','星期一','星期二','星期三','星期四','星期五','星期六'];
      const wmInfo: WatermarkInfo = {
        timestamp: `${now.getFullYear()}.${String(now.getMonth() + 1).padStart(2, '0')}.${String(now.getDate()).padStart(2, '0')} ${weekdays[now.getDay()]} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`,
        weather: this.cachedInfoValues?.weather || '晴朗',
        location: this.cachedInfoValues?.location || '定位中...',
        altitude: this.cachedInfoValues?.altitude || '计算中...',
        direction: this.cachedInfoValues?.direction || '北偏东30°',
        longitude: this.cachedInfoValues?.longitude || '获取中...',
        latitude: this.cachedInfoValues?.latitude || '获取中...',
        organization: orgForKey
      };
      await this.drawWatermarkWithCanvas(ctx2d as OffscreenCanvasRenderingContext2D, wmInfo, watermarkWidth, watermarkHeight);
      // 无需取PixelMap；drawWatermarkWithCanvas内部已缓存底图快照
    } catch (e) {
      Logger.warn(TAG_LOG, `预热底图失败: ${String(e)}`);
    }
  }
  
  private callback: (pixelMap: image.PixelMap, url: string) => void = () => {
  };

  constructor(context: Context, isActive = true) {
    this.context = context;
    // 使用应用上下文进行偏好读写，避免 UI 上下文在某些调用时无效
    this.appContext = this.context.getApplicationContext();
    this.isActive = isActive;
    
    
    // 初始化位置信息
    this.initializeLocation();
    this.orgListener = (org: string) => {
      this.refreshWatermarkCachesImmediately(org).catch(() => {});
    };
    this.addOrganizationListener(this.orgListener);
    // 顺序初始化与预热：确保组织值到位后再构建底图，避免 key 的 org 为空
    this.initOrganizationFromPrefs()
      .then(() => this.initSaveModeFromPrefs())
      .then(async () => {
        try { await GeoDataService.getInstance().start(this.appContext) } catch (_) {}
        await this.prewarmWatermarkInfo()
      })
      .then(() => this.prewarmWatermarkBaseCacheForExpectedSize())
      .catch((err: Error | BusinessError) =>
        Logger.warn(TAG_LOG, `启动阶段预热失败: ${String(err)}`)
      );
  }

  // 获取或创建图像打包器（会话内复用）
  /**
   * 获取或创建 ImagePacker（会话内复用），降低编码构造开销
   */
  private getOrCreateImagePacker(): image.ImagePacker {
    if (!this.imagePacker) {
      this.imagePacker = image.createImagePacker();
    }
    return this.imagePacker as image.ImagePacker;
  }

  private getDisplayInfo(): display.Display {
    if (!this.displayInfoCached) {
      try {
        this.displayInfoCached = display.getDefaultDisplaySync();
      } catch (_) {
        this.displayInfoCached = undefined;
      }
    }
    return (this.displayInfoCached || display.getDefaultDisplaySync()) as display.Display;
  }

  public setWatermarkConfig(next: Partial<WatermarkConfig>): void {
    const prev: WatermarkConfig = this.config as WatermarkConfig;
    const merged: WatermarkConfig = {
      targetPhotoWidth: (next.targetPhotoWidth !== undefined ? next.targetPhotoWidth : prev.targetPhotoWidth) as number,
      targetPhotoHeight: (next.targetPhotoHeight !== undefined ? next.targetPhotoHeight : prev.targetPhotoHeight) as number,
      watermarkWidthRatio: (next.watermarkWidthRatio !== undefined ? next.watermarkWidthRatio : prev.watermarkWidthRatio) as number,
      watermarkHeightRatio: (next.watermarkHeightRatio !== undefined ? next.watermarkHeightRatio : prev.watermarkHeightRatio) as number,
      jpegQuality: (next.jpegQuality !== undefined ? next.jpegQuality : prev.jpegQuality) as number,
      dynamicRange: (next.dynamicRange !== undefined ? next.dynamicRange : prev.dynamicRange) as image.PackingDynamicRange,
      watermarkBaseCacheTTL: (next.watermarkBaseCacheTTL !== undefined ? next.watermarkBaseCacheTTL : prev.watermarkBaseCacheTTL) as number,
      watermarkInfoCacheTTL: (next.watermarkInfoCacheTTL !== undefined ? next.watermarkInfoCacheTTL : prev.watermarkInfoCacheTTL) as number
    };
    this.config = merged;
    this.watermarkBaseCacheTTL = merged.watermarkBaseCacheTTL;
    this.watermarkInfoCacheTTL = merged.watermarkInfoCacheTTL;
    const ratioChanged: boolean = (next.watermarkWidthRatio !== undefined) || (next.watermarkHeightRatio !== undefined) ||
      (next.targetPhotoWidth !== undefined) || (next.targetPhotoHeight !== undefined);
    if (ratioChanged) {
      try {
        for (const entry of this.watermarkBaseCache.values()) {
          try { entry.pixelMap.release(); } catch (_) {}
        }
      } finally {
        this.watermarkBaseCache.clear();
      }
    }
  }

  // 在前台恢复或会话开始时触发统一预热
  /**
   * 在前台恢复或会话开始时统一预热水印信息与底图
   */
  public async prewarmWatermarkCaches(): Promise<void> {
    try {
      // 避免空值覆盖：若已有缓存组织且非空，则传入以保持一致
      const prevOrg = this.cachedInfoValues?.organization;
      if (prevOrg && prevOrg.length > 0) {
        await this.prewarmWatermarkInfo(prevOrg);
      } else {
        await this.prewarmWatermarkInfo();
      }
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, '前台预热：水印信息项已刷新');
      }
    } catch (errInfo) {
      Logger.warn(TAG_LOG, `前台预热水印信息失败: ${String(errInfo)}`);
    }
    try {
      await this.prewarmWatermarkBaseCacheForExpectedSize();
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, '前台预热：水印底图已构建');
      }
    } catch (errBase) {
      Logger.warn(TAG_LOG, `前台预热水印底图失败: ${String(errBase)}`);
    }
  }

  /**
   * 组织变更后立即刷新拍摄过程中使用的水印缓存
   */
  public async refreshWatermarkCachesImmediately(newOrg?: string): Promise<void> {
    const currentOrg = OrganizationService.getInstance().getOrganization() || '';
    const nextOrg = typeof newOrg === 'string' ? newOrg : currentOrg;
    const sameOrg = (this.cachedInfoValues?.organization || currentOrg) === nextOrg;
    if (sameOrg) {
      try {
        await this.prewarmWatermarkInfo(nextOrg);
        if (this.debugWatermark) {
          Logger.info(TAG_LOG, '刷新：水印信息项已按新组织更新');
        }
      } catch (errInfo) {
        Logger.warn(TAG_LOG, `刷新水印信息失败: ${String(errInfo)}`);
      }
      return;
    }
    // 清空动态信息缓存
    this.cachedInfoValues = null;
    this.cachedInfoExpiresAt = 0;
    // 释放并清空底图缓存，避免沿用旧组织的底图
    try {
      for (const entry of this.watermarkBaseCache.values()) {
        try { entry.pixelMap.release(); } catch (_) {}
      }
    } finally {
      this.watermarkBaseCache.clear();
    }
    // 重新预热以构建新组织对应的缓存
    try {
      await this.prewarmWatermarkInfo(newOrg);
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, '刷新：水印信息项已按新组织更新');
      }
    } catch (errInfo) {
      Logger.warn(TAG_LOG, `刷新水印信息失败: ${String(errInfo)}`);
    }
    try {
      await this.prewarmWatermarkBaseCacheForExpectedSize();
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, '刷新：水印底图已按新组织构建');
      }
    } catch (errBase) {
      Logger.warn(TAG_LOG, `刷新水印底图失败: ${String(errBase)}`);
    }
  }

  setIsActive(isActive: boolean) {
    this.isActive = isActive;
  }

  setCallback(callback: (pixelMap: image.PixelMap, url: string) => void) {
    this.callback = callback;
  }

  

  /**
   * 读取偏好设置中的制作单位（默认返回空字符串）
   */
  private async initOrganizationFromPrefs(): Promise<void> {
    try {
      await OrganizationService.getInstance().initialize(this.appContext);
      const org = OrganizationService.getInstance().getOrganization();
      if (org && org.length > 0) {
        Logger.info(TAG_LOG, `初始化制作单位：${org}`);
      }
    } catch (err) {
      Logger.warn(TAG_LOG, `初始化制作单位失败: ${String(err)}`);
    }
  }

  /**
   * 启用/禁用水印
   */
  setWatermarkEnabled(enabled: boolean): void {
    this.enableWatermark = enabled;
  }

  public getSaveMode(): 'WM_ONLY' | 'KEEP_BOTH' {
    return this.saveMode;
  }

  private async initSaveModeFromPrefs(): Promise<void> {
    try {
      const prefs: preferences.Preferences = await preferences.getPreferences(this.appContext, 'watermark_prefs');
      const mode = await prefs.get(this.PREF_KEY_SAVE_MODE, 'WM_ONLY') as string;
      if (mode === 'KEEP_BOTH') {
        this.saveMode = 'KEEP_BOTH';
      } else {
        this.saveMode = 'WM_ONLY';
      }
      Logger.info(TAG_LOG, `初始化保存模式：${this.saveMode}`);
    } catch (err) {
      Logger.warn(TAG_LOG, `初始化保存模式失败: ${String(err)}`);
      this.saveMode = 'WM_ONLY';
    }
  }

  public async setSaveMode(mode: 'WM_ONLY' | 'KEEP_BOTH', ctx?: Context): Promise<void> {
    this.saveMode = mode;
    try {
      const contextToUse: Context = (ctx ?? this.appContext);
      const prefs: preferences.Preferences = await preferences.getPreferences(contextToUse, 'watermark_prefs');
      await prefs.put(this.PREF_KEY_SAVE_MODE, mode);
      await prefs.flush();
      Logger.info(TAG_LOG, `保存模式更新：${mode}`);
    } catch (err) {
      Logger.warn(TAG_LOG, `保存模式持久化失败: ${String(err)}`);
    }
  }

  /**
   * 设置制作单位（单一入口）：更新内存态、持久化、刷新缓存
   */
  public async setOrganization(newOrg: string, ctx?: Context): Promise<void> {
    await OrganizationService.getInstance().setOrganization(newOrg, ctx ?? this.appContext);
    await this.refreshWatermarkCachesImmediately(OrganizationService.getInstance().getOrganization());
  }

  /**
   * 设置是否使用高性能模式（已废弃，保留兼容性）
   */
  // 已废弃：不再需要该方法，保留注释以说明兼容性取消

  async createOutput(config: CreateOutputConfig) {
    let cameraPhotoOutput: camera.PhotoOutput | undefined = undefined;
    cameraPhotoOutput = this.createPhotoOutput(config.cameraManager, config.device, config.profile);
    if (cameraPhotoOutput) {
      this.output = cameraPhotoOutput;
      this.setPhotoOutputCallback();
    }
    return cameraPhotoOutput;
  }

  // [Start create_photo_output]
  // Create photo output
  /**
   * 创建照片输出（根据设备能力选择最匹配的 Profile）
   */
  public createPhotoOutput(cameraManager: camera.CameraManager|undefined, cameraDevice: camera.CameraDevice,
    profile: camera.Profile) {
    let cameraPhotoOutput: camera.PhotoOutput | undefined = undefined;
    const cameraOutputCapability =
      cameraManager?.getSupportedOutputCapability(cameraDevice, camera.SceneMode.NORMAL_PHOTO);
    let photoProfilesArray: camera.Profile[] | undefined = cameraOutputCapability?.photoProfiles;
    if (photoProfilesArray?.length) {
      try {
        const displayRatio = profile.size.width / profile.size.height;
        // 固定目标分辨率（限制在 2880×2160），并设置合理回退策略
        const targetWidth = this.config.targetPhotoWidth;
        const targetHeight = this.config.targetPhotoHeight;

        const candidates = photoProfilesArray.filter(pf => {
          const pfDisplayRatio = pf.size.width / pf.size.height;
          return Math.abs(pfDisplayRatio - displayRatio) <= CameraConstant.PROFILE_DIFFERENCE &&
            pf.format === camera.CameraFormat.CAMERA_FORMAT_JPEG;
        });

        let photoProfile: camera.Profile | undefined = candidates.find(pf =>
          pf.size.width === targetWidth && pf.size.height === targetHeight
        );

        if (!photoProfile) {
          // 优先选择不超过目标分辨率的“最大项”（清晰度尽量高但受限于目标）
          const notExceed = candidates.filter(pf => pf.size.width <= targetWidth && pf.size.height <= targetHeight)
            .sort((a, b) => (b.size.width * b.size.height) - (a.size.width * a.size.height));
          if (notExceed.length > 0) {
            photoProfile = notExceed[0];
          } else {
            // 若无不超过目标的项，再选择刚好高于目标的“最小项”，避免跳到过高分辨率
            const exceed = candidates.filter(pf => pf.size.width >= targetWidth && pf.size.height >= targetHeight)
              .sort((a, b) => (a.size.width * a.size.height) - (b.size.width * b.size.height));
            photoProfile = exceed[0];
          }
        }
          
        if (!photoProfile) {
          Logger.error(TAG_LOG, 'Failed to get photo profile');
          return;
        }
        
        Logger.info(TAG_LOG, `选择照片配置: ${photoProfile.size.width}x${photoProfile.size.height}, 格式: ${photoProfile.format}`);
        cameraPhotoOutput = cameraManager?.createPhotoOutput(photoProfile);
      } catch (error) {
        Logger.error(TAG_LOG, `Failed to createPhotoOutput. error: ${String(error)}`);
      }
    }
    this.output = cameraPhotoOutput;
    return cameraPhotoOutput;
  }

  // [End create_photo_output]

  

  // [Start set_photo_cb_asset]
  // 以已保存资产为入口进行水印处理
  setPhotoOutputCbAsset(photoOutput: camera.PhotoOutput, context: Context) {
    photoOutput.on('photoAssetAvailable', async (errCode: BusinessError, asset: PhotoAssetEvent): Promise<void> => {
      if (errCode || !asset || !asset.uri) {
        Logger.error(TAG_LOG, 'photoAssetAvailable: invalid asset');
        return;
      }
      Logger.info(TAG_LOG, `photoAssetAvailable: uri=${asset.uri}`);
      if (this.isProcessingPhoto) {
        Logger.warn(TAG_LOG, '已有照片正在处理，忽略资产回调');
        return;
      }
      this.isProcessingPhoto = true;
      try {
        if (this.enableWatermark) {
          await this.processSavedAssetWithWatermark(context, asset.uri);
        } else {
          Logger.info(TAG_LOG, '水印关闭：保留系统已保存的原片');
        }
      } catch (e) {
        Logger.error(TAG_LOG, `photoAssetAvailable 处理失败: ${String(e)}`);
      } finally {
        this.isProcessingPhoto = false;
      }
    });
  }

  // [End set_photo_cb_asset]

  

  /**
   * 获取水印信息
   */
  private async getWatermarkInfo(): Promise<WatermarkInfo> {
    const now = new Date();
    const weekdays = ['星期日','星期一','星期二','星期三','星期四','星期五','星期六'];
    const timestamp = `${now.getFullYear()}.${String(now.getMonth() + 1).padStart(2, '0')}.${String(now.getDate()).padStart(2, '0')} ${weekdays[now.getDay()]} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
    
    // 优先使用缓存的动态信息项（不含时间戳），过期则刷新
    const nowMs = Date.now();
    if (!this.cachedInfoValues || this.cachedInfoExpiresAt <= nowMs) {
      await this.prewarmWatermarkInfo();
    }
    const infoValues = this.cachedInfoValues!;
    // 始终优先使用最新的内存态组织；否则使用缓存，其次回退偏好
    let org = OrganizationService.getInstance().getOrganization() ||
      (infoValues.organization && infoValues.organization.length > 0
        ? infoValues.organization
        : await OrganizationService.getInstance().getEffectiveOrganization(this.appContext));
    // 空值统一替换为默认占位文案，避免空值导致的时序问题与显示缺失
    this.debugLog(`水印组织值: '${org}'`);
    // 如与缓存不一致，保持缓存与返回值一致，避免后续使用旧组织
    if (infoValues.organization !== org) {
      this.cachedInfoValues = {
        weather: infoValues.weather,
        location: infoValues.location,
        altitude: infoValues.altitude,
        direction: infoValues.direction,
        longitude: infoValues.longitude,
        latitude: infoValues.latitude,
        organization: org
      } as WatermarkDynamicInfo;
    }
    let alt = infoValues.altitude;
    let dir = infoValues.direction;
    let lon = infoValues.longitude;
    let lat = infoValues.latitude;
    let attempts = 0;
    while (attempts < 10) {
      const snap = GeoDataService.getInstance().getSnapshot();
      const altOk = snap.altitude.display && !this.isPlaceholder(snap.altitude.display);
      const dirOk = snap.direction.display && !this.isPlaceholder(snap.direction.display);
      const lonOk = snap.longitude.display && !this.isPlaceholder(snap.longitude.display);
      const latOk = snap.latitude.display && !this.isPlaceholder(snap.latitude.display);
      if (altOk || dirOk || lonOk || latOk) {
        alt = altOk ? snap.altitude.display : alt;
        dir = dirOk ? snap.direction.display : dir;
        lon = lonOk ? snap.longitude.display : lon;
        lat = latOk ? snap.latitude.display : lat;
        break;
      }
      await new Promise<void>(resolve => setTimeout(resolve, 50));
      attempts = attempts + 1;
    }
    if (this.location) {
      if (this.location.altitude !== undefined && this.location.altitude !== null && this.isPlaceholder(alt)) {
        alt = `${Math.round(this.location.altitude)}m`;
      }
      if (this.isPlaceholder(lon)) {
        const hemiE = (this.location.longitude >= 0) ? 'E' : 'W';
        const absLon = Math.abs(this.location.longitude).toFixed(6);
        lon = `${absLon}°${hemiE}`;
      }
      if (this.isPlaceholder(lat)) {
        const hemiN = (this.location.latitude >= 0) ? 'N' : 'S';
        const absLat = Math.abs(this.location.latitude).toFixed(6);
        lat = `${absLat}°${hemiN}`;
      }
    }
    this.cachedInfoValues = {
      weather: infoValues.weather,
      location: infoValues.location,
      altitude: alt,
      direction: dir,
      longitude: lon,
      latitude: lat,
      organization: org
    } as WatermarkDynamicInfo;
    return {
      timestamp,
      weather: infoValues.weather,
      location: infoValues.location,
      altitude: alt,
      direction: dir,
      longitude: lon,
      latitude: lat,
      organization: org
    };
  }


  /**
   * 获取天气信息
   */
  private async getWeatherInfo(): Promise<string> {
    if (this.cachedInfoValues && this.cachedInfoExpiresAt > Date.now() && this.cachedInfoValues.weather) {
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, `getWeather branch=cache value='${this.cachedInfoValues.weather}'`);
      }
      return this.cachedInfoValues.weather;
    }
    try {
      if (this.externalLocWeaProvider) {
        await this.refreshLocationWeatherFromProvider();
        if (this.cachedInfoValues && this.cachedInfoValues.weather) {
          return this.cachedInfoValues.weather;
        }
      }
    } catch (_) {}
    if (this.debugWatermark) {
      Logger.info(TAG_LOG, 'getWeather branch=fallback value=获取失败');
    }
    return '获取失败';
  }

  /**
   * 获取位置信息
   */
  private async getLocationInfo(): Promise<string> {
    if (this.cachedInfoValues && this.cachedInfoExpiresAt > Date.now() && this.cachedInfoValues.location) {
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, `getLocation branch=cache value='${this.cachedInfoValues.location}'`);
      }
      return this.cachedInfoValues.location;
    }
    try {
      if (this.externalLocWeaProvider) {
        await this.refreshLocationWeatherFromProvider();
        if (this.cachedInfoValues && this.cachedInfoValues.location) {
          return this.cachedInfoValues.location;
        }
      }
    } catch (_) {}
    if (this.debugWatermark) {
      Logger.info(TAG_LOG, 'getLocation branch=fallback value=获取失败');
    }
    return '获取失败';
  }

  private async refreshLocationWeatherFromProvider(): Promise<void> {
    try {
      const res = await this.externalLocWeaProvider!();
      const weather = res?.weather || '获取失败';
      const location = res?.location || '获取失败';
      const next: WatermarkDynamicInfo = {
        weather,
        location,
        altitude: this.cachedInfoValues?.altitude || '获取中',
        direction: this.cachedInfoValues?.direction || '获取中',
        longitude: this.cachedInfoValues?.longitude || '获取中',
        latitude: this.cachedInfoValues?.latitude || '获取中',
        organization: this.cachedInfoValues?.organization || (OrganizationService.getInstance().getOrganization() || '')
      };
      this.cachedInfoValues = next;
      this.cachedInfoExpiresAt = Date.now() + this.watermarkInfoCacheTTL;
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, `provider refresh weather='${weather}' location='${location}' ttl=${this.watermarkInfoCacheTTL}`);
      }
    } catch (e) {
      if (this.debugWatermark) {
        Logger.warn(TAG_LOG, `provider refresh failed: ${String(e)}`);
      }
    }
  }

  /**
   * 获取海拔信息
   */
  private async getAltitudeInfo(): Promise<string> {
    if (this.location && this.location.altitude) {
      return `${this.location.altitude.toFixed(1)}m`;
    }
    return '计算中...';
  }

  /**
   * 获取方向信息
   */
  private async getDirectionInfo(): Promise<string> {
    // 实际实现中应该使用指南针传感器
    return '北偏东30°';
  }

  /**
   * 保存 PixelMap 到相册
   */
  private async encodePixelMapToJpeg(pixelMap: image.PixelMap): Promise<ArrayBuffer> {
    const imagePackerApi = this.getOrCreateImagePacker();
    const packOpts: image.PackingOption = {
      format: 'image/jpeg',
      quality: this.config.jpegQuality,
      desiredDynamicRange: this.config.dynamicRange
    };
    const buffer: ArrayBuffer = await imagePackerApi.packing(pixelMap, packOpts);
    return buffer;
  }

  async savePixelMapToGallery(pixelMap: image.PixelMap, context: Context): Promise<string> {
    try {
      const buffer: ArrayBuffer = await this.encodePixelMapToJpeg(pixelMap);
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, `图像编码完成，缓冲区大小: ${buffer.byteLength} bytes`);
      }
      const savedUri: string = await this.saveBufferToGallery(buffer, context, `watermark_photo_${Date.now()}`);
      return savedUri;
    } catch (error) {
      Logger.error(TAG_LOG, `保存PixelMap失败: ${String(error)}`);
      throw new Error('保存处理后的图像失败');
    }
  }
  
  private async saveBufferToGallery(buffer: ArrayBuffer, context: Context, title: string): Promise<string> {
    const photoType: photoAccessHelper.PhotoType = photoAccessHelper.PhotoType.IMAGE;
    const extension: string = 'jpg';
    const createOptions: photoAccessHelper.CreateOptions = { title };
    let accessHelper: photoAccessHelper.PhotoAccessHelper | null = null;
    try {
      const assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
        photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(context, photoType, extension, createOptions);
      assetChangeRequest.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, buffer);
      assetChangeRequest.saveCameraPhoto();
      accessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      await accessHelper.applyChanges(assetChangeRequest);
      const savedUri = assetChangeRequest.getAsset().uri;
      return savedUri;
    } catch (e) {
      Logger.error(TAG_LOG, `保存到相册失败: ${String(e)}`);
      throw new Error('保存到相册失败');
    } finally {
      if (accessHelper) {
        try { accessHelper.release(); } catch (_) {}
      }
    }
  }
  
  // [End save_photo_single]

  // 基于已保存的资产 URI 进行水印处理与保存
  private async processSavedAssetWithWatermark(context: Context, assetUri: string): Promise<void> {
    Logger.info(TAG_LOG, '水印处理链阶段: begin');
    Logger.info(TAG_LOG, '开始水印处理流程');
    const watermarkInfo: WatermarkInfo = await this.getWatermarkInfo();
    const originalPixelMap: image.PixelMap = await this.decodePixelMapFromUri(assetUri);
    const displayInfo = this.getDisplayInfo();
    if (this.saveMode === 'KEEP_BOTH') {
      const origBuffer: ArrayBuffer = await this.encodePixelMapToJpeg(originalPixelMap);
      await this.saveBufferToGallery(origBuffer, context, `original_photo_${Date.now()}`);
    }
    const watermarkPixelMap = await this.createWatermarkPixelMap(watermarkInfo, originalPixelMap, displayInfo);
    const originalInfo = await originalPixelMap.getImageInfo();
    let resultPixelMap: image.PixelMap;
    try {
      resultPixelMap = await this.compositeImagesCanvas(originalPixelMap, watermarkPixelMap);
      try { originalPixelMap.release(); } catch (_) {}
    } catch (_) {
      resultPixelMap = await this.compositeImages(originalPixelMap, watermarkPixelMap, originalInfo);
    }
    Logger.info(TAG_LOG, '水印处理链阶段: compose-done');
    const savedUri = await this.savePixelMapToGallery(resultPixelMap, context);
    this.callback(resultPixelMap, savedUri);
    Logger.info(TAG_LOG, `水印处理完成，保存路径: ${savedUri}`);
    Logger.info(TAG_LOG, '水印处理链阶段: done');
    watermarkPixelMap.release();
    if (this.saveMode === 'WM_ONLY') {
      Logger.info(TAG_LOG, 'WM_ONLY: 当前保留系统原片（删除接口未使用）');
    }
  }

  // 基于 URI 的文件解码生成 PixelMap
  private async decodePixelMapFromUri(uri: string): Promise<image.PixelMap> {
    let imageSource: image.ImageSource | null = null;
    let fileHandle: fileIo.File | null = null;
    try {
      fileHandle = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(fileHandle.fd);
      if (!imageSource) {
        throw new Error('ImageSource未创建');
      }
      const pixelMap = await imageSource.createPixelMap({
        desiredSize: { width: 0, height: 0 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      });
      return pixelMap;
    } catch (e) {
      Logger.error(TAG_LOG, `从URI解码失败: ${String(e)}`);
      throw new Error('无法从URI解码图像');
    } finally {
      if (imageSource) {
        try { imageSource.release(); } catch (_) {}
      }
      if (fileHandle) {
        try { await fileIo.close(fileHandle.fd); } catch (_) {}
      }
    }
  }

  setPhotoOutputCallback() {
    if (!this.output) {
      return;
    }
    // 改为以已保存资产为主的处理模式
    this.output?.off('photoAssetAvailable');
    this.setPhotoOutputCbAsset(this.output, this.context);
  }

  preparePhoto(session: camera.Session, zoomRatio?: number, flashMode?: camera.FlashMode,
    focusMode?: camera.FocusMode) {
    const photoSession = session as camera.PhotoSession;
    this.setPhotoFlash(photoSession, flashMode);
    this.setPhotoFocus(photoSession, focusMode);
    this.setPhotoZoomRatio(photoSession, zoomRatio || 0);
  }

  // [Start set_color_space]
  // Set color space
  setColorSpaceBeforeCommitConfig(session: camera.PhotoSession, isHdr: boolean): void {
    // The isHdr flag indicates whether HDR mode is enabled, with true representing the use of the DISPLAY_P3 color space.
    let colorSpace: colorSpaceManager.ColorSpace =
      isHdr ? colorSpaceManager.ColorSpace.DISPLAY_P3 : colorSpaceManager.ColorSpace.SRGB;
    let colorSpaces: Array<colorSpaceManager.ColorSpace> = [];
    try {
      colorSpaces = session.getSupportedColorSpaces();
    } catch (error) {
      Logger.error(TAG_LOG, `The getSupportedColorSpaces call failed. error code: ${error.code}`);
    }
    if (!colorSpaces.includes(colorSpace)) {
      Logger.info(TAG_LOG, `colorSpace: ${colorSpace} is not support`);
      return;
    }
    try {
      Logger.info(TAG_LOG, `setColorSpace: ${colorSpace}`);
      session.setColorSpace(colorSpace);
    } catch (exception) {
      Logger.error(TAG_LOG, `setColorSpace failed, code is ${exception.code}, message is ${exception.message}`);
    }
    try {
      let activeColorSpace: colorSpaceManager.ColorSpace = session.getActiveColorSpace();
      Logger.info(TAG_LOG, `activeColorSpace: ${activeColorSpace}`);
    } catch (error) {
      Logger.error(TAG_LOG, `getActiveColorSpace Faild: ${error.message}`);
    }
  }

  // [End set_color_space]

  public checkFlash(photoSession: camera.PhotoSession) {
    let flashModeStatus: boolean = false;
    try {
      if (photoSession.hasFlash()) {
        flashModeStatus = photoSession.isFlashModeSupported(camera.FlashMode.FLASH_MODE_AUTO);
      }
    } catch (exception) {
      Logger.error(TAG_LOG, `checkFlash failed, code is ${exception.code}, message is ${exception.message}`);
    }
    return flashModeStatus;
  }

  public setPhotoFlash(photoSession: camera.PhotoSession, flashMode?: camera.FlashMode) {
    try {
      if (this.checkFlash(photoSession)) {
        photoSession.setFlashMode(flashMode || camera.FlashMode.FLASH_MODE_CLOSE);
      }
    } catch (error) {
      Logger.error(TAG_LOG, `Failed to hasFlash. error: ${String(error)}`);
    }
  }

  public setPhotoFocus(photoSession: camera.PhotoSession, focusMode?: camera.FocusMode) {
    const defaultMode = camera.FocusMode.FOCUS_MODE_CONTINUOUS_AUTO;
    try {
      let focusModeStatus: boolean = photoSession.isFocusModeSupported(focusMode || defaultMode);
      if (focusModeStatus) {
        photoSession.setFocusMode(focusMode || defaultMode);
      }
    } catch (error) {
      Logger.error(TAG_LOG,
        `Failed to check whether the focus mode is supported. error: ${String(error)}`);
    }
  }


  public setPhotoZoomRatio(photoSession: camera.PhotoSession, zoomRatio?: number) {
    let photoZoomRatio = 0;
    if (!zoomRatio) {
      try {
        let zoomRatioRange: number[] = photoSession.getZoomRatioRange();
        if (zoomRatioRange?.length) {
          photoZoomRatio = zoomRatioRange[0];
        }
      } catch (error) {
        Logger.error(TAG_LOG, `Failed to get the zoom ratio range. error: ${String(error)}`);
      }
    }
    try {
      photoSession.setZoomRatio(zoomRatio || photoZoomRatio);
    } catch (exception) {
      Logger.error(TAG_LOG, `setZoomRatio failed, code is ${exception.code}, message is ${exception.message}`);
    }
  }


  // [Start get_photo_rotation]
  // Get photo rotation - 修正逆时针旋转90°问题
  getPhotoRotation(photoOutput: camera.PhotoOutput, deviceDegree: number): camera.ImageRotation {
    return camera.ImageRotation.ROTATION_270;
  }

  // [End get_photo_rotation]

  // [Start capture_photo]
  // Capture photo
  public async capture(isFront: boolean) {
    const degree = await this.getPhotoDegree();
    const rotation = this.getPhotoRotation(this.output!, degree);
    let settings: camera.PhotoCaptureSetting = {
      quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
      rotation,
      mirror: isFront
    };
    this.output?.capture(settings, (err: BusinessError) => {
      if (err) {
        Logger.error(TAG_LOG, `Failed to capture the photo. error: ${String(err)}`);
        return;
      }
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, 'Callback invoked to indicate the photo capture request success.');
      }
    });
  }

  // [End capture_photo]

  private calculateDeviceDegree(x: number, y: number, z: number): number {
    let deviceDegree: number = 0;
    // Determine if the device is approaching a vertical position (perpendicular to the ground)
    if ((x * x + y * y) * 3 < z * z) {
      return deviceDegree;
    } else {
      try {
        // Calculate the inverse tangent value
        let sd: Decimal = Decimal.atan2(y, -x)
        // Convert radian values to angle values;
        let sc: Decimal = Decimal.round(Number(sd) / Math.PI * 180);
        // Adjust angle to be relative to vertical orientation
        deviceDegree = 90 - Number(sc);
        // Normalize angle to 0-360 degrees range
        deviceDegree = deviceDegree >= 0 ? deviceDegree % 360 : deviceDegree % 360 + 360;
      } catch (exception) {
        Logger.error(TAG_LOG,
          `calculateDeviceDegree failed, code is ${exception.code}, message is ${exception.message}`);
      }
    }
    return deviceDegree;
  }

  private getPhotoDegree() {
    const promise: Promise<number> = new Promise(resolve => {
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve(0);
        }
      }, 250);
      try {
        sensor.once(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            const degree = this.calculateDeviceDegree(data.x, data.y, data.z);
            resolve(degree);
          }
        });
      } catch (exception) {
        Logger.error(TAG_LOG, `getPhotoDegree failed, code is ${exception.code}, message is ${exception.message}`);
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(0);
        }
      }
    })
    return promise;
  }

  // [Start is_moving_photo]
  // Check whether support moving photo or not
  public isMovingPhotoSupported(photoOutput: camera.PhotoOutput): boolean {
    let isSupported: boolean = false;
    try {
      isSupported = photoOutput.isMovingPhotoSupported();
    } catch (error) {
      Logger.error(TAG_LOG, `The isMovingPhotoSupported call failed. error code: ${error.code}`);
    }
    return isSupported;
  }

  // [End is_moving_photo]

  // [Start enable_moving_photo]
  // Enable moving photo
  public enableMovingPhoto(enabled: boolean): void {
    try {
      this.output?.enableMovingPhoto(enabled);
    } catch (error) {
      Logger.error(TAG_LOG, `The enableMovingPhoto call failed. error code: ${error.code}`);
    }
  }

  // [End enable_moving_photo]

  // [Start photo_release]
  // Release photo and watermark processors
  /**
   * 释放照片输出与相关资源：解绑事件、清空缓存、释放编码器
   */
  async release() {
    try {
      await this.output?.release();
    } catch (exception) {
      Logger.error(TAG_LOG, `release failed, code is ${exception.code}, message is ${exception.message}`);
    }
    
    // 清理水印处理相关资源（当前为内联方法，无需显式销毁）
    if (this.debugWatermark) {
      Logger.info(TAG_LOG, '水印处理资源已清理');
    }
    
    // 统一解绑事件，避免残留监听
    this.output?.off('photoAssetAvailable');
    
    // 清理水印底图缓存
    const entriesIter = this.watermarkBaseCache.entries();
    for (const keyEntry of entriesIter) {
      const entry = keyEntry[1];
      try { entry.pixelMap.release(); } catch (_) {}
    }
    this.watermarkBaseCache.clear();

    // 释放复用的 ImagePacker
    if (this.imagePacker) {
      try {
        this.imagePacker.release();
        if (this.debugWatermark) {
          Logger.info(TAG_LOG, 'ImagePacker 已释放');
        }
      } catch (error) {
        Logger.error(TAG_LOG, `ImagePacker 释放失败: ${error?.code ?? ''} ${error?.message ?? ''}`);
      }
      this.imagePacker = undefined;
    }
    if (this.orgListener) {
      this.removeOrganizationListener(this.orgListener);
      this.orgListener = undefined;
    }
    this.output = undefined;
  }

  /**
   * 初始化位置信息
   */
  /**
   * 初始化位置信息（单次请求），失败时降级为默认值
   */
  private async initializeLocation(): Promise<void> {
    try {
      // 请求单次位置信息
      const requestInfo: geoLocationManager.SingleLocationRequest = {
        locatingTimeoutMs: 10000,  // 10秒超时
        locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY
      };
      
      this.location = await geoLocationManager.getCurrentLocation(requestInfo);
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, `位置信息获取成功: ${this.location.latitude}, ${this.location.longitude}`);
      }
    } catch (error) {
      Logger.error(TAG_LOG, `位置信息获取失败: ${String(error)}`);
      // 设置默认位置信息，避免水印处理失败
      this.location = {
        latitude: 0,
        longitude: 0,
        altitude: 0,
        accuracy: 0,
        speed: 0,
        timeStamp: Date.now(),
        direction: 0,
        timeSinceBoot: 0
      } as geoLocationManager.Location;
    }
  }

  // [End photo_release]

  /**
   * ===== 内联水印处理方法（来自 RobustWatermarkProcessor） =====
   */

  

  // 创建水印PixelMap
  private async createWatermarkPixelMap(watermarkInfo: WatermarkInfo, originalPixelMap: image.PixelMap, displayInfo: display.Display): Promise<image.PixelMap> {
    try {
      const imageInfo = await originalPixelMap.getImageInfo();
      const photoWidth = imageInfo.size.width;
      const photoHeight = imageInfo.size.height;
      const pixelRatio = displayInfo.densityPixels;
      const watermarkWidth = Math.round(photoWidth * this.config.watermarkWidthRatio / pixelRatio);
      const watermarkHeight = Math.round(photoHeight * this.config.watermarkHeightRatio / pixelRatio);
      this.debugLog(`创建水印画布: photo=${photoWidth}x${photoHeight}, ratio=${pixelRatio}, wm=${watermarkWidth}x${watermarkHeight}, org='${watermarkInfo.organization || ''}'`);
      if (this.debugWatermark) {
        Logger.info(TAG_LOG, `draw wmInfo{ts='${watermarkInfo.timestamp}',weather='${watermarkInfo.weather || ''}',location='${watermarkInfo.location || ''}',alt='${watermarkInfo.altitude || ''}',dir='${watermarkInfo.direction || ''}',lon='${watermarkInfo.longitude || ''}',lat='${watermarkInfo.latitude || ''}',org='${watermarkInfo.organization || ''}'}`);
      }
      const offscreenCanvas = new OffscreenCanvas(watermarkWidth, watermarkHeight);
      const context2d = offscreenCanvas.getContext('2d');
      
      if (!context2d) {
        throw new Error('无法获取Canvas上下文');
      }

      await this.drawWatermarkWithCanvas(context2d as OffscreenCanvasRenderingContext2D, watermarkInfo, watermarkWidth, watermarkHeight);

      const watermarkPixelMap: image.PixelMap = await (context2d as OffscreenCanvasRenderingContext2D).getPixelMap(0, 0, watermarkWidth, watermarkHeight);

      return watermarkPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `创建水印PixelMap失败: ${String(error)}`);
      throw new Error('无法创建水印');
    }
  }

  // 使用Canvas绘制水印内容
  private async drawWatermarkWithCanvas(context2d: OffscreenCanvasRenderingContext2D, 
                                       watermarkInfo: WatermarkInfo, 
                                       canvasWidth: number , 
                                       canvasHeight: number ): Promise<void> {

    
    // 布局常量
    const MARGIN = 4; 
    const DOUBLE_MARGIN = MARGIN * 2; 
    const radius = 8; 
    
    // 顶部区域布局（不直接绘制，由底图构建方法负责）
    const topRegionHeight = Math.round(canvasHeight * 0.3);
    const topRectX = MARGIN; // 左边距
    const topRectY = MARGIN; // 上边距
    const topRectWidth = canvasWidth - DOUBLE_MARGIN; // 宽度减去左右边距
    const topRectHeight = topRegionHeight - MARGIN; // 高度减去上边距
    
    // 在顶部矩形和底部矩形之间的区域：信息项布局
    const infoItems = this.getWatermarkInfoItems(watermarkInfo);
    const bottomRegionHeight = Math.round(canvasHeight * 0.1); // 底部区域高度
    const infoRegionTop = topRectY + topRectHeight + MARGIN; // 顶部矩形底部加上间距
    const infoRegionBottom = canvasHeight - bottomRegionHeight - MARGIN; // 底部矩形顶部减去间距
    const infoRegionHeight = infoRegionBottom - infoRegionTop;
    const itemCount = infoItems.length;

    // 1) 绘制/复用静态底图（背景、顶部/底部矩形、Logo与标题、信息项label与冒号、底部“制作单位：”label）
    // 统一组织值来源：优先使用传入信息项中的组织；其次使用内存态；最后回退偏好
    let orgForKey = (watermarkInfo.organization && watermarkInfo.organization.length > 0)
      ? watermarkInfo.organization
      : (OrganizationService.getInstance().getOrganization() ||
        await OrganizationService.getInstance().getEffectiveOrganization(this.appContext));
    const baseKey = this.getWatermarkBaseKey(canvasWidth, canvasHeight, orgForKey);
    this.purgeExpiredWatermarkBaseCache();
    let baseEntry = this.watermarkBaseCache.get(baseKey);
    if (!baseEntry) {
      const layout: WatermarkBaseLayout = {
        MARGIN: MARGIN,
        DOUBLE_MARGIN: DOUBLE_MARGIN,
        radius: radius,
        topRectX: topRectX,
        topRectY: topRectY,
        topRectWidth: topRectWidth,
        topRectHeight: topRectHeight,
        bottomRegionHeight: bottomRegionHeight,
        infoRegionTop: infoRegionTop,
        infoRegionHeight: infoRegionHeight,
        itemCount: itemCount,
        infoItems: infoItems
      };
      baseEntry = await this.buildWatermarkBasePixelMap(watermarkInfo, canvasWidth, canvasHeight, layout);
      this.watermarkBaseCache.set(baseKey, baseEntry);
      Logger.debug(TAG_LOG, `底图缓存构建完成: key=${baseKey}, 尺寸=${canvasWidth}×${canvasHeight}`);
    } else {
      const nowTs = Date.now();
      const ttlMs = baseEntry.expiresAt - nowTs;
      Logger.debug(TAG_LOG, `底图缓存命中: key=${baseKey}, 剩余TTL=${ttlMs}ms`);
    }

    // 清空并绘制底图快照
    context2d.clearRect(0, 0, canvasWidth, canvasHeight);
    context2d.drawImage(baseEntry.pixelMap as image.PixelMap, 0, 0, canvasWidth, canvasHeight);
    
    // 2) 动态渲染 value（使用底图缓存的公共度量）
    if (infoRegionHeight > 0 && infoItems.length > 0) {
      const metrics = baseEntry.metrics;
      context2d.fillStyle = 'black';
      context2d.textAlign = 'left';
      context2d.textBaseline = 'middle';
      context2d.font = `${metrics.valueFontSize}px sans-serif`;

      let k = 0;
      while (k < infoItems.length) {
        const textY = metrics.infoItemsTextY[k];
        const valueText = infoItems[k].value;
        context2d.fillText(valueText, metrics.valueX, textY, metrics.valueMaxWidth);
        k = k + 1;
      }
    }
    
    // 3) 底部“制作单位”值已纳入静态底图缓存，无需动态绘制

    // 顶部 Logo 与标题文本已包含在静态底图中（缓存）
  }

  /**
   * 构建静态水印底图（背景、顶部/底部矩形、Logo与标题、信息项label与冒号、底部“制作单位：”label），并缓存
   */
  private async buildWatermarkBasePixelMap(
    watermarkInfo: WatermarkInfo,
    canvasWidth: number,
    canvasHeight: number,
    layout: WatermarkBaseLayout
  ): Promise<WatermarkBaseCacheEntry> {
    const MARGIN = layout.MARGIN;
    const DOUBLE_MARGIN = layout.DOUBLE_MARGIN;
    const radius = layout.radius;
    const topRectX = layout.topRectX;
    const topRectY = layout.topRectY;
    const topRectWidth = layout.topRectWidth;
    const topRectHeight = layout.topRectHeight;
    const bottomRegionHeight = layout.bottomRegionHeight;
    const infoRegionTop = layout.infoRegionTop;
    const infoRegionHeight = layout.infoRegionHeight;
    const itemCount = layout.itemCount;
    const infoItems = layout.infoItems;

    const baseCanvas = new OffscreenCanvas(canvasWidth, canvasHeight);
    const ctx = baseCanvas.getContext('2d') as OffscreenCanvasRenderingContext2D;

    // 背景：白色圆角矩形
    ctx.clearRect(0, 0, canvasWidth, canvasHeight);
    ctx.fillStyle = 'rgba(255, 255, 255, 0.7)';
    this.drawRoundedRect(ctx, 0, 0, canvasWidth, canvasHeight, radius);
    ctx.fill();

    // 顶部矩形
    ctx.fillStyle = 'rgba(0, 87, 217, 0.5)';
    ctx.fillRect(topRectX, topRectY, topRectWidth, topRectHeight);

    // 底部矩形
    const bottomRectX = MARGIN;
    const bottomRectY = canvasHeight - bottomRegionHeight;
    const bottomRectWidth = canvasWidth - DOUBLE_MARGIN;
    const bottomRectHeight = bottomRegionHeight - MARGIN;
    ctx.fillRect(bottomRectX, bottomRectY, bottomRectWidth, bottomRectHeight);

    // 顶部 Logo 与标题文本
    let logoWidth = 0;
    const logoX = topRectX + MARGIN;
    try {
      const watermarkLogo = await this.loadWatermarkLogo();
      if (watermarkLogo) {
        const logoInfo = await watermarkLogo.getImageInfo();
        const maxLogoWidth = topRectWidth - DOUBLE_MARGIN;
        const maxLogoHeight = topRectHeight - DOUBLE_MARGIN;
        const widthRatio = maxLogoWidth / logoInfo.size.width;
        const heightRatio = maxLogoHeight / logoInfo.size.height;
        const scaleRatio = Math.min(widthRatio, heightRatio);
        logoWidth = logoInfo.size.width * scaleRatio;
        const logoHeight = logoInfo.size.height * scaleRatio;
        const logoY = topRectY + (topRectHeight - logoHeight) / 2;
        ctx.drawImage(watermarkLogo as image.PixelMap, logoX, logoY, logoWidth, logoHeight);
        watermarkLogo.release();
      }
    } catch (error) {
      Logger.warn(TAG_LOG, `静态底图Logo绘制失败: ${String(error)}`);
    }
    // 标题文本始终绘制（无论徽章是否加载成功）
    const titleText = '灭火救援灾害现场';
    const titleAreaX = logoX + logoWidth + MARGIN;
    const titleAreaWidth = topRectWidth - (logoX + logoWidth + DOUBLE_MARGIN);
    const titleAreaHeight = topRectHeight;
    const titleFontSize = titleAreaHeight * 0.8;
    ctx.fillStyle = 'white';
    ctx.font = `${titleFontSize}px sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    const titleTextX = titleAreaX + titleAreaWidth / 2;
    const titleTextY = topRectY + topRectHeight / 2;
    ctx.fillText(titleText, titleTextX, titleTextY);

    // 信息项 label 与冒号（中部区域）并计算公共度量
    let metrics: WatermarkBaseMetrics = {
      itemHeight: 0,
      valueFontSize: 0,
      maxLabelWidth: 0,
      valueX: 0,
      valueMaxWidth: 0,
      infoItemsCount: itemCount,
      infoItemsTextY: []
    };
    if (infoRegionHeight > 0 && itemCount > 0) {
      metrics.itemHeight = infoRegionHeight / itemCount;
      const labelFontSize = metrics.itemHeight * 2; // 与现有样式保持一致
      metrics.valueFontSize = labelFontSize;

      ctx.fillStyle = 'black';
      ctx.textAlign = 'left';
      ctx.textBaseline = 'middle';
      ctx.font = `${labelFontSize}px sans-serif`;

      // 计算每个label的宽度，取最大值
      let i = 0;
      while (i < infoItems.length) {
        const labelText = `${infoItems[i].label}：`;
        const width = ctx.measureText(labelText).width;
        if (width > metrics.maxLabelWidth) {
          metrics.maxLabelWidth = width;
        }
        i = i + 1;
      }
      const labelX = DOUBLE_MARGIN;
      metrics.valueX = labelX + metrics.maxLabelWidth + MARGIN;
      metrics.valueMaxWidth = canvasWidth - metrics.valueX - MARGIN;

      // 实际绘制静态label
      let j = 0;
      while (j < infoItems.length) {
        const textY = infoRegionTop + (j + 0.5) * metrics.itemHeight;
        metrics.infoItemsTextY[j] = textY;
        const labelText = `${infoItems[j].label}：`;
        ctx.fillText(labelText, labelX, textY);
        j = j + 1;
      }
    }

    // 底部“制作单位：”label 与 value 静态绘制，并计算公共度量
    {
      const orgFontSize = bottomRectHeight * 2; // 与现有样式一致
      ctx.fillStyle = 'white';
      ctx.textAlign = 'left';
      ctx.textBaseline = 'middle';
      ctx.font = `bold ${orgFontSize}px sans-serif`;
      const orgLabel = '制作单位：';
      const orgLabelX = bottomRectX + MARGIN;
      const orgLabelY = bottomRectY + bottomRectHeight / 2;
      ctx.fillText(orgLabel, orgLabelX, orgLabelY);
      const orgLabelWidth = ctx.measureText(orgLabel).width;
      const orgValueX = orgLabelX + orgLabelWidth + MARGIN;
      const orgValueY = orgLabelY;
      const orgValueMaxWidth = bottomRectWidth - (orgValueX - bottomRectX) - MARGIN;
      // 统一底部文案的组织值来源，避免与缓存键不一致
      const orgValue = (watermarkInfo.organization && watermarkInfo.organization.length > 0)
        ? watermarkInfo.organization
        : (await OrganizationService.getInstance().getEffectiveOrganization(this.appContext) || '');
      ctx.fillText(orgValue, orgValueX, orgValueY, orgValueMaxWidth);
    }

    const pixelMap: image.PixelMap = await ctx.getPixelMap(0, 0, canvasWidth, canvasHeight);
    const entry: WatermarkBaseCacheEntry = { pixelMap: pixelMap, expiresAt: Date.now() + this.watermarkBaseCacheTTL, metrics: metrics };
    return entry;
  }

  private getWatermarkInfoItems(watermarkInfo: WatermarkInfo): Array<WatermarkInfoItem> {
    return [
      { label: '拍摄时间', value: watermarkInfo.timestamp },
      { label: '天        气', value: watermarkInfo.weather || '获取中...' },
      { label: '地        点', value: watermarkInfo.location || '定位中...' },
      { label: '海        拔', value: watermarkInfo.altitude || '计算中...' },
      { label: '方  位  角', value: watermarkInfo.direction || '计算中...' },
      { label: '经        度', value: watermarkInfo.longitude || '计算中...' },
      { label: '纬        度', value: watermarkInfo.latitude || '获取中...' }
    ];
  }

  private async compositeImages(originalPixelMap: image.PixelMap, watermarkPixelMap: image.PixelMap, originalInfo: image.ImageInfo): Promise<image.PixelMap> {
    try {
      // 计算水印在原图中的位置：左下角并与边缘对齐
      const targetWidth = originalInfo.size.width;
      const targetHeight = originalInfo.size.height;
      const wmInfo = await watermarkPixelMap.getImageInfo();
      const watermarkWidth = wmInfo.size.width;
      const watermarkHeight = wmInfo.size.height;

      // 左下角坐标（X贴左边缘，Y贴底部边缘）
      const watermarkX = 8;
      const watermarkY = Math.max(targetHeight - watermarkHeight-7, 0);

      await this.blendWatermark(originalPixelMap, watermarkPixelMap, watermarkX, watermarkY);
      return originalPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `图像合成失败: ${String(error)}`);
      throw new Error('无法合成图像');
    }
  }

  private async compositeImagesCanvas(originalPixelMap: image.PixelMap, watermarkPixelMap: image.PixelMap): Promise<image.PixelMap> {
    try {
      const infos = await Promise.all([
        originalPixelMap.getImageInfo(),
        watermarkPixelMap.getImageInfo()
      ]);
      const targetWidth = infos[0].size.width;
      const targetHeight = infos[0].size.height;
      const watermarkWidth = infos[1].size.width;
      const watermarkHeight = infos[1].size.height;
      const watermarkX = 8;
      const watermarkY = Math.max(targetHeight - watermarkHeight - 7, 0);

      const canvas = new OffscreenCanvas(targetWidth, targetHeight);
      const ctx = canvas.getContext('2d') as OffscreenCanvasRenderingContext2D;
      ctx.clearRect(0, 0, targetWidth, targetHeight);
      ctx.drawImage(originalPixelMap as image.PixelMap, 0, 0, targetWidth, targetHeight);
      ctx.drawImage(watermarkPixelMap as image.PixelMap, watermarkX, watermarkY, watermarkWidth, watermarkHeight);
      const composed = await ctx.getPixelMap(0, 0, targetWidth, targetHeight);
      return composed;
    } catch (error) {
      Logger.error(TAG_LOG, `画布合成失败: ${String(error)}`);
      throw new Error('画布合成失败');
    }
  }

  // 直接在原图上就地混合水印，避免额外拷贝
  private async blendWatermark(targetPixelMap: image.PixelMap, watermarkPixelMap: image.PixelMap, x: number, y: number): Promise<void> {
    try {
      const imageInfos = await Promise.all([
        targetPixelMap.getImageInfo(),
        watermarkPixelMap.getImageInfo()
      ]);
      const targetInfo = imageInfos[0];
      const watermarkInfoRes = imageInfos[1];

      const targetWidth = targetInfo.size.width;
      const targetHeight = targetInfo.size.height;
      const watermarkWidth = watermarkInfoRes.size.width;
      const watermarkHeight = watermarkInfoRes.size.height;

      const startX = Math.max(x, 0);
      const startY = Math.max(y, 0);
      const endX = Math.min(x + watermarkWidth, targetWidth);
      const endY = Math.min(y + watermarkHeight, targetHeight);

      if (startX >= endX || startY >= endY) {
        Logger.warn(TAG_LOG, '水印区域超出目标图像边界，跳过混合');
        return;
      }

      const blendWidth = endX - startX;
      const blendHeight = endY - startY;
      this.debugLog(`blend: target=${targetWidth}x${targetHeight}, wm=${watermarkWidth}x${watermarkHeight}`);
      this.debugLog(`blend: region target(x=${startX},y=${startY},w=${blendWidth},h=${blendHeight}), wmOffset(x=${startX - x},y=${startY - y})`);
      
      const targetBuffer = new ArrayBuffer(blendWidth * blendHeight * 4);
      const targetArea: image.PositionArea = {
        pixels: targetBuffer,
        offset: 0,
        stride: blendWidth * 4,
        region: { size: { width: blendWidth, height: blendHeight }, x: startX, y: startY }
      };
      this.debugLog('blend: readTarget begin');
      try {
        await targetPixelMap.readPixels(targetArea);
        this.debugLog('blend: readTarget ok');
      } catch (readTargetErr) {
        if (typeof readTargetErr === 'number') {
          Logger.error(TAG_LOG, `blend: readTarget failed(code=${readTargetErr})`);
        } else {
          Logger.error(TAG_LOG, 'blend: readTarget failed');
        }
        throw new Error('readTarget failed');
      }
      const targetView = new Uint8Array(targetBuffer);

      const watermarkBuffer = new ArrayBuffer(blendWidth * blendHeight * 4);
      const watermarkArea: image.PositionArea = {
        pixels: watermarkBuffer,
        offset: 0,
        stride: blendWidth * 4,
        region: { size: { width: blendWidth, height: blendHeight }, x: startX - x, y: startY - y }
      };
      this.debugLog('blend: readWm begin');
      try {
        await watermarkPixelMap.readPixels(watermarkArea);
        this.debugLog('blend: readWm ok');
      } catch (readWmErr) {
        if (typeof readWmErr === 'number') {
          Logger.error(TAG_LOG, `blend: readWm failed(code=${readWmErr})`);
        } else {
          Logger.error(TAG_LOG, 'blend: readWm failed');
        }
        throw new Error('readWm failed');
      }
      const watermarkView = new Uint8Array(watermarkBuffer);

      for (let localY = 0; localY < blendHeight; localY++) {
        for (let localX = 0; localX < blendWidth; localX++) {
          const targetIndex = (localY * blendWidth + localX) * 4;
          const watermarkIndex = targetIndex;

          const alpha = watermarkView[watermarkIndex + 3] / 255.0;
          if (alpha < 0.01) continue;
          const invAlpha = 1.0 - alpha;

          targetView[targetIndex] = (targetView[targetIndex] * invAlpha + watermarkView[watermarkIndex] * alpha + 0.5) | 0;
          targetView[targetIndex + 1] = (targetView[targetIndex + 1] * invAlpha + watermarkView[watermarkIndex + 1] * alpha + 0.5) | 0;
          targetView[targetIndex + 2] = (targetView[targetIndex + 2] * invAlpha + watermarkView[watermarkIndex + 2] * alpha + 0.5) | 0;
        }
      }

      const writeArea: image.PositionArea = {
        pixels: targetBuffer,
        offset: 0,
        stride: blendWidth * 4,
        region: { size: { width: blendWidth, height: blendHeight }, x: startX, y: startY }
      };
      this.debugLog('blend: writeTarget begin');
      try {
        await targetPixelMap.writePixels(writeArea);
        this.debugLog('blend: writeTarget ok');
      } catch (writeErr) {
        if (typeof writeErr === 'number') {
          Logger.error(TAG_LOG, `blend: writeTarget failed(code=${writeErr})`);
        } else {
          Logger.error(TAG_LOG, 'blend: writeTarget failed');
        }
        throw new Error('writeTarget failed');
      }
    } catch (error) {
      Logger.error(TAG_LOG, `水印混合失败: ${String(error)}`);
      throw new Error('无法混合水印');
    }
  }

  private drawRoundedRect(context2d: OffscreenCanvasRenderingContext2D, x: number, y: number, 
                         width: number, height: number, radius: number): void {
    context2d.beginPath();
    
    if (radius > 0) {
      const x1 = x;
      const y1 = y;
      const x2 = x + width;
      const y2 = y + height;
      const r = radius;
      
      context2d.moveTo(x1 + r, y1);
      context2d.lineTo(x2 - r, y1);
      context2d.quadraticCurveTo(x2, y1, x2, y1 + r);
      context2d.lineTo(x2, y2 - r);
      context2d.quadraticCurveTo(x2, y2, x2 - r, y2);
      context2d.lineTo(x1 + r, y2);
      context2d.quadraticCurveTo(x1, y2, x1, y2 - r);
      context2d.lineTo(x1, y1 + r);
      context2d.quadraticCurveTo(x1, y1, x1 + r, y1);
    } else {
      context2d.rect(x, y, width, height);
    }
    
    context2d.closePath();
  }

  private async loadWatermarkLogo(): Promise<image.PixelMap | null> {
    try {
      // 优先使用应用上下文的资源管理器，避免 UI 上下文失效
      const appCtx = this.appContext as common.UIAbilityContext;
      let rm = appCtx.resourceManager;
      if (!rm) {
        const uiCtx = this.context as common.UIAbilityContext;
        rm = uiCtx.resourceManager;
      }
      if (!rm) {
        throw new Error('ResourceManager unavailable');
      }
      const imageBuffer: Uint8Array = await rm.getMediaContent($r('app.media.watermark_logo'));
      if (!imageBuffer || imageBuffer.byteLength === 0) {
        throw new Error('Media content unavailable');
      }
      const imageSource: image.ImageSource = image.createImageSource(imageBuffer.buffer);
      const pixelMap: image.PixelMap = await imageSource.createPixelMap();
      // 及时释放ImageSource资源
      imageSource.release();
      return pixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `加载水印徽章失败: ${String(error)}`);
      return null;
    }
  }
  
  private debugLog(msg: string): void {
    if (this.DEBUG_WATERMARK_LOGS) {
      Logger.debug(TAG_LOG, msg);
    }
  }

  private isPlaceholder(text: string): boolean {
    const t = String(text || '');
    if (t.length === 0) return true;
    return t.indexOf('获取') >= 0 || t.indexOf('计算') >= 0 || t.indexOf('定位') >= 0;
  }
}
