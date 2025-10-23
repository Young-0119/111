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

import { image } from '@kit.ImageKit';
import { drawing } from '@kit.ArkGraphics2D';
import { Logger } from './Logger';

const TAG = 'ImageWatermarkUtil';

export interface WatermarkInfo {
  timestamp: string;
  weather?: string;
  location?: string;
  altitude?: string;
  direction?: string;
  longitude?: string;
  latitude?: string;
  organization?: string;
}

export interface WatermarkStyle {
  fontSize: number;
  fontColor: string;
  backgroundColor: string;
  backgroundOpacity: number;
  rotation: number;
  scale: number;
  padding: number;
  lineHeight: number;
}

export interface Position {
  x: number;
  y: number;
}

export interface Size {
  width: number;
  height: number;
}

export interface UiWatermarkStyle {
  fontSize?: number;
  fontColor?: string;
  backgroundColor?: string;
  backgroundOpacity?: number;
  rotation?: number;
  scale?: number;
  padding?: number;
  lineHeight?: number;
}

export class ImageWatermarkUtil {
  private static readonly DEFAULT_STYLE: WatermarkStyle = {
    fontSize: 12,
    fontColor: '#FFFFFF',
    backgroundColor: 'rgba(255, 0, 0, 0.8)',
    backgroundOpacity: 0.5,
    rotation: 0,
    scale: 0.8,
    padding: 8,
    lineHeight: 16
  };
  

  /**
   * 添加水印到PixelMap（支持PixelMap输入，支持坐标转换）
   */
  static async addWatermarkToPixelMap(
    originalPixelMap: image.PixelMap,
    watermarkInfo: WatermarkInfo,
    style: WatermarkStyle = ImageWatermarkUtil.DEFAULT_STYLE,
    uiPosition?: Position,
    uiSize?: Size
  ): Promise<image.PixelMap> {
    try {
      Logger.info(TAG, 'Starting watermark addition process');
      
      // 获取原始图片尺寸
      const imageInfo = await originalPixelMap.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;
      
      Logger.info(TAG, `Original image size: ${width}x${height}`);
      
      // 创建离屏画布
      const offscreenCanvas = new OffscreenCanvas(width, height);
      const offscreenContext = offscreenCanvas.getContext('2d');
      
      // 绘制原始图片
      offscreenContext.drawImage(originalPixelMap, 0, 0, width, height);
      
      // 绘制水印（支持坐标转换）
      await ImageWatermarkUtil.drawWatermark(offscreenContext, watermarkInfo, style, width, height, uiPosition, uiSize);
      
      // 获取处理后的PixelMap
      Logger.info(TAG, 'Converting OffscreenCanvas to ImageBitmap...');
      const imageBitmap = offscreenCanvas.transferToImageBitmap();
      
      // 将ImageBitmap转换为PixelMap
      Logger.info(TAG, 'Converting ImageBitmap to PixelMap...');
      const watermarkedPixelMap = await ImageWatermarkUtil.imageBitmapToPixelMap(imageBitmap);
      
      Logger.info(TAG, 'Watermark drawn successfully on PixelMap');
      Logger.info(TAG, 'Watermark addition completed successfully');
      return watermarkedPixelMap;
      
    } catch (error) {
      Logger.error(TAG, `Failed to add watermark: ${error}`);
      // 不重新抛出错误，而是返回原始图片或抛出标准Error
      throw new Error(`Failed to add watermark: ${error}`);
    }
  }

  /**
   * 将ImageBitmap转换为PixelMap
   * @param imageBitmap ImageBitmap对象
   * @returns Promise<PixelMap> 转换后的PixelMap
   */
  private static async imageBitmapToPixelMap(imageBitmap: ImageBitmap): Promise<PixelMap> {
    try {
      Logger.info(TAG, 'Starting ImageBitmap to PixelMap conversion...');
      // 获取ImageBitmap的宽度和高度
      const width = imageBitmap.width;
      const height = imageBitmap.height;
      
      // 创建canvas来提取像素数据
      const canvas = new OffscreenCanvas(width, height);
      const ctx = canvas.getContext('2d');
      
      // 将ImageBitmap绘制到canvas
      ctx.drawImage(imageBitmap, 0, 0);
      
      // 获取像素数据
      const imageData = ctx.getImageData(0, 0, width, height);
      const pixelData = imageData.data.buffer;
      
      // 创建PixelMap
      const pixelMap = await image.createPixelMap(pixelData, {
        size: { width, height },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      
      Logger.info(TAG, 'ImageBitmap to PixelMap conversion completed successfully');
      return pixelMap;
    } catch (error) {
      Logger.error(TAG, `Failed to convert ImageBitmap to PixelMap: ${error}`);
      throw new Error(`ImageBitmap to PixelMap conversion failed: ${error}`);
    }
  }

  /**
   * 绘制水印内容（增强错误处理和性能优化）
   */
  private static async drawWatermark(
    context: OffscreenCanvasRenderingContext2D,
    watermarkInfo: WatermarkInfo,
    style: WatermarkStyle,
    canvasWidth: number,
    canvasHeight: number,
    uiPosition?: Position,
    uiSize?: Size
  ): Promise<void> {
    // 保存当前状态
    context.save();
    
    try {
      // 参数验证
      if (!context) {
        throw new Error('Invalid canvas context: null or undefined');
      }
      
      if (!watermarkInfo) {
        throw new Error('Invalid watermark info: null or undefined');
      }
      
      if (canvasWidth <= 0 || canvasHeight <= 0) {
        throw new Error(`Invalid canvas dimensions: ${canvasWidth}x${canvasHeight}`);
      }
      
      // 构建水印文本行
      const lines = ImageWatermarkUtil.buildWatermarkLines(watermarkInfo);
      Logger.info(TAG, `Built watermark lines: ${JSON.stringify(lines)}`);
      if (lines.length === 0) {
        Logger.warn(TAG, 'No watermark lines to draw, skipping');
        return;
      }
      
      // 计算文本尺寸
      const textMetrics = ImageWatermarkUtil.calculateTextMetrics(context, lines, style);
      if (textMetrics.width <= 0 || textMetrics.height <= 0) {
        Logger.warn(TAG, 'Invalid text dimensions, skipping watermark drawing');
        return;
      }
      
      // 计算水印位置（支持坐标转换）
      let watermarkX: number;
      let watermarkY: number;
      
      if (uiPosition && uiSize) {
        // 如果有UI坐标信息，进行坐标转换
        const convertedPosition = ImageWatermarkUtil.convertUiPositionToCanvas(
          uiPosition.x, uiPosition.y, canvasWidth, canvasHeight, uiSize.width, uiSize.height
        );
        watermarkX = convertedPosition.x;
        watermarkY = convertedPosition.y;
      } else {
        // 默认位置：左上角带边距
        const margin = 20;
        watermarkX = margin;
        watermarkY = margin;
      }
      
      // 边界检查
      if (watermarkX < 0 || watermarkY < 0 || 
          watermarkX + textMetrics.width > canvasWidth || 
          watermarkY + textMetrics.height > canvasHeight) {
        Logger.warn(TAG, `Watermark position out of bounds: (${watermarkX}, ${watermarkY}), adjusting to safe position`);
        
        // 调整到安全位置
        watermarkX = Math.max(0, Math.min(watermarkX, canvasWidth - textMetrics.width));
        watermarkY = Math.max(0, Math.min(watermarkY, canvasHeight - textMetrics.height));
      }
      
      // 应用变换（考虑旋转和缩放）
      Logger.info(TAG, `Applying transformations: translate(${watermarkX}, ${watermarkY}), rotate(${style.rotation}deg), scale(${style.scale})`);
      context.translate(watermarkX, watermarkY);
      context.rotate((style.rotation * Math.PI) / 180);
      context.scale(style.scale, style.scale);
      
      // 设置字体样式
      Logger.info(TAG, `Setting font style: ${style.fontSize}px sans-serif, color: ${style.fontColor}`);
      context.font = `${style.fontSize}px sans-serif`;
      context.fillStyle = style.fontColor;
      
      // 绘制背景
      Logger.info(TAG, `Drawing watermark background at (${watermarkX}, ${watermarkY}) with size ${textMetrics.width}x${textMetrics.height}`);
      ImageWatermarkUtil.drawWatermarkBackground(context, textMetrics, style);
      
      // 绘制文本
      Logger.info(TAG, `Drawing watermark text with font: ${context.font}, color: ${context.fillStyle}`);
      ImageWatermarkUtil.drawWatermarkText(context, lines, style);
      
    } catch (error) {
      Logger.error(TAG, `Failed to draw watermark: ${error}`);
      // 错误恢复：不中断整个处理流程，只是记录错误
      Logger.info(TAG, 'Continuing without watermark due to drawing error');
    } finally {
      // 恢复状态
      context.restore();
    }
  }

  /**
   * 构建水印文本行
   */
  private static buildWatermarkLines(watermarkInfo: WatermarkInfo): string[] {
    const lines: string[] = [];
    
    // 标题行（制作单位）
    if (watermarkInfo.organization) {
      lines.push(`制作单位：${watermarkInfo.organization}`);
    }
    
    // 时间戳
    lines.push(`拍摄时间：${watermarkInfo.timestamp}`);
    
    // 天气信息
    if (watermarkInfo.weather) {
      lines.push(`天气：${watermarkInfo.weather}`);
    }
    
    // 位置信息
    if (watermarkInfo.location) {
      lines.push(`位置：${watermarkInfo.location}`);
    }
    
    // 海拔
    if (watermarkInfo.altitude) {
      lines.push(`海拔：${watermarkInfo.altitude}`);
    }
    
    // 方向
    if (watermarkInfo.direction) {
      lines.push(`方向：${watermarkInfo.direction}`);
    }
    
    // 经纬度
    if (watermarkInfo.longitude && watermarkInfo.latitude) {
      lines.push(`经度：${watermarkInfo.longitude} 纬度：${watermarkInfo.latitude}`);
    }
    
    return lines;
  }

  /**
   * 计算文本尺寸
   */
  private static calculateTextMetrics(
    context: OffscreenCanvasRenderingContext2D,
    lines: string[],
    style: WatermarkStyle
  ): Size {
    let maxWidth = 0;
    const lineHeight = style.lineHeight;
    
    lines.forEach(line => {
      const metrics = context.measureText(line);
      maxWidth = Math.max(maxWidth, metrics.width);
    });
    
    return {
      width: maxWidth + (style.padding * 2),
      height: (lines.length * lineHeight) + (style.padding * 2)
    };
  }

  /**
   * 绘制水印背景
   */
  private static drawWatermarkBackground(
    context: OffscreenCanvasRenderingContext2D,
    textMetrics: Size,
    style: WatermarkStyle
  ): void {
    // 解析背景颜色
    Logger.info(TAG, `Parsing background color: ${style.backgroundColor} with opacity: ${style.backgroundOpacity}`);
    const bgColor = ImageWatermarkUtil.parseRgbaColor(style.backgroundColor, style.backgroundOpacity);
    Logger.info(TAG, `Parsed background color: ${bgColor}`);
    
    context.fillStyle = bgColor;
    context.fillRect(0, 0, textMetrics.width, textMetrics.height);
    Logger.info(TAG, `Filled background rectangle: 0,0,${textMetrics.width}x${textMetrics.height}`);
  }

  /**
   * 绘制水印文本
   */
  private static drawWatermarkText(
    context: OffscreenCanvasRenderingContext2D,
    lines: string[],
    style: WatermarkStyle
  ): void {
    const lineHeight = style.lineHeight;
    const startY = style.padding + 12; // 字体基线调整
    
    Logger.info(TAG, `Drawing ${lines.length} text lines with line height: ${lineHeight}, startY: ${startY}`);
    
    lines.forEach((line, index) => {
      const y = startY + (index * lineHeight);
      Logger.info(TAG, `Drawing text line ${index}: "${line}" at position (${style.padding}, ${y})`);
      context.fillText(line, style.padding, y);
    });
  }

  /**
   * 解析RGBA颜色
   */
  private static parseRgbaColor(color: string, opacity: number): string {
    // 如果是rgba格式，提取rgb部分并更新透明度
    const rgbaMatch = color.match(/rgba?\(([^)]+)\)/);
    if (rgbaMatch) {
      const rgbPart = rgbaMatch[1].split(',').slice(0, 3).join(',');
      return `rgba(${rgbPart},${opacity})`;
    }
    
    // 如果是十六进制颜色，转换为rgba
    if (color.startsWith('#')) {
      const hex = color.slice(1);
      const r = parseInt(hex.slice(0, 2), 16);
      const g = parseInt(hex.slice(2, 4), 16);
      const b = parseInt(hex.slice(4, 6), 16);
      return `rgba(${r},${g},${b},${opacity})`;
    }
    
    // 默认返回原颜色
    return color;
  }

  /**
   * 添加水印到图片（支持ArrayBuffer输入，支持坐标转换，带缓存和错误处理）
   */
  static async addWatermarkToPhoto(
    imageBuffer: ArrayBuffer,
    watermarkInfo: WatermarkInfo,
    style: WatermarkStyle = this.DEFAULT_STYLE,
    uiPosition?: Position,
    uiSize?: Size
  ): Promise<ArrayBuffer> {
    const startTime = Date.now();
    
    try {
      // 参数验证
      if (!imageBuffer || imageBuffer.byteLength === 0) {
        throw new Error('Invalid image buffer: empty or null');
      }
      
      if (!watermarkInfo) {
        throw new Error('Invalid watermark info: null or undefined');
      }
      
      Logger.info(TAG, `Starting watermark addition process for ArrayBuffer with style: ${JSON.stringify(style)}`);
      Logger.info(TAG, `Watermark info: ${JSON.stringify(watermarkInfo)}`);
      
      // 从ArrayBuffer创建ImageSource
      const imageSource = image.createImageSource(imageBuffer);
      const pixelMap = await imageSource.createPixelMap();
      
      // 获取图片尺寸
      const imageInfo = await pixelMap.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;
      
      Logger.info(TAG, `Original image size: ${width}x${height}`);
      
      // 图片尺寸限制检查（性能优化）
      const maxDimension = 4096; // 最大支持4K图片
      if (width > maxDimension || height > maxDimension) {
        Logger.warn(TAG, `Image dimensions too large: ${width}x${height}, skipping watermark`);
        return imageBuffer; // 返回原始图片
      }
      
      // 创建离屏画布
      const offscreenCanvas = new OffscreenCanvas(width, height);
      const offscreenContext = offscreenCanvas.getContext('2d');
      
      // 绘制原始图片
      offscreenContext.drawImage(pixelMap, 0, 0, width, height);
      
      // 绘制水印（支持坐标转换）
      Logger.info(TAG, `About to draw watermark with style: fontSize=${style.fontSize}, fontColor=${style.fontColor}, rotation=${style.rotation}`);
      await ImageWatermarkUtil.drawWatermark(offscreenContext, watermarkInfo, style, width, height, uiPosition, uiSize);
      Logger.info(TAG, 'Watermark drawing completed');
      
      // 获取处理后的PixelMap
      Logger.info(TAG, 'Converting OffscreenCanvas to ImageBitmap...');
      const imageBitmap = offscreenCanvas.transferToImageBitmap();
      Logger.info(TAG, 'ImageBitmap created successfully');
      
      const watermarkedPixelMap = await ImageWatermarkUtil.imageBitmapToPixelMap(imageBitmap);
      Logger.info(TAG, 'PixelMap created from ImageBitmap');
      
      // 将PixelMap转换回ArrayBuffer
      const resultBuffer = await ImageWatermarkUtil.pixelMapToArrayBuffer(watermarkedPixelMap);
      Logger.info(TAG, 'ArrayBuffer conversion completed');
      
      const processingTime = Date.now() - startTime;
      Logger.info(TAG, `Watermark addition completed successfully in ${processingTime}ms`);
      
      return resultBuffer;
      
    } catch (error) {
      Logger.error(TAG, `Failed to add watermark to ArrayBuffer: ${error}`);
      Logger.error(TAG, `Error stack: ${error.stack || 'No stack trace available'}`);
      
      // 错误恢复策略：返回原始图片
      if (imageBuffer) {
        Logger.info(TAG, 'Returning original image due to watermark processing error');
        return imageBuffer;
      }
      
      // 如果没有原始图片，抛出自定义错误
      throw new Error('Failed to add watermark to ArrayBuffer: no valid image buffer available');
    }
  }

  /**
   * 将PixelMap转换回ArrayBuffer（带错误处理和优化）
   */
  private static async pixelMapToArrayBuffer(pixelMap: image.PixelMap): Promise<ArrayBuffer> {
    try {
      Logger.info(TAG, 'Converting PixelMap to ArrayBuffer');
      
      // 参数验证
      if (!pixelMap) {
        throw new Error('Invalid pixelMap: null or undefined');
      }
      
      // 获取图片信息
      const imageInfo = await pixelMap.getImageInfo();
      if (!imageInfo || !imageInfo.size) {
        throw new Error('Invalid image info from pixelMap');
      }
      
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;
      
      // 尺寸验证
      if (width <= 0 || height <= 0) {
        throw new Error(`Invalid image dimensions: ${width}x${height}`);
      }
      
      // 内存限制检查
      const bufferSize = width * height * 4; // RGBA格式
      const maxBufferSize = 50 * 1024 * 1024; // 50MB限制
      if (bufferSize > maxBufferSize) {
        throw new Error(`Image too large for conversion: ${bufferSize} bytes`);
      }
      
      // 读取像素数据
      const buffer = new ArrayBuffer(bufferSize);
      await pixelMap.readPixelsToBuffer(buffer);
      
      Logger.info(TAG, `PixelMap to ArrayBuffer conversion completed: ${bufferSize} bytes`);
      return buffer;
      
    } catch (error) {
      Logger.error(TAG, `Failed to convert PixelMap to ArrayBuffer: ${error}`);
      throw new Error(`Failed to convert PixelMap to ArrayBuffer: ${error}`);
    }
  }

  /**
   * 获取当前时间戳
   */
  static getCurrentTimestamp(): string {
    const now = new Date();
    const year = now.getFullYear();
    const month = String(now.getMonth() + 1).padStart(2, '0');
    const day = String(now.getDate()).padStart(2, '0');
    const hours = String(now.getHours()).padStart(2, '0');
    const minutes = String(now.getMinutes()).padStart(2, '0');
    const seconds = String(now.getSeconds()).padStart(2, '0');
    return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
  }

  /**
   * 坐标转换工具方法 - 将UI坐标转换为Canvas坐标
   */
  static convertUiPositionToCanvas(
    uiX: number,
    uiY: number,
    canvasWidth: number,
    canvasHeight: number,
    uiWidth: number,
    uiHeight: number
  ): Position {
    // 计算缩放比例
    const scaleX = canvasWidth / uiWidth;
    const scaleY = canvasHeight / uiHeight;
    
    // 应用缩放转换
    return {
      x: uiX * scaleX,
      y: uiY * scaleY
    };
  }

  /**
   * 样式匹配方法 - 根据UI样式生成Canvas样式
   */
  static matchStyleForCanvas(uiStyle: UiWatermarkStyle): WatermarkStyle {
    // 默认样式
    const defaultStyle = ImageWatermarkUtil.DEFAULT_STYLE;
    
    if (!uiStyle) {
      return defaultStyle;
    }
    
    // 转换UI样式到Canvas样式
    return {
      fontSize: uiStyle.fontSize || defaultStyle.fontSize,
      fontColor: uiStyle.fontColor || defaultStyle.fontColor,
      backgroundColor: uiStyle.backgroundColor || defaultStyle.backgroundColor,
      backgroundOpacity: uiStyle.backgroundOpacity !== undefined ? uiStyle.backgroundOpacity : defaultStyle.backgroundOpacity,
      rotation: uiStyle.rotation || defaultStyle.rotation,
      scale: uiStyle.scale || defaultStyle.scale,
      padding: uiStyle.padding || defaultStyle.padding,
      lineHeight: uiStyle.lineHeight || defaultStyle.lineHeight
    };
  }
}