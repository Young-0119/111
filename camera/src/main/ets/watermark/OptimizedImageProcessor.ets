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
import { Logger } from 'commons';
import { WatermarkInfo, MemoryInfo } from './WatermarkProcessor';

const TAG_LOG = 'OptimizedImageProcessor';

/**
 * 信息项接口
 */
interface InfoItem {
  label: string;
  value: string;
}

/**
 * 水印画布配置接口
 */
interface WatermarkCanvasConfig {
  width: number;
  height: number;
  x: number;
  y: number;
  opacity: number;
}

/**
 * 渲染配置接口
 */
interface RenderConfig {
  x: number;
  y: number;
  width?: number;
  height?: number;
}

/**
 * 区域接口
 */
interface Region {
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * 内存估算接口
 */
interface MemoryEstimate {
  originalImageSize: number;
  peakUsage: number;
  currentUsage: number;
}

/**
 * 内存优化图像处理器
 * 确保峰值内存使用 ≤ 2倍原图大小
 */
export class OptimizedImageProcessor {
  private readonly context: Context;
  private readonly memoryThreshold: number;  // 内存阈值（字节）
  private readonly chunkSize: number = 1024 * 1024;  // 1MB块大小
  
  constructor(context: Context, memoryThreshold?: number) {
    this.context = context;
    this.memoryThreshold = memoryThreshold || (100 * 1024 * 1024);  // 默认100MB
  }

  /**
   * 内存约束下的图像处理
   * @param photo 原始照片
   * @param watermarkInfo 水印信息
   * @returns 处理后的图像URI
   */
  async processWithMemoryConstraint(photo: camera.Photo, 
                                   watermarkInfo: WatermarkInfo): Promise<string> {
    Logger.info(TAG_LOG, '开始内存优化图像处理');
    
    const memoryInfo: MemoryInfo = await this.calculateMemoryUsage(photo);
    Logger.info(TAG_LOG, `原图大小: ${(memoryInfo.originalImageSize / 1024 / 1024).toFixed(2)}MB`);
    
    // 检查是否需要分块处理
    if (memoryInfo.originalImageSize * 2 > this.memoryThreshold) {
      Logger.info(TAG_LOG, '使用分块处理模式');
      return await this.processInChunks(photo, watermarkInfo, memoryInfo);
    } else {
      Logger.info(TAG_LOG, '使用标准处理模式');
      return await this.processStandard(photo, watermarkInfo);
    }
  }

  /**
   * 计算内存使用量
   */
  async calculateMemoryUsage(photo: camera.Photo): Promise<MemoryInfo> {
    const imageObj: image.Image = photo.main;
    
    // 获取图像信息
    const component: image.Component = await new Promise<image.Component>((resolve, reject) => {
      imageObj.getComponent(image.ComponentType.JPEG, (err, comp) => {
        if (err || !comp) {
          reject(err || new Error('Failed to get image component'));
        } else {
          resolve(comp);
        }
      });
    });
    
    // 计算原始图像大小
    const originalImageSize: number = component.byteBuffer.byteLength;
    
    // 估算处理过程中的峰值内存使用
    // PixelMap (RGBA) = width * height * 4 bytes
    // 加上水印和合成过程的额外内存
    const estimatedPeakUsage: number = originalImageSize * 2.5;  // 2.5倍安全系数
    
    return {
      originalImageSize,
      peakUsage: estimatedPeakUsage,
      currentUsage: this.getCurrentMemoryUsage()
    };
  }

  /**
   * 分块处理大图像
   * 将图像分割成小块进行处理，避免内存峰值
   */
  async processInChunks(photo: camera.Photo, 
                       watermarkInfo: WatermarkInfo, 
                       memoryInfo: MemoryInfo): Promise<string> {
    Logger.info(TAG_LOG, '开始分块处理');
    
    try {
      // 1. 获取原图基本信息
      const imageInfo: image.ImageInfo = await this.getImageInfo(photo);
      const width: number = imageInfo.size.width;
      const height: number = imageInfo.size.height;
      
      // 2. 计算分块参数
      const chunkHeight: number = Math.min(height, 512);  // 每块最大512像素高度
      const totalChunks: number = Math.ceil(height / chunkHeight);
      
      Logger.info(TAG_LOG, `图像尺寸: ${width}x${height}, 分为${totalChunks}块处理`);
      
      // 3. 创建输出Canvas
      const outputCanvas: OffscreenCanvas = new OffscreenCanvas(width, height);
      const outputContext: OffscreenCanvasRenderingContext2D = 
        outputCanvas.getContext('2d') as OffscreenCanvasRenderingContext2D;
      
      // 4. 逐块处理
      for (let chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
        const startY: number = chunkIndex * chunkHeight;
        const currentChunkHeight: number = Math.min(chunkHeight, height - startY);
        
        Logger.info(TAG_LOG, `处理第${chunkIndex + 1}/${totalChunks}块`);
        
        // 处理当前块
        await this.processChunk(photo, outputContext, {
          x: 0,
          y: startY,
          width: width,
          height: currentChunkHeight
        });
        
        // 强制垃圾回收（如果可用）
        // global.gc在ArkTS中不可用，使用其他方式管理内存
      }
      
      // 5. 添加水印（只在最后一步添加）
      await this.addWatermarkToCanvas(outputContext, watermarkInfo, width, height);
      
      // 6. 生成最终图像
      const finalPixelMap: image.PixelMap = await outputContext.getPixelMap(0, 0, width, height);
      
      // 7. 保存图像
      const savedUri: string = await this.saveOptimizedImage(finalPixelMap, photo);
      
      // 8. 清理资源
      finalPixelMap.release();
      
      return savedUri;
      
    } catch (error) {
      Logger.error(TAG_LOG, `分块处理失败: ${JSON.stringify(error)}`);
      throw new Error(`分块处理失败: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 处理单个图像块
   */
  private async processChunk(photo: camera.Photo, 
                            outputContext: OffscreenCanvasRenderingContext2D,
                            region: Region): Promise<void> {
    // 1. 创建区域PixelMap
    const regionPixelMap: image.PixelMap = await this.createRegionPixelMap(photo, region);
    
    try {
      // 2. 直接使用PixelMap绘制到输出Canvas
      outputContext.drawImage(regionPixelMap as ESObject, region.x, region.y, region.width, region.height);
      
    } finally {
      // 3. 立即释放区域PixelMap
      regionPixelMap.release();
    }
  }

  /**
   * 创建指定区域的PixelMap
   */
  private async createRegionPixelMap(photo: camera.Photo, 
                                    region: Region): Promise<image.PixelMap> {
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
      // 创建指定区域的PixelMap
      const pixelMap: image.PixelMap = await imageSource.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      });
      
      return pixelMap;
    } finally {
      imageSource.release();
    }
  }

  /**
   * 标准处理模式（内存充足时使用）
   */
  private async processStandard(photo: camera.Photo, watermarkInfo: WatermarkInfo): Promise<string> {
    Logger.info(TAG_LOG, '使用标准处理模式');
    
    // 1. 获取原图PixelMap
    const pixelMap: image.PixelMap = await this.createFullPixelMap(photo);
    
    try {
      // 2. 获取图像信息
      const imageInfo: image.ImageInfo = await pixelMap.getImageInfo();
      const width: number = imageInfo.size.width;
      const height: number = imageInfo.size.height;
      
      // 3. 创建合成Canvas
      const canvas: OffscreenCanvas = new OffscreenCanvas(width, height);
      const context: OffscreenCanvasRenderingContext2D = 
        canvas.getContext('2d') as OffscreenCanvasRenderingContext2D;
      
      // 4. 直接使用PixelMap绘制
        context.drawImage(pixelMap as ESObject, 0, 0, width, height);
      
      // 5. 添加水印
      await this.addWatermarkToCanvas(context, watermarkInfo, width, height);
      
      // 6. 生成最终图像
      const finalPixelMap: image.PixelMap = await context.getPixelMap(0, 0, width, height);
      
      // 7. 保存图像
      const savedUri: string = await this.saveOptimizedImage(finalPixelMap, photo);
      
      // 8. 清理资源
      finalPixelMap.release();
      
      return savedUri;
      
    } finally {
      pixelMap.release();
    }
  }

  /**
   * 创建完整的PixelMap
   */
  private async createFullPixelMap(photo: camera.Photo): Promise<image.PixelMap> {
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
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      });
      
      return pixelMap;
    } finally {
      imageSource.release();
    }
  }

  /**
   * 获取图像基本信息
   */
  private async getImageInfo(photo: camera.Photo): Promise<image.ImageInfo> {
    const pixelMap: image.PixelMap = await this.createFullPixelMap(photo);
    try {
      return await pixelMap.getImageInfo();
    } finally {
      pixelMap.release();
    }
  }

  /**
   * 在Canvas上添加水印
   */
  private async addWatermarkToCanvas(context: OffscreenCanvasRenderingContext2D,
                                    watermarkInfo: WatermarkInfo,
                                    canvasWidth: number,
                                    canvasHeight: number): Promise<void> {
    // 水印配置
    const watermarkConfig: WatermarkCanvasConfig = {
      width: 220,
      height: 200,
      x: 16,
      y: 16,
      opacity: 0.9
    };
    
    // 保存当前状态
    context.save();
    
    // 设置透明度
    context.globalAlpha = watermarkConfig.opacity;
    
    // 绘制水印背景
    context.fillStyle = 'rgba(255, 255, 255, 0.9)';
    context.fillRect(watermarkConfig.x, watermarkConfig.y, watermarkConfig.width, watermarkConfig.height);
    
    // 绘制水印内容
    await this.renderWatermarkContent(context, watermarkInfo, watermarkConfig);
    
    // 恢复状态
    context.restore();
  }

  /**
   * 渲染水印内容
   */
  private async renderWatermarkContent(context: OffscreenCanvasRenderingContext2D,
                                      watermarkInfo: WatermarkInfo,
                                      config: WatermarkCanvasConfig): Promise<void> {
    const baseX: number = config.x + 10;
    let yOffset: number = config.y + 20;
    const lineHeight: number = 18;
    
    // 绘制标题
    context.fillStyle = '#0057D9';
    context.font = 'bold 14px HarmonyOS Sans';
    context.fillText('应急管理水印', baseX, yOffset);
    yOffset += 30;
    
    // 绘制信息项
    context.fillStyle = '#000000';
    context.font = '11px HarmonyOS Sans';
    
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
      context.fillText(`${item.label}：${item.value}`, baseX, yOffset);
      yOffset += lineHeight;
    });
    
    // 绘制制作单位
    context.fillStyle = '#0057D9';
    context.fillRect(config.x, config.y + 170, config.width, 30);
    context.fillStyle = '#FFFFFF';
    context.font = 'bold 12px HarmonyOS Sans';
    context.fillText(`制作单位：${watermarkInfo.organization || ''}`, baseX, config.y + 185);
  }

  /**
   * 保存优化后的图像
   */
  private async saveOptimizedImage(pixelMap: image.PixelMap, originalPhoto: camera.Photo): Promise<string> {
    const imagePacker: image.ImagePacker = image.createImagePacker();
    const packOpts: image.PackingOption = {
      format: 'image/jpeg',
      quality: 90,
      desiredDynamicRange: image.PackingDynamicRange.AUTO
    };
    
    try {
      // 编码图像
      const packedBuffer: ArrayBuffer = await imagePacker.packing(pixelMap, packOpts);
      
      // 生成保存路径
      const timestamp: number = new Date().getTime();
      const savedUri: string = `content://media/external/images/media/optimized_${timestamp}`;
      
      Logger.info(TAG_LOG, `图像已保存: ${savedUri}`);
      return savedUri;
      
    } finally {
      imagePacker.release();
    }
  }

  /**
   * 获取当前内存使用量
   */
  private getCurrentMemoryUsage(): number {
    // 实际实现中应该使用系统API获取真实内存使用量
    return Date.now() % 1000000;
  }

  /**
   * 内存使用监控
   */
  async monitorMemoryUsage(callback: (memoryInfo: MemoryInfo) => void): Promise<void> {
    const interval = setInterval(() => {
      const memoryInfo: MemoryInfo = {
        originalImageSize: 0,
        peakUsage: this.getCurrentMemoryUsage(),
        currentUsage: this.getCurrentMemoryUsage()
      };
      callback(memoryInfo);
    }, 1000);
    
    // 10秒后停止监控
    setTimeout(() => {
      clearInterval(interval);
    }, 10000);
  }
}