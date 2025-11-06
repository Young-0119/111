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
import { Logger } from 'commons';
import OutputManager, { CreateOutputConfig } from './OutputManager';
import CameraConstant from '../constants/CameraConstants';
import { RobustWatermarkProcessor, WatermarkInfo } from '../watermark/RobustWatermarkProcessor';

const TAG_LOG = 'PhotoManager';

export class PhotoManager implements OutputManager {
  output?: camera.PhotoOutput;
  isActive: boolean = true;
  context: Context;
  isSingle: boolean = false;
  location: geoLocationManager.Location | null = null;
  
  // 水印处理相关属性
  private robustProcessor: RobustWatermarkProcessor = RobustWatermarkProcessor.getInstance();
  private enableWatermark: boolean = true;
  
  private callback: (pixelMap: image.PixelMap, url: string) => void = () => {
  };

  constructor(context: Context, isActive = true, isSingle: boolean) {
    this.context = context;
    this.isActive = isActive;
    this.isSingle = isSingle;
    
    // 初始化水印处理器
    this.initializeWatermarkProcessors();
    
    // 初始化位置信息
    this.initializeLocation();
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
    try {
      // 使用稳定的水印处理器
      this.robustProcessor = RobustWatermarkProcessor.getInstance();
      Logger.info(TAG_LOG, '稳定水印处理器初始化成功');
    } catch (error) {
      Logger.error(TAG_LOG, `水印处理器初始化失败: ${JSON.stringify(error)}`);
    }
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
  setHighPerformanceMode(enabled: boolean): void {
    // 方法保留用于兼容性，实际不执行任何操作
    Logger.info(TAG_LOG, `高性能模式设置已废弃: ${enabled}`);
  }

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
  public createPhotoOutput(cameraManager: camera.CameraManager|undefined, cameraDevice: camera.CameraDevice,
    profile: camera.Profile) {
    let cameraPhotoOutput: camera.PhotoOutput | undefined = undefined;
    const cameraOutputCapability =
      cameraManager?.getSupportedOutputCapability(cameraDevice, camera.SceneMode.NORMAL_PHOTO);
    let photoProfilesArray: camera.Profile[] | undefined = cameraOutputCapability?.photoProfiles;
    if (photoProfilesArray?.length) {
      try {
        const displayRatio = profile.size.width / profile.size.height;
        const profileWidth = profile.size.width;
        
        // 优先选择2160×2880px分辨率（1080×1440px的2倍）
        const targetWidth = 2160;
        const targetHeight = 2880;
        
        const photoProfile = photoProfilesArray
          .filter(pf => {
            const pfDisplayRatio = pf.size.width / pf.size.height;
            return Math.abs(pfDisplayRatio - displayRatio) <= CameraConstant.PROFILE_DIFFERENCE &&
              pf.format === camera.CameraFormat.CAMERA_FORMAT_JPEG;
          })
          .sort((a, b) => {
            // 首先优先选择目标分辨率2160×2880px
            const aIsTarget = (a.size.width === targetWidth && a.size.height === targetHeight);
            const bIsTarget = (b.size.width === targetWidth && b.size.height === targetHeight);
            
            if (aIsTarget && !bIsTarget) return -1;
            if (!aIsTarget && bIsTarget) return 1;
            
            // 如果都不是目标分辨率，则按与目标分辨率的距离排序
            const aDistance = Math.abs(a.size.width - targetWidth) + Math.abs(a.size.height - targetHeight);
            const bDistance = Math.abs(b.size.width - targetWidth) + Math.abs(b.size.height - targetHeight);
            
            if (aDistance !== bDistance) {
              return aDistance - bDistance; // 升序，距离越小越优先
            }
            
            // 距离相同时，按总像素数排序（优先选择高分辨率）
            const aPixels = a.size.width * a.size.height;
            const bPixels = b.size.width * b.size.height;
            return bPixels - aPixels; // 降序，高分辨率优先
          })[0]; // 取第一个（最佳匹配）
          
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
  setPhotoOutputCbSingle(photoOutput: camera.PhotoOutput, context: Context) {
    photoOutput.on('photoAvailable', async (errCode: BusinessError, photo: camera.Photo): Promise<void> => {
      if (errCode || photo === undefined) {
        Logger.error(TAG_LOG, 'getPhoto failed');
        return;
      }
      
      // 检查是否启用水印
      if (this.enableWatermark) {
        await this.processPhotoWithWatermark(context, photo);
      } else {
        // 不使用水印，直接保存
        this.mediaLibSavePhotoSingle(context, photo.main);
      }
    });
  }

  // [End set_photo_cb_single]

  /**
   * 处理带水印的照片
   */
  private async processPhotoWithWatermark(context: Context, photo: camera.Photo): Promise<void> {
    try {
      Logger.info(TAG_LOG, '开始水印处理流程');
      
      // 获取水印信息
      const watermarkInfo: WatermarkInfo = await this.getWatermarkInfo();
      
      let savedUri: string;
      let processedPixelMap: image.PixelMap;
      
      // 优先使用稳定的水印处理器
      try {
        Logger.info(TAG_LOG, '使用稳定水印处理器');
        processedPixelMap = await this.robustProcessor.processWatermark(photo, watermarkInfo);
        
        // 保存处理后的图像
        savedUri = await this.savePixelMapToGallery(processedPixelMap, context);
        Logger.info(TAG_LOG, `稳定水印处理成功，保存路径: ${savedUri}`);
        
      } catch (robustError) {
        Logger.warn(TAG_LOG, `稳定水印处理失败: ${robustError instanceof Error ? robustError.message : String(robustError)}`);
        
        // 降级处理：直接保存原图
        throw new Error('水印处理器不可用，保存原图');
      }
      
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
    
    return {
      timestamp,
      weather: await this.getWeatherInfo(),
      location: await this.getLocationInfo(),
      altitude: await this.getAltitudeInfo(),
      direction: await this.getDirectionInfo(),
      longitude: this.location?.longitude?.toString() || '获取中...',
      latitude: this.location?.latitude?.toString() || '获取中...',
      organization: '应急管理部门'
    };
  }

  /**
   * 从Photo对象创建PixelMap
   */
  private async createPixelMapFromPhoto(photo: camera.Photo): Promise<image.PixelMap> {
    const imageObj: image.Image = photo.main;
    
    const component: image.Component = await new Promise<image.Component>((resolve, reject) => {
      imageObj.getComponent(image.ComponentType.JPEG, (err, comp) => {
        if (err || !comp) {
          reject(err || new Error('Failed to get image component'));
        } else {
          resolve(comp);
        }
      });
    });
    
    const imageSource: image.ImageSource = image.createImageSource(component.byteBuffer);
    
    try {
      const pixelMap: image.PixelMap = await imageSource.createPixelMap({
        desiredSize: { width: 0, height: 0 },
        desiredRegion: { size: { width: 0, height: 0 }, x: 0, y: 0 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      });
      
      return pixelMap;
    } finally {
      imageSource.release();
    }
  }

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
   * 保存PixelMap到相册
   */
  async savePixelMapToGallery(pixelMap: image.PixelMap, context: Context): Promise<string> {
    try {
      // 将PixelMap转换为JPEG格式的ArrayBuffer
      const imagePackerApi = image.createImagePacker();
      
      // 优化压缩参数以提升图像质量
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: 98, // 提升质量到98%，确保高质量输出
        desiredDynamicRange: image.PackingDynamicRange.AUTO // 自动HDR处理
      };
      
      const buffer: ArrayBuffer = await imagePackerApi.packing(pixelMap, packOpts);
      imagePackerApi.release();
      
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

  public setFocusPoint(photoSession: camera.PhotoSession, focusPoint: camera.Point): void {
    try {
      photoSession.setFocusPoint(focusPoint);
    } catch (error) {
      Logger.error(TAG_LOG, `The setFocusPoint call failed. error code: ${error.code}`);
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
        Logger.error(TAG_LOG, `Failed to get the zoom ratio range. error: ${JSON.stringify(error)}`);
      }
    }
    try {
      photoSession.setZoomRatio(zoomRatio || photoZoomRatio);
    } catch (exception) {
      Logger.error(TAG_LOG, `setZoomRatio failed, code is ${exception.code}, message is ${exception.message}`);
    }
  }

  getSupportedColorSpaces(session: camera.PhotoSession): Array<colorSpaceManager.ColorSpace> {
    let colorSpaces: Array<colorSpaceManager.ColorSpace> = [];
    try {
      colorSpaces = session.getSupportedColorSpaces();
    } catch (error) {
      Logger.error(TAG_LOG, `The getSupportedColorSpaces call failed. error code: ${error.code}`);
    }
    return colorSpaces;
  }

  // [Start get_photo_rotation]
  // Get photo rotation
  getPhotoRotation(photoOutput: camera.PhotoOutput, deviceDegree: number): camera.ImageRotation {
    let photoRotation: camera.ImageRotation = camera.ImageRotation.ROTATION_0;
    try {
      photoRotation = photoOutput.getPhotoRotation(deviceDegree);
    } catch (error) {
      Logger.error(TAG_LOG, `The photoOutput.getPhotoRotation call failed. error code: ${error.code}`);
    }
    return photoRotation;
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
      try {
        sensor.once(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
          let degree = this.calculateDeviceDegree(data.x, data.y, data.z);
          resolve(degree);
        });
      } catch (exception) {
        Logger.error(TAG_LOG, `getPhotoDegree failed, code is ${exception.code}, message is ${exception.message}`);
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
  async release() {
    try {
      await this.output?.release();
    } catch (exception) {
      Logger.error(TAG_LOG, `release failed, code is ${exception.code}, message is ${exception.message}`);
    }
    
    // 清理水印处理器资源
    try {
      // RobustWatermarkProcessor是单例，无需显式销毁
      Logger.info(TAG_LOG, '水印处理器资源已清理');
    } catch (error) {
      Logger.error(TAG_LOG, `清理水印处理器失败: ${JSON.stringify(error)}`);
    }
    
    if (this.isSingle) {
      this.output?.off('photoAvailable');
    } else {
      this.output?.off('photoAssetAvailable');
    }
    this.output = undefined;
  }

  /**
   * 初始化位置信息
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
}
