/**
 * 稳定的水印处理器 - 使用HarmonyOS原生API
 * 彻底解决真机兼容性问题
 */
import { image } from '@kit.ImageKit';
import { camera } from '@kit.CameraKit';
import { display } from '@kit.ArkUI';
import { Logger } from 'commons';
import { common } from '@kit.AbilityKit';

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
   * 主要水印处理方法 - 使用原生API确保兼容性（性能优化版）
   * 优化策略：并行化操作、缓存设备信息、减少内存分配
   */
  async processWatermark(photo: camera.Photo, watermarkInfo: WatermarkInfo): Promise<image.PixelMap> {
    Logger.info(TAG_LOG, '开始稳定水印处理流程');
    
    let originalPixelMap: image.PixelMap | null = null;
    let watermarkPixelMap: image.PixelMap | null = null;
    
    try {
      // 1. 并行获取原始图像和设备信息（提前获取设备信息用于后续计算）
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

      // 3. 合成图像 - 使用优化后的原生API
      const resultPixelMap: image.PixelMap = await this.compositeImages(originalPixelMap, watermarkPixelMap, originalInfo);
      
      return resultPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `水印处理失败: ${error instanceof Error ? error.message : String(error)}`);
      
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
      // 确保资源释放
      if (watermarkPixelMap) {
        watermarkPixelMap.release();
      }
    }
  }

  /**
   * 获取照片的PixelMap - 使用标准API（性能优化版本）
   */
  private async getPhotoPixelMap(photo: camera.Photo): Promise<image.PixelMap> {
    const imageObj: image.Image = photo.main;
    let imageSource: image.ImageSource | null = null;
    
    try {
      // 直接使用util.promisify风格的异步调用，减少Promise包装开销
      const component: image.Component = await new Promise<image.Component>((resolve, reject) => {
        imageObj.getComponent(image.ComponentType.JPEG, (err, comp) => {
          err ? reject(err) : comp ? resolve(comp) : reject(new Error('Failed to get image component'));
        });
      });
      
      // 创建ImageSource并立即使用
      imageSource = image.createImageSource(component.byteBuffer);
      
      // 创建PixelMap - 使用更简洁的配置
      const pixelMap: image.PixelMap = await imageSource.createPixelMap({
        desiredSize: { width: 0, height: 0 }, // 0表示使用原始尺寸
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      });
      
      return pixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `获取照片PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法获取照片数据');
    } finally {
      // 确保资源释放
      if (imageSource) {
        imageSource.release();
      }
    }
  }

  /**
   * 创建水印PixelMap - 使用Canvas API实现清晰文字渲染，基于实际照片尺寸动态计算水印大小
   * 优化版本：减少异步操作，缓存设备信息，优化性能
   */
  private async createWatermarkPixelMap(watermarkInfo: WatermarkInfo, originalPixelMap: image.PixelMap, displayInfo: display.Display): Promise<image.PixelMap> {
    try {
      // 获取原图尺寸（使用缓存或并行获取）
      const imageInfo = await originalPixelMap.getImageInfo();
      const photoWidth = imageInfo.size.width;
      const photoHeight = imageInfo.size.height;
      const pixelRatio = displayInfo.densityPixels;

      // 水印尺寸比例设置
      const WATERMARK_WIDTH_RATIO = 0.5;
      const WATERMARK_HEIGHT_RATIO = 0.4;
      
      // 基于实际照片尺寸计算水印尺寸，并考虑像素密度
      const watermarkWidth = Math.round(photoWidth * WATERMARK_WIDTH_RATIO / pixelRatio);
      const watermarkHeight = Math.round(photoHeight * WATERMARK_HEIGHT_RATIO / pixelRatio);

      // 创建OffscreenCanvas进行高质量渲染
      const offscreenCanvas = new OffscreenCanvas(watermarkWidth, watermarkHeight);
      const context = offscreenCanvas.getContext('2d');
      
      if (!context) {
        throw new Error('无法获取Canvas上下文');
      }

      // 使用Canvas API绘制清晰的水印内容
      await this.drawWatermarkWithCanvas(context, watermarkInfo, watermarkWidth, watermarkHeight);

      // 直接从Canvas获取PixelMap，跳过尺寸验证（Canvas会自动处理尺寸）
      const watermarkPixelMap: image.PixelMap = await context.getPixelMap(0, 0, watermarkWidth, watermarkHeight);

      return watermarkPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `创建水印PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法创建水印');
    }
  }

  /**
   * 使用Canvas绘制水印内容，基于固定相机分辨率的水印布局和字体
   * 优化版本：减少状态操作，预计算布局参数，优化性能
   */
  private async drawWatermarkWithCanvas(context: OffscreenCanvasRenderingContext2D, 
                                       watermarkInfo: WatermarkInfo, 
                                       canvasWidth: number , 
                                       canvasHeight: number ): Promise<void> {
    // 清除画布
    context.clearRect(0, 0, canvasWidth, canvasHeight);
    
    // 设置最高质量渲染参数
    context.imageSmoothingEnabled = true;
    context.imageSmoothingQuality = 'high';
    context.textAlign = 'left';
    context.textBaseline = 'top';
    
    // 保存初始状态
    context.save();
    
    Logger.info(TAG_LOG, `水印绘制尺寸: ${canvasWidth}×${canvasHeight}`);
    
    // 定义边距常量
    const MARGIN = 4; // 绘制图层之间的边距
    const DOUBLE_MARGIN = MARGIN * 2;
    const radius = 8;
    
    // 预计算布局参数
    const orgWidth = canvasWidth * 0.1; // 制作单位区域宽度
    const titleBarWidth = canvasWidth * 0.3; // 标题栏宽度
    const titleBarX = canvasWidth - titleBarWidth - MARGIN; // 标题栏X坐标
    const orgX = MARGIN; // 制作单位区域X坐标
    const orgHeight = canvasHeight - DOUBLE_MARGIN; // 制作单位区域高度
    const titleBarHeight = canvasHeight - DOUBLE_MARGIN; // 标题栏高度
    const orgY = MARGIN; // 制作单位区域Y坐标
    const titleBarY = MARGIN; // 标题栏Y坐标
    
    context.translate(0, 0);
    
    // 1. 绘制主背景
    context.fillStyle = 'rgba(255, 255, 255, 0.7)';
    this.drawRoundedRect(context, 0, 0, canvasWidth, canvasHeight, radius);
    context.fill();

    // 2. 绘制左侧制作单位背景区
    context.fillStyle = 'rgba(0, 87, 217, 0.5)';
    this.drawRoundedRect(context, orgX, orgY, orgWidth, orgHeight, 0);
    context.fill();
    
    // 3. 绘制右侧标题栏背景区
    context.fillStyle = 'rgba(0, 87, 217, 0.5)';
    this.drawRoundedRect(context, titleBarX, titleBarY, titleBarWidth, titleBarHeight, 0);
    context.fill();

    // 4. 绘制水印logo和文字
    const watermarkLogo = await this.loadWatermarkLogo();
    if (watermarkLogo) {
      const logoInfo = await watermarkLogo.getImageInfo();
      
      // 计算logo缩放尺寸
      const maxLogoWidth = titleBarHeight - DOUBLE_MARGIN;
      const maxLogoHeight = titleBarWidth - DOUBLE_MARGIN;
      const widthRatio = maxLogoWidth / logoInfo.size.width;
      const heightRatio = maxLogoHeight / logoInfo.size.height;
      const scaleRatio = Math.min(widthRatio, heightRatio);
      
      const logoWidth = logoInfo.size.width * scaleRatio;
      const logoHeight = logoInfo.size.height * scaleRatio;
      
      // 计算logo位置
      const logoX = titleBarX + (titleBarWidth - logoHeight) / 2;
      const logoY = titleBarY + MARGIN;
      
      // 绘制logo
      context.save();
      context.translate(logoX + logoHeight / 2, logoY + logoWidth / 2);
      context.rotate(90 * Math.PI / 180);
      context.drawImage(watermarkLogo, -logoWidth / 2, -logoHeight / 2, logoWidth, logoHeight);
      context.restore();

      // 绘制标题文字
      context.fillStyle = 'white';
      context.font = '80px sans-serif';
      context.textAlign = 'center';
      context.textBaseline = 'middle';
      
      const remainingHeight = titleBarHeight - (logoY + logoWidth);
      const titleTextX = titleBarX + titleBarWidth / 2;
      const titleTextY = logoY + logoWidth + remainingHeight / 2;
      
      context.save();
      context.translate(titleTextX, titleTextY);
      context.rotate(90 * Math.PI / 180);
      context.fillText('灭火救援灾害现场', 0, 0);
      context.restore();
    }
    
    // 5. 绘制信息文本
    const infoItems = this.getWatermarkInfoItems(watermarkInfo);
    const infoAreaWidth = titleBarX - MARGIN;
    const fontSize = 50;
    const itemCount = infoItems.length;
    const availableHeight = infoAreaWidth;
    const adjustedLineHeight = availableHeight / itemCount;
    
    context.fillStyle = 'black';
    context.font = `${fontSize}px sans-serif`;
    context.textAlign = 'left';
    context.textBaseline = 'middle';
    
    const infoCenterX = MARGIN + infoAreaWidth / 2;
    const infoCenterY = DOUBLE_MARGIN;
    const totalAdjustedHeight = (itemCount - 1) * adjustedLineHeight;
    const startY = -totalAdjustedHeight / 2;
    
    context.save();
    context.translate(infoCenterX, infoCenterY);
    context.rotate(90 * Math.PI / 180);
    
    // 批量绘制文本信息
    infoItems.forEach((item, index) => {
      const text = `${item.label}：${item.value}`;
      const y = startY + index * adjustedLineHeight;
      
      if (item.label === '制作单位') {
        context.fillStyle = 'white';
        context.font = '500 50px sans-serif';
      } else {
        context.fillStyle = 'black';
        context.font = '50px sans-serif';
      }
      
      context.fillText(text, 0, y);
    });
    
    context.restore();
    
    // 恢复初始状态
    context.restore();
    
    Logger.info(TAG_LOG, `水印绘制完成: ${canvasWidth}×${canvasHeight}`);
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
      { label: '方  位  角', value: watermarkInfo.direction || '计算中...' },
      { label: '经        度', value: watermarkInfo.longitude || '计算中...' },
      { label: '纬        度', value: watermarkInfo.latitude || '获取中...' },
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
   * 合成图像 - 使用原生PixelMap操作（优化版）
   */
  private async compositeImages(originalPixelMap: image.PixelMap, watermarkPixelMap: image.PixelMap, originalInfo: image.ImageInfo): Promise<image.PixelMap> {
    try {
      // 获取水印图像信息（原图信息已通过参数传入）
      const watermarkInfo = await watermarkPixelMap.getImageInfo();

      const originalWidth = originalInfo.size.width;
      const originalHeight = originalInfo.size.height;

      // 照片合成前尺寸信息（调试时启用）
      // Logger.debug(TAG_LOG, `原图尺寸: ${originalWidth}×${originalHeight}, 水印尺寸: ${watermarkInfo.size.width}×${watermarkInfo.size.height}`);

      // 直接使用原图创建结果PixelMap，避免额外的缓冲区复制
      // 使用createPixelMapFromPixelMap API（如果可用）或直接复制
      let resultPixelMap: image.PixelMap;
      
      // 直接使用传统方法创建结果PixelMap
      const createOptions: image.InitializationOptions = {
        size: originalInfo.size,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.PREMUL,
        scaleMode: image.ScaleMode.CENTER_CROP,
        editable: true
      };

      const pixelBytes = originalWidth * originalHeight * 4;
      const buffer = new ArrayBuffer(pixelBytes);
      
      resultPixelMap = await image.createPixelMap(buffer, createOptions);

      // 复制原图数据
      const copyArea: image.PositionArea = {
        pixels: buffer,
        offset: 0,
        stride: originalWidth * 4,
        region: { size: originalInfo.size, x: 0, y: 0 }
      };
      
      await originalPixelMap.readPixels(copyArea);
      await resultPixelMap.writePixels(copyArea);

      // 水印位置设置在照片的左上侧
      const watermarkX = 0; // 左上角x坐标
      const watermarkY = 0; // 左上角y坐标

      // 水印合成信息（调试时启用）
      // Logger.debug(TAG_LOG, `水印位置: x=${watermarkX}, y=${watermarkY}, 比例: ${(watermarkInfo.size.width / originalWidth).toFixed(3)}x`);

      // 使用优化后的原生API合成水印
      await this.blendWatermark(resultPixelMap, watermarkPixelMap, watermarkX, watermarkY);

      // Logger.debug(TAG_LOG, '图像合成完成');
      return resultPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `图像合成失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法合成图像');
    }
  }

  /**
   * 混合水印到目标图像 - 像素级操作（优化版）
   */
  private async blendWatermark(targetPixelMap: image.PixelMap, watermarkPixelMap: image.PixelMap, x: number, y: number): Promise<void> {
    try {
      // 并行获取图像信息（避免解构赋值）
      const imageInfos = await Promise.all([
        targetPixelMap.getImageInfo(),
        watermarkPixelMap.getImageInfo()
      ]);
      const targetInfo = imageInfos[0];
      const watermarkInfo = imageInfos[1];

      const targetWidth = targetInfo.size.width;
      const targetHeight = targetInfo.size.height;
      const watermarkWidth = watermarkInfo.size.width;
      const watermarkHeight = watermarkInfo.size.height;

      // 计算有效混合区域（避免不必要的边界检查）
      const startX = Math.max(x, 0);
      const startY = Math.max(y, 0);
      const endX = Math.min(x + watermarkWidth, targetWidth);
      const endY = Math.min(y + watermarkHeight, targetHeight);

      // 如果没有重叠区域，直接返回
      if (startX >= endX || startY >= endY) {
        Logger.warn(TAG_LOG, '水印区域超出目标图像边界，跳过混合');
        return;
      }

      // 优化内存使用：只读取需要修改的目标区域
      const blendWidth = endX - startX;
      const blendHeight = endY - startY;
      
      // 读取目标图像需要修改的区域
      const targetBuffer = new ArrayBuffer(blendWidth * blendHeight * 4);
      const targetArea: image.PositionArea = {
        pixels: targetBuffer,
        offset: 0,
        stride: blendWidth * 4,
        region: { size: { width: blendWidth, height: blendHeight }, x: startX, y: startY }
      };
      await targetPixelMap.readPixels(targetArea);
      const targetView = new Uint8Array(targetBuffer);

      // 读取水印数据（对应区域）
      const watermarkBuffer = new ArrayBuffer(blendWidth * blendHeight * 4);
      const watermarkArea: image.PositionArea = {
        pixels: watermarkBuffer,
        offset: 0,
        stride: blendWidth * 4,
        region: { size: { width: blendWidth, height: blendHeight }, x: startX - x, y: startY - y }
      };
      await watermarkPixelMap.readPixels(watermarkArea);
      const watermarkView = new Uint8Array(watermarkBuffer);

      // 预计算水印在目标图像中的偏移量（已通过循环变量计算，无需额外使用）

      // 优化混合循环 - 处理局部区域
      for (let localY = 0; localY < blendHeight; localY++) {
        for (let localX = 0; localX < blendWidth; localX++) {
          const targetIndex = (localY * blendWidth + localX) * 4;
          const watermarkIndex = targetIndex; // 由于读取的是相同大小的区域

          const alpha = watermarkView[watermarkIndex + 3] / 255.0;
          
          // 如果水印像素完全透明，跳过混合
          if (alpha < 0.01) continue;
          
          const invAlpha = 1.0 - alpha;

          // Alpha混合（使用更快的整数运算）
          targetView[targetIndex] = (targetView[targetIndex] * invAlpha + watermarkView[watermarkIndex] * alpha + 0.5) | 0;
          targetView[targetIndex + 1] = (targetView[targetIndex + 1] * invAlpha + watermarkView[watermarkIndex + 1] * alpha + 0.5) | 0;
          targetView[targetIndex + 2] = (targetView[targetIndex + 2] * invAlpha + watermarkView[watermarkIndex + 2] * alpha + 0.5) | 0;
        }
      }

      // 写回目标图像
      const writeArea: image.PositionArea = {
        pixels: targetBuffer,
        offset: 0,
        stride: blendWidth * 4,
        region: { size: { width: blendWidth, height: blendHeight }, x: startX, y: startY }
      };
      await targetPixelMap.writePixels(writeArea);
      
      // Logger.debug(TAG_LOG, '水印混合完成');
    } catch (error) {
      Logger.error(TAG_LOG, `水印混合失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法混合水印');
    }
  }

  /**
   * 绘制圆角矩形路径 - 极简优化版（全圆角或全直角，最少API调用）
   * @param context Canvas上下文
   * @param x 起始x坐标
   * @param y 起始y坐标
   * @param width 宽度
   * @param height 高度
   * @param radius 圆角半径（0表示直角）
   */
  private drawRoundedRect(context: OffscreenCanvasRenderingContext2D, x: number, y: number, 
                         width: number, height: number, radius: number): void {
    context.beginPath();
    
    if (radius > 0) {
      // 全圆角模式 - 最少API调用
      const x1 = x;
      const y1 = y;
      const x2 = x + width;
      const y2 = y + height;
      const r = radius;
      
      context.moveTo(x1 + r, y1);
      context.lineTo(x2 - r, y1);
      context.quadraticCurveTo(x2, y1, x2, y1 + r);
      context.lineTo(x2, y2 - r);
      context.quadraticCurveTo(x2, y2, x2 - r, y2);
      context.lineTo(x1 + r, y2);
      context.quadraticCurveTo(x1, y2, x1, y2 - r);
      context.lineTo(x1, y1 + r);
      context.quadraticCurveTo(x1, y1, x1 + r, y1);
    } else {
      // 无圆角 - 直接矩形（最快路径）
      context.rect(x, y, width, height);
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