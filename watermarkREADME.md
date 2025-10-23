# 自定义相机水印功能开发文档

## 技术概述

本方案基于OffscreenCanvas离屏画布技术，实现相机拍照图片的水印添加功能。通过离屏绘制方式，将水印文本或图像与原始图片融合，生成带水印的最终图片文件。

### 核心原理
- **OffscreenCanvas**：提供离屏画布功能，无需将绘制过程渲染到屏幕
- **OffscreenCanvasRenderingContext2D**：在离屏画布上进行绘制操作
- **PixelMap**：图片像素数据载体，用于图片处理流程

## 技术架构

### 关键技术点
1. **图片解析**：将原始图片解析为PixelMap数据格式
2. **离屏绘制**：在OffscreenCanvas上依次绘制原图和水印
3. **像素融合**：通过Canvas 2D API实现图片与水印的像素级融合
4. **文件保存**：将处理后的PixelMap数据写入文件系统

### 与Camera Kit集成
本方案与现有Camera Kit相机服务深度集成，在拍照流程中无缝嵌入水印处理环节。

## 开发流程

### 1. 图片数据获取与解析
```typescript
// 从资源或相机获取图片数据
async getImagePixelMap(resource: Resource): Promise<ImagePixelMap> {
  const data: Uint8Array = await this.getUIContext().getHostContext()?.resourceManager.getMediaContent(resource.id) as Uint8Array;
  const arrayBuffer: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
  const imageSource: image.ImageSource = image.createImageSource(arrayBuffer);
  return await imageSource2PixelMap(imageSource);
}
```

### 2. 创建PixelMap对象
```typescript
// 获取图片信息并创建PixelMap
export async function imageSource2PixelMap(imageSource: image.ImageSource): Promise<ImagePixelMap> {
  const imageInfo: image.ImageInfo = await imageSource.getImageInfo();
  const height = imageInfo.size.height;
  const width = imageInfo.size.width;
  const options: image.DecodingOptions = {
    editable: true,
    desiredSize: { height, width }
  };
  const pixelMap: PixelMap = await imageSource.createPixelMap(options);
  const result: ImagePixelMap = { pixelMap, width, height };
  return result;
}
```

### 3. 离屏水印添加
```typescript
// 核心水印添加函数
export function addWatermark(
  imagePixelMap: ImagePixelMap,
  text: string = 'watermark',
  drawWatermark?: (OffscreenContext: OffscreenCanvasRenderingContext2D) => void
): image.PixelMap {
  // 创建与图片同尺寸的离屏画布
  const height = uiContext?.px2vp(imagePixelMap.height) as number;
  const width = uiContext?.px2vp(imagePixelMap.width) as number;
  const offScreenCanvas = new OffscreenCanvas(width, height);
  const offScreenContext = offScreenCanvas.getContext('2d');
  
  // 绘制原图
  offScreenContext.drawImage(imagePixelMap.pixelMap, 0, 0, width, height);
  
  // 添加水印（支持自定义或默认文本）
  if (drawWatermark) {
    drawWatermark(offScreenContext);
  } else {
    const displayWidth = display.getDefaultDisplaySync().width;
    const vpWidth = uiContext?.px2vp(displayWidth) ?? displayWidth;
    const imageScale = width / vpWidth;
    
    // 设置水印样式
    offScreenContext.textAlign = 'right';
    offScreenContext.fillStyle = '#A2FFFFFF'; // 半透明白色
    offScreenContext.font = 12 * imageScale + 'vp';
    
    const padding = 5 * imageScale;
    offScreenContext.fillText(text, width - padding, height - padding);
  }
  
  // 获取处理后的PixelMap
  return offScreenContext.getPixelMap(0, 0, width, height);
}
```

### 4. 文件保存
```typescript
// 将PixelMap保存为图片文件
export async function saveToFile(pixelMap: image.PixelMap, context: Context): Promise<void> {
  try {
    const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    const filePath = await phAccessHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
    
    const imagePacker = image.createImagePacker();
    const imageBuffer = await imagePacker.packToData(pixelMap, {
      format: 'image/png',
      quality: 100
    });
    
    const mode = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE;
    const fd = (await fileIo.open(filePath, mode)).fd;
    await fileIo.truncate(fd);
    await fileIo.write(fd, imageBuffer);
  } catch (err) {
    hilog.error(0x0000, TAG, 'saveToFile error：', JSON.stringify(err) ?? '');
  } finally {
    if (fd) {
      fileIo.close(fd);
    }
  }
}
```

## 集成方案

### 现有项目集成点

#### 1. UI层集成 (entry/src/main/ets/views/)
- **WatermarkOverlay.ets**：已实现的水印覆盖层组件
  - 支持8项信息展示：时间、天气、位置、海拔、方位角、经纬度、制作单位
  - 实时时间更新机制（每秒更新）
  - 双击编辑制作单位功能
  - 数据持久化（Preferences存储）
  - 特殊视觉效果：旋转90度、缩放80%、半透明背景

#### 2. 相机模块集成 (camera/src/main/ets/)
- **PhotoManager.ets**：需要集成水印处理逻辑
  - 在拍照流程中调用addWatermarkToPhoto方法
  - 获取当前WatermarkInfo数据
  - 协调原始图片和水印合成

#### 3. 状态管理层 (entry/src/main/ets/viewModels/)
- **PreviewViewModel.ets**：需要添加水印状态管理
  - 管理WatermarkInfo数据状态
  - 提供获取当前水印信息的方法
  - 协调UI显示和图片处理的数据同步

#### 4. 工具类扩展 (commons/src/main/ets/utils/)
- **ImageWatermarkUtil.ets**：新增图片水印处理工具类
  - 实现addWatermarkToPhoto核心方法
  - 处理坐标转换和样式匹配
  - 提供各种水印元素的绘制方法

### 数据流设计
```
WatermarkOverlay预览 → 用户编辑确认 → PreviewViewModel状态管理 → 
PhotoManager拍照 → ImageWatermarkUtil离屏处理 → 生成带水印图片 → 文件保存
```

### 具体数据流程

#### 1. 预览数据流
```
WatermarkInfo默认值 → WatermarkOverlay显示 → 用户双击编辑 → 
Preferences存储 → 实时更新显示
```

#### 2. 拍照数据流
```
相机原始图像 → PhotoManager获取水印信息 → ImageWatermarkUtil处理 → 
OffscreenCanvas绘制水印 → 生成新PixelMap → 保存文件
```

#### 3. 状态同步机制
```typescript
// PreviewViewModel协调数据
class PreviewViewModel {
  watermarkInfo: WatermarkInfo;
  
  // UI层获取数据用于显示
  getWatermarkInfoForDisplay(): WatermarkInfo {
    return this.watermarkInfo;
  }
  
  // 拍照时获取数据用于处理
  getWatermarkInfoForProcessing(): WatermarkInfo {
    return {
      ...this.watermarkInfo,
      timestamp: this.getCurrentTimestamp() // 确保时间准确
    };
  }
}
```

## 性能优化

### 1. 异步处理
- 水印处理采用异步方式，避免阻塞UI线程
- 使用Promise链式处理，确保流程顺畅

### 2. 内存管理
- 及时释放中间PixelMap对象
- 合理控制OffscreenCanvas生命周期

### 3. 缓存策略
- 相同尺寸图片可复用OffscreenCanvas
- 字体样式等可缓存避免重复设置

## 实际实现方案

### 水印界面组件 (WatermarkOverlay.ets)

基于现有项目实现的水印覆盖层组件，具有以下特性：

#### 1. 水印信息结构
```typescript
export interface WatermarkInfo {
  timestamp: string;      // 拍摄时间
  weather?: string;       // 天气信息
  location?: string;      // 位置信息
  altitude?: string;      // 海拔信息
  direction?: string;     // 方位角信息
  longitude?: string;     // 经度信息
  latitude?: string;      // 纬度信息
  organization?: string;  // 制作单位
}
```

#### 2. 界面布局设计
- **左上角定位**：使用Row容器实现左上角对齐
- **半透明背景**：白色背景，透明度70% (rgba(255, 255, 255, 0.7))
- **阴影效果**：半径6，黑色透明度30%，向下偏移3像素
- **缩放和旋转**：以左下角为中心缩放到80%，顺时针旋转90度
- **圆角边框**：8像素圆角，4像素内边距

#### 3. 视觉层次结构
1. **标题区域**：蓝色半透明背景，包含Logo和标题
2. **信息区域**：黑色文字显示各项数据
3. **制作单位**：特殊样式，蓝色半透明背景，支持双击编辑

#### 4. 交互功能
- **实时时间更新**：每秒自动更新时间戳
- **双击编辑制作单位**：弹出模态对话框进行编辑
- **数据持久化**：使用Preferences保存制作单位信息
- **默认值处理**：各项信息支持默认值和加载状态

#### 5. 样式细节
```typescript
// 标题样式
.backgroundColor('rgba(0, 87, 217, 0.5)')
.fontColor('#FFFFFF')
.fontWeight(FontWeight.Bold)

// 信息文本样式
.fontSize(12)
.fontColor('#000000')
.margin({ bottom: 4 })

// 特殊变换
.scale({ x: 0.8, y: 0.8, centerX: '0%', centerY: '100%' })
.rotate({ angle: 90, centerX: '0%', centerY: '100%' })
.translate({ x: 0, y: '-100%' })
```

### 与OffscreenCanvas技术集成

虽然界面层使用声明式UI组件实现水印显示，但实际图片处理仍需要OffscreenCanvas技术：

1. **界面预览**：WatermarkOverlay提供实时预览效果
2. **数据收集**：收集时间、位置、天气等信息
3. **离屏绘制**：使用OffscreenCanvas将水印信息绘制到图片上
4. **最终输出**：生成带水印的图片文件

### 性能优化策略

#### 1. 界面层优化
- 使用@State管理状态变化
- 合理设置重绘区域
- 避免不必要的布局计算

#### 2. 数据层优化
- 异步加载和保存配置信息
- 缓存机制减少重复计算
- 错误处理确保稳定性

#### 3. 图片处理优化
- 异步处理避免阻塞UI线程
- 合理控制OffscreenCanvas生命周期
- 内存管理和及时释放资源

## 完整集成流程

### 1. 预览阶段 (UI层)
```typescript
// WatermarkOverlay组件提供实时预览
WatermarkOverlay({
  watermarkInfo: {
    timestamp: '2025-01-08 14:30:25',
    weather: '晴朗',
    location: '北京市朝阳区',
    altitude: '50米',
    direction: '北偏东30度',
    longitude: '116.4074°',
    latitude: '39.9042°',
    organization: '消防救援支队'
  }
})
```

### 2. 拍照阶段 (相机层)
```typescript
// PhotoManager.ets中集成水印处理
async capturePhoto(): Promise<string> {
  // 1. 获取原始图片PixelMap
  const originalPixelMap = await this.captureOriginalPhoto();
  
  // 2. 获取当前水印信息
  const watermarkInfo = this.getCurrentWatermarkInfo();
  
  // 3. 使用OffscreenCanvas添加水印
  const watermarkedPixelMap = await this.addWatermarkToPixelMap(originalPixelMap, watermarkInfo);
  
  // 4. 保存带水印的图片
  return await this.savePhoto(watermarkedPixelMap);
}
```

### 3. 水印处理核心逻辑
```typescript
// 在PhotoManager中添加水印处理方法
private async addWatermarkToPhoto(
  pixelMap: image.PixelMap, 
  watermarkInfo: WatermarkInfo
): Promise<image.PixelMap> {
  // 1. 创建离屏画布
  const offscreenCanvas = new OffscreenCanvas(width, height);
  const ctx = offscreenCanvas.getContext('2d');
  
  // 2. 绘制原始图片
  ctx.drawImage(pixelMap, 0, 0, width, height);
  
  // 3. 根据WatermarkInfo绘制水印信息
  this.drawWatermarkInfo(ctx, watermarkInfo);
  
  // 4. 返回处理后的PixelMap
  return ctx.getPixelMap(0, 0, width, height);
}
```

### 4. 数据同步机制
```typescript
// PreviewViewModel.ets中管理水印状态
@Observed
class WatermarkViewModel {
  @Track watermarkInfo: WatermarkInfo;
  
  // 同步UI组件和处理逻辑的数据
  updateWatermarkInfo(info: Partial<WatermarkInfo>) {
    this.watermarkInfo = { ...this.watermarkInfo, ...info };
  }
  
  // 获取当前水印信息供拍照使用
  getCurrentWatermarkInfo(): WatermarkInfo {
    return this.watermarkInfo;
  }
}
```

## 关键技术实现细节

### 1. 坐标转换处理
由于WatermarkOverlay组件使用了旋转和缩放变换，在OffscreenCanvas处理时需要相应的坐标转换：

```typescript
// 将UI坐标转换为图片坐标
private transformUICoordinatesToImage(
  uiX: number, 
  uiY: number, 
  imageWidth: number, 
  imageHeight: number
): { x: number; y: number } {
  // 考虑旋转90度和缩放80%的变换
  const scale = 0.8;
  const angle = 90 * Math.PI / 180;
  
  // 应用逆变换
  const centerX = imageWidth * 0.1; // 左上角区域
  const centerY = imageHeight * 0.1;
  
  return {
    x: centerX + (uiX * Math.cos(angle) - uiY * Math.sin(angle)) / scale,
    y: centerY + (uiX * Math.sin(angle) + uiY * Math.cos(angle)) / scale
  };
}
```

### 2. 字体和样式匹配
确保OffscreenCanvas绘制的样式与UI预览一致：

```typescript
private applyWatermarkStyle(ctx: OffscreenCanvasRenderingContext2D) {
  // 匹配WatermarkOverlay的样式
  ctx.font = '12px sans-serif';
  ctx.fillStyle = '#000000'; // 黑色文字
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  
  // 特殊样式处理
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(90 * Math.PI / 180); // 旋转90度
  ctx.scale(0.8, 0.8); // 缩放80%
}
```

### 3. 分层绘制策略
按照WatermarkOverlay的视觉层次进行绘制：

```typescript
private drawWatermarkInfo(ctx: OffscreenCanvasRenderingContext2D, info: WatermarkInfo) {
  // 1. 绘制背景层（半透明白色）
  this.drawBackgroundLayer(ctx);
  
  // 2. 绘制标题区域（蓝色半透明）
  this.drawTitleSection(ctx, info);
  
  // 3. 绘制信息列表（黑色文字）
  this.drawInfoList(ctx, info);
  
  // 4. 绘制制作单位（特殊蓝色背景）
  this.drawOrganizationSection(ctx, info);
}
```

## 错误处理

### 1. 图片解析错误
- 处理损坏或格式不支持图片
- 提供友好的错误提示

### 2. 内存不足
- 监控内存使用情况
- 提供降级方案（如降低图片质量）

### 3. 文件保存失败
- 处理存储权限问题
- 处理磁盘空间不足

## 兼容性考虑

### 1. 设备适配
- 适配不同屏幕密度和分辨率
- 处理横竖屏切换

### 2. 系统版本
- 兼容不同HarmonyOS版本
- 处理API差异

### 3. 权限管理
- 确保必要的文件读写权限
- 处理权限被拒绝场景

## 测试方案

### 1. 功能测试
- 水印添加准确性验证
- 不同样式水印测试
- 批量处理稳定性测试

### 2. 性能测试
- 处理时间测试
- 内存占用测试
- 大文件处理测试

### 3. 兼容性测试
- 不同设备测试
- 不同系统版本测试
- 异常情况测试

## 相关权限

本方案需要以下权限支持：
- `ohos.permission.WRITE_IMAGEVIDEO`：写入图片文件
- `ohos.permission.READ_IMAGEVIDEO`：读取图片文件
- `ohos.permission.CAMERA`：相机使用权限（已有）

## 约束与限制

1. 支持HarmonyOS 5.1.1 Release及以上版本
2. 支持标准系统设备：华为手机、平板
3. 图片格式支持：PNG、JPEG等常见格式
4. 水印文本长度建议不超过50个字符
5. 同时处理图片数量建议不超过10张

## 后续优化方向

1. **AI智能水印**：根据图片内容自动选择水印位置和样式
2. **云端处理**：支持云端批量水印处理
3. **模板系统**：提供丰富的水印模板库
4. **性能提升**：利用GPU加速处理过程
5. **用户体验**：提供更直观的操作界面