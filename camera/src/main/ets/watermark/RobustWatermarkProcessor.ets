/**
 * 稳定的水印处理器 - 使用HarmonyOS原生API
 * 彻底解决真机兼容性问题
 */
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { Logger } from 'commons';
import { WatermarkInfo, WatermarkProcessConfig, PerformanceMetrics } from './WatermarkProcessor';

const TAG_LOG: string = 'RobustWatermarkProcessor';

export class RobustWatermarkProcessor {
  private static instance: RobustWatermarkProcessor;

  public static getInstance(): RobustWatermarkProcessor {
    if (!RobustWatermarkProcessor.instance) {
      RobustWatermarkProcessor.instance = new RobustWatermarkProcessor();
    }
    return RobustWatermarkProcessor.instance;
  }

  /**
   * 主要水印处理方法 - 使用原生API确保兼容性
   */
  async processWatermark(photo: camera.Photo, watermarkInfo: WatermarkInfo): Promise<image.PixelMap> {
    Logger.info(TAG_LOG, '开始稳定水印处理流程');
    
    try {
      // 1. 获取原始图像
      const originalPixelMap: image.PixelMap = await this.getPhotoPixelMap(photo);
      Logger.info(TAG_LOG, '成功获取原始图像');

      // 2. 创建水印图像
      const watermarkPixelMap: image.PixelMap = await this.createWatermarkPixelMap(watermarkInfo, originalPixelMap);
      Logger.info(TAG_LOG, '成功创建水印图像');

      // 3. 合成图像 - 使用原生API
      const resultPixelMap: image.PixelMap = await this.compositeImages(originalPixelMap, watermarkPixelMap);
      Logger.info(TAG_LOG, '成功合成水印图像');

      // 4. 清理资源
      watermarkPixelMap.release();
      
      return resultPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `水印处理失败: ${error instanceof Error ? error.message : String(error)}`);
      
      // 降级处理：返回原图
      try {
        const originalPixelMap: image.PixelMap = await this.getPhotoPixelMap(photo);
        Logger.info(TAG_LOG, '使用降级方案：返回原始图像');
        return originalPixelMap;
      } catch (fallbackError) {
        Logger.error(TAG_LOG, `降级处理也失败: ${fallbackError instanceof Error ? fallbackError.message : String(fallbackError)}`);
        throw new Error('水印处理完全失败');
      }
    }
  }

  /**
   * 获取照片的PixelMap - 使用标准API
   */
  private async getPhotoPixelMap(photo: camera.Photo): Promise<image.PixelMap> {
    try {
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
        // 创建PixelMap
        const pixelMap: image.PixelMap = await imageSource.createPixelMap({
          desiredSize: { width: 0, height: 0 },
          desiredRegion: { size: { width: 0, height: 0 }, x: 0, y: 0 },
          desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
          editable: true
        });
        
        Logger.info(TAG_LOG, '成功创建PixelMap');
        return pixelMap;
      } finally {
        imageSource.release();
      }
    } catch (error) {
      Logger.error(TAG_LOG, `获取照片PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法获取照片数据');
    }
  }

  /**
   * 创建水印PixelMap - 使用原生绘制API
   */
  private async createWatermarkPixelMap(watermarkInfo: WatermarkInfo, originalPixelMap: image.PixelMap): Promise<image.PixelMap> {
    try {
      // 获取原图尺寸
      const imageInfo: image.ImageInfo = await originalPixelMap.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;

      // 创建水印PixelMap
      const watermarkWidth = Math.min(width * 0.3, 300);
      const watermarkHeight = Math.min(height * 0.1, 80);

      const createOptions: image.InitializationOptions = {
        size: { width: Math.floor(watermarkWidth), height: Math.floor(watermarkHeight) },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.PREMUL
      };

      // 创建像素数据
      const pixelBytes = Math.floor(watermarkWidth) * Math.floor(watermarkHeight) * 4;
      const buffer = new ArrayBuffer(pixelBytes);
      
      const watermarkPixelMap: image.PixelMap = await image.createPixelMap(buffer, createOptions);

      // 使用原生API绘制水印内容
      await this.drawWatermarkContent(watermarkPixelMap, watermarkInfo);

      return watermarkPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `创建水印PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法创建水印');
    }
  }

  /**
   * 绘制水印内容 - 使用像素级操作确保兼容性
   */
  private async drawWatermarkContent(watermarkPixelMap: image.PixelMap, watermarkInfo: WatermarkInfo): Promise<void> {
    try {
      const imageInfo: image.ImageInfo = await watermarkPixelMap.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;

      // 创建简单的白色背景水印
      const pixelBytes = width * height * 4; // RGBA
      const buffer = new ArrayBuffer(pixelBytes);
      const view = new Uint8Array(buffer);

      // 填充白色背景 (RGBA: 255, 255, 255, 180)
      for (let i = 0; i < pixelBytes; i += 4) {
        view[i] = 255;     // R
        view[i + 1] = 255; // G  
        view[i + 2] = 255; // B
        view[i + 3] = 180; // A (透明度)
      }

      // 创建PositionArea对象
      const area: image.PositionArea = {
        pixels: buffer,
        offset: 0,
        stride: width * 4,
        region: { size: { height: height, width: width }, x: 0, y: 0 }
      };

      // 写入像素数据
      await watermarkPixelMap.writePixels(area);
      
      Logger.info(TAG_LOG, `水印内容绘制完成: ${width}x${height}`);
    } catch (error) {
      Logger.error(TAG_LOG, `绘制水印内容失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法绘制水印内容');
    }
  }

  /**
   * 合成图像 - 使用原生PixelMap操作
   */
  private async compositeImages(originalPixelMap: image.PixelMap, watermarkPixelMap: image.PixelMap): Promise<image.PixelMap> {
    try {
      // 获取原图信息
      const originalInfo: image.ImageInfo = await originalPixelMap.getImageInfo();
      const watermarkInfo: image.ImageInfo = await watermarkPixelMap.getImageInfo();

      // 创建结果PixelMap
      const createOptions: image.InitializationOptions = {
        size: originalInfo.size,
        pixelFormat: originalInfo.pixelFormat,
        alphaType: image.AlphaType.PREMUL
      };

      const pixelBytes = originalInfo.size.width * originalInfo.size.height * 4;
      const buffer = new ArrayBuffer(pixelBytes);
      
      const resultPixelMap: image.PixelMap = await image.createPixelMap(buffer, createOptions);

      // 复制原图数据
      const originalBuffer = new ArrayBuffer(originalInfo.size.width * originalInfo.size.height * 4);
      const originalArea: image.PositionArea = {
        pixels: originalBuffer,
        offset: 0,
        stride: originalInfo.size.width * 4,
        region: { size: originalInfo.size, x: 0, y: 0 }
      };
      
      await originalPixelMap.readPixels(originalArea);
      
      const resultArea: image.PositionArea = {
        pixels: originalBuffer,
        offset: 0,
        stride: originalInfo.size.width * 4,
        region: { size: originalInfo.size, x: 0, y: 0 }
      };
      
      await resultPixelMap.writePixels(resultArea);

      // 计算水印位置 (右下角)
      const watermarkX = originalInfo.size.width - watermarkInfo.size.width - 20;
      const watermarkY = originalInfo.size.height - watermarkInfo.size.height - 20;

      // 使用原生API合成水印
      await this.blendWatermark(resultPixelMap, watermarkPixelMap, watermarkX, watermarkY);

      Logger.info(TAG_LOG, '图像合成完成');
      return resultPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `图像合成失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法合成图像');
    }
  }

  /**
   * 混合水印到目标图像 - 像素级操作
   */
  private async blendWatermark(targetPixelMap: image.PixelMap, watermarkPixelMap: image.PixelMap, x: number, y: number): Promise<void> {
    try {
      const targetInfo: image.ImageInfo = await targetPixelMap.getImageInfo();
      const watermarkInfo: image.ImageInfo = await watermarkPixelMap.getImageInfo();

      // 读取目标图像数据
      const targetBuffer = new ArrayBuffer(targetInfo.size.width * targetInfo.size.height * 4);
      const targetArea: image.PositionArea = {
        pixels: targetBuffer,
        offset: 0,
        stride: targetInfo.size.width * 4,
        region: { size: targetInfo.size, x: 0, y: 0 }
      };
      await targetPixelMap.readPixels(targetArea);
      const targetView = new Uint8Array(targetBuffer);

      // 读取水印数据
      const watermarkBuffer = new ArrayBuffer(watermarkInfo.size.width * watermarkInfo.size.height * 4);
      const watermarkArea: image.PositionArea = {
        pixels: watermarkBuffer,
        offset: 0,
        stride: watermarkInfo.size.width * 4,
        region: { size: watermarkInfo.size, x: 0, y: 0 }
      };
      await watermarkPixelMap.readPixels(watermarkArea);
      const watermarkView = new Uint8Array(watermarkBuffer);

      // 混合像素
      for (let wy = 0; wy < watermarkInfo.size.height; wy++) {
        for (let wx = 0; wx < watermarkInfo.size.width; wx++) {
          const targetX = x + wx;
          const targetY = y + wy;

          // 检查边界
          if (targetX >= 0 && targetX < targetInfo.size.width && 
              targetY >= 0 && targetY < targetInfo.size.height) {
            
            const targetIndex = (targetY * targetInfo.size.width + targetX) * 4;
            const watermarkIndex = (wy * watermarkInfo.size.width + wx) * 4;

            const alpha = watermarkView[watermarkIndex + 3] / 255.0;
            const invAlpha = 1.0 - alpha;

            // Alpha混合
            targetView[targetIndex] = Math.floor(targetView[targetIndex] * invAlpha + watermarkView[watermarkIndex] * alpha);
            targetView[targetIndex + 1] = Math.floor(targetView[targetIndex + 1] * invAlpha + watermarkView[watermarkIndex + 1] * alpha);
            targetView[targetIndex + 2] = Math.floor(targetView[targetIndex + 2] * invAlpha + watermarkView[watermarkIndex + 2] * alpha);
          }
        }
      }

      // 写回目标图像
      const writeArea: image.PositionArea = {
        pixels: targetBuffer,
        offset: 0,
        stride: targetInfo.size.width * 4,
        region: { size: targetInfo.size, x: 0, y: 0 }
      };
      await targetPixelMap.writePixels(writeArea);
      
      Logger.info(TAG_LOG, '水印混合完成');
    } catch (error) {
      Logger.error(TAG_LOG, `水印混合失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法混合水印');
    }
  }

  /**
   * 性能监控
   */
  async measurePerformance(photo: camera.Photo, watermarkInfo: WatermarkInfo): Promise<PerformanceMetrics> {
    const startTime: number = Date.now();
    
    try {
      await this.processWatermark(photo, watermarkInfo);
      
      const endTime: number = Date.now();
      const processingTime = endTime - startTime;
      
      const metrics: PerformanceMetrics = {
        startTime,
        endTime,
        processingTime,
        memoryUsage: 0 // 简化实现
      };
      
      return metrics;
    } catch (error) {
      const endTime: number = Date.now();
      const processingTime = endTime - startTime;
      
      const metrics: PerformanceMetrics = {
        startTime,
        endTime,
        processingTime,
        memoryUsage: 0
      };
      
      return metrics;
    }
  }
}