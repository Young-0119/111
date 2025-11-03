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

import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { Logger } from 'commons';

const TAG_LOG = 'WatermarkProcessor';

/**
 * 信息项接口
 */
interface InfoItem {
  label: string;
  value: string;
}

/**
 * 绘制配置接口
 */
interface DrawConfig {
  backgroundColor: string;
  textColor: string;
  fontSize: number;
  fontFamily: string;
}

/**
 * 位置接口
 */
interface Position {
  x: number;
  y: number;
}

/**
 * 水印样式配置接口
 */
interface WatermarkStyleConfig {
  fontSize: number;
  fontFamily: string;
  textColor: string;
  backgroundColor: string;
  padding: number;
  borderRadius: number;
  position: Position;
}

// 严格类型定义 - 符合ArkTS规范
export interface WatermarkProcessConfig {
  readonly enabled: boolean;
  readonly quality: number;  // 1-100
  readonly position: 'top-left' | 'top-right' | 'bottom-left' | 'bottom-right';
  readonly opacity: number;  // 0-1
  readonly scale: number;    // 0.5-2.0
  readonly rotation: number; // 0-360度
}

export interface WatermarkInfo {
  readonly timestamp: string;
  readonly weather?: string;
  readonly location?: string;
  readonly altitude?: string;
  readonly direction?: string;
  readonly longitude?: string;
  readonly latitude?: string;
  readonly organization?: string;
}

export interface PerformanceMetrics {
  readonly startTime: number;
  readonly endTime: number;
  readonly memoryUsage: number;
  readonly processingTime: number;
}

export interface MemoryInfo {
  readonly peakUsage: number;
  readonly currentUsage: number;
  readonly originalImageSize: number;
}

/**
 * 水印处理核心类 - 严格合规实现
 * 完全符合鸿蒙5.0官方开发规范
 */
export class WatermarkProcessor {
  private readonly context: Context;
  private readonly config: WatermarkProcessConfig;

  constructor(context: Context, config: WatermarkProcessConfig) {
    this.context = context;
    this.config = config;
  }

  /**
   * 水印处理主方法 - 无降级处理
   * @param photo 相机拍摄的照片对象
   * @param watermarkInfo 水印信息
   * @returns 保存后的图片URI
   */
  async processWatermark(photo: camera.Photo, watermarkInfo: WatermarkInfo): Promise<string> {
    const startTime: number = Date.now();
    Logger.info(TAG_LOG, '开始水印处理流程');

    try {
      // 1. 获取原始图像PixelMap
      const pixelMap: image.PixelMap = await this.getOriginalImagePixelMap(photo);
      
      // 2. 图像合成处理
      const compositePixelMap: image.PixelMap = await this.compositeImageWithWatermark(pixelMap, watermarkInfo);
      
      // 3. 保存合成图像
      const savedUri: string = await this.saveCompositeImage(compositePixelMap, photo);
      
      // 4. 严格资源管理
      pixelMap.release();
      compositePixelMap.release();
      
      const endTime: number = Date.now();
      Logger.info(TAG_LOG, `水印处理完成，耗时: ${(endTime - startTime).toFixed(2)}ms`);
      
      return savedUri;
    } catch (error) {
      Logger.error(TAG_LOG, `水印处理失败: ${JSON.stringify(error)}`);
      throw new Error(`水印处理失败: ${JSON.stringify(error)}`); // 严格错误处理，不进行降级
    }
  }

  /**
   * 从Photo对象获取原始图像PixelMap
   */
  private async getOriginalImagePixelMap(photo: camera.Photo): Promise<image.PixelMap> {
    const imageObj: image.Image = photo.main;
    
    // 获取图像组件
    const component: image.Component = await new Promise<image.Component>((resolve, reject) => {
      imageObj.getComponent(image.ComponentType.JPEG, (err, comp) => {
        if (err || !comp) {
          reject(err || new Error('Failed to get image component'));
        } else {
          resolve(comp);
        }
      });
    });
    
    // 创建ImageSource
    const imageSource: image.ImageSource = image.createImageSource(component.byteBuffer);
    
    try {
      // 创建PixelMap - 严格类型配置
      const pixelMap: image.PixelMap = await imageSource.createPixelMap({
        desiredSize: { width: 0, height: 0 },  // 保持原始尺寸
        desiredRegion: { size: { width: 0, height: 0 }, x: 0, y: 0 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,  // 标准RGBA格式
        editable: false  // 只读模式，提高性能
      });
      
      return pixelMap;
    } finally {
      // 及时释放ImageSource资源
      imageSource.release();
    }
  }

  /**
   * 图像与水印合成处理
   */
  private async compositeImageWithWatermark(originalPixelMap: image.PixelMap, 
                                           watermarkInfo: WatermarkInfo): Promise<image.PixelMap> {
    // 1. 获取原图尺寸
    const imageInfo: image.ImageInfo = await originalPixelMap.getImageInfo();
    const width = imageInfo.size.width;
    const height = imageInfo.size.height;
    
    // 2. 创建离屏Canvas
    const offscreenCanvas: OffscreenCanvas = new OffscreenCanvas(width, height);
    const offscreenContext: OffscreenCanvasRenderingContext2D = 
      offscreenCanvas.getContext('2d') as OffscreenCanvasRenderingContext2D;
    
    // 3. 直接使用PixelMap绘制
    offscreenContext.drawImage(originalPixelMap as ESObject, 0, 0, width, height);
    
    // 4. 叠加水印
    await this.renderWatermarkOnCanvas(offscreenContext, watermarkInfo, width, height);
    
    // 5. 生成最终PixelMap
    const compositePixelMap: image.PixelMap = await offscreenContext.getPixelMap(0, 0, width, height);
    
    return compositePixelMap;
  }

  /**
   * 在Canvas上渲染水印
   */
  private async renderWatermarkOnCanvas(context: OffscreenCanvasRenderingContext2D, 
                                       watermarkInfo: WatermarkInfo, 
                                       canvasWidth: number, 
                                       canvasHeight: number): Promise<void> {
    // 1. 设置水印基础样式
    const watermarkConfig: WatermarkStyleConfig = {
      fontSize: Math.min(canvasWidth, canvasHeight) * 0.03,  // 响应式字体大小
      fontFamily: 'HarmonyOS Sans',  // 鸿蒙系统字体
      textColor: '#FFFFFF',
      backgroundColor: 'rgba(0, 87, 217, 0.7)',  // 半透明蓝色背景
      padding: 8,
      borderRadius: 8,
      position: { x: 16, y: 16 } as Position  // 左上角定位
    };
    
    // 2. 绘制水印背景容器
    const watermarkWidth: number = 220;
    const watermarkHeight: number = 200;
    
    context.save();
    
    // 应用旋转和缩放变换（与WatermarkOverlay.ets保持一致）
    context.translate(watermarkConfig.position.x, watermarkConfig.position.y);
    context.scale(this.config.scale, this.config.scale);  // 使用配置的缩放比例
    context.rotate(this.config.rotation * Math.PI / 180);  // 使用配置的旋转角度
    
    // 绘制背景
    this.drawRoundedRect(context, 0, 0, watermarkWidth, watermarkHeight, 
                        watermarkConfig.borderRadius, 'rgba(255, 255, 255, 0.7)');
    
    // 3. 绘制水印内容
    await this.drawWatermarkContent(context, watermarkInfo, watermarkConfig);
    
    context.restore();
  }

  /**
   * 绘制圆角矩形背景
   */
  private drawRoundedRect(context: OffscreenCanvasRenderingContext2D, 
                         x: number, y: number, width: number, height: number, 
                         radius: number, fillStyle: string): void {
    context.beginPath();
    context.moveTo(x + radius, y);
    context.lineTo(x + width - radius, y);
    context.quadraticCurveTo(x + width, y, x + width, y + radius);
    context.lineTo(x + width, y + height - radius);
    context.quadraticCurveTo(x + width, y + height, x + width - radius, y + height);
    context.lineTo(x + radius, y + height);
    context.quadraticCurveTo(x, y + height, x, y + height - radius);
    context.lineTo(x, y + radius);
    context.quadraticCurveTo(x, y, x + radius, y);
    context.closePath();
    
    context.fillStyle = fillStyle;
    context.fill();
  }

  /**
   * 绘制具体水印内容
   */
  private async drawWatermarkContent(context: OffscreenCanvasRenderingContext2D, 
                                    watermarkInfo: WatermarkInfo, 
                                    config: WatermarkStyleConfig): Promise<void> {
    let yOffset: number = 20;
    const lineHeight: number = config.fontSize + 8;
    
    // 绘制标题栏（图标+标题）
    await this.drawTitleBar(context, yOffset, config);
    yOffset += 50;
    
    // 绘制信息行
    const infoItems: Array<InfoItem> = [
      { label: '拍摄时间', value: watermarkInfo.timestamp },
      { label: '天气信息', value: watermarkInfo.weather || '获取中...' },
      { label: '地点信息', value: watermarkInfo.location || '定位中...' },
      { label: '海拔信息', value: watermarkInfo.altitude || '计算中...' },
      { label: '方位角', value: watermarkInfo.direction || '计算中...' },
      { label: '经度', value: watermarkInfo.longitude || '计算中...' },
      { label: '纬度', value: watermarkInfo.latitude || '获取中...' }
    ];
    
    infoItems.forEach((item: InfoItem) => {
      this.drawInfoLine(context, item.label, item.value, yOffset, config);
      yOffset += lineHeight;
    });
    
    // 绘制制作单位（特殊样式）
    this.drawOrganizationLine(context, watermarkInfo.organization || '', yOffset, config);
  }

  /**
   * 绘制标题栏
   */
  private async drawTitleBar(context: OffscreenCanvasRenderingContext2D, 
                            yOffset: number, config: WatermarkStyleConfig): Promise<void> {
    // 绘制蓝色背景
    context.fillStyle = config.backgroundColor;
    context.fillRect(0, yOffset - 10, 220, 40);
    
    // 绘制标题文字
    context.fillStyle = config.textColor;
    context.font = `bold ${config.fontSize + 2}px ${config.fontFamily}`;
    context.fillText('应急管理水印', 70, yOffset + 15);
  }

  /**
   * 绘制信息行
   */
  private drawInfoLine(context: OffscreenCanvasRenderingContext2D, 
                      label: string, value: string, yOffset: number, config: WatermarkStyleConfig): void {
    context.fillStyle = '#000000';
    context.font = `${config.fontSize}px ${config.fontFamily}`;
    context.fillText(`${label}：${value}`, 8, yOffset);
  }

  /**
   * 绘制制作单位行（特殊样式）
   */
  private drawOrganizationLine(context: OffscreenCanvasRenderingContext2D, 
                              organization: string, yOffset: number, config: WatermarkStyleConfig): void {
    // 绘制蓝色背景
    context.fillStyle = config.backgroundColor;
    context.fillRect(0, yOffset - 8, 220, 24);
    
    // 绘制白色文字
    context.fillStyle = config.textColor;
    context.font = `bold ${config.fontSize}px ${config.fontFamily}`;
    context.fillText(`制作单位：${organization}`, 8, yOffset + 8);
  }

  /**
   * 保存合成后的图像
   */
  private async saveCompositeImage(compositePixelMap: image.PixelMap, 
                                  originalPhoto: camera.Photo): Promise<string> {
    // 1. 创建ImagePacker进行编码
    const imagePacker: image.ImagePacker = image.createImagePacker();
    const packOpts: image.PackingOption = {
      format: 'image/jpeg',
      quality: this.config.quality,  // 使用配置的质量设置
      desiredDynamicRange: image.PackingDynamicRange.AUTO  // 自动HDR处理
    };
    
    try {
      // 2. 编码为ArrayBuffer
      const packedBuffer: ArrayBuffer = await imagePacker.packing(compositePixelMap, packOpts);
      
      // 3. 创建媒体资产
      const photoType: photoAccessHelper.PhotoType = photoAccessHelper.PhotoType.IMAGE;
      const extension: string = 'jpg';
      const timestamp: number = new Date().getTime();
      const options: photoAccessHelper.CreateOptions = {
        title: `watermarked_photo_${timestamp}`
      };
      
      // 4. 保存到媒体库
      const assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest = 
        photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(this.context, photoType, extension, options);
      
      assetChangeRequest.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, packedBuffer);
      assetChangeRequest.saveCameraPhoto();  // 标记为相机照片
      
      // 5. 应用更改
      const accessHelper: photoAccessHelper.PhotoAccessHelper = 
        photoAccessHelper.getPhotoAccessHelper(this.context);
      await accessHelper.applyChanges(assetChangeRequest);
      
      // 6. 获取保存路径
      const savedUri: string = assetChangeRequest.getAsset().uri;
      
      // 7. 清理资源
      accessHelper.release();
      
      return savedUri;
    } finally {
      // 确保ImagePacker被释放
      imagePacker.release();
    }
  }
}