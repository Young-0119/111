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
import { common } from '@kit.AbilityKit';
import { Logger } from 'commons';
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

const TAG_LOG = 'PhotoManager';

export class PhotoManager implements OutputManager {
  output?: camera.PhotoOutput;
  isActive: boolean = true;
  context: Context;
  location: geoLocationManager.Location | null = null;
  /**
   * 编码与水印尺寸等参数常量，集中管理，便于维护
   */
  private readonly TARGET_PHOTO_WIDTH: number = 2880; // 预热与选择配置所期望的宽度
  private readonly TARGET_PHOTO_HEIGHT: number = 2160; // 预热与选择配置所期望的高度
  private readonly WATERMARK_WIDTH_RATIO: number = 0.4; // 水印占照片宽度比例（按设备像素比折算）
  private readonly WATERMARK_HEIGHT_RATIO: number = 0.5; // 水印占照片高度比例（按设备像素比折算）
  private readonly DEFAULT_JPEG_QUALITY: number = 100; // 默认JPEG质量，兼顾体积与耗时
  private readonly DEFAULT_DYNAMIC_RANGE: image.PackingDynamicRange = image.PackingDynamicRange.AUTO;
  // 复用图像打包器，减少多次创建的开销
  private imagePacker?: image.ImagePacker;
  
  // 水印处理相关属性
  private enableWatermark: boolean = true;
  
  // 并发保护：避免同时处理多张照片
  private isProcessingPhoto: boolean = false;

  // 水印底图缓存：复用不依赖动态信息项的绘制结果（背景、徽标、标题栏等）
  private watermarkBaseCache: Map<string, WatermarkBaseCacheEntry> = new Map();
  private readonly watermarkBaseCacheTTL: number = 120000; // 120秒TTL

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
  private watermarkInfoCacheTTL: number = 30000; // 30秒TTL
  private cachedInfoExpiresAt: number = 0;
  private cachedInfoValues: WatermarkDynamicInfo | null = null; // weather/location/altitude/direction/longitude/latitude/organization

  /**
   * 计算水印绘制尺寸（考虑设备像素比）
   */
  private computeWatermarkSize(): Size2D {
    const displayInfo = display.getDefaultDisplaySync();
    const pixelRatio = displayInfo.densityPixels;
    const width = Math.round(this.TARGET_PHOTO_WIDTH * this.WATERMARK_WIDTH_RATIO / pixelRatio);
    const height = Math.round(this.TARGET_PHOTO_HEIGHT * this.WATERMARK_HEIGHT_RATIO / pixelRatio);
    
    // 调试信息：预热阶段的水印尺寸计算
    Logger.debug(TAG_LOG, `预热阶段水印尺寸计算: 宽度=${width} (${this.TARGET_PHOTO_WIDTH} × ${this.WATERMARK_WIDTH_RATIO} / ${pixelRatio})`);
    Logger.debug(TAG_LOG, `预热阶段水印尺寸计算: 高度=${height} (${this.TARGET_PHOTO_HEIGHT} × ${this.WATERMARK_HEIGHT_RATIO} / ${pixelRatio})`);
    
    return { width, height };
  }

  /**
   * 预热水印动态信息项（不含时间戳），用于后续绘制复用
   */
  private async prewarmWatermarkInfo(): Promise<void> {
    const values: WatermarkDynamicInfo = {
      weather: await this.getWeatherInfo(),
      location: await this.getLocationInfo(),
      altitude: await this.getAltitudeInfo(),
      direction: await this.getDirectionInfo(),
      longitude: this.location?.longitude?.toString() || '获取中...',
      latitude: this.location?.latitude?.toString() || '获取中...',
      organization: '应急管理部门'
    };
    this.cachedInfoValues = values;
    this.cachedInfoExpiresAt = Date.now() + this.watermarkInfoCacheTTL;
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
      const orgForKey = this.cachedInfoValues?.organization || '应急管理部门';
      const key = this.getWatermarkBaseKey(watermarkWidth, watermarkHeight, orgForKey);
      if (this.watermarkBaseCache.has(key)) return;

      const offscreenCanvas = new OffscreenCanvas(watermarkWidth, watermarkHeight);
      const ctx2d = offscreenCanvas.getContext('2d');
      if (!ctx2d) return;

      // 使用当前（或预热后的）信息项绘制，底图快照会在方法内被缓存
      const now = new Date();
      const wmInfo: WatermarkInfo = {
        timestamp: `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}:${String(now.getSeconds()).padStart(2, '0')}`,
        weather: this.cachedInfoValues?.weather || '晴朗',
        location: this.cachedInfoValues?.location || '定位中...',
        altitude: this.cachedInfoValues?.altitude || '计算中...',
        direction: this.cachedInfoValues?.direction || '北偏东30°',
        longitude: this.cachedInfoValues?.longitude || '获取中...',
        latitude: this.cachedInfoValues?.latitude || '获取中...',
        organization: this.cachedInfoValues?.organization || '应急管理部门'
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
    this.isActive = isActive;
    
    // 初始化水印处理器
    this.initializeWatermarkProcessors();
    
    // 初始化位置信息
    this.initializeLocation();
    
    // 启动阶段预热：缓存信息项与底图，降低首次拍摄延迟
    this.prewarmWatermarkInfo().catch((err: Error | BusinessError) =>
      Logger.warn(TAG_LOG, `预热水印信息失败: ${String(err)}`)
    );
    this.prewarmWatermarkBaseCacheForExpectedSize().catch((err: Error | BusinessError) =>
      Logger.warn(TAG_LOG, `预热水印底图失败: ${String(err)}`)
    );
  }

  // 获取或创建图像打包器（会话内复用）
  /**
   * 获取或创建 ImagePacker（会话内复用），降低编码构造开销
   */
  private getOrCreateImagePacker(): image.ImagePacker {
    if (!this.imagePacker) {
      this.imagePacker = image.createImagePacker();
      Logger.info(TAG_LOG, 'ImagePacker 已创建并开始复用');
    } else {
      Logger.info(TAG_LOG, 'ImagePacker 复用现有实例');
    }
    return this.imagePacker;
  }

  // 在前台恢复或会话开始时触发统一预热
  /**
   * 在前台恢复或会话开始时统一预热水印信息与底图
   */
  public async prewarmWatermarkCaches(): Promise<void> {
    try {
      await this.prewarmWatermarkInfo();
      Logger.info(TAG_LOG, '前台预热：水印信息项已刷新');
    } catch (errInfo) {
      Logger.warn(TAG_LOG, `前台预热水印信息失败: ${String(errInfo)}`);
    }
    try {
      await this.prewarmWatermarkBaseCacheForExpectedSize();
      Logger.info(TAG_LOG, '前台预热：水印底图已构建');
    } catch (errBase) {
      Logger.warn(TAG_LOG, `前台预热水印底图失败: ${String(errBase)}`);
    }
  }

  setIsActive(isActive: boolean) {
    this.isActive = isActive;
  }

  setCallback(callback: (pixelMap: image.PixelMap, url: string) => void) {
    this.callback = callback;
  }

  /**
   * 初始化水印处理器
   */
  private initializeWatermarkProcessors(): void {
    // 已内置水印处理方法，无需初始化单例处理器
    Logger.info(TAG_LOG, '水印处理方法已内置，无需单独初始化处理器');
  }

  /**
   * 启用/禁用水印
   */
  setWatermarkEnabled(enabled: boolean): void {
    this.enableWatermark = enabled;
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
        const targetWidth = this.TARGET_PHOTO_WIDTH;
        const targetHeight = this.TARGET_PHOTO_HEIGHT;

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
        Logger.error(TAG_LOG, `Failed to createPhotoOutput. error: ${JSON.stringify(error)}`);
      }
    }
    this.output = cameraPhotoOutput;
    return cameraPhotoOutput;
  }

  // [End create_photo_output]

  // [Start set_photo_cb_single]
  // Set photo callback single with watermark processing
  /**
   * 设置单阶段拍照回调，内含水印处理与并发保护
   */
  setPhotoOutputCbSingle(photoOutput: camera.PhotoOutput, context: Context) {
    photoOutput.on('photoAvailable', async (errCode: BusinessError, photo: camera.Photo): Promise<void> => {
      if (errCode || photo === undefined) {
        Logger.error(TAG_LOG, 'getPhoto failed');
        return;
      }
      
      // 并发保护：若已有照片在处理，忽略本次回调
      if (this.isProcessingPhoto) {
        Logger.warn(TAG_LOG, '已有照片正在处理，忽略本次回调');
        return;
      }
      this.isProcessingPhoto = true;
      try {
        // 检查是否启用水印
        if (this.enableWatermark) {
          await this.processPhotoWithWatermark(context, photo);
        } else {
          // 不使用水印，直接保存
          this.mediaLibSavePhotoSingle(context, photo.main);
        }
      } finally {
        this.isProcessingPhoto = false;
      }
    });
  }

  // [End set_photo_cb_single]

  /**
   * 处理带水印的照片
   */
  /**
   * 完整的带水印处理流程：获取信息 → 绘制 → 保存 → 回调
   */
  private async processPhotoWithWatermark(context: Context, photo: camera.Photo): Promise<void> {
    try {
      Logger.info(TAG_LOG, '开始水印处理流程');
      
      // 获取水印信息
      const watermarkInfo: WatermarkInfo = await this.getWatermarkInfo();
      
      let savedUri: string;
      let processedPixelMap: image.PixelMap;
      
      Logger.info(TAG_LOG, '使用内置水印处理方法');
      processedPixelMap = await this.processWatermark(photo, watermarkInfo);
      
      // 保存处理后的图像
      savedUri = await this.savePixelMapToGallery(processedPixelMap, context);
      Logger.info(TAG_LOG, `水印处理成功，保存路径: ${savedUri}`);
      
      // 调用回调函数
      this.callback(processedPixelMap, savedUri);
      
      Logger.info(TAG_LOG, `水印处理完成，保存路径: ${savedUri}`);
      
    } catch (error) {
      // 改进错误日志记录，提供更详细的错误信息
      const errorMessage = error instanceof Error ? error.message : '未知错误';
      const errorStack = error instanceof Error ? error.stack : '';
      Logger.error(TAG_LOG, `水印处理失败: ${errorMessage}`);
      if (errorStack) {
        Logger.error(TAG_LOG, `错误堆栈: ${errorStack}`);
      }
      
      // 降级处理：直接保存原图
      this.mediaLibSavePhotoSingle(context, photo.main);
    }
  }

  /**
   * 获取水印信息
   */
  private async getWatermarkInfo(): Promise<WatermarkInfo> {
    const now = new Date();
    const timestamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}:${String(now.getSeconds()).padStart(2, '0')}`;
    
    // 优先使用缓存的动态信息项（不含时间戳），过期则刷新
    const nowMs = Date.now();
    if (!this.cachedInfoValues || this.cachedInfoExpiresAt <= nowMs) {
      await this.prewarmWatermarkInfo();
    }
    const infoValues = this.cachedInfoValues!;
    return {
      timestamp,
      weather: infoValues.weather,
      location: infoValues.location,
      altitude: infoValues.altitude,
      direction: infoValues.direction,
      longitude: infoValues.longitude,
      latitude: infoValues.latitude,
      organization: infoValues.organization
    };
  }

  // 已移除：createPixelMapFromPhoto（使用 getPhotoPixelMap 统一实现）

  /**
   * 获取天气信息
   */
  private async getWeatherInfo(): Promise<string> {
    // 实际实现中应该调用天气API
    return '晴朗';
  }

  /**
   * 获取位置信息
   */
  private async getLocationInfo(): Promise<string> {
    if (this.location) {
      return `${this.location.latitude?.toFixed(6)}, ${this.location.longitude?.toFixed(6)}`;
    }
    return '定位中...';
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

  // [Start save_photo_single]
  // Save photo single
  mediaLibSavePhotoSingle(context: Context, imageObj: image.Image) {
    imageObj.getComponent(image.ComponentType.JPEG, async (errCode: BusinessError, component: image.Component) => {
      if (errCode || component === undefined) {
        Logger.error(TAG_LOG, 'getComponent failed');
        return;
      }
      const buffer: ArrayBuffer = component.byteBuffer;
      if (!buffer) {
        Logger.error(TAG_LOG, 'byteBuffer is null');
        return;
      }
      let photoType: photoAccessHelper.PhotoType = photoAccessHelper.PhotoType.IMAGE;
      let extension: string = 'jpg';
      let options: photoAccessHelper.CreateOptions = {
        title: 'testPhoto'
      }
      try {
        let assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
          photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(context, photoType, extension, options);
        assetChangeRequest.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, buffer)
        assetChangeRequest.saveCameraPhoto();
        let accessHelper: photoAccessHelper.PhotoAccessHelper =
          photoAccessHelper.getPhotoAccessHelper(context);
        await accessHelper.applyChanges(assetChangeRequest);
        let imageSource = image.createImageSource(buffer);
        let pixelmap = imageSource.createPixelMapSync();
        this.callback(pixelmap, assetChangeRequest.getAsset().uri);
        accessHelper.release();
        imageObj.release();
      } catch (exception) {
        Logger.error(TAG_LOG,
          `mediaLibSavePhotoSingle failed, code is ${exception.code}, message is ${exception.message}`);
      }
    });
  }

  /**
   * 保存 PixelMap 到相册
   *
   * 步骤：
   * 1) 使用复用的 ImagePacker 将 PixelMap 编码为 JPEG buffer；
   * 2) 通过 MediaAssetChangeRequest 写入相册，并返回保存的 URI；
   * 3) 记录阶段日志便于性能追踪。
   */
  async savePixelMapToGallery(pixelMap: image.PixelMap, context: Context): Promise<string> {
    try {
      // 将PixelMap转换为JPEG格式的ArrayBuffer（复用 ImagePacker）
      const imagePackerApi = this.getOrCreateImagePacker();
      
      // 编码参数：集中在类常量中管理，便于统一调整
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: this.DEFAULT_JPEG_QUALITY, // 质量 90%，平衡体积与耗时
        desiredDynamicRange: this.DEFAULT_DYNAMIC_RANGE // 自动动态范围处理
      };
      
      const buffer: ArrayBuffer = await imagePackerApi.packing(pixelMap, packOpts);
      Logger.info(TAG_LOG, 'ImagePacker 复用执行 packing 完成');
      
      if (!buffer) {
        throw new Error('PixelMap转换为buffer失败');
      }
      
      Logger.info(TAG_LOG, `图像编码完成，缓冲区大小: ${buffer.byteLength} bytes`);
      
      // 保存到相册
      const photoType: photoAccessHelper.PhotoType = photoAccessHelper.PhotoType.IMAGE;
      const extension: string = 'jpg';
      const options: photoAccessHelper.CreateOptions = {
        title: `watermark_photo_${Date.now()}`
      };
      
      const assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
        photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(context, photoType, extension, options);
      assetChangeRequest.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, buffer);
      assetChangeRequest.saveCameraPhoto();
      
      const accessHelper: photoAccessHelper.PhotoAccessHelper =
        photoAccessHelper.getPhotoAccessHelper(context);
      await accessHelper.applyChanges(assetChangeRequest);
      
      const savedUri = assetChangeRequest.getAsset().uri;
      accessHelper.release();
      
      Logger.info(TAG_LOG, `PixelMap保存成功，URI: ${savedUri}`);
      return savedUri;
      
    } catch (error) {
      Logger.error(TAG_LOG, `保存PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('保存处理后的图像失败');
    }
  }

  // [End save_photo_single]

  setPhotoOutputCallback() {
    if (!this.output) {
      return;
    }
    // Only support single-stage photo mode
    this.output?.off('photoAssetAvailable');
    this.output?.off('photoAvailable');
    this.setPhotoOutputCbSingle(this.output, this.context);
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
      Logger.error(TAG_LOG, `Failed to hasFlash. error: ${JSON.stringify(error)}`);
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
        `Failed to check whether the focus mode is supported. error: ${JSON.stringify(error)}`);
    }
  }

  // 已移除：setFocusPoint 方法由 CameraManager 统一对外暴露

  public setPhotoZoomRatio(photoSession: camera.PhotoSession, zoomRatio?: number) {
    let photoZoomRatio = 0;
    if (!zoomRatio) {
      try {
        let zoomRatioRange: number[] = photoSession.getZoomRatioRange();
        if (zoomRatioRange?.length) {
          photoZoomRatio = zoomRatioRange[0];
        }
      } catch (error) {
        Logger.error(TAG_LOG, `Failed to get the zoom ratio range. error: ${JSON.stringify(error)}`);
      }
    }
    try {
      photoSession.setZoomRatio(zoomRatio || photoZoomRatio);
    } catch (exception) {
      Logger.error(TAG_LOG, `setZoomRatio failed, code is ${exception.code}, message is ${exception.message}`);
    }
  }

  // 已移除：getSupportedColorSpaces 不再对外提供封装

  // [Start get_photo_rotation]
  // Get photo rotation - 修正逆时针旋转90°问题
  getPhotoRotation(photoOutput: camera.PhotoOutput, deviceDegree: number): camera.ImageRotation {
    // 补偿270°顺时针旋转（相当于逆时针90°），修正保存到相册时的逆时针旋转问题
    Logger.info(TAG_LOG, `修正旋转配置，设备方向: ${deviceDegree}度，补偿270°顺时针旋转`);
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
        Logger.error(TAG_LOG, `Failed to capture the photo. error: ${JSON.stringify(err)}`);
        return;
      }
      Logger.info(TAG_LOG, 'Callback invoked to indicate the photo capture request success.');
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
    Logger.info(TAG_LOG, '水印处理资源已清理');
    
    // 统一解绑所有可能事件，避免残留监听
    this.output?.off('photoAvailable');
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
        Logger.info(TAG_LOG, 'ImagePacker 已释放');
      } catch (error) {
        Logger.error(TAG_LOG, `ImagePacker 释放失败: ${error?.code ?? ''} ${error?.message ?? ''}`);
      }
      this.imagePacker = undefined;
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
      Logger.info(TAG_LOG, `位置信息获取成功: ${this.location.latitude}, ${this.location.longitude}`);
    } catch (error) {
      Logger.error(TAG_LOG, `位置信息获取失败: ${JSON.stringify(error)}`);
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

  // 主要水印处理方法 - 使用原生API确保兼容性
  private async processWatermark(photo: camera.Photo, watermarkInfo: WatermarkInfo): Promise<image.PixelMap> {
    Logger.info(TAG_LOG, '开始稳定水印处理流程');
    
    let originalPixelMap: image.PixelMap | null = null;
    let watermarkPixelMap: image.PixelMap | null = null;
    
    try {
      // 1. 并行获取原始图像和设备信息
      const parallelResults1 = await Promise.all([
        this.getPhotoPixelMap(photo),
        Promise.resolve(display.getDefaultDisplaySync())
      ]);
      originalPixelMap = parallelResults1[0];
      const displayInfo = parallelResults1[1];
      
      // 2. 并行创建水印图像和获取原图信息
      const parallelResults2 = await Promise.all([
        this.createWatermarkPixelMap(watermarkInfo, originalPixelMap, displayInfo),
        originalPixelMap.getImageInfo()
      ]);
      watermarkPixelMap = parallelResults2[0];
      const originalInfo = parallelResults2[1];

      // 3. 合成图像
      const resultPixelMap: image.PixelMap = await this.compositeImages(originalPixelMap, watermarkPixelMap, originalInfo);
      
      return resultPixelMap;
    } catch (err) {
      Logger.error(TAG_LOG, `水印处理失败: ${err instanceof Error ? err.message : String(err)}`);
      
      // 降级处理：返回原图（使用已获取的原图或重新获取）
      if (originalPixelMap) {
        Logger.info(TAG_LOG, '使用降级方案：返回已获取的原始图像');
        return originalPixelMap;
      }
      
      try {
        const fallbackPixelMap: image.PixelMap = await this.getPhotoPixelMap(photo);
        Logger.info(TAG_LOG, '使用降级方案：重新获取原始图像');
        return fallbackPixelMap;
      } catch (fallbackError) {
        Logger.error(TAG_LOG, `降级处理也失败: ${fallbackError instanceof Error ? fallbackError.message : String(fallbackError)}`);
        throw new Error('水印处理完全失败');
      }
    } finally {
      if (watermarkPixelMap) {
        watermarkPixelMap.release();
      }
    }
  }

  // 获取照片的PixelMap
  private async getPhotoPixelMap(photo: camera.Photo): Promise<image.PixelMap> {
    const imageObj: image.Image = photo.main;
    let imageSource: image.ImageSource | null = null;
    
    try {
      const component: image.Component = await new Promise<image.Component>((resolve, reject) => {
        imageObj.getComponent(image.ComponentType.JPEG, (err, comp) => {
          err ? reject(err) : comp ? resolve(comp) : reject(new Error('Failed to get image component'));
        });
      });
      
      imageSource = image.createImageSource(component.byteBuffer);
      
      const pixelMap: image.PixelMap = await imageSource.createPixelMap({
        desiredSize: { width: 0, height: 0 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      });
      
      return pixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `获取照片PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法获取照片数据');
    } finally {
      if (imageSource) {
        imageSource.release();
      }
    }
  }

  // 创建水印PixelMap
  private async createWatermarkPixelMap(watermarkInfo: WatermarkInfo, originalPixelMap: image.PixelMap, displayInfo: display.Display): Promise<image.PixelMap> {
    try {
      const imageInfo = await originalPixelMap.getImageInfo();
      const photoWidth = imageInfo.size.width;
      const photoHeight = imageInfo.size.height;
      const pixelRatio = displayInfo.densityPixels;
      
      // 调试信息：原始照片尺寸和设备像素比
      Logger.debug(TAG_LOG, `原始照片尺寸: ${photoWidth}×${photoHeight}, 设备像素比: ${pixelRatio}`);
      
      const watermarkWidth = Math.round(photoWidth * this.WATERMARK_WIDTH_RATIO / pixelRatio);
      const watermarkHeight = Math.round(photoHeight * this.WATERMARK_HEIGHT_RATIO / pixelRatio);

      // 调试信息：计算后的水印尺寸和比例参数
      Logger.debug(TAG_LOG, `水印尺寸计算: 宽度=${watermarkWidth} (${photoWidth} × ${this.WATERMARK_WIDTH_RATIO} / ${pixelRatio})`);
      Logger.debug(TAG_LOG, `水印尺寸计算: 高度=${watermarkHeight} (${photoHeight} × ${this.WATERMARK_HEIGHT_RATIO} / ${pixelRatio})`);

      const offscreenCanvas = new OffscreenCanvas(watermarkWidth, watermarkHeight);
      const context2d = offscreenCanvas.getContext('2d');
      
      if (!context2d) {
        throw new Error('无法获取Canvas上下文');
      }

      await this.drawWatermarkWithCanvas(context2d as OffscreenCanvasRenderingContext2D, watermarkInfo, watermarkWidth, watermarkHeight);

      const watermarkPixelMap: image.PixelMap = await (context2d as OffscreenCanvasRenderingContext2D).getPixelMap(0, 0, watermarkWidth, watermarkHeight);

      return watermarkPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `创建水印PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法创建水印');
    }
  }

  // 使用Canvas绘制水印内容
  private async drawWatermarkWithCanvas(context2d: OffscreenCanvasRenderingContext2D, 
                                       watermarkInfo: WatermarkInfo, 
                                       canvasWidth: number , 
                                       canvasHeight: number ): Promise<void> {
    // 调试信息：计划绘制的尺寸
    Logger.debug(TAG_LOG, `计划绘制画布尺寸: ${canvasWidth}×${canvasHeight}`);
    
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
    const orgForKey = watermarkInfo.organization || '应急管理部门';
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

      Logger.debug(TAG_LOG, `值渲染完成: 行数=${metrics.infoItemsCount}, 行高=${metrics.itemHeight.toFixed(1)}px, 列宽=${metrics.maxLabelWidth.toFixed(1)}px`);
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
    try {
      const watermarkLogo = await this.loadWatermarkLogo();
      if (watermarkLogo) {
        const logoInfo = await watermarkLogo.getImageInfo();
        const maxLogoWidth = topRectWidth - DOUBLE_MARGIN;
        const maxLogoHeight = topRectHeight - DOUBLE_MARGIN;
        const widthRatio = maxLogoWidth / logoInfo.size.width;
        const heightRatio = maxLogoHeight / logoInfo.size.height;
        const scaleRatio = Math.min(widthRatio, heightRatio);
        const logoWidth = logoInfo.size.width * scaleRatio;
        const logoHeight = logoInfo.size.height * scaleRatio;
        const logoX = topRectX + MARGIN;
        const logoY = topRectY + (topRectHeight - logoHeight) / 2;
        ctx.drawImage(watermarkLogo as image.PixelMap, logoX, logoY, logoWidth, logoHeight);
        watermarkLogo.release();

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
      }
    } catch (error) {
      Logger.warn(TAG_LOG, `静态底图Logo绘制失败: ${error instanceof Error ? error.message : String(error)}`);
    }

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
      const labelX = MARGIN;
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
      const orgValue = watermarkInfo.organization || '应急管理部门';
      ctx.fillText(orgValue, orgValueX, orgValueY, orgValueMaxWidth);
    }

    const pixelMap: image.PixelMap = await ctx.getPixelMap(0, 0, canvasWidth, canvasHeight);
    const entry: WatermarkBaseCacheEntry = { pixelMap: pixelMap, expiresAt: Date.now() + this.watermarkBaseCacheTTL, metrics: metrics };
    Logger.debug(TAG_LOG, `静态底图构建完成并缓存: ${canvasWidth}×${canvasHeight}`);
    return entry;
  }

  private getWatermarkInfoItems(watermarkInfo: WatermarkInfo): Array<WatermarkInfoItem> {
    return [
      { label: '拍摄时间', value: watermarkInfo.timestamp },
      { label: '天气信息', value: watermarkInfo.weather || '获取中...' },
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
      const watermarkX = 0;
      const watermarkY = Math.max(targetHeight - watermarkHeight, 0);

      await this.blendWatermark(originalPixelMap, watermarkPixelMap, watermarkX, watermarkY);
      return originalPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `图像合成失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法合成图像');
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
      
      const targetBuffer = new ArrayBuffer(blendWidth * blendHeight * 4);
      const targetArea: image.PositionArea = {
        pixels: targetBuffer,
        offset: 0,
        stride: blendWidth * 4,
        region: { size: { width: blendWidth, height: blendHeight }, x: startX, y: startY }
      };
      await targetPixelMap.readPixels(targetArea);
      const targetView = new Uint8Array(targetBuffer);

      const watermarkBuffer = new ArrayBuffer(blendWidth * blendHeight * 4);
      const watermarkArea: image.PositionArea = {
        pixels: watermarkBuffer,
        offset: 0,
        stride: blendWidth * 4,
        region: { size: { width: blendWidth, height: blendHeight }, x: startX - x, y: startY - y }
      };
      await watermarkPixelMap.readPixels(watermarkArea);
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
      await targetPixelMap.writePixels(writeArea);
    } catch (error) {
      Logger.error(TAG_LOG, `水印混合失败: ${error instanceof Error ? error.message : String(error)}`);
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
      const ctx = this.context as common.UIAbilityContext;
      const resourceManager = ctx.resourceManager;
      const imageBuffer: Uint8Array = await resourceManager.getMediaContent($r('app.media.watermark_logo'));
      const imageSource: image.ImageSource = image.createImageSource(imageBuffer.buffer);
      const pixelMap: image.PixelMap = await imageSource.createPixelMap();
      // 及时释放ImageSource资源
      imageSource.release();
      return pixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `加载水印徽章失败: ${error instanceof Error ? error.message : String(error)}`);
      return null;
    }
  }
}
