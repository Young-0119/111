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
   * 创建水印PixelMap - 使用Canvas API实现清晰文字渲染，基于实际照片尺寸动态计算水印大小
   */
  private async createWatermarkPixelMap(watermarkInfo: WatermarkInfo, originalPixelMap: image.PixelMap): Promise<image.PixelMap> {
    try {
      // 获取原图尺寸
      const imageInfo: image.ImageInfo = await originalPixelMap.getImageInfo();
      const photoWidth = imageInfo.size.width;
      const photoHeight = imageInfo.size.height;

      // 获取设备像素密度 - 使用新的API
       const displayInfo = display.getDefaultDisplaySync();
       const pixelRatio = displayInfo.densityPixels;
       Logger.info(TAG_LOG, `设备像素密度: ${pixelRatio}`);

      // 水印尺寸比例设置
      const WATERMARK_WIDTH_RATIO = 0.5;   // 
      const WATERMARK_HEIGHT_RATIO = 0.4;  // 
      
      // 基于实际照片尺寸计算水印尺寸，并考虑像素密度
       const watermarkWidth = photoWidth * WATERMARK_WIDTH_RATIO / pixelRatio
       const watermarkHeight = photoHeight * WATERMARK_HEIGHT_RATIO / pixelRatio

      Logger.info(TAG_LOG, `照片尺寸: ${photoWidth}×${photoHeight}, 水印尺寸: ${watermarkWidth}×${watermarkHeight}`);

      // 创建OffscreenCanvas进行高质量渲染
      const offscreenCanvas = new OffscreenCanvas(watermarkWidth, watermarkHeight);
      const context = offscreenCanvas.getContext('2d');
      
      // 在HarmonyOS中，Canvas可能会根据设备DPI自动缩放
      // 为了确保水印尺寸准确，我们直接使用计算的水印尺寸
      // 不进行额外的设备像素比处理，避免复杂的类型检查
      
      if (!context) {
        throw new Error('无法获取Canvas上下文');
      }

      // 使用Canvas API绘制清晰的水印内容，传入实际尺寸
      await this.drawWatermarkWithCanvas(context, watermarkInfo, watermarkWidth, watermarkHeight);

      // 调试：检查Canvas的实际尺寸
      Logger.info(TAG_LOG, `Canvas实际尺寸: ${offscreenCanvas.width}×${offscreenCanvas.height}`);
      Logger.info(TAG_LOG, `Canvas预期尺寸: ${watermarkWidth}×${watermarkHeight}`);

      // 从Canvas获取PixelMap - 指定正确的区域参数
      const watermarkPixelMap: image.PixelMap = await context.getPixelMap(0, 0, watermarkWidth, watermarkHeight);
       
      // 调试：检查获取的PixelMap实际尺寸
      const watermarkPixelMapInfo = await watermarkPixelMap.getImageInfo();
      Logger.info(TAG_LOG, `Canvas获取的PixelMap尺寸: ${watermarkPixelMapInfo.size.width}×${watermarkPixelMapInfo.size.height}`);
      Logger.info(TAG_LOG, `预期水印尺寸: ${watermarkWidth}×${watermarkHeight}, 实际获取尺寸: ${watermarkPixelMapInfo.size.width}×${watermarkPixelMapInfo.size.height}`);

      return watermarkPixelMap;
    } catch (error) {
      Logger.error(TAG_LOG, `创建水印PixelMap失败: ${error instanceof Error ? error.message : String(error)}`);
      throw new Error('无法创建水印');
    }
  }

  /**
   * 使用Canvas绘制水印内容，基于固定相机分辨率的水印布局和字体
   */
  private async drawWatermarkWithCanvas(context: OffscreenCanvasRenderingContext2D, 
                                       watermarkInfo: WatermarkInfo, 
                                       canvasWidth: number , 
                                       canvasHeight: number ): Promise<void> {
    // 清除画布
    context.clearRect(0, 0, canvasWidth, canvasHeight);
    
    // 设置最高质量渲染参数
    context.imageSmoothingEnabled = true;
    context.imageSmoothingQuality = 'high'; // 设置最高图像平滑质量
    context.textAlign = 'left';
    context.textBaseline = 'top';
    
    // 保存初始状态
    context.save();
    
    Logger.info(TAG_LOG, `水印绘制尺寸: ${canvasWidth}×${canvasHeight}`);
    
    // 固定各区域尺寸
    const titleAreaHeight = 58; // 标题区域高度
    const infoLineHeight = 16;  // 信息行高度
    const infoCount = 7;        // 信息项数量
    const orgAreaHeight = 24;   // 制作单位区域高度
    const padding = 8;          // 内边距
    
    // 固定字体大小
    const titleFontSize = 14;
    const infoFontSize = 12;
    const logoWidth = 60;
    const logoHeight = 46.48;
    const radius = 8;
    const leftPadding = 8;
    

    // 定义边距常量
    const MARGIN = 4; // 绘制图层之间的边距
    const DOUBLE_MARGIN = MARGIN * 2; // 双倍边距
    
    context.translate(0, 0);
    // 1. 绘制主背景 - 严格按照预览UI规范
    context.fillStyle = 'rgba(255, 255, 255, 0.7)'; // 白色70%透明度
    
    // 绘制主背景 - 不用圆角
    this.drawRoundedRect(context, 0, 0, canvasWidth, canvasHeight, radius);
    context.fill();

    // 2. 在左侧绘制蓝色制作单位背景区
    const orgWidth = canvasWidth * 0.1; // 制作单位区域宽度为背景宽度的10%
    context.fillStyle = ('rgba(0, 87, 217, 0.5)'); // 
    const orgX = MARGIN; // X坐标从MARGIN开始，确保左边距
    const orgHeight = canvasHeight - DOUBLE_MARGIN; // 高度自适应，上下各保持MARGIN像素边距
    const orgY = MARGIN; // Y坐标从MARGIN开始，确保上下边距
    this.drawRoundedRect(context, orgX, orgY, orgWidth, orgHeight, 0);
    context.fill();
    
    // 3. 在右侧绘制蓝色标题栏背景区 - 不用圆角
    const titleBarWidth = canvasWidth * 0.3; // 标题栏宽度为背景宽度的30%
    context.fillStyle = ('rgba(0, 87, 217, 0.5)'); // 
    const titleBarX = canvasWidth - titleBarWidth - MARGIN; // 从右侧开始，保持MARGIN像素右边距
    const titleBarHeight = canvasHeight - DOUBLE_MARGIN; // 高度自适应，上下各保持MARGIN像素边距
    const titleBarY = MARGIN; // Y坐标从MARGIN开始，确保上下边距
    this.drawRoundedRect(context, titleBarX, titleBarY, titleBarWidth, titleBarHeight, 0);
    context.fill();

    // 4. 在右侧蓝色标题栏区域绘制旋转90度的水印logo图片
    const watermarkLogo = await this.loadWatermarkLogo();
    if (watermarkLogo) {
      const logoInfo = await watermarkLogo.getImageInfo();
      
      // 保持原始长宽比，计算最大可用尺寸（考虑MARGIN像素边距）
      // 注意：由于要旋转90度，我们需要交换宽高的限制条件
      const maxLogoWidth = titleBarHeight - DOUBLE_MARGIN; // 旋转后，原高度变为宽度限制
      const maxLogoHeight = titleBarWidth - DOUBLE_MARGIN; // 旋转后，原宽度变为高度限制
      
      // 计算保持原始长宽比的缩放尺寸
      const widthRatio = maxLogoWidth / logoInfo.size.width;
      const heightRatio = maxLogoHeight / logoInfo.size.height;
      const scaleRatio = Math.min(widthRatio, heightRatio);
      
      const logoWidth = logoInfo.size.width * scaleRatio;
      const logoHeight = logoInfo.size.height * scaleRatio;
      
      // 计算位置，确保与标题区的上侧、左右侧保持MARGIN个像素间距
      // 注意：旋转90度后，坐标系发生变化，需要重新计算位置
      const logoX = titleBarX + (titleBarWidth - logoHeight) / 2; // 水平居中（考虑旋转后的宽度）
      const logoY = titleBarY + MARGIN; // 从标题区顶部开始，保持MARGIN像素上边距
      
      // 保存当前状态
      context.save();
      
      // 移动到logo中心点并旋转90度
      context.translate(logoX + logoHeight / 2, logoY + logoWidth / 2);
      context.rotate(90 * Math.PI / 180); // 顺时针旋转90度
      
      // 绘制logo（保持原始长宽比）
      context.drawImage(watermarkLogo, -logoWidth / 2, -logoHeight / 2, logoWidth, logoHeight);
      
      // 恢复状态
      context.restore();

      // 5. 在水印logo下方绘制旋转90度的文字
      context.fillStyle = 'white'; // 白色字体
      context.font = '80px sans-serif'; // 设置字体大小和样式
      context.textAlign = 'center'; // 水平居中
      context.textBaseline = 'middle'; // 垂直居中
      
      // 保存当前状态
      context.save();
      
      // 移动到文字中心点并旋转90度
      const titleTextX = titleBarX + titleBarWidth / 2; // 水平中心
      // 计算蓝色标题区剩余区域的Y轴中心点
      // 剩余高度 = 标题栏总高度 - (水印logo的Y位置 + 水印logo的宽度)
      const remainingHeight = titleBarHeight - (logoY + logoWidth);
      // Y轴中心点 = 剩余高度的中心 + 水印logo底部位置
      const titleTextY = logoY + logoWidth + remainingHeight / 2;
      context.translate(titleTextX, titleTextY);
      context.rotate(90 * Math.PI / 180); // 顺时针旋转90度
      
      // 绘制文字（居中对齐）
      context.fillText('灭火救援灾害现场', 0, 0);
      
      // 恢复状态
      context.restore();
    }
    
    // 6. 在左侧制作单位区与右侧标题区域之间绘制旋转90度的文本信息
    const infoItems = this.getWatermarkInfoItems(watermarkInfo);
    const infoStartX = MARGIN; // 从主背景左侧边开始
    const infoAreaWidth = titleBarX - MARGIN; // 可用宽度（从左侧边到右侧标题区左侧边）
    
    // 固定字体大小为50，行高根据剩余空间均匀分配
    const fontSize = 50; // 字体大小固定为50
    const itemCount = infoItems.length; // 总行数
    
    // 计算可用高度（旋转后，宽度变为高度）
    const availableHeight = infoAreaWidth;
    
    // 计算每行需要的行高（均匀分配剩余空间）
    const adjustedLineHeight = availableHeight / itemCount;
    
    context.fillStyle = 'black'; // 黑色字体
    context.font = `${fontSize}px sans-serif`; // 设置固定字体大小50px
    context.textAlign = 'left'; // 左对齐
    context.textBaseline = 'middle'; // 垂直居中
    
    // 保存当前状态
    context.save();
    
    // 移动到信息区域并旋转90度，保持DOUBLE_MARGIN间距对齐
    const infoCenterX = infoStartX + infoAreaWidth / 2; // 信息区域水平中心
    const infoCenterY = DOUBLE_MARGIN; // Y轴保持DOUBLE_MARGIN间距对齐
    context.translate(infoCenterX, infoCenterY);
    context.rotate(90 * Math.PI / 180); // 顺时针旋转90度
    
    // 计算垂直均匀分布
    const totalAdjustedHeight = (itemCount - 1) * adjustedLineHeight; // 总间距高度
    const startY = -totalAdjustedHeight / 2; // 从中心开始向上偏移
    
    // 绘制所有文本信息（垂直均匀分布）
    infoItems.forEach((item, index) => {
      const text = `${item.label}：${item.value}`;
      const y = startY + index * adjustedLineHeight;
      
      // 制作单位单独设置为白色和中等粗细
      if (item.label === '制作单位') {
        context.fillStyle = 'white';
        context.font = '500 50px sans-serif'; // 中等粗细 (FontWeight.Medium)
      } else {
        context.fillStyle = 'black';
        context.font = '50px sans-serif'; // 恢复默认字体
      }
      
      context.fillText(text, 0, y);
    });
    
    // 恢复状态
    context.restore();
    
    // 恢复变换状态
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
   * 合成图像 - 使用原生PixelMap操作
   */
  private async compositeImages(originalPixelMap: image.PixelMap, watermarkPixelMap: image.PixelMap): Promise<image.PixelMap> {
    try {
      // 获取原图信息
      const originalInfo: image.ImageInfo = await originalPixelMap.getImageInfo();
      const watermarkInfo: image.ImageInfo = await watermarkPixelMap.getImageInfo();

      // 照片合成前调试信息 - 详细尺寸参数
      Logger.info(TAG_LOG, `=== 照片合成前尺寸调试 ===`);
      Logger.info(TAG_LOG, `原图尺寸: ${originalInfo.size.width}×${originalInfo.size.height}`);
      Logger.info(TAG_LOG, `水印尺寸: ${watermarkInfo.size.width}×${watermarkInfo.size.height}`);


      // 创建结果PixelMap - 使用最高质量配置，避免缩放
      const createOptions: image.InitializationOptions = {
        size: originalInfo.size,
        pixelFormat: image.PixelMapFormat.RGBA_8888, // 使用正确的PixelMapFormat
        alphaType: image.AlphaType.PREMUL,
        scaleMode: image.ScaleMode.CENTER_CROP, // 避免缩放，保持原始尺寸
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

      // 水印位置设置在照片的左上侧
      const watermarkX = 0; // 左上角x坐标
      const watermarkY = 0; // 左上角y坐标

      // 记录水印尺寸信息用于调试
      Logger.info(TAG_LOG, `水印合成信息 - 原图: ${originalInfo.size.width}×${originalInfo.size.height}, 水印: ${watermarkInfo.size.width}×${watermarkInfo.size.height}`);
      Logger.info(TAG_LOG, `水印位置: x=${watermarkX}, y=${watermarkY}, 预期比例: ${(watermarkInfo.size.width / originalInfo.size.width).toFixed(3)}x`);

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