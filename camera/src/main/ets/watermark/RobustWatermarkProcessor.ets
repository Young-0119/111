/**
 * 稳定的水印处理器 - 使用HarmonyOS原生API
 * 彻底解决真机兼容性问题
 */
import { image } from '@kit.ImageKit';
import { camera } from '@kit.CameraKit';
import { Logger } from 'commons';
import { common } from '@kit.AbilityKit';

// 水印处理配置接口
export interface WatermarkProcessConfig {
  readonly enabled: boolean;
  readonly quality: number;  // 1-100
  readonly position: 'top-left' | 'top-right' | 'bottom-left' | 'bottom-right';
  readonly opacity: number;  // 0-1
  readonly scale: number;    // 0.5-2.0
  readonly rotation: number; // 0-360度
}

// 水印信息接口
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

// 性能指标接口
export interface PerformanceMetrics {
  readonly startTime: number;
  readonly endTime: number;
  readonly memoryUsage: number;
  readonly processingTime: number;
}

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
   * 创建水印PixelMap - 使用Canvas API实现清晰文字渲染，动态适应照片尺寸
   */
  private async createWatermarkPixelMap(watermarkInfo: WatermarkInfo, originalPixelMap: image.PixelMap): Promise<image.PixelMap> {
    try {
      // 获取原图尺寸
      const imageInfo: image.ImageInfo = await originalPixelMap.getImageInfo();
      const photoWidth = imageInfo.size.width;
      const photoHeight = imageInfo.size.height;

      // 基于预览界面的水印占比进行动态适应
      // 预览界面水印占比：宽度16.3%，高度16.7%（经过0.8缩放后的实际占比）
      const PREVIEW_WIDTH_RATIO = 0.163;  // 预览界面水印宽度占比
      const PREVIEW_HEIGHT_RATIO = 0.167; // 预览界面水印高度占比
      
      // 根据照片实际尺寸计算水印尺寸，保持与预览界面相同的视觉比例
      const adaptiveWatermarkWidth = Math.floor(photoWidth * PREVIEW_WIDTH_RATIO);
      const adaptiveWatermarkHeight = Math.floor(photoHeight * PREVIEW_HEIGHT_RATIO);
      
      // 设置合理的尺寸范围，确保水印既清晰又不过大
      const watermarkWidth = Math.max(200, Math.min(adaptiveWatermarkWidth, 400));  // 限制在200-400px之间
      const watermarkHeight = Math.max(250, Math.min(adaptiveWatermarkHeight, 500)); // 限制在250-500px之间

      Logger.info(TAG_LOG, `照片尺寸: ${photoWidth}×${photoHeight}, 水印尺寸: ${watermarkWidth}×${watermarkHeight}`);

      // 创建OffscreenCanvas进行高质量渲染
      const offscreenCanvas = new OffscreenCanvas(watermarkWidth, watermarkHeight);
      const context = offscreenCanvas.getContext('2d');
      
      if (!context) {
        throw new Error('无法获取Canvas上下文');
      }

      // 使用Canvas API绘制清晰的水印内容，传入实际尺寸
      await this.drawWatermarkWithCanvas(context, watermarkInfo, watermarkWidth, watermarkHeight);

      // 从Canvas获取PixelMap
      const watermarkPixelMap: image.PixelMap = await context.getPixelMap(0, 0, watermarkWidth, watermarkHeight);

      return watermarkPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `创建水印PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法创建水印');
    }
  }

  /**
   * 使用Canvas绘制水印内容，根据动态尺寸自适应调整布局和字体
   */
  private async drawWatermarkWithCanvas(context: OffscreenCanvasRenderingContext2D, 
                                       watermarkInfo: WatermarkInfo, 
                                       canvasWidth: number, 
                                       canvasHeight: number): Promise<void> {
    // 清除画布
    context.clearRect(0, 0, canvasWidth, canvasHeight);
    
    // 设置最高质量渲染参数
    context.imageSmoothingEnabled = true;
    context.imageSmoothingQuality = 'high'; // 设置最高图像平滑质量
    context.textAlign = 'left';
    context.textBaseline = 'top';
    
    // 保存初始状态
    context.save();
    
    // 基于动态尺寸计算缩放比例（以220px为基准）
    const baseWidth = 220; // 预览UI的基准宽度
    const scaleRatio = canvasWidth / baseWidth; // 计算缩放比例
    
    Logger.info(TAG_LOG, `水印绘制尺寸: ${canvasWidth}×${canvasHeight}, 缩放比例: ${scaleRatio.toFixed(2)}`);
    
    // 动态计算各区域尺寸（基于缩放比例）
    const titleAreaHeight = Math.floor(58 * scaleRatio); // 标题区域高度
    const infoLineHeight = Math.floor(16 * scaleRatio);  // 信息行高度
    const infoCount = 7;        // 信息项数量
    const orgAreaHeight = Math.floor(24 * scaleRatio);   // 制作单位区域高度
    const padding = Math.floor(8 * scaleRatio);          // 内边距
    
    // 动态计算字体大小
    const titleFontSize = Math.floor(14 * scaleRatio);
    const infoFontSize = Math.floor(12 * scaleRatio);
    const logoWidth = Math.floor(60 * scaleRatio);
    const logoHeight = Math.floor(46.48 * scaleRatio);
    const radius = Math.floor(8 * scaleRatio);
    const leftPadding = Math.floor(8 * scaleRatio);
    
    // 应用变换：保持与预览UI一致的变换效果
    // 1. 移动到合适位置进行变换
    context.translate(canvasHeight * 0.8, 0); // 为旋转后预留空间
    
    // 2. 缩放80%（保持与预览UI一致）
    context.scale(0.8, 0.8);
    
    // 3. 旋转90度（以左下角为轴心）
    context.rotate(90 * Math.PI / 180);
    
    // 现在绘制水印内容（在变换后的坐标系中）
    
    // 1. 绘制主背景 - 严格按照预览UI规范
    context.fillStyle = 'rgba(255, 255, 255, 0.7)'; // 白色70%透明度
    
    // 绘制圆角矩形背景
    this.drawRoundedRect(context, 0, 0, canvasWidth, canvasHeight, radius);
    context.fill();
    
    // 2. 绘制标题区域背景 - 蓝色50%透明度
    context.fillStyle = 'rgba(0, 87, 217, 0.5)';
    this.drawRoundedRect(context, 0, 0, canvasWidth, titleAreaHeight, radius, true, false);
    context.fill();
    
    // 3. 绘制徽章图标区域（使用真实的watermark_logo.png）
    const logoX = Math.floor(12 * scaleRatio); // 左边距
    const logoY = (titleAreaHeight - logoHeight) / 2; // 垂直居中
    
    // 加载并绘制徽章图片
    const logoPixelMap = await this.loadWatermarkLogo();
    if (logoPixelMap) {
      context.drawImage(logoPixelMap, logoX, logoY, logoWidth, logoHeight);
    }
    
    // 4. 绘制标题文字 - 动态字体大小，白色粗体
    context.fillStyle = '#FFFFFF';
    context.font = `bold ${titleFontSize}px sans-serif`; // 动态字体大小
    const titleText = '灭火救援灾害现场';
    const titleX = logoX + logoWidth + Math.floor(12 * scaleRatio); // logo右侧 + 间距
    const titleY = (titleAreaHeight - titleFontSize) / 2; // 垂直居中
    context.fillText(titleText, titleX, titleY);
    
    // 5. 绘制信息项 - 动态字体大小，黑色文字
    context.fillStyle = '#000000';
    context.font = `${infoFontSize}px sans-serif`;
    
    let yOffset = titleAreaHeight + Math.floor(6 * scaleRatio); // 标题区域后开始，增加间距
    
    const infoItems = this.getWatermarkInfoItems(watermarkInfo);
    
    // 绘制前7个信息项（不包括制作单位）
    for (let i = 0; i < Math.min(infoItems.length - 1, 7); i++) {
      const item = infoItems[i];
      const text = `${item.label}：${item.value}`;
      context.fillText(text, leftPadding, yOffset);
      yOffset += infoLineHeight;
    }
    
    // 6. 绘制制作单位区域 - 蓝色50%透明度背景
    const orgAreaY = canvasHeight - orgAreaHeight;
    context.beginPath();
    // 使用现有的drawRoundedRect方法，只圆角底部
    this.drawRoundedRect(context, 0, orgAreaY, canvasWidth, orgAreaHeight, radius, false, true);
    context.fillStyle = 'rgba(0, 87, 217, 0.5)';
    context.fill();
    
    // 7. 绘制制作单位文字 - 动态字体大小，白色中等字重
    context.fillStyle = '#FFFFFF';
    context.font = `500 ${infoFontSize}px sans-serif`; // 动态字体大小
    const orgText = `制作单位：${watermarkInfo.organization || '应急管理部门'}`;
    const orgY = orgAreaY + (orgAreaHeight - infoFontSize) / 2; // 垂直居中
    context.fillText(orgText, leftPadding, orgY);
    
    // 恢复变换状态
    context.restore();
    
    Logger.info(TAG_LOG, `动态适应水印绘制完成: ${canvasWidth}×${canvasHeight}, 缩放比例: ${scaleRatio.toFixed(2)}`);
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

      // 创建结果PixelMap - 使用最高质量配置
      const createOptions: image.InitializationOptions = {
        size: originalInfo.size,
        pixelFormat: image.PixelMapFormat.RGBA_8888, // 使用正确的PixelMapFormat
        alphaType: image.AlphaType.PREMUL,
        scaleMode: image.ScaleMode.FIT_TARGET_SIZE, // 优化缩放模式
        editable: true // 确保可编辑
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

  /**
   * 加载水印徽章图片
   */
  private async loadWatermarkLogo(): Promise<image.PixelMap | null> {
    try {
      // 使用资源管理器加载徽章图片
      const context = getContext(this) as common.UIAbilityContext;
      const resourceManager = context.resourceManager;
      const imageBuffer: Uint8Array = await resourceManager.getMediaContent($r('app.media.watermark_logo'));
      
      // 创建ImageSource
      const imageSource: image.ImageSource = image.createImageSource(imageBuffer.buffer);
      
      // 创建PixelMap
      const pixelMap: image.PixelMap = await imageSource.createPixelMap();
      
      return pixelMap;
    } catch (error) {
      console.error('Failed to load watermark logo:', error);
      return null;
    }
  }
}