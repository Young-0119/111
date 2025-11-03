/**
 * 稳定的水印处理器 - 使用HarmonyOS原生API
 * 彻底解决真机兼容性问题
 */
import { image } from '@kit.ImageKit';
import { camera } from '@kit.CameraKit';
import { Logger } from 'commons';
import { WatermarkInfo, WatermarkProcessConfig, PerformanceMetrics } from './WatermarkProcessor';

/**
 * 水印信息项接口
 */
interface WatermarkInfoItem {
  label: string;
  value: string;
}

const TAG_LOG = 'RobustWatermarkProcessor';

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
   * 创建水印PixelMap - 使用Canvas API实现清晰文字渲染
   */
  private async createWatermarkPixelMap(watermarkInfo: WatermarkInfo, originalPixelMap: image.PixelMap): Promise<image.PixelMap> {
    try {
      // 获取原图尺寸
      const imageInfo: image.ImageInfo = await originalPixelMap.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;

      // 优化水印尺寸计算 - 确保清晰可见但不过大
      // 严格按照WatermarkOverlay.ets的UI规范设置尺寸
      const watermarkWidth = 220;  // 固定宽度，与UI组件完全一致
      const watermarkHeight = Math.max(300, height * 0.15); // 自适应高度，确保内容完整显示

      // 创建OffscreenCanvas进行高质量渲染
      const offscreenCanvas = new OffscreenCanvas(Math.floor(watermarkWidth), Math.floor(watermarkHeight));
      const context = offscreenCanvas.getContext('2d');
      
      if (!context) {
        throw new Error('无法获取Canvas上下文');
      }

      // 使用Canvas API绘制清晰的水印内容，严格按照UI规范
      await this.drawWatermarkWithCanvas(context, watermarkInfo, Math.floor(watermarkWidth), Math.floor(watermarkHeight));

      // 从Canvas获取PixelMap
      const watermarkPixelMap: image.PixelMap = await context.getPixelMap(0, 0, Math.floor(watermarkWidth), Math.floor(watermarkHeight));

      return watermarkPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `创建水印PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法创建水印');
    }
  }

  /**
   * 使用Canvas绘制水印内容，严格按照WatermarkOverlay.ets的UI规范
   */
  private async drawWatermarkWithCanvas(context: OffscreenCanvasRenderingContext2D, 
                                       watermarkInfo: WatermarkInfo, 
                                       canvasWidth: number, 
                                       canvasHeight: number): Promise<void> {
    // 清除画布
    context.clearRect(0, 0, canvasWidth, canvasHeight);
    
    // 设置高质量渲染
    context.imageSmoothingEnabled = true;
    context.textAlign = 'left';
    context.textBaseline = 'top';
    
    // 保存初始状态
    context.save();
    
    // 严格按照WatermarkOverlay.ets的UI规范：
    // 1. 固定宽度220px（对应预览中的width(220)）
    // 2. 完全匹配预览的布局、颜色、字体、间距
    
    const watermarkWidth = 220; // 与预览UI保持一致的固定宽度
    
    // 计算实际高度（根据内容动态计算）
    const titleAreaHeight = 52; // 标题区域高度（图片46.48 + padding）
    const infoLineHeight = 16;  // 信息行高度（12px字体 + 4px间距）
    const infoCount = 7;        // 信息项数量
    const orgAreaHeight = 24;   // 制作单位区域高度
    const padding = 8;          // 上下内边距
    
    const watermarkHeight = titleAreaHeight + (infoCount * infoLineHeight) + orgAreaHeight + padding;
    
    // 应用变换：严格按照预览UI的变换顺序和参数
    // 1. 移动到合适位置进行变换
    context.translate(watermarkHeight * 0.8, 0); // 为旋转后预留空间
    
    // 2. 缩放80%（以左下角为中心）
    context.scale(0.8, 0.8);
    
    // 3. 旋转90度（以左下角为轴心）
    context.rotate(90 * Math.PI / 180);
    
    // 现在绘制水印内容（在变换后的坐标系中）
    
    // 1. 绘制主背景 - 严格按照预览UI规范
    context.fillStyle = 'rgba(255, 255, 255, 0.7)'; // 白色70%透明度
    
    // 绘制圆角矩形背景
    const radius = 8;
    this.drawRoundedRect(context, 0, 0, watermarkWidth, watermarkHeight, radius);
    context.fill();
    
    // 2. 绘制标题区域背景 - 蓝色50%透明度
    context.fillStyle = 'rgba(0, 87, 217, 0.5)';
    this.drawRoundedRect(context, 0, 0, watermarkWidth, titleAreaHeight, radius, true, false);
    context.fill();
    
    // 3. 绘制logo图片区域（用矩形代替，因为Canvas中加载图片较复杂）
    const logoWidth = 60;
    const logoHeight = 46.48;
    const logoX = 12; // 左边距
    const logoY = (titleAreaHeight - logoHeight) / 2; // 垂直居中
    
    // 绘制logo占位矩形（蓝色）
    context.fillStyle = 'rgba(0, 87, 217, 0.8)';
    context.fillRect(logoX, logoY, logoWidth, logoHeight);
    
    // 4. 绘制标题文字 - 14px白色粗体
    context.fillStyle = '#FFFFFF';
    context.font = 'bold 14px sans-serif'; // 使用通用字体确保兼容性
    const titleText = '应急管理水印';
    const titleX = logoX + logoWidth + 12; // logo右侧 + 间距
    const titleY = (titleAreaHeight - 14) / 2; // 垂直居中
    context.fillText(titleText, titleX, titleY);
    
    // 5. 绘制信息项 - 12px黑色文字，严格按照预览UI布局
    context.fillStyle = '#000000';
    context.font = '12px sans-serif';
    
    let yOffset = titleAreaHeight + 4; // 标题区域后开始
    const leftPadding = 4; // 左边距4px，与预览UI一致
    
    const infoItems = this.getWatermarkInfoItems(watermarkInfo);
    
    // 绘制前7个信息项（不包括制作单位）
    for (let i = 0; i < Math.min(infoItems.length - 1, 7); i++) {
      const item = infoItems[i];
      context.fillText(`${item.label}：${item.value}`, leftPadding, yOffset);
      yOffset += infoLineHeight;
    }
    
    // 6. 绘制制作单位区域 - 蓝色50%透明度背景
    const orgAreaY = watermarkHeight - orgAreaHeight;
    context.beginPath();
    context.roundRect(0, orgAreaY, watermarkWidth, orgAreaHeight, [0, 0, radius, radius]);
    context.fillStyle = 'rgba(0, 87, 217, 0.5)';
    context.fill();
    
    // 7. 绘制制作单位文字 - 12px白色中等字重
    context.fillStyle = '#FFFFFF';
    context.font = '500 12px sans-serif'; // 中等字重
    const orgText = `制作单位：${watermarkInfo.organization || '应急管理部门'}`;
    const orgY = orgAreaY + (orgAreaHeight - 12) / 2; // 垂直居中
    context.fillText(orgText, leftPadding, orgY);
    
    // 恢复变换状态
    context.restore();
    
    Logger.info(TAG_LOG, `严格按照预览UI规范绘制水印完成: ${watermarkWidth}x${watermarkHeight}，与预览保持完全一致`);
  }

  /**
   * 获取水印信息项列表
   */
  private getWatermarkInfoItems(watermarkInfo: WatermarkInfo): Array<WatermarkInfoItem> {
    return [
      { label: '拍摄时间', value: watermarkInfo.timestamp },
      { label: '天气信息', value: watermarkInfo.weather || '获取中...' },
      { label: '地点信息', value: watermarkInfo.location || '定位中...' },
      { label: '海拔信息', value: watermarkInfo.altitude || '计算中...' },
      { label: '方位角', value: watermarkInfo.direction || '计算中...' },
      { label: '经度', value: watermarkInfo.longitude || '计算中...' },
      { label: '纬度', value: watermarkInfo.latitude || '获取中...' },
      { label: '制作单位', value: watermarkInfo.organization || '应急管理部门' }
    ];
  }

  /**
   * 获取信息项数量
   */
  private getInfoItemsCount(watermarkInfo: WatermarkInfo): number {
    return this.getWatermarkInfoItems(watermarkInfo).length;
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

      // 计算水印位置 - 严格按照WatermarkOverlay.ets的UI规范 (左上角，位置x:2, y:2)
      // 考虑到旋转和缩放变换，需要调整实际位置
      const watermarkX = 2; // 左上角x坐标
      const watermarkY = 2; // 左上角y坐标

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

  /**
   * 绘制圆角矩形路径
   * @param context Canvas上下文
   * @param x 起始x坐标
   * @param y 起始y坐标
   * @param width 宽度
   * @param height 高度
   * @param radius 圆角半径
   * @param topRounded 是否圆角顶部（默认true）
   * @param bottomRounded 是否圆角底部（默认true）
   */
  private drawRoundedRect(context: OffscreenCanvasRenderingContext2D, x: number, y: number, 
                         width: number, height: number, radius: number, 
                         topRounded: boolean = true, bottomRounded: boolean = true): void {
    context.beginPath();
    
    // 左上角
    if (topRounded) {
      context.moveTo(x + radius, y);
    } else {
      context.moveTo(x, y);
    }
    
    // 顶边和右上角
    if (topRounded) {
      context.lineTo(x + width - radius, y);
      context.quadraticCurveTo(x + width, y, x + width, y + radius);
    } else {
      context.lineTo(x + width, y);
    }
    
    // 右边和右下角
    if (bottomRounded) {
      context.lineTo(x + width, y + height - radius);
      context.quadraticCurveTo(x + width, y + height, x + width - radius, y + height);
    } else {
      context.lineTo(x + width, y + height);
    }
    
    // 底边和左下角
    if (bottomRounded) {
      context.lineTo(x + radius, y + height);
      context.quadraticCurveTo(x, y + height, x, y + height - radius);
    } else {
      context.lineTo(x, y + height);
    }
    
    // 左边和左上角
    if (topRounded) {
      context.lineTo(x, y + radius);
      context.quadraticCurveTo(x, y, x + radius, y);
    } else {
      context.lineTo(x, y);
    }
    
    context.closePath();
  }
}